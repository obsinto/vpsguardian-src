#!/bin/bash
################################################################################
# Script: limpar-dados-bancos-apps.sh
# Propósito: Limpar dados de bancos de dados de aplicações (para testar restore)
# ATENÇÃO: Este script é DESTRUTIVO! Use apenas para testes!
################################################################################

# Carregar bibliotecas compartilhadas
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh" 2>/dev/null || {
    log_info() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] [$(basename "$0")] $*"; }
    log_success() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [SUCCESS] [$(basename "$0")] $*"; }
    log_error() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] [$(basename "$0")] $*"; }
    log_warning() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARNING] [$(basename "$0")] $*"; }
    log_section() { echo ""; echo "════════════════════════════════════════════════════════════"; echo "  $*"; echo "════════════════════════════════════════════════════════════"; echo ""; }
}

### ========== FUNÇÕES DE DETECÇÃO ==========

detect_database_type() {
    local container="$1"
    local image=$(docker inspect --format='{{.Config.Image}}' "$container" 2>/dev/null)
    local env_vars=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$container" 2>/dev/null)
    local exposed_ports=$(docker inspect --format='{{range $p, $conf := .Config.ExposedPorts}}{{$p}} {{end}}' "$container" 2>/dev/null)

    if [[ "$image" =~ mysql|mariadb ]] || echo "$env_vars" | grep -qEi 'MYSQL_ROOT_PASSWORD|MARIADB_ROOT_PASSWORD' || [[ "$exposed_ports" =~ 3306 ]]; then
        echo "mysql"
    elif [[ "$image" =~ postgres|esus_database ]] || echo "$env_vars" | grep -qEi 'POSTGRES_PASSWORD' || [[ "$exposed_ports" =~ 5432 ]]; then
        echo "postgres"
    elif [[ "$image" =~ mongo|mongodb ]] || echo "$env_vars" | grep -qEi 'MONGO_INITDB_ROOT_PASSWORD' || [[ "$exposed_ports" =~ 27017 ]]; then
        echo "mongodb"
    elif [[ "$image" =~ redis ]] || echo "$env_vars" | grep -qEi 'REDIS_PASSWORD' || [[ "$exposed_ports" =~ 6379 ]]; then
        echo "redis"
    else
        echo "unknown"
    fi
}

