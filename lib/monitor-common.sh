#!/bin/bash
################################################################################
# Script: monitor-common.sh
# Propósito: Biblioteca base do Monitor Preventivo (M0 — Fundação)
# Uso: source /opt/vpsguardian/lib/monitor-common.sh
#
# Funcionalidades:
#   - Carregamento de configuração com defaults seguros
#   - Execução de comandos externos com timeout
#   - Lock contra execuções simultâneas
#   - Classificação de severidade (INFO/WARNING/CRITICAL/EMERGENCY/UNKNOWN)
#   - Persistência de estado entre execuções (deltas de swap/cgroup)
#
# Referência: docs/MARCOS-MONITOR-PREVENTIVO.md (M0)
# Versão: 1.0.0
################################################################################

MONITOR_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONITOR_ROOT="${MONITOR_INSTALL_ROOT:-${VPSGUARDIAN_ROOT:-$(dirname "$MONITOR_LIB_DIR")}}"

# Carregar logging/cores se ainda não carregados (fallbacks mínimos)
if ! declare -F log_info >/dev/null 2>&1; then
    if [ -f "$MONITOR_LIB_DIR/logging.sh" ]; then
        source "$MONITOR_LIB_DIR/logging.sh"
    else
        log_info() { echo "[ INFO ] $*"; }
        log_success() { echo "[ OK ] $*"; }
        log_error() { echo "[ ERRO ] $*" >&2; }
        log_warning() { echo "[ AVISO ] $*"; }
        log_debug() { [ "${DEBUG:-0}" = "1" ] && echo "[ DEBUG ] $*"; }
        log_section() { echo ""; echo "========== $* =========="; echo ""; }
    fi
fi

################################################################################
# Configuração
################################################################################

