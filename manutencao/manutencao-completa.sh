#!/bin/bash
################################################################################
# Script de Manutenção Automatizada para VPS com Docker/Coolify
# Autor: Baseado no setup de Zsolt (hyperknot) com melhorias
# Versão: 2.0
# Uso: Execute manualmente ou via cron
################################################################################

# Carregar biblioteca de notificações
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/notificacoes.sh" 2>/dev/null || true

# Configurações
LOG_DIR="/var/log/vpsguardian"
LOG_FILE="$LOG_DIR/manutencao.log"
DISCO_LIMITE=85 # Alerta se disco > 85%
MANTER_KERNELS=2 # Quantos kernels manter

# Marcar início para calcular duração
MANUTENCAO_START_TIME=$(date +%s)

# Cores para output (opcional, remova se der problema)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

################################################################################
# FUNÇÕES AUXILIARES
################################################################################

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[ERRO]${NC} $1" | tee -a "$LOG_FILE"
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $1" | tee -a "$LOG_FILE"
}

log_warning() {
    echo -e "${YELLOW}[AVISO]${NC} $1" | tee -a "$LOG_FILE"
}


# Calcula espaço livre
espaco_livre() {
    df -h / | awk 'NR==2 {print $5}' | sed 's/%//'
}

# Calcula tamanho legível
tamanho_humano() {
    numfmt --to=iec-i --suffix=B "$1" 2>/dev/null || echo "$1 bytes"
}

################################################################################
# INÍCIO DA MANUTENÇÃO
################################################################################

# Criar diretório de logs se não existir
mkdir -p "$LOG_DIR"

log "========================================"
log "INICIANDO MANUTENÇÃO AUTOMATIZADA"
log "========================================"

# Notificar início
notify_maintenance_start

# Espaço inicial
ESPACO_INICIAL=$(espaco_livre)
log "Uso de disco inicial: ${ESPACO_INICIAL}%"

################################################################################
# 1. ATUALIZAÇÕES DE SEGURANÇA
################################################################################

log "--- 1. Verificando atualizações de segurança ---"

# Atualizar lista de pacotes
apt-get update > /dev/null 2>&1
UPDATES_DISPONIVEIS=$(apt list --upgradable 2>/dev/null | grep -c "upgradable")

if [ "$UPDATES_DISPONIVEIS" -gt 0 ]; then
    log_warning "$UPDATES_DISPONIVEIS pacotes disponíveis para atualização"

    # Executar unattended-upgrades se instalado
    if command -v unattended-upgrade &> /dev/null; then
        log "Aplicando updates de segurança via unattended-upgrades..."
        unattended-upgrade -d >> "$LOG_FILE" 2>&1

        if [ $? -eq 0 ]; then
            log_success "Updates de segurança aplicados"
        else
            log_error "Erro ao aplicar updates"
        fi
    else
        log_warning "unattended-upgrades não instalado, pulando updates automáticos"
    fi
else
    log_success "Sistema atualizado, sem updates disponíveis"
fi

################################################################################
# 2. LIMPEZA DE DOCKER
################################################################################

if command -v docker &> /dev/null; then
    log "--- 2. Limpeza de Docker ---"

    # Espaço Docker antes
    DOCKER_ANTES=$(docker system df --format "{{.Reclaimable}}" 2>/dev/null | grep -oE '[0-9.]+GB' | head -1 | sed 's/GB//')

    if [ -n "$DOCKER_ANTES" ]; then
        log "Espaço recuperável antes: ${DOCKER_ANTES}GB"
    fi

    # Remover containers parados
    CONTAINERS_PARADOS=$(docker ps -q -f status=exited 2>/dev/null | wc -l)
    if [ "$CONTAINERS_PARADOS" -gt 0 ]; then
        log "Removendo $CONTAINERS_PARADOS containers parados..."
        docker container prune -f >> "$LOG_FILE" 2>&1
    fi

    # Remover imagens não usadas (dangling)
    IMAGENS_DANGLING=$(docker images -q -f dangling=true 2>/dev/null | wc -l)
    if [ "$IMAGENS_DANGLING" -gt 0 ]; then
        log "Removendo $IMAGENS_DANGLING imagens dangling..."
        docker image prune -f >> "$LOG_FILE" 2>&1
    fi

    # Remover volumes não usados (CUIDADO!)
    VOLUMES_ORFAOS=$(docker volume ls -q -f dangling=true 2>/dev/null | wc -l)
    if [ "$VOLUMES_ORFAOS" -gt 0 ]; then
        log_warning "$VOLUMES_ORFAOS volumes órfãos encontrados"
        # DESCOMENTE a linha abaixo para remover automaticamente (PERIGOSO)
        # docker volume prune -f >> "$LOG_FILE" 2>&1
        log "Volumes não removidos automaticamente (segurança). Revise manualmente."
    fi

    # Remover build cache
    log "Limpando build cache..."
    docker builder prune -a -f >> "$LOG_FILE" 2>&1

    # Espaço Docker depois
    DOCKER_DEPOIS=$(docker system df --format "{{.Reclaimable}}" 2>/dev/null | grep -oE '[0-9.]+GB' | head -1 | sed 's/GB//')

    if [ -n "$DOCKER_ANTES" ] && [ -n "$DOCKER_DEPOIS" ]; then
        ECONOMIZADO=$(echo "$DOCKER_ANTES - $DOCKER_DEPOIS" | bc 2>/dev/null)
        if [ -n "$ECONOMIZADO" ] && (( $(echo "$ECONOMIZADO > 0" | bc -l) )); then
            log_success "Docker: ~${ECONOMIZADO}GB recuperados"
        fi
    fi

