#!/bin/bash
################################################################################
# Detecção conservadora de engines de banco em containers Docker.
#
# Variáveis como POSTGRES_PASSWORD e MYSQL_ROOT_PASSWORD podem ser propagadas
# pelo Coolify para aplicações, workers e outros serviços do mesmo compose.
# Portanto, variáveis de ambiente não são evidência suficiente de que o
# container executa um servidor de banco.
################################################################################

declare -A DATABASE_CONTAINER_SHELL_CACHE=()

database_container_has_shell() {
    local container="$1"
    local cached="${DATABASE_CONTAINER_SHELL_CACHE[$container]:-}"

    [ "$cached" = true ] && return 0
    [ "$cached" = false ] && return 1

    if docker exec "$container" sh -c ':' >/dev/null 2>&1; then
        DATABASE_CONTAINER_SHELL_CACHE["$container"]=true
        return 0
    fi

    DATABASE_CONTAINER_SHELL_CACHE["$container"]=false
    return 1
}

database_container_has_command() {
    local container="$1" tool="$2"

    # Quando há shell, uma ferramenta ausente vira apenas exit status 1 dentro
    # do container e não um erro OCI ruidoso no journal do dockerd.
    if database_container_has_shell "$container"; then
        docker exec "$container" sh -c \
            'command -v "$1" >/dev/null 2>&1' _ "$tool" >/dev/null 2>&1
        return $?
    fi

    # Imagens distroless podem não ter shell. Nelas mantemos a sondagem direta
    # para não deixar de detectar uma ferramenta realmente disponível.
    docker exec "$container" "$tool" --version >/dev/null 2>&1
}

database_container_has_tool() {
    local container="$1"
    local engine="$2"

    case "$engine" in
        mysql)
            database_container_has_command "$container" mariadb-dump ||
                database_container_has_command "$container" mysqldump
            ;;
        postgres)
            database_container_has_command "$container" pg_dump
            ;;
        mongodb)
            database_container_has_command "$container" mongodump
            ;;
        redis)
            database_container_has_command "$container" redis-server
            ;;
        *)
            return 1
            ;;
    esac
}

database_container_matches_engine() {
    local container="$1"
    local engine="$2"
    local metadata image exposed_ports coolify_type

    metadata=$(docker inspect \
        --format='{{.Config.Image}}|{{range $p, $conf := .Config.ExposedPorts}}{{$p}} {{end}}|{{index .Config.Labels "coolify.type"}}' \
        "$container" 2>/dev/null) || return 1
    IFS='|' read -r image exposed_ports coolify_type <<< "$metadata"
    image=${image,,}

    case "$engine" in
        mysql)
            [[ "$image" =~ mysql|mariadb ]] || [[ "$exposed_ports" =~ (^|[[:space:]])3306/ ]] ||
                [ "$coolify_type" = "database" ] || return 1
            ;;
        postgres)
            [[ "$image" =~ postgres|esus_database ]] || [[ "$exposed_ports" =~ (^|[[:space:]])5432/ ]] ||
                [ "$coolify_type" = "database" ] || return 1
            ;;
        mongodb)
            [[ "$image" =~ mongo|mongodb ]] || [[ "$exposed_ports" =~ (^|[[:space:]])27017/ ]] ||
                [ "$coolify_type" = "database" ] || return 1
            ;;
        redis)
            [[ "$image" =~ redis ]] || [[ "$exposed_ports" =~ (^|[[:space:]])6379/ ]] ||
                [ "$coolify_type" = "database" ] || return 1
            ;;
        *)
            return 1
            ;;
    esac

    database_container_has_tool "$container" "$engine"
}

detect_database_containers_by_engine() {
    local engine="$1"
    local name

    while IFS= read -r name; do
        [ -n "$name" ] || continue
        if database_container_matches_engine "$name" "$engine"; then
            printf '%s\n' "$name"
        fi
    done < <(docker ps --format '{{.Names}}' 2>/dev/null)
}

detect_database_engine() {
    local container="$1"
    local engine

    for engine in mysql postgres mongodb redis; do
        if database_container_matches_engine "$container" "$engine"; then
            printf '%s\n' "$engine"
            return 0
        fi
    done

    printf 'unknown\n'
    return 1
}
