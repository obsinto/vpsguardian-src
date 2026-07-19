#!/bin/bash
################################################################################
# Script de Upload de Backup para Múltiplos Destinos
# Suporta: Self-hosted, Google Drive (rclone), AWS S3/R2/MinIO
# Uso: ./backup-destinos.sh [arquivo_backup.tar.gz] [--dest=DESTINO]
#      DESTINO: self-hosted, google-drive, aws-s3, all
################################################################################

# NÃO usar set -e aqui - queremos continuar tentando outros destinos mesmo se um falhar
# set -e

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

normalize_s3_prefix() {
    local prefix="$1"
    prefix="${prefix#/}"
    prefix="${prefix%/}"
    echo "$prefix"
}

s3_object_uri() {
    local key="$1"
    echo "s3://$S3_BUCKET/$key"
}

s3_prefix_uri() {
    local prefix
    prefix=$(normalize_s3_prefix "$1")

    if [ -n "$prefix" ]; then
        echo "s3://$S3_BUCKET/$prefix/"
    else
        echo "s3://$S3_BUCKET/"
    fi
}

run_aws() {
    if [ -n "$S3_ENDPOINT" ]; then
        aws "$@" --endpoint-url "$S3_ENDPOINT"
    else
        aws "$@"
    fi
}

s3_list_backup_objects() {
    local prefix_uri="$1"

    run_aws s3 ls "$prefix_uri" --recursive 2>/dev/null | while read -r obj_date obj_time obj_size obj_key; do
        [ -z "$obj_key" ] && continue

        case "$obj_key" in
            *.tar.gz|*.tar.gz.*)
                printf '%s\t%s\t%s\t%s\n' "$obj_date" "$obj_time" "$obj_size" "$obj_key"
                ;;
        esac
    done
}

format_bytes() {
    local bytes="${1:-0}"

    if command -v numfmt >/dev/null 2>&1; then
        numfmt --to=iec --suffix=B "$bytes"
    else
        awk -v bytes="$bytes" 'BEGIN {
            split("B KiB MiB GiB TiB", units)
            unit = 1
            while (bytes >= 1024 && unit < 5) {
                bytes = bytes / 1024
                unit++
            }
            printf "%.1f %s", bytes, units[unit]
        }'
    fi
}

delete_s3_objects() {
    local deleted=0
    local failed=0
    local entry
    local obj_key
    local obj_size
    local obj_size_fmt

    for entry in "$@"; do
        IFS=$'\t' read -r obj_size obj_key <<< "$entry"
        obj_size="${obj_size:-0}"
        obj_size_fmt=$(format_bytes "$obj_size")

        log_info "Removendo backup antigo do S3/R2: s3://$S3_BUCKET/$obj_key ($obj_size_fmt)"
        if run_aws s3 rm "$(s3_object_uri "$obj_key")"; then
            ((deleted++))
            S3_CLEANUP_DELETED_COUNT=$((S3_CLEANUP_DELETED_COUNT + 1))
            S3_CLEANUP_DELETED_BYTES=$((S3_CLEANUP_DELETED_BYTES + obj_size))
            if [ -z "$S3_CLEANUP_DELETED_KEYS" ]; then
                S3_CLEANUP_DELETED_KEYS="- $obj_key ($obj_size_fmt)"
            else
                S3_CLEANUP_DELETED_KEYS="${S3_CLEANUP_DELETED_KEYS}\\n- $obj_key ($obj_size_fmt)"
            fi
        else
            log_warning "Falha ao remover: s3://$S3_BUCKET/$obj_key"
            ((failed++))
            S3_CLEANUP_FAILED_COUNT=$((S3_CLEANUP_FAILED_COUNT + 1))
            if [ -z "$S3_CLEANUP_FAILED_KEYS" ]; then
                S3_CLEANUP_FAILED_KEYS="- $obj_key ($obj_size_fmt)"
            else
                S3_CLEANUP_FAILED_KEYS="${S3_CLEANUP_FAILED_KEYS}\\n- $obj_key ($obj_size_fmt)"
            fi
        fi
    done

    if [ "$deleted" -gt 0 ]; then
        log_success "$deleted backup(s) antigo(s) removido(s) do S3/R2"
        log_success "Espaço remoto liberado: $(format_bytes "$S3_CLEANUP_DELETED_BYTES")"
    fi

    [ "$failed" -eq 0 ]
}

