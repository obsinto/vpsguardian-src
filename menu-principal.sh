#!/bin/bash
################################################################################
# MENU PRINCIPAL - Gerenciamento Centralizado de Scripts VPS
# Propósito: Interface unificada para acessar todas as ferramentas do repositório
# Autor: Sistema de Manutenção e Backup VPS
# Versão: 1.0
################################################################################

# Cores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
GRAY='\033[0;90m'
NC='\033[0m' # No Color

# Diretório base (resolve links simbólicos para encontrar o diretório real)
SCRIPT_PATH="${BASH_SOURCE[0]}"
# Se for link simbólico, resolve para o caminho real
if [ -L "$SCRIPT_PATH" ]; then
    SCRIPT_PATH="$(readlink -f "$SCRIPT_PATH")"
fi
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"

LOG_DIR="/var/log/manutencao"
LOG_FILE="$LOG_DIR/menu-execucoes.log"

# Criar diretório de logs se não existir
mkdir -p "$LOG_DIR"

################################################################################
# FUNÇÕES AUXILIARES
# Funções reutilizáveis em todo o menu para logging, UI e validação
################################################################################

# log_execution(mensagem)
# Registra a execução de scripts com timestamp
# Localização: /var/log/manutencao/menu-execucoes.log
# Uso: log_execution "INÍCIO: Backup Coolify"
log_execution() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# clear_screen()
# Limpa a tela do terminal antes de exibir novo menu
# Melhora legibilidade ao navegar entre menus
clear_screen() {
    clear
}

# pause()
# Aguarda usuário pressionar ENTER antes de continuar
# Permite ler output do script antes de voltar ao menu
# Uso: Após cada execução de script
pause() {
    echo ""
    echo -e "${GRAY}Pressione ENTER para continuar...${NC}"
    read -r
}

# confirm(mensagem)
# Confirmação simples (sim/não) para operações normais
# Retorna: 0 (sim), 1 (não)
# Uso: if confirm "Executar backup?"; then
# Diferente de confirm_critical que é para operações críticas
confirm() {
    local message="$1"
    echo ""
    echo -e "${YELLOW}$message${NC}"
    echo -ne "${WHITE}Confirmar? [s/N]: ${NC}"
    read -r response
    case "$response" in
        [sS][iI][mM]|[sS]) return 0 ;;
        *) return 1 ;;
    esac
}

# confirm_critical(title, description, impacts, recommendations)
# Confirmação DETALHADA para operações CRÍTICAS/DESTRUTIVAS
# Exibe: título, descrição, impactos, recomendações
# Requer: usuário digitar "SIM" em MAIÚSCULAS para confirmar
# Retorna: 0 (SIM confirmado), 1 (cancelado)
# Uso: Restauração, migração, reset de firewall, limpeza Docker
# Diferente de confirm() que é simples (s/N)
confirm_critical() {
    local title="$1"
    local description="$2"
    local impacts="$3"
    local recommendations="$4"

    clear_screen
    echo -e "${RED}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║                    ⚠️  OPERAÇÃO CRÍTICA  ⚠️                      ║${NC}"
    echo -e "${RED}╚══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${WHITE}${title}${NC}"
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}📋 DESCRIÇÃO:${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "$description"
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}⚠️  IMPACTOS:${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "$impacts"
    echo ""
    if [ -n "$recommendations" ]; then
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${GREEN}💡 RECOMENDAÇÕES:${NC}"
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "$recommendations"
        echo ""
    fi
    echo -e "${RED}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║  Você compreende os riscos e deseja continuar?                  ║${NC}"
    echo -e "${RED}╚══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -ne "${WHITE}Digite 'SIM' em MAIÚSCULAS para confirmar ou Enter para cancelar: ${NC}"
    read -r response

    if [ "$response" = "SIM" ]; then
        return 0
    else
        echo ""
        echo -e "${YELLOW}Operação cancelada pelo usuário.${NC}"
        sleep 2
        return 1
    fi
}

