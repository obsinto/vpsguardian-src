#!/bin/bash
################################################################################
# Script: restore-database-volumes.sh
# Propósito: Restore INTELIGENTE com fallback automático
# Estratégia: Volume primeiro, SQL dump se falhar (crash loop detection)
# Autor: VPS Guardian - Production-Ready Migration System
################################################################################

# Carregar bibliotecas compartilhadas
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

### ========== CONFIGURAÇÃO ==========
BACKUP_DIR="${BACKUP_DIR:-/root/coolify-volumes-backup}"
HEALTH_CHECK_TIMEOUT=30
CRASH_LOOP_DETECTION_SAMPLES=3

### ========== FUNÇÕES DE HEALTH CHECK ==========

# Aguarda container iniciar e verifica se está saudável
wait_for_container_healthy() {
    local container_name="$1"
    local timeout="${2:-$HEALTH_CHECK_TIMEOUT}"
    local elapsed=0

    log_info "  ⏳ Aguardando container iniciar ($timeout segundos)..."

    while [ $elapsed -lt $timeout ]; do
        local state=$(docker inspect --format='{{.State.Status}}' "$container_name" 2>/dev/null)

        if [ "$state" = "running" ]; then
            log_success "  ✅ Container está rodando"
            return 0
        elif [ "$state" = "exited" ] || [ "$state" = "dead" ]; then
            log_error "  ❌ Container falhou ao iniciar (estado: $state)"
            return 1
        fi

        sleep 2
        ((elapsed+=2))
    done

    log_error "  ❌ Timeout aguardando container iniciar"
    return 1
}

# Detecta crash loop analisando logs do container
detect_crash_loop() {
    local container_name="$1"
    local samples="${2:-$CRASH_LOOP_DETECTION_SAMPLES}"

    log_info "  🔍 Verificando crash loop (${samples} amostras)..."

    local crash_detected=false

    for i in $(seq 1 $samples); do
        sleep 3

        local state=$(docker inspect --format='{{.State.Status}}' "$container_name" 2>/dev/null)

        if [ "$state" = "exited" ] || [ "$state" = "restarting" ]; then
            # Analisar logs para erros conhecidos
            local logs=$(docker logs "$container_name" 2>&1 | tail -50)

            # MySQL/MariaDB crash patterns
            if echo "$logs" | grep -qi "redo log.*comes from other data directory"; then
                log_error "  ❌ Crash Loop detectado: InnoDB redo log corruption"
                crash_detected=true
                break
            elif echo "$logs" | grep -qi "InnoDB.*initialization.*abort"; then
                log_error "  ❌ Crash Loop detectado: InnoDB initialization failed"
                crash_detected=true
                break
            elif echo "$logs" | grep -qi "Data Dictionary initialization failed"; then
                log_error "  ❌ Crash Loop detectado: MySQL Data Dictionary error"
                crash_detected=true
                break
            fi

            # PostgreSQL crash patterns
            if echo "$logs" | grep -qi "FATAL.*database system is in recovery mode"; then
                log_error "  ❌ Crash Loop detectado: PostgreSQL recovery mode stuck"
                crash_detected=true
                break
            fi

            # MongoDB crash patterns
            if echo "$logs" | grep -qi "exception in initAndListen"; then
                log_error "  ❌ Crash Loop detectado: MongoDB initialization error"
                crash_detected=true
                break
            fi
        elif [ "$state" = "running" ]; then
            # Container rodando, sem crash loop
            log_success "  ✅ Nenhum crash loop detectado (container saudável)"
            return 1  # Retorna 1 = sem crash (invertido para lógica)
        fi
    done

    if [ "$crash_detected" = true ]; then
        return 0  # Retorna 0 = crash detectado
    else
        log_warning "  ⚠️  Container instável mas sem padrão de crash identificado"
        return 2  # Código 2 = inconclusivo
    fi
}

### ========== RESTORE DE VOLUME ==========

