#!/bin/bash
################################################################################
# Script: migrar-databases-dump.sh
# Propósito: Migração de bancos de dados via DUMP SQL (leve e seguro)
# Uso: ./migrar-databases-dump.sh [--target=IP] [--auto]
#
# Vantagens do dump SQL vs volume:
#   - Arquivos menores (texto comprimido)
#   - Portável entre versões do banco
#   - Sem problemas de redo logs corrompidos
#   - Mais fácil de verificar integridade
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
TARGET_SERVER="${TARGET_SERVER:-}"
TARGET_USER="${TARGET_USER:-root}"
TARGET_PORT="${TARGET_PORT:-22}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_rsa}"
AUTO_MODE=false
DUMP_DIR="/tmp/database-dumps-$$"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

### ========== PARSE ARGUMENTOS ==========
while [[ $# -gt 0 ]]; do
    case $1 in
        --target=*) TARGET_SERVER="${1#*=}"; shift ;;
        --user=*) TARGET_USER="${1#*=}"; shift ;;
        --port=*) TARGET_PORT="${1#*=}"; shift ;;
        --key=*) SSH_KEY="${1#*=}"; shift ;;
        --auto) AUTO_MODE=true; shift ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Migração de bancos de dados via DUMP SQL"
            echo ""
            echo "Options:"
            echo "  --target=IP      IP do servidor de destino"
            echo "  --user=USER      Usuário SSH (default: root)"
            echo "  --port=PORT      Porta SSH (default: 22)"
            echo "  --key=PATH       Chave SSH (default: ~/.ssh/id_rsa)"
            echo "  --auto           Modo automático (sem confirmações)"
            echo "  -h, --help       Mostrar esta ajuda"
            echo ""
            echo "Exemplo:"
            echo "  $0 --target=192.168.1.100"
            echo ""
            exit 0
            ;;
        *) log_error "Opção desconhecida: $1"; exit 1 ;;
    esac
done

### ========== FUNÇÕES DE DETECÇÃO (Tripla Checagem) ==========

detect_mysql_containers() {
    docker ps --format '{{.Names}}' 2>/dev/null | while read name; do
        local image=$(docker inspect --format='{{.Config.Image}}' "$name" 2>/dev/null)
        
        # Filtro Anti-Impostor: Ignorar proxies e aplicações web
        if [[ "$image" =~ nginx|traefik|wordpress|webserver|php|apache ]] || [[ "$name" =~ -proxy ]]; then
            continue
        fi

        local env_vars=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$name" 2>/dev/null)
        local exposed_ports=$(docker inspect --format='{{range $p, $conf := .Config.ExposedPorts}}{{$p}} {{end}}' "$name" 2>/dev/null)
        
        if [[ "$image" =~ mysql|mariadb ]] || echo "$env_vars" | grep -qEi 'MYSQL_ROOT_PASSWORD|MARIADB_ROOT_PASSWORD' || [[ "$exposed_ports" =~ 3306 ]]; then
            echo "$name"
        fi
    done
}

detect_postgres_containers() {
    docker ps --format '{{.Names}}' 2>/dev/null | while read name; do
        local image=$(docker inspect --format='{{.Config.Image}}' "$name" 2>/dev/null)
        
        # Filtro Anti-Impostor: Ignorar proxies e aplicações web
        if [[ "$image" =~ nginx|traefik|wordpress|webserver|php|apache ]] || [[ "$name" =~ -proxy ]]; then
            continue
        fi

        local env_vars=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$name" 2>/dev/null)
        local exposed_ports=$(docker inspect --format='{{range $p, $conf := .Config.ExposedPorts}}{{$p}} {{end}}' "$name" 2>/dev/null)
        
        if [[ "$image" =~ postgres|esus_database ]] || echo "$env_vars" | grep -qEi 'POSTGRES_PASSWORD' || [[ "$exposed_ports" =~ 5432 ]]; then
            echo "$name"
        fi
    done
}

detect_mongodb_containers() {
    docker ps --format '{{.Names}}' 2>/dev/null | while read name; do
        local image=$(docker inspect --format='{{.Config.Image}}' "$name" 2>/dev/null)
        
        # Filtro Anti-Impostor: Ignorar proxies e aplicações web
        if [[ "$image" =~ nginx|traefik|wordpress|webserver|php|apache ]] || [[ "$name" =~ -proxy ]]; then
            continue
        fi

        local env_vars=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$name" 2>/dev/null)
        local exposed_ports=$(docker inspect --format='{{range $p, $conf := .Config.ExposedPorts}}{{$p}} {{end}}' "$name" 2>/dev/null)
        
        if [[ "$image" =~ mongo ]] || echo "$env_vars" | grep -qEi 'MONGO_INITDB_ROOT_PASSWORD' || [[ "$exposed_ports" =~ 27017 ]]; then
            echo "$name"
        fi
    done
}

