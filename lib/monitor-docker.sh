#!/bin/bash
################################################################################
# Script: monitor-docker.sh
# Propósito: Diagnóstico de Docker e containerd (M2) para o Monitor Preventivo
# Uso: source /opt/vpsguardian/lib/monitor-docker.sh
#      (requer monitor-common.sh carregado antes)
#
# Estados principais:
#   HEALTHY                                 → Docker e containerd respondem bem
#   SLOW                                    → respondem, mas acima do threshold
#   DOCKER_UNRESPONSIVE_CONTAINERD_HEALTHY  → docker ps trava, containerd OK
#                                             (Docker pode ser vítima do host!)
#   DOCKER_AND_CONTAINERD_UNRESPONSIVE      → ambos inacessíveis
#
# Estados auxiliares:
#   DOCKER_NOT_INSTALLED, PERMISSION_DENIED,
#   DOCKER_UNRESPONSIVE_CONTAINERD_UNKNOWN, UNKNOWN
#
# Regras: toda sonda tem timeout e latência medida; a ausência de systemd,
# do binário docker ou do ctr nunca derruba o monitor; nenhuma saída inclui
# secrets ou dumps de configuração do Docker.
#
# Referência: docs/MARCOS-MONITOR-PREVENTIVO.md (M2)
# Versão: 1.0.0
################################################################################

################################################################################
# Sonda genérica com timeout, latência e stderr sanitizado
################################################################################

# Timestamp em milissegundos (coreutils GNU nas distros suportadas)
monitor_now_ms() {
    date +%s%3N
}

# Executa uma sonda: captura código, latência e primeira linha do stderr.
# Uso: monitor_probe <timeout_s> comando [args...]
# Resultado nas globais: PROBE_RC, PROBE_LATENCY_MS, PROBE_ERR, PROBE_OUT,
#                        PROBE_PERMISSION (erro de permissão em qualquer linha)
monitor_probe() {
    local timeout_s="$1"
    shift

    PROBE_RC=0 PROBE_LATENCY_MS=0 PROBE_ERR="" PROBE_OUT="" PROBE_PERMISSION=false

    local errfile
    errfile=$(mktemp "${TMPDIR:-/tmp}/vpsg-probe.XXXXXX" 2>/dev/null) || errfile="/dev/null"

    local start end
    start=$(monitor_now_ms)
    PROBE_OUT=$(run_with_timeout "$timeout_s" "$@" 2>"$errfile")
    PROBE_RC=$?
    end=$(monitor_now_ms)
    PROBE_LATENCY_MS=$((end - start))

    if [ "$errfile" != "/dev/null" ]; then
        # Permissão é checada no stderr inteiro (a mensagem pode vir longe do início)
        grep -qi "permission denied" "$errfile" 2>/dev/null && PROBE_PERMISSION=true
        # Para exibição: apenas a primeira linha, truncada — nunca dumps completos
        PROBE_ERR=$(head -n1 "$errfile" 2>/dev/null | cut -c1-160 | tr -d '"' )
        rm -f "$errfile" 2>/dev/null
    fi
    return "$PROBE_RC"
}

# Detecta erro de permissão no stderr de uma sonda
monitor_probe_is_permission_error() {
    echo "$1" | grep -qi "permission denied"
}

################################################################################
# Processos via /proc (dockerd / containerd)
################################################################################

# Encontra o PID de um processo pelo nome (comm), varrendo /proc.
# Testável via MONITOR_PROC_DIR. Uso: monitor_find_pid_by_comm <nome>
monitor_find_pid_by_comm() {
    local name="$1" dir comm
    for dir in "$MONITOR_PROC_DIR"/[0-9]*; do
        [ -r "$dir/comm" ] || continue
        read -r comm < "$dir/comm" 2>/dev/null || continue
        if [ "$comm" = "$name" ]; then
            basename "$dir"
            return 0
        fi
    done
    return 1
}

# Lê estado, threads e RSS (MB) de /proc/<pid>/status
# Saída: linhas chave=valor (state, threads, rss_mb)
monitor_proc_status() {
    local pid="$1"
    local status_file="$MONITOR_PROC_DIR/$pid/status"
    [ -r "$status_file" ] || return 1

    awk '
        /^State:/   {print "state=" $2}
        /^Threads:/ {print "threads=" $2}
        /^VmRSS:/   {print "rss_mb=" int($2/1024)}
    ' "$status_file" 2>/dev/null
}

