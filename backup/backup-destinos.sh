#!/bin/bash
################################################################################
# Script de Upload de Backup para Múltiplos Destinos
# Suporta: Self-hosted, Google Drive (rclone), AWS S3/R2/MinIO
# Uso: ./backup-destinos.sh [arquivo_backup.tar.gz] [--dest=DESTINO]
#      DESTINO: self-hosted, google-drive, aws-s3, all
################################################################################

set -e

LOG_PREFIX="[ Backup Upload ]"

# Funções de log
log() {
    echo "$LOG_PREFIX [ $1 ] $2"
}
log_info() {
    echo "$LOG_PREFIX [ INFO ] $*"
}
log_success() {
    echo "$LOG_PREFIX [ OK ] $*"
}
log_error() {
    echo "$LOG_PREFIX [ ERRO ] $*"
}
log_warning() {
    echo "$LOG_PREFIX [ AVISO ] $*"
}

# Carregar configurações de destino
CONFIG_FILE="/opt/vpsguardian/config/backup-destinations.conf"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
fi

# Verificar argumentos
BACKUP_FILE=""
DEST_AUTO=""

for arg in "$@"; do
    case $arg in
        --dest=*)
            DEST_AUTO="${arg#*=}"
            shift
            ;;
        *)
            if [ -z "$BACKUP_FILE" ]; then
                BACKUP_FILE="$arg"
            fi
            ;;
    esac
done

# Verificar se arquivo foi passado como argumento
if [ -z "$BACKUP_FILE" ]; then
    echo "$LOG_PREFIX [ ERROR ] Uso: $0 <arquivo_backup.tar.gz> [--dest=DESTINO]"
    echo "DESTINO: self-hosted, google-drive, aws-s3, all"
    exit 1
fi

# Verificar se arquivo existe
if [ ! -f "$BACKUP_FILE" ]; then
    log_error "Arquivo não encontrado: $BACKUP_FILE"
    exit 1
fi

BACKUP_FILENAME=$(basename "$BACKUP_FILE")
BACKUP_SIZE=$(du -h "$BACKUP_FILE" | cut -f1)

log_info "Arquivo: $BACKUP_FILENAME ($BACKUP_SIZE)"
echo ""

# Se destino foi especificado via --dest, usar automaticamente
if [ -n "$DEST_AUTO" ]; then
    case $DEST_AUTO in
        self-hosted)
            CHOICE=1
            log_info "Modo automático: Self-hosted"
            ;;
        google-drive)
            CHOICE=2
            log_info "Modo automático: Google Drive"
            ;;
        aws-s3)
            CHOICE=3
            log_info "Modo automático: AWS S3"
            ;;
        all)
            CHOICE=4
            log_info "Modo automático: Todos os destinos"
            ;;
        *)
            log_error "Destino inválido: $DEST_AUTO"
            log_error "Use: self-hosted, google-drive, aws-s3, all"
            exit 1
            ;;
    esac
else
    # Menu de seleção de destinos
    echo "$LOG_PREFIX [ INFO ] Selecione os destinos de backup:"
    echo ""
    echo "  [1] Self-hosted (servidor remoto via SSH)"
    echo "  [2] Google Drive (via rclone)"
    echo "  [3] AWS S3"
    echo "  [4] Todos os destinos"
    echo "  [0] Cancelar"
    echo ""

    read -p "$LOG_PREFIX [ INPUT ] Escolha uma opção (0-4): " CHOICE
fi

case $CHOICE in
    0)
        log_info "Operação cancelada pelo usuário"
        exit 0
        ;;
    1)
        UPLOAD_SELFHOSTED=true
        ;;
    2)
        UPLOAD_GDRIVE=true
        ;;
    3)
        UPLOAD_S3=true
        ;;
    4)
        UPLOAD_SELFHOSTED=true
        UPLOAD_GDRIVE=true
        UPLOAD_S3=true
        ;;
    *)
        log_error "Opção inválida"
        exit 1
        ;;
esac

echo ""
SUCCESS_COUNT=0
FAIL_COUNT=0

################################################################################
# SELF-HOSTED (SSH/SCP)
################################################################################

