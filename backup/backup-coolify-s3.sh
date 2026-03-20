#!/bin/bash
################################################################################
# VPS Guardian - Backup Completo Coolify para S3
#
# Faz backup completo do Coolify (DB + SSH keys + configs) e envia para S3
# Suporta: AWS S3, Backblaze B2, Wasabi, MinIO e qualquer S3-compatible
#
# Uso:
#   ./backup-coolify-s3.sh                    # Modo interativo
#   ./backup-coolify-s3.sh --config=/path     # Usa arquivo de configuração
#   ./backup-coolify-s3.sh --auto             # Modo não-interativo (requer config)
#
# Versão: 1.0
################################################################################

set -e

# Carregar bibliotecas compartilhadas
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

# Inicializar script
init_script

################################################################################
# CONFIGURAÇÕES PADRÃO
################################################################################

# Diretórios
BACKUP_BASE_DIR="${COOLIFY_BACKUP_DIR:-/var/backups/vpsguardian/coolify}"
TEMP_BACKUP_DIR=""
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-30}"

# Coolify
COOLIFY_DATA_DIR="/data/coolify"
COOLIFY_SOURCE_DIR="$COOLIFY_DATA_DIR/source"
COOLIFY_SSH_DIR="$COOLIFY_DATA_DIR/ssh/keys"
COOLIFY_ENV_FILE="$COOLIFY_SOURCE_DIR/.env"

# S3 Config
S3_PROVIDER=""          # aws, backblaze, wasabi, minio, custom
S3_BUCKET=""
S3_PREFIX="backups/coolify"
S3_REGION="us-east-1"
S3_ENDPOINT=""          # Para provedores custom
S3_ACCESS_KEY=""
S3_SECRET_KEY=""

# Criptografia
ENCRYPT_BACKUP=false
GPG_RECIPIENT=""

# Lifecycle
CONFIGURE_LIFECYCLE=false
LIFECYCLE_DAYS=90

# Notificações
WEBHOOK_URL=""
TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_ID=""

# Config file
CONFIG_FILE="/etc/vpsguardian/backup-s3.conf"
AUTO_MODE=false

################################################################################
# FUNÇÕES AUXILIARES
################################################################################

show_help() {
    cat << EOF
$(log_info "VPS Guardian - Backup Coolify para S3")

$(log_info "USO:")
  $0 [opções]

$(log_info "OPÇÕES:")
  --config=PATH       Usar arquivo de configuração
  --auto              Modo não-interativo (requer config)
  --help              Mostrar esta ajuda

$(log_info "ARQUIVO DE CONFIGURAÇÃO EXEMPLO:")
  /etc/vpsguardian/backup-s3.conf

  # Provedor S3
  S3_PROVIDER="aws"              # aws, backblaze, wasabi, minio, custom
  S3_BUCKET="meu-bucket"
  S3_PREFIX="backups/coolify"
  S3_REGION="us-east-1"
  S3_ACCESS_KEY="AKIAIOSFODNN7EXAMPLE"
  S3_SECRET_KEY="wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"

  # Backblaze B2 (exemplo)
  # S3_PROVIDER="backblaze"
  # S3_ENDPOINT="https://s3.us-west-002.backblazeb2.com"

  # Criptografia (opcional)
  ENCRYPT_BACKUP=true
  GPG_RECIPIENT="seu-email@example.com"

  # Lifecycle (opcional)
  CONFIGURE_LIFECYCLE=true
  LIFECYCLE_DAYS=90

  # Notificações (opcional)
  WEBHOOK_URL="https://discord.com/api/webhooks/..."
  TELEGRAM_BOT_TOKEN="123456:ABC-DEF..."
  TELEGRAM_CHAT_ID="123456789"

$(log_info "PROVEDORES SUPORTADOS:")
  • AWS S3
  • Backblaze B2
  • Wasabi
  • MinIO
  • Qualquer S3-compatible

$(log_info "EXEMPLOS:")
  # Modo interativo
  sudo $0

  # Com arquivo de configuração
  sudo $0 --config=/etc/vpsguardian/backup-s3.conf

  # Modo automático (cron)
  sudo $0 --config=/etc/vpsguardian/backup-s3.conf --auto

EOF
    exit 0
}

