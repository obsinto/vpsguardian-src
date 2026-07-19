#!/bin/bash
################################################################################
# Script: monitor-emergency.sh
# Propósito: Modo de emergência e pacote de diagnóstico (M8)
# Uso: source /opt/vpsguardian/lib/monitor-emergency.sh
#      (requer monitor-common.sh; reutiliza M2/M6/M7 quando disponíveis)
#
# Princípio: COLETAR PRIMEIRO, diagnosticar depois. Nunca bloqueia esperando um
# daemon degradado. Todo subprocesso tem timeout; há um DEADLINE global; falhas
# parciais produzem um pacote utilizável. NENHUMA ação destrutiva.
#
# Prioridades: P0 (host, sem Docker) -> P1 (runtime, com timeout) -> P2 (logs/rede/
# histórico, só se sobrar tempo). Cada coleta verifica o tempo restante antes.
#
# Saída: diretório de incidente autocontido e SANITIZADO com manifest.json,
# summary.txt/json, errors.jsonl, checksums.sha256 e subdiretórios host/runtime/
# laravel/logs/network/history. Arquivo .tar.gz opcional (--archive).
#
# Referência: docs/MARCOS-MONITOR-PREVENTIVO.md (M8)
# Versão: 1.0.0
################################################################################

# Estado da execução (exposto ao JSON/KV/humano)
EM_DIR="" EM_ID="" EM_START=0 EM_DEADLINE=45 EM_LOCK=""
EM_OK=0 EM_FAIL=0 EM_TIMEOUT=0 EM_SKIPPED=0 EM_FILES=0
EM_STATUS="UNKNOWN" EM_SEVERITY="UNKNOWN" EM_PARTIAL=false
EM_ARCHIVE="" EM_ARCHIVE_SHA="" EM_MAIN_DIAG="" EM_NOTIFY_RESULT="none"
EM_GOROUTINE_DUMP=false EM_TMP="" EM_LOCK_HELD=false

# Orçamento agregado de tamanho do pacote (M8 — limite total real)
EM_MAX_TOTAL=52428800 EM_ESSENTIAL_RESERVE=65536
EM_TOTAL_BYTES_WRITTEN=0 EM_MEASURED_TOTAL=0
EM_TRUNC_TOTAL=0 EM_SKIP_TOTAL=0 EM_TOTAL_LIMIT_REACHED=false

# Piso seguro documentado para o limite total (essenciais sempre cabem)
EM_MIN_TOTAL_FLOOR=131072      # 128 KB
EM_MIN_USEFUL_BYTES=256        # abaixo disso, pular em vez de truncar (não-P0)

################################################################################
# Configuração
################################################################################

monitor_emergency_init_config() {
    : "${MONITOR_EMERGENCY_DEADLINE_SECONDS:=45}"
    : "${MONITOR_EMERGENCY_COMMAND_TIMEOUT:=5}"
    : "${MONITOR_EMERGENCY_FAST_TIMEOUT:=2}"
    : "${MONITOR_EMERGENCY_LOG_TIMEOUT:=8}"
    : "${MONITOR_EMERGENCY_TOP_PROCESSES:=30}"
    : "${MONITOR_EMERGENCY_MAX_TOTAL_BYTES:=52428800}"
    : "${MONITOR_EMERGENCY_MAX_FILE_BYTES:=5242880}"
    : "${MONITOR_EMERGENCY_MAX_PROCESS_LINES:=500}"
    : "${MONITOR_EMERGENCY_LOG_SINCE_MINUTES:=30}"
    : "${MONITOR_EMERGENCY_LOG_MAX_LINES:=2000}"
    : "${MONITOR_EMERGENCY_HISTORY_WINDOW:=1h}"
    : "${MONITOR_EMERGENCY_HISTORY_MAX_LINES:=1000}"
    : "${MONITOR_EMERGENCY_CPU_SAMPLE:=0}"
    : "${MONITOR_EMERGENCY_INCIDENTS_DIR:=$MONITOR_STATE_DIR/incidents}"
    : "${MONITOR_EMERGENCY_LOCK_FILE:=$MONITOR_STATE_DIR/emergency.lock}"

    # Validação do limite total agregado:
    #  - inválido/zero/negativo => padrão seguro (50 MB)
    #  - abaixo do piso documentado => elevado ao piso (essenciais sempre cabem)
    local raw="${MONITOR_EMERGENCY_MAX_TOTAL_BYTES:-52428800}"
    if [[ "$raw" =~ ^[0-9]+$ ]] && [ "$raw" -gt 0 ]; then
        EM_MAX_TOTAL="$raw"
    else
        EM_MAX_TOTAL=52428800
    fi
    if [ "$EM_MAX_TOTAL" -lt "$EM_MIN_TOTAL_FLOOR" ]; then
        log_info "Emergency: MONITOR_EMERGENCY_MAX_TOTAL_BYTES ($EM_MAX_TOTAL) abaixo do piso; elevado a $EM_MIN_TOTAL_FLOOR bytes"
        EM_MAX_TOTAL="$EM_MIN_TOTAL_FLOOR"
    fi
    # Reserva para essenciais (manifest/summary/errors/checksums): no máx. metade
    EM_ESSENTIAL_RESERVE=65536
    [ "$EM_ESSENTIAL_RESERVE" -gt "$((EM_MAX_TOTAL / 2))" ] && EM_ESSENTIAL_RESERVE="$((EM_MAX_TOTAL / 2))"
}

################################################################################
# Sanitização (obrigatória em todo conteúdo)
################################################################################

