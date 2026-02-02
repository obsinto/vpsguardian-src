#!/bin/bash
################################################################################
# Script: backup-database-volumes.sh
# Propósito: Backup ROBUSTO de volumes com detecção de bancos de dados
# Estratégia: Double-Check (Dump SQL + Snapshot de Volume)
# Autor: VPS Guardian - Production-Ready Migration System
################################################################################

# Carregar bibliotecas compartilhadas
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

# Carregar biblioteca de retenção
if [ -f "$SCRIPT_DIR/../lib/backup-retention.sh" ]; then
    source "$SCRIPT_DIR/../lib/backup-retention.sh"
fi

### ========== CONFIGURAÇÃO ==========
BACKUP_OUTPUT_DIR="${BACKUP_OUTPUT_DIR:-./volume-backup}"
BATCH_ID=$(date +%Y%m%d_%H%M%S)

### ========== DETECÇÃO DINÂMICA DE DATABASES ==========

# Detecta tipo de banco de dados por imagem Docker
detect_database_type() {
    local container_id="$1"
    local image=$(docker inspect --format='{{.Config.Image}}' "$container_id" 2>/dev/null)

    if [[ "$image" =~ mysql|mariadb ]]; then
        echo "mysql"
    elif [[ "$image" =~ postgres|postgresql ]]; then
        echo "postgres"
    elif [[ "$image" =~ mongo ]]; then
        echo "mongodb"
    elif [[ "$image" =~ redis ]]; then
        echo "redis"
    else
        echo "unknown"
    fi
}

# Obtém credenciais de banco de dados de variáveis de ambiente
get_db_credentials() {
    local container_id="$1"
    local db_type="$2"

    case "$db_type" in
        mysql)
            local root_pass=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$container_id" | grep -E '^MYSQL_ROOT_PASSWORD=' | cut -d'=' -f2)
            local db_name=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$container_id" | grep -E '^MYSQL_DATABASE=' | cut -d'=' -f2)
            echo "root:${root_pass}:${db_name:-all}"
            ;;
        postgres)
            local pg_pass=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$container_id" | grep -E '^POSTGRES_PASSWORD=' | cut -d'=' -f2)
            local pg_user=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$container_id" | grep -E '^POSTGRES_USER=' | cut -d'=' -f2)
            local pg_db=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$container_id" | grep -E '^POSTGRES_DB=' | cut -d'=' -f2)
            echo "${pg_user:-postgres}:${pg_pass}:${pg_db:-postgres}"
            ;;
        mongodb)
            local mongo_pass=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$container_id" | grep -E '^MONGO_INITDB_ROOT_PASSWORD=' | cut -d'=' -f2)
            local mongo_user=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$container_id" | grep -E '^MONGO_INITDB_ROOT_USERNAME=' | cut -d'=' -f2)
            echo "${mongo_user:-root}:${mongo_pass}:admin"
            ;;
        *)
            echo ":::"
            ;;
    esac
}

# Verifica se container está rodando e saudável
is_container_healthy() {
    local container_id="$1"
    local state=$(docker inspect --format='{{.State.Status}}' "$container_id" 2>/dev/null)

    if [ "$state" = "running" ]; then
        return 0
    else
        return 1
    fi
}

# Lista todos os containers que usam um volume específico
get_containers_using_volume() {
    local volume_name="$1"
    docker ps -a --filter "volume=${volume_name}" --format '{{.ID}}:{{.Names}}:{{.State}}' 2>/dev/null
}

### ========== DUMP SQL FUNCTIONS ==========

# MySQL/MariaDB Dump
dump_mysql() {
    local container_id="$1"
    local output_file="$2"
    local credentials="$3"

    local user=$(echo "$credentials" | cut -d':' -f1)
    local password=$(echo "$credentials" | cut -d':' -f2)
    local database=$(echo "$credentials" | cut -d':' -f3)

    log_info "  → Executando mysqldump..."

    if [ "$database" = "all" ]; then
        docker exec "$container_id" mysqldump \
            -u "$user" \
            -p"$password" \
            --all-databases \
            --single-transaction \
            --quick \
            --lock-tables=false \
            > "$output_file" 2>/dev/null
    else
        docker exec "$container_id" mysqldump \
            -u "$user" \
            -p"$password" \
            --single-transaction \
            --quick \
            --lock-tables=false \
            "$database" \
            > "$output_file" 2>/dev/null
    fi

    return $?
}