get_mysql_credentials() {
    local container="$1"
    local root_pass=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$container" 2>/dev/null | grep -E '^(MYSQL|MARIADB)_ROOT_PASSWORD=' | cut -d'=' -f2 | head -n1)
    local db_name=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$container" 2>/dev/null | grep -E '^(MYSQL|MARIADB)_DATABASE=' | cut -d'=' -f2 | head -n1)

    echo "root"
    echo "$root_pass"
    echo "${db_name:-mysql}"
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

### ========== FUNÇÕES DE LIMPEZA ==========

clean_mysql_database() {
    local container="$1"
    local credentials="$2"

    local user=$(echo "$credentials" | sed -n '1p' | tr -d '\r\n')
    local password=$(echo "$credentials" | sed -n '2p' | tr -d '\r\n')
    local database=$(echo "$credentials" | sed -n '3p' | tr -d '\r\n')

    if [ -z "$password" ]; then
        log_error "  Senha MySQL/MariaDB não encontrada"
        return 1
    fi

    local cmd="mysql"
    if docker exec "$container" which mariadb >/dev/null 2>&1; then cmd="mariadb"; fi

    log_info "  Banco de dados a limpar: $database"

    # Listar tabelas antes
    local table_count=$(docker exec "$container" $cmd -u "$user" -p"$password" "$database" -e "SHOW TABLES;" 2>/dev/null | wc -l)
    log_info "  Tabelas encontradas: $((table_count - 1))"

    # Dropar e recriar o banco de dados
    log_warning "  Executando DROP DATABASE..."
    docker exec "$container" $cmd -u "$user" -p"$password" -e "DROP DATABASE IF EXISTS \`$database\`;" 2>/dev/null

    if [ $? -ne 0 ]; then
        log_error "  Falha ao dropar banco de dados"
        return 1
    fi

    log_info "  Recriando banco de dados vazio..."
    docker exec "$container" $cmd -u "$user" -p"$password" -e "CREATE DATABASE \`$database\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>/dev/null

    if [ $? -eq 0 ]; then
        log_success "  Banco de dados limpo com sucesso!"
        return 0
    else
        log_error "  Falha ao recriar banco de dados"
        return 1
    fi
}

clean_postgres_database() {
    local container="$1"
    local credentials="$2"

    local user=$(echo "$credentials" | sed -n '1p' | tr -d '\r\n')
    local password=$(echo "$credentials" | sed -n '2p' | tr -d '\r\n')
    local database=$(echo "$credentials" | sed -n '3p' | tr -d '\r\n')

    if [ -z "$password" ]; then
        log_error "  Senha PostgreSQL não encontrada"
        return 1
    fi

    log_info "  Banco de dados a limpar: $database"

    # Contar tabelas antes
    local table_count=$(docker exec -e PGPASSWORD="$password" "$container" psql -U "$user" -d "$database" -t -c "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public';" 2>/dev/null | tr -d ' ')
    log_info "  Tabelas encontradas: $table_count"

    # Dropar todos os schemas e recriar
    log_warning "  Executando DROP SCHEMA CASCADE..."
    docker exec -e PGPASSWORD="$password" "$container" psql -U "$user" -d "$database" -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;" 2>/dev/null

    if [ $? -eq 0 ]; then
        log_success "  Banco de dados limpo com sucesso!"
        return 0
    else
        log_error "  Falha ao limpar banco de dados"
        return 1
    fi
}

clean_mongodb_database() {
    local container="$1"
    local credentials="$2"

    local user=$(echo "$credentials" | sed -n '1p' | tr -d '\r\n')
    local password=$(echo "$credentials" | sed -n '2p' | tr -d '\r\n')

    log_info "  Limpando todas as databases MongoDB (exceto admin, config, local)..."

    # Listar databases
    local databases=$(docker exec "$container" mongosh --username "$user" --password "$password" --authenticationDatabase admin --quiet --eval "db.adminCommand('listDatabases').databases.map(d => d.name).join(' ')" 2>/dev/null)

    log_info "  Databases encontradas: $databases"

    for db in $databases; do
        if [ "$db" != "admin" ] && [ "$db" != "config" ] && [ "$db" != "local" ]; then
            log_warning "  Dropando database: $db"
            docker exec "$container" mongosh --username "$user" --password "$password" --authenticationDatabase admin --quiet --eval "db.getSiblingDB('$db').dropDatabase()" 2>/dev/null
        fi
    done

    log_success "  Banco de dados limpo com sucesso!"
    return 0
}

clean_redis_database() {
    local container="$1"

    log_warning "  Executando FLUSHALL no Redis..."
    docker exec "$container" redis-cli FLUSHALL 2>/dev/null

    if [ $? -eq 0 ]; then
        log_success "  Redis limpo com sucesso!"
        return 0
    else
        log_error "  Falha ao limpar Redis"
        return 1
    fi
}

### ========== VERIFICAÇÃO DE SEGURANÇA - REDE LOCAL ==========

is_local_network() {
    local ip="$1"

    # Verificar se é localhost
    if [[ "$ip" =~ ^127\. ]] || [ "$ip" = "::1" ] || [ "$ip" = "localhost" ]; then
        return 0
    fi

    # Verificar se é IP privado
    # 10.0.0.0 - 10.255.255.255 (10/8 prefix)
    if [[ "$ip" =~ ^10\. ]]; then
        return 0
    fi

    # 172.16.0.0 - 172.31.255.255 (172.16/12 prefix)
    if [[ "$ip" =~ ^172\.((1[6-9])|(2[0-9])|(3[0-1]))\. ]]; then
        return 0
    fi

    # 192.168.0.0 - 192.168.255.255 (192.168/16 prefix)
    if [[ "$ip" =~ ^192\.168\. ]]; then
        return 0
    fi

    return 1
}

check_local_network() {
    log_info "Verificando se o servidor está em rede local..."

    # Pegar todos os IPs da máquina
    local ips=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -v '^$')

    if [ -z "$ips" ]; then
        log_warning "Não foi possível detectar IPs da máquina"
        return 1
    fi

    local has_local=false
    local has_public=false

    while IFS= read -r ip; do
        if is_local_network "$ip"; then
            has_local=true
            log_info "  ✓ IP local detectado: $ip"
        else
            has_public=true
            log_warning "  ⚠️  IP público detectado: $ip"
        fi
    done <<< "$ips"

    # Se tem IP público, bloquear
    if [ "$has_public" = true ]; then
        return 1
    fi

    # Se tem pelo menos um IP local e nenhum público, permitir
    if [ "$has_local" = true ]; then
        return 0
    fi

    return 1
}

