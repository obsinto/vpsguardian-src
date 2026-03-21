#!/bin/bash
################################################################################
# Script: restaurar-do-s3.sh
# Propósito: Restauração COMPLETA a partir de backups no AWS S3
# Uso: ./restaurar-do-s3.sh --bucket=NOME-DO-BUCKET
#
# Este script automatiza:
#   1. Download dos backups do S3
#   2. Instalação do Coolify (se necessário)
#   3. Restauração completa
#
# Versão: 1.0.0
################################################################################

# Não usar set -e para permitir fallbacks e tratamento manual de erros
# set -e

# Cores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}→${NC} $*"; }
log_success() { echo -e "${GREEN}✓${NC} $*"; }
log_error() { echo -e "${RED}✗${NC} $*"; }
log_warning() { echo -e "${YELLOW}⚠${NC} $*"; }
log_section() { echo ""; echo -e "${BLUE}========== $* ==========${NC}"; echo ""; }

### ========== CARREGAR CONFIGURAÇÃO SALVA ==========
BACKUP_DEST_CONFIG="/opt/vpsguardian/config/backup-destinations.conf"
if [ -f "$BACKUP_DEST_CONFIG" ]; then
    source "$BACKUP_DEST_CONFIG"
fi

### ========== CONFIGURAÇÃO ==========
# Usa valores do arquivo de config como padrão, se existirem
S3_BUCKET="${S3_BUCKET:-}"
S3_PREFIX="${S3_PREFIX:-backups}"
S3_ENDPOINT="${S3_ENDPOINT:-}"  # Para Cloudflare R2 ou S3-compatible
BACKUP_LOCAL_DIR="/var/backups/vpsguardian"
AWS_PROFILE="default"
SKIP_COOLIFY_INSTALL=false
DRY_RUN=false

### ========== PARSE ARGUMENTOS ==========
while [[ $# -gt 0 ]]; do
    case $1 in
        --bucket=*)
            S3_BUCKET="${1#*=}"
            shift
            ;;
        --prefix=*)
            S3_PREFIX="${1#*=}"
            shift
            ;;
        --profile=*)
            AWS_PROFILE="${1#*=}"
            shift
            ;;
        --endpoint=*)
            S3_ENDPOINT="${1#*=}"
            shift
            ;;
        --r2)
            # Atalho para Cloudflare R2
            echo "Para usar Cloudflare R2, use:"
            echo "  --endpoint=https://ACCOUNT_ID.r2.cloudflarestorage.com"
            echo ""
            echo "Encontre seu Account ID em: Cloudflare Dashboard > R2 > Overview"
            exit 0
            ;;
        --skip-coolify-install)
            SKIP_COOLIFY_INSTALL=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            cat << EOF
╔════════════════════════════════════════════════════════════════╗
║      RESTAURAÇÃO DO S3 - VPS Guardian v1.0                     ║
╚════════════════════════════════════════════════════════════════╝

DESCRIÇÃO:
  Restaura backups completos a partir do AWS S3

USO:
  ./restaurar-do-s3.sh --bucket=MEU-BUCKET [OPÇÕES]

OPÇÕES:
  --bucket=NOME          Nome do bucket S3 (OBRIGATÓRIO)
  --prefix=PATH          Prefixo/pasta no S3 (padrão: backups)
  --profile=NOME         Perfil AWS CLI (padrão: default)
  --endpoint=URL         Endpoint S3-compatible (Cloudflare R2, MinIO, etc)
  --skip-coolify-install Não instalar Coolify (já instalado)
  --dry-run              Apenas simular (não baixar/restaurar)
  -h, --help             Mostrar esta ajuda

EXEMPLOS:

  # Restauração básica (AWS S3)
  ./restaurar-do-s3.sh --bucket=meu-bucket-backups

  # Cloudflare R2
  ./restaurar-do-s3.sh --bucket=meu-bucket \
    --endpoint=https://ACCOUNT_ID.r2.cloudflarestorage.com

  # Com prefixo customizado
  ./restaurar-do-s3.sh --bucket=meu-bucket --prefix=vps-guardian/backups

  # Usando perfil AWS específico
  ./restaurar-do-s3.sh --bucket=meu-bucket --profile=producao

  # Simular (dry-run)
  ./restaurar-do-s3.sh --bucket=meu-bucket --dry-run

