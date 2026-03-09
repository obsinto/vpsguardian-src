#!/bin/bash
################################################################################
# Script: migrar-databases-dump-seletivo.sh
# Propósito: Migração SELETIVA de bancos de dados via DUMP SQL
# Uso: ./migrar-databases-dump-seletivo.sh [--target=IP] [--mode=MODE]
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

# Carregar configurações do VPS Guardian
if [ -f "/opt/vpsguardian/config/config.env" ]; then
    source "/opt/vpsguardian/config/config.env" 2>/dev/null
fi
if [ -f "/opt/vpsguardian/config/default.conf" ]; then
    source "/opt/vpsguardian/config/default.conf" 2>/dev/null
elif [ -f "$SCRIPT_DIR/../config/default.conf" ]; then
    source "$SCRIPT_DIR/../config/default.conf" 2>/dev/null
fi

### ========== CONFIGURAÇÃO ==========
TARGET_SERVER="${TARGET_SERVER:-}"
TARGET_USER="${TARGET_USER:-root}"
TARGET_PORT="${TARGET_PORT:-22}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_rsa}"
MIGRATION_MODE="interactive"
DUMP_DIR="/tmp/database-dumps-$$"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

### ========== PARSE ARGUMENTOS ==========
while [[ $# -gt 0 ]]; do
    case $1 in
        --target=*) TARGET_SERVER="${1#*=}"; shift ;;
        --user=*) TARGET_USER="${1#*=}"; shift ;;
        --port=*) TARGET_PORT="${1#*=}"; shift ;;
        --mode=*) MIGRATION_MODE="${1#*=}"; shift ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo "Migração SELETIVA de bancos de dados via DUMP SQL"
            exit 0
            ;;
        *) log_error "Opção desconhecida: $1"; exit 1 ;;
    esac
done

### ========== FUNÇÕES DE DETECÇÃO ==========

# Detectar bancos de APLICAÇÕES gerenciados pelo Coolify
detect_app_databases() {
    docker ps --format '{{.Names}}' 2>/dev/null | while read name; do
        local is_coolify_db=$(docker inspect --format='{{index .Config.Labels "coolify.type"}}' "$name" 2>/dev/null)
        if [ "$is_coolify_db" = "database" ]; then
            echo "$name"
        fi
    done
}

# Detectar TODOS os bancos de aplicações por LABELS + IMAGEM + PORTAS
detect_all_app_databases() {
    docker ps --format '{{.Names}}' 2>/dev/null | while read name; do
        local is_database=false
        local image=$(docker inspect --format='{{.Config.Image}}' "$name" 2>/dev/null)

        # Filtro Anti-Impostor: Ignorar proxies e aplicações web
        if [[ "$image" =~ nginx|traefik|wordpress|webserver|php|apache ]] || [[ "$name" =~ -proxy ]]; then
            continue
        fi

        local coolify_type=$(docker inspect --format='{{index .Config.Labels "coolify.type"}}' "$name" 2>/dev/null)
        local exposed_ports=$(docker inspect --format='{{range $p, $conf := .Config.ExposedPorts}}{{$p}} {{end}}' "$name" 2>/dev/null)

        # Critério 1: Tem label coolify.type = database ou service
        if [ "$coolify_type" = "database" ] || [ "$coolify_type" = "service" ]; then
            if [[ "$image" =~ mysql|mariadb|postgres|redis|mongo|mongodb|esus_database ]] || [[ "$exposed_ports" =~ 3306|5432|6379|27017 ]]; then
                is_database=true
            fi
        fi

        # Critério 2: Detectar por imagem conhecida
        if [[ "$image" =~ mysql|mariadb|postgres|redis|mongo|mongodb|esus_database ]]; then
            is_database=true
        fi

        # Critério 3: Detectar por portas expostas clássicas
        if [[ "$exposed_ports" =~ 3306|5432|6379|27017 ]]; then
            is_database=true
        fi

        if [ "$is_database" = true ]; then
            echo "$name"
        fi
    done
}

