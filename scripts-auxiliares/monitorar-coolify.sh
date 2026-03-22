#!/bin/bash
################################################################################
# Script: monitorar-coolify.sh
# Propósito: Monitorar status dos recursos do Coolify via API
# Uso: ./monitorar-coolify.sh [--notify] [--cron] [--dashboard]
#
# Funcionalidades:
#   - Verificar health de applications, databases e services
#   - Enviar notificações Discord quando há problemas
#   - Exibir dashboard de status
#   - Executar via cron para monitoramento contínuo
#
# Versão: 1.0.0
################################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Carregar bibliotecas
source "$SCRIPT_DIR/../lib/common.sh" 2>/dev/null || {
    log_info() { echo "[ INFO ] $*"; }
    log_success() { echo "[ OK ] $*"; }
    log_error() { echo "[ ERRO ] $*"; }
    log_warning() { echo "[ AVISO ] $*"; }
    log_section() { echo ""; echo "========== $* =========="; echo ""; }
}

# Carregar configurações
if [ -f "/opt/vpsguardian/config/backup-destinations.conf" ]; then
    source "/opt/vpsguardian/config/backup-destinations.conf" 2>/dev/null
elif [ -f "$SCRIPT_DIR/../config/backup-destinations.conf" ]; then
    source "$SCRIPT_DIR/../config/backup-destinations.conf" 2>/dev/null
fi

# Carregar biblioteca de notificações
source "$SCRIPT_DIR/../lib/notificacoes.sh" 2>/dev/null || true

# Carregar biblioteca de API do Coolify
source "$SCRIPT_DIR/../lib/coolify-api.sh" 2>/dev/null || {
    log_error "Biblioteca coolify-api.sh não encontrada"
    exit 1
}

# Configuração
NOTIFY_MODE=false
CRON_MODE=false
DASHBOARD_MODE=false
STATUS_FILE="/tmp/coolify-status-$(date +%Y%m%d).json"
LAST_STATUS_FILE="/var/lib/vpsguardian/last-coolify-status.json"

# Parse argumentos
while [[ $# -gt 0 ]]; do
    case $1 in
        --notify)
            NOTIFY_MODE=true
            shift
            ;;
        --cron)
            CRON_MODE=true
            NOTIFY_MODE=true  # Cron sempre notifica
            shift
            ;;
        --dashboard)
            DASHBOARD_MODE=true
            shift
            ;;
        -h|--help)
            cat << 'EOF'
MONITORAR COOLIFY - VPS Guardian

USO:
  ./monitorar-coolify.sh [OPÇÕES]

OPÇÕES:
  --notify      Enviar notificações Discord se houver problemas
  --cron        Modo cron (silencioso, apenas notifica problemas)
  --dashboard   Exibir dashboard de status
  -h, --help    Mostrar esta ajuda

EXEMPLOS:
  # Ver dashboard de status
  ./monitorar-coolify.sh --dashboard

  # Monitorar e notificar problemas
  ./monitorar-coolify.sh --notify

  # Para usar no cron (a cada 5 minutos)
  */5 * * * * /opt/vpsguardian/scripts-auxiliares/monitorar-coolify.sh --cron

REQUISITOS:
  - API do Coolify configurada (scripts-auxiliares/configurar-coolify-api.sh)
  - Webhook Discord configurado (para notificações)

EOF
            exit 0
            ;;
        *)
            shift
            ;;
    esac
done

# Se nenhum modo especificado, mostrar dashboard
if [ "$NOTIFY_MODE" = false ] && [ "$CRON_MODE" = false ] && [ "$DASHBOARD_MODE" = false ]; then
    DASHBOARD_MODE=true
fi

################################################################################
# Funções
################################################################################

# Verificar se API está disponível
check_api() {
    if ! coolify_api_available 2>/dev/null; then
        if [ "$CRON_MODE" = false ]; then
            log_error "API do Coolify não está disponível"
            log_info "Configure com: scripts-auxiliares/configurar-coolify-api.sh"
        fi
        return 1
    fi
    return 0
}

# Coletar status de todos os recursos
collect_status() {
    local apps_json dbs_json services_json

    apps_json=$(coolify_list_applications 2>/dev/null || echo "[]")
    dbs_json=$(coolify_list_databases 2>/dev/null || echo "[]")
    services_json=$(coolify_list_services 2>/dev/null || echo "[]")

    # Criar JSON de status
    cat > "$STATUS_FILE" <<EOF
{
    "timestamp": "$(date -Iseconds)",
    "hostname": "$(hostname)",
    "applications": $apps_json,
    "databases": $dbs_json,
    "services": $services_json
}
EOF
}

