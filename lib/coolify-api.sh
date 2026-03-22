#!/bin/bash
################################################################################
# Script: coolify-api.sh
# Propósito: Biblioteca de integração com API REST do Coolify
# Uso: source /opt/vpsguardian/lib/coolify-api.sh
#
# Funcionalidades:
#   - Descoberta automática de databases via API
#   - Stop/Start graceful (respeita estado do Coolify)
#   - Obtenção de credenciais de conexão via API
#
# Documentação: https://coolify.io/docs/api-reference/api/
# Versão: 1.0.0
################################################################################

# Configuração (pode ser sobrescrita via backup-destinations.conf)
COOLIFY_API_URL="${COOLIFY_API_URL:-http://localhost:8000/api/v1}"
COOLIFY_API_TOKEN="${COOLIFY_API_TOKEN:-}"
COOLIFY_API_TIMEOUT="${COOLIFY_API_TIMEOUT:-10}"
COOLIFY_USE_API_FOR_STOP="${COOLIFY_USE_API_FOR_STOP:-true}"
COOLIFY_API_ENABLED="${COOLIFY_API_ENABLED:-false}"

# Cache de recursos (para evitar múltiplas chamadas à API)
declare -A COOLIFY_DATABASES_CACHE
declare -A COOLIFY_APPLICATIONS_CACHE
declare -A COOLIFY_SERVICES_CACHE
COOLIFY_CACHE_LOADED=false

################################################################################
# Funções de Verificação
################################################################################

# Verifica se jq está instalado
coolify_check_jq() {
    if ! command -v jq &>/dev/null; then
        return 1
    fi
    return 0
}

# Verifica se a API está disponível e configurada
coolify_api_available() {
    # Verificar se está habilitado
    if [ "$COOLIFY_API_ENABLED" != "true" ]; then
        return 1
    fi

    # Verificar token
    if [ -z "$COOLIFY_API_TOKEN" ]; then
        return 1
    fi

    # Verificar jq
    if ! coolify_check_jq; then
        return 1
    fi

    # Verificar conectividade (endpoint de health)
    local health_url="${COOLIFY_API_URL%/api/v1}/health"
    if curl -sf --max-time 3 "$health_url" >/dev/null 2>&1; then
        return 0
    fi

    # Fallback: tentar endpoint raiz da API
    if curl -sf --max-time 3 -H "Authorization: Bearer $COOLIFY_API_TOKEN" \
        "$COOLIFY_API_URL/servers" >/dev/null 2>&1; then
        return 0
    fi

    return 1
}

# Verifica se a API está habilitada (sem testar conectividade)
coolify_api_enabled() {
    [ "$COOLIFY_API_ENABLED" = "true" ] && [ -n "$COOLIFY_API_TOKEN" ]
}

################################################################################
# Funções de Chamada à API
################################################################################

# Chamada genérica à API
# Uso: coolify_api_call GET /databases
# Uso: coolify_api_call POST /databases/uuid/start
coolify_api_call() {
    local method="${1:-GET}"
    local endpoint="$2"
    local data="$3"

    if [ -z "$COOLIFY_API_TOKEN" ]; then
        echo '{"error": "Token não configurado"}' >&2
        return 1
    fi

    local curl_opts=(
        -sf
        --max-time "$COOLIFY_API_TIMEOUT"
        -X "$method"
        -H "Authorization: Bearer $COOLIFY_API_TOKEN"
        -H "Content-Type: application/json"
        -H "Accept: application/json"
    )

    if [ -n "$data" ]; then
        curl_opts+=(-d "$data")
    fi

    local response
    response=$(curl "${curl_opts[@]}" "${COOLIFY_API_URL}${endpoint}" 2>/dev/null)
    local exit_code=$?

    if [ $exit_code -ne 0 ]; then
        echo '{"error": "Falha na requisição"}' >&2
        return 1
    fi

    echo "$response"
    return 0
}

################################################################################
# Funções de Databases
################################################################################

# Lista todos os databases
# Retorna JSON array com databases
coolify_list_databases() {
    local response
    response=$(coolify_api_call GET "/databases")

    if [ $? -eq 0 ] && [ -n "$response" ]; then
        echo "$response"
        return 0
    fi

    echo "[]"
    return 1
}

# Obtém detalhes de um database específico
# Uso: coolify_get_database <uuid>
coolify_get_database() {
    local uuid="$1"

    if [ -z "$uuid" ]; then
        echo '{"error": "UUID não fornecido"}' >&2
        return 1
    fi

    coolify_api_call GET "/databases/$uuid"
}