# PostgreSQL Dump
dump_postgres() {
    local container_id="$1"
    local output_file="$2"
    local credentials="$3"

    local user=$(echo "$credentials" | cut -d':' -f1)
    local password=$(echo "$credentials" | cut -d':' -f2)
    local database=$(echo "$credentials" | cut -d':' -f3)

    log_info "  → Executando pg_dump..."

    docker exec -e PGPASSWORD="$password" "$container_id" pg_dump \
        -U "$user" \
        -d "$database" \
        --clean \
        --if-exists \
        > "$output_file" 2>/dev/null

    return $?
}

# MongoDB Dump
dump_mongodb() {
    local container_id="$1"
    local output_dir="$2"
    local credentials="$3"

    local user=$(echo "$credentials" | cut -d':' -f1)
    local password=$(echo "$credentials" | cut -d':' -f2)

    log_info "  → Executando mongodump..."

    # MongoDB dump precisa de diretório, não arquivo único
    mkdir -p "$output_dir"

    docker exec "$container_id" mongodump \
        --username="$user" \
        --password="$password" \
        --authenticationDatabase=admin \
        --out=/tmp/mongodump \
        >/dev/null 2>&1

    if [ $? -eq 0 ]; then
        docker cp "$container_id:/tmp/mongodump/." "$output_dir/" >/dev/null 2>&1
        docker exec "$container_id" rm -rf /tmp/mongodump >/dev/null 2>&1
        return 0
    fi

    return 1
}

### ========== BACKUP INTELIGENTE COM METADATA ==========

