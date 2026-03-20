#!/bin/bash
################################################################################
# Script: backup-completo-agora.sh
# Propósito: Executar manualmente as mesmas tarefas que os crons executam
# Uso: ./backup-completo-agora.sh
################################################################################

# Cores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
GRAY='\033[0;90m'
NC='\033[0m'

INSTALL_ROOT="/opt/vpsguardian"

# Carregar configurações de destino
if [ -f "$INSTALL_ROOT/config/backup-destinations.conf" ]; then
    source "$INSTALL_ROOT/config/backup-destinations.conf"
fi

# Detectar o que está configurado nos crons atuais
detect_cron_config() {
    CRON_CONTENT=$(crontab -l 2>/dev/null)

    # Detectar backup de databases
    if echo "$CRON_CONTENT" | grep -q "backup-databases-dump-auto.sh"; then
        CRON_DB_BACKUP="true"
        # Extrair destino
        CRON_DB_DEST=$(echo "$CRON_CONTENT" | grep "backup-databases-dump-auto.sh" | grep -oP '\-\-dest=\K[^ ]+' | head -1)
        [ -z "$CRON_DB_DEST" ] && CRON_DB_DEST="local"
    else
        CRON_DB_BACKUP="false"
    fi

    # Detectar backup de volumes
    if echo "$CRON_CONTENT" | grep -q "backup-database-volumes.sh"; then
        CRON_VOLUMES_BACKUP="true"
    else
        CRON_VOLUMES_BACKUP="false"
    fi

    # Detectar backup do Coolify
    if echo "$CRON_CONTENT" | grep -q "backup-coolify.sh"; then
        CRON_COOLIFY_BACKUP="true"
    else
        CRON_COOLIFY_BACKUP="false"
    fi

    # Detectar upload automático
    if echo "$CRON_CONTENT" | grep -q "backup-destinos.sh"; then
        CRON_AUTO_UPLOAD="true"
        CRON_UPLOAD_DEST=$(echo "$CRON_CONTENT" | grep "backup-destinos.sh" | grep -oP '\-\-dest=\K[^ ]+' | head -1)
    else
        CRON_AUTO_UPLOAD="false"
    fi

    # Detectar manutenção
    if echo "$CRON_CONTENT" | grep -q "manutencao-completa.sh"; then
        CRON_MANUTENCAO="true"
    else
        CRON_MANUTENCAO="false"
    fi

    # Detectar alerta de disco
    if echo "$CRON_CONTENT" | grep -q "alerta-disco.sh"; then
        CRON_ALERTA_DISCO="true"
    else
        CRON_ALERTA_DISCO="false"
    fi
}

clear
echo ""
echo -e "${CYAN}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║       EXECUTAR TAREFAS DO CRON MANUALMENTE                     ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Detectar configuração atual
detect_cron_config

# Verificar webhook
if [ -z "$WEBHOOK_URL" ]; then
    echo -e "${YELLOW}⚠️  Webhook não configurado${NC}"
    echo -e "${GRAY}   Configure em: Menu 2 → 11 (Configurar Destinos)${NC}"
    echo ""
else
    echo -e "${GREEN}✅ Webhook configurado${NC}"
    echo ""
fi

