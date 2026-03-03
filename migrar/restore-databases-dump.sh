#!/bin/bash
################################################################################
# Script: restore-databases-dump.sh
# Propósito: Restaurar bancos de dados de dumps SQL
# Uso: ./restore-databases-dump.sh [--dir=PATH] [--auto]
#
# Suporta:
#   - MySQL/MariaDB (.sql ou .sql.gz)
#   - PostgreSQL (.sql ou .sql.gz)
#   - MongoDB (.tar.gz com mongodump)
################################################################################

# Carregar bibliotecas compartilhadas
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh" 2>/dev/null || {
    # Fallback se common.sh não existir
    log_info() { echo "[ INFO ] $*"; }
    log_success() { echo "[ OK ] $*"; }
    log_error() { echo "[ ERRO ] $*"; }
    log_warning() { echo "[ AVISO ] $*"; }
    log_section() { echo ""; echo "========== $* =========="; echo ""; }
}

### ========== CONFIGURAÇÃO ==========
DUMP_DIR="${DUMP_DIR:-/var/backups/vpsguardian/database-dumps}"
AUTO_MODE=false
SELECTED_DUMPS=()

### ========== PARSE ARGUMENTOS ==========
while [[ $# -gt 0 ]]; do
    case $1 in
        --dir=*)
            DUMP_DIR="${1#*=}"
            shift
            ;;
        --auto)
            AUTO_MODE=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Restaurar bancos de dados de dumps SQL"
            echo ""
            echo "Options:"
            echo "  --dir=PATH       Diretório com dumps (default: /var/backups/vpsguardian/database-dumps)"
            echo "  --auto           Modo automático (restaurar todos)"
            echo "  -h, --help       Mostrar esta ajuda"
            echo ""
            echo "Formatos suportados:"
            echo "  - MySQL/MariaDB: *-mysql-*.sql.gz ou *-mysql-*.sql"
            echo "  - PostgreSQL: *-postgres-*.sql.gz ou *-postgres-*.sql"
            echo "  - MongoDB: *-mongodb-*.tar.gz"
            echo ""
            exit 0
            ;;
        *)
            log_error "Opção desconhecida: $1"
            exit 1
            ;;
    esac
done

### ========== FUNÇÕES DE DETECÇÃO ==========

detect_dump_type() {
    local filename="$1"

    if [[ "$filename" =~ -mysql- ]]; then
        echo "mysql"
    elif [[ "$filename" =~ -postgres- ]]; then
        echo "postgres"
    elif [[ "$filename" =~ -mongodb- ]]; then
        echo "mongodb"
    else
        echo "unknown"
    fi
}

extract_container_name() {
    local filename="$1"
    # Formato: container-type-timestamp.sql.gz
    # Extrair primeira parte antes do tipo
    echo "$filename" | sed -E 's/-(mysql|postgres|mongodb)-[0-9_]+\.(sql\.gz|sql|tar\.gz)$//'
}

find_matching_container() {
    local original_name="$1"
    local db_type="$2"

    # Procurar container com nome similar
    local containers=""

    case "$db_type" in
        mysql)
            containers=$(docker ps --format '{{.Names}}' 2>/dev/null | while read name; do
                local image=$(docker inspect --format='{{.Config.Image}}' "$name" 2>/dev/null)
                if [[ "$image" =~ mysql|mariadb ]]; then
                    echo "$name"
                fi
            done)
            ;;
        postgres)
            containers=$(docker ps --format '{{.Names}}' 2>/dev/null | while read name; do
                local image=$(docker inspect --format='{{.Config.Image}}' "$name" 2>/dev/null)
                if [[ "$image" =~ postgres ]]; then
                    echo "$name"
                fi
            done)
            ;;
        mongodb)
            containers=$(docker ps --format '{{.Names}}' 2>/dev/null | while read name; do
                local image=$(docker inspect --format='{{.Config.Image}}' "$name" 2>/dev/null)
                if [[ "$image" =~ mongo ]]; then
                    echo "$name"
                fi
            done)
            ;;
    esac

    # Tentar encontrar container com nome igual
    for container in $containers; do
        if [ "$container" = "$original_name" ]; then
            echo "$container"
            return 0
        fi
    done

    # Se não encontrou exato, retornar lista de containers disponíveis
    echo "$containers"
}

