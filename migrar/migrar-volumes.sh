#!/bin/bash
################################################################################
# Script: migrar-volumes.sh
# Propósito: Migrar volumes Docker para um novo servidor usando backups existentes
# Uso: ./migrar-volumes.sh
################################################################################

### ========== CONFIGURAÇÃO ==========

# Servidor de destino (preserva valores exportados pelo migrar-coolify.sh)
NEW_SERVER_IP="${NEW_SERVER_IP:-}"
NEW_SERVER_USER="${NEW_SERVER_USER:-root}"
NEW_SERVER_PORT="${NEW_SERVER_PORT:-22}"

# Autenticação SSH (escolher método: key ou password)
SSH_AUTH_METHOD="${SSH_AUTH_METHOD:-}" # Será definido interativamente (key ou password)
SSH_PRIVATE_KEY_PATH="${SSH_PRIVATE_KEY_PATH:-/root/.ssh/id_rsa}"
SSH_PASSWORD="" # Será solicitado se método password for escolhido

# Diretórios
LOCAL_BACKUP_DIR="/root/volume-backups"
REMOTE_BACKUP_DIR="/root/volume-backups-received"

### ========== NÃO EDITAR ABAIXO DESTA LINHA ==========

LOG_PREFIX="[ Volume Migration Agent ]"
CONTROL_SOCKET="${CONTROL_SOCKET:-/tmp/ssh_mux_volumes_$$}"

# Criar diretório de logs
LOG_DIR="$(pwd)/volume-migration-logs"
mkdir -p "$LOG_DIR"
AGENT_LOG="$LOG_DIR/volume-migration-$(date +%Y%m%d_%H%M%S).log"

### ========== FUNÇÕES ==========

# Cores para melhor visualização
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log() {
    echo "$LOG_PREFIX [ $1 ] $2" | tee -a "$AGENT_LOG"
}

log_info() {
    echo -e "${BLUE}$LOG_PREFIX${NC} [ INFO ] $1" | tee -a "$AGENT_LOG"
}

log_success() {
    echo -e "${GREEN}$LOG_PREFIX${NC} [ ✓ ] $1" | tee -a "$AGENT_LOG"
}

log_error() {
    echo -e "${RED}$LOG_PREFIX${NC} [ ✗ ] $1" | tee -a "$AGENT_LOG"
}

log_warning() {
    echo -e "${YELLOW}$LOG_PREFIX${NC} [ ⚠ ] $1" | tee -a "$AGENT_LOG"
}

log_section() {
    echo "" | tee -a "$AGENT_LOG"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}" | tee -a "$AGENT_LOG"
    echo -e "${CYAN}  $1${NC}" | tee -a "$AGENT_LOG"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}" | tee -a "$AGENT_LOG"
    echo "" | tee -a "$AGENT_LOG"
}

check_success() {
    if [ $1 -eq 0 ]; then
        log_success "$2"
    else
        log_error "$2"
        cleanup_and_exit 1
    fi
}

cleanup_and_exit() {
    if [ $1 -eq 0 ]; then
        log_success "Volume migration completed successfully."
    else
        log_error "Volume migration failed."
    fi

    # Só fechar conexão SSH se foi criada por este script (não herdada)
    if [ "$SSH_REUSED" != "true" ]; then
        log_info "Cleaning up SSH connection..."
        ssh -S "$CONTROL_SOCKET" -O exit "$NEW_SERVER_USER@$NEW_SERVER_IP" 2>/dev/null || true
        rm -f "$CONTROL_SOCKET"
    else
        log_info "Keeping SSH connection for parent script."
    fi

    exit $1
}

trap cleanup_and_exit SIGINT SIGTERM

### ========== FUNÇÕES DE GESTÃO DE LOTES ==========

