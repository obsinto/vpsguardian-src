#!/bin/bash
################################################################################
# Script: fix-mysql-redo-log.sh
# Propósito: Corrigir erro de redo log corrompido no MySQL/MariaDB
# Uso: ./fix-mysql-redo-log.sh [container_name]
################################################################################

# Cores para melhor visualização
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

LOG_PREFIX="[ MySQL Fix Agent ]"

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

### ========== APRESENTAÇÃO ==========
echo ""
echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║${NC}                                                               ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}          ${GREEN}🔧 MySQL Redo Log Corruption Fix 🔧${NC}             ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}                                                               ${CYAN}║${NC}"
echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════╝${NC}"
echo ""

log_info "Este script corrige o erro:"
echo ""
echo "  ${RED}[ERROR] [MY-013879] [InnoDB] The redo log file comes from other data directory${NC}"
echo "  ${RED}[ERROR] [MY-012930] [InnoDB] Plugin initialization aborted${NC}"
echo "  ${RED}[ERROR] [MY-010334] [Server] Failed to initialize DD Storage Engine${NC}"
echo ""

### ========== DETECTAR OU SOLICITAR CONTAINER ==========

CONTAINER_NAME="$1"

if [ -z "$CONTAINER_NAME" ]; then
    log_section "DETECT MYSQL/MARIADB CONTAINERS"

    # Listar containers MySQL/MariaDB
    echo "Detectando containers MySQL/MariaDB..."
    echo ""

    MYSQL_CONTAINERS=$(docker ps -a --filter "ancestor=mysql" --filter "ancestor=mariadb" --format "{{.Names}}" 2>/dev/null)

    # Adicionar containers que tenham mysql ou mariadb no nome
    MYSQL_BY_NAME=$(docker ps -a --format "{{.Names}}" 2>/dev/null | grep -i -E "mysql|mariadb|db")

    # Combinar e remover duplicatas
    ALL_CONTAINERS=$(echo -e "$MYSQL_CONTAINERS\n$MYSQL_BY_NAME" | sort -u | grep -v "^$")

    if [ -z "$ALL_CONTAINERS" ]; then
        log_error "Nenhum container MySQL/MariaDB encontrado"
        echo ""
        echo "  Execute: docker ps -a"
        echo "  E forneça o nome do container como argumento:"
        echo "  $0 <container_name>"
        echo ""
        exit 1
    fi

    # Mostrar lista de containers
    echo "Containers detectados:"
    echo ""

    CONTAINER_ARRAY=()
    INDEX=0

    while IFS= read -r container; do
        if [ -n "$container" ]; then
            STATUS=$(docker inspect --format='{{.State.Status}}' "$container" 2>/dev/null)
            IMAGE=$(docker inspect --format='{{.Config.Image}}' "$container" 2>/dev/null)

            echo "  [$INDEX] $container"
            echo "      Status: $STATUS"
            echo "      Image: $IMAGE"

            # Verificar se tem erro de redo log
            if docker logs "$container" 2>&1 | grep -q "redo log file.*comes from other data directory"; then
                echo -e "      ${RED}⚠️  ERRO DE REDO LOG DETECTADO!${NC}"
            fi

            echo ""

            CONTAINER_ARRAY+=("$container")
            INDEX=$((INDEX + 1))
        fi
    done <<< "$ALL_CONTAINERS"

    # Solicitar seleção
    read -p "Selecione o container (0-$((INDEX-1))): " SELECTION

    if ! [[ "$SELECTION" =~ ^[0-9]+$ ]] || [ "$SELECTION" -ge "$INDEX" ]; then
        log_error "Seleção inválida"
        exit 1
    fi

    CONTAINER_NAME="${CONTAINER_ARRAY[$SELECTION]}"
fi

log_section "CONTAINER SELECTED"
log_success "Container: $CONTAINER_NAME"
echo ""