load_config() {
    local config_file="$1"

    if [ ! -f "$config_file" ]; then
        log_error "Arquivo de configuração não encontrado: $config_file"
        return 1
    fi

    log_info "Carregando configuração: $config_file"
    source "$config_file"

    # Validar configurações obrigatórias
    if [ -z "$S3_PROVIDER" ] || [ -z "$S3_BUCKET" ] || [ -z "$S3_ACCESS_KEY" ] || [ -z "$S3_SECRET_KEY" ]; then
        log_error "Configuração incompleta. Obrigatório: S3_PROVIDER, S3_BUCKET, S3_ACCESS_KEY, S3_SECRET_KEY"
        return 1
    fi

    log_success "Configuração carregada"
    return 0
}

configure_s3_endpoint() {
    case "$S3_PROVIDER" in
        aws)
            S3_ENDPOINT=""
            ;;
        backblaze)
            if [ -z "$S3_ENDPOINT" ]; then
                log_error "Backblaze requer S3_ENDPOINT (ex: https://s3.us-west-002.backblazeb2.com)"
                return 1
            fi
            ;;
        wasabi)
            if [ -z "$S3_ENDPOINT" ]; then
                S3_ENDPOINT="https://s3.${S3_REGION}.wasabisys.com"
            fi
            ;;
        minio)
            if [ -z "$S3_ENDPOINT" ]; then
                log_error "MinIO requer S3_ENDPOINT (ex: https://minio.example.com)"
                return 1
            fi
            ;;
        custom)
            if [ -z "$S3_ENDPOINT" ]; then
                log_error "Provedor custom requer S3_ENDPOINT"
                return 1
            fi
            ;;
        *)
            log_error "Provedor inválido: $S3_PROVIDER"
            return 1
            ;;
    esac
    return 0
}

configure_aws_cli() {
    log_section "Configurando AWS CLI"

    # Criar diretório de config se não existir
    mkdir -p ~/.aws

    # Configurar credentials
    cat > ~/.aws/credentials << EOF
[default]
aws_access_key_id = $S3_ACCESS_KEY
aws_secret_access_key = $S3_SECRET_KEY
EOF
    chmod 600 ~/.aws/credentials

    # Configurar config
    cat > ~/.aws/config << EOF
[default]
region = $S3_REGION
EOF

    log_success "AWS CLI configurado"
}

notify() {
    local title="$1"
    local message="$2"
    local status="$3"  # success, error, info

    local emoji="ℹ️"
    case "$status" in
        success) emoji="✅" ;;
        error) emoji="❌" ;;
        warning) emoji="⚠️" ;;
    esac

    local full_message="$emoji **$title**\n$message\n\nServidor: $(hostname)\nData: $(date '+%Y-%m-%d %H:%M:%S')"

    # Discord/Slack Webhook
    if [ -n "$WEBHOOK_URL" ]; then
        curl -s -H "Content-Type: application/json" \
             -d "{\"content\":\"$full_message\"}" \
             "$WEBHOOK_URL" > /dev/null 2>&1
    fi

    # Telegram
    if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
        local telegram_url="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage"
        curl -s -X POST "$telegram_url" \
             -d "chat_id=$TELEGRAM_CHAT_ID" \
             -d "text=$full_message" \
             -d "parse_mode=Markdown" > /dev/null 2>&1
    fi
}

