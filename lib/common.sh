#!/bin/bash
################################################################################
# VPS Guardian - Biblioteca Comum
# Carrega todas as bibliotecas e configurações necessárias
#
# Uso: source /opt/vpsguardian/lib/common.sh
################################################################################

# Determina o diretório da biblioteca
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VPSGUARDIAN_ROOT="$(dirname "$LIB_DIR")"

# A instalação registra os caminhos escolhidos ao lado do código. Carregar esse
# metadado antes dos defaults evita que uma instalação customizada volte
# silenciosamente para /var/backups ou /var/log.
if [ -f "$VPSGUARDIAN_ROOT/.install.conf" ]; then
    # shellcheck disable=SC1091
    source "$VPSGUARDIAN_ROOT/.install.conf"
fi

# Carrega configuração global
if [ -f "$VPSGUARDIAN_ROOT/config/default.conf" ]; then
    source "$VPSGUARDIAN_ROOT/config/default.conf"
elif [ -f "/etc/vpsguardian/config.conf" ]; then
    source "/etc/vpsguardian/config.conf"
fi

# Carrega bibliotecas na ordem correta
source "$LIB_DIR/colors.sh"
source "$LIB_DIR/logging.sh"
source "$LIB_DIR/validation.sh"

# Configurações padrão se não foram definidas
: "${VPSGUARDIAN_ROOT:=/opt/vpsguardian}"
: "${BACKUP_ROOT:=/var/backups/vpsguardian}"
: "${LOG_DIR:=${LOG_ROOT:-/var/log/vpsguardian}}"

# Define nome do script automaticamente
if [ -z "$SCRIPT_NAME" ]; then
    SCRIPT_NAME="$(basename "$0" .sh)"
    export SCRIPT_NAME
fi

# Função de inicialização comum
init_script() {
    # Cria diretórios necessários
    ensure_directory "$BACKUP_ROOT" 700
    ensure_directory "$LOG_DIR" 750

    # Configura log file se não estiver definido
    if [ -z "$LOG_FILE" ]; then
        LOG_FILE="$LOG_DIR/${SCRIPT_NAME}.log"
        set_log_file "$LOG_FILE"
    fi

    # Rotaciona log se necessário
    rotate_log "$LOG_FILE" 10

    log_debug "Script iniciado: $SCRIPT_NAME"
    log_debug "VPS Guardian Root: $VPSGUARDIAN_ROOT"
}

# Trap para cleanup ao sair
cleanup_on_exit() {
    log_debug "Script finalizado: $SCRIPT_NAME"
}

trap cleanup_on_exit EXIT

################################################################################
# Funções auxiliares comuns
################################################################################

# Confirma ação com usuário
confirm() {
    local message="$1"
    local default="${2:-n}"
    local prompt

    if [ "$default" = "y" ]; then
        prompt="$message (S/n): "
    else
        prompt="$message (s/N): "
    fi

    read -p "$prompt" response
    response="${response:-$default}"

    case "$response" in
        [Ss]|[Yy]|[Ss][Ii][Mm]|[Yy][Ee][Ss])
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# Pausa com mensagem
pause() {
    local message="${1:-Pressione ENTER para continuar...}"
    read -p "$message"
}

# Exibe progresso simples
show_progress() {
    local current="$1"
    local total="$2"
    local message="${3:-Progresso}"

    local percent=$((current * 100 / total))
    log_info "$message: $current/$total ($percent%)"
}

# Executa comando com retry
retry() {
    local max_attempts="${1:-3}"
    local delay="${2:-5}"
    shift 2
    local cmd_display
    printf -v cmd_display '%q ' "$@"
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        log_debug "Tentativa $attempt/$max_attempts: $cmd_display"

        if "$@"; then
            return 0
        fi

        if [ $attempt -lt $max_attempts ]; then
            log_warning "Falhou, tentando novamente em ${delay}s..."
            sleep "$delay"
        fi

        ((attempt++))
    done

    log_error "Comando falhou após $max_attempts tentativas: $cmd_display"
    return 1
}

################################################################################
# Export
################################################################################

export -f init_script cleanup_on_exit
export -f confirm pause show_progress retry

# Marca que common.sh foi carregado
VPSGUARDIAN_COMMON_LOADED=1
export VPSGUARDIAN_COMMON_LOADED