# run_script(script_path, script_name)
# Executa um script com validações, logging e tratamento de erro
# Responsabilidades:
#   1. Verifica se script existe
#   2. Verifica/corrige permissão de execução
#   3. Loga início da execução
#   4. Executa o script
#   5. Captura código de retorno
#   6. Loga resultado (sucesso/erro)
#   7. Exibe output e aguarda usuário
# Retorna: código de retorno do script
# Uso: run_script "$SCRIPT_DIR/backup/backup-coolify.sh" "Backup Coolify"
run_script() {
    local script_path="$1"
    local script_name="$2"
    shift 2  # Remove os dois primeiros argumentos, deixando apenas os argumentos adicionais
    local script_args="$@"  # Captura todos os argumentos restantes

    clear_screen
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${WHITE}Executando: $script_name${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""

    # VALIDAÇÃO 1: Script existe?
    if [ ! -f "$script_path" ]; then
        echo -e "${RED}✗ Script não encontrado: $script_path${NC}"
        log_execution "ERRO: Script não encontrado - $script_name"
        pause
        return 1
    fi

    # VALIDAÇÃO 2: Script é executável?
    if [ ! -x "$script_path" ]; then
        echo -e "${YELLOW}⚠ Tornando script executável...${NC}"
        chmod +x "$script_path"
    fi

    # EXECUÇÃO: Log início
    log_execution "INÍCIO: $script_name"

    # EXECUÇÃO: Rodar script (com argumentos se fornecidos)
    bash "$script_path" $script_args
    local exit_code=$?

    # RESULTADO: Exibir e logar
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    if [ $exit_code -eq 0 ]; then
        echo -e "${GREEN}✓ Script concluído com sucesso!${NC}"
        log_execution "SUCESSO: $script_name"
    else
        echo -e "${RED}✗ Script finalizado com erros (código: $exit_code)${NC}"
        log_execution "ERRO: $script_name (código: $exit_code)"
    fi
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"

    pause
}

# Cabeçalho do menu
print_header() {
    clear_screen
    echo -e "${CYAN}"
    cat << "EOF"
╔══════════════════════════════════════════════════════════════════╗
║                                                                  ║
║        🚀 MENU PRINCIPAL - GERENCIAMENTO VPS 🚀                 ║
║                                                                  ║
║              Sistema de Manutenção e Backup                      ║
║                                                                  ║
╚══════════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
    echo -e "${WHITE}📍 Localização:${NC} $SCRIPT_DIR"
    echo -e "${WHITE}🖥️  Servidor:${NC}    $(hostname)"
    echo -e "${WHITE}📅 Data/Hora:${NC}   $(date '+%d/%m/%Y %H:%M:%S')"
    echo ""
}

################################################################################
# MENUS - Funções de Visualização
# Cada menu exibe opções disponíveis para categoria específica
# Padrão: show_xxx_menu() exibe, handle_xxx_menu() processa entrada
################################################################################

# Menu principal - 7 categorias principais + logs + sair
show_main_menu() {
    print_header
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${WHITE}MENU PRINCIPAL${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${GREEN}1${NC} → 📊 Status e Diagnóstico"
    echo -e "       ${GRAY}(Verificar saúde do servidor e serviços)${NC}"
    echo ""
    echo -e "  ${GREEN}2${NC} → 💾 Backups"
    echo -e "       ${GRAY}(Criar e restaurar backups do Coolify)${NC}"
    echo ""
    echo -e "  ${GREEN}3${NC} → 🔧 Manutenção"
    echo -e "       ${GRAY}(Limpeza, updates e otimização do sistema)${NC}"
    echo ""
    echo -e "  ${GREEN}4${NC} → 🚚 Migração"
    echo -e "       ${GRAY}(Transferir Coolify para outro servidor)${NC}"
    echo ""
    echo -e "  ${GREEN}5${NC} → ⚙️  Configuração"
    echo -e "       ${GRAY}(Cron, firewall, variáveis de ambiente)${NC}"
    echo ""
    echo -e "  ${GREEN}6${NC} → 📚 Documentação"
    echo -e "       ${GRAY}(Guias e manuais de uso)${NC}"
    echo ""
    echo -e "  ${GREEN}7${NC} → 📓 Obsidian"
    echo -e "       ${GRAY}(Backup GitHub e sincronização Syncthing)${NC}"
    echo ""
    echo -e "  ${YELLOW}8${NC} → 📜 Ver Logs de Execução"
    echo -e "       ${GRAY}(Histórico de operações realizadas)${NC}"
    echo ""
    echo -e "  ${RED}0${NC} → 🚪 Sair"
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -ne "${WHITE}Escolha uma opção: ${NC}"
}

# Menu Status e Diagnóstico
show_status_menu() {
    print_header
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${WHITE}📊 STATUS E DIAGNÓSTICO${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${GREEN}1${NC} → 🏥 Verificação de Saúde Completa"
    echo -e "       ${GRAY}(17 seções, score 0-100, recomendações)${NC}"
    echo ""
    echo -e "  ${GREEN}2${NC} → 📋 Status Resumido"
    echo -e "       ${GRAY}(Visão rápida: disco, memória, Docker, Coolify)${NC}"
    echo ""
    echo -e "  ${GREEN}3${NC} → 🧪 Teste do Sistema"
    echo -e "       ${GRAY}(Verificar funcionalidades básicas)${NC}"
    echo ""
    echo -e "  ${RED}0${NC} → ↩️  Voltar ao Menu Principal"
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -ne "${WHITE}Escolha uma opção: ${NC}"
}

# Menu Backups
show_backup_menu() {
    print_header
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${WHITE}💾 BACKUPS${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${MAGENTA}CRIAR BACKUPS${NC}"
    echo -e "  ${GREEN}1${NC} → 📦 Backup Completo do Coolify (Local)"
    echo -e "       ${GRAY}(DB + SSH keys + configs + volumes)${NC}"
    echo -e "       ${GRAY}(Salvo em: /var/backups/vpsguardian)${NC}"
    echo ""
    echo -e "  ${GREEN}2${NC} → 🗄️  Backup de Bancos via Dump SQL"
    echo -e "       ${GRAY}(PostgreSQL, MySQL, MongoDB - inclui Coolify)${NC}"
    echo -e "       ${GRAY}(Escolha destino: Local, Google Drive, S3, SSH)${NC}"
    echo ""
    echo -e "  ${GREEN}3${NC} → 🎯 Backup por Projeto (Coolify API)"
    echo -e "       ${GRAY}(Selecionar projeto específico para backup)${NC}"
    echo -e "       ${GRAY}(Requer API do Coolify configurada)${NC}"
    echo ""
    echo -e "  ${GREEN}4${NC} → 📁 Backup de Volume Docker Específico"
    echo -e "       ${GRAY}(Selecione volume manualmente)${NC}"
    echo -e "       ${GRAY}(Útil para backups pontuais)${NC}"
    echo ""
    echo -e "  ${GREEN}5${NC} → 📤 Enviar Backups para Destinos Remotos"
    echo -e "       ${GRAY}(S3, Google Drive, servidor SSH)${NC}"
    echo -e "       ${GRAY}(AWS, Backblaze, rsync, rclone)${NC}"
    echo ""
    echo -e "  ${MAGENTA}RESTAURAR BACKUPS${NC}"
    echo -e "  ${GREEN}6${NC} → 🔄 Restaurar Coolify Completo"
    echo -e "       ${GRAY}(Instalação + dados do Coolify)${NC}"
    echo -e "       ${GRAY}(Escolha origem: Local / S3 / Google Drive)${NC}"
    echo -e "       ${GRAY}(⚠️  Sobrescreve instalação atual)${NC}"
    echo ""
    echo -e "  ${GREEN}7${NC} → 🗄️  Restaurar Bancos de Dados"
    echo -e "       ${GRAY}(Dumps SQL dos seus projetos)${NC}"
    echo -e "       ${GRAY}(Escolha origem: Local / S3 / Google Drive / SSH)${NC}"
    echo -e "       ${GRAY}(Controle: tudo, exceto Coolify, ou específico)${NC}"
    echo -e "       ${GRAY}(⚠️  Sobrescreve dados dos bancos selecionados)${NC}"
    echo ""
    echo -e "  ${GREEN}8${NC} → 📦 Restaurar Volume Docker"
    echo -e "       ${GRAY}(Dados persistentes de containers)${NC}"
    echo -e "       ${GRAY}(De backup local em /var/backups/vpsguardian)${NC}"
    echo -e "       ${GRAY}(⚠️  Sobrescreve dados do volume)${NC}"
    echo ""
    echo -e "  ${MAGENTA}VALIDAÇÃO E DIAGNÓSTICO${NC}"
    echo -e "  ${GREEN}9${NC} → 🏥 Validar Saúde dos Bancos de Dados"
    echo -e "       ${GRAY}(Verificar integridade após restore)${NC}"
    echo -e "       ${GRAY}(Teste de conectividade e queries)${NC}"
    echo ""
    echo -e "  ${GREEN}10${NC} → 📊 Ver Status dos Backups Automáticos"
    echo -e "       ${GRAY}(Destinos configurados, cron jobs, últimos backups)${NC}"
    echo ""
    echo -e "  ${GREEN}11${NC} → 🚀 Executar Tarefas do Cron AGORA"
    echo -e "       ${GRAY}(Executa exatamente o que os crons fazem)${NC}"
    echo ""
    echo -e "  ${GREEN}12${NC} → 📡 Monitorar Status do Coolify (API)"
    echo -e "       ${GRAY}(Dashboard de apps, databases e services)${NC}"
    echo -e "       ${GRAY}(Requer API do Coolify configurada)${NC}"
    echo ""
    echo -e "  ${RED}0${NC} → ↩️  Voltar ao Menu Principal"
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -ne "${WHITE}Escolha uma opção: ${NC}"
}

# Menu Manutenção
show_maintenance_menu() {
    print_header
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${WHITE}🔧 MANUTENÇÃO${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${GREEN}1${NC} → 🔄 Manutenção Completa"
    echo -e "       ${GRAY}(Atualizar sistema, limpar Docker, verificar saúde)${NC}"
    echo ""
    echo -e "  ${GREEN}2${NC} → ⚠️  Verificar Alerta de Disco"
    echo -e "       ${GRAY}(Checar uso de disco e alertar se necessário)${NC}"
    echo ""
    echo -e "  ${GREEN}3${NC} → 🆙 Configurar Updates Automáticos"
    echo -e "       ${GRAY}(Instalar e configurar unattended-upgrades)${NC}"
    echo ""
    echo -e "  ${GREEN}4${NC} → 🧹 Limpeza Manual do Docker"
    echo -e "       ${GRAY}(Remover imagens, containers e volumes não usados)${NC}"
    echo ""
    echo -e "  ${GREEN}5${NC} → 🔄 Reiniciar Serviços Essenciais"
    echo -e "       ${GRAY}(Docker, Cloudflared, UFW)${NC}"
    echo ""
    echo -e "  ${GREEN}6${NC} → 🗑️  Limpar Backups"
    echo -e "       ${GRAY}(Volumes, Databases, Coolify)${NC}"
    echo -e "       ${GRAY}(Limpar tudo ou por período)${NC}"
    echo ""
    echo -e "  ${RED}0${NC} → ↩️  Voltar ao Menu Principal"
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -ne "${WHITE}Escolha uma opção: ${NC}"
}

# Menu Migração
show_migration_menu() {
    print_header
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${WHITE}🚚 MIGRAÇÃO${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${YELLOW}⚠️  ATENÇÃO: Operações de migração são CRÍTICAS!${NC}"
    echo -e "  ${YELLOW}Certifique-se de ter backups antes de prosseguir.${NC}"
    echo ""
    echo -e "  ${GREEN}1${NC} → 🚀 Migrar Coolify Completo"
    echo -e "       ${GRAY}(Transferir toda instalação para novo servidor)${NC}"
    echo -e "       ${GRAY}(Tempo: 30min-2h | Downtime: SIM)${NC}"
    echo ""
    echo -e "  ${GREEN}2${NC} → 📦 Migrar Volumes Docker"
    echo -e "       ${GRAY}(Transferir volumes específicos entre servidores)${NC}"
    echo -e "       ${GRAY}(Escolha quais volumes migrar)${NC}"
    echo ""
    echo -e "  ${GREEN}3${NC} → 📤 Transferir Backups Entre Servidores"
    echo -e "       ${GRAY}(Copiar arquivos de backup via rsync/scp)${NC}"
    echo -e "       ${GRAY}(Útil para migração manual)${NC}"
    echo ""
    echo -e "  ${MAGENTA}MIGRAÇÃO VIA DUMP SQL (RECOMENDADO)${NC}"
    echo -e "  ${GREEN}4${NC} → 🗄️  Migrar Bancos via Dump SQL"
    echo -e "       ${GRAY}(MySQL, PostgreSQL, MongoDB - mais leve e seguro)${NC}"
    echo -e "       ${GRAY}(Sem problemas de redo logs corrompidos)${NC}"
    echo ""
    echo -e "  ${GREEN}5${NC} → 📥 Restaurar Dumps SQL Locais"
    echo -e "       ${GRAY}(Restaurar de pasta com dumps pré-existentes)${NC}"
    echo -e "       ${GRAY}(Suporta .sql.gz e .tar.gz)${NC}"
    echo ""
    echo -e "  ${GREEN}6${NC} → ☁️  Restaurar Dumps de Origem Remota"
    echo -e "       ${GRAY}(Baixar de S3/Google Drive/SSH e restaurar)${NC}"
    echo -e "       ${GRAY}(Controle total: tudo, tudo exceto Coolify, ou específico)${NC}"
    echo ""
    echo -e "  ${MAGENTA}VALIDAÇÃO E CHECKLIST${NC}"
    echo -e "  ${GREEN}7${NC} → 📋 Checklist de Migração"
    echo -e "       ${GRAY}(Guia passo a passo com verificações)${NC}"
    echo ""
    echo -e "  ${GREEN}8${NC} → ✅ Validar Pré-Migração (Origem)"
    echo -e "       ${GRAY}(Verificar ambiente antes de migrar)${NC}"
    echo ""
    echo -e "  ${GREEN}9${NC} → ✅ Validar Pós-Migração (Destino)"
    echo -e "       ${GRAY}(Verificar ambiente após migrar)${NC}"
    echo ""
    echo -e "  ${RED}0${NC} → ↩️  Voltar ao Menu Principal"
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -ne "${WHITE}Escolha uma opção: ${NC}"
}

# Menu Configuração
show_config_menu() {
    print_header
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${WHITE}⚙️  CONFIGURAÇÃO${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${GREEN}1${NC} → ☁️  Configurar Destinos de Backup"
    echo -e "       ${GRAY}(Local, S3, R2, Google Drive, SSH)${NC}"
    echo -e "       ${GRAY}(Onde os backups automáticos vão)${NC}"
    echo ""
    echo -e "  ${GREEN}2${NC} → ⏰ Configurar Tarefas Agendadas (Cron)"
    echo -e "       ${GRAY}(Agendar backups e manutenções automáticas)${NC}"
    echo ""
    echo -e "  ${GREEN}3${NC} → 📝 Editar Configurações (config.env)"
    echo -e "       ${GRAY}(Alterar variáveis de ambiente do sistema)${NC}"
    echo -e "       ${GRAY}(Paths, retenção, notificações)${NC}"
    echo ""
    echo -e "  ${GREEN}4${NC} → 🛡️  Configurar Firewall (UFW)"
    echo -e "       ${GRAY}(Modo rápido ou personalizado)${NC}"
    echo -e "       ${GRAY}(SSH, HTTP, HTTPS, Cloudflare Tunnel)${NC}"
    echo ""
    echo -e "  ${GREEN}5${NC} → 🔐 Configurar Cloudflare Tunnel"
    echo -e "       ${GRAY}(SSH seguro via Zero Trust)${NC}"
    echo -e "       ${GRAY}(Ver status e documentação)${NC}"
    echo ""
    echo -e "  ${GREEN}6${NC} → 🔌 Configurar API do Coolify"
    echo -e "       ${GRAY}(Descoberta automática de databases)${NC}"
    echo -e "       ${GRAY}(Stop/Start graceful via API)${NC}"
    echo ""
    echo -e "  ${GREEN}7${NC} → 📋 Mostrar Configurações Atuais"
    echo -e "       ${GRAY}(Cron jobs, firewall, destinos de backup)${NC}"
    echo -e "       ${GRAY}(Visualização completa do sistema)${NC}"
    echo ""
    echo -e "  ${RED}0${NC} → ↩️  Voltar ao Menu Principal"
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -ne "${WHITE}Escolha uma opção: ${NC}"
}

# Menu Obsidian
show_obsidian_menu() {
    print_header
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${WHITE}📓 OBSIDIAN${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${GREEN}1${NC} → 📤 Backup com GitHub"
    echo -e "       ${GRAY}(Fazer commit e push automático do vault)${NC}"
    echo -e "       ${GRAY}(Configurar repositório Git e GitHub)${NC}"
    echo ""
    echo -e "  ${GREEN}2${NC} → 🔄 Instalar e Configurar Syncthing"
    echo -e "       ${GRAY}(Sincronização em tempo real entre dispositivos)${NC}"
    echo -e "       ${GRAY}(Com Cloudflare Zero Trust Tunnel)${NC}"
    echo ""
    echo -e "  ${GREEN}3${NC} → ⏰ Configurar Backup Automático (Cron)"
    echo -e "       ${GRAY}(Agendar backups periódicos para GitHub)${NC}"
    echo ""
    echo -e "  ${YELLOW}4${NC} → 📊 Status dos Serviços"
    echo -e "       ${GRAY}(Verificar Git, Syncthing e Cron)${NC}"
    echo ""
    echo -e "  ${RED}0${NC} → ↩️  Voltar ao Menu Principal"
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -ne "${WHITE}Escolha uma opção: ${NC}"
}

################################################################################
# FUNÇÕES DE EXECUÇÃO
################################################################################

# Status e Diagnóstico
handle_status_menu() {
    while true; do
        show_status_menu
        read -r option

        case $option in
            1)
                run_script "$SCRIPT_DIR/scripts-auxiliares/verificar-saude-completa.sh" "Verificação de Saúde Completa"
                ;;
            2)
                run_script "$SCRIPT_DIR/scripts-auxiliares/verificar-saude-completa.sh" "Status Resumido"
                ;;
            3)
                run_script "$SCRIPT_DIR/scripts-auxiliares/test-sistema.sh" "Teste do Sistema"
                ;;
            0)
                return
                ;;
            *)
                echo -e "${RED}Opção inválida!${NC}"
                sleep 1
                ;;
        esac
    done
}

# Backups
handle_backup_menu() {
    while true; do
        show_backup_menu
        read -r option

        case $option in
            1)
                if confirm "Executar backup completo do Coolify?"; then
                    run_script "$SCRIPT_DIR/backup/backup-coolify.sh" "Backup Completo do Coolify"
                fi
                ;;
            2)
                # Backup de Bancos via Dump SQL (novo sistema)
                echo ""
                echo -e "${CYAN}🗄️  BACKUP DE BANCOS DE DADOS VIA DUMP SQL${NC}"
                echo ""
                echo "Onde deseja salvar o backup?"
                echo "  1) Local apenas"
                echo "  2) Local + Google Drive"
                echo "  3) Local + AWS S3"
                echo "  4) Local + SSH"
                echo "  5) Todos os destinos"
                echo "  0) Cancelar"
                echo ""
                read -p "Escolha (0-5): " backup_dest_choice

                case $backup_dest_choice in
                    1) DEST="local" ;;
                    2) DEST="google-drive" ;;
                    3) DEST="aws-s3" ;;
                    4) DEST="self-hosted" ;;
                    5) DEST="all" ;;
                    0) continue ;;
                    *) DEST="local" ;;
                esac

                if confirm "Executar backup via dump SQL (destino: $DEST)?"; then
                    run_script "$SCRIPT_DIR/backup/backup-databases-dump-auto.sh" "Backup de Bancos via Dump" "--dest=$DEST"
                fi
                ;;
            3)
                # Backup por Projeto (Coolify API)
                echo ""
                echo -e "${CYAN}🎯 BACKUP POR PROJETO (Coolify API)${NC}"
                echo ""

                # Verificar se API está disponível
                # Carregar de /opt/vpsguardian primeiro, fallback para local
                if [ -f "/opt/vpsguardian/config/backup-destinations.conf" ]; then
                    source "/opt/vpsguardian/config/backup-destinations.conf" 2>/dev/null
                elif [ -f "$SCRIPT_DIR/config/backup-destinations.conf" ]; then
                    source "$SCRIPT_DIR/config/backup-destinations.conf" 2>/dev/null
                fi
                source "$SCRIPT_DIR/lib/coolify-api.sh" 2>/dev/null

                if [ "$COOLIFY_API_ENABLED" != "true" ] || [ -z "$COOLIFY_API_TOKEN" ]; then
                    echo -e "${RED}✗ API do Coolify não está configurada${NC}"
                    echo ""
                    echo "Para usar backup por projeto, configure a API primeiro:"
                    echo "  Menu → Configuração → Configurar API do Coolify"
                    echo ""
                    pause
                    continue
                fi

                # Listar projetos
                echo "Carregando projetos..."
                if type coolify_list_project_names &>/dev/null; then
                    PROJECTS=$(coolify_list_project_names 2>/dev/null)
                else
                    echo -e "${RED}✗ Biblioteca coolify-api.sh não carregada${NC}"
                    pause
                    continue
                fi

                if [ -z "$PROJECTS" ]; then
                    echo -e "${YELLOW}⚠ Nenhum projeto encontrado via API${NC}"
                    pause
                    continue
                fi

                echo ""
                echo "Projetos disponíveis:"
                echo ""

                IDX=1
                declare -a PROJ_OPTS
                while IFS='|' read -r uuid name desc; do
                    printf "  ${GREEN}%2d${NC} → %s" "$IDX" "$name"
                    [ -n "$desc" ] && printf " ${GRAY}(%s)${NC}" "${desc:0:30}"
                    echo ""
                    PROJ_OPTS[$IDX]="$uuid"
                    ((IDX++))
                done <<< "$PROJECTS"

                echo ""
                read -p "Escolha um projeto (1-$((IDX-1)), ou 0 para cancelar): " proj_choice

                if [ "$proj_choice" = "0" ] || [ -z "$proj_choice" ]; then
                    continue
                fi

                SELECTED_PROJECT="${PROJ_OPTS[$proj_choice]}"
                if [ -z "$SELECTED_PROJECT" ]; then
                    echo -e "${RED}Opção inválida${NC}"
                    sleep 1
                    continue
                fi

                echo ""
                echo "Onde deseja salvar o backup?"
                echo "  1) Local apenas"
                echo "  2) Local + Google Drive"
                echo "  3) Local + AWS S3"
                echo "  0) Cancelar"
                echo ""
                read -p "Escolha (0-3): " backup_dest_choice

                case $backup_dest_choice in
                    1) DEST="local" ;;
                    2) DEST="google-drive" ;;
                    3) DEST="aws-s3" ;;
                    0) continue ;;
                    *) DEST="local" ;;
                esac

                if confirm "Executar backup do projeto selecionado?"; then
                    run_script "$SCRIPT_DIR/backup/backup-databases-dump-auto.sh" "Backup por Projeto" "--dest=$DEST" "--project=$SELECTED_PROJECT"
                fi
                ;;
            4)
                run_script "$SCRIPT_DIR/backup/backup-volume-interativo.sh" "Backup de Volume Interativo"
                ;;
            5)
                if confirm "Enviar backups para destinos remotos?"; then
                    run_script "$SCRIPT_DIR/backup/backup-destinos.sh" "Enviar Backups"
                fi
                ;;
            6)
                # Restaurar Coolify Completo (unificado)
                if confirm_critical \
                    "🔄 RESTAURAR COOLIFY COMPLETO" \
                    "Este script irá SOBRESCREVER a instalação atual do Coolify.\n\n${WHITE}Você escolherá a origem:${NC}\n  • Backup Local\n  • AWS S3\n  • Google Drive\n\n${WHITE}O que será restaurado:${NC}\n  • Banco de dados do Coolify\n  • Chaves SSH\n  • Configurações (.env)\n  • Volumes (se disponíveis)" \
                    "${RED}⚠ TODOS OS DADOS ATUAIS DO COOLIFY SERÃO PERDIDOS!${NC}\n\n  • ${RED}Aplicações em execução${NC} → SERÃO PARADAS\n  • ${RED}Configurações atuais${NC} → SERÃO PERDIDAS\n  • ${RED}Bancos de dados${NC} → SERÃO SOBRESCRITOS\n\n${YELLOW}Tempo estimado:${NC} 10-30 minutos" \
                    "1. ${GREEN}Faça backup dos dados atuais${NC} antes de prosseguir\n2. ${GREEN}Verifique se tem o backup${NC} disponível\n3. ${GREEN}Avise usuários${NC} que haverá downtime"; then
                    run_script "$SCRIPT_DIR/backup/restaurar-coolify.sh" "Restaurar Coolify"
                fi
                ;;
            7)
                # Restaurar Bancos de Dados (unificado)
                if confirm_critical \
                    "🗄️  RESTAURAR BANCOS DE DADOS" \
                    "Restaurar dumps SQL dos seus projetos.\n\n${WHITE}Você escolherá a origem:${NC}\n  • Backup Local\n  • AWS S3\n  • Google Drive\n  • Servidor SSH\n\n${WHITE}Controle total no restore:${NC}\n  • Restaurar TUDO (incluindo Coolify)\n  • Restaurar TUDO EXCETO Coolify ⭐\n  • Escolher dumps específicos" \
                    "${RED}⚠ DADOS DOS BANCOS SERÃO SOBRESCRITOS!${NC}\n\n  • ${RED}Tabelas existentes${NC} → SERÃO SUBSTITUÍDAS\n  • ${YELLOW}Aplicações${NC} → PODEM TER DOWNTIME\n  • ${GREEN}Coolify-db${NC} → VOCÊ DECIDE se restaura" \
                    "1. ${GREEN}Você terá menu interativo${NC} para escolher\n2. ${GREEN}Dumps do Coolify${NC} são destacados\n3. ${YELLOW}Recomendado${NC}: Restaurar tudo EXCETO Coolify"; then
                    run_script "$SCRIPT_DIR/backup/restaurar-databases.sh" "Restaurar Bancos de Dados"
                fi
                ;;
            8)
                # Restaurar Volume Docker Específico
                if confirm_critical \
                    "📦 RESTAURAR VOLUME DOCKER" \
                    "Restaurar dados persistentes de containers.\n\n${WHITE}O que será feito:${NC}\n  • Listar backups disponíveis\n  • Você escolherá qual volume restaurar\n  • ${YELLOW}PARAR${NC} containers que usam o volume\n  • ${RED}SUBSTITUIR${NC} dados do volume\n  • Reiniciar containers" \
                    "${YELLOW}⚠ OS DADOS ATUAIS DO VOLUME SERÃO PERDIDOS!${NC}\n\n  • ${RED}Dados do volume${NC} → SERÃO SOBRESCRITOS\n  • ${YELLOW}Aplicações afetadas${NC} → PODEM TER DOWNTIME\n\n${WHITE}Impacto por tipo de volume:${NC}\n  • ${RED}Volume de banco de dados${NC} → DADOS SUBSTITUÍDOS\n  • ${YELLOW}Volume de aplicação${NC} → ARQUIVOS RESTAURADOS" \
                    "1. ${GREEN}Identifique qual volume${NC} precisa restaurar\n2. ${GREEN}Verifique se tem o backup${NC} deste volume\n3. ${YELLOW}Considere fazer snapshot${NC} antes de restaurar"; then
                    run_script "$SCRIPT_DIR/backup/restaurar-volume-interativo.sh" "Restaurar Volume"
                fi
                ;;
            9)
                # Validar Saúde dos Bancos
                if confirm "Verificar saúde de todos os bancos de dados?"; then
                    clear_screen
                    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
                    echo -e "${WHITE}Executando: Validar Saúde dos Bancos${NC}"
                    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
                    echo ""

                    log_execution "INÍCIO: Validar Saúde dos Bancos"

                    # Executar com argumentos
                    bash "$SCRIPT_DIR/scripts-auxiliares/validate-database-health.sh" --all
                    local exit_code=$?

                    echo ""
                    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
                    if [ $exit_code -eq 0 ]; then
                        echo -e "${GREEN}✓ Validação concluída com sucesso!${NC}"
                        log_execution "SUCESSO: Validar Saúde dos Bancos"
                    else
                        echo -e "${RED}✗ Validação encontrou problemas (código: $exit_code)${NC}"
                        log_execution "AVISO: Validar Saúde dos Bancos (código: $exit_code)"
                    fi
                    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"

                    pause
                fi
                ;;
            10)
                # Ver Status dos Backups Automáticos
                run_script "$SCRIPT_DIR/scripts-auxiliares/status-backups.sh" "Status dos Backups"
                ;;
            11)
                # Executar Backup Completo AGORA
                run_script "$SCRIPT_DIR/scripts-auxiliares/backup-completo-agora.sh" "Backup Completo"
                ;;
            12)
                # Monitorar Status do Coolify via API
                echo ""
                # Carregar de /opt/vpsguardian primeiro, fallback para local
                if [ -f "/opt/vpsguardian/config/backup-destinations.conf" ]; then
                    source "/opt/vpsguardian/config/backup-destinations.conf" 2>/dev/null
                elif [ -f "$SCRIPT_DIR/config/backup-destinations.conf" ]; then
                    source "$SCRIPT_DIR/config/backup-destinations.conf" 2>/dev/null
                fi

                if [ "$COOLIFY_API_ENABLED" != "true" ] || [ -z "$COOLIFY_API_TOKEN" ]; then
                    echo -e "${RED}✗ API do Coolify não está configurada${NC}"
                    echo ""
                    echo "Para usar o monitoramento, configure a API primeiro:"
                    echo "  Menu → Configuração → Configurar API do Coolify"
                    echo ""
                    pause
                else
                    run_script "$SCRIPT_DIR/scripts-auxiliares/monitorar-coolify.sh" "Monitorar Coolify" "--dashboard"
                fi
                ;;
            0)
                return
                ;;
            *)
                echo -e "${RED}Opção inválida!${NC}"
                sleep 1
                ;;
        esac
    done
}