restore_volume_from_snapshot() {
    local volume_name="$1"
    local backup_file="$2"

    if [ ! -f "$backup_file" ]; then
        log_error "Arquivo de backup não encontrado: $backup_file"
        return 1
    fi

    log_info "  📦 Restaurando volume de snapshot..."

    # CORREÇÃO: Se volume já existe, remover completamente para evitar mistura de arquivos
    # Isso resolve o problema de redo logs corrompidos no MySQL após migração
    if docker volume inspect "$volume_name" >/dev/null 2>&1; then
        log_info "  🧹 Volume existente detectado, removendo para restore limpo..."

        # Parar containers que usam este volume
        local containers_using=$(docker ps -a --filter "volume=$volume_name" --format '{{.Names}}' 2>/dev/null)
        if [ -n "$containers_using" ]; then
            log_info "  ⏸️  Parando containers que usam o volume..."
            for container in $containers_using; do
                docker stop "$container" >/dev/null 2>&1 || true
            done
        fi

        # Remover volume completamente
        if ! docker volume rm "$volume_name" >/dev/null 2>&1; then
            log_warning "  ⚠️  Não foi possível remover volume, limpando conteúdo..."
            docker run --rm -v "$volume_name":/target busybox \
                sh -c "rm -rf /target/* /target/..?* /target/.[!.]* 2>/dev/null" >/dev/null 2>&1
        fi
    fi

    # Criar volume limpo
    docker volume create "$volume_name" >/dev/null 2>&1 || true

    # Restaurar dados em volume limpo
    docker run --rm \
        -v "$volume_name":/target \
        -v "$(dirname "$backup_file")":/backup:ro \
        busybox \
        sh -c "tar -xzf /backup/$(basename "$backup_file") -C /target" \
        >/dev/null 2>&1

    if [ $? -eq 0 ]; then
        log_success "  ✅ Volume restaurado de snapshot (restore limpo)"
        return 0
    else
        log_error "  ❌ Falha ao restaurar volume"
        return 1
    fi
}

### ========== RESTORE DE SQL DUMP ==========

restore_mysql_from_dump() {
    local container_name="$1"
    local dump_file="$2"
    local credentials="$3"

    local user=$(echo "$credentials" | cut -d':' -f1)
    local password=$(echo "$credentials" | cut -d':' -f2)

    log_info "  📥 Restaurando MySQL de dump SQL..."

    # Aguardar MySQL aceitar conexões
    log_info "  ⏳ Aguardando MySQL aceitar conexões..."
    local retries=0
    while [ $retries -lt 30 ]; do
        if docker exec "$container_name" mysqladmin ping -u "$user" -p"$password" >/dev/null 2>&1; then
            break
        fi
        sleep 2
        ((retries++))
    done

    if [ $retries -ge 30 ]; then
        log_error "  ❌ Timeout: MySQL não aceitou conexões"
        return 1
    fi

    # Restaurar dump
    cat "$dump_file" | docker exec -i "$container_name" mysql -u "$user" -p"$password" 2>/dev/null

    if [ $? -eq 0 ]; then
        log_success "  ✅ MySQL restaurado de dump SQL"
        return 0
    else
        log_error "  ❌ Falha ao restaurar dump SQL"
        return 1
    fi
}

restore_postgres_from_dump() {
    local container_name="$1"
    local dump_file="$2"
    local credentials="$3"

    local user=$(echo "$credentials" | cut -d':' -f1)
    local password=$(echo "$credentials" | cut -d':' -f2)
    local database=$(echo "$credentials" | cut -d':' -f3)

    log_info "  📥 Restaurando PostgreSQL de dump SQL..."

    # Aguardar PostgreSQL aceitar conexões
    log_info "  ⏳ Aguardando PostgreSQL aceitar conexões..."
    local retries=0
    while [ $retries -lt 30 ]; do
        if docker exec -e PGPASSWORD="$password" "$container_name" pg_isready -U "$user" >/dev/null 2>&1; then
            break
        fi
        sleep 2
        ((retries++))
    done

    if [ $retries -ge 30 ]; then
        log_error "  ❌ Timeout: PostgreSQL não aceitou conexões"
        return 1
    fi

    # Restaurar dump
    cat "$dump_file" | docker exec -i -e PGPASSWORD="$password" "$container_name" psql -U "$user" -d "$database" 2>/dev/null

    if [ $? -eq 0 ]; then
        log_success "  ✅ PostgreSQL restaurado de dump SQL"
        return 0
    else
        log_error "  ❌ Falha ao restaurar dump SQL"
        return 1
    fi
}

