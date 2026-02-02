#!/bin/bash
################################################################################
# Script: fix-docker-network.sh
# Propósito: Corrigir containers com erro de rede Docker não encontrada
# Uso: ./fix-docker-network.sh [container_name] [network_name]
################################################################################

# Cores para melhor visualização
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

LOG_PREFIX="[ Network Fix Agent ]"

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
echo -e "${CYAN}║${NC}          ${GREEN}🔧 Docker Network Reconnect Fix 🔧${NC}              ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}                                                               ${CYAN}║${NC}"
echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════╝${NC}"
echo ""

log_info "Este script corrige o erro:"
echo ""
echo "  ${RED}failed to set up container networking: network [ID] not found${NC}"
echo ""

### ========== DETECTAR OU SOLICITAR CONTAINER ==========

CONTAINER_NAME="$1"
NETWORK_NAME="$2"

if [ -z "$CONTAINER_NAME" ]; then
    log_section "DETECT CONTAINERS WITH NETWORK ISSUES"

    echo "Detectando containers com problemas de rede..."
    echo ""

    # Listar containers que não estão rodando
    STOPPED_CONTAINERS=$(docker ps -a --filter "status=exited" --format "{{.Names}}" 2>/dev/null)

    if [ -z "$STOPPED_CONTAINERS" ]; then
        log_error "Nenhum container parado encontrado"
        exit 1
    fi

    # Verificar quais têm erro de rede
    CONTAINER_ARRAY=()
    INDEX=0

    while IFS= read -r container; do
        if [ -n "$container" ]; then
            ERROR=$(docker inspect --format='{{.State.Error}}' "$container" 2>/dev/null)

            if echo "$ERROR" | grep -q "network.*not found"; then
                STATUS=$(docker inspect --format='{{.State.Status}}' "$container" 2>/dev/null)
                IMAGE=$(docker inspect --format='{{.Config.Image}}' "$container" 2>/dev/null)
                MISSING_NETWORK=$(echo "$ERROR" | grep -oP 'network \K[a-f0-9]+')

                echo "  [$INDEX] $container"
                echo "      Status: $STATUS"
                echo "      Image: $IMAGE"
                echo -e "      ${RED}⚠️  ERRO DE REDE DETECTADO!${NC}"
                echo "      Rede faltando: ${MISSING_NETWORK:0:12}..."
                echo ""

                CONTAINER_ARRAY+=("$container")
                INDEX=$((INDEX + 1))
            fi
        fi
    done <<< "$STOPPED_CONTAINERS"

    if [ $INDEX -eq 0 ]; then
        log_warning "Nenhum container com erro de rede encontrado"
        echo ""
        echo "  Se você sabe o nome do container com problema:"
        echo "  $0 <container_name> [network_name]"
        echo ""
        exit 0
    fi

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

# Verificar erro
CONTAINER_ERROR=$(docker inspect --format='{{.State.Error}}' "$CONTAINER_NAME" 2>/dev/null)

if [ -z "$CONTAINER_ERROR" ]; then
    log_warning "Container não tem erro de rede registrado"
    log_info "Status: $(docker inspect --format='{{.State.Status}}' "$CONTAINER_NAME")"
    echo ""
    read -p "Deseja continuar mesmo assim? (s/N): " CONTINUE
    if [[ ! "$CONTINUE" =~ ^[Ss]$ ]]; then
        exit 0
    fi
elif ! echo "$CONTAINER_ERROR" | grep -q "network.*not found"; then
    log_warning "Container tem outro tipo de erro:"
    echo "  $CONTAINER_ERROR"
    echo ""
    read -p "Deseja continuar mesmo assim? (s/N): " CONTINUE
    if [[ ! "$CONTINUE" =~ ^[Ss]$ ]]; then
        exit 0
    fi
else
    log_info "Erro detectado: $CONTAINER_ERROR"
fi

### ========== SELECIONAR REDE ==========