# Manutenção
handle_maintenance_menu() {
    while true; do
        show_maintenance_menu
        read -r option

        case $option in
            1)
                if confirm "Executar manutenção completa? (pode demorar alguns minutos)"; then
                    run_script "$SCRIPT_DIR/manutencao/manutencao-completa.sh" "Manutenção Completa"
                fi
                ;;
            2)
                run_script "$SCRIPT_DIR/manutencao/alerta-disco.sh" "Alerta de Disco"
                ;;
            3)
                if confirm "Configurar updates automáticos?"; then
                    run_script "$SCRIPT_DIR/manutencao/configurar-updates-automaticos.sh" "Configurar Updates Automáticos"
                fi
                ;;
            4)
                # Confirmação crítica para Limpeza Docker
                if confirm_critical \
                    "🧹 LIMPEZA COMPLETA DO DOCKER" \
                    "Este comando irá remover TODOS os recursos Docker não utilizados.\n\n${WHITE}O que será removido:${NC}\n  • ${RED}Todas as imagens${NC} não associadas a containers\n  • ${RED}Todos os containers${NC} parados\n  • ${RED}Todas as redes${NC} não utilizadas\n  • ${RED}Todos os volumes${NC} não utilizados\n  • ${RED}Cache de build${NC} completo\n\n${YELLOW}Comando executado:${NC}\n  ${GRAY}docker system prune -a --volumes${NC}" \
                    "${RED}⚠ DADOS EM VOLUMES NÃO USADOS SERÃO DELETADOS!${NC}\n\n  • ${RED}Volumes órfãos${NC} → DELETADOS PERMANENTEMENTE\n  • ${YELLOW}Imagens antigas${NC} → PRECISARÃO SER BAIXADAS NOVAMENTE\n  • ${YELLOW}Cache de build${NC} → BUILDS FICARÃO MAIS LENTOS\n  • ${GREEN}Espaço liberado${NC} → Pode ser SIGNIFICATIVO (GBs)\n\n${YELLOW}Tempo de execução:${NC} 1-5 minutos\n${YELLOW}Downtime:${NC} Nenhum (apenas recursos não usados)" \
                    "1. ${GREEN}Verifique se NÃO tem volumes importantes${NC} sem containers\n2. ${GREEN}Containers em execução${NC} NÃO serão afetados\n3. ${YELLOW}Você precisará re-baixar imagens${NC} removidas\n4. ${GREEN}Ideal para recuperar espaço${NC} em disco"; then
                    clear_screen
                    echo -e "${CYAN}Executando limpeza do Docker...${NC}"
                    echo ""
                    docker system prune -a --volumes
                    log_execution "Limpeza manual do Docker"
                    pause
                fi
                ;;
            5)
                if confirm "Reiniciar serviços essenciais? (Docker, Cloudflared, UFW)"; then
                    clear_screen
                    echo -e "${CYAN}Reiniciando serviços...${NC}"
                    echo ""
                    echo -e "${BLUE}→ Reiniciando Docker...${NC}"
                    systemctl restart docker
                    echo -e "${BLUE}→ Reiniciando Cloudflared...${NC}"
                    systemctl restart cloudflared 2>/dev/null || echo "  Cloudflared não instalado"
                    echo -e "${BLUE}→ Recarregando UFW...${NC}"
                    ufw reload 2>/dev/null || echo "  UFW não ativo"
                    echo ""
                    echo -e "${GREEN}✓ Serviços reiniciados!${NC}"
                    log_execution "Reinicialização manual de serviços"
                    pause
                fi
                ;;
            6)
                run_script "$SCRIPT_DIR/manutencao/limpar-backups.sh" "Limpar Backups"
                ;;
            0)
                return
                ;;
            *)
                echo -e "${RED}Opção inválida!${NC}"
                sleep 1
                ;;
        esac
    done
}