# Preenche variáveis <PREFIX>_PID/STATE/THREADS/RSS_MB/CPU_PERCENT/ETIME
# para um daemon. Uso: monitor_collect_daemon_info <comm> <PREFIX>
monitor_collect_daemon_info() {
    local comm="$1" prefix="$2"
    local pid state="" threads="" rss="" pcpu="" etime=""

    pid=$(monitor_find_pid_by_comm "$comm") || {
        printf -v "${prefix}_PID" '%s' ""
        return 1
    }

    local parsed
    parsed=$(monitor_proc_status "$pid")
    state=$(echo "$parsed" | awk -F= '$1=="state"{print $2}')
    threads=$(echo "$parsed" | awk -F= '$1=="threads"{print $2}')
    rss=$(echo "$parsed" | awk -F= '$1=="rss_mb"{print $2}')

    # CPU e tempo de execução: complemento via ps (essenciais já vieram de /proc)
    local ps_out
    ps_out=$(run_with_timeout "$MONITOR_COMMAND_TIMEOUT" ps -o pcpu=,etime= -p "$pid" 2>/dev/null | head -n1)
    pcpu=$(echo "$ps_out" | awk '{print $1}')
    etime=$(echo "$ps_out" | awk '{print $2}')

    printf -v "${prefix}_PID" '%s' "$pid"
    printf -v "${prefix}_STATE" '%s' "$state"
    printf -v "${prefix}_THREADS" '%s' "$threads"
    printf -v "${prefix}_RSS_MB" '%s' "$rss"
    printf -v "${prefix}_CPU_PERCENT" '%s' "$pcpu"
    printf -v "${prefix}_ETIME" '%s' "$etime"
    return 0
}

################################################################################
# Serviços systemd
################################################################################

# Estado de um serviço: active|inactive|failed|activating|unknown|no-systemd
monitor_service_state() {
    local service="$1"
    local systemctl_bin="${MONITOR_SYSTEMCTL_BIN:-systemctl}"

    if ! command -v "$systemctl_bin" &>/dev/null; then
        echo "no-systemd"
        return 0
    fi

    local state
    state=$(run_with_timeout "$MONITOR_COMMAND_TIMEOUT" "$systemctl_bin" is-active "$service" 2>/dev/null)
    case "$state" in
        active|inactive|failed|activating|deactivating) echo "$state" ;;
        "") echo "unknown" ;;
        *) echo "$state" ;;
    esac
}

################################################################################
# Classificação (função pura, testável)
################################################################################

# Classifica o estado do Docker a partir dos resultados das sondas.
# Uso: monitor_docker_classify <installed> <permission> <ps_ok> <max_latency_ms> \
#                              <slow_ms> <containerd_ok>
#   installed:     true|false
#   permission:    true|false (erro de permissão detectado)
#   ps_ok:         true|false (docker ps respondeu dentro do timeout)
#   max_latency_ms: maior latência entre as sondas docker
#   slow_ms:       threshold de lentidão
#   containerd_ok: true|false|unknown
monitor_docker_classify() {
    local installed="$1" permission="$2" ps_ok="$3"
    local max_latency_ms="$4" slow_ms="$5" containerd_ok="$6"

    if [ "$installed" != "true" ]; then
        echo "DOCKER_NOT_INSTALLED"
        return 0
    fi

    if [ "$ps_ok" = "true" ]; then
        if monitor_is_number "$max_latency_ms" && monitor_is_number "$slow_ms" && \
            [ "$max_latency_ms" -gt "$slow_ms" ]; then
            echo "SLOW"
        else
            echo "HEALTHY"
        fi
        return 0
    fi

    # docker ps falhou
    if [ "$permission" = "true" ]; then
        echo "PERMISSION_DENIED"
        return 0
    fi

    case "$containerd_ok" in
        true)  echo "DOCKER_UNRESPONSIVE_CONTAINERD_HEALTHY" ;;
        false) echo "DOCKER_AND_CONTAINERD_UNRESPONSIVE" ;;
        *)     echo "DOCKER_UNRESPONSIVE_CONTAINERD_UNKNOWN" ;;
    esac
}

# Severidade correspondente a cada estado
monitor_docker_severity_for() {
    local status="$1"
    case "$status" in
        HEALTHY) echo "INFO" ;;
        SLOW) echo "WARNING" ;;
        DOCKER_UNRESPONSIVE_CONTAINERD_HEALTHY) echo "CRITICAL" ;;
        DOCKER_UNRESPONSIVE_CONTAINERD_UNKNOWN) echo "CRITICAL" ;;
        DOCKER_AND_CONTAINERD_UNRESPONSIVE) echo "EMERGENCY" ;;
        PERMISSION_DENIED) echo "WARNING" ;;
        DOCKER_NOT_INSTALLED)
            if [ "${MONITOR_DOCKER_REQUIRED:-false}" = "true" ]; then
                echo "CRITICAL"
            else
                echo "UNKNOWN"
            fi
            ;;
        *) echo "UNKNOWN" ;;
    esac
}

