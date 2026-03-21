#!/bin/bash
################################################################################
# Script: restaurar-coolify.sh
# Propósito: Interface UNIFICADA para restauração do Coolify de qualquer origem
#
# Origens suportadas:
#   - Local: Backup em /var/backups/vpsguardian/coolify
#   - AWS S3: Bucket S3 configurado
#   - Google Drive: Via rclone
#
# Uso: ./restaurar-coolify.sh [--source=local|s3|gdrive]
#
# Versão: 1.0.0
################################################################################

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh" 2>/dev/null || {
    log_info() { echo -e "\033[0;34m[ INFO ]\033[0m $*"; }
    log_success() { echo -e "\033[0;32m[ OK ]\033[0m $*"; }
    log_error() { echo -e "\033[0;31m[ ERRO ]\033[0m $*"; }
    log_warning() { echo -e "\033[1;33m[ AVISO ]\033[0m $*"; }
    log_section() { echo ""; echo -e "\033[0;34m========== $* ==========\033[0m"; echo ""; }
}

# Carregar configurações
BACKUP_DEST_CONFIG="/opt/vpsguardian/config/backup-destinations.conf"
if [ -f "$BACKUP_DEST_CONFIG" ]; then
    source "$BACKUP_DEST_CONFIG"
fi

### ========== CONFIGURAÇÃO ==========
SOURCE=""
BACKUP_LOCAL_DIR="${COOLIFY_BACKUP_DIR:-/var/backups/vpsguardian/coolify}"

### ========== PARSE ARGUMENTOS ==========
while [[ $# -gt 0 ]]; do
    case $1 in
        --source=*) SOURCE="${1#*=}"; shift ;;
        --local) SOURCE="local"; shift ;;
        --s3) SOURCE="s3"; shift ;;
        --gdrive) SOURCE="gdrive"; shift ;;
        -h|--help)
            cat << 'EOF'
================================================================================
     RESTAURAR COOLIFY - Interface Unificada
================================================================================

DESCRIÇÃO:
  Restaura instalação completa do Coolify de qualquer origem configurada.

USO:
  ./restaurar-coolify.sh [--source=ORIGEM]

OPÇÕES:
  --source=local     Restaurar de backup local
  --source=s3        Restaurar de AWS S3
  --source=gdrive    Restaurar de Google Drive (rclone)
  -h, --help         Mostrar esta ajuda

  Sem argumentos: Menu interativo para escolher origem

EXEMPLOS:
  # Menu interativo
  ./restaurar-coolify.sh

  # Direto do local
  ./restaurar-coolify.sh --source=local

  # Direto do S3
  ./restaurar-coolify.sh --source=s3

O QUE SERÁ RESTAURADO:
  - Banco de dados do Coolify (PostgreSQL)
  - Chaves SSH
  - Configurações (.env)
  - Volumes (se disponíveis)

EOF
            exit 0
            ;;
        *)
            log_error "Opção desconhecida: $1"
            exit 1
            ;;
    esac
done

### ========== BANNER ==========
clear
echo ""
echo "=============================================================="
echo "     RESTAURAR COOLIFY - Interface Unificada"
echo "=============================================================="
echo ""

### ========== VERIFICAR ROOT ==========
if [ "$EUID" -ne 0 ]; then
    log_error "Este script deve ser executado como root"
    exit 1
fi

### ========== ESCOLHER ORIGEM ==========
if [ -z "$SOURCE" ]; then
    log_section "De onde deseja restaurar?"
    echo ""
    echo "  [1] Backup Local"
    echo "      Restaurar de $BACKUP_LOCAL_DIR"
    echo ""
    echo "  [2] AWS S3"
    if [ -n "$S3_BUCKET" ]; then
        echo "      Bucket configurado: $S3_BUCKET"
    else
        echo "      (Requer configuração)"
    fi
    echo ""
    echo "  [3] Google Drive"
    if [ -n "$GDRIVE_REMOTE_NAME" ]; then
        echo "      Remote configurado: ${GDRIVE_REMOTE_NAME}:${GDRIVE_DIR:-backups}"
    else
        echo "      (Requer rclone configurado)"
    fi
    echo ""
    echo "  [0] Cancelar"
    echo ""
    read -p "Escolha uma opção (0-3): " source_choice

    case "$source_choice" in
        1) SOURCE="local" ;;
        2) SOURCE="s3" ;;
        3) SOURCE="gdrive" ;;
        0) log_info "Operação cancelada"; exit 0 ;;
        *) log_error "Opção inválida"; exit 1 ;;
    esac
fi

echo ""
log_info "Origem selecionada: $SOURCE"
echo ""

### ========== RESTAURAR DO LOCAL ==========
if [ "$SOURCE" = "local" ]; then
    log_section "Restauração de Backup Local"

    # Verificar se existe script de restauração completa
    if [ -x "$SCRIPT_DIR/restaurar-completo.sh" ]; then
        exec "$SCRIPT_DIR/restaurar-completo.sh" --local
    else
        log_error "Script restaurar-completo.sh não encontrado"
        exit 1
    fi