detect_coolify_database() {
    if docker ps --format '{{.Names}}' | grep -q '^coolify-db$'; then
        echo "coolify-db"
    fi
}

get_container_info() {
    local container="$1"
    local image=$(docker inspect --format='{{.Config.Image}}' "$container" 2>/dev/null)
    local project=$(docker inspect --format='{{index .Config.Labels "coolify.projectName"}}' "$container" 2>/dev/null)
    echo "$image|$project"
}

### ========== FUNÇÕES DE CREDENCIAIS (Linha por linha) ==========

get_mysql_credentials() {
    local container="$1"
    local root_pass=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$container" 2>/dev/null | grep -E '^(MYSQL|MARIADB)_ROOT_PASSWORD=' | cut -d'=' -f2 | head -n1)
    local db_name=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$container" 2>/dev/null | grep -E '^(MYSQL|MARIADB)_DATABASE=' | cut -d'=' -f2 | head -n1)
    
    echo "root"
    echo "$root_pass"
    echo "${db_name:-all}"
}

get_postgres_credentials() {
    local container="$1"
    local pg_pass=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$container" 2>/dev/null | grep -E '^POSTGRES_PASSWORD=' | cut -d'=' -f2 | head -n1)
    local pg_user=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$container" 2>/dev/null | grep -E '^POSTGRES_USER=' | cut -d'=' -f2 | head -n1)
    local pg_db=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$container" 2>/dev/null | grep -E '^POSTGRES_DB=' | cut -d'=' -f2 | head -n1)
    
    echo "${pg_user:-postgres}"
    echo "$pg_pass"
    echo "${pg_db:-postgres}"
}

get_mongodb_credentials() {
    local container="$1"
    local mongo_pass=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$container" 2>/dev/null | grep -E '^MONGO_INITDB_ROOT_PASSWORD=' | cut -d'=' -f2 | head -n1)
    local mongo_user=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$container" 2>/dev/null | grep -E '^MONGO_INITDB_ROOT_USERNAME=' | cut -d'=' -f2 | head -n1)
    
    echo "${mongo_user:-root}"
    echo "$mongo_pass"
    echo "admin"
}

# Detecção INTELIGENTE de tipo de banco (Imagem + Env Vars + Portas)
detect_database_type() {
    local container="$1"
    local image=$(docker inspect --format='{{.Config.Image}}' "$container" 2>/dev/null)
    local env_vars=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$container" 2>/dev/null)
    local exposed_ports=$(docker inspect --format='{{range $p, $conf := .Config.ExposedPorts}}{{$p}} {{end}}' "$container" 2>/dev/null)

    if [[ "$image" =~ mysql|mariadb ]] || echo "$env_vars" | grep -qEi 'MYSQL_ROOT_PASSWORD|MARIADB_ROOT_PASSWORD' || [[ "$exposed_ports" =~ 3306 ]]; then
        echo "mysql"
    elif [[ "$image" =~ postgres|esus_database ]] || echo "$env_vars" | grep -qEi 'POSTGRES_PASSWORD' || [[ "$exposed_ports" =~ 5432 ]]; then
        echo "postgres"
    elif [[ "$image" =~ redis ]] || echo "$env_vars" | grep -qEi 'REDIS_PASSWORD' || [[ "$exposed_ports" =~ 6379 ]]; then
        echo "redis"
    else
        echo "unknown"
    fi
}

### ========== FUNÇÕES DE DUMP ==========

