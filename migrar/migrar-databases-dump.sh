#!/bin/bash
################################################################################

umask 077
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

# Carregar configurações do VPS Guardian
if [ -f "$VPSGUARDIAN_ROOT/config/config.env" ]; then
    source "$VPSGUARDIAN_ROOT/config/config.env" 2>/dev/null
fi
if [ -f "$VPSGUARDIAN_ROOT/config/default.conf" ]; then
    source "$VPSGUARDIAN_ROOT/config/default.conf" 2>/dev/null
fi

# Carregar configurações de destino de backup (inclui Coolify API)
SHARED_CONFIG_FILE="${VPSGUARDIAN_SHARED_CONFIG_FILE:-$VPSGUARDIAN_ROOT/config/backup-destinations.conf}"
if [ -f "$SHARED_CONFIG_FILE" ]; then
    source "$SHARED_CONFIG_FILE" 2>/dev/null
fi

# Carregar biblioteca de API do Coolify
source "$SCRIPT_DIR/../lib/coolify-api.sh" 2>/dev/null || true

### ========== CONFIGURAÇÃO ==========
TARGET_SERVER="${TARGET_SERVER:-}"
TARGET_USER="${TARGET_USER:-root}"
TARGET_PORT="${TARGET_PORT:-22}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_rsa}"
AUTO_MODE=false
INCLUDE_COOLIFY=""  # vazio = perguntar, true = incluir, false = excluir
PROJECT_FILTER=""   # vazio = todos, ou UUID/nome do projeto
DUMP_DIR=""
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

### ========== PARSE ARGUMENTOS ==========
while [[ $# -gt 0 ]]; do
    case $1 in
        --target=*) TARGET_SERVER="${1#*=}"; shift ;;
        --user=*) TARGET_USER="${1#*=}"; shift ;;
        --port=*) TARGET_PORT="${1#*=}"; shift ;;
        --key=*) SSH_KEY="${1#*=}"; shift ;;
        --auto) AUTO_MODE=true; shift ;;
        --include-coolify) INCLUDE_COOLIFY=true; shift ;;
        --exclude-coolify) INCLUDE_COOLIFY=false; shift ;;
        --project=*) PROJECT_FILTER="${1#*=}"; shift ;;
        --list-projects) LIST_PROJECTS_ONLY=true; shift ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Migração de bancos de dados via DUMP SQL"
            echo ""
            echo "Options:"
            echo "  --target=IP         IP do servidor de destino"
            echo "  --user=USER         Usuário SSH (default: root)"
            echo "  --port=PORT         Porta SSH (default: 22)"
            echo "  --key=PATH          Chave SSH (default: ~/.ssh/id_rsa)"
            echo "  --auto              Modo automático (sem confirmações)"
            echo "  --include-coolify   Incluir banco do Coolify (coolify-db)"
            echo "  --exclude-coolify   Excluir banco do Coolify (coolify-db)"
            echo "  --project=ID        Filtrar por projeto (UUID ou nome)"
            echo "  --list-projects     Listar projetos disponíveis e sair"
            echo "  -h, --help          Mostrar esta ajuda"
            echo ""
            echo "Exemplo:"
            echo "  $0 --target=192.168.1.100"
            echo "  $0 --auto --include-coolify --target=local"
            echo "  $0 --project=meu-projeto --target=local"
            echo "  $0 --list-projects"
            echo ""
            exit 0
            ;;
        *) log_error "Opção desconhecida: $1"; exit 1 ;;
    esac
done

### ========== FUNÇÕES DE DETECÇÃO VIA COOLIFY API ==========

# Flag para indicar se estamos usando API
USING_COOLIFY_API=false

# Arrays para armazenar dados da API
declare -A API_DB_CREDENTIALS
declare -A API_DB_TYPES