# Carrega primeiro a configuração compartilhada (Discord/Coolify), depois
# config/monitor.conf, que contém apenas thresholds e flags sem credenciais.
# Precedência: valores do arquivo de config > variáveis de ambiente > defaults.
# Para ignorar qualquer config (ex: testes), use MONITOR_CONFIG_FILE=/dev/null.
monitor_load_config() {
    local shared_candidates shared
    if [ -n "${VPSGUARDIAN_SHARED_CONFIG_FILE:-}" ]; then
        shared_candidates=("$VPSGUARDIAN_SHARED_CONFIG_FILE")
    else
        shared_candidates=(
            "$MONITOR_ROOT/config/backup-destinations.conf"
            "/etc/vpsguardian/backup-destinations.conf"
            "/opt/vpsguardian/config/backup-destinations.conf"
        )
    fi
    for shared in "${shared_candidates[@]}"; do
        if [ -f "$shared" ]; then
            source "$shared"
            MONITOR_SHARED_CONFIG_LOADED="$shared"
            break
        fi
    done

    # MONITOR_CONFIG_FILE definido => usa somente ele (/dev/null desabilita tudo)
    local config_candidates
    if [ -n "${MONITOR_CONFIG_FILE:-}" ]; then
        config_candidates=("$MONITOR_CONFIG_FILE")
    else
        config_candidates=(
            "$MONITOR_ROOT/config/monitor.conf"
            "/etc/vpsguardian/monitor.conf"
            "/opt/vpsguardian/config/monitor.conf"
        )
    fi

    local config
    for config in "${config_candidates[@]}"; do
        if [ -f "$config" ]; then
            source "$config"
            MONITOR_CONFIG_LOADED="$config"
            break
        fi
    done

    # ---- Defaults seguros (usados quando nenhuma config define o valor) ----

    # Timeout para qualquer comando externo que possa travar (segundos)
    : "${MONITOR_COMMAND_TIMEOUT:=5}"

    # Intervalo entre as duas leituras de /proc/stat para delta de CPU (segundos)
    : "${MONITOR_CPU_SAMPLE_INTERVAL:=1}"

    # Memória disponível mínima (MB)
    : "${MONITOR_MEM_AVAILABLE_WARNING_MB:=2048}"
    : "${MONITOR_MEM_AVAILABLE_CRITICAL_MB:=1024}"
    # Alternativa por percentual disponível (0 = desabilitado)
    : "${MONITOR_MEM_AVAILABLE_WARNING_PERCENT:=0}"
    : "${MONITOR_MEM_AVAILABLE_CRITICAL_PERCENT:=0}"

    # Swap utilizada (%)
    : "${MONITOR_SWAP_WARNING_PERCENT:=10}"
    : "${MONITOR_SWAP_CRITICAL_PERCENT:=20}"
    : "${MONITOR_SWAP_EMERGENCY_PERCENT:=50}"

    # Load ratio (load_1min / vCPUs)
    : "${MONITOR_LOAD_RATIO_WARNING:=1.5}"
    : "${MONITOR_LOAD_RATIO_CRITICAL:=3.0}"
    : "${MONITOR_LOAD_RATIO_EMERGENCY:=5.0}"

    # CPU total (%)
    : "${MONITOR_CPU_WARNING_PERCENT:=85}"
    : "${MONITOR_CPU_CRITICAL_PERCENT:=95}"

    # CPU steal (%)
    : "${MONITOR_STEAL_WARNING_PERCENT:=10}"
    : "${MONITOR_STEAL_CRITICAL_PERCENT:=20}"
    : "${MONITOR_STEAL_EMERGENCY_PERCENT:=30}"

    # I/O wait (%)
    : "${MONITOR_IOWAIT_WARNING_PERCENT:=15}"
    : "${MONITOR_IOWAIT_CRITICAL_PERCENT:=30}"

    # Disco e inodes (%)
    : "${MONITOR_DISK_WARNING_PERCENT:=80}"
    : "${MONITOR_DISK_CRITICAL_PERCENT:=90}"
    : "${MONITOR_INODE_WARNING_PERCENT:=80}"
    : "${MONITOR_INODE_CRITICAL_PERCENT:=90}"

    # Alertas / motor de incidentes (M5)
    # Reutiliza o webhook Discord já configurado do VPS Guardian (WEBHOOK_URL em
    # config/backup-destinations.conf). Estas flags NÃO contêm credenciais.
    : "${MONITOR_ALERTS_ENABLED:=true}"
    : "${MONITOR_ALERT_DISCORD_ENABLED:=true}"
    : "${MONITOR_ALERT_COOLDOWN_MINUTES:=15}"
    : "${MONITOR_ALERT_REMINDERS_ENABLED:=false}"
    : "${MONITOR_ALERT_MIN_SEVERITY:=WARNING}"
    : "${MONITOR_ALERT_CONSECUTIVE:=1}"
    : "${MONITOR_ALERT_HTTP_TIMEOUT:=10}"
    : "${MONITOR_ALERT_DRY_RUN:=false}"
    : "${MONITOR_SERVER_NAME:=}"

    # Diretórios e arquivos
    : "${MONITOR_STATE_DIR:=/var/lib/vpsguardian/monitor}"
    : "${MONITOR_LOG_DIR:=${LOG_DIR:-/var/log/vpsguardian}}"
    : "${MONITOR_LOCK_FILE:=${LOCK_DIR:-/var/lock}/vpsguardian-monitor.lock}"

    # Fontes de dados (sobrescritas nos testes para apontar para fixtures)
    : "${MONITOR_PROC_DIR:=/proc}"
    : "${MONITOR_SYS_CGROUP_DIR:=/sys/fs/cgroup}"
    : "${MONITOR_DISK_PATH:=/}"

    MONITOR_STATE_FILE="$MONITOR_STATE_DIR/previous-metrics.env"
    MONITOR_LAST_CHECK_FILE="$MONITOR_STATE_DIR/last-check.json"
    MONITOR_INCIDENT_STATE_FILE="$MONITOR_STATE_DIR/incidents.state"
    MONITOR_DIAG_STATE_FILE="$MONITOR_STATE_DIR/diagnoses.state"
}

# Garante diretório de estado gravável; se não conseguir (ex: execução sem
# root), usa fallback em /tmp para o monitor continuar funcionando.
monitor_init_dirs() {
    if ! mkdir -p "$MONITOR_STATE_DIR" 2>/dev/null || [ ! -w "$MONITOR_STATE_DIR" ]; then
        MONITOR_STATE_DIR="/tmp/vpsguardian-monitor-$(id -u)"
        mkdir -p "$MONITOR_STATE_DIR" 2>/dev/null || true
        chmod 700 "$MONITOR_STATE_DIR" 2>/dev/null || true
        MONITOR_STATE_FILE="$MONITOR_STATE_DIR/previous-metrics.env"
        MONITOR_LAST_CHECK_FILE="$MONITOR_STATE_DIR/last-check.json"
        MONITOR_INCIDENT_STATE_FILE="$MONITOR_STATE_DIR/incidents.state"
    MONITOR_DIAG_STATE_FILE="$MONITOR_STATE_DIR/diagnoses.state"
        log_debug "Sem permissão no diretório de estado padrão; usando $MONITOR_STATE_DIR"
    fi

    mkdir -p "$MONITOR_LOG_DIR" 2>/dev/null || true
}

