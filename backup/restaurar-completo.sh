#!/bin/bash
################################################################################
# Script: restaurar-completo.sh
# Propósito: Restauração COMPLETA (Coolify + Volumes) de forma automatizada
# Uso: ./restaurar-completo.sh [--local | --remote]
#
# Modos:
#   --local  : Restaurar no servidor atual (recuperação local)
#   --remote : Restaurar em novo servidor (migração)
#
# Versão: 2.0.0
################################################################################

set -e

# Carregar bibliotecas compartilhadas
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

init_script

### ========== CONFIGURAÇÃO ==========
MODE=""
BACKUP_COOLIFY_DIR="${BACKUP_COOLIFY_DIR:-/var/backups/vpsguardian/coolify}"
BACKUP_VOLUMES_DIR="${BACKUP_VOLUMES_DIR:-/var/backups/vpsguardian/volumes}"

# Configuração servidor remoto (se aplicável)
REMOTE_IP=""
REMOTE_USER="root"
REMOTE_PORT="22"
SSH_KEY=""

### ========== PARSE ARGUMENTOS ==========
while [[ $# -gt 0 ]]; do
    case $1 in
        --local)
            MODE="local"
            shift
            ;;
        --remote)
            MODE="remote"
            shift
            ;;
        --ip=*)
            REMOTE_IP="${1#*=}"
            shift
            ;;
        --user=*)
            REMOTE_USER="${1#*=}"
            shift
            ;;
        --port=*)
            REMOTE_PORT="${1#*=}"
            shift
            ;;
        --key=*)
            SSH_KEY="${1#*=}"
            shift
            ;;
        -h|--help)
            cat << EOF
╔════════════════════════════════════════════════════════════════╗
║         RESTAURAÇÃO COMPLETA - VPS Guardian v2.0               ║
╚════════════════════════════════════════════════════════════════╝

DESCRIÇÃO:
  Restaura TUDO de forma automatizada:
  • Coolify (configurações, banco de dados, SSH keys)
  • Volumes das aplicações (dados, bancos de dados)
  • Validação pós-restauração

MODOS DE USO:

1. RESTAURAÇÃO LOCAL (recuperação no mesmo servidor):
   ./restaurar-completo.sh --local

2. RESTAURAÇÃO REMOTA (migração para novo servidor):
   ./restaurar-completo.sh --remote

   Opções adicionais:
   --ip=X.X.X.X       IP do novo servidor
   --user=root        Usuário SSH (padrão: root)
   --port=22          Porta SSH (padrão: 22)
   --key=/path        Caminho da chave SSH privada

EXEMPLOS:

  # Restauração local (desastre no servidor atual)
  ./restaurar-completo.sh --local

  # Migração para novo servidor (modo interativo)
  ./restaurar-completo.sh --remote

  # Migração automática (não-interativo)
  ./restaurar-completo.sh --remote --ip=192.168.1.100

PROCESSO:
  1. Verificar backups disponíveis
  2. Selecionar backup (interativo ou mais recente)
  3. Restaurar Coolify (configurações)
  4. Restaurar volumes (dados)
  5. Validar restauração
  6. Relatório final

EOF
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            echo "Use --help para ajuda"
            exit 1
            ;;
    esac
done

### ========== VALIDAÇÃO ==========

if [ -z "$MODE" ]; then
    log_error "Modo de restauração não especificado"
    echo ""
    echo "Escolha um modo:"
    echo "  --local  : Restaurar neste servidor (recuperação)"
    echo "  --remote : Restaurar em novo servidor (migração)"
    echo ""
    echo "Use --help para mais informações"
    exit 1
fi

### ========== BANNER ==========
log_section "VPS Guardian - Restauração Completa v2.0"
echo ""
echo "Modo: $(echo $MODE | tr '[:lower:]' '[:upper:]')"
echo ""

if [ "$MODE" = "remote" ]; then
    log_warning "ATENÇÃO: Restauração remota irá SUBSTITUIR dados no servidor de destino!"
    echo ""
fi

### ========== MODO LOCAL ==========

