#!/bin/bash
################################################################################
# Script: configurar-backup-destinos.sh
# Propósito: Configurar destinos de backup de forma interativa
# Uso: ./configurar-backup-destinos.sh
################################################################################

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="/opt/vpsguardian/config/backup-destinations.conf"

# Cores
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[ INFO ]${NC} $*"; }
log_success() { echo -e "${GREEN}[ OK ]${NC} $*"; }
log_error() { echo -e "${RED}[ ERRO ]${NC} $*"; }
log_warning() { echo -e "${YELLOW}[ AVISO ]${NC} $*"; }

get_s3_retention_strategy() {
    echo "${S3_RETENTION_STRATEGY:-${BACKUP_RETENTION_STRATEGY:-simple}}"
}

get_s3_retention_days() {
    echo "${S3_RETENTION_DAYS:-${BACKUP_RETENTION_DAYS:-30}}"
}

get_s3_retention_count() {
    echo "${S3_RETENTION_COUNT:-${BACKUP_RETENTION_COUNT:-10}}"
}

show_s3_cleanup_summary() {
    if [ "${S3_CLEANUP_ENABLED:-true}" = "true" ]; then
        case "$(get_s3_retention_strategy)" in
            simple) echo -e "     ${GREEN}↳${NC} Limpeza S3/R2: >$(get_s3_retention_days) dias" ;;
            count) echo -e "     ${GREEN}↳${NC} Limpeza S3/R2: manter últimos $(get_s3_retention_count)" ;;
            gfs) echo -e "     ${GREEN}↳${NC} Limpeza S3/R2: GFS - 7d+4w+12m" ;;
        esac
    else
        echo -e "     ${YELLOW}↳${NC} Limpeza S3/R2: desabilitada"
    fi
}

configure_s3_cleanup() {
    echo ""
    echo -e "${YELLOW}Limpeza remota S3/R2${NC}"
    echo "A limpeza roda logo após cada upload bem-sucedido e só afeta o prefixo enviado."
    echo ""

    read -p "$(echo -e ${BLUE}Limpar backups antigos no S3/R2 após upload? \(Y/n\):${NC} )" ENABLE_S3_CLEANUP
    ENABLE_S3_CLEANUP=${ENABLE_S3_CLEANUP:-Y}
    S3_CLEANUP_ENABLED=$([[ "$ENABLE_S3_CLEANUP" =~ ^[Yy]$ ]] && echo "true" || echo "false")

    if [ "$S3_CLEANUP_ENABLED" != "true" ]; then
        S3_RETENTION_STRATEGY=""
        S3_RETENTION_DAYS=""
        S3_RETENTION_COUNT=""
        return
    fi

    read -p "$(echo -e ${BLUE}Usar a mesma retenção local no S3/R2? \(Y/n\):${NC} )" USE_LOCAL_RETENTION
    USE_LOCAL_RETENTION=${USE_LOCAL_RETENTION:-Y}

    if [[ "$USE_LOCAL_RETENTION" =~ ^[Yy]$ ]]; then
        S3_RETENTION_STRATEGY=""
        S3_RETENTION_DAYS=""
        S3_RETENTION_COUNT=""
        log_info "S3/R2 usará a mesma política local (${BACKUP_RETENTION_STRATEGY:-simple})"
        return
    fi

    echo ""
    echo "Estratégia de retenção remota:"
    echo "  1) simple - Deleta backups mais antigos que X dias"
    echo "  2) count  - Mantém últimos X backups"
    echo "  3) gfs    - 7 diários + 4 semanais + 12 mensais"
    echo ""
    read -p "$(echo -e ${BLUE}Escolha a estratégia \(1-3, padrão: 1\):${NC} )" S3_CLEANUP_CHOICE
    S3_CLEANUP_CHOICE=${S3_CLEANUP_CHOICE:-1}

    case "$S3_CLEANUP_CHOICE" in
        2)
            S3_RETENTION_STRATEGY="count"
            read -p "$(echo -e ${BLUE}Quantidade de backups remotos a manter \(padrão: 10\):${NC} )" NEW_S3_COUNT
            S3_RETENTION_COUNT=${NEW_S3_COUNT:-10}
            S3_RETENTION_DAYS=""
            ;;
        3)
            S3_RETENTION_STRATEGY="gfs"
            S3_RETENTION_DAYS=""
            S3_RETENTION_COUNT=""
            ;;
        *)
            S3_RETENTION_STRATEGY="simple"
            read -p "$(echo -e ${BLUE}Deletar backups remotos com mais de quantos dias? \(padrão: 30\):${NC} )" NEW_S3_DAYS
            S3_RETENTION_DAYS=${NEW_S3_DAYS:-30}
            S3_RETENTION_COUNT=""
            ;;
    esac
}

clear
echo -e "${CYAN}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║     CONFIGURAÇÃO DE DESTINOS DE BACKUP AUTOMÁTICO             ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Verificar se é root
if [ "$EUID" -ne 0 ]; then
    log_error "Este script deve ser executado como root (use sudo)"
    exit 1
fi