dump_mysql() {
    local container="$1"
    local output_file="$2"
    local credentials="$3"

    # Vacina contra caracteres invisíveis: o comando "tr -d '\r\n'" mata qualquer quebra de linha escondida
    local user=$(echo "$credentials" | sed -n '1p' | tr -d '\r\n')
    local password=$(echo "$credentials" | sed -n '2p' | tr -d '\r\n')
    local database=$(echo "$credentials" | sed -n '3p' | tr -d '\r\n')

    if [ -z "$password" ]; then
        log_error "Senha MySQL/MariaDB não encontrada para $container"
        return 1
    fi

    log_info "  Executando dump de dados..."

    # Detecta de forma inteligente se é MariaDB 11+ para usar o binário correto
    local dump_cmd="mysqldump"
    if docker exec "$container" which mariadb-dump >/dev/null 2>&1; then
        dump_cmd="mariadb-dump"
    fi

    # Executa o dump usando as variáveis higienizadas
    # IMPORTANTE: --add-drop-table permite restaurar sobre dados existentes
    if [ "$database" = "all" ]; then
        docker exec "$container" $dump_cmd -u "$user" -p"$password" --all-databases --single-transaction --quick --lock-tables=false --routines --triggers --add-drop-table 2>/dev/null > "$output_file"
    else
        docker exec "$container" $dump_cmd -u "$user" -p"$password" --single-transaction --quick --lock-tables=false --routines --triggers --add-drop-table "$database" 2>/dev/null > "$output_file"
    fi
    
    # Verificação de segurança: se gerou um arquivo com 0 bytes, algo deu errado
    if [ $? -ne 0 ] || [ ! -s "$output_file" ]; then
        rm -f "$output_file"
        return 1
    fi

    return 0
}

dump_postgres() {
    local container="$1"
    local output_file="$2"
    local credentials="$3"

    local user=$(echo "$credentials" | sed -n '1p' | tr -d '\r\n')
    local password=$(echo "$credentials" | sed -n '2p' | tr -d '\r\n')
    local database=$(echo "$credentials" | sed -n '3p' | tr -d '\r\n')

    if [ -z "$password" ]; then
        log_error "Senha PostgreSQL não encontrada para $container"
        return 1
    fi

    log_info "  Executando pg_dump..."
    docker exec -e PGPASSWORD="$password" "$container" pg_dump -U "$user" -d "$database" --clean --if-exists 2>/dev/null > "$output_file"
    
    if [ $? -ne 0 ] || [ ! -s "$output_file" ]; then
        rm -f "$output_file"
        return 1
    fi

    return 0
}

dump_redis() {
    local container="$1"
    local output_file="$2"

    log_info "  Executando SAVE + copiando dump.rdb..."
    docker exec "$container" redis-cli SAVE >/dev/null 2>&1 || { log_error "Falha ao executar SAVE no Redis"; return 1; }
    docker exec "$container" cat /data/dump.rdb > "$output_file" 2>/dev/null || { log_error "Falha ao copiar dump.rdb"; return 1; }
    return 0
}

dump_mongodb() {
    local container="$1"
    local output_dir="$2"
    local credentials="$3"

    local user=$(echo "$credentials" | sed -n '1p' | tr -d '\r\n')
    local password=$(echo "$credentials" | sed -n '2p' | tr -d '\r\n')

    log_info "  Executando mongodump..."

    docker exec "$container" mongodump --username="$user" --password="$password" --authenticationDatabase=admin --out=/tmp/mongodump >/dev/null 2>&1

    if [ $? -eq 0 ]; then
        docker cp "$container:/tmp/mongodump/." "$output_dir/" >/dev/null 2>&1
        docker exec "$container" rm -rf /tmp/mongodump >/dev/null 2>&1
        return 0
    fi
    return 1
}

### ========== APRESENTAÇÃO ==========
echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║                        MIGRAÇÃO SELETIVA                       ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

if ! docker ps >/dev/null 2>&1; then log_error "Docker não está rodando"; exit 1; fi

log_section "Detectando Bancos de Dados"

