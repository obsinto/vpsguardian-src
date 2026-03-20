#!/bin/bash
################################################################################
# Script de Configuração Automática de Cron
# Propósito: Configurar automaticamente todas as tarefas agendadas
# Uso: sudo ./configurar-cron.sh
################################################################################

set -e

LOG_PREFIX="[ Cron Config ]"

log() {
    echo "$LOG_PREFIX [ $1 ] $2"
}

log_error() {
    echo "$LOG_PREFIX [ ERRO ] $1"
}

log_success() {
    echo "$LOG_PREFIX [ OK ] $1"
}

# Arquivo de configuração de destinos
BACKUP_DEST_CONFIG="/opt/vpsguardian/config/backup-destinations.conf"

# Função para atualizar variável no arquivo de configuração
update_config_var() {
    local var_name="$1"
    local var_value="$2"
    local config_file="${3:-$BACKUP_DEST_CONFIG}"

    if [ ! -f "$config_file" ]; then
        log "WARN" "Arquivo de config não encontrado: $config_file"
        return 1
    fi

    # Se a variável existe, atualiza; senão, adiciona
    if grep -q "^${var_name}=" "$config_file"; then
        sed -i "s|^${var_name}=.*|${var_name}=\"${var_value}\"|" "$config_file"
    else
        echo "${var_name}=\"${var_value}\"" >> "$config_file"
    fi
}

# Função para salvar configurações de retenção
save_retention_config() {
    local strategy="$1"
    local days="$2"
    local count="$3"

    if [ -f "$BACKUP_DEST_CONFIG" ]; then
        log "INFO" "Salvando configurações de retenção..."
        update_config_var "BACKUP_RETENTION_STRATEGY" "$strategy"
        update_config_var "BACKUP_RETENTION_DAYS" "$days"
        update_config_var "BACKUP_RETENTION_COUNT" "$count"
        log_success "Configurações de retenção salvas em $BACKUP_DEST_CONFIG"
    fi
}

# Verificar se é root
if [ "$EUID" -ne 0 ]; then
    log_error "Este script deve ser executado como root (use sudo)"
    exit 1
fi

echo "╔════════════════════════════════════════════════════════════╗"
echo "║         CONFIGURAÇÃO AUTOMÁTICA DE TAREFAS AGENDADAS       ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

log "INFO" "Este script irá configurar cron jobs para:"
echo "  • Backup automático do Coolify (configurações)"
echo "  • Backup automático de volumes (dados das aplicações)"
echo "  • Backup automático de bancos de dados"
echo "  • Limpeza automática de backups antigos (GFS ou customizado)"
echo "  • Manutenção preventiva do sistema"
echo "  • Alertas de espaço em disco"
echo "  • Upload automático para destinos remotos (opcional)"
echo "  • Rotação de logs"
echo ""

# Detectar diretório de instalação
INSTALL_ROOT="/opt/vpsguardian"

# Procurar arquivo de configuração
for config in "/opt/vpsguardian/.install.conf" "/opt/vpsguardian-src/.install.conf"; do
    if [ -f "$config" ]; then
        source "$config"
        break
    fi
done

# Verificar se scripts existem
log "INFO" "Verificando scripts necessários..."
ERRORS=0

if [ ! -x "$INSTALL_ROOT/backup/backup-coolify.sh" ]; then
    log_error "Script de backup não encontrado: $INSTALL_ROOT/backup/backup-coolify.sh"
    ((ERRORS++))
fi

if [ ! -x "$INSTALL_ROOT/manutencao/manutencao-completa.sh" ]; then
    log_error "Script de manutenção não encontrado: $INSTALL_ROOT/manutencao/manutencao-completa.sh"
    ((ERRORS++))
fi

if [ ! -x "$INSTALL_ROOT/manutencao/alerta-disco.sh" ]; then
    log_error "Script de alerta não encontrado: $INSTALL_ROOT/manutencao/alerta-disco.sh"
    ((ERRORS++))
fi

if [ $ERRORS -gt 0 ]; then
    log_error "Execute primeiro: sudo ./instalar.sh"
    exit 1
fi

log_success "Todos os scripts encontrados"
echo ""

# Perguntar configurações
log "INFO" "========== CONFIGURAÇÃO PERSONALIZADA =========="
echo ""

# Backup de Bancos de Dados
echo "1️⃣  BACKUP DE BANCOS DE DADOS (PostgreSQL + MySQL)"
echo ""
read -p "$LOG_PREFIX [ INPUT ] Habilitar backup automático de bancos? (Y/n): " ENABLE_DB_BACKUP
ENABLE_DB_BACKUP=${ENABLE_DB_BACKUP:-y}