if [ "$MODE" = "local" ]; then
    log_section "Restauração Local"
    echo ""
    log_info "Este modo restaura backups NESTE servidor"
    log_warning "⚠️  ATENÇÃO: Dados atuais serão SUBSTITUÍDOS!"
    echo ""
    read -p "Continuar? (digite 'CONFIRMO' para prosseguir): " confirm

    if [ "$confirm" != "CONFIRMO" ]; then
        log_info "Restauração cancelada pelo usuário"
        exit 0
    fi

    echo ""

    ### STEP 1: Verificar backups disponíveis
    log_section "Step 1/4: Verificar Backups Disponíveis"

    if [ ! -d "$BACKUP_COOLIFY_DIR" ]; then
        log_error "Diretório de backups do Coolify não encontrado: $BACKUP_COOLIFY_DIR"
        exit 1
    fi

    COOLIFY_BACKUPS=($(ls -t "$BACKUP_COOLIFY_DIR"/*.tar.gz 2>/dev/null))

    if [ ${#COOLIFY_BACKUPS[@]} -eq 0 ]; then
        log_error "Nenhum backup do Coolify encontrado"
        exit 1
    fi

    log_success "${#COOLIFY_BACKUPS[@]} backup(s) do Coolify encontrados"

    # Verificar backups de volumes
    if [ -d "$BACKUP_VOLUMES_DIR" ]; then
        VOLUME_BACKUPS=$(find "$BACKUP_VOLUMES_DIR" -name "*-backup-*.tar.gz" 2>/dev/null | wc -l)
        log_success "$VOLUME_BACKUPS backup(s) de volumes encontrados"
    else
        log_warning "Diretório de backups de volumes não encontrado: $BACKUP_VOLUMES_DIR"
        VOLUME_BACKUPS=0
    fi

    echo ""

    ### STEP 2: Selecionar backup
    log_section "Step 2/4: Selecionar Backup do Coolify"

    echo "Backups disponíveis:"
    echo ""

    for i in "${!COOLIFY_BACKUPS[@]}"; do
        BACKUP_NAME=$(basename "${COOLIFY_BACKUPS[$i]}")
        BACKUP_SIZE=$(du -h "${COOLIFY_BACKUPS[$i]}" | cut -f1)
        BACKUP_DATE=$(stat -c %y "${COOLIFY_BACKUPS[$i]}" | cut -d' ' -f1,2 | cut -d'.' -f1)
        echo "  [$i] $BACKUP_NAME"
        echo "      Data: $BACKUP_DATE | Tamanho: $BACKUP_SIZE"
        echo ""
    done

    read -p "Selecione o número do backup (Enter = mais recente): " BACKUP_INDEX
    BACKUP_INDEX=${BACKUP_INDEX:-0}

    if [ "$BACKUP_INDEX" -ge "${#COOLIFY_BACKUPS[@]}" ]; then
        log_error "Seleção inválida"
        exit 1
    fi

    SELECTED_COOLIFY_BACKUP="${COOLIFY_BACKUPS[$BACKUP_INDEX]}"
    log_success "Selecionado: $(basename $SELECTED_COOLIFY_BACKUP)"
    echo ""

    ### STEP 3: Restaurar Coolify
    log_section "Step 3/4: Restaurar Coolify (Configurações)"

    log_info "Parando containers do Coolify..."
    docker stop $(docker ps -q --filter "name=coolify") 2>/dev/null || true

    log_info "Extraindo backup..."
    TEMP_RESTORE_DIR="/tmp/coolify-restore-$$"
    mkdir -p "$TEMP_RESTORE_DIR"
    tar -xzf "$SELECTED_COOLIFY_BACKUP" -C "$TEMP_RESTORE_DIR"

    # Restaurar banco de dados
    log_info "Restaurando banco de dados do Coolify..."
    DB_DUMP=$(find "$TEMP_RESTORE_DIR" -name "coolify-db-*.dmp" | head -1)

    if [ -f "$DB_DUMP" ]; then
        docker start coolify-db 2>/dev/null || true
        sleep 5

        docker cp "$DB_DUMP" coolify-db:/tmp/restore.dmp
        docker exec coolify-db pg_restore -U coolify -d coolify -c /tmp/restore.dmp 2>/dev/null || \
        docker exec coolify-db psql -U coolify -d coolify -f /tmp/restore.dmp 2>/dev/null

        docker exec coolify-db rm /tmp/restore.dmp
        log_success "Banco de dados restaurado"
    else
        log_warning "Dump do banco não encontrado no backup"
    fi

    # Restaurar SSH keys
    if [ -d "$TEMP_RESTORE_DIR/ssh-keys" ]; then
        log_info "Restaurando SSH keys..."
        rm -rf /data/coolify/ssh/keys
        cp -r "$TEMP_RESTORE_DIR/ssh-keys" /data/coolify/ssh/keys
        log_success "SSH keys restauradas"
    fi

    # Restaurar .env
    if [ -f "$TEMP_RESTORE_DIR/.env" ]; then
        log_info "Restaurando configurações (.env)..."
        cp "$TEMP_RESTORE_DIR/.env" /data/coolify/source/.env
        log_success "Configurações restauradas"
    fi

    # Cleanup
    rm -rf "$TEMP_RESTORE_DIR"

    log_info "Reiniciando Coolify..."
    docker start $(docker ps -aq --filter "name=coolify") 2>/dev/null || true

    log_success "Coolify restaurado!"
    echo ""

    ### STEP 4: Restaurar volumes
    if [ "$VOLUME_BACKUPS" -gt 0 ]; then
        log_section "Step 4/4: Restaurar Volumes das Aplicações"

        export BACKUP_DIR="$BACKUP_VOLUMES_DIR"
        "$SCRIPT_DIR/../migrar/restore-database-volumes.sh"

        log_success "Volumes restaurados!"
    else
        log_section "Step 4/4: SKIPPED (sem backups de volumes)"
    fi

    echo ""

    ### VALIDAÇÃO PÓS-RESTAURAÇÃO
    log_section "Validação Pós-Restauração"
    echo ""

    log_info "Aguardando Coolify inicializar..."
    sleep 10

    # Verificar Coolify
    if docker ps | grep -q coolify; then
        log_success "✅ Coolify está rodando"
    else
        log_error "❌ Coolify não está rodando"
    fi

    # Verificar banco de dados
    if docker exec coolify-db pg_isready -U coolify >/dev/null 2>&1; then
        log_success "✅ Banco de dados está saudável"
    else
        log_warning "⚠️  Banco de dados pode não estar pronto"
    fi

    # Contar aplicações no banco
    APP_COUNT=$(docker exec coolify-db psql -U coolify -d coolify -t -c "SELECT COUNT(*) FROM applications;" 2>/dev/null | tr -d ' ' || echo "0")
    if [ "$APP_COUNT" -gt 0 ]; then
        log_success "✅ $APP_COUNT aplicações encontradas no Coolify"
    else
        log_warning "⚠️  Nenhuma aplicação encontrada (pode ser normal se backup estava vazio)"
    fi

    # Validar bancos de dados restaurados (se existe script de validação)
    if [ -x "$SCRIPT_DIR/../scripts-auxiliares/validate-database-health.sh" ]; then
        log_info "Validando bancos de dados restaurados..."
        "$SCRIPT_DIR/../scripts-auxiliares/validate-database-health.sh" --all >/dev/null 2>&1 && \
        log_success "✅ Bancos de dados validados" || \
        log_warning "⚠️  Alguns bancos podem precisar verificação"
    fi

    echo ""

    ### RELATÓRIO FINAL
    log_section "RESTAURAÇÃO COMPLETA"
    echo ""
    echo "  ✅ Coolify restaurado"
    if [ "$VOLUME_BACKUPS" -gt 0 ]; then
        echo "  ✅ $VOLUME_BACKUPS volumes restaurados"
    fi
    echo "  ✅ Validação pós-restauração concluída"
    echo ""
    echo "  📍 Acesse: http://localhost:8000"
    echo ""
    echo "  ⚠️  PRÓXIMOS PASSOS:"
    echo "     1. Acesse o Coolify (http://localhost:8000)"
    echo "     2. Verifique se todas as aplicações aparecem ($APP_COUNT apps esperadas)"
    echo "     3. Faça DEPLOY de cada aplicação"
    echo "        (volumes restaurados mas containers precisam ser recriados)"
    echo "     4. Teste cada aplicação individualmente"
    echo "     5. Verifique logs de cada app"
    echo ""
    echo "  💡 DICAS:"
    echo "     • Aplicações não iniciam automaticamente após restore"
    echo "     • Clique 'Deploy' para cada app no dashboard do Coolify"
    echo "     • Bancos de dados já estão com dados restaurados"
    echo ""

    log_success "Restauração local concluída com sucesso!"
    exit 0
fi

### ========== MODO REMOTO ==========

if [ "$MODE" = "remote" ]; then
    log_section "Restauração Remota (Migração)"
    echo ""

    # Se não forneceu IP, perguntar
    if [ -z "$REMOTE_IP" ]; then
        read -p "IP do novo servidor: " REMOTE_IP
    fi

    if [ -z "$REMOTE_IP" ]; then
        log_error "IP do servidor remoto é obrigatório"
        exit 1
    fi

    read -p "Usuário SSH (padrão: root): " INPUT_USER
    REMOTE_USER=${INPUT_USER:-$REMOTE_USER}

    read -p "Porta SSH (padrão: 22): " INPUT_PORT
    REMOTE_PORT=${INPUT_PORT:-$REMOTE_PORT}

    # Testar conexão SSH
    log_info "Testando conexão SSH com $REMOTE_IP..."

    SSH_CMD="ssh -p $REMOTE_PORT"
    if [ -n "$SSH_KEY" ]; then
        SSH_CMD="$SSH_CMD -i $SSH_KEY"
    fi

    if ! $SSH_CMD -o ConnectTimeout=10 "$REMOTE_USER@$REMOTE_IP" "exit" 2>/dev/null; then
        log_error "Falha na conexão SSH"
        log_info "Verifique: IP, porta, acesso SSH"
        exit 1
    fi

    log_success "Conexão SSH estabelecida!"
    echo ""

    log_info "Usando script de migração completa..."
    echo ""

    # Usar migrar-completo.sh
    export NEW_SERVER_IP="$REMOTE_IP"
    export NEW_SERVER_USER="$REMOTE_USER"
    export NEW_SERVER_PORT="$REMOTE_PORT"
    if [ -n "$SSH_KEY" ]; then
        export SSH_PRIVATE_KEY_PATH="$SSH_KEY"
    fi

    "$SCRIPT_DIR/../migrar/migrar-completo.sh" --auto

    log_success "Migração remota concluída!"
    exit 0
fi