# Detectar lotes de backup disponíveis
detect_backup_batches() {
    local backup_dir="$1"

    # Encontrar todos os arquivos .batch-*.meta
    local batch_files=($(ls -t "$backup_dir"/.batch-*.meta 2>/dev/null))

    if [ ${#batch_files[@]} -eq 0 ]; then
        return 1
    fi

    # Array associativo para armazenar informações dos lotes
    declare -g -A BATCH_INFO
    declare -g BATCH_IDS=()

    for meta_file in "${batch_files[@]}"; do
        if [ -f "$meta_file" ]; then
            source "$meta_file"
            BATCH_IDS+=("$BATCH_ID")
            BATCH_INFO[$BATCH_ID]="$CREATED|$TOTAL_VOLUMES|$SUCCESSFUL_BACKUPS"
        fi
    done

    return 0
}

# Listar lotes disponíveis
list_backup_batches() {
    local backup_dir="$1"

    echo ""
    log_info "Lotes de backup disponíveis:"
    echo ""

    for i in "${!BATCH_IDS[@]}"; do
        local batch_id="${BATCH_IDS[$i]}"
        local info="${BATCH_INFO[$batch_id]}"

        IFS='|' read -r created total success <<< "$info"

        echo "  [$i] Lote: $batch_id"
        echo "      Criado em: $created"
        echo "      Volumes no lote: $success/$total"

        # Contar backups deste lote
        local batch_count=$(ls -1 "$backup_dir"/*-backup-${batch_id}.tar.gz 2>/dev/null | wc -l)
        echo "      Backups encontrados: $batch_count"
        echo ""
    done
}

# Obter backups de um lote específico
get_batch_backups() {
    local backup_dir="$1"
    local batch_id="$2"

    # Listar apenas backups deste lote
    ls -t "$backup_dir"/*-backup-${batch_id}.tar.gz 2>/dev/null
}

# Normalizar seleção de usuário (aceitar vírgulas, espaços, intervalos)
normalize_selection() {
    local input="$1"
    local result=""

    # Substituir vírgulas por espaços
    input="${input//,/ }"

    # Processar cada token
    for token in $input; do
        # Verificar se é um intervalo (ex: 0-5)
        if [[ "$token" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            local start="${BASH_REMATCH[1]}"
            local end="${BASH_REMATCH[2]}"

            # Adicionar todos os números do intervalo
            for ((i=start; i<=end; i++)); do
                result="$result $i"
            done
        elif [[ "$token" =~ ^[0-9]+$ ]]; then
            # Número simples
            result="$result $token"
        fi
    done

    # Remover espaços duplicados e trim
    echo "$result" | xargs
}

# Função auxiliar para executar comandos SSH (suporta key e password)
ssh_exec() {
    if [ "$SSH_AUTH_METHOD" = "password" ]; then
        sshpass -p "$SSH_PASSWORD" ssh -o StrictHostKeyChecking=no -p "$NEW_SERVER_PORT" "$NEW_SERVER_USER@$NEW_SERVER_IP" "$@"
    else
        # Usa ControlMaster se disponível
        if [ -S "$CONTROL_SOCKET" ]; then
            ssh -S "$CONTROL_SOCKET" "$NEW_SERVER_USER@$NEW_SERVER_IP" "$@"
        else
            ssh -p "$NEW_SERVER_PORT" "$NEW_SERVER_USER@$NEW_SERVER_IP" "$@"
        fi
    fi
}

# Função auxiliar para transferir arquivos via SCP (suporta key e password)
scp_exec() {
    local source="$1"
    local dest="$2"

    if [ "$SSH_AUTH_METHOD" = "password" ]; then
        sshpass -p "$SSH_PASSWORD" scp -o StrictHostKeyChecking=no -P "$NEW_SERVER_PORT" "$source" "$dest"
    else
        # Usa ControlMaster se disponível
        if [ -S "$CONTROL_SOCKET" ]; then
            scp -o ControlPath="$CONTROL_SOCKET" -P "$NEW_SERVER_PORT" "$source" "$dest"
        else
            scp -P "$NEW_SERVER_PORT" "$source" "$dest"
        fi
    fi
}

### ========== APRESENTAÇÃO ==========

echo ""
echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║${NC}                                                               ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}          ${GREEN}🚀 DOCKER VOLUME MIGRATION AGENT 🚀${NC}              ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}                                                               ${CYAN}║${NC}"
echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════╝${NC}"
echo ""

### ========== PROMPTS INTERATIVOS ==========

log_section "CONFIGURAÇÃO DO SERVIDOR"

# Verificar se está sendo chamado pela migração do Coolify
if [ "$COOLIFY_MIGRATION" = "true" ]; then
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║${NC}  ✅ Reutilizando configurações da migração do Coolify      ${GREEN}║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    log_success "Servidor de destino: $NEW_SERVER_IP"
    log_success "Usuário SSH: $NEW_SERVER_USER"
    log_success "Porta SSH: $NEW_SERVER_PORT"
    log_success "Método de autenticação: Chave SSH"
    log_success "Conexão SSH: Reutilizando conexão persistente"
    echo ""
else
    # Modo normal: solicitar informações
    if [ -z "$NEW_SERVER_IP" ]; then
        echo -e "${BLUE}Digite os detalhes do servidor de destino:${NC}"
        echo ""
        read -p "  Endereço IP do novo servidor: " NEW_SERVER_IP
    fi
    log_success "Servidor de destino: $NEW_SERVER_IP"

    if [ -z "$NEW_SERVER_USER" ] || [ "$NEW_SERVER_USER" = "root" ]; then
        read -p "  Usuário SSH (padrão: root): " INPUT_USER
        NEW_SERVER_USER=${INPUT_USER:-root}
    fi
    log_info "Usuário SSH: $NEW_SERVER_USER"

    if [ -z "$NEW_SERVER_PORT" ] || [ "$NEW_SERVER_PORT" = "22" ]; then
        read -p "  Porta SSH (padrão: 22): " INPUT_PORT
        NEW_SERVER_PORT=${INPUT_PORT:-22}
    fi
    log_info "Porta SSH: $NEW_SERVER_PORT"
fi

# SEMPRE criar backups fresh na execução
log_section "CREATING FRESH VOLUME BACKUPS"
log_info "Creating fresh backups of all Docker volumes..."

# Contar volumes reais no Docker
DOCKER_VOLUMES_COUNT=$(docker volume ls --quiet | wc -l)
log_info "Docker volumes found: $DOCKER_VOLUMES_COUNT"

if [ $DOCKER_VOLUMES_COUNT -eq 0 ]; then
    log_error "No Docker volumes found to backup."
    exit 1
fi

# Criar diretório de backup
mkdir -p "$LOCAL_BACKUP_DIR"

# Verificar se script de backup existe
BACKUP_SCRIPT="$(dirname "$0")/backup-volumes.sh"

if [ ! -f "$BACKUP_SCRIPT" ]; then
    log_error "Backup script not found: $BACKUP_SCRIPT"
    echo ""
    echo "  Expected location: $BACKUP_SCRIPT"
    echo ""
    exit 1
fi

if [ ! -x "$BACKUP_SCRIPT" ]; then
    chmod +x "$BACKUP_SCRIPT"
fi

log_info "Launching backup script..."
echo ""

# Executar backup-volumes.sh em modo all
"$BACKUP_SCRIPT" --all --output="$LOCAL_BACKUP_DIR"

BACKUP_EXIT_CODE=$?

if [ $BACKUP_EXIT_CODE -ne 0 ]; then
    log_error "Backup creation failed with code: $BACKUP_EXIT_CODE"
    echo ""
    echo "  Please fix the errors and try again."
    exit 1
fi

echo ""
log_success "Fresh backups created successfully!"
echo ""

### ========== DETECÇÃO E SELEÇÃO DE LOTES ==========
log_section "BATCH SELECTION"

# Detectar lotes disponíveis
if ! detect_backup_batches "$LOCAL_BACKUP_DIR"; then
    log_error "No batch metadata found. Cannot determine backup batches."
    echo ""
    echo "  This might happen if:"
    echo "    - Backups were created with an older version of the script"
    echo "    - Batch metadata files were deleted"
    echo ""
    read -p "  Continue with ALL backups found? (yes/no): " CONTINUE_OLD
    if [ "$CONTINUE_OLD" != "yes" ]; then
        log_info "Migration aborted by user."
        exit 1
    fi

    # Modo legacy: sem lotes
    SELECTED_BATCH_ID=""
    BACKUPS=($(ls -t "$LOCAL_BACKUP_DIR"/*-backup-*.tar.gz 2>/dev/null | grep -v "\-latest\.tar\.gz$"))
else
    # Listar lotes disponíveis
    list_backup_batches "$LOCAL_BACKUP_DIR"

    # Se houver apenas um lote, usar automaticamente
    if [ ${#BATCH_IDS[@]} -eq 1 ]; then
        SELECTED_BATCH_ID="${BATCH_IDS[0]}"
        log_success "Usando automaticamente o único lote disponível: $SELECTED_BATCH_ID"
    else
        # Perguntar qual lote usar
        echo ""
        echo "$LOG_PREFIX [ INPUT ] Escolha o lote de backup:"
        echo "  - Digite o número do lote [0-$((${#BATCH_IDS[@]}-1))]"
        echo "  - Digite 'latest' para usar o mais recente (default)"
        read -p "$LOG_PREFIX [ INPUT ] Lote: " BATCH_SELECTION

        if [ -z "$BATCH_SELECTION" ] || [ "$BATCH_SELECTION" = "latest" ]; then
            SELECTED_BATCH_ID="${BATCH_IDS[0]}"  # Primeiro da lista (mais recente)
            log_success "Usando lote mais recente: $SELECTED_BATCH_ID"
        elif [[ "$BATCH_SELECTION" =~ ^[0-9]+$ ]] && [ "$BATCH_SELECTION" -lt "${#BATCH_IDS[@]}" ]; then
            SELECTED_BATCH_ID="${BATCH_IDS[$BATCH_SELECTION]}"
            log_success "Usando lote selecionado: $SELECTED_BATCH_ID"
        else
            log_error "Seleção inválida."
            exit 1
        fi
    fi

    # Obter backups do lote selecionado
    BACKUPS=($(get_batch_backups "$LOCAL_BACKUP_DIR" "$SELECTED_BATCH_ID"))
fi

# Validar contagem de backups do lote selecionado
BACKUP_FILES_COUNT=${#BACKUPS[@]}

log_section "BACKUP VALIDATION"
if [ -n "$SELECTED_BATCH_ID" ]; then
    echo "  Lote selecionado: $SELECTED_BATCH_ID"
fi
echo "  Docker volumes in origin: $DOCKER_VOLUMES_COUNT"
echo "  Backup files in selected batch: $BACKUP_FILES_COUNT"
echo ""

if [ $BACKUP_FILES_COUNT -ne $DOCKER_VOLUMES_COUNT ]; then
    log_warning "Volume count mismatch!"
    log_warning "Expected $DOCKER_VOLUMES_COUNT backups, but found $BACKUP_FILES_COUNT in this batch"
    echo ""
    echo "  This could mean:"
    echo "    - Some volumes failed to backup"
    echo "    - You selected a batch from a different server/time"
    echo "    - Permission issues accessing volumes"
    echo ""
    read -p "  Continue anyway? (yes/no): " CONTINUE_ANYWAY
    if [ "$CONTINUE_ANYWAY" != "yes" ]; then
        log_info "Migration aborted by user."
        exit 1
    fi
else
    log_success "Validation passed! Batch contains expected number of backups."
fi

echo ""
log_info "Available volume backups in selected batch:"
echo ""

if [ ${#BACKUPS[@]} -eq 0 ]; then
    log_error "No backup files found after check"
    exit 1
fi

VOLUMES_TO_MIGRATE=()

for i in "${!BACKUPS[@]}"; do
    BACKUP_FILE="${BACKUPS[$i]}"
    BACKUP_DATE=$(stat -c %y "$BACKUP_FILE" | cut -d'.' -f1)
    BACKUP_SIZE=$(du -h "$BACKUP_FILE" | cut -f1)
    # Extrair nome do volume removendo -backup-TIMESTAMP.tar.gz
    VOLUME_NAME=$(basename "$BACKUP_FILE" | sed 's/-backup-[0-9_]*\.tar\.gz$//')

    # Filtrar TODOS os volumes do sistema Coolify (já migrados via dump SQL/backup específico)
    if [[ "$VOLUME_NAME" == "coolify-db" ]] || \
       [[ "$VOLUME_NAME" == "coolify-redis" ]] || \
       [[ "$VOLUME_NAME" == "coolify-data" ]] || \
       [[ "$VOLUME_NAME" == "coolify_db_data" ]] || \
       [[ "$VOLUME_NAME" == "coolify" ]] || \
       [[ "$VOLUME_NAME" == "coolify-proxy" ]] || \
       [[ "$VOLUME_NAME" == "coolify-sentinel" ]] || \
       [[ "$VOLUME_NAME" == "coolify-realtime" ]]; then
        # Pula silenciosamente este volume para não oferecer risco de corrupção
        continue
    fi

    # Mostrar numeração começando de 1 (mais natural para usuário)
    echo "  [$((i+1))] $(basename $BACKUP_FILE)"
    echo "      Volume: $VOLUME_NAME"
    echo "      Date: $BACKUP_DATE"
    echo "      Size: $BACKUP_SIZE"
    echo ""
done

# Permitir seleção múltipla
echo "$LOG_PREFIX [ INPUT ] Selecione os volumes para migrar:"
echo "  - Digite números separados por espaços (ex: 1 2 4)"
echo "  - Digite números separados por vírgulas (ex: 1,2,4)"
echo "  - Digite intervalos usando hífen (ex: 1-5 10-15)"
echo "  - Digite 'all' para migrar todos os volumes"
echo "  - Digite 'none' para cancelar"
echo ""
echo "  Exemplos:"
echo "    1 2 3 4         → volumes 1, 2, 3, 4"
echo "    1,2,3,4         → volumes 1, 2, 3, 4"
echo "    1-4             → volumes 1, 2, 3, 4"
echo "    1-4,6,8-10      → volumes 1, 2, 3, 4, 6, 8, 9, 10"
echo ""
read -p "$LOG_PREFIX [ INPUT ] Seleção: " SELECTION

if [ "$SELECTION" = "none" ]; then
    log_info "Migração cancelada pelo usuário."
    exit 0
fi

if [ "$SELECTION" = "all" ]; then
    # Gerar sequência de 1 até N, depois converter para 0-based internamente
    SELECTED_INDICES=$(seq 0 $((${#BACKUPS[@]}-1)))
else
    # Normalizar seleção (aceitar vírgulas, espaços, intervalos)
    # Converter de 1-based (usuário) para 0-based (array)
    SELECTED_INDICES_1BASED=$(normalize_selection "$SELECTION")

    if [ -z "$SELECTED_INDICES_1BASED" ]; then
        log_error "Formato de seleção inválido."
        exit 1
    fi

    # Converter para 0-based (subtrair 1 de cada índice)
    SELECTED_INDICES=""
    for idx in $SELECTED_INDICES_1BASED; do
        SELECTED_INDICES="$SELECTED_INDICES $((idx - 1))"
    done
    SELECTED_INDICES=$(echo "$SELECTED_INDICES" | xargs)
fi

# Processar seleção
SELECTED_BACKUPS=()
for idx in $SELECTED_INDICES; do
    # Validar que é um número inteiro
    if [[ ! "$idx" =~ ^[0-9]+$ ]]; then
        log_warning "Ignorando índice inválido: $((idx+1))"
        continue
    fi

    if [ $idx -ge 0 ] && [ $idx -lt ${#BACKUPS[@]} ]; then
    # --- [INÍCIO] BLOCO DE SEGURANÇA QUE VOCÊ DEVE ADICIONAR ---
        CHECK_NAME=$(basename "${BACKUPS[$idx]}" | sed 's/-backup-[0-9_]*\.tar\.gz$//')
        
        if [[ "$CHECK_NAME" == "coolify-db" ]] || \
           [[ "$CHECK_NAME" == "coolify-redis" ]] || \
           [[ "$CHECK_NAME" == "coolify-data" ]] || \
           [[ "$CHECK_NAME" == "coolify_db_data" ]] || \
           [[ "$CHECK_NAME" == "coolify" ]] || \
           [[ "$CHECK_NAME" == "coolify-proxy" ]] || \
           [[ "$CHECK_NAME" == "coolify-sentinel" ]] || \
           [[ "$CHECK_NAME" == "coolify-realtime" ]]; then
            log_warning "Volume de sistema Coolify detectado e ignorado: $CHECK_NAME"
            continue
        fi
        
        SELECTED_BACKUPS+=("${BACKUPS[$idx]}")
        # Extrair nome do volume removendo -backup-TIMESTAMP.tar.gz
        VOLUME_NAME=$(basename "${BACKUPS[$idx]}" | sed 's/-backup-[0-9_]*\.tar\.gz$//')
        VOLUMES_TO_MIGRATE+=("$VOLUME_NAME")
    else
        log_warning "Índice $((idx+1)) está fora do intervalo (1-${#BACKUPS[@]})"
    fi
done

if [ ${#SELECTED_BACKUPS[@]} -eq 0 ]; then
    log_error "No valid volumes selected."
    exit 1
fi

# Confirmar migração
echo ""
log_info "========== MIGRATION SUMMARY =========="
echo "  Volumes to migrate: ${#SELECTED_BACKUPS[@]}"
for i in "${!SELECTED_BACKUPS[@]}"; do
    echo "    - ${VOLUMES_TO_MIGRATE[$i]} ($(basename ${SELECTED_BACKUPS[$i]}))"
done
echo "  Target server: $NEW_SERVER_USER@$NEW_SERVER_IP:$NEW_SERVER_PORT"
echo "  Total size: $(du -ch "${SELECTED_BACKUPS[@]}" | tail -1 | cut -f1)"
echo "  Logs: $LOG_DIR"
echo "========================================"
echo ""
read -p "$LOG_PREFIX [ INPUT ] Proceed with migration? (yes/no): " CONFIRM

if [ "$CONFIRM" != "yes" ]; then
    log_info "Migration cancelled by user."
    exit 0
fi

### ========== DETECÇÃO AUTOMÁTICA DE CHAVE SSH ==========

# Pular seleção de método SSH se vem do Coolify
if [ "$COOLIFY_MIGRATION" = "true" ]; then
    log_section "AUTENTICAÇÃO SSH"
    log_success "✅ Reutilizando método de autenticação do Coolify (Chave SSH)"
    # SSH_AUTH_METHOD já foi exportado pelo migrar-coolify.sh
else
    log_section "DETECÇÃO DE CHAVE SSH"

    # Tentar detectar chave SSH automaticamente ANTES de pedir senha
    SSH_KEY_DETECTED=false

    # 1. Verificar chave SSH padrão
    if [ -f "$SSH_PRIVATE_KEY_PATH" ]; then
        log_info "Chave SSH encontrada: $SSH_PRIVATE_KEY_PATH"

        # Testar se a chave funciona
        log_info "Testando conexão SSH com chave..."
        ssh -o BatchMode=yes -o ConnectTimeout=5 -i "$SSH_PRIVATE_KEY_PATH" -p "$NEW_SERVER_PORT" \
            "$NEW_SERVER_USER@$NEW_SERVER_IP" "exit" >/dev/null 2>&1

        if [ $? -eq 0 ]; then
            log_success "✅ Chave SSH funcionando! Usando autenticação por chave."
            SSH_AUTH_METHOD="key"
            SSH_KEY_DETECTED=true
        else
            log_warning "Chave SSH encontrada mas não está configurada no servidor remoto."
        fi
    else
        log_info "Chave SSH padrão não encontrada em: $SSH_PRIVATE_KEY_PATH"
    fi

    # 2. Se não encontrou chave padrão, procurar chaves de migração anteriores
    if [ "$SSH_KEY_DETECTED" = false ]; then
        log_info "Procurando chaves de migração anteriores..."
        MIGRATION_KEYS=($(ls -t /root/.ssh/id_ed25519_migration* 2>/dev/null | grep -v "\.pub$" | head -5))

        if [ ${#MIGRATION_KEYS[@]} -gt 0 ]; then
            LATEST_KEY="${MIGRATION_KEYS[0]}"
            log_info "Encontrada chave de migração: $(basename $LATEST_KEY)"

            # Testar chave de migração
            ssh -o BatchMode=yes -o ConnectTimeout=5 -i "$LATEST_KEY" -p "$NEW_SERVER_PORT" \
                "$NEW_SERVER_USER@$NEW_SERVER_IP" "exit" >/dev/null 2>&1

            if [ $? -eq 0 ]; then
                log_success "✅ Chave de migração funcionando! Usando autenticação por chave."
                SSH_PRIVATE_KEY_PATH="$LATEST_KEY"
                SSH_AUTH_METHOD="key"
                SSH_KEY_DETECTED=true
            else
                log_warning "Chave de migração encontrada mas não está configurada no servidor remoto."
            fi
        fi
    fi

    echo ""

    # 3. Se não detectou chave SSH funcionando, oferecer opções
    if [ "$SSH_KEY_DETECTED" = false ]; then
        log_section "MÉTODO DE AUTENTICAÇÃO SSH"

        echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║${NC}  Escolha o método de autenticação SSH para o servidor      ${CYAN}║${NC}"
        echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════╝${NC}"
        echo ""
echo -e "  ${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  ${GREEN}[1] Chave SSH (RECOMENDADO) 🔑${NC}"
echo -e "  ${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "      ✅ Máxima segurança (criptografia assimétrica)"
echo "      ✅ Sem solicitação de senha durante a migração"
echo "      ✅ Padrão da indústria e melhores práticas DevOps"
echo "      ✅ Permite automação segura de processos"
echo "      ✅ Auditável e rastreável"
echo ""
echo "      📋 Pré-requisito: Chave SSH configurada em ~/.ssh/id_rsa"
echo "                       ou será solicitado o caminho alternativo"
echo ""
echo -e "  ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  ${YELLOW}[2] Senha (Autenticação por Senha) 🔓${NC}"
echo -e "  ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "      ⚠️  Menor segurança (senha trafega pela rede)"
echo "      ⚠️  Pode solicitar senha múltiplas vezes"
echo "      ⚠️  Não recomendado para ambientes de produção"
echo "      ⚠️  Dificulta automação de processos"
echo "      ⚠️  Vulnerável a ataques de força bruta"
echo ""
echo "      📋 Pré-requisito: Servidor deve permitir autenticação por senha"
echo "                       (PasswordAuthentication yes no sshd_config)"
echo ""
echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
echo ""

        read -p "$LOG_PREFIX [ INPUT ] Selecione o método [1/2] (padrão: 1): " AUTH_CHOICE
        AUTH_CHOICE=${AUTH_CHOICE:-1}

        if [ "$AUTH_CHOICE" = "1" ]; then
            SSH_AUTH_METHOD="key"
            echo ""
            log_success "Método de autenticação: Chave SSH 🔑"
        elif [ "$AUTH_CHOICE" = "2" ]; then
            SSH_AUTH_METHOD="password"
            echo ""
            log_warning "Método de autenticação: Senha 🔓"
            log_warning "ATENÇÃO: Este método é menos seguro. Considere usar chave SSH."

            # Verificar se sshpass está instalado
            if ! command -v sshpass &> /dev/null; then
                echo ""
                log_error "O pacote 'sshpass' não está instalado."
                log_error "Autenticação por senha requer o sshpass."
                echo ""
                echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
                echo "  Para instalar o sshpass:"
                echo ""
                echo "    Ubuntu/Debian:  sudo apt-get install -y sshpass"
                echo "    CentOS/RHEL:    sudo yum install -y sshpass"
                echo "    Alpine:         apk add sshpass"
                echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
                echo ""
                read -p "  Deseja instalar o sshpass agora? (yes/no): " INSTALL_SSHPASS

                if [ "$INSTALL_SSHPASS" = "yes" ]; then
                    log_info "Instalando sshpass..."
                    if command -v apt-get &> /dev/null; then
                        apt-get update -qq && apt-get install -y sshpass >/dev/null 2>&1
                    elif command -v yum &> /dev/null; then
                        yum install -y sshpass >/dev/null 2>&1
                    elif command -v apk &> /dev/null; then
                        apk add sshpass >/dev/null 2>&1
                    else
                        log_error "Não foi possível instalar automaticamente."
                        log_error "Por favor, instale o sshpass manualmente."
                        exit 1
                    fi
                    check_success $? "sshpass instalado com sucesso."
                else
                    log_error "Não é possível continuar sem o sshpass. Abortando."
                    exit 1
                fi
            fi

            # Solicitar senha
            echo ""
            echo -e "${YELLOW}═══════════════════════════════════════════════════════════════${NC}"
            echo -e "${YELLOW}  CONFIGURAÇÃO DE SENHA SSH${NC}"
            echo -e "${YELLOW}═══════════════════════════════════════════════════════════════${NC}"
            echo ""
            echo "  Servidor: $NEW_SERVER_USER@$NEW_SERVER_IP"
            echo "  Porta:    $NEW_SERVER_PORT"
            echo ""
            read -sp "  Digite a senha SSH: " SSH_PASSWORD
            echo ""

            if [ -z "$SSH_PASSWORD" ]; then
                log_error "A senha não pode estar vazia."
                exit 1
            fi

            log_success "Senha configurada com sucesso."
        else
            log_error "Opção inválida. Abortando."
            exit 1
        fi
    else
        # Chave SSH detectada automaticamente, pular menu de seleção
        log_success "✅ Autenticação por chave SSH será usada (detectada automaticamente)"
    fi
fi  # Fim do if COOLIFY_MIGRATION

### ========== CONFIGURAÇÃO SSH ==========

if [ "$COOLIFY_MIGRATION" != "true" ]; then
    log_info "Configurando conexão SSH com o servidor de destino..."
fi

# Verificar se já existe uma conexão SSH ativa (herdada de migrar-coolify.sh)
SSH_REUSED=false
if [ -n "$CONTROL_SOCKET" ] && [ -S "$CONTROL_SOCKET" ]; then
    log_info "Verificando conexão SSH existente..."
    if ssh -S "$CONTROL_SOCKET" -O check "$NEW_SERVER_USER@$NEW_SERVER_IP" 2>/dev/null; then
        log_success "Reutilizando conexão SSH existente da migração do Coolify."
        SSH_REUSED=true
    else
        log_warning "Conexão SSH existente não está ativa, criando nova..."
        CONTROL_SOCKET="/tmp/ssh_mux_volumes_$$"
    fi
else
    # Se não existe, criar novo CONTROL_SOCKET
    CONTROL_SOCKET="/tmp/ssh_mux_volumes_$$"
fi

# Se não está reutilizando conexão, configurar nova
if [ "$SSH_REUSED" = false ]; then
    if [ "$SSH_AUTH_METHOD" = "key" ]; then
        # ========== AUTENTICAÇÃO POR CHAVE SSH ==========

        # Verificar chave SSH
        if [ ! -f "$SSH_PRIVATE_KEY_PATH" ]; then
            log_warning "Chave SSH não encontrada em: $SSH_PRIVATE_KEY_PATH"
            echo ""
            read -p "$LOG_PREFIX [ INPUT ] Digite o caminho da chave SSH privada (ou pressione Enter para usar senha): " SSH_PRIVATE_KEY_PATH

            if [ -z "$SSH_PRIVATE_KEY_PATH" ] || [ ! -f "$SSH_PRIVATE_KEY_PATH" ]; then
                if [ -n "$SSH_PRIVATE_KEY_PATH" ]; then
                    log_warning "Chave SSH não encontrada em: $SSH_PRIVATE_KEY_PATH"
                fi

                echo ""
                log_warning "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                log_warning "🔄 FALLBACK AUTOMÁTICO: Mudando para autenticação por senha"
                log_warning "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo ""
                log_info "Como a chave SSH não está disponível, vamos usar senha."
                log_warning "⚠️  ATENÇÃO: Autenticação por senha é menos segura que chave SSH"
                echo ""

                # Mudar para método password
                SSH_AUTH_METHOD="password"

                # Verificar se sshpass está instalado
                if ! command -v sshpass &> /dev/null; then
                    echo ""
                    log_error "O pacote 'sshpass' não está instalado."
                    log_error "Autenticação por senha requer o sshpass."
                    echo ""
                    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
                    echo "  Para instalar o sshpass:"
                    echo ""
                    echo "    Ubuntu/Debian:  sudo apt-get install -y sshpass"
                    echo "    CentOS/RHEL:    sudo yum install -y sshpass"
                    echo "    Alpine:         apk add sshpass"
                    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
                    echo ""
                    read -p "  Deseja instalar o sshpass agora? (yes/no): " INSTALL_SSHPASS

                    if [ "$INSTALL_SSHPASS" = "yes" ]; then
                        log_info "Instalando sshpass..."
                        if command -v apt-get &> /dev/null; then
                            apt-get update -qq && apt-get install -y sshpass >/dev/null 2>&1
                        elif command -v yum &> /dev/null; then
                            yum install -y sshpass >/dev/null 2>&1
                        elif command -v apk &> /dev/null; then
                            apk add sshpass >/dev/null 2>&1
                        else
                            log_error "Não foi possível instalar automaticamente."
                            log_error "Por favor, instale o sshpass manualmente."
                            exit 1
                        fi
                        check_success $? "sshpass instalado com sucesso."
                    else
                        log_error "Não é possível continuar sem o sshpass. Abortando."
                        exit 1
                    fi
                fi

                # Solicitar senha
                echo ""
                echo -e "${YELLOW}═══════════════════════════════════════════════════════════════${NC}"
                echo -e "${YELLOW}  CONFIGURAÇÃO DE SENHA SSH${NC}"
                echo -e "${YELLOW}═══════════════════════════════════════════════════════════════${NC}"
                echo ""
                echo "  Servidor: $NEW_SERVER_USER@$NEW_SERVER_IP"
                echo "  Porta:    $NEW_SERVER_PORT"
                echo ""
                read -sp "  Digite a senha SSH: " SSH_PASSWORD
                echo ""

                if [ -z "$SSH_PASSWORD" ]; then
                    log_error "A senha não pode estar vazia."
                    exit 1
                fi

                log_success "Senha configurada com sucesso."
            fi
        fi

        # Se após verificações ainda está usando chave SSH, prosseguir com setup
        if [ "$SSH_AUTH_METHOD" = "key" ]; then
            log_info "Iniciando ssh-agent..."
            eval "$(ssh-agent -s)" >/dev/null
            ssh-add "$SSH_PRIVATE_KEY_PATH" >/dev/null 2>&1
            check_success $? "Chave SSH adicionada ao agente."

            log_info "Testando conexão SSH..."
            ssh -o BatchMode=yes -o ConnectTimeout=10 -p "$NEW_SERVER_PORT" \
                "$NEW_SERVER_USER@$NEW_SERVER_IP" "exit" >/dev/null 2>&1
            check_success $? "Conexão SSH estabelecida com sucesso."

            log_info "Estabelecendo conexão SSH persistente..."
            ssh -fN -M -S "$CONTROL_SOCKET" -p "$NEW_SERVER_PORT" \
                "$NEW_SERVER_USER@$NEW_SERVER_IP" 2>/dev/null
            check_success $? "Conexão SSH persistente estabelecida."
        fi

    elif [ "$SSH_AUTH_METHOD" = "password" ]; then
        # ========== AUTENTICAÇÃO POR SENHA ==========

        log_info "Testando conexão SSH com senha..."
        sshpass -p "$SSH_PASSWORD" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
            -p "$NEW_SERVER_PORT" "$NEW_SERVER_USER@$NEW_SERVER_IP" "exit" >/dev/null 2>&1

        if [ $? -ne 0 ]; then
            log_error "Falha na conexão SSH. Verifique:"
            echo ""
            echo "  ❌ IP/hostname do servidor está correto?"
            echo "  ❌ Usuário e senha estão corretos?"
            echo "  ❌ Porta SSH está correta?"
            echo "  ❌ Servidor permite autenticação por senha?"
            echo ""
            echo "  💡 Dica: Para habilitar autenticação por senha no servidor:"
            echo "     1. Edite /etc/ssh/sshd_config"
            echo "     2. Defina: PasswordAuthentication yes"
            echo "     3. Reinicie: systemctl restart sshd"
            echo ""
            exit 1
        fi

        log_success "Conexão SSH estabelecida com sucesso."

        # NÃO estabelecer ControlMaster com senha (não funciona bem)
        # Vamos usar sshpass diretamente em cada comando
        log_info "Usando autenticação por senha para cada comando SSH."
    fi
fi

### ========== VERIFICAR DOCKER NO SERVIDOR REMOTO ==========
log_info "Verificando se Docker está instalado no servidor remoto..."
ssh_exec "command -v docker >/dev/null 2>&1"
check_success $? "Docker está instalado no servidor remoto."

### ========== PREPARAR SERVIDOR REMOTO ==========
log_info "Preparing remote server..."
ssh_exec "mkdir -p $REMOTE_BACKUP_DIR"
check_success $? "Remote directory created: $REMOTE_BACKUP_DIR"

### ========== MIGRAR VOLUMES ==========
MIGRATED_COUNT=0
FAILED_COUNT=0

for i in "${!SELECTED_BACKUPS[@]}"; do
    BACKUP_FILE="${SELECTED_BACKUPS[$i]}"
    VOLUME_NAME="${VOLUMES_TO_MIGRATE[$i]}"
    BACKUP_FILENAME=$(basename "$BACKUP_FILE")

    echo ""
    log_info "========== Migrating volume $((i+1))/${#SELECTED_BACKUPS[@]}: $VOLUME_NAME =========="

    # 1. Transferir backup
    log_info "Transferring backup: $BACKUP_FILENAME..."
    scp_exec "$BACKUP_FILE" "$NEW_SERVER_USER@$NEW_SERVER_IP:$REMOTE_BACKUP_DIR/" >/dev/null 2>&1

    if [ $? -ne 0 ]; then
        log_error "Failed to transfer backup for $VOLUME_NAME"
        ((FAILED_COUNT++))
        continue
    fi
    log_success "Backup transferred."

    # 2. Verificar se volume já existe e preparar para restore limpo
    log_info "Checking if volume '$VOLUME_NAME' exists on remote server..."
    VOLUME_EXISTS=$(ssh_exec "docker volume inspect $VOLUME_NAME >/dev/null 2>&1 && echo 'yes' || echo 'no'")

    if [ "$VOLUME_EXISTS" = "yes" ]; then
        log_warning "Volume '$VOLUME_NAME' already exists - preparing clean restore..."

        # Parar containers que usam este volume
        log_info "Stopping containers using this volume..."
        ssh_exec "docker ps -a --filter volume=$VOLUME_NAME --format '{{.Names}}' | xargs -r docker stop" 2>/dev/null || true

        # CORREÇÃO: Remover volume existente para evitar mistura de arquivos
        # Isso resolve problemas de redo logs corrompidos no MySQL
        log_info "Removing existing volume for clean restore..."
        if ! ssh_exec "docker volume rm $VOLUME_NAME" 2>/dev/null; then
            log_warning "Could not remove volume, cleaning contents instead..."
            ssh_exec "docker run --rm -v $VOLUME_NAME:/volume busybox sh -c 'rm -rf /volume/* /volume/..?* /volume/.[!.]*'" 2>/dev/null || true
        fi
    fi

    # Criar volume limpo
    log_info "Creating clean volume '$VOLUME_NAME' on remote server..."
    ssh_exec "docker volume create $VOLUME_NAME" >/dev/null 2>&1
    log_success "Clean volume created."

    # 3. Restaurar volume em volume limpo
    log_info "Restoring volume data (clean restore)..."
    ssh_exec "docker run --rm -v $VOLUME_NAME:/volume -v $REMOTE_BACKUP_DIR:/backup busybox sh -c 'cd /volume && tar xzf /backup/$BACKUP_FILENAME'" 2>/dev/null

    if [ $? -eq 0 ]; then
        log_success "Volume '$VOLUME_NAME' restored successfully."
        ((MIGRATED_COUNT++))

        # Verificar conteúdo
        FILES_COUNT=$(ssh_exec "docker run --rm -v $VOLUME_NAME:/volume busybox find /volume -type f" 2>/dev/null | wc -l)
        log_info "Files restored: $FILES_COUNT"
    else
        log_error "Failed to restore volume '$VOLUME_NAME'"
        ((FAILED_COUNT++))
    fi
done

### ========== CLEANUP REMOTE BACKUPS ==========
echo ""
log_info "Cleaning up temporary backups on remote server..."
ssh_exec "rm -rf $REMOTE_BACKUP_DIR" 2>/dev/null
log_success "Remote cleanup complete."

### ========== CLEANUP LOCAL BACKUPS ==========
echo ""
log_warning "Cleaning up local backups..."
echo ""
echo "  Local backup directory: $LOCAL_BACKUP_DIR"
echo "  Space used: $(du -sh "$LOCAL_BACKUP_DIR" | cut -f1)"
echo ""
read -p "  Delete local backups to free space? (yes/no): " DELETE_LOCAL

if [ "$DELETE_LOCAL" = "yes" ]; then
    log_info "Deleting local backups..."
    rm -rf "$LOCAL_BACKUP_DIR"
    log_success "Local backups deleted successfully."
else
    log_info "Local backups preserved at: $LOCAL_BACKUP_DIR"
    echo ""
    echo "  To clean up later, run:"
    echo "    rm -rf $LOCAL_BACKUP_DIR"
    echo ""
    echo "  Or use the maintenance menu:"
    echo "    vps-guardian"
    echo "    → Manutenção → Limpar backups antigos"
    echo ""
fi

### ========== FINAL SUMMARY ==========
echo ""
log_info "========== MIGRATION SUMMARY =========="
echo ""
echo "  ✅ Successfully migrated: $MIGRATED_COUNT volumes"
if [ $FAILED_COUNT -gt 0 ]; then
    echo "  ❌ Failed: $FAILED_COUNT volumes"
fi
echo ""
echo "  📍 Remote server: $NEW_SERVER_IP"
echo "  📋 Migration log: $AGENT_LOG"
echo ""
echo "  Migrated volumes:"
for i in "${!SELECTED_BACKUPS[@]}"; do
    VOLUME_NAME="${VOLUMES_TO_MIGRATE[$i]}"
    echo "    - $VOLUME_NAME"
done
echo ""
echo "  ⚠️  NEXT STEPS:"
echo "  1. Verify volumes on remote server:"
echo "     ssh $NEW_SERVER_USER@$NEW_SERVER_IP 'docker volume ls'"
echo ""
echo "  2. Check volume contents:"
echo "     ssh $NEW_SERVER_USER@$NEW_SERVER_IP 'docker run --rm -v VOLUME_NAME:/volume busybox ls -la /volume'"
echo ""
echo "  3. Update your applications to use the migrated volumes"
echo ""
echo "========================================"
echo ""

cleanup_and_exit 0