restore_mongodb_from_dump() {
    local container_name="$1"
    local dump_archive="$2"
    local credentials="$3"

    local user=$(echo "$credentials" | cut -d':' -f1)
    local password=$(echo "$credentials" | cut -d':' -f2)

    log_info "  📥 Restaurando MongoDB de dump..."

    # Extrair dump dentro do container
    local temp_dir="/tmp/mongorestore-$$"
    mkdir -p "$temp_dir"
    tar -xzf "$dump_archive" -C "$temp_dir" 2>/dev/null

    # Copiar para container
    docker cp "$temp_dir/." "$container_name:/tmp/mongorestore/" >/dev/null 2>&1

    # Restaurar
    docker exec "$container_name" mongorestore \
        --username="$user" \
        --password="$password" \
        --authenticationDatabase=admin \
        --drop \
        /tmp/mongorestore/ \
        >/dev/null 2>&1

    local result=$?

    # Cleanup
    docker exec "$container_name" rm -rf /tmp/mongorestore >/dev/null 2>&1
    rm -rf "$temp_dir"

    if [ $result -eq 0 ]; then
        log_success "  ✅ MongoDB restaurado de dump"
        return 0
    else
        log_error "  ❌ Falha ao restaurar MongoDB"
        return 1
    fi
}

### ========== RESTORE INTELIGENTE COM FALLBACK ==========

intelligent_restore() {
    local volume_name="$1"
    local backup_dir="$2"

    log_section "Restaurando: $volume_name"

    # Procurar metadata
    local meta_file=$(find "$backup_dir" -name "${volume_name}-backup-*.meta" -type f | head -1)

    if [ ! -f "$meta_file" ]; then
        log_warning "Metadata não encontrada, usando restore simples de volume"
        local volume_backup=$(find "$backup_dir" -name "${volume_name}-backup-*.tar.gz" -type f | head -1)
        if [ -f "$volume_backup" ]; then
            restore_volume_from_snapshot "$volume_name" "$volume_backup"
            return $?
        else
            log_error "Nenhum backup encontrado para $volume_name"
            return 1
        fi
    fi

    # Carregar metadata
    source "$meta_file"

    log_info "Tipo: ${DB_TYPE:-volume normal}"
    log_info "Container original: ${CONTAINER_NAME:-N/A}"

    # PASSO 1: Tentar restore de volume (rápido)
    if [ -n "$VOLUME_BACKUP_FILE" ] && [ -f "$backup_dir/$VOLUME_BACKUP_FILE" ]; then
        log_info "Estratégia: Volume snapshot primeiro (rollback para SQL se falhar)"

        if restore_volume_from_snapshot "$volume_name" "$backup_dir/$VOLUME_BACKUP_FILE"; then

            # Se for banco de dados, precisa validar se funcionou
            if [ "$IS_DATABASE" = "true" ] && [ -n "$CONTAINER_NAME" ]; then

                log_info "Validando integridade do banco de dados..."

                # Aguardar container subir
                if ! wait_for_container_healthy "$CONTAINER_NAME" 45; then
                    log_warning "Container não iniciou corretamente"

                    # Detectar crash loop
                    if detect_crash_loop "$CONTAINER_NAME"; then
                        log_warning "CRASH LOOP confirmado! Iniciando fallback para SQL dump..."

                        # FALLBACK: Limpar volume e usar SQL dump
                        log_info "Limpando volume corrompido..."
                        docker volume rm "$volume_name" >/dev/null 2>&1
                        docker volume create "$volume_name" >/dev/null 2>&1

                        # Tentar restaurar de SQL dump
                        return restore_from_sql_dump "$volume_name" "$backup_dir" "$meta_file"
                    else
                        log_warning "Container instável mas sem crash loop claro"
                        return 2  # Código de aviso
                    fi
                else
                    log_success "✅ Volume restaurado e validado com sucesso"
                    return 0
                fi
            else
                # Não é DB, restauração de volume é suficiente
                log_success "✅ Volume restaurado com sucesso"
                return 0
            fi
        else
            log_error "Falha ao restaurar volume"
            return 1
        fi
    fi

    # PASSO 2: Não tem volume backup, tentar SQL dump direto
    log_info "Volume snapshot não disponível, usando SQL dump"
    return restore_from_sql_dump "$volume_name" "$backup_dir" "$meta_file"
}

