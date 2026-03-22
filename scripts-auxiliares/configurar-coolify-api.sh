#!/bin/bash
################################################################################
# Script: configurar-coolify-api.sh
# Propósito: Configurar integração com API REST do Coolify
# Uso: ./configurar-coolify-api.sh [--test] [--disable]
#
# Permite:
#   - Configurar token de API do Coolify
#   - Testar conexão com a API
#   - Habilitar/desabilitar integração
#
# Versão: 1.0.0
################################################################################

# Carregar bibliotecas
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh" 2>/dev/null || {
    log_info() { echo "[ INFO ] $*"; }
    log_success() { echo "[ OK ] $*"; }
    log_error() { echo "[ ERRO ] $*"; }
    log_warning() { echo "[ AVISO ] $*"; }
    log_section() { echo ""; echo "========== $* =========="; echo ""; }
}

# Cores (fallback se colors.sh não carregado)
RED="${RED:-\033[0;31m}"
GREEN="${GREEN:-\033[0;32m}"
YELLOW="${YELLOW:-\033[1;33m}"
BLUE="${BLUE:-\033[0;34m}"
CYAN="${CYAN:-\033[0;36m}"
WHITE="${WHITE:-\033[1;37m}"
GRAY="${GRAY:-\033[0;90m}"
NC="${NC:-\033[0m}"

# Configuração
CONFIG_FILE="/opt/vpsguardian/config/backup-destinations.conf"
DEV_CONFIG_FILE="$SCRIPT_DIR/../config/backup-destinations.conf"

# Usar arquivo de desenvolvimento se existir e produção não existir
if [ ! -f "$CONFIG_FILE" ] && [ -f "$DEV_CONFIG_FILE" ]; then
    CONFIG_FILE="$DEV_CONFIG_FILE"
fi

# Valores padrão
TEST_ONLY=false
DISABLE_API=false

# Parse de argumentos
while [[ $# -gt 0 ]]; do
    case $1 in
        --test)
            TEST_ONLY=true
            shift
            ;;
        --disable)
            DISABLE_API=true
            shift
            ;;
        -h|--help)
            cat << 'EOF'
CONFIGURAR COOLIFY API - VPS Guardian

USO:
  ./configurar-coolify-api.sh [OPÇÕES]

OPÇÕES:
  --test       Apenas testar conexão atual (não altera configuração)
  --disable    Desabilitar integração com API
  -h, --help   Mostrar esta ajuda

SOBRE A INTEGRAÇÃO:

A API do Coolify permite:
  - Descoberta automática de databases (sem parsing de containers)
  - Stop/Start graceful (respeita estado do Coolify)
  - Obtenção de credenciais de conexão

COMO OBTER O TOKEN:

  1. Acesse a UI do Coolify
  2. Vá em: Settings → Keys & Tokens → API tokens
  3. Crie um novo token com permissão "read:sensitive" ou "*"
  4. Copie o token gerado

PERMISSÕES RECOMENDADAS:

  - read:sensitive  → Para descoberta de databases e credenciais
  - *               → Para stop/start via API (recomendado)

EXEMPLOS:
  ./configurar-coolify-api.sh           # Configurar interativamente
  ./configurar-coolify-api.sh --test    # Testar conexão atual
  ./configurar-coolify-api.sh --disable # Desabilitar integração
EOF
            exit 0
            ;;
        *)
            log_error "Opção desconhecida: $1"
            exit 2
            ;;
    esac
done

################################################################################
# Funções
################################################################################

