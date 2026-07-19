#!/bin/bash
################################################################################
# Script de Configuração de Updates Automáticos
# Propósito: Configurar unattended-upgrades para VPS com Docker/Coolify
# Uso: sudo ./configurar-updates-automaticos.sh
################################################################################

set -e

LOG_PREFIX="[ Updates Automáticos ]"

log() {
    echo "$LOG_PREFIX [ $1 ] $2"
}
log_info() { log "INFO" "$*"; }
log_success() { log "OK" "$*"; }
log_error() { log "ERRO" "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_ROOT="${VPSGUARDIAN_ROOT:-$(dirname "$SCRIPT_DIR")}"
if [ -f "/etc/vpsguardian/install.conf" ]; then
    source "/etc/vpsguardian/install.conf"
fi

# Verificar se é root
if [ "$EUID" -ne 0 ]; then
    log_error "Este script deve ser executado como root (use sudo)"
    exit 1
fi

echo "╔════════════════════════════════════════════════════════════╗"
echo "║      CONFIGURAÇÃO DE UPDATES AUTOMÁTICOS DE SEGURANÇA      ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

log_info "Este script irá configurar updates automáticos de segurança"
log_info "Otimizado para VPS com Docker e Coolify"
echo ""

# Instalar pacotes necessários
log_info "========== INSTALANDO PACOTES =========="
echo ""

log_info "Instalando unattended-upgrades e apt-listchanges..."
apt update -qq
apt install -y unattended-upgrades apt-listchanges

log_success "Pacotes instalados"
echo ""

# Ativar unattended-upgrades
log_info "========== ATIVANDO UNATTENDED-UPGRADES =========="
echo ""

log_info "Ativando serviço..."
dpkg-reconfigure -plow unattended-upgrades

log_success "Serviço ativado"
echo ""

# Backup da configuração original
log_info "========== BACKUP DA CONFIGURAÇÃO ORIGINAL =========="
echo ""

CONFIG_FILE="/etc/apt/apt.conf.d/50unattended-upgrades"
BACKUP_FILE="/etc/apt/apt.conf.d/50unattended-upgrades.bak"

if [ ! -f "$BACKUP_FILE" ]; then
    log_info "Criando backup da configuração original..."
    cp "$CONFIG_FILE" "$BACKUP_FILE"
    log_success "Backup criado: $BACKUP_FILE"
else
    log_info "Backup já existe: $BACKUP_FILE"
fi

echo ""

# Perguntar configurações ao usuário
log_info "========== CONFIGURAÇÃO PERSONALIZADA =========="
echo ""

read -p "$LOG_PREFIX [ INPUT ] Incluir updates regulares além de segurança? (y/N): " INCLUDE_UPDATES
INCLUDE_UPDATES=${INCLUDE_UPDATES:-n}

read -p "$LOG_PREFIX [ INPUT ] Reiniciar automaticamente se necessário? (y/N): " AUTO_REBOOT
AUTO_REBOOT=${AUTO_REBOOT:-n}

read -p "$LOG_PREFIX [ INPUT ] Horário para reinício automático (padrão: 03:00): " REBOOT_TIME
REBOOT_TIME=${REBOOT_TIME:-03:00}

read -p "$LOG_PREFIX [ INPUT ] Email para notificações (deixe vazio para pular): " EMAIL_ADDRESS

if [[ ! "$REBOOT_TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
    log_error "Horário inválido: use HH:MM entre 00:00 e 23:59"
    exit 2
fi
if [ -n "$EMAIL_ADDRESS" ] && [[ ! "$EMAIL_ADDRESS" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
    log_error "Endereço de email inválido"
    exit 2
fi

echo ""

# Verificar se webhook Discord está configurado
WEBHOOK_CONFIG="${VPSGUARDIAN_SHARED_CONFIG_FILE:-$INSTALL_ROOT/config/backup-destinations.conf}"
WEBHOOK_URL=""
if [ -f "$WEBHOOK_CONFIG" ]; then
    source "$WEBHOOK_CONFIG"
fi

ENABLE_DISCORD="n"
if [ -n "$WEBHOOK_URL" ] && [[ "$WEBHOOK_URL" == *"discord.com"* ]]; then
    log_info "🔔 Webhook Discord detectado nas configurações!"
    read -p "$LOG_PREFIX [ INPUT ] Enviar notificações de updates para Discord? (Y/n): " ENABLE_DISCORD
    ENABLE_DISCORD=${ENABLE_DISCORD:-y}
else
    log_info "💡 Dica: Configure um webhook Discord em:"
    log_info "   Menu → Configurações → Destinos de Backup → Webhook"
    echo ""
fi

echo ""

# =========================================
# SELEÇÃO DE PACOTES PARA BLACKLIST
# =========================================
log_info "========== PROTEÇÃO DE PACOTES =========="
echo ""

# Array com pacotes e descrições (ESCALÁVEL - fácil adicionar novos)
declare -a PACKAGES=(
    "docker-ce:Docker Engine"
    "docker-ce-cli:Docker CLI"
    "containerd.io:Containerd Runtime"
    "docker-compose-v2:Docker Compose"
    "postgresql-*:PostgreSQL Database"
    "mysql-server:MySQL Server"
    "mariadb-server:MariaDB Server"
    "nginx:Nginx Web Server"
    "apache2:Apache Web Server"
    "haproxy:HAProxy Load Balancer"
    "nodejs:Node.js Runtime"
    "golang-*:Go Programming Language"
    "python3:Python 3 Interpreter"
    "redis-server:Redis Cache"
    "mongodb:MongoDB Database"
)

# Detectar se Coolify está instalado (pré-selecionar Docker)
COOLIFY_INSTALLED=false
if systemctl is-active --quiet coolify 2>/dev/null || [ -d "/data/coolify" ] || [ -d "/opt/coolify" ]; then
    COOLIFY_INSTALLED=true
    log "WARN" "⚠️  Coolify detectado no sistema!"
fi

# Array para rastrear seleções (índice correspondente ao PACKAGES)
declare -a SELECTED
for i in "${!PACKAGES[@]}"; do
    SELECTED[$i]=0
done

# Se Coolify detectado, pré-selecionar Docker
if [ "$COOLIFY_INSTALLED" = true ]; then
    SELECTED[0]=1  # docker-ce
    SELECTED[1]=1  # docker-ce-cli
    SELECTED[2]=1  # containerd.io
    SELECTED[3]=1  # docker-compose
fi

# Função para renderizar o menu de seleção
render_package_menu() {
    clear
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║   Selecione Pacotes para BLACKLIST (proteger de updates)   ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""

    local counter=1
    for i in "${!PACKAGES[@]}"; do
        IFS=':' read -r package_name description <<< "${PACKAGES[$i]}"
        local checkbox="[ ]"
        if [ "${SELECTED[$i]}" -eq 1 ]; then
            checkbox="[✓]"
        fi
        printf "  %s %2d. %-30s %s\n" "$checkbox" "$counter" "$package_name" "($description)"
        counter=$((counter + 1))
    done

    echo ""
    echo "  Digite o número para marcar/desmarcar, 0 para continuar:"
}

# Loop interativo para seleção
selecting_packages=true
while [ "$selecting_packages" = true ]; do
    render_package_menu
    read -p "  → " -r selection

    if [ "$selection" = "0" ]; then
        selecting_packages=false
    elif [[ "$selection" =~ ^[0-9]+$ ]]; then
        index=$((selection - 1))
        if [ "$index" -ge 0 ] && [ "$index" -lt "${#PACKAGES[@]}" ]; then
            # Toggle seleção
            if [ "${SELECTED[$index]}" -eq 0 ]; then
                SELECTED[$index]=1
            else
                SELECTED[$index]=0
            fi
        else
            echo "❌ Número inválido. Tente novamente."
            sleep 1
        fi
    else
        echo "❌ Entrada inválida. Digite um número."
        sleep 1
    fi
done

echo ""
clear

echo ""
log_info "Configurações escolhidas:"
log_info "  - Updates regulares: $([ "$INCLUDE_UPDATES" = "y" ] && echo "SIM" || echo "NÃO")"
log_info "  - Reinício automático: $([ "$AUTO_REBOOT" = "y" ] && echo "SIM às $REBOOT_TIME" || echo "NÃO")"
log_info "  - Email notificações: ${EMAIL_ADDRESS:-Nenhum}"
log_info "  - Discord notificações: $([ "$ENABLE_DISCORD" = "y" ] && echo "SIM" || echo "NÃO")"
echo ""
log_info "Pacotes na BLACKLIST (protegidos de updates):"

# Contar e listar pacotes selecionados
selected_count=0
for i in "${!PACKAGES[@]}"; do
    if [ "${SELECTED[$i]}" -eq 1 ]; then
        IFS=':' read -r package_name description <<< "${PACKAGES[$i]}"
        log_info "    ✓ $package_name ($description)"
        selected_count=$((selected_count + 1))
    fi
done

if [ "$selected_count" -eq 0 ]; then
    log_info "    (Nenhum pacote selecionado)"
fi
echo ""

read -p "$LOG_PREFIX [ INPUT ] Continuar com estas configurações? (Y/n): " CONFIRM
if [ "$CONFIRM" = "n" ]; then
    log_info "Configuração cancelada"
    exit 0
fi

echo ""

# Criar configuração otimizada
log_info "========== CRIANDO CONFIGURAÇÃO OTIMIZADA =========="
echo ""

log_info "Escrevendo configuração em $CONFIG_FILE..."

cat > "$CONFIG_FILE" << 'EOF'
// Configuração otimizada de Updates Automáticos
// Gerado automaticamente para VPS com Docker/Coolify
// Data: $(date +%Y-%m-%d)

Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
EOF

# Adicionar updates regulares se solicitado
if [ "$INCLUDE_UPDATES" = "y" ]; then
    cat >> "$CONFIG_FILE" << 'EOF'
    "${distro_id}:${distro_codename}-updates";
EOF
fi

cat >> "$CONFIG_FILE" << 'EOF'
};

// Pacotes que NUNCA devem ser atualizados automaticamente
Unattended-Upgrade::Package-Blacklist {
EOF

# Adicionar pacotes selecionados pelo usuário à blacklist
has_selected_packages=false
for i in "${!PACKAGES[@]}"; do
    if [ "${SELECTED[$i]}" -eq 1 ]; then
        IFS=':' read -r package_name description <<< "${PACKAGES[$i]}"
        echo "    \"$package_name\";        // $description" >> "$CONFIG_FILE"
        has_selected_packages=true
    fi
done

# Se nenhum pacote foi selecionado, adicionar um comentário informativo
if [ "$has_selected_packages" = false ]; then
    cat >> "$CONFIG_FILE" << 'EOF'
    // Nenhum pacote selecionado para proteger
    // Descomente exemplos abaixo se precisar proteger alguns:
    // "docker-ce";        // Docker Engine
    // "postgresql-*";     // PostgreSQL
    // "mysql-server";     // MySQL
EOF
fi

cat >> "$CONFIG_FILE" << 'EOF'
};

// Remover dependências não usadas automaticamente
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";

// Auto-remover kernels antigos (mantém apenas 2 últimos)
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";

EOF

# Configurar reinício automático
if [ "$AUTO_REBOOT" = "y" ]; then
    cat >> "$CONFIG_FILE" << EOF
// Reiniciar automaticamente se necessário
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-WithUsers "true";
Unattended-Upgrade::Automatic-Reboot-Time "$REBOOT_TIME";
EOF
else
    cat >> "$CONFIG_FILE" << 'EOF'
// Reiniciar automaticamente se necessário
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Automatic-Reboot-WithUsers "false";
Unattended-Upgrade::Automatic-Reboot-Time "03:00";
EOF
fi

# Configurar email se fornecido
if [ -n "$EMAIL_ADDRESS" ]; then
    cat >> "$CONFIG_FILE" << EOF

// Notificações por email
Unattended-Upgrade::Mail "$EMAIL_ADDRESS";
Unattended-Upgrade::MailReport "on-change";
EOF
else
    cat >> "$CONFIG_FILE" << 'EOF'

// Notificações por email (desabilitado)
// Unattended-Upgrade::Mail "seu-email@exemplo.com";
Unattended-Upgrade::MailReport "on-change";
EOF
fi

# Adicionar configurações finais
cat >> "$CONFIG_FILE" << 'EOF'

// Aplicar updates em passos mínimos (mais estável)
Unattended-Upgrade::MinimalSteps "true";

// Instalar atualizações de segurança automaticamente
Unattended-Upgrade::InstallOnShutdown "false";

// Logar detalhadamente
Unattended-Upgrade::Verbose "true";

// Modo de debug (desabilitado por padrão)
// Unattended-Upgrade::Debug "true";

// Baixar e instalar automaticamente
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
EOF

log_success "Configuração criada com sucesso"
echo ""

# Aviso sobre Docker e Coolify
if [ "$COOLIFY_INSTALLED" = true ]; then
    # Verificar se Docker foi selecionado
    docker_selected=false
    for i in 0 1 2 3; do  # Índices do Docker
        if [ "${SELECTED[$i]}" -eq 1 ]; then
            docker_selected=true
            break
        fi
    done

    if [ "$docker_selected" = true ]; then
        echo "╔════════════════════════════════════════════════════════════╗"
        echo "║                   ✅ PROTEÇÃO ATIVADA                      ║"
        echo "╚════════════════════════════════════════════════════════════╝"
        echo ""
        log_success "Docker está PROTEGIDO (na BLACKLIST)"
        echo "  Motivo: Você usa Coolify, e updates de Docker podem:"
        echo "    • Causar downtime em aplicações"
        echo "    • Quebrar compatibilidade de containers"
        echo "    • Causar perda de dados não persistidos"
        echo ""
        echo "  ✅ Proteção ativada com sucesso!"
        echo ""
        echo "  Para atualizar Docker manualmente no futuro:"
        echo "    1. Faça backup: sudo bash /backup/backup-coolify.sh"
        echo "    2. Remova da blacklist: sudo nano /etc/apt/apt.conf.d/50unattended-upgrades"
        echo "    3. Atualize: sudo apt install docker-ce docker-ce-cli containerd.io"
        echo "    4. Teste: docker ps -a"
        echo "    5. Re-adicione à blacklist (recomendado)"
        echo ""
    else
        echo "╔════════════════════════════════════════════════════════════╗"
        echo "║                   ⚠️  AVISO IMPORTANTE                     ║"
        echo "╚════════════════════════════════════════════════════════════╝"
        echo ""
        log "WARN" "Coolify detectado, mas Docker NÃO foi selecionado"
        echo "  Recomendação FORTE: Proteja Docker na blacklist"
        echo ""
        echo "  Motivos:"
        echo "    • Updates de Docker podem causar downtime"
        echo "    • Pode quebrar compatibilidade de containers"
        echo "    • Risco de perda de dados não persistidos"
        echo ""
        echo "  Para re-configurar:"
        echo "    sudo bash manutencao/configurar-updates-automaticos.sh"
        echo ""
    fi
fi
echo ""

# Criar configuração adicional
log_info "========== CONFIGURAÇÃO ADICIONAL =========="
echo ""

AUTO_UPGRADES_FILE="/etc/apt/apt.conf.d/20auto-upgrades"

log_info "Criando $AUTO_UPGRADES_FILE..."

cat > "$AUTO_UPGRADES_FILE" << 'EOF'
// Habilitar updates automáticos
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
EOF

log_success "Configuração adicional criada"
echo ""

# Habilitar e iniciar serviços
log_info "========== HABILITANDO SERVIÇOS =========="
echo ""

log_info "Habilitando timer do unattended-upgrades..."
systemctl enable unattended-upgrades
systemctl restart unattended-upgrades

log_success "Serviços habilitados e iniciados"
echo ""

# Configurar notificações Discord se habilitado
if [[ "$ENABLE_DISCORD" =~ ^[Yy]$ ]]; then
    log_info "========== CONFIGURANDO NOTIFICAÇÕES DISCORD =========="
    echo ""

    # Verificar se script de notificação existe
    NOTIF_SCRIPT="$INSTALL_ROOT/manutencao/notificar-updates.sh"
    if [ -f "$NOTIF_SCRIPT" ]; then
        chmod +x "$NOTIF_SCRIPT"

        # Criar hook do apt para notificar após updates
        APT_HOOK="/etc/apt/apt.conf.d/99vpsguardian-notify"
        cat > "$APT_HOOK" << EOF
// VPS Guardian - Notificações Discord após updates
DPkg::Post-Invoke { "$NOTIF_SCRIPT check || true"; };
EOF
        log_success "Hook de notificação criado: $APT_HOOK"

        # Adicionar cron para relatório diário (se não existir)
        if ! crontab -l 2>/dev/null | grep -q "notificar-updates.sh daily"; then
            log_info "Adicionando relatório diário ao cron..."
            NOTIF_LOG_DIR="${LOG_ROOT:-/var/log/vpsguardian}"
            mkdir -p "$NOTIF_LOG_DIR"
            NOTIF_SCRIPT_Q=$(printf '%q' "$NOTIF_SCRIPT")
            NOTIF_LOG_Q=$(printf '%q' "$NOTIF_LOG_DIR/cron-updates-notify.log")
            (crontab -l 2>/dev/null; echo "# Relatório diário de updates (Discord)"; echo "0 10 * * * $NOTIF_SCRIPT_Q daily >> $NOTIF_LOG_Q 2>&1") | crontab -
            log_success "Relatório diário agendado para 10:00"
        fi

        # Testar notificação
        log_info "Enviando notificação de teste..."
        "$NOTIF_SCRIPT" test
        echo ""
    else
        log "WARN" "Script de notificação não encontrado: $NOTIF_SCRIPT"
        log_info "Instale o VPS Guardian para habilitar notificações Discord"
    fi
    echo ""
fi

# Testar configuração
log_info "========== TESTANDO CONFIGURAÇÃO =========="
echo ""

log_info "Executando dry-run (simulação)..."
unattended-upgrade --dry-run --debug

echo ""
log_success "Teste de configuração concluído"
echo ""

# Resumo
log_success "========== CONFIGURAÇÃO CONCLUÍDA =========="
echo ""
echo "  ✅ Unattended-upgrades instalado e configurado"
echo "  ✅ Updates de segurança: HABILITADOS"
echo "  ✅ Updates regulares: $([ "$INCLUDE_UPDATES" = "y" ] && echo "HABILITADOS" || echo "DESABILITADOS")"
echo "  ✅ Reinício automático: $([ "$AUTO_REBOOT" = "y" ] && echo "HABILITADO às $REBOOT_TIME" || echo "DESABILITADO")"
echo "  ✅ Limpeza automática: HABILITADA (a cada 7 dias)"
echo "  ✅ Remoção de kernels antigos: HABILITADA"
echo ""

if [ -n "$EMAIL_ADDRESS" ]; then
    echo "  📧 Email: $EMAIL_ADDRESS"
fi

if [[ "$ENABLE_DISCORD" =~ ^[Yy]$ ]]; then
    echo "  🔔 Discord: Webhook configurado"
    echo "     • Notificação após cada update"
    echo "     • Relatório diário às 10:00"
fi

echo ""

echo "  📁 Arquivos de configuração:"
echo "     • $CONFIG_FILE"
echo "     • $AUTO_UPGRADES_FILE"
echo "     • Backup: $BACKUP_FILE"
echo ""

log_info "========== COMANDOS ÚTEIS =========="
echo ""
echo "  # Ver status do serviço"
echo "  sudo systemctl status unattended-upgrades"
echo ""
echo "  # Ver log de updates"
echo "  sudo cat /var/log/unattended-upgrades/unattended-upgrades.log"
echo ""
echo "  # Executar update manualmente (dry-run)"
echo "  sudo unattended-upgrade --dry-run --debug"
echo ""
echo "  # Executar update manualmente"
echo "  sudo unattended-upgrade --debug"
echo ""
echo "  # Editar configuração"
echo "  sudo nano $CONFIG_FILE"
echo ""
echo "  # Restaurar backup"
echo "  sudo cp $BACKUP_FILE $CONFIG_FILE"
echo ""

log_info "========== PRÓXIMOS PASSOS =========="
echo ""
echo "  1. Verifique os logs regularmente:"
echo "     tail -f /var/log/unattended-upgrades/unattended-upgrades.log"
echo ""
echo "  2. Teste manualmente após alguns dias:"
echo "     sudo unattended-upgrade --dry-run"
echo ""
echo "  3. Configure email (se ainda não fez):"
echo "     sudo apt install mailutils -y"
echo ""

log_success "Sistema de updates automáticos configurado e ativo! 🚀"
