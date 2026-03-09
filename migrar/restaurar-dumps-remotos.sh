#!/bin/bash
################################################################################
# Script: restaurar-dumps-remotos.sh
# Propósito: Baixar dumps SQL de S3/Google Drive e restaurar usando restore-databases-dump.sh
# Uso: ./restaurar-dumps-remotos.sh [--source=s3|gdrive]
#
# Este script:
#   1. Lista lotes de dumps disponíveis no S3 ou Google Drive
#   2. Permite escolher qual lote baixar
#   3. Baixa o lote selecionado
#   4. Chama restore-databases-dump.sh com menu interativo completo
################################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh" 2>/dev/null || {
    log_info() { echo "[ INFO ] $*"; }
    log_success() { echo "[ OK ] $*"; }
    log_error() { echo "[ ERRO ] $*"; }
    log_warning() { echo "[ AVISO ] $*"; }
    log_section() { echo ""; echo "========== $* =========="; echo ""; }
}

# Carregar configurações
if [ -f "/opt/vpsguardian/config/backup-destinations.conf" ]; then
    source "/opt/vpsguardian/config/backup-destinations.conf"
fi

### ========== CONFIGURAÇÃO ==========
SOURCE=""  # s3, gdrive, ou ssh
TEMP_DIR="/tmp/restore-dumps-$$"
LOCAL_RESTORE_DIR="/var/backups/vpsguardian/restore-remote"
AUTO_CLEANUP=true

### ========== PARSE ARGUMENTOS ==========
while [[ $# -gt 0 ]]; do
    case $1 in
        --source=*) SOURCE="${1#*=}"; shift ;;
        --no-cleanup) AUTO_CLEANUP=false; shift ;;
        -h|--help)
            cat << 'EOF'
╔════════════════════════════════════════════════════════════════╗
║         RESTAURAR DUMPS SQL DE ORIGEM REMOTA                   ║
╚════════════════════════════════════════════════════════════════╝

DESCRIÇÃO:
  Baixa lotes de dumps SQL de S3/Google Drive e restaura usando
  o menu interativo do restore-databases-dump.sh

USO:
  ./restaurar-dumps-remotos.sh [--source=ORIGEM]

OPÇÕES:
  --source=s3          Baixar do AWS S3
  --source=gdrive      Baixar do Google Drive (rclone)
  --source=ssh         Baixar de servidor SSH
  --no-cleanup         Não deletar arquivos baixados após restore
  -h, --help           Mostrar esta ajuda

EXEMPLOS:
  # Via menu interativo (escolhe a origem)
  ./restaurar-dumps-remotos.sh

  # Direto do S3
  ./restaurar-dumps-remotos.sh --source=s3

  # Direto do Google Drive
  ./restaurar-dumps-remotos.sh --source=gdrive

PRÉ-REQUISITOS:
  • AWS S3: AWS CLI instalado e configurado
  • Google Drive: rclone instalado e configurado
  • SSH: Chave SSH configurada

IMPORTANTE:
  Após baixar, você terá controle total no restore:
  - Restaurar tudo
  - Restaurar tudo EXCETO Coolify
  - Escolher dumps específicos

EOF
            exit 0
            ;;
        *) log_error "Opção desconhecida: $1"; exit 1 ;;
    esac
done

### ========== APRESENTAÇÃO ==========
clear
echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║       RESTAURAR DUMPS SQL DE ORIGEM REMOTA                     ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

### ========== ESCOLHER ORIGEM ==========
if [ -z "$SOURCE" ]; then
    log_section "Escolha a Origem dos Dumps"

    echo "De onde você deseja baixar os dumps SQL?"
    echo ""
    echo "  [1] AWS S3"
    echo "  [2] Google Drive (rclone)"
    echo "  [3] Servidor SSH (rsync/scp)"
    echo "  [0] Cancelar"
    echo ""
    read -p "Escolha uma opção (0-3): " source_choice

    case "$source_choice" in
        1) SOURCE="s3" ;;
        2) SOURCE="gdrive" ;;
        3) SOURCE="ssh" ;;
        0) log_info "Operação cancelada"; exit 0 ;;
        *) log_error "Opção inválida"; exit 1 ;;
    esac
    echo ""
fi