backup_volume_with_intelligence() {
    local volume_name="$1"
    local output_dir="$2"
    local batch_id="$3"

    # Verificar se volume existe
    if ! docker volume inspect "$volume_name" >/dev/null 2>&1; then
        log_error "Volume não encontrado: $volume_name"
        return 1
    fi

    # Criar diretório de output
    ensure_directory "$output_dir" 755

    log_info "Analisando volume: $volume_name"

    # Detectar containers que usam este volume
    local containers=$(get_containers_using_volume "$volume_name")

    local db_type="unknown"
    local container_id=""
    local container_name=""
    local is_database=false

    # Analisar containers
    if [ -n "$containers" ]; then
        # Pegar primeiro container (geralmente o principal)
        container_id=$(echo "$containers" | head -1 | cut -d':' -f1)
        container_name=$(echo "$containers" | head -1 | cut -d':' -f2)

        db_type=$(detect_database_type "$container_id")

        if [ "$db_type" != "unknown" ]; then
            is_database=true
            log_info "  🗄️  Tipo detectado: $db_type (container: $container_name)"
        fi
    fi

    # Criar metadata do volume
    local meta_file="$output_dir/${volume_name}-backup-${batch_id}.meta"
    cat > "$meta_file" <<EOF
VOLUME_NAME=$volume_name
BATCH_ID=$batch_id
BACKUP_DATE=$(date '+%Y-%m-%d %H:%M:%S')
IS_DATABASE=$is_database
DB_TYPE=$db_type
CONTAINER_ID=$container_id
CONTAINER_NAME=$container_name
HOSTNAME=$(hostname)
EOF

    # Obter UID/GID do mountpoint
    local mountpoint=$(docker volume inspect --format='{{.Mountpoint}}' "$volume_name" 2>/dev/null)
    if [ -d "$mountpoint" ]; then
        local uid=$(stat -c '%u' "$mountpoint" 2>/dev/null || echo "N/A")
        local gid=$(stat -c '%g' "$mountpoint" 2>/dev/null || echo "N/A")
        echo "VOLUME_UID=$uid" >> "$meta_file"
        echo "VOLUME_GID=$gid" >> "$meta_file"
    fi

    ### ESTRATÉGIA DOUBLE-CHECK ###

    local dump_success=false
    local volume_backup_success=false

    # 1. DUMP SQL (se for banco de dados)
    if [ "$is_database" = true ] && is_container_healthy "$container_id"; then
        log_info "  📤 Exportação lógica (SQL dump)..."

        local credentials=$(get_db_credentials "$container_id" "$db_type")
        local dump_file="$output_dir/${volume_name}-dump-${batch_id}.sql"

        case "$db_type" in
            mysql)
                if dump_mysql "$container_id" "$dump_file" "$credentials"; then
                    dump_success=true
                    local dump_size=$(du -h "$dump_file" | cut -f1)
                    log_success "  ✅ Dump SQL criado: $dump_size"
                    echo "SQL_DUMP_FILE=${volume_name}-dump-${batch_id}.sql" >> "$meta_file"
                    echo "SQL_DUMP_SIZE=$(stat -c%s "$dump_file" 2>/dev/null || echo 0)" >> "$meta_file"
                fi
                ;;
            postgres)
                if dump_postgres "$container_id" "$dump_file" "$credentials"; then
                    dump_success=true
                    local dump_size=$(du -h "$dump_file" | cut -f1)
                    log_success "  ✅ Dump SQL criado: $dump_size"
                    echo "SQL_DUMP_FILE=${volume_name}-dump-${batch_id}.sql" >> "$meta_file"
                    echo "SQL_DUMP_SIZE=$(stat -c%s "$dump_file" 2>/dev/null || echo 0)" >> "$meta_file"
                fi
                ;;
            mongodb)
                local mongo_dump_dir="$output_dir/${volume_name}-mongodump-${batch_id}"
                if dump_mongodb "$container_id" "$mongo_dump_dir" "$credentials"; then
                    dump_success=true
                    # Comprimir MongoDB dump
                    tar -czf "$output_dir/${volume_name}-mongodump-${batch_id}.tar.gz" -C "$output_dir" "$(basename "$mongo_dump_dir")" 2>/dev/null
                    rm -rf "$mongo_dump_dir"
                    local dump_size=$(du -h "$output_dir/${volume_name}-mongodump-${batch_id}.tar.gz" | cut -f1)
                    log_success "  ✅ MongoDB dump criado: $dump_size"
                    echo "MONGO_DUMP_FILE=${volume_name}-mongodump-${batch_id}.tar.gz" >> "$meta_file"
                fi
                ;;
            redis)
                # Redis: apenas parar/pausar antes do backup de volume
                log_info "  ⏸️  Redis detectado - snapshot de volume será usado"
                ;;
        esac

        if [ "$dump_success" = false ]; then
            log_warning "  ⚠️  Dump SQL falhou ou não aplicável"
        fi
    fi

    # 2. SNAPSHOT DE VOLUME (sempre fazer como backup/fallback)
    log_info "  📦 Snapshot físico (volume backup)..."

    local backup_filename="${volume_name}-backup-${batch_id}.tar.gz"

    # Se for Redis ou DB com container rodando, pausar temporariamente
    local should_pause=false
    if [ "$is_database" = true ] && [ "$db_type" = "redis" ] && is_container_healthy "$container_id"; then
        should_pause=true
        log_info "  ⏸️  Pausando container para snapshot consistente..."
        docker pause "$container_id" >/dev/null 2>&1
    fi

    # Fazer backup do volume
    docker run --rm \
        -v "$volume_name":/source:ro \
        -v "$output_dir":/backup \
        busybox \
        tar -czf "/backup/${backup_filename}" -C /source . \
        >/dev/null 2>&1

    if [ $? -eq 0 ]; then
        volume_backup_success=true
        local size=$(du -h "$output_dir/${backup_filename}" | cut -f1)
        log_success "  ✅ Snapshot criado: $size"
        echo "VOLUME_BACKUP_FILE=${backup_filename}" >> "$meta_file"
        echo "VOLUME_BACKUP_SIZE=$(stat -c%s "$output_dir/${backup_filename}" 2>/dev/null || echo 0)" >> "$meta_file"
    else
        log_error "  ❌ Falha ao criar snapshot de volume"
    fi

    # Despausar se necessário
    if [ "$should_pause" = true ]; then
        docker unpause "$container_id" >/dev/null 2>&1
        log_info "  ▶️  Container despausado"
    fi

    # Finalizar metadata
    echo "DUMP_SUCCESS=$dump_success" >> "$meta_file"
    echo "VOLUME_BACKUP_SUCCESS=$volume_backup_success" >> "$meta_file"

    # Determinar sucesso geral
    if [ "$is_database" = true ]; then
        # Para bancos de dados, preferir dump SQL mas aceitar volume como fallback
        if [ "$dump_success" = true ] || [ "$volume_backup_success" = true ]; then
            if [ "$dump_success" = true ]; then
                log_success "Backup completo: $volume_name (SQL + Volume)"
            else
                log_warning "Backup parcial: $volume_name (apenas Volume - use com cuidado)"
            fi
            return 0
        else
            log_error "Backup falhou completamente: $volume_name"
            return 1
        fi
    else
        # Para volumes normais, apenas snapshot é suficiente
        if [ "$volume_backup_success" = true ]; then
            log_success "Backup completo: $volume_name"
            return 0
        else
            return 1
        fi
    fi
}