################################################################################
# Coletor principal do M2
################################################################################

collect_docker() {
    local docker_bin="${MONITOR_DOCKER_BIN:-docker}"
    local ctr_bin="${MONITOR_CTR_BIN:-ctr}"
    local socket="${MONITOR_DOCKER_SOCKET:-${DOCKER_SOCKET:-/var/run/docker.sock}}"

    DOCKER_INSTALLED=false
    DOCKER_SOCKET_EXISTS=false
    DOCKER_SOCKET_ACCESSIBLE=false
    DOCKER_SERVICE_STATE="unknown"
    CONTAINERD_SERVICE_STATE="unknown"
    DOCKER_VERSION_OK=false DOCKER_VERSION_LATENCY_MS=""
    DOCKER_INFO_OK=false DOCKER_INFO_LATENCY_MS=""
    DOCKER_PS_OK=false DOCKER_PS_LATENCY_MS="" DOCKER_PS_ERROR=""
    DOCKER_MAX_LATENCY_MS=""
    DOCKER_RUNNING_COUNT=""
    DOCKER_PERMISSION_ERROR=false
    DOCKERD_PID="" DOCKERD_STATE="" DOCKERD_THREADS="" DOCKERD_RSS_MB=""
    DOCKERD_CPU_PERCENT="" DOCKERD_ETIME=""
    CONTAINERD_PID="" CONTAINERD_STATE="" CONTAINERD_THREADS="" CONTAINERD_RSS_MB=""
    CONTAINERD_CPU_PERCENT="" CONTAINERD_ETIME=""
    CTR_AVAILABLE=false
    CONTAINERD_PROBE_OK="unknown"    # true|false|unknown (resultado consolidado)
    CONTAINERD_LATENCY_MS=""
    CONTAINERD_STATUS="UNKNOWN"      # HEALTHY|SLOW|UNRESPONSIVE|NOT_AVAILABLE|UNKNOWN
    DOCKER_STATUS="UNKNOWN"
    DOCKER_SEVERITY="UNKNOWN"
    DOCKER_STATUS_SINCE=""

    # ---- Instalação e socket ----
    if command -v "$docker_bin" &>/dev/null; then
        DOCKER_INSTALLED=true
    fi
    if [ -S "$socket" ]; then
        DOCKER_SOCKET_EXISTS=true
        [ -r "$socket" ] && [ -w "$socket" ] && DOCKER_SOCKET_ACCESSIBLE=true
    fi

    # ---- Serviços systemd (ausência de systemd não interrompe) ----
    DOCKER_SERVICE_STATE=$(monitor_service_state docker)
    CONTAINERD_SERVICE_STATE=$(monitor_service_state containerd)

    # ---- Processos via /proc ----
    monitor_collect_daemon_info dockerd DOCKERD || true
    monitor_collect_daemon_info containerd CONTAINERD || true

    # ---- Sondas Docker CLI (cada uma com timeout e latência) ----
    local docker_timeout="${MONITOR_DOCKER_TIMEOUT_SECONDS:-5}"
    local max_lat=0

    if [ "$DOCKER_INSTALLED" = true ]; then
        monitor_probe "$docker_timeout" "$docker_bin" version --format '{{.Server.Version}}'
        [ "$PROBE_RC" -eq 0 ] && DOCKER_VERSION_OK=true
        DOCKER_VERSION_LATENCY_MS="$PROBE_LATENCY_MS"
        [ "$PROBE_LATENCY_MS" -gt "$max_lat" ] && max_lat=$PROBE_LATENCY_MS
        [ "$PROBE_PERMISSION" = true ] && DOCKER_PERMISSION_ERROR=true

        monitor_probe "$docker_timeout" "$docker_bin" info --format '{{.ServerVersion}}'
        [ "$PROBE_RC" -eq 0 ] && DOCKER_INFO_OK=true
        DOCKER_INFO_LATENCY_MS="$PROBE_LATENCY_MS"
        [ "$PROBE_LATENCY_MS" -gt "$max_lat" ] && max_lat=$PROBE_LATENCY_MS
        [ "$PROBE_PERMISSION" = true ] && DOCKER_PERMISSION_ERROR=true

        monitor_probe "$docker_timeout" "$docker_bin" ps --format '{{.ID}}'
        if [ "$PROBE_RC" -eq 0 ]; then
            DOCKER_PS_OK=true
            DOCKER_RUNNING_COUNT=$(echo "$PROBE_OUT" | grep -c '.')
        else
            DOCKER_PS_ERROR="${PROBE_ERR:-timeout/erro (rc=$PROBE_RC)}"
            [ "$PROBE_PERMISSION" = true ] && DOCKER_PERMISSION_ERROR=true
        fi
        DOCKER_PS_LATENCY_MS="$PROBE_LATENCY_MS"
        [ "$PROBE_LATENCY_MS" -gt "$max_lat" ] && max_lat=$PROBE_LATENCY_MS

        DOCKER_MAX_LATENCY_MS="$max_lat"
    fi

    # ---- Sonda containerd via ctr (nunca tenta instalar) ----
    local ctr_timeout="${MONITOR_CONTAINERD_TIMEOUT_SECONDS:-5}"
    local ctr_slow="${MONITOR_CONTAINERD_SLOW_MS:-2000}"

    if command -v "$ctr_bin" &>/dev/null; then
        CTR_AVAILABLE=true
        monitor_probe "$ctr_timeout" "$ctr_bin" -n moby containers list
        CONTAINERD_LATENCY_MS="$PROBE_LATENCY_MS"
        if [ "$PROBE_RC" -eq 0 ]; then
            CONTAINERD_PROBE_OK=true
            if [ "$PROBE_LATENCY_MS" -gt "$ctr_slow" ]; then
                CONTAINERD_STATUS="SLOW"
            else
                CONTAINERD_STATUS="HEALTHY"
            fi
        elif [ "$PROBE_PERMISSION" = true ]; then
            # Sem permissão para o ctr: cai para sinais de serviço/processo
            CONTAINERD_PROBE_OK="unknown"
            CONTAINERD_STATUS="UNKNOWN"
        else
            CONTAINERD_PROBE_OK=false
            CONTAINERD_STATUS="UNRESPONSIVE"
        fi
    else
        CONTAINERD_STATUS="NOT_AVAILABLE"
    fi

    # Fallback: sem ctr utilizável, inferir containerd por serviço/processo
    if [ "$CONTAINERD_PROBE_OK" = "unknown" ]; then
        if [ "$CONTAINERD_SERVICE_STATE" = "active" ] || [ -n "$CONTAINERD_PID" ]; then
            CONTAINERD_PROBE_OK=true
        elif [ "$CONTAINERD_SERVICE_STATE" = "failed" ] || [ "$CONTAINERD_SERVICE_STATE" = "inactive" ]; then
            CONTAINERD_PROBE_OK=false
        fi
    fi

    # ---- Classificação ----
    local docker_slow="${MONITOR_DOCKER_SLOW_MS:-2000}"
    DOCKER_STATUS=$(monitor_docker_classify \
        "$DOCKER_INSTALLED" "$DOCKER_PERMISSION_ERROR" "$DOCKER_PS_OK" \
        "${DOCKER_MAX_LATENCY_MS:-0}" "$docker_slow" "$CONTAINERD_PROBE_OK")

    # Containerd lento também degrada o estado geral para SLOW
    if [ "$DOCKER_STATUS" = "HEALTHY" ] && [ "$CONTAINERD_STATUS" = "SLOW" ]; then
        DOCKER_STATUS="SLOW"
    fi

    DOCKER_SEVERITY=$(monitor_docker_severity_for "$DOCKER_STATUS")

    # ---- Duração do estado (para cooldown/recovery nos próximos marcos) ----
    local prev_status_entry prev_status prev_since now_epoch
    now_epoch=$(date +%s)
    prev_status_entry=$(monitor_state_get "docker_status_since")
    prev_status="${prev_status_entry%%:*}"
    prev_since="${prev_status_entry##*:}"
    if [ "$prev_status" = "$DOCKER_STATUS" ] && monitor_is_number "$prev_since"; then
        DOCKER_STATUS_SINCE="$prev_since"
    else
        DOCKER_STATUS_SINCE="$now_epoch"
    fi
    monitor_state_set "docker_status_since" "${DOCKER_STATUS}:${DOCKER_STATUS_SINCE}"
    monitor_state_set "docker_prev_latency_ms" "${DOCKER_PS_LATENCY_MS:-0}"

    return 0
}

################################################################################
# Export das funções
################################################################################

export -f monitor_now_ms monitor_probe monitor_probe_is_permission_error
export -f monitor_find_pid_by_comm monitor_proc_status monitor_collect_daemon_info
export -f monitor_service_state
export -f monitor_docker_classify monitor_docker_severity_for
export -f collect_docker

# Marca que monitor-docker.sh foi carregado
MONITOR_DOCKER_LOADED=1
export MONITOR_DOCKER_LOADED
