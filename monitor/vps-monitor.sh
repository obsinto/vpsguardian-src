#!/bin/bash
################################################################################
# Script: vps-monitor.sh
# Propósito: Monitor Preventivo de recursos do host (M0 + M1)
# Uso: ./vps-monitor.sh [comando] [opções]
#
# Comandos:
#   check       Executa uma verificação completa do host (padrão)
#   status      Mostra o resultado da última verificação
#   containers  Inventário detalhado de containers (M3)
#   emergency   Pacote de diagnóstico de emergência (M8)
#   report      Relatório do histórico (M7)
#   test-alert  Teste do canal compartilhado (M5)
#   config-check Valida configuração real e compatibilidade
#   self-check   Valida instalação, scheduler, dados e versões
#
# O monitor roda direto no host, não depende do Docker, aplica timeout em
# todo comando externo e nunca executa ações destrutivas.
#
# Referência: docs/MARCOS-MONITOR-PREVENTIVO.md
# Versão: 1.0.0
################################################################################

MONITOR_VERSION="1.0.0"
MONITOR_SCHEMA_VERSION="1"

INVOKED_SCRIPT_PATH="${BASH_SOURCE[0]}"
INVOKED_SCRIPT_DIR="$(cd "$(dirname "$INVOKED_SCRIPT_PATH")" && pwd)"
MONITOR_INSTALL_ROOT="${MONITOR_INSTALL_ROOT:-$(dirname "$INVOKED_SCRIPT_DIR")}"
export MONITOR_INSTALL_ROOT
VPSGUARDIAN_ROOT="${VPSGUARDIAN_ROOT:-$MONITOR_INSTALL_ROOT}"
export VPSGUARDIAN_ROOT

SCRIPT_PATH="$INVOKED_SCRIPT_PATH"
if [ -L "$SCRIPT_PATH" ]; then
    SCRIPT_PATH="$(readlink -f "$SCRIPT_PATH")"
fi
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"

# Carregar bibliotecas (com fallback de log se common.sh não existir)
source "$SCRIPT_DIR/../lib/common.sh" 2>/dev/null || {
    log_info() { echo "[ INFO ] $*"; }
    log_success() { echo "[ OK ] $*"; }
    log_error() { echo "[ ERRO ] $*" >&2; }
    log_warning() { echo "[ AVISO ] $*"; }
    log_debug() { [ "${DEBUG:-0}" = "1" ] && echo "[ DEBUG ] $*"; }
    log_section() { echo ""; echo "========== $* =========="; echo ""; }
}

source "$SCRIPT_DIR/../lib/monitor-common.sh" 2>/dev/null || {
    log_error "Biblioteca monitor-common.sh não encontrada"
    exit 1
}
source "$SCRIPT_DIR/../lib/monitor-collectors.sh" 2>/dev/null || {
    log_error "Biblioteca monitor-collectors.sh não encontrada"
    exit 1
}
source "$SCRIPT_DIR/../lib/monitor-docker.sh" 2>/dev/null || {
    log_error "Biblioteca monitor-docker.sh não encontrada"
    exit 1
}
source "$SCRIPT_DIR/../lib/monitor-containers.sh" 2>/dev/null || {
    log_error "Biblioteca monitor-containers.sh não encontrada"
    exit 1
}
source "$SCRIPT_DIR/../lib/monitor-laravel-workers.sh" 2>/dev/null || {
    log_error "Biblioteca monitor-laravel-workers.sh não encontrada"
    exit 1
}
source "$SCRIPT_DIR/../lib/monitor-alerts.sh" 2>/dev/null || {
    log_error "Biblioteca monitor-alerts.sh não encontrada"
    exit 1
}
source "$SCRIPT_DIR/../lib/monitor-correlation.sh" 2>/dev/null || {
    log_error "Biblioteca monitor-correlation.sh não encontrada"
    exit 1
}
source "$SCRIPT_DIR/../lib/monitor-history.sh" 2>/dev/null || {
    log_error "Biblioteca monitor-history.sh não encontrada"
    exit 1
}
source "$SCRIPT_DIR/../lib/monitor-emergency.sh" 2>/dev/null || {
    log_error "Biblioteca monitor-emergency.sh não encontrada"
    exit 1
}

################################################################################
# Ajuda e argumentos
################################################################################

show_help() {
    cat << 'EOF'
MONITOR PREVENTIVO - VPS Guardian

USO:
  ./vps-monitor.sh [COMANDO] [OPÇÕES]

COMANDOS:
  check         Executa verificação completa do host (padrão)
  status        Mostra o resultado da última verificação (JSON salvo)
  containers    Tabela detalhada de containers (consumo, limites, restarts)
  emergency     Pacote de diagnóstico de emergência (marco M8)
  report        Relatório do histórico (métricas, eventos, timeline)
  test-alert    Teste de canais de alerta (marco M5)
  config-check  Valida configuração, herança, chaves antigas e conflitos
  self-check    Valida instalação, scheduler, última execução, dados e versões

REPORT (histórico):
  report --last 1h|24h|7d          janela relativa
  report --from "AAAA-MM-DD HH:MM" --to "..."   janela absoluta
  report --incident <chave>        filtra a timeline por condição
  report --diagnosis <chave>       filtra por diagnóstico
  report --format human|json|csv   formato de saída (padrão: human)

EMERGENCY (pacote de diagnóstico):
  emergency                        coleta e gera o pacote de incidente
  emergency --archive              também gera .tar.gz
  emergency --notify               envia resumo curto pelo Discord existente
  emergency --output-dir <dir>     diretório de saída (validado)
  emergency --deadline <seg>       deadline global (padrão 45s)
  emergency --dockerd-goroutine-dump   envia SIGUSR1 ao dockerd (explícito)
  Exit: 0 completo · 1 parcial utilizável · 2 falha mínima · 3 args · 4 já em execução

OPÇÕES:
  --check         Sinônimo do comando check
  --json          Saída estruturada em JSON (stdout)
  --kv            Saída estruturada em chave=valor
  -v, --verbose   Saída detalhada (inclui thresholds e fontes)
  -q, --quiet     Mostra apenas métricas com WARNING ou pior
  --dry-run       Simula alertas E histórico sem gravar nada de estado real
  --dry-run-alerts  Sinônimo de --dry-run
  --no-alerts     Desativa o motor de alertas (o histórico continua sendo gravado)
  --no-history    Desativa a gravação de histórico/baseline neste ciclo
  -h, --help      Mostra esta ajuda
  --version       Mostra a versão

CÓDIGOS DE SAÍDA (comando check):
  0  Tudo normal (INFO)
  1  Pelo menos uma métrica em WARNING
  2  Pelo menos uma métrica em CRITICAL
  3  Pelo menos uma métrica em EMERGENCY
  4  Nenhuma métrica pôde ser coletada (UNKNOWN)
  10 Outra instância do monitor já está em execução

CONFIGURAÇÃO:
  Thresholds e diretórios em config/monitor.conf
  (veja config/monitor.conf.example — sem o arquivo, usa defaults seguros)

EXEMPLOS:
  ./vps-monitor.sh --check              # verificação com resumo legível
  ./vps-monitor.sh check --json         # saída JSON para integração
  ./vps-monitor.sh check --quiet        # só problemas (ideal para cron)
  DEBUG=1 ./vps-monitor.sh check -v     # depuração completa

EOF
}

ACTION="check"
OUTPUT_MODE="human"     # human | json | kv
VERBOSE=false
QUIET=false
CLI_DRY_RUN=false
CLI_NO_ALERTS=false
CLI_NO_HISTORY=false

# Contadores do motor de alertas (default seguro se o motor não rodar)
ALERTS_OPENED=0 ALERTS_ESCALATED=0 ALERTS_REMINDED=0 ALERTS_RECOVERED=0
ALERTS_SUPPRESSED=0 ALERTS_FAILED=0 ALERTS_PENDING=0 ALERTS_CHANNEL="none"
ALERTS_DRY_RUN=false ALERTS_STATE_PERSISTED=false ALERTS_NOTIFICATIONS_SENT=false
ALERTS_DRYRUN_REPORT=()

# Parâmetros do subcomando report (M7)
REPORT_LAST="" REPORT_FROM="" REPORT_TO="" REPORT_FORMAT="human"
REPORT_INCIDENT="" REPORT_CONTAINER="" REPORT_DIAGNOSIS=""

# Parâmetros do subcomando emergency (M8)
EM_OUTPUT_DIR="" EM_WANT_ARCHIVE=false EM_NOTIFY=false EM_GOROUTINE_DUMP=false
EM_CLI_DEADLINE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        check|status|containers|emergency|report|test-alert|config-check|self-check)
            ACTION="$1" ;;
        --check)        ACTION="check" ;;
        --json)         OUTPUT_MODE="json"; REPORT_FORMAT="json" ;;
        --kv)           OUTPUT_MODE="kv" ;;
        -v|--verbose)   VERBOSE=true ;;
        -q|--quiet)     QUIET=true ;;
        --dry-run|--dry-run-alerts) CLI_DRY_RUN=true ;;
        --no-alerts)    CLI_NO_ALERTS=true ;;
        --no-history)   CLI_NO_HISTORY=true ;;
        --last)         REPORT_LAST="$2"; shift ;;
        --from)         REPORT_FROM="$2"; shift ;;
        --to)           REPORT_TO="$2"; shift ;;
        --format)       REPORT_FORMAT="$2"; shift ;;
        --incident)     REPORT_INCIDENT="$2"; shift ;;
        --container)    REPORT_CONTAINER="$2"; shift ;;
        --diagnosis)    REPORT_DIAGNOSIS="$2"; shift ;;
        --archive)      EM_WANT_ARCHIVE=true ;;
        --notify)       EM_NOTIFY=true ;;
        --no-notify)    EM_NOTIFY=false ;;
        --output-dir)   EM_OUTPUT_DIR="$2"; shift ;;
        --deadline)     EM_CLI_DEADLINE="$2"; shift ;;
        --dockerd-goroutine-dump) EM_GOROUTINE_DUMP=true ;;
        -h|--help)      show_help; exit 0 ;;
        --version)      echo "vps-monitor $MONITOR_VERSION"; exit 0 ;;
        *)
            log_error "Opção desconhecida: $1 (use --help)"
            exit 64 ;;
    esac
    shift
done

################################################################################
# Inicialização, lock e sinais
################################################################################

monitor_load_config

# config-check e self-check são estritamente read-only: não criam diretórios,
# locks, snapshots ou histórico.
case "$ACTION" in
    config-check|self-check) ;;
    *) monitor_init_dirs ;;
esac

# Log em arquivo (best-effort; falha silenciosa se sem permissão)
if [ "$ACTION" != "config-check" ] && [ "$ACTION" != "self-check" ] && \
   declare -F set_log_file >/dev/null 2>&1 && [ -w "$MONITOR_LOG_DIR" ] 2>/dev/null; then
    set_log_file "$MONITOR_LOG_DIR/monitor.log"