if [[ "$ENABLE_DB_BACKUP" =~ ^[Yy]$ ]]; then
    read -p "$LOG_PREFIX [ INPUT ] Frequência (daily/weekly, padrão: daily): " DB_BACKUP_FREQ
    DB_BACKUP_FREQ=${DB_BACKUP_FREQ:-daily}

    if [ "$DB_BACKUP_FREQ" = "weekly" ]; then
        read -p "$LOG_PREFIX [ INPUT ] Dia da semana (0-6, 0=Domingo, padrão: 0): " DB_BACKUP_DAY
        DB_BACKUP_DAY=${DB_BACKUP_DAY:-0}
    fi

    read -p "$LOG_PREFIX [ INPUT ] Horário (HH:MM formato 24h, padrão: 01:00): " DB_BACKUP_TIME
    DB_BACKUP_TIME=${DB_BACKUP_TIME:-01:00}

    DB_BACKUP_HOUR=$(echo $DB_BACKUP_TIME | cut -d':' -f1)
    DB_BACKUP_MIN=$(echo $DB_BACKUP_TIME | cut -d':' -f2)
fi

echo ""

# Backup do Coolify
echo "2️⃣  BACKUP DO COOLIFY"
echo ""
read -p "$LOG_PREFIX [ INPUT ] Dia da semana para backup (0-6, 0=Domingo): " BACKUP_DAY
BACKUP_DAY=${BACKUP_DAY:-0}

read -p "$LOG_PREFIX [ INPUT ] Horário do backup (HH:MM formato 24h, padrão: 02:00): " BACKUP_TIME
BACKUP_TIME=${BACKUP_TIME:-02:00}

# Extrair hora e minuto
BACKUP_HOUR=$(echo $BACKUP_TIME | cut -d':' -f1)
BACKUP_MIN=$(echo $BACKUP_TIME | cut -d':' -f2)

echo ""

# Backup de volumes (dados das aplicações)
echo "3️⃣  BACKUP DE VOLUMES DAS APLICAÇÕES (DADOS)"
echo ""
echo "⚠️  IMPORTANTE: O backup do Coolify (anterior) salva apenas CONFIGURAÇÕES."
echo "    Para backup completo dos DADOS das aplicações (bancos, arquivos), habilite isto."
echo ""
read -p "$LOG_PREFIX [ INPUT ] Habilitar backup de volumes (dados das aplicações)? (Y/n): " ENABLE_VOLUMES_BACKUP
ENABLE_VOLUMES_BACKUP=${ENABLE_VOLUMES_BACKUP:-y}

VOLUMES_BACKUP_FREQ=""
VOLUMES_BACKUP_DAY=""
VOLUMES_BACKUP_TIME=""
VOLUMES_BACKUP_HOUR=""
VOLUMES_BACKUP_MIN=""

if [[ "$ENABLE_VOLUMES_BACKUP" =~ ^[Yy]$ ]]; then
    read -p "$LOG_PREFIX [ INPUT ] Frequência (daily/weekly, padrão: weekly): " VOLUMES_BACKUP_FREQ
    VOLUMES_BACKUP_FREQ=${VOLUMES_BACKUP_FREQ:-weekly}

    if [ "$VOLUMES_BACKUP_FREQ" = "weekly" ]; then
        read -p "$LOG_PREFIX [ INPUT ] Dia da semana (0-6, 0=Domingo, padrão: 0): " VOLUMES_BACKUP_DAY
        VOLUMES_BACKUP_DAY=${VOLUMES_BACKUP_DAY:-0}
    fi

    read -p "$LOG_PREFIX [ INPUT ] Horário (HH:MM formato 24h, padrão: 01:00): " VOLUMES_BACKUP_TIME
    VOLUMES_BACKUP_TIME=${VOLUMES_BACKUP_TIME:-01:00}

    VOLUMES_BACKUP_HOUR=$(echo $VOLUMES_BACKUP_TIME | cut -d':' -f1)
    VOLUMES_BACKUP_MIN=$(echo $VOLUMES_BACKUP_TIME | cut -d':' -f2)

    log "INFO" "Backup de volumes será executado ANTES do backup do Coolify"
fi

echo ""

# Manutenção preventiva
echo "4️⃣  MANUTENÇÃO PREVENTIVA"
echo ""
read -p "$LOG_PREFIX [ INPUT ] Dia da semana para manutenção (0-6, 1=Segunda): " MANUTENCAO_DAY
MANUTENCAO_DAY=${MANUTENCAO_DAY:-1}

read -p "$LOG_PREFIX [ INPUT ] Horário da manutenção (HH:MM formato 24h, padrão: 03:00): " MANUTENCAO_TIME
MANUTENCAO_TIME=${MANUTENCAO_TIME:-03:00}

