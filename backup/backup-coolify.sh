#!/bin/bash
################################################################################
# Script de Backup Completo para Coolify
# Complementa o script de manutenção
# Versão: 2.0 - Refatorado com bibliotecas compartilhadas
# Compatível com o padrão de migração do Coolify
################################################################################

# O arquivo final contém .env, APP_KEY e chaves SSH. Não permitir que a umask
# do usuário torne esses dados legíveis por outros usuários do host.
umask 077

# Carregar bibliotecas compartilhadas
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../lib/notificacoes.sh"

# Inicializar script (cria diretórios, configura log)
init_script

# Marcar início para calcular duração
BACKUP_START_TIME=$(date +%s)

# Configurações (usa variáveis de config/default.conf)
BACKUP_BASE_DIR="${COOLIFY_BACKUP_DIR:-/var/backups/vpsguardian/coolify}"
BACKUP_DIR="$BACKUP_BASE_DIR/$(date +%Y%m%d_%H%M%S)"
BACKUP_DEST_CONFIG="${VPSGUARDIAN_SHARED_CONFIG_FILE:-$VPSGUARDIAN_ROOT/config/backup-destinations.conf}"
BACKUP_FATAL_ERRORS=0
BACKUP_WARNINGS=0
DB_STATUS="✗"
SSH_KEYS_STATUS="—"
ENV_STATUS="✗"
NGINX_STATUS="—"
AUTHORIZED_KEYS_STATUS="—"
PROXY_STATUS="—"
VOLUMES_LIST_STATUS="✗"
# Carregar biblioteca de retenção
if [ -f "$SCRIPT_DIR/../lib/backup-retention.sh" ]; then
    source "$SCRIPT_DIR/../lib/backup-retention.sh"
fi

RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-30}"

# Impedir dois backups completos concorrentes. O lock é liberado
# automaticamente quando o descritor é fechado no fim do processo.
if command -v flock >/dev/null 2>&1; then
    mkdir -p "$(dirname "$BACKUP_LOCK_FILE")"
    exec 9>"$BACKUP_LOCK_FILE"
    if ! flock -n 9; then
        log_error "Já existe um backup do VPS Guardian em execução"
        exit 4
    fi
else
    log_warning "flock não encontrado; proteção contra backup concorrente indisponível"
fi

# Diretórios e arquivos do Coolify
COOLIFY_DATA_DIR="${COOLIFY_DATA_DIR:-/data/coolify}"
COOLIFY_SOURCE_DIR="$COOLIFY_DATA_DIR/source"
COOLIFY_SSH_DIR="$COOLIFY_DATA_DIR/ssh/keys"
COOLIFY_ENV_FILE="$COOLIFY_SOURCE_DIR/.env"


################################################################################
# INÍCIO DO BACKUP
################################################################################

log_section "VPS Guardian - Backup Coolify"

# Notificar início
notify_backup_start "Coolify" "Iniciando backup de SSH keys, .env, certificados e banco de dados..."

# Verificar se Coolify está instalado
check_docker || exit 1
check_coolify || exit 1
check_container_running "coolify-db" || exit 1
log_success "Coolify detectado e rodando"

# Criar diretório de backup
ensure_directory "$BACKUP_DIR" 700
log_info "Diretório de backup criado: $BACKUP_DIR"

################################################################################
# 1. BACKUP DO BANCO DE DADOS
################################################################################

log_section "Backup do Banco de Dados PostgreSQL"

DB_BACKUP_FILE="$BACKUP_DIR/coolify-db-$(date +%s).dmp"

if docker exec coolify-db pg_dump -U coolify -d coolify -F c -f /tmp/backup.dmp 2>/dev/null &&
   docker cp coolify-db:/tmp/backup.dmp "$DB_BACKUP_FILE" >/dev/null 2>&1 &&
   [ -s "$DB_BACKUP_FILE" ]; then
    docker exec coolify-db rm -f /tmp/backup.dmp >/dev/null 2>&1 || true
    DB_SIZE=$(du -h "$DB_BACKUP_FILE" | cut -f1)
    DB_STATUS="✓"
    log_success "Banco de dados backupeado: $DB_SIZE"
else
    docker exec coolify-db rm -f /tmp/backup.dmp >/dev/null 2>&1 || true
    rm -f "$DB_BACKUP_FILE"
    BACKUP_FATAL_ERRORS=$((BACKUP_FATAL_ERRORS + 1))
    log_error "Falha ao fazer backup do banco de dados"
    notify_backup_error "Coolify" "Falha ao criar dump do PostgreSQL"