# Migração
handle_migration_menu() {
    while true; do
        show_migration_menu
        read -r option

        case $option in
            1)
                # Confirmação crítica para Migrar Coolify
                if confirm_critical \
                    "🚚 MIGRAÇÃO COMPLETA DO COOLIFY" \
                    "Este script irá migrar TODA a instalação do Coolify para outro servidor.\n\n${WHITE}O que será feito:${NC}\n  • Criar backup completo do Coolify atual\n  • ${RED}PARAR${NC} todos os serviços\n  • Transferir dados para servidor destino\n  • Configurar Coolify no novo servidor\n  • Verificar integridade dos dados\n\n${YELLOW}Você precisará de:${NC}\n  • Acesso SSH ao servidor destino\n  • Espaço suficiente em ambos servidores\n  • Conexão estável entre servidores" \
                    "${RED}⚠ OPERAÇÃO EXTREMAMENTE CRÍTICA - DOWNTIME TOTAL!${NC}\n\n  • ${RED}Coolify será DESLIGADO${NC} durante a migração\n  • ${RED}Aplicações FICARÃO OFFLINE${NC} (30min - 2h)\n  • ${RED}Banco de dados será TRANSFERIDO${NC}\n  • ${RED}DNS pode precisar de atualização${NC}\n  • ${RED}Certificados SSL${NC} podem precisar renovação\n\n${YELLOW}Requisitos OBRIGATÓRIOS:${NC}\n  • Backup atualizado em local seguro\n  • Servidor destino configurado\n  • Janela de manutenção agendada\n  • Plano de rollback definido" \
                    "1. ${RED}FAÇA BACKUP COMPLETO${NC} antes de iniciar\n2. ${GREEN}Teste a conexão${NC} com servidor destino\n3. ${GREEN}Avise todos os usuários${NC} sobre o downtime\n4. ${GREEN}Documente IPs e configurações${NC} atuais\n5. ${YELLOW}Tenha plano B${NC} caso algo falhe\n6. ${RED}Esta é uma operação ONE-WAY${NC} - não há desfazer"; then
                    run_script "$SCRIPT_DIR/migrar/migrar-coolify.sh" "Migrar Coolify"
                fi
                ;;
            2)
                # Confirmação crítica para Migrar Volumes
                if confirm_critical \
                    "📦 MIGRAÇÃO DE VOLUMES DOCKER" \
                    "Este script irá migrar volumes Docker específicos para outro servidor.\n\n${WHITE}O que será feito:${NC}\n  • Listar volumes disponíveis\n  • Criar backup dos volumes selecionados\n  • ${YELLOW}PARAR${NC} containers que usam os volumes\n  • Transferir volumes via rsync/scp\n  • Restaurar volumes no destino\n  • Reiniciar containers (se aplicável)" \
                    "${YELLOW}⚠ APLICAÇÕES AFETADAS TERÃO DOWNTIME!${NC}\n\n  • ${YELLOW}Containers serão parados${NC} durante transferência\n  • ${YELLOW}Dados em trânsito${NC} → podem demorar dependendo do tamanho\n  • ${RED}Falha na transferência${NC} → pode corromper dados\n  • ${YELLOW}Rede instável${NC} → pode causar problemas\n\n${WHITE}Tempo estimado por volume:${NC}\n  • Volume pequeno (<1GB): 5-10 min\n  • Volume médio (1-10GB): 15-30 min\n  • Volume grande (>10GB): 30min - 2h" \
                    "1. ${GREEN}Identifique quais volumes${NC} precisa migrar\n2. ${GREEN}Verifique espaço disponível${NC} no destino\n3. ${GREEN}Teste conectividade${NC} entre servidores\n4. ${YELLOW}Faça backup${NC} antes de migrar\n5. ${GREEN}Migre em horário de baixo uso${NC}"; then
                    run_script "$SCRIPT_DIR/migrar/migrar-volumes.sh" "Migrar Volumes"
                fi
                ;;
            3)
                run_script "$SCRIPT_DIR/migrar/transferir-backups.sh" "Transferir Backups"
                ;;
            4)
                # Migrar Bancos via Dump SQL
                if confirm_critical \
                    "🗄️  MIGRAÇÃO DE BANCOS VIA DUMP SQL" \
                    "Este script migra bancos de dados usando dumps SQL (método mais seguro).\n\n${WHITE}O que será feito:${NC}\n  • Detectar bancos MySQL, PostgreSQL, MongoDB\n  • Criar dumps SQL de cada banco\n  • Comprimir e transferir para destino\n  • Opcionalmente restaurar no destino\n\n${GREEN}Vantagens:${NC}\n  • Arquivos menores que volumes\n  • Sem problemas de redo logs corrompidos\n  • Portável entre versões do banco" \
                    "CRÍTICA - Certifique-se de ter backup" \
                    "1. ${GREEN}Os bancos continuam rodando${NC} durante o dump\n2. ${GREEN}Menor downtime${NC} que migração de volumes\n3. ${YELLOW}Verifique espaço em disco${NC} para os dumps"; then
                    run_script "$SCRIPT_DIR/migrar/migrar-databases-dump.sh" "Migrar Bancos via Dump"
                fi
                ;;
            5)
                # Restaurar Dumps SQL
                echo ""
                echo -e "${CYAN}📥 RESTAURAR DUMPS SQL${NC}"
                echo ""
                echo "Diretórios comuns com dumps:"
                echo "  1) /var/backups/vpsguardian/databases (padrão)"
                echo "  2) /root/database-dumps-migration (migração remota)"
                echo "  3) Outro diretório"
                echo ""
                read -p "Escolha (1-3): " dir_choice

                case $dir_choice in
                    1) DUMP_PATH="/var/backups/vpsguardian/databases" ;;
                    2) DUMP_PATH="/root/database-dumps-migration" ;;
                    3)
                        read -p "Digite o caminho completo: " DUMP_PATH
                        ;;
                    *) DUMP_PATH="/var/backups/vpsguardian/databases" ;;
                esac

                if [ -d "$DUMP_PATH" ]; then
                    run_script "$SCRIPT_DIR/migrar/restore-databases-dump.sh" "Restaurar Dumps SQL" "--dir=$DUMP_PATH"
                else
                    echo -e "${RED}Diretório não encontrado: $DUMP_PATH${NC}"
                    sleep 2
                fi
                ;;
            6)
                # Restaurar Dumps de Origem Remota
                if confirm \
                    "Baixar dumps de S3/Google Drive/SSH e restaurar?\n\nVocê terá controle total sobre o que restaurar:\n• Tudo (incluindo Coolify)\n• Tudo EXCETO Coolify (recomendado)\n• Dumps específicos"; then
                    run_script "$SCRIPT_DIR/backup/restaurar-dumps-remotos.sh" "Restaurar Dumps Remotos"
                fi
                ;;
            7)
                # Checklist de Migração
                run_script "$SCRIPT_DIR/scripts-auxiliares/checklist-migracao.sh" "Checklist de Migração"
                ;;
            8)
                # Validar Pré-Migração
                run_script "$SCRIPT_DIR/scripts-auxiliares/validar-pre-migracao.sh" "Validar Pré-Migração"
                ;;
            9)
                # Validar Pós-Migração
                run_script "$SCRIPT_DIR/scripts-auxiliares/validar-pos-migracao.sh" "Validar Pós-Migração"
                ;;
            0)
                return
                ;;
            *)
                echo -e "${RED}Opção inválida!${NC}"
                sleep 1
                ;;
        esac
    done
}