fi

monitor_cleanup() {
    monitor_release_lock
}

# EXIT cobre o término normal; INT/TERM garantem código de saída correto
trap monitor_cleanup EXIT
trap 'log_debug "Interrompido (SIGINT)"; exit 130' INT
trap 'log_debug "Finalizado (SIGTERM)"; exit 143' TERM

################################################################################
# Coleta (cada coletor pode falhar sem derrubar o restante)
################################################################################

COLLECT_ERRORS=""

run_collector() {
    local fn="$1" label="$2"
    if ! "$fn"; then
        COLLECT_ERRORS="${COLLECT_ERRORS}${label}; "
        log_debug "Coletor falhou: $label"
    fi
}

run_check_collectors() {
    run_collector collect_host_info "identificação do host"
    run_collector collect_load "load average"
    run_collector collect_memory "memória"
    run_collector collect_swap "swap"
    run_collector collect_cpu "cpu"
    run_collector collect_cgroup "cgroup"
    run_collector collect_processes "processos"
    run_collector collect_disk "disco"
    run_collector collect_docker "docker/containerd"
    run_collector collect_containers "containers"
    run_collector collect_laravel_workers "workers laravel"
}

################################################################################
# Severidade geral e alertas por métrica
################################################################################

OVERALL_SEVERITY="UNKNOWN"
ALERTS=()   # cada item: "severidade|métrica|mensagem"

add_alert() {
    local severity="$1" metric="$2" message="$3"
    case "$severity" in
        WARNING|CRITICAL|EMERGENCY)
            ALERTS+=("$severity|$metric|$message")
            ;;
    esac
    if [ "$severity" != "UNKNOWN" ]; then
        OVERALL_SEVERITY=$(monitor_severity_max "$OVERALL_SEVERITY" "$severity")
        if [ "$OVERALL_SEVERITY" = "UNKNOWN" ]; then
            OVERALL_SEVERITY="$severity"
        fi
    fi
}

evaluate_metrics() {
    # A severidade geral começa em UNKNOWN e vira INFO na primeira métrica válida
    [ -n "$LOAD_SEVERITY" ] && add_alert "$LOAD_SEVERITY" "load" \
        "Load ratio ${LOAD_RATIO:-n/d} (load 1min: ${LOAD_1:-n/d}, vCPUs: ${HOST_VCPUS:-n/d})"
    [ -n "$MEM_SEVERITY" ] && add_alert "$MEM_SEVERITY" "memoria" \
        "RAM disponível: ${MEM_AVAILABLE_MB:-n/d} MB de ${MEM_TOTAL_MB:-n/d} MB (${MEM_AVAILABLE_PERCENT:-n/d}%)"
    [ -n "$SWAP_SEVERITY" ] && add_alert "$SWAP_SEVERITY" "swap" \
        "Swap utilizada: ${SWAP_USED_PERCENT:-n/d}% (${SWAP_USED_MB:-n/d} MB, crescimento: ${SWAP_GROWTH_MB:-n/d} MB)"
    [ -n "$CPU_SEVERITY" ] && add_alert "$CPU_SEVERITY" "cpu" \
        "CPU total: ${CPU_USAGE_PERCENT:-n/d}%"
    [ -n "$CPU_STEAL_SEVERITY" ] && add_alert "$CPU_STEAL_SEVERITY" "cpu_steal" \
        "CPU steal: ${CPU_STEAL_PERCENT:-n/d}% (possível limitação do provedor)"
    [ -n "$CPU_IOWAIT_SEVERITY" ] && add_alert "$CPU_IOWAIT_SEVERITY" "iowait" \
        "I/O wait: ${CPU_IOWAIT_PERCENT:-n/d}%"
    [ -n "$CGROUP_SEVERITY" ] && add_alert "$CGROUP_SEVERITY" "cgroup" \
        "Throttling de cgroup: ${CGROUP_THROTTLING_STATUS:-indeterminado} (delta: ${CGROUP_THROTTLED_DELTA:-n/d})"
    [ -n "$DISK_SEVERITY" ] && add_alert "$DISK_SEVERITY" "disco" \
        "Disco ${DISK_PATH:-/}: ${DISK_USED_PERCENT:-n/d}% usado (${DISK_AVAILABLE_MB:-n/d} MB livres)"
    [ -n "$INODE_SEVERITY" ] && add_alert "$INODE_SEVERITY" "inodes" \
        "Inodes ${DISK_PATH:-/}: ${INODE_USED_PERCENT:-n/d}% usados"

    # Docker/containerd (M2)
    if [ -n "$DOCKER_SEVERITY" ]; then
        local docker_msg="Docker: ${DOCKER_STATUS:-UNKNOWN}"
        [ -n "$DOCKER_PS_LATENCY_MS" ] && docker_msg+=" (docker ps: ${DOCKER_PS_LATENCY_MS}ms)"
        if [ "$DOCKER_STATUS" = "DOCKER_UNRESPONSIVE_CONTAINERD_HEALTHY" ]; then
            docker_msg+=" — containerd responde; Docker pode ser vítima da saturação do host, não assumir corrupção"
        fi
        add_alert "$DOCKER_SEVERITY" "docker" "$docker_msg"
    fi

    # Containers (M3): alertas individuais já classificados, com limite de exibição
    local max_container_alerts="${MONITOR_TOP_CONTAINERS:-5}"
    local shown=0 item severity cname message
    for item in "${CONTAINERS_ALERTS[@]}"; do
        [ "$shown" -ge "$max_container_alerts" ] && break
        IFS='|' read -r severity cname message <<< "$item"
        add_alert "$severity" "container" "Container $cname: $message"
        ((shown++))
    done
    if [ "${#CONTAINERS_ALERTS[@]}" -gt "$max_container_alerts" ]; then
        add_alert "WARNING" "containers" \
            "$(( ${#CONTAINERS_ALERTS[@]} - max_container_alerts )) outro(s) container(s) com problemas (veja --json)"
    fi

    # Workers Laravel/Horizon (M4): alertas individuais já classificados
    shown=0
    for item in "${LARAVEL_WORKERS_ALERTS[@]}"; do
        [ "$shown" -ge "$max_container_alerts" ] && break
        IFS='|' read -r severity cname message <<< "$item"
        add_alert "$severity" "laravel_worker" "Worker [$cname] $message"
        ((shown++))
    done
    if [ "${#LARAVEL_WORKERS_ALERTS[@]}" -gt "$max_container_alerts" ]; then
        add_alert "WARNING" "laravel_workers" \
            "$(( ${#LARAVEL_WORKERS_ALERTS[@]} - max_container_alerts )) outro(s) worker(s) com problemas (veja --json)"
    fi
}

################################################################################
# Motor de alertas (M5) — registra incidentes correntes a partir das métricas
################################################################################

build_incidents() {
    monitor_alerts_reset_current

    # Host
    monitor_alert_register "host:load"    "$LOAD_SEVERITY"      "Load average alto" \
        "Load 1min: ${LOAD_1} (ratio ${LOAD_RATIO}, vCPUs ${HOST_VCPUS})"
    monitor_alert_register "host:memoria" "$MEM_SEVERITY"       "Memória disponível baixa" \
        "Disponível: ${MEM_AVAILABLE_MB} MB (${MEM_AVAILABLE_PERCENT}%)"
    monitor_alert_register "host:swap"    "$SWAP_SEVERITY"      "Uso de swap elevado" \
        "Swap: ${SWAP_USED_PERCENT}% (${SWAP_USED_MB} MB, crescimento ${SWAP_GROWTH_MB} MB)"
    monitor_alert_register "host:cpu"     "$CPU_SEVERITY"       "CPU saturada" \
        "CPU: ${CPU_USAGE_PERCENT}%"
    monitor_alert_register "host:steal"   "$CPU_STEAL_SEVERITY" "CPU steal alto (possível throttling do provedor)" \
        "Steal: ${CPU_STEAL_PERCENT}%"
    monitor_alert_register "host:iowait"  "$CPU_IOWAIT_SEVERITY" "I/O wait elevado" \
        "I/O wait: ${CPU_IOWAIT_PERCENT}%"
    monitor_alert_register "host:cgroup"  "$CGROUP_SEVERITY"    "Throttling de cgroup detectado" \
        "Status: ${CGROUP_THROTTLING_STATUS} (delta ${CGROUP_THROTTLED_DELTA})"
    monitor_alert_register "host:disco"   "$DISK_SEVERITY"      "Disco quase cheio" \
        "Uso: ${DISK_USED_PERCENT}% em ${DISK_PATH} (${DISK_AVAILABLE_MB} MB livres)"
    monitor_alert_register "host:inodes"  "$INODE_SEVERITY"     "Inodes quase esgotados" \
        "Inodes: ${INODE_USED_PERCENT}% usados em ${DISK_PATH}"

    # Docker / containerd
    monitor_alert_register "docker:status" "$DOCKER_SEVERITY" "Docker: ${DOCKER_STATUS}" \
        "docker ps: ${DOCKER_PS_LATENCY_MS} ms | containerd: ${CONTAINERD_STATUS}"

    # Containers (M3)
    local item severity cname message
    for item in "${CONTAINERS_ALERTS[@]}"; do
        IFS='|' read -r severity cname message <<< "$item"
        monitor_alert_register "container:${cname}" "$severity" "Container ${cname}" "$message"
    done

    # Workers Laravel/Horizon (M4)
    for item in "${LARAVEL_WORKERS_ALERTS[@]}"; do
        IFS='|' read -r severity cname message <<< "$item"
        monitor_alert_register "worker:${cname}" "$severity" "Worker ${cname}" "$message"
    done
}

run_alert_engine() {
    # Flags de linha de comando têm precedência sobre a config
    [ "$CLI_DRY_RUN" = true ] && MONITOR_ALERT_DRY_RUN=true
    [ "$CLI_NO_ALERTS" = true ] && MONITOR_ALERTS_ENABLED=false

    # Correlação (M6): sempre calcula diagnósticos para as saídas, mesmo com o
    # motor de alertas desligado. Não faz coletas novas nem persiste aqui.
    [ "${MONITOR_CORRELATION_ENABLED:-true}" = "true" ] && monitor_correlation_compute

    if [ "${MONITOR_ALERTS_ENABLED:-true}" != "true" ]; then
        ALERTS_CHANNEL="engine_disabled"
        return 0
    fi

    monitor_alerts_load_state
    build_incidents
    # Registra diagnósticos elegíveis (por confiança) como incidentes do M5,
    # que então passam pela mesma máquina de estados (open/escalate/recover).
    [ "${MONITOR_CORRELATION_ENABLED:-true}" = "true" ] && monitor_correlation_register
    monitor_alerts_process
}