################################################################################
# Execução com timeout
################################################################################

# Executa um comando externo com timeout obrigatório.
# Uso: run_with_timeout [segundos] comando [args...]
# Retorno: código do comando; 124 em caso de timeout; 127 se comando não existe
run_with_timeout() {
    local secs="$1"
    shift

    if [ -z "$secs" ] || ! [[ "$secs" =~ ^[0-9]+$ ]]; then
        secs="$MONITOR_COMMAND_TIMEOUT"
    fi

    if command -v timeout &>/dev/null; then
        timeout "$secs" "$@"
    else
        # Sem o utilitário timeout (raro em distros suportadas): executa direto
        log_debug "Utilitário 'timeout' indisponível; executando sem proteção: $1"
        "$@"
    fi
}

################################################################################
# Lock (previne execuções simultâneas)
################################################################################

MONITOR_LOCK_ACQUIRED=false

# Adquire o lock do monitor. Reutiliza a semântica de check_lock (lib/validation.sh):
# lock com PID vivo => falha; lock órfão => remove e prossegue.
monitor_acquire_lock() {
    local lockfile="${1:-$MONITOR_LOCK_FILE}"

    if [ -f "$lockfile" ]; then
        local pid
        pid=$(cat "$lockfile" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            log_error "Monitor já está em execução (PID: $pid, Lock: $lockfile)"
            return 1
        fi
        log_debug "Lock órfão encontrado, removendo: $lockfile"
        rm -f "$lockfile" 2>/dev/null || true
    fi

    if ! echo $$ > "$lockfile" 2>/dev/null; then
        # Sem permissão no diretório de lock: usa fallback no diretório de estado
        MONITOR_LOCK_FILE="$MONITOR_STATE_DIR/monitor.lock"
        lockfile="$MONITOR_LOCK_FILE"
        if [ -f "$lockfile" ]; then
            local pid
            pid=$(cat "$lockfile" 2>/dev/null)
            if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
                log_error "Monitor já está em execução (PID: $pid, Lock: $lockfile)"
                return 1
            fi
            rm -f "$lockfile" 2>/dev/null || true
        fi
        echo $$ > "$lockfile" 2>/dev/null || {
            log_error "Não foi possível criar lock em $lockfile"
            return 1
        }
    fi

    MONITOR_LOCK_FILE="$lockfile"
    MONITOR_LOCK_ACQUIRED=true
    log_debug "Lock adquirido: $lockfile (PID: $$)"
    return 0
}

# Libera o lock (apenas se foi este processo que o adquiriu)
monitor_release_lock() {
    if [ "$MONITOR_LOCK_ACQUIRED" = true ]; then
        rm -f "$MONITOR_LOCK_FILE" 2>/dev/null || true
        MONITOR_LOCK_ACQUIRED=false
    fi
}

################################################################################
# Severidade
################################################################################

# Ordem de severidade para comparação
monitor_severity_rank() {
    case "$1" in
        INFO) echo 0 ;;
        WARNING) echo 1 ;;
        CRITICAL) echo 2 ;;
        EMERGENCY) echo 3 ;;
        *) echo -1 ;;  # UNKNOWN não eleva a severidade geral
    esac
}

# Retorna a pior severidade entre duas
monitor_severity_max() {
    local a="$1" b="$2"
    if [ "$(monitor_severity_rank "$a")" -ge "$(monitor_severity_rank "$b")" ]; then
        echo "$a"
    else
        echo "$b"
    fi
}

# Verifica se valor é numérico (inteiro ou decimal, com sinal opcional)
monitor_is_number() {
    [[ "$1" =~ ^-?[0-9]+([.][0-9]+)?$ ]]
}

# Classifica métrica onde MAIOR é pior (CPU, swap%, load ratio, steal...).
# Uso: monitor_classify_high <valor> <warning> <critical> [emergency]
# Thresholds vazios ou 0 são ignorados.
monitor_classify_high() {
    local value="$1" warn="$2" crit="$3" emerg="${4:-}"

    if ! monitor_is_number "$value"; then
        echo "UNKNOWN"
        return 0
    fi

    if [ -n "$emerg" ] && monitor_is_number "$emerg" && \
        awk -v v="$value" -v t="$emerg" 'BEGIN{exit !(t>0 && v>=t)}'; then
        echo "EMERGENCY"; return 0
    fi
    if [ -n "$crit" ] && monitor_is_number "$crit" && \
        awk -v v="$value" -v t="$crit" 'BEGIN{exit !(t>0 && v>=t)}'; then
        echo "CRITICAL"; return 0
    fi
    if [ -n "$warn" ] && monitor_is_number "$warn" && \
        awk -v v="$value" -v t="$warn" 'BEGIN{exit !(t>0 && v>=t)}'; then
        echo "WARNING"; return 0
    fi
    echo "INFO"
}