# Contar recursos por status
count_by_status() {
    local json_file="$1"
    local resource_type="$2"

    local total running stopped other

    total=$(jq ".$resource_type | length" "$json_file" 2>/dev/null || echo 0)
    running=$(jq "[.$resource_type[] | select(.status == \"running\")] | length" "$json_file" 2>/dev/null || echo 0)
    stopped=$(jq "[.$resource_type[] | select(.status == \"stopped\" or .status == \"exited\")] | length" "$json_file" 2>/dev/null || echo 0)
    other=$((total - running - stopped))

    echo "$total|$running|$stopped|$other"
}

# Listar recursos com problemas
list_problems() {
    local json_file="$1"
    local problems=""

    # Applications não running
    local app_problems
    app_problems=$(jq -r '.applications[] | select(.status != "running") | "App: \(.name) (\(.status))"' "$json_file" 2>/dev/null)
    [ -n "$app_problems" ] && problems="$problems$app_problems\n"

    # Databases não running
    local db_problems
    db_problems=$(jq -r '.databases[] | select(.status != "running") | "DB: \(.name) (\(.status))"' "$json_file" 2>/dev/null)
    [ -n "$db_problems" ] && problems="$problems$db_problems\n"

    # Services não running
    local svc_problems
    svc_problems=$(jq -r '.services[] | select(.status != "running") | "Svc: \(.name) (\(.status))"' "$json_file" 2>/dev/null)
    [ -n "$svc_problems" ] && problems="$problems$svc_problems\n"

    echo -e "$problems"
}

# Verificar se houve mudança de status
check_status_change() {
    if [ ! -f "$LAST_STATUS_FILE" ]; then
        return 0  # Primeira execução, considerar como mudança
    fi

    local current_problems=$(list_problems "$STATUS_FILE" | sort)
    local last_problems=$(list_problems "$LAST_STATUS_FILE" | sort)

    if [ "$current_problems" != "$last_problems" ]; then
        return 0  # Houve mudança
    fi

    return 1  # Sem mudança
}

# Enviar notificação de problemas
send_problem_notification() {
    local problems="$1"
    local app_stats="$2"
    local db_stats="$3"
    local svc_stats="$4"

    if [ -z "$WEBHOOK_URL" ]; then
        return 0
    fi

    local app_running=$(echo "$app_stats" | cut -d'|' -f2)
    local app_total=$(echo "$app_stats" | cut -d'|' -f1)
    local db_running=$(echo "$db_stats" | cut -d'|' -f2)
    local db_total=$(echo "$db_stats" | cut -d'|' -f1)
    local svc_running=$(echo "$svc_stats" | cut -d'|' -f2)
    local svc_total=$(echo "$svc_stats" | cut -d'|' -f1)

    # Escapar caracteres especiais para JSON
    local escaped_problems=$(echo "$problems" | sed 's/"/\\"/g' | tr '\n' ' ')

    send_discord_detailed \
        "⚠️ Coolify - Recursos com Problemas" \
        "Alguns recursos não estão running" \
        "warning" \
        "Apps|$app_running/$app_total running" \
        "DBs|$db_running/$db_total running" \
        "Services|$svc_running/$svc_total running" \
        "Problemas|$escaped_problems|false"
}

# Enviar notificação de recuperação
send_recovery_notification() {
    local app_stats="$1"
    local db_stats="$2"
    local svc_stats="$3"

    if [ -z "$WEBHOOK_URL" ]; then
        return 0
    fi

    local app_total=$(echo "$app_stats" | cut -d'|' -f1)
    local db_total=$(echo "$db_stats" | cut -d'|' -f1)
    local svc_total=$(echo "$svc_stats" | cut -d'|' -f1)

    send_discord_simple \
        "✅ Coolify - Todos os Recursos OK" \
        "Todos os $app_total apps, $db_total databases e $svc_total services estão running" \
        "success"
}