# Função para salvar configuração
save_config() {
    mkdir -p "$(dirname "$CONFIG_FILE")"
    cat > "$CONFIG_FILE" << EOF
#!/bin/bash
################################################################################
# VPS Guardian - Configuração de Destinos de Backup
# Gerado automaticamente em: $(date '+%Y-%m-%d %H:%M:%S')
################################################################################

# ========== DESTINOS HABILITADOS ==========
BACKUP_DEST_LOCAL=$BACKUP_DEST_LOCAL
BACKUP_DEST_SSH=$BACKUP_DEST_SSH
BACKUP_DEST_GOOGLE_DRIVE=$BACKUP_DEST_GOOGLE_DRIVE
BACKUP_DEST_AWS_S3=$BACKUP_DEST_AWS_S3

# ========== CONFIGURAÇÕES SSH (Self-hosted) ==========
SSH_REMOTE_ENABLED=${SSH_REMOTE_ENABLED:-false}
SSH_REMOTE_SERVER="$SSH_REMOTE_SERVER"
SSH_REMOTE_USER="$SSH_REMOTE_USER"
SSH_REMOTE_PORT="$SSH_REMOTE_PORT"
SSH_REMOTE_DIR="$SSH_REMOTE_DIR"
SSH_KEY_PATH="$SSH_KEY_PATH"

# ========== CONFIGURAÇÕES GOOGLE DRIVE (rclone) ==========
GDRIVE_ENABLED=${GDRIVE_ENABLED:-false}
GDRIVE_REMOTE_NAME="$GDRIVE_REMOTE_NAME"
GDRIVE_DIR="$GDRIVE_DIR"

# ========== CONFIGURAÇÕES AWS S3 / R2 / MinIO ==========
S3_ENABLED=${S3_ENABLED:-false}
S3_BUCKET="$S3_BUCKET"
S3_PREFIX="$S3_PREFIX"
S3_REGION="$S3_REGION"
S3_STORAGE_CLASS="$S3_STORAGE_CLASS"
S3_ENDPOINT="$S3_ENDPOINT"
S3_CLEANUP_ENABLED=${S3_CLEANUP_ENABLED:-true}
S3_RETENTION_STRATEGY="${S3_RETENTION_STRATEGY:-}"
S3_RETENTION_DAYS="${S3_RETENTION_DAYS:-}"
S3_RETENTION_COUNT="${S3_RETENTION_COUNT:-}"

# ========== RETENÇÃO DE BACKUPS ==========
# Estratégia: simple, count, gfs
BACKUP_RETENTION_STRATEGY="${BACKUP_RETENTION_STRATEGY:-simple}"
BACKUP_RETENTION_DAYS=${BACKUP_RETENTION_DAYS:-30}
BACKUP_RETENTION_COUNT=${BACKUP_RETENTION_COUNT:-10}
REMOVE_LOCAL_AFTER_UPLOAD=$REMOVE_LOCAL_AFTER_UPLOAD

# ========== OPÇÕES DE BACKUP ==========
BACKUP_INCLUDE_COOLIFY=$BACKUP_INCLUDE_COOLIFY

# ========== NOTIFICAÇÕES ==========
WEBHOOK_URL="$WEBHOOK_URL"
NOTIFICATION_EMAIL="$NOTIFICATION_EMAIL"
EOF
    chmod 600 "$CONFIG_FILE"
}