notify_s3_cleanup_webhook() {
    local prefix="$1"
    local strategy="$2"
    local details=""

    if [ "${S3_CLEANUP_DELETED_COUNT:-0}" -eq 0 ] && [ "${S3_CLEANUP_FAILED_COUNT:-0}" -eq 0 ]; then
        return 0
    fi

    if [ -n "$S3_CLEANUP_DELETED_KEYS" ]; then
        details="Removidos:\\n$S3_CLEANUP_DELETED_KEYS"
    fi

    if [ -n "$S3_CLEANUP_FAILED_KEYS" ]; then
        if [ -n "$details" ]; then
            details="${details}\\n\\nFalhas:\\n$S3_CLEANUP_FAILED_KEYS"
        else
            details="Falhas:\\n$S3_CLEANUP_FAILED_KEYS"
        fi
    fi

    if type notify_s3_cleanup_result &>/dev/null; then
        notify_s3_cleanup_result \
            "$S3_BUCKET" \
            "$prefix" \
            "$strategy" \
            "${S3_CLEANUP_DELETED_COUNT:-0}" \
            "${S3_CLEANUP_FAILED_COUNT:-0}" \
            "$details" \
            "$(format_bytes "${S3_CLEANUP_DELETED_BYTES:-0}")"
    fi
}

cleanup_s3_simple() {
    local prefix_uri="$1"
    local retention_days="$2"
    local now
    local obj_date obj_time obj_size obj_key modified age_days
    local backups_to_delete=()

    if ! [[ "$retention_days" =~ ^[0-9]+$ ]]; then
        log_warning "S3_RETENTION_DAYS inválido: $retention_days. Limpeza remota ignorada."
        return 0
    fi

    now=$(date +%s)

    while IFS=$'\t' read -r obj_date obj_time obj_size obj_key; do
        modified=$(date -d "$obj_date $obj_time" +%s 2>/dev/null || echo 0)
        [ "$modified" -eq 0 ] && continue

        age_days=$(( (now - modified) / 86400 ))
        if [ "$age_days" -gt "$retention_days" ]; then
            backups_to_delete+=("${obj_size}"$'\t'"${obj_key}")
        fi
    done < <(s3_list_backup_objects "$prefix_uri")

    if [ "${#backups_to_delete[@]}" -eq 0 ]; then
        log_success "Nenhum backup remoto antigo para remover (todos <= ${retention_days} dias)"
        return 0
    fi

    log_info "Encontrados ${#backups_to_delete[@]} backup(s) remoto(s) com mais de ${retention_days} dias"
    delete_s3_objects "${backups_to_delete[@]}"
}

cleanup_s3_count() {
    local prefix_uri="$1"
    local retention_count="$2"
    local obj_date obj_time obj_size obj_key modified
    local all_backups=()
    local backups_to_delete=()
    local line index

    if ! [[ "$retention_count" =~ ^[0-9]+$ ]] || [ "$retention_count" -lt 1 ]; then
        log_warning "S3_RETENTION_COUNT inválido: $retention_count. Limpeza remota ignorada."
        return 0
    fi

    while IFS=$'\t' read -r obj_date obj_time obj_size obj_key; do
        modified=$(date -d "$obj_date $obj_time" +%s 2>/dev/null || echo 0)
        [ "$modified" -eq 0 ] && continue
        all_backups+=("${modified}"$'\t'"${obj_size}"$'\t'"${obj_key}")
    done < <(s3_list_backup_objects "$prefix_uri")

    if [ "${#all_backups[@]}" -le "$retention_count" ]; then
        log_success "Nenhum backup remoto para remover (total: ${#all_backups[@]}, retenção: $retention_count)"
        return 0
    fi

    index=0
    while IFS=$'\t' read -r modified obj_size obj_key; do
        if [ "$index" -ge "$retention_count" ]; then
            backups_to_delete+=("${obj_size}"$'\t'"${obj_key}")
        fi
        ((index++))
    done < <(printf '%s\n' "${all_backups[@]}" | sort -rn)

    log_info "Encontrados ${#backups_to_delete[@]} backup(s) remoto(s) para remover (mantendo últimos $retention_count)"
    delete_s3_objects "${backups_to_delete[@]}"
}

