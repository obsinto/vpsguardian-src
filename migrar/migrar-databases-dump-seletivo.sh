#!/bin/bash
################################################################################
# Script: migrar-databases-dump-seletivo.sh
# Propósito: Migração SELETIVA de bancos de dados via DUMP SQL
# Uso: ./migrar-databases-dump-seletivo.sh [--target=IP] [--mode=MODE]
#
# Modos disponíveis:
#   apps-only     - Migrar apenas bancos com label coolify.type:database
#   apps-all      - Migrar TODOS os bancos detectados por imagem (exceto Coolify)
#   coolify-only  - Migrar apenas banco do Coolify
#   all           - Migrar tudo (aplicações + Coolify)
#   interactive   - Perguntar o que migrar (padrão)
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
MIGRATION_MODE="interactive"
DUMP_DIR="/tmp/database-dumps-$$"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

### ========== PARSE ARGUMENTOS ==========
while [[ $# -gt 0 ]]; do
    case $1 in
        --target=*)
            TARGET_SERVER="${1#*=}"
            shift
            ;;
        --user=*)
            TARGET_USER="${1#*=}"
            shift
            ;;
        --port=*)
            TARGET_PORT="${1#*=}"
            shift
            ;;
        --mode=*)
            MIGRATION_MODE="${1#*=}"
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Migração SELETIVA de bancos de dados via DUMP SQL"
            echo ""
            echo "Options:"
            echo "  --target=IP      IP do servidor de destino (ou 'local')"
            echo "  --user=USER      Usuário SSH (default: root)"
            echo "  --port=PORT      Porta SSH (default: 22)"
            echo "  --mode=MODE      Modo de migração:"
            echo "                     apps-only     - Só aplicações (label coolify.type:database)"
            echo "                     apps-all      - TODOS bancos por imagem (exceto Coolify)"
            echo "                     coolify-only  - Só Coolify"
            echo "                     all           - Tudo"
            echo "                     interactive   - Perguntar (padrão)"
            echo "  -h, --help       Mostrar esta ajuda"
            echo ""
            echo "Exemplos:"
            echo "  $0 --target=192.168.1.100 --mode=apps-only"
            echo "  $0 --target=local --mode=all"
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

# Detectar bancos de APLICAÇÕES gerenciados pelo Coolify
detect_app_databases() {
    docker ps --format '{{.Names}}' 2>/dev/null | while read name; do
        # Verificar se tem label coolify.type:database
        local is_coolify_db=$(docker inspect --format='{{index .Config.Labels "coolify.type"}}' "$name" 2>/dev/null)

        if [ "$is_coolify_db" = "database" ]; then
            echo "$name"
        fi
    done
}

# Detectar TODOS os bancos de aplicações por imagem (exceto Coolify)
detect_all_app_databases() {
    docker ps --format '{{.Names}}' 2>/dev/null | while read name; do
        # Ignorar bancos do próprio Coolify
        if [ "$name" = "coolify-db" ] || [ "$name" = "coolify-redis" ]; then
            continue
        fi

        # Detectar por imagem
        local image=$(docker inspect --format='{{.Config.Image}}' "$name" 2>/dev/null)
        if [[ "$image" =~ mysql|mariadb|postgres|redis|mongo|mongodb ]]; then
            echo "$name"
        fi
    done
}

# Detectar banco do COOLIFY (PostgreSQL interno)
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

get_mysql_credentials() {
    local container="$1"
    local root_pass=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$container" 2>/dev/null | grep -E '^MYSQL_ROOT_PASSWORD=' | cut -d'=' -f2)
    local db_name=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$container" 2>/dev/null | grep -E '^MYSQL_DATABASE=' | cut -d'=' -f2)
    echo "root:${root_pass}:${db_name:-all}"
}