# Verificar dependências
check_dependencies() {
    local missing=()

    if ! command -v curl &>/dev/null; then
        missing+=("curl")
    fi

    if ! command -v jq &>/dev/null; then
        missing+=("jq")
    fi

    if [ ${#missing[@]} -gt 0 ]; then
        log_error "Dependências não encontradas: ${missing[*]}"
        echo ""
        echo "Instale com:"
        echo "  apt install ${missing[*]}"
        return 3
    fi

    return 0
}

# Carregar configuração atual
load_current_config() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
    fi
}

# Atualizar variável no arquivo de configuração
update_config_var() {
    local var_name="$1"
    local var_value="$2"

    if grep -q "^${var_name}=" "$CONFIG_FILE" 2>/dev/null; then
        # Variável existe, atualizar
        sed -i "s|^${var_name}=.*|${var_name}=\"${var_value}\"|" "$CONFIG_FILE"
    else
        # Variável não existe, verificar se seção existe
        if grep -q "# ========== COOLIFY API ==========" "$CONFIG_FILE" 2>/dev/null; then
            # Seção existe, adicionar após ela
            sed -i "/# ========== COOLIFY API ==========/a ${var_name}=\"${var_value}\"" "$CONFIG_FILE"
        else
            log_warning "Seção COOLIFY API não encontrada no arquivo de configuração"
            echo "${var_name}=\"${var_value}\"" >> "$CONFIG_FILE"
        fi
    fi
}

# Testar conexão com API
test_api_connection() {
    local url="${1:-$COOLIFY_API_URL}"
    local token="${2:-$COOLIFY_API_TOKEN}"

    echo ""
    echo -e "${CYAN}Testando conexão com API do Coolify...${NC}"
    echo ""
    echo -e "  ${GRAY}URL:${NC} $url"
    echo -e "  ${GRAY}Token:${NC} ${token:0:10}...${token: -5}"
    echo ""

    # Verificar jq
    if ! command -v jq &>/dev/null; then
        echo -e "  ${RED}[ERRO]${NC} jq não está instalado"
        echo -e "         ${GRAY}Instale com: apt install jq${NC}"
        return 1
    fi
    echo -e "  ${GREEN}[OK]${NC} jq instalado"

    # Verificar health endpoint
    local health_url="${url%/api/v1}/health"
    if curl -sf --max-time 5 "$health_url" >/dev/null 2>&1; then
        echo -e "  ${GREEN}[OK]${NC} Coolify está rodando"
    else
        echo -e "  ${YELLOW}[AVISO]${NC} Health endpoint não acessível"
        echo -e "           ${GRAY}Verifique se o Coolify está rodando${NC}"
    fi

    # Testar autenticação
    local response
    response=$(curl -sf --max-time 10 \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        "${url}/servers" 2>/dev/null)

    if [ $? -eq 0 ] && [ -n "$response" ]; then
        local server_count
        server_count=$(echo "$response" | jq 'length' 2>/dev/null)
        echo -e "  ${GREEN}[OK]${NC} API autenticada ($server_count servidor(es))"
    else
        echo -e "  ${RED}[ERRO]${NC} Falha na autenticação"
        echo -e "         ${GRAY}Verifique se o token é válido${NC}"
        return 1
    fi

    # Testar databases
    local dbs
    dbs=$(curl -sf --max-time 10 \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        "${url}/databases" 2>/dev/null)

    if [ $? -eq 0 ] && [ -n "$dbs" ]; then
        local db_count
        db_count=$(echo "$dbs" | jq 'length' 2>/dev/null)
        echo -e "  ${GREEN}[OK]${NC} $db_count database(s) encontrado(s)"

        if [ "$db_count" -gt 0 ]; then
            echo ""
            echo -e "  ${WHITE}Databases detectados via API:${NC}"
            echo "$dbs" | jq -r '.[] | "    - \(.name) (\(.type)) - \(.status)"' 2>/dev/null
        fi
    else
        echo -e "  ${YELLOW}[AVISO]${NC} Não foi possível listar databases"
    fi

    echo ""
    echo -e "${GREEN}Conexão estabelecida com sucesso!${NC}"
    return 0
}

# Desabilitar integração
disable_integration() {
    log_section "Desabilitando Integração"

    update_config_var "COOLIFY_API_ENABLED" "false"

    log_success "Integração com API do Coolify desabilitada"
    echo ""
    echo "Os backups continuarão funcionando usando detecção via Docker."
    return 0
}

# Menu interativo de configuração
interactive_setup() {
    echo ""
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}       ${WHITE}CONFIGURAR INTEGRAÇÃO COM API DO COOLIFY${NC}              ${CYAN}║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    # Verificar dependências
    if ! check_dependencies; then
        return 3
    fi

    # Carregar configuração atual
    load_current_config

    # Mostrar status atual
    echo -e "${WHITE}Status Atual:${NC}"
    if [ "$COOLIFY_API_ENABLED" = "true" ]; then
        echo -e "  Integração: ${GREEN}HABILITADA${NC}"
    else
        echo -e "  Integração: ${YELLOW}DESABILITADA${NC}"
    fi
    echo -e "  URL: ${GRAY}${COOLIFY_API_URL:-http://localhost:8000/api/v1}${NC}"
    if [ -n "$COOLIFY_API_TOKEN" ]; then
        echo -e "  Token: ${GRAY}${COOLIFY_API_TOKEN:0:10}...${COOLIFY_API_TOKEN: -5}${NC}"
    else
        echo -e "  Token: ${RED}NÃO CONFIGURADO${NC}"
    fi
    echo ""

    # Perguntar o que fazer
    echo -e "${WHITE}O que deseja fazer?${NC}"
    echo ""
    echo -e "  ${GREEN}1${NC} → Configurar/Atualizar token de API"
    echo -e "  ${GREEN}2${NC} → Testar conexão atual"
    echo -e "  ${GREEN}3${NC} → Habilitar integração"
    echo -e "  ${GREEN}4${NC} → Desabilitar integração"
    echo -e "  ${RED}0${NC} → Cancelar"
    echo ""
    read -p "Escolha (0-4): " choice

    case $choice in
        1)
            configure_token
            ;;
        2)
            if [ -z "$COOLIFY_API_TOKEN" ]; then
                log_error "Token não configurado"
                return 1
            fi
            test_api_connection "$COOLIFY_API_URL" "$COOLIFY_API_TOKEN"
            ;;
        3)
            enable_integration
            ;;
        4)
            disable_integration
            ;;
        0)
            log_info "Operação cancelada"
            return 0
            ;;
        *)
            log_error "Opção inválida"
            return 2
            ;;
    esac
}