# Menu de Firewall
show_firewall_menu() {
    print_header
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${WHITE}🛡️  CONFIGURAÇÃO DE FIREWALL (UFW)${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${GREEN}1${NC} → ⚡ Modo Rápido (Perfil Padrão)"
    echo -e "       ${GRAY}(Você digita sua rede LAN, resto é automático)${NC}"
    echo -e "       ${GRAY}(SSH: localhost + sua LAN + Docker)${NC}"
    echo ""
    echo -e "  ${GREEN}2${NC} → 🔧 Modo Assistente (Configuração Personalizada)"
    echo -e "       ${GRAY}(Detecta sua rede e permite configuração customizada)${NC}"
    echo -e "       ${GRAY}(Ideal para redes diferentes ou múltiplas LANs)${NC}"
    echo ""
    echo -e "  ${YELLOW}3${NC} → 📊 Ver Status Atual"
    echo -e "       ${GRAY}(Mostra configuração do firewall agora)${NC}"
    echo ""
    echo -e "  ${GREEN}4${NC} → 🎛️  Gerenciador Interativo"
    echo -e "       ${GRAY}(Whitelist de IPs, múltiplos perfis)${NC}"
    echo ""
    echo -e "  ${RED}0${NC} → ↩️  Voltar ao Menu Principal"
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -ne "${WHITE}Escolha uma opção: ${NC}"
}

# Handler de Firewall
handle_firewall_menu() {
    while true; do
        show_firewall_menu
        read -r option

        case $option in
            1)
                # Modo Rápido - Perfil Padrão
                if confirm_critical \
                    "⚡ MODO RÁPIDO - PERFIL PADRÃO" \
                    "Este script irá aplicar a configuração UFW padrão otimizada para\nCoolify + Cloudflare Tunnel.\n\n${WHITE}O que será feito:${NC}\n  • ${RED}RESET TOTAL${NC} de todas as regras\n  • Você irá digitar sua rede LAN\n  • Política: ${RED}DENY${NC} incoming, ${GREEN}ALLOW${NC} outgoing\n  • HTTP/HTTPS (80/443): ${GREEN}PÚBLICO${NC}\n  • SSH (22): ${YELLOW}RESTRITO${NC} a:\n      - Localhost (127.0.0.1)\n      - SUA LAN (você irá digitar)\n      - Redes Docker (10.0.0.0/8)\n  • Loopback: ${GREEN}PERMITIDO${NC} (CF Tunnel)" \
                    "${RED}⚠ VOCÊ PODE PERDER ACESSO SSH!${NC}\n\nO script pedirá:\n  • Seus 3 primeiros octetos de rede\n    (ex: ${YELLOW}192.168.31${NC} → ${GREEN}192.168.31.0/24${NC})\n\n${YELLOW}Como descobrir:${NC}\n  • Linux/Mac: ${GRAY}ip addr | grep inet${NC}\n  • Windows: ${GRAY}ipconfig${NC}\n  • Se IP é 192.168.31.105 → digite 192.168.31" \
                    "1. ${GREEN}Saiba sua rede LAN (execute em seu PC: ip addr ou ipconfig)${NC}\n2. ${GREEN}Tenha Cloudflare Tunnel como backup${NC}\n3. ${GREEN}Faça backup: ${GRAY}sudo ufw status numbered > ufw-backup.txt${NC}"; then
                    run_script "$SCRIPT_DIR/manutencao/firewall-perfil-padrao.sh" "Firewall - Modo Rápido"
                fi
                ;;
            2)
                # Modo Assistente - Configuração Personalizada
                if confirm_critical \
                    "🔧 MODO ASSISTENTE - CONFIGURAÇÃO PERSONALIZADA" \
                    "Este script irá RESETAR completamente as regras do firewall e guiá-lo\npela configuração personalizada.\n\n${WHITE}O que será feito:${NC}\n  • ${RED}RESET TOTAL${NC} de todas as regras existentes\n  • Detectará automaticamente sua conexão SSH\n  • Solicitará sua(s) rede(s) LAN\n  • Aplicará todas as regras de forma segura\n  • Testará conectividade antes de finalizar" \
                    "${RED}⚠ VOCÊ PODE PERDER ACESSO SSH SE CONFIGURAR ERRADO!${NC}\n\nSe você:\n  • ${RED}Estiver atrás de CGNAT${NC} → O script ajudará a descobrir\n  • ${RED}Usar Cloudflare Tunnel${NC} → SSH via tunnel funcionará\n  • ${RED}Tem múltiplas LANs${NC} → Pode configurar todas\n\n${YELLOW}O script fornecerá:${NC}\n  • Detecção automática de rede\n  • Instruções passo a passo\n  • Confirmação antes de aplicar" \
                    "1. ${GREEN}Tenha acesso via Cloudflare Tunnel${NC} como backup\n2. ${GREEN}Saiba o IP da sua rede LAN${NC} (ex: 192.168.1.100)\n3. ${GREEN}Esteja preparado${NC} para acessar via console do provedor\n4. ${GREEN}Faça backup${NC}: ${GRAY}sudo ufw status numbered > ufw-backup.txt${NC}"; then
                    run_script "$SCRIPT_DIR/manutencao/firewall-perfil-padrao.sh" "Firewall - Modo Assistente"
                fi
                ;;
            3)
                # Ver status atual
                clear_screen
                echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
                echo -e "${WHITE}📊 Status Atual do Firewall${NC}"
                echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
                echo ""
                if command -v ufw &>/dev/null; then
                    ufw status verbose
                else
                    echo -e "${RED}UFW não está instalado${NC}"
                fi
                echo ""
                pause
                ;;
            4)
                # Gerenciador Interativo
                run_script "$SCRIPT_DIR/manutencao/firewall-interativo.sh" "Firewall Interativo"
                ;;
            0)
                return
                ;;
            *)
                echo -e "${RED}Opção inválida!${NC}"
                sleep 1
                ;;
        esac
    done
}