APP_DATABASES=($(detect_app_databases))
ALL_APP_DATABASES=($(detect_all_app_databases))
COOLIFY_DATABASE=$(detect_coolify_database)

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║  BANCOS DAS APLICAÇÕES (gerenciados pelo Coolify)              ║"
echo "╚════════════════════════════════════════════════════════════════╝"
if [ ${#APP_DATABASES[@]} -gt 0 ]; then
    for container in "${APP_DATABASES[@]}"; do
        info=$(get_container_info "$container")
        echo "  📦 $container (Img: $(echo "$info" | cut -d'|' -f1))"
    done
else echo "  ⚠️  Nenhum banco de aplicação detectado"; fi

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║  TODOS OS BANCOS (detectados por Imagem + Portas)              ║"
echo "╚════════════════════════════════════════════════════════════════╝"
if [ ${#ALL_APP_DATABASES[@]} -gt 0 ]; then
    for container in "${ALL_APP_DATABASES[@]}"; do
        info=$(get_container_info "$container")
        echo "  📦 $container (Img: $(echo "$info" | cut -d'|' -f1))"
    done
else echo "  ⚠️  Nenhum banco detectado"; fi

### ========== ESCOLHER MODO ==========
if [ "$MIGRATION_MODE" = "interactive" ]; then
    echo ""
    log_section "Escolha o que Migrar"
    echo "  1) Apenas APLICAÇÕES com label (${#APP_DATABASES[@]} banco(s))"
    echo "  2) TODOS OS BANCOS detectados (${#ALL_APP_DATABASES[@]} banco(s)) ⭐ RECOMENDADO"
    echo "  0) Cancelar"
    echo ""
    read -p "Escolha (1-2): " choice
    case $choice in
        1) MIGRATION_MODE="apps-only" ;;
        2) MIGRATION_MODE="apps-all" ;;
        0) log_info "Operação cancelada"; exit 0 ;;
        *) log_error "Opção inválida"; exit 1 ;;
    esac
fi

DATABASES_TO_MIGRATE=()
case "$MIGRATION_MODE" in
    apps-only) DATABASES_TO_MIGRATE=("${APP_DATABASES[@]}") ;;
    apps-all) DATABASES_TO_MIGRATE=("${ALL_APP_DATABASES[@]}") ;;
esac

