#!/bin/bash
################################################################################
# Script: notificar-updates.sh
# Propósito: Enviar notificações de updates do sistema via Discord/Slack
# Uso: Chamado automaticamente pelo unattended-upgrades ou manualmente
################################################################################

# Carregar configurações
NOTIF_CONFIG="/opt/vpsguardian/config/backup-destinations.conf"
if [ -f "$NOTIF_CONFIG" ]; then
    source "$NOTIF_CONFIG"
fi

# Carregar biblioteca de notificações (se disponível)
LIB_NOTIF="/opt/vpsguardian/lib/notificacoes.sh"
if [ -f "$LIB_NOTIF" ]; then
    source "$LIB_NOTIF"
fi

# Log de unattended-upgrades
UPGRADE_LOG="/var/log/unattended-upgrades/unattended-upgrades.log"
DPKG_LOG="/var/log/dpkg.log"

# Cores Discord
COLOR_SUCCESS=3066993    # Verde
COLOR_WARNING=16776960   # Amarelo
COLOR_INFO=3447003       # Azul

# Obter informações do servidor
HOSTNAME=$(hostname)
SERVER_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

### ========== FUNÇÕES ==========

# Enviar notificação ao Discord
send_discord_update() {
    local title="$1"
    local description="$2"
    local color="${3:-$COLOR_INFO}"
    local packages="$4"

    [ -z "$WEBHOOK_URL" ] && return 0
    [[ ! "$WEBHOOK_URL" == *"discord.com"* ]] && return 0

    # Construir campos se houver pacotes
    local fields=""
    if [ -n "$packages" ]; then
        # Escapar caracteres especiais para JSON
        packages=$(echo "$packages" | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')
        fields=",\"fields\": [{\"name\": \"Pacotes Atualizados\", \"value\": \"\`\`\`$packages\`\`\`\", \"inline\": false}]"
    fi

    local payload=$(cat <<EOF
{
    "embeds": [{
        "title": "$title",
        "description": "$description",
        "color": $color,
        "footer": {"text": "$HOSTNAME ($SERVER_IP) • $TIMESTAMP"}
        $fields
    }]
}
EOF
)

    curl -s -X POST -H "Content-Type: application/json" -d "$payload" "$WEBHOOK_URL" >/dev/null 2>&1
}

# Obter pacotes atualizados recentemente (últimas 24h)
get_recent_updates() {
    local hours="${1:-24}"
    local since=$(date -d "$hours hours ago" '+%Y-%m-%d %H:%M:%S')

    if [ -f "$DPKG_LOG" ]; then
        # Extrair upgrades do dpkg.log
        grep "upgrade" "$DPKG_LOG" 2>/dev/null | \
            awk -v since="$since" '$1" "$2 >= since' | \
            awk '{print $4}' | \
            head -20
    fi
}

# Verificar se houve updates recentes
check_recent_updates() {
    local updates=$(get_recent_updates 1)  # Última hora

    if [ -n "$updates" ]; then
        local count=$(echo "$updates" | wc -l)
        local package_list=$(echo "$updates" | head -10 | tr '\n' ', ' | sed 's/,$//')

        if [ $count -gt 10 ]; then
            package_list="$package_list... (+$((count-10)) mais)"
        fi

        echo "$count:$package_list"
    fi
}

# Verificar se precisa reiniciar
check_reboot_required() {
    if [ -f /var/run/reboot-required ]; then
        echo "true"
        if [ -f /var/run/reboot-required.pkgs ]; then
            cat /var/run/reboot-required.pkgs | head -5 | tr '\n' ', ' | sed 's/,$//'
        fi
    else
        echo "false"
    fi
}

### ========== MODO DE EXECUÇÃO ==========

MODE="${1:-check}"

case "$MODE" in
    # Verificar e notificar sobre updates recentes
    check)
        updates_info=$(check_recent_updates)

        if [ -n "$updates_info" ]; then
            count=$(echo "$updates_info" | cut -d':' -f1)
            packages=$(echo "$updates_info" | cut -d':' -f2-)

            reboot_info=$(check_reboot_required)
            reboot_needed=$(echo "$reboot_info" | head -1)

            if [ "$reboot_needed" = "true" ]; then
                send_discord_update \
                    "🔄 Updates Instalados (Reboot Necessário)" \
                    "**$count pacote(s)** foram atualizados automaticamente.\n\n⚠️ **Reinicialização necessária** para aplicar todas as mudanças." \
                    "$COLOR_WARNING" \
                    "$packages"
            else
                send_discord_update \
                    "✅ Updates Instalados" \
                    "**$count pacote(s)** foram atualizados automaticamente." \
                    "$COLOR_SUCCESS" \
                    "$packages"
            fi
        fi
        ;;

    # Notificação de sucesso (chamado pelo hook do apt)
    success)
        packages="${2:-}"
        send_discord_update \
            "✅ Updates de Segurança Aplicados" \
            "Updates automáticos foram instalados com sucesso." \
            "$COLOR_SUCCESS" \
            "$packages"
        ;;

    # Notificação de erro
    error)
        error_msg="${2:-Erro desconhecido}"
        send_discord_update \
            "❌ Erro nos Updates Automáticos" \
            "Ocorreu um erro durante a aplicação de updates:\n\`\`\`$error_msg\`\`\`" \
            "15158332" \
            ""
        ;;

    # Notificação de reboot necessário
    reboot)
        reboot_info=$(check_reboot_required)
        reboot_needed=$(echo "$reboot_info" | head -1)
        packages=$(echo "$reboot_info" | tail -n +2)

        if [ "$reboot_needed" = "true" ]; then
            send_discord_update \
                "⚠️ Reinicialização Necessária" \
                "O servidor precisa ser reiniciado para aplicar updates de segurança." \
                "$COLOR_WARNING" \
                "$packages"
        fi
        ;;

    # Relatório diário
    daily)
        # Obter estatísticas
        updates_24h=$(get_recent_updates 24 | wc -l)
        pending=$(apt list --upgradable 2>/dev/null | grep -c upgradable || echo "0")
        reboot_info=$(check_reboot_required)
        reboot_needed=$(echo "$reboot_info" | head -1)

        # Construir mensagem
        status="🟢 Sistema atualizado"
        color=$COLOR_SUCCESS

        if [ "$reboot_needed" = "true" ]; then
            status="🟡 Reboot pendente"
            color=$COLOR_WARNING
        elif [ "$pending" -gt 0 ]; then
            status="🟡 $pending updates pendentes"
            color=$COLOR_WARNING
        fi

        description="**Status:** $status\n"
        description+="**Updates (24h):** $updates_24h pacotes\n"
        description+="**Pendentes:** $pending pacotes"

        send_discord_update \
            "📊 Relatório Diário de Updates" \
            "$description" \
            "$color" \
            ""
        ;;

    # Teste de webhook
    test)
        send_discord_update \
            "🧪 Teste de Notificação" \
            "Este é um teste do sistema de notificações de updates.\n\nSe você está vendo esta mensagem, o webhook está configurado corretamente!" \
            "$COLOR_INFO" \
            ""
        echo "Notificação de teste enviada para Discord"
        ;;

    *)
        echo "Uso: $0 {check|success|error|reboot|daily|test}"
        echo ""
        echo "Modos:"
        echo "  check   - Verifica updates recentes e notifica"
        echo "  success - Notifica sucesso (usado pelo hook apt)"
        echo "  error   - Notifica erro com mensagem"
        echo "  reboot  - Notifica se reboot é necessário"
        echo "  daily   - Envia relatório diário"
        echo "  test    - Testa o webhook"
        exit 1
        ;;
esac