# Lê stdin, remove/substitui secrets por [REDACTED]. Determinística.
emergency_sanitize() {
    sed -E \
        -e 's#(https?://[^/[:space:]]+/api/webhooks/)[^[:space:]"]+#\1[REDACTED]#gI' \
        -e 's#(://[^:/@[:space:]]+):[^@[:space:]]+@#\1:[REDACTED]@#g' \
        -e 's#([Aa]uthorization:[[:space:]]*)[^[:space:]]+#\1[REDACTED]#g' \
        -e 's#([Bb]earer[[:space:]]+)[A-Za-z0-9._~+/=-]{6,}#\1[REDACTED]#g' \
        -e 's#(([Tt]oken|[Ss]ecret|[Pp]assword|[Pp]asswd|[Pp]wd|[Aa]pi[_-]?[Kk]ey|[Aa]pikey)[[:space:]]*[=:][[:space:]]*"?)[^[:space:]"'"'"',}]+#\1[REDACTED]#g' \
        -e 's#([A-Za-z0-9_]*(TOKEN|SECRET|PASSWORD|PASSWD|APIKEY|API_KEY)=)[^[:space:]]+#\1[REDACTED]#g' \
        -e 's#([Cc]ookie:[[:space:]]*)[^[:space:]]+#\1[REDACTED]#g' \
        -e 's#(WEBHOOK_URL=)[^[:space:]]+#\1[REDACTED]#g' \
        -e 's#.*PRIVATE KEY.*#[REDACTED PRIVATE KEY]#g'
}

################################################################################
# Deadline e utilitários de tempo
################################################################################

_em_now_ms() { date +%s%3N; }
_em_elapsed() { echo "$(( $(date +%s) - EM_START ))"; }
_em_time_left() { echo "$(( EM_DEADLINE - $(_em_elapsed) ))"; }

################################################################################
# Truncamento por tamanho de arquivo
################################################################################

_em_truncate() {
    local max="${MONITOR_EMERGENCY_MAX_FILE_BYTES:-5242880}"
    awk -v max="$max" '
        { buf[NR]=$0; total += length($0)+1
          if (total > max && !cut) { cut=NR } }
        END {
            if (!cut) { for(i=1;i<=NR;i++) print buf[i]; exit }
            head=int(NR*0.8); tail=NR-head
            for(i=1;i<=head;i++) print buf[i]
            printf "[TRUNCATED: original tinha %d linhas / %d bytes; limite %d bytes]\n", NR, total, max
            for(i=NR-int(tail*0.1);i<=NR;i++) if(i>head) print buf[i]
        }'
}

################################################################################
# Registro de erros e captura de comandos
################################################################################

_em_error() {
    local rel="$1" kind="$2" cmd="$3" rc="$4" errline="$5"
    local ef="$EM_DIR/errors.jsonl"
    printf '{"timestamp_epoch":%s,"file":"%s","kind":"%s","command":"%s","exit_code":%s,"stderr_sanitized":"%s"}\n' \
        "$(date +%s)" "$(monitor_json_escape "$rel")" "$kind" "$(monitor_json_escape "$cmd")" "${rc:-null}" \
        "$(monitor_json_escape "$errline")" >> "$ef" 2>/dev/null
}

_em_record_skip() {
    local rel="$1" cmd="$2"
    EM_SKIPPED=$((EM_SKIPPED+1))
    _em_error "$rel" SKIPPED_DEADLINE "$cmd" "" "sem tempo restante antes do deadline"
}