interactive_setup() {
    log_section "Configuração Interativa do S3"

    echo ""
    echo "Provedores suportados:"
    echo "  [1] AWS S3"
    echo "  [2] Backblaze B2"
    echo "  [3] Wasabi"
    echo "  [4] MinIO"
    echo "  [5] Outro (S3-compatible)"
    echo ""

    read -p "Escolha o provedor (1-5): " provider_choice

    case "$provider_choice" in
        1) S3_PROVIDER="aws" ;;
        2) S3_PROVIDER="backblaze" ;;
        3) S3_PROVIDER="wasabi" ;;
        4) S3_PROVIDER="minio" ;;
        5) S3_PROVIDER="custom" ;;
        *)
            log_error "Opção inválida"
            exit 1
            ;;
    esac

    echo ""
    read -p "Nome do bucket: " S3_BUCKET
    read -p "Prefixo/pasta (padrão: backups/coolify): " input_prefix
    S3_PREFIX="${input_prefix:-backups/coolify}"

    read -p "Região (padrão: us-east-1): " input_region
    S3_REGION="${input_region:-us-east-1}"

    if [ "$S3_PROVIDER" != "aws" ]; then
        read -p "Endpoint S3: " S3_ENDPOINT
    fi

    echo ""
    read -p "Access Key ID: " S3_ACCESS_KEY
    read -sp "Secret Access Key: " S3_SECRET_KEY
    echo ""

    echo ""
    read -p "Criptografar backup com GPG? (y/N): " encrypt_choice
    if [ "$encrypt_choice" = "y" ] || [ "$encrypt_choice" = "Y" ]; then
        ENCRYPT_BACKUP=true
        read -p "Email do destinatário GPG: " GPG_RECIPIENT
    fi

    echo ""
    read -p "Configurar expiração automática no S3? (y/N): " lifecycle_choice
    if [ "$lifecycle_choice" = "y" ] || [ "$lifecycle_choice" = "Y" ]; then
        CONFIGURE_LIFECYCLE=true
        read -p "Dias para expiração (padrão: 90): " input_days
        LIFECYCLE_DAYS="${input_days:-90}"
    fi

    echo ""
    read -p "Salvar esta configuração em $CONFIG_FILE? (Y/n): " save_choice
    if [ "$save_choice" != "n" ] && [ "$save_choice" != "N" ]; then
        save_config
    fi
}

save_config() {
    log_info "Salvando configuração em $CONFIG_FILE"

    ensure_directory "$(dirname "$CONFIG_FILE")" 755

    cat > "$CONFIG_FILE" << EOF
# VPS Guardian - Configuração de Backup S3
# Gerado em: $(date '+%Y-%m-%d %H:%M:%S')

# Provedor S3
S3_PROVIDER="$S3_PROVIDER"
S3_BUCKET="$S3_BUCKET"
S3_PREFIX="$S3_PREFIX"
S3_REGION="$S3_REGION"
S3_ENDPOINT="$S3_ENDPOINT"
S3_ACCESS_KEY="$S3_ACCESS_KEY"
S3_SECRET_KEY="$S3_SECRET_KEY"

# Criptografia
ENCRYPT_BACKUP=$ENCRYPT_BACKUP
GPG_RECIPIENT="$GPG_RECIPIENT"

# Lifecycle
CONFIGURE_LIFECYCLE=$CONFIGURE_LIFECYCLE
LIFECYCLE_DAYS=$LIFECYCLE_DAYS

# Notificações (opcional)
WEBHOOK_URL="$WEBHOOK_URL"
TELEGRAM_BOT_TOKEN="$TELEGRAM_BOT_TOKEN"
TELEGRAM_CHAT_ID="$TELEGRAM_CHAT_ID"
EOF

    chmod 600 "$CONFIG_FILE"
    log_success "Configuração salva em $CONFIG_FILE"
}

################################################################################
# BACKUP DO COOLIFY (baseado em backup-coolify.sh)
################################################################################

