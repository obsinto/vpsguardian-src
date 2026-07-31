#!/bin/bash
################################################################################
# Detecção conservadora de engines de banco em containers Docker.
#
# Variáveis como POSTGRES_PASSWORD e MYSQL_ROOT_PASSWORD podem ser propagadas
# pelo Coolify para aplicações, workers e outros serviços do mesmo compose.
# Portanto, variáveis de ambiente não são evidência suficiente de que o
# container executa um servidor de banco.
################################################################################

database_container_has_tool() {
    local container="$1"
    local engine="$2"

    case "$engine" in
        mysql)
            docker exec "$container" mariadb-dump --version >/dev/null 2>&1 ||
                docker exec "$container" mysqldump --version >/dev/null 2>&1
            ;;
        postgres)
            docker exec "$container" pg_dump --version >/dev/null 2>&1
            ;;
        mongodb)
            docker exec "$container" mongodump --version >/dev/null 2>&1
            ;;
        redis)
            docker exec "$container" redis-server --version >/dev/null 2>&1
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