# Detectar databases via API do Coolify
detect_databases_via_api() {
    if ! coolify_api_available 2>/dev/null; then
        return 1
    fi

    log_info "Usando API do Coolify para descoberta de databases..."

    local databases

    # Se filtro de projeto foi especificado, usar função específica
    if [ -n "$PROJECT_FILTER" ]; then
        log_info "Filtrando por projeto: $PROJECT_FILTER"
        databases=$(coolify_list_project_databases "$PROJECT_FILTER" 2>/dev/null)

        if [ -z "$databases" ]; then
            log_warning "Nenhum database encontrado no projeto '$PROJECT_FILTER'"
            log_info "Use --list-projects para ver projetos disponíveis"
            return 1
        fi
    else
        databases=$(coolify_discover_databases 2>/dev/null)
    fi

    if [ -z "$databases" ]; then
        log_warning "API disponível mas nenhum database encontrado"
        return 1
    fi

    USING_COOLIFY_API=true

    # Processar databases da API
    while IFS='|' read -r uuid name type status container url; do
        if [ -z "$uuid" ]; then continue; fi

        # Normalizar tipo
        local normalized_type=""
        case "$type" in
            postgresql|postgres) normalized_type="postgres" ;;
            mysql|mariadb) normalized_type="mysql" ;;
            mongodb|mongo) normalized_type="mongodb" ;;
            redis) normalized_type="redis" ;;
            *) normalized_type="$type" ;;
        esac

        # Armazenar informações
        API_DB_TYPES["$container"]="$normalized_type"

        # Extrair credenciais da URL se disponível
        if [ -n "$url" ] && [ "$url" != "null" ]; then
            API_DB_CREDENTIALS["$container"]="$url"
        fi

        # Adicionar ao array apropriado
        case "$normalized_type" in
            mysql|mariadb)
                echo "$container" >> "$API_MYSQL_FILE"
                ;;
            postgres)
                echo "$container" >> "$API_POSTGRES_FILE"
                ;;
            mongodb)
                echo "$container" >> "$API_MONGODB_FILE"
                ;;
        esac

        log_success "  API: $name ($normalized_type) → container: $container"
    done <<< "$databases"

    return 0
}

# Obter credenciais via API (fallback para método Docker)
get_credentials_from_api() {
    local container="$1"
    local url="${API_DB_CREDENTIALS[$container]}"

    if [ -n "$url" ] && [ "$url" != "null" ]; then
        # Parse URL: protocol://user:pass@host:port/db
        local user pass db

        # Extrair user:pass
        local userpass=$(echo "$url" | sed -n 's|.*://\([^@]*\)@.*|\1|p')
        user=$(echo "$userpass" | cut -d: -f1)
        pass=$(echo "$userpass" | cut -d: -f2-)

        # Extrair database
        db=$(echo "$url" | sed -n 's|.*/\([^?]*\).*|\1|p')

        if [ -n "$user" ] && [ -n "$pass" ]; then
            echo "$user"
            echo "$pass"
            echo "${db:-all}"
            return 0
        fi
    fi

    return 1
}

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

### ========== FUNÇÕES DE CREDENCIAIS (Linha por Linha) ==========

get_mysql_credentials() {
    local container="$1"

    # Tentar via API primeiro
    if [ "$USING_COOLIFY_API" = true ]; then
        local api_creds
        api_creds=$(get_credentials_from_api "$container")
        if [ -n "$api_creds" ]; then
            echo "$api_creds"
            return 0
        fi
    fi

    # Fallback: Docker inspect
    local root_pass=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$container" 2>/dev/null | grep -E '^(MYSQL|MARIADB)_ROOT_PASSWORD=' | cut -d'=' -f2 | head -n1)
    local db_name=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$container" 2>/dev/null | grep -E '^(MYSQL|MARIADB)_DATABASE=' | cut -d'=' -f2 | head -n1)

    echo "root"
    echo "$root_pass"
    echo "${db_name:-all}"
}