# Configuração
handle_config_menu() {
    while true; do
        show_config_menu
        read -r option

        case $option in
            1)
                # Configurar Destinos de Backup (S3, R2, Google Drive, SSH)
                run_script "$SCRIPT_DIR/backup/configurar-backup-destinos.sh" "Configurar Destinos de Backup"
                ;;
            2)
                run_script "$SCRIPT_DIR/scripts-auxiliares/configurar-cron.sh" "Configurar Cron"
                ;;
            3)
                if [ -f "$SCRIPT_DIR/config/config.env" ]; then
                    nano "$SCRIPT_DIR/config/config.env"
                    log_execution "Edição de config.env"
                else
                    echo -e "${RED}Arquivo config.env não encontrado!${NC}"
                    pause
                fi
                ;;
            4)
                handle_firewall_menu
                ;;
            5)
                clear_screen
                echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
                echo -e "${WHITE}Configuração do Cloudflare Tunnel${NC}"
                echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
                echo ""
                echo -e "${YELLOW}Consulte o guia completo em:${NC}"
                echo -e "${BLUE}docs/GUIA-COMPLETO-INFRAESTRUTURA-SEGURA.md${NC}"
                echo ""
                if systemctl is-active --quiet cloudflared; then
                    echo -e "${GREEN}✓ Cloudflared está rodando${NC}"
                    echo ""
                    systemctl status cloudflared --no-pager | head -10
                else
                    echo -e "${RED}✗ Cloudflared não está ativo${NC}"
                fi
                echo ""
                pause
                ;;
            6)
                # Configurar API do Coolify
                run_script "$SCRIPT_DIR/scripts-auxiliares/configurar-coolify-api.sh" "Configurar API Coolify"
                ;;
            7)
                clear_screen
                echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
                echo -e "${WHITE}Configurações Atuais${NC}"
                echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
                echo ""
                echo -e "${MAGENTA}▶ Destinos de Backup:${NC}"
                if [ -f "/opt/vpsguardian/config/backup-destinations.conf" ]; then
                    source "/opt/vpsguardian/config/backup-destinations.conf"
                    [ "$BACKUP_DEST_LOCAL" = "true" ] && echo "  ✅ Local" || echo "  ❌ Local"
                    [ "$BACKUP_DEST_SSH" = "true" ] && echo "  ✅ SSH → $SSH_REMOTE_USER@$SSH_REMOTE_SERVER" || echo "  ❌ SSH"
                    [ "$BACKUP_DEST_GOOGLE_DRIVE" = "true" ] && echo "  ✅ Google Drive → ${GDRIVE_REMOTE_NAME}:${GDRIVE_DIR}" || echo "  ❌ Google Drive"
                    if [ "$BACKUP_DEST_AWS_S3" = "true" ]; then
                        [ -n "$S3_ENDPOINT" ] && echo "  ✅ S3/R2 → s3://${S3_BUCKET} (${S3_ENDPOINT})" || echo "  ✅ AWS S3 → s3://${S3_BUCKET}"
                    else
                        echo "  ❌ AWS S3 / R2"
                    fi
                else
                    echo "  Não configurado (execute opção 1)"
                fi
                echo ""
                echo -e "${MAGENTA}▶ Cron Jobs:${NC}"
                crontab -l 2>/dev/null | grep -v "^#" | grep -v "^$" || echo "  Nenhum cron job configurado"
                echo ""
                echo -e "${MAGENTA}▶ Portas Abertas (UFW):${NC}"
                ufw status 2>/dev/null | grep ALLOW || echo "  UFW não configurado"
                echo ""
                echo -e "${MAGENTA}▶ Updates Automáticos:${NC}"
                if systemctl is-active --quiet unattended-upgrades 2>/dev/null; then
                    echo "  ✅ unattended-upgrades: ativo"
                    # Verificar configuração
                    if [ -f "/etc/apt/apt.conf.d/50unattended-upgrades" ]; then
                        if grep -q "Automatic-Reboot \"true\"" /etc/apt/apt.conf.d/50unattended-upgrades 2>/dev/null; then
                            REBOOT_TIME=$(grep "Automatic-Reboot-Time" /etc/apt/apt.conf.d/50unattended-upgrades 2>/dev/null | grep -oP '"\K[^"]+' | head -1)
                            echo "  ✅ Reboot automático: ${REBOOT_TIME:-03:00}"
                        else
                            echo "  ❌ Reboot automático: desabilitado"
                        fi
                    fi
                    # Verificar notificações Discord
                    if [ -f "/etc/apt/apt.conf.d/99vpsguardian-notify" ]; then
                        echo "  ✅ Notificações Discord: configuradas"
                    fi
                    # Verificar se precisa reboot
                    if [ -f /var/run/reboot-required ]; then
                        echo -e "  ${YELLOW}⚠️  Reboot pendente${NC}"
                    fi
                else
                    echo "  ❌ unattended-upgrades: não configurado"
                    echo "     Configure em: Menu → Configurações → Tarefas Agendadas"
                fi
                echo ""
                echo -e "${MAGENTA}▶ Coolify API:${NC}"
                if [ "$COOLIFY_API_ENABLED" = "true" ]; then
                    echo "  ✅ Integração: habilitada"
                    echo "     URL: ${COOLIFY_API_URL:-http://localhost:8000/api/v1}"
                    if [ -n "$COOLIFY_API_TOKEN" ]; then
                        echo "     Token: ${COOLIFY_API_TOKEN:0:10}...${COOLIFY_API_TOKEN: -5}"
                    fi
                    [ "$COOLIFY_USE_API_FOR_STOP" = "true" ] && echo "  ✅ Stop/Start via API: ativo" || echo "  ❌ Stop/Start via API: desativado"
                else
                    echo "  ❌ Integração: desabilitada"
                    echo "     Configure em: Menu → Configurações → Configurar API do Coolify"
                fi
                echo ""
                if [ -f "$SCRIPT_DIR/config/config.env" ]; then
                    echo -e "${MAGENTA}▶ Configurações (config.env):${NC}"
                    cat "$SCRIPT_DIR/config/config.env"
                fi
                echo ""
                pause
                ;;
            0)
                return
                ;;
            *)
                echo -e "${RED}Opção inválida!${NC}"
                sleep 1
                ;;
        esac
    done
}