### ========== VALIDAR FERRAMENTAS ==========
log_section "Validando Ferramentas"

case "$SOURCE" in
    s3)
        if ! command -v aws &> /dev/null; then
            log_error "AWS CLI não está instalado"
            echo "Instale com: sudo apt install awscli -y"
            echo "Configure com: aws configure"
            exit 1
        fi

        if [ ! -f ~/.aws/credentials ]; then
            log_error "AWS CLI não está configurado"
            echo "Configure com: aws configure"
            exit 1
        fi

        # Usar configuração ou perguntar
        if [ -z "$S3_BUCKET" ]; then
            read -p "Nome do bucket S3: " S3_BUCKET
            read -p "Prefixo/pasta (padrão: backups/vpsguardian/databases): " S3_PREFIX
            S3_PREFIX=${S3_PREFIX:-backups/vpsguardian/databases}
        fi

        log_info "Testando acesso ao S3..."
        if ! aws s3 ls "s3://$S3_BUCKET/$S3_PREFIX/" >/dev/null 2>&1; then
            log_error "Falha ao acessar s3://$S3_BUCKET/$S3_PREFIX/"
            echo "Verifique o nome do bucket e as credenciais AWS"
            exit 1
        fi

        log_success "AWS S3 configurado: s3://$S3_BUCKET/$S3_PREFIX/"
        ;;

    gdrive)
        if ! command -v rclone &> /dev/null; then
            log_error "rclone não está instalado"
            echo "Instale com: curl https://rclone.org/install.sh | sudo bash"
            exit 1
        fi

        # Usar configuração ou perguntar
        if [ -z "$GDRIVE_REMOTE_NAME" ]; then
            echo "Remotes disponíveis:"
            rclone listremotes
            echo ""
            read -p "Nome do remote (padrão: gdrive): " GDRIVE_REMOTE_NAME
            GDRIVE_REMOTE_NAME=${GDRIVE_REMOTE_NAME:-gdrive}
        fi

        if [ -z "$GDRIVE_DIR" ]; then
            read -p "Diretório no Google Drive (padrão: backups/vpsguardian/databases): " GDRIVE_DIR
            GDRIVE_DIR=${GDRIVE_DIR:-backups/vpsguardian/databases}
        fi

        log_info "Testando acesso ao Google Drive..."
        if ! rclone lsd "${GDRIVE_REMOTE_NAME}:${GDRIVE_DIR}" >/dev/null 2>&1; then
            log_error "Falha ao acessar ${GDRIVE_REMOTE_NAME}:${GDRIVE_DIR}"
            echo "Verifique a configuração do rclone"
            exit 1
        fi

        log_success "Google Drive configurado: ${GDRIVE_REMOTE_NAME}:${GDRIVE_DIR}"
        ;;

    ssh)
        # Usar configuração ou perguntar
        if [ -z "$SSH_REMOTE_SERVER" ]; then
            read -p "IP/Hostname do servidor remoto: " SSH_REMOTE_SERVER
            read -p "Usuário SSH (padrão: root): " SSH_REMOTE_USER
            SSH_REMOTE_USER=${SSH_REMOTE_USER:-root}
            read -p "Porta SSH (padrão: 22): " SSH_REMOTE_PORT
            SSH_REMOTE_PORT=${SSH_REMOTE_PORT:-22}
            read -p "Diretório remoto (padrão: /var/backups/vpsguardian/databases): " SSH_REMOTE_DIR
            SSH_REMOTE_DIR=${SSH_REMOTE_DIR:-/var/backups/vpsguardian/databases}
        fi

        log_info "Testando conexão SSH..."
        if ! ssh -p "$SSH_REMOTE_PORT" -o ConnectTimeout=10 "$SSH_REMOTE_USER@$SSH_REMOTE_SERVER" "exit" 2>/dev/null; then
            log_error "Falha na conexão SSH com $SSH_REMOTE_USER@$SSH_REMOTE_SERVER:$SSH_REMOTE_PORT"
            exit 1
        fi

        log_success "SSH configurado: $SSH_REMOTE_USER@$SSH_REMOTE_SERVER:$SSH_REMOTE_DIR"
        ;;
esac

echo ""

### ========== LISTAR LOTES DISPONÍVEIS ==========
log_section "Lotes de Dumps Disponíveis"