get_mysql_credentials() {
    local container="$1"
    local root_pass=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$container" 2>/dev/null | grep -E '^(MYSQL|MARIADB)_ROOT_PASSWORD=' | cut -d'=' -f2 | head -n1)
    local db_name=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$container" 2>/dev/null | grep -E '^(MYSQL|MARIADB)_DATABASE=' | cut -d'=' -f2 | head -n1)
    echo "root:${root_pass}:${db_name:-all}"
}

get_postgres_credentials() {
    local container="$1"
    local pg_pass=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$container" 2>/dev/null | grep -E '^POSTGRES_PASSWORD=' | cut -d'=' -f2 | head -n1)
    local pg_user=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$container" 2>/dev/null | grep -E '^POSTGRES_USER=' | cut -d'=' -f2 | head -n1)
    local pg_db=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$container" 2>/dev/null | grep -E '^POSTGRES_DB=' | cut -d'=' -f2 | head -n1)
    echo "${pg_user:-postgres}:${pg_pass}:${pg_db:-postgres}"
}

get_mongodb_credentials() {
    local container="$1"
    local mongo_pass=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$container" 2>/dev/null | grep -E '^MONGO_INITDB_ROOT_PASSWORD=' | cut -d'=' -f2 | head -n1)
    local mongo_user=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$container" 2>/dev/null | grep -E '^MONGO_INITDB_ROOT_USERNAME=' | cut -d'=' -f2 | head -n1)
    echo "${mongo_user:-root}:${mongo_pass}:admin"
}

### ========== FUNÇÕES DE DUMP ==========

dump_mysql() {
    local container="$1"
    local output_file="$2"
    local credentials="$3"

    local user=$(echo "$credentials" | cut -d':' -f1)
    local password=$(echo "$credentials" | cut -d':' -f2)
    local database=$(echo "$credentials" | cut -d':' -f3)

    if [ -z "$password" ]; then
        log_error "Senha MySQL não encontrada para $container"
        return 1
    fi

    log_info "  Executando mysqldump..."

    if [ "$database" = "all" ]; then
        docker exec "$container" mysqldump -u "$user" -p"$password" --all-databases --single-transaction --quick --lock-tables=false --routines --triggers 2>/dev/null > "$output_file"
    else
        docker exec "$container" mysqldump -u "$user" -p"$password" --single-transaction --quick --lock-tables=false --routines --triggers "$database" 2>/dev/null > "$output_file"
    fi
    return $?
}

dump_postgres() {
    local container="$1"
    local output_file="$2"
    local credentials="$3"

    local user=$(echo "$credentials" | cut -d':' -f1)
    local password=$(echo "$credentials" | cut -d':' -f2)
    local database=$(echo "$credentials" | cut -d':' -f3)

    if [ -z "$password" ]; then
        log_error "Senha PostgreSQL não encontrada para $container"
        return 1
    fi

    log_info "  Executando pg_dump..."
    docker exec -e PGPASSWORD="$password" "$container" pg_dump -U "$user" -d "$database" --clean --if-exists 2>/dev/null > "$output_file"
    return $?
}