create_coolify_backup() {
    log_section "Backup do Coolify"

    # Verificar se Coolify está instalado
    check_docker || exit 1
    check_coolify || exit 1
    check_container_running "coolify-db" || exit 1

    # Criar diretório temporário para backup
    TEMP_BACKUP_DIR="$BACKUP_BASE_DIR/temp-$(date +%Y%m%d_%H%M%S)"
    ensure_directory "$TEMP_BACKUP_DIR" 700
    log_info "Diretório temporário: $TEMP_BACKUP_DIR"

    # 1. Backup do banco de dados
    log_info "Fazendo backup do PostgreSQL..."
    local db_file="$TEMP_BACKUP_DIR/coolify-db-$(date +%s).dmp"

    docker exec coolify-db pg_dump -U coolify -d coolify -F c -f /tmp/backup.dmp 2>/dev/null
    if [ $? -eq 0 ]; then
        docker cp coolify-db:/tmp/backup.dmp "$db_file"
        docker exec coolify-db rm /tmp/backup.dmp
        local db_size=$(du -h "$db_file" | cut -f1)
        log_success "Banco de dados: $db_size"
    else
        log_error "Falha no backup do banco de dados"
        return 1
    fi

    # 2. Backup das SSH keys
    log_info "Fazendo backup das SSH keys..."
    if [ -d "$COOLIFY_SSH_DIR" ]; then
        cp -r "$COOLIFY_SSH_DIR" "$TEMP_BACKUP_DIR/ssh-keys"
        local keys_count=$(find "$TEMP_BACKUP_DIR/ssh-keys" -type f | wc -l)
        log_success "SSH Keys: $keys_count arquivos"
    else
        log_warning "Diretório de SSH keys não encontrado"
    fi

    # 3. Backup do .env
    log_info "Fazendo backup das configurações..."
    if [ -f "$COOLIFY_ENV_FILE" ]; then
        cp "$COOLIFY_ENV_FILE" "$TEMP_BACKUP_DIR/.env"

        # Extrair APP_KEY
        local app_key=$(grep "^APP_KEY=" "$COOLIFY_ENV_FILE" | cut -d '=' -f2-)
        echo "APP_KEY=$app_key" > "$TEMP_BACKUP_DIR/app-key.txt"

        log_success "Arquivo .env e APP_KEY"
    else
        log_warning "Arquivo .env não encontrado"
    fi

    # 4. Backup do authorized_keys
    if [ -f "/root/.ssh/authorized_keys" ]; then
        cp /root/.ssh/authorized_keys "$TEMP_BACKUP_DIR/authorized_keys"
        log_success "Arquivo authorized_keys"
    fi

    # 5. Configurações do Nginx
    if [ -d "/etc/nginx" ]; then
        cp -r /etc/nginx "$TEMP_BACKUP_DIR/nginx-config" 2>/dev/null
        log_success "Configurações do Nginx"
    fi

    # 6. Lista de volumes
    docker volume ls --format '{{.Name}}' > "$TEMP_BACKUP_DIR/volumes-list.txt"
    local volumes_count=$(wc -l < "$TEMP_BACKUP_DIR/volumes-list.txt")
    log_success "Lista de volumes: $volumes_count"

    # 7. Informações do sistema
    cat > "$TEMP_BACKUP_DIR/system-info.txt" <<EOF
Sistema: $(lsb_release -d 2>/dev/null | cut -f2 || echo "N/A")
Kernel: $(uname -r)
Docker: $(docker --version 2>/dev/null || echo "N/A")
Espaço: $(df -h / | tail -1 | awk '{print $5 " usado de " $2}')
Memória: $(free -h | grep Mem | awk '{print $3 " usado de " $2}')
Coolify: $(docker ps --filter "name=coolify" --format '{{.Image}}' | grep coollabsio/coolify | head -n1)
Backup: $(date '+%Y-%m-%d %H:%M:%S')
Hostname: $(hostname)
EOF

    log_success "Backup do Coolify concluído"
    return 0
}

compress_backup() {
    log_section "Compactação"

    cd "$BACKUP_BASE_DIR"
    local backup_basename=$(basename "$TEMP_BACKUP_DIR")
    local compressed_file="${backup_basename}.tar.gz"

    tar -czf "$compressed_file" "$backup_basename" 2>/dev/null

    if [ $? -eq 0 ]; then
        local size=$(du -h "$compressed_file" | cut -f1)
        log_success "Backup compactado: $size"

        # Remover diretório não compactado
        rm -rf "$TEMP_BACKUP_DIR"

        echo "$BACKUP_BASE_DIR/$compressed_file"
        return 0
    else
        log_error "Falha na compactação"
        return 1
    fi
}