################################################################################
# Saídas
################################################################################

# JSON: número vazio vira null; strings são escapadas
jv() {
    if [ -z "$1" ]; then
        printf 'null'
    else
        monitor_json_value "$1"
    fi
}

# Converte linhas "pid|%cpu|%mem|etime|comando" em array JSON
processes_to_json() {
    local lines="$1" out="" pid cpu mem etime cmd
    while IFS='|' read -r pid cpu mem etime cmd; do
        [ -n "$pid" ] || continue
        [ -n "$out" ] && out+=","
        out+="{\"pid\":$(jv "$pid"),\"cpu_percent\":$(jv "$cpu"),\"mem_percent\":$(jv "$mem"),\"etime\":$(jv "$etime"),\"command\":\"$(monitor_json_escape "$cmd")\"}"
    done <<< "$lines"
    printf '%s' "$out"
}

build_json() {
    local alerts_json="" item severity metric message
    for item in "${ALERTS[@]}"; do
        IFS='|' read -r severity metric message <<< "$item"
        [ -n "$alerts_json" ] && alerts_json+=","
        alerts_json+="{\"metric\":\"$metric\",\"severity\":\"$severity\",\"message\":\"$(monitor_json_escape "$message")\"}"
    done

    cat << EOF
{
  "schema_version": 1,
  "collected_at": $(jv "$HOST_DATETIME"),
  "monitor_version": "$MONITOR_VERSION",
  "host": {
    "hostname": $(jv "$HOST_HOSTNAME"),
    "os": $(jv "$HOST_OS"),
    "kernel": $(jv "$HOST_KERNEL"),
    "vcpus": $(jv "$HOST_VCPUS"),
    "uptime_seconds": $(jv "$HOST_UPTIME_SECONDS"),
    "uptime_human": $(jv "$HOST_UPTIME_HUMAN")
  },
  "load": {
    "load_1": $(jv "$LOAD_1"),
    "load_5": $(jv "$LOAD_5"),
    "load_15": $(jv "$LOAD_15"),
    "load_ratio": $(jv "$LOAD_RATIO"),
    "severity": $(jv "$LOAD_SEVERITY")
  },
  "memory": {
    "total_mb": $(jv "$MEM_TOTAL_MB"),
    "used_mb": $(jv "$MEM_USED_MB"),
    "available_mb": $(jv "$MEM_AVAILABLE_MB"),
    "used_percent": $(jv "$MEM_USED_PERCENT"),
    "available_percent": $(jv "$MEM_AVAILABLE_PERCENT"),
    "severity": $(jv "$MEM_SEVERITY")
  },
  "swap": {
    "enabled": ${SWAP_ENABLED:-false},
    "total_mb": $(jv "$SWAP_TOTAL_MB"),
    "used_mb": $(jv "$SWAP_USED_MB"),
    "used_percent": $(jv "$SWAP_USED_PERCENT"),
    "growth_mb": $(jv "$SWAP_GROWTH_MB"),
    "severity": $(jv "$SWAP_SEVERITY")
  },
  "cpu": {
    "usage_percent": $(jv "$CPU_USAGE_PERCENT"),
    "user_percent": $(jv "$CPU_USER_PERCENT"),
    "system_percent": $(jv "$CPU_SYSTEM_PERCENT"),
    "idle_percent": $(jv "$CPU_IDLE_PERCENT"),
    "iowait_percent": $(jv "$CPU_IOWAIT_PERCENT"),
    "steal_percent": $(jv "$CPU_STEAL_PERCENT"),
    "severity": $(jv "$CPU_SEVERITY"),
    "steal_severity": $(jv "$CPU_STEAL_SEVERITY"),
    "iowait_severity": $(jv "$CPU_IOWAIT_SEVERITY")
  },
  "cgroup": {
    "version": $(jv "$CGROUP_VERSION"),
    "quota_status": $(jv "$CGROUP_QUOTA_STATUS"),
    "quota_percent": $(jv "$CGROUP_QUOTA_PERCENT"),
    "nr_periods": $(jv "$CGROUP_NR_PERIODS"),
    "nr_throttled": $(jv "$CGROUP_NR_THROTTLED"),
    "throttled_usec": $(jv "$CGROUP_THROTTLED_USEC"),
    "throttled_delta": $(jv "$CGROUP_THROTTLED_DELTA"),
    "throttling_status": $(jv "$CGROUP_THROTTLING_STATUS"),
    "severity": $(jv "$CGROUP_SEVERITY")
  },
  "top_processes": {
    "by_cpu": [$(processes_to_json "$TOP_CPU_PROCESSES")],
    "by_mem": [$(processes_to_json "$TOP_MEM_PROCESSES")]
  },
  "disk": {
    "path": $(jv "$DISK_PATH"),
    "total_mb": $(jv "$DISK_TOTAL_MB"),
    "available_mb": $(jv "$DISK_AVAILABLE_MB"),
    "used_percent": $(jv "$DISK_USED_PERCENT"),
    "inode_used_percent": $(jv "$INODE_USED_PERCENT"),
    "severity": $(jv "$DISK_SEVERITY"),
    "inode_severity": $(jv "$INODE_SEVERITY")
  },
  "docker": {
    "status": $(jv "$DOCKER_STATUS"),
    "severity": $(jv "$DOCKER_SEVERITY"),
    "status_since_epoch": $(jv "$DOCKER_STATUS_SINCE"),
    "docker_installed": ${DOCKER_INSTALLED:-false},
    "docker_available": ${DOCKER_PS_OK:-false},
    "socket_exists": ${DOCKER_SOCKET_EXISTS:-false},
    "socket_accessible": ${DOCKER_SOCKET_ACCESSIBLE:-false},
    "permission_error": ${DOCKER_PERMISSION_ERROR:-false},
    "service_state": $(jv "$DOCKER_SERVICE_STATE"),
    "version_latency_ms": $(jv "$DOCKER_VERSION_LATENCY_MS"),
    "info_latency_ms": $(jv "$DOCKER_INFO_LATENCY_MS"),
    "ps_latency_ms": $(jv "$DOCKER_PS_LATENCY_MS"),
    "dockerd": {
      "pid": $(jv "$DOCKERD_PID"),
      "state": $(jv "$DOCKERD_STATE"),
      "threads": $(jv "$DOCKERD_THREADS"),
      "rss_mb": $(jv "$DOCKERD_RSS_MB"),
      "cpu_percent": $(jv "$DOCKERD_CPU_PERCENT"),
      "etime": $(jv "$DOCKERD_ETIME")
    },
    "containerd": {
      "status": $(jv "$CONTAINERD_STATUS"),
      "available": ${CTR_AVAILABLE:-false},
      "responsive": $(jv "$CONTAINERD_PROBE_OK"),
      "latency_ms": $(jv "$CONTAINERD_LATENCY_MS"),
      "service_state": $(jv "$CONTAINERD_SERVICE_STATE"),
      "pid": $(jv "$CONTAINERD_PID"),
      "state": $(jv "$CONTAINERD_STATE"),
      "threads": $(jv "$CONTAINERD_THREADS"),
      "rss_mb": $(jv "$CONTAINERD_RSS_MB")
    }
  },
  "containers_summary": {
    "status": $(jv "$CONTAINERS_STATUS"),
    "note": $(jv "$CONTAINERS_STATUS_NOTE"),
    "total": $(jv "$CONTAINERS_TOTAL"),
    "running": $(jv "$CONTAINERS_RUNNING"),
    "stopped": $(jv "$CONTAINERS_STOPPED"),
    "restarting": $(jv "$CONTAINERS_RESTARTING"),
    "unhealthy": $(jv "$CONTAINERS_UNHEALTHY"),
    "without_memory_limit": $(jv "$CONTAINERS_NO_MEM_LIMIT"),
    "without_cpu_limit": $(jv "$CONTAINERS_NO_CPU_LIMIT"),
    "restart_loops": $(jv "$CONTAINERS_RESTART_LOOPS"),
    "with_problems": $(jv "$CONTAINERS_PROBLEMS"),
    "max_severity": $(jv "$CONTAINERS_MAX_SEVERITY"),
    "coolify_api_used": ${MONITOR_COOLIFY_API_USED:-false}
  },
  "containers": [$(monitor_containers_json)],
  "laravel_workers_summary": {
    "status": $(jv "$LARAVEL_STATUS"),
    "workers_total": $(jv "$LARAVEL_TOTAL"),
    "horizon_masters": $(jv "$LARAVEL_HORIZON_MASTERS"),
    "horizon_workers": $(jv "$LARAVEL_HORIZON_WORKERS"),
    "queue_workers": $(jv "$LARAVEL_QUEUE_WORKERS"),
    "queue_listeners": $(jv "$LARAVEL_QUEUE_LISTENERS"),
    "schedulers": $(jv "$LARAVEL_SCHEDULERS"),
    "octane_processes": $(jv "$LARAVEL_OCTANE"),
    "containers_with_workers": $(jv "$LARAVEL_CONTAINERS_WITH_WORKERS"),
    "containers_shared_with_web": $(jv "$LARAVEL_SHARED_WITH_WEB"),
    "workers_warning": $(jv "$LARAVEL_WARNING"),
    "workers_critical": $(jv "$LARAVEL_CRITICAL"),
    "workers_emergency": $(jv "$LARAVEL_EMERGENCY"),
    "dangerous_timeout_count": $(jv "$LARAVEL_DANGEROUS_TIMEOUTS"),
    "containers_without_worker_memory_limit": $(jv "$LARAVEL_CONTAINERS_NO_MEM_LIMIT"),
    "max_severity": $(jv "$LARAVEL_MAX_SEVERITY")
  },
  "laravel_workers": [$(monitor_laravel_workers_json)],
  "alerts": {
    "engine_enabled": ${MONITOR_ALERTS_ENABLED:-true},
    "discord_enabled": ${MONITOR_ALERT_DISCORD_ENABLED:-true},
    "alerts_dry_run": ${ALERTS_DRY_RUN:-false},
    "state_persisted": ${ALERTS_STATE_PERSISTED:-false},
    "notifications_sent": ${ALERTS_NOTIFICATIONS_SENT:-false},
    "opened": $(jv "$ALERTS_OPENED"),
    "escalated": $(jv "$ALERTS_ESCALATED"),
    "reminded": $(jv "$ALERTS_REMINDED"),
    "recovered": $(jv "$ALERTS_RECOVERED"),
    "suppressed": $(jv "$ALERTS_SUPPRESSED"),
    "pending": $(jv "$ALERTS_PENDING"),
    "failed": $(jv "$ALERTS_FAILED"),
    "last_channel_result": $(jv "$ALERTS_CHANNEL")
  },
  "diagnostics_summary": {
    "total": ${DIAG_N:-0},
    "main_diagnosis_key": $(jv "$DIAG_MAIN_KEY"),
    "highest_severity": $(jv "$DIAG_HIGHEST_SEV"),
    "highest_confidence": $(jv "$DIAG_HIGHEST_CONF")
  },
  "diagnostics": [$(monitor_correlation_json)],
  "history": {
    "enabled": ${HIST_ENABLED:-false},
    "dry_run": ${HIST_DRY_RUN:-false},
    "metrics_persisted": ${HIST_METRICS_PERSISTED:-false},
    "events_persisted": ${HIST_EVENTS_PERSISTED:-0},
    "baseline_updated": ${HIST_BASELINE_UPDATED:-false},
    "last_metrics_at": $(jv "${HIST_LAST_METRICS_AT:-}"),
    "write_errors": ${HIST_WRITE_ERRORS:-0}
  },
  "overall": {
    "severity": $(jv "$OVERALL_SEVERITY"),
    "collect_errors": $(jv "${COLLECT_ERRORS%; }"),
    "alerts": [$alerts_json]
  }
}
EOF
}