# Carregar configuração existente se houver
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"

    # Menu de edição quando configuração existe
    echo -e "${GREEN}✅ Configuração existente encontrada${NC}"
    echo ""
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}Configuração atual:${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    # Mostrar configuração atual resumida
    if [ "$BACKUP_DEST_LOCAL" = "true" ]; then
        case "${BACKUP_RETENTION_STRATEGY:-simple}" in
            simple) echo -e "  ${GREEN}✅${NC} Local (Retenção: ${BACKUP_RETENTION_DAYS:-30} dias)" ;;
            count) echo -e "  ${GREEN}✅${NC} Local (Retenção: últimos ${BACKUP_RETENTION_COUNT:-10} backups)" ;;
            gfs) echo -e "  ${GREEN}✅${NC} Local (Retenção: GFS - 7d+4w+12m)" ;;
        esac
    else
        echo -e "  ${RED}❌${NC} Local"
    fi
    [ "$BACKUP_DEST_SSH" = "true" ] && echo -e "  ${GREEN}✅${NC} SSH → $SSH_REMOTE_USER@$SSH_REMOTE_SERVER" || echo -e "  ${RED}❌${NC} SSH"
    [ "$BACKUP_DEST_GOOGLE_DRIVE" = "true" ] && echo -e "  ${GREEN}✅${NC} Google Drive → ${GDRIVE_REMOTE_NAME}:${GDRIVE_DIR}" || echo -e "  ${RED}❌${NC} Google Drive"
    if [ "$BACKUP_DEST_AWS_S3" = "true" ]; then
        [ -n "$S3_ENDPOINT" ] && echo -e "  ${GREEN}✅${NC} S3/R2 → s3://${S3_BUCKET}/${S3_PREFIX}" || echo -e "  ${GREEN}✅${NC} AWS S3 → s3://${S3_BUCKET}/${S3_PREFIX}"
        show_s3_cleanup_summary
    else
        echo -e "  ${RED}❌${NC} AWS S3"
    fi
    echo ""
    [ "$BACKUP_INCLUDE_COOLIFY" = "true" ] && echo -e "  ${GREEN}✅${NC} Incluir coolify-db" || echo -e "  ${YELLOW}⚠️${NC}  Excluir coolify-db"
    [ -n "$WEBHOOK_URL" ] && echo -e "  ${GREEN}🔔${NC} Webhook: configurado" || echo -e "  ${RED}❌${NC} Webhook: não configurado"
    [ -n "$NOTIFICATION_EMAIL" ] && echo -e "  ${GREEN}📧${NC} Email: $NOTIFICATION_EMAIL" || echo -e "  ${RED}❌${NC} Email: não configurado"
    echo ""

    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}O que deseja fazer?${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${GREEN}1${NC} → Editar Notificações (Webhook/Email)"
    echo -e "  ${GREEN}2${NC} → 🧪 Testar Webhook"
    echo -e "  ${GREEN}3${NC} → Editar Destino Local"
    echo -e "  ${GREEN}4${NC} → Editar Destino SSH"
    echo -e "  ${GREEN}5${NC} → Editar Destino Google Drive"
    echo -e "  ${GREEN}6${NC} → Editar Destino AWS S3 / R2"
    echo -e "  ${GREEN}7${NC} → Editar Opções (coolify-db, etc)"
    echo -e "  ${GREEN}8${NC} → 🗑️ Editar Retenção de Backups"
    echo -e "  ${GREEN}9${NC} → Reconfigurar TUDO do zero"
    echo -e "  ${GREEN}0${NC} → Voltar (manter configuração atual)"
    echo ""

    read -p "$(echo -e ${BLUE}Escolha uma opção:${NC} )" EDIT_CHOICE

    case $EDIT_CHOICE in
        1)
            # Editar notificações
            clear
            echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo -e "${YELLOW}EDITAR NOTIFICAÇÕES${NC}"
            echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo ""
            echo -e "Webhook atual: ${YELLOW}${WEBHOOK_URL:-não configurado}${NC}"
            echo -e "Email atual: ${YELLOW}${NOTIFICATION_EMAIL:-não configurado}${NC}"
            echo ""
            read -p "$(echo -e ${BLUE}Novo Webhook \(Enter para manter, 'limpar' para remover\):${NC} )" NEW_WEBHOOK
            if [ "$NEW_WEBHOOK" = "limpar" ]; then
                WEBHOOK_URL=""
                log_success "Webhook removido"
            elif [ -n "$NEW_WEBHOOK" ]; then
                WEBHOOK_URL="$NEW_WEBHOOK"
                log_success "Webhook atualizado"
            fi

            read -p "$(echo -e ${BLUE}Novo Email \(Enter para manter, 'limpar' para remover\):${NC} )" NEW_EMAIL
            if [ "$NEW_EMAIL" = "limpar" ]; then
                NOTIFICATION_EMAIL=""
                log_success "Email removido"
            elif [ -n "$NEW_EMAIL" ]; then
                NOTIFICATION_EMAIL="$NEW_EMAIL"
                log_success "Email atualizado"
            fi

            save_config
            log_success "Configuração salva!"
            exit 0
            ;;
        2)
            # Testar webhook
            clear
            echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo -e "${YELLOW}🧪 TESTAR WEBHOOK${NC}"
            echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo ""

            if [ -z "$WEBHOOK_URL" ]; then
                log_error "Nenhum webhook configurado!"
                echo ""
                read -p "$(echo -e ${BLUE}Deseja configurar um webhook agora? \(Y/n\):${NC} )" CONFIGURE_NOW
                if [[ "$CONFIGURE_NOW" =~ ^[Yy]$ ]] || [ -z "$CONFIGURE_NOW" ]; then
                    read -p "$(echo -e ${BLUE}URL do Webhook \(Discord/Slack\):${NC} )" WEBHOOK_URL
                    if [ -n "$WEBHOOK_URL" ]; then
                        save_config
                        log_success "Webhook salvo!"
                    else
                        exit 0
                    fi
                else
                    exit 0
                fi
            fi

            echo -e "Webhook: ${YELLOW}$WEBHOOK_URL${NC}"
            echo ""
            log_info "Enviando mensagem de teste..."
            echo ""

            # Detectar tipo de webhook (Discord ou Slack)
            if [[ "$WEBHOOK_URL" == *"discord.com"* ]]; then
                # Discord webhook
                HOSTNAME=$(hostname)
                IP=$(curl -s ifconfig.me 2>/dev/null || echo "N/A")
                DATE=$(date '+%Y-%m-%d %H:%M:%S')

                PAYLOAD=$(cat <<EOF
{
    "embeds": [{
        "title": "🧪 Teste de Webhook - VPS Guardian",
        "description": "Este é um teste de notificação do VPS Guardian.",
        "color": 3066993,
        "fields": [
            {"name": "🖥️ Servidor", "value": "$HOSTNAME", "inline": true},
            {"name": "🌐 IP", "value": "$IP", "inline": true},
            {"name": "📅 Data/Hora", "value": "$DATE", "inline": false},
            {"name": "✅ Status", "value": "Webhook funcionando corretamente!", "inline": false}
        ],
        "footer": {"text": "VPS Guardian - Sistema de Backup e Manutenção"}
    }]
}
EOF
)
                RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" -X POST -H "Content-Type: application/json" -d "$PAYLOAD" "$WEBHOOK_URL")

                if [ "$RESPONSE" = "204" ] || [ "$RESPONSE" = "200" ]; then
                    log_success "Mensagem de teste enviada com sucesso!"
                    echo ""
                    echo -e "${GREEN}✅ Verifique seu canal Discord para confirmar o recebimento.${NC}"
                else
                    log_error "Falha ao enviar mensagem (HTTP $RESPONSE)"
                    echo ""
                    echo "Possíveis causas:"
                    echo "  • URL do webhook incorreta"
                    echo "  • Webhook foi deletado no Discord"
                    echo "  • Problemas de conectividade"
                fi
            elif [[ "$WEBHOOK_URL" == *"slack.com"* ]]; then
                # Slack webhook
                HOSTNAME=$(hostname)
                DATE=$(date '+%Y-%m-%d %H:%M:%S')

                PAYLOAD=$(cat <<EOF
{
    "text": "🧪 *Teste de Webhook - VPS Guardian*",
    "attachments": [{
        "color": "#2eb886",
        "fields": [
            {"title": "Servidor", "value": "$HOSTNAME", "short": true},
            {"title": "Data/Hora", "value": "$DATE", "short": true},
            {"title": "Status", "value": "✅ Webhook funcionando corretamente!", "short": false}
        ]
    }]
}
EOF
)
                RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" -X POST -H "Content-Type: application/json" -d "$PAYLOAD" "$WEBHOOK_URL")

                if [ "$RESPONSE" = "200" ]; then
                    log_success "Mensagem de teste enviada com sucesso!"
                else
                    log_error "Falha ao enviar mensagem (HTTP $RESPONSE)"
                fi
            else
                log_warning "Tipo de webhook não reconhecido. Tentando envio genérico..."
                RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" -X POST -H "Content-Type: application/json" \
                    -d '{"text": "Teste VPS Guardian - Webhook funcionando!"}' "$WEBHOOK_URL")

                if [ "$RESPONSE" = "200" ] || [ "$RESPONSE" = "204" ]; then
                    log_success "Mensagem enviada (HTTP $RESPONSE)"
                else
                    log_error "Falha (HTTP $RESPONSE)"
                fi
            fi

            echo ""
            read -p "Pressione ENTER para continuar..."
            exit 0
            ;;
        3)
            # Editar Local
            clear
            echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo -e "${YELLOW}EDITAR BACKUP LOCAL${NC}"
            echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo ""
            echo -e "Status atual: ${YELLOW}$([[ "$BACKUP_DEST_LOCAL" = "true" ]] && echo "Habilitado" || echo "Desabilitado")${NC}"
            echo -e "Retenção atual: ${YELLOW}${LOCAL_BACKUP_RETENTION_DAYS:-30} dias${NC}"
            echo ""
            read -p "$(echo -e ${BLUE}Habilitar backup local? \(Y/n\):${NC} )" KEEP_LOCAL
            KEEP_LOCAL=${KEEP_LOCAL:-Y}
            BACKUP_DEST_LOCAL=$([[ "$KEEP_LOCAL" =~ ^[Yy]$ ]] && echo "true" || echo "false")

            if [ "$BACKUP_DEST_LOCAL" = "true" ]; then
                read -p "$(echo -e ${BLUE}Retenção em dias \(atual: ${LOCAL_BACKUP_RETENTION_DAYS:-30}\):${NC} )" RETENTION
                LOCAL_BACKUP_RETENTION_DAYS=${RETENTION:-${LOCAL_BACKUP_RETENTION_DAYS:-30}}
            fi

            save_config
            log_success "Configuração salva!"
            exit 0
            ;;
        4)
            # Editar SSH - pula para a seção SSH abaixo
            SKIP_TO_SSH=true
            ;;
        5)
            # Editar Google Drive - pula para a seção
            SKIP_TO_GDRIVE=true
            ;;
        6)
            # Editar S3/R2 - pula para a seção
            SKIP_TO_S3=true
            ;;
        7)
            # Editar opções
            clear
            echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo -e "${YELLOW}EDITAR OPÇÕES${NC}"
            echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo ""
            echo -e "Incluir coolify-db: ${YELLOW}$([[ "$BACKUP_INCLUDE_COOLIFY" = "true" ]] && echo "Sim" || echo "Não")${NC}"
            echo -e "Remover local após upload: ${YELLOW}$([[ "$REMOVE_LOCAL_AFTER_UPLOAD" = "true" ]] && echo "Sim" || echo "Não")${NC}"
            echo ""

            read -p "$(echo -e ${BLUE}Incluir coolify-db nos backups? \(Y/n\):${NC} )" INCLUDE_COOLIFY
            INCLUDE_COOLIFY=${INCLUDE_COOLIFY:-Y}
            BACKUP_INCLUDE_COOLIFY=$([[ "$INCLUDE_COOLIFY" =~ ^[Yy]$ ]] && echo "true" || echo "false")

            read -p "$(echo -e ${BLUE}Remover backup local após upload? \(y/N\):${NC} )" REMOVE_LOCAL
            REMOVE_LOCAL=${REMOVE_LOCAL:-N}
            REMOVE_LOCAL_AFTER_UPLOAD=$([[ "$REMOVE_LOCAL" =~ ^[Yy]$ ]] && echo "true" || echo "false")

            save_config
            log_success "Configuração salva!"
            exit 0
            ;;
        8)
            # Editar retenção de backups
            clear
            echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo -e "${YELLOW}🗑️ EDITAR RETENÇÃO DE BACKUPS${NC}"
            echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo ""
            echo -e "Configuração atual:"
            echo -e "  Estratégia: ${YELLOW}${BACKUP_RETENTION_STRATEGY:-simple}${NC}"
            echo -e "  Dias (simple): ${YELLOW}${BACKUP_RETENTION_DAYS:-30}${NC}"
            echo -e "  Quantidade (count): ${YELLOW}${BACKUP_RETENTION_COUNT:-10}${NC}"
            echo ""
            echo -e "${CYAN}Estratégias disponíveis:${NC}"
            echo "  simple = Deleta backups mais antigos que X dias"
            echo "  count  = Mantém últimos X backups (independente da idade)"
            echo "  gfs    = Grandfather-Father-Son (7 diários + 4 semanais + 12 mensais)"
            echo ""
            read -p "$(echo -e ${BLUE}Estratégia \(simple/count/gfs, atual: ${BACKUP_RETENTION_STRATEGY:-simple}\):${NC} )" NEW_STRATEGY
            NEW_STRATEGY=${NEW_STRATEGY:-${BACKUP_RETENTION_STRATEGY:-simple}}

            case "$NEW_STRATEGY" in
                simple|count|gfs)
                    BACKUP_RETENTION_STRATEGY="$NEW_STRATEGY"
                    ;;
                *)
                    log_error "Estratégia inválida. Use: simple, count ou gfs"
                    exit 1
                    ;;
            esac

            if [ "$BACKUP_RETENTION_STRATEGY" = "simple" ]; then
                read -p "$(echo -e ${BLUE}Dias de retenção \(atual: ${BACKUP_RETENTION_DAYS:-30}\):${NC} )" NEW_DAYS
                BACKUP_RETENTION_DAYS=${NEW_DAYS:-${BACKUP_RETENTION_DAYS:-30}}
            elif [ "$BACKUP_RETENTION_STRATEGY" = "count" ]; then
                read -p "$(echo -e ${BLUE}Quantidade de backups a manter \(atual: ${BACKUP_RETENTION_COUNT:-10}\):${NC} )" NEW_COUNT
                BACKUP_RETENTION_COUNT=${NEW_COUNT:-${BACKUP_RETENTION_COUNT:-10}}
            else
                log_info "GFS usa retenção fixa: 7 diários + 4 semanais + 12 mensais"
            fi

            if [ "$BACKUP_DEST_AWS_S3" = "true" ] && [ "${S3_CLEANUP_ENABLED:-true}" = "true" ]; then
                echo ""
                read -p "$(echo -e ${BLUE}Usar esta mesma política também no S3/R2? \(Y/n\):${NC} )" UPDATE_S3_RETENTION
                UPDATE_S3_RETENTION=${UPDATE_S3_RETENTION:-Y}
                if [[ "$UPDATE_S3_RETENTION" =~ ^[Yy]$ ]]; then
                    S3_RETENTION_STRATEGY=""
                    S3_RETENTION_DAYS=""
                    S3_RETENTION_COUNT=""
                fi
            fi

            save_config
            log_success "Configuração de retenção salva!"
            echo ""
            echo -e "${YELLOW}Resumo:${NC}"
            echo -e "  Estratégia: ${GREEN}$BACKUP_RETENTION_STRATEGY${NC}"
            [ "$BACKUP_RETENTION_STRATEGY" = "simple" ] && echo -e "  Retenção: ${GREEN}$BACKUP_RETENTION_DAYS dias${NC}"
            [ "$BACKUP_RETENTION_STRATEGY" = "count" ] && echo -e "  Retenção: ${GREEN}últimos $BACKUP_RETENTION_COUNT backups${NC}"
            [ "$BACKUP_RETENTION_STRATEGY" = "gfs" ] && echo -e "  Retenção: ${GREEN}7 diários + 4 semanais + 12 mensais${NC}"
            [ "$BACKUP_DEST_AWS_S3" = "true" ] && show_s3_cleanup_summary
            exit 0
            ;;
        9)
            # Reconfigurar tudo - continua com o fluxo normal
            BACKUP_CONFIG="${CONFIG_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
            cp "$CONFIG_FILE" "$BACKUP_CONFIG"
            log_info "Backup da configuração atual: $BACKUP_CONFIG"
            # Limpar variáveis para reconfigurar
            unset BACKUP_DEST_LOCAL BACKUP_DEST_SSH BACKUP_DEST_GOOGLE_DRIVE BACKUP_DEST_AWS_S3
            unset SSH_REMOTE_SERVER SSH_REMOTE_USER SSH_REMOTE_PORT SSH_REMOTE_DIR
            unset GDRIVE_REMOTE_NAME GDRIVE_DIR S3_BUCKET S3_PREFIX S3_REGION S3_ENDPOINT
            unset S3_CLEANUP_ENABLED S3_RETENTION_STRATEGY S3_RETENTION_DAYS S3_RETENTION_COUNT
            unset WEBHOOK_URL NOTIFICATION_EMAIL BACKUP_RETENTION_STRATEGY BACKUP_RETENTION_DAYS BACKUP_RETENTION_COUNT
            ;;
        0|"")
            log_info "Configuração mantida sem alterações"
            exit 0
            ;;
        *)
            log_error "Opção inválida"
            exit 1
            ;;
    esac