# Obsidian
handle_obsidian_menu() {
    while true; do
        show_obsidian_menu
        read -r option

        case $option in
            1)
                # Backup com GitHub
                if confirm "Executar backup do Obsidian para GitHub?"; then
                    run_script "$SCRIPT_DIR/obsidian/backup-github.sh" "Backup Obsidian GitHub"
                fi
                ;;
            2)
                # Instalar Syncthing
                if confirm "Instalar e configurar Syncthing?"; then
                    run_script "$SCRIPT_DIR/obsidian/instalar-syncthing.sh" "Instalar Syncthing"
                fi
                ;;
            3)
                # Configurar Cron
                if confirm "Configurar backup automático com cron?"; then
                    run_script "$SCRIPT_DIR/obsidian/configurar-cron-backup.sh" "Configurar Backup Automático"
                fi
                ;;
            4)
                # Status dos serviços
                clear_screen
                echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
                echo -e "${WHITE}📊 Status dos Serviços Obsidian${NC}"
                echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
                echo ""

                # Carregar configuração para pegar o vault path
                OBSIDIAN_VAULT_PATH="/root/obsidian-vault"  # padrão
                if [ -f "$SCRIPT_DIR/config/config.env" ]; then
                    source "$SCRIPT_DIR/config/config.env"
                fi

                echo -e "${MAGENTA}▶ Configuração:${NC}"
                echo -e "${GRAY}Vault Path: ${WHITE}$OBSIDIAN_VAULT_PATH${NC}"
                echo -e "${GRAY}Config File: ${WHITE}$SCRIPT_DIR/config/config.env${NC}"
                echo ""

                # Verificar Git
                echo -e "${MAGENTA}▶ Git:${NC}"
                if command -v git &> /dev/null; then
                    echo -e "${GREEN}✓ Git instalado${NC}"
                    git --version
                    echo ""
                    if [ -d "$OBSIDIAN_VAULT_PATH/.git" ]; then
                        echo -e "${GREEN}✓ Vault configurado como repositório Git${NC}"
                        echo -e "${GRAY}Localização: $OBSIDIAN_VAULT_PATH${NC}"
                        cd "$OBSIDIAN_VAULT_PATH" 2>/dev/null && {
                            echo -e "${GRAY}Remote: $(git remote get-url origin 2>/dev/null || echo 'Não configurado')${NC}"
                            echo -e "${GRAY}Branch: $(git branch --show-current 2>/dev/null || echo 'N/A')${NC}"
                            echo -e "${GRAY}Último commit: $(git log -1 --format='%h - %s (%ar)' 2>/dev/null || echo 'N/A')${NC}"
                        }
                    else
                        echo -e "${YELLOW}⚠ Vault não é um repositório Git${NC}"
                    fi
                else
                    echo -e "${RED}✗ Git não instalado${NC}"
                fi
                echo ""

                # Verificar Syncthing
                echo -e "${MAGENTA}▶ Syncthing:${NC}"
                if command -v syncthing &> /dev/null; then
                    echo -e "${GREEN}✓ Syncthing instalado${NC}"
                    syncthing --version | head -1
                    echo ""
                    if systemctl is-active --quiet syncthing@root; then
                        echo -e "${GREEN}✓ Serviço rodando${NC}"
                        systemctl status syncthing@root --no-pager | head -5
                    else
                        echo -e "${RED}✗ Serviço parado${NC}"
                    fi
                else
                    echo -e "${YELLOW}⚠ Syncthing não instalado${NC}"
                fi
                echo ""

                # Verificar Cron
                echo -e "${MAGENTA}▶ Backup Automático (Cron):${NC}"
                if crontab -l 2>/dev/null | grep -q "obsidian\|backup-github.sh"; then
                    echo -e "${GREEN}✓ Cron configurado${NC}"
                    echo ""
                    echo -e "${GRAY}Jobs agendados:${NC}"
                    crontab -l 2>/dev/null | grep -B 1 "obsidian\|backup-github.sh" | sed 's/^/  /'
                else
                    echo -e "${YELLOW}⚠ Nenhum backup automático configurado${NC}"
                    echo -e "${GRAY}  Configure na opção 3 do menu${NC}"
                fi
                echo ""
                echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
                pause
                ;;
            0)
                return
                ;;
            *)
                echo -e "${RED}Opção inválida!${NC}"
                sleep 1
                ;;
        esac
    done
}

