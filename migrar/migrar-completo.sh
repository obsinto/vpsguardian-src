#!/bin/bash
################################################################################
# Script: migrar-completo.sh
# Propósito: Migração COMPLETA Coolify + Apps (DB + Volumes + Configurações)
# Uso: ./migrar-completo.sh [--config=FILE] [--auto] [--skip-volumes]
################################################################################

# Carregar bibliotecas compartilhadas
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../lib/reporting.sh"

### ========== CONFIGURAÇÃO PADRÃO ==========
NEW_SERVER_IP="${NEW_SERVER_IP:-}"
NEW_SERVER_USER="${NEW_SERVER_USER:-root}"
NEW_SERVER_PORT="${NEW_SERVER_PORT:-22}"
SSH_PRIVATE_KEY_PATH="${SSH_PRIVATE_KEY_PATH:-/root/.ssh/id_rsa}"

BACKUP_FILE="${BACKUP_FILE:-}"
SKIP_VOLUMES=false
AUTO_MODE=false
REPLACE_EXISTING=false
REQUIRE_DESTINATION_MARKER=""
JSON_REPORT=""
JUNIT_REPORT=""
CURRENT_PHASE="arguments"
MIGRATION_STARTED_AT=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

VOLUMES_BACKUP_DIR=""

### ========== PARSE ARGUMENTOS ==========
CONFIG_FILE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --config=*)
            CONFIG_FILE="${1#*=}"
            shift
            ;;
        --auto)
            AUTO_MODE=true
            shift
            ;;
        --skip-volumes)
            SKIP_VOLUMES=true
            shift
            ;;
        --replace-existing)
            REPLACE_EXISTING=true
            shift
            ;;
        --require-destination-marker=*)
            REQUIRE_DESTINATION_MARKER="${1#*=}"
            shift
            ;;
        --json-report=*)
            JSON_REPORT="${1#*=}"
            shift
            ;;
        --junit-report=*)
            JUNIT_REPORT="${1#*=}"
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Migração COMPLETA do Coolify (DB + Volumes + Configurações)"
            echo ""
            echo "Options:"
            echo "  --config=FILE      Load configuration from file"
            echo "  --auto             Run in automatic mode (no prompts)"
            echo "  --skip-volumes     Skip application volumes migration"
            echo "  --replace-existing Replace existing Coolify only with E2E guard enabled"
            echo "  --require-destination-marker=PATH  Require marker and ALLOW_DESTRUCTIVE_E2E=YES"
            echo "  --json-report=FILE Write a machine-readable JSON result"
            echo "  --junit-report=FILE Write a JUnit XML result"
            echo "  -h, --help         Show this help"
            echo ""
            echo "Este script executa:"
            echo "  1. Backup do Coolify (DB + SSH keys + .env)"
            echo "  2. Backup de TODOS os volumes Docker (aplicações)"
            echo "  3. Migração do Coolify para novo servidor"
            echo "  4. Transferência dos volumes para novo servidor"
            echo "  5. Restore dos volumes no novo servidor"
            echo ""
            echo "Configuration file: use migration.conf.example as template"
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Carregar configuração
if [ -n "$CONFIG_FILE" ]; then
    if [ ! -f "$CONFIG_FILE" ]; then
        log_error "Configuration file not found: $CONFIG_FILE"
        exit 2
    fi
    log_info "Loading configuration from $CONFIG_FILE"
    source "$CONFIG_FILE"
fi

MIGRATE_PROXY="${MIGRATE_PROXY:-true}"
KEY_ROTATION_MODE="${KEY_ROTATION_MODE:-1}"
DESTINATION_MARKER_FILE="${REQUIRE_DESTINATION_MARKER:-${DESTINATION_MARKER_FILE:-}}"