# Obtém a URL interna de conexão do database
# Uso: coolify_get_db_connection_url <uuid>
# Retorna: postgresql://user:pass@host:5432/db ou mysql://...
coolify_get_db_connection_url() {
    local uuid="$1"
    local db_info

    db_info=$(coolify_get_database "$uuid")
    if [ $? -ne 0 ]; then
        return 1
    fi

    # Tentar obter internal_db_url
    local url
    url=$(echo "$db_info" | jq -r '.internal_db_url // empty' 2>/dev/null)

    if [ -n "$url" ] && [ "$url" != "null" ]; then
        echo "$url"
        return 0
    fi

    return 1
}

# Para um database
# Uso: coolify_stop_database <uuid>
coolify_stop_database() {
    local uuid="$1"
    coolify_api_call GET "/databases/$uuid/stop"
}

# Inicia um database
# Uso: coolify_start_database <uuid>
coolify_start_database() {
    local uuid="$1"
    coolify_api_call GET "/databases/$uuid/start"
}

# Reinicia um database
# Uso: coolify_restart_database <uuid>
coolify_restart_database() {
    local uuid="$1"
    coolify_api_call GET "/databases/$uuid/restart"
}

################################################################################
# Funções de Projects
################################################################################

# Lista todos os projetos
# Retorna JSON array com projetos
coolify_list_projects() {
    local response
    response=$(coolify_api_call GET "/projects")

    if [ $? -eq 0 ] && [ -n "$response" ]; then
        echo "$response"
        return 0
    fi

    echo "[]"
    return 1
}

# Obtém detalhes de um projeto específico
# Uso: coolify_get_project <uuid>
coolify_get_project() {
    local uuid="$1"

    if [ -z "$uuid" ]; then
        echo '{"error": "UUID não fornecido"}' >&2
        return 1
    fi

    coolify_api_call GET "/projects/$uuid"
}

# Lista recursos de um projeto (apps, databases, services)
# Uso: coolify_list_project_resources <project_uuid>
coolify_list_project_resources() {
    local uuid="$1"

    if [ -z "$uuid" ]; then
        echo '{"error": "UUID não fornecido"}' >&2
        return 1
    fi

    # A API retorna environments que contém os recursos
    local project
    project=$(coolify_get_project "$uuid")

    if [ $? -ne 0 ]; then
        return 1
    fi

    echo "$project"
}