fi

### ========== RESTAURAR DO S3 ==========
if [ "$SOURCE" = "s3" ]; then
    log_section "Restauração do AWS S3"

    # Verificar AWS CLI
    if ! command -v aws &> /dev/null; then
        log_error "AWS CLI não está instalado"
        echo ""
        echo "Instale com:"
        echo "  curl \"https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip\" -o \"awscliv2.zip\""
        echo "  unzip awscliv2.zip && sudo ./aws/install"
        exit 1
    fi

    # Verificar bucket configurado
    if [ -z "$S3_BUCKET" ]; then
        read -p "Nome do bucket S3: " S3_BUCKET
    fi

    if [ -z "$S3_BUCKET" ]; then
        log_error "Bucket S3 não informado"
        exit 1
    fi

    # Usar script existente
    if [ -x "$SCRIPT_DIR/restaurar-do-s3.sh" ]; then
        exec "$SCRIPT_DIR/restaurar-do-s3.sh" --bucket="$S3_BUCKET"
    else
        log_error "Script restaurar-do-s3.sh não encontrado"
        exit 1
    fi
fi

### ========== RESTAURAR DO GOOGLE DRIVE ==========
if [ "$SOURCE" = "gdrive" ]; then
    log_section "Restauração do Google Drive"

    # Verificar rclone
    if ! command -v rclone &> /dev/null; then
        log_error "rclone não está instalado"
        echo ""
        echo "Instale com:"
        echo "  curl https://rclone.org/install.sh | sudo bash"
        echo "  rclone config"
        exit 1
    fi

    # Verificar remote configurado
    if [ -z "$GDRIVE_REMOTE_NAME" ]; then
        echo "Remotes disponíveis:"
        rclone listremotes
        echo ""
        read -p "Nome do remote (padrão: gdrive): " GDRIVE_REMOTE_NAME
        GDRIVE_REMOTE_NAME=${GDRIVE_REMOTE_NAME:-gdrive}
    fi

    if [ -z "$GDRIVE_DIR" ]; then
        read -p "Diretório no Google Drive (padrão: backups/vpsguardian/coolify): " GDRIVE_DIR
        GDRIVE_DIR=${GDRIVE_DIR:-backups/vpsguardian/coolify}
    fi

    # Testar acesso
    log_info "Testando acesso ao Google Drive..."
    if ! rclone lsd "${GDRIVE_REMOTE_NAME}:${GDRIVE_DIR}" >/dev/null 2>&1; then
        log_error "Falha ao acessar ${GDRIVE_REMOTE_NAME}:${GDRIVE_DIR}"
        echo "Verifique a configuração do rclone"
        exit 1
    fi

    log_success "Acesso confirmado"
    echo ""

    ### Listar backups disponíveis
    log_section "Backups Disponíveis no Google Drive"

    echo "Listando backups em ${GDRIVE_REMOTE_NAME}:${GDRIVE_DIR}..."
    echo ""

    BACKUPS=()
    while IFS= read -r line; do
        if [[ "$line" =~ \.tar\.gz$ ]]; then
            BACKUPS+=("$line")
        fi
    done < <(rclone lsf "${GDRIVE_REMOTE_NAME}:${GDRIVE_DIR}" 2>/dev/null | sort -r)

    if [ ${#BACKUPS[@]} -eq 0 ]; then
        log_error "Nenhum backup encontrado no Google Drive"
        exit 1
    fi

    log_success "${#BACKUPS[@]} backup(s) encontrado(s):"
    echo ""

    for i in "${!BACKUPS[@]}"; do
        echo "  [$i] ${BACKUPS[$i]}"
    done

    echo ""
    read -p "Selecione o número do backup (0 = mais recente): " backup_choice
    backup_choice=${backup_choice:-0}

    if [ "$backup_choice" -ge "${#BACKUPS[@]}" ]; then
        log_error "Seleção inválida"
        exit 1
    fi

    SELECTED_BACKUP="${BACKUPS[$backup_choice]}"
    log_info "Selecionado: $SELECTED_BACKUP"

    ### Baixar backup
    log_section "Baixando Backup do Google Drive"

    mkdir -p "$BACKUP_LOCAL_DIR"
    DOWNLOAD_FILE="$BACKUP_LOCAL_DIR/$SELECTED_BACKUP"

    log_info "Baixando para: $DOWNLOAD_FILE"
    echo ""

    rclone copy "${GDRIVE_REMOTE_NAME}:${GDRIVE_DIR}/$SELECTED_BACKUP" "$BACKUP_LOCAL_DIR/" --progress

    if [ $? -ne 0 ]; then
        log_error "Falha no download"
        exit 1
    fi

    log_success "Download concluído"
    echo ""

    ### Usar script de restauração local
    log_section "Iniciando Restauração"

    log_info "Usando script de restauração local..."
    exec "$SCRIPT_DIR/restaurar-completo.sh" --local --coolify-dir="$BACKUP_LOCAL_DIR"
fi

log_error "Origem '$SOURCE' não reconhecida"
exit 1
