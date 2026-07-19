#!/bin/bash
################################################################################
# VPS Guardian - Biblioteca de Validação
# Fornece funções de validação reutilizáveis
################################################################################

# Carregar logging se disponível
if [ -f "$(dirname "${BASH_SOURCE[0]}")/logging.sh" ]; then
    source "$(dirname "${BASH_SOURCE[0]}")/logging.sh"
fi

################################################################################
# Validações de Sistema
################################################################################

# Verifica se está rodando como root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "Este script precisa ser executado como root (use sudo)"
        return 1
    fi
    return 0
}

# Verifica se NOT está rodando como root (para segurança)
check_not_root() {
    if [ "$EUID" -eq 0 ]; then
        log_error "Este script NÃO deve ser executado como root"
        return 1
    fi
    return 0
}

# Verifica se um comando existe
check_command() {
    local cmd="$1"
    local package="${2:-$cmd}"

    if ! command -v "$cmd" &> /dev/null; then
        log_error "$cmd não está instalado"
        log_info "Instale com: sudo apt install $package -y"
        return 1
    fi
    return 0
}

# Verifica múltiplos comandos de uma vez
check_commands() {
    local missing=0

    for cmd in "$@"; do
        if ! command -v "$cmd" &> /dev/null; then
            log_error "$cmd não está instalado"
            ((missing++))
        fi
    done

    if [ $missing -gt 0 ]; then
        log_error "$missing comando(s) faltando"
        return 1
    fi

    return 0
}

################################################################################
# Validações de Docker
################################################################################

# Verifica se Docker está instalado e rodando
check_docker() {
    if ! check_command docker; then
        return 1
    fi

    if ! docker ps &> /dev/null; then
        log_error "Docker não está rodando ou você não tem permissão"
        log_info "Verifique: sudo systemctl status docker"
        return 1
    fi

    return 0
}

# Verifica se um container Docker existe
check_container() {
    local container="$1"

    if ! docker ps -a --format '{{.Names}}' | grep -q "^${container}$"; then
        log_error "Container '$container' não existe"
        return 1
    fi

    return 0
}

# Verifica se um container está rodando
check_container_running() {
    local container="$1"

    if ! docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
        log_error "Container '$container' não está rodando"
        log_info "Inicie com: docker start $container"
        return 1
    fi

    return 0
}

# Verifica se um volume Docker existe
check_volume() {
    local volume="$1"

    if ! docker volume ls -q | grep -q "^${volume}$"; then
        log_error "Volume '$volume' não existe"
        return 1
    fi

    return 0
}

################################################################################
# Validações de Arquivo/Diretório
################################################################################

# Verifica se arquivo existe
check_file() {
    local file="$1"

    if [ ! -f "$file" ]; then
        log_error "Arquivo não encontrado: $file"
        return 1
    fi

    return 0
}

# Verifica se diretório existe
check_directory() {
    local dir="$1"

    if [ ! -d "$dir" ]; then
        log_error "Diretório não encontrado: $dir"
        return 1
    fi

    return 0
}

# Verifica se arquivo existe E é executável
check_executable() {
    local file="$1"

    if [ ! -f "$file" ]; then
        log_error "Arquivo não encontrado: $file"
        return 1
    fi

    if [ ! -x "$file" ]; then
        log_error "Arquivo não é executável: $file"
        log_info "Torne executável: chmod +x $file"
        return 1
    fi

    return 0
}

# Verifica se tem permissão de escrita em diretório
check_writable() {
    local dir="$1"

    if [ ! -w "$dir" ]; then
        log_error "Sem permissão de escrita em: $dir"
        return 1
    fi

    return 0
}

# Cria diretório se não existir
ensure_directory() {
    local dir="$1"
    local mode="${2:-755}"

    if [ ! -d "$dir" ]; then
        if ! mkdir -p "$dir" 2>/dev/null; then
            log_error "Não foi possível criar diretório: $dir"
            return 1
        fi
        chmod "$mode" "$dir" 2>/dev/null || true
        log_debug "Diretório criado: $dir"
    fi

    return 0
}

################################################################################
# Validações de Espaço em Disco
################################################################################

# Verifica se há espaço suficiente em disco (em MB)
check_disk_space() {
    local path="${1:-.}"
    local required_mb="${2:-1024}"

    local available_kb=$(df -k "$path" | awk 'NR==2 {print $4}')
    local available_mb=$((available_kb / 1024))

    if [ $available_mb -lt $required_mb ]; then
        log_error "Espaço insuficiente em $path"
        log_error "Necessário: ${required_mb}MB, Disponível: ${available_mb}MB"
        return 1
    fi

    log_debug "Espaço OK: ${available_mb}MB disponível em $path"
    return 0
}

################################################################################
# Validações de Rede
################################################################################

# Verifica conectividade de rede
check_network() {
    if ! ping -c 1 -W 2 8.8.8.8 &> /dev/null; then
        log_error "Sem conectividade de rede"
        return 1
    fi
    return 0
}