# Exibir dashboard
show_dashboard() {
    clear 2>/dev/null || true

    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║             COOLIFY MONITORING DASHBOARD                     ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
    echo "  Servidor: $(hostname)"
    echo "  Data/Hora: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "  API URL: $COOLIFY_API_URL"
    echo ""

    # Coletar status
    collect_status

    # Estatísticas
    local app_stats=$(count_by_status "$STATUS_FILE" "applications")
    local db_stats=$(count_by_status "$STATUS_FILE" "databases")
    local svc_stats=$(count_by_status "$STATUS_FILE" "services")

    local app_total=$(echo "$app_stats" | cut -d'|' -f1)
    local app_running=$(echo "$app_stats" | cut -d'|' -f2)
    local app_stopped=$(echo "$app_stats" | cut -d'|' -f3)

    local db_total=$(echo "$db_stats" | cut -d'|' -f1)
    local db_running=$(echo "$db_stats" | cut -d'|' -f2)
    local db_stopped=$(echo "$db_stats" | cut -d'|' -f3)

    local svc_total=$(echo "$svc_stats" | cut -d'|' -f1)
    local svc_running=$(echo "$svc_stats" | cut -d'|' -f2)
    local svc_stopped=$(echo "$svc_stats" | cut -d'|' -f3)

    echo "  ┌─────────────────────────────────────────────────────────┐"
    echo "  │  RESUMO                                                 │"
    echo "  ├─────────────────────────────────────────────────────────┤"
    printf "  │  %-15s %3s total │ %3s running │ %3s stopped │\n" "Applications" "$app_total" "$app_running" "$app_stopped"
    printf "  │  %-15s %3s total │ %3s running │ %3s stopped │\n" "Databases" "$db_total" "$db_running" "$db_stopped"
    printf "  │  %-15s %3s total │ %3s running │ %3s stopped │\n" "Services" "$svc_total" "$svc_running" "$svc_stopped"
    echo "  └─────────────────────────────────────────────────────────┘"
    echo ""

    # Listar recursos
    echo "  APPLICATIONS:"
    if [ "$app_total" -gt 0 ]; then
        jq -r '.applications[] | "    \(if .status == "running" then "✓" else "✗" end) \(.name) (\(.status))"' "$STATUS_FILE" 2>/dev/null
    else
        echo "    (nenhuma)"
    fi
    echo ""

    echo "  DATABASES:"
    if [ "$db_total" -gt 0 ]; then
        jq -r '.databases[] | "    \(if .status == "running" then "✓" else "✗" end) \(.name) [\(.type)] (\(.status))"' "$STATUS_FILE" 2>/dev/null
    else
        echo "    (nenhum)"
    fi
    echo ""

    echo "  SERVICES:"
    if [ "$svc_total" -gt 0 ]; then
        jq -r '.services[] | "    \(if .status == "running" then "✓" else "✗" end) \(.name) (\(.status))"' "$STATUS_FILE" 2>/dev/null
    else
        echo "    (nenhum)"
    fi
    echo ""

    # Verificar problemas
    local problems=$(list_problems "$STATUS_FILE")
    if [ -n "$problems" ]; then
        echo "  ⚠️  RECURSOS COM PROBLEMAS:"
        echo "$problems" | while read -r line; do
            [ -n "$line" ] && echo "    $line"
        done
        echo ""
    else
        echo "  ✅ Todos os recursos estão saudáveis!"
        echo ""
    fi
}

################################################################################
# Main
################################################################################

# Verificar API
if ! check_api; then
    exit 1
fi

# Modo Dashboard
if [ "$DASHBOARD_MODE" = true ]; then
    show_dashboard
    exit 0
fi

# Modo Cron/Notify
if [ "$CRON_MODE" = true ] || [ "$NOTIFY_MODE" = true ]; then
    # Criar diretório para status se não existir
    mkdir -p "$(dirname "$LAST_STATUS_FILE")" 2>/dev/null

    # Coletar status atual
    collect_status

    # Estatísticas
    app_stats=$(count_by_status "$STATUS_FILE" "applications")
    db_stats=$(count_by_status "$STATUS_FILE" "databases")
    svc_stats=$(count_by_status "$STATUS_FILE" "services")

    # Verificar problemas
    problems=$(list_problems "$STATUS_FILE")

    if [ -n "$problems" ]; then
        # Há problemas
        if [ "$CRON_MODE" = false ]; then
            log_warning "Recursos com problemas detectados:"
            echo "$problems" | while read -r line; do
                [ -n "$line" ] && log_warning "  $line"
            done
        fi

        # Notificar se houve mudança de status
        if check_status_change; then
            send_problem_notification "$problems" "$app_stats" "$db_stats" "$svc_stats"
            if [ "$CRON_MODE" = false ]; then
                log_info "Notificação enviada via Discord"
            fi
        fi
    else
        # Tudo OK
        if [ "$CRON_MODE" = false ]; then
            log_success "Todos os recursos estão saudáveis"
        fi

        # Se havia problemas antes e agora está OK, notificar recuperação
        if [ -f "$LAST_STATUS_FILE" ]; then
            last_problems=$(list_problems "$LAST_STATUS_FILE")
            if [ -n "$last_problems" ]; then
                send_recovery_notification "$app_stats" "$db_stats" "$svc_stats"
                if [ "$CRON_MODE" = false ]; then
                    log_info "Notificação de recuperação enviada"
                fi
            fi
        fi
    fi

    # Salvar status atual para próxima comparação
    cp "$STATUS_FILE" "$LAST_STATUS_FILE" 2>/dev/null

    # Limpar arquivo temporário
    rm -f "$STATUS_FILE" 2>/dev/null

    exit 0
fi