MANUTENCAO_HOUR=$(echo $MANUTENCAO_TIME | cut -d':' -f1)
MANUTENCAO_MIN=$(echo $MANUTENCAO_TIME | cut -d':' -f2)

echo ""

# Alerta de disco
echo "5️⃣  ALERTA DE ESPAÇO EM DISCO"
echo ""
read -p "$LOG_PREFIX [ INPUT ] Horário do alerta diário (HH:MM formato 24h, padrão: 09:00): " ALERTA_TIME
ALERTA_TIME=${ALERTA_TIME:-09:00}

ALERTA_HOUR=$(echo $ALERTA_TIME | cut -d':' -f1)
ALERTA_MIN=$(echo $ALERTA_TIME | cut -d':' -f2)

echo ""

# Upload automático de backups
echo "6️⃣  UPLOAD AUTOMÁTICO DE BACKUPS (OPCIONAL)"
echo ""
read -p "$LOG_PREFIX [ INPUT ] Enviar backups para destino remoto automaticamente? (y/N): " AUTO_UPLOAD
AUTO_UPLOAD=${AUTO_UPLOAD:-n}

UPLOAD_DEST=""
if [[ "$AUTO_UPLOAD" =~ ^[Yy]$ ]]; then
    echo ""
    echo "Destinos disponíveis:"
    echo "  [1] Self-hosted (SSH)"
    echo "  [2] Google Drive (rclone)"
    echo "  [3] AWS S3"
    echo "  [4] Todos os destinos"
    echo ""
    read -p "$LOG_PREFIX [ INPUT ] Escolha o destino (1-4): " UPLOAD_CHOICE

    case $UPLOAD_CHOICE in
        1) UPLOAD_DEST="self-hosted" ;;
        2) UPLOAD_DEST="google-drive" ;;
        3) UPLOAD_DEST="aws-s3" ;;
        4) UPLOAD_DEST="all" ;;
        *)
            log "WARN" "Opção inválida. Upload automático desabilitado."
            AUTO_UPLOAD="n"
            ;;
    esac

    if [[ "$AUTO_UPLOAD" =~ ^[Yy]$ ]]; then
        echo ""
        read -p "$LOG_PREFIX [ INPUT ] Quantas horas após o backup fazer upload? (padrão: 1): " UPLOAD_DELAY
        UPLOAD_DELAY=${UPLOAD_DELAY:-1}
    fi
fi

echo ""

# Retenção de backups
echo "7️⃣  RETENÇÃO DE BACKUPS (LIMPEZA AUTOMÁTICA)"
echo ""
read -p "$LOG_PREFIX [ INPUT ] Habilitar limpeza automática de backups antigos? (Y/n): " ENABLE_CLEANUP
ENABLE_CLEANUP=${ENABLE_CLEANUP:-y}

CLEANUP_STRATEGY=""
CLEANUP_DAYS=""
CLEANUP_COUNT=""

if [[ "$ENABLE_CLEANUP" =~ ^[Yy]$ ]]; then
    echo ""
    echo "Estratégias de retenção disponíveis:"
    echo "  [1] GFS (Grandfather-Father-Son) - Recomendado ⭐"
    echo "      • 7 diários (todos dos últimos 7 dias)"
    echo "      • 4 semanais (1 por semana - domingo)"
    echo "      • 12 mensais (1 por mês - dia 1)"
    echo ""
    echo "  [2] Simple (Por idade)"
    echo "      • Deleta backups mais antigos que X dias"
    echo ""
    echo "  [3] Count (Por quantidade)"
    echo "      • Mantém últimos X backups"
    echo ""
    read -p "$LOG_PREFIX [ INPUT ] Escolha a estratégia (1-3, padrão: 1): " CLEANUP_CHOICE
    CLEANUP_CHOICE=${CLEANUP_CHOICE:-1}

    case $CLEANUP_CHOICE in
        1)
            CLEANUP_STRATEGY="gfs"
            ;;
        2)
            CLEANUP_STRATEGY="simple"
            echo ""
            read -p "$LOG_PREFIX [ INPUT ] Deletar backups mais antigos que quantos dias? (padrão: 30): " CLEANUP_DAYS
            CLEANUP_DAYS=${CLEANUP_DAYS:-30}
            ;;
        3)
            CLEANUP_STRATEGY="count"
            echo ""
            read -p "$LOG_PREFIX [ INPUT ] Manter quantos backups? (padrão: 10): " CLEANUP_COUNT
            CLEANUP_COUNT=${CLEANUP_COUNT:-10}
            ;;
        *)
            log "WARN" "Opção inválida. Usando GFS (padrão)."
            CLEANUP_STRATEGY="gfs"
            ;;
    esac

    echo ""
    read -p "$LOG_PREFIX [ INPUT ] Dia da semana para limpeza (0-6, 0=Domingo, padrão: 0): " CLEANUP_DAY
    CLEANUP_DAY=${CLEANUP_DAY:-0}

    # Calcular horário da limpeza (2h após o backup)
    CLEANUP_HOUR=$((BACKUP_HOUR + 2))
    if [ $CLEANUP_HOUR -ge 24 ]; then
        CLEANUP_HOUR=$((CLEANUP_HOUR - 24))
        CLEANUP_DAY=$((BACKUP_DAY + 1))
        if [ $CLEANUP_DAY -gt 6 ]; then
            CLEANUP_DAY=0
        fi
    fi

    CLEANUP_MIN=$BACKUP_MIN

    log "INFO" "Limpeza será executada 2h após o backup ($(printf "%02d:%02d" $((10#$CLEANUP_HOUR)) $((10#$CLEANUP_MIN))))"

    # Salvar configurações de retenção no arquivo de config
    save_retention_config "$CLEANUP_STRATEGY" "${CLEANUP_DAYS:-30}" "${CLEANUP_COUNT:-10}"
