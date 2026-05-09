#!/bin/bash
################################################################################
# Script: status-backups.sh
# Propósito: Mostrar status completo dos backups automáticos
# Uso: ./status-backups.sh
################################################################################

# Cores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
NC='\033[0m'

# Configurações
CONFIG_FILE="/opt/vpsguardian/config/backup-destinations.conf"
BACKUP_DIR="/var/backups/vpsguardian"

get_s3_retention_strategy() {
    echo "${S3_RETENTION_STRATEGY:-${BACKUP_RETENTION_STRATEGY:-simple}}"
}

get_s3_retention_days() {
    echo "${S3_RETENTION_DAYS:-${BACKUP_RETENTION_DAYS:-30}}"
}

get_s3_retention_count() {
    echo "${S3_RETENTION_COUNT:-${BACKUP_RETENTION_COUNT:-10}}"
}

echo ""
echo -e "${CYAN}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║              STATUS DOS BACKUPS AUTOMÁTICOS                    ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════════════════════════════╝${NC}"
echo ""

################################################################################
# 1. DESTINOS CONFIGURADOS
################################################################################

echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}1️⃣  DESTINOS DE BACKUP CONFIGURADOS${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"

    # Local
    if [ "$BACKUP_DEST_LOCAL" = "true" ]; then
        echo -e "  ${GREEN}✅${NC} Local"
        echo -e "     ${GRAY}Retenção: ${LOCAL_BACKUP_RETENTION_DAYS:-30} dias${NC}"
    else
        echo -e "  ${RED}❌${NC} Local"
    fi

    # SSH
    if [ "$BACKUP_DEST_SSH" = "true" ]; then
        echo -e "  ${GREEN}✅${NC} SSH → ${SSH_REMOTE_USER}@${SSH_REMOTE_SERVER}:${SSH_REMOTE_DIR}"
    else
        echo -e "  ${RED}❌${NC} SSH"
    fi

    # Google Drive
    if [ "$BACKUP_DEST_GOOGLE_DRIVE" = "true" ]; then
        echo -e "  ${GREEN}✅${NC} Google Drive → ${GDRIVE_REMOTE_NAME}:${GDRIVE_DIR}"
    else
        echo -e "  ${RED}❌${NC} Google Drive"
    fi

    # AWS S3 / R2
    if [ "$BACKUP_DEST_AWS_S3" = "true" ]; then
        if [ -n "$S3_ENDPOINT" ]; then
            echo -e "  ${GREEN}✅${NC} S3-Compatible → s3://${S3_BUCKET}/${S3_PREFIX}"
            echo -e "     ${GRAY}Endpoint: ${S3_ENDPOINT}${NC}"
        else
            echo -e "  ${GREEN}✅${NC} AWS S3 → s3://${S3_BUCKET}/${S3_PREFIX}"
        fi

        if [ "${S3_CLEANUP_ENABLED:-true}" = "true" ]; then
            case "$(get_s3_retention_strategy)" in
                simple) echo -e "     ${GRAY}Limpeza após upload: >$(get_s3_retention_days) dias${NC}" ;;
                count) echo -e "     ${GRAY}Limpeza após upload: manter últimos $(get_s3_retention_count)${NC}" ;;
                gfs) echo -e "     ${GRAY}Limpeza após upload: GFS (7d+4w+12m)${NC}" ;;
            esac
        else
            echo -e "     ${YELLOW}Limpeza após upload: desabilitada${NC}"
        fi
    else
        echo -e "  ${RED}❌${NC} AWS S3"
    fi

    echo ""

    # Opções
    echo -e "  ${BLUE}Opções:${NC}"
    if [ "$BACKUP_INCLUDE_COOLIFY" = "true" ]; then
        echo -e "    ${GREEN}✅${NC} Incluir coolify-db nos backups"
    else
        echo -e "    ${YELLOW}⚠️${NC}  coolify-db EXCLUÍDO dos backups"
    fi

    if [ "$REMOVE_LOCAL_AFTER_UPLOAD" = "true" ]; then
        echo -e "    🗑️  Remover backup local após upload"
    else
        echo -e "    💾 Manter backup local após upload"
    fi

    if [ -n "$WEBHOOK_URL" ]; then
        echo -e "    🔔 Webhook configurado"
    fi

    if [ -n "$NOTIFICATION_EMAIL" ]; then
        echo -e "    📧 Email: $NOTIFICATION_EMAIL"
    fi
else
    echo -e "  ${RED}⚠️  Nenhuma configuração encontrada!${NC}"
    echo -e "  ${GRAY}Execute: Menu → 2 → 11 (Configurar Destinos de Backup)${NC}"
fi

echo ""

################################################################################
# 2. CRON JOBS CONFIGURADOS
################################################################################

echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}2️⃣  TAREFAS AGENDADAS (CRON)${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

CRON_BACKUP_COOLIFY=$(crontab -l 2>/dev/null | grep -c "backup-coolify.sh")
CRON_BACKUP_DATABASES=$(crontab -l 2>/dev/null | grep -c "backup-databases")
CRON_BACKUP_VOLUMES=$(crontab -l 2>/dev/null | grep -c "backup-database-volumes.sh")
CRON_MANUTENCAO=$(crontab -l 2>/dev/null | grep -c "manutencao-completa.sh")
CRON_ALERTA=$(crontab -l 2>/dev/null | grep -c "alerta-disco.sh")
CRON_LIMPEZA=$(crontab -l 2>/dev/null | grep -c "limpar-backups")

# Backup Coolify
if [ "$CRON_BACKUP_COOLIFY" -gt 0 ]; then
    HORARIO=$(crontab -l 2>/dev/null | grep "backup-coolify.sh" | awk '{print $2":"$1}' | head -1)
    DIA=$(crontab -l 2>/dev/null | grep "backup-coolify.sh" | awk '{print $5}' | head -1)
    DIA_NOME=$(case $DIA in 0) echo "Domingo";; 1) echo "Segunda";; 2) echo "Terça";; 3) echo "Quarta";; 4) echo "Quinta";; 5) echo "Sexta";; 6) echo "Sábado";; *) echo "Diário";; esac)
    echo -e "  ${GREEN}✅${NC} Backup Coolify (SSH keys, .env, configs)"
    echo -e "     ${GRAY}Quando: $DIA_NOME às $HORARIO${NC}"
else
    echo -e "  ${RED}❌${NC} Backup Coolify ${YELLOW}(NÃO CONFIGURADO!)${NC}"
    echo -e "     ${GRAY}⚠️  SSH keys, .env e configs NÃO estão sendo salvos!${NC}"
fi

# Backup Databases
if [ "$CRON_BACKUP_DATABASES" -gt 0 ]; then
    HORARIO=$(crontab -l 2>/dev/null | grep "backup-databases" | awk '{print $2":"$1}' | head -1)
    DIA=$(crontab -l 2>/dev/null | grep "backup-databases" | awk '{print $5}' | head -1)
    if [ "$DIA" = "*" ]; then
        DIA_NOME="Diário"
    else
        DIA_NOME=$(case $DIA in 0) echo "Domingo";; 1) echo "Segunda";; 2) echo "Terça";; 3) echo "Quarta";; 4) echo "Quinta";; 5) echo "Sexta";; 6) echo "Sábado";; esac)
    fi
    echo -e "  ${GREEN}✅${NC} Backup de Bancos de Dados (Dumps SQL)"
    echo -e "     ${GRAY}Quando: $DIA_NOME às $HORARIO${NC}"
else
    echo -e "  ${RED}❌${NC} Backup de Bancos de Dados"
fi

# Backup Volumes
if [ "$CRON_BACKUP_VOLUMES" -gt 0 ]; then
    HORARIO=$(crontab -l 2>/dev/null | grep "backup-database-volumes.sh" | awk '{print $2":"$1}' | head -1)
    DIA=$(crontab -l 2>/dev/null | grep "backup-database-volumes.sh" | awk '{print $5}' | head -1)
    DIA_NOME=$(case $DIA in 0) echo "Domingo";; 1) echo "Segunda";; 2) echo "Terça";; 3) echo "Quarta";; 4) echo "Quinta";; 5) echo "Sexta";; 6) echo "Sábado";; *) echo "Diário";; esac)
    echo -e "  ${GREEN}✅${NC} Backup de Volumes"
    echo -e "     ${GRAY}Quando: $DIA_NOME às $HORARIO${NC}"
else
    echo -e "  ${GRAY}➖${NC} Backup de Volumes (opcional)"
fi

# Manutenção
if [ "$CRON_MANUTENCAO" -gt 0 ]; then
    HORARIO=$(crontab -l 2>/dev/null | grep "manutencao-completa.sh" | awk '{print $2":"$1}' | head -1)
    DIA=$(crontab -l 2>/dev/null | grep "manutencao-completa.sh" | awk '{print $5}' | head -1)
    DIA_NOME=$(case $DIA in 0) echo "Domingo";; 1) echo "Segunda";; 2) echo "Terça";; 3) echo "Quarta";; 4) echo "Quinta";; 5) echo "Sexta";; 6) echo "Sábado";; esac)
    echo -e "  ${GREEN}✅${NC} Manutenção Preventiva"
    echo -e "     ${GRAY}Quando: $DIA_NOME às $HORARIO${NC}"
else
    echo -e "  ${GRAY}➖${NC} Manutenção Preventiva"
fi

# Alerta de Disco
if [ "$CRON_ALERTA" -gt 0 ]; then
    HORARIO=$(crontab -l 2>/dev/null | grep "alerta-disco.sh" | awk '{print $2":"$1}' | head -1)
    echo -e "  ${GREEN}✅${NC} Alerta de Disco"
    echo -e "     ${GRAY}Quando: Diário às $HORARIO${NC}"
else
    echo -e "  ${GRAY}➖${NC} Alerta de Disco"
fi

# Limpeza
if [ "$CRON_LIMPEZA" -gt 0 ]; then
    echo -e "  ${GREEN}✅${NC} Limpeza de Backups Antigos"
else
    echo -e "  ${GRAY}➖${NC} Limpeza de Backups Antigos"