declare -a LOTE_NAMES
declare -a LOTE_SIZES
declare -a LOTE_DATES

log_info "Buscando lotes disponíveis..."

case "$SOURCE" in
    s3)
        # Listar arquivos .tar.gz no S3
        while IFS= read -r line; do
            if [[ "$line" =~ lote-.*\.tar\.gz$ ]]; then
                filename=$(echo "$line" | awk '{print $4}')
                size=$(echo "$line" | awk '{print $3}')
                date=$(echo "$line" | awk '{print $1" "$2}')

                LOTE_NAMES+=("$filename")
                LOTE_SIZES+=("$size")
                LOTE_DATES+=("$date")
            fi
        done < <(aws s3 ls "s3://$S3_BUCKET/$S3_PREFIX/" 2>/dev/null)
        ;;

    gdrive)
        # Listar arquivos .tar.gz no Google Drive
        while IFS= read -r line; do
            if [[ "$line" =~ lote-.*\.tar\.gz$ ]]; then
                # rclone lsl retorna: size date time filename
                size=$(echo "$line" | awk '{print $1}')
                date=$(echo "$line" | awk '{print $2" "$3}')
                filename=$(echo "$line" | awk '{print $4}')

                # Converter size para formato legível
                size_mb=$((size / 1024 / 1024))
                size="${size_mb}M"

                LOTE_NAMES+=("$filename")
                LOTE_SIZES+=("$size")
                LOTE_DATES+=("$date")
            fi
        done < <(rclone lsl "${GDRIVE_REMOTE_NAME}:${GDRIVE_DIR}" 2>/dev/null | grep "lote-.*\.tar\.gz$")
        ;;

    ssh)
        # Listar arquivos .tar.gz no servidor SSH
        while IFS= read -r line; do
            if [[ "$line" =~ lote-.*\.tar\.gz$ ]]; then
                filename=$(basename "$line")
                size=$(ssh -p "$SSH_REMOTE_PORT" "$SSH_REMOTE_USER@$SSH_REMOTE_SERVER" "du -h '$line' 2>/dev/null" | cut -f1)
                date=$(ssh -p "$SSH_REMOTE_PORT" "$SSH_REMOTE_USER@$SSH_REMOTE_SERVER" "stat -c %y '$line' 2>/dev/null" | cut -d'.' -f1)

                LOTE_NAMES+=("$filename")
                LOTE_SIZES+=("$size")
                LOTE_DATES+=("$date")
            fi
        done < <(ssh -p "$SSH_REMOTE_PORT" "$SSH_REMOTE_USER@$SSH_REMOTE_SERVER" "find '$SSH_REMOTE_DIR' -name 'lote-*.tar.gz' -type f 2>/dev/null" | sort -r)
        ;;
esac

if [ ${#LOTE_NAMES[@]} -eq 0 ]; then
    log_warning "Nenhum lote de dumps encontrado na origem remota"
    exit 0
fi

echo ""
log_success "${#LOTE_NAMES[@]} lote(s) encontrado(s):"
echo ""

for i in "${!LOTE_NAMES[@]}"; do
    echo "  [$i] ${LOTE_NAMES[$i]}"
    echo "      Tamanho: ${LOTE_SIZES[$i]} | Data: ${LOTE_DATES[$i]}"
    echo ""
done

### ========== ESCOLHER LOTE ==========
read -p "Selecione o número do lote para baixar (ou 'q' para cancelar): " lote_choice

if [ "$lote_choice" = "q" ]; then
    log_info "Operação cancelada"
    exit 0
fi

if ! [[ "$lote_choice" =~ ^[0-9]+$ ]] || [ "$lote_choice" -ge "${#LOTE_NAMES[@]}" ]; then
    log_error "Seleção inválida"
    exit 1
fi

SELECTED_LOTE="${LOTE_NAMES[$lote_choice]}"
log_info "Selecionado: $SELECTED_LOTE"
echo ""

### ========== BAIXAR LOTE ==========
log_section "Download do Lote"

mkdir -p "$LOCAL_RESTORE_DIR"
DOWNLOAD_FILE="$LOCAL_RESTORE_DIR/$SELECTED_LOTE"

log_info "Baixando para: $DOWNLOAD_FILE"
echo ""

case "$SOURCE" in
    s3)
        aws s3 cp "s3://$S3_BUCKET/$S3_PREFIX/$SELECTED_LOTE" "$DOWNLOAD_FILE" --progress
        ;;

    gdrive)
        rclone copy "${GDRIVE_REMOTE_NAME}:${GDRIVE_DIR}/$SELECTED_LOTE" "$LOCAL_RESTORE_DIR/" --progress
        ;;

    ssh)
        scp -P "$SSH_REMOTE_PORT" \
            "$SSH_REMOTE_USER@$SSH_REMOTE_SERVER:$SSH_REMOTE_DIR/$SELECTED_LOTE" \
            "$DOWNLOAD_FILE"
        ;;