else
    log_warning "Docker não instalado, pulando limpeza de containers"
fi

################################################################################
# 3. LIMPEZA DE PACOTES DO SISTEMA
################################################################################

log "--- 3. Limpeza de pacotes do sistema ---"

# Remover pacotes órfãos
log "Removendo pacotes não usados..."
apt-get autoremove --purge -y >> "$LOG_FILE" 2>&1

# Remover configurações de pacotes desinstalados
CONFIGS_ORFAS=$(dpkg --list | grep "^rc" | wc -l)
if [ "$CONFIGS_ORFAS" -gt 0 ]; then
    log "Removendo $CONFIGS_ORFAS configurações órfãs..."
    dpkg --list | grep "^rc" | cut -d " " -f 3 | xargs -r dpkg --purge >> "$LOG_FILE" 2>&1
fi

# Limpar cache do APT
log "Limpando cache do APT..."
apt-get autoclean -y >> "$LOG_FILE" 2>&1
apt-get clean -y >> "$LOG_FILE" 2>&1

log_success "Pacotes limpos"

################################################################################
# 4. LIMPEZA DE KERNELS ANTIGOS
################################################################################

log "--- 4. Limpeza de kernels antigos ---"

KERNEL_ATUAL=$(uname -r)
KERNELS_INSTALADOS=$(dpkg --list | grep -c "^ii  linux-image")

log "Kernel em uso: $KERNEL_ATUAL"
log "Kernels instalados: $KERNELS_INSTALADOS"

if [ "$KERNELS_INSTALADOS" -gt "$MANTER_KERNELS" ]; then
    log "Removendo kernels antigos (mantendo $MANTER_KERNELS)..."

    # Método 1: usando apt autoremove
    apt-get autoremove --purge -y >> "$LOG_FILE" 2>&1

    # Método 2: purge-old-kernels (se disponível)
    if command -v purge-old-kernels &> /dev/null; then
        purge-old-kernels --keep $MANTER_KERNELS -qy >> "$LOG_FILE" 2>&1
    fi

    KERNELS_APOS=$(dpkg --list | grep -c "^ii  linux-image")
    REMOVIDOS=$((KERNELS_INSTALADOS - KERNELS_APOS))

    if [ "$REMOVIDOS" -gt 0 ]; then
        log_success "$REMOVIDOS kernels removidos"
    fi
else
    log_success "Apenas $KERNELS_INSTALADOS kernels instalados, nada a remover"
fi

################################################################################
# 5. LIMPEZA DE LOGS
################################################################################

log "--- 5. Limpeza de logs ---"

# Tamanho dos logs antes
LOGS_ANTES=$(du -sb /var/log 2>/dev/null | awk '{print $1}')

# Limpar journal (systemd)
if command -v journalctl &> /dev/null; then
    log "Limpando journalctl (mantendo 30 dias)..."
    journalctl --vacuum-time=30d >> "$LOG_FILE" 2>&1
fi

# Rotacionar logs
if [ -f /etc/logrotate.conf ]; then
    log "Forçando rotação de logs..."
    logrotate -f /etc/logrotate.conf >> "$LOG_FILE" 2>&1
fi