# Classifica métrica onde MENOR é pior (memória disponível).
# Uso: monitor_classify_low <valor> <warning> <critical> [emergency]
monitor_classify_low() {
    local value="$1" warn="$2" crit="$3" emerg="${4:-}"

    if ! monitor_is_number "$value"; then
        echo "UNKNOWN"
        return 0
    fi

    if [ -n "$emerg" ] && monitor_is_number "$emerg" && \
        awk -v v="$value" -v t="$emerg" 'BEGIN{exit !(t>0 && v<=t)}'; then
        echo "EMERGENCY"; return 0
    fi
    if [ -n "$crit" ] && monitor_is_number "$crit" && \
        awk -v v="$value" -v t="$crit" 'BEGIN{exit !(t>0 && v<=t)}'; then
        echo "CRITICAL"; return 0
    fi
    if [ -n "$warn" ] && monitor_is_number "$warn" && \
        awk -v v="$value" -v t="$warn" 'BEGIN{exit !(t>0 && v<=t)}'; then
        echo "WARNING"; return 0
    fi
    echo "INFO"
}

################################################################################
# Estado entre execuções (para deltas de swap e cgroup)
################################################################################

# Lê um valor do arquivo de estado da execução anterior
# Uso: monitor_state_get <chave>
monitor_state_get() {
    local key="$1"
    [ -f "$MONITOR_STATE_FILE" ] || return 1
    awk -F= -v k="$key" '$1==k {print substr($0, length(k)+2); found=1} END{exit !found}' \
        "$MONITOR_STATE_FILE" 2>/dev/null
}

# Acumula pares chave=valor para o próximo estado (gravação atômica no final)
MONITOR_STATE_BUFFER=""
monitor_state_set() {
    local key="$1" value="$2"
    MONITOR_STATE_BUFFER="${MONITOR_STATE_BUFFER}${key}=${value}
"
}

# Grava o estado acumulado de forma atômica
monitor_state_save() {
    [ -n "$MONITOR_STATE_BUFFER" ] || return 0
    local tmp="$MONITOR_STATE_FILE.tmp.$$"
    printf '%s' "$MONITOR_STATE_BUFFER" > "$tmp" 2>/dev/null && \
        mv -f "$tmp" "$MONITOR_STATE_FILE" 2>/dev/null || {
        rm -f "$tmp" 2>/dev/null
        log_debug "Não foi possível gravar estado em $MONITOR_STATE_FILE"
        return 1
    }
}

################################################################################
# Utilitários de formatação
################################################################################

# Escapa string para uso seguro dentro de JSON
monitor_json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/ }"
    s="${s//$'\t'/ }"
    printf '%s' "$s"
}

# Emite valor JSON: número puro sem aspas, resto com aspas
monitor_json_value() {
    local v="$1"
    if monitor_is_number "$v"; then
        printf '%s' "$v"
    else
        printf '"%s"' "$(monitor_json_escape "$v")"
    fi
}

# Converte segundos em formato humano (ex: "3d 4h 12m")
monitor_format_uptime() {
    local total="$1"
    monitor_is_number "$total" || { echo "n/d"; return; }
    local secs=${total%.*}
    local days=$((secs / 86400))
    local hours=$(((secs % 86400) / 3600))
    local mins=$(((secs % 3600) / 60))
    if [ "$days" -gt 0 ]; then
        echo "${days}d ${hours}h ${mins}m"
    elif [ "$hours" -gt 0 ]; then
        echo "${hours}h ${mins}m"
    else
        echo "${mins}m"
    fi
}

################################################################################
# Export das funções
################################################################################

export -f monitor_load_config monitor_init_dirs
export -f run_with_timeout
export -f monitor_acquire_lock monitor_release_lock
export -f monitor_severity_rank monitor_severity_max
export -f monitor_is_number monitor_classify_high monitor_classify_low
export -f monitor_state_get monitor_state_set monitor_state_save
export -f monitor_json_escape monitor_json_value monitor_format_uptime

# Marca que monitor-common.sh foi carregado
MONITOR_COMMON_LOADED=1
export MONITOR_COMMON_LOADED