get_postgres_credentials() {
    local container="$1"

    # Tentar via API primeiro
    if [ "$USING_COOLIFY_API" = true ]; then
        local api_creds
        api_creds=$(get_credentials_from_api "$container")
        if [ -n "$api_creds" ]; then
            echo "$api_creds"
            return 0
        fi
    fi

    # Fallback: Docker inspect
    local pg_pass=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$container" 2>/dev/null | grep -E '^POSTGRES_PASSWORD=' | cut -d'=' -f2 | head -n1)
    local pg_user=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$container" 2>/dev/null | grep -E '^POSTGRES_USER=' | cut -d'=' -f2 | head -n1)
    local pg_db=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$container" 2>/dev/null | grep -E '^POSTGRES_DB=' | cut -d'=' -f2 | head -n1)

    echo "${pg_user:-postgres}"
    echo "$pg_pass"
    echo "${pg_db:-postgres}"
}

get_mongodb_credentials() {
    local container="$1"

    # Tentar via API primeiro
    if [ "$USING_COOLIFY_API" = true ]; then
        local api_creds
        api_creds=$(get_credentials_from_api "$container")
        if [ -n "$api_creds" ]; then
            echo "$api_creds"
            return 0
        fi
    fi

    # Fallback: Docker inspect
    local mongo_pass=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$container" 2>/dev/null | grep -E '^MONGO_INITDB_ROOT_PASSWORD=' | cut -d'=' -f2 | head -n1)
    local mongo_user=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$container" 2>/dev/null | grep -E '^MONGO_INITDB_ROOT_USERNAME=' | cut -d'=' -f2 | head -n1)

    echo "${mongo_user:-root}"
    echo "$mongo_pass"
    echo "admin"
}

### ========== FUNÇÕES DE DUMP (Higienizadas) ==========

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
        docker exec -e MYSQL_PWD="$password" "$container" $dump_cmd -u "$user" --all-databases --single-transaction --quick --lock-tables=false --routines --triggers --add-drop-table 2>/dev/null > "$output_file"
    else
        docker exec -e MYSQL_PWD="$password" "$container" $dump_cmd -u "$user" --single-transaction --quick --lock-tables=false --routines --triggers --add-drop-table "$database" 2>/dev/null > "$output_file"
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

### ========== LISTAR PROJETOS (se solicitado) ==========
if [ "${LIST_PROJECTS_ONLY:-false}" = true ]; then
    log_section "Projetos Disponíveis (via Coolify API)"

    if ! coolify_api_available 2>/dev/null; then
        log_error "API do Coolify não está disponível"
        log_info "Configure a API com: scripts-auxiliares/configurar-coolify-api.sh"
        exit 1
    fi

    projects=""
    projects=$(coolify_list_project_names 2>/dev/null)

    if [ -z "$projects" ]; then
        log_warning "Nenhum projeto encontrado"
        exit 0
    fi

    echo ""
    printf "  %-36s  %-30s  %s\n" "UUID" "NOME" "DESCRIÇÃO"
    printf "  %-36s  %-30s  %s\n" "------------------------------------" "------------------------------" "----------"

    echo "$projects" | while IFS='|' read -r uuid name desc; do
        printf "  %-36s  %-30s  %s\n" "$uuid" "$name" "${desc:0:40}"
    done

    echo ""
    log_info "Use: $0 --project=NOME_OU_UUID para filtrar por projeto"
    exit 0
fi

### ========== SELEÇÃO DE PROJETO (Interativo) ==========
# Se API disponível, modo interativo e sem filtro de projeto, oferecer seleção
if [ "$AUTO_MODE" = false ] && [ -z "$PROJECT_FILTER" ] && coolify_api_available 2>/dev/null; then
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC:-}"

    # Listar projetos disponíveis
    projects_list=""
    projects_list=$(coolify_list_project_names 2>/dev/null)

    if [ -n "$projects_list" ]; then
        echo ""
        echo "  Projetos disponíveis (via Coolify API):"
        echo ""

        idx=1
        declare -a PROJECT_OPTIONS
        while IFS='|' read -r uuid name desc; do
            printf "    ${GREEN:-}%2d${NC:-} → %s" "$idx" "$name"
            if [ -n "$desc" ]; then
                printf " ${GRAY:-}(%s)${NC:-}" "${desc:0:30}"
            fi
            echo ""
            PROJECT_OPTIONS[$idx]="$uuid|$name"
            ((idx++))
        done <<< "$projects_list"

        echo ""
        printf "    ${GREEN:-}%2d${NC:-} → Todos os bancos (sem filtro)\n" "0"
        echo ""
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC:-}"

        read -p "Escolha um projeto (0-$((idx-1))): " project_choice

        if [ -n "$project_choice" ] && [ "$project_choice" != "0" ] && [ -n "${PROJECT_OPTIONS[$project_choice]}" ]; then
            PROJECT_FILTER=$(echo "${PROJECT_OPTIONS[$project_choice]}" | cut -d'|' -f1)
            project_name=$(echo "${PROJECT_OPTIONS[$project_choice]}" | cut -d'|' -f2)
            log_info "Projeto selecionado: $project_name"
        else
            log_info "Backup de todos os bancos (sem filtro de projeto)"
        fi
        echo ""
    fi