fi

echo ""

# Resumo das configurações
log "INFO" "========== RESUMO DAS CONFIGURAÇÕES =========="
echo ""

if [ "$ENABLE_DB_BACKUP" = "y" ]; then
    echo "🗄️  Backup de Bancos de Dados:"
    if [ "$DB_BACKUP_FREQ" = "daily" ]; then
        echo "   • Frequência: Diário"
    else
        echo "   • Frequência: Semanal ($(case $DB_BACKUP_DAY in 0) echo 'Domingo';; 1) echo 'Segunda';; 2) echo 'Terça';; 3) echo 'Quarta';; 4) echo 'Quinta';; 5) echo 'Sexta';; 6) echo 'Sábado';; esac))"
    fi
    echo "   • Horário: $DB_BACKUP_TIME"
    echo ""
fi

echo "📅 Backup do Coolify (Configurações):"
echo "   • Dia: $(case $BACKUP_DAY in 0) echo 'Domingo';; 1) echo 'Segunda';; 2) echo 'Terça';; 3) echo 'Quarta';; 4) echo 'Quinta';; 5) echo 'Sexta';; 6) echo 'Sábado';; esac)"
echo "   • Horário: $BACKUP_TIME"
echo ""

if [[ "$ENABLE_VOLUMES_BACKUP" =~ ^[Yy]$ ]]; then
    echo "📦 Backup de Volumes (Dados das Aplicações):"
    if [ "$VOLUMES_BACKUP_FREQ" = "daily" ]; then
        echo "   • Frequência: Diário"
    else
        echo "   • Frequência: Semanal ($(case $VOLUMES_BACKUP_DAY in 0) echo 'Domingo';; 1) echo 'Segunda';; 2) echo 'Terça';; 3) echo 'Quarta';; 4) echo 'Quinta';; 5) echo 'Sexta';; 6) echo 'Sábado';; esac))"
    fi
    echo "   • Horário: $VOLUMES_BACKUP_TIME (antes do backup do Coolify)"
    echo "   • Estratégia: Double-Check (SQL Dump + Volume Snapshot)"
    echo ""
fi

echo "🔧 Manutenção Preventiva:"
echo "   • Dia: $(case $MANUTENCAO_DAY in 0) echo 'Domingo';; 1) echo 'Segunda';; 2) echo 'Terça';; 3) echo 'Quarta';; 4) echo 'Quinta';; 5) echo 'Sexta';; 6) echo 'Sábado';; esac)"
echo "   • Horário: $MANUTENCAO_TIME"
echo ""
echo "💾 Alerta de Disco:"
echo "   • Frequência: Diário"
echo "   • Horário: $ALERTA_TIME"
echo ""
echo "📦 Rotação de Logs:"
echo "   • Frequência: Mensalmente (dia 1 às 04:00)"
echo ""

if [[ "$AUTO_UPLOAD" =~ ^[Yy]$ ]]; then
    echo "☁️  Upload Automático:"
    echo "   • Destino: $UPLOAD_DEST"
    echo "   • Delay: $UPLOAD_DELAY hora(s) após o backup"
    echo ""
fi

