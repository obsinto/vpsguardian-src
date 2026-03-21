#!/bin/bash
################################################################################
# Script: backup-databases-dump-auto.sh
# Propósito: Wrapper para backup automático via dump SQL (usa migrar-databases-dump.sh)
# Uso: ./backup-databases-dump-auto.sh [--dest=local|google-drive|aws-s3|all]
#
# Este script:
#   1. Executa migrar-databases-dump.sh para criar dumps locais
#   2. Opcionalmente envia para destinos remotos (Google Drive, S3, SSH)
#   3. Pode ser agendado via cron
################################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh" 2>/dev/null || {
    log_info() { echo "[ INFO ] $*"; }
    log_success() { echo "[ OK ] $*"; }
    log_error() { echo "[ ERRO ] $*"; }
    log_warning() { echo "[ AVISO ] $*"; }
    log_section() { echo ""; echo "========== $* =========="; echo ""; }
}

# Carregar biblioteca de notificações
source "$SCRIPT_DIR/../lib/notificacoes.sh" 2>/dev/null || true

# Marcar início para calcular duração
BACKUP_START_TIME=$(date +%s)

# Carregar configurações
if [ -f "/opt/vpsguardian/config/config.env" ]; then
    source "/opt/vpsguardian/config/config.env" 2>/dev/null
fi
if [ -f "$SCRIPT_DIR/../config/default.conf" ]; then
    source "$SCRIPT_DIR/../config/default.conf" 2>/dev/null
fi

# Carregar configurações de destino de backup
BACKUP_DESTINATIONS_CONFIG="/opt/vpsguardian/config/backup-destinations.conf"
if [ -f "$BACKUP_DESTINATIONS_CONFIG" ]; then
    source "$BACKUP_DESTINATIONS_CONFIG"
fi

### ========== CONFIGURAÇÃO ==========
UPLOAD_DEST="${1:-local}"
BASE_BACKUP_DIR="${DATABASE_BACKUP_DIR:-/var/backups/vpsguardian/databases}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="/var/log/vpsguardian/backup-databases-auto-${TIMESTAMP}.log"

# Parse argumentos
while [[ $# -gt 0 ]]; do
    case $1 in
        --dest=*) UPLOAD_DEST="${1#*=}"; shift ;;
        --include-coolify) INCLUDE_COOLIFY=true; shift ;;
        *) shift ;;
    esac
done

### ========== INÍCIO ==========
mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║         BACKUP AUTOMÁTICO VIA DUMP SQL                         ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
log_info "Iniciado em: $(date '+%Y-%m-%d %H:%M:%S')"
log_info "Destino: $UPLOAD_DEST"
echo ""

# Notificar início
notify_backup_start "Databases (Dumps SQL)" "Destino: $UPLOAD_DEST | Coolify: ${BACKUP_INCLUDE_COOLIFY:-true}"

### ========== EXECUTAR DUMP ==========
log_section "Criando Dumps SQL"

# Executar script de dump (modo local)
DUMP_SCRIPT="$SCRIPT_DIR/../migrar/migrar-databases-dump.sh"

if [ ! -x "$DUMP_SCRIPT" ]; then
    log_error "Script de dump não encontrado ou não executável: $DUMP_SCRIPT"
    exit 1
fi

# Determinar se inclui Coolify (padrão: sim)
COOLIFY_FLAG="--include-coolify"
if [ "${BACKUP_INCLUDE_COOLIFY:-true}" = "false" ]; then
    COOLIFY_FLAG="--exclude-coolify"
    log_info "Configuração: Coolify será EXCLUÍDO do backup"
else
    log_info "Configuração: Coolify será INCLUÍDO no backup"
fi

# Executar em modo automático (--auto) para não pedir confirmação
log_info "Executando: $DUMP_SCRIPT --auto $COOLIFY_FLAG"
bash "$DUMP_SCRIPT" --target=local --auto $COOLIFY_FLAG

if [ $? -ne 0 ]; then
    log_error "Falha ao criar dumps"
    notify_backup_error "Databases" "Falha ao executar script de dump SQL"
    exit 1
fi

# Encontrar o lote mais recente criado
LATEST_BATCH=$(find "$BASE_BACKUP_DIR" -maxdepth 1 -type d -name "lote-*" | sort -r | head -n1)

if [ -z "$LATEST_BATCH" ] || [ ! -d "$LATEST_BATCH" ]; then
    log_error "Nenhum lote de backup encontrado em $BASE_BACKUP_DIR"
    exit 1
fi

log_success "Dumps criados em: $LATEST_BATCH"
BATCH_SIZE=$(du -sh "$LATEST_BATCH" | cut -f1)
log_info "Tamanho total: $BATCH_SIZE"
echo ""

