#!/bin/bash
################################################################################
# Script: backup-completo-agora.sh
# Propósito: Executar backup completo em tempo real com notificações
# Uso: ./backup-completo-agora.sh
################################################################################

# Cores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
GRAY='\033[0;90m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_ROOT="/opt/vpsguardian"

# Carregar configurações
if [ -f "/opt/vpsguardian/config/backup-destinations.conf" ]; then
    source "/opt/vpsguardian/config/backup-destinations.conf"
fi

clear
echo ""
echo -e "${CYAN}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║           🚀 BACKUP COMPLETO EM TEMPO REAL                     ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Verificar webhook
if [ -z "$WEBHOOK_URL" ]; then
    echo -e "${YELLOW}⚠️  Webhook não configurado${NC}"
    echo -e "${GRAY}   Configure em: Menu 2 → 11 (Configurar Destinos)${NC}"
    echo ""
else
    echo -e "${GREEN}✅ Webhook configurado${NC}"
    echo -e "${GRAY}   Notificações serão enviadas ao Discord/Slack${NC}"
    echo ""
fi

# Mostrar configuração atual
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}Configuração atual:${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
[ "$BACKUP_DEST_LOCAL" = "true" ] && echo -e "  ${GREEN}✅${NC} Local"
[ "$BACKUP_DEST_GOOGLE_DRIVE" = "true" ] && echo -e "  ${GREEN}✅${NC} Google Drive → ${GDRIVE_REMOTE_NAME}:${GDRIVE_DIR}"
[ "$BACKUP_DEST_AWS_S3" = "true" ] && echo -e "  ${GREEN}✅${NC} S3/R2 → s3://${S3_BUCKET}/${S3_PREFIX}"
[ "$BACKUP_INCLUDE_COOLIFY" = "true" ] && echo -e "  ${GREEN}✅${NC} Incluir coolify-db" || echo -e "  ${YELLOW}⚠️${NC}  Excluir coolify-db"
echo ""

# Menu de opções
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}O que deseja executar?${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  ${GREEN}1${NC} → 📦 Backup de Databases (Dumps SQL)"
echo -e "       ${GRAY}Backup de todos os bancos de dados das aplicações${NC}"
echo ""
echo -e "  ${GREEN}2${NC} → 🔐 Backup do Coolify (SSH keys, .env, configs)"
echo -e "       ${GRAY}Configurações críticas para migração${NC}"
echo ""
echo -e "  ${GREEN}3${NC} → 🚀 Backup COMPLETO (Coolify + Databases)"
echo -e "       ${GRAY}Executa ambos os backups em sequência${NC}"
echo ""
echo -e "  ${GREEN}4${NC} → 🧪 Apenas testar Webhook"
echo -e "       ${GRAY}Envia mensagem de teste sem fazer backup${NC}"
echo ""
echo -e "  ${RED}0${NC} → Voltar"
echo ""

read -p "$(echo -e ${BLUE}Escolha uma opção:${NC} )" CHOICE

case $CHOICE in
    1)
        # Backup de Databases
        echo ""
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${MAGENTA}📦 BACKUP DE DATABASES${NC}"
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""

        echo -e "${YELLOW}Escolha o destino:${NC}"
        echo "  [1] Local apenas"
        echo "  [2] Local + Google Drive"
        echo "  [3] Local + S3/R2"
        echo "  [4] Todos os destinos"
        echo ""
        read -p "Destino (1-4, padrão: 1): " DEST_CHOICE

        case $DEST_CHOICE in
            2) DEST="google-drive" ;;
            3) DEST="aws-s3" ;;
            4) DEST="all" ;;
            *) DEST="local" ;;
        esac

        echo ""
        echo -e "${GREEN}▶ Iniciando backup de databases (destino: $DEST)...${NC}"
        echo ""

        bash "$INSTALL_ROOT/backup/backup-databases-dump-auto.sh" --dest="$DEST"

        echo ""
        echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${GREEN}✅ Backup de databases concluído!${NC}"
        echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        ;;

    2)
        # Backup do Coolify
        echo ""
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${MAGENTA}🔐 BACKUP DO COOLIFY${NC}"
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        echo -e "${GREEN}▶ Iniciando backup do Coolify...${NC}"
        echo ""

        bash "$INSTALL_ROOT/backup/backup-coolify.sh"

        echo ""
        echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${GREEN}✅ Backup do Coolify concluído!${NC}"
        echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        ;;

    3)
        # Backup COMPLETO
        echo ""
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${MAGENTA}🚀 BACKUP COMPLETO${NC}"
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""

        echo -e "${YELLOW}Escolha o destino para databases:${NC}"
        echo "  [1] Local apenas"
        echo "  [2] Local + Google Drive"
        echo "  [3] Local + S3/R2"
        echo "  [4] Todos os destinos"
        echo ""
        read -p "Destino (1-4, padrão: 4): " DEST_CHOICE

        case $DEST_CHOICE in
            1) DEST="local" ;;
            2) DEST="google-drive" ;;
            3) DEST="aws-s3" ;;
            *) DEST="all" ;;
        esac

        TOTAL_START=$(date +%s)

        # Passo 1: Databases
        echo ""
        echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${YELLOW}PASSO 1/2: Backup de Databases${NC}"
        echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""

        bash "$INSTALL_ROOT/backup/backup-databases-dump-auto.sh" --dest="$DEST"

        # Passo 2: Coolify
        echo ""
        echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${YELLOW}PASSO 2/2: Backup do Coolify${NC}"
        echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""

        bash "$INSTALL_ROOT/backup/backup-coolify.sh"

        # Resumo final
        TOTAL_END=$(date +%s)
        TOTAL_DURATION=$((TOTAL_END - TOTAL_START))
        TOTAL_DURATION_FMT=$(printf '%02d:%02d:%02d' $((TOTAL_DURATION/3600)) $((TOTAL_DURATION%3600/60)) $((TOTAL_DURATION%60)))

        echo ""
        echo -e "${GREEN}╔════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║              ✅ BACKUP COMPLETO FINALIZADO                     ║${NC}"
        echo -e "${GREEN}╚════════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "  ${GREEN}⏱️  Duração total: $TOTAL_DURATION_FMT${NC}"
        echo ""
        echo -e "  ${BLUE}📁 Backups salvos em:${NC}"
        echo -e "     • Databases: /var/backups/vpsguardian/databases/"
        echo -e "     • Coolify:   /var/backups/vpsguardian/coolify/"
        echo ""

        # Mostrar tamanhos
        DB_SIZE=$(du -sh /var/backups/vpsguardian/databases/ 2>/dev/null | cut -f1)
        COOLIFY_SIZE=$(du -sh /var/backups/vpsguardian/coolify/ 2>/dev/null | cut -f1)
        echo -e "  ${BLUE}📦 Tamanhos:${NC}"
        echo -e "     • Databases: $DB_SIZE"
        echo -e "     • Coolify:   $COOLIFY_SIZE"
        echo ""

        if [ -n "$WEBHOOK_URL" ]; then
            echo -e "  ${GREEN}🔔 Notificações enviadas ao webhook${NC}"
        fi
        echo ""
        ;;

    4)
        # Testar webhook
        echo ""
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${MAGENTA}🧪 TESTE DE WEBHOOK${NC}"
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""

        if [ -z "$WEBHOOK_URL" ]; then
            echo -e "${RED}❌ Webhook não configurado!${NC}"
            echo ""
            echo "Configure em: Menu 2 → 11 (Configurar Destinos)"
        else
            echo -e "Webhook: ${YELLOW}$WEBHOOK_URL${NC}"
            echo ""
            echo -e "${GREEN}▶ Enviando mensagem de teste...${NC}"
            echo ""

            # Detectar tipo de webhook
            if [[ "$WEBHOOK_URL" == *"discord.com"* ]]; then
                HOSTNAME=$(hostname)
                IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || echo "N/A")
                DATE=$(date '+%Y-%m-%d %H:%M:%S')

                PAYLOAD=$(cat <<EOF
{
    "embeds": [{
        "title": "🧪 Teste de Webhook - VPS Guardian",
        "description": "Este é um teste de notificação do sistema de backup.",
        "color": 3066993,
        "fields": [
            {"name": "🖥️ Servidor", "value": "$HOSTNAME", "inline": true},
            {"name": "🌐 IP", "value": "$IP", "inline": true},
            {"name": "📅 Data/Hora", "value": "$DATE", "inline": false},
            {"name": "✅ Status", "value": "Webhook funcionando corretamente!", "inline": false},
            {"name": "📋 Próximos backups", "value": "Verifique o cron com: sudo crontab -l", "inline": false}
        ],
        "footer": {"text": "VPS Guardian - Sistema de Backup Automático"}
    }]
}
EOF
)
                RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" -X POST -H "Content-Type: application/json" -d "$PAYLOAD" "$WEBHOOK_URL")

                if [ "$RESPONSE" = "204" ] || [ "$RESPONSE" = "200" ]; then
                    echo -e "${GREEN}✅ Mensagem enviada com sucesso!${NC}"
                    echo ""
                    echo -e "${GRAY}Verifique seu canal Discord para confirmar o recebimento.${NC}"
                else
                    echo -e "${RED}❌ Falha ao enviar (HTTP $RESPONSE)${NC}"
                fi
            else
                echo -e "${YELLOW}Webhook não é do Discord. Tentando envio genérico...${NC}"
                RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" -X POST -H "Content-Type: application/json" \
                    -d '{"text": "🧪 Teste VPS Guardian - Webhook funcionando!"}' "$WEBHOOK_URL")
                echo "Resposta HTTP: $RESPONSE"
            fi
        fi
        echo ""
        ;;

    0|"")
        echo ""
        echo -e "${GRAY}Operação cancelada${NC}"
        exit 0
        ;;

    *)
        echo ""
        echo -e "${RED}Opção inválida${NC}"
        ;;
esac

echo ""
read -p "Pressione ENTER para continuar..."