dump_mongodb() {
    local container="$1"
    local output_dir="$2"
    local credentials="$3"

    local user=$(echo "$credentials" | cut -d':' -f1)
    local password=$(echo "$credentials" | cut -d':' -f2)

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
echo "║                                                                ║"
echo "║        MIGRAÇÃO DE BANCOS DE DADOS VIA DUMP SQL                ║"
echo "║                                                                ║"
echo "║   Método mais leve e seguro - sem problemas de redo logs       ║"
echo "║                                                                ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

if ! docker ps >/dev/null 2>&1; then
    log_error "Docker não está rodando"
    exit 1
fi

### ========== DETECTAR BANCOS DE DADOS ==========
log_section "Detectando Bancos de Dados"

MYSQL_CONTAINERS=($(detect_mysql_containers))
POSTGRES_CONTAINERS=($(detect_postgres_containers))
MONGODB_CONTAINERS=($(detect_mongodb_containers))

TOTAL_DBS=0

if [ ${#MYSQL_CONTAINERS[@]} -gt 0 ]; then
    echo "  MySQL/MariaDB:"
    for c in "${MYSQL_CONTAINERS[@]}"; do
        echo "    - $c"
        ((TOTAL_DBS++))
    done
fi

if [ ${#POSTGRES_CONTAINERS[@]} -gt 0 ]; then
    echo "  PostgreSQL:"
    for c in "${POSTGRES_CONTAINERS[@]}"; do
        echo "    - $c"
        ((TOTAL_DBS++))
    done
fi

if [ ${#MONGODB_CONTAINERS[@]} -gt 0 ]; then
    echo "  MongoDB:"
    for c in "${MONGODB_CONTAINERS[@]}"; do
        echo "    - $c"
        ((TOTAL_DBS++))
    done
fi

if [ $TOTAL_DBS -eq 0 ]; then
    log_warning "Nenhum banco de dados detectado"
    exit 0
fi

echo ""
log_info "Total: $TOTAL_DBS banco(s) de dados detectado(s)"

### ========== SOLICITAR DESTINO ==========
if [ -z "$TARGET_SERVER" ]; then
    echo ""
    log_section "Configuração do Destino"

    read -p "IP do servidor de destino (ou 'local' para apenas criar dumps): " TARGET_SERVER

    if [ "$TARGET_SERVER" != "local" ] && [ -n "$TARGET_SERVER" ]; then
        read -p "Usuário SSH (default: root): " input_user
        TARGET_USER=${input_user:-root}

        read -p "Porta SSH (default: 22): " input_port
        TARGET_PORT=${input_port:-22}
    fi
fi

### ========== CONFIRMAR ==========
if [ "$AUTO_MODE" = false ]; then
    echo ""
    log_section "Confirmar Migração"
    echo ""
    echo "  Bancos a migrar: $TOTAL_DBS"
    if [ "$TARGET_SERVER" = "local" ]; then
        echo "  Destino: Apenas criar dumps locais"
        echo "  Diretório: $DUMP_DIR"
    else
        echo "  Destino: $TARGET_USER@$TARGET_SERVER:$TARGET_PORT"
    fi
    echo ""
    read -p "Continuar? (S/n): " confirm
    confirm=${confirm:-S}

    if [[ ! "$confirm" =~ ^[Ss]$ ]]; then
        log_info "Operação cancelada"
        exit 0
    fi
fi

### ========== CRIAR DUMPS ==========
log_section "Criando Dumps SQL"

mkdir -p "$DUMP_DIR"

SUCCESS_COUNT=0
FAIL_COUNT=0
declare -A DUMP_FILES

# MySQL/MariaDB
for container in "${MYSQL_CONTAINERS[@]}"; do
    log_info "MySQL: $container"
    credentials=$(get_mysql_credentials "$container")
    output_file="$DUMP_DIR/${container}-mysql-${TIMESTAMP}.sql"

    if dump_mysql "$container" "$output_file" "$credentials"; then
        gzip "$output_file"
        output_file="${output_file}.gz"
        size=$(du -h "$output_file" | cut -f1)
        log_success "  Dump criado: $size"
        DUMP_FILES["$container"]="$output_file"
        ((SUCCESS_COUNT++))
    else
        log_error "  Falha ao criar dump"
        ((FAIL_COUNT++))
    fi
    echo ""
done

# PostgreSQL
for container in "${POSTGRES_CONTAINERS[@]}"; do
    log_info "PostgreSQL: $container"
    credentials=$(get_postgres_credentials "$container")
    output_file="$DUMP_DIR/${container}-postgres-${TIMESTAMP}.sql"

    if dump_postgres "$container" "$output_file" "$credentials"; then
        gzip "$output_file"
        output_file="${output_file}.gz"
        size=$(du -h "$output_file" | cut -f1)
        log_success "  Dump criado: $size"
        DUMP_FILES["$container"]="$output_file"
        ((SUCCESS_COUNT++))
    else
        log_error "  Falha ao criar dump"
        ((FAIL_COUNT++))
    fi
    echo ""
done

# MongoDB
for container in "${MONGODB_CONTAINERS[@]}"; do
    log_info "MongoDB: $container"
    credentials=$(get_mongodb_credentials "$container")
    output_dir="$DUMP_DIR/${container}-mongodb-${TIMESTAMP}"

    mkdir -p "$output_dir"

    if dump_mongodb "$container" "$output_dir" "$credentials"; then
        tar -czf "${output_dir}.tar.gz" -C "$DUMP_DIR" "$(basename "$output_dir")" 2>/dev/null
        rm -rf "$output_dir"
        size=$(du -h "${output_dir}.tar.gz" | cut -f1)
        log_success "  Dump criado: $size"
        DUMP_FILES["$container"]="${output_dir}.tar.gz"
        ((SUCCESS_COUNT++))
    else
        log_error "  Falha ao criar dump"
        rm -rf "$output_dir"
        ((FAIL_COUNT++))
    fi
    echo ""
done

### ========== CRIAR METADATA ==========
META_FILE="$DUMP_DIR/migration-metadata-${TIMESTAMP}.txt"
cat > "$META_FILE" << EOF
# Metadata de Migração de Bancos de Dados
# Gerado em: $(date '+%Y-%m-%d %H:%M:%S')
# Servidor origem: $(hostname)

TIMESTAMP=$TIMESTAMP
TOTAL_DATABASES=$TOTAL_DBS
SUCCESSFUL_DUMPS=$SUCCESS_COUNT
FAILED_DUMPS=$FAIL_COUNT

# Arquivos de dump:
EOF

for container in "${!DUMP_FILES[@]}"; do
    echo "DUMP_${container}=$(basename "${DUMP_FILES[$container]}")" >> "$META_FILE"
done

cat >> "$META_FILE" << 'EOF'

# Para restaurar manualmente:
#
# MySQL:
#   gunzip dump.sql.gz
#   docker exec -i CONTAINER mysql -uroot -pSENHA < dump.sql
#
# PostgreSQL:
#   gunzip dump.sql.gz
#   docker exec -i CONTAINER psql -U USER -d DATABASE < dump.sql
#
# MongoDB:
#   tar -xzf dump.tar.gz
#   docker cp dump/ CONTAINER:/tmp/
#   docker exec CONTAINER mongorestore --drop /tmp/dump/
EOF

### ========== TRANSFERIR PARA DESTINO ==========
if [ "$TARGET_SERVER" != "local" ] && [ -n "$TARGET_SERVER" ]; then
    log_section "Transferindo para $TARGET_SERVER"

    if ! ssh -o ConnectTimeout=10 -o BatchMode=yes -p "$TARGET_PORT" "$TARGET_USER@$TARGET_SERVER" "echo ok" >/dev/null 2>&1; then
        log_error "Não foi possível conectar ao servidor destino"
        log_info "Dumps ficaram salvos em: $DUMP_DIR"
        exit 1
    fi

    REMOTE_DIR="/root/database-dumps-migration"
    ssh -p "$TARGET_PORT" "$TARGET_USER@$TARGET_SERVER" "mkdir -p $REMOTE_DIR"

    log_info "Transferindo dumps..."
    rsync -avz --progress -e "ssh -p $TARGET_PORT" "$DUMP_DIR/" "$TARGET_USER@$TARGET_SERVER:$REMOTE_DIR/" 2>/dev/null

    if [ $? -eq 0 ]; then
        log_success "Transferência concluída"
        TOTAL_SIZE=$(du -sh "$DUMP_DIR" | cut -f1)
        log_info "Tamanho total transferido: $TOTAL_SIZE"
    else
        log_error "Falha na transferência"
        log_info "Dumps ficaram salvos localmente em: $DUMP_DIR"
        exit 1
    fi

    if [ "$AUTO_MODE" = false ]; then
        echo ""
        read -p "Deseja restaurar os dumps no servidor destino agora? (s/N): " restore_now
        if [[ "$restore_now" =~ ^[Ss]$ ]]; then
            log_section "Restaurando no Servidor Destino"
            scp -P "$TARGET_PORT" "$SCRIPT_DIR/restore-databases-dump.sh" "$TARGET_USER@$TARGET_SERVER:/tmp/" 2>/dev/null
            ssh -t -p "$TARGET_PORT" "$TARGET_USER@$TARGET_SERVER" "chmod +x /tmp/restore-databases-dump.sh && /tmp/restore-databases-dump.sh --dir=$REMOTE_DIR"
        else
            log_info "Dumps disponíveis em $TARGET_SERVER:$REMOTE_DIR"
            log_info "Para restaurar depois, execute no servidor destino:"
            echo "  ./restore-databases-dump.sh --dir=$REMOTE_DIR"
        fi
    fi

    rm -rf "$DUMP_DIR"
else
    log_section "Dumps Criados Localmente"
    FINAL_DIR="/var/backups/vpsguardian/database-dumps"
    mkdir -p "$FINAL_DIR"
    mv "$DUMP_DIR"/* "$FINAL_DIR/" 2>/dev/null
    rm -rf "$DUMP_DIR"
    log_info "Dumps salvos em: $FINAL_DIR"
    echo ""
    ls -lh "$FINAL_DIR"/*${TIMESTAMP}* 2>/dev/null
fi

### ========== RESUMO FINAL ==========
echo ""
log_section "RESUMO DA MIGRAÇÃO"
echo ""
echo "  Dumps criados com sucesso: $SUCCESS_COUNT"
if [ $FAIL_COUNT -gt 0 ]; then
    echo "  Dumps com falha: $FAIL_COUNT"
fi

if [ "$TARGET_SERVER" != "local" ] && [ -n "$TARGET_SERVER" ]; then
    echo ""
    echo "  Destino: $TARGET_USER@$TARGET_SERVER"
    echo "  Diretório remoto: $REMOTE_DIR"
fi

echo ""
echo "  Vantagens do dump SQL:"
echo "    - Arquivos menores que volumes"
echo "    - Sem problemas de redo logs"
echo "    - Portável entre versões"
echo ""

log_success "Migração via dump concluída!"
exit 0
