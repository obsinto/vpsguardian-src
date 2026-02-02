#!/bin/bash
################################################################################
# Script: validate-database-health.sh
# Propósito: Validação pós-restore de bancos de dados
# Uso: ./validate-database-health.sh [--container=NAME] [--all]
################################################################################

# Carregar bibliotecas compartilhadas
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

### ========== CONFIGURAÇÃO ==========
CONTAINER_NAME="${CONTAINER_NAME:-}"
CHECK_ALL=false
HEALTH_CHECK_TIMEOUT=30

### ========== PARSE ARGUMENTOS ==========
while [[ $# -gt 0 ]]; do
    case $1 in
        --container=*)
            CONTAINER_NAME="${1#*=}"
            shift
            ;;
        --all)
            CHECK_ALL=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --container=NAME   Validate specific container"
            echo "  --all              Validate all database containers"
            echo "  -h, --help         Show this help"
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

### ========== FUNÇÕES DE DETECÇÃO ==========

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

get_db_credentials() {
    local container_id="$1"
    local db_type="$2"

    case "$db_type" in
        mysql)
            local root_pass=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$container_id" | grep -E '^MYSQL_ROOT_PASSWORD=' | cut -d'=' -f2)
            echo "root:${root_pass}"
            ;;
        postgres)
            local pg_pass=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$container_id" | grep -E '^POSTGRES_PASSWORD=' | cut -d'=' -f2)
            local pg_user=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$container_id" | grep -E '^POSTGRES_USER=' | cut -d'=' -f2)
            echo "${pg_user:-postgres}:${pg_pass}"
            ;;
        mongodb)
            local mongo_pass=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$container_id" | grep -E '^MONGO_INITDB_ROOT_PASSWORD=' | cut -d'=' -f2)
            local mongo_user=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$container_id" | grep -E '^MONGO_INITDB_ROOT_USERNAME=' | cut -d'=' -f2)
            echo "${mongo_user:-root}:${mongo_pass}"
            ;;
        *)
            echo ":"
            ;;
    esac
}

### ========== FUNÇÕES DE HEALTH CHECK ==========

check_mysql_health() {
    local container_name="$1"
    local credentials="$2"

    local user=$(echo "$credentials" | cut -d':' -f1)
    local password=$(echo "$credentials" | cut -d':' -f2)

    log_info "  🔍 Testando conectividade MySQL..."

    # Teste de ping
    if ! docker exec "$container_name" mysqladmin ping -u "$user" -p"$password" >/dev/null 2>&1; then
        log_error "  ❌ MySQL não responde a ping"
        return 1
    fi

    log_success "  ✅ MySQL responde a ping"

    # Teste de query simples
    local result=$(docker exec "$container_name" mysql -u "$user" -p"$password" -e "SELECT 1;" 2>/dev/null | grep -c "1")

    if [ "$result" -ge 1 ]; then
        log_success "  ✅ Query test passou"
    else
        log_error "  ❌ Query test falhou"
        return 1
    fi

    # Verificar se há databases
    local db_count=$(docker exec "$container_name" mysql -u "$user" -p"$password" -e "SHOW DATABASES;" 2>/dev/null | grep -v -E "Database|information_schema|performance_schema|mysql|sys" | wc -l)

    log_info "  📊 Databases encontradas: $db_count"

    # Verificar integridade de tabelas (se houver databases)
    if [ "$db_count" -gt 0 ]; then
        log_info "  🔧 Verificando integridade das tabelas..."
        local check_result=$(docker exec "$container_name" mysqlcheck -u "$user" -p"$password" --all-databases --check 2>&1 | grep -c "OK")

        if [ "$check_result" -gt 0 ]; then
            log_success "  ✅ Integridade das tabelas: OK"
        else
            log_warning "  ⚠️  Alguns problemas de integridade detectados"
        fi
    fi

    return 0
}

check_postgres_health() {
    local container_name="$1"
    local credentials="$2"

    local user=$(echo "$credentials" | cut -d':' -f1)
    local password=$(echo "$credentials" | cut -d':' -f2)

    log_info "  🔍 Testando conectividade PostgreSQL..."

    # Teste de pg_isready
    if ! docker exec -e PGPASSWORD="$password" "$container_name" pg_isready -U "$user" >/dev/null 2>&1; then
        log_error "  ❌ PostgreSQL não está pronto"
        return 1
    fi

    log_success "  ✅ PostgreSQL está pronto"

    # Teste de query simples
    local result=$(docker exec -e PGPASSWORD="$password" "$container_name" psql -U "$user" -t -c "SELECT 1;" 2>/dev/null | grep -c "1")

    if [ "$result" -ge 1 ]; then
        log_success "  ✅ Query test passou"
    else
        log_error "  ❌ Query test falhou"
        return 1
    fi

    # Verificar databases
    local db_count=$(docker exec -e PGPASSWORD="$password" "$container_name" psql -U "$user" -t -c "SELECT count(*) FROM pg_database WHERE datistemplate = false;" 2>/dev/null | tr -d ' ')

    log_info "  📊 Databases encontradas: $db_count"

    # Verificar conexões ativas
    local conn_count=$(docker exec -e PGPASSWORD="$password" "$container_name" psql -U "$user" -t -c "SELECT count(*) FROM pg_stat_activity;" 2>/dev/null | tr -d ' ')

    log_info "  🔌 Conexões ativas: $conn_count"

    return 0
}