if [ "$UPLOAD_SELFHOSTED" = true ]; then
    log_info "========== UPLOAD SELF-HOSTED =========="
    echo ""

    read -p "$LOG_PREFIX [ INPUT ] IP do servidor remoto: " REMOTE_IP
    read -p "$LOG_PREFIX [ INPUT ] Usuário SSH (padrão: root): " REMOTE_USER
    REMOTE_USER=${REMOTE_USER:-root}
    read -p "$LOG_PREFIX [ INPUT ] Porta SSH (padrão: 22): " REMOTE_PORT
    REMOTE_PORT=${REMOTE_PORT:-22}
    read -p "$LOG_PREFIX [ INPUT ] Diretório de destino (padrão: /root/backups): " REMOTE_DIR
    REMOTE_DIR=${REMOTE_DIR:-/root/backups}

    log_info "Testando conexão SSH..."
    if ssh -p "$REMOTE_PORT" -o ConnectTimeout=10 "$REMOTE_USER@$REMOTE_IP" "exit" 2>/dev/null; then
        log_success "Conexão SSH estabelecida"

        # Criar diretório remoto se não existir
        log_info "Criando diretório remoto se necessário..."
        ssh -p "$REMOTE_PORT" "$REMOTE_USER@$REMOTE_IP" "mkdir -p $REMOTE_DIR"

        # Upload do arquivo
        log_info "Enviando backup para $REMOTE_USER@$REMOTE_IP:$REMOTE_DIR..."
        if scp -P "$REMOTE_PORT" "$BACKUP_FILE" "$REMOTE_USER@$REMOTE_IP:$REMOTE_DIR/"; then
            log_success "Upload self-hosted concluído!"
            ((SUCCESS_COUNT++))
        else
            log_error "Falha no upload self-hosted"
            ((FAIL_COUNT++))
        fi
    else
        log_error "Falha na conexão SSH com $REMOTE_IP"
        ((FAIL_COUNT++))
    fi
    echo ""
fi

################################################################################
# GOOGLE DRIVE (RCLONE)
################################################################################

if [ "$UPLOAD_GDRIVE" = true ]; then
    log_info "========== UPLOAD GOOGLE DRIVE =========="
    echo ""

    # Verificar se rclone está instalado
    if ! command -v rclone &> /dev/null; then
        log_error "rclone não está instalado"
        log_info "Instale com: curl https://rclone.org/install.sh | sudo bash"
        ((FAIL_COUNT++))
    else
        # Verificar se já existe configuração do Google Drive
        if ! rclone listremotes | grep -q "gdrive:"; then
            log_info "Configuração do Google Drive não encontrada"
            log_info "Execute: rclone config"
            log_info "Escolha: Google Drive, nome do remote: gdrive"

            read -p "$LOG_PREFIX [ INPUT ] Deseja configurar agora? (y/N): " CONFIG_NOW
            if [ "$CONFIG_NOW" = "y" ]; then
                rclone config
            else
                log_error "Upload para Google Drive cancelado - configure rclone primeiro"
                ((FAIL_COUNT++))
            fi
        fi

        # Se configuração existe, fazer upload
        if rclone listremotes | grep -q "gdrive:"; then
            read -p "$LOG_PREFIX [ INPUT ] Diretório no Google Drive (padrão: backups/coolify): " GDRIVE_DIR
            GDRIVE_DIR=${GDRIVE_DIR:-backups/coolify}

            log_info "Enviando backup para Google Drive: $GDRIVE_DIR..."
            if rclone copy "$BACKUP_FILE" "gdrive:$GDRIVE_DIR" --progress; then
                log_success "Upload para Google Drive concluído!"
                ((SUCCESS_COUNT++))
            else
                log_error "Falha no upload para Google Drive"
                ((FAIL_COUNT++))
            fi
        fi
    fi
    echo ""
fi

################################################################################
# AWS S3
################################################################################

