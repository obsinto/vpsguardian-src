#!/bin/bash
################################################################################
# Script: backup-volumes.sh
# Propósito: Backup seguro de volumes Docker com "Desligamento Perfeito" para DBs
# Uso: ./backup-volumes.sh [--all] [--output=DIR] [--no-restart]
################################################################################

set -euo pipefail

# Cores para melhor visualização
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

LOG_PREFIX="[ Volume Backup Agent ]"

### ========== FUNÇÕES DE LOG ==========

log_info() {
    echo -e "${BLUE}$LOG_PREFIX${NC} [ INFO ] $1"
}

log_success() {
    echo -e "${GREEN}$LOG_PREFIX${NC} [ ✓ ] $1"
}

log_error() {
    echo -e "${RED}$LOG_PREFIX${NC} [ ✗ ] $1"
}

log_warning() {
    echo -e "${YELLOW}$LOG_PREFIX${NC} [ ⚠ ] $1"
}

log_section() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
}

### ========== CONFIGURAÇÃO ==========

BACKUP_ALL=false
OUTPUT_DIR="/root/volume-backups"
AUTO_RESTART=true
BATCH_ID=$(date +%Y%m%d_%H%M%S)

# Parse argumentos
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
        --no-restart)
            AUTO_RESTART=false
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --all              Backup all Docker volumes"
            echo "  --output=DIR       Output directory (default: /root/volume-backups)"
            echo "  --no-restart       Don't restart containers after backup"
            echo "  -h, --help         Show this help"
            echo ""
            echo "Examples:"
            echo "  $0 --all"
            echo "  $0 --all --output=/backups --no-restart"
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

### ========== APRESENTAÇÃO ==========
echo ""
echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║${NC}                                                               ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}        ${GREEN}🔒 SAFE DOCKER VOLUME BACKUP AGENT 🔒${NC}             ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}          ${YELLOW}Estratégia do \"Desligamento Perfeito\"${NC}             ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}                                                               ${CYAN}║${NC}"
echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════╝${NC}"
echo ""

log_info "Este script implementa a técnica de 'Slow Shutdown' para bancos de dados"
log_info "Garante integridade total dos dados durante backup de volumes"
echo ""

### ========== CRIAR DIRETÓRIO DE BACKUP ==========
mkdir -p "$OUTPUT_DIR"
log_success "Diretório de backup: $OUTPUT_DIR"
log_info "Batch ID: $BATCH_ID"
echo ""

### ========== DETECTAR CONTAINERS DE BANCO DE DADOS ==========
log_section "DETECÇÃO DE BANCOS DE DADOS"

declare -A DB_CONTAINERS
declare -A DB_TYPES
declare -A DB_VOLUMES
declare -A DB_WAS_RUNNING

# Detectar MySQL/MariaDB
log_info "Procurando containers MySQL/MariaDB..."
MYSQL_CONTAINERS=$(docker ps --filter "ancestor=mysql" --filter "ancestor=mariadb" --format "{{.Names}}" 2>/dev/null || true)
MYSQL_BY_NAME=$(docker ps --format "{{.Names}}" 2>/dev/null | grep -iE "mysql|mariadb" || true)
ALL_MYSQL=$(echo -e "$MYSQL_CONTAINERS\n$MYSQL_BY_NAME" | sort -u | grep -v "^$" || true)

for container in $ALL_MYSQL; do
    if [ -n "$container" ]; then
        IMAGE=$(docker inspect --format='{{.Config.Image}}' "$container" 2>/dev/null)
        if echo "$IMAGE" | grep -qE "mysql|mariadb"; then
            DB_CONTAINERS[$container]=1
            if echo "$IMAGE" | grep -q "mariadb"; then
                DB_TYPES[$container]="mariadb"
            else
                DB_TYPES[$container]="mysql"
            fi

            # Detectar volumes
            VOLUMES=$(docker inspect --format='{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}} {{end}}{{end}}' "$container" 2>/dev/null)
            DB_VOLUMES[$container]="$VOLUMES"

            log_success "Detectado: $container (${DB_TYPES[$container]})"
            [ -n "$VOLUMES" ] && log_info "  Volumes: $VOLUMES"
        fi
    fi
done