check_mongodb_health() {
    local container_name="$1"
    local credentials="$2"

    local user=$(echo "$credentials" | cut -d':' -f1)
    local password=$(echo "$credentials" | cut -d':' -f2)

    log_info "  🔍 Testando conectividade MongoDB..."

    # Teste de ping
    local ping_result=$(docker exec "$container_name" mongo --username "$user" --password "$password" --authenticationDatabase admin --quiet --eval "db.adminCommand('ping').ok" 2>/dev/null)

    if [ "$ping_result" != "1" ]; then
        log_error "  ❌ MongoDB não responde a ping"
        return 1
    fi

    log_success "  ✅ MongoDB responde a ping"

    # Listar databases
    local db_count=$(docker exec "$container_name" mongo --username "$user" --password "$password" --authenticationDatabase admin --quiet --eval "db.adminCommand('listDatabases').databases.length" 2>/dev/null)

    log_info "  📊 Databases encontradas: $db_count"

    # Verificar status do replica set (se aplicável)
    local rs_status=$(docker exec "$container_name" mongo --username "$user" --password "$password" --authenticationDatabase admin --quiet --eval "try { rs.status().ok } catch(e) { 'N/A' }" 2>/dev/null)

    if [ "$rs_status" = "1" ]; then
        log_info "  🔄 Replica Set: Ativo"
    fi

    return 0
}

check_redis_health() {
    local container_name="$1"

    log_info "  🔍 Testando conectividade Redis..."

    # Teste de ping
    local ping_result=$(docker exec "$container_name" redis-cli ping 2>/dev/null)

    if [ "$ping_result" != "PONG" ]; then
        log_error "  ❌ Redis não responde a ping"
        return 1
    fi

    log_success "  ✅ Redis responde a ping"

    # Verificar quantidade de chaves
    local key_count=$(docker exec "$container_name" redis-cli DBSIZE 2>/dev/null | awk '{print $2}')

    log_info "  🔑 Chaves armazenadas: $key_count"

    # Verificar memória usada
    local mem_used=$(docker exec "$container_name" redis-cli INFO memory 2>/dev/null | grep "used_memory_human:" | cut -d':' -f2 | tr -d '\r')

    log_info "  💾 Memória usada: $mem_used"

    return 0
}

### ========== VALIDAÇÃO DE CONTAINER ==========

validate_container() {
    local container_name="$1"

    log_section "Validando: $container_name"

    # Verificar se container existe
    if ! docker ps -a --format '{{.Names}}' | grep -q "^${container_name}$"; then
        log_error "Container não encontrado: $container_name"
        return 1
    fi

    # Verificar estado
    local state=$(docker inspect --format='{{.State.Status}}' "$container_name" 2>/dev/null)
    log_info "Estado: $state"

    if [ "$state" != "running" ]; then
        log_error "Container não está rodando"

        # Mostrar últimas linhas do log
        log_info "Últimas linhas do log:"
        docker logs --tail 20 "$container_name" 2>&1 | sed 's/^/    /'
        return 1
    fi

    # Detectar tipo de banco
    local container_id=$(docker ps -aqf "name=^${container_name}$")
    local db_type=$(detect_database_type "$container_id")

    if [ "$db_type" = "unknown" ]; then
        log_warning "Tipo de banco não reconhecido, pulando validação específica"
        log_success "Container está rodando (validação básica)"
        return 0
    fi

    log_info "Tipo: $db_type"

    # Obter credenciais
    local credentials=$(get_db_credentials "$container_id" "$db_type")

    # Health check específico por tipo
    case "$db_type" in
        mysql)
            check_mysql_health "$container_name" "$credentials"
            return $?
            ;;
        postgres)
            check_postgres_health "$container_name" "$credentials"
            return $?
            ;;
        mongodb)
            check_mongodb_health "$container_name" "$credentials"
            return $?
            ;;
        redis)
            check_redis_health "$container_name"
            return $?
            ;;
        *)
            log_warning "Tipo não suportado para validação: $db_type"
            return 0
            ;;
    esac
}

### ========== MAIN ==========
log_section "VPS Guardian - Validação de Bancos de Dados"

if [ "$CHECK_ALL" = true ]; then
    log_info "Modo: Validar TODOS os containers de banco de dados"
    echo ""

    # Detectar todos os containers de DB
    containers=($(docker ps --format '{{.ID}}:{{.Names}}' | while read line; do
        container_id=$(echo "$line" | cut -d':' -f1)
        container_name=$(echo "$line" | cut -d':' -f2)
        db_type=$(detect_database_type "$container_id")

        if [ "$db_type" != "unknown" ]; then
            echo "$container_name"
        fi
    done))

    if [ ${#containers[@]} -eq 0 ]; then
        log_warning "Nenhum container de banco de dados encontrado"
        exit 0
    fi

    log_info "Encontrados ${#containers[@]} containers de banco de dados"
    echo ""

    success_count=0
    fail_count=0

    for container in "${containers[@]}"; do
        if validate_container "$container"; then
            ((success_count++))
        else
            ((fail_count++))
        fi
        echo ""
    done

    # Resumo
    log_section "RESUMO DA VALIDAÇÃO"
    echo "  ✅ Saudáveis: $success_count"
    if [ $fail_count -gt 0 ]; then
        echo "  ❌ Com problemas: $fail_count"
    fi
    echo ""

    if [ $fail_count -gt 0 ]; then
        exit 1
    else
        log_success "Todos os bancos de dados estão saudáveis!"
        exit 0
    fi

elif [ -n "$CONTAINER_NAME" ]; then
    # Validar container específico
    validate_container "$CONTAINER_NAME"
    exit $?
else
    log_error "Especifique --container=NAME ou --all"
    exit 1
fi