fi

################################################################################
# 2. BACKUP DAS SSH KEYS
################################################################################

log_section "Backup das SSH Keys"

if [ -d "$COOLIFY_SSH_DIR" ]; then
    if cp -r "$COOLIFY_SSH_DIR" "$BACKUP_DIR/ssh-keys"; then
        KEYS_COUNT=$(find "$BACKUP_DIR/ssh-keys" -type f | wc -l)
        SSH_KEYS_STATUS="✓"
        log_success "SSH Keys backupeadas: $KEYS_COUNT arquivos"
    else
        BACKUP_WARNINGS=$((BACKUP_WARNINGS + 1))
        SSH_KEYS_STATUS="✗"
        log_warning "Falha ao copiar as SSH keys do Coolify"
    fi
else
    BACKUP_WARNINGS=$((BACKUP_WARNINGS + 1))
    log_warning "Diretório de SSH keys não encontrado: $COOLIFY_SSH_DIR"
fi

################################################################################
# 3. BACKUP DO .ENV E CONFIGURAÇÕES
################################################################################

log_section "Backup das Configurações"

if [ -f "$COOLIFY_ENV_FILE" ]; then
    APP_KEY=$(grep "^APP_KEY=" "$COOLIFY_ENV_FILE" | head -n1 | cut -d '=' -f2-)
    if [ -n "$APP_KEY" ] && cp "$COOLIFY_ENV_FILE" "$BACKUP_DIR/.env"; then
        printf 'APP_KEY=%s\n' "$APP_KEY" > "$BACKUP_DIR/app-key.txt"
        ENV_STATUS="✓"
        log_success "Arquivo .env e APP_KEY backupeados"
    else
        BACKUP_FATAL_ERRORS=$((BACKUP_FATAL_ERRORS + 1))
        log_error "Arquivo .env não contém uma APP_KEY válida ou não pôde ser copiado"
    fi
else
    BACKUP_FATAL_ERRORS=$((BACKUP_FATAL_ERRORS + 1))
    log_error "Arquivo .env não encontrado: $COOLIFY_ENV_FILE"
fi

# Backup de outras configurações importantes
if [ -d "/etc/nginx" ]; then
    if cp -r /etc/nginx "$BACKUP_DIR/nginx-config"; then
        NGINX_STATUS="✓"
        log_success "Configurações do Nginx backupeadas"
    else
        BACKUP_WARNINGS=$((BACKUP_WARNINGS + 1))
        NGINX_STATUS="✗"
    fi
fi

# Backup do authorized_keys (importante para acesso SSH)
if [ -f "/root/.ssh/authorized_keys" ]; then
    if cp /root/.ssh/authorized_keys "$BACKUP_DIR/authorized_keys"; then
        AUTHORIZED_KEYS_STATUS="✓"
        log_success "Arquivo authorized_keys backupeado"
    else
        BACKUP_WARNINGS=$((BACKUP_WARNINGS + 1))
        AUTHORIZED_KEYS_STATUS="✗"
    fi
fi

# Backup das configurações do proxy (certificados SSL, configs personalizadas)
COOLIFY_PROXY_DIR="$COOLIFY_DATA_DIR/proxy"
if [ -d "$COOLIFY_PROXY_DIR" ]; then
    log_info "Backupeando configurações do proxy..."
    if ! cp -r "$COOLIFY_PROXY_DIR" "$BACKUP_DIR/proxy-config"; then
        BACKUP_WARNINGS=$((BACKUP_WARNINGS + 1))
        PROXY_STATUS="✗"
        log_warning "Falha ao copiar configurações do proxy"
    else
        PROXY_STATUS="✓"

        # Contar arquivos importantes
        CERTS_COUNT=$(find "$BACKUP_DIR/proxy-config" \( -name "*.crt" -o -name "*.pem" -o -name "*.key" \) | wc -l)
        CONFIGS_COUNT=$(find "$BACKUP_DIR/proxy-config" \( -name "*.conf" -o -name "*.toml" -o -name "*.yaml" \) | wc -l)

        if [ "$CERTS_COUNT" -gt 0 ] || [ "$CONFIGS_COUNT" -gt 0 ]; then
            log_success "Configurações do proxy backupeadas (certificados: $CERTS_COUNT, configs: $CONFIGS_COUNT)"
        else
            log_info "Configurações do proxy backupeadas (diretório vazio ou padrão)"
        fi
    fi