# Configurar token
configure_token() {
    log_section "Configurar Token de API"

    echo -e "${WHITE}Como obter o token:${NC}"
    echo ""
    echo "  1. Acesse a UI do Coolify"
    echo "  2. Vá em: Settings → Keys & Tokens → API tokens"
    echo "  3. Crie um novo token com permissão \"*\" (full access)"
    echo "  4. Copie o token gerado"
    echo ""

    # URL da API
    read -p "URL da API [${COOLIFY_API_URL:-http://localhost:8000/api/v1}]: " input_url
    local new_url="${input_url:-${COOLIFY_API_URL:-http://localhost:8000/api/v1}}"

    # Token
    echo ""
    read -p "Token de API: " input_token

    if [ -z "$input_token" ]; then
        log_error "Token não pode ser vazio"
        return 1
    fi

    # Testar antes de salvar
    echo ""
    read -p "Testar conexão antes de salvar? (S/n): " test_first
    test_first="${test_first:-s}"

    if [[ "$test_first" =~ ^[Ss]$ ]]; then
        if ! test_api_connection "$new_url" "$input_token"; then
            echo ""
            read -p "Salvar mesmo assim? (s/N): " save_anyway
            if [[ ! "$save_anyway" =~ ^[Ss]$ ]]; then
                log_info "Configuração cancelada"
                return 1
            fi
        fi
    fi

    # Salvar configuração
    log_section "Salvando Configuração"

    update_config_var "COOLIFY_API_URL" "$new_url"
    update_config_var "COOLIFY_API_TOKEN" "$input_token"
    update_config_var "COOLIFY_API_ENABLED" "true"
    update_config_var "COOLIFY_USE_API_FOR_STOP" "true"

    log_success "Configuração salva em: $CONFIG_FILE"
    echo ""
    echo -e "${WHITE}Próximos passos:${NC}"
    echo "  - Os backups agora usarão a API para descobrir databases"
    echo "  - Stop/Start de containers usará a API (graceful)"
    echo "  - Execute um backup para testar a integração"

    return 0
}

# Habilitar integração
enable_integration() {
    log_section "Habilitar Integração"

    # Verificar se token existe
    if [ -z "$COOLIFY_API_TOKEN" ]; then
        log_warning "Token não configurado. Vamos configurar agora."
        configure_token
        return $?
    fi

    # Testar conexão
    if ! test_api_connection "$COOLIFY_API_URL" "$COOLIFY_API_TOKEN"; then
        log_error "Conexão falhou. Verifique as configurações."
        return 1
    fi

    # Habilitar
    update_config_var "COOLIFY_API_ENABLED" "true"

    log_success "Integração habilitada com sucesso!"
    return 0
}

################################################################################
# Main
################################################################################

# Verificar se arquivo de configuração existe
if [ ! -f "$CONFIG_FILE" ]; then
    log_error "Arquivo de configuração não encontrado: $CONFIG_FILE"
    log_info "Execute o instalador do VPS Guardian primeiro"
    exit 5
fi

# Carregar configuração
load_current_config

# Executar ação
if [ "$TEST_ONLY" = true ]; then
    if [ -z "$COOLIFY_API_TOKEN" ]; then
        log_error "Token não configurado"
        log_info "Execute: $0 (sem argumentos) para configurar"
        exit 1
    fi
    test_api_connection "$COOLIFY_API_URL" "$COOLIFY_API_TOKEN"
    exit $?
elif [ "$DISABLE_API" = true ]; then
    disable_integration
    exit $?
else
    interactive_setup
    exit $?
fi