write_migration_reports() {
    local exit_code="$1"
    local status="failed"
    local finished_at
    finished_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    [ "$exit_code" -eq 0 ] && status="passed"

    if [ -n "$JSON_REPORT" ] && vpsg_prepare_report_path "$JSON_REPORT"; then
        {
            printf '{\n'
            printf '  "status": "%s",\n' "$status"
            printf '  "exit_code": %s,\n' "$exit_code"
            printf '  "phase": "%s",\n' "$(vpsg_json_escape "$CURRENT_PHASE")"
            printf '  "target": "%s",\n' "$(vpsg_json_escape "$NEW_SERVER_USER@$NEW_SERVER_IP:$NEW_SERVER_PORT")"
            printf '  "started_at": "%s",\n' "$MIGRATION_STARTED_AT"
            printf '  "finished_at": "%s",\n' "$finished_at"
            printf '  "skip_volumes": %s,\n' "$SKIP_VOLUMES"
            printf '  "volume_backups": %s\n' "${backup_count:-0}"
            printf '}\n'
        } > "$JSON_REPORT"
    fi

    if [ -n "$JUNIT_REPORT" ] && vpsg_prepare_report_path "$JUNIT_REPORT"; then
        {
            printf '<testsuite name="vpsguardian.migration" tests="1" failures="%s">\n' "$([ "$exit_code" -eq 0 ] && echo 0 || echo 1)"
            printf '  <testcase name="complete-migration-to-%s">' "$(vpsg_xml_escape "$NEW_SERVER_IP")"
            [ "$exit_code" -ne 0 ] && printf '<failure message="failed in phase %s"/>' "$(vpsg_xml_escape "$CURRENT_PHASE")"
            printf '</testcase>\n'
            printf '</testsuite>\n'
        } > "$JUNIT_REPORT"
    fi
}

on_migration_exit() {
    local exit_code=$?
    write_migration_reports "$exit_code"
}

trap on_migration_exit EXIT

### ========== VALIDAÇÃO ==========
CURRENT_PHASE="preflight"
log_section "VPS Guardian - Migração Completa Coolify + Apps"

if [ -z "$NEW_SERVER_IP" ]; then
    if [ "$AUTO_MODE" = true ]; then
        log_error "NEW_SERVER_IP is required in automatic mode"
        exit 1
    fi
    read -p "Enter NEW server IP: " NEW_SERVER_IP
fi

if [ -z "$NEW_SERVER_IP" ]; then
    log_error "Server IP is required"
    exit 1
fi

log_info "Target server: $NEW_SERVER_USER@$NEW_SERVER_IP:$NEW_SERVER_PORT"

# Verificar chave SSH
if [ ! -f "$SSH_PRIVATE_KEY_PATH" ]; then
    log_error "SSH key not found: $SSH_PRIVATE_KEY_PATH"
    exit 1
fi

if [ "$REPLACE_EXISTING" = true ] && [ -z "$DESTINATION_MARKER_FILE" ]; then
    log_error "--replace-existing exige --require-destination-marker=PATH"
    exit 2
fi

if [ -n "$DESTINATION_MARKER_FILE" ]; then
    if [[ ! "$DESTINATION_MARKER_FILE" =~ ^/[A-Za-z0-9._/-]+$ ]] || \
       [[ "/$DESTINATION_MARKER_FILE/" == *"/../"* ]]; then
        log_error "Caminho de marcador inválido: $DESTINATION_MARKER_FILE"
        exit 2
    fi
    if [ "${ALLOW_DESTRUCTIVE_E2E:-}" != "YES" ]; then
        log_error "Destino protegido: defina ALLOW_DESTRUCTIVE_E2E=YES para usar o marcador"
        exit 2
    fi
fi

SSH_PREFLIGHT=(
    ssh -i "$SSH_PRIVATE_KEY_PATH" -p "$NEW_SERVER_PORT"
    -o BatchMode=yes -o ConnectTimeout=10
    "$NEW_SERVER_USER@$NEW_SERVER_IP"
)

log_info "Validating destination SSH before creating backups..."
if ! "${SSH_PREFLIGHT[@]}" "exit" >/dev/null 2>&1; then
    log_error "Cannot connect to destination with the configured SSH key"
    exit 1
fi

SOURCE_MACHINE_ID=$(cat /etc/machine-id 2>/dev/null)
DESTINATION_MACHINE_ID=$("${SSH_PREFLIGHT[@]}" "cat /etc/machine-id" 2>/dev/null)
if [ -z "$SOURCE_MACHINE_ID" ] || [ -z "$DESTINATION_MACHINE_ID" ]; then
    log_error "Could not compare source and destination machine identities"
    exit 1
