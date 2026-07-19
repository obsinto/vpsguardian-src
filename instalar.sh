#!/bin/bash

################################################################################
# Script de Instalação - VPS Guardian
# Propósito: Instalação escalável e configurável do sistema
# Uso: sudo ./instalar.sh
#
# Características:
# - Menu interativo para configuração
# - Detecta instalação anterior
# - Oferece atualizar/reinstalar/desinstalar
# - Cópias transacionais por padrão; symlinks mantidos por compatibilidade
# - Configuração completa integrada
# - Validações robustas
# - Modo automatizado e raiz de sistema simulada para testes
# - Atualização transacional com rollback dos arquivos imutáveis
################################################################################

set -euo pipefail

# ═══════════════════════════════════════════════════════════════════════════════
# CORES E FORMATAÇÃO
# ═══════════════════════════════════════════════════════════════════════════════

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ═══════════════════════════════════════════════════════════════════════════════
# DETECÇÃO AUTOMÁTICA DE DIRETÓRIOS
# ═══════════════════════════════════════════════════════════════════════════════

# Detectar diretório de origem (onde está o repositório clonado)
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_NAME="$(basename "$SOURCE_DIR")"

# Padrões dinâmicos baseados no nome da pasta atual
DEFAULT_INSTALL_DIR="/opt/$SOURCE_NAME"
DEFAULT_BACKUP_DIR="/var/backups/$SOURCE_NAME"
DEFAULT_LOG_DIR="/var/log/$SOURCE_NAME"

# Versões: o projeto já expõe v1.0.0 no wrapper; o monitor mantém versão própria.
VPSGUARDIAN_VERSION="1.0.0"
MONITOR_VERSION="1.0.0"

# Opções de automação. VPSGUARDIAN_SYSTEM_ROOT é exclusivamente um prefixo de
# testes/empacotamento (ex.: /tmp/...); vazio significa o sistema real.
MODE=""
NON_INTERACTIVE=false
CLI_INSTALL_ROOT=""
CLI_BACKUP_ROOT=""
CLI_LOG_ROOT=""
CLI_USE_SYMLINKS=""
SYSTEM_ROOT="${VPSGUARDIAN_SYSTEM_ROOT:-}"
SKIP_SYSTEMCTL="${VPSGUARDIAN_SKIP_SYSTEMCTL:-false}"
MONITOR_ONLY=false
PURGE_CONFIG=false
PURGE_STATE=false
PURGE_HISTORY=false
PURGE_INCIDENTS=false
PURGE_ALL=false
ROLLBACK_DIR=""

system_path() {
    local path="$1"
    if [ -n "$SYSTEM_ROOT" ]; then
        printf '%s%s' "${SYSTEM_ROOT%/}" "$path"
    else
        printf '%s' "$path"
    fi
}

usage() {
    cat <<'EOF'
Uso: sudo ./instalar.sh [opções]

Sem opções, abre o fluxo interativo existente.

  --mode install|update|reinstall|uninstall
  --non-interactive              Não faz perguntas
  --install-root CAMINHO         Raiz instalada
  --backup-root CAMINHO          Diretório de backups
  --log-root CAMINHO             Diretório de logs
  --symlink | --copy             Estratégia de instalação
  --monitor-only                 Remove somente o monitor (com --mode uninstall)
  --purge-config                 Remove configuração ativa do monitor
  --purge-state                  Remove estado M5/M6 (preserva histórico/incidentes)
  --purge-history                Remove histórico M7
  --purge-incidents              Remove pacotes de emergência M8
  --purge-all                    Remove configuração e todos os dados do monitor
  --system-root CAMINHO          Prefixo isolado para testes de empacotamento
  -h, --help                     Mostra esta ajuda
EOF
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --mode)
                [ "$#" -ge 2 ] || { log_error "--mode requer um valor"; exit 64; }
                MODE="$2"; shift ;;
            --mode=*) MODE="${1#*=}" ;;
            --non-interactive|--auto) NON_INTERACTIVE=true ;;
            --install-root)
                [ "$#" -ge 2 ] || { log_error "--install-root requer um caminho"; exit 64; }
                CLI_INSTALL_ROOT="$2"; shift ;;
            --install-root=*) CLI_INSTALL_ROOT="${1#*=}" ;;
            --backup-root)
                [ "$#" -ge 2 ] || { log_error "--backup-root requer um caminho"; exit 64; }
                CLI_BACKUP_ROOT="$2"; shift ;;
            --backup-root=*) CLI_BACKUP_ROOT="${1#*=}" ;;
            --log-root)
                [ "$#" -ge 2 ] || { log_error "--log-root requer um caminho"; exit 64; }
                CLI_LOG_ROOT="$2"; shift ;;
            --log-root=*) CLI_LOG_ROOT="${1#*=}" ;;
            --symlink) CLI_USE_SYMLINKS=true ;;
            --copy) CLI_USE_SYMLINKS=false ;;
            --system-root)
                [ "$#" -ge 2 ] || { log_error "--system-root requer um caminho"; exit 64; }
                SYSTEM_ROOT="$2"; shift ;;
            --system-root=*) SYSTEM_ROOT="${1#*=}" ;;
            --monitor-only) MONITOR_ONLY=true ;;
            --purge-config) PURGE_CONFIG=true ;;
            --purge-state) PURGE_STATE=true ;;
            --purge-history) PURGE_HISTORY=true ;;
            --purge-incidents) PURGE_INCIDENTS=true ;;
            --purge-all) PURGE_ALL=true ;;
            -h|--help) usage; exit 0 ;;
            *) log_error "Opção desconhecida: $1"; usage; exit 64 ;;
        esac
        shift
    done

    case "$MODE" in
        ""|install|update|reinstall|uninstall) ;;
        *) log_error "Modo inválido: $MODE"; exit 64 ;;
    esac

    if [ -n "$SYSTEM_ROOT" ]; then
        case "$SYSTEM_ROOT" in
            /|/opt|/usr|/etc|/var) log_error "Raiz de sistema insegura: $SYSTEM_ROOT"; exit 64 ;;
        esac
        SKIP_SYSTEMCTL=true
        NON_INTERACTIVE=true
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# FUNÇÕES DE LOG
# ═══════════════════════════════════════════════════════════════════════════════

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[⚠]${NC} $1"
}

log_error() {
    echo -e "${RED}[✗]${NC} $1"
}