PRÉ-REQUISITOS:
  • AWS CLI instalado (apt install awscli)
  • Credenciais configuradas (aws configure)
  • Para R2: Access Key ID e Secret do Cloudflare R2
  • Permissões: s3:GetObject, s3:ListBucket

ESTRUTURA NO S3:
  s3://MEU-BUCKET/backups/
  ├── coolify/
  │   └── coolify-backup-*.tar.gz
  └── volumes/
      └── app-*-backup-*.tar.gz

EOF
            exit 0
            ;;
        *)
            log_error "Opção desconhecida: $1"
            echo "Use --help para ajuda"
            exit 1
            ;;
    esac
done

### ========== VALIDAÇÃO ==========

if [ -z "$S3_BUCKET" ]; then
    log_error "Bucket S3 não especificado"
    echo ""
    echo "Uso: $0 --bucket=NOME-DO-BUCKET"
    echo "Use --help para mais informações"
    exit 1
fi

### ========== CONSTRUIR COMANDO AWS ==========
# Se endpoint customizado (R2, MinIO, etc), adiciona --endpoint-url
AWS_CMD="aws"
if [ -n "$S3_ENDPOINT" ]; then
    AWS_CMD="aws --endpoint-url $S3_ENDPOINT"
fi

### ========== BANNER ==========
log_section "VPS Guardian - Restauração do S3"
echo "Bucket: s3://$S3_BUCKET/$S3_PREFIX"
echo "Perfil AWS: $AWS_PROFILE"
if [ -n "$S3_ENDPOINT" ]; then
    echo "Endpoint: $S3_ENDPOINT (S3-compatible)"
fi
if [ "$DRY_RUN" = true ]; then
    log_warning "MODO DRY-RUN (simulação, nada será baixado/restaurado)"
fi
echo ""

### ========== PRÉ-REQUISITOS ==========
log_section "Verificando Pré-requisitos"

# Verificar se é root
if [ "$EUID" -ne 0 ]; then
    log_error "Este script deve ser executado como root"
    echo "Use: sudo $0 --bucket=$S3_BUCKET"
    exit 1
fi

# Verificar AWS CLI
if ! command -v aws &> /dev/null; then
    log_error "AWS CLI não encontrado"
    echo ""
    echo "Instalando AWS CLI..."
    apt update && apt install awscli -y
    log_success "AWS CLI instalado"
fi

# Verificar credenciais AWS
log_info "Testando credenciais AWS (perfil: $AWS_PROFILE)..."
if ! $AWS_CMD s3 ls s3://$S3_BUCKET --profile $AWS_PROFILE >/dev/null 2>&1; then
    log_error "Falha ao acessar S3"
    echo ""
    echo "Possíveis causas:"
    echo "  • Credenciais AWS não configuradas"
    echo "  • Bucket não existe ou sem permissão"
    echo "  • Perfil AWS incorreto"
    echo ""
    echo "Configure credenciais com: aws configure"
    exit 1
fi
log_success "Credenciais AWS válidas"

echo ""

### ========== LISTAR BACKUPS DISPONÍVEIS NO S3 ==========
log_section "Listando Backups no S3"

# Backups do Coolify ficam em /coolify/ (separado do prefixo de databases)
COOLIFY_S3_PATH="s3://$S3_BUCKET/coolify/"

log_info "Verificando backups do Coolify em $COOLIFY_S3_PATH..."
COOLIFY_BACKUPS=$($AWS_CMD s3 ls "$COOLIFY_S3_PATH" --profile $AWS_PROFILE 2>/dev/null | grep ".tar.gz" | wc -l)