# Mostrar tarefas detectadas nos crons
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}Tarefas configuradas nos crons:${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

[ "$CRON_DB_BACKUP" = "true" ] && echo -e "  ${GREEN}✅${NC} Backup Databases (dumps) → destino: ${CYAN}$CRON_DB_DEST${NC}" || echo -e "  ${GRAY}⬚${NC}  Backup Databases (não configurado)"
[ "$CRON_VOLUMES_BACKUP" = "true" ] && echo -e "  ${GREEN}✅${NC} Backup Volumes Docker" || echo -e "  ${GRAY}⬚${NC}  Backup Volumes (não configurado)"
[ "$CRON_COOLIFY_BACKUP" = "true" ] && echo -e "  ${GREEN}✅${NC} Backup Coolify (SSH, .env, configs)" || echo -e "  ${GRAY}⬚${NC}  Backup Coolify (não configurado)"
[ "$CRON_AUTO_UPLOAD" = "true" ] && echo -e "  ${GREEN}✅${NC} Upload automático → ${CYAN}$CRON_UPLOAD_DEST${NC}" || echo -e "  ${GRAY}⬚${NC}  Upload automático (não configurado)"
[ "$CRON_MANUTENCAO" = "true" ] && echo -e "  ${GREEN}✅${NC} Manutenção preventiva" || echo -e "  ${GRAY}⬚${NC}  Manutenção (não configurada)"
[ "$CRON_ALERTA_DISCO" = "true" ] && echo -e "  ${GREEN}✅${NC} Alerta de disco" || echo -e "  ${GRAY}⬚${NC}  Alerta de disco (não configurado)"
echo ""

# Menu de opções
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}O que deseja executar agora?${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Montar menu baseado no que está configurado
OPTION_NUM=1
declare -A OPTIONS

if [ "$CRON_DB_BACKUP" = "true" ]; then
    echo -e "  ${GREEN}$OPTION_NUM${NC} → 📦 Backup Databases (dump SQL) → $CRON_DB_DEST"
    OPTIONS[$OPTION_NUM]="db"
    ((OPTION_NUM++))
fi

if [ "$CRON_VOLUMES_BACKUP" = "true" ]; then
    echo -e "  ${GREEN}$OPTION_NUM${NC} → 💾 Backup Volumes Docker"
    OPTIONS[$OPTION_NUM]="volumes"
    ((OPTION_NUM++))
fi

if [ "$CRON_COOLIFY_BACKUP" = "true" ]; then
    echo -e "  ${GREEN}$OPTION_NUM${NC} → 🔐 Backup Coolify (SSH, .env, configs)"
    OPTIONS[$OPTION_NUM]="coolify"
    ((OPTION_NUM++))
fi

if [ "$CRON_MANUTENCAO" = "true" ]; then
    echo -e "  ${GREEN}$OPTION_NUM${NC} → 🔧 Manutenção preventiva"
    OPTIONS[$OPTION_NUM]="manutencao"
    ((OPTION_NUM++))
fi

if [ "$CRON_ALERTA_DISCO" = "true" ]; then
    echo -e "  ${GREEN}$OPTION_NUM${NC} → 📊 Verificar disco (alerta)"
    OPTIONS[$OPTION_NUM]="disco"
    ((OPTION_NUM++))
fi

# Opção para executar TUDO
if [ ${#OPTIONS[@]} -gt 1 ]; then
    echo ""
    echo -e "  ${MAGENTA}$OPTION_NUM${NC} → 🚀 Executar TODAS as tarefas configuradas"
    OPTIONS[$OPTION_NUM]="all"
    ((OPTION_NUM++))
fi

# Teste de webhook
echo ""
echo -e "  ${BLUE}T${NC}  → 🧪 Testar Webhook (sem executar backup)"
echo ""
echo -e "  ${RED}0${NC}  → Voltar"
echo ""

read -p "$(echo -e ${BLUE}Escolha uma opção:${NC} )" CHOICE

# Função para executar tarefa
run_task() {
    local task=$1
    local start_time=$(date +%s)

    case $task in
        db)
            echo ""
            echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo -e "${MAGENTA}📦 BACKUP DE DATABASES${NC}"
            echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo ""
            echo -e "${GRAY}Executando: $INSTALL_ROOT/backup/backup-databases-dump-auto.sh --dest=$CRON_DB_DEST${NC}"
            echo ""
            bash "$INSTALL_ROOT/backup/backup-databases-dump-auto.sh" --dest="$CRON_DB_DEST"
            ;;
        volumes)
            echo ""
            echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo -e "${MAGENTA}💾 BACKUP DE VOLUMES DOCKER${NC}"
            echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo ""
            echo -e "${GRAY}Executando: BACKUP_OUTPUT_DIR=/var/backups/vpsguardian/volumes $INSTALL_ROOT/migrar/backup-database-volumes.sh${NC}"
            echo ""
            BACKUP_OUTPUT_DIR=/var/backups/vpsguardian/volumes bash "$INSTALL_ROOT/migrar/backup-database-volumes.sh"
            ;;
        coolify)
            echo ""
            echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo -e "${MAGENTA}🔐 BACKUP DO COOLIFY${NC}"
            echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo ""
            echo -e "${GRAY}Executando: $INSTALL_ROOT/backup/backup-coolify.sh${NC}"
            echo ""
            bash "$INSTALL_ROOT/backup/backup-coolify.sh"
            ;;
        manutencao)
            echo ""
            echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo -e "${MAGENTA}🔧 MANUTENÇÃO PREVENTIVA${NC}"
            echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo ""
            echo -e "${GRAY}Executando: $INSTALL_ROOT/manutencao/manutencao-completa.sh${NC}"
            echo ""
            bash "$INSTALL_ROOT/manutencao/manutencao-completa.sh"
            ;;
        disco)
            echo ""
            echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo -e "${MAGENTA}📊 VERIFICAÇÃO DE DISCO${NC}"
            echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo ""
            echo -e "${GRAY}Executando: $INSTALL_ROOT/manutencao/alerta-disco.sh${NC}"
            echo ""
            bash "$INSTALL_ROOT/manutencao/alerta-disco.sh"
            ;;
    esac

    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    echo ""
    echo -e "${GREEN}✅ Concluído em ${duration}s${NC}"
}