build_kv() {
    # Formato chave=valor estável para consumo por outros scripts
    cat << EOF
collected_at=$HOST_DATETIME
hostname=$HOST_HOSTNAME
os=$HOST_OS
kernel=$HOST_KERNEL
vcpus=$HOST_VCPUS
uptime_seconds=$HOST_UPTIME_SECONDS
load_1=$LOAD_1
load_5=$LOAD_5
load_15=$LOAD_15
load_ratio=$LOAD_RATIO
load_severity=$LOAD_SEVERITY
mem_total_mb=$MEM_TOTAL_MB
mem_used_mb=$MEM_USED_MB
mem_available_mb=$MEM_AVAILABLE_MB
mem_available_percent=$MEM_AVAILABLE_PERCENT
mem_severity=$MEM_SEVERITY
swap_enabled=$SWAP_ENABLED
swap_total_mb=$SWAP_TOTAL_MB
swap_used_mb=$SWAP_USED_MB
swap_used_percent=$SWAP_USED_PERCENT
swap_growth_mb=$SWAP_GROWTH_MB
swap_severity=$SWAP_SEVERITY
cpu_usage_percent=$CPU_USAGE_PERCENT
cpu_user_percent=$CPU_USER_PERCENT
cpu_system_percent=$CPU_SYSTEM_PERCENT
cpu_iowait_percent=$CPU_IOWAIT_PERCENT
cpu_steal_percent=$CPU_STEAL_PERCENT
cpu_severity=$CPU_SEVERITY
cpu_steal_severity=$CPU_STEAL_SEVERITY
cpu_iowait_severity=$CPU_IOWAIT_SEVERITY
cgroup_version=$CGROUP_VERSION
cgroup_quota_status=$CGROUP_QUOTA_STATUS
cgroup_quota_percent=$CGROUP_QUOTA_PERCENT
cgroup_nr_throttled=$CGROUP_NR_THROTTLED
cgroup_throttled_delta=$CGROUP_THROTTLED_DELTA
cgroup_throttling_status=$CGROUP_THROTTLING_STATUS
cgroup_severity=$CGROUP_SEVERITY
disk_path=$DISK_PATH
disk_used_percent=$DISK_USED_PERCENT
disk_available_mb=$DISK_AVAILABLE_MB
disk_severity=$DISK_SEVERITY
inode_used_percent=$INODE_USED_PERCENT
inode_severity=$INODE_SEVERITY
docker.status=$DOCKER_STATUS
docker.severity=$DOCKER_SEVERITY
docker.installed=$DOCKER_INSTALLED
docker.available=$DOCKER_PS_OK
docker.latency_ms=$DOCKER_PS_LATENCY_MS
docker.service_state=$DOCKER_SERVICE_STATE
containerd.status=$CONTAINERD_STATUS
containerd.available=$CTR_AVAILABLE
containerd.responsive=$CONTAINERD_PROBE_OK
containerd.latency_ms=$CONTAINERD_LATENCY_MS
containers.status=$CONTAINERS_STATUS
containers.total=$CONTAINERS_TOTAL
containers.running=$CONTAINERS_RUNNING
containers.stopped=$CONTAINERS_STOPPED
containers.restarting=$CONTAINERS_RESTARTING
containers.unhealthy=$CONTAINERS_UNHEALTHY
containers.without_memory_limit=$CONTAINERS_NO_MEM_LIMIT
containers.without_cpu_limit=$CONTAINERS_NO_CPU_LIMIT
containers.restart_loops=$CONTAINERS_RESTART_LOOPS
containers.with_problems=$CONTAINERS_PROBLEMS
containers.max_severity=$CONTAINERS_MAX_SEVERITY
laravel_workers.status=$LARAVEL_STATUS
laravel_workers.total=$LARAVEL_TOTAL
laravel_workers.horizon=$((LARAVEL_HORIZON_MASTERS + LARAVEL_HORIZON_WORKERS))
laravel_workers.queue=$((LARAVEL_QUEUE_WORKERS + LARAVEL_QUEUE_LISTENERS))
laravel_workers.schedulers=$LARAVEL_SCHEDULERS
laravel_workers.octane=$LARAVEL_OCTANE
laravel_workers.warning=$LARAVEL_WARNING
laravel_workers.critical=$LARAVEL_CRITICAL
laravel_workers.emergency=$LARAVEL_EMERGENCY
laravel_workers.dangerous_timeout=$LARAVEL_DANGEROUS_TIMEOUTS
laravel_workers.shared_with_web=$LARAVEL_SHARED_WITH_WEB
laravel_workers.containers_without_memory_limit=$LARAVEL_CONTAINERS_NO_MEM_LIMIT
laravel_workers.max_severity=$LARAVEL_MAX_SEVERITY
alerts.engine_enabled=${MONITOR_ALERTS_ENABLED:-true}
alerts.discord_enabled=${MONITOR_ALERT_DISCORD_ENABLED:-true}
alerts.dry_run=${ALERTS_DRY_RUN:-false}
alerts.state_persisted=${ALERTS_STATE_PERSISTED:-false}
alerts.notifications_sent=${ALERTS_NOTIFICATIONS_SENT:-false}
alerts.opened=$ALERTS_OPENED
alerts.escalated=$ALERTS_ESCALATED
alerts.reminded=$ALERTS_REMINDED
alerts.recovered=$ALERTS_RECOVERED
alerts.suppressed=$ALERTS_SUPPRESSED
alerts.failed=$ALERTS_FAILED
alerts.channel=$ALERTS_CHANNEL
diagnostics.total=${DIAG_N:-0}
diagnostics.main_key=$DIAG_MAIN_KEY
diagnostics.highest_severity=$DIAG_HIGHEST_SEV
diagnostics.highest_confidence=$DIAG_HIGHEST_CONF
diagnostics.memory_pressure=$(diag_present "diagnosis:memory:" && echo true || echo false)
diagnostics.throttling=$(diag_present "diagnosis:provider:" && echo true || echo false)
diagnostics.laravel_worker=$(diag_present "diagnosis:laravel:" && echo true || echo false)
diagnostics.docker_victim=$(diag_present "diagnosis:docker:" && echo true || echo false)
history.enabled=${HIST_ENABLED:-false}
history.dry_run=${HIST_DRY_RUN:-false}
history.metrics_persisted=${HIST_METRICS_PERSISTED:-false}
history.events_persisted=${HIST_EVENTS_PERSISTED:-0}
history.baseline_updated=${HIST_BASELINE_UPDATED:-false}
history.last_metrics_at=${HIST_LAST_METRICS_AT:-}
history.write_errors=${HIST_WRITE_ERRORS:-0}
overall_severity=$OVERALL_SEVERITY
EOF
}

# Verifica se há algum diagnóstico com o prefixo informado
diag_present() {
    local p="$1" i
    for ((i=0; i<${DIAG_N:-0}; i++)); do
        case "${D_KEY[$i]}" in "$p"*) return 0 ;; esac
    done
    return 1
}

# Agrupa workers Laravel por container e imprime os grupos problemáticos
show_laravel_groups() {
    local rec
    local -a F
    declare -A G_SEV G_COUNT G_TYPES G_TIMEOUT G_RSS_MIN G_RSS_MAX
    declare -A G_LIMIT G_POLICY G_ISO G_FINDINGS G_APP

    for rec in "${LARAVEL_WORKERS_DATA[@]}"; do
        IFS='|' read -r -a F <<< "$rec"
        local key="${F[11]:-host}"
        G_COUNT["$key"]=$(( ${G_COUNT[$key]:-0} + 1 ))
        G_SEV["$key"]=$(monitor_severity_max "${G_SEV[$key]:-INFO}" "${F[28]}")
        case "${G_TYPES[$key]:-}" in *"${F[9]}"*) ;; *) G_TYPES["$key"]="${G_TYPES[$key]:-}${G_TYPES[$key]:+, }${F[9]}" ;; esac
        if [ -n "${F[16]}" ] && [ "${F[16]}" -gt "${G_TIMEOUT[$key]:-0}" ] 2>/dev/null; then
            G_TIMEOUT["$key"]="${F[16]}"
        fi
        if monitor_is_number "${F[8]}"; then
            local rss_mb=$(( F[8] / 1024 ))
            [ -z "${G_RSS_MIN[$key]:-}" ] || [ "$rss_mb" -lt "${G_RSS_MIN[$key]}" ] && G_RSS_MIN["$key"]="$rss_mb"
            [ -z "${G_RSS_MAX[$key]:-}" ] || [ "$rss_mb" -gt "${G_RSS_MAX[$key]}" ] && G_RSS_MAX["$key"]="$rss_mb"
        fi
        G_LIMIT["$key"]="${F[25]}"
        G_POLICY["$key"]="${F[24]}"
        G_ISO["$key"]="${F[27]}"
        [ -n "${F[14]}" ] && G_APP["$key"]="${F[14]}"
        local f
        for f in ${F[30]//,/ }; do
            case "${G_FINDINGS[$key]:-}" in *"$f"*) ;; *) G_FINDINGS["$key"]="${G_FINDINGS[$key]:-}${G_FINDINGS[$key]:+, }$f" ;; esac
        done
    done

    local key shown=0 top_n="${MONITOR_TOP_CONTAINERS:-5}"
    for key in "${!G_SEV[@]}"; do
        [ "${G_SEV[$key]}" = "INFO" ] && continue
        [ "$shown" -ge "$top_n" ] && { echo "    ... (mais grupos no --json)"; break; }
        ((shown++))
        echo ""
        printf "  %s %s%s\n" "$(sev_tag "${G_SEV[$key]}")" "${G_APP[$key]:+${G_APP[$key]} / }" "$key"
        echo "      ${G_COUNT[$key]} worker(s): ${G_TYPES[$key]}"
        [ -n "${G_TIMEOUT[$key]:-}" ] && echo "      timeout: ${G_TIMEOUT[$key]}s"
        [ -n "${G_RSS_MIN[$key]:-}" ] && echo "      memória por processo: ${G_RSS_MIN[$key]}–${G_RSS_MAX[$key]} MB"
        if [ "${G_LIMIT[$key]}" = "0" ]; then
            echo "      container: sem limite de memória"
        elif [ -n "${G_LIMIT[$key]}" ]; then
            echo "      container: limite de ${G_LIMIT[$key]} MB"
        fi
        [ -n "${G_POLICY[$key]}" ] && echo "      restart policy: ${G_POLICY[$key]}"
        case "${G_ISO[$key]}" in
            ISOLATED) echo "      isolamento: container exclusivo" ;;
            SHARED_WITH_WEB) echo "      isolamento: COMPARTILHADO com servidor web" ;;
        esac
        [ -n "${G_FINDINGS[$key]:-}" ] && echo "      achados: ${G_FINDINGS[$key]}"
    done
}