else
    log_warning "Diretório de proxy não encontrado: $COOLIFY_PROXY_DIR (pode estar usando configuração padrão)"
fi

################################################################################
# 4. BACKUP DE VOLUMES DOCKER (OPCIONAL)
################################################################################

log_section "Volumes Docker"

# Criar arquivo com lista de volumes
if docker volume ls --format '{{.Name}}' > "$BACKUP_DIR/volumes-list.txt"; then
    VOLUMES_COUNT=$(wc -l < "$BACKUP_DIR/volumes-list.txt")
    VOLUMES_LIST_STATUS="✓"
    log_info "Total de volumes Docker: $VOLUMES_COUNT"
else
    BACKUP_WARNINGS=$((BACKUP_WARNINGS + 1))
    rm -f "$BACKUP_DIR/volumes-list.txt"
    log_warning "Não foi possível listar os volumes Docker"
fi

# Se quiser fazer backup de volumes específicos, descomente abaixo
# IMPORTANTE: Isso pode consumir MUITO espaço em disco
#
# mkdir -p "$BACKUP_DIR/volumes"
# while IFS= read -r volume; do
#     # Pular volumes do sistema
#     if [[ "$volume" =~ ^(coolify|postgres) ]]; then
#         continue
#     fi
#
#     log_info "Backupeando volume: $volume"
#     docker run --rm \
#       -v "$volume":/volume \
#       -v "$BACKUP_DIR/volumes":/backup \
#       busybox \
#       tar czf "/backup/${volume}.tar.gz" -C /volume .
# done < "$BACKUP_DIR/volumes-list.txt"

log_info "Backup de volumes desativado (economizar espaço). Habilite se necessário."

################################################################################
# 5. INFORMAÇÕES DO SISTEMA
################################################################################

log_section "Informações do Sistema"

cat > "$BACKUP_DIR/system-info.txt" <<EOF
Sistema Operacional: $(lsb_release -d | cut -f2)
Kernel: $(uname -r)
Docker Version: $(docker --version)
Espaço em disco: $(df -h / | tail -1 | awk '{print $5 " usado de " $2}')
Memória: $(free -h | grep Mem | awk '{print $3 " usado de " $2}')
EOF

log_success "Informações do sistema coletadas"

################################################################################
# 6. CRIAR ARQUIVO DE METADADOS
################################################################################

log_section "Arquivo de Metadados"

COOLIFY_VERSION=$(docker ps --filter "name=coolify" --format '{{.Image}}' | grep coollabsio/coolify | head -n1)

cat > "$BACKUP_DIR/backup-info.txt" <<EOF
╔════════════════════════════════════════════════════════════╗
║              BACKUP DO COOLIFY                             ║
╚════════════════════════════════════════════════════════════╝

📅 Data: $(date '+%Y-%m-%d %H:%M:%S')
🖥️  Hostname: $(hostname)
🐳 Versão do Coolify: $COOLIFY_VERSION

📦 CONTEÚDO DO BACKUP:
  $DB_STATUS Banco de dados PostgreSQL (dump completo no formato custom)
  $SSH_KEYS_STATUS SSH Keys do Coolify (/data/coolify/ssh/keys)
  $ENV_STATUS Arquivo .env e APP_KEY extraída
  $AUTHORIZED_KEYS_STATUS Arquivo authorized_keys do root
  $NGINX_STATUS Configurações do Nginx
  $PROXY_STATUS Configurações do Proxy (certificados SSL, configs personalizadas)
  $VOLUMES_LIST_STATUS Lista de volumes Docker
  ✓ Informações do sistema

Erros fatais: $BACKUP_FATAL_ERRORS
Avisos: $BACKUP_WARNINGS

💾 Tamanho total: $(du -sh "$BACKUP_DIR" | cut -f1)

🔄 COMO RESTAURAR ESTE BACKUP:

1. Instale o Coolify no novo servidor:
   curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash

2. Pare os containers (exceto o banco):
   docker ps --filter name=coolify --format '{{.Names}}' | grep -v 'coolify-db' | xargs docker stop