log_section() {
    echo ""
    echo -e "${MAGENTA}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${MAGENTA}║${NC} $1"
    echo -e "${MAGENTA}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# ═══════════════════════════════════════════════════════════════════════════════
# VERIFICAÇÕES INICIAIS
# ═══════════════════════════════════════════════════════════════════════════════

verify_root() {
    # Testes com --system-root nunca escrevem no host e podem rodar sem root.
    [ -n "$SYSTEM_ROOT" ] && return 0
    if [ "$EUID" -ne 0 ]; then
        log_error "Este script precisa ser executado como root (use sudo)"
        exit 1
    fi
}

verify_directory() {
    if [ ! -f "$SOURCE_DIR/menu-principal.sh" ] || [ ! -d "$SOURCE_DIR/backup" ]; then
        log_error "Estrutura do projeto não encontrada ao lado de instalar.sh"
        exit 1
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# CARREGAMENTO DE CONFIGURAÇÕES ANTERIORES
# ═══════════════════════════════════════════════════════════════════════════════

INSTALL_ROOT=""
BACKUP_ROOT=""
LOG_ROOT=""
USE_SYMLINKS=""
INSTALLED=false
INSTALL_CONFIG=""

load_previous_config() {
    # Procurar arquivo de configuração em locais possíveis
    local possible_configs=(
        "${VPSGUARDIAN_INSTALL_CONFIG:-}"
        "$(system_path /etc/vpsguardian/install.conf)"
        "$(system_path /opt/vpsguardian/.install.conf)"
        "$(system_path /opt/vpsguardian-src/.install.conf)"
        "$DEFAULT_INSTALL_DIR/.install.conf"
    )

    for config in "${possible_configs[@]}"; do
        if [ -n "$config" ] && [ -f "$config" ]; then
            INSTALL_CONFIG="$config"
            source "$INSTALL_CONFIG"
            INSTALLED=true
            return
        fi
    done
}

# ═══════════════════════════════════════════════════════════════════════════════
# BANNER
# ═══════════════════════════════════════════════════════════════════════════════

show_banner() {
    clear
    echo -e "${CYAN}"
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║                                                            ║"
    echo "║             🛡️  VPS GUARDIAN - INSTALADOR                  ║"
    echo "║                                                            ║"
    echo "║     Sistema completo de Backup, Manutenção e Migração     ║"
    echo "║                                                            ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# ═══════════════════════════════════════════════════════════════════════════════
# MENU DE MODO (Instalar/Atualizar/Desinstalar)
# ═══════════════════════════════════════════════════════════════════════════════

choose_installation_mode() {
    if [[ "$MODE" =~ ^(install|update|reinstall|uninstall)$ ]]; then
        if [ "$MODE" != "install" ] && [ "$INSTALLED" != true ]; then
            log_error "Nenhuma instalação anterior encontrada para o modo '$MODE'"
            return 1
        fi
        return 0
    fi
    MODE=""

    log_section "MODO DE INSTALAÇÃO"

    if [ "$INSTALLED" = true ]; then
        log_warning "Instalação anterior detectada em: $INSTALL_ROOT"
        echo ""
        echo "O que deseja fazer?"
        echo ""
        echo "  1. 🔄 Atualizar (preservar configurações)"
        echo "  2. 🔁 Reinstalar (reconfigurar tudo)"
        echo "  3. ❌ Desinstalar (remover do sistema)"
        echo "  4. 📋 Ver configuração atual"
        echo "  5. ⬅️  Cancelar"
        echo ""

        read -p "Escolha uma opção (1-5): " MODE
        case $MODE in
            1) MODE="update" ;;
            2) MODE="reinstall" ;;
            3) MODE="uninstall" ;;
            4) show_current_config; return 1 ;;
            5) log_info "Cancelado"; exit 0 ;;
            *) log_error "Opção inválida"; return 1 ;;
        esac
    else
        log_success "Primeira instalação detectada"
        MODE="install"
    fi

    echo ""
}

show_current_config() {
    log_section "CONFIGURAÇÃO ATUAL"

    log_info "Diretório de instalação: $INSTALL_ROOT"
    log_info "Diretório de backups:    $BACKUP_ROOT"
    log_info "Diretório de logs:       $LOG_ROOT"
    log_info "Tipo de links:           $([ "$USE_SYMLINKS" = "true" ] && echo "Symlinks" || echo "Cópias")"
    echo ""
}

# ═══════════════════════════════════════════════════════════════════════════════
# MENU INTERATIVO DE CONFIGURAÇÃO
# ═══════════════════════════════════════════════════════════════════════════════

interactive_configuration() {
    if [ "$NON_INTERACTIVE" = true ]; then
        local auto_install="$DEFAULT_INSTALL_DIR"
        local auto_backup="$DEFAULT_BACKUP_DIR"
        local auto_log="$DEFAULT_LOG_DIR"
        if [ -n "$SYSTEM_ROOT" ]; then
            auto_install="$(system_path "$DEFAULT_INSTALL_DIR")"
            auto_backup="$(system_path "$DEFAULT_BACKUP_DIR")"
            auto_log="$(system_path "$DEFAULT_LOG_DIR")"
        fi
        INSTALL_ROOT="${CLI_INSTALL_ROOT:-${INSTALL_ROOT:-$auto_install}}"
        BACKUP_ROOT="${CLI_BACKUP_ROOT:-${BACKUP_ROOT:-$auto_backup}}"
        LOG_ROOT="${CLI_LOG_ROOT:-${LOG_ROOT:-$auto_log}}"
        USE_SYMLINKS="${CLI_USE_SYMLINKS:-${USE_SYMLINKS:-false}}"
        return 0
    fi

    log_section "CONFIGURAÇÃO INTERATIVA"

    log_info "Nome da pasta de origem detectado: $SOURCE_NAME"
    echo ""

    # Diretório de Instalação
    log_info "Diretório de instalação (padrão: $DEFAULT_INSTALL_DIR)"
    read -p "Caminho: " -i "$DEFAULT_INSTALL_DIR" -e INSTALL_ROOT
    INSTALL_ROOT="${INSTALL_ROOT:-$DEFAULT_INSTALL_DIR}"

    # Diretório de Backups
    log_info ""
    log_info "Diretório de backups (padrão: $DEFAULT_BACKUP_DIR)"
    read -p "Caminho: " -i "$DEFAULT_BACKUP_DIR" -e BACKUP_ROOT
    BACKUP_ROOT="${BACKUP_ROOT:-$DEFAULT_BACKUP_DIR}"

    # Diretório de Logs
    log_info ""
    log_info "Diretório de logs (padrão: $DEFAULT_LOG_DIR)"
    read -p "Caminho: " -i "$DEFAULT_LOG_DIR" -e LOG_ROOT
    LOG_ROOT="${LOG_ROOT:-$DEFAULT_LOG_DIR}"

    # Tipo de links
    log_info ""
    log_info "Usar cópias transacionais ou symlinks para o checkout?"
    echo "  1. 📋 Cópias (recomendado; permite validação e rollback)"
    echo "  2. 🔗 Symlinks (mudam imediatamente com o checkout)"
    echo ""
    read -p "Escolha (1-2): " LINK_TYPE
    USE_SYMLINKS=$([ "$LINK_TYPE" = "2" ] && echo "true" || echo "false")

    echo ""
}

validate_paths() {
    log_section "VALIDAÇÃO DE CAMINHOS"

    # Definir INSTALL_CONFIG baseado no INSTALL_ROOT escolhido
    INSTALL_CONFIG="$INSTALL_ROOT/.install.conf"

    # Validar que os caminhos são diferentes
    if [ "$INSTALL_ROOT" = "$BACKUP_ROOT" ] || [ "$INSTALL_ROOT" = "$LOG_ROOT" ]; then
        log_error "Os caminhos devem ser diferentes!"
        return 1
    fi

    case "$INSTALL_ROOT" in
        ""|/|/opt|/usr|/etc|/var) log_error "Diretório de instalação inseguro: $INSTALL_ROOT"; return 1 ;;
    esac

    # Criar diretórios pai se necessário. Em raiz simulada, os pais pertencem ao
    # próprio fixture e podem ser criados pelo instalador.
    for path in "$INSTALL_ROOT" "$BACKUP_ROOT" "$LOG_ROOT"; do
        parent_dir=$(dirname "$path")
        if [ ! -d "$parent_dir" ]; then
            if [ -n "$SYSTEM_ROOT" ]; then
                mkdir -p "$parent_dir"
            else
                log_error "Diretório pai não existe: $parent_dir"
                return 1
            fi
        fi
    done

    log_success "Validação de caminhos OK"
    echo ""
}

