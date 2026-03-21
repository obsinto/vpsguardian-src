#!/bin/bash
################################################################################
# Script: backup-volumes.sh
# Propósito: Backup unificado de volumes Docker com estratégias inteligentes
# Uso: ./backup-volumes.sh [--all] [--output=DIR] [--auto] [--strategy=MODE]
#
# Estratégias:
#   slow-shutdown  - Para containers antes do backup (mais seguro, causa downtime)
#   double-check   - Dump SQL + Snapshot sem parar (para cron, sem downtime)
#
# Versão: 3.0.0 - Unificado (backup-volumes.sh + backup-database-volumes.sh)
################################################################################

# Carregar bibliotecas compartilhadas
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh" 2>/dev/null || {
    # Fallback se bibliotecas não estiverem disponíveis
    log_info() { echo "[ INFO ] $*"; }
    log_success() { echo "[ OK ] $*"; }
    log_error() { echo "[ ERRO ] $*"; }
    log_warning() { echo "[ AVISO ] $*"; }
    log_section() { echo ""; echo "========== $* =========="; echo ""; }
}

# Carregar notificações se disponível
source "$SCRIPT_DIR/../lib/notificacoes.sh" 2>/dev/null || true

# Carregar biblioteca de retenção se disponível
source "$SCRIPT_DIR/../lib/backup-retention.sh" 2>/dev/null || true

### ========== CONFIGURAÇÃO ==========
BACKUP_ALL=false
OUTPUT_DIR="${BACKUP_OUTPUT_DIR:-/var/backups/vpsguardian/volumes}"
AUTO_MODE=false
AUTO_RESTART=true
STRATEGY="double-check"  # Padrão: double-check (mais moderno)
BATCH_ID=$(date +%Y%m%d_%H%M%S)
DRY_RUN=false

### ========== PARSE ARGUMENTOS ==========
while [[ $# -gt 0 ]]; do
    case $1 in
        --all)
            BACKUP_ALL=true
            shift
            ;;
        --output=*)
            OUTPUT_DIR="${1#*=}"
            shift
            ;;
        --output)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --auto|--cron)
            AUTO_MODE=true
            shift
            ;;
        --no-restart)
            AUTO_RESTART=false
            shift
            ;;
        --strategy=*)
            STRATEGY="${1#*=}"
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            cat << 'EOF'
BACKUP DE VOLUMES DOCKER - VPS Guardian

USO:
  ./backup-volumes.sh [OPÇÕES]

OPÇÕES:
  --all                  Backup de TODOS os volumes Docker
  --output=DIR           Diretório de saída (padrão: /var/backups/vpsguardian/volumes)
  --auto, --cron         Modo automático sem confirmações (para cron)
  --no-restart           Não reiniciar containers após backup (só slow-shutdown)
  --strategy=MODE        Estratégia de backup:
                           slow-shutdown  Para containers antes (mais seguro)
                           double-check   Dump SQL + Snapshot (padrão, sem downtime)
  --dry-run              Simular sem executar
  -h, --help             Mostrar esta ajuda

ESTRATÉGIAS:

  slow-shutdown (recomendado para migração):
    1. Configura innodb_fast_shutdown=0 (MySQL/MariaDB)
    2. Executa CHECKPOINT (PostgreSQL)
    3. Para containers graciosamente
    4. Faz backup dos volumes
    5. Reinicia containers (opcional)

    Vantagem: Dados 100% consistentes
    Desvantagem: Downtime durante backup

  double-check (recomendado para cron):
    1. Faz dump SQL (MySQL, PostgreSQL, MongoDB)
    2. Faz snapshot do volume (sem parar container)
    3. Mantém ambos como redundância

    Vantagem: Sem downtime
    Desvantagem: Snapshot pode ter transações pendentes

EXEMPLOS:
  # Backup interativo de todos os volumes (slow-shutdown)
  ./backup-volumes.sh --all --strategy=slow-shutdown

  # Backup automático para cron (double-check)
  ./backup-volumes.sh --all --auto

  # Backup sem reiniciar containers
  ./backup-volumes.sh --all --strategy=slow-shutdown --no-restart

  # Backup em diretório específico
  ./backup-volumes.sh --all --output=/mnt/backups

EOF
            exit 0
            ;;
        *)
            log_error "Opção desconhecida: $1"
            log_info "Use --help para ver as opções disponíveis"
            exit 2
            ;;
    esac