# Verifica se uma porta está aberta
check_port() {
    local port="$1"
    local host="${2:-localhost}"

    if ! command -v nc &> /dev/null; then
        log_warning "netcat não instalado, não foi possível verificar porta"
        return 0
    fi

    if ! nc -z "$host" "$port" 2>/dev/null; then
        log_error "Porta $port não está acessível em $host"
        return 1
    fi

    return 0
}

# Verifica conectividade SSH
check_ssh() {
    local user="$1"
    local host="$2"
    local port="${3:-22}"

    if ! ssh -o BatchMode=yes -o ConnectTimeout=5 -p "$port" "$user@$host" "exit" 2>/dev/null; then
        log_error "Não foi possível conectar via SSH: $user@$host:$port"
        log_info "Verifique: ssh -v $user@$host -p $port"
        return 1
    fi

    return 0
}

################################################################################
# Validações de Variáveis
################################################################################

# Verifica se variável está definida e não vazia
check_var() {
    local var_name="$1"
    local var_value="${!var_name}"

    if [ -z "$var_value" ]; then
        log_error "Variável '$var_name' não está definida ou está vazia"
        return 1
    fi

    return 0
}

# Verifica se variável é um número
check_number() {
    local value="$1"
    local var_name="${2:-valor}"

    if ! [[ "$value" =~ ^[0-9]+$ ]]; then
        log_error "'$var_name' deve ser um número: $value"
        return 1
    fi

    return 0
}

# Verifica se variável é um IP válido
check_ip() {
    local ip="$1"
    local ip_regex='^([0-9]{1,3}\.){3}[0-9]{1,3}$'

    if ! [[ "$ip" =~ $ip_regex ]]; then
        log_error "IP inválido: $ip"
        return 1
    fi

    # Verifica cada octeto
    local IFS='.'
    local octets=($ip)
    for octet in "${octets[@]}"; do
        if [ "$octet" -gt 255 ]; then
            log_error "IP inválido: $ip (octeto > 255)"
            return 1
        fi
    done

    return 0
}

################################################################################
# Validações de Processo
################################################################################

# Verifica se processo está rodando
check_process() {
    local process="$1"

    if ! pgrep -x "$process" > /dev/null; then
        log_error "Processo '$process' não está rodando"
        return 1
    fi

    return 0
}

# Verifica se há processos concorrentes (lock)
check_lock() {
    local lockfile="$1"

    if [ -f "$lockfile" ]; then
        local pid=$(cat "$lockfile" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            log_error "Processo já está rodando (PID: $pid, Lock: $lockfile)"
            return 1
        else
            # Lock file existe mas processo morreu
            log_warning "Lock file órfão encontrado, removendo..."
            rm -f "$lockfile"
        fi
    fi

    return 0
}

# Cria lock file
create_lock() {
    local lockfile="$1"

    if ! check_lock "$lockfile"; then
        return 1
    fi

    echo $$ > "$lockfile"
    log_debug "Lock criado: $lockfile (PID: $$)"

    # Setup trap para remover lock ao sair
    trap "rm -f '$lockfile'" EXIT

    return 0
}

################################################################################
# Validações Específicas do Coolify
################################################################################

# Verifica se Coolify está instalado
check_coolify() {
    local coolify_dir="${COOLIFY_DATA_DIR:-/data/coolify}"
    if [ ! -d "$coolify_dir" ]; then
        log_error "Coolify não está instalado"
        log_info "Instale: curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash"
        return 1
    fi

    return 0
}

# Verifica se banco do Coolify está saudável
check_coolify_db() {
    if ! check_container_running "coolify-db"; then
        return 1
    fi

    if ! docker exec coolify-db pg_isready -U coolify &> /dev/null; then
        log_error "Banco de dados do Coolify não está pronto"
        log_info "Verifique: docker logs coolify-db"
        return 1
    fi

    return 0
}

################################################################################
# Funções de Validação Combinadas
################################################################################

# Validação completa do ambiente para backup
validate_backup_environment() {
    local errors=0

    log_info "Validando ambiente para backup..."

    check_root || ((errors++))
    check_docker || ((errors++))
    check_coolify || ((errors++))
    check_disk_space "/var/backups" 1024 || ((errors++))

    if [ $errors -gt 0 ]; then
        log_error "Validação falhou com $errors erro(s)"
        return 1
    fi

    log_success "Ambiente validado com sucesso"
    return 0
}

# Validação completa do ambiente para migração
validate_migration_environment() {
    local errors=0

    log_info "Validando ambiente para migração..."

    check_root || ((errors++))
    check_docker || ((errors++))
    check_coolify || ((errors++))
    check_coolify_db || ((errors++))
    check_commands ssh scp tar gzip || ((errors++))

    if [ $errors -gt 0 ]; then
        log_error "Validação falhou com $errors erro(s)"
        return 1
    fi

    log_success "Ambiente validado com sucesso"
    return 0
}

################################################################################
# Export de funções para uso em subshells
################################################################################

export -f check_root check_not_root check_command check_commands
export -f check_docker check_container check_container_running check_volume
export -f check_file check_directory check_executable check_writable ensure_directory
export -f check_disk_space check_network check_port check_ssh
export -f check_var check_number check_ip
export -f check_process check_lock create_lock
export -f check_coolify check_coolify_db
export -f validate_backup_environment validate_migration_environment