3. Restaure o banco de dados:
   cat coolify-db-*.dmp | docker exec -i coolify-db pg_restore --verbose --clean --no-acl --no-owner -U coolify -d coolify

4. Copie as SSH keys:
   cp -r ssh-keys/* /data/coolify/ssh/keys/

5. Restaure o authorized_keys:
   cat authorized_keys >> /root/.ssh/authorized_keys

6. Atualize o .env com a APP_KEY:
   cd /data/coolify/source
   sed -i '/^APP_PREVIOUS_KEYS=/d' .env
   echo 'APP_PREVIOUS_KEYS=<APP_KEY_DO_BACKUP>' >> .env

7. Execute o install script novamente:
   curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash

📋 Para mais detalhes, consulte: https://coolify.io/docs

EOF

log_success "Arquivo de metadados criado"

if [ "$BACKUP_FATAL_ERRORS" -gt 0 ]; then
    log_error "Backup incompleto: $BACKUP_FATAL_ERRORS componente(s) obrigatório(s) falharam"
    log_error "Dados parciais preservados em: $BACKUP_DIR"
    notify_backup_error "Coolify" "Backup incompleto; dados parciais em $BACKUP_DIR"
    exit 1
fi

################################################################################
# 7. COMPACTAR BACKUP
################################################################################

log_section "Compactação"

cd "$BACKUP_BASE_DIR"
BACKUP_BASENAME=$(basename "$BACKUP_DIR")
tar -czf "${BACKUP_BASENAME}.tar.gz" "$BACKUP_BASENAME" 2>/dev/null

if [ $? -eq 0 ] && [ -s "${BACKUP_BASENAME}.tar.gz" ]; then
    chmod 0600 "${BACKUP_BASENAME}.tar.gz"
    COMPRESSED_SIZE=$(du -h "${BACKUP_BASENAME}.tar.gz" | cut -f1)
    log_success "Backup compactado: $COMPRESSED_SIZE"

    # Remover diretório não compactado para economizar espaço
    rm -rf "$BACKUP_DIR"
    log_info "Diretório descompactado removido"

    BACKUP_FILE_PATH="$BACKUP_BASE_DIR/${BACKUP_BASENAME}.tar.gz"
else
    log_error "Falha ao compactar backup"
    notify_backup_error "Coolify" "Falha ao compactar o backup"
    exit 1
fi

################################################################################
# 8. ENVIAR PARA DESTINOS REMOTOS (S3, Google Drive, SSH)
################################################################################

log_section "Upload para Destinos Remotos"

# Carregar configurações de destino da instalação real
if [ -f "$BACKUP_DEST_CONFIG" ]; then
    source "$BACKUP_DEST_CONFIG"
fi

# Verificar se há destinos remotos habilitados
HAS_REMOTE_DEST=false
[ "${BACKUP_DEST_SSH:-false}" = "true" ] && HAS_REMOTE_DEST=true
[ "${BACKUP_DEST_GOOGLE_DRIVE:-false}" = "true" ] && HAS_REMOTE_DEST=true
[ "${BACKUP_DEST_AWS_S3:-false}" = "true" ] && HAS_REMOTE_DEST=true

if [ "$HAS_REMOTE_DEST" = "true" ] && [ -n "$BACKUP_FILE_PATH" ] && [ -f "$BACKUP_FILE_PATH" ]; then
    log_info "Enviando backup para destinos configurados..."

    # Chamar script de upload com prefixo 'coolify' para separar dos backups de databases
    if [ -x "$SCRIPT_DIR/backup-destinos.sh" ]; then
        "$SCRIPT_DIR/backup-destinos.sh" "$BACKUP_FILE_PATH" --dest=all --prefix=coolify
        UPLOAD_RESULT=$?

        if [ $UPLOAD_RESULT -eq 0 ]; then
            log_success "Backup enviado para destinos remotos"
            UPLOAD_SUCCESS=true
        else
            log_warning "Alguns uploads falharam (código: $UPLOAD_RESULT)"
            UPLOAD_SUCCESS=false
        fi
    else
        log_warning "Script backup-destinos.sh não encontrado, backup mantido apenas localmente"
        UPLOAD_SUCCESS=false
    fi
else
    if [ "$HAS_REMOTE_DEST" != "true" ]; then
        log_info "Nenhum destino remoto configurado"
        log_info "Configure em: Menu → Configuração → Configurar Destinos de Backup"
    elif [ -z "$BACKUP_FILE_PATH" ]; then
        log_warning "Backup não foi criado, upload ignorado"
    fi
    UPLOAD_SUCCESS=false
fi

################################################################################
# 9. LIMPEZA DE BACKUPS ANTIGOS
################################################################################

log_section "Limpeza de Backups Antigos"

if type apply_retention &>/dev/null; then
    # Usar biblioteca de retenção (suporta GFS, simple, count)
    BACKUPS_ANTES=$(find "$BACKUP_BASE_DIR" -name "*.tar.gz" 2>/dev/null | wc -l)
    apply_retention "$BACKUP_BASE_DIR" "$DEFAULT_RETENTION_STRATEGY" true
    BACKUPS_DEPOIS=$(find "$BACKUP_BASE_DIR" -name "*.tar.gz" 2>/dev/null | wc -l)
    BACKUPS_REMOVIDOS=$((BACKUPS_ANTES - BACKUPS_DEPOIS))

    if [ "$BACKUPS_REMOVIDOS" -gt 0 ]; then
        log_success "$BACKUPS_REMOVIDOS backups antigos removidos (política: $DEFAULT_RETENTION_STRATEGY)"
    else
        log_info "Nenhum backup antigo para remover"
    fi
else
    # Fallback para limpeza simples (compatibilidade)
    BACKUPS_REMOVIDOS=$(find "$BACKUP_BASE_DIR" -name "*.tar.gz" -mtime +$RETENTION_DAYS -delete -print | wc -l)

    if [ "$BACKUPS_REMOVIDOS" -gt 0 ]; then
        log_success "$BACKUPS_REMOVIDOS backups antigos removidos (>${RETENTION_DAYS} dias)"
    else
        log_info "Nenhum backup antigo para remover"
    fi
fi

################################################################################
# 9. RELATÓRIO FINAL
################################################################################

log_section "BACKUP LOCAL CONCLUÍDO"

BACKUP_FINAL="$BACKUP_FILE_PATH ($COMPRESSED_SIZE)"

RELATORIO="
📦 RELATÓRIO DE BACKUP - $(hostname)
Data: $(date '+%d/%m/%Y %H:%M')

✅ Backup criado: $BACKUP_FINAL

📊 Conteúdo:
  - Banco de dados PostgreSQL: $DB_STATUS
  - SSH Keys: $SSH_KEYS_STATUS
  - Configuração .env e APP_KEY: $ENV_STATUS
  - Nginx: $NGINX_STATUS
  - Proxy: $PROXY_STATUS
  - authorized_keys: $AUTHORIZED_KEYS_STATUS
  - Lista de volumes: $VOLUMES_LIST_STATUS

🗄️  Backups mantidos: $(ls -1 "$BACKUP_BASE_DIR"/*.tar.gz 2>/dev/null | wc -l)
🗑️  Backups removidos: $BACKUPS_REMOVIDOS

📍 Localização: $BACKUP_BASE_DIR
📋 Log completo: $LOG_FILE

⚠️  IMPORTANTE:
  - Baixe este backup para outro local seguro
  - Teste a restauração periodicamente
  - Mantenha backups off-site (outro servidor/cloud)
"

echo "$RELATORIO" | tee -a "$LOG_FILE"

# Calcular duração
BACKUP_END_TIME=$(date +%s)
BACKUP_DURATION=$((BACKUP_END_TIME - BACKUP_START_TIME))
BACKUP_DURATION_FMT=$(printf '%02d:%02d:%02d' $((BACKUP_DURATION/3600)) $((BACKUP_DURATION%3600/60)) $((BACKUP_DURATION%60)))

# Um destino remoto configurado faz parte do resultado solicitado. Não emitir
# sucesso global quando o arquivo local existe, mas o envio falhou.
if [ "$HAS_REMOTE_DEST" = "true" ] && [ "$UPLOAD_SUCCESS" != "true" ]; then
    notify_backup_error "Coolify" "Backup local criado, mas um ou mais uploads remotos falharam"
    log_error "Backup local válido, porém o envio remoto não foi concluído"
    exit 1
fi

notify_backup_success "Coolify" "$COMPRESSED_SIZE" "$BACKUP_DURATION_FMT" "Local: $BACKUP_BASE_DIR" \
    "PostgreSQL e .env verificados; avisos opcionais: $BACKUP_WARNINGS"

exit 0