done

# Validar estratégia
if [[ ! "$STRATEGY" =~ ^(slow-shutdown|double-check)$ ]]; then
    log_error "Estratégia inválida: $STRATEGY"
    log_info "Use: slow-shutdown ou double-check"
    exit 2
fi

### ========== ARRAYS E VARIÁVEIS GLOBAIS ==========
declare -A DB_CONTAINERS
declare -A DB_TYPES
declare -A DB_VOLUMES
declare -A DB_WAS_RUNNING
declare -A DB_CREDENTIALS

SUCCESSFUL_BACKUPS=0
FAILED_BACKUPS=0

### ========== FUNÇÕES DE DETECÇÃO ==========

# Detecta tipo de banco de dados por imagem Docker
detect_database_type() {
    local container_id="$1"
    local image=$(docker inspect --format='{{.Config.Image}}' "$container_id" 2>/dev/null)

    if [[ "$image" =~ mysql|mariadb ]]; then
        echo "mysql"
    elif [[ "$image" =~ postgres|postgresql ]]; then
        echo "postgres"
    elif [[ "$image" =~ mongo ]]; then
        echo "mongodb"
    elif [[ "$image" =~ redis ]]; then
        echo "redis"
    else
        echo "unknown"
    fi
}

# Obtém credenciais de banco de dados de variáveis de ambiente
get_db_credentials() {
    local container_id="$1"
    local db_type="$2"

    local env_vars=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$container_id" 2>/dev/null)

    case "$db_type" in
        mysql)
            local root_pass=$(echo "$env_vars" | grep -E '^(MYSQL_ROOT_PASSWORD|MARIADB_ROOT_PASSWORD)=' | head -1 | cut -d'=' -f2-)
            local db_name=$(echo "$env_vars" | grep -E '^MYSQL_DATABASE=' | cut -d'=' -f2)
            echo "root:${root_pass}:${db_name:-all}"
            ;;
        postgres)
            local pg_pass=$(echo "$env_vars" | grep -E '^POSTGRES_PASSWORD=' | cut -d'=' -f2)
            local pg_user=$(echo "$env_vars" | grep -E '^POSTGRES_USER=' | cut -d'=' -f2)
            local pg_db=$(echo "$env_vars" | grep -E '^POSTGRES_DB=' | cut -d'=' -f2)
            echo "${pg_user:-postgres}:${pg_pass}:${pg_db:-postgres}"
            ;;
        mongodb)
            local mongo_pass=$(echo "$env_vars" | grep -E '^MONGO_INITDB_ROOT_PASSWORD=' | cut -d'=' -f2)
            local mongo_user=$(echo "$env_vars" | grep -E '^MONGO_INITDB_ROOT_USERNAME=' | cut -d'=' -f2)
            echo "${mongo_user:-root}:${mongo_pass}:admin"
            ;;
        *)
            echo ":::"
            ;;
    esac
}

# Verifica se container está rodando
is_container_running() {
    local container_id="$1"
    local state=$(docker inspect --format='{{.State.Status}}' "$container_id" 2>/dev/null)
    [ "$state" = "running" ]
}

# Lista containers que usam um volume
get_containers_using_volume() {
    local volume_name="$1"
    docker ps -a --filter "volume=${volume_name}" --format '{{.ID}}:{{.Names}}:{{.State}}' 2>/dev/null
}

### ========== FUNÇÕES DE DUMP SQL ==========

dump_mysql() {
    local container_id="$1"
    local output_file="$2"
    local credentials="$3"

    local user=$(echo "$credentials" | cut -d':' -f1)
    local password=$(echo "$credentials" | cut -d':' -f2)
    local database=$(echo "$credentials" | cut -d':' -f3)

    log_info "  Executando mysqldump..."

    local dump_opts="--single-transaction --quick --lock-tables=false"

    if [ "$database" = "all" ]; then
        docker exec "$container_id" mysqldump -u "$user" -p"$password" --all-databases $dump_opts > "$output_file" 2>/dev/null
    else
        docker exec "$container_id" mysqldump -u "$user" -p"$password" $dump_opts "$database" > "$output_file" 2>/dev/null
    fi
}