cleanup_s3_gfs() {
    local prefix_uri="$1"
    local now
    local obj_date obj_time obj_size obj_key modified age_days backup_day backup_dom
    local backups_to_delete=()

    now=$(date +%s)

    while IFS=$'\t' read -r obj_date obj_time obj_size obj_key; do
        modified=$(date -d "$obj_date $obj_time" +%s 2>/dev/null || echo 0)
        [ "$modified" -eq 0 ] && continue

        age_days=$(( (now - modified) / 86400 ))
        backup_day=$(date -d "@$modified" +%u)
        backup_dom=$(date -d "@$modified" +%d)

        if [ "$age_days" -le 7 ]; then
            continue
        elif [ "$age_days" -le 28 ] && [ "$backup_day" -eq 7 ]; then
            continue
        elif [ "$age_days" -le 365 ] && [ "$backup_dom" -eq 01 ]; then
            continue
        fi

        backups_to_delete+=("${obj_size}"$'\t'"${obj_key}")
    done < <(s3_list_backup_objects "$prefix_uri")

    if [ "${#backups_to_delete[@]}" -eq 0 ]; then
        log_success "Nenhum backup remoto fora da política GFS"
        return 0
    fi

    log_info "Encontrados ${#backups_to_delete[@]} backup(s) remoto(s) fora da política GFS"
    delete_s3_objects "${backups_to_delete[@]}"
}

cleanup_s3_after_upload() {
    local prefix="$1"
    local prefix_uri
    local strategy
    local retention_days
    local retention_count
    local cleanup_status=0

    if [ "${S3_CLEANUP_ENABLED:-true}" != "true" ]; then
        log_info "Limpeza remota S3/R2 desabilitada (S3_CLEANUP_ENABLED=false)"
        return 0
    fi

    prefix_uri=$(s3_prefix_uri "$prefix")
    strategy="${S3_RETENTION_STRATEGY:-${BACKUP_RETENTION_STRATEGY:-simple}}"
    retention_days="${S3_RETENTION_DAYS:-${BACKUP_RETENTION_DAYS:-30}}"
    retention_count="${S3_RETENTION_COUNT:-${BACKUP_RETENTION_COUNT:-10}}"
    S3_CLEANUP_DELETED_COUNT=0
    S3_CLEANUP_FAILED_COUNT=0
    S3_CLEANUP_DELETED_BYTES=0
    S3_CLEANUP_DELETED_KEYS=""
    S3_CLEANUP_FAILED_KEYS=""

    log_info "Aplicando retenção remota S3/R2 em $prefix_uri (estratégia: $strategy)"

    case "$strategy" in
        simple)
            cleanup_s3_simple "$prefix_uri" "$retention_days" || cleanup_status=$?
            ;;
        count)
            cleanup_s3_count "$prefix_uri" "$retention_count" || cleanup_status=$?
            ;;
        gfs)
            cleanup_s3_gfs "$prefix_uri" || cleanup_status=$?
            ;;
        *)
            log_warning "Estratégia de retenção S3/R2 inválida: $strategy. Limpeza remota ignorada."
            return 0
            ;;
    esac

    notify_s3_cleanup_webhook "$prefix" "$strategy"
    return "$cleanup_status"
}

# Carregar configurações de destino
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${VPSGUARDIAN_SHARED_CONFIG_FILE:-$SCRIPT_DIR/../config/backup-destinations.conf}"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
fi

# Carregar biblioteca de notificações
if [ -f "$SCRIPT_DIR/../lib/notificacoes.sh" ]; then
    source "$SCRIPT_DIR/../lib/notificacoes.sh"