# Seção de diagnósticos (M6): diagnóstico principal + gatilho/amplificador/impacto
show_diagnostics_report() {
    echo ""
    echo "  ─── Diagnósticos ───"
    if [ "${DIAG_N:-0}" -eq 0 ]; then
        printf "  %s Nenhum diagnóstico composto com confiança suficiente.\n" "$(sev_tag INFO)"
        return 0
    fi

    local mi=-1 i
    for ((i=0; i<DIAG_N; i++)); do [ "${D_KEY[$i]}" = "$DIAG_MAIN_KEY" ] && mi=$i; done
    [ "$mi" -lt 0 ] && mi=0

    # Sem confiança suficiente (nenhum diagnóstico MEDIUM+): apenas hipóteses fracas
    if [ "$(monitor_correlation_conf_rank "${D_CONF[$mi]}")" -lt 2 ]; then
        printf "  %s Nenhum diagnóstico composto com confiança suficiente.\n" "$(sev_tag INFO)"
        echo "  Hipóteses de baixa confiança (apenas informativas):"
        for ((i=0; i<DIAG_N; i++)); do
            printf "    - %s (%s, %s/100)\n" "${D_TITLE[$i]}" "${D_CONF[$i]}" "${D_SCORE[$i]}"
        done
        return 0
    fi

    echo ""
    echo "  Diagnóstico principal:"
    printf "  %s %s\n" "$(sev_tag "${D_SEV[$mi]}")" "${D_TITLE[$mi]}"
    printf "  Confiança: %s (%s/100)\n" "${D_CONF[$mi]}" "${D_SCORE[$mi]}"
    printf "  Papel: %s\n" "${D_ROLE[$mi]}"
    echo ""
    echo "  Gatilho provável:"
    printf "    %s\n" "${D_CAUSE[$mi]}"

    local role_label
    for ((i=0; i<DIAG_N; i++)); do
        [ "$i" -eq "$mi" ] && continue
        case "${D_ROLE[$i]}" in
            AMPLIFIER)           role_label="Amplificador" ;;
            IMPACT)              role_label="Impacto" ;;
            CONTRIBUTING_FACTOR) role_label="Fator contribuinte" ;;
            *)                   role_label="${D_ROLE[$i]}" ;;
        esac
        printf "\n  %s:\n    %s (confiança %s)\n" "$role_label" "${D_TITLE[$i]}" "${D_CONF[$i]}"
    done

    echo ""
    echo "  Evidências:"
    printf '%s' "${D_EVID[$mi]}" | awk -F';;' '{for(j=1;j<=NF;j++) if($j!="") printf "    - %s\n",$j}'
    echo "  Recomendação:"
    printf '%s' "${D_RECS[$mi]}" | awk -F';;' '{n=0;for(j=1;j<=NF;j++) if($j!=""){n++; printf "    %d. %s\n",n,$j}}'
}

# Tag colorida de severidade para o resumo humano
sev_tag() {
    local sev="$1"
    local color=""
    case "$sev" in
        INFO)      color="$GREEN" ;;
        WARNING)   color="$YELLOW" ;;
        CRITICAL)  color="$RED" ;;
        EMERGENCY) color="${BOLD_RED:-$RED}" ;;
        *)         color="$GRAY"; sev="UNKNOWN" ;;
    esac
    if [ -t 1 ]; then
        printf "%b[%-9s]%b" "$color" "$sev" "$NC"
    else
        printf "[%-9s]" "$sev"
    fi
}

# Linha do resumo; em modo quiet só imprime WARNING ou pior
print_metric() {
    local sev="$1" label="$2" value="$3"
    if [ "$QUIET" = true ]; then
        case "$sev" in WARNING|CRITICAL|EMERGENCY) ;; *) return 0 ;; esac
    fi
    printf "  %s  %-10s %s\n" "$(sev_tag "$sev")" "$label" "$value"
}

