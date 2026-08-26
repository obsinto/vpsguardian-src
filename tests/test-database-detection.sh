#!/bin/bash
################################################################################
# Regressão: aplicações que recebem credenciais de banco não podem ser
# classificadas como servidores de banco.
################################################################################

set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$TEST_DIR")"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/vpsguardian-database-detection.XXXXXX")
MOCK_BIN="$TMP_ROOT/bin"
MOCK_EXEC_LOG="$TMP_ROOT/docker-exec.log"
FAILURES=0

cleanup() { rm -rf "$TMP_ROOT"; }
trap cleanup EXIT

mkdir -p "$MOCK_BIN"
export MOCK_EXEC_LOG
cat > "$MOCK_BIN/docker" <<'EOF'
#!/bin/bash

if [ "${1:-}" = "ps" ]; then
    printf '%s\n' postgres-real postgres-custom web-false api-false redis-real mysql-real worker-false mongo-real
    exit 0
fi

if [ "${1:-}" = "inspect" ]; then
    format="${2:-}"
    container="${3:-}"
    case "$format" in
        *'.Config.Image'*'ExposedPorts'*'coolify.type'*)
            case "$container" in
                postgres-real) printf 'postgres:16-alpine|5432/tcp |\n' ;;
                postgres-custom) printf 'registry.invalid/custom-database:1|5432/tcp |\n' ;;
                web-false) printf 'example/web-app:1|80/tcp |\n' ;;
                api-false) printf 'example/api:1|8080/tcp |\n' ;;
                redis-real) printf 'redis:7-alpine|6379/tcp |\n' ;;
                mysql-real) printf 'mariadb:11|3306/tcp |\n' ;;
                worker-false) printf 'example/web-app:1|3000/tcp |\n' ;;
                mongo-real) printf 'mongo:7|27017/tcp |\n' ;;
            esac
            ;;
        *'.Config.Image'*)
            case "$container" in
                postgres-real) printf 'postgres:16-alpine\n' ;;
                postgres-custom) printf 'registry.invalid/custom-database:1\n' ;;
                web-false|worker-false) printf 'example/web-app:1\n' ;;
                api-false) printf 'example/api:1\n' ;;
                redis-real) printf 'redis:7-alpine\n' ;;
                mysql-real) printf 'mariadb:11\n' ;;
                mongo-real) printf 'mongo:7\n' ;;
            esac
            ;;
        *'ExposedPorts'*)
            case "$container" in
                postgres-real|postgres-custom) printf '5432/tcp ' ;;
                web-false) printf '80/tcp ' ;;
                api-false) printf '8080/tcp ' ;;
                redis-real) printf '6379/tcp ' ;;
                mysql-real) printf '3306/tcp ' ;;
                worker-false) printf '3000/tcp ' ;;
                mongo-real) printf '27017/tcp ' ;;
            esac
            ;;
        *'coolify.type'*) printf '\n' ;;
    esac
    exit 0
fi

if [ "${1:-}" = "exec" ]; then
    container="${2:-}"
    if [ "${3:-}" = "sh" ]; then
        if [ "${5:-}" = ":" ]; then
            printf 'shell|%s\n' "$container" >> "$MOCK_EXEC_LOG"
            exit 0
        fi
        tool="${7:-}"
        printf 'shell-command|%s|%s\n' "$container" "$tool" >> "$MOCK_EXEC_LOG"
    else
        tool="${3:-}"
        printf 'direct|%s|%s\n' "$container" "$tool" >> "$MOCK_EXEC_LOG"
    fi
    case "$container:$tool" in
        postgres-real:pg_dump|postgres-custom:pg_dump|redis-real:redis-server|mysql-real:mariadb-dump|mongo-real:mongodump)
            exit 0
            ;;
        *) exit 127 ;;
    esac
fi

exit 1
EOF
chmod +x "$MOCK_BIN/docker"

PATH="$MOCK_BIN:$PATH"
source "$ROOT/lib/database-detection.sh"

assert_output() {
    local expected="$1"
    local description="$2"
    shift 2
    local actual
    actual=$("$@")
    if [ "$actual" = "$expected" ]; then
        printf '  ✓ %s\n' "$description"
    else
        printf '  ✗ %s (esperado=%q obtido=%q)\n' "$description" "$expected" "$actual"
        FAILURES=$((FAILURES + 1))
    fi
}

assert_output $'postgres-real\npostgres-custom' "PostgreSQL real e customizado são detectados" \
    detect_database_containers_by_engine postgres
assert_output 'mysql-real' "MariaDB real é detectado" detect_database_containers_by_engine mysql
assert_output 'mongo-real' "MongoDB real é detectado" detect_database_containers_by_engine mongodb
assert_output 'redis-real' "Redis não é confundido com PostgreSQL" detect_database_containers_by_engine redis
assert_output 'unknown' "aplicação com POSTGRES_* não é banco" detect_database_engine web-false
assert_output 'unknown' "API com credenciais herdadas não é banco" detect_database_engine api-false
assert_output 'unknown' "worker com credenciais herdadas não é banco" detect_database_engine worker-false

if grep -q '^direct|' "$MOCK_EXEC_LOG" 2>/dev/null; then
    printf '  ✗ containers com shell receberam sondagem direta ruidosa\n'
    FAILURES=$((FAILURES + 1))
else
    printf '  ✓ ferramentas ausentes são sondadas silenciosamente via shell\n'
fi

printf '\nDatabase detection: %d falha(s)\n' "$FAILURES"
exit "$FAILURES"