# ═══════════════════════════════════════════════════════════════════════════════
# INSTALAÇÃO/ATUALIZAÇÃO
# ═══════════════════════════════════════════════════════════════════════════════

prepare_installation() {
    log_section "PREPARAÇÃO PARA INSTALAÇÃO"

    # Criar diretórios
    log_info "Criando diretórios..."
    mkdir -p "$INSTALL_ROOT"/{backup,manutencao,migrar,scripts-auxiliares,docs,lib,monitor,config}
    mkdir -p "$BACKUP_ROOT"/{coolify,volumes,databases}
    mkdir -p "$LOG_ROOT"

    # Dados mutáveis M5–M8. mkdir -p é idempotente e nunca zera estado.
    MONITOR_STATE_ROOT="${MONITOR_STATE_ROOT:-$(system_path /var/lib/vpsguardian/monitor)}"
    mkdir -p "$MONITOR_STATE_ROOT"/history/{metrics,containers,workers,events,diagnostics,indexes,reports}
    mkdir -p "$MONITOR_STATE_ROOT/incidents"
    chmod 0750 "$MONITOR_STATE_ROOT" "$MONITOR_STATE_ROOT/history" "$MONITOR_STATE_ROOT/incidents"
    log_success "Diretórios criados (estado, histórico e incidentes preservados)"

    echo ""
}