# Prioridade de um arquivo para o orçamento agregado.
# ESSENTIAL nunca é bloqueado; P0 nunca é descartado; P2 é descartado primeiro.
_em_priority() {
    case "$1" in
        manifest.json|summary.txt|summary.json|errors.jsonl|checksums.sha256) echo ESSENTIAL ;;
        host/identity.txt|host/load.txt|host/memory.txt|host/swap.txt|host/cpu.txt|host/processes-*) echo P0 ;;
        runtime/*|laravel/*|host/cgroups.txt|host/pressure.txt|host/vmstat.txt|host/disk.txt|host/inodes.txt|host/mounts.txt|host/limits.txt|logs/oom.txt) echo P1 ;;
        logs/*|network/*|history/*) echo P2 ;;
        *) echo P1 ;;
    esac
}

# Grava um conteúdo já SANITIZADO (arquivo src) respeitando o orçamento agregado.
# Ordem garantida pelo chamador: capturar -> sanitizar -> (aqui) orçar -> truncar -> gravar.
# Retorno: 0 gravado (inclusive truncado) | 1 pulado por limite total.
_em_finalize_write() {
    local rel="$1" src="$2" dest="$EM_DIR/$rel"
    mkdir -p "$(dirname "$dest")" 2>/dev/null
    local prio; prio=$(_em_priority "$rel")
    local size; size=$(wc -c < "$src" 2>/dev/null); [[ "$size" =~ ^[0-9]+$ ]] || size=0
    local marker=$'\n[TRUNCATED: limite total do pacote atingido]\n'

    if [ "$prio" = "ESSENTIAL" ]; then
        cp "$src" "$dest" 2>/dev/null; chmod 0640 "$dest" 2>/dev/null
        return 0
    fi

    # Orçamento medido em DISCO (robusto a subshells de pipe): soma real já gravada.
    local budget written remaining
    budget=$((EM_MAX_TOTAL - EM_ESSENTIAL_RESERVE)); [ "$budget" -lt 0 ] && budget=0
    written=$(find "$EM_DIR" -type f ! -name '*.lock' -printf '%s\n' 2>/dev/null | awk '{s+=$1} END{print s+0}')
    remaining=$((budget - written))

    if [ "$size" -le "$remaining" ]; then
        cp "$src" "$dest" 2>/dev/null; chmod 0640 "$dest" 2>/dev/null
        return 0
    fi

    # Não coube inteiro: decidir por prioridade
    if [ "$prio" = "P0" ]; then
        # P0 nunca é descartado: trunca ao espaço restante (piso pequeno; P0 é enxuto)
        local eff="$remaining"; [ "$eff" -lt 1024 ] && eff=1024
        { head -c "$eff" "$src"; printf '%s' "$marker"; } > "$dest" 2>/dev/null
        chmod 0640 "$dest" 2>/dev/null
        _em_error "$rel" TRUNCATED_TOTAL_LIMIT "(P0) tamanho $size > restante $remaining" "0" ""
        return 0
    fi

    if [ "$remaining" -ge "$EM_MIN_USEFUL_BYTES" ]; then
        local eff=$((remaining - ${#marker})); [ "$eff" -lt 0 ] && eff=0
        { head -c "$eff" "$src"; printf '%s' "$marker"; } > "$dest" 2>/dev/null
        chmod 0640 "$dest" 2>/dev/null
        _em_error "$rel" TRUNCATED_TOTAL_LIMIT "tamanho $size > restante $remaining" "0" ""
        return 0
    fi

    # Sem espaço útil: pular (preferir omitir P2/P1 a truncar P0)
    _em_error "$rel" SKIPPED_TOTAL_LIMIT "sem espaço no orçamento total" "" ""
    return 1
}

# Deriva os contadores de limite total a partir do disco e do errors.jsonl
# (robusto a incrementos perdidos em subshells de pipe).
_em_finalize_counters() {
    EM_MEASURED_TOTAL=$(find "$EM_DIR" -type f ! -name '*.lock' -printf '%s\n' 2>/dev/null | awk '{s+=$1} END{print s+0}')
    EM_FILES=$(find "$EM_DIR" -type f ! -name '*.lock' 2>/dev/null | wc -l | tr -d ' ')
    if [ -f "$EM_DIR/errors.jsonl" ]; then
        EM_TRUNC_TOTAL=$(grep -c 'TRUNCATED_TOTAL_LIMIT' "$EM_DIR/errors.jsonl" 2>/dev/null); EM_TRUNC_TOTAL=${EM_TRUNC_TOTAL:-0}
        EM_SKIP_TOTAL=$(grep -c 'SKIPPED_TOTAL_LIMIT' "$EM_DIR/errors.jsonl" 2>/dev/null); EM_SKIP_TOTAL=${EM_SKIP_TOTAL:-0}
        EM_SKIPPED=$(grep -c 'SKIPPED_DEADLINE' "$EM_DIR/errors.jsonl" 2>/dev/null); EM_SKIPPED=${EM_SKIPPED:-0}
    fi
    [ $((EM_TRUNC_TOTAL + EM_SKIP_TOTAL)) -gt 0 ] && EM_TOTAL_LIMIT_REACHED=true || EM_TOTAL_LIMIT_REACHED=false
}

# Captura a saída de um comando externo (com timeout, sanitização e orçamento).
# Uso: _em_capture <relpath> <timeout> -- <cmd...>
_em_capture() {
    local rel="$1" tmo="$2"; shift 2; [ "${1:-}" = "--" ] && shift

    if [ "$(_em_time_left)" -le 0 ]; then _em_record_skip "$rel" "$*"; return 0; fi

    local errf raw san rc start end dur
    errf=$(mktemp "${TMPDIR:-/tmp}/em-err.XXXXXX" 2>/dev/null) || errf=/dev/null
    raw=$(mktemp "${TMPDIR:-/tmp}/em-raw.XXXXXX" 2>/dev/null) || raw="$EM_TMP/raw.$$"
    san=$(mktemp "${TMPDIR:-/tmp}/em-san.XXXXXX" 2>/dev/null) || san="$EM_TMP/san.$$"

    start=$(_em_now_ms)
    run_with_timeout "$tmo" "$@" > "$raw" 2>"$errf"
    rc=$?
    end=$(_em_now_ms); dur=$((end-start))

    # capturar -> SANITIZAR -> truncar por arquivo -> (orçamento) gravar
    emergency_sanitize < "$raw" | _em_truncate > "$san" 2>/dev/null
    if _em_finalize_write "$rel" "$san"; then EM_FILES=$((EM_FILES+1)); fi

    local errline=""
    [ -s "$errf" ] && errline=$(head -n1 "$errf" | emergency_sanitize | cut -c1-200)
    rm -f "$raw" "$errf" "$san" 2>/dev/null

    if [ "$rc" -eq 124 ]; then
        EM_TIMEOUT=$((EM_TIMEOUT+1)); _em_error "$rel" TIMEOUT "$*" "$rc" "$errline"
    elif [ "$rc" -ne 0 ]; then
        EM_FAIL=$((EM_FAIL+1)); _em_error "$rel" FAILED "$*" "$rc" "$errline"
    else
        EM_OK=$((EM_OK+1))
    fi
    return 0
}

# Grava conteúdo direto (stdin) já sanitizado, respeitando o orçamento agregado.
_em_write() {
    local rel="$1"
    local san; san=$(mktemp "${TMPDIR:-/tmp}/em-san.XXXXXX" 2>/dev/null) || san="$EM_TMP/wsan.$$"
    emergency_sanitize | _em_truncate > "$san" 2>/dev/null
    if _em_finalize_write "$rel" "$san"; then EM_FILES=$((EM_FILES+1)); EM_OK=$((EM_OK+1)); fi
    rm -f "$san" 2>/dev/null
}

################################################################################
# Lock próprio de emergência
################################################################################

# Retorna: 0 adquirido; 4 já existe emergência ativa (EM_DIR aponta para ela)
monitor_emergency_lock() {
    local lock="$MONITOR_EMERGENCY_LOCK_FILE"
    mkdir -p "$(dirname "$lock")" 2>/dev/null
    if [ -f "$lock" ]; then
        local pid ts dir
        read -r pid ts dir < "$lock" 2>/dev/null
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && [ -d "$dir" ]; then
            EM_DIR="$dir"
            return 4
        fi
        log_debug "Emergency: lock órfão removido (pid $pid)"
        rm -f "$lock" 2>/dev/null
    fi
    printf '%s %s %s\n' "$$" "$(date +%s)" "$EM_DIR" > "$lock" 2>/dev/null || return 0
    EM_LOCK="$lock"; EM_LOCK_HELD=true
    return 0
}

monitor_emergency_unlock() {
    [ "$EM_LOCK_HELD" = true ] && rm -f "$EM_LOCK" 2>/dev/null
    EM_LOCK_HELD=false
}

################################################################################
# Validação de output-dir
################################################################################

# 0 se seguro; 1 caso contrário (vazio, "/", relativo, symlink inseguro)
monitor_emergency_validate_output_dir() {
    local d="$1"
    [ -n "$d" ] || return 1
    [ "$d" = "/" ] && return 1
    case "$d" in /*) ;; *) return 1 ;; esac
    # rejeita se qualquer componente existente for symlink
    local p="$d"
    while [ "$p" != "/" ] && [ -n "$p" ]; do
        [ -L "$p" ] && return 1
        p=$(dirname "$p")
    done
    return 0
}

################################################################################
# P0 — Host (independente do Docker)
################################################################################

monitor_emergency_collect_host() {
    local ft="$MONITOR_EMERGENCY_FAST_TIMEOUT" ct="$MONITOR_EMERGENCY_COMMAND_TIMEOUT"
    local proc="${MONITOR_PROC_DIR:-/proc}"

    { echo "hostname: $(hostname 2>/dev/null)"
      echo "kernel: $(uname -r 2>/dev/null)"
      echo "os: ${HOST_OS:-$(. /etc/os-release 2>/dev/null; echo "$PRETTY_NAME")}"
      echo "date_utc: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
      echo "vcpus: ${HOST_VCPUS:-$(nproc 2>/dev/null)}"
    } | _em_write host/identity.txt

    _em_capture host/uptime.txt "$ft" -- uptime
    _em_capture host/load.txt "$ft" -- cat "$proc/loadavg"
    _em_capture host/memory.txt "$ft" -- cat "$proc/meminfo"
    _em_capture host/cpu.txt "$ft" -- cat "$proc/stat"
    _em_capture host/swap.txt "$ft" -- swapon --show
    _em_capture host/disk.txt "$ct" -- df -h
    _em_capture host/inodes.txt "$ct" -- df -i
    _em_capture host/mounts.txt "$ft" -- cat "$proc/mounts"
    command -v vmstat &>/dev/null && _em_capture host/vmstat.txt "$ft" -- vmstat 1 2

    # PSI (some/full); ausência não é erro crítico
    if [ -d "$proc/pressure" ]; then
        { for r in cpu memory io; do
            echo "== $r =="; cat "$proc/pressure/$r" 2>/dev/null || echo "(indisponível)"
          done; } | _em_write host/pressure.txt
    else
        echo "PSI indisponível (/proc/pressure ausente)" | _em_write host/pressure.txt
    fi

    # cgroup do host + limites
    { echo "== cpu.stat =="; cat "${MONITOR_SYS_CGROUP_DIR:-/sys/fs/cgroup}/cpu.stat" 2>/dev/null
      echo "== cpu.max ==";  cat "${MONITOR_SYS_CGROUP_DIR:-/sys/fs/cgroup}/cpu.max" 2>/dev/null
      echo "== memory.current =="; cat "${MONITOR_SYS_CGROUP_DIR:-/sys/fs/cgroup}/memory.current" 2>/dev/null
    } | _em_write host/cgroups.txt
    { echo "swappiness: $(cat "$proc/sys/vm/swappiness" 2>/dev/null)"
      ulimit -a 2>/dev/null
    } | _em_write host/limits.txt

    _em_collect_processes
    return 0
}

# Um único snapshot de ps; deriva os arquivos por CPU/memória/estado
_em_collect_processes() {
    local snap="$EM_TMP/ps-snapshot.txt" n="${MONITOR_EMERGENCY_TOP_PROCESSES:-30}"
    if [ -n "${MONITOR_EMERGENCY_PS_SOURCE:-}" ]; then
        cp "$MONITOR_EMERGENCY_PS_SOURCE" "$snap" 2>/dev/null
    else
        run_with_timeout "$MONITOR_EMERGENCY_COMMAND_TIMEOUT" \
            ps -eo pid,ppid,user,stat,etimes,pcpu,pmem,rss,vsz,comm,args > "$snap" 2>/dev/null
    fi
    if [ ! -s "$snap" ]; then
        _em_error host/processes-cpu.txt FAILED "ps snapshot" "1" "snapshot vazio"
        EM_FAIL=$((EM_FAIL+1)); return 0
    fi

    # por CPU (col 6 = %cpu)
    { head -n1 "$snap"; tail -n +2 "$snap" | sort -k6 -rn | head -n "$n"; } \
        | emergency_sanitize | _em_write host/processes-cpu.txt
    # por memória (col 8 = rss)
    { head -n1 "$snap"; tail -n +2 "$snap" | sort -k8 -rn | head -n "$n"; } \
        | emergency_sanitize | _em_write host/processes-memory.txt
    # estados D (uninterruptible) e Z (zombie)
    { head -n1 "$snap"; awk 'NR>1 && ($4 ~ /^D/ || $4 ~ /^Z/)' "$snap"; } \
        | emergency_sanitize | _em_write host/processes-state.txt

    # contadores para o resumo
    EM_PROC_D=$(awk 'NR>1 && $4 ~ /^D/' "$snap" | wc -l | tr -d ' ')
    EM_PROC_Z=$(awk 'NR>1 && $4 ~ /^Z/' "$snap" | wc -l | tr -d ' ')
}

################################################################################
# P1 — Runtime (Docker/containerd com timeout; reutiliza classificação do M2)
################################################################################

monitor_emergency_collect_runtime() {
    local dt="${MONITOR_DOCKER_TIMEOUT_SECONDS:-$MONITOR_EMERGENCY_COMMAND_TIMEOUT}"
    local docker_bin="${MONITOR_DOCKER_BIN:-docker}" ctr_bin="${MONITOR_CTR_BIN:-ctr}"
    local sysctl="${MONITOR_SYSTEMCTL_BIN:-systemctl}"

    # Classificação já obtida pelo M2 (se a coleta estruturada rodou)
    { echo "docker_status_class: ${DOCKER_STATUS:-desconhecido}"
      echo "docker_ps_latency_ms: ${DOCKER_PS_LATENCY_MS:-n/d}"
      echo "docker_installed: ${DOCKER_INSTALLED:-n/d}"
    } | _em_write runtime/docker-status.txt
    { echo "containerd_status_class: ${CONTAINERD_STATUS:-desconhecido}"
      echo "containerd_responsive: ${CONTAINERD_PROBE_OK:-n/d}"
    } | _em_write runtime/containerd-status.txt

    if command -v "$docker_bin" &>/dev/null; then
        _em_capture runtime/docker-info.txt "$dt" -- "$docker_bin" info
        _em_capture runtime/docker-ps.txt "$dt" -- "$docker_bin" ps -a
        _em_capture runtime/docker-stats.txt "$dt" -- "$docker_bin" stats --no-stream
    else
        echo "docker não instalado" | _em_write runtime/docker-info.txt
    fi
    command -v "$ctr_bin" &>/dev/null && \
        _em_capture runtime/ctr-containers.txt "$dt" -- "$ctr_bin" -n moby containers list

    # Daemons via /proc (estado + threads) — sem depender do Docker responder
    { for name in dockerd containerd; do
        local pid; pid=$(monitor_find_pid_by_comm "$name" 2>/dev/null)
        if [ -n "$pid" ]; then
            echo "== $name (pid $pid) =="
            grep -E '^(State|Threads|VmRSS):' "${MONITOR_PROC_DIR:-/proc}/$pid/status" 2>/dev/null
        else
            echo "== $name: não encontrado =="
        fi
      done; } | _em_write runtime/daemon-processes.txt
    return 0
}

################################################################################
# Laravel (reutiliza detecção do M4 via ps snapshot)
################################################################################

monitor_emergency_collect_laravel() {
    if [ "${#LARAVEL_WORKERS_DATA[@]}" -gt 0 ]; then
        { printf '%s\n' "PID TIPO CONTAINER TIMEOUT SEV FINDINGS"
          local rec; local -a F
          for rec in "${LARAVEL_WORKERS_DATA[@]}"; do
              IFS='|' read -r -a F <<< "$rec"
              printf '%s %s %s %s %s %s\n' "${F[0]}" "${F[9]}" "${F[11]:-host}" "${F[16]:-none}" "${F[28]}" "${F[30]}"
          done; } | _em_write laravel/workers.txt
        { printf '['; local rec first=1; local -a F
          for rec in "${LARAVEL_WORKERS_DATA[@]}"; do
              IFS='|' read -r -a F <<< "$rec"
              [ "$first" = 1 ] && first=0 || printf ','
              printf '{"pid":%s,"type":"%s","container":"%s","timeout":%s,"severity":"%s"}' \
                  "$(monitor_json_value "${F[0]}")" "${F[9]}" "$(monitor_json_escape "${F[11]}")" \
                  "$(monitor_json_value "${F[16]:-null}")" "${F[28]}"
          done; printf ']'; } | _em_write laravel/workers.json
    else
        echo "Nenhum worker Laravel/Horizon detectado." | _em_write laravel/workers.txt
        echo "[]" | _em_write laravel/workers.json
    fi
    return 0
}

################################################################################
# P2 — Logs, rede e histórico (só se sobrar tempo)
################################################################################

monitor_emergency_collect_logs() {
    local lt="$MONITOR_EMERGENCY_LOG_TIMEOUT" since="${MONITOR_EMERGENCY_LOG_SINCE_MINUTES:-30}"
    local maxl="${MONITOR_EMERGENCY_LOG_MAX_LINES:-2000}"

    _em_log_or_source logs/kernel.txt "${MONITOR_EMERGENCY_DMESG_SOURCE:-}" "$lt" journalctl -k --no-pager -n "$maxl"
    _em_log_or_source logs/docker.txt "${MONITOR_EMERGENCY_JOURNAL_SOURCE:-}" "$lt" journalctl -u docker --no-pager -n "$maxl" --since "-${since}min"
    _em_log_or_source logs/containerd.txt "" "$lt" journalctl -u containerd --no-pager -n "$maxl" --since "-${since}min"
    _em_log_or_source logs/system.txt "" "$lt" journalctl --no-pager -n "$maxl" --since "-${since}min"

    # OOM/hung task: extrai do kernel/journal coletados (não recoleta)
    local oom_src="$EM_DIR/logs/kernel.txt"
    [ -s "$EM_DIR/logs/docker.txt" ] && oom_src="$oom_src $EM_DIR/logs/docker.txt"
    if [ -s "$EM_DIR/logs/kernel.txt" ] || [ -s "$EM_DIR/logs/system.txt" ]; then
        grep -hiE 'out of memory|killed process|oom-kill|memory cgroup out of memory|hung task|blocked for more than|I/O error|segfault|throttled|watchdog' \
            "$EM_DIR/logs/kernel.txt" "$EM_DIR/logs/system.txt" 2>/dev/null | head -n 200 \
            | _em_write logs/oom.txt
    else
        echo "(sem logs de kernel/sistema para varrer OOM)" | _em_write logs/oom.txt
    fi
    EM_OOM_FOUND=false
    grep -qiE 'out of memory|oom-kill|killed process' "$EM_DIR/logs/oom.txt" 2>/dev/null && EM_OOM_FOUND=true
    return 0
}

# Usa uma fixture (arquivo) se fornecida; senão executa o comando com timeout.
_em_log_or_source() {
    local rel="$1" src="$2" tmo="$3"; shift 3
    if [ -n "$src" ] && [ -f "$src" ]; then
        head -n "${MONITOR_EMERGENCY_LOG_MAX_LINES:-2000}" "$src" | _em_write "$rel"
    else
        _em_capture "$rel" "$tmo" -- "$@"
    fi
}

monitor_emergency_collect_network() {
    local ft="$MONITOR_EMERGENCY_FAST_TIMEOUT"
    command -v ip &>/dev/null && {
        _em_capture network/interfaces.txt "$ft" -- ip -o addr
        _em_capture network/routes.txt "$ft" -- ip route
    }
    command -v ss &>/dev/null && _em_capture network/sockets-summary.txt "$ft" -- ss -s
    _em_capture network/dns.txt "$ft" -- cat /etc/resolv.conf
    return 0
}

# Reutiliza o M7 (report + tails) sem modificar estado
monitor_emergency_collect_history() {
    if ! declare -F monitor_history_report >/dev/null 2>&1; then
        echo "Histórico (M7) indisponível." | _em_write history/recent-report.txt
        return 0
    fi
    monitor_history_init 2>/dev/null || true
    local now; now=$(date +%s)
    local secs; secs=$(monitor_history_parse_duration "${MONITOR_EMERGENCY_HISTORY_WINDOW:-1h}" 2>/dev/null || echo 3600)
    (
        REPORT_FROM="$((now - secs))" REPORT_TO="$now" REPORT_FORMAT=human
        REPORT_INCIDENT="" REPORT_DIAGNOSIS="" REPORT_CONTAINER=""
        monitor_history_report 2>/dev/null
    ) | _em_write history/recent-report.txt

    local maxl="${MONITOR_EMERGENCY_HISTORY_MAX_LINES:-1000}"
    local mf="$HIST_METRICS_DIR/metrics-$(date +%Y-%m-%d).jsonl"
    [ -f "$mf" ] && tail -n "$maxl" "$mf" | _em_write history/recent-metrics.jsonl
    local ef="$HIST_EVENTS_DIR/events-$(date +%Y-%m).jsonl"
    [ -f "$ef" ] && tail -n "$maxl" "$ef" | _em_write history/recent-events.jsonl
    return 0
}

################################################################################
# Goroutine dump do dockerd (somente com flag; apenas SIGUSR1)
################################################################################

monitor_emergency_goroutine_dump() {
    [ "$EM_GOROUTINE_DUMP" = true ] || return 0
    local pid; pid=$(monitor_find_pid_by_comm dockerd 2>/dev/null)
    if [ -z "$pid" ]; then
        echo "dockerd não encontrado; dump não realizado." | _em_write runtime/goroutine-dump.txt
        return 0
    fi
    # APENAS SIGUSR1 — nunca TERM/KILL. Override em testes via MONITOR_EMERGENCY_SIGNAL_CMD.
    local sigcmd="${MONITOR_EMERGENCY_SIGNAL_CMD:-kill -USR1}"
    $sigcmd "$pid" 2>/dev/null
    { echo "Sinal SIGUSR1 enviado ao dockerd (pid $pid) em $(date -u +%FT%TZ)."
      echo "O dump é escrito pelo dockerd no seu próprio log/arquivo; referência registrada."
    } | _em_write runtime/goroutine-dump.txt
    EM_ACTION_TAKEN=true
    return 0
}

################################################################################
# Resumo (summary.txt + summary.json)
################################################################################

monitor_emergency_summary() {
    EM_MAIN_DIAG="${DIAG_MAIN_KEY:-}"
    local main_title="" main_conf="" main_cause="" main_impact=""
    if [ -n "$EM_MAIN_DIAG" ] && [ "${DIAG_N:-0}" -gt 0 ]; then
        local i
        for ((i=0; i<DIAG_N; i++)); do
            if [ "${D_KEY[$i]}" = "$EM_MAIN_DIAG" ]; then
                main_title="${D_TITLE[$i]}"; main_conf="${D_CONF[$i]}"
                main_cause="${D_CAUSE[$i]}"; main_impact="${D_IMPACT[$i]}"
            fi
        done
    fi
    EM_SEVERITY="${OVERALL_SEVERITY:-UNKNOWN}"

    # PSI memory full avg10 (se disponível)
    local psi_mem=""
    [ -f "$EM_DIR/host/pressure.txt" ] && \
        psi_mem=$(awk '/memory/{m=1} m&&/full/{match($0,/avg10=[0-9.]+/); if(RSTART){print substr($0,RSTART+6,RLENGTH-6); exit}}' "$EM_DIR/host/pressure.txt" 2>/dev/null)

    local completed=$((EM_OK)) total=$((EM_OK+EM_FAIL+EM_TIMEOUT+EM_SKIPPED))

    { echo "VPS Guardian — Diagnóstico de emergência"
      echo ""
      echo "Incidente: $EM_ID"
      echo "Estado: $EM_SEVERITY"
      echo "Coleta: $([ "$EM_PARTIAL" = true ] && echo parcial || echo completa), $completed de $total verificações concluídas"
      echo "Duração: $(_em_elapsed)s (deadline ${EM_DEADLINE}s)"
      echo ""
      echo "Diagnóstico principal:"
      if [ -n "$main_title" ]; then
          echo "$main_title"; echo "Confiança: $main_conf"
      else
          echo "Nenhum diagnóstico composto com confiança suficiente."
      fi
      echo ""
      echo "Host:"
      echo "Load: ${LOAD_1:-n/d} / ${LOAD_5:-n/d} / ${LOAD_15:-n/d}"
      echo "RAM disponível: ${MEM_AVAILABLE_MB:-n/d} MB"
      echo "Swap: ${SWAP_USED_PERCENT:-n/d}%"
      echo "I/O wait: ${CPU_IOWAIT_PERCENT:-n/d}%"
      echo "CPU steal: ${CPU_STEAL_PERCENT:-n/d}%"
      [ -n "$psi_mem" ] && echo "PSI memória full avg10: ${psi_mem}%"
      echo "Processos em D: ${EM_PROC_D:-n/d} | zombies: ${EM_PROC_Z:-n/d}"
      echo "OOM detectado: $([ "${EM_OOM_FOUND:-false}" = true ] && echo sim || echo não)"
      echo ""
      echo "Runtime:"
      echo "Docker: ${DOCKER_STATUS:-desconhecido}"
      echo "containerd: ${CONTAINERD_STATUS:-desconhecido}"
      echo ""
      [ -n "$main_cause" ] && { echo "Provável gatilho:"; echo "$main_cause"; echo ""; }
      [ -n "$main_impact" ] && { echo "Impacto:"; echo "$main_impact"; echo ""; }
      echo "Erros de coleta: ${EM_FAIL} falhas, ${EM_TIMEOUT} timeouts, ${EM_SKIPPED} puladas"
      if [ "$EM_TOTAL_LIMIT_REACHED" = true ]; then
          echo ""
          echo "Pacote limitado por tamanho:"
          echo "  Limite total: $((EM_MAX_TOTAL / 1048576)) MB ($EM_MAX_TOTAL bytes)"
          echo "  Arquivos truncados: $EM_TRUNC_TOTAL"
          echo "  Arquivos ignorados: $EM_SKIP_TOTAL"
      fi
      echo ""
      echo "Recomendação (somente orientativa — NÃO executada):"
      echo "  1. Registre o estado atual (este pacote)."
      echo "  2. Identifique o maior consumidor de CPU/memória."
      echo "  3. Inspecione o worker/recurso ofensivo."
      echo "  4. Considere parada manual e controlada do recurso."
      echo "  5. Verifique throttling com o provedor (steal/cpu.stat)."
      echo "  6. Evite reiniciar Docker ou a VPS antes de controlar o causador."
    } | _em_write summary.txt

    { printf '{'
      printf '"schema_version":1'
      printf ',"incident_id":"%s"' "$EM_ID"
      printf ',"severity":"%s"' "$EM_SEVERITY"
      printf ',"duration_seconds":%s' "$(_em_elapsed)"
      printf ',"deadline_seconds":%s' "$EM_DEADLINE"
      printf ',"completed":%s,"total":%s' "$completed" "$total"
      printf ',"partial":%s' "$EM_PARTIAL"
      printf ',"main_diagnosis":{"key":%s,"title":%s,"confidence":%s}' \
          "$(_em_jv "$EM_MAIN_DIAG")" "$(_em_jv "$main_title")" "$(_em_jv "$main_conf")"
      printf ',"host":{"load_1":%s,"memory_available_mb":%s,"swap_used_percent":%s,"iowait_percent":%s,"steal_percent":%s,"procs_d":%s,"procs_z":%s,"oom_found":%s}' \
          "$(_em_jv "${LOAD_1:-}")" "$(_em_jv "${MEM_AVAILABLE_MB:-}")" "$(_em_jv "${SWAP_USED_PERCENT:-}")" \
          "$(_em_jv "${CPU_IOWAIT_PERCENT:-}")" "$(_em_jv "${CPU_STEAL_PERCENT:-}")" \
          "$(_em_jv "${EM_PROC_D:-}")" "$(_em_jv "${EM_PROC_Z:-}")" "${EM_OOM_FOUND:-false}"
      printf ',"runtime":{"docker":%s,"containerd":%s}' "$(_em_jv "${DOCKER_STATUS:-}")" "$(_em_jv "${CONTAINERD_STATUS:-}")"
      printf ',"commands_successful":%s,"commands_failed":%s,"commands_timed_out":%s,"commands_skipped":%s' \
          "$EM_OK" "$EM_FAIL" "$EM_TIMEOUT" "$EM_SKIPPED"
      printf '}'
    } | _em_write summary.json
    return 0
}

_em_jv() { if [ -z "$1" ]; then printf 'null'; else monitor_json_value "$1"; fi; }

################################################################################
# Manifesto e checksums
################################################################################

monitor_emergency_manifest() {
    local completed=$((EM_OK)) total=$((EM_OK+EM_FAIL+EM_TIMEOUT+EM_SKIPPED))
    # Total medido real: soma dos arquivos regulares do incidente (o archive fica
    # no diretório-pai, logo é naturalmente excluído; manifest.json ainda não existe)
    EM_MEASURED_TOTAL=$(find "$EM_DIR" -type f -printf '%s\n' 2>/dev/null | awk '{s+=$1} END{print s+0}')
    { printf '{'
      printf '"schema_version":1'
      printf ',"incident_id":"%s"' "$EM_ID"
      printf ',"created_at_epoch":%s' "$EM_START"
      printf ',"created_at_utc":"%s"' "$(date -u -d "@$EM_START" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%FT%TZ)"
      printf ',"hostname":%s' "$(_em_jv "$(hostname 2>/dev/null)")"
      printf ',"monitor_version":%s' "$(_em_jv "${MONITOR_VERSION:-}")"
      printf ',"command":"emergency"'
      printf ',"effective_user":%s' "$(_em_jv "$(id -un 2>/dev/null)")"
      printf ',"duration_seconds":%s' "$(_em_elapsed)"
      printf ',"deadline_seconds":%s' "$EM_DEADLINE"
      printf ',"completed":%s' "$([ "$EM_PARTIAL" = true ] && echo false || echo true)"
      printf ',"partial":%s' "$EM_PARTIAL"
      printf ',"files_created":%s' "$EM_FILES"
      printf ',"commands_successful":%s' "$EM_OK"
      printf ',"commands_failed":%s' "$EM_FAIL"
      printf ',"commands_timed_out":%s' "$EM_TIMEOUT"
      printf ',"commands_skipped":%s' "$EM_SKIPPED"
      printf ',"secrets_redacted":true'
      printf ',"archive_created":%s' "$([ -n "$EM_ARCHIVE" ] && echo true || echo false)"
      printf ',"archive_path":%s' "$(_em_jv "$EM_ARCHIVE")"
      printf ',"archive_sha256":%s' "$(_em_jv "$EM_ARCHIVE_SHA")"
      printf ',"size_limits":{"max_file_bytes":%s,"max_total_bytes":%s,"total_bytes_written":%s,"essential_reserve_bytes":%s,"total_limit_reached":%s,"files_truncated_by_total_limit":%s,"files_skipped_by_total_limit":%s}' \
          "${MONITOR_EMERGENCY_MAX_FILE_BYTES:-5242880}" "$EM_MAX_TOTAL" "$EM_MEASURED_TOTAL" \
          "$EM_ESSENTIAL_RESERVE" "$EM_TOTAL_LIMIT_REACHED" "$EM_TRUNC_TOTAL" "$EM_SKIP_TOTAL"
      printf '}'
    } | _em_write manifest.json
}

monitor_emergency_checksums() {
    local dest="$EM_DIR/checksums.sha256"
    if ! command -v sha256sum &>/dev/null; then
        echo "sha256sum indisponível" > "$dest" 2>/dev/null
        EM_CHECKSUMS=false; return 0
    fi
    ( cd "$EM_DIR" 2>/dev/null || exit 0
      find . -type f ! -name checksums.sha256 ! -name '*.lock' -print 2>/dev/null \
        | LC_ALL=C sort | sed 's#^\./##' | while read -r f; do sha256sum "$f"; done
    ) > "$dest" 2>/dev/null
    chmod 0640 "$dest" 2>/dev/null
    EM_CHECKSUMS=true
    return 0
}

################################################################################
# Arquivo compactado opcional
################################################################################

monitor_emergency_archive() {
    [ "${EM_WANT_ARCHIVE:-false}" = true ] || return 0
    if ! command -v tar &>/dev/null || ! command -v gzip &>/dev/null; then
        log_info "Emergency: tar/gzip ausente; diretório mantido sem arquivo compactado"
        return 0
    fi
    local parent base tarball
    parent=$(dirname "$EM_DIR"); base=$(basename "$EM_DIR")
    tarball="$parent/incident-$base.tar.gz"

    # Não criar o archive se o espaço livre for insuficiente (evita cópias grandes)
    local dir_kb free_kb
    dir_kb=$(du -sk "$EM_DIR" 2>/dev/null | awk '{print $1}')
    free_kb=$(df -Pk "$parent" 2>/dev/null | awk 'NR==2{print $4}')
    if [[ "$dir_kb" =~ ^[0-9]+$ ]] && [[ "$free_kb" =~ ^[0-9]+$ ]] && [ "$free_kb" -lt "$dir_kb" ]; then
        log_info "Emergency: espaço livre insuficiente para o archive; diretório preservado"
        return 0
    fi

    if run_with_timeout 30 tar -czf "$tarball" -C "$parent" "$base" 2>/dev/null; then
        chmod 0640 "$tarball" 2>/dev/null
        EM_ARCHIVE="$tarball"
        command -v sha256sum &>/dev/null && EM_ARCHIVE_SHA=$(sha256sum "$tarball" 2>/dev/null | cut -d' ' -f1)
    else
        rm -f "$tarball" 2>/dev/null
        log_info "Emergency: falha ao criar arquivo compactado; diretório preservado"
    fi
    return 0
}

################################################################################
# Orquestração da coleta (P0 -> P1 -> P2), com deadline entre etapas
################################################################################

# Prepara o diretório do incidente. Retorna 2 se não conseguir criar.
monitor_emergency_prepare() {
    monitor_emergency_init_config
    EM_START=$(date +%s)
    EM_ID="$(date +%Y-%m-%d_%H-%M-%S)_$(hostname 2>/dev/null || echo host)"
    local base="${EM_OUTPUT_DIR:-$MONITOR_EMERGENCY_INCIDENTS_DIR}"
    EM_DIR="$base/$EM_ID"
    if ! mkdir -p "$EM_DIR" 2>/dev/null; then return 2; fi
    chmod 0750 "$base" "$EM_DIR" 2>/dev/null || true
    : > "$EM_DIR/errors.jsonl" 2>/dev/null
    EM_TMP=$(mktemp -d "${TMPDIR:-/tmp}/em-tmp.XXXXXX" 2>/dev/null) || EM_TMP="$EM_DIR/.tmp"
    mkdir -p "$EM_TMP" 2>/dev/null
    return 0
}

# Executa uma etapa se ainda houver tempo; senão registra SKIPPED.
_em_stage() {
    local label="$1" fn="$2"
    if [ "$(_em_time_left)" -le 0 ]; then
        EM_PARTIAL=true; _em_record_skip "$label" "$fn"; return 0
    fi
    "$fn"
}

monitor_emergency_collect_all() {
    # P0 — indispensável (host, sem Docker)
    _em_stage "P0/host" monitor_emergency_collect_host
    # P1 — runtime
    _em_stage "P1/runtime" monitor_emergency_collect_runtime
    _em_stage "P1/laravel" monitor_emergency_collect_laravel
    monitor_emergency_goroutine_dump
    # P2 — logs/rede/histórico (só se sobrar tempo)
    _em_stage "P2/logs" monitor_emergency_collect_logs
    _em_stage "P2/network" monitor_emergency_collect_network
    _em_stage "P2/history" monitor_emergency_collect_history

    # Deriva contadores de limite/arquivos do disco (robusto a subshells)
    _em_finalize_counters

    [ "$EM_SKIPPED" -gt 0 ] && EM_PARTIAL=true
    [ "$EM_FAIL" -gt 0 ] || [ "$EM_TIMEOUT" -gt 0 ] && EM_PARTIAL=true
    [ "$EM_TOTAL_LIMIT_REACHED" = true ] && EM_PARTIAL=true

    # Ordem: resumo -> archive (manifesto registra sha) -> manifesto -> checksums (último,
    # cobre o manifesto e é o único a respeitar sua própria reserva)
    monitor_emergency_summary
    monitor_emergency_archive
    monitor_emergency_manifest
    monitor_emergency_checksums

    # limpeza do tmp interno
    [ -n "$EM_TMP" ] && [ "$EM_TMP" != "$EM_DIR/.tmp" ] && rm -rf "$EM_TMP" 2>/dev/null
    rm -rf "$EM_DIR/.tmp" 2>/dev/null

    # status final
    if [ "$EM_OK" -eq 0 ]; then EM_STATUS="MINIMAL"
    elif [ "$EM_PARTIAL" = true ]; then EM_STATUS="PARTIAL"
    else EM_STATUS="COMPLETE"; fi
    return 0
}

################################################################################
# Export
################################################################################

export -f emergency_sanitize monitor_emergency_init_config
export -f monitor_emergency_lock monitor_emergency_unlock
export -f monitor_emergency_validate_output_dir
export -f monitor_emergency_collect_host monitor_emergency_collect_runtime
export -f monitor_emergency_collect_laravel monitor_emergency_collect_logs
export -f monitor_emergency_collect_network monitor_emergency_collect_history
export -f monitor_emergency_goroutine_dump monitor_emergency_summary
export -f monitor_emergency_manifest monitor_emergency_checksums
export -f monitor_emergency_archive monitor_emergency_prepare monitor_emergency_collect_all

MONITOR_EMERGENCY_LOADED=1
export MONITOR_EMERGENCY_LOADED