if [[ "$ENABLE_CLEANUP" =~ ^[Yy]$ ]]; then
    echo "🗑️  Limpeza de Backups:"
    case "$CLEANUP_STRATEGY" in
        gfs)
            echo "   • Estratégia: GFS (7 diários + 4 semanais + 12 mensais)"
            ;;
        simple)
            echo "   • Estratégia: Simple (deletar backups >$CLEANUP_DAYS dias)"
            ;;
        count)
            echo "   • Estratégia: Count (manter últimos $CLEANUP_COUNT backups)"
            ;;
    esac
    echo "   • Dia: $(case $CLEANUP_DAY in 0) echo 'Domingo';; 1) echo 'Segunda';; 2) echo 'Terça';; 3) echo 'Quarta';; 4) echo 'Quinta';; 5) echo 'Sexta';; 6) echo 'Sábado';; esac)"
    echo "   • Horário: $(printf "%02d:%02d" $((10#$CLEANUP_HOUR)) $((10#$CLEANUP_MIN)))"
    echo ""
fi

read -p "$LOG_PREFIX [ INPUT ] Confirmar configuração? (Y/n): " CONFIRM
CONFIRM=${CONFIRM:-y}

if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    log "INFO" "Configuração cancelada"
    exit 0
fi

echo ""

# Backup do crontab atual
log "INFO" "========== BACKUP DO CRONTAB ATUAL =========="
echo ""

CRONTAB_BACKUP="/root/crontab.backup.$(date +%Y%m%d_%H%M%S)"
crontab -l > "$CRONTAB_BACKUP" 2>/dev/null || touch "$CRONTAB_BACKUP"

log_success "Backup criado: $CRONTAB_BACKUP"
echo ""

# Criar arquivo temporário com novos cron jobs
log "INFO" "========== CONFIGURANDO CRON JOBS =========="
echo ""

TEMP_CRON=$(mktemp)

# Adicionar crontab existente (removendo entradas antigas do sistema)
crontab -l 2>/dev/null | grep -v "vpsguardian.*backup-coolify.sh" | \
    grep -v "vpsguardian.*backup-databases" | \
    grep -v "vpsguardian.*manutencao-completa.sh" | \
    grep -v "vpsguardian.*alerta-disco.sh" | \
    grep -v "vpsguardian.*backup-destinos.sh" | \
    grep -v "vpsguardian.*limpar-backups-antigos.sh" | \
    grep -v "vpsguardian.*backup-database-volumes.sh" | \
    grep -v "logrotate" > "$TEMP_CRON" || true

# Adicionar cabeçalho
cat >> "$TEMP_CRON" << 'EOF'

################################################################################
# Sistema de Manutenção e Backup VPS - Configurado automaticamente
# Gerado em: $(date +"%Y-%m-%d %H:%M:%S")
################################################################################

# Configurações de ambiente
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
MAILTO=""

EOF

# Adicionar backup de bancos de dados se habilitado
if [[ "$ENABLE_DB_BACKUP" =~ ^[Yy]$ ]]; then
    # Determinar destino do backup (usa o mesmo destino do upload automático se configurado)
    if [[ "$AUTO_UPLOAD" =~ ^[Yy]$ ]] && [ -n "$UPLOAD_DEST" ]; then
        DB_BACKUP_DEST="$UPLOAD_DEST"
    else
        DB_BACKUP_DEST="local"
    fi

    if [ "$DB_BACKUP_FREQ" = "daily" ]; then
        cat >> "$TEMP_CRON" << EOF
# Backup automático de bancos de dados (diário às $DB_BACKUP_TIME) → destino: $DB_BACKUP_DEST
$DB_BACKUP_MIN $DB_BACKUP_HOUR * * * $INSTALL_ROOT/backup/backup-databases-dump-auto.sh --dest=$DB_BACKUP_DEST >> /var/log/vpsguardian/cron-db-backup.log 2>&1

EOF
    else
        cat >> "$TEMP_CRON" << EOF
# Backup automático de bancos de dados (semanal ${DB_BACKUP_DAY}=Dia da semana, $DB_BACKUP_TIME) → destino: $DB_BACKUP_DEST
$DB_BACKUP_MIN $DB_BACKUP_HOUR * * $DB_BACKUP_DAY $INSTALL_ROOT/backup/backup-databases-dump-auto.sh --dest=$DB_BACKUP_DEST >> /var/log/vpsguardian/cron-db-backup.log 2>&1

EOF
    fi
fi

# Adicionar backup de volumes se habilitado
if [[ "$ENABLE_VOLUMES_BACKUP" =~ ^[Yy]$ ]]; then
    if [ "$VOLUMES_BACKUP_FREQ" = "daily" ]; then
        cat >> "$TEMP_CRON" << EOF
# Backup de volumes das aplicações (diário às $VOLUMES_BACKUP_TIME)
$VOLUMES_BACKUP_MIN $VOLUMES_BACKUP_HOUR * * * BACKUP_OUTPUT_DIR=/var/backups/vpsguardian/volumes $INSTALL_ROOT/migrar/backup-database-volumes.sh >> /var/log/vpsguardian/cron-volumes-backup.log 2>&1