dump_postgres() {
    local container_id="$1"
    local output_file="$2"
    local credentials="$3"

    local user=$(echo "$credentials" | cut -d':' -f1)
    local password=$(echo "$credentials" | cut -d':' -f2)
    local database=$(echo "$credentials" | cut -d':' -f3)

    log_info "  Executando pg_dump..."

    docker exec -e PGPASSWORD="$password" "$container_id" pg_dump \
        -U "$user" -d "$database" --clean --if-exists > "$output_file" 2>/dev/null
}

dump_mongodb() {
    local container_id="$1"
    local output_dir="$2"
    local credentials="$3"

    local user=$(echo "$credentials" | cut -d':' -f1)
    local password=$(echo "$credentials" | cut -d':' -f2)

    log_info "  Executando mongodump..."

    mkdir -p "$output_dir"

    docker exec "$container_id" mongodump \
        --username="$user" --password="$password" \
        --authenticationDatabase=admin --out=/tmp/mongodump >/dev/null 2>&1

    if [ $? -eq 0 ]; then
        docker cp "$container_id:/tmp/mongodump/." "$output_dir/" >/dev/null 2>&1
        docker exec "$container_id" rm -rf /tmp/mongodump >/dev/null 2>&1
        return 0
    fi
    return 1
}

### ========== FUNÇÕES DE BACKUP ==========

# Detectar todos os bancos de dados
detect_databases() {
    log_section "Detectando Bancos de Dados"

    # MySQL/MariaDB
    log_info "Procurando MySQL/MariaDB..."
    local mysql_containers=$(docker ps --format "{{.Names}}" 2>/dev/null | while read name; do
        local image=$(docker inspect --format='{{.Config.Image}}' "$name" 2>/dev/null)
        if [[ "$image" =~ mysql|mariadb ]]; then
            echo "$name"
        fi
    done)

    for container in $mysql_containers; do
        if [ -n "$container" ]; then
            DB_CONTAINERS[$container]=1
            local image=$(docker inspect --format='{{.Config.Image}}' "$container" 2>/dev/null)
            if [[ "$image" =~ mariadb ]]; then
                DB_TYPES[$container]="mariadb"
            else
                DB_TYPES[$container]="mysql"
            fi
            DB_VOLUMES[$container]=$(docker inspect --format='{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}} {{end}}{{end}}' "$container" 2>/dev/null)
            DB_CREDENTIALS[$container]=$(get_db_credentials "$container" "mysql")
            log_success "Detectado: $container (${DB_TYPES[$container]})"
        fi
    done

    # PostgreSQL
    log_info "Procurando PostgreSQL..."
    local pg_containers=$(docker ps --format "{{.Names}}" 2>/dev/null | while read name; do
        local image=$(docker inspect --format='{{.Config.Image}}' "$name" 2>/dev/null)
        if [[ "$image" =~ postgres ]]; then
            echo "$name"
        fi
    done)

    for container in $pg_containers; do
        if [ -n "$container" ]; then
            DB_CONTAINERS[$container]=1
            DB_TYPES[$container]="postgres"
            DB_VOLUMES[$container]=$(docker inspect --format='{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}} {{end}}{{end}}' "$container" 2>/dev/null)
            DB_CREDENTIALS[$container]=$(get_db_credentials "$container" "postgres")
            log_success "Detectado: $container (postgres)"
        fi
    done

    # MongoDB
    log_info "Procurando MongoDB..."
    local mongo_containers=$(docker ps --format "{{.Names}}" 2>/dev/null | while read name; do
        local image=$(docker inspect --format='{{.Config.Image}}' "$name" 2>/dev/null)
        if [[ "$image" =~ mongo ]]; then
            echo "$name"
        fi
    done)

    for container in $mongo_containers; do
        if [ -n "$container" ]; then
            DB_CONTAINERS[$container]=1
            DB_TYPES[$container]="mongodb"
            DB_VOLUMES[$container]=$(docker inspect --format='{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}} {{end}}{{end}}' "$container" 2>/dev/null)
            DB_CREDENTIALS[$container]=$(get_db_credentials "$container" "mongodb")
            log_success "Detectado: $container (mongodb)"
        fi
    done

    # Redis
    log_info "Procurando Redis..."
    local redis_containers=$(docker ps --format "{{.Names}}" 2>/dev/null | while read name; do
        local image=$(docker inspect --format='{{.Config.Image}}' "$name" 2>/dev/null)
        if [[ "$image" =~ redis ]]; then
            echo "$name"
        fi
    done)

    for container in $redis_containers; do
        if [ -n "$container" ]; then
            DB_CONTAINERS[$container]=1
            DB_TYPES[$container]="redis"
            DB_VOLUMES[$container]=$(docker inspect --format='{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}} {{end}}{{end}}' "$container" 2>/dev/null)
            log_success "Detectado: $container (redis)"
        fi
    done

    local db_count=${#DB_CONTAINERS[@]}
    log_info "Total de bancos detectados: $db_count"
}

# Estratégia Slow Shutdown
strategy_slow_shutdown() {
    local container="$1"
    local db_type="${DB_TYPES[$container]}"

    log_info "Preparando slow shutdown: $container ($db_type)"

    # Verificar se está rodando
    if ! is_container_running "$container"; then
        log_info "  Container já estava parado"
        DB_WAS_RUNNING[$container]="false"
        return 0
    fi

    DB_WAS_RUNNING[$container]="true"

    case "$db_type" in
        mysql|mariadb)
            log_info "  Configurando innodb_fast_shutdown=0..."
            local creds="${DB_CREDENTIALS[$container]}"
            local password=$(echo "$creds" | cut -d':' -f2)

            if [ -n "$password" ]; then
                docker exec "$container" mysql -u root -p"$password" \
                    -e "SET GLOBAL innodb_fast_shutdown = 0;" 2>/dev/null
                if [ $? -eq 0 ]; then
                    log_success "  innodb_fast_shutdown=0 configurado"
                else
                    log_warning "  Falha ao configurar innodb_fast_shutdown"
                fi
            fi
            ;;
        postgres)
            log_info "  Executando CHECKPOINT..."
            docker exec "$container" psql -U postgres -c "CHECKPOINT;" 2>/dev/null || \
                log_warning "  Falha ao executar checkpoint"
            log_success "  PostgreSQL checkpoint executado"
            ;;
        redis)
            log_info "  Executando BGSAVE..."
            docker exec "$container" redis-cli BGSAVE 2>/dev/null || true
            sleep 2
            ;;
    esac

    # Parar container graciosamente
    log_info "  Parando container (timeout: 60s)..."
    docker stop -t 60 "$container" >/dev/null 2>&1

    if ! docker ps --filter "name=^${container}$" --format "{{.Names}}" | grep -q "^${container}$"; then
        log_success "  Container parado com sucesso"
    else
        log_error "  Falha ao parar container"
        return 1
    fi
}