get_container_credentials() {
    local container="$1"
    local db_type="$2"

    case "$db_type" in
        mysql)
            local root_pass=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$container" 2>/dev/null | grep -E '^MYSQL_ROOT_PASSWORD=' | cut -d'=' -f2)
            local db_name=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$container" 2>/dev/null | grep -E '^MYSQL_DATABASE=' | cut -d'=' -f2)
            echo "root:${root_pass}:${db_name:-}"
            ;;
        postgres)
            local pg_pass=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$container" 2>/dev/null | grep -E '^POSTGRES_PASSWORD=' | cut -d'=' -f2)
            local pg_user=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$container" 2>/dev/null | grep -E '^POSTGRES_USER=' | cut -d'=' -f2)
            local pg_db=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$container" 2>/dev/null | grep -E '^POSTGRES_DB=' | cut -d'=' -f2)
            echo "${pg_user:-postgres}:${pg_pass}:${pg_db:-postgres}"
            ;;
        mongodb)
            local mongo_pass=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$container" 2>/dev/null | grep -E '^MONGO_INITDB_ROOT_PASSWORD=' | cut -d'=' -f2)
            local mongo_user=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$container" 2>/dev/null | grep -E '^MONGO_INITDB_ROOT_USERNAME=' | cut -d'=' -f2)
            echo "${mongo_user:-root}:${mongo_pass}:admin"
            ;;
    esac
}

### ========== FUNÇÕES DE RESTORE ==========

restore_mysql() {
    local container="$1"
    local dump_file="$2"
    local credentials="$3"

    local user=$(echo "$credentials" | cut -d':' -f1)
    local password=$(echo "$credentials" | cut -d':' -f2)

    if [ -z "$password" ]; then
        log_error "Senha MySQL não encontrada"
        return 1
    fi

    log_info "  Aguardando MySQL aceitar conexões..."

    local retries=0
    while [ $retries -lt 30 ]; do
        if docker exec "$container" mysqladmin ping -u "$user" -p"$password" >/dev/null 2>&1; then
            break
        fi
        sleep 2
        ((retries++))
    done

    if [ $retries -ge 30 ]; then
        log_error "  Timeout: MySQL não respondeu"
        return 1
    fi

    log_info "  Restaurando dump..."

    # Descomprimir se necessário
    local sql_content
    if [[ "$dump_file" =~ \.gz$ ]]; then
        sql_content=$(gunzip -c "$dump_file")
    else
        sql_content=$(cat "$dump_file")
    fi

    echo "$sql_content" | docker exec -i "$container" mysql -u "$user" -p"$password" 2>/dev/null

    return $?
}

restore_postgres() {
    local container="$1"
    local dump_file="$2"
    local credentials="$3"

    local user=$(echo "$credentials" | cut -d':' -f1)
    local password=$(echo "$credentials" | cut -d':' -f2)
    local database=$(echo "$credentials" | cut -d':' -f3)

    if [ -z "$password" ]; then
        log_error "Senha PostgreSQL não encontrada"
        return 1
    fi

    log_info "  Aguardando PostgreSQL aceitar conexões..."

    local retries=0
    while [ $retries -lt 30 ]; do
        if docker exec -e PGPASSWORD="$password" "$container" pg_isready -U "$user" >/dev/null 2>&1; then
            break
        fi
        sleep 2
        ((retries++))
    done

    if [ $retries -ge 30 ]; then
        log_error "  Timeout: PostgreSQL não respondeu"
        return 1
    fi

    log_info "  Restaurando dump..."

    # Descomprimir se necessário
    if [[ "$dump_file" =~ \.gz$ ]]; then
        gunzip -c "$dump_file" | docker exec -i -e PGPASSWORD="$password" "$container" psql -U "$user" -d "$database" 2>/dev/null
    else
        cat "$dump_file" | docker exec -i -e PGPASSWORD="$password" "$container" psql -U "$user" -d "$database" 2>/dev/null
    fi

    return $?
}