# Documentação
show_documentation() {
    clear_screen
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${WHITE}📚 DOCUMENTAÇÃO DISPONÍVEL${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${WHITE}Guias disponíveis no diretório 'docs/':${NC}"
    echo ""

    if [ -d "$SCRIPT_DIR/docs" ]; then
        ls -1 "$SCRIPT_DIR/docs"/*.md 2>/dev/null | while read -r doc; do
            echo -e "  ${BLUE}→ $(basename "$doc")${NC}"
        done
    else
        echo -e "  ${YELLOW}Nenhuma documentação encontrada${NC}"
    fi

    echo ""
    echo -e "${WHITE}Outros arquivos de documentação:${NC}"
    echo ""
    [ -f "$SCRIPT_DIR/README.md" ] && echo -e "  ${BLUE}→ README.md${NC}"
    [ -f "$SCRIPT_DIR/GUIA.md" ] && echo -e "  ${BLUE}→ GUIA.md${NC}"

    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${WHITE}Para visualizar um arquivo:${NC}"
    echo -e "  ${GRAY}cat docs/nome-do-arquivo.md${NC}"
    echo -e "  ${GRAY}less docs/nome-do-arquivo.md${NC}"
    echo ""

    pause
}

# Ver logs
show_logs() {
    clear_screen
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${WHITE}📜 LOGS DE EXECUÇÃO${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""

    if [ -f "$LOG_FILE" ]; then
        echo -e "${WHITE}Últimas 30 execuções:${NC}"
        echo ""
        tail -30 "$LOG_FILE" | while IFS= read -r line; do
            if echo "$line" | grep -q "SUCESSO"; then
                echo -e "${GREEN}$line${NC}"
            elif echo "$line" | grep -q "ERRO"; then
                echo -e "${RED}$line${NC}"
            else
                echo -e "${GRAY}$line${NC}"
            fi
        done
        echo ""
        echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
        echo -e "${WHITE}Arquivo completo:${NC} $LOG_FILE"
        echo -e "${WHITE}Total de linhas:${NC} $(wc -l < "$LOG_FILE")"
    else
        echo -e "${YELLOW}Nenhum log encontrado ainda.${NC}"
    fi

    echo ""
    pause
}

################################################################################
# LOOP PRINCIPAL
################################################################################

main() {
    # Verificar se está sendo executado como root
    if [ "$EUID" -ne 0 ]; then
        echo -e "${YELLOW}⚠️  Alguns scripts requerem privilégios de root.${NC}"
        echo -e "${YELLOW}Recomenda-se executar com: sudo $0${NC}"
        echo ""
        sleep 2
    fi

    # Loop principal
    while true; do
        show_main_menu
        read -r option

        case $option in
            1)
                handle_status_menu
                ;;
            2)
                handle_backup_menu
                ;;
            3)
                handle_maintenance_menu
                ;;
            4)
                handle_migration_menu
                ;;
            5)
                handle_config_menu
                ;;
            6)
                show_documentation
                ;;
            7)
                handle_obsidian_menu
                ;;
            8)
                show_logs
                ;;
            0)
                clear_screen
                echo -e "${GREEN}Até logo! 👋${NC}"
                echo ""
                log_execution "Menu Principal encerrado"
                exit 0
                ;;
            *)
                echo -e "${RED}Opção inválida!${NC}"
                sleep 1
                ;;
        esac
    done
}

# Executar menu principal
main