show_human_report() {
    if [ "$QUIET" = false ]; then
        log_section "VPS GUARDIAN — MONITOR PREVENTIVO"
        echo "  Host:       ${HOST_HOSTNAME:-n/d} (${HOST_OS:-n/d})"
        echo "  Kernel:     ${HOST_KERNEL:-n/d}"
        echo "  Data/hora:  ${HOST_DATETIME:-n/d}"
        echo "  Uptime:     ${HOST_UPTIME_HUMAN:-n/d}"
        echo "  vCPUs:      ${HOST_VCPUS:-n/d}"
        echo ""
    fi

    print_metric "$LOAD_SEVERITY" "Load:" \
        "${LOAD_1:-n/d} / ${LOAD_5:-n/d} / ${LOAD_15:-n/d}  (ratio: ${LOAD_RATIO:-n/d})"
    print_metric "$CPU_SEVERITY" "CPU:" \
        "${CPU_USAGE_PERCENT:-n/d}%  (user ${CPU_USER_PERCENT:-n/d}%, system ${CPU_SYSTEM_PERCENT:-n/d}%, idle ${CPU_IDLE_PERCENT:-n/d}%)"
    print_metric "$CPU_STEAL_SEVERITY" "Steal:" "${CPU_STEAL_PERCENT:-n/d}%"
    print_metric "$CPU_IOWAIT_SEVERITY" "I/O wait:" "${CPU_IOWAIT_PERCENT:-n/d}%"
    print_metric "$MEM_SEVERITY" "RAM:" \
        "${MEM_USED_MB:-n/d} MB usados de ${MEM_TOTAL_MB:-n/d} MB  (disponível: ${MEM_AVAILABLE_MB:-n/d} MB / ${MEM_AVAILABLE_PERCENT:-n/d}%)"
    if [ "$SWAP_ENABLED" = false ]; then
        print_metric "$SWAP_SEVERITY" "Swap:" "não configurada"
    else
        print_metric "$SWAP_SEVERITY" "Swap:" \
            "${SWAP_USED_MB:-n/d} MB de ${SWAP_TOTAL_MB:-n/d} MB  (${SWAP_USED_PERCENT:-n/d}%, crescimento: ${SWAP_GROWTH_MB:-n/d} MB)"
    fi

    local quota_desc="${CGROUP_QUOTA_STATUS:-indeterminado}"
    [ -n "$CGROUP_QUOTA_PERCENT" ] && quota_desc="$quota_desc (${CGROUP_QUOTA_PERCENT}% de 1 vCPU)"
    print_metric "$CGROUP_SEVERITY" "Quota CPU:" "$quota_desc [cgroup ${CGROUP_VERSION:-n/d}]"
    print_metric "$CGROUP_SEVERITY" "Throttle:" \
        "${CGROUP_THROTTLING_STATUS:-indeterminado}  (nr_throttled: ${CGROUP_NR_THROTTLED:-n/d}, delta: ${CGROUP_THROTTLED_DELTA:-n/d})"
    print_metric "$DISK_SEVERITY" "Disco:" \
        "${DISK_USED_PERCENT:-n/d}% usado em ${DISK_PATH:-/}  (${DISK_AVAILABLE_MB:-n/d} MB livres)"
    print_metric "$INODE_SEVERITY" "Inodes:" "${INODE_USED_PERCENT:-n/d}% usados"

    # ─── Docker / containers (M2 + M3) ───
    if [ "$DOCKER_INSTALLED" = true ] || [ "${MONITOR_DOCKER_REQUIRED:-false}" = "true" ]; then
        if [ "$QUIET" = false ]; then
            echo ""
            echo "  ─── Docker / Containerd ───"
        fi
        local docker_lat_desc="docker ps: ${DOCKER_PS_LATENCY_MS:-n/d} ms"
        [ -n "$CONTAINERD_LATENCY_MS" ] && docker_lat_desc+=", containerd: ${CONTAINERD_LATENCY_MS} ms"
        print_metric "$DOCKER_SEVERITY" "Docker:" "${DOCKER_STATUS:-n/d}  ($docker_lat_desc)"
        if [ "$QUIET" = false ]; then
            local dockerd_desc="não encontrado"
            [ -n "$DOCKERD_PID" ] && dockerd_desc="PID $DOCKERD_PID (${DOCKERD_STATE:-?}), ${DOCKERD_THREADS:-?} threads, ${DOCKERD_RSS_MB:-?} MB"
            local containerd_desc="não encontrado"
            [ -n "$CONTAINERD_PID" ] && containerd_desc="PID $CONTAINERD_PID (${CONTAINERD_STATE:-?}), ${CONTAINERD_THREADS:-?} threads"
            echo "               dockerd: $dockerd_desc"
            echo "               containerd: $containerd_desc  [serviços: docker=${DOCKER_SERVICE_STATE}, containerd=${CONTAINERD_SERVICE_STATE}]"
        fi

        if [ "$CONTAINERS_STATUS" = "ok" ] || [ "$CONTAINERS_STATUS" = "parcial" ]; then
            print_metric "$CONTAINERS_MAX_SEVERITY" "Containers:" \
                "${CONTAINERS_RUNNING:-0} rodando, ${CONTAINERS_STOPPED:-0} parados, ${CONTAINERS_RESTARTING:-0} reiniciando, ${CONTAINERS_UNHEALTHY:-0} unhealthy | sem limite: ${CONTAINERS_NO_MEM_LIMIT:-0} mem, ${CONTAINERS_NO_CPU_LIMIT:-0} CPU"
            [ -n "$CONTAINERS_STATUS_NOTE" ] && [ "$QUIET" = false ] && \
                echo "               ($CONTAINERS_STATUS_NOTE)"
        elif [ -n "$CONTAINERS_STATUS_NOTE" ]; then
            print_metric "UNKNOWN" "Containers:" "$CONTAINERS_STATUS_NOTE"
        fi

        if [ "$QUIET" = false ] && [ "${#CONTAINERS_ALERTS[@]}" -gt 0 ]; then
            local top_n="${MONITOR_TOP_CONTAINERS:-5}"
            echo ""
            echo "  ⚠ Containers com problemas (${#CONTAINERS_ALERTS[@]}):"
            local shown=0 item csev cname cmsg
            for item in "${CONTAINERS_ALERTS[@]}"; do
                [ "$shown" -ge "$top_n" ] && { echo "    ... e mais $(( ${#CONTAINERS_ALERTS[@]} - shown ))"; break; }
                IFS='|' read -r csev cname cmsg <<< "$item"
                printf "    %s %s — %s\n" "$(sev_tag "$csev")" "$cname" "$cmsg"
                ((shown++))
            done
        fi

        if [ "$QUIET" = false ] && [ "${#CONTAINERS_DATA[@]}" -gt 0 ]; then
            local top_n="${MONITOR_TOP_CONTAINERS:-5}"
            echo ""
            echo "  Top memória (containers):"
            monitor_containers_top 19 "$top_n" | while IFS='|' read -r val _ cname _; do
                printf "    %-30s %6s MB\n" "$cname" "$val"
            done
            echo "  Top CPU (containers):"
            monitor_containers_top 13 "$top_n" | while IFS='|' read -r val _ cname _; do
                printf "    %-30s %6s%%\n" "$cname" "$val"
            done
        fi
    fi

    # ─── Laravel / Horizon (M4) ───
    if [ "${MONITOR_LARAVEL_WORKERS_ENABLED:-true}" = "true" ] && [ "$QUIET" = false ]; then
        echo ""
        echo "  ─── Laravel / Horizon ───"
        if [ "${#LARAVEL_WORKERS_DATA[@]}" -eq 0 ]; then
            printf "  %s Nenhum worker Laravel/Horizon detectado.\n" "$(sev_tag INFO)"
        else
            printf "  %s %s worker(s): %s Horizon (%s master), %s queue:work, %s queue:listen, %s scheduler, %s octane\n" \
                "$(sev_tag "$LARAVEL_MAX_SEVERITY")" "$LARAVEL_TOTAL" \
                "$LARAVEL_HORIZON_WORKERS" "$LARAVEL_HORIZON_MASTERS" \
                "$LARAVEL_QUEUE_WORKERS" "$LARAVEL_QUEUE_LISTENERS" \
                "$LARAVEL_SCHEDULERS" "$LARAVEL_OCTANE"
            show_laravel_groups
        fi
    fi

    if [ "$QUIET" = false ] && [ -n "$TOP_CPU_PROCESSES" ]; then
        echo ""
        echo "  Maiores consumidores (CPU):"
        echo "$TOP_CPU_PROCESSES" | head -n 3 | while IFS='|' read -r pid cpu mem etime cmd; do
            printf "    PID %-8s %5s%% CPU  %5s%% MEM  [%s]  %s\n" "$pid" "$cpu" "$mem" "$etime" "$cmd"
        done
        echo "  Maiores consumidores (memória):"
        echo "$TOP_MEM_PROCESSES" | head -n 3 | while IFS='|' read -r pid cpu mem etime cmd; do
            printf "    PID %-8s %5s%% CPU  %5s%% MEM  [%s]  %s\n" "$pid" "$cpu" "$mem" "$etime" "$cmd"
        done
    fi

    if [ "$VERBOSE" = true ]; then
        echo ""
        echo "  ─── Detalhes (verbose) ───"
        echo "  Config carregada:   ${MONITOR_CONFIG_LOADED:-nenhuma (defaults)}"
        echo "  Estado:             $MONITOR_STATE_FILE"
        echo "  Snapshot:           $MONITOR_LAST_CHECK_FILE"
        echo "  Timeout de comando: ${MONITOR_COMMAND_TIMEOUT}s"
        echo "  Intervalo de CPU:   ${MONITOR_CPU_SAMPLE_INTERVAL}s"
        echo "  Thresholds:         mem ${MONITOR_MEM_AVAILABLE_WARNING_MB}/${MONITOR_MEM_AVAILABLE_CRITICAL_MB} MB | swap ${MONITOR_SWAP_WARNING_PERCENT}/${MONITOR_SWAP_CRITICAL_PERCENT}/${MONITOR_SWAP_EMERGENCY_PERCENT}% | load ${MONITOR_LOAD_RATIO_WARNING}/${MONITOR_LOAD_RATIO_CRITICAL}/${MONITOR_LOAD_RATIO_EMERGENCY}"
        echo "                      cpu ${MONITOR_CPU_WARNING_PERCENT}/${MONITOR_CPU_CRITICAL_PERCENT}% | steal ${MONITOR_STEAL_WARNING_PERCENT}/${MONITOR_STEAL_CRITICAL_PERCENT}/${MONITOR_STEAL_EMERGENCY_PERCENT}% | iowait ${MONITOR_IOWAIT_WARNING_PERCENT}/${MONITOR_IOWAIT_CRITICAL_PERCENT}% | disco ${MONITOR_DISK_WARNING_PERCENT}/${MONITOR_DISK_CRITICAL_PERCENT}%"
    fi

    if [ -n "$COLLECT_ERRORS" ]; then
        echo ""
        log_warning "Coletores com falha: ${COLLECT_ERRORS%; }"
    fi

    show_diagnostics_report

    echo ""
    if [ ${#ALERTS[@]} -gt 0 ]; then
        echo "  ⚠ Métricas fora do normal:"
        local item severity metric message
        for item in "${ALERTS[@]}"; do
            IFS='|' read -r severity metric message <<< "$item"
            printf "    %s %s\n" "$(sev_tag "$severity")" "$message"
        done
        echo ""
    fi
    printf "  Severidade geral (provisória): %s\n" "$(sev_tag "$OVERALL_SEVERITY")"

    # Aviso de histórico (apenas quando há problema ou em modo detalhado)
    if [ "${HIST_ENABLED:-false}" = "true" ] && [ "${HIST_WRITE_ERRORS:-0}" -gt 0 ]; then
        log_warning "  Histórico não pôde ser gravado (${HIST_WRITE_ERRORS} erro(s))${HIST_LAST_ERROR:+: $HIST_LAST_ERROR}"
    elif [ "$VERBOSE" = true ] && [ "${HIST_ENABLED:-false}" = "true" ]; then
        echo "  Histórico: métricas=$HIST_METRICS_PERSISTED eventos=$HIST_EVENTS_PERSISTED baseline=$HIST_BASELINE_UPDATED"
    fi

    # Resumo do motor de alertas (quando houve ação)
    if [ "${MONITOR_ALERTS_ENABLED:-true}" = "true" ]; then
        if [ "$ALERTS_DRY_RUN" = "true" ]; then
            show_dryrun_report
        else
            local acted=$(( ALERTS_OPENED + ALERTS_ESCALATED + ALERTS_REMINDED + ALERTS_RECOVERED ))
            if [ "$acted" -gt 0 ]; then
                printf "  Notificações: %s aberto(s), %s escalonado(s), %s recuperado(s)" \
                    "$ALERTS_OPENED" "$ALERTS_ESCALATED" "$ALERTS_RECOVERED"
                [ "$ALERTS_REMINDED" -gt 0 ] && printf ", %s lembrete(s)" "$ALERTS_REMINDED"
                printf " — canal: %s\n" "$ALERTS_CHANNEL"
                [ "$ALERTS_FAILED" -gt 0 ] && log_warning "  Falha no envio de $ALERTS_FAILED notificação(ões); serão retentadas no próximo ciclo"
            fi
        fi
    fi
    echo ""
}

# Relatório de simulação do motor de alertas (dry-run): mostra as transições que
# ocorreriam sem gravar nada no estado real nem enviar notificações.
show_dryrun_report() {
    echo ""
    echo "  ─── Alertas — DRY-RUN ───"
    echo "  Nenhuma alteração foi gravada no estado real."
    echo ""
    if [ "${#ALERTS_DRYRUN_REPORT[@]}" -eq 0 ]; then
        echo "  (nenhuma transição simulada)"
    else
        local line label key sev detail
        for line in "${ALERTS_DRYRUN_REPORT[@]}"; do
            IFS='|' read -r label key sev detail <<< "$line"
            printf "  [%s] %s\n" "$label" "$key"
            printf "      severidade: %s\n" "$sev"
            [ -n "$detail" ] && printf "      %s\n" "$detail"
        done
    fi
    echo ""
    echo "  Estado real preservado:"
    echo "    ${MONITOR_INCIDENT_STATE_FILE:-$MONITOR_STATE_DIR/incidents.state}"
}

################################################################################
# Comandos
################################################################################

exit_code_for_severity() {
    case "$1" in
        INFO) echo 0 ;;
        WARNING) echo 1 ;;
        CRITICAL) echo 2 ;;
        EMERGENCY) echo 3 ;;
        *) echo 4 ;;
    esac
}

cmd_check() {
    if ! monitor_acquire_lock; then
        exit 10
    fi

    run_check_collectors
    evaluate_metrics

    # Motor de alertas (M5): decide e despacha incidentes reutilizando o Discord.
    # Falha aqui nunca derruba o check (o motor é defensivo internamente).
    run_alert_engine

    # Histórico (M7): persiste métricas/eventos/baseline. Falha aqui nunca derruba
    # o check (a biblioteca é defensiva e conta erros internamente).
    monitor_history_persist

    # Snapshot estruturado sempre gravado (consumido por status e marcos futuros)
    monitor_state_set "last_check_epoch" "$(date +%s)"
    monitor_state_save
    build_json > "$MONITOR_LAST_CHECK_FILE.tmp.$$" 2>/dev/null && \
        mv -f "$MONITOR_LAST_CHECK_FILE.tmp.$$" "$MONITOR_LAST_CHECK_FILE" 2>/dev/null || \
        rm -f "$MONITOR_LAST_CHECK_FILE.tmp.$$" 2>/dev/null

    case "$OUTPUT_MODE" in
        json) build_json ;;
        kv)   build_kv ;;
        *)    show_human_report ;;
    esac

    exit "$(exit_code_for_severity "$OVERALL_SEVERITY")"
}

cmd_status() {
    if [ -f "$MONITOR_LAST_CHECK_FILE" ]; then
        cat "$MONITOR_LAST_CHECK_FILE"
    else
        log_warning "Nenhuma verificação anterior encontrada"
        log_info "Execute: $0 check"
        exit 1
    fi
}

monitor_config_candidates() {
    if [ -n "${MONITOR_CONFIG_FILE:-}" ]; then
        printf '%s\n' "$MONITOR_CONFIG_FILE"
    else
        printf '%s\n' \
            "$MONITOR_INSTALL_ROOT/config/monitor.conf" \
            "/etc/vpsguardian/monitor.conf" \
            "/opt/vpsguardian/config/monitor.conf"
    fi
}