fi

# Verificar argumentos
BACKUP_FILE=""
DEST_AUTO=""
PREFIX_OVERRIDE=""
TYPE_OVERRIDE=""

for arg in "$@"; do
    case $arg in
        --dest=*)
            DEST_AUTO="${arg#*=}"
            ;;
        --prefix=*)
            PREFIX_OVERRIDE="${arg#*=}"
            ;;
        --type=*)
            TYPE_OVERRIDE="${arg#*=}"
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

# Modo automático = usa configurações do arquivo, sem interação
AUTO_MODE=false

# Se destino foi especificado via --dest, usar automaticamente
if [ -n "$DEST_AUTO" ]; then
    AUTO_MODE=true
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
        if [ "$AUTO_MODE" = true ]; then
            # Modo automático: usar apenas destinos HABILITADOS e CONFIGURADOS
            log_info "Verificando destinos configurados..."
            echo ""

            # Self-hosted (SSH)
            if [ "$BACKUP_DEST_SSH" = true ] && [ -n "$SSH_REMOTE_SERVER" ]; then
                UPLOAD_SELFHOSTED=true
                log_info "✓ Self-hosted habilitado: $SSH_REMOTE_SERVER"
            elif [ "$BACKUP_DEST_SSH" = true ]; then
                log_warning "✗ Self-hosted habilitado mas SSH_REMOTE_SERVER não configurado"
            fi

            # Google Drive
            if [ "$BACKUP_DEST_GOOGLE_DRIVE" = true ]; then
                UPLOAD_GDRIVE=true
                log_info "✓ Google Drive habilitado"
            fi

            # AWS S3
            if [ "$BACKUP_DEST_AWS_S3" = true ] && [ -n "$S3_BUCKET" ]; then
                UPLOAD_S3=true
                log_info "✓ AWS S3 habilitado: $S3_BUCKET"
            elif [ "$BACKUP_DEST_AWS_S3" = true ]; then
                log_warning "✗ AWS S3 habilitado mas S3_BUCKET não configurado"
            fi

            # Verificar se pelo menos um destino está configurado
            if [ "$UPLOAD_SELFHOSTED" != true ] && [ "$UPLOAD_GDRIVE" != true ] && [ "$UPLOAD_S3" != true ]; then
                log_error "Nenhum destino remoto está habilitado e configurado!"
                log_info "Configure os destinos em: $CONFIG_FILE"
                log_info ""
                log_info "Opções disponíveis:"
                log_info "  BACKUP_DEST_SSH=true + SSH_REMOTE_SERVER=<ip>"
                log_info "  BACKUP_DEST_GOOGLE_DRIVE=true (+ rclone configurado)"
                log_info "  BACKUP_DEST_AWS_S3=true + S3_BUCKET=<bucket>"
                exit 1
            fi
        else
            # Modo interativo: habilitar todos
            UPLOAD_SELFHOSTED=true
            UPLOAD_GDRIVE=true
            UPLOAD_S3=true
        fi
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

    if [ "$AUTO_MODE" = true ]; then
        # Usar configurações do arquivo
        REMOTE_IP="$SSH_REMOTE_SERVER"
        REMOTE_USER="${SSH_REMOTE_USER:-root}"
        REMOTE_PORT="${SSH_REMOTE_PORT:-22}"
        REMOTE_DIR="${SSH_REMOTE_DIR:-/root/backups}"

        if [ -z "$REMOTE_IP" ]; then
            log_error "SSH_REMOTE_SERVER não configurado em $CONFIG_FILE"
            log_info "Configure o servidor remoto antes de usar o modo automático"
            ((FAIL_COUNT++))
            UPLOAD_SELFHOSTED=false
        else
            log_info "Usando configuração: $REMOTE_USER@$REMOTE_IP:$REMOTE_PORT → $REMOTE_DIR"
        fi
    else
        # Modo interativo - pedir inputs
        read -p "$LOG_PREFIX [ INPUT ] IP do servidor remoto: " REMOTE_IP
        read -p "$LOG_PREFIX [ INPUT ] Usuário SSH (padrão: root): " REMOTE_USER
        REMOTE_USER=${REMOTE_USER:-root}
        read -p "$LOG_PREFIX [ INPUT ] Porta SSH (padrão: 22): " REMOTE_PORT
        REMOTE_PORT=${REMOTE_PORT:-22}
        read -p "$LOG_PREFIX [ INPUT ] Diretório de destino (padrão: /root/backups): " REMOTE_DIR
        REMOTE_DIR=${REMOTE_DIR:-/root/backups}
    fi

    if [ "$UPLOAD_SELFHOSTED" = true ]; then
        # Aplicar PREFIX_OVERRIDE se definido
        if [ -n "$PREFIX_OVERRIDE" ]; then
            REMOTE_UPLOAD_DIR="$REMOTE_DIR/$PREFIX_OVERRIDE"
            log_info "Usando prefixo override: $REMOTE_UPLOAD_DIR"
        else
            REMOTE_UPLOAD_DIR="$REMOTE_DIR"
        fi

        if [[ ! "$REMOTE_USER" =~ ^[A-Za-z0-9._-]+$ ]] ||
           [[ ! "$REMOTE_PORT" =~ ^[0-9]+$ ]] ||
           [[ ! "$REMOTE_IP" =~ ^[A-Za-z0-9.:-]+$ ]] ||
           [[ ! "$REMOTE_UPLOAD_DIR" =~ ^/[A-Za-z0-9._/-]+$ ]]; then
            log_error "Configuração SSH contém usuário, host, porta ou caminho inválido"
            FAIL_COUNT=$((FAIL_COUNT + 1))
            UPLOAD_SELFHOSTED=false
        fi

        log_info "Testando conexão SSH..."
    fi

    if [ "$UPLOAD_SELFHOSTED" = true ]; then
        if ssh -p "$REMOTE_PORT" -o ConnectTimeout=10 "$REMOTE_USER@$REMOTE_IP" "exit" 2>/dev/null; then
            log_success "Conexão SSH estabelecida"

            # Criar o diretório e gravar via stdin mantém o caminho devidamente
            # quoted e aplica permissão restrita no destino.
            log_info "Enviando backup para $REMOTE_USER@$REMOTE_IP:$REMOTE_UPLOAD_DIR..."
            REMOTE_UPLOAD_DIR_Q=$(printf '%q' "$REMOTE_UPLOAD_DIR")
            REMOTE_FILE_Q=$(printf '%q' "$REMOTE_UPLOAD_DIR/$BACKUP_FILENAME")
            if ssh -p "$REMOTE_PORT" "$REMOTE_USER@$REMOTE_IP" \
                "umask 077; mkdir -p -- $REMOTE_UPLOAD_DIR_Q && cat > $REMOTE_FILE_Q" < "$BACKUP_FILE"; then
                log_success "Upload self-hosted concluído!"
                notify_upload_success "$BACKUP_FILENAME" "SSH ($REMOTE_IP)" "$BACKUP_SIZE"
                ((SUCCESS_COUNT++))
            else
                log_error "Falha no upload self-hosted"
                notify_upload_error "$BACKUP_FILENAME" "SSH ($REMOTE_IP)" "Falha no SCP"
                ((FAIL_COUNT++))
            fi
        else
            log_error "Falha na conexão SSH com $REMOTE_IP"
            notify_upload_error "$BACKUP_FILENAME" "SSH ($REMOTE_IP)" "Conexão SSH falhou"
            ((FAIL_COUNT++))
        fi
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
        # Definir nome do remote (do config ou padrão)
        RCLONE_REMOTE="${GDRIVE_REMOTE_NAME:-gdrive}"

        # Verificar se já existe configuração do Google Drive
        if ! rclone listremotes | grep -q "${RCLONE_REMOTE}:"; then
            log_info "Configuração do Google Drive não encontrada (remote: $RCLONE_REMOTE)"
            log_info "Execute: rclone config"
            log_info "Escolha: Google Drive, nome do remote: $RCLONE_REMOTE"

            if [ "$AUTO_MODE" = true ]; then
                log_error "Upload para Google Drive cancelado - configure rclone primeiro"
                ((FAIL_COUNT++))
            else
                read -p "$LOG_PREFIX [ INPUT ] Deseja configurar agora? (y/N): " CONFIG_NOW
                if [ "$CONFIG_NOW" = "y" ]; then
                    rclone config
                else
                    log_error "Upload para Google Drive cancelado - configure rclone primeiro"
                    ((FAIL_COUNT++))
                fi
            fi
        fi

        # Se configuração existe, fazer upload
        if rclone listremotes | grep -q "${RCLONE_REMOTE}:"; then
            if [ "$AUTO_MODE" = true ]; then
                # Usar prefixo override se fornecido, senão usar configurado
                if [ -n "$PREFIX_OVERRIDE" ]; then
                    # Substituir última parte do path pelo override
                    GDRIVE_BASE=$(dirname "${GDRIVE_DIR:-backups/vpsguardian}")
                    GDRIVE_UPLOAD_DIR="$GDRIVE_BASE/$PREFIX_OVERRIDE"
                    log_info "Usando prefixo override: ${RCLONE_REMOTE}:$GDRIVE_UPLOAD_DIR"
                else
                    GDRIVE_UPLOAD_DIR="${GDRIVE_DIR:-backups/vpsguardian}"
                    log_info "Usando configuração: ${RCLONE_REMOTE}:$GDRIVE_UPLOAD_DIR"
                fi
            else
                read -p "$LOG_PREFIX [ INPUT ] Diretório no Google Drive (padrão: backups/coolify): " GDRIVE_UPLOAD_DIR
                GDRIVE_UPLOAD_DIR=${GDRIVE_UPLOAD_DIR:-backups/coolify}
            fi

            log_info "Enviando backup para Google Drive: $GDRIVE_UPLOAD_DIR..."
            RCLONE_OPTS=""
            if [ "$AUTO_MODE" = false ]; then
                RCLONE_OPTS="--progress"
            fi
            if rclone copy "$BACKUP_FILE" "${RCLONE_REMOTE}:$GDRIVE_UPLOAD_DIR" $RCLONE_OPTS; then
                log_success "Upload para Google Drive concluído!"
                notify_upload_success "$BACKUP_FILENAME" "Google Drive" "$BACKUP_SIZE"
                ((SUCCESS_COUNT++))
            else
                log_error "Falha no upload para Google Drive"
                notify_upload_error "$BACKUP_FILENAME" "Google Drive" "Falha no rclone"
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

            if [ "$AUTO_MODE" = true ]; then
                log_error "Upload para S3 cancelado - configure AWS CLI primeiro"
                ((FAIL_COUNT++))
            else
                read -p "$LOG_PREFIX [ INPUT ] Deseja configurar agora? (y/N): " CONFIG_NOW
                if [ "$CONFIG_NOW" = "y" ]; then
                    aws configure
                else
                    log_error "Upload para S3 cancelado - configure AWS CLI primeiro"
                    ((FAIL_COUNT++))
                fi
            fi
        fi

        # Se configuração existe, fazer upload
        if [ -f ~/.aws/credentials ]; then
            # Usar configurações salvas ou perguntar interativamente
            if [ "$AUTO_MODE" = true ]; then
                # Modo automático - usar config ou falhar
                if [ -z "$S3_BUCKET" ]; then
                    log_error "S3_BUCKET não configurado em $CONFIG_FILE"
                    log_info "Configure o bucket S3 antes de usar o modo automático"
                    notify_upload_error "$BACKUP_FILENAME" "AWS S3" "S3_BUCKET não configurado"
                    ((FAIL_COUNT++))
                    S3_UPLOAD_READY=false
                else
                    log_info "Usando bucket configurado: $S3_BUCKET"
                    # Usar prefixo override se fornecido, senão usar configurado
                    if [ -n "$PREFIX_OVERRIDE" ]; then
                        S3_PREFIX="$PREFIX_OVERRIDE"
                        log_info "Usando prefixo override: $S3_PREFIX"
                    else
                        S3_PREFIX="${S3_PREFIX:-backups/vpsguardian}"
                        log_info "Usando prefixo configurado: $S3_PREFIX"
                    fi
                    S3_UPLOAD_READY=true
                fi
            else
                # Modo interativo
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
                S3_UPLOAD_READY=true
            fi

            if [ "$S3_UPLOAD_READY" = true ]; then
                S3_PREFIX=$(normalize_s3_prefix "$S3_PREFIX")
                if [ -n "$S3_PREFIX" ]; then
                    S3_BACKUP_KEY="$S3_PREFIX/$BACKUP_FILENAME"
                else
                    S3_BACKUP_KEY="$BACKUP_FILENAME"
                fi

                if [ -n "$S3_ENDPOINT" ]; then
                    log_info "Usando endpoint customizado: $S3_ENDPOINT"
                fi

                log_info "Enviando backup para S3: s3://$S3_BUCKET/$S3_BACKUP_KEY"
                if run_aws s3 cp "$BACKUP_FILE" "$(s3_object_uri "$S3_BACKUP_KEY")"; then
                    log_success "Upload para S3 concluído!"
                    notify_upload_success "$BACKUP_FILENAME" "S3 ($S3_BUCKET)" "$BACKUP_SIZE"

                    if cleanup_s3_after_upload "$S3_PREFIX"; then
                        log_success "Limpeza remota S3/R2 concluída"
                    else
                        log_warning "Limpeza remota S3/R2 terminou com avisos"
                    fi

                    # Configurar lifecycle policy (apenas em modo interativo)
                    if [ "$AUTO_MODE" = false ]; then
                        read -p "$LOG_PREFIX [ INPUT ] Configurar expiração automática? (y/N): " CONFIGURE_LIFECYCLE
                        if [ "$CONFIGURE_LIFECYCLE" = "y" ]; then
                            read -p "$LOG_PREFIX [ INPUT ] Dias para expiração (padrão: 30): " EXPIRE_DAYS
                            EXPIRE_DAYS=${EXPIRE_DAYS:-30}

                            if [[ ! "$EXPIRE_DAYS" =~ ^[1-9][0-9]*$ ]] || \
                               [[ ! "$S3_PREFIX" =~ ^[A-Za-z0-9._/-]*$ ]]; then
                                log_error "Dias de expiração ou prefixo S3 inválido"
                                FAIL_COUNT=$((FAIL_COUNT + 1))
                            else
                                log_info "Configurando lifecycle policy para $EXPIRE_DAYS dias..."
                                LIFECYCLE_FILE=$(mktemp "${TMPDIR:-/tmp}/vpsguardian-s3-lifecycle.XXXXXX.json")
                                cat > "$LIFECYCLE_FILE" <<EOF
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
                                run_aws s3api put-bucket-lifecycle-configuration \
                                    --bucket "$S3_BUCKET" \
                                    --lifecycle-configuration "file://$LIFECYCLE_FILE"
                                LIFECYCLE_RESULT=$?
                                rm -f "$LIFECYCLE_FILE"
                                if [ "$LIFECYCLE_RESULT" -eq 0 ]; then
                                    log_success "Lifecycle policy configurada"
                                else
                                    log_error "Falha ao configurar lifecycle policy"
                                    FAIL_COUNT=$((FAIL_COUNT + 1))
                                fi
                            fi
                        fi
                    fi

                    ((SUCCESS_COUNT++))
                else
                    log_error "Falha no upload para S3"
                    notify_upload_error "$BACKUP_FILENAME" "S3 ($S3_BUCKET)" "Falha no aws s3 cp"
                    ((FAIL_COUNT++))
                fi
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
elif [ $FAIL_COUNT -gt 0 ]; then
    log_error "Upload parcial: ao menos um destino falhou"
    exit 1
else
    log_success "Backup enviado com sucesso para $SUCCESS_COUNT destino(s)"
fi

exit 0