fi

### ========== DETECTAR BANCOS DE DADOS ==========
log_section "Detectando Bancos de Dados"

# Arquivos temporários seguros para o inventário retornado pela API.
API_DISCOVERY_DIR=$(mktemp -d "${TMPDIR:-/tmp}/vpsguardian-api-discovery.XXXXXX")
API_MYSQL_FILE="$API_DISCOVERY_DIR/mysql"
API_POSTGRES_FILE="$API_DISCOVERY_DIR/postgres"
API_MONGODB_FILE="$API_DISCOVERY_DIR/mongodb"

# Tentar usar API do Coolify primeiro
if detect_databases_via_api 2>/dev/null; then
    # Carregar containers dos arquivos temporários
    mapfile -t MYSQL_CONTAINERS < <(sort -u "$API_MYSQL_FILE" 2>/dev/null)
    mapfile -t POSTGRES_CONTAINERS < <(sort -u "$API_POSTGRES_FILE" 2>/dev/null)
    mapfile -t MONGODB_CONTAINERS < <(sort -u "$API_MONGODB_FILE" 2>/dev/null)
else
    # Fallback: detecção via Docker
    log_info "Usando detecção via Docker (API não disponível)"
    MYSQL_CONTAINERS=($(detect_mysql_containers))
    POSTGRES_CONTAINERS=($(detect_postgres_containers))
    MONGODB_CONTAINERS=($(detect_mongodb_containers))
fi
rm -rf "$API_DISCOVERY_DIR"

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

### ========== PERGUNTAR SOBRE CONTAINERS COOLIFY ==========
# Separar containers Coolify dos demais
COOLIFY_MYSQL=()
COOLIFY_POSTGRES=()
COOLIFY_MONGODB=()
APP_MYSQL=()
APP_POSTGRES=()
APP_MONGODB=()

for container in "${MYSQL_CONTAINERS[@]}"; do
    if [[ "$container" =~ coolify ]]; then
        COOLIFY_MYSQL+=("$container")
    else
        APP_MYSQL+=("$container")
    fi
done

for container in "${POSTGRES_CONTAINERS[@]}"; do
    if [[ "$container" =~ coolify ]]; then
        COOLIFY_POSTGRES+=("$container")
    else
        APP_POSTGRES+=("$container")
    fi
done

for container in "${MONGODB_CONTAINERS[@]}"; do
    if [[ "$container" =~ coolify ]]; then
        COOLIFY_MONGODB+=("$container")
    else
        APP_MONGODB+=("$container")
    fi
done