if [ "$UPLOAD_S3" = true ]; then
    log_info "========== UPLOAD AWS S3 =========="
    echo ""

    # Verificar se aws-cli está instalado
    if ! command -v aws &> /dev/null; then
        log_error "AWS CLI não está instalado"
        log_info "Instale com o instalador oficial (AWS CLI v2):"
        log_info "  sudo apt update && sudo apt install unzip -y"
        log_info "  curl \"https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip\" -o \"awscliv2.zip\""
        log_info "  unzip awscliv2.zip && sudo ./aws/install"
        log_info "Configure com: aws configure"
        ((FAIL_COUNT++))
    else
        # Verificar se AWS CLI está configurado
        if [ ! -f ~/.aws/credentials ]; then
            log_error "AWS CLI não está configurado"
            log_info "Execute: aws configure"
            log_info "Você precisará de: Access Key ID, Secret Access Key, Region"

            read -p "$LOG_PREFIX [ INPUT ] Deseja configurar agora? (y/N): " CONFIG_NOW
            if [ "$CONFIG_NOW" = "y" ]; then
                aws configure
            else
                log_error "Upload para S3 cancelado - configure AWS CLI primeiro"
                ((FAIL_COUNT++))
            fi
        fi

        # Se configuração existe, fazer upload
        if [ -f ~/.aws/credentials ]; then
            # Usar configurações salvas ou perguntar interativamente
            if [ -z "$S3_BUCKET" ]; then
                read -p "$LOG_PREFIX [ INPUT ] Nome do bucket S3: " S3_BUCKET
            else
                log_info "Usando bucket configurado: $S3_BUCKET"
            fi

            if [ -z "$S3_PREFIX" ]; then
                read -p "$LOG_PREFIX [ INPUT ] Prefixo/pasta (padrão: backups/coolify): " S3_PREFIX
                S3_PREFIX=${S3_PREFIX:-backups/coolify}
            else
                log_info "Usando prefixo configurado: $S3_PREFIX"
            fi

            # Montar comando com endpoint se configurado (R2, MinIO, etc)
            AWS_CMD="aws s3 cp \"$BACKUP_FILE\" \"s3://$S3_BUCKET/$S3_PREFIX/$BACKUP_FILENAME\""
            if [ -n "$S3_ENDPOINT" ]; then
                AWS_CMD="aws s3 cp \"$BACKUP_FILE\" \"s3://$S3_BUCKET/$S3_PREFIX/$BACKUP_FILENAME\" --endpoint-url \"$S3_ENDPOINT\""
                log_info "Usando endpoint customizado: $S3_ENDPOINT"
            fi

            log_info "Enviando backup para S3: s3://$S3_BUCKET/$S3_PREFIX/..."
            if eval $AWS_CMD; then
                log_success "Upload para S3 concluído!"

                # Configurar lifecycle policy (opcional)
                read -p "$LOG_PREFIX [ INPUT ] Configurar expiração automática? (y/N): " CONFIGURE_LIFECYCLE
                if [ "$CONFIGURE_LIFECYCLE" = "y" ]; then
                    read -p "$LOG_PREFIX [ INPUT ] Dias para expiração (padrão: 30): " EXPIRE_DAYS
                    EXPIRE_DAYS=${EXPIRE_DAYS:-30}

                    log_info "Configurando lifecycle policy para $EXPIRE_DAYS dias..."
                    cat > /tmp/s3-lifecycle.json <<EOF
{
  "Rules": [
    {
      "Id": "DeleteOldBackups",
      "Prefix": "$S3_PREFIX/",
      "Status": "Enabled",
      "Expiration": {
        "Days": $EXPIRE_DAYS
      }
    }
  ]
}
EOF
                    aws s3api put-bucket-lifecycle-configuration \
                        --bucket "$S3_BUCKET" \
                        --lifecycle-configuration file:///tmp/s3-lifecycle.json
                    rm /tmp/s3-lifecycle.json
                    log_success "Lifecycle policy configurada"
                fi

                ((SUCCESS_COUNT++))
            else
                log_error "Falha no upload para S3"
                ((FAIL_COUNT++))
            fi
        fi
    fi
    echo ""
fi

################################################################################
# RESUMO
################################################################################

log_info "========== RESUMO =========="
log_success "Uploads bem-sucedidos: $SUCCESS_COUNT"
if [ $FAIL_COUNT -gt 0 ]; then
    log_error "Uploads falhados: $FAIL_COUNT"
fi

if [ $SUCCESS_COUNT -eq 0 ]; then
    log_error "Nenhum upload foi realizado com sucesso"
    exit 1
else
    log_success "Backup enviado com sucesso para $SUCCESS_COUNT destino(s)"
fi