### ========== UPLOAD PARA DESTINOS REMOTOS ==========
if [ "$UPLOAD_DEST" != "local" ]; then
    log_section "Enviando para Destinos Remotos"

    # Criar tarball do lote para facilitar upload
    BATCH_NAME=$(basename "$LATEST_BATCH")
    TARBALL="$BASE_BACKUP_DIR/${BATCH_NAME}.tar.gz"

    log_info "Comprimindo lote para upload..."
    tar -czf "$TARBALL" -C "$BASE_BACKUP_DIR" "$BATCH_NAME" 2>/dev/null

    if [ $? -eq 0 ]; then
        TARBALL_SIZE=$(du -h "$TARBALL" | cut -f1)
        log_success "Tarball criado: $TARBALL_SIZE"
        echo ""

        # Chamar backup-destinos.sh com o tarball
        # Usar --prefix=databases para manter estrutura padronizada:
        # bucket/databases/, bucket/coolify/, bucket/volumes/
        DESTINOS_SCRIPT="$SCRIPT_DIR/backup-destinos.sh"

        if [ -x "$DESTINOS_SCRIPT" ]; then
            log_info "Executando: $DESTINOS_SCRIPT $TARBALL --dest=$UPLOAD_DEST --prefix=databases"
            bash "$DESTINOS_SCRIPT" "$TARBALL" --dest="$UPLOAD_DEST" --prefix=databases

            if [ $? -eq 0 ]; then
                log_success "Upload concluído com sucesso"

                # Opcional: Remover tarball local após upload bem-sucedido
                if [ "${REMOVE_LOCAL_AFTER_UPLOAD:-false}" = "true" ]; then
                    log_info "Removendo tarball local (REMOVE_LOCAL_AFTER_UPLOAD=true)"
                    rm -f "$TARBALL"
                fi
            else
                log_error "Falha no upload para destino remoto"
            fi
        else
            log_error "Script de upload não encontrado: $DESTINOS_SCRIPT"
        fi
    else
        log_error "Falha ao criar tarball para upload"
    fi
    echo ""
fi

### ========== LIMPEZA DE BACKUPS ANTIGOS ==========
log_section "Limpeza de Backups Antigos"

# Usar script de limpeza se existir
CLEANUP_SCRIPT="$SCRIPT_DIR/../scripts-auxiliares/limpar-backups-antigos.sh"

if [ -x "$CLEANUP_SCRIPT" ]; then
    RETENTION_STRATEGY="${BACKUP_RETENTION_STRATEGY:-simple}"
    RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-30}"

    log_info "Executando limpeza (estratégia: $RETENTION_STRATEGY)"

    bash "$CLEANUP_SCRIPT" \
        --dir="$BASE_BACKUP_DIR" \
        --strategy="$RETENTION_STRATEGY" \
        --days="$RETENTION_DAYS" \
        --auto

    if [ $? -eq 0 ]; then
        log_success "Limpeza concluída"
    else
        log_warning "Limpeza apresentou avisos"
    fi
else
    # Fallback: limpeza simples por idade
    log_info "Removendo lotes com mais de $RETENTION_DAYS dias..."

    DELETED_COUNT=0
    while IFS= read -r OLD_BATCH; do
        log_info "  Removendo: $(basename "$OLD_BATCH")"
        rm -rf "$OLD_BATCH"
        ((DELETED_COUNT++))
    done < <(find "$BASE_BACKUP_DIR" -maxdepth 1 -type d -name "lote-*" -mtime +$RETENTION_DAYS 2>/dev/null)

    # Também remover tarballs antigos
    while IFS= read -r OLD_TARBALL; do
        log_info "  Removendo: $(basename "$OLD_TARBALL")"
        rm -f "$OLD_TARBALL"
        ((DELETED_COUNT++))
    done < <(find "$BASE_BACKUP_DIR" -maxdepth 1 -type f -name "lote-*.tar.gz" -mtime +$RETENTION_DAYS 2>/dev/null)

    if [ $DELETED_COUNT -gt 0 ]; then
        log_success "$DELETED_COUNT item(ns) antigo(s) removido(s)"
    else
        log_info "Nenhum backup antigo para remover"
    fi
fi

echo ""

### ========== RESUMO FINAL ==========
log_section "RESUMO DO BACKUP"
echo ""
echo "  📅 Data/Hora: $(date '+%Y-%m-%d %H:%M:%S')"
echo "  📁 Lote criado: $(basename "$LATEST_BATCH")"
echo "  💾 Tamanho: $BATCH_SIZE"
echo "  🎯 Destino: $UPLOAD_DEST"
echo ""
echo "  📂 Arquivos salvos em:"
echo "     $LATEST_BATCH"
if [ "$UPLOAD_DEST" != "local" ]; then
    echo ""
    echo "  📦 Tarball criado: $(basename "$TARBALL") ($TARBALL_SIZE)"
    echo "     $TARBALL"
fi
echo ""
echo "  📝 Log completo: $LOG_FILE"
echo ""

log_success "Backup automático concluído com sucesso!"
echo ""

# Calcular duração
BACKUP_END_TIME=$(date +%s)
BACKUP_DURATION=$((BACKUP_END_TIME - BACKUP_START_TIME))
BACKUP_DURATION_FMT=$(printf '%02d:%02d:%02d' $((BACKUP_DURATION/3600)) $((BACKUP_DURATION%3600/60)) $((BACKUP_DURATION%60)))

# Contar bancos de dados backupeados
DB_COUNT=$(find "$LATEST_BATCH" -name "*.sql.gz" -o -name "*.gz" 2>/dev/null | wc -l)

# Notificar sucesso com detalhes
notify_backup_success "Databases (Dumps SQL)" "$BATCH_SIZE" "$BACKUP_DURATION_FMT" "$UPLOAD_DEST" \
    "$DB_COUNT bancos de dados | Lote: $(basename "$LATEST_BATCH")"

exit 0