# Backup de volume individual
backup_volume() {
    local volume_name="$1"
    local is_database="$2"
    local db_type="$3"
    local container_id="$4"

    log_info "Backup: $volume_name"

    # Verificar se volume existe
    if ! docker volume inspect "$volume_name" >/dev/null 2>&1; then
        log_error "  Volume não existe: $volume_name"
        return 1
    fi

    if [ "$DRY_RUN" = true ]; then
        log_info "  [DRY-RUN] Simulando backup..."
        return 0
    fi

    local dump_success=false
    local volume_success=false

    # Double-Check: Dump SQL primeiro (se aplicável)
    if [ "$STRATEGY" = "double-check" ] && [ "$is_database" = true ] && [ -n "$container_id" ]; then
        if is_container_running "$container_id"; then
            local credentials="${DB_CREDENTIALS[$container_id]}"
            local dump_file="$OUTPUT_DIR/${volume_name}-dump-${BATCH_ID}.sql"

            case "$db_type" in
                mysql|mariadb)
                    if dump_mysql "$container_id" "$dump_file" "$credentials"; then
                        dump_success=true
                        local size=$(du -h "$dump_file" 2>/dev/null | cut -f1)
                        log_success "  Dump SQL: $size"
                    fi
                    ;;
                postgres)
                    if dump_postgres "$container_id" "$dump_file" "$credentials"; then
                        dump_success=true
                        local size=$(du -h "$dump_file" 2>/dev/null | cut -f1)
                        log_success "  Dump SQL: $size"
                    fi
                    ;;
                mongodb)
                    local mongo_dir="$OUTPUT_DIR/${volume_name}-mongodump-${BATCH_ID}"
                    if dump_mongodb "$container_id" "$mongo_dir" "$credentials"; then
                        tar -czf "$OUTPUT_DIR/${volume_name}-mongodump-${BATCH_ID}.tar.gz" \
                            -C "$OUTPUT_DIR" "$(basename "$mongo_dir")" 2>/dev/null
                        rm -rf "$mongo_dir"
                        dump_success=true
                        log_success "  MongoDB dump criado"
                    fi
                    ;;
            esac

            if [ "$dump_success" = false ]; then
                log_warning "  Dump SQL falhou (continuando com snapshot)"
            fi
        fi
    fi

    # Pausar Redis temporariamente (double-check)
    local paused=false
    if [ "$STRATEGY" = "double-check" ] && [ "$db_type" = "redis" ] && [ -n "$container_id" ]; then
        if is_container_running "$container_id"; then
            docker pause "$container_id" >/dev/null 2>&1 && paused=true
        fi
    fi

    # Snapshot do volume
    local backup_file="${volume_name}-backup-${BATCH_ID}.tar.gz"
    log_info "  Criando snapshot..."

    docker run --rm \
        -v "$volume_name":/source:ro \
        -v "$OUTPUT_DIR":/backup \
        busybox tar -czf "/backup/${backup_file}" -C /source . 2>/dev/null

    if [ $? -eq 0 ] && [ -f "$OUTPUT_DIR/$backup_file" ]; then
        volume_success=true
        local size=$(du -h "$OUTPUT_DIR/$backup_file" | cut -f1)
        log_success "  Snapshot: $size"
    else
        log_error "  Falha no snapshot"
    fi

    # Despausar Redis
    if [ "$paused" = true ]; then
        docker unpause "$container_id" >/dev/null 2>&1
    fi

    # Criar metadata
    cat > "$OUTPUT_DIR/${volume_name}-backup-${BATCH_ID}.meta" <<EOF