fi

# Se estiver editando seção específica, pular para ela
if [ "$SKIP_TO_SSH" = "true" ]; then
    clear
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}EDITAR BACKUP SSH${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
fi

if [ "$SKIP_TO_GDRIVE" = "true" ]; then
    clear
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}EDITAR GOOGLE DRIVE${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
fi

if [ "$SKIP_TO_S3" = "true" ]; then
    clear
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}EDITAR AWS S3 / R2${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
fi

log_info "Configure os destinos para onde os backups via dump serão enviados automaticamente."
echo ""

# ========== LOCAL ==========
if [ "$SKIP_TO_SSH" != "true" ] && [ "$SKIP_TO_GDRIVE" != "true" ] && [ "$SKIP_TO_S3" != "true" ]; then
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}1️⃣  BACKUP LOCAL${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    read -p "$(echo -e ${BLUE}Manter backups locais? \(Y/n\):${NC} )" KEEP_LOCAL
    KEEP_LOCAL=${KEEP_LOCAL:-Y}
    BACKUP_DEST_LOCAL=$([[ "$KEEP_LOCAL" =~ ^[Yy]$ ]] && echo "true" || echo "false")

    if [ "$BACKUP_DEST_LOCAL" = "true" ]; then
        echo ""
        echo "Estratégia de retenção:"
        echo "  1) simple - Deleta backups mais antigos que X dias"
        echo "  2) count  - Mantém últimos X backups (independente da idade)"
        echo "  3) gfs    - Grandfather-Father-Son (7 diários + 4 semanais + 12 mensais)"
        echo ""
        read -p "$(echo -e ${BLUE}Escolha a estratégia \(1-3, padrão: 1\):${NC} )" STRATEGY_CHOICE
        STRATEGY_CHOICE=${STRATEGY_CHOICE:-1}

        case "$STRATEGY_CHOICE" in
            2)
                BACKUP_RETENTION_STRATEGY="count"
                read -p "$(echo -e ${BLUE}Quantidade de backups a manter \(padrão: 10\):${NC} )" RETENTION_COUNT
                BACKUP_RETENTION_COUNT=${RETENTION_COUNT:-10}
                BACKUP_RETENTION_DAYS=30  # fallback
                ;;
            3)
                BACKUP_RETENTION_STRATEGY="gfs"
                BACKUP_RETENTION_DAYS=30  # não usado em GFS
                BACKUP_RETENTION_COUNT=10 # não usado em GFS
                log_info "GFS: 7 diários + 4 semanais + 12 mensais"
                ;;
            *)
                BACKUP_RETENTION_STRATEGY="simple"
                read -p "$(echo -e ${BLUE}Retenção em dias \(padrão: 30\):${NC} )" RETENTION
                BACKUP_RETENTION_DAYS=${RETENTION:-30}
                BACKUP_RETENTION_COUNT=10 # fallback
                ;;
        esac
    fi
    echo ""