# Processar escolha
case $CHOICE in
    [Tt])
        # Testar webhook
        echo ""
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${MAGENTA}🧪 TESTE DE WEBHOOK${NC}"
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""

        if [ -z "$WEBHOOK_URL" ]; then
            echo -e "${RED}❌ Webhook não configurado!${NC}"
            echo ""
            echo "Configure em: Menu 2 → 11 (Configurar Destinos)"
        else
            echo -e "Webhook: ${YELLOW}$WEBHOOK_URL${NC}"
            echo ""
            echo -e "${GREEN}▶ Enviando mensagem de teste...${NC}"
            echo ""

            HOSTNAME=$(hostname)
            IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || echo "N/A")
            DATE=$(date '+%Y-%m-%d %H:%M:%S')

            if [[ "$WEBHOOK_URL" == *"discord.com"* ]]; then
                PAYLOAD=$(cat <<EOF
{
    "embeds": [{
        "title": "🧪 Teste Manual - VPS Guardian",
        "description": "Este é um teste das notificações executado manualmente.",
        "color": 3066993,
        "fields": [
            {"name": "🖥️ Servidor", "value": "$HOSTNAME", "inline": true},
            {"name": "🌐 IP", "value": "$IP", "inline": true},
            {"name": "📅 Data/Hora", "value": "$DATE", "inline": false},
            {"name": "✅ Status", "value": "Webhook funcionando! Pronto para receber notificações dos backups.", "inline": false}
        ],
        "footer": {"text": "VPS Guardian - Teste Manual"}
    }]
}
EOF
)
                RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" -X POST -H "Content-Type: application/json" -d "$PAYLOAD" "$WEBHOOK_URL")

                if [ "$RESPONSE" = "204" ] || [ "$RESPONSE" = "200" ]; then
                    echo -e "${GREEN}✅ Mensagem enviada com sucesso!${NC}"
                    echo ""
                    echo -e "${GRAY}Verifique seu canal Discord.${NC}"
                else
                    echo -e "${RED}❌ Falha ao enviar (HTTP $RESPONSE)${NC}"
                fi
            else
                echo -e "${YELLOW}Tentando envio genérico...${NC}"
                RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" -X POST -H "Content-Type: application/json" \
                    -d '{"text": "🧪 Teste VPS Guardian - Webhook funcionando!"}' "$WEBHOOK_URL")
                echo "Resposta HTTP: $RESPONSE"
            fi
        fi
        ;;

    0|"")
        echo ""
        echo -e "${GRAY}Operação cancelada${NC}"
        exit 0
        ;;

    *)
        if [ -n "${OPTIONS[$CHOICE]}" ]; then
            TASK="${OPTIONS[$CHOICE]}"

            if [ "$TASK" = "all" ]; then
                # Executar todas as tarefas configuradas
                TOTAL_START=$(date +%s)
                TASK_COUNT=0

                echo ""
                echo -e "${CYAN}╔════════════════════════════════════════════════════════════════╗${NC}"
                echo -e "${CYAN}║         EXECUTANDO TODAS AS TAREFAS CONFIGURADAS               ║${NC}"
                echo -e "${CYAN}╚════════════════════════════════════════════════════════════════╝${NC}"

                for key in "${!OPTIONS[@]}"; do
                    task="${OPTIONS[$key]}"
                    if [ "$task" != "all" ]; then
                        run_task "$task"
                        ((TASK_COUNT++))
                    fi
                done

                TOTAL_END=$(date +%s)
                TOTAL_DURATION=$((TOTAL_END - TOTAL_START))
                TOTAL_DURATION_FMT=$(printf '%02d:%02d:%02d' $((TOTAL_DURATION/3600)) $((TOTAL_DURATION%3600/60)) $((TOTAL_DURATION%60)))

                echo ""
                echo -e "${GREEN}╔════════════════════════════════════════════════════════════════╗${NC}"
                echo -e "${GREEN}║              ✅ TODAS AS TAREFAS CONCLUÍDAS                    ║${NC}"
                echo -e "${GREEN}╚════════════════════════════════════════════════════════════════╝${NC}"
                echo ""
                echo -e "  ${GREEN}📋 Tarefas executadas: $TASK_COUNT${NC}"
                echo -e "  ${GREEN}⏱️  Duração total: $TOTAL_DURATION_FMT${NC}"
                echo ""
            else
                run_task "$TASK"
            fi
        else
            echo ""
            echo -e "${RED}Opção inválida${NC}"
        fi
        ;;
esac

echo ""
read -p "Pressione ENTER para continuar..."