# Verificar se container existe
if ! docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
    log_error "Container '$CONTAINER_NAME' não encontrado"
    exit 1
fi

# Verificar se é MySQL ou MariaDB
IMAGE=$(docker inspect --format='{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null)
log_info "Image: $IMAGE"

if ! echo "$IMAGE" | grep -q -E "mysql|mariadb"; then
    log_warning "Container não parece ser MySQL/MariaDB"
    echo ""
    read -p "Deseja continuar mesmo assim? (s/N): " CONTINUE
    if [[ ! "$CONTINUE" =~ ^[Ss]$ ]]; then
        log_info "Cancelado pelo usuário"
        exit 0
    fi
fi

### ========== CONFIRMAR AÇÃO ==========
echo ""
log_section "CONFIRMATION"
echo ""
echo "  ${YELLOW}⚠️  ATENÇÃO: Esta operação irá:${NC}"
echo ""
echo "  1. Parar o container: $CONTAINER_NAME"
echo "  2. Remover arquivos de redo log corrompidos (#innodb_redo/)"
echo "  3. Remover arquivos temporários do InnoDB"
echo "  4. Reiniciar o container"
echo ""
echo "  ${GREEN}✅ O MySQL irá recriar os redo logs automaticamente${NC}"
echo "  ${GREEN}✅ Os dados do banco NÃO serão perdidos${NC}"
echo ""

read -p "Deseja continuar? (yes/no): " CONFIRM

if [ "$CONFIRM" != "yes" ]; then
    log_info "Operação cancelada pelo usuário"
    exit 0
fi

### ========== PARAR CONTAINER ==========
log_section "STOP CONTAINER"

CONTAINER_STATUS=$(docker inspect --format='{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null)
log_info "Status atual: $CONTAINER_STATUS"

if [ "$CONTAINER_STATUS" = "running" ]; then
    log_info "Parando container..."
    docker stop "$CONTAINER_NAME" >/dev/null 2>&1

    if [ $? -eq 0 ]; then
        log_success "Container parado com sucesso"
    else
        log_error "Falha ao parar container"
        exit 1
    fi
else
    log_info "Container já está parado"
fi

### ========== LIMPAR REDO LOGS ==========
log_section "CLEAN CORRUPTED REDO LOGS"

# Detectar volume do MySQL
VOLUME_NAME=$(docker inspect --format='{{range .Mounts}}{{if eq .Destination "/var/lib/mysql"}}{{.Name}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)

if [ -z "$VOLUME_NAME" ]; then
    log_warning "Volume Docker não detectado, tentando bind mount..."
    VOLUME_PATH=$(docker inspect --format='{{range .Mounts}}{{if eq .Destination "/var/lib/mysql"}}{{.Source}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)

    if [ -n "$VOLUME_PATH" ]; then
        log_info "Bind mount detectado: $VOLUME_PATH"

        log_info "Removendo redo logs corrompidos..."
        # Escapar # corretamente para evitar problemas de interpretação do shell
        rm -rf "${VOLUME_PATH}/#innodb_redo" 2>/dev/null
        rm -f "${VOLUME_PATH}"/ib_logfile* 2>/dev/null
        rm -f "${VOLUME_PATH}"/'#ib_'* 2>/dev/null

        log_success "Redo logs removidos do bind mount"
    else
        log_error "Não foi possível detectar volume ou bind mount"
        log_warning "Tentando método alternativo..."

        # Método alternativo: usar docker run com volume do container
        log_info "Usando container temporário para limpar redo logs..."
        docker run --rm -v "$(docker inspect --format='{{range .Mounts}}{{if eq .Destination "/var/lib/mysql"}}{{.Name}}{{end}}{{end}}' "$CONTAINER_NAME"):/mysql" busybox sh -c 'rm -rf /mysql/#innodb_redo /mysql/ib_logfile* /mysql/#ib_*' 2>/dev/null

        if [ $? -eq 0 ]; then
            log_success "Redo logs removidos via container temporário"
        else
            log_error "Falha ao remover redo logs"
            echo ""
            echo "  Você pode tentar manualmente:"
            echo "  1. Identifique o volume: docker volume inspect $CONTAINER_NAME"
            echo "  2. Navegue até o volume no host"
            echo "  3. Remova: rm -rf #innodb_redo/ ib_logfile* #ib_*"
            echo ""
            exit 1
        fi
    fi
else
    log_info "Volume Docker detectado: $VOLUME_NAME"

    log_info "Removendo redo logs corrompidos..."
    # Usar aspas simples dentro do sh -c para evitar expansão de # pelo shell
    docker run --rm -v "$VOLUME_NAME:/mysql" busybox sh -c 'rm -rf /mysql/#innodb_redo /mysql/ib_logfile* /mysql/#ib_*' 2>/dev/null

    if [ $? -eq 0 ]; then
        log_success "Redo logs removidos com sucesso"
    else
        log_error "Falha ao remover redo logs"
        exit 1
    fi
fi

### ========== REINICIAR CONTAINER ==========
log_section "RESTART CONTAINER"

log_info "Iniciando container..."
docker start "$CONTAINER_NAME" >/dev/null 2>&1

if [ $? -ne 0 ]; then
    log_error "Falha ao iniciar container"
    echo ""
    echo "  Verifique os logs:"
    echo "  docker logs $CONTAINER_NAME"
    echo ""
    exit 1
fi

log_success "Container iniciado"

### ========== VERIFICAR STATUS ==========
log_section "VERIFY STATUS"

log_info "Aguardando MySQL inicializar (30 segundos)..."
sleep 30

# Verificar se container está rodando
CONTAINER_STATUS=$(docker inspect --format='{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null)

if [ "$CONTAINER_STATUS" = "running" ]; then
    log_success "✅ Container está rodando!"

    # Verificar logs para confirmar sucesso
    log_info "Verificando logs..."

    if docker logs "$CONTAINER_NAME" --tail 50 2>&1 | grep -q "ready for connections"; then
        log_success "✅ MySQL está pronto para conexões!"
        echo ""
        echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║${NC}                                                               ${GREEN}║${NC}"
        echo -e "${GREEN}║${NC}          ✅ CORREÇÃO CONCLUÍDA COM SUCESSO! ✅                ${GREEN}║${NC}"
        echo -e "${GREEN}║${NC}                                                               ${GREEN}║${NC}"
        echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        log_info "O MySQL recriou os redo logs automaticamente"
        log_info "Container: $CONTAINER_NAME"
        echo ""
    elif docker logs "$CONTAINER_NAME" --tail 50 2>&1 | grep -q "redo log file.*comes from other data"; then
        log_error "❌ Erro de redo log ainda persiste!"
        echo ""
        echo "  Possíveis causas:"
        echo "    1. Múltiplos volumes montados"
        echo "    2. Volume incorreto foi limpo"
        echo "    3. Permissões incorretas"
        echo ""
        echo "  Logs recentes:"
        docker logs "$CONTAINER_NAME" --tail 20 2>&1 | grep -E "ERROR|WARNING"
        echo ""
    else
        log_warning "MySQL ainda está inicializando..."
        log_info "Aguarde mais alguns segundos e verifique:"
        echo "  docker logs $CONTAINER_NAME -f"
        echo ""
    fi
else
    log_error "❌ Container não está rodando!"
    echo ""
    echo "  Status: $CONTAINER_STATUS"
    echo ""
    echo "  Verifique os logs para mais detalhes:"
    echo "  docker logs $CONTAINER_NAME"
    echo ""
    exit 1
fi

### ========== LOGS FINAIS ==========
echo ""
log_info "Para monitorar os logs em tempo real:"
echo "  docker logs -f $CONTAINER_NAME"
echo ""

exit 0