VOLUME_NAME=$volume_name
BATCH_ID=$BATCH_ID
BACKUP_DATE=$(date '+%Y-%m-%d %H:%M:%S')
STRATEGY=$STRATEGY
IS_DATABASE=$is_database
DB_TYPE=$db_type
CONTAINER_ID=$container_id
DUMP_SUCCESS=$dump_success
VOLUME_SUCCESS=$volume_success
HOSTNAME=$(hostname)
EOF

    # Determinar sucesso
    if [ "$volume_success" = true ]; then
        return 0
    else
        return 1
    fi
}

# Reiniciar containers (slow-shutdown)
restart_containers() {
    if [ "$AUTO_RESTART" = false ]; then
        log_warning "Containers NÃO foram reiniciados (--no-restart)"
        return
    fi

    log_section "Reiniciando Containers"

    for container in "${!DB_CONTAINERS[@]}"; do
        if [ "${DB_WAS_RUNNING[$container]}" = "true" ]; then
            log_info "Reiniciando: $container"
            docker start "$container" >/dev/null 2>&1
            if [ $? -eq 0 ]; then
                log_success "  Container reiniciado"
            else
                log_error "  Falha ao reiniciar"
            fi
        fi
    done
}

### ========== MAIN ==========

# Banner
if [ "$AUTO_MODE" = false ]; then
    echo ""
    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║       VPS Guardian - Backup Inteligente de Volumes            ║"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo ""
fi

log_section "Iniciando Backup de Volumes"
log_info "Batch ID: $BATCH_ID"
log_info "Estratégia: $STRATEGY"
log_info "Modo: $([ "$AUTO_MODE" = true ] && echo "Automático" || echo "Interativo")"
log_info "Diretório: $OUTPUT_DIR"

# Criar diretório de saída
mkdir -p "$OUTPUT_DIR"

# Detectar bancos de dados
detect_databases

# Listar volumes para backup
log_section "Volumes para Backup"

if [ "$BACKUP_ALL" = true ]; then
    VOLUMES_TO_BACKUP=($(docker volume ls -q))
    log_info "Modo: Todos os volumes (${#VOLUMES_TO_BACKUP[@]})"
else
    # Apenas volumes de bancos de dados
    VOLUMES_TO_BACKUP=()
    for container in "${!DB_CONTAINERS[@]}"; do
        for vol in ${DB_VOLUMES[$container]}; do
            if [ -n "$vol" ]; then
                VOLUMES_TO_BACKUP+=("$vol")
            fi
        done
    done
    log_info "Modo: Volumes de bancos de dados (${#VOLUMES_TO_BACKUP[@]})"
fi

