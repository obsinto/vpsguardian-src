#!/bin/bash
################################################################################
# Script: monitor-history.sh
# Propósito: Persistência histórica, baseline, eventos e relatórios (M7)
# Uso: source /opt/vpsguardian/lib/monitor-history.sh
#      (requer monitor-common.sh carregado antes)
#
# Camada SEPARADA do estado operacional do M5/M6 (incidents.state / diagnoses.state).
# Não substitui nem mistura esses arquivos. Transforma snapshots em séries
# temporais (JSON Lines), sem tornar o monitor pesado e sem novas coletas.
#
# Estrutura (sob MONITOR_HISTORY_DIR):
#   metrics/metrics-YYYY-MM-DD.jsonl      métricas do host (1 linha/execução)
#   containers/containers-YYYY-MM-DD.jsonl  detalhes de containers relevantes
#   workers/workers-YYYY-MM-DD.jsonl      detalhes de workers relevantes
#   events/events-YYYY-MM.jsonl           eventos (só em transições reais)
#   events/diagnostics-YYYY-MM.jsonl      diagnósticos detectados/resolvidos
#   indexes/latest-baseline.kv            baseline leve (deltas/tendências)
#   reports/                              relatórios exportados
#
# Regras: escrita append com lock; uma linha completa; permissões restritas;
# tolera FS somente leitura / disco cheio; a falha de histórico NUNCA derruba o
# monitor (coleta/alertas/diagnósticos/recovery seguem). Nenhum segredo persiste.
#
# Referência: docs/MARCOS-MONITOR-PREVENTIVO.md (M7)
# Versão: 1.0.0
################################################################################

# Resultado da última persistência (exposto ao JSON/KV/humano)
HIST_ENABLED=true HIST_METRICS_PERSISTED=false HIST_EVENTS_PERSISTED=0
HIST_BASELINE_UPDATED=false HIST_LAST_METRICS_AT="" HIST_WRITE_ERRORS=0
HIST_DRY_RUN=false HIST_LAST_ERROR="" HIST_MAINTENANCE_RAN=false
HIST_WOULD_METRICS=false

# Baseline em memória (carregado/gravado como KV)
declare -A BL

################################################################################
# Inicialização e validação de caminhos
################################################################################

monitor_history_init() {
    : "${MONITOR_HISTORY_ENABLED:=true}"
    : "${MONITOR_HISTORY_DIR:=$MONITOR_STATE_DIR/history}"
    : "${MONITOR_HISTORY_METRICS_INTERVAL:=60}"
    : "${MONITOR_HISTORY_CONTAINER_INTERVAL:=300}"
    : "${MONITOR_HISTORY_METRICS_RETENTION_DAYS:=30}"
    : "${MONITOR_HISTORY_EVENTS_RETENTION_DAYS:=180}"
    : "${MONITOR_HISTORY_REPORTS_RETENTION_DAYS:=90}"
    : "${MONITOR_HISTORY_COMPRESS_AFTER_DAYS:=2}"
    : "${MONITOR_HISTORY_MAINTENANCE_INTERVAL:=86400}"
    : "${MONITOR_HISTORY_SWAP_TREND_MIN_BYTES:=67108864}"
    : "${MONITOR_HISTORY_CONTAINER_TREND_MIN_BYTES:=67108864}"
    : "${MONITOR_HISTORY_TOP_CONTAINERS:=${MONITOR_TOP_CONTAINERS:-5}}"

    HIST_METRICS_DIR="$MONITOR_HISTORY_DIR/metrics"
    HIST_CONTAINERS_DIR="$MONITOR_HISTORY_DIR/containers"
    HIST_WORKERS_DIR="$MONITOR_HISTORY_DIR/workers"
    HIST_EVENTS_DIR="$MONITOR_HISTORY_DIR/events"
    HIST_INDEX_DIR="$MONITOR_HISTORY_DIR/indexes"
    HIST_REPORTS_DIR="$MONITOR_HISTORY_DIR/reports"
    HIST_BASELINE_FILE="$HIST_INDEX_DIR/latest-baseline.kv"
}