get_postgres_credentials() {
    local container="$1"
    local pg_pass=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$container" 2>/dev/null | grep -E '^POSTGRES_PASSWORD=' | cut -d'=' -f2)
    local pg_user=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$container" 2>/dev/null | grep -E '^POSTGRES_USER=' | cut -d'=' -f2)
    local pg_db=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$container" 2>/dev/null | grep -E '^POSTGRES_DB=' | cut -d'=' -f2)
    echo "${pg_user:-postgres}:${pg_pass}:${pg_db:-postgres}"
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
        docker exec "$container" mysqldump \
            -u "$user" \
            -p"$password" \
            --all-databases \
            --single-transaction \
            --quick \
            --lock-tables=false \
            --routines \
            --triggers \
            2>/dev/null > "$output_file"
    else
        docker exec "$container" mysqldump \
            -u "$user" \
            -p"$password" \
            --single-transaction \
            --quick \
            --lock-tables=false \
            --routines \
            --triggers \
            "$database" \
            2>/dev/null > "$output_file"
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

    docker exec -e PGPASSWORD="$password" "$container" pg_dump \
        -U "$user" \
        -d "$database" \
        --clean \
        --if-exists \
        2>/dev/null > "$output_file"

    return $?
}

dump_redis() {
    local container="$1"
    local output_file="$2"

    log_info "  Executando SAVE + copiando dump.rdb..."

    # Forçar save do Redis
    docker exec "$container" redis-cli SAVE >/dev/null 2>&1 || {
        log_error "Falha ao executar SAVE no Redis"
        return 1
    }

    # Copiar o arquivo dump.rdb
    docker exec "$container" cat /data/dump.rdb > "$output_file" 2>/dev/null || {
        log_error "Falha ao copiar dump.rdb"
        return 1
    }

    return 0
}

### ========== APRESENTAÇÃO ==========
echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║                                                                ║"
echo "║       MIGRAÇÃO SELETIVA VIA DUMP SQL                          ║"
echo "║                                                                ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

### ========== VERIFICAR DOCKER ==========
if ! docker ps >/dev/null 2>&1; then
    log_error "Docker não está rodando"
    exit 1
fi

### ========== DETECTAR BANCOS ==========
log_section "Detectando Bancos de Dados"

APP_DATABASES=($(detect_app_databases))
ALL_APP_DATABASES=($(detect_all_app_databases))
COOLIFY_DATABASE=$(detect_coolify_database)

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║  BANCOS DAS APLICAÇÕES (gerenciados pelo Coolify)             ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