monitor_shared_config_candidates() {
    if [ -n "${VPSGUARDIAN_SHARED_CONFIG_FILE:-}" ]; then
        printf '%s\n' "$VPSGUARDIAN_SHARED_CONFIG_FILE"
    else
        printf '%s\n' \
            "$MONITOR_INSTALL_ROOT/config/backup-destinations.conf" \
            "/etc/vpsguardian/backup-destinations.conf" \
            "/opt/vpsguardian/config/backup-destinations.conf"
    fi
}

cmd_config_check() {
    local errors=0 warnings=0 file active_monitor=0 active_shared=0
    local -A seen=()

    echo "VPS Guardian — config-check"
    echo "  instalação: $MONITOR_INSTALL_ROOT"
    echo "  monitor: ${MONITOR_CONFIG_LOADED:-defaults internos}"
    echo "  compartilhada: ${MONITOR_SHARED_CONFIG_LOADED:-não encontrada}"

    while IFS= read -r file; do
        [ -n "$file" ] || continue
        [ -n "${seen[$file]:-}" ] && continue
        seen["$file"]=1
        if [ -f "$file" ]; then
            active_monitor=$((active_monitor + 1))
            if ! bash -n "$file"; then
                echo "  ERRO: sintaxe inválida em $file"
                errors=$((errors + 1))
            fi
            if grep -Eq '^[[:space:]]*(WEBHOOK_URL|WEBHOOK_DISCORD|COOLIFY_API_(URL|TOKEN)|NOTIFICATION_EMAIL)=' "$file"; then
                echo "  ERRO: credencial/configuração compartilhada duplicada em $file"
                errors=$((errors + 1))
            fi
            if grep -Eq '^[[:space:]]*(MEMORY_THRESHOLD|SWAP_THRESHOLD|LOAD_THRESHOLD|DISK_THRESHOLD)=' "$file"; then
                echo "  AVISO: variável antiga encontrada em $file; migre para MONITOR_*"
                warnings=$((warnings + 1))
            fi
        fi
    done < <(monitor_config_candidates)

    seen=()
    while IFS= read -r file; do
        [ -n "$file" ] || continue
        [ -n "${seen[$file]:-}" ] && continue
        seen["$file"]=1
        if [ -f "$file" ]; then
            active_shared=$((active_shared + 1))
            if ! bash -n "$file"; then
                echo "  ERRO: sintaxe inválida em $file"
                errors=$((errors + 1))
            fi
        fi
    done < <(monitor_shared_config_candidates)

    if [ "$active_monitor" -gt 1 ]; then
        echo "  ERRO: $active_monitor arquivos monitor.conf ativos (configuração concorrente)"
        errors=$((errors + 1))
    fi
    if [ "$active_shared" -gt 1 ]; then
        echo "  ERRO: $active_shared configurações compartilhadas ativas"
        errors=$((errors + 1))
    fi

    local name value
    for name in MONITOR_COMMAND_TIMEOUT MONITOR_MEM_AVAILABLE_WARNING_MB \
                MONITOR_MEM_AVAILABLE_CRITICAL_MB MONITOR_SWAP_WARNING_PERCENT \
                MONITOR_SWAP_CRITICAL_PERCENT MONITOR_LOAD_RATIO_WARNING \
                MONITOR_LOAD_RATIO_CRITICAL MONITOR_CPU_WARNING_PERCENT \
                MONITOR_CPU_CRITICAL_PERCENT MONITOR_DISK_WARNING_PERCENT \
                MONITOR_DISK_CRITICAL_PERCENT; do
        value="${!name:-}"
        if ! monitor_is_number "$value"; then
            echo "  ERRO: $name deve ser numérico (valor: ${value:-vazio})"
            errors=$((errors + 1))
        fi
    done

    for name in MONITOR_ALERTS_ENABLED MONITOR_ALERT_DISCORD_ENABLED \
                MONITOR_ALERT_REMINDERS_ENABLED MONITOR_DOCKER_REQUIRED \
                MONITOR_HISTORY_ENABLED MONITOR_CORRELATION_ENABLED; do
        value="${!name:-true}"
        case "$value" in
            true|false) ;;
            *) echo "  ERRO: $name deve ser true ou false (valor: $value)"; errors=$((errors + 1)) ;;
        esac
    done

    if [ "$errors" -gt 0 ]; then
        echo "  resultado: INVÁLIDO ($errors erro(s), $warnings aviso(s))"
        exit 2
    fi
    echo "  resultado: VÁLIDO ($warnings aviso(s); chaves ausentes herdam defaults seguros)"
    exit 0
}

cmd_self_check() {
    local failures=0 warnings=0 file unit_dir install_version="1.0.0"
    local required_libs=(common collectors docker containers laravel-workers alerts correlation history emergency)

    echo "VPS Guardian — self-check"
    echo "  caminho instalado: $MONITOR_INSTALL_ROOT"

    if [ -r "$MONITOR_INSTALL_ROOT/.install.conf" ]; then
        install_version=$(awk -F= '$1=="VPSGUARDIAN_VERSION" {gsub(/\"/,"",$2); print $2}' \
            "$MONITOR_INSTALL_ROOT/.install.conf" 2>/dev/null)
        install_version="${install_version:-1.0.0}"
    fi
    echo "  versão VPS Guardian: $install_version"
    echo "  versão monitor/schema: $MONITOR_VERSION/$MONITOR_SCHEMA_VERSION"

    if [ ! -x "$MONITOR_INSTALL_ROOT/monitor/vps-monitor.sh" ]; then
        echo "  ERRO: executável do monitor ausente"
        failures=$((failures + 1))
    fi
    for file in "${required_libs[@]}"; do
        if [ ! -r "$MONITOR_INSTALL_ROOT/lib/monitor-$file.sh" ]; then
            echo "  ERRO: biblioteca ausente: monitor-$file.sh"
            failures=$((failures + 1))
        fi
    done

    unit_dir="${MONITOR_SYSTEMD_DIR:-/etc/systemd/system}"
    for file in vpsguardian-monitor.service vpsguardian-monitor.timer; do
        if [ ! -r "$unit_dir/$file" ]; then
            echo "  ERRO: unit ausente: $unit_dir/$file"
            failures=$((failures + 1))
        fi
    done
    if [ -r "$unit_dir/vpsguardian-monitor.service" ] && \
       ! grep -q '^ExecStart=/usr/local/bin/vps-guardian monitor check --quiet$' \
           "$unit_dir/vpsguardian-monitor.service"; then
        echo "  ERRO: ExecStart não segue o wrapper da instalação real"
        failures=$((failures + 1))
    fi

    if command -v systemctl >/dev/null 2>&1 && [ -z "${MONITOR_SELF_CHECK_SKIP_SYSTEMCTL:-}" ]; then
        if systemctl is-enabled vpsguardian-monitor.timer >/dev/null 2>&1; then
            echo "  timer: habilitado"
        else
            echo "  AVISO: timer não está habilitado"
            warnings=$((warnings + 1))
        fi
    else
        echo "  timer: validação via systemctl indisponível/ignorada"
    fi

    if [ -d "$MONITOR_STATE_DIR" ]; then
        echo "  estado: $MONITOR_STATE_DIR"
        [ -w "$MONITOR_STATE_DIR" ] || { echo "  ERRO: estado sem permissão de escrita"; failures=$((failures + 1)); }
    else
        echo "  ERRO: diretório de estado ausente: $MONITOR_STATE_DIR"
        failures=$((failures + 1))
    fi
    for file in "$MONITOR_STATE_DIR/history" "$MONITOR_STATE_DIR/incidents"; do
        [ -d "$file" ] || { echo "  ERRO: diretório mutável ausente: $file"; failures=$((failures + 1)); }
    done

    if [ -f "$MONITOR_LAST_CHECK_FILE" ]; then
        echo "  última execução: $(date -r "$MONITOR_LAST_CHECK_FILE" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo desconhecida)"
    else
        echo "  última execução: ainda não registrada"
    fi
    echo "  Discord compartilhado: $([ -n "${WEBHOOK_URL:-}" ] && echo configurado || echo desabilitado)"
    echo "  Coolify API compartilhada: $([ "${COOLIFY_API_ENABLED:-false}" = true ] && echo habilitada || echo desabilitada)"

    if [ "$failures" -gt 0 ]; then
        echo "  resultado: FALHA ($failures erro(s), $warnings aviso(s))"
        exit 2
    fi
    echo "  resultado: OK ($warnings aviso(s))"
    exit 0
}

cmd_not_implemented() {
    local cmd="$1" marco="$2"
    log_warning "Comando '$cmd' ainda não implementado (previsto para o marco $marco)"
    log_info "Consulte docs/MARCOS-MONITOR-PREVENTIVO.md"
    exit 65
}

# Tabela detalhada de containers (subcomando containers)
cmd_containers() {
    if ! monitor_acquire_lock; then
        exit 10
    fi

    collect_host_info || true
    collect_docker || true
    collect_containers || true
    monitor_state_save

    if [ "$OUTPUT_MODE" = "json" ]; then
        printf '{\n  "collected_at": %s,\n  "containers_summary": {"status": %s, "total": %s, "running": %s},\n  "containers": [%s]\n}\n' \
            "$(jv "$(date -Iseconds)")" "$(jv "$CONTAINERS_STATUS")" \
            "$(jv "$CONTAINERS_TOTAL")" "$(jv "$CONTAINERS_RUNNING")" \
            "$(monitor_containers_json)"
        exit 0
    fi

    log_section "CONTAINERS — CONSUMO, LIMITES E RESTARTS"
    echo "  Docker: ${DOCKER_STATUS:-n/d} | containers: ${CONTAINERS_TOTAL:-0} (${CONTAINERS_RUNNING:-0} rodando)"
    [ -n "$CONTAINERS_STATUS_NOTE" ] && echo "  Nota: $CONTAINERS_STATUS_NOTE"
    echo ""

    if [ "${#CONTAINERS_DATA[@]}" -eq 0 ]; then
        log_info "Nenhum container para exibir"
        exit 0
    fi

    printf "  %-11s %-28s %8s %9s %9s %7s %5s %-9s %s\n" \
        "SEVERIDADE" "NOME" "CPU%" "MEM(MB)" "LIM(MB)" "MEM%" "RST" "HEALTH" "COOLIFY"
    local rec f
    for rec in "${CONTAINERS_DATA[@]}"; do
        local -a F
        IFS='|' read -r -a F <<< "$rec"
        printf "  %-11s %-28.28s %8s %9s %9s %7s %5s %-9s %s\n" \
            "${F[23]}" "${F[1]}" "${F[12]:-n/d}" "${F[18]:-n/d}" \
            "$([ "${F[19]}" = "0" ] && echo "sem" || echo "${F[19]:-n/d}")" \
            "${F[21]:-n/d}" "${F[8]:-0}" "${F[5]}" \
            "${F[26]:-${F[24]:--}}"
    done
    echo ""
    echo "  RST = total de restarts | LIM = limite de memória | sem = sem limite"
    exit 0
}