fi

# ========== SSH ==========
if [ "$SKIP_TO_GDRIVE" != "true" ] && [ "$SKIP_TO_S3" != "true" ]; then
    if [ "$SKIP_TO_SSH" != "true" ]; then
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${YELLOW}2️⃣  BACKUP REMOTO VIA SSH (Self-hosted)${NC}"
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
    fi

    read -p "$(echo -e ${BLUE}Habilitar backup via SSH? \(y/N\):${NC} )" ENABLE_SSH
    ENABLE_SSH=${ENABLE_SSH:-N}

    if [[ "$ENABLE_SSH" =~ ^[Yy]$ ]]; then
        SSH_REMOTE_ENABLED=true
        BACKUP_DEST_SSH=true

        read -p "$(echo -e ${BLUE}IP/Hostname do servidor remoto:${NC} )" SSH_SERVER
        SSH_REMOTE_SERVER="$SSH_SERVER"

        read -p "$(echo -e ${BLUE}Usuário SSH \(padrão: root\):${NC} )" SSH_USER
        SSH_REMOTE_USER=${SSH_USER:-root}

        read -p "$(echo -e ${BLUE}Porta SSH \(padrão: 22\):${NC} )" SSH_PORT
        SSH_REMOTE_PORT=${SSH_PORT:-22}

        read -p "$(echo -e ${BLUE}Diretório no servidor remoto \(padrão: /root/backups\):${NC} )" SSH_DIR
        SSH_REMOTE_DIR=${SSH_DIR:-/root/backups}

        read -p "$(echo -e ${BLUE}Caminho da chave SSH \(padrão: ~/.ssh/id_rsa\):${NC} )" SSH_KEY
        SSH_KEY_PATH=${SSH_KEY:-$HOME/.ssh/id_rsa}

        # Testar conexão
        log_info "Testando conexão SSH..."
        if ssh -i "$SSH_KEY_PATH" -p "$SSH_REMOTE_PORT" -o ConnectTimeout=10 -o BatchMode=yes "$SSH_REMOTE_USER@$SSH_REMOTE_SERVER" "exit" 2>/dev/null; then
            log_success "Conexão SSH estabelecida com sucesso!"
        else
            log_error "Falha na conexão SSH. Verifique as configurações."
            log_warning "Você pode continuar, mas o backup falhará se a conexão não funcionar."
            read -p "Deseja continuar mesmo assim? (y/N): " CONTINUE
            if [[ ! "$CONTINUE" =~ ^[Yy]$ ]]; then
                SSH_REMOTE_ENABLED=false
                BACKUP_DEST_SSH=false
            fi
        fi
    else
        SSH_REMOTE_ENABLED=false
        BACKUP_DEST_SSH=false
    fi
    echo ""

    # Se estava editando apenas SSH, salvar e sair
    if [ "$SKIP_TO_SSH" = "true" ]; then
        save_config
        log_success "Configuração SSH salva!"
        exit 0
    fi