restore_mongodb() {
    local container="$1"
    local dump_archive="$2"
    local credentials="$3"

    local user=$(echo "$credentials" | cut -d':' -f1)
    local password=$(echo "$credentials" | cut -d':' -f2)

    log_info "  Extraindo dump MongoDB..."

    local temp_dir="/tmp/mongorestore-$$"
    mkdir -p "$temp_dir"
    tar -xzf "$dump_archive" -C "$temp_dir" 2>/dev/null

    # Encontrar diretório do dump
    local dump_dir=$(find "$temp_dir" -type d -name "*mongodb*" | head -1)
    if [ -z "$dump_dir" ]; then
        dump_dir="$temp_dir"
    fi

    log_info "  Copiando para container..."
    docker exec "$container" rm -rf /tmp/mongorestore 2>/dev/null
    docker cp "$dump_dir/." "$container:/tmp/mongorestore/" >/dev/null 2>&1

    log_info "  Restaurando..."

    if [ -n "$password" ]; then
        docker exec "$container" mongorestore \
            --username="$user" \
            --password="$password" \
            --authenticationDatabase=admin \
            --drop \
            /tmp/mongorestore/ \
            >/dev/null 2>&1
    else
        docker exec "$container" mongorestore \
            --drop \
            /tmp/mongorestore/ \
            >/dev/null 2>&1
    fi

    local result=$?

    # Limpeza
    docker exec "$container" rm -rf /tmp/mongorestore 2>/dev/null
    rm -rf "$temp_dir"

    return $result
}

### ========== APRESENTAÇÃO ==========
echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║                                                                ║"
echo "║         RESTAURAR BANCOS DE DADOS DE DUMPS SQL                ║"
echo "║                                                                ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

### ========== VERIFICAR DIRETÓRIO ==========
if [ ! -d "$DUMP_DIR" ]; then
    log_error "Diretório não encontrado: $DUMP_DIR"
    echo ""
    echo "  Use --dir=PATH para especificar o diretório com os dumps"
    echo ""
    exit 1
fi

### ========== LISTAR DUMPS DISPONÍVEIS ==========
log_section "Dumps Disponíveis"

# Encontrar arquivos de dump
DUMP_FILES=()
while IFS= read -r -d '' file; do
    DUMP_FILES+=("$file")
done < <(find "$DUMP_DIR" -type f \( -name "*-mysql-*.sql*" -o -name "*-postgres-*.sql*" -o -name "*-mongodb-*.tar.gz" \) -print0 2>/dev/null | sort -z)