if [ -z "$NETWORK_NAME" ]; then
    log_section "SELECT NETWORK"

    echo "Redes Docker disponíveis:"
    echo ""

    # Listar redes disponíveis
    NETWORK_ARRAY=()
    INDEX=0

    docker network ls --format "{{.Name}}" | while read -r network; do
        if [ -n "$network" ] && [ "$network" != "none" ] && [ "$network" != "host" ]; then
            DRIVER=$(docker network inspect --format='{{.Driver}}' "$network" 2>/dev/null)
            SUBNET=$(docker network inspect --format='{{range .IPAM.Config}}{{.Subnet}}{{end}}' "$network" 2>/dev/null)

            echo "  [$INDEX] $network"
            echo "      Driver: $DRIVER"
            [ -n "$SUBNET" ] && echo "      Subnet: $SUBNET"
            echo ""

            NETWORK_ARRAY+=("$network")
            INDEX=$((INDEX + 1))
        fi
    done

    # Recarregar array (necessário por causa do pipe)
    NETWORK_ARRAY=($(docker network ls --format "{{.Name}}" | grep -v "none\|host"))

    echo ""
    log_info "Redes comuns:"
    echo "  • ${GREEN}bridge${NC} - Rede padrão do Docker"
    echo "  • ${GREEN}coolify${NC} - Rede do Coolify (se aplicável)"
    echo "  • ${GREEN}[app-specific]${NC} - Redes específicas da aplicação"
    echo ""

    # Sugerir rede padrão
    if docker network ls | grep -q "coolify"; then
        SUGGESTED_NETWORK="coolify"
        log_info "Sugestão: ${GREEN}coolify${NC} (detectada instalação Coolify)"
    else
        SUGGESTED_NETWORK="bridge"
        log_info "Sugestão: ${GREEN}bridge${NC} (rede padrão)"
    fi
    echo ""

    read -p "Digite o nome da rede (ou pressione Enter para '$SUGGESTED_NETWORK'): " NETWORK_NAME
    NETWORK_NAME=${NETWORK_NAME:-$SUGGESTED_NETWORK}
fi

# Validar que a rede existe
if ! docker network inspect "$NETWORK_NAME" >/dev/null 2>&1; then
    log_error "Rede '$NETWORK_NAME' não encontrada"
    echo ""
    echo "  Redes disponíveis:"
    docker network ls --format "    - {{.Name}}"
    echo ""
    exit 1
fi

log_success "Rede selecionada: $NETWORK_NAME"
echo ""

### ========== CONFIRMAR AÇÃO ==========
log_section "CONFIRMATION"
echo ""
echo "  ${YELLOW}⚠️  Esta operação irá:${NC}"
echo ""
echo "  1. Parar o container: $CONTAINER_NAME (se estiver rodando)"
echo "  2. Desconectar de redes antigas/inválidas"
echo "  3. Conectar à rede: $NETWORK_NAME"
echo "  4. Reiniciar o container"
echo ""
echo "  ${GREEN}✅ As configurações do container serão preservadas${NC}"
echo "  ${GREEN}✅ Os dados não serão perdidos${NC}"
echo ""

read -p "Deseja continuar? (yes/no): " CONFIRM

if [ "$CONFIRM" != "yes" ]; then
    log_info "Operação cancelada pelo usuário"
    exit 0
fi

### ========== PARAR CONTAINER ==========
log_section "PREPARE CONTAINER"