fi

# ========== GOOGLE DRIVE ==========
if [ "$SKIP_TO_S3" != "true" ]; then
    if [ "$SKIP_TO_GDRIVE" != "true" ] && [ "$SKIP_TO_SSH" != "true" ]; then
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${YELLOW}3️⃣  GOOGLE DRIVE (via rclone)${NC}"
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
    fi

# Verificar se rclone está instalado
if ! command -v rclone &> /dev/null; then
    log_warning "rclone não está instalado"
    echo "Instale com: curl https://rclone.org/install.sh | sudo bash"
    GDRIVE_ENABLED=false
    BACKUP_DEST_GOOGLE_DRIVE=false
else
    read -p "$(echo -e ${BLUE}Habilitar backup no Google Drive? \(y/N\):${NC} )" ENABLE_GDRIVE
    ENABLE_GDRIVE=${ENABLE_GDRIVE:-N}

    if [[ "$ENABLE_GDRIVE" =~ ^[Yy]$ ]]; then
        # Listar remotes configurados
        REMOTES=$(rclone listremotes)

        if [ -z "$REMOTES" ]; then
            log_warning "Nenhum remote configurado no rclone"
            echo "Execute: rclone config"
            echo "E configure um remote do tipo 'Google Drive'"
            GDRIVE_ENABLED=false
            BACKUP_DEST_GOOGLE_DRIVE=false
        else
            echo "Remotes disponíveis:"
            echo "$REMOTES"
            echo ""
            read -p "$(echo -e ${BLUE}Nome do remote do Google Drive \(padrão: gdrive\):${NC} )" GDRIVE_REMOTE
            GDRIVE_REMOTE_NAME=${GDRIVE_REMOTE:-gdrive}

            # Verificar se remote existe
            if rclone listremotes | grep -q "^${GDRIVE_REMOTE_NAME}:$"; then
                GDRIVE_ENABLED=true
                BACKUP_DEST_GOOGLE_DRIVE=true

                read -p "$(echo -e ${BLUE}Diretório no Google Drive \(padrão: backups/vpsguardian/databases\):${NC} )" GDRIVE_PATH
                GDRIVE_DIR=${GDRIVE_PATH:-backups/vpsguardian/databases}

                log_success "Google Drive configurado: ${GDRIVE_REMOTE_NAME}:${GDRIVE_DIR}"
            else
                log_error "Remote '${GDRIVE_REMOTE_NAME}' não encontrado"
                GDRIVE_ENABLED=false
                BACKUP_DEST_GOOGLE_DRIVE=false
            fi
        fi
    else
        GDRIVE_ENABLED=false
        BACKUP_DEST_GOOGLE_DRIVE=false
    fi
fi

# Se estava editando apenas Google Drive, salvar e sair
if [ "$SKIP_TO_GDRIVE" = "true" ]; then
    save_config
    log_success "Configuração Google Drive salva!"
    exit 0
fi

fi  # Fecha o if [ "$SKIP_TO_S3" != "true" ] da linha 549

echo ""