if [ ${#APP_DATABASES[@]} -gt 0 ]; then
    for container in "${APP_DATABASES[@]}"; do
        info=$(get_container_info "$container")
        image=$(echo "$info" | cut -d'|' -f1)
        project=$(echo "$info" | cut -d'|' -f2)

        echo "  📦 $container"
        echo "     Projeto: $project"
        echo "     Imagem: $image"
        echo ""
    done
    echo "  Total: ${#APP_DATABASES[@]} banco(s) de aplicações"
else
    echo "  ⚠️  Nenhum banco de aplicação detectado"
fi

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║  TODOS OS BANCOS (detectados por imagem)                      ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

if [ ${#ALL_APP_DATABASES[@]} -gt 0 ]; then
    for container in "${ALL_APP_DATABASES[@]}"; do
        info=$(get_container_info "$container")
        image=$(echo "$info" | cut -d'|' -f1)
        project=$(echo "$info" | cut -d'|' -f2)

        echo "  📦 $container"
        echo "     Projeto: ${project:-não identificado}"
        echo "     Imagem: $image"
        echo ""
    done
    echo "  Total: ${#ALL_APP_DATABASES[@]} banco(s) detectado(s)"
else
    echo "  ⚠️  Nenhum banco detectado"
fi

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║  BANCO DO COOLIFY (sistema)                                   ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

if [ -n "$COOLIFY_DATABASE" ]; then
    echo "  🔧 coolify-db (PostgreSQL - configurações do Coolify)"
    echo ""
else
    echo "  ⚠️  Banco do Coolify não encontrado"
fi

### ========== ESCOLHER MODO DE MIGRAÇÃO ==========
if [ "$MIGRATION_MODE" = "interactive" ]; then
    echo ""
    log_section "Escolha o que Migrar"
    echo ""
    echo "  1) Apenas APLICAÇÕES com label (${#APP_DATABASES[@]} banco(s))"
    echo "     → Migra apenas bancos com label coolify.type:database"
    echo "     → Coolify não será afetado"
    echo ""
    echo "  2) TODOS OS BANCOS detectados (${#ALL_APP_DATABASES[@]} banco(s)) ⭐ RECOMENDADO"
    echo "     → Detecta por imagem (MySQL, MariaDB, PostgreSQL, Redis)"
    echo "     → Exclui apenas coolify-db e coolify-redis"
    echo "     → Pega TUDO, inclusive bancos sem label"
    echo ""
    echo "  3) Apenas COOLIFY (1 banco)"
    echo "     → Migra apenas o banco do Coolify"
    echo "     → Configurações, projetos, usuários"
    echo ""
    echo "  4) TUDO (aplicações + Coolify)"
    echo "     → Migração completa"
    echo ""
    echo "  0) Cancelar"
    echo ""
    read -p "Escolha (1-4): " choice

    case $choice in
        1) MIGRATION_MODE="apps-only" ;;
        2) MIGRATION_MODE="apps-all" ;;
        3) MIGRATION_MODE="coolify-only" ;;
        4) MIGRATION_MODE="all" ;;
        0)
            log_info "Operação cancelada"
            exit 0
            ;;
        *)
            log_error "Opção inválida"
            exit 1
            ;;
    esac
fi

# Definir quais bancos migrar baseado no modo
DATABASES_TO_MIGRATE=()

case "$MIGRATION_MODE" in
    apps-only)
        DATABASES_TO_MIGRATE=("${APP_DATABASES[@]}")
        ;;
    apps-all)
        DATABASES_TO_MIGRATE=("${ALL_APP_DATABASES[@]}")
        ;;
    coolify-only)
        if [ -n "$COOLIFY_DATABASE" ]; then
            DATABASES_TO_MIGRATE=("$COOLIFY_DATABASE")
        fi
        ;;
    all)
        DATABASES_TO_MIGRATE=("${ALL_APP_DATABASES[@]}")
        if [ -n "$COOLIFY_DATABASE" ]; then
            DATABASES_TO_MIGRATE+=("$COOLIFY_DATABASE")
        fi
        ;;
    *)
        log_error "Modo inválido: $MIGRATION_MODE"
        exit 1
        ;;
esac