esac

if [ $? -ne 0 ]; then
    log_error "Falha no download"
    exit 1
fi

log_success "Download concluído: $(du -h "$DOWNLOAD_FILE" | cut -f1)"
echo ""

### ========== EXTRAIR LOTE ==========
log_section "Extraindo Lote"

EXTRACT_DIR="$LOCAL_RESTORE_DIR/$(basename "$SELECTED_LOTE" .tar.gz)"
mkdir -p "$EXTRACT_DIR"

log_info "Extraindo para: $EXTRACT_DIR"
tar -xzf "$DOWNLOAD_FILE" -C "$EXTRACT_DIR" --strip-components=1 2>/dev/null

if [ $? -ne 0 ]; then
    log_error "Falha ao extrair arquivo"
    exit 1
fi

# Contar dumps extraídos
DUMP_COUNT=$(find "$EXTRACT_DIR" -name "*.sql.gz" -o -name "*.rdb.gz" -o -name "*.tar.gz" | wc -l)
log_success "Extraído: $DUMP_COUNT dump(s)"
echo ""

### ========== RESTAURAR ==========
log_section "Iniciar Restauração"

log_info "Chamando restore-databases-dump.sh com menu interativo..."
echo ""
echo "════════════════════════════════════════════════════════════════"
echo "  Você terá CONTROLE TOTAL sobre o que restaurar:"
echo "  • Opção 1: Restaurar TUDO (incluindo Coolify)"
echo "  • Opção 2: Restaurar TUDO EXCETO Coolify ⭐ RECOMENDADO"
echo "  • Opção 3: Escolher dumps específicos"
echo "════════════════════════════════════════════════════════════════"
echo ""
read -p "Pressione ENTER para continuar..."

# Chamar script de restore
RESTORE_SCRIPT="$SCRIPT_DIR/restore-databases-dump.sh"

if [ ! -x "$RESTORE_SCRIPT" ]; then
    log_error "Script de restore não encontrado: $RESTORE_SCRIPT"
    exit 1
fi

bash "$RESTORE_SCRIPT" --dir="$EXTRACT_DIR"
RESTORE_EXIT_CODE=$?

echo ""

### ========== LIMPEZA ==========
if [ "$AUTO_CLEANUP" = true ]; then
    log_section "Limpeza"

    read -p "Remover arquivos baixados? (S/n): " cleanup_choice
    cleanup_choice=${cleanup_choice:-S}

    if [[ "$cleanup_choice" =~ ^[Ss]$ ]]; then
        log_info "Removendo arquivos temporários..."
        rm -f "$DOWNLOAD_FILE"
        rm -rf "$EXTRACT_DIR"
        log_success "Limpeza concluída"
    else
        log_info "Arquivos mantidos em:"
        echo "  • Tarball: $DOWNLOAD_FILE"
        echo "  • Extraído: $EXTRACT_DIR"
    fi
fi

echo ""

### ========== RESUMO FINAL ==========
log_section "RESUMO"
echo ""
if [ $RESTORE_EXIT_CODE -eq 0 ]; then
    log_success "Restauração concluída com sucesso!"
else
    log_warning "Restauração concluída com avisos (código: $RESTORE_EXIT_CODE)"
fi
echo ""
echo "  📥 Origem: $SOURCE"
echo "  📦 Lote: $SELECTED_LOTE"
echo "  💾 Dumps processados: $DUMP_COUNT"
echo ""

exit $RESTORE_EXIT_CODE