# Rejeita caminhos perigosos (vazio, "/", relativo). Retorna 0 se seguro.
monitor_history_path_safe() {
    local p="$1"
    [ -n "$p" ] || return 1
    [ "$p" = "/" ] && return 1
    case "$p" in /*) return 0 ;; *) return 1 ;; esac
}

################################################################################
# Escrita segura (append com lock, uma linha, permissões restritas)
################################################################################

_hist_fail() {
    HIST_WRITE_ERRORS=$((HIST_WRITE_ERRORS + 1))
    HIST_LAST_ERROR="$1"
    log_debug "Histórico: falha de escrita: $1"
}

_hist_append() {
    local file="$1" line="$2"
    local dir; dir=$(dirname "$file")
    if ! mkdir -p "$dir" 2>/dev/null; then _hist_fail "mkdir $dir"; return 1; fi
    chmod 0750 "$dir" 2>/dev/null || true

    if command -v flock &>/dev/null; then
        (
            flock -w 2 9 || exit 1
            printf '%s\n' "$line" >> "$file"
        ) 9>"$file.lock" 2>/dev/null || { _hist_fail "append $file"; return 1; }
    else
        printf '%s\n' "$line" >> "$file" 2>/dev/null || { _hist_fail "append $file"; return 1; }
    fi
    chmod 0640 "$file" 2>/dev/null || true
    return 0
}

################################################################################
# Baseline (KV atômico)
################################################################################

_bl() { printf '%s' "${BL[$1]:-}"; }
_bl_num() { local v="${BL[$1]:-}"; [[ "$v" =~ ^-?[0-9]+$ ]] && printf '%s' "$v" || printf '%s' "${2:-0}"; }

monitor_history_load_baseline() {
    BL=()
    [ -f "$HIST_BASELINE_FILE" ] || return 0
    local key val
    while IFS='=' read -r key val; do
        [ -n "$key" ] || continue
        case "$key" in \#*) continue ;; esac
        BL["$key"]="$val"
    done < "$HIST_BASELINE_FILE" 2>/dev/null
    # Baseline corrompido (sem schema): descarta e recomeça (recuperação)
    if [ -z "${BL[schema_version]:-}" ]; then
        log_debug "Histórico: baseline sem schema; recomeçando"
        BL=()
    fi
}

monitor_history_save_baseline() {
    BL[schema_version]=1
    local tmp="$HIST_BASELINE_FILE.tmp.$$" key
    if ! mkdir -p "$HIST_INDEX_DIR" 2>/dev/null; then _hist_fail "mkdir index"; return 1; fi
    if ! : > "$tmp" 2>/dev/null; then _hist_fail "baseline tmp"; return 1; fi
    for key in "${!BL[@]}"; do
        printf '%s=%s\n' "$key" "${BL[$key]}" >> "$tmp"
    done
    if mv -f "$tmp" "$HIST_BASELINE_FILE" 2>/dev/null; then
        chmod 0640 "$HIST_BASELINE_FILE" 2>/dev/null || true
        return 0
    fi
    rm -f "$tmp" 2>/dev/null
    _hist_fail "baseline mv"
    return 1
}

################################################################################
# Tendências (funções puras, testáveis)
################################################################################

# monitor_history_trend <delta_bytes> <min_bytes> -> RISING|STABLE|FALLING
monitor_history_trend() {
    local delta="$1" min="$2"
    [[ "$delta" =~ ^-?[0-9]+$ ]] || { echo "UNKNOWN"; return; }
    [[ "$min" =~ ^[0-9]+$ ]] || min=0
    if [ "$delta" -ge "$min" ] && [ "$delta" -gt 0 ]; then echo "RISING"
    elif [ "$delta" -le "-$min" ] && [ "$delta" -lt 0 ]; then echo "FALLING"
    else echo "STABLE"; fi
}

# monitor_history_rate <delta_bytes> <seconds> -> bytes/minuto (0 se clock inválido)
monitor_history_rate() {
    local delta="$1" secs="$2"
    [[ "$delta" =~ ^-?[0-9]+$ ]] || { echo "0"; return; }
    # Clock retrocedendo ou intervalo nulo => taxa 0 (evita valores absurdos)
    [[ "$secs" =~ ^[0-9]+$ ]] && [ "$secs" -gt 0 ] || { echo "0"; return; }
    awk -v d="$delta" -v s="$secs" 'BEGIN{printf "%d", d*60/s}'
}

################################################################################
# Helpers JSON (valor ou null; MB->bytes)
################################################################################

_hv() { if [ -z "$1" ] || [ "$1" = "n/d" ]; then printf 'null'; else monitor_json_value "$1"; fi; }
_hv_bytes() {   # <mb> -> bytes ou null
    local mb="$1"
    [[ "$mb" =~ ^-?[0-9]+$ ]] && printf '%s' "$((mb * 1048576))" || printf 'null'
}
_hv_str() { if [ -z "$1" ]; then printf 'null'; else printf '"%s"' "$(monitor_json_escape "$1")"; fi; }

################################################################################
# Construção da linha de métricas do host (flat JSON)
################################################################################

monitor_history_build_metrics_line() {
    local now="$1" swap_delta="$2"
    local ts_utc; ts_utc=$(date -u -d "@$now" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)

    printf '{'
    printf '"schema_version":1'
    printf ',"timestamp_epoch":%s' "$now"
    printf ',"timestamp_utc":%s' "$(_hv_str "$ts_utc")"
    printf ',"hostname":%s' "$(_hv_str "${HOST_HOSTNAME:-}")"
    printf ',"monitor_version":%s' "$(_hv_str "${MONITOR_VERSION:-}")"
    printf ',"uptime_seconds":%s' "$(_hv "${HOST_UPTIME_SECONDS:-}")"
    printf ',"vcpu_count":%s' "$(_hv "${HOST_VCPUS:-}")"
    printf ',"load_1":%s' "$(_hv "${LOAD_1:-}")"
    printf ',"load_5":%s' "$(_hv "${LOAD_5:-}")"
    printf ',"load_15":%s' "$(_hv "${LOAD_15:-}")"
    printf ',"load_ratio":%s' "$(_hv "${LOAD_RATIO:-}")"
    printf ',"cpu_usage_percent":%s' "$(_hv "${CPU_USAGE_PERCENT:-}")"
    printf ',"cpu_user_percent":%s' "$(_hv "${CPU_USER_PERCENT:-}")"
    printf ',"cpu_system_percent":%s' "$(_hv "${CPU_SYSTEM_PERCENT:-}")"
    printf ',"cpu_idle_percent":%s' "$(_hv "${CPU_IDLE_PERCENT:-}")"
    printf ',"cpu_iowait_percent":%s' "$(_hv "${CPU_IOWAIT_PERCENT:-}")"
    printf ',"cpu_steal_percent":%s' "$(_hv "${CPU_STEAL_PERCENT:-}")"
    printf ',"cgroup_cpu_quota":%s' "$(_hv "${CGROUP_QUOTA_PERCENT:-}")"
    printf ',"cgroup_nr_periods":%s' "$(_hv "${CGROUP_NR_PERIODS:-}")"
    printf ',"cgroup_nr_throttled":%s' "$(_hv "${CGROUP_NR_THROTTLED:-}")"
    printf ',"cgroup_throttled_usec":%s' "$(_hv "${CGROUP_THROTTLED_USEC:-}")"
    printf ',"cgroup_throttled_delta":%s' "$(_hv "${CGROUP_THROTTLED_DELTA:-}")"
    printf ',"memory_total_bytes":%s' "$(_hv_bytes "${MEM_TOTAL_MB:-}")"
    printf ',"memory_used_bytes":%s' "$(_hv_bytes "${MEM_USED_MB:-}")"
    printf ',"memory_available_bytes":%s' "$(_hv_bytes "${MEM_AVAILABLE_MB:-}")"
    printf ',"memory_used_percent":%s' "$(_hv "${MEM_USED_PERCENT:-}")"
    printf ',"swap_total_bytes":%s' "$(_hv_bytes "${SWAP_TOTAL_MB:-}")"
    printf ',"swap_used_bytes":%s' "$(_hv_bytes "${SWAP_USED_MB:-}")"
    printf ',"swap_used_percent":%s' "$(_hv "${SWAP_USED_PERCENT:-}")"
    printf ',"swap_activity_pages_delta":%s' "$(_hv "${SWAP_ACTIVITY_PAGES_DELTA:-}")"
    printf ',"swap_active_pressure":%s' "$(_hv_str "${SWAP_ACTIVE_PRESSURE:-false}")"
    printf ',"swap_delta_bytes":%s' "$(_hv "$swap_delta")"
    printf ',"disk_root_total_bytes":%s' "$(_hv_bytes "${DISK_TOTAL_MB:-}")"
    printf ',"disk_root_available_bytes":%s' "$(_hv_bytes "${DISK_AVAILABLE_MB:-}")"
    printf ',"disk_root_used_percent":%s' "$(_hv "${DISK_USED_PERCENT:-}")"
    printf ',"inodes_root_used_percent":%s' "$(_hv "${INODE_USED_PERCENT:-}")"
    printf ',"docker_status":%s' "$(_hv_str "${DOCKER_STATUS:-}")"
    printf ',"docker_latency_ms":%s' "$(_hv "${DOCKER_PS_LATENCY_MS:-}")"
    printf ',"containerd_status":%s' "$(_hv_str "${CONTAINERD_STATUS:-}")"
    printf ',"containers_total":%s' "$(_hv "${CONTAINERS_TOTAL:-}")"
    printf ',"containers_running":%s' "$(_hv "${CONTAINERS_RUNNING:-}")"
    printf ',"containers_stopped":%s' "$(_hv "${CONTAINERS_STOPPED:-}")"
    printf ',"containers_restarting":%s' "$(_hv "${CONTAINERS_RESTARTING:-}")"
    printf ',"containers_unhealthy":%s' "$(_hv "${CONTAINERS_UNHEALTHY:-}")"
    printf ',"containers_without_memory_limit":%s' "$(_hv "${CONTAINERS_NO_MEM_LIMIT:-}")"
    printf ',"containers_without_cpu_limit":%s' "$(_hv "${CONTAINERS_NO_CPU_LIMIT:-}")"
    printf ',"laravel_workers_total":%s' "$(_hv "${LARAVEL_TOTAL:-}")"
    printf ',"laravel_workers_warning":%s' "$(_hv "${LARAVEL_WARNING:-}")"
    printf ',"laravel_workers_critical":%s' "$(_hv "${LARAVEL_CRITICAL:-}")"
    printf ',"laravel_workers_emergency":%s' "$(_hv "${LARAVEL_EMERGENCY:-}")"
    printf ',"alerts_overall_severity":%s' "$(_hv_str "${OVERALL_SEVERITY:-}")"
    printf ',"alerts_active_total":%s' "$(_hv "${ALERTS_OPENED:-0}")"
    printf ',"diagnostics_total":%s' "$(_hv "${DIAG_N:-0}")"
    printf ',"diagnostics_main_key":%s' "$(_hv_str "${DIAG_MAIN_KEY:-}")"
    printf ',"diagnostics_highest_confidence":%s' "$(_hv_str "${DIAG_HIGHEST_CONF:-}")"
    printf ',"diagnostics_highest_severity":%s' "$(_hv_str "${DIAG_HIGHEST_SEV:-}")"
    printf '}'
}

################################################################################
# Eventos — só em transições reais (comparação com baseline)
################################################################################

HIST_EVENT_LINES=()

_hist_emit_event() {
    local now="$1" etype="$2" severity="$3" rtype="$4" rid="$5" key="$6" summary="$7"
    local line
    line=$(printf '{"schema_version":1,"timestamp_epoch":%s,"event_type":"%s","severity":%s,"resource_type":%s,"resource_id":%s,"key":%s,"summary":%s,"metadata":{}}' \
        "$now" "$etype" "$(_hv_str "$severity")" "$(_hv_str "$rtype")" "$(_hv_str "$rid")" \
        "$(_hv_str "$key")" "$(_hv_str "$summary")")
    HIST_EVENT_LINES+=("$etype|$line")
}

# Constrói o mapa de condições atuais "chave:severidade" (chaves pontilhadas)
_hist_current_conditions() {
    local out="" k sev
    _hist_cond() {
        local key="$1" s="$2"
        case "$s" in WARNING|CRITICAL|EMERGENCY) out+="${key}:${s};" ;; esac
    }
    _hist_cond "host.load" "${LOAD_SEVERITY:-}"
    _hist_cond "host.memory.available" "${MEM_SEVERITY:-}"
    _hist_cond "host.swap.usage" "${SWAP_SEVERITY:-}"
    _hist_cond "host.cpu" "${CPU_SEVERITY:-}"
    _hist_cond "host.cpu_steal" "${CPU_STEAL_SEVERITY:-}"
    _hist_cond "host.iowait" "${CPU_IOWAIT_SEVERITY:-}"
    _hist_cond "host.cgroup" "${CGROUP_SEVERITY:-}"
    _hist_cond "host.disk" "${DISK_SEVERITY:-}"
    _hist_cond "host.inodes" "${INODE_SEVERITY:-}"
    unset -f _hist_cond
    printf '%s' "$out"
}

# Lê severidade de uma chave num mapa "k:sev;k2:sev2"
_hist_map_get() {
    local map="$1" key="$2"
    printf '%s' "$map" | tr ';' '\n' | awk -F: -v k="$key" '$1==k{print $2; exit}'
}

monitor_history_detect_events() {
    local now="$1"
    HIST_EVENT_LINES=()

    # ---- Alertas de host (aberto/escalonado/recuperado) ----
    local cur prev k sev psev
    cur=$(_hist_current_conditions)
    prev="$(_bl alert_conditions)"
    local pair
    for pair in ${cur//;/ }; do
        k="${pair%%:*}"; sev="${pair##*:}"
        psev=$(_hist_map_get "$prev" "$k")
        if [ -z "$psev" ]; then
            _hist_emit_event "$now" ALERT_OPENED "$sev" host "${HOST_HOSTNAME:-}" "$k" "Condição $k em $sev"
        elif [ "$(monitor_severity_rank "$sev")" -gt "$(monitor_severity_rank "$psev")" ]; then
            _hist_emit_event "$now" ALERT_ESCALATED "$sev" host "${HOST_HOSTNAME:-}" "$k" "Escalou de $psev para $sev"
        fi
    done
    for pair in ${prev//;/ }; do
        k="${pair%%:*}"
        [ -z "$(_hist_map_get "$cur" "$k")" ] && \
            _hist_emit_event "$now" ALERT_RECOVERED INFO host "${HOST_HOSTNAME:-}" "$k" "Condição $k normalizada"
    done
    BL[alert_conditions]="$cur"

    # ---- Docker mudou de estado ----
    local dcur="${DOCKER_STATUS:-}" dprev; dprev="$(_bl docker_status)"
    if [ -n "$dcur" ] && [ "$dcur" != "$dprev" ]; then
        _hist_emit_event "$now" DOCKER_STATE_CHANGED "${DOCKER_SEVERITY:-INFO}" docker "${HOST_HOSTNAME:-}" "docker.status" "Docker: ${dprev:-desconhecido} -> $dcur"
    fi
    BL[docker_status]="$dcur"

    # ---- Diagnósticos (detectado/escalonado/resolvido) — só alertáveis (>=MEDIUM) ----
    local dgcur="" i
    for ((i=0; i<${DIAG_N:-0}; i++)); do
        [ "$(monitor_correlation_conf_rank "${D_CONF[$i]}")" -ge 2 ] || continue
        dgcur+="${D_KEY[$i]}:${D_CONF[$i]};"
    done
    local dgprev; dgprev="$(_bl diag_conditions)"
    for pair in ${dgcur//;/ }; do
        k="${pair%%:*}"; sev="${pair##*:}"
        psev=$(_hist_map_get "$dgprev" "$k")
        if [ -z "$psev" ]; then
            _hist_emit_event "$now" DIAGNOSIS_DETECTED "$sev" diagnosis "$k" "$k" "Diagnóstico detectado ($sev)"
        elif [ "$(monitor_correlation_conf_rank "$sev")" -gt "$(monitor_correlation_conf_rank "$psev")" ]; then
            _hist_emit_event "$now" DIAGNOSIS_ESCALATED "$sev" diagnosis "$k" "$k" "Confiança $psev -> $sev"
        fi
    done
    for pair in ${dgprev//;/ }; do
        k="${pair%%:*}"
        [ -z "$(_hist_map_get "$dgcur" "$k")" ] && \
            _hist_emit_event "$now" DIAGNOSIS_RESOLVED INFO diagnosis "$k" "$k" "Diagnóstico resolvido"
    done
    BL[diag_conditions]="$dgcur"

    # ---- Risco de workers Laravel mudou ----
    local wcur="${LARAVEL_MAX_SEVERITY:-INFO}" wprev; wprev="$(_bl worker_risk)"
    if [ -n "$wprev" ] && [ "$wcur" != "$wprev" ]; then
        _hist_emit_event "$now" WORKER_RISK_CHANGED "$wcur" laravel_worker host "laravel.workers" "Risco de workers: $wprev -> $wcur"
    fi
    BL[worker_risk]="$wcur"
}

################################################################################
# Detalhes de containers/workers relevantes (não grava tudo em toda coleta)
################################################################################

# Um container é "relevante"? (rodando com problema, unhealthy, restarting, sem
# limite, ou entre os maiores consumidores)
monitor_history_persist_containers() {
    local now="$1" file="$HIST_CONTAINERS_DIR/containers-$(date -d "@$now" +%Y-%m-%d 2>/dev/null || date +%Y-%m-%d).jsonl"
    local rec written=0
    local -a F
    # top consumidores de memória (ids) para inclusão
    local top_ids; top_ids=$(printf '%s\n' "${CONTAINERS_DATA[@]}" | awk -F'|' 'NF>20{print $19"|"$1}' | sort -t'|' -k1 -rn | head -n "${MONITOR_HISTORY_TOP_CONTAINERS:-5}" | cut -d'|' -f2 | tr '\n' ' ')
    for rec in "${CONTAINERS_DATA[@]}"; do
        IFS='|' read -r -a F <<< "$rec"
        local cid="${F[0]}" name="${F[1]}" state="${F[3]}" health="${F[5]}" sev="${F[23]}"
        local relevant=false
        case "$sev" in WARNING|CRITICAL|EMERGENCY) relevant=true ;; esac
        [ "$state" = "restarting" ] && relevant=true
        [ "$health" = "unhealthy" ] && relevant=true
        [ "${F[19]}" = "0" ] && [ "$state" = "running" ] && relevant=true
        case " $top_ids " in *" $cid "*) relevant=true ;; esac
        [ "$relevant" = true ] || continue

        local reasons=""
        case "$sev" in WARNING|CRITICAL|EMERGENCY) reasons+="\"severity_$sev\"," ;; esac
        [ "$health" = "unhealthy" ] && reasons+="\"unhealthy\","
        [ "$state" = "restarting" ] && reasons+="\"restarting\","
        [ "${F[19]}" = "0" ] && reasons+="\"no_memory_limit\","
        reasons="[${reasons%,}]"

        local line
        line=$(printf '{"schema_version":1,"timestamp_epoch":%s,"container_id":%s,"container_name":%s,"coolify_uuid":%s,"coolify_type":%s,"coolify_name":%s,"state":%s,"health":%s,"cpu_percent":%s,"memory_usage_bytes":%s,"memory_limit_bytes":%s,"memory_limit_percent":%s,"restart_count":%s,"restart_policy":%s,"severity":%s,"reasons":%s}' \
            "$now" "$(_hv_str "$cid")" "$(_hv_str "$name")" "$(_hv_str "${F[24]}")" "$(_hv_str "${F[25]}")" "$(_hv_str "${F[26]}")" \
            "$(_hv_str "$state")" "$(_hv_str "$health")" "$(_hv "${F[12]}")" "$(_hv_bytes "${F[18]}")" "$(_hv_bytes "${F[19]}")" \
            "$(_hv "${F[21]}")" "$(_hv "${F[8]}")" "$(_hv_str "${F[6]}")" "$(_hv_str "$sev")" "$reasons")
        _hist_append "$file" "$line" && written=$((written+1))
    done
    return 0
}

monitor_history_persist_workers() {
    local now="$1" file="$HIST_WORKERS_DIR/workers-$(date -d "@$now" +%Y-%m-%d 2>/dev/null || date +%Y-%m-%d).jsonl"
    local rec
    local -a F
    for rec in "${LARAVEL_WORKERS_DATA[@]}"; do
        IFS='|' read -r -a F <<< "$rec"
        local sev="${F[28]}"
        case "$sev" in WARNING|CRITICAL|EMERGENCY) ;; *) continue ;; esac
        # Identidade estável: coolify_uuid|container|tipo|filas (não o PID)
        local identity="${F[12]:-}"; [ -z "$identity" ] && identity="${F[11]:-host}:${F[9]}:${F[15]}"
        local findings=""; local f
        for f in ${F[30]//,/ }; do findings+="\"$f\","; done
        findings="[${findings%,}]"
        local line
        line=$(printf '{"schema_version":1,"timestamp_epoch":%s,"worker_identity":%s,"pid":%s,"worker_type":%s,"container_id":%s,"container_name":%s,"coolify_uuid":%s,"queue_names":%s,"elapsed_seconds":%s,"cpu_percent":%s,"rss_bytes":%s,"timeout_seconds":%s,"memory_option_mb":%s,"max_time_seconds":%s,"worker_isolation":%s,"severity":%s,"findings":%s}' \
            "$now" "$(_hv_str "$identity")" "$(_hv "${F[0]}")" "$(_hv_str "${F[9]}")" "$(_hv_str "${F[10]}")" "$(_hv_str "${F[11]}")" \
            "$(_hv_str "${F[12]}")" "$(_hv_str "${F[15]}")" "$(_hv "${F[4]}")" "$(_hv "${F[5]}")" \
            "$(awk -v k="${F[8]}" 'BEGIN{if(k ~ /^[0-9]+$/) printf "%d", k*1024; else printf "null"}')" \
            "$(_hv "${F[16]}")" "$(_hv "${F[18]}")" "$(_hv "${F[20]}")" "$(_hv_str "${F[27]}")" "$(_hv_str "$sev")" "$findings")
        _hist_append "$file" "$line"
    done
    return 0
}

################################################################################
# Retenção e compressão (manutenção diária, segura)
################################################################################

# Remove/comprime apenas arquivos reconhecidos, no diretório validado, sem seguir
# symlink, com maxdepth 1. Tolerante a falhas.
monitor_history_maintenance() {
    HIST_MAINTENANCE_RAN=true
    local base="$MONITOR_HISTORY_DIR"
    case "$base" in ""|"/") return 1 ;; esac
    [ -d "$base" ] || return 0

    _clean() {  # <subdir> <glob> <days>
        local d="$base/$1" pat="$2" days="$3"
        [ -d "$d" ] || return 0
        [[ "$days" =~ ^[0-9]+$ ]] || return 0
        run_with_timeout 10 find "$d" -maxdepth 1 -type f -name "$pat" -mtime "+$days" -delete 2>/dev/null || true
    }
    _clean metrics "metrics-*.jsonl" "$MONITOR_HISTORY_METRICS_RETENTION_DAYS"
    _clean metrics "metrics-*.jsonl.gz" "$MONITOR_HISTORY_METRICS_RETENTION_DAYS"
    _clean containers "containers-*.jsonl" "$MONITOR_HISTORY_METRICS_RETENTION_DAYS"
    _clean containers "containers-*.jsonl.gz" "$MONITOR_HISTORY_METRICS_RETENTION_DAYS"
    _clean workers "workers-*.jsonl" "$MONITOR_HISTORY_METRICS_RETENTION_DAYS"
    _clean workers "workers-*.jsonl.gz" "$MONITOR_HISTORY_METRICS_RETENTION_DAYS"
    _clean events "events-*.jsonl" "$MONITOR_HISTORY_EVENTS_RETENTION_DAYS"
    _clean events "diagnostics-*.jsonl" "$MONITOR_HISTORY_EVENTS_RETENTION_DAYS"
    _clean reports "report-*" "$MONITOR_HISTORY_REPORTS_RETENTION_DAYS"
    unset -f _clean

    # Compressão opcional (gzip); ausência não falha
    if command -v gzip &>/dev/null; then
        local d
        for d in metrics containers workers; do
            [ -d "$base/$d" ] || continue
            run_with_timeout 20 find "$base/$d" -maxdepth 1 -type f -name "*.jsonl" \
                -mtime "+${MONITOR_HISTORY_COMPRESS_AFTER_DAYS:-2}" -exec gzip -q {} \; 2>/dev/null || true
        done
    else
        log_info "Histórico: gzip ausente; arquivos mantidos sem compressão"
    fi
    return 0
}

################################################################################
# Persistência principal (chamada pelo cmd_check após alertas/diagnósticos)
################################################################################

monitor_history_persist() {
    HIST_METRICS_PERSISTED=false HIST_EVENTS_PERSISTED=0 HIST_BASELINE_UPDATED=false
    HIST_MAINTENANCE_RAN=false HIST_WOULD_METRICS=false
    HIST_DRY_RUN="${MONITOR_ALERT_DRY_RUN:-false}"

    monitor_history_init
    if [ "${MONITOR_HISTORY_ENABLED:-true}" != "true" ] || [ "$CLI_NO_HISTORY" = "true" ]; then
        HIST_ENABLED=false
        return 0
    fi
    HIST_ENABLED=true

    monitor_history_load_baseline
    local now; now=$(date +%s)
    HIST_LAST_METRICS_AT="$(_bl_num last_metrics_epoch 0)"

    # ---- Delta e tendência de swap ----
    local swap_cur_bytes="" swap_delta="" swap_secs=0
    if [[ "${SWAP_USED_MB:-}" =~ ^[0-9]+$ ]]; then
        swap_cur_bytes=$((SWAP_USED_MB * 1048576))
        local swap_prev; swap_prev="$(_bl_num swap_used_bytes -1)"
        local swap_prev_epoch; swap_prev_epoch="$(_bl_num swap_epoch 0)"
        if [ "$swap_prev" -ge 0 ]; then
            swap_delta=$((swap_cur_bytes - swap_prev))
            swap_secs=$((now - swap_prev_epoch))
        fi
    fi

    # ---- Intervalos ----
    local metrics_due=false container_due=false
    [ $((now - $(_bl_num last_metrics_epoch 0))) -ge "${MONITOR_HISTORY_METRICS_INTERVAL:-60}" ] && metrics_due=true
    [ "$(_bl_num last_metrics_epoch 0)" -eq 0 ] && metrics_due=true
    [ $((now - $(_bl_num last_container_epoch 0))) -ge "${MONITOR_HISTORY_CONTAINER_INTERVAL:-300}" ] && container_due=true

    # ---- Eventos (sempre avaliados; só transições emitem) ----
    monitor_history_detect_events "$now"
    local n_events="${#HIST_EVENT_LINES[@]}"

    # DRY-RUN: nada é gravado; apenas informa o que seria
    if [ "$HIST_DRY_RUN" = "true" ]; then
        [ "$metrics_due" = true ] && HIST_WOULD_METRICS=true
        return 0
    fi

    # ---- Métricas do host ----
    if [ "$metrics_due" = true ]; then
        local file="$HIST_METRICS_DIR/metrics-$(date -d "@$now" +%Y-%m-%d 2>/dev/null || date +%Y-%m-%d).jsonl"
        local line; line=$(monitor_history_build_metrics_line "$now" "${swap_delta:-}")
        if _hist_append "$file" "$line"; then
            HIST_METRICS_PERSISTED=true
            HIST_LAST_METRICS_AT="$now"
            BL[last_metrics_epoch]="$now"
            [ -n "$swap_cur_bytes" ] && { BL[swap_used_bytes]="$swap_cur_bytes"; BL[swap_epoch]="$now"; }
        fi
    fi

    # ---- Eventos (ignoram intervalo; gravam imediatamente) ----
    if [ "$n_events" -gt 0 ]; then
        local item etype eline efile
        for item in "${HIST_EVENT_LINES[@]}"; do
            etype="${item%%|*}"; eline="${item#*|}"
            case "$etype" in
                DIAGNOSIS_*) efile="$HIST_EVENTS_DIR/diagnostics-$(date -d "@$now" +%Y-%m 2>/dev/null || date +%Y-%m).jsonl" ;;
                *) efile="$HIST_EVENTS_DIR/events-$(date -d "@$now" +%Y-%m 2>/dev/null || date +%Y-%m).jsonl" ;;
            esac
            _hist_append "$efile" "$eline" && HIST_EVENTS_PERSISTED=$((HIST_EVENTS_PERSISTED + 1))
        done
    fi

    # ---- Detalhes de containers/workers (intervalo próprio ou evento) ----
    if [ "$container_due" = true ] || [ "$n_events" -gt 0 ]; then
        monitor_history_persist_containers "$now"
        monitor_history_persist_workers "$now"
        BL[last_container_epoch]="$now"
    fi

    # ---- Manutenção diária (retenção/compressão) ----
    if [ $((now - $(_bl_num last_maintenance_epoch 0))) -ge "${MONITOR_HISTORY_MAINTENANCE_INTERVAL:-86400}" ]; then
        monitor_history_maintenance
        BL[last_maintenance_epoch]="$now"
    fi

    # ---- Baseline atômico ----
    [ "$HIST_WRITE_ERRORS" -gt 0 ] && BL[write_failed]="true" || BL[write_failed]="false"
    monitor_history_save_baseline && HIST_BASELINE_UPDATED=true
    return 0
}

################################################################################
# RELATÓRIOS (subcomando report)
################################################################################

# Lê um arquivo .jsonl ou .jsonl.gz (com timeout)
_hist_read() {
    local f="$1"
    [ -f "$f" ] || return 0
    case "$f" in
        *.gz) command -v gzip &>/dev/null && run_with_timeout 15 gzip -dc "$f" 2>/dev/null ;;
        *)    run_with_timeout 15 cat "$f" 2>/dev/null ;;
    esac
}

# Converte "--last 1h|24h|7d|30m" em segundos
monitor_history_parse_duration() {
    local s="$1" n unit
    [[ "$s" =~ ^([0-9]+)([smhd])$ ]] || { echo ""; return 1; }
    n="${BASH_REMATCH[1]}"; unit="${BASH_REMATCH[2]}"
    case "$unit" in
        s) echo "$n" ;; m) echo "$((n*60))" ;; h) echo "$((n*3600))" ;; d) echo "$((n*86400))" ;;
    esac
}

# Lista arquivos de métricas (únicos) que cobrem [from,to], por dia
_hist_metric_files() {
    local from="$1" to="$2" d="$1" day f
    local guard=0
    {
        # varre de 'from' até 'to' e inclui explicitamente o dia de 'to'
        while [ "$d" -le "$to" ] && [ "$guard" -lt 400 ]; do
            day=$(date -u -d "@$d" +%Y-%m-%d 2>/dev/null || date -d "@$d" +%Y-%m-%d)
            for f in "$HIST_METRICS_DIR/metrics-$day.jsonl" "$HIST_METRICS_DIR/metrics-$day.jsonl.gz"; do
                [ -f "$f" ] && echo "$f"
            done
            d=$((d + 86400)); guard=$((guard+1))
        done
        day=$(date -u -d "@$to" +%Y-%m-%d 2>/dev/null || date -d "@$to" +%Y-%m-%d)
        for f in "$HIST_METRICS_DIR/metrics-$day.jsonl" "$HIST_METRICS_DIR/metrics-$day.jsonl.gz"; do
            [ -f "$f" ] && echo "$f"
        done
    } | sort -u
}

# awk portável (mawk/gawk) para extrair campos de JSON plano e agregar
_HIST_AWK='
function num(f,   s,i,v){ s="\""f"\":"; i=index($0,s); if(i==0)return ""; v=substr($0,i+length(s)); if(v ~ /^-?[0-9]/){match(v,/^-?[0-9.]+/); return substr(v,1,RLENGTH)} return "" }
function str(f,   s,i,v,j){ s="\""f"\":\""; i=index($0,s); if(i==0)return ""; v=substr($0,i+length(s)); j=index(v,"\""); return substr(v,1,j-1) }
{
  ts=num("timestamp_epoch"); if(ts==""||ts+0<from||ts+0>to) next;
  cnt++;
  l=num("load_1"); if(l!=""){ if(nl==0||l+0>maxl)maxl=l+0; suml+=l; nl++ }
  lr=num("load_ratio"); if(lr!=""){ if(nlr==0||lr+0>maxlr)maxlr=lr+0 }
  ma=num("memory_available_bytes"); if(ma!=""){ if(nma==0||ma+0<minma)minma=ma+0; nma++ }
  sp=num("swap_used_percent"); if(sp!=""){ if(nsp==0||sp+0>maxsp)maxsp=sp+0; sumsp+=sp; nsp++ }
  st=num("cpu_steal_percent"); if(st!=""){ if(nst==0||st+0>maxst)maxst=st+0 }
  io=num("cpu_iowait_percent"); if(io!=""){ if(nio==0||io+0>maxio)maxio=io+0 }
  cu=num("cpu_usage_percent"); if(cu!=""){ if(ncu==0||cu+0>maxcu)maxcu=cu+0; sumcu+=cu; ncu++ }
  ds=str("docker_status"); if(ds!=""&&ds!="HEALTHY")dockerbad++;
  sev=str("alerts_overall_severity");
  if(sev=="WARNING")twarn++; else if(sev=="CRITICAL")tcrit++; else if(sev=="EMERGENCY")temerg++;
}
END{
  printf "samples=%d\n", cnt;
  printf "max_load=%s\n", (nl?maxl:"");
  printf "avg_load=%s\n", (nl?suml/nl:"");
  printf "max_load_ratio=%s\n", (nlr?maxlr:"");
  printf "min_mem_available=%s\n", (nma?minma:"");
  printf "max_swap_percent=%s\n", (nsp?maxsp:"");
  printf "avg_swap_percent=%s\n", (nsp?sumsp/nsp:"");
  printf "max_steal=%s\n", (nst?maxst:"");
  printf "max_iowait=%s\n", (nio?maxio:"");
  printf "max_cpu=%s\n", (ncu?maxcu:"");
  printf "docker_unavailable=%d\n", dockerbad;
  printf "samples_warning=%d\n", twarn;
  printf "samples_critical=%d\n", tcrit;
  printf "samples_emergency=%d\n", temerg;
}'

# Coleta eventos no intervalo (opcionalmente filtrando por chave)
_hist_events_in_range() {
    local from="$1" to="$2" keyfilter="$3"
    local f
    for f in "$HIST_EVENTS_DIR"/events-*.jsonl "$HIST_EVENTS_DIR"/diagnostics-*.jsonl; do
        [ -f "$f" ] || continue
        _hist_read "$f"
    done | awk -v from="$from" -v to="$to" -v kf="$keyfilter" '
        function num(f,   s,i,v){ s="\""f"\":"; i=index($0,s); if(i==0)return ""; v=substr($0,i+length(s)); if(v ~ /^-?[0-9]/){match(v,/^-?[0-9.]+/); return substr(v,1,RLENGTH)} return "" }
        function str(f,   s,i,v,j){ s="\""f"\":\""; i=index($0,s); if(i==0)return ""; v=substr($0,i+length(s)); j=index(v,"\""); return substr(v,1,j-1) }
        { ts=num("timestamp_epoch"); if(ts==""||ts+0<from||ts+0>to) next;
          k=str("key"); if(kf!=""&&k!=kf) next;
          printf "%s\t%s\t%s\t%s\t%s\n", ts, str("event_type"), str("severity"), k, str("summary") }
    ' | sort -n
}

# Conta linhas JSON inválidas num conjunto de arquivos (report informa)
_hist_invalid_lines() {
    local from="$1" to="$2" f
    for f in $(_hist_metric_files "$from" "$to"); do _hist_read "$f"; done | awk '
        { if ($0 !~ /^\{.*\}$/ || index($0,"\"timestamp_epoch\":")==0) bad++ }
        END{ print bad+0 }'
}

# Relatório principal. Usa REPORT_* já definidos pelo chamador.
monitor_history_report() {
    monitor_history_init

    local from="$REPORT_FROM" to="$REPORT_TO" fmt="${REPORT_FORMAT:-human}"
    local now; now=$(date +%s)
    [ -z "$to" ] && to="$now"

    # Agregação de métricas
    local agg
    agg=$(for f in $(_hist_metric_files "$from" "$to"); do _hist_read "$f"; done \
        | awk -v from="$from" -v to="$to" "$_HIST_AWK")
    local samples; samples=$(echo "$agg" | awk -F= '$1=="samples"{print $2}')
    local invalid; invalid=$(_hist_invalid_lines "$from" "$to")
    _ag() { echo "$agg" | awk -F= -v k="$1" '$1==k{print $2}'; }

    # Timeline de eventos (filtro opcional)
    local keyfilter="$REPORT_INCIDENT"
    [ -n "$REPORT_DIAGNOSIS" ] && keyfilter="$REPORT_DIAGNOSIS"
    local events; events=$(_hist_events_in_range "$from" "$to" "$keyfilter")
    local n_open=0 n_recover=0
    if [ -n "$events" ]; then
        # grep -c já imprime o número (0 inclusive); não usar "|| echo 0"
        n_open=$(printf '%s\n' "$events" | grep -cE $'\t''(ALERT_OPENED|DIAGNOSIS_DETECTED)'$'\t')
        n_recover=$(printf '%s\n' "$events" | grep -cE $'\t''(ALERT_RECOVERED|DIAGNOSIS_RESOLVED)'$'\t')
    fi

    local from_h to_h
    from_h=$(date -d "@$from" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "$from")
    to_h=$(date -d "@$to" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "$to")

    case "$fmt" in
        json) _hist_report_json ;;
        csv)  _hist_report_csv ;;
        *)    _hist_report_human ;;
    esac
}

_hist_bytes_to_mb() { [[ "$1" =~ ^[0-9]+$ ]] && echo "$(( $1 / 1048576 ))" || echo "n/d"; }

_hist_report_human() {
    echo ""
    echo "VPS Guardian — Relatório de histórico"
    echo ""
    echo "Período:"
    echo "  $from_h → $to_h"
    echo ""
    if [ "${samples:-0}" -eq 0 ]; then
        echo "Nenhuma amostra encontrada no período."
        [ "${invalid:-0}" -gt 0 ] && echo "(${invalid} linha(s) inválida(s) ignorada(s))"
        return 0
    fi
    echo "Resumo:"
    echo "  Amostras: $samples"
    echo "  Maior load: $(_ag max_load)"
    echo "  Menor RAM disponível: $(_hist_bytes_to_mb "$(_ag min_mem_available)") MB"
    echo "  Maior swap: $(_ag max_swap_percent)%"
    echo "  Maior CPU steal: $(_ag max_steal)%"
    echo "  Maior I/O wait: $(_ag max_iowait)%"
    echo "  Maior CPU: $(_ag max_cpu)%"
    echo "  Docker indisponível: $(_ag docker_unavailable) amostra(s)"
    echo "  Amostras WARNING/CRITICAL/EMERGENCY: $(_ag samples_warning)/$(_ag samples_critical)/$(_ag samples_emergency)"
    echo "  Alertas/diagnósticos abertos: $n_open"
    echo "  Recuperações: $n_recover"
    [ "${invalid:-0}" -gt 0 ] && echo "  Linhas inválidas ignoradas: $invalid"
    echo ""
    echo "Linha do tempo:"
    if [ -z "$events" ]; then
        echo "  (nenhum evento no período)"
    else
        echo "$events" | while IFS=$'\t' read -r ts etype sev key summary; do
            printf "  %s %-20s %s\n" "$(date -d "@$ts" '+%m-%d %H:%M' 2>/dev/null || echo "$ts")" "$etype" "$summary"
        done
    fi
}

_hist_report_csv() {
    # Métricas em CSV com colunas estáveis
    echo "record_type,timestamp,hostname,load_1,load_ratio,cpu_usage,cpu_steal,memory_available_bytes,swap_used_bytes,swap_used_percent,docker_status"
    for f in $(_hist_metric_files "$from" "$to"); do _hist_read "$f"; done | awk -v from="$from" -v to="$to" '
        function num(f,   s,i,v){ s="\""f"\":"; i=index($0,s); if(i==0)return ""; v=substr($0,i+length(s)); if(v ~ /^-?[0-9]/){match(v,/^-?[0-9.]+/); return substr(v,1,RLENGTH)} return "" }
        function str(f,   s,i,v,j){ s="\""f"\":\""; i=index($0,s); if(i==0)return ""; v=substr($0,i+length(s)); j=index(v,"\""); return substr(v,1,j-1) }
        function csv(x){ if(x ~ /[",]/){ gsub(/"/,"\"\"",x); return "\"" x "\"" } return x }
        { ts=num("timestamp_epoch"); if(ts==""||ts+0<from||ts+0>to) next;
          printf "metric,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n", ts, csv(str("hostname")), num("load_1"), num("load_ratio"), num("cpu_usage_percent"), num("cpu_steal_percent"), num("memory_available_bytes"), num("swap_used_bytes"), num("swap_used_percent"), csv(str("docker_status")) }'
}

_hist_report_json() {
    local tl="" line
    if [ -n "$events" ]; then
        while IFS=$'\t' read -r ts etype sev key summary; do
            [ -n "$ts" ] || continue
            [ -n "$tl" ] && tl+=","
            tl+=$(printf '{"timestamp_epoch":%s,"event_type":%s,"severity":%s,"key":%s,"summary":%s}' \
                "$ts" "$(_hv_str "$etype")" "$(_hv_str "$sev")" "$(_hv_str "$key")" "$(_hv_str "$summary")")
        done <<< "$events"
    fi
    cat <<EOF
{
  "report": {
    "schema_version": 1,
    "generated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "period": { "from_epoch": $from, "to_epoch": $to },
    "summary": {
      "samples": ${samples:-0},
      "invalid_lines": ${invalid:-0},
      "max_load": $(_hv "$(_ag max_load)"),
      "avg_load": $(_hv "$(_ag avg_load)"),
      "min_memory_available_bytes": $(_hv "$(_ag min_mem_available)"),
      "max_swap_percent": $(_hv "$(_ag max_swap_percent)"),
      "max_cpu_steal_percent": $(_hv "$(_ag max_steal)"),
      "max_iowait_percent": $(_hv "$(_ag max_iowait)"),
      "max_cpu_percent": $(_hv "$(_ag max_cpu)"),
      "docker_unavailable_samples": $(_hv "$(_ag docker_unavailable)"),
      "alerts_opened": ${n_open:-0},
      "recoveries": ${n_recover:-0}
    },
    "timeline": [$tl]
  }
}
EOF
}

################################################################################
# Export (persistência)
################################################################################

export -f monitor_history_init monitor_history_path_safe
export -f monitor_history_load_baseline monitor_history_save_baseline
export -f monitor_history_trend monitor_history_rate
export -f monitor_history_build_metrics_line monitor_history_detect_events
export -f monitor_history_persist_containers monitor_history_persist_workers
export -f monitor_history_maintenance monitor_history_persist
export -f monitor_history_parse_duration monitor_history_report

MONITOR_HISTORY_LOADED=1
export MONITOR_HISTORY_LOADED