fi

echo ""

# Alerta se backup do Coolify não está configurado
if [ "$CRON_BACKUP_COOLIFY" -eq 0 ]; then
    echo -e "  ${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${RED}⚠️  ATENÇÃO: Backup do Coolify NÃO está configurado!${NC}"
    echo -e "  ${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${YELLOW}Sem este backup, você perderá:${NC}"
    echo -e "    • SSH keys (acesso aos servidores)"
    echo -e "    • .env e APP_KEY (configurações críticas)"
    echo -e "    • Certificados SSL"
    echo ""
    echo -e "  ${GREEN}Para configurar: Menu → 5 → 1 (Configurar Tarefas Agendadas)${NC}"
    echo ""
fi

################################################################################
# 3. ÚLTIMOS BACKUPS CRIADOS
################################################################################

echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}3️⃣  ÚLTIMOS BACKUPS CRIADOS${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Backup Coolify
echo -e "  ${BLUE}Backup Coolify:${NC}"
ULTIMO_COOLIFY=$(ls -t "$BACKUP_DIR/coolify/"*.tar.gz 2>/dev/null | head -1)
if [ -n "$ULTIMO_COOLIFY" ]; then
    NOME=$(basename "$ULTIMO_COOLIFY")
    TAMANHO=$(du -h "$ULTIMO_COOLIFY" | cut -f1)
    DATA=$(stat -c %y "$ULTIMO_COOLIFY" 2>/dev/null | cut -d'.' -f1)
    echo -e "    ${GREEN}✅${NC} $NOME ($TAMANHO)"
    echo -e "       ${GRAY}Criado em: $DATA${NC}"
else
    echo -e "    ${RED}❌${NC} Nenhum backup encontrado"
fi
echo ""

# Backup Databases
echo -e "  ${BLUE}Backup de Bancos de Dados:${NC}"
ULTIMO_LOTE=$(ls -td "$BACKUP_DIR/databases/lote-"*/ 2>/dev/null | head -1 | sed 's:/$::')
if [ -n "$ULTIMO_LOTE" ] && [ -d "$ULTIMO_LOTE" ]; then
    NOME=$(basename "$ULTIMO_LOTE")
    TAMANHO=$(du -sh "$ULTIMO_LOTE" | cut -f1)
    QTD=$(ls -1 "$ULTIMO_LOTE"/*.gz 2>/dev/null | wc -l)
    DATA=$(stat -c %y "$ULTIMO_LOTE" 2>/dev/null | cut -d'.' -f1)
    echo -e "    ${GREEN}✅${NC} $NOME ($TAMANHO - $QTD arquivos)"
    echo -e "       ${GRAY}Criado em: $DATA${NC}"
else
    echo -e "    ${RED}❌${NC} Nenhum backup encontrado"
fi
echo ""

# Backup Volumes
echo -e "  ${BLUE}Backup de Volumes:${NC}"
ULTIMO_VOLUME=$(ls -t "$BACKUP_DIR/volumes/"*.tar.gz 2>/dev/null | head -1)
if [ -n "$ULTIMO_VOLUME" ]; then
    NOME=$(basename "$ULTIMO_VOLUME")
    TAMANHO=$(du -h "$ULTIMO_VOLUME" | cut -f1)
    DATA=$(stat -c %y "$ULTIMO_VOLUME" 2>/dev/null | cut -d'.' -f1)
    echo -e "    ${GREEN}✅${NC} $NOME ($TAMANHO)"
    echo -e "       ${GRAY}Criado em: $DATA${NC}"
else
    echo -e "    ${GRAY}➖${NC} Nenhum backup encontrado"
fi
echo ""

################################################################################
# 4. ESPAÇO EM DISCO
################################################################################

echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}4️⃣  ESPAÇO EM DISCO${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

if [ -d "$BACKUP_DIR" ]; then
    TOTAL_BACKUPS=$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1)
    echo -e "  📁 Total de backups locais: ${GREEN}$TOTAL_BACKUPS${NC}"
    echo ""

    # Detalhamento
    for dir in coolify databases volumes; do
        if [ -d "$BACKUP_DIR/$dir" ]; then
            TAMANHO=$(du -sh "$BACKUP_DIR/$dir" 2>/dev/null | cut -f1)
            echo -e "     • $dir: $TAMANHO"
        fi
    done
else
    echo -e "  ${GRAY}Diretório de backups não encontrado${NC}"
fi

echo ""

# Espaço livre
DISCO_LIVRE=$(df -h / | awk 'NR==2 {print $4}')
DISCO_USADO=$(df -h / | awk 'NR==2 {print $5}')
echo -e "  💾 Espaço livre no disco: ${GREEN}$DISCO_LIVRE${NC} (usado: $DISCO_USADO)"

echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  ${BLUE}Ações disponíveis:${NC}"
echo -e "    • Configurar destinos: Menu → 2 → 11"
echo -e "    • Configurar cron:     Menu → 5 → 1"
echo -e "    • Backup manual:       Menu → 2 → 1 (Coolify) ou 2 → 2 (Bancos)"
echo ""