if [ ${#DATABASES_TO_MIGRATE[@]} -eq 0 ]; then
    log_warning "Nenhum banco para migrar no modo: $MIGRATION_MODE"
    exit 0
fi

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
echo ""
log_section "Confirmar Migração"
echo ""
echo "  Modo: $MIGRATION_MODE"
echo "  Bancos a migrar: ${#DATABASES_TO_MIGRATE[@]}"
for db in "${DATABASES_TO_MIGRATE[@]}"; do
    echo "    - $db"
done
if [ "$TARGET_SERVER" = "local" ]; then
    echo "  Destino: Apenas criar dumps locais"
    echo "  Diretório: /var/backups/vpsguardian/database-dumps"
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

### ========== CRIAR DUMPS ==========
log_section "Criando Dumps SQL"

mkdir -p "$DUMP_DIR"

SUCCESS_COUNT=0
FAIL_COUNT=0
declare -A DUMP_FILES

for container in "${DATABASES_TO_MIGRATE[@]}"; do
    image=$(docker inspect --format='{{.Config.Image}}' "$container" 2>/dev/null)

    log_info "Processando: $container"

    if [[ "$image" =~ mysql|mariadb ]]; then
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

    elif [[ "$image" =~ postgres ]]; then
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

    elif [[ "$image" =~ redis ]]; then
        output_file="$DUMP_DIR/${container}-redis-${TIMESTAMP}.rdb"

        if dump_redis "$container" "$output_file"; then
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
    else
        log_warning "  Tipo de banco não suportado: $image"
        ((FAIL_COUNT++))
    fi

    echo ""
done

### ========== CRIAR METADATA ==========
META_FILE="$DUMP_DIR/migration-metadata-${MIGRATION_MODE}-${TIMESTAMP}.txt"
cat > "$META_FILE" << EOF
# Metadata de Migração de Bancos de Dados
# Gerado em: $(date '+%Y-%m-%d %H:%M:%S')
# Servidor origem: $(hostname)
# Modo: $MIGRATION_MODE

TIMESTAMP=$TIMESTAMP
MIGRATION_MODE=$MIGRATION_MODE
TOTAL_DATABASES=${#DATABASES_TO_MIGRATE[@]}
SUCCESSFUL_DUMPS=$SUCCESS_COUNT
FAILED_DUMPS=$FAIL_COUNT

# Arquivos de dump:
EOF

for container in "${!DUMP_FILES[@]}"; do
    echo "DUMP_${container}=$(basename "${DUMP_FILES[$container]}")" >> "$META_FILE"
done

### ========== TRANSFERIR OU SALVAR LOCAL ==========
if [ "$TARGET_SERVER" != "local" ] && [ -n "$TARGET_SERVER" ]; then
    log_section "Transferindo para $TARGET_SERVER"

    # Verificar conectividade SSH
    if ! ssh -o ConnectTimeout=10 -o BatchMode=yes -p "$TARGET_PORT" "$TARGET_USER@$TARGET_SERVER" "echo ok" >/dev/null 2>&1; then
        log_error "Não foi possível conectar ao servidor destino"
        log_info "Dumps ficaram salvos em: $DUMP_DIR"
        exit 1
    fi

    # Criar diretório no destino
    REMOTE_DIR="/root/database-dumps-migration-${MIGRATION_MODE}"
    ssh -p "$TARGET_PORT" "$TARGET_USER@$TARGET_SERVER" "mkdir -p $REMOTE_DIR"

    # Transferir arquivos
    log_info "Transferindo dumps..."
    rsync -avz --progress -e "ssh -p $TARGET_PORT" "$DUMP_DIR/" "$TARGET_USER@$TARGET_SERVER:$REMOTE_DIR/" 2>/dev/null

    if [ $? -eq 0 ]; then
        log_success "Transferência concluída"
        TOTAL_SIZE=$(du -sh "$DUMP_DIR" | cut -f1)
        log_info "Tamanho total transferido: $TOTAL_SIZE"
        log_info "Diretório remoto: $REMOTE_DIR"
    else
        log_error "Falha na transferência"
        exit 1
    fi

    rm -rf "$DUMP_DIR"
else
    # Modo local
    FINAL_DIR="/var/backups/vpsguardian/database-dumps"
    mkdir -p "$FINAL_DIR"
    mv "$DUMP_DIR"/* "$FINAL_DIR/" 2>/dev/null
    rm -rf "$DUMP_DIR"

    log_section "Dumps Criados Localmente"
    log_info "Dumps salvos em: $FINAL_DIR"
    echo ""
    ls -lh "$FINAL_DIR"/*${TIMESTAMP}* 2>/dev/null
fi

### ========== RESUMO FINAL ==========
echo ""
log_section "RESUMO DA MIGRAÇÃO"
echo ""
echo "  Modo: $MIGRATION_MODE"
echo "  Dumps criados com sucesso: $SUCCESS_COUNT"
if [ $FAIL_COUNT -gt 0 ]; then
    echo "  Dumps com falha: $FAIL_COUNT"
fi
echo ""

log_success "Migração via dump concluída!"
exit 0