# ========== AWS S3 / Cloudflare R2 ==========
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}4️⃣  AWS S3 / Cloudflare R2 / S3-Compatible${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Verificar se aws-cli está instalado
if ! command -v aws &> /dev/null; then
    log_warning "AWS CLI não está instalado"
    echo ""
    echo "Instale com:"
    echo "  sudo apt update && sudo apt install awscli -y"
    echo ""
    read -p "$(echo -e ${BLUE}Instalar AWS CLI agora? \(Y/n\):${NC} )" INSTALL_AWS
    INSTALL_AWS=${INSTALL_AWS:-Y}

    if [[ "$INSTALL_AWS" =~ ^[Yy]$ ]]; then
        apt update && apt install awscli -y
        if command -v aws &> /dev/null; then
            log_success "AWS CLI instalado!"
        else
            log_error "Falha na instalação"
            S3_ENABLED=false
            BACKUP_DEST_AWS_S3=false
        fi
    else
        S3_ENABLED=false
        BACKUP_DEST_AWS_S3=false
    fi
fi

# Se AWS CLI está disponível, continuar configuração
if command -v aws &> /dev/null; then
    read -p "$(echo -e ${BLUE}Habilitar backup S3/R2? \(y/N\):${NC} )" ENABLE_S3
    ENABLE_S3=${ENABLE_S3:-N}

    if [[ "$ENABLE_S3" =~ ^[Yy]$ ]]; then
        S3_ENABLED=true
        BACKUP_DEST_AWS_S3=true

        # Perguntar tipo primeiro para guiar melhor
        echo ""
        echo "Qual serviço você usa?"
        echo "  1) AWS S3"
        echo "  2) Cloudflare R2"
        echo "  3) Outro (MinIO, Backblaze B2, etc)"
        read -p "$(echo -e ${BLUE}Escolha \(1-3\):${NC} )" S3_TYPE
        echo ""

        read -p "$(echo -e ${BLUE}Nome do bucket \(sem s3://\):${NC} )" S3_BUCKET_NAME
        S3_BUCKET="$S3_BUCKET_NAME"

        read -p "$(echo -e ${BLUE}Prefixo/pasta \(padrão: backups\):${NC} )" S3_PATH
        S3_PREFIX=${S3_PATH:-backups}

        # Configurar baseado no tipo
        case "$S3_TYPE" in
            2)
                # Cloudflare R2
                S3_REGION="auto"
                S3_STORAGE_CLASS="STANDARD"
                echo ""
                echo -e "${YELLOW}Para R2, você precisa do Account ID do Cloudflare.${NC}"
                echo "Encontre em: Cloudflare Dashboard → R2 → Overview (lado direito)"
                echo ""
                read -p "$(echo -e ${BLUE}Account ID do Cloudflare:${NC} )" CF_ACCOUNT_ID
                S3_ENDPOINT="https://${CF_ACCOUNT_ID}.r2.cloudflarestorage.com"
                echo ""
                log_info "Endpoint configurado: $S3_ENDPOINT"
                ;;
            3)
                # Outro S3-compatible
                read -p "$(echo -e ${BLUE}Região \(padrão: us-east-1\):${NC} )" S3_REG
                S3_REGION=${S3_REG:-us-east-1}
                S3_STORAGE_CLASS="STANDARD"
                echo ""
                read -p "$(echo -e ${BLUE}Endpoint URL completo:${NC} )" S3_ENDPOINT
                ;;
            *)
                # AWS S3 padrão
                read -p "$(echo -e ${BLUE}Região \(padrão: us-east-1\):${NC} )" S3_REG
                S3_REGION=${S3_REG:-us-east-1}
                read -p "$(echo -e ${BLUE}Storage Class \(STANDARD/STANDARD_IA/GLACIER, padrão: STANDARD_IA\):${NC} )" S3_CLASS
                S3_STORAGE_CLASS=${S3_CLASS:-STANDARD_IA}
                S3_ENDPOINT=""
                ;;
        esac

        # Verificar se credenciais existem
        if [ ! -f ~/.aws/credentials ]; then
            echo ""
            log_warning "Credenciais AWS não configuradas ainda"
            echo ""
            echo "Você precisa configurar as credenciais para o serviço escolhido."
            if [ "$S3_TYPE" = "2" ]; then
                echo ""
                echo -e "${YELLOW}Para Cloudflare R2:${NC}"
                echo "1. Vá em Cloudflare Dashboard → R2 → Manage R2 API Tokens"
                echo "2. Crie um token com permissão de leitura/escrita"
                echo "3. Use o Access Key ID e Secret Access Key gerados"
            fi
            echo ""
            read -p "$(echo -e ${BLUE}Configurar credenciais agora? \(Y/n\):${NC} )" CONFIG_CREDS
            CONFIG_CREDS=${CONFIG_CREDS:-Y}

            if [[ "$CONFIG_CREDS" =~ ^[Yy]$ ]]; then
                aws configure
            fi
        fi

        # Testar acesso ao bucket
        echo ""
        log_info "Testando acesso ao bucket..."
        if [ -n "$S3_ENDPOINT" ]; then
            if aws s3 ls "s3://$S3_BUCKET" --endpoint-url "$S3_ENDPOINT" >/dev/null 2>&1; then
                log_success "Acesso ao bucket confirmado!"
            else
                log_error "Falha ao acessar bucket."
                echo "Verifique: credenciais, nome do bucket, endpoint"
                read -p "Salvar configuração mesmo assim? (y/N): " CONTINUE
                if [[ ! "$CONTINUE" =~ ^[Yy]$ ]]; then
                    S3_ENABLED=false
                    BACKUP_DEST_AWS_S3=false
                fi
            fi
        else
            if aws s3 ls "s3://$S3_BUCKET" --region "$S3_REGION" >/dev/null 2>&1; then
                log_success "Acesso ao bucket S3 confirmado!"
            else
                log_error "Falha ao acessar bucket."
                read -p "Salvar configuração mesmo assim? (y/N): " CONTINUE
                if [[ ! "$CONTINUE" =~ ^[Yy]$ ]]; then
                    S3_ENABLED=false
                    BACKUP_DEST_AWS_S3=false
                fi
            fi
        fi

        if [ "$BACKUP_DEST_AWS_S3" = "true" ]; then
            configure_s3_cleanup
        fi
    else
        S3_ENABLED=false
        BACKUP_DEST_AWS_S3=false
    fi
fi

# Se estava editando apenas S3/R2, salvar e sair
if [ "$SKIP_TO_S3" = "true" ]; then
    save_config
    log_success "Configuração S3/R2 salva!"
    exit 0
fi

echo ""