### ========== MAIN ==========
log_section "VPS Guardian - Backup Inteligente de Volumes"
log_info "Batch ID: $BATCH_ID"
echo ""

# Listar todos os volumes
volumes=($(docker volume ls -q))

if [ ${#volumes[@]} -eq 0 ]; then
    log_warning "Nenhum volume Docker encontrado"
    exit 0
fi

log_info "Encontrados ${#volumes[@]} volumes Docker"
echo ""

success_count=0
fail_count=0

# Processar cada volume
for volume in "${volumes[@]}"; do
    if backup_volume_with_intelligence "$volume" "$BACKUP_OUTPUT_DIR" "$BATCH_ID"; then
        ((success_count++))
    else
        ((fail_count++))
    fi
    echo ""
done

# Criar metadata geral do batch
cat > "$BACKUP_OUTPUT_DIR/.batch-${BATCH_ID}.meta" <<EOF
BATCH_ID=$BATCH_ID
CREATED=$(date '+%Y-%m-%d %H:%M:%S')
TOTAL_VOLUMES=${#volumes[@]}
SUCCESSFUL_BACKUPS=$success_count
FAILED_BACKUPS=$fail_count
HOSTNAME=$(hostname)
DOCKER_VERSION=$(docker --version 2>/dev/null || echo "N/A")
STRATEGY=DOUBLE_CHECK
EOF

# Aplicar política de retenção
if type apply_retention &>/dev/null && [ -n "$BACKUP_OUTPUT_DIR" ]; then
    log_section "Aplicando Política de Retenção"

    backups_antes=$(find "$BACKUP_OUTPUT_DIR" -name "*-backup-*.tar.gz" 2>/dev/null | wc -l)
    apply_retention "$BACKUP_OUTPUT_DIR" "$DEFAULT_RETENTION_STRATEGY" true
    backups_depois=$(find "$BACKUP_OUTPUT_DIR" -name "*-backup-*.tar.gz" 2>/dev/null | wc -l)
    backups_removidos=$((backups_antes - backups_depois))

    if [ "$backups_removidos" -gt 0 ]; then
        log_success "$backups_removidos backups antigos removidos (política: $DEFAULT_RETENTION_STRATEGY)"
    else
        log_info "Nenhum backup removido (dentro da política)"
    fi

    echo ""
fi

# Resumo final
log_section "RESUMO DO BACKUP"
echo "  🆔 Batch ID: $BATCH_ID"
echo "  ✅ Sucesso: $success_count volumes"
if [ $fail_count -gt 0 ]; then
    echo "  ❌ Falha: $fail_count volumes"
fi
echo "  📁 Diretório: $BACKUP_OUTPUT_DIR"
if type apply_retention &>/dev/null && [ -n "$backups_removidos" ]; then
    echo "  🗑️  Limpeza: $backups_removidos backups removidos"
fi
echo ""
echo "  💡 Estratégia: Double-Check (SQL Dump + Volume Snapshot)"
echo "     Bancos de dados: Dump SQL prioritário, Volume como fallback"
echo "     Outros volumes: Snapshot direto"
echo ""

if [ $fail_count -gt 0 ]; then
    exit 1
else
    exit 0
fi