# Descobre projetos e seus recursos em formato estruturado
# Retorna linhas no formato: project_uuid|project_name|env_name|resource_type|resource_uuid|resource_name
coolify_discover_projects() {
    if ! coolify_api_available; then
        return 1
    fi

    local projects
    projects=$(coolify_list_projects 2>/dev/null)

    if [ -z "$projects" ] || [ "$projects" = "[]" ]; then
        return 1
    fi

    # Processar cada projeto
    echo "$projects" | jq -r '.[] |
        .uuid as $proj_uuid |
        .name as $proj_name |
        (.environments // [])[] |
        .name as $env_name |
        (
            ((.applications // [])[] | [$proj_uuid, $proj_name, $env_name, "application", .uuid, .name]),
            ((.databases // [])[] | [$proj_uuid, $proj_name, $env_name, "database", .uuid, .name]),
            ((.services // [])[] | [$proj_uuid, $proj_name, $env_name, "service", .uuid, .name])
        ) | @tsv
    ' 2>/dev/null | while IFS=$'\t' read -r proj_uuid proj_name env_name res_type res_uuid res_name; do
        echo "$proj_uuid|$proj_name|$env_name|$res_type|$res_uuid|$res_name"
    done
}

# Lista databases de um projeto específico
# Uso: coolify_list_project_databases <project_uuid_or_name>
# Retorna linhas no formato: uuid|name|type|status|container_name|connection_url
coolify_list_project_databases() {
    local project_id="$1"

    if ! coolify_api_available; then
        return 1
    fi

    # Se não for UUID, tentar encontrar pelo nome
    local project_uuid="$project_id"
    if [[ ! "$project_id" =~ ^[a-z0-9-]{20,}$ ]]; then
        project_uuid=$(coolify_get_project_uuid_by_name "$project_id")
        if [ -z "$project_uuid" ]; then
            return 1
        fi
    fi

    local project
    project=$(coolify_get_project "$project_uuid" 2>/dev/null)

    if [ -z "$project" ]; then
        return 1
    fi

    # Extrair databases de todos os environments
    echo "$project" | jq -r '
        (.environments // [])[] |
        (.databases // [])[] |
        [.uuid, .name, .type, .status, (.container_name // .name), (.internal_db_url // "")] | @tsv
    ' 2>/dev/null | while IFS=$'\t' read -r uuid name type status container url; do
        echo "$uuid|$name|$type|$status|$container|$url"
    done
}

# Obtém UUID de um projeto pelo nome
# Uso: coolify_get_project_uuid_by_name <project_name>
coolify_get_project_uuid_by_name() {
    local project_name="$1"

    local projects
    projects=$(coolify_list_projects 2>/dev/null)

    if [ -z "$projects" ] || [ "$projects" = "[]" ]; then
        return 1
    fi

    echo "$projects" | jq -r --arg name "$project_name" '.[] | select(.name == $name) | .uuid' 2>/dev/null | head -n1
}

# Lista nomes de projetos para seleção
# Retorna linhas no formato: uuid|name|description
coolify_list_project_names() {
    if ! coolify_api_available; then
        return 1
    fi

    local projects
    projects=$(coolify_list_projects 2>/dev/null)

    if [ -z "$projects" ] || [ "$projects" = "[]" ]; then
        return 1
    fi

    echo "$projects" | jq -r '.[] | [.uuid, .name, (.description // "")] | @tsv' 2>/dev/null | \
        while IFS=$'\t' read -r uuid name desc; do
            echo "$uuid|$name|$desc"
        done
}

################################################################################
# Funções de Applications
################################################################################

# Lista todas as applications
coolify_list_applications() {
    coolify_api_call GET "/applications"
}

# Para uma application
coolify_stop_application() {
    local uuid="$1"
    coolify_api_call GET "/applications/$uuid/stop"
}

# Inicia uma application
coolify_start_application() {
    local uuid="$1"
    coolify_api_call GET "/applications/$uuid/start"
}

# Reinicia uma application
coolify_restart_application() {
    local uuid="$1"
    coolify_api_call GET "/applications/$uuid/restart"
}

################################################################################
# Funções de Services (Docker Compose)
################################################################################

# Lista todos os services
coolify_list_services() {
    coolify_api_call GET "/services"
}

# Para um service
coolify_stop_service() {
    local uuid="$1"
    coolify_api_call GET "/services/$uuid/stop"
}

# Inicia um service
coolify_start_service() {
    local uuid="$1"
    coolify_api_call GET "/services/$uuid/start"
}

################################################################################
# Funções de Mapeamento Container <-> UUID
################################################################################

# Carrega cache de recursos do Coolify
coolify_load_cache() {
    if [ "$COOLIFY_CACHE_LOADED" = true ]; then
        return 0
    fi

    if ! coolify_api_available; then
        return 1
    fi

    # Carregar databases
    local dbs
    dbs=$(coolify_list_databases 2>/dev/null)
    if [ -n "$dbs" ] && [ "$dbs" != "[]" ]; then
        while IFS= read -r db; do
            local uuid name container_name type status
            uuid=$(echo "$db" | jq -r '.uuid // empty')
            name=$(echo "$db" | jq -r '.name // empty')
            type=$(echo "$db" | jq -r '.type // empty')
            status=$(echo "$db" | jq -r '.status // empty')

            # Tentar obter nome do container (pode variar conforme versão do Coolify)
            container_name=$(echo "$db" | jq -r '.container_name // .name // empty')

            if [ -n "$uuid" ]; then
                COOLIFY_DATABASES_CACHE["$uuid"]="$name|$type|$status|$container_name"
                # Mapeamento reverso por nome
                COOLIFY_DATABASES_CACHE["name:$name"]="$uuid"
                if [ -n "$container_name" ]; then
                    COOLIFY_DATABASES_CACHE["container:$container_name"]="$uuid"
                fi
            fi
        done < <(echo "$dbs" | jq -c '.[]' 2>/dev/null)
    fi

    COOLIFY_CACHE_LOADED=true
    return 0
}

# Obtém UUID de um database pelo nome do container
# Uso: coolify_get_uuid_by_container <container_name>
coolify_get_uuid_by_container() {
    local container_name="$1"

    coolify_load_cache

    # Buscar no cache por container
    local uuid="${COOLIFY_DATABASES_CACHE["container:$container_name"]}"
    if [ -n "$uuid" ]; then
        echo "$uuid"
        return 0
    fi

    # Buscar no cache por nome
    uuid="${COOLIFY_DATABASES_CACHE["name:$container_name"]}"
    if [ -n "$uuid" ]; then
        echo "$uuid"
        return 0
    fi

    # Busca parcial (container pode ter sufixo/prefixo)
    for key in "${!COOLIFY_DATABASES_CACHE[@]}"; do
        if [[ "$key" == container:* ]] && [[ "$key" == *"$container_name"* ]]; then
            echo "${COOLIFY_DATABASES_CACHE[$key]}"
            return 0
        fi
    done

    return 1
}

# Obtém tipo de database pelo UUID
# Retorna: postgresql, mysql, mariadb, mongodb, redis
coolify_get_db_type() {
    local uuid="$1"

    coolify_load_cache

    local info="${COOLIFY_DATABASES_CACHE[$uuid]}"
    if [ -n "$info" ]; then
        echo "$info" | cut -d'|' -f2
        return 0
    fi

    # Fallback: buscar na API
    local db_info
    db_info=$(coolify_get_database "$uuid" 2>/dev/null)
    if [ $? -eq 0 ]; then
        echo "$db_info" | jq -r '.type // "unknown"'
        return 0
    fi

    echo "unknown"
    return 1
}

################################################################################
# Funções de Alto Nível (Integração com Backup)
################################################################################

# Descobre todos os databases via API e retorna em formato estruturado
# Retorna linhas no formato: uuid|name|type|status|container_name|connection_url
coolify_discover_databases() {
    if ! coolify_api_available; then
        return 1
    fi

    local dbs
    dbs=$(coolify_list_databases 2>/dev/null)

    if [ -z "$dbs" ] || [ "$dbs" = "[]" ]; then
        return 1
    fi

    echo "$dbs" | jq -r '.[] | [.uuid, .name, .type, .status, (.container_name // .name), (.internal_db_url // "")] | @tsv' 2>/dev/null | \
        while IFS=$'\t' read -r uuid name type status container url; do
            echo "$uuid|$name|$type|$status|$container|$url"
        done
}

# Para um recurso (database, application ou service) via API
# Uso: coolify_graceful_stop <resource_type> <uuid_or_container>
# resource_type: database, application, service
coolify_graceful_stop() {
    local resource_type="$1"
    local identifier="$2"

    if ! coolify_api_available; then
        return 1
    fi

    local uuid="$identifier"

    # Se não for UUID, tentar descobrir pelo nome do container
    if [[ ! "$identifier" =~ ^[a-z0-9-]+$ ]] || [ ${#identifier} -lt 20 ]; then
        uuid=$(coolify_get_uuid_by_container "$identifier")
        if [ -z "$uuid" ]; then
            return 1
        fi
    fi

    case "$resource_type" in
        database|databases)
            coolify_stop_database "$uuid"
            ;;
        application|applications)
            coolify_stop_application "$uuid"
            ;;
        service|services)
            coolify_stop_service "$uuid"
            ;;
        *)
            return 1
            ;;
    esac
}

# Inicia um recurso (database, application ou service) via API
# Uso: coolify_graceful_start <resource_type> <uuid_or_container>
coolify_graceful_start() {
    local resource_type="$1"
    local identifier="$2"

    if ! coolify_api_available; then
        return 1
    fi

    local uuid="$identifier"

    if [[ ! "$identifier" =~ ^[a-z0-9-]+$ ]] || [ ${#identifier} -lt 20 ]; then
        uuid=$(coolify_get_uuid_by_container "$identifier")
        if [ -z "$uuid" ]; then
            return 1
        fi
    fi

    case "$resource_type" in
        database|databases)
            coolify_start_database "$uuid"
            ;;
        application|applications)
            coolify_start_application "$uuid"
            ;;
        service|services)
            coolify_start_service "$uuid"
            ;;
        *)
            return 1
            ;;
    esac
}

# Wrapper inteligente para stop que usa API se disponível, senão docker stop
# Uso: smart_stop_container <container_name> [resource_type]
smart_stop_container() {
    local container="$1"
    local resource_type="${2:-database}"

    # Tentar via API primeiro
    if [ "$COOLIFY_USE_API_FOR_STOP" = "true" ] && coolify_api_available; then
        if coolify_graceful_stop "$resource_type" "$container" >/dev/null 2>&1; then
            # Aguardar container parar
            local max_wait=30
            local waited=0
            while docker ps --format '{{.Names}}' | grep -q "^${container}$" && [ $waited -lt $max_wait ]; do
                sleep 1
                ((waited++))
            done

            if ! docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
                return 0
            fi
        fi
    fi

    # Fallback: docker stop
    docker stop -t 60 "$container" >/dev/null 2>&1
}

# Wrapper inteligente para start que usa API se disponível, senão docker start
# Uso: smart_start_container <container_name> [resource_type]
smart_start_container() {
    local container="$1"
    local resource_type="${2:-database}"

    # Tentar via API primeiro
    if [ "$COOLIFY_USE_API_FOR_STOP" = "true" ] && coolify_api_available; then
        if coolify_graceful_start "$resource_type" "$container" >/dev/null 2>&1; then
            # Aguardar container iniciar
            local max_wait=30
            local waited=0
            while ! docker ps --format '{{.Names}}' | grep -q "^${container}$" && [ $waited -lt $max_wait ]; do
                sleep 1
                ((waited++))
            done

            if docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
                return 0
            fi
        fi
    fi

    # Fallback: docker start
    docker start "$container" >/dev/null 2>&1
}

################################################################################
# Funções de Health Check e Migração
################################################################################

# Verifica health de todas as applications
# Retorna linhas no formato: uuid|name|status|health
coolify_check_applications_health() {
    if ! coolify_api_available; then
        return 1
    fi

    local apps
    apps=$(coolify_list_applications 2>/dev/null)

    if [ -z "$apps" ] || [ "$apps" = "[]" ]; then
        return 1
    fi

    echo "$apps" | jq -r '.[] | [.uuid, .name, .status, (.health // "unknown")] | @tsv' 2>/dev/null | \
        while IFS=$'\t' read -r uuid name status health; do
            echo "$uuid|$name|$status|$health"
        done
}

# Verifica health de todos os databases
# Retorna linhas no formato: uuid|name|type|status|is_public
coolify_check_databases_health() {
    if ! coolify_api_available; then
        return 1
    fi

    local dbs
    dbs=$(coolify_list_databases 2>/dev/null)

    if [ -z "$dbs" ] || [ "$dbs" = "[]" ]; then
        return 1
    fi

    echo "$dbs" | jq -r '.[] | [.uuid, .name, .type, .status, (.is_public // false)] | @tsv' 2>/dev/null | \
        while IFS=$'\t' read -r uuid name type status is_public; do
            echo "$uuid|$name|$type|$status|$is_public"
        done
}

# Verifica health de todos os services
# Retorna linhas no formato: uuid|name|status
coolify_check_services_health() {
    if ! coolify_api_available; then
        return 1
    fi

    local services
    services=$(coolify_list_services 2>/dev/null)

    if [ -z "$services" ] || [ "$services" = "[]" ]; then
        return 1
    fi

    echo "$services" | jq -r '.[] | [.uuid, .name, .status] | @tsv' 2>/dev/null | \
        while IFS=$'\t' read -r uuid name status; do
            echo "$uuid|$name|$status"
        done
}

# Lista todos os recursos do Coolify com status
# Retorna linhas no formato: type|uuid|name|status|extra_info
coolify_list_all_resources() {
    if ! coolify_api_available; then
        return 1
    fi

    # Applications
    coolify_check_applications_health 2>/dev/null | while IFS='|' read -r uuid name status health; do
        echo "application|$uuid|$name|$status|health:$health"
    done

    # Databases
    coolify_check_databases_health 2>/dev/null | while IFS='|' read -r uuid name type status is_public; do
        echo "database|$uuid|$name|$status|type:$type"
    done

    # Services
    coolify_check_services_health 2>/dev/null | while IFS='|' read -r uuid name status; do
        echo "service|$uuid|$name|$status|"
    done
}

# Conta recursos por tipo e status
# Uso: coolify_count_resources [running|stopped|all]
coolify_count_resources() {
    local filter="${1:-all}"

    if ! coolify_api_available; then
        echo "0|0|0"
        return 1
    fi

    local apps_total=0 apps_running=0
    local dbs_total=0 dbs_running=0
    local services_total=0 services_running=0

    # Contar applications
    local apps
    apps=$(coolify_list_applications 2>/dev/null)
    if [ -n "$apps" ] && [ "$apps" != "[]" ]; then
        apps_total=$(echo "$apps" | jq 'length' 2>/dev/null)
        apps_running=$(echo "$apps" | jq '[.[] | select(.status == "running")] | length' 2>/dev/null)
    fi

    # Contar databases
    local dbs
    dbs=$(coolify_list_databases 2>/dev/null)
    if [ -n "$dbs" ] && [ "$dbs" != "[]" ]; then
        dbs_total=$(echo "$dbs" | jq 'length' 2>/dev/null)
        dbs_running=$(echo "$dbs" | jq '[.[] | select(.status == "running")] | length' 2>/dev/null)
    fi

    # Contar services
    local services
    services=$(coolify_list_services 2>/dev/null)
    if [ -n "$services" ] && [ "$services" != "[]" ]; then
        services_total=$(echo "$services" | jq 'length' 2>/dev/null)
        services_running=$(echo "$services" | jq '[.[] | select(.status == "running")] | length' 2>/dev/null)
    fi

    case "$filter" in
        running)
            echo "$apps_running|$dbs_running|$services_running"
            ;;
        total|all)
            echo "$apps_total|$dbs_total|$services_total"
            ;;
        *)
            echo "apps:$apps_running/$apps_total|dbs:$dbs_running/$dbs_total|services:$services_running/$services_total"
            ;;
    esac
}

# Verifica se todos os recursos estão running
# Retorna 0 se todos estão running, 1 caso contrário
coolify_all_resources_healthy() {
    if ! coolify_api_available; then
        return 1
    fi

    local total running

    # Verificar applications
    local apps
    apps=$(coolify_list_applications 2>/dev/null)
    if [ -n "$apps" ] && [ "$apps" != "[]" ]; then
        total=$(echo "$apps" | jq 'length' 2>/dev/null)
        running=$(echo "$apps" | jq '[.[] | select(.status == "running")] | length' 2>/dev/null)
        if [ "$total" != "$running" ]; then
            return 1
        fi
    fi

    # Verificar databases
    local dbs
    dbs=$(coolify_list_databases 2>/dev/null)
    if [ -n "$dbs" ] && [ "$dbs" != "[]" ]; then
        total=$(echo "$dbs" | jq 'length' 2>/dev/null)
        running=$(echo "$dbs" | jq '[.[] | select(.status == "running")] | length' 2>/dev/null)
        if [ "$total" != "$running" ]; then
            return 1
        fi
    fi

    # Verificar services
    local services
    services=$(coolify_list_services 2>/dev/null)
    if [ -n "$services" ] && [ "$services" != "[]" ]; then
        total=$(echo "$services" | jq 'length' 2>/dev/null)
        running=$(echo "$services" | jq '[.[] | select(.status == "running")] | length' 2>/dev/null)
        if [ "$total" != "$running" ]; then
            return 1
        fi
    fi

    return 0
}

################################################################################
# Funções de Exportação/Importação para Migração
################################################################################

# Exporta inventário completo de recursos para arquivo JSON
# Uso: coolify_export_inventory [output_file]
coolify_export_inventory() {
    local output_file="${1:-/tmp/coolify-inventory-$(date +%Y%m%d_%H%M%S).json}"

    if ! coolify_api_available; then
        echo '{"error": "API não disponível"}' > "$output_file"
        return 1
    fi

    local apps dbs services projects

    apps=$(coolify_list_applications 2>/dev/null || echo "[]")
    dbs=$(coolify_list_databases 2>/dev/null || echo "[]")
    services=$(coolify_list_services 2>/dev/null || echo "[]")
    projects=$(coolify_list_projects 2>/dev/null || echo "[]")

    cat > "$output_file" <<EOF
{
  "exported_at": "$(date -Iseconds)",
  "hostname": "$(hostname)",
  "coolify_api_url": "$COOLIFY_API_URL",
  "applications": $apps,
  "databases": $dbs,
  "services": $services,
  "projects": $projects
}
EOF

    if [ -f "$output_file" ]; then
        echo "$output_file"
        return 0
    fi
    return 1
}

# Exporta variáveis de ambiente de uma application
# Uso: coolify_export_app_envs <app_uuid> [output_file]
coolify_export_app_envs() {
    local app_uuid="$1"
    local output_file="${2:-/tmp/app-envs-${app_uuid}-$(date +%Y%m%d_%H%M%S).json}"

    if ! coolify_api_available || [ -z "$app_uuid" ]; then
        return 1
    fi

    local envs
    envs=$(coolify_api_call GET "/applications/$app_uuid/envs" 2>/dev/null)

    if [ -n "$envs" ]; then
        echo "$envs" > "$output_file"
        echo "$output_file"
        return 0
    fi
    return 1
}

# Exporta lista simplificada de recursos para comparação pré/pós migração
# Uso: coolify_export_resources_list [output_file]
# Formato: CSV (type,uuid,name,status)
coolify_export_resources_list() {
    local output_file="${1:-/tmp/coolify-resources-$(date +%Y%m%d_%H%M%S).csv}"

    if ! coolify_api_available; then
        return 1
    fi

    echo "type,uuid,name,status,extra" > "$output_file"

    # Applications
    coolify_list_applications 2>/dev/null | jq -r '.[] | ["application", .uuid, .name, .status, ""] | @csv' >> "$output_file" 2>/dev/null

    # Databases
    coolify_list_databases 2>/dev/null | jq -r '.[] | ["database", .uuid, .name, .status, .type] | @csv' >> "$output_file" 2>/dev/null

    # Services
    coolify_list_services 2>/dev/null | jq -r '.[] | ["service", .uuid, .name, .status, ""] | @csv' >> "$output_file" 2>/dev/null

    if [ -f "$output_file" ]; then
        echo "$output_file"
        return 0
    fi
    return 1
}

# Compara dois inventários de recursos (pré e pós migração)
# Uso: coolify_compare_inventories <pre_file> <post_file>
coolify_compare_inventories() {
    local pre_file="$1"
    local post_file="$2"

    if [ ! -f "$pre_file" ] || [ ! -f "$post_file" ]; then
        echo "Erro: Arquivos de inventário não encontrados"
        return 1
    fi

    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║            COMPARAÇÃO DE INVENTÁRIOS (Migração)              ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""

    # Contar recursos em cada arquivo
    local pre_apps pre_dbs pre_svcs
    local post_apps post_dbs post_svcs

    pre_apps=$(jq '.applications | length' "$pre_file" 2>/dev/null || echo 0)
    pre_dbs=$(jq '.databases | length' "$pre_file" 2>/dev/null || echo 0)
    pre_svcs=$(jq '.services | length' "$pre_file" 2>/dev/null || echo 0)

    post_apps=$(jq '.applications | length' "$post_file" 2>/dev/null || echo 0)
    post_dbs=$(jq '.databases | length' "$post_file" 2>/dev/null || echo 0)
    post_svcs=$(jq '.services | length' "$post_file" 2>/dev/null || echo 0)

    echo "  CONTAGEM DE RECURSOS:"
    echo "                       PRÉ    PÓS    DIFF"
    echo "    Applications:     $pre_apps      $post_apps      $((post_apps - pre_apps))"
    echo "    Databases:        $pre_dbs      $post_dbs      $((post_dbs - pre_dbs))"
    echo "    Services:         $pre_svcs      $post_svcs      $((post_svcs - pre_svcs))"
    echo ""

    # Verificar recursos ausentes
    echo "  RECURSOS AUSENTES NO DESTINO:"
    local missing=0

    # Comparar applications
    for uuid in $(jq -r '.applications[].uuid' "$pre_file" 2>/dev/null); do
        if ! jq -e --arg uuid "$uuid" '.applications[] | select(.uuid == $uuid)' "$post_file" >/dev/null 2>&1; then
            local name=$(jq -r --arg uuid "$uuid" '.applications[] | select(.uuid == $uuid) | .name' "$pre_file" 2>/dev/null)
            echo "    ✗ Application: $name ($uuid)"
            ((missing++))
        fi
    done

    # Comparar databases
    for uuid in $(jq -r '.databases[].uuid' "$pre_file" 2>/dev/null); do
        if ! jq -e --arg uuid "$uuid" '.databases[] | select(.uuid == $uuid)' "$post_file" >/dev/null 2>&1; then
            local name=$(jq -r --arg uuid "$uuid" '.databases[] | select(.uuid == $uuid) | .name' "$pre_file" 2>/dev/null)
            echo "    ✗ Database: $name ($uuid)"
            ((missing++))
        fi
    done

    if [ $missing -eq 0 ]; then
        echo "    ✓ Nenhum recurso ausente"
    fi

    echo ""

    # Status dos recursos no destino
    echo "  STATUS DOS RECURSOS NO DESTINO:"
    local not_running=0

    jq -r '.applications[] | "\(.name)|\(.status)"' "$post_file" 2>/dev/null | while IFS='|' read -r name status; do
        if [ "$status" != "running" ]; then
            echo "    ⚠ App: $name ($status)"
            ((not_running++))
        fi
    done

    jq -r '.databases[] | "\(.name)|\(.status)"' "$post_file" 2>/dev/null | while IFS='|' read -r name status; do
        if [ "$status" != "running" ]; then
            echo "    ⚠ DB: $name ($status)"
            ((not_running++))
        fi
    done

    if [ $not_running -eq 0 ]; then
        echo "    ✓ Todos os recursos estão running"
    fi

    echo ""
    return 0
}

# Exporta configuração de servidor (para migração)
# Uso: coolify_export_server_config <server_uuid> [output_file]
coolify_export_server_config() {
    local server_uuid="$1"
    local output_file="${2:-/tmp/server-config-${server_uuid}-$(date +%Y%m%d_%H%M%S).json}"

    if ! coolify_api_available || [ -z "$server_uuid" ]; then
        return 1
    fi

    local server_info
    server_info=$(coolify_api_call GET "/servers/$server_uuid" 2>/dev/null)

    if [ -n "$server_info" ]; then
        echo "$server_info" > "$output_file"
        echo "$output_file"
        return 0
    fi
    return 1
}

# Lista servidores disponíveis
# Retorna linhas no formato: uuid|name|ip|status
coolify_list_servers() {
    if ! coolify_api_available; then
        return 1
    fi

    local servers
    servers=$(coolify_api_call GET "/servers" 2>/dev/null)

    if [ -z "$servers" ] || [ "$servers" = "[]" ]; then
        return 1
    fi

    echo "$servers" | jq -r '.[] | [.uuid, .name, .ip, (.settings.is_reachable // false)] | @tsv' 2>/dev/null | \
        while IFS=$'\t' read -r uuid name ip reachable; do
            local status="unreachable"
            [ "$reachable" = "true" ] && status="reachable"
            echo "$uuid|$name|$ip|$status"
        done
}

# Gera relatório de saúde para migração
# Uso: coolify_migration_health_report
coolify_migration_health_report() {
    if ! coolify_api_available; then
        echo "API não disponível"
        return 1
    fi

    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║            COOLIFY HEALTH REPORT (via API)                   ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""

    local apps_ok=0 apps_fail=0
    local dbs_ok=0 dbs_fail=0
    local services_ok=0 services_fail=0

    # Applications
    echo "  APPLICATIONS:"
    local apps_health
    apps_health=$(coolify_check_applications_health 2>/dev/null)
    if [ -n "$apps_health" ]; then
        while IFS='|' read -r uuid name status health; do
            if [ "$status" = "running" ]; then
                echo "    ✓ $name (running)"
                ((apps_ok++))
            else
                echo "    ✗ $name ($status)"
                ((apps_fail++))
            fi
        done <<< "$apps_health"
    else
        echo "    (nenhuma application encontrada)"
    fi
    echo ""

    # Databases
    echo "  DATABASES:"
    local dbs_health
    dbs_health=$(coolify_check_databases_health 2>/dev/null)
    if [ -n "$dbs_health" ]; then
        while IFS='|' read -r uuid name type status is_public; do
            if [ "$status" = "running" ]; then
                echo "    ✓ $name ($type) - running"
                ((dbs_ok++))
            else
                echo "    ✗ $name ($type) - $status"
                ((dbs_fail++))
            fi
        done <<< "$dbs_health"
    else
        echo "    (nenhum database encontrado)"
    fi
    echo ""

    # Services
    echo "  SERVICES:"
    local services_health
    services_health=$(coolify_check_services_health 2>/dev/null)
    if [ -n "$services_health" ]; then
        while IFS='|' read -r uuid name status; do
            if [ "$status" = "running" ]; then
                echo "    ✓ $name (running)"
                ((services_ok++))
            else
                echo "    ✗ $name ($status)"
                ((services_fail++))
            fi
        done <<< "$services_health"
    else
        echo "    (nenhum service encontrado)"
    fi
    echo ""

    # Resumo
    local total_ok=$((apps_ok + dbs_ok + services_ok))
    local total_fail=$((apps_fail + dbs_fail + services_fail))
    local total=$((total_ok + total_fail))

    echo "  RESUMO:"
    echo "    Applications: $apps_ok OK, $apps_fail com problemas"
    echo "    Databases:    $dbs_ok OK, $dbs_fail com problemas"
    echo "    Services:     $services_ok OK, $services_fail com problemas"
    echo ""
    echo "    Total: $total_ok/$total recursos saudáveis"
    echo ""

    if [ $total_fail -eq 0 ]; then
        echo "  ✅ Todos os recursos estão saudáveis!"
        return 0
    else
        echo "  ⚠️  $total_fail recurso(s) com problemas"
        return 1
    fi
}

################################################################################
# Funções de Diagnóstico
################################################################################

# Testa a conexão com a API e exibe informações
coolify_test_connection() {
    echo "Testando conexão com API do Coolify..."
    echo ""
    echo "  URL: $COOLIFY_API_URL"
    echo "  Token: ${COOLIFY_API_TOKEN:0:10}...${COOLIFY_API_TOKEN: -5}"
    echo "  Timeout: ${COOLIFY_API_TIMEOUT}s"
    echo ""

    # Verificar jq
    if ! coolify_check_jq; then
        echo "  [ERRO] jq não está instalado"
        echo "         Instale com: apt install jq"
        return 1
    fi
    echo "  [OK] jq instalado"

    # Verificar health endpoint
    local health_url="${COOLIFY_API_URL%/api/v1}/health"
    if curl -sf --max-time 3 "$health_url" >/dev/null 2>&1; then
        echo "  [OK] Health endpoint acessível"
    else
        echo "  [AVISO] Health endpoint não acessível"
    fi

    # Testar API
    local servers
    servers=$(coolify_api_call GET "/servers" 2>/dev/null)
    if [ $? -eq 0 ] && [ -n "$servers" ]; then
        local server_count
        server_count=$(echo "$servers" | jq 'length' 2>/dev/null)
        echo "  [OK] API respondendo ($server_count servidor(es))"
    else
        echo "  [ERRO] API não respondeu"
        return 1
    fi

    # Testar databases
    local dbs
    dbs=$(coolify_list_databases 2>/dev/null)
    if [ $? -eq 0 ] && [ -n "$dbs" ]; then
        local db_count
        db_count=$(echo "$dbs" | jq 'length' 2>/dev/null)
        echo "  [OK] $db_count database(s) encontrado(s)"
    fi

    echo ""
    echo "Conexão estabelecida com sucesso!"
    return 0
}

################################################################################
# Export das funções
################################################################################

export -f coolify_api_available coolify_api_enabled coolify_api_call
export -f coolify_list_databases coolify_get_database coolify_get_db_connection_url
export -f coolify_stop_database coolify_start_database coolify_restart_database
export -f coolify_list_projects coolify_get_project coolify_list_project_resources
export -f coolify_discover_projects coolify_list_project_databases
export -f coolify_get_project_uuid_by_name coolify_list_project_names
export -f coolify_list_applications coolify_stop_application coolify_start_application
export -f coolify_list_services coolify_stop_service coolify_start_service
export -f coolify_get_uuid_by_container coolify_get_db_type
export -f coolify_discover_databases coolify_graceful_stop coolify_graceful_start
export -f smart_stop_container smart_start_container
export -f coolify_check_applications_health coolify_check_databases_health coolify_check_services_health
export -f coolify_list_all_resources coolify_count_resources coolify_all_resources_healthy
export -f coolify_export_inventory coolify_export_app_envs coolify_export_resources_list
export -f coolify_compare_inventories coolify_export_server_config coolify_list_servers
export -f coolify_migration_health_report
export -f coolify_test_connection coolify_load_cache

# Marca que coolify-api.sh foi carregado
COOLIFY_API_LOADED=1
export COOLIFY_API_LOADED