fi
if [ "$SOURCE_MACHINE_ID" = "$DESTINATION_MACHINE_ID" ]; then
    log_error "Source and destination have the same /etc/machine-id; aborting"
    exit 2
fi

if [ -n "$DESTINATION_MARKER_FILE" ]; then
    if ! "${SSH_PREFLIGHT[@]}" "test -f '$DESTINATION_MARKER_FILE'" >/dev/null 2>&1; then
        log_error "Required destination marker not found: $DESTINATION_MARKER_FILE"
        exit 2
    fi
    log_success "Disposable destination marker validated"
fi

# Contar volumes
volume_count=$(docker volume ls -q | wc -l)
log_info "Docker volumes found: $volume_count"

if [ "$SKIP_VOLUMES" = true ]; then
    log_warning "Volume migration will be SKIPPED (--skip-volumes flag)"
fi

# Confirmar migração
if [ "$AUTO_MODE" = false ]; then
    echo ""
    log_section "MIGRATION PLAN"
    echo "  📋 Steps:"
    echo "     1. Backup Coolify (DB + config)"
    if [ "$SKIP_VOLUMES" = false ]; then
        echo "     2. Backup $volume_count Docker volumes"
        echo "     3. Migrate Coolify to $NEW_SERVER_IP"
        echo "     4. Transfer volumes to $NEW_SERVER_IP"
        echo "     5. Restore volumes on $NEW_SERVER_IP"
    else
        echo "     2. Migrate Coolify to $NEW_SERVER_IP (VOLUMES SKIPPED)"
    fi
    echo ""
    echo "  ⏱️  Estimated time: 30min-3h (depends on data size)"
    echo "  ⚠️  Downtime: YES (applications will be down during migration)"
    echo ""
    read -p "Proceed with COMPLETE migration? Type 'YES' to confirm: " confirm

    if [ "$confirm" != "YES" ]; then
        log_info "Migration cancelled by user"
        exit 0
    fi
fi

### ========== STEP 1: BACKUP COOLIFY ==========
CURRENT_PHASE="backup_coolify"
log_section "Step 1/5: Backup Coolify"

log_info "Running backup-coolify.sh..."
"$SCRIPT_DIR/../backup/backup-coolify.sh" >/dev/null 2>&1

if [ $? -ne 0 ]; then
    log_error "Coolify backup failed"
    exit 1
fi