restore_from_sql_dump() {
    local volume_name="$1"
    local backup_dir="$2"
    local meta_file="$3"

    source "$meta_file"

    # Verificar se tem dump SQL
    if [ -z "$SQL_DUMP_FILE" ] && [ -z "$MONGO_DUMP_FILE" ]; then
        log_error "Nenhum dump SQL disponível para fallback"
        return 1
    fi

    case "$DB_TYPE" in
        mysql)
            if [ -f "$backup_dir/$SQL_DUMP_FILE" ]; then
                # Container precisa estar rodando com volume limpo
                restore_mysql_from_dump "$CONTAINER_NAME" "$backup_dir/$SQL_DUMP_FILE" "root:password:all"
                return $?
            fi
            ;;
        postgres)
            if [ -f "$backup_dir/$SQL_DUMP_FILE" ]; then
                restore_postgres_from_dump "$CONTAINER_NAME" "$backup_dir/$SQL_DUMP_FILE" "postgres:password:postgres"
                return $?
            fi
            ;;
        mongodb)
            if [ -f "$backup_dir/$MONGO_DUMP_FILE" ]; then
                restore_mongodb_from_dump "$CONTAINER_NAME" "$backup_dir/$MONGO_DUMP_FILE" "root:password:admin"
                return $?
            fi
            ;;
        *)
            log_error "Tipo de banco não suportado para restore de SQL: $DB_TYPE"
            return 1
            ;;
    esac

    log_error "Arquivo de dump SQL não encontrado"
    return 1
}

### ========== MAIN ==========
log_section "VPS Guardian - Restore Inteligente de Volumes"

if [ ! -d "$BACKUP_DIR" ]; then
    log_error "Diretório de backup não encontrado: $BACKUP_DIR"
    exit 1
fi

log_info "Diretório de backup: $BACKUP_DIR"
echo ""

# Listar volumes para restaurar
volumes=($(find "$BACKUP_DIR" -name "*-backup-*.meta" -type f -exec basename {} \; | sed 's/-backup-.*\.meta$//' | sort -u))

if [ ${#volumes[@]} -eq 0 ]; then
    log_warning "Nenhum backup encontrado"
    exit 0
fi

log_info "Encontrados ${#volumes[@]} volumes para restaurar"
echo ""

success_count=0
fail_count=0
warning_count=0

for volume in "${volumes[@]}"; do
    intelligent_restore "$volume" "$BACKUP_DIR"
    result=$?

    if [ $result -eq 0 ]; then
        ((success_count++))
    elif [ $result -eq 2 ]; then
        ((warning_count++))
    else
        ((fail_count++))
    fi
    echo ""
done

# Cleanup
log_info "Limpando arquivos de backup..."
rm -rf "$BACKUP_DIR"

# Resumo
log_section "RESUMO DO RESTORE"
echo "  ✅ Sucesso: $success_count volumes"
if [ $warning_count -gt 0 ]; then
    echo "  ⚠️  Avisos: $warning_count volumes"
fi
if [ $fail_count -gt 0 ]; then
    echo "  ❌ Falha: $fail_count volumes"
fi
echo ""
echo "  💡 Volumes com avisos podem precisar de verificação manual"
echo ""

if [ $fail_count -gt 0 ]; then
    exit 1
elif [ $warning_count -gt 0 ]; then
    exit 2
else
    exit 0
fi