### ========== PERGUNTAR SOBRE CONTAINERS COOLIFY ==========
if [ "$MIGRATION_MODE" != "" ]; then
    # Separar containers Coolify dos demais
    COOLIFY_CONTAINERS=()
    APP_CONTAINERS=()

    for container in "${DATABASES_TO_MIGRATE[@]}"; do
        if [[ "$container" =~ coolify ]]; then
            COOLIFY_CONTAINERS+=("$container")
        else
            APP_CONTAINERS+=("$container")
        fi
    done

    if [ ${#COOLIFY_CONTAINERS[@]} -gt 0 ]; then
        echo ""
        log_warning "⚠️  Detecção: ${#COOLIFY_CONTAINERS[@]} container(s) relacionado(s) ao Coolify encontrado(s):"
        for c in "${COOLIFY_CONTAINERS[@]}"; do
            echo "    - $c"
        done
        echo ""
        read -p "Deseja incluir estes containers no backup? (s/N): " include_coolify
        include_coolify=${include_coolify,,}  # Converter para minúsculas

        if [ "$include_coolify" = "s" ] || [ "$include_coolify" = "sim" ] || [ "$include_coolify" = "y" ] || [ "$include_coolify" = "yes" ]; then
            log_info "✓ Containers Coolify serão incluídos no backup."
        else
            # Usar apenas containers de apps
            DATABASES_TO_MIGRATE=("${APP_CONTAINERS[@]}")
            log_info "✓ Containers Coolify NÃO serão incluídos no backup."
        fi
    fi
fi

if [ ${#DATABASES_TO_MIGRATE[@]} -eq 0 ]; then log_warning "Nenhum banco para migrar"; exit 0; fi

### ========== DESTINO ==========
if [ -z "$TARGET_SERVER" ]; then
    read -p "IP de destino (ou 'local' para dumps): " TARGET_SERVER
    if [ "$TARGET_SERVER" != "local" ] && [ -n "$TARGET_SERVER" ]; then
        read -p "Usuário SSH (default: root): " input_user; TARGET_USER=${input_user:-root}
        read -p "Porta SSH (default: 22): " input_port; TARGET_PORT=${input_port:-22}
    fi
fi

### ========== CRIAR DUMPS ==========
log_section "Criando Dumps SQL"
mkdir -p "$DUMP_DIR"
SUCCESS_COUNT=0
FAIL_COUNT=0
declare -A DUMP_FILES

for container in "${DATABASES_TO_MIGRATE[@]}"; do
    log_info "Processando: $container"
    db_type=$(detect_database_type "$container")

    if [ "$db_type" = "mysql" ]; then
        credentials=$(get_mysql_credentials "$container")
        output_file="$DUMP_DIR/${container}-mysql-${TIMESTAMP}.sql"
        if dump_mysql "$container" "$output_file" "$credentials"; then
            gzip "$output_file"; output_file="${output_file}.gz"; size=$(du -h "$output_file" | cut -f1)
            log_success "  Dump criado: $size"; DUMP_FILES["$container"]="$output_file"; ((SUCCESS_COUNT++))
        else log_error "  Falha"; ((FAIL_COUNT++)); fi

    elif [ "$db_type" = "postgres" ]; then
        credentials=$(get_postgres_credentials "$container")
        output_file="$DUMP_DIR/${container}-postgres-${TIMESTAMP}.sql"
        if dump_postgres "$container" "$output_file" "$credentials"; then
            gzip "$output_file"; output_file="${output_file}.gz"; size=$(du -h "$output_file" | cut -f1)
            log_success "  Dump criado: $size"; DUMP_FILES["$container"]="$output_file"; ((SUCCESS_COUNT++))
        else log_error "  Falha"; ((FAIL_COUNT++)); fi

    elif [ "$db_type" = "redis" ]; then
        output_file="$DUMP_DIR/${container}-redis-${TIMESTAMP}.rdb"
        if dump_redis "$container" "$output_file"; then
            gzip "$output_file"; output_file="${output_file}.gz"; size=$(du -h "$output_file" | cut -f1)
            log_success "  Dump criado: $size"; DUMP_FILES["$container"]="$output_file"; ((SUCCESS_COUNT++))
        else log_error "  Falha"; ((FAIL_COUNT++)); fi

    else
        log_warning "  Tipo de banco não reconhecido pelo container $container. Pulando."
        ((FAIL_COUNT++))
    fi
    echo ""
done

### ========== FINALIZAÇÃO (Com Lotes) ==========
if [ "$TARGET_SERVER" != "local" ]; then
    REMOTE_DIR="/root/database-dumps-migration/lote-${TIMESTAMP}"
    ssh -p "$TARGET_PORT" "$TARGET_USER@$TARGET_SERVER" "mkdir -p $REMOTE_DIR"
    rsync -avz --progress -e "ssh -p $TARGET_PORT" "$DUMP_DIR/" "$TARGET_USER@$TARGET_SERVER:$REMOTE_DIR/" 2>/dev/null
    
    if [ "$MIGRATION_MODE" != "interactive" ]; then
        ssh -t -p "$TARGET_PORT" "$TARGET_USER@$TARGET_SERVER" "/tmp/restore-databases-dump.sh --dir=$REMOTE_DIR" 2>/dev/null
    fi
    rm -rf "$DUMP_DIR"
else
    # Mover para pasta local definitiva e organizada
    # Usar DATABASE_BACKUP_DIR da configuração ou padrão
    BASE_BACKUP_DIR="${DATABASE_BACKUP_DIR:-/var/backups/vpsguardian/databases}"
    FINAL_DIR="$BASE_BACKUP_DIR/lote-${TIMESTAMP}"
    mkdir -p "$FINAL_DIR"
    mv "$DUMP_DIR"/* "$FINAL_DIR/" 2>/dev/null
    rm -rf "$DUMP_DIR"
    log_info "Dumps salvos em: $FINAL_DIR"
fi

log_success "Finalizado! Sucesso: $SUCCESS_COUNT | Falhas: $FAIL_COUNT"
exit 0