EOF
    else
        cat >> "$TEMP_CRON" << EOF
# Backup de volumes das aplicações (semanal ${VOLUMES_BACKUP_DAY}=Dia da semana, $VOLUMES_BACKUP_TIME)
$VOLUMES_BACKUP_MIN $VOLUMES_BACKUP_HOUR * * $VOLUMES_BACKUP_DAY BACKUP_OUTPUT_DIR=/var/backups/vpsguardian/volumes $INSTALL_ROOT/migrar/backup-database-volumes.sh >> /var/log/vpsguardian/cron-volumes-backup.log 2>&1

EOF
    fi
fi

# Adicionar backup do Coolify
cat >> "$TEMP_CRON" << EOF
# Backup completo do Coolify - Configurações (${BACKUP_DAY}=Dia da semana, $BACKUP_TIME)
$BACKUP_MIN $BACKUP_HOUR * * $BACKUP_DAY $INSTALL_ROOT/backup/backup-coolify.sh >> /var/log/vpsguardian/cron-backup.log 2>&1

EOF

# Adicionar upload automático se configurado
if [[ "$AUTO_UPLOAD" =~ ^[Yy]$ ]]; then
    # Calcular horário do upload (backup_time + delay)
    UPLOAD_HOUR=$((BACKUP_HOUR + UPLOAD_DELAY))

    # Ajustar se passar de 24h
    if [ $UPLOAD_HOUR -ge 24 ]; then
        UPLOAD_HOUR=$((UPLOAD_HOUR - 24))
        UPLOAD_DAY=$((BACKUP_DAY + 1))
        if [ $UPLOAD_DAY -gt 6 ]; then
            UPLOAD_DAY=0
        fi
    else
        UPLOAD_DAY=$BACKUP_DAY
    fi

    cat >> "$TEMP_CRON" << EOF
# Upload automático de backups para $UPLOAD_DEST ($UPLOAD_DELAY hora(s) após o backup)
$BACKUP_MIN $UPLOAD_HOUR * * $UPLOAD_DAY find /var/backups/vpsguardian/coolify -name "*.tar.gz" -mmin -120 -exec $INSTALL_ROOT/backup/backup-destinos.sh {} --dest=$UPLOAD_DEST \; >> /var/log/vpsguardian/cron-upload.log 2>&1

EOF
fi

# Adicionar manutenção preventiva
cat >> "$TEMP_CRON" << EOF
# Manutenção preventiva semanal (${MANUTENCAO_DAY}=Dia da semana, $MANUTENCAO_TIME)
$MANUTENCAO_MIN $MANUTENCAO_HOUR * * $MANUTENCAO_DAY $INSTALL_ROOT/manutencao/manutencao-completa.sh >> /var/log/vpsguardian/cron-manutencao.log 2>&1

EOF

# Adicionar alerta de disco
cat >> "$TEMP_CRON" << EOF
# Alerta de espaço em disco (diário às $ALERTA_TIME)
$ALERTA_MIN $ALERTA_HOUR * * * $INSTALL_ROOT/manutencao/alerta-disco.sh >> /var/log/vpsguardian/cron-alerta.log 2>&1

EOF

