#!/bin/bash
################################################################################
# Script: restore-volumes.sh
# Propósito: Restaurar volumes Docker de backups
# Uso: ./restore-volumes.sh [--volume=NOME] [--backup=FILE] [--all]
################################################################################

# Carregar bibliotecas compartilhadas
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

### ========== CONFIGURAÇÃO ==========
BACKUP_DIR="${BACKUP_DIR:-./volume-backup}"
VOLUME_NAME="${VOLUME_NAME:-}"
BACKUP_FILE="${BACKUP_FILE:-}"
RESTORE_ALL=false

### ========== PARSE ARGUMENTOS ==========
while [[ $# -gt 0 ]]; do
    case $1 in
        --volume=*)
            VOLUME_NAME="${1#*=}"
            shift
            ;;
        --backup=*)
            BACKUP_FILE="${1#*=}"
            shift
            ;;
        --dir=*)
            BACKUP_DIR="${1#*=}"
            shift
            ;;
        --all)
            RESTORE_ALL=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --volume=NAME    Target volume name"
            echo "  --backup=FILE    Backup file to restore"
            echo "  --dir=PATH       Backup directory (default: ./volume-backup)"
            echo "  --all            Restore all backups found"
            echo "  -h, --help       Show this help"
            echo ""
            echo "Interactive mode if no options provided."
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

### ========== FUNÇÕES ==========

restore_volume() {
    local volume_name="$1"
    local backup_file="$2"
    local force_clean="${3:-false}"

    # Verificar se backup existe
    if [ ! -f "$backup_file" ]; then
        log_error "Backup file not found: $backup_file"
        return 1
    fi

    log_info "Restoring volume: $volume_name from $(basename $backup_file)"

    # Verificar se volume já existe
    if docker volume inspect "$volume_name" >/dev/null 2>&1; then
        log_warning "Volume already exists: $volume_name"

        # Parar containers que usam este volume para permitir remoção limpa
        local containers_using=$(docker ps -a --filter "volume=$volume_name" --format '{{.Names}}' 2>/dev/null)
        if [ -n "$containers_using" ]; then
            log_info "Stopping containers using this volume..."
            for container in $containers_using; do
                docker stop "$container" >/dev/null 2>&1 || true
            done
        fi

        # CORREÇÃO: Remover volume completamente para evitar mistura de arquivos
        # Isso resolve o problema de redo logs corrompidos no MySQL
        log_info "Removing existing volume completely (clean restore)..."
        if ! docker volume rm "$volume_name" >/dev/null 2>&1; then
            log_warning "Could not remove volume (may be in use). Trying force clean..."
            # Fallback: limpar conteúdo se não conseguir remover
            docker run --rm -v "$volume_name":/target busybox \
                sh -c "rm -rf /target/* /target/..?* /target/.[!.]* 2>/dev/null" >/dev/null 2>&1
        fi
    fi

    # Criar volume limpo
    if ! docker volume inspect "$volume_name" >/dev/null 2>&1; then
        log_info "Creating clean volume: $volume_name"
        docker volume create "$volume_name" >/dev/null 2>&1

        if [ $? -ne 0 ]; then
            log_error "Failed to create volume: $volume_name"
            return 1
        fi
    fi

    # Restaurar usando container temporário
    docker run --rm \
        -v "$volume_name":/target \
        -v "$(dirname $backup_file)":/backup:ro \
        busybox \
        sh -c "tar -xzf /backup/$(basename $backup_file) -C /target" \
        >/dev/null 2>&1

    if [ $? -eq 0 ]; then
        log_success "Volume restored successfully: $volume_name"
        return 0
    else
        log_error "Failed to restore volume: $volume_name"
        return 1
    fi
}

### ========== MAIN ==========
log_section "VPS Guardian - Restore de Volumes Docker"

# Verificar diretório de backup
if [ ! -d "$BACKUP_DIR" ]; then
    log_error "Backup directory not found: $BACKUP_DIR"
    exit 1
fi

# Modo: Restore todos os backups
if [ "$RESTORE_ALL" = true ]; then
    log_info "Modo: Restore de TODOS os backups"

    backups=($(find "$BACKUP_DIR" -name "*-backup-*.tar.gz" -type f | sort))

    if [ ${#backups[@]} -eq 0 ]; then
        log_warning "No backup files found in $BACKUP_DIR"
        exit 0
    fi

    log_info "Found ${#backups[@]} backup files"
    echo ""
    read -p "Restore all backups? (yes/no): " confirm

    if [ "$confirm" != "yes" ]; then
        log_info "Operation cancelled"
        exit 0
    fi

    echo ""
    success_count=0
    fail_count=0

    for backup_file in "${backups[@]}"; do
        # Extrair nome do volume do nome do arquivo
        # Formato: volume-name-backup-TIMESTAMP.tar.gz
        filename=$(basename "$backup_file")
        volume=$(echo "$filename" | sed 's/-backup-[0-9_]*\.tar\.gz$//')

        if restore_volume "$volume" "$backup_file"; then
            ((success_count++))
        else
            ((fail_count++))
        fi
        echo ""
    done

    log_section "RESUMO"
    echo "  ✅ Sucesso: $success_count volumes"
    if [ $fail_count -gt 0 ]; then
        echo "  ❌ Falha: $fail_count volumes"
    fi
    echo ""

    exit 0
fi

# Modo: Restore específico
if [ -n "$VOLUME_NAME" ] && [ -n "$BACKUP_FILE" ]; then
    restore_volume "$VOLUME_NAME" "$BACKUP_FILE"
    exit $?
fi

# Modo: Interativo
echo ""
log_info "Backups disponíveis em $BACKUP_DIR:"
echo ""

backups=($(find "$BACKUP_DIR" -name "*-backup-*.tar.gz" -type f | sort -r))

if [ ${#backups[@]} -eq 0 ]; then
    log_warning "No backup files found"
    exit 0
fi

# Listar backups
for i in "${!backups[@]}"; do
    filename=$(basename "${backups[$i]}")
    filesize=$(du -h "${backups[$i]}" | cut -f1)
    filedate=$(stat -c %y "${backups[$i]}" | cut -d'.' -f1)

    # Extrair nome do volume
    volume=$(echo "$filename" | sed 's/-backup-[0-9_]*\.tar\.gz$//')

    echo "  [$i] $filename"
    echo "      Volume: $volume"
    echo "      Size: $filesize | Date: $filedate"
    echo ""
done

echo ""
read -p "Select backup number to restore: " selection

if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -lt "${#backups[@]}" ]; then
    BACKUP_FILE="${backups[$selection]}"
    filename=$(basename "$BACKUP_FILE")

    # Extrair nome do volume padrão
    default_volume=$(echo "$filename" | sed 's/-backup-[0-9_]*\.tar\.gz$//')

    echo ""
    read -p "Target volume name (default: $default_volume): " VOLUME_NAME
    VOLUME_NAME=${VOLUME_NAME:-$default_volume}

    echo ""
    echo "  Source: $filename"
    echo "  Target volume: $VOLUME_NAME"
    echo ""
    read -p "Proceed with restore? (yes/no): " confirm

    if [ "$confirm" = "yes" ]; then
        restore_volume "$VOLUME_NAME" "$BACKUP_FILE"
    else
        log_info "Operation cancelled"
    fi
else
    log_error "Invalid selection"
    exit 1
fi