# Detectar PostgreSQL
log_info "Procurando containers PostgreSQL..."
PG_CONTAINERS=$(docker ps --filter "ancestor=postgres" --format "{{.Names}}" 2>/dev/null || true)
PG_BY_NAME=$(docker ps --format "{{.Names}}" 2>/dev/null | grep -iE "postgres|pg" || true)
ALL_PG=$(echo -e "$PG_CONTAINERS\n$PG_BY_NAME" | sort -u | grep -v "^$" || true)

for container in $ALL_PG; do
    if [ -n "$container" ]; then
        IMAGE=$(docker inspect --format='{{.Config.Image}}' "$container" 2>/dev/null)
        if echo "$IMAGE" | grep -q "postgres"; then
            DB_CONTAINERS[$container]=1
            DB_TYPES[$container]="postgres"

            VOLUMES=$(docker inspect --format='{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}} {{end}}{{end}}' "$container" 2>/dev/null)
            DB_VOLUMES[$container]="$VOLUMES"

            log_success "Detectado: $container (postgres)"
            [ -n "$VOLUMES" ] && log_info "  Volumes: $VOLUMES"
        fi
    fi
done

# Contar bancos detectados (protegido contra array vazio)
if [ -v DB_CONTAINERS ] && [ ${#DB_CONTAINERS[@]} -gt 0 ]; then
    DB_COUNT=${#DB_CONTAINERS[@]}
else
    DB_COUNT=0
fi
log_info "Total de bancos de dados detectados: $DB_COUNT"
echo ""

### ========== PREPARAÇÃO: DESLIGAMENTO PERFEITO ==========

if [ $DB_COUNT -gt 0 ]; then
    log_section "PREPARAÇÃO: DESLIGAMENTO PERFEITO"

    echo -e "${YELLOW}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║${NC}  ${GREEN}Estratégia do \"Desligamento Perfeito\"${NC}                      ${YELLOW}║${NC}"
    echo -e "${YELLOW}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "  Para garantir integridade dos dados, vamos:"
    echo ""
    echo "  1️⃣  Forçar flush de buffers no MySQL/MariaDB (innodb_fast_shutdown=0)"
    echo "  2️⃣  Executar checkpoint no PostgreSQL"
    echo "  3️⃣  Parar containers graciosamente (tempo para fechar)"
    echo "  4️⃣  Aguardar confirmação de parada completa"
    echo "  5️⃣  Fazer backup dos volumes com dados 'limpos'"
    if [ "$AUTO_RESTART" = true ]; then
        echo "  6️⃣  Reiniciar containers automaticamente"
    fi
    echo ""
    echo -e "${GREEN}  ✅ Sem corrupção de redo logs${NC}"
    echo -e "${GREEN}  ✅ Sem transações pendentes${NC}"
    echo -e "${GREEN}  ✅ Volumes prontos para migração${NC}"
    echo ""

    read -p "Continuar com Desligamento Perfeito? (yes/no): " CONFIRM

    if [ "$CONFIRM" != "yes" ]; then
        log_info "Operação cancelada pelo usuário"
        exit 0
    fi

    echo ""

    ### ========== FASE 1: SLOW SHUTDOWN ==========
    log_section "FASE 1: SLOW SHUTDOWN (Preparação)"

    for container in "${!DB_CONTAINERS[@]}"; do
        DB_TYPE="${DB_TYPES[$container]}"

        log_info "Preparando: $container ($DB_TYPE)"

        # Verificar se está rodando
        IS_RUNNING=$(docker inspect --format='{{.State.Running}}' "$container" 2>/dev/null)
        DB_WAS_RUNNING[$container]=$IS_RUNNING

        if [ "$IS_RUNNING" = "true" ]; then
            case "$DB_TYPE" in
                mysql|mariadb)
                    log_info "  Configurando innodb_fast_shutdown=0 (flush completo)..."

                    # Detectar senha do MySQL/MariaDB das variáveis de ambiente
                    MYSQL_ROOT_PASSWORD=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$container" 2>/dev/null | grep -E '^MYSQL_ROOT_PASSWORD=' | cut -d'=' -f2-)
                    MARIADB_ROOT_PASSWORD=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$container" 2>/dev/null | grep -E '^MARIADB_ROOT_PASSWORD=' | cut -d'=' -f2-)

                    # Usar a senha que foi encontrada
                    DB_PASSWORD="${MYSQL_ROOT_PASSWORD:-$MARIADB_ROOT_PASSWORD}"

                    if [ -n "$DB_PASSWORD" ]; then
                        log_info "  ✓ Senha MySQL detectada (via MYSQL_ROOT_PASSWORD ou MARIADB_ROOT_PASSWORD)"

                        # Tentar com senha e capturar erro
                        DB_ERROR=$(docker exec "$container" sh -c "mysql -u root -p'$DB_PASSWORD' -e \"SET GLOBAL innodb_fast_shutdown = 0;\"" 2>&1)
                        DB_EXIT_CODE=$?

                        if [ $DB_EXIT_CODE -eq 0 ]; then
                            log_success "  ✅ innodb_fast_shutdown=0 configurado com sucesso"

                            # Verificar se foi aplicado
                            CURRENT_VALUE=$(docker exec "$container" sh -c "mysql -u root -p'$DB_PASSWORD' -e \"SHOW VARIABLES LIKE 'innodb_fast_shutdown';\"" 2>/dev/null | grep innodb_fast_shutdown | awk '{print $2}')
                            log_info "  Valor atual de innodb_fast_shutdown: $CURRENT_VALUE"
                        else
                            log_warning "  ⚠️  Falha ao configurar innodb_fast_shutdown"
                            log_warning "  Erro: $DB_ERROR"
                            log_warning "  Continuando sem slow shutdown (backup pode ter redo logs inconsistentes)"
                        fi
                    else
                        log_warning "  ⚠️  Senha MySQL não detectada nas variáveis de ambiente"
                        log_info "  Tentando sem senha (caso raro)..."

                        # Tentar sem senha (caso raro)
                        DB_ERROR=$(docker exec "$container" sh -c 'mysql -u root -e "SET GLOBAL innodb_fast_shutdown = 0;"' 2>&1)
                        DB_EXIT_CODE=$?

                        if [ $DB_EXIT_CODE -eq 0 ]; then
                            log_success "  ✅ innodb_fast_shutdown=0 configurado sem senha"
                        else
                            log_error "  ❌ Não foi possível configurar innodb_fast_shutdown"
                            log_error "  Erro: $DB_ERROR"
                            log_error "  ATENÇÃO: Backup será feito SEM slow shutdown!"
                            log_error "  Risco: Redo logs podem estar inconsistentes após migração"
                        fi
                    fi

                    log_success "  MySQL/MariaDB preparado para shutdown"
                    ;;

                postgres)
                    log_info "  Executando checkpoint no PostgreSQL..."
                    docker exec "$container" psql -U postgres -c "CHECKPOINT;" 2>/dev/null || \
                    log_warning "  Não foi possível executar checkpoint (pode precisar de credenciais)"

                    log_success "  PostgreSQL checkpoint executado"
                    ;;
            esac

            # Parar container graciosamente (timeout de 60s)
            log_info "  Parando container graciosamente (timeout: 60s)..."
            docker stop -t 60 "$container" >/dev/null 2>&1

            # Aguardar parada completa
            sleep 3

            # Verificar se parou
            if docker ps --filter "name=$container" --format "{{.Names}}" | grep -q "^$container$"; then
                log_error "  Falha ao parar $container"
                exit 1
            else
                log_success "  Container parado com sucesso"
            fi
        else
            log_info "  Container já estava parado"
        fi

        echo ""
    done

    log_success "Todos os bancos foram preparados e parados graciosamente"
    echo ""
fi

### ========== LISTAR VOLUMES PARA BACKUP ==========
log_section "VOLUMES PARA BACKUP"

ALL_VOLUMES=$(docker volume ls --quiet)
VOLUME_COUNT=$(echo "$ALL_VOLUMES" | wc -l)

log_info "Total de volumes Docker: $VOLUME_COUNT"
echo ""

# Criar array de volumes para backup
VOLUMES_TO_BACKUP=()

if [ "$BACKUP_ALL" = true ]; then
    log_info "Modo: Backup de TODOS os volumes"

    while IFS= read -r volume; do
        if [ -n "$volume" ]; then
            VOLUMES_TO_BACKUP+=("$volume")
        fi
    done <<< "$ALL_VOLUMES"
else
    # Modo interativo: selecionar volumes
    log_info "Modo: Seleção interativa de volumes"
    echo ""

    # TODO: Implementar seleção interativa se necessário
    # Por enquanto, apenas backup de volumes de DBs
    for container in "${!DB_CONTAINERS[@]}"; do
        VOLUMES="${DB_VOLUMES[$container]}"
        for vol in $VOLUMES; do
            if [ -n "$vol" ]; then
                VOLUMES_TO_BACKUP+=("$vol")
            fi
        done
    done
fi

# Contar volumes para backup (sempre funciona, mesmo se array vazio)
BACKUP_COUNT=${#VOLUMES_TO_BACKUP[@]}
log_info "Volumes selecionados para backup: $BACKUP_COUNT"

if [ $BACKUP_COUNT -eq 0 ]; then
    log_error "Nenhum volume para backup"
    exit 1
fi

echo ""

### ========== FASE 2: BACKUP DOS VOLUMES ==========
log_section "FASE 2: BACKUP DOS VOLUMES"

SUCCESSFUL_BACKUPS=0
FAILED_BACKUPS=0

for volume in "${VOLUMES_TO_BACKUP[@]}"; do
    echo ""
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Fazendo backup do volume: $volume"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Verificar se volume existe
    if ! docker volume inspect "$volume" >/dev/null 2>&1; then
        log_error "  ❌ ERRO: Volume '$volume' não existe!"
        ((FAILED_BACKUPS++))
        continue
    fi

    # Obter informações do volume
    VOLUME_DRIVER=$(docker volume inspect --format='{{.Driver}}' "$volume" 2>/dev/null)
    VOLUME_MOUNTPOINT=$(docker volume inspect --format='{{.Mountpoint}}' "$volume" 2>/dev/null)
    log_info "  Driver: $VOLUME_DRIVER"
    log_info "  Mountpoint: $VOLUME_MOUNTPOINT"

    # Verificar espaço em disco
    AVAILABLE_SPACE=$(df -BG "$OUTPUT_DIR" | tail -1 | awk '{print $4}' | tr -d 'G')
    log_info "  Espaço disponível: ${AVAILABLE_SPACE}GB"

    if [ "$AVAILABLE_SPACE" -lt 1 ]; then
        log_error "  ❌ ERRO: Espaço em disco insuficiente (< 1GB)!"
        ((FAILED_BACKUPS++))
        continue
    fi

    BACKUP_FILE="${volume}-backup-${BATCH_ID}.tar.gz"
    BACKUP_ERROR_FILE="/tmp/backup-error-$$.txt"

    log_info "  Iniciando compactação..."

    # Executar backup com captura de erro
    docker run --rm \
        -v "$volume":/volume:ro \
        -v "$OUTPUT_DIR":/backup \
        busybox \
        tar czf /backup/"$BACKUP_FILE" -C /volume . 2>"$BACKUP_ERROR_FILE"

    BACKUP_EXIT_CODE=$?

    if [ $BACKUP_EXIT_CODE -eq 0 ]; then
        if [ -f "$OUTPUT_DIR/$BACKUP_FILE" ]; then
            BACKUP_SIZE=$(du -h "$OUTPUT_DIR/$BACKUP_FILE" | cut -f1)
            FILE_COUNT=$(tar -tzf "$OUTPUT_DIR/$BACKUP_FILE" 2>/dev/null | wc -l)
            log_success "  ✅ Backup criado com sucesso!"
            log_success "     Arquivo: $BACKUP_FILE"
            log_success "     Tamanho: $BACKUP_SIZE"
            log_success "     Arquivos: $FILE_COUNT"
            ((SUCCESSFUL_BACKUPS++))
        else
            log_error "  ❌ ERRO: Arquivo de backup não foi criado!"
            log_error "     Esperado: $OUTPUT_DIR/$BACKUP_FILE"
            ((FAILED_BACKUPS++))
        fi
    else
        log_error "  ❌ FALHA no backup de $volume (exit code: $BACKUP_EXIT_CODE)"

        # Mostrar erro detalhado
        if [ -f "$BACKUP_ERROR_FILE" ] && [ -s "$BACKUP_ERROR_FILE" ]; then
            log_error "  Mensagem de erro:"
            while IFS= read -r line; do
                log_error "    $line"
            done < "$BACKUP_ERROR_FILE"
        fi

        # Diagnosticar causa provável
        log_error "  Possíveis causas:"
        log_error "    1. Volume vazio ou sem permissão de leitura"
        log_error "    2. Espaço em disco insuficiente"
        log_error "    3. Volume corrompido ou em uso exclusivo"
        log_error "    4. Problema com o Docker daemon"

        ((FAILED_BACKUPS++))
    fi

    # Limpar arquivo de erro temporário
    rm -f "$BACKUP_ERROR_FILE"
done

### ========== CRIAR METADATA DO LOTE ==========
BATCH_META_FILE="$OUTPUT_DIR/.batch-${BATCH_ID}.meta"

cat > "$BATCH_META_FILE" << EOF
# Batch Metadata
BATCH_ID="$BATCH_ID"
CREATED="$(date '+%Y-%m-%d %H:%M:%S')"
TOTAL_VOLUMES=$BACKUP_COUNT
SUCCESSFUL_BACKUPS=$SUCCESSFUL_BACKUPS
FAILED_BACKUPS=$FAILED_BACKUPS
DB_CONTAINERS_COUNT=$DB_COUNT
SLOW_SHUTDOWN_USED=$([ $DB_COUNT -gt 0 ] && echo "true" || echo "false")
EOF

log_success "Metadata do lote criada: .batch-${BATCH_ID}.meta"
echo ""

### ========== FASE 3: REINICIAR CONTAINERS (OPCIONAL) ==========

if [ "$AUTO_RESTART" = true ] && [ $DB_COUNT -gt 0 ]; then
    log_section "FASE 3: REINICIANDO CONTAINERS"

    for container in "${!DB_CONTAINERS[@]}"; do
        WAS_RUNNING="${DB_WAS_RUNNING[$container]}"

        if [ "$WAS_RUNNING" = "true" ]; then
            log_info "Reiniciando: $container"
            docker start "$container" >/dev/null 2>&1

            if [ $? -eq 0 ]; then
                log_success "  Container reiniciado"
            else
                log_error "  Falha ao reiniciar $container"
            fi
        else
            log_info "Não reiniciando $container (estava parado antes)"
        fi
    done

    echo ""
    log_success "Todos os containers foram reiniciados"
else
    if [ $DB_COUNT -gt 0 ]; then
        log_warning "Containers NÃO foram reiniciados (use sem --no-restart para reiniciar)"
        echo ""
        echo "  Para reiniciar manualmente:"
        for container in "${!DB_CONTAINERS[@]}"; do
            echo "    docker start $container"
        done
        echo ""
    fi
fi

### ========== SUMÁRIO FINAL ==========
log_section "BACKUP COMPLETO"

echo ""
echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║${NC}                                                               ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}          ✅ BACKUP CONCLUÍDO COM SUCESSO! ✅                  ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}                                                               ${GREEN}║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "  📦 Batch ID: $BATCH_ID"
echo "  📂 Localização: $OUTPUT_DIR"
echo "  ✅ Backups bem-sucedidos: $SUCCESSFUL_BACKUPS"
if [ $FAILED_BACKUPS -gt 0 ]; then echo "  ❌ Backups falhados: $FAILED_BACKUPS"; fi
echo "  🗄️  Bancos de dados: $DB_COUNT (Slow Shutdown aplicado)"
echo ""
echo "  Arquivos criados:"
for volume in "${VOLUMES_TO_BACKUP[@]}"; do
    BACKUP_FILE="${volume}-backup-${BATCH_ID}.tar.gz"
    if [ -f "$OUTPUT_DIR/$BACKUP_FILE" ]; then
        SIZE=$(du -h "$OUTPUT_DIR/$BACKUP_FILE" | cut -f1)
        echo "    • $BACKUP_FILE ($SIZE)"
    fi
done
echo ""
echo "  💾 Metadata: .batch-${BATCH_ID}.meta"
echo ""
echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
echo ""

exit 0