# Adicionar limpeza de backups se habilitado
if [[ "$ENABLE_CLEANUP" =~ ^[Yy]$ ]]; then
    # Construir argumentos do comando
    CLEANUP_ARGS="--strategy=$CLEANUP_STRATEGY --auto"

    case "$CLEANUP_STRATEGY" in
        simple)
            CLEANUP_ARGS="$CLEANUP_ARGS --days=$CLEANUP_DAYS"
            ;;
        count)
            CLEANUP_ARGS="$CLEANUP_ARGS --count=$CLEANUP_COUNT"
            ;;
    esac

    # Diretórios a limpar
    COOLIFY_BACKUP_DIR="/var/backups/vpsguardian/coolify"
    VOLUMES_BACKUP_DIR="/var/backups/vpsguardian/volumes"
    DATABASES_BACKUP_DIR="/var/backups/vpsguardian/databases"

    # Formatação de horário (evita erro de octal com 08, 09)
    CLEANUP_TIME_FMT=$(printf "%02d:%02d" $((10#$CLEANUP_HOUR)) $((10#$CLEANUP_MIN)))

    cat >> "$TEMP_CRON" << EOF
# Limpeza automática de backups do Coolify (${CLEANUP_DAY}=Dia da semana, $CLEANUP_TIME_FMT)
$CLEANUP_MIN $CLEANUP_HOUR * * $CLEANUP_DAY $INSTALL_ROOT/scripts-auxiliares/limpar-backups-antigos.sh --dir=$COOLIFY_BACKUP_DIR $CLEANUP_ARGS >> /var/log/vpsguardian/cron-cleanup-coolify.log 2>&1

EOF

    # Adicionar limpeza de databases se backup de databases estiver habilitado
    if [[ "$ENABLE_DB_BACKUP" =~ ^[Yy]$ ]]; then
        cat >> "$TEMP_CRON" << EOF
# Limpeza automática de backups de databases (${CLEANUP_DAY}=Dia da semana, $CLEANUP_TIME_FMT)
$CLEANUP_MIN $CLEANUP_HOUR * * $CLEANUP_DAY $INSTALL_ROOT/scripts-auxiliares/limpar-backups-antigos.sh --dir=$DATABASES_BACKUP_DIR $CLEANUP_ARGS >> /var/log/vpsguardian/cron-cleanup-databases.log 2>&1

EOF
    fi

    # Adicionar limpeza de volumes se backup de volumes estiver habilitado
    if [[ "$ENABLE_VOLUMES_BACKUP" =~ ^[Yy]$ ]]; then
        cat >> "$TEMP_CRON" << EOF
# Limpeza automática de backups de volumes (${CLEANUP_DAY}=Dia da semana, $CLEANUP_TIME_FMT)
$CLEANUP_MIN $CLEANUP_HOUR * * $CLEANUP_DAY $INSTALL_ROOT/scripts-auxiliares/limpar-backups-antigos.sh --dir=$VOLUMES_BACKUP_DIR $CLEANUP_ARGS >> /var/log/vpsguardian/cron-cleanup-volumes.log 2>&1

EOF
    fi
fi

# Adicionar rotação de logs
cat >> "$TEMP_CRON" << 'EOF'
# Rotação de logs (mensalmente, dia 1 às 04:00)
0 4 1 * * /usr/sbin/logrotate /etc/logrotate.conf >> /var/log/vpsguardian/cron-logrotate.log 2>&1

EOF

# Instalar novo crontab
crontab "$TEMP_CRON"
rm "$TEMP_CRON"

log_success "Cron jobs configurados com sucesso"
echo ""

# Criar diretórios de logs se não existirem
mkdir -p /var/log/vpsguardian

# Verificar instalação
log "INFO" "========== VERIFICANDO CONFIGURAÇÃO =========="
echo ""

log "INFO" "Cron jobs instalados:"
crontab -l | grep -E "(backup-coolify|backup-databases|backup-database-volumes|manutencao-completa|alerta-disco|backup-destinos|limpar-backups-antigos|logrotate)" | while read -r line; do
    echo "  ✓ $(echo "$line" | sed 's|/opt/vpsguardian/[^ ]*/||g')"
done

echo ""

# Mostrar próximas execuções
log "INFO" "========== PRÓXIMAS EXECUÇÕES =========="
echo ""

# Função para calcular próxima execução
get_next_execution() {
    local min=$1
    local hour=$2
    local day=$3
    local current_day=$(date +%u)

    # Converter domingo de 0 para 7
    if [ "$day" -eq 0 ]; then
        day=7
    fi

    # Calcular dias até próxima execução
    local days_until=$((day - current_day))
    if [ $days_until -lt 0 ]; then
        days_until=$((days_until + 7))
    elif [ $days_until -eq 0 ]; then
        # Se é hoje, verificar se já passou o horário
        local current_time=$(date +%H%M)
        local exec_time=$(printf "%02d%02d" $hour $min)
        if [ $current_time -gt $exec_time ]; then
            days_until=7
        fi
    fi

    if [ $days_until -eq 0 ]; then
        echo "Hoje às $(printf "%02d:%02d" $hour $min)"
    else
        date -d "+$days_until days" "+%d/%m/%Y às $(printf "%02d:%02d" $hour $min)"
    fi
}

echo "📅 Backup do Coolify (Configurações):"
echo "   $(get_next_execution $BACKUP_MIN $BACKUP_HOUR $BACKUP_DAY)"
echo ""

if [[ "$ENABLE_VOLUMES_BACKUP" =~ ^[Yy]$ ]]; then
    echo "📦 Backup de Volumes (Dados das Aplicações):"
    if [ "$VOLUMES_BACKUP_FREQ" = "daily" ]; then
        # Para diário, calcular próxima execução
        TOMORROW=$(date -d "tomorrow" +%d/%m/%Y)
        if [ $(date +%H) -lt $VOLUMES_BACKUP_HOUR ]; then
            echo "   Hoje às $(printf "%02d:%02d" $((10#$VOLUMES_BACKUP_HOUR)) $((10#$VOLUMES_BACKUP_MIN)))"
        else
            echo "   $TOMORROW às $(printf "%02d:%02d" $((10#$VOLUMES_BACKUP_HOUR)) $((10#$VOLUMES_BACKUP_MIN)))"
        fi
    else
        echo "   $(get_next_execution $VOLUMES_BACKUP_MIN $VOLUMES_BACKUP_HOUR $VOLUMES_BACKUP_DAY)"
    fi
    echo ""
fi

echo "🔧 Manutenção Preventiva:"
echo "   $(get_next_execution $MANUTENCAO_MIN $MANUTENCAO_HOUR $MANUTENCAO_DAY)"
echo ""

echo "💾 Alerta de Disco:"
TOMORROW=$(date -d "tomorrow" +%d/%m/%Y)
if [ $(date +%H) -lt $ALERTA_HOUR ]; then
    echo "   Hoje às $(printf "%02d:%02d" $((10#$ALERTA_HOUR)) $((10#$ALERTA_MIN)))"
else
    echo "   $TOMORROW às $(printf "%02d:%02d" $((10#$ALERTA_HOUR)) $((10#$ALERTA_MIN)))"
fi
echo ""

echo "📦 Rotação de Logs:"
NEXT_MONTH=$(date -d "$(date +%Y-%m-01) +1 month" +%d/%m/%Y)
echo "   $NEXT_MONTH às 04:00"
echo ""

if [[ "$AUTO_UPLOAD" =~ ^[Yy]$ ]]; then
    echo "☁️  Upload Automático:"
    echo "   $(get_next_execution $BACKUP_MIN $UPLOAD_HOUR $UPLOAD_DAY)"
    echo ""
fi

if [[ "$ENABLE_CLEANUP" =~ ^[Yy]$ ]]; then
    echo "🗑️  Limpeza de Backups:"
    echo "   $(get_next_execution $CLEANUP_MIN $CLEANUP_HOUR $CLEANUP_DAY)"
    case "$CLEANUP_STRATEGY" in
        gfs)
            echo "   (Estratégia GFS: 7 diários + 4 semanais + 12 mensais)"
            ;;
        simple)
            echo "   (Deletar backups >$CLEANUP_DAYS dias)"
            ;;
        count)
            echo "   (Manter últimos $CLEANUP_COUNT backups)"
            ;;
    esac
    echo ""