# Remover logs antigos de manutenção (mantém 90 dias)
find "$LOG_DIR" -name "*.log" -type f -mtime +90 -delete 2>/dev/null

# Tamanho dos logs depois
LOGS_DEPOIS=$(du -sb /var/log 2>/dev/null | awk '{print $1}')

if [ -n "$LOGS_ANTES" ] && [ -n "$LOGS_DEPOIS" ]; then
    LOGS_ECONOMIZADO=$((LOGS_ANTES - LOGS_DEPOIS))
    if [ "$LOGS_ECONOMIZADO" -gt 0 ]; then
        log_success "Logs: $(tamanho_humano $LOGS_ECONOMIZADO) recuperados"
    fi
fi

################################################################################
# 6. VERIFICAÇÕES FINAIS
################################################################################

log "--- 6. Verificações finais ---"

# Espaço final
ESPACO_FINAL=$(espaco_livre)
ECONOMIZADO_TOTAL=$((ESPACO_INICIAL - ESPACO_FINAL))

log "Uso de disco final: ${ESPACO_FINAL}%"

if [ "$ECONOMIZADO_TOTAL" -gt 0 ]; then
    log_success "Espaço recuperado: ${ECONOMIZADO_TOTAL}%"
else
    log "Nenhum espaço adicional recuperado (sistema já otimizado)"
fi

# Alerta se disco > limite
if [ "$ESPACO_FINAL" -gt "$DISCO_LIMITE" ]; then
    log_error "ALERTA: Disco em ${ESPACO_FINAL}% (limite: ${DISCO_LIMITE}%)"
    DISCO_LIVRE=$(df -h / | awk 'NR==2 {print $4}')
    DISCO_TOTAL=$(df -h / | awk 'NR==2 {print $2}')
    notify_disk_alert "${ESPACO_FINAL}%" "$DISCO_LIVRE" "$DISCO_TOTAL"
fi

# Verificar se precisa reboot
if [ -f /var/run/reboot-required ]; then
    log_warning "Reboot necessário após atualizações"
    send_discord_simple "⚠️ Reboot Necessário" "O servidor precisa ser reiniciado após atualizações de sistema." "warning"

    # DESCOMENTE para reboot automático (CUIDADO!)
    # log "Agendando reboot em 5 minutos..."
    # shutdown -r +5 "Reboot automático após manutenção" &
fi

################################################################################
# 7. RELATÓRIO FINAL
################################################################################

log "========================================"
log "MANUTENÇÃO CONCLUÍDA"
log "========================================"

# Gerar resumo
RESUMO="
📊 RELATÓRIO DE MANUTENÇÃO - $(hostname)
Data: $(date '+%d/%m/%Y %H:%M')

💾 Disco:
  - Antes: ${ESPACO_INICIAL}%
  - Depois: ${ESPACO_FINAL}%
  - Recuperado: ${ECONOMIZADO_TOTAL}%

📦 Pacotes:
  - Updates aplicados: Verificar logs
  - Kernels instalados: $KERNELS_INSTALADOS

🐳 Docker:
  - Containers parados removidos: $CONTAINERS_PARADOS
  - Imagens limpas: $IMAGENS_DANGLING
  - Volumes órfãos: $VOLUMES_ORFAOS (não removidos)

📋 Logs completos: $LOG_FILE
"

echo "$RESUMO" | tee -a "$LOG_FILE"

# Calcular duração
MANUTENCAO_END_TIME=$(date +%s)
MANUTENCAO_DURATION=$((MANUTENCAO_END_TIME - MANUTENCAO_START_TIME))
MANUTENCAO_DURATION_FMT=$(printf '%02d:%02d:%02d' $((MANUTENCAO_DURATION/3600)) $((MANUTENCAO_DURATION%3600/60)) $((MANUTENCAO_DURATION%60)))

# Notificar sucesso
ACOES_REALIZADAS="Disco: ${ESPACO_INICIAL}% → ${ESPACO_FINAL}% | Docker: limpo | Logs: rotacionados"
notify_maintenance_success "$MANUTENCAO_DURATION_FMT" "$ACOES_REALIZADAS"

# Rotacionar log se muito grande (> 10MB)
LOG_SIZE=$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
if [ "$LOG_SIZE" -gt 10485760 ]; then
    mv "$LOG_FILE" "${LOG_FILE}.old"
    log "Log rotacionado (arquivo anterior salvo como .old)"
fi

exit 0