TOTAL_COOLIFY=$((${#COOLIFY_MYSQL[@]} + ${#COOLIFY_POSTGRES[@]} + ${#COOLIFY_MONGODB[@]}))

# Decidir se inclui Coolify baseado em flags ou modo
if [ $TOTAL_COOLIFY -gt 0 ]; then
    echo ""
    log_warning "⚠️  Detecção: $TOTAL_COOLIFY container(s) relacionado(s) ao Coolify encontrado(s):"
    for c in "${COOLIFY_MYSQL[@]}" "${COOLIFY_POSTGRES[@]}" "${COOLIFY_MONGODB[@]}"; do
        echo "    - $c"
    done
    echo ""

    # Se flag explícita foi passada, usar ela
    if [ "$INCLUDE_COOLIFY" = "true" ]; then
        log_info "✓ Containers Coolify serão incluídos (--include-coolify)"
    elif [ "$INCLUDE_COOLIFY" = "false" ]; then
        log_info "✓ Containers Coolify serão EXCLUÍDOS (--exclude-coolify)"
        MYSQL_CONTAINERS=("${APP_MYSQL[@]}")
        POSTGRES_CONTAINERS=("${APP_POSTGRES[@]}")
        MONGODB_CONTAINERS=("${APP_MONGODB[@]}")
        TOTAL_DBS=$((TOTAL_DBS - TOTAL_COOLIFY))
    # Modo interativo: perguntar ao usuário
    elif [ "$AUTO_MODE" = false ]; then
        read -p "Deseja incluir estes containers no backup? (s/N): " include_coolify
        include_coolify=${include_coolify,,}  # Converter para minúsculas

        if [ "$include_coolify" = "s" ] || [ "$include_coolify" = "sim" ] || [ "$include_coolify" = "y" ] || [ "$include_coolify" = "yes" ]; then
            log_info "✓ Containers Coolify serão incluídos no backup."
        else
            # Remover containers Coolify das listas
            MYSQL_CONTAINERS=("${APP_MYSQL[@]}")
            POSTGRES_CONTAINERS=("${APP_POSTGRES[@]}")
            MONGODB_CONTAINERS=("${APP_MONGODB[@]}")
            TOTAL_DBS=$((TOTAL_DBS - TOTAL_COOLIFY))
            log_info "✓ Containers Coolify NÃO serão incluídos no backup."
            echo ""
            log_info "Total de bancos a migrar: $TOTAL_DBS"
        fi
    # Modo auto sem flag: incluir por padrão
    else
        log_info "✓ Containers Coolify serão incluídos (modo automático)"
    fi
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
if [ "$AUTO_MODE" = false ]; then
    echo ""
    log_section "Confirmar Migração"
    echo ""
    echo "  Bancos a migrar: $TOTAL_DBS"
    if [ "$TARGET_SERVER" = "local" ]; then
        echo "  Destino: Apenas criar dumps locais (Organizado por Lotes)"
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

if ! DUMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/vpsguardian-database-dumps.XXXXXX"); then
    log_error "Não foi possível criar diretório temporário seguro"
    exit 1
fi

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

    REMOTE_DIR="/root/database-dumps-migration/lote-${TIMESTAMP}"
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
    # Salvando em lotes organizados usando diretório configurado
    BASE_BACKUP_DIR="${DATABASE_BACKUP_DIR:-${BACKUP_ROOT:-/var/backups/vpsguardian}/databases}"
    FINAL_DIR="$BASE_BACKUP_DIR/lote-${TIMESTAMP}"
    mkdir -p "$FINAL_DIR"
    mv "$DUMP_DIR"/* "$FINAL_DIR/" 2>/dev/null
    rm -rf "$DUMP_DIR"

    echo ""
    log_success "Dumps salvos e organizados com sucesso!"
    echo ""
    echo "  📂 Localização dos arquivos:"
    echo "     $FINAL_DIR"
    echo ""
    echo "  📄 Conteúdo do lote:"
    ls -lh "$FINAL_DIR"/*${TIMESTAMP}* 2>/dev/null | awk '{printf "     %s  %s\n", $5, $9}' | sed "s|$FINAL_DIR/|     |"
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
else
    echo ""
    echo "  📂 Diretório dos backups:"
    echo "     $FINAL_DIR"
fi

echo ""
echo "  Vantagens do dump SQL:"
echo "    - Arquivos menores que volumes"
echo "    - Sem problemas de redo logs"
echo "    - Portável entre versões"
echo ""

if [ "$FAIL_COUNT" -gt 0 ]; then
    log_error "Migração via dump incompleta: $FAIL_COUNT de $TOTAL_DBS dump(s) falharam"
    exit 1
fi

log_success "Migração via dump concluída com sucesso!"
exit 0