install_scripts() {
    log_section "INSTALANDO SCRIPTS"

    local link_cmd="cp -v"
    if [ "$USE_SYMLINKS" = "true" ]; then
        link_cmd="ln -sf"
    fi

    # Instalar backup scripts
    log_info "Instalando scripts de backup..."
    for script in "$SOURCE_DIR"/backup/*.sh; do
        if [ -f "$script" ]; then
            $link_cmd "$script" "$INSTALL_ROOT/backup/$(basename "$script")"
        fi
    done
    log_success "Scripts de backup instalados"

    # Instalar maintenance scripts
    log_info "Instalando scripts de manutenção..."
    for script in "$SOURCE_DIR"/manutencao/*.sh; do
        if [ -f "$script" ]; then
            $link_cmd "$script" "$INSTALL_ROOT/manutencao/$(basename "$script")"
        fi
    done
    log_success "Scripts de manutenção instalados"

    # Instalar migration scripts
    log_info "Instalando scripts de migração..."
    for script in "$SOURCE_DIR"/migrar/*.sh; do
        if [ -f "$script" ]; then
            $link_cmd "$script" "$INSTALL_ROOT/migrar/$(basename "$script")"
        fi
    done
    log_success "Scripts de migração instalados"

    # Instalar auxiliary scripts
    log_info "Instalando scripts auxiliares..."
    for script in "$SOURCE_DIR"/scripts-auxiliares/*.sh; do
        if [ -f "$script" ]; then
            $link_cmd "$script" "$INSTALL_ROOT/scripts-auxiliares/$(basename "$script")"
        fi
    done
    log_success "Scripts auxiliares instalados"

    # Nomes oficiais aposentados. Mantê-los após um upgrade cria duas rotas para
    # a mesma operação e faz menus/crons antigos chamarem implementações obsoletas.
    rm -f "$INSTALL_ROOT/backup/backup-coolify-s3.sh" \
          "$INSTALL_ROOT/backup/backup-databases.sh" \
          "$INSTALL_ROOT/backup/backup-volume.sh" \
          "$INSTALL_ROOT/migrar/backup-database-volumes.sh"

    # Instalar bibliotecas compartilhadas
    log_info "Instalando bibliotecas compartilhadas..."
    for lib in "$SOURCE_DIR"/lib/*.sh; do
        if [ -f "$lib" ]; then
            $link_cmd "$lib" "$INSTALL_ROOT/lib/$(basename "$lib")"
        fi
    done
    log_success "Bibliotecas instaladas"

    # Instalar monitor preventivo
    log_info "Instalando monitor preventivo..."
    for script in "$SOURCE_DIR"/monitor/*.sh; do
        if [ -f "$script" ]; then
            $link_cmd "$script" "$INSTALL_ROOT/monitor/$(basename "$script")"
        fi
    done
    log_success "Monitor preventivo instalado"

    # Configuração modular já é um padrão do projeto. Arquivos ativos nunca são
    # sobrescritos; defaults e exemplos são código imutável e são atualizados.
    log_info "Instalando configurações e exemplos..."
    for config_file in default.conf monitor.conf.example retention.conf.example \
                       migration.conf.example crontab-exemplo.txt; do
        if [ -f "$SOURCE_DIR/config/$config_file" ]; then
            $link_cmd "$SOURCE_DIR/config/$config_file" "$INSTALL_ROOT/config/$config_file"
        fi
    done
    if [ ! -e "$INSTALL_ROOT/config/backup-destinations.conf" ] && \
       [ -f "$SOURCE_DIR/config/backup-destinations.conf" ]; then
        cp -p "$SOURCE_DIR/config/backup-destinations.conf" \
            "$INSTALL_ROOT/config/backup-destinations.conf"
    fi
    log_success "Configuração ativa preservada; exemplos atualizados"

    # Instalar menu principal
    log_info "Instalando menu principal..."
    $link_cmd "$SOURCE_DIR/menu-principal.sh" "$INSTALL_ROOT/menu-principal.sh"
    log_success "Menu principal instalado"

    # Instalar documentação
    if [ -d "$SOURCE_DIR/docs" ]; then
        log_info "Instalando documentação..."
        cp -r "$SOURCE_DIR/docs/." "$INSTALL_ROOT/docs/"
        log_success "Documentação instalada"
    fi

    echo ""
}

set_permissions() {
    log_section "CONFIGURANDO PERMISSÕES"

    log_info "Configurando permissões de execução..."
    find "$INSTALL_ROOT" -name "*.sh" -type f -exec chmod +x {} \;
    find "$INSTALL_ROOT/lib" -maxdepth 1 -type f -name 'monitor-*.sh' -exec chmod 0644 {} \;
    chmod 0755 "$INSTALL_ROOT/monitor/vps-monitor.sh"
    log_success "Permissões configuradas"

    log_info "Configurando permissões de diretórios..."
    chmod 755 "$INSTALL_ROOT"/{backup,manutencao,migrar,scripts-auxiliares,docs,lib,monitor}
    chmod 750 "$INSTALL_ROOT/config"
    find "$INSTALL_ROOT/config" -maxdepth 1 -type f -name '*.conf' -exec chmod 640 {} \;
    find "$INSTALL_ROOT/config" -maxdepth 1 -type f -name '*.example' -exec chmod 640 {} \;
    chmod 700 "$BACKUP_ROOT" "$BACKUP_ROOT"/{coolify,volumes,databases}
    chmod 750 "$LOG_ROOT"
    log_success "Permissões de diretórios OK"

    echo ""
}

install_systemd_units() {
    log_section "INTEGRANDO MONITOR AO SYSTEMD"

    local unit_source="$SOURCE_DIR/monitor/systemd"
    local unit_target
    unit_target="$(system_path /etc/systemd/system)"
    mkdir -p "$unit_target"

    install -m 0644 "$unit_source/vpsguardian-monitor.service" \
        "$unit_target/vpsguardian-monitor.service"
    install -m 0644 "$unit_source/vpsguardian-monitor.timer" \
        "$unit_target/vpsguardian-monitor.timer"

    if [ "$SKIP_SYSTEMCTL" = true ]; then
        log_info "systemctl ignorado na raiz simulada"
    elif command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload
        systemctl enable --now vpsguardian-monitor.timer
    else
        log_warning "systemctl não encontrado; unidades instaladas, mas timer não ativado"
    fi
    log_success "Unidades do monitor instaladas sem duplicação"
}

# ═══════════════════════════════════════════════════════════════════════════════
# SALVAR CONFIGURAÇÃO
# ═══════════════════════════════════════════════════════════════════════════════

save_configuration() {
    log_section "SALVANDO CONFIGURAÇÃO"

    # Criar arquivo de configuração
    mkdir -p "$(dirname "$INSTALL_CONFIG")"

    cat > "$INSTALL_CONFIG" << EOF
# Configuração de Instalação - $(date)
INSTALL_ROOT=$(printf '%q' "$INSTALL_ROOT")
BACKUP_ROOT=$(printf '%q' "$BACKUP_ROOT")
LOG_ROOT=$(printf '%q' "$LOG_ROOT")
USE_SYMLINKS=$(printf '%q' "$USE_SYMLINKS")
MONITOR_STATE_ROOT=$(printf '%q' "$MONITOR_STATE_ROOT")
VPSGUARDIAN_VERSION=$(printf '%q' "$VPSGUARDIAN_VERSION")
MONITOR_VERSION=$(printf '%q' "$MONITOR_VERSION")
INSTALLED="true"
EOF

    # Contém apenas caminhos e versões, sem credenciais; precisa ser legível pelo
    # wrapper global quando comandos read-only rodam sem sudo.
    chmod 0644 "$INSTALL_CONFIG"

    log_success "Configuração salva em: $INSTALL_CONFIG"

    # Metadado canônico usado pelo wrapper para descobrir instalações customizadas.
    local canonical_config
    canonical_config="$(system_path /etc/vpsguardian/install.conf)"
    mkdir -p "$(dirname "$canonical_config")"
    if [ "$INSTALL_CONFIG" != "$INSTALL_ROOT/.install.conf" ]; then
        cp "$INSTALL_CONFIG" "$INSTALL_ROOT/.install.conf"
    fi
    cp "$INSTALL_ROOT/.install.conf" "$canonical_config"
    chmod 0644 "$INSTALL_ROOT/.install.conf" "$canonical_config"
    log_success "Metadados da instalação registrados em: $canonical_config"

    echo ""
}

# ═══════════════════════════════════════════════════════════════════════════════
# CRIAR COMANDOS GLOBAIS
# ═══════════════════════════════════════════════════════════════════════════════

create_global_commands() {
    log_section "CRIANDO COMANDOS GLOBAIS"

    local bin_dir
    bin_dir="$(system_path /usr/local/bin)"
    mkdir -p "$bin_dir"

    # Wrapper principal inteligente: vps-guardian
    cat > "$bin_dir/vps-guardian" << 'WRAPPER_EOF'
#!/bin/bash

# Procurar arquivo de configuração em locais possíveis
INSTALL_CONFIG=""
for config in "${VPSGUARDIAN_INSTALL_CONFIG:-}" "/etc/vpsguardian/install.conf" "/opt/vpsguardian/.install.conf" "/opt/vpsguardian-src/.install.conf" "/opt/"*"/.install.conf"; do
    if [ -n "$config" ] && [ -f "$config" ]; then
        INSTALL_CONFIG="$config"
        break
    fi
done

if [ -z "$INSTALL_CONFIG" ]; then
    echo "❌ Erro: VPS Guardian não está instalado"
    echo "Execute: sudo ./instalar.sh"
    exit 1
fi

source "$INSTALL_CONFIG"
export VPSGUARDIAN_ROOT="$INSTALL_ROOT"
export MONITOR_INSTALL_ROOT="$INSTALL_ROOT"
export MONITOR_STATE_DIR="${MONITOR_STATE_ROOT:-/var/lib/vpsguardian/monitor}"
export VPSGUARDIAN_VERSION="${VPSGUARDIAN_VERSION:-1.0.0}"
export MONITOR_VERSION="${MONITOR_VERSION:-1.0.0}"

# Cores
BLUE='\033[0;34m'
GREEN='\033[0;32m'
NC='\033[0m'

show_help() {
    echo -e "${GREEN}🛡️  VPS Guardian${NC} - Sistema de Manutenção e Backup VPS"
    echo ""
    echo "Uso: vps-guardian [comando] [opções]"
    echo ""
    echo "Comandos Principais:"
    echo "  menu              📋 Abre o menu principal interativo"
    echo "  backup            📦 Faz backup completo do Coolify (local)"
    echo "  backup-s3         ☁️  Faz backup completo + envia para S3"
    echo "  migrate           🚀 Migra Coolify para novo servidor"
    echo "  restore           ♻️  Restaura backup do Coolify"
    echo ""
    echo "Manutenção:"
    echo "  status            📊 Mostra status completo do sistema"
    echo "  firewall          🔥 Gerenciador interativo de firewall"
    echo "  maintenance       🔧 Executa manutenção completa"
    echo "  updates           🔄 Configura updates automáticos"
    echo "  monitor           🩺 Opera o monitor preventivo"
    echo ""
    echo "Configuração:"
    echo "  cron              ⏰ Configura cron jobs para backups"
    echo "  --help, -h        ❓ Mostra esta ajuda"
    echo "  --version, -v     ℹ️  Mostra versão"
    echo ""
    echo "Exemplos:"
    echo "  vps-guardian              # Abre menu principal"
    echo "  vps-guardian backup       # Backup local do Coolify"
    echo "  vps-guardian backup-s3    # Backup + upload para S3"
    echo "  vps-guardian firewall     # Gerenciar firewall (interativo)"
    echo "  vps-guardian migrate      # Migrar para novo servidor"
    echo "  vps-guardian status       # Ver status do sistema"
    echo "  vps-guardian monitor self-check # Validar integração do monitor"
    echo ""
    echo "Aliases Disponíveis:"
    echo "  firewall-vps      = vps-guardian firewall"
    echo "  backup-vps        = vps-guardian backup"
    echo "  backup-s3-vps     = vps-guardian backup-s3"
    echo "  status-vps        = vps-guardian status"
    echo ""
}

show_version() {
    echo -e "${GREEN}VPS Guardian${NC} v${VPSGUARDIAN_VERSION:-1.0.0}"
    echo "Monitor Preventivo v${MONITOR_VERSION:-1.0.0}"
    echo "Sistema de Manutenção e Backup VPS"
    echo "Instalado em: $INSTALL_ROOT"
    echo ""
}

# Se sem argumentos, abre menu
if [ $# -eq 0 ]; then
    exec sudo bash "$INSTALL_ROOT/menu-principal.sh"
fi

# Processar comando
case "$1" in
    menu)
        exec sudo bash "$INSTALL_ROOT/menu-principal.sh"
        ;;
    backup)
        exec sudo bash "$INSTALL_ROOT/backup/backup-coolify.sh" "${@:2}"
        ;;
    backup-s3)
        if [ -f "$INSTALL_ROOT/backup/backup-coolify.sh" ]; then
            # O backup principal envia automaticamente aos destinos habilitados,
            # inclusive S3, pelo backend compartilhado backup-destinos.sh.
            exec sudo bash "$INSTALL_ROOT/backup/backup-coolify.sh" "${@:2}"
        else
            echo "❌ Script de backup não encontrado"
            exit 1
        fi
        ;;
    status)
        if [ -f "$INSTALL_ROOT/scripts-auxiliares/verificar-saude-completa.sh" ]; then
            exec bash "$INSTALL_ROOT/scripts-auxiliares/verificar-saude-completa.sh" "${@:2}"
        else
            echo "❌ Script de status não encontrado"
            exit 1
        fi
        ;;
    firewall)
        # Prioriza o firewall interativo se existir
        if [ -f "$INSTALL_ROOT/manutencao/firewall-interativo.sh" ]; then
            exec sudo bash "$INSTALL_ROOT/manutencao/firewall-interativo.sh" "${@:2}"
        elif [ -f "$INSTALL_ROOT/manutencao/firewall-perfil-padrao.sh" ]; then
            exec sudo bash "$INSTALL_ROOT/manutencao/firewall-perfil-padrao.sh" "${@:2}"
        else
            echo "❌ Script de firewall não encontrado"
            exit 1
        fi
        ;;
    migrate)
        if [ -f "$INSTALL_ROOT/migrar/migrar-coolify.sh" ]; then
            exec sudo bash "$INSTALL_ROOT/migrar/migrar-coolify.sh" "${@:2}"
        else
            echo "❌ Script de migração não encontrado"
            exit 1
        fi
        ;;
    restore)
        if [ -f "$INSTALL_ROOT/backup/restaurar-coolify-remoto.sh" ]; then
            exec sudo bash "$INSTALL_ROOT/backup/restaurar-coolify-remoto.sh" "${@:2}"
        else
            echo "❌ Script de restauração não encontrado"
            exit 1
        fi
        ;;
    maintenance)
        if [ -f "$INSTALL_ROOT/manutencao/manutencao-completa.sh" ]; then
            exec sudo bash "$INSTALL_ROOT/manutencao/manutencao-completa.sh" "${@:2}"
        else
            echo "❌ Script de manutenção não encontrado"
            exit 1
        fi
        ;;
    updates)
        if [ -f "$INSTALL_ROOT/manutencao/configurar-updates-automaticos.sh" ]; then
            exec sudo bash "$INSTALL_ROOT/manutencao/configurar-updates-automaticos.sh" "${@:2}"
        else
            echo "❌ Script de updates não encontrado"
            exit 1
        fi
        ;;
    monitor)
        if [ -x "$INSTALL_ROOT/monitor/vps-monitor.sh" ]; then
            exec "$INSTALL_ROOT/monitor/vps-monitor.sh" "${@:2}"
        else
            echo "❌ Monitor preventivo não encontrado"
            exit 1
        fi
        ;;
    cron)
        if [ -f "$INSTALL_ROOT/scripts-auxiliares/configurar-cron.sh" ]; then
            exec sudo bash "$INSTALL_ROOT/scripts-auxiliares/configurar-cron.sh" "${@:2}"
        else
            echo "❌ Script de cron não encontrado"
            exit 1
        fi
        ;;
    --help|-h)
        show_help
        ;;
    --version|-v)
        show_version
        ;;
    *)
        echo "❌ Comando desconhecido: $1"
        echo ""
        show_help
        exit 1
        ;;
esac
WRAPPER_EOF

    chmod +x "$bin_dir/vps-guardian"
    log_success "Comando global criado: vps-guardian"

    # Criar aliases úteis
    log_info "Criando aliases úteis..."

    # firewall-vps
    ln -sf "$bin_dir/vps-guardian" "$bin_dir/firewall-vps"
    cat > "$bin_dir/.firewall-vps-wrapper" << 'EOF'
#!/bin/bash
exec vps-guardian firewall "$@"
EOF
    chmod +x "$bin_dir/.firewall-vps-wrapper"
    ln -sf "$bin_dir/.firewall-vps-wrapper" "$bin_dir/firewall-vps"

    # backup-vps
    cat > "$bin_dir/backup-vps" << 'EOF'
#!/bin/bash
exec vps-guardian backup "$@"
EOF
    chmod +x "$bin_dir/backup-vps"

    # status-vps
    cat > "$bin_dir/status-vps" << 'EOF'
#!/bin/bash
exec vps-guardian status "$@"
EOF
    chmod +x "$bin_dir/status-vps"

    # backup-s3-vps
    cat > "$bin_dir/backup-s3-vps" << 'EOF'
#!/bin/bash
exec vps-guardian backup-s3 "$@"
EOF
    chmod +x "$bin_dir/backup-s3-vps"

    log_success "Aliases criados: firewall-vps, backup-vps, backup-s3-vps, status-vps"
    echo ""
    log_info "Teste os comandos:"
    echo "  • vps-guardian --help"
    echo "  • firewall-vps (abre firewall interativo)"
    echo "  • backup-vps (faz backup)"
    echo "  • status-vps (mostra status)"
    echo ""
}

# ═══════════════════════════════════════════════════════════════════════════════
# VERIFICAÇÃO PÓS-INSTALAÇÃO
# ═══════════════════════════════════════════════════════════════════════════════

validate_monitor_syntax() {
    local root="${1:-$INSTALL_ROOT}"
    local file

    [ -f "$root/monitor/vps-monitor.sh" ] || {
        log_error "Monitor não encontrado em $root/monitor/vps-monitor.sh"
        return 1
    }
    bash -n "$root/monitor/vps-monitor.sh"
    for file in "$root"/lib/monitor-*.sh; do
        [ -f "$file" ] || continue
        bash -n "$file"
    done
}

run_monitor_smoke_test() {
    local smoke_state rc
    smoke_state=$(mktemp -d "${TMPDIR:-/tmp}/vpsguardian-monitor-smoke.XXXXXX")

    set +e
    MONITOR_CONFIG_FILE=/dev/null \
    MONITOR_STATE_DIR="$smoke_state" \
    MONITOR_LOG_DIR="$smoke_state/log" \
    MONITOR_LOCK_FILE="$smoke_state/monitor.lock" \
    MONITOR_CPU_SAMPLE_INTERVAL=0 \
    MONITOR_DOCKER_BIN=/bin/false \
    MONITOR_CTR_BIN=/bin/false \
    MONITOR_SYSTEMCTL_BIN=/bin/false \
    MONITOR_DOCKER_TIMEOUT_SECONDS=1 \
    MONITOR_CONTAINERD_TIMEOUT_SECONDS=1 \
        "$INSTALL_ROOT/monitor/vps-monitor.sh" check --dry-run --no-alerts \
        --no-history --quiet >/dev/null 2>&1
    rc=$?
    set -e

    rm -rf "$smoke_state"
    # 0–4 são severidades válidas do check; qualquer outro código é falha técnica.
    [ "$rc" -ge 0 ] && [ "$rc" -le 4 ]
}

audit_monitor_duplicates() {
    local unit_dir
    unit_dir="$(system_path /etc/systemd/system)"

    [ -x "$INSTALL_ROOT/monitor/vps-monitor.sh" ] || return 1
    [ -f "$unit_dir/vpsguardian-monitor.service" ] || return 1
    [ -f "$unit_dir/vpsguardian-monitor.timer" ] || return 1

    # Não pode haver uma segunda configuração ativa no fallback global.
    local active_configs=0 candidate
    for candidate in "$INSTALL_ROOT/config/monitor.conf" \
                     "$(system_path /etc/vpsguardian/monitor.conf)"; do
        [ -f "$candidate" ] && active_configs=$((active_configs + 1))
    done
    [ "$active_configs" -le 1 ]

    # Um update deve remover os nomes antigos que duplicavam os backends atuais.
    local retired
    for retired in backup/backup-coolify-s3.sh backup/backup-databases.sh \
                   backup/backup-volume.sh migrar/backup-database-volumes.sh; do
        [ ! -e "$INSTALL_ROOT/$retired" ] || return 1
    done
}

verify_installation() {
    log_section "VERIFICAÇÃO PÓS-INSTALAÇÃO"

    local errors=0

    # Verificar diretórios
    for dir in "$INSTALL_ROOT" "$BACKUP_ROOT" "$LOG_ROOT"; do
        if [ -d "$dir" ]; then
            log_success "Diretório OK: $dir"
        else
            log_error "Diretório não encontrado: $dir"
            errors=$((errors + 1))
        fi
    done

    # Verificar scripts principais
    for script in menu-principal.sh backup/backup-coolify.sh \
                  manutencao/configurar-updates-automaticos.sh \
                  monitor/vps-monitor.sh; do
        script_path="$INSTALL_ROOT/$script"
        if [ -f "$script_path" ] && [ -x "$script_path" ]; then
            log_success "Script OK: $script"
        else
            log_error "Script não encontrado ou não executável: $script"
            errors=$((errors + 1))
        fi
    done

    if ! validate_monitor_syntax "$INSTALL_ROOT"; then
        log_error "Sintaxe do monitor ou de suas bibliotecas é inválida"
        errors=$((errors + 1))
    else
        log_success "Sintaxe do monitor validada"
    fi

    if ! audit_monitor_duplicates; then
        log_error "Auditoria detectou instalação incompleta ou configuração concorrente"
        errors=$((errors + 1))
    else
        log_success "Auditoria de duplicação OK"
    fi

    local config_check_env=()
    if [ -n "$SYSTEM_ROOT" ]; then
        config_check_env=(
            "MONITOR_CONFIG_FILE=$INSTALL_ROOT/config/monitor.conf"
            "VPSGUARDIAN_SHARED_CONFIG_FILE=$INSTALL_ROOT/config/backup-destinations.conf"
        )
    fi
    if ! env "${config_check_env[@]}" \
        "$INSTALL_ROOT/monitor/vps-monitor.sh" config-check >/dev/null; then
        log_error "config-check da instalação falhou"
        errors=$((errors + 1))
    else
        log_success "config-check validou a configuração real"
    fi

    if ! env "${config_check_env[@]}" \
        MONITOR_STATE_DIR="$MONITOR_STATE_ROOT" \
        MONITOR_SYSTEMD_DIR="$(system_path /etc/systemd/system)" \
        MONITOR_SELF_CHECK_SKIP_SYSTEMCTL=1 \
        "$INSTALL_ROOT/monitor/vps-monitor.sh" self-check >/dev/null; then
        log_error "self-check da instalação falhou"
        errors=$((errors + 1))
    else
        log_success "self-check validou caminhos, unidades, dados e versões"
    fi

    if ! run_monitor_smoke_test; then
        log_error "Smoke test não destrutivo do monitor falhou"
        errors=$((errors + 1))
    else
        log_success "Smoke test do monitor concluído"
    fi

    # Verificar comando global na raiz real ou simulada.
    if [ -x "$(system_path /usr/local/bin/vps-guardian)" ]; then
        log_success "Comando global OK: vps-guardian"
    else
        log_error "Comando global não encontrado"
        errors=$((errors + 1))
    fi

    echo ""
    if [ $errors -eq 0 ]; then
        log_success "✅ Instalação verificada com sucesso!"
        return 0
    else
        log_error "❌ Instalação com $errors erro(s)"
        return 1
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# CONFIGURAÇÃO OPCIONAL
# ═══════════════════════════════════════════════════════════════════════════════

offer_additional_config() {
    log_section "CONFIGURAÇÃO ADICIONAL"

    log_info "Deseja configurar agora?"
    echo ""
    echo "  1. 🔧 Configurar firewall"
    echo "  2. 🔄 Configurar updates automáticos"
    echo "  3. ⏰ Configurar cron jobs"
    echo "  4. 📧 Configurar notificações por email"
    echo "  5. 🚀 Nenhuma (continuar depois)"
    echo ""

    read -p "Escolha uma opção (1-5): " CONFIG_CHOICE

    case $CONFIG_CHOICE in
        1)
            log_info "Iniciando configuração de firewall..."
            sudo bash "$INSTALL_ROOT/manutencao/firewall-perfil-padrao.sh"
            ;;
        2)
            log_info "Iniciando configuração de updates automáticos..."
            sudo bash "$INSTALL_ROOT/manutencao/configurar-updates-automaticos.sh"
            ;;
        3)
            log_info "Iniciando configuração de cron jobs..."
            sudo bash "$INSTALL_ROOT/scripts-auxiliares/configurar-cron.sh"
            ;;
        4)
            log_warning "Email será configurado nos scripts individuais"
            ;;
        *)
            log_info "Configurações adicionais podem ser feitas depois"
            ;;
    esac

    echo ""
}

# ═══════════════════════════════════════════════════════════════════════════════
# DESINSTALAÇÃO
# ═══════════════════════════════════════════════════════════════════════════════

remove_monitor_units() {
    local unit_dir
    unit_dir="$(system_path /etc/systemd/system)"

    if [ "$SKIP_SYSTEMCTL" != true ] && command -v systemctl >/dev/null 2>&1; then
        systemctl disable --now vpsguardian-monitor.timer 2>/dev/null || true
        systemctl stop vpsguardian-monitor.service 2>/dev/null || true
    fi

    rm -f "$unit_dir/vpsguardian-monitor.service" \
          "$unit_dir/vpsguardian-monitor.timer"

    if [ "$SKIP_SYSTEMCTL" != true ] && command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload
    fi
}

remove_monitor_files() {
    rm -f "$INSTALL_ROOT/monitor/vps-monitor.sh"
    rm -f "$INSTALL_ROOT"/lib/monitor-*.sh
    rm -f "$INSTALL_ROOT/config/monitor.conf.example"
    rmdir "$INSTALL_ROOT/monitor" 2>/dev/null || true
}

purge_monitor_data() {
    [ "$PURGE_ALL" = true ] && {
        PURGE_CONFIG=true
        PURGE_STATE=true
        PURGE_HISTORY=true
        PURGE_INCIDENTS=true
    }

    if [ "$PURGE_CONFIG" = true ]; then
        rm -f "$INSTALL_ROOT/config/monitor.conf"
        rm -f "$(system_path /etc/vpsguardian/monitor.conf)"
    fi

    if [ "$PURGE_HISTORY" = true ]; then
        rm -rf "$MONITOR_STATE_ROOT/history"
    fi
    if [ "$PURGE_INCIDENTS" = true ]; then
        rm -rf "$MONITOR_STATE_ROOT/incidents"
    fi
    if [ "$PURGE_STATE" = true ]; then
        rm -f "$MONITOR_STATE_ROOT/previous-metrics.env" \
              "$MONITOR_STATE_ROOT/last-check.json" \
              "$MONITOR_STATE_ROOT/incidents.state" \
              "$MONITOR_STATE_ROOT/diagnoses.state" \
              "$MONITOR_STATE_ROOT/monitor.lock" \
              "$MONITOR_STATE_ROOT/emergency.lock"
    fi
    if [ "$PURGE_ALL" = true ]; then
        rmdir "$MONITOR_STATE_ROOT" 2>/dev/null || true
    fi
}

uninstall() {
    log_section "DESINSTALAÇÃO"

    log_warning "Você está prestes a desinstalar o sistema"
    log_warning "Backups, logs e histórico do monitor serão PRESERVADOS"
    echo ""

    if [ "$NON_INTERACTIVE" != true ]; then
        read -p "Digite 'SIM' para confirmar desinstalação: " CONFIRM
        if [ "$CONFIRM" != "SIM" ]; then
            log_info "Desinstalação cancelada"
            return
        fi
    fi

    echo ""
    log_info "Parando e removendo unidades do monitor..."
    remove_monitor_units
    remove_monitor_files

    if [ "$MONITOR_ONLY" = true ]; then
        purge_monitor_data
        log_success "Monitor removido; configuração e dados preservados conforme as opções de purge"
        return 0
    fi

    log_info "Removendo scripts imutáveis..."
    rm -rf "$INSTALL_ROOT/backup" "$INSTALL_ROOT/manutencao" \
           "$INSTALL_ROOT/migrar" "$INSTALL_ROOT/scripts-auxiliares" \
           "$INSTALL_ROOT/docs" "$INSTALL_ROOT/lib" "$INSTALL_ROOT/monitor"
    rm -f "$INSTALL_ROOT/menu-principal.sh"
    rm -f "$INSTALL_ROOT/config/default.conf" \
          "$INSTALL_ROOT/config/monitor.conf.example" \
          "$INSTALL_ROOT/config/retention.conf.example" \
          "$INSTALL_ROOT/config/migration.conf.example" \
          "$INSTALL_ROOT/config/crontab-exemplo.txt"
    log_success "Scripts removidos; configurações ativas preservadas"

    log_info "Removendo comandos globais..."
    local bin_dir
    bin_dir="$(system_path /usr/local/bin)"
    rm -f "$bin_dir/vps-guardian" "$bin_dir/firewall-vps" \
          "$bin_dir/.firewall-vps-wrapper" "$bin_dir/backup-vps" \
          "$bin_dir/status-vps" "$bin_dir/backup-s3-vps"
    log_success "Comandos globais removidos"

    log_info "Removendo metadados da instalação..."
    rm -f "$INSTALL_ROOT/.install.conf" "$INSTALL_CONFIG" \
          "$(system_path /etc/vpsguardian/install.conf)"
    purge_monitor_data

    log_warning "Backups, logs, configuração e dados do monitor preservados por padrão:"
    log_warning "  - $BACKUP_ROOT"
    log_warning "  - $LOG_ROOT"
    log_warning "  - $INSTALL_ROOT/config"
    log_warning "  - $MONITOR_STATE_ROOT"
    echo ""

    log_success "✅ Desinstalação concluída"
}

# ═══════════════════════════════════════════════════════════════════════════════
# RESUMO FINAL
# ═══════════════════════════════════════════════════════════════════════════════

show_summary() {
    log_section "RESUMO DA INSTALAÇÃO"

    echo -e "${GREEN}✅ INSTALAÇÃO CONCLUÍDA COM SUCESSO${NC}"
    echo ""

    echo "📍 Localização:"
    echo "   • Scripts: $INSTALL_ROOT"
    echo "   • Backups: $BACKUP_ROOT"
    echo "   • Logs:    $LOG_ROOT"
    echo ""

    echo "🔗 Tipo de links:"
    echo "   • $([ "$USE_SYMLINKS" = "true" ] && echo "Symlinks (atualizações fáceis com git pull)" || echo "Cópias")"
    echo ""

    echo "🛡️  Comando disponível:"
    echo "   • vps-guardian [comando]"
    echo ""
    echo "   Subcomandos:"
    echo "     - vps-guardian            (abre menu principal)"
    echo "     - vps-guardian backup     (faz backup)"
    echo "     - vps-guardian status     (mostra status)"
    echo "     - vps-guardian firewall   (configura firewall)"
    echo "     - vps-guardian updates    (configura updates)"
    echo "     - vps-guardian monitor    (monitor preventivo)"
    echo "     - vps-guardian cron       (configura cron)"
    echo "     - vps-guardian --help     (mostra ajuda)"
    echo ""

    echo "📚 Próximos passos:"
    echo "   1. Execute o menu: ${CYAN}vps-guardian${NC}"
    echo "   2. Configure firewall: ${CYAN}vps-guardian firewall${NC} (ou Menu → 5 → 1)"
    echo "   3. Configure updates: ${CYAN}vps-guardian updates${NC} (ou Menu → 3 → 3)"
    echo "   4. Configure cron: ${CYAN}vps-guardian cron${NC} (ou Menu → 5 → 2)"
    echo "   5. Faça primeiro backup: ${CYAN}vps-guardian backup${NC}"
    echo ""

    echo "📖 Documentação:"
    echo "   • Manual completo: $INSTALL_ROOT/docs/MANUAL-COMPLETO-DO-SISTEMA.md"
    echo "   • README: Veja $(pwd)/README.md"
    echo ""

    echo "📞 Suporte:"
    echo "   • Acesso remoto seguro via Cloudflare Tunnel"
    echo "   • Zero Trust com WARP + Email Auth"
    echo "   • SSH restrito a LAN local"
    echo ""

    echo -e "${GREEN}Instalação concluída. Valide o primeiro backup e um restore antes de produção. 🎉${NC}"
    echo ""
}

# ═══════════════════════════════════════════════════════════════════════════════
# BACKUP E ROLLBACK DO MODO UPDATE (somente código imutável)
# ═══════════════════════════════════════════════════════════════════════════════

backup_monitor_for_rollback() {
    ROLLBACK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/vpsguardian-update-rollback.XXXXXX")
    local unit_dir bin_dir item file
    unit_dir="$(system_path /etc/systemd/system)"
    bin_dir="$(system_path /usr/local/bin)"

    # O atualizador substitui todos estes artefatos. O snapshot precisa cobrir o
    # mesmo conjunto; configurações ativas e dados mutáveis ficam deliberadamente
    # fora do rollback.
    mkdir -p "$ROLLBACK_DIR/install" "$ROLLBACK_DIR/install/config"
    for item in backup manutencao migrar scripts-auxiliares docs lib monitor menu-principal.sh; do
        if [ -e "$INSTALL_ROOT/$item" ]; then
            cp -aL "$INSTALL_ROOT/$item" "$ROLLBACK_DIR/install/$item"
        fi
    done
    for file in default.conf monitor.conf.example retention.conf.example \
                migration.conf.example crontab-exemplo.txt; do
        if [ -e "$INSTALL_ROOT/config/$file" ]; then
            cp -aL "$INSTALL_ROOT/config/$file" "$ROLLBACK_DIR/install/config/$file"
        fi
    done

    mkdir -p "$ROLLBACK_DIR/metadata" "$ROLLBACK_DIR/bin"
    [ -f "$INSTALL_ROOT/.install.conf" ] && \
        cp -a "$INSTALL_ROOT/.install.conf" "$ROLLBACK_DIR/metadata/install.conf"
    [ -f "$(system_path /etc/vpsguardian/install.conf)" ] && \
        cp -a "$(system_path /etc/vpsguardian/install.conf)" "$ROLLBACK_DIR/metadata/canonical-install.conf"
    for file in vps-guardian firewall-vps .firewall-vps-wrapper backup-vps status-vps backup-s3-vps; do
        [ -e "$bin_dir/$file" ] && cp -a "$bin_dir/$file" "$ROLLBACK_DIR/bin/$file"
    done

    mkdir -p "$ROLLBACK_DIR/systemd"
    for file in vpsguardian-monitor.service vpsguardian-monitor.timer; do
        if [ -e "$unit_dir/$file" ]; then
            cp -aL "$unit_dir/$file" "$ROLLBACK_DIR/systemd/$file"
            touch "$ROLLBACK_DIR/had-$file"
        fi
    done

    log_success "Backup pré-atualização criado para todos os artefatos imutáveis"
}

rollback_monitor_update() {
    [ -n "$ROLLBACK_DIR" ] && [ -d "$ROLLBACK_DIR" ] || return 1
    local unit_dir bin_dir file item
    unit_dir="$(system_path /etc/systemd/system)"
    bin_dir="$(system_path /usr/local/bin)"

    log_warning "Falha na atualização; restaurando versão instalada anterior..."
    for item in backup manutencao migrar scripts-auxiliares docs lib monitor; do
        rm -rf "$INSTALL_ROOT/$item"
    done
    rm -f "$INSTALL_ROOT/menu-principal.sh"
    for file in default.conf monitor.conf.example retention.conf.example \
                migration.conf.example crontab-exemplo.txt; do
        rm -f "$INSTALL_ROOT/config/$file"
    done
    rm -f "$unit_dir/vpsguardian-monitor.service" "$unit_dir/vpsguardian-monitor.timer"
    rm -f "$bin_dir/vps-guardian" "$bin_dir/firewall-vps" \
          "$bin_dir/.firewall-vps-wrapper" "$bin_dir/backup-vps" \
          "$bin_dir/status-vps" "$bin_dir/backup-s3-vps"

    mkdir -p "$INSTALL_ROOT" "$INSTALL_ROOT/config" "$unit_dir" "$bin_dir"
    cp -a "$ROLLBACK_DIR/install/." "$INSTALL_ROOT/"
    for file in "$ROLLBACK_DIR"/bin/* "$ROLLBACK_DIR"/bin/.[!.]*; do
        [ -e "$file" ] && cp -a "$file" "$bin_dir/"
    done
    if [ -f "$ROLLBACK_DIR/metadata/install.conf" ]; then
        cp -a "$ROLLBACK_DIR/metadata/install.conf" "$INSTALL_ROOT/.install.conf"
    fi
    if [ -f "$ROLLBACK_DIR/metadata/canonical-install.conf" ]; then
        mkdir -p "$(dirname "$(system_path /etc/vpsguardian/install.conf)")"
        cp -a "$ROLLBACK_DIR/metadata/canonical-install.conf" \
            "$(system_path /etc/vpsguardian/install.conf)"
    fi
    for file in vpsguardian-monitor.service vpsguardian-monitor.timer; do
        if [ -f "$ROLLBACK_DIR/had-$file" ]; then
            cp -a "$ROLLBACK_DIR/systemd/$file" "$unit_dir/$file"
        fi
    done

    if [ "$SKIP_SYSTEMCTL" != true ] && command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload || true
    fi
    log_success "Rollback global concluído; configuração e dados mutáveis não foram alterados"
}

cleanup_rollback() {
    if [ -n "$ROLLBACK_DIR" ] && [ -d "$ROLLBACK_DIR" ]; then
        rm -rf "$ROLLBACK_DIR"
    fi
    ROLLBACK_DIR=""
}

perform_update() {
    if [ "$USE_SYMLINKS" = true ]; then
        log_warning "Convertendo instalação por symlink em cópias para permitir atualização transacional futura"
        USE_SYMLINKS=false
    fi
    backup_monitor_for_rollback || return 1
    validate_monitor_syntax "$SOURCE_DIR" || return 1
    prepare_installation || return 1
    install_scripts || return 1
    set_permissions || return 1
    install_systemd_units || return 1
    create_global_commands || return 1
    save_configuration || return 1
    if [ "${VPSGUARDIAN_TEST_FAIL_AFTER_INSTALL:-false}" = true ]; then
        return 1
    fi
    verify_installation || return 1
}

# ═══════════════════════════════════════════════════════════════════════════════
# FLUXO PRINCIPAL
# ═══════════════════════════════════════════════════════════════════════════════

main() {
    parse_args "$@"
    [ "$NON_INTERACTIVE" = true ] || show_banner
    verify_root
    verify_directory
    load_previous_config

    [ -n "$CLI_INSTALL_ROOT" ] && INSTALL_ROOT="$CLI_INSTALL_ROOT"
    [ -n "$CLI_BACKUP_ROOT" ] && BACKUP_ROOT="$CLI_BACKUP_ROOT"
    [ -n "$CLI_LOG_ROOT" ] && LOG_ROOT="$CLI_LOG_ROOT"
    [ -n "$CLI_USE_SYMLINKS" ] && USE_SYMLINKS="$CLI_USE_SYMLINKS"
    [ "$NON_INTERACTIVE" = true ] && [ -z "$MODE" ] && {
        if [ "$INSTALLED" = true ]; then MODE=update; else MODE=install; fi
    }
    if [ "$INSTALLED" = true ]; then
        MONITOR_STATE_ROOT="${MONITOR_STATE_ROOT:-$(system_path /var/lib/vpsguardian/monitor)}"
    fi

    # Escolher modo
    if ! choose_installation_mode; then
        if [ "$NON_INTERACTIVE" = true ]; then
            exit 1
        fi
        main "$@"
        return
    fi

    case $MODE in
        uninstall)
            uninstall
            return
            ;;
        install|reinstall)
            if ! interactive_configuration || ! validate_paths; then
                if [ "$NON_INTERACTIVE" = true ]; then exit 1; fi
                main "$@"
                return
            fi
            validate_monitor_syntax "$SOURCE_DIR"
            prepare_installation
            install_scripts
            set_permissions
            create_global_commands
            save_configuration
            install_systemd_units
            verify_installation || exit 1
            [ "$NON_INTERACTIVE" = true ] || offer_additional_config
            show_summary
            ;;
        update)
            log_section "ATUALIZANDO"
            log_warning "Atualizando scripts mantendo configuração anterior..."
            validate_paths || exit 1
            if ! perform_update; then
                rollback_monitor_update || true
                cleanup_rollback
                log_error "Atualização falhou; versão anterior restaurada"
                exit 1
            fi
            cleanup_rollback
            log_success "✅ Sistema atualizado com sucesso!"
            echo ""
            ;;
    esac
}

# ═══════════════════════════════════════════════════════════════════════════════
# EXECUTAR
# ═══════════════════════════════════════════════════════════════════════════════

main "$@"