# ========== OPÇÕES ADICIONAIS ==========
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}5️⃣  OPÇÕES ADICIONAIS${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Incluir banco Coolify
echo -e "${YELLOW}⚠️  IMPORTANTE: Banco de Dados do Coolify (coolify-db)${NC}"
echo ""
echo "O coolify-db contém as configurações do Coolify (projetos, deployments, etc)."
echo "No restore, você terá controle para decidir se restaura ou não este banco."
echo ""
read -p "$(echo -e ${BLUE}Incluir coolify-db nos backups automáticos? \(Y/n\):${NC} )" INCLUDE_COOLIFY
INCLUDE_COOLIFY=${INCLUDE_COOLIFY:-Y}
BACKUP_INCLUDE_COOLIFY=$([[ "$INCLUDE_COOLIFY" =~ ^[Yy]$ ]] && echo "true" || echo "false")
echo ""

# Verificar se algum destino remoto foi habilitado
if [ "$BACKUP_DEST_SSH" = "true" ] || [ "$BACKUP_DEST_GOOGLE_DRIVE" = "true" ] || [ "$BACKUP_DEST_AWS_S3" = "true" ]; then
    read -p "$(echo -e ${BLUE}Remover backup local após upload bem-sucedido? \(y/N\):${NC} )" REMOVE_LOCAL
    REMOVE_LOCAL=${REMOVE_LOCAL:-N}
    REMOVE_LOCAL_AFTER_UPLOAD=$([[ "$REMOVE_LOCAL" =~ ^[Yy]$ ]] && echo "true" || echo "false")
else
    REMOVE_LOCAL_AFTER_UPLOAD=false
fi

read -p "$(echo -e ${BLUE}Webhook para notificações \(Discord/Slack, deixe vazio para desabilitar\):${NC} )" WEBHOOK
WEBHOOK_URL="$WEBHOOK"

read -p "$(echo -e ${BLUE}Email para notificações \(deixe vazio para desabilitar\):${NC} )" EMAIL
NOTIFICATION_EMAIL="$EMAIL"

echo ""

# ========== RESUMO ==========
clear
echo -e "${CYAN}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║                     RESUMO DA CONFIGURAÇÃO                     ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════════════════════════════╝${NC}"
echo ""

echo -e "${GREEN}Destinos habilitados:${NC}"
if [ "$BACKUP_DEST_LOCAL" = "true" ]; then
    case "${BACKUP_RETENTION_STRATEGY:-simple}" in
        simple) echo "  ✅ Local (Retenção: ${BACKUP_RETENTION_DAYS:-30} dias)" ;;
        count) echo "  ✅ Local (Retenção: últimos ${BACKUP_RETENTION_COUNT:-10} backups)" ;;
        gfs) echo "  ✅ Local (Retenção: GFS - 7d+4w+12m)" ;;
    esac
else
    echo "  ❌ Local"
fi
[ "$BACKUP_DEST_SSH" = "true" ] && echo "  ✅ SSH → $SSH_REMOTE_USER@$SSH_REMOTE_SERVER:$SSH_REMOTE_DIR" || echo "  ❌ SSH"
[ "$BACKUP_DEST_GOOGLE_DRIVE" = "true" ] && echo "  ✅ Google Drive → ${GDRIVE_REMOTE_NAME}:${GDRIVE_DIR}" || echo "  ❌ Google Drive"
if [ "$BACKUP_DEST_AWS_S3" = "true" ]; then
    if [ -n "$S3_ENDPOINT" ]; then
        echo "  ✅ S3-Compatible → s3://${S3_BUCKET}/${S3_PREFIX} (${S3_ENDPOINT})"
    else
        echo "  ✅ AWS S3 → s3://${S3_BUCKET}/${S3_PREFIX}"
    fi
    show_s3_cleanup_summary
else
    echo "  ❌ AWS S3"
fi
echo ""

echo -e "${YELLOW}Opções:${NC}"
[ "$BACKUP_INCLUDE_COOLIFY" = "true" ] && echo "  ✅ Incluir coolify-db nos backups" || echo "  ❌ Excluir coolify-db dos backups"
[ "$REMOVE_LOCAL_AFTER_UPLOAD" = "true" ] && echo "  🗑️  Remover backup local após upload" || echo "  💾 Manter backup local após upload"
[ -n "$WEBHOOK_URL" ] && echo "  🔔 Notificações via webhook habilitadas"
[ -n "$NOTIFICATION_EMAIL" ] && echo "  📧 Notificações via email: $NOTIFICATION_EMAIL"
echo ""

read -p "$(echo -e ${BLUE}Confirmar e salvar configuração? \(Y/n\):${NC} )" CONFIRM
CONFIRM=${CONFIRM:-Y}

if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    log_info "Configuração cancelada"
    exit 0
fi

# ========== SALVAR CONFIGURAÇÃO ==========
save_config
log_success "Configuração salva em: $CONFIG_FILE"
echo ""

# ========== TESTAR CONFIGURAÇÃO ==========
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}Deseja testar a configuração agora?${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
read -p "$(echo -e ${BLUE}Executar backup de teste? \(y/N\):${NC} )" TEST_BACKUP
TEST_BACKUP=${TEST_BACKUP:-N}

if [[ "$TEST_BACKUP" =~ ^[Yy]$ ]]; then
    log_info "Executando backup de teste..."
    echo ""

    # Determinar destino baseado na configuração
    DEST="local"
    if [ "$BACKUP_DEST_AWS_S3" = "true" ]; then
        DEST="aws-s3"
    elif [ "$BACKUP_DEST_GOOGLE_DRIVE" = "true" ]; then
        DEST="google-drive"
    elif [ "$BACKUP_DEST_SSH" = "true" ]; then
        DEST="self-hosted"
    fi

    bash "$SCRIPT_DIR/backup-databases-dump-auto.sh" --dest="$DEST"
fi

echo ""
log_success "Configuração concluída!"
echo ""
echo -e "${CYAN}Para executar backup manualmente:${NC}"
echo "  sudo $SCRIPT_DIR/backup-databases-dump-auto.sh --dest=local"
echo "  sudo $SCRIPT_DIR/backup-databases-dump-auto.sh --dest=google-drive"
echo "  sudo $SCRIPT_DIR/backup-databases-dump-auto.sh --dest=aws-s3"
echo ""
echo -e "${CYAN}Para agendar backups automáticos:${NC}"
echo "  Execute o menu principal → Configuração → Configurar Cron"
echo "  ou execute: sudo $SCRIPT_DIR/../scripts-auxiliares/configurar-cron.sh"
echo ""