### ========== PARSE ARGUMENTOS ==========
ALLOW_PRODUCTION=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --allow-production)
            ALLOW_PRODUCTION=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Limpar dados de bancos de aplicações (para testes)"
            echo ""
            echo "Options:"
            echo "  --allow-production   Permitir execução fora de rede local (USE COM CAUTELA!)"
            echo "  -h, --help          Mostrar esta ajuda"
            echo ""
            echo "ATENÇÃO: Este script é DESTRUTIVO e por padrão só funciona em rede local!"
            echo ""
            exit 0
            ;;
        *)
            log_error "Opção desconhecida: $1"
            echo "Use -h ou --help para ver as opções disponíveis"
            exit 1
            ;;
    esac
done

### ========== INÍCIO ==========

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║            LIMPAR DADOS DE BANCOS DE APLICAÇÕES                ║"
echo "║                  ⚠️  OPERAÇÃO DESTRUTIVA ⚠️                     ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

if ! docker ps >/dev/null 2>&1; then
    log_error "Docker não está rodando"
    exit 1
fi

### ========== VERIFICAR REDE LOCAL ==========
if [ "$ALLOW_PRODUCTION" = false ]; then
    echo ""
    log_section "Verificação de Segurança"

    if ! check_local_network; then
        echo ""
        log_error "╔════════════════════════════════════════════════════════════════╗"
        log_error "║  🚨 BLOQUEIO DE SEGURANÇA ATIVADO 🚨                           ║"
        log_error "╚════════════════════════════════════════════════════════════════╝"
        echo ""
        log_error "Este script só pode ser executado em servidores de REDE LOCAL!"
        log_error "Foi detectado que este servidor possui IP público."
        echo ""
        log_warning "Razões de segurança:"
        log_warning "  • Este script apaga TODOS OS DADOS dos bancos selecionados"
        log_warning "  • É destinado apenas para AMBIENTES DE TESTE"
        log_warning "  • NUNCA deve ser usado em PRODUÇÃO"
        echo ""
        log_info "Se você realmente precisa executar em produção (NÃO RECOMENDADO!):"
        log_info "  $0 --allow-production"
        echo ""
        log_error "🛑 Execução bloqueada por segurança!"
        exit 1
    fi

    log_success "✓ Servidor está em rede local - execução permitida"
    echo ""
else
    echo ""
    log_warning "╔════════════════════════════════════════════════════════════════╗"
    log_warning "║  ⚠️  MODO PRODUÇÃO ATIVADO - TRAVA DE SEGURANÇA DESABILITADA  ║"
    log_warning "╚════════════════════════════════════════════════════════════════╝"
    echo ""
    log_warning "Você está executando este script com --allow-production"
    log_warning "Tenha ABSOLUTA CERTEZA do que está fazendo!"
    echo ""
    sleep 3
fi

log_section "Detectando Bancos de Dados de Aplicações"

# Detectar TODOS os containers de banco
ALL_DBS=()
COOLIFY_DBS=()
APP_DBS=()

while IFS= read -r container; do
    db_type=$(detect_database_type "$container")
    if [ "$db_type" != "unknown" ]; then
        ALL_DBS+=("$container")

        # Separar Coolify de Apps
        if [[ "$container" =~ coolify ]]; then
            COOLIFY_DBS+=("$container")
        else
            APP_DBS+=("$container")
        fi
    fi
done < <(docker ps --format '{{.Names}}' 2>/dev/null)