# Teste manual do canal de alertas (subcomando test-alert)
cmd_test_alert() {
    [ "$CLI_DRY_RUN" = true ] && MONITOR_ALERT_DRY_RUN=true

    log_info "Enviando alerta de teste pelo canal Discord configurado (WEBHOOK_URL)..."
    local result
    result=$(monitor_alert_test)

    case "$result" in
        SUCCESS)
            log_success "Alerta de teste enviado com sucesso (canal: Discord)"
            exit 0 ;;
        DISABLED)
            if [ "${MONITOR_ALERT_DRY_RUN:-false}" = "true" ]; then
                log_info "Dry-run: nenhuma notificação enviada"
            elif [ "${MONITOR_ALERT_DISCORD_ENABLED:-true}" != "true" ]; then
                log_warning "Canal Discord desabilitado (MONITOR_ALERT_DISCORD_ENABLED=false)"
            else
                log_warning "Nenhum webhook Discord configurado (defina WEBHOOK_URL em backup-destinations.conf)"
            fi
            exit 0 ;;
        *)
            log_error "Falha ao enviar o alerta de teste (verifique conectividade/webhook)"
            exit 1 ;;
    esac
}

# Relatório de histórico (subcomando report — M7)
cmd_report() {
    monitor_history_init

    # Resolve o período: --last tem precedência; senão --from/--to; senão 24h
    local now; now=$(date +%s)
    if [ -n "$REPORT_LAST" ]; then
        local secs; secs=$(monitor_history_parse_duration "$REPORT_LAST") || {
            log_error "Intervalo inválido: $REPORT_LAST (use ex.: 1h, 24h, 7d, 30m)"; exit 64; }
        REPORT_TO="$now"; REPORT_FROM="$((now - secs))"
    elif [ -n "$REPORT_FROM" ]; then
        local fe te
        fe=$(date -d "$REPORT_FROM" +%s 2>/dev/null) || { log_error "Data --from inválida"; exit 64; }
        REPORT_FROM="$fe"
        if [ -n "$REPORT_TO" ]; then
            te=$(date -d "$REPORT_TO" +%s 2>/dev/null) || { log_error "Data --to inválida"; exit 64; }
            REPORT_TO="$te"
        else
            REPORT_TO="$now"
        fi
    else
        REPORT_TO="$now"; REPORT_FROM="$((now - 86400))"
    fi

    monitor_history_report
    exit 0
}

# Coleta estruturada leve para o resumo/diagnóstico do pacote (reusa M1–M6).
# Guardada por deadline; timeouts de emergência; amostragem de CPU reduzida.
emergency_structured_collection() {
    local left; left=$(_em_time_left)
    [ "$left" -le 3 ] && return 0
    local old_cpu="$MONITOR_CPU_SAMPLE_INTERVAL"
    MONITOR_CPU_SAMPLE_INTERVAL="${MONITOR_EMERGENCY_CPU_SAMPLE:-0}"
    MONITOR_ALERT_DRY_RUN=true   # nunca notifica/persiste durante a coleta estruturada
    collect_host_info 2>/dev/null || true
    collect_load 2>/dev/null || true
    collect_memory 2>/dev/null || true
    collect_swap 2>/dev/null || true
    collect_cpu 2>/dev/null || true
    collect_cgroup 2>/dev/null || true
    collect_disk 2>/dev/null || true
    collect_docker 2>/dev/null || true
    collect_containers 2>/dev/null || true
    collect_laravel_workers 2>/dev/null || true
    evaluate_metrics 2>/dev/null || true
    monitor_correlation_compute 2>/dev/null || true
    MONITOR_CPU_SAMPLE_INTERVAL="$old_cpu"
}

# Notificação curta do pacote (reutiliza o canal do M5; nunca anexa arquivos)
emergency_notify() {
    [ "$EM_NOTIFY" = true ] || { EM_NOTIFY_RESULT="skipped"; return 0; }
    local srv="${MONITOR_SERVER_NAME:-${HOST_HOSTNAME:-$(hostname 2>/dev/null)}}"
    local diag="Nenhum diagnóstico com confiança suficiente"
    [ -n "$EM_MAIN_DIAG" ] && diag="$EM_MAIN_DIAG"
    local body="Servidor: $srv\nIncidente: $EM_ID\nSeveridade: $EM_SEVERITY\nDiagnóstico provável: $diag\nColeta: ${EM_STATUS} (${EM_OK} ok, ${EM_FAIL} falhas, ${EM_TIMEOUT} timeouts)\nDiretório local: $EM_DIR"
    EM_NOTIFY_RESULT=$(monitor_alert_channel_send error "🆘 VPS Guardian — Pacote de emergência gerado" "$body")
}

cmd_emergency() {
    monitor_emergency_init_config

    # Validação de argumentos (exit 3)
    if [ -n "$EM_CLI_DEADLINE" ]; then
        [[ "$EM_CLI_DEADLINE" =~ ^[0-9]+$ ]] && [ "$EM_CLI_DEADLINE" -ge 5 ] || {
            log_error "Deadline inválido: $EM_CLI_DEADLINE (inteiro >= 5)"; exit 3; }
        EM_DEADLINE="$EM_CLI_DEADLINE"
    else
        EM_DEADLINE="$MONITOR_EMERGENCY_DEADLINE_SECONDS"
    fi
    if [ -n "$EM_OUTPUT_DIR" ]; then
        monitor_emergency_validate_output_dir "$EM_OUTPUT_DIR" || {
            log_error "Diretório de saída inválido/inseguro: '$EM_OUTPUT_DIR'"; exit 3; }
    fi

    # Lock próprio (exit 4 se já houver emergência ativa)
    monitor_emergency_lock
    if [ $? -eq 4 ]; then
        log_warning "Emergência já em execução; incidente atual: $EM_DIR"
        [ "$OUTPUT_MODE" = "json" ] && printf '{"emergency":{"status":"ALREADY_RUNNING","directory":"%s"}}\n' "$EM_DIR"
        exit 4
    fi
    trap 'monitor_emergency_unlock' EXIT

    # Preparação do diretório (exit 2 se falhar o mínimo)
    if ! monitor_emergency_prepare; then
        log_error "Não foi possível criar o diretório de incidente"
        exit 2
    fi

    # Formato efetivo: --format tem precedência; --json/--kv também aceitos
    local EM_FMT="human"
    case "$OUTPUT_MODE" in json) EM_FMT=json ;; kv) EM_FMT=kv ;; esac
    case "$REPORT_FORMAT" in json) EM_FMT=json ;; kv) EM_FMT=kv ;; esac

    local quiet=false; [ "$EM_FMT" != "human" ] && quiet=true
    _emp() { [ "$quiet" = true ] || echo "$*"; }

    _emp "[1/8] Coletando estado do host..."
    emergency_structured_collection
    _emp "[2/8] Coletando processos..."
    # (host + processos coletados dentro de collect_all/P0)
    _emp "[3/8] Verificando Docker e containerd..."
    _emp "[4/8] Coletando workers Laravel..."
    _emp "[5/8] Consultando histórico..."
    _emp "[6/8] Gerando diagnóstico..."
    monitor_emergency_collect_all
    _emp "[7/8] Sanitizando pacote..."
    _emp "[8/8] Finalizando manifesto..."

    emergency_notify

    # Saída
    case "$EM_FMT" in
        json) emergency_json ;;
        kv)   emergency_kv ;;
        *)    emergency_human ;;
    esac

    monitor_emergency_unlock
    trap - EXIT

    # Exit codes
    case "$EM_STATUS" in
        COMPLETE) exit 0 ;;
        MINIMAL)  exit 2 ;;
        *)        exit 1 ;;   # PARTIAL utilizável
    esac
}

emergency_human() {
    echo ""
    echo "Pacote de emergência criado:"
    echo "  $EM_DIR/"
    if [ -n "$EM_ARCHIVE" ]; then
        echo ""; echo "Arquivo compactado:"; echo "  $EM_ARCHIVE"
        echo "SHA-256:"; echo "  $EM_ARCHIVE_SHA"
    fi
    echo ""
    echo "Coletas:"
    echo "  $EM_OK concluídas"
    echo "  $EM_FAIL falharam"
    echo "  $EM_TIMEOUT excederam timeout"
    echo "  $EM_SKIPPED puladas (deadline)"
    echo ""
    echo "Diagnóstico principal:"
    if [ -n "$EM_MAIN_DIAG" ]; then
        echo "  $EM_MAIN_DIAG"
    else
        echo "  Nenhum diagnóstico com confiança suficiente"
    fi
    [ "$EM_NOTIFY" = true ] && echo "  Notificação: $EM_NOTIFY_RESULT"
}

emergency_kv() {
    cat <<EOF
emergency.incident_id=$EM_ID
emergency.status=$EM_STATUS
emergency.severity=$EM_SEVERITY
emergency.directory=$EM_DIR
emergency.archive=$EM_ARCHIVE
emergency.duration_seconds=$(_em_elapsed)
emergency.commands_successful=$EM_OK
emergency.commands_failed=$EM_FAIL
emergency.commands_timed_out=$EM_TIMEOUT
emergency.main_diagnosis_key=$EM_MAIN_DIAG
emergency.notification_result=$EM_NOTIFY_RESULT
EOF
}

emergency_json() {
    cat <<EOF
{
  "emergency": {
    "incident_id": $(jv "$EM_ID"),
    "status": $(jv "$EM_STATUS"),
    "severity": $(jv "$EM_SEVERITY"),
    "started_at": ${EM_START:-0},
    "finished_at": $(date +%s),
    "duration_seconds": $(_em_elapsed),
    "deadline_seconds": ${EM_DEADLINE:-45},
    "directory": $(jv "$EM_DIR"),
    "archive": $(jv "$EM_ARCHIVE"),
    "archive_sha256": $(jv "$EM_ARCHIVE_SHA"),
    "commands_successful": ${EM_OK:-0},
    "commands_failed": ${EM_FAIL:-0},
    "commands_timed_out": ${EM_TIMEOUT:-0},
    "commands_skipped": ${EM_SKIPPED:-0},
    "main_diagnosis_key": $(jv "$EM_MAIN_DIAG"),
    "notification_result": $(jv "$EM_NOTIFY_RESULT")
  }
}
EOF
}

case "$ACTION" in
    check)      cmd_check ;;
    status)     cmd_status ;;
    containers) cmd_containers ;;
    emergency)  cmd_emergency ;;
    report)     cmd_report ;;
    test-alert) cmd_test_alert ;;
    config-check) cmd_config_check ;;
    self-check) cmd_self_check ;;
esac