# Obter backup mais recente se não especificado
if [ -z "$BACKUP_FILE" ]; then
    BACKUP_FILE=$(ls -t "${COOLIFY_BACKUP_DIR:-$BACKUP_ROOT/coolify}"/*.tar.gz 2>/dev/null | head -1)
fi

if [ ! -f "$BACKUP_FILE" ]; then
    log_error "Backup file not found"
    exit 1
fi

log_success "Coolify backup: $(basename $BACKUP_FILE)"

### ========== STEP 2: BACKUP VOLUMES (MODO ROBUSTO) ==========
if [ "$SKIP_VOLUMES" = false ]; then
    CURRENT_PHASE="backup_volumes"
    log_section "Step 2/5: Backup Docker Volumes (Modo Robusto)"

    if ! VOLUMES_BACKUP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/vpsguardian-volumes-migration.XXXXXX"); then
        log_error "Não foi possível criar diretório temporário seguro"
        exit 1
    fi

    log_info "Usando backup inteligente com detecção de bancos de dados..."
    log_info "Estratégia: Double-Check (SQL Dump + Volume Snapshot)"
    echo ""

    # Usar novo script robusto
    "$SCRIPT_DIR/backup-volumes.sh" --all --auto \
        --output="$VOLUMES_BACKUP_DIR" --strategy=double-check

    if [ $? -ne 0 ]; then
        log_error "Um ou mais volumes falharam no backup; migração cancelada"
        log_info "Backups parciais preservados em: $VOLUMES_BACKUP_DIR"
        exit 1
    fi

    # Contar backups criados (arquivos .meta são criados para cada volume)
    backup_count=$(find "$VOLUMES_BACKUP_DIR" -name "*-backup-*.meta" -type f | wc -l)

    if [ "$backup_count" -eq 0 ]; then
        log_warning "No volume backups created (this is OK if no volumes exist)"
    else
        log_success "$backup_count volume backups created"

        # Mostrar estatísticas
        db_backups=$(find "$VOLUMES_BACKUP_DIR" -name "*-dump-*.sql" -type f | wc -l)
        if [ "$db_backups" -gt 0 ]; then
            log_info "  📊 Dumps SQL criados: $db_backups"
        fi
    fi
else
    log_section "Step 2/5: SKIPPED (--skip-volumes)"
fi

### ========== STEP 3: MIGRATE COOLIFY ==========
CURRENT_PHASE="migrate_coolify"
log_section "Step 3/5: Migrate Coolify to New Server"

# Preparar variáveis para migrar-coolify.sh
export NEW_SERVER_IP
export NEW_SERVER_USER
export NEW_SERVER_PORT
export SSH_PRIVATE_KEY_PATH
export BACKUP_FILE
export MIGRATE_PROXY
export KEY_ROTATION_MODE

log_info "Running migrar-coolify.sh..."

COOLIFY_MIGRATION_ARGS=()
[ "$AUTO_MODE" = true ] && COOLIFY_MIGRATION_ARGS+=(--auto)
[ "$REPLACE_EXISTING" = true ] && COOLIFY_MIGRATION_ARGS+=(--replace-existing)
"$SCRIPT_DIR/migrar-coolify.sh" "${COOLIFY_MIGRATION_ARGS[@]}"

if [ $? -ne 0 ]; then
    log_error "Coolify migration failed"
    log_info "Cleaning up..."
        [ -n "$VOLUMES_BACKUP_DIR" ] && rm -rf "$VOLUMES_BACKUP_DIR"
    exit 1
fi

log_success "Coolify migrated successfully"

### ========== STEP 4: TRANSFER VOLUMES ==========
if [ "$SKIP_VOLUMES" = false ] && [ "$backup_count" -gt 0 ]; then
    CURRENT_PHASE="transfer_volumes"
    log_section "Step 4/5: Transfer Volumes to New Server"

    # Preparar configuração para transfer-volumes.sh
    export SSH_IP="$NEW_SERVER_IP"
    export SSH_USER="$NEW_SERVER_USER"
    export SSH_PORT="$NEW_SERVER_PORT"
    export SSH_KEY="$SSH_PRIVATE_KEY_PATH"
    export SOURCE_PATH="$VOLUMES_BACKUP_DIR"
    export DESTINATION_PATH="/root/coolify-volumes-backup"

    log_info "Transferring $backup_count volume backups..."
    "$SCRIPT_DIR/transfer-volumes.sh" --auto

    if [ $? -ne 0 ]; then
        log_error "Volume transfer failed"
        log_warning "Coolify was migrated but volumes failed to transfer"
        log_info "You can manually transfer volumes from: $VOLUMES_BACKUP_DIR"
        exit 1
    fi

    log_success "All volumes transferred"
else
    log_section "Step 4/5: SKIPPED (no volumes to transfer)"
fi

### ========== STEP 5: RESTORE VOLUMES (MODO INTELIGENTE) ==========
if [ "$SKIP_VOLUMES" = false ] && [ "$backup_count" -gt 0 ]; then
    CURRENT_PHASE="restore_volumes"
    log_section "Step 5/5: Restore Volumes on New Server (Modo Inteligente)"

    log_info "Usando restore inteligente com fallback automático..."
    log_info "Estratégia: Volume primeiro, SQL dump se crash loop detectado"
    echo ""

    # Preservar a mesma estrutura relativa esperada pelos scripts (migrar/../lib).
    log_info "Transferindo scripts de restore..."
    if ! ssh -i "$SSH_PRIVATE_KEY_PATH" -p "$NEW_SERVER_PORT" \
        "$NEW_SERVER_USER@$NEW_SERVER_IP" \
        "mkdir -p /tmp/vpsguardian-migration/migrar /tmp/vpsguardian-migration/lib" >/dev/null 2>&1 ||
       ! scp -i "$SSH_PRIVATE_KEY_PATH" -P "$NEW_SERVER_PORT" \
        "$SCRIPT_DIR/restore-database-volumes.sh" \
        "$NEW_SERVER_USER@$NEW_SERVER_IP:/tmp/vpsguardian-migration/migrar/" >/dev/null 2>&1 ||
       ! scp -i "$SSH_PRIVATE_KEY_PATH" -P "$NEW_SERVER_PORT" \
        "$SCRIPT_DIR/../lib/"*.sh \
        "$NEW_SERVER_USER@$NEW_SERVER_IP:/tmp/vpsguardian-migration/lib/" >/dev/null 2>&1; then
        log_error "Falha ao transferir os scripts de restore"
        log_info "Backup local preservado em: $VOLUMES_BACKUP_DIR"
        exit 1
    fi

    log_info "Executando restore inteligente remotamente..."
    echo ""

    # Executar restore no servidor remoto
    ssh -i "$SSH_PRIVATE_KEY_PATH" -p "$NEW_SERVER_PORT" \
        "$NEW_SERVER_USER@$NEW_SERVER_IP" \
        "BACKUP_DIR=/root/coolify-volumes-backup bash /tmp/vpsguardian-migration/migrar/restore-database-volumes.sh"

    restore_exit_code=$?

    if [ $restore_exit_code -eq 0 ]; then
        log_success "Todos os volumes restaurados com sucesso"
    elif [ $restore_exit_code -eq 2 ]; then
        log_error "Volumes restaurados apenas parcialmente; migração requer verificação"
        log_info "Backup local preservado em: $VOLUMES_BACKUP_DIR"
        exit 2
    else
        log_error "Alguns volumes falharam ao restaurar"
        log_warning "Verifique logs em $NEW_SERVER_IP para detalhes"
        log_info "Backup local preservado em: $VOLUMES_BACKUP_DIR"
        exit 1
    fi

    ssh -i "$SSH_PRIVATE_KEY_PATH" -p "$NEW_SERVER_PORT" \
        "$NEW_SERVER_USER@$NEW_SERVER_IP" \
        "rm -rf /tmp/vpsguardian-migration" >/dev/null 2>&1 || true
else
    log_section "Step 5/5: SKIPPED (no volumes to restore)"
fi

### ========== CLEANUP ==========
log_info "Cleaning up local temporary files..."
[ -n "$VOLUMES_BACKUP_DIR" ] && rm -rf "$VOLUMES_BACKUP_DIR"

### ========== FINAL SUMMARY ==========
echo ""
log_section "MIGRATION COMPLETE"
echo ""
echo "  🎉 Coolify + Applications migrated successfully!"
echo ""
echo "  📍 New server: http://$NEW_SERVER_IP:8000"
echo "  📦 Coolify: ✅ Migrated (DB + SSH keys + config)"
if [ "$SKIP_VOLUMES" = false ]; then
    echo "  📂 Volumes: ✅ $backup_count volumes migrated"
    echo "  🔒 Strategy: Double-Check (SQL Dump + Volume Snapshot)"
else
    echo "  📂 Volumes: ⏭️  SKIPPED"
fi
echo ""
echo "  ⚠️  IMPORTANT NEXT STEPS:"
echo ""
echo "  1. Access Coolify: http://$NEW_SERVER_IP:8000"
echo "  2. Check all applications are listed"
echo "  3. Verify database containers are healthy:"
echo "     docker ps | grep -E 'mysql|postgres|mongo|redis'"
echo "  4. If any DB is in crash loop, restore was auto-fallback to SQL dump"
echo "  5. DEPLOY each application to start containers"
echo "     (volumes are restored but containers need to be recreated)"
echo "  6. Update DNS records to point to $NEW_SERVER_IP"
echo "  7. Test all applications thoroughly"
echo "  8. Configure backups on new server"
echo ""
echo "  💡 TIP: Restore inteligente detecta crash loops automaticamente!"
echo "          Se volume corrompido → fallback para SQL dump"
echo "          Bancos de dados têm dupla proteção (volume + SQL)"
echo ""
echo "  🔍 TROUBLESHOOTING:"
echo "     Se algum DB não subir: docker logs <container_name>"
echo "     Dumps SQL disponíveis em: /root/coolify-volumes-backup/"
echo ""

log_success "Migration completed successfully with intelligent database handling"
CURRENT_PHASE="complete"
exit 0