if [ ${#VOLUMES_TO_BACKUP[@]} -eq 0 ]; then
    log_warning "Nenhum volume para backup"
    exit 0
fi

# Confirmação (modo interativo)
if [ "$AUTO_MODE" = false ] && [ "$STRATEGY" = "slow-shutdown" ]; then
    echo ""
    log_warning "ATENÇÃO: Estratégia slow-shutdown irá PARAR os containers!"
    echo ""
    echo "  O que vai acontecer:"
    echo "  1. Flush de buffers (MySQL/MariaDB)"
    echo "  2. Checkpoint (PostgreSQL)"
    echo "  3. Containers serão PARADOS"
    echo "  4. Backup dos volumes"
    if [ "$AUTO_RESTART" = true ]; then
        echo "  5. Containers serão reiniciados"
    fi
    echo ""
    read -p "Continuar? (yes/no): " CONFIRM
    if [ "$CONFIRM" != "yes" ]; then
        log_info "Operação cancelada"
        exit 0
    fi
fi

# Executar slow shutdown se necessário
if [ "$STRATEGY" = "slow-shutdown" ]; then
    log_section "Fase 1: Slow Shutdown"
    for container in "${!DB_CONTAINERS[@]}"; do
        strategy_slow_shutdown "$container"
    done
fi

# Backup dos volumes
log_section "Fase 2: Backup dos Volumes"

for volume in "${VOLUMES_TO_BACKUP[@]}"; do
    # Detectar se é volume de banco de dados
    is_db=false
    db_type=""
    container_id=""

    for container in "${!DB_CONTAINERS[@]}"; do
        if [[ " ${DB_VOLUMES[$container]} " =~ " $volume " ]]; then
            is_db=true
            db_type="${DB_TYPES[$container]}"
            container_id="$container"
            break
        fi
    done

    if backup_volume "$volume" "$is_db" "$db_type" "$container_id"; then
        ((SUCCESSFUL_BACKUPS++))
    else
        ((FAILED_BACKUPS++))
    fi
    echo ""
done

# Reiniciar containers (slow-shutdown)
if [ "$STRATEGY" = "slow-shutdown" ] && [ ${#DB_CONTAINERS[@]} -gt 0 ]; then
    restart_containers
fi

# Aplicar retenção
if type apply_retention &>/dev/null 2>&1; then
    log_section "Aplicando Política de Retenção"
    local antes=$(find "$OUTPUT_DIR" -name "*-backup-*.tar.gz" 2>/dev/null | wc -l)
    apply_retention "$OUTPUT_DIR" "${BACKUP_RETENTION_STRATEGY:-gfs}" true 2>/dev/null || true
    local depois=$(find "$OUTPUT_DIR" -name "*-backup-*.tar.gz" 2>/dev/null | wc -l)
    local removidos=$((antes - depois))
    if [ "$removidos" -gt 0 ]; then
        log_success "$removidos backups antigos removidos"
    fi
fi

# Criar metadata do batch
cat > "$OUTPUT_DIR/.batch-${BATCH_ID}.meta" <<EOF
BATCH_ID=$BATCH_ID
CREATED=$(date '+%Y-%m-%d %H:%M:%S')
STRATEGY=$STRATEGY
TOTAL_VOLUMES=${#VOLUMES_TO_BACKUP[@]}
SUCCESSFUL_BACKUPS=$SUCCESSFUL_BACKUPS
FAILED_BACKUPS=$FAILED_BACKUPS
HOSTNAME=$(hostname)
DOCKER_VERSION=$(docker --version 2>/dev/null | head -1)
EOF

# Resumo final
log_section "Backup Concluído"
echo ""
echo "  Batch ID: $BATCH_ID"
echo "  Estratégia: $STRATEGY"
echo "  Sucesso: $SUCCESSFUL_BACKUPS volumes"
if [ $FAILED_BACKUPS -gt 0 ]; then
    echo "  Falha: $FAILED_BACKUPS volumes"
fi
echo "  Diretório: $OUTPUT_DIR"
echo ""

# Notificação
if [ $FAILED_BACKUPS -eq 0 ]; then
    notify_backup_success "Volumes" "$(du -sh "$OUTPUT_DIR" 2>/dev/null | cut -f1)" "$SUCCESSFUL_BACKUPS volumes" 2>/dev/null || true
else
    notify_backup_error "Volumes" "$FAILED_BACKUPS volumes falharam" 2>/dev/null || true
fi

# Exit code
if [ $FAILED_BACKUPS -gt 0 ]; then
    exit 1
else
    exit 0
fi
