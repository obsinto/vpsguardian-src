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

# Criar backup do arquivo de configuração existente
if [ -f "$CONFIG_FILE" ]; then
    BACKUP_CONFIG="${CONFIG_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
    cp "$CONFIG_FILE" "$BACKUP_CONFIG"
    log_info "Backup da configuração atual: $BACKUP_CONFIG"
    echo ""
fi

# Carregar configuração existente se houver
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
fi

log_info "Configure os destinos para onde os backups via dump serão enviados automaticamente."
echo ""

# ========== LOCAL ==========
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}1️⃣  BACKUP LOCAL${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
read -p "$(echo -e ${BLUE}Manter backups locais? \(Y/n\):${NC} )" KEEP_LOCAL
KEEP_LOCAL=${KEEP_LOCAL:-Y}
BACKUP_DEST_LOCAL=$([[ "$KEEP_LOCAL" =~ ^[Yy]$ ]] && echo "true" || echo "false")

if [ "$BACKUP_DEST_LOCAL" = "true" ]; then
    read -p "$(echo -e ${BLUE}Retenção local em dias \(padrão: 30\):${NC} )" RETENTION
    LOCAL_BACKUP_RETENTION_DAYS=${RETENTION:-30}
fi
echo ""

# ========== SSH ==========
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}2️⃣  BACKUP REMOTO VIA SSH (Self-hosted)${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
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

# ========== GOOGLE DRIVE ==========
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}3️⃣  GOOGLE DRIVE (via rclone)${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

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
echo ""

# ========== AWS S3 ==========
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}4️⃣  AWS S3${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Verificar se aws-cli está instalado
if ! command -v aws &> /dev/null; then
    log_warning "AWS CLI não está instalado"
    echo "Instale com: sudo apt install awscli -y"
    echo "Configure com: aws configure"
    S3_ENABLED=false
    BACKUP_DEST_AWS_S3=false
else
    # Verificar se AWS está configurado
    if [ ! -f ~/.aws/credentials ]; then
        log_warning "AWS CLI não está configurado"
        echo "Execute: aws configure"
        S3_ENABLED=false
        BACKUP_DEST_AWS_S3=false
    else
        read -p "$(echo -e ${BLUE}Habilitar backup no AWS S3? \(y/N\):${NC} )" ENABLE_S3
        ENABLE_S3=${ENABLE_S3:-N}

        if [[ "$ENABLE_S3" =~ ^[Yy]$ ]]; then
            S3_ENABLED=true
            BACKUP_DEST_AWS_S3=true

            read -p "$(echo -e ${BLUE}Nome do bucket S3 \(sem s3://\):${NC} )" S3_BUCKET_NAME
            S3_BUCKET="$S3_BUCKET_NAME"

            read -p "$(echo -e ${BLUE}Prefixo/pasta \(padrão: backups/vpsguardian/databases\):${NC} )" S3_PATH
            S3_PREFIX=${S3_PATH:-backups/vpsguardian/databases}

            read -p "$(echo -e ${BLUE}Região \(padrão: us-east-1\):${NC} )" S3_REG
            S3_REGION=${S3_REG:-us-east-1}

            read -p "$(echo -e ${BLUE}Storage Class \(STANDARD/STANDARD_IA/GLACIER, padrão: STANDARD_IA\):${NC} )" S3_CLASS
            S3_STORAGE_CLASS=${S3_CLASS:-STANDARD_IA}

            # Testar acesso ao bucket
            log_info "Testando acesso ao bucket S3..."
            if aws s3 ls "s3://$S3_BUCKET" --region "$S3_REGION" >/dev/null 2>&1; then
                log_success "Acesso ao bucket S3 confirmado!"
            else
                log_error "Falha ao acessar bucket. Verifique credenciais e nome do bucket."
                read -p "Deseja continuar mesmo assim? (y/N): " CONTINUE
                if [[ ! "$CONTINUE" =~ ^[Yy]$ ]]; then
                    S3_ENABLED=false
                    BACKUP_DEST_AWS_S3=false
                fi
            fi
        else
            S3_ENABLED=false
            BACKUP_DEST_AWS_S3=false
        fi
    fi
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
[ "$BACKUP_DEST_LOCAL" = "true" ] && echo "  ✅ Local (Retenção: $LOCAL_BACKUP_RETENTION_DAYS dias)" || echo "  ❌ Local"
[ "$BACKUP_DEST_SSH" = "true" ] && echo "  ✅ SSH → $SSH_REMOTE_USER@$SSH_REMOTE_SERVER:$SSH_REMOTE_DIR" || echo "  ❌ SSH"
[ "$BACKUP_DEST_GOOGLE_DRIVE" = "true" ] && echo "  ✅ Google Drive → ${GDRIVE_REMOTE_NAME}:${GDRIVE_DIR}" || echo "  ❌ Google Drive"
[ "$BACKUP_DEST_AWS_S3" = "true" ] && echo "  ✅ AWS S3 → s3://${S3_BUCKET}/${S3_PREFIX}" || echo "  ❌ AWS S3"
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
SSH_REMOTE_ENABLED=$SSH_REMOTE_ENABLED
SSH_REMOTE_SERVER="$SSH_REMOTE_SERVER"
SSH_REMOTE_USER="$SSH_REMOTE_USER"
SSH_REMOTE_PORT="$SSH_REMOTE_PORT"
SSH_REMOTE_DIR="$SSH_REMOTE_DIR"
SSH_KEY_PATH="$SSH_KEY_PATH"

# ========== CONFIGURAÇÕES GOOGLE DRIVE (rclone) ==========
GDRIVE_ENABLED=$GDRIVE_ENABLED
GDRIVE_REMOTE_NAME="$GDRIVE_REMOTE_NAME"
GDRIVE_DIR="$GDRIVE_DIR"

# ========== CONFIGURAÇÕES AWS S3 ==========
S3_ENABLED=$S3_ENABLED
S3_BUCKET="$S3_BUCKET"
S3_PREFIX="$S3_PREFIX"
S3_REGION="$S3_REGION"
S3_STORAGE_CLASS="$S3_STORAGE_CLASS"

# ========== RETENÇÃO DE BACKUPS LOCAIS ==========
REMOVE_LOCAL_AFTER_UPLOAD=$REMOVE_LOCAL_AFTER_UPLOAD
LOCAL_BACKUP_RETENTION_DAYS=$LOCAL_BACKUP_RETENTION_DAYS

# ========== OPÇÕES DE BACKUP ==========
# Incluir banco de dados do Coolify (coolify-db) nos backups automáticos?
BACKUP_INCLUDE_COOLIFY=$BACKUP_INCLUDE_COOLIFY

# ========== NOTIFICAÇÕES ==========
WEBHOOK_URL="$WEBHOOK_URL"
NOTIFICATION_EMAIL="$NOTIFICATION_EMAIL"
EOF

chmod 600 "$CONFIG_FILE"
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