CONTAINER_STATUS=$(docker inspect --format='{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null)
log_info "Status atual: $CONTAINER_STATUS"

if [ "$CONTAINER_STATUS" = "running" ]; then
    log_info "Parando container..."
    docker stop "$CONTAINER_NAME" >/dev/null 2>&1

    if [ $? -eq 0 ]; then
        log_success "Container parado"
    else
        log_error "Falha ao parar container"
        exit 1
    fi
else
    log_info "Container já está parado"
fi

### ========== DESCONECTAR REDES ANTIGAS ==========
log_section "DISCONNECT OLD NETWORKS"

log_info "Procurando redes conectadas ao container..."

# Listar redes atuais (se houver)
CURRENT_NETWORKS=$(docker inspect --format='{{range $net, $conf := .NetworkSettings.Networks}}{{$net}} {{end}}' "$CONTAINER_NAME" 2>/dev/null)

if [ -n "$CURRENT_NETWORKS" ]; then
    log_info "Redes encontradas: $CURRENT_NETWORKS"

    for net in $CURRENT_NETWORKS; do
        if [ "$net" != "$NETWORK_NAME" ]; then
            log_info "Desconectando de: $net"
            docker network disconnect -f "$net" "$CONTAINER_NAME" 2>/dev/null || true
        fi
    done
    log_success "Redes antigas removidas"
else
    log_info "Nenhuma rede conectada no momento"
fi

### ========== CONECTAR À NOVA REDE ==========
log_section "CONNECT TO NEW NETWORK"

log_info "Conectando à rede: $NETWORK_NAME"

# Conectar à nova rede
docker network connect "$NETWORK_NAME" "$CONTAINER_NAME" 2>/dev/null

if [ $? -eq 0 ]; then
    log_success "Container conectado à rede $NETWORK_NAME"
else
    log_warning "Falha ao conectar (pode já estar conectado)"
    # Não abortar, pode estar tudo ok
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

log_info "Aguardando container estabilizar (10 segundos)..."
sleep 10

# Verificar se container está rodando
CONTAINER_STATUS=$(docker inspect --format='{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null)

if [ "$CONTAINER_STATUS" = "running" ]; then
    log_success "✅ Container está rodando!"

    # Verificar erro
    CONTAINER_ERROR=$(docker inspect --format='{{.State.Error}}' "$CONTAINER_NAME" 2>/dev/null)

    if [ -z "$CONTAINER_ERROR" ]; then
        log_success "✅ Sem erros de rede!"
        echo ""
        echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║${NC}                                                               ${GREEN}║${NC}"
        echo -e "${GREEN}║${NC}          ✅ CORREÇÃO CONCLUÍDA COM SUCESSO! ✅                ${GREEN}║${NC}"
        echo -e "${GREEN}║${NC}                                                               ${GREEN}║${NC}"
        echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        log_info "Container: $CONTAINER_NAME"
        log_info "Rede: $NETWORK_NAME"

        # Mostrar IP atribuído
        IP=$(docker inspect --format='{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)
        [ -n "$IP" ] && log_info "IP: $IP"

        echo ""
    else
        log_error "❌ Container ainda tem erro:"
        echo "  $CONTAINER_ERROR"
        echo ""
    fi
elif [ "$CONTAINER_STATUS" = "exited" ]; then
    log_error "❌ Container saiu após iniciar"

    EXIT_CODE=$(docker inspect --format='{{.State.ExitCode}}' "$CONTAINER_NAME" 2>/dev/null)
    CONTAINER_ERROR=$(docker inspect --format='{{.State.Error}}' "$CONTAINER_NAME" 2>/dev/null)

    echo ""
    echo "  Exit Code: $EXIT_CODE"
    [ -n "$CONTAINER_ERROR" ] && echo "  Erro: $CONTAINER_ERROR"
    echo ""
    echo "  Verifique os logs:"
    echo "  docker logs $CONTAINER_NAME --tail 50"
    echo ""
    exit 1
else
    log_warning "Container em estado: $CONTAINER_STATUS"
    echo ""
    echo "  Aguarde mais alguns segundos e verifique:"
    echo "  docker ps -a --filter name=$CONTAINER_NAME"
    echo ""
fi

### ========== LOGS FINAIS ==========
echo ""
log_info "Para monitorar os logs em tempo real:"
echo "  docker logs -f $CONTAINER_NAME"
echo ""

exit 0