if [ ${#DUMP_FILES[@]} -eq 0 ]; then
    log_warning "Nenhum dump encontrado em $DUMP_DIR"
    echo ""
    echo "  Formatos esperados:"
    echo "    - *-mysql-*.sql.gz"
    echo "    - *-postgres-*.sql.gz"
    echo "    - *-mongodb-*.tar.gz"
    echo ""
    exit 0
fi

# Mostrar dumps disponíveis
declare -A DUMP_INFO
INDEX=0

for dump_file in "${DUMP_FILES[@]}"; do
    filename=$(basename "$dump_file")
    db_type=$(detect_dump_type "$filename")
    container_name=$(extract_container_name "$filename")
    size=$(du -h "$dump_file" | cut -f1)
    date_modified=$(stat -c %y "$dump_file" 2>/dev/null | cut -d'.' -f1)

    echo "  [$INDEX] $filename"
    echo "       Tipo: $db_type | Container: $container_name | Tamanho: $size"
    echo "       Data: $date_modified"
    echo ""

    DUMP_INFO["$INDEX,file"]="$dump_file"
    DUMP_INFO["$INDEX,type"]="$db_type"
    DUMP_INFO["$INDEX,container"]="$container_name"

    ((INDEX++))
done

log_info "Total: ${#DUMP_FILES[@]} dump(s) encontrado(s)"

### ========== SELECIONAR DUMPS ==========
if [ "$AUTO_MODE" = true ]; then
    # Modo automático: restaurar todos
    for ((i=0; i<${#DUMP_FILES[@]}; i++)); do
        SELECTED_DUMPS+=($i)
    done
else
    echo ""
    echo "Opções:"
    echo "  - Digite os números separados por espaço (ex: 0 2 3)"
    echo "  - Digite 'all' para restaurar todos"
    echo "  - Digite 'q' para cancelar"
    echo ""
    read -p "Selecione os dumps para restaurar: " selection

    if [ "$selection" = "q" ]; then
        log_info "Operação cancelada"
        exit 0
    elif [ "$selection" = "all" ]; then
        for ((i=0; i<${#DUMP_FILES[@]}; i++)); do
            SELECTED_DUMPS+=($i)
        done
    else
        for num in $selection; do
            if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -lt "${#DUMP_FILES[@]}" ]; then
                SELECTED_DUMPS+=($num)
            fi
        done
    fi
fi

if [ ${#SELECTED_DUMPS[@]} -eq 0 ]; then
    log_warning "Nenhum dump selecionado"
    exit 0
fi

### ========== RESTAURAR DUMPS ==========
log_section "Restaurando Dumps"

SUCCESS_COUNT=0
FAIL_COUNT=0

for idx in "${SELECTED_DUMPS[@]}"; do
    dump_file="${DUMP_INFO["$idx,file"]}"
    db_type="${DUMP_INFO["$idx,type"]}"
    original_container="${DUMP_INFO["$idx,container"]}"
    filename=$(basename "$dump_file")

    echo ""
    log_info "Processando: $filename"
    log_info "  Tipo: $db_type"
    log_info "  Container original: $original_container"

    # Encontrar container de destino
    available_containers=$(find_matching_container "$original_container" "$db_type")

    if [ -z "$available_containers" ]; then
        log_error "  Nenhum container $db_type encontrado!"
        log_warning "  Inicie o container primeiro e tente novamente"
        ((FAIL_COUNT++))
        continue
    fi

    # Se há múltiplos containers, deixar usuário escolher
    container_count=$(echo "$available_containers" | wc -w)

    if [ $container_count -eq 1 ]; then
        target_container="$available_containers"
    else
        echo ""
        echo "  Containers $db_type disponíveis:"
        local ci=0
        for c in $available_containers; do
            echo "    [$ci] $c"
            ((ci++))
        done

        read -p "  Selecione o container de destino (0-$((ci-1))): " container_sel

        target_container=$(echo "$available_containers" | tr ' ' '\n' | sed -n "$((container_sel+1))p")

        if [ -z "$target_container" ]; then
            log_error "  Seleção inválida"
            ((FAIL_COUNT++))
            continue
        fi
    fi

    log_info "  Container destino: $target_container"

    # Obter credenciais
    credentials=$(get_container_credentials "$target_container" "$db_type")

    # Restaurar
    case "$db_type" in
        mysql)
            if restore_mysql "$target_container" "$dump_file" "$credentials"; then
                log_success "  Dump restaurado com sucesso!"
                ((SUCCESS_COUNT++))
            else
                log_error "  Falha ao restaurar dump"
                ((FAIL_COUNT++))
            fi
            ;;
        postgres)
            if restore_postgres "$target_container" "$dump_file" "$credentials"; then
                log_success "  Dump restaurado com sucesso!"
                ((SUCCESS_COUNT++))
            else
                log_error "  Falha ao restaurar dump"
                ((FAIL_COUNT++))
            fi
            ;;
        mongodb)
            if restore_mongodb "$target_container" "$dump_file" "$credentials"; then
                log_success "  Dump restaurado com sucesso!"
                ((SUCCESS_COUNT++))
            else
                log_error "  Falha ao restaurar dump"
                ((FAIL_COUNT++))
            fi
            ;;
        *)
            log_error "  Tipo de banco desconhecido: $db_type"
            ((FAIL_COUNT++))
            ;;
    esac
done

### ========== RESUMO FINAL ==========
echo ""
log_section "RESUMO DO RESTORE"
echo ""
echo "  Dumps restaurados com sucesso: $SUCCESS_COUNT"
if [ $FAIL_COUNT -gt 0 ]; then
    echo "  Dumps com falha: $FAIL_COUNT"
fi
echo ""

if [ $FAIL_COUNT -eq 0 ]; then
    log_success "Todos os dumps foram restaurados com sucesso!"
else
    log_warning "Alguns dumps falharam - verifique os logs acima"
fi

exit 0