fi

# Informações adicionais
log "INFO" "========== COMANDOS ÚTEIS =========="
echo ""
echo "  # Ver cron jobs configurados"
echo "  sudo crontab -l"
echo ""
echo "  # Editar manualmente"
echo "  sudo crontab -e"
echo ""
echo "  # Ver logs de execução"
echo "  tail -f /var/log/vpsguardian/cron-backup.log"
if [[ "$ENABLE_DB_BACKUP" =~ ^[Yy]$ ]]; then
    echo "  tail -f /var/log/vpsguardian/cron-db-backup.log"
fi
if [[ "$ENABLE_VOLUMES_BACKUP" =~ ^[Yy]$ ]]; then
    echo "  tail -f /var/log/vpsguardian/cron-volumes-backup.log"
fi
echo "  tail -f /var/log/vpsguardian/cron-manutencao.log"
echo "  tail -f /var/log/vpsguardian/cron-alerta.log"
if [[ "$ENABLE_CLEANUP" =~ ^[Yy]$ ]]; then
    echo "  tail -f /var/log/vpsguardian/cron-cleanup-coolify.log"
    if [[ "$ENABLE_DB_BACKUP" =~ ^[Yy]$ ]]; then
        echo "  tail -f /var/log/vpsguardian/cron-cleanup-databases.log"
    fi
    if [[ "$ENABLE_VOLUMES_BACKUP" =~ ^[Yy]$ ]]; then
        echo "  tail -f /var/log/vpsguardian/cron-cleanup-volumes.log"
    fi
fi
echo ""
echo "  # Verificar próximas execuções (aproximado)"
echo "  grep CRON /var/log/syslog | tail -20"
echo ""
echo "  # Restaurar backup do crontab"
echo "  sudo crontab $CRONTAB_BACKUP"
echo ""

log "SUCCESS" "========== CONFIGURAÇÃO CONCLUÍDA =========="
echo ""
log_success "Tarefas agendadas configuradas automaticamente!"
log "INFO" "Backup do crontab anterior: $CRONTAB_BACKUP"
echo ""

# Testar se cron está rodando
if systemctl is-active --quiet cron || systemctl is-active --quiet crond; then
    log_success "Serviço cron está ativo"
else
    log "WARN" "Serviço cron pode não estar ativo. Execute: sudo systemctl start cron"
fi

echo ""
log "INFO" "Monitore os logs em /var/log/vpsguardian/ para garantir que tudo funciona"