log_info "Verificando backups de volumes..."
VOLUME_BACKUPS=$($AWS_CMD s3 ls s3://$S3_BUCKET/volumes/ --profile $AWS_PROFILE 2>/dev/null | grep ".tar.gz" | wc -l)

echo ""
log_success "Backups encontrados no S3:"
echo "  • Coolify: $COOLIFY_BACKUPS backup(s)"
echo "  • Volumes: $VOLUME_BACKUPS backup(s)"

if [ "$COOLIFY_BACKUPS" -eq 0 ]; then
    log_error "Nenhum backup do Coolify encontrado no S3"
    echo ""
    echo "Verifique se:"
    echo "  1. O backup do Coolify foi executado (Menu 2 → Opção 1)"
    echo "  2. O backup foi enviado para o S3 (verifique os logs)"
    echo "  3. O caminho está correto: $COOLIFY_S3_PATH"
    echo ""
    echo "Listando conteúdo do bucket:"
    $AWS_CMD s3 ls s3://$S3_BUCKET/ --profile $AWS_PROFILE 2>/dev/null | head -10
    exit 1
fi

echo ""

# Listar backups disponíveis
log_info "Backups do Coolify disponíveis no S3:"
$AWS_CMD s3 ls "$COOLIFY_S3_PATH" --profile $AWS_PROFILE | grep ".tar.gz" | awk '{print "  • " $4 " (" $3 ")"}'

echo ""

### ========== CONFIRMAÇÃO ==========
if [ "$DRY_RUN" = false ]; then
    log_warning "ATENÇÃO: Este processo irá:"
    echo "  1. Baixar ~$(du -sh $BACKUP_LOCAL_DIR 2>/dev/null | cut -f1 || echo 'X GB') de dados do S3"
    echo "  2. Instalar Coolify (se necessário)"
    echo "  3. SUBSTITUIR dados atuais pelos backups"
    echo ""
    read -p "Continuar? (digite 'CONFIRMO' para prosseguir): " confirm

    if [ "$confirm" != "CONFIRMO" ]; then
        log_info "Operação cancelada pelo usuário"
        exit 0
    fi
    echo ""
fi

### ========== DOWNLOAD DOS BACKUPS ==========
log_section "Download dos Backups do S3"

# Criar diretórios locais
mkdir -p $BACKUP_LOCAL_DIR/coolify
mkdir -p $BACKUP_LOCAL_DIR/volumes

if [ "$DRY_RUN" = true ]; then
    log_info "DRY-RUN: Simulando download..."
    $AWS_CMD s3 ls s3://$S3_BUCKET/coolify/ --profile $AWS_PROFILE --recursive
    $AWS_CMD s3 ls s3://$S3_BUCKET/volumes/ --profile $AWS_PROFILE --recursive
else
    log_info "Baixando backups do Coolify..."
    $AWS_CMD s3 sync s3://$S3_BUCKET/coolify/ \
        $BACKUP_LOCAL_DIR/coolify/ \
        --profile $AWS_PROFILE \
        --no-progress

    log_success "Backups do Coolify baixados"

    if [ "$VOLUME_BACKUPS" -gt 0 ]; then
        log_info "Baixando backups de volumes..."
        $AWS_CMD s3 sync s3://$S3_BUCKET/volumes/ \
            $BACKUP_LOCAL_DIR/volumes/ \
            --profile $AWS_PROFILE \
            --no-progress

        log_success "Backups de volumes baixados"
    fi

    # Verificar downloads
    DOWNLOADED_COOLIFY=$(ls $BACKUP_LOCAL_DIR/coolify/*.tar.gz 2>/dev/null | wc -l)
    DOWNLOADED_VOLUMES=$(ls $BACKUP_LOCAL_DIR/volumes/*-backup-*.tar.gz 2>/dev/null | wc -l)

    echo ""
    log_success "Download concluído:"
    echo "  • Coolify: $DOWNLOADED_COOLIFY arquivo(s)"
    echo "  • Volumes: $DOWNLOADED_VOLUMES arquivo(s)"
    echo "  • Tamanho total: $(du -sh $BACKUP_LOCAL_DIR | cut -f1)"
fi

echo ""

### ========== INSTALAÇÃO DO COOLIFY ==========
if [ "$SKIP_COOLIFY_INSTALL" = false ]; then
    log_section "Instalação do Coolify"

    if docker ps | grep -q coolify; then
        log_info "Coolify já está instalado"
    else
        if [ "$DRY_RUN" = true ]; then
            log_info "DRY-RUN: Simulando instalação do Coolify..."
        else
            log_info "Instalando Coolify..."
            curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash

            log_success "Coolify instalado"

            # Aguardar Coolify inicializar
            log_info "Aguardando Coolify inicializar (30s)..."
            sleep 30
        fi
    fi
else
    log_section "Instalação do Coolify (SKIPPED)"
fi

echo ""

### ========== RESTAURAÇÃO ==========
log_section "Restauração dos Backups"

if [ "$DRY_RUN" = true ]; then
    log_info "DRY-RUN: Simulando restauração..."
    echo "  • Restauraria Coolify de: $BACKUP_LOCAL_DIR/coolify/"
    echo "  • Restauraria volumes de: $BACKUP_LOCAL_DIR/volumes/"
else
    # Verificar se script de restauração existe
    RESTORE_SCRIPT="/opt/vpsguardian/backup/restaurar-completo.sh"

    if [ ! -f "$RESTORE_SCRIPT" ]; then
        log_warning "Script de restauração não encontrado, usando método alternativo..."

        # Restauração direta (fallback)
        log_info "Parando Coolify..."
        docker stop $(docker ps -q --filter "name=coolify") 2>/dev/null || true

        # Restaurar banco do Coolify
        LATEST_BACKUP=$(ls -t $BACKUP_LOCAL_DIR/coolify/*.tar.gz | head -1)
        log_info "Restaurando de: $(basename $LATEST_BACKUP)"

        TEMP_DIR="/tmp/coolify-restore-$$"
        mkdir -p $TEMP_DIR
        tar -xzf $LATEST_BACKUP -C $TEMP_DIR

        # ==============================================================================
        # EXTRAÇÃO DE APP_KEY E APP_PREVIOUS_KEYS (CRÍTICO!)
        # Mesmo método usado em migrar-coolify.sh que funciona perfeitamente
        # ==============================================================================
        log_info "🔍 Localizando chaves de criptografia no backup..."

        BACKUP_APP_KEY=""
        BACKUP_PREV_KEYS=""

        # 1. BUSCA INTELIGENTE: Procurar .env recursivamente no backup extraído
        FOUND_ENV_FILE=$(find "$TEMP_DIR" -name ".env" -type f | head -n 1)

        if [ -n "$FOUND_ENV_FILE" ]; then
            log_success "✅ Arquivo .env encontrado no backup!"
            log_info "   Localização: ${FOUND_ENV_FILE#$TEMP_DIR/}"

            BACKUP_APP_KEY=$(grep "^APP_KEY=" "$FOUND_ENV_FILE" | cut -d '=' -f2-)
            BACKUP_PREV_KEYS=$(grep "^APP_PREVIOUS_KEYS=" "$FOUND_ENV_FILE" | cut -d '=' -f2-)

            if [ -n "$BACKUP_APP_KEY" ]; then
                log_success "✅ APP_KEY encontrada no backup"
                log_info "   Preview: ${BACKUP_APP_KEY:0:30}..."
            fi

            if [ -n "$BACKUP_PREV_KEYS" ]; then
                KEY_COUNT=$(echo "$BACKUP_PREV_KEYS" | tr ',' '\n' | wc -l)
                log_success "✅ APP_PREVIOUS_KEYS encontrado ($KEY_COUNT chaves antigas)"
            fi
        else
            log_warning "⚠️  Arquivo .env não encontrado no backup extraído"
        fi

        # 2. VALIDAÇÃO FINAL
        if [ -z "$BACKUP_APP_KEY" ]; then
            log_error "❌ ERRO CRÍTICO: Nenhuma APP_KEY encontrada no backup!"
            log_error "Isso causará erro 'The MAC is invalid' no Coolify"
            log_error "Verifique se o backup está completo"
        else
            # 3. APLICAR APP_KEY NO .ENV DO SISTEMA
            log_info "Aplicando chaves de criptografia..."

            ENV_FILE="/data/coolify/source/.env"

            # Criar backup do .env atual
            if [ -f "$ENV_FILE" ]; then
                cp "$ENV_FILE" "${ENV_FILE}.before-restore-$(date +%Y%m%d_%H%M%S)"
            fi

            # Garantir que o arquivo existe
            mkdir -p /data/coolify/source
            touch "$ENV_FILE"

            # Remover linhas antigas de APP_KEY e APP_PREVIOUS_KEYS
            sed -i '/^APP_KEY=/d' "$ENV_FILE"
            sed -i '/^APP_PREVIOUS_KEYS=/d' "$ENV_FILE"

            # Aplicar APP_KEY do backup usando printf (evita problemas com caracteres especiais)
            printf 'APP_KEY=%s\n' "$BACKUP_APP_KEY" >> "$ENV_FILE"

            # Aplicar APP_PREVIOUS_KEYS se existir
            if [ -n "$BACKUP_PREV_KEYS" ]; then
                printf 'APP_PREVIOUS_KEYS=%s\n' "$BACKUP_PREV_KEYS" >> "$ENV_FILE"
            fi

            # Limpar linhas vazias
            sed -i '/^$/d' "$ENV_FILE"

            chmod 600 "$ENV_FILE"
            log_success "✅ APP_KEY aplicada com sucesso!"
            log_info "   APP_KEY: ${BACKUP_APP_KEY:0:30}..."
        fi

        # Encontrar o diretório extraído para outros arquivos
        BACKUP_EXTRACTED_DIR=$(find $TEMP_DIR -maxdepth 1 -type d -name "[0-9]*" | head -1)
        if [ -z "$BACKUP_EXTRACTED_DIR" ]; then
            BACKUP_EXTRACTED_DIR="$TEMP_DIR"
        fi

        # ========== RESTAURAR SSH KEYS ==========
        SSH_KEYS_DIR=$(find $BACKUP_EXTRACTED_DIR -maxdepth 1 -type d -name "ssh-keys" | head -1)
        if [ -d "$SSH_KEYS_DIR" ]; then
            log_info "Restaurando SSH keys privadas..."
            mkdir -p /data/coolify/ssh/keys
            cp -r "$SSH_KEYS_DIR"/* /data/coolify/ssh/keys/ 2>/dev/null || true
            chmod 600 /data/coolify/ssh/keys/* 2>/dev/null || true
            log_success "SSH keys privadas restauradas"
        else
            log_warning "SSH keys não encontradas no backup"
        fi

        # ========== RESTAURAR AUTHORIZED_KEYS ==========
        # Necessário para o Coolify poder conectar via SSH ao servidor
        AUTHORIZED_KEYS_FILE=$(find $BACKUP_EXTRACTED_DIR -maxdepth 1 -name "authorized_keys" -type f | head -1)
        if [ -f "$AUTHORIZED_KEYS_FILE" ]; then
            log_info "Restaurando authorized_keys..."
            mkdir -p /root/.ssh
            chmod 700 /root/.ssh

            # Fazer backup do atual
            if [ -f /root/.ssh/authorized_keys ]; then
                cp /root/.ssh/authorized_keys /root/.ssh/authorized_keys.before-restore 2>/dev/null || true
            fi

            # Adicionar chaves do backup (merge, não sobrescrever)
            cat "$AUTHORIZED_KEYS_FILE" >> /root/.ssh/authorized_keys

            # Remover duplicatas mantendo ordem
            sort -u /root/.ssh/authorized_keys > /root/.ssh/authorized_keys.tmp
            mv /root/.ssh/authorized_keys.tmp /root/.ssh/authorized_keys
            chmod 600 /root/.ssh/authorized_keys

            log_success "authorized_keys restaurado (SSH do Coolify funcionará)"
        else
            log_warning "authorized_keys não encontrado no backup"
            log_warning "O Coolify pode não conseguir conectar ao servidor via SSH"
        fi

        # ========== RESTAURAR PROXY CONFIG (certificados SSL) ==========
        PROXY_CONFIG_DIR=$(find $BACKUP_EXTRACTED_DIR -maxdepth 1 -type d -name "proxy-config" | head -1)
        if [ -d "$PROXY_CONFIG_DIR" ]; then
            log_info "Restaurando configuração do proxy (certificados SSL)..."
            mkdir -p /data/coolify/proxy
            cp -r "$PROXY_CONFIG_DIR"/* /data/coolify/proxy/ 2>/dev/null || true
            log_success "Configuração do proxy restaurada"
        fi

        # ========== RESTAURAR BANCO DE DADOS ==========
        DB_DUMP=$(find $BACKUP_EXTRACTED_DIR -name "coolify-db-*.dmp" -o -name "coolify-db-*.sql" | head -1)
        if [ -f "$DB_DUMP" ]; then
            log_info "Iniciando container do banco de dados..."
            docker start coolify-db 2>/dev/null || true

            # Aguardar banco ficar pronto
            log_info "Aguardando banco de dados ficar pronto..."
            for i in {1..30}; do
                if docker exec coolify-db pg_isready -U coolify >/dev/null 2>&1; then
                    log_success "Banco de dados pronto"
                    break
                fi
                sleep 1
            done

            log_info "Copiando dump para container..."
            docker cp "$DB_DUMP" coolify-db:/tmp/restore.dmp

            # Tentar pg_restore primeiro (formato custom), se falhar, tentar psql (formato SQL)
            log_info "Restaurando banco de dados..."
            if docker exec coolify-db pg_restore -U coolify -d coolify -c --if-exists /tmp/restore.dmp 2>/dev/null; then
                log_success "Banco de dados restaurado (pg_restore)"
            elif docker exec coolify-db psql -U coolify -d coolify -f /tmp/restore.dmp 2>/dev/null; then
                log_success "Banco de dados restaurado (psql)"
            else
                log_warning "Restauração do banco teve avisos (pode ser normal em instalação nova)"
                # Tentar novamente sem o -c (clean) flag
                docker exec coolify-db pg_restore -U coolify -d coolify /tmp/restore.dmp 2>&1 || true
            fi

            docker exec coolify-db rm -f /tmp/restore.dmp
        else
            log_warning "Dump do banco de dados não encontrado no backup"
        fi

        # Limpar diretório temporário
        rm -rf $TEMP_DIR

        # ========== RECRIAR CONTAINERS DO COOLIFY ==========
        # IMPORTANTE: Usar --force-recreate para que os containers
        # carreguem a nova APP_KEY do .env (docker start NÃO recarrega env vars!)
        log_section "Recriando Containers do Coolify"

        log_info "Parando containers existentes..."
        docker stop coolify coolify-db coolify-redis coolify-realtime coolify-proxy coolify-sentinel 2>/dev/null || true

        log_info "Removendo containers para recriar com nova APP_KEY..."
        docker rm coolify coolify-realtime coolify-sentinel coolify-proxy 2>/dev/null || true

        log_info "Recriando containers com docker compose..."
        cd /data/coolify/source

        # Usar --force-recreate para garantir que as env vars sejam recarregadas
        if docker compose up -d --force-recreate 2>/dev/null; then
            log_success "Containers recriados com nova APP_KEY"
        else
            log_warning "docker compose falhou, tentando método alternativo..."
            # Fallback: iniciar containers restantes
            docker start coolify-db coolify-redis 2>/dev/null || true
            sleep 5

            # Rodar script de upgrade do Coolify que recria containers corretamente
            if [ -f "/data/coolify/source/upgrade.sh" ]; then
                log_info "Usando upgrade.sh do Coolify..."
                bash /data/coolify/source/upgrade.sh 2>/dev/null || true
            fi
        fi

        # Aguardar containers iniciarem
        log_info "Aguardando Coolify inicializar (30s)..."
        sleep 30

        # Verificar se APP_KEY foi aplicada corretamente
        CONTAINER_APP_KEY=$(docker exec coolify env 2>/dev/null | grep "^APP_KEY=" | cut -d'=' -f2-)
        if [ "$CONTAINER_APP_KEY" = "$BACKUP_APP_KEY" ]; then
            log_success "✅ APP_KEY verificada - container usando chave correta!"
        else
            log_warning "⚠️  APP_KEY no container pode estar diferente"
            log_info "   Esperado: ${BACKUP_APP_KEY:0:30}..."
            log_info "   Atual:    ${CONTAINER_APP_KEY:0:30}..."
            log_info "   Se houver erro 'MAC is invalid', execute manualmente:"
            log_info "   cd /data/coolify/source && docker compose up -d --force-recreate"
        fi

        # ========== APLICAÇÕES EM STANDBY ==========
        # As aplicações NÃO são iniciadas automaticamente após restauração
        # O usuário deve fazer deploy manualmente de cada aplicação no Coolify
        log_success "✅ Aplicações em STANDBY (não iniciadas automaticamente)"
        log_info "   Acesse o Coolify para fazer deploy manualmente de cada aplicação"
        log_info "   Os dados das aplicações foram restaurados no banco de dados"

        log_success "Coolify restaurado"
    else
        # Usar script de restauração completo
        log_info "Usando script de restauração automatizado..."
        $RESTORE_SCRIPT --local
    fi
fi

echo ""

### ========== RELATÓRIO FINAL ==========
log_section "RESTAURAÇÃO CONCLUÍDA"
echo ""
echo "  ✅ Backups baixados do S3"
echo "  ✅ Coolify instalado/restaurado"
if [ "$VOLUME_BACKUPS" -gt 0 ]; then
    echo "  ✅ Volumes restaurados"
fi
echo ""
echo "  📍 Acesse Coolify: http://$(hostname -I | awk '{print $1}'):8000"
echo ""
echo "  ⚠️  PRÓXIMOS PASSOS:"
echo "     1. Acesse o Coolify"
echo "     2. Verifique se todas as aplicações aparecem"
echo "     3. Faça DEPLOY de cada aplicação"
echo "     4. Teste cada aplicação"
echo "     5. Reconfigure DNS (se migração)"
echo ""
echo "  💾 Backups locais em: $BACKUP_LOCAL_DIR"
echo "     (Você pode deletá-los depois de validar)"
echo ""

log_success "Restauração do S3 concluída com sucesso!"