encrypt_backup() {
    local backup_file="$1"

    log_section "Criptografia GPG"

    if ! command -v gpg &> /dev/null; then
        log_error "GPG não está instalado. Instale com: apt install gnupg -y"
        return 1
    fi

    log_info "Criptografando com GPG para: $GPG_RECIPIENT"

    local encrypted_file="${backup_file}.gpg"

    if gpg --encrypt --recipient "$GPG_RECIPIENT" --output "$encrypted_file" "$backup_file" 2>/dev/null; then
        log_success "Backup criptografado: $(du -h "$encrypted_file" | cut -f1)"

        # Remover arquivo não criptografado
        rm -f "$backup_file"

        echo "$encrypted_file"
        return 0
    else
        log_error "Falha na criptografia. Verifique se a chave GPG existe: gpg --list-keys"
        return 1
    fi
}

upload_to_s3() {
    local backup_file="$1"
    local filename=$(basename "$backup_file")

    log_section "Upload para S3"

    # Verificar se aws-cli está instalado
    if ! command -v aws &> /dev/null; then
        log_error "AWS CLI não está instalado"
        log_info "Instale com o instalador oficial (AWS CLI v2):"
        log_info "  sudo apt update && sudo apt install unzip -y"
        log_info "  curl \"https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip\" -o \"awscliv2.zip\""
        log_info "  unzip awscliv2.zip && sudo ./aws/install"
        return 1
    fi

    # Configurar AWS CLI
    configure_aws_cli

    # Configurar endpoint
    configure_s3_endpoint || return 1

    # Montar comando aws s3 cp
    local aws_cmd="aws s3 cp \"$backup_file\" \"s3://$S3_BUCKET/$S3_PREFIX/$filename\""

    if [ -n "$S3_ENDPOINT" ]; then
        aws_cmd="$aws_cmd --endpoint-url=\"$S3_ENDPOINT\""
    fi

    log_info "Enviando para: s3://$S3_BUCKET/$S3_PREFIX/$filename"
    log_info "Provedor: $S3_PROVIDER"

    # Executar upload
    if [ -n "$S3_ENDPOINT" ]; then
        aws s3 cp "$backup_file" "s3://$S3_BUCKET/$S3_PREFIX/$filename" --endpoint-url="$S3_ENDPOINT"
    else
        aws s3 cp "$backup_file" "s3://$S3_BUCKET/$S3_PREFIX/$filename"
    fi

    if [ $? -eq 0 ]; then
        log_success "Upload concluído!"

        # Configurar lifecycle se solicitado
        if [ "$CONFIGURE_LIFECYCLE" = true ]; then
            configure_s3_lifecycle
        fi

        return 0
    else
        log_error "Falha no upload"
        return 1
    fi
}

configure_s3_lifecycle() {
    log_info "Configurando lifecycle policy ($LIFECYCLE_DAYS dias)..."

    local lifecycle_file="/tmp/s3-lifecycle-$$.json"

    cat > "$lifecycle_file" << EOF
{
  "Rules": [
    {
      "Id": "DeleteOldCoolifyBackups",
      "Filter": {
        "Prefix": "$S3_PREFIX/"
      },
      "Status": "Enabled",
      "Expiration": {
        "Days": $LIFECYCLE_DAYS
      }
    }
  ]
}
EOF

    if [ -n "$S3_ENDPOINT" ]; then
        aws s3api put-bucket-lifecycle-configuration \
            --bucket "$S3_BUCKET" \
            --lifecycle-configuration "file://$lifecycle_file" \
            --endpoint-url="$S3_ENDPOINT" 2>/dev/null
    else
        aws s3api put-bucket-lifecycle-configuration \
            --bucket "$S3_BUCKET" \
            --lifecycle-configuration "file://$lifecycle_file" 2>/dev/null
    fi

    if [ $? -eq 0 ]; then
        log_success "Lifecycle configurado: backups expiram em $LIFECYCLE_DAYS dias"
    else
        log_warning "Não foi possível configurar lifecycle (pode não ser suportado pelo provedor)"
    fi

    rm -f "$lifecycle_file"
}