if [ ${#ALL_DBS[@]} -eq 0 ]; then
    log_warning "Nenhum banco de dados encontrado"
    exit 0
fi

echo "Bancos de dados detectados:"
echo ""

if [ ${#APP_DBS[@]} -gt 0 ]; then
    echo "📊 BANCOS DE APLICAÇÕES:"
    for i in "${!APP_DBS[@]}"; do
        container="${APP_DBS[$i]}"
        db_type=$(detect_database_type "$container")
        image=$(docker inspect --format='{{.Config.Image}}' "$container" 2>/dev/null)
        echo "  [$i] $container"
        echo "      Tipo: $db_type | Imagem: $image"
    done
    echo ""
fi

if [ ${#COOLIFY_DBS[@]} -gt 0 ]; then
    echo "⚙️  BANCOS DO COOLIFY (use com CUIDADO!):"
    for container in "${COOLIFY_DBS[@]}"; do
        db_type=$(detect_database_type "$container")
        image=$(docker inspect --format='{{.Config.Image}}' "$container" 2>/dev/null)
        echo "  ⚠️  $container"
        echo "      Tipo: $db_type | Imagem: $image"
    done
    echo ""
fi

# Perguntar se quer incluir Coolify
INCLUDE_COOLIFY=false
if [ ${#COOLIFY_DBS[@]} -gt 0 ]; then
    log_warning "Containers Coolify detectados (${#COOLIFY_DBS[@]})"
    echo ""
    read -p "Deseja incluir os containers Coolify na lista para limpeza? (s/N): " include_coolify_input
    include_coolify_input=${include_coolify_input,,}

    if [ "$include_coolify_input" = "s" ] || [ "$include_coolify_input" = "sim" ] || [ "$include_coolify_input" = "y" ] || [ "$include_coolify_input" = "yes" ]; then
        INCLUDE_COOLIFY=true
        log_info "✓ Containers Coolify serão incluídos na lista"
    else
        log_info "✓ Containers Coolify NÃO serão incluídos"
    fi
    echo ""
fi

# Construir lista final
AVAILABLE_DBS=()
if [ "$INCLUDE_COOLIFY" = true ]; then
    AVAILABLE_DBS=("${APP_DBS[@]}" "${COOLIFY_DBS[@]}")
else
    AVAILABLE_DBS=("${APP_DBS[@]}")
fi

if [ ${#AVAILABLE_DBS[@]} -eq 0 ]; then
    log_warning "Nenhum banco disponível para limpeza"
    exit 0
fi

echo "Bancos disponíveis para limpeza:"
for i in "${!AVAILABLE_DBS[@]}"; do
    container="${AVAILABLE_DBS[$i]}"
    db_type=$(detect_database_type "$container")

    # Indicar se é Coolify
    if [[ "$container" =~ coolify ]]; then
        echo "  [$i] $container ⚠️  COOLIFY"
    else
        echo "  [$i] $container"
    fi
done

echo ""
log_warning "ATENÇÃO: Esta operação irá APAGAR TODOS OS DADOS dos bancos selecionados!"
log_warning "Use apenas para TESTES! Certifique-se de ter backups!"
echo ""

read -p "Digite 'CONFIRMO' para continuar: " confirmation

if [ "$confirmation" != "CONFIRMO" ]; then
    log_info "Operação cancelada"
    exit 0
fi

echo ""
echo "Escolha quais bancos limpar:"
echo "  - Digite os números separados por espaço (ex: 0 2 3)"
echo "  - Digite 'all' para limpar todos"
echo "  - Digite 'q' para cancelar"
echo ""
read -p "Seleção: " selection

if [ "$selection" = "q" ]; then
    log_info "Operação cancelada"
    exit 0
fi

SELECTED_DBS=()
if [ "$selection" = "all" ]; then
    SELECTED_DBS=("${AVAILABLE_DBS[@]}")
else
    for num in $selection; do
        if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -lt "${#AVAILABLE_DBS[@]}" ]; then
            SELECTED_DBS+=("${AVAILABLE_DBS[$num]}")
        fi
    done
fi

if [ ${#SELECTED_DBS[@]} -eq 0 ]; then
    log_warning "Nenhum banco selecionado"
    exit 0
fi

### ========== LIMPAR BANCOS ==========
log_section "Limpando Bancos de Dados"

SUCCESS=0
FAILED=0

for container in "${SELECTED_DBS[@]}"; do
    echo ""
    log_info "Processando: $container"

    db_type=$(detect_database_type "$container")
    log_info "  Tipo detectado: $db_type"

    case "$db_type" in
        mysql)
            credentials=$(get_mysql_credentials "$container")
            if clean_mysql_database "$container" "$credentials"; then
                ((SUCCESS++))
            else
                ((FAILED++))
            fi
            ;;
        postgres)
            credentials=$(get_postgres_credentials "$container")
            if clean_postgres_database "$container" "$credentials"; then
                ((SUCCESS++))
            else
                ((FAILED++))
            fi
            ;;
        mongodb)
            credentials=$(get_mongodb_credentials "$container")
            if clean_mongodb_database "$container" "$credentials"; then
                ((SUCCESS++))
            else
                ((FAILED++))
            fi
            ;;
        redis)
            if clean_redis_database "$container"; then
                ((SUCCESS++))
            else
                ((FAILED++))
            fi
            ;;
        *)
            log_error "  Tipo de banco não suportado"
            ((FAILED++))
            ;;
    esac
done

### ========== RESUMO ==========
echo ""
log_section "RESUMO"
echo "  ✅ Limpos com sucesso: $SUCCESS"
if [ $FAILED -gt 0 ]; then
    echo "  ❌ Falhas: $FAILED"
fi
echo ""

if [ $FAILED -eq 0 ]; then
    log_success "Todos os bancos foram limpos com sucesso!"
    echo ""
    log_info "Agora você pode testar a restauração executando:"
    echo "  sudo ./restore-databases-dump.sh --dir=/caminho/dos/dumps"
else
    log_warning "Alguns bancos não puderam ser limpos. Revise os erros acima."
fi

exit 0