cleanup_local_backup() {
    local backup_file="$1"

    log_section "Limpeza Local"

    if [ -f "$backup_file" ]; then
        rm -f "$backup_file"
        log_success "Arquivo local removido (backup está no S3)"
    fi

    # Limpar backups locais antigos (usa variável configurável)
    local retention_days="${LOCAL_BACKUP_RETENTION_DAYS:-7}"
    log_info "Removendo backups locais >$retention_days dias..."

    local removed=$(find "$BACKUP_BASE_DIR" -name "*.tar.gz*" -type f -mtime +$retention_days -delete -print 2>/dev/null | wc -l)
    if [ "$removed" -gt 0 ]; then
        log_success "$removed backups locais antigos removidos (>$retention_days dias)"
    else
        log_info "Nenhum backup antigo para remover"
    fi
}

################################################################################
# MAIN
################################################################################

main() {
    log_section "VPS Guardian - Backup Coolify para S3"

    # Parse argumentos
    for arg in "$@"; do
        case $arg in
            --help|-h)
                show_help
                ;;
            --config=*)
                CONFIG_FILE="${arg#*=}"
                ;;
            --auto)
                AUTO_MODE=true
                ;;
        esac
    done

    # Carregar ou criar configuração
    if [ -f "$CONFIG_FILE" ]; then
        load_config "$CONFIG_FILE" || exit 1
    else
        if [ "$AUTO_MODE" = true ]; then
            log_error "Modo --auto requer arquivo de configuração"
            log_info "Use: $0 --config=/etc/vpsguardian/backup-s3.conf --auto"
            exit 1
        fi

        interactive_setup
    fi

    # Validar endpoint
    configure_s3_endpoint || exit 1

    # Notificar início
    notify "Backup Iniciado" "Iniciando backup do Coolify para S3" "info"

    # 1. Criar backup do Coolify
    create_coolify_backup || {
        notify "Backup Falhou" "Erro ao criar backup do Coolify" "error"
        exit 1
    }

    # 2. Compactar backup
    BACKUP_FILE=$(compress_backup) || {
        notify "Backup Falhou" "Erro ao compactar backup" "error"
        exit 1
    }

    # 3. Criptografar (se habilitado)
    if [ "$ENCRYPT_BACKUP" = true ]; then
        BACKUP_FILE=$(encrypt_backup "$BACKUP_FILE") || {
            notify "Backup Falhou" "Erro ao criptografar backup" "error"
            exit 1
        }
    fi

    # 4. Upload para S3
    upload_to_s3 "$BACKUP_FILE" || {
        notify "Backup Falhou" "Erro ao enviar para S3" "error"
        exit 1
    }

    # 5. Limpar backup local
    cleanup_local_backup "$BACKUP_FILE"

    # 6. Relatório final
    log_section "BACKUP CONCLUÍDO"

    local final_size=$(du -h "$BACKUP_FILE" 2>/dev/null | cut -f1 || echo "N/A")
    local backup_name=$(basename "$BACKUP_FILE")

    local report="
✅ BACKUP CONCLUÍDO COM SUCESSO

📦 Arquivo: $backup_name
💾 Tamanho: $final_size
🔒 Criptografado: $([ "$ENCRYPT_BACKUP" = true ] && echo "Sim (GPG)" || echo "Não")

☁️  Destino S3:
   Provedor: $S3_PROVIDER
   Bucket: s3://$S3_BUCKET/$S3_PREFIX/
   Região: $S3_REGION

⏰ Retenção: $LIFECYCLE_DAYS dias $([ "$CONFIGURE_LIFECYCLE" = true ] && echo "(automático)" || echo "(manual)")

📊 Conteúdo:
   ✓ Banco de dados PostgreSQL
   ✓ SSH Keys do Coolify
   ✓ Configurações (.env, Nginx)
   ✓ authorized_keys
   ✓ Lista de volumes

📍 Log: $LOG_FILE
"

    echo "$report"

    # Notificar sucesso
    notify "Backup Concluído" "$report" "success"

    log_success "Backup disponível em: s3://$S3_BUCKET/$S3_PREFIX/$backup_name"
}

# Executar
main "$@"
