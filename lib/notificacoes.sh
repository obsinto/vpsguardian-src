#!/bin/bash
################################################################################
# Biblioteca de Notificações - VPS Guardian
# Funções para enviar notificações via Webhook (Discord/Slack) e Email
################################################################################

# Carregar a configuração compartilhada da instalação real. O monitor pode
# fornecê-la já carregada; nunca há um segundo arquivo de webhook.
NOTIF_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NOTIF_ROOT="${MONITOR_INSTALL_ROOT:-${VPSGUARDIAN_ROOT:-$(dirname "$NOTIF_LIB_DIR")}}"
NOTIF_CONFIG_FILE="${VPSGUARDIAN_SHARED_CONFIG_FILE:-$NOTIF_ROOT/config/backup-destinations.conf}"
if [ -f "$NOTIF_CONFIG_FILE" ]; then
    source "$NOTIF_CONFIG_FILE"
fi

# Cores para embeds Discord
COLOR_SUCCESS=3066993    # Verde
COLOR_WARNING=16776960   # Amarelo
COLOR_ERROR=15158332     # Vermelho
COLOR_INFO=3447003       # Azul

# Obter informações do servidor
get_server_info() {
    HOSTNAME=$(hostname)
    SERVER_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
}

################################################################################
# DISCORD WEBHOOK
################################################################################

# Enviar notificação simples ao Discord
# Uso: send_discord_simple "Título" "Mensagem" "cor(success/warning/error/info)"
send_discord_simple() {
    local title="$1"
    local message="$2"
    local type="${3:-info}"

    [ -z "$WEBHOOK_URL" ] && return 0
    [[ ! "$WEBHOOK_URL" == *"discord.com"* ]] && return 0

    get_server_info

    local color
    case "$type" in
        success) color=$COLOR_SUCCESS ;;
        warning) color=$COLOR_WARNING ;;
        error)   color=$COLOR_ERROR ;;
        *)       color=$COLOR_INFO ;;
    esac

    local payload=$(cat <<EOF
{
    "embeds": [{
        "title": "$title",
        "description": "$message",
        "color": $color,
        "footer": {"text": "$HOSTNAME • $TIMESTAMP"}
    }]
}
EOF
)

    curl -s -X POST -H "Content-Type: application/json" -d "$payload" "$WEBHOOK_URL" >/dev/null 2>&1 &
}

# Enviar notificação detalhada ao Discord com campos
# Uso: send_discord_detailed "Título" "Descrição" "cor" "campo1|valor1" "campo2|valor2" ...
send_discord_detailed() {
    local title="$1"
    local description="$2"
    local type="$3"
    shift 3

    [ -z "$WEBHOOK_URL" ] && return 0
    [[ ! "$WEBHOOK_URL" == *"discord.com"* ]] && return 0

    get_server_info

    local color
    case "$type" in
        success) color=$COLOR_SUCCESS ;;
        warning) color=$COLOR_WARNING ;;
        error)   color=$COLOR_ERROR ;;
        *)       color=$COLOR_INFO ;;
    esac

    # Construir campos JSON
    local fields=""
    local first=true
    for field in "$@"; do
        local name=$(echo "$field" | cut -d'|' -f1)
        local value=$(echo "$field" | cut -d'|' -f2)
        local inline=$(echo "$field" | cut -d'|' -f3)
        inline=${inline:-true}

        if [ "$first" = true ]; then
            first=false
        else
            fields="$fields,"
        fi

        fields="$fields{\"name\": \"$name\", \"value\": \"$value\", \"inline\": $inline}"
    done

    local payload=$(cat <<EOF
{
    "embeds": [{
        "title": "$title",
        "description": "$description",
        "color": $color,
        "fields": [$fields],
        "footer": {"text": "$HOSTNAME • $TIMESTAMP"}
    }]
}
EOF
)

    curl -s -X POST -H "Content-Type: application/json" -d "$payload" "$WEBHOOK_URL" >/dev/null 2>&1 &
}

################################################################################
# NOTIFICAÇÕES DE BACKUP
################################################################################

# Notificar início de backup
# Uso: notify_backup_start "tipo" "detalhes"
notify_backup_start() {
    local type="$1"
    local details="$2"

    send_discord_simple "🔄 Backup Iniciado: $type" "$details" "info"
}

# Notificar conclusão de backup com sucesso
# Uso: notify_backup_success "tipo" "tamanho" "duracao" "destino" "detalhes_extras"
notify_backup_success() {
    local type="$1"
    local size="$2"
    local duration="$3"
    local destination="$4"
    local extras="$5"

    local desc="Backup concluído com sucesso!"
    [ -n "$extras" ] && desc="$desc\n$extras"

    send_discord_detailed "✅ Backup Concluído: $type" "$desc" "success" \
        "📦 Tamanho|$size" \
        "⏱️ Duração|$duration" \
        "📍 Destino|$destination"
}

# Notificar falha de backup
# Uso: notify_backup_error "tipo" "erro"
notify_backup_error() {
    local type="$1"
    local error="$2"

    send_discord_detailed "❌ Falha no Backup: $type" "O backup falhou durante a execução." "error" \
        "🔴 Erro|$error|false"
}

################################################################################
# NOTIFICAÇÕES DE MANUTENÇÃO
################################################################################

# Notificar início de manutenção
notify_maintenance_start() {
    send_discord_simple "🔧 Manutenção Iniciada" "Executando manutenção preventiva do sistema..." "info"
}

# Notificar conclusão de manutenção
# Uso: notify_maintenance_success "duracao" "ações_realizadas"
notify_maintenance_success() {
    local duration="$1"
    local actions="$2"

    send_discord_detailed "✅ Manutenção Concluída" "Manutenção preventiva finalizada com sucesso." "success" \
        "⏱️ Duração|$duration" \
        "📋 Ações|$actions|false"
}

################################################################################
# NOTIFICAÇÕES DE ALERTA
################################################################################

# Notificar alerta de disco
# Uso: notify_disk_alert "uso_percent" "espaco_livre" "espaco_total"
notify_disk_alert() {
    local usage="$1"
    local free="$2"
    local total="$3"

    local type="warning"
    local emoji="⚠️"
    if [ "${usage%\%}" -ge 90 ]; then
        type="error"
        emoji="🚨"
    fi

    send_discord_detailed "$emoji Alerta de Disco" "O espaço em disco está ficando baixo!" "$type" \
        "📊 Uso|$usage" \
        "💾 Livre|$free" \
        "📀 Total|$total"
}

# Notificar disco OK
notify_disk_ok() {
    local usage="$1"
    local free="$2"

    send_discord_simple "✅ Disco OK" "Espaço em disco dentro do normal.\n**Uso:** $usage | **Livre:** $free" "success"
}

################################################################################
# NOTIFICAÇÕES DE LIMPEZA
################################################################################

# Notificar limpeza de backups
# Uso: notify_cleanup_success "tipo" "arquivos_removidos" "espaco_liberado"
notify_cleanup_success() {
    local type="$1"
    local files_removed="$2"
    local space_freed="$3"

    send_discord_detailed "🗑️ Limpeza de Backups: $type" "Backups antigos removidos com sucesso." "success" \
        "📁 Arquivos|$files_removed removidos" \
        "💾 Liberado|$space_freed"
}

# Notificar limpeza remota de backups S3/R2
# Uso: notify_s3_cleanup_result "bucket" "prefixo" "estrategia" "removidos" "falhas" "detalhes" "espaco_liberado"
notify_s3_cleanup_result() {
    local bucket="$1"
    local prefix="$2"
    local strategy="$3"
    local removed="$4"
    local failed="$5"
    local details="$6"
    local space_freed="${7:-0 B}"

    [ -z "$details" ] && details="Nenhum detalhe disponível"
    if [ "${#details}" -gt 900 ]; then
        details="${details:0:900}\\n..."
    fi

    local title="🗑️ Limpeza S3/R2"
    local message_type="success"
    local description="Backups antigos removidos do destino remoto."

    if [ "${failed:-0}" -gt 0 ]; then
        title="⚠️ Limpeza S3/R2 com avisos"
        message_type="warning"
        description="A limpeza remota terminou com falhas em alguns objetos."
    fi

    send_discord_detailed "$title" "$description" "$message_type" \
        "🪣 Bucket|$bucket" \
        "📁 Prefixo|${prefix:-/}" \
        "📋 Estratégia|$strategy" \
        "🗑️ Removidos|$removed" \
        "💾 Liberado|$space_freed" \
        "⚠️ Falhas|$failed" \
        "📝 Log|$details|false"
}

################################################################################
# NOTIFICAÇÕES DE UPLOAD
################################################################################

# Notificar upload concluído
# Uso: notify_upload_success "arquivo" "destino" "tamanho"
notify_upload_success() {
    local file="$1"
    local destination="$2"
    local size="$3"

    send_discord_detailed "☁️ Upload Concluído" "Backup enviado para destino remoto." "success" \
        "📁 Arquivo|$file" \
        "📍 Destino|$destination" \
        "📦 Tamanho|$size"
}

# Notificar falha de upload
notify_upload_error() {
    local file="$1"
    local destination="$2"
    local error="$3"

    send_discord_detailed "❌ Falha no Upload" "Não foi possível enviar o backup." "error" \
        "📁 Arquivo|$file" \
        "📍 Destino|$destination" \
        "🔴 Erro|$error|false"
}

################################################################################
# NOTIFICAÇÕES DE RESTORE
################################################################################

# Notificar restore concluído
notify_restore_success() {
    local type="$1"
    local details="$2"

    send_discord_detailed "✅ Restore Concluído: $type" "Dados restaurados com sucesso." "success" \
        "📋 Detalhes|$details|false"
}

# Notificar falha de restore
notify_restore_error() {
    local type="$1"
    local error="$2"

    send_discord_detailed "❌ Falha no Restore: $type" "Não foi possível restaurar os dados." "error" \
        "🔴 Erro|$error|false"
}

################################################################################
# MONITOR PREVENTIVO (M5)
################################################################################

# Envia um incidente do Monitor Preventivo reutilizando o MESMO webhook Discord
# (variável WEBHOOK_URL) e o mesmo formato de embed já usado pelo projeto.
#
# Diferente de send_discord_simple/send_discord_detailed (que enviam em segundo
# plano e sempre retornam 0), esta função envia de forma SÍNCRONA e com timeout,
# devolvendo o resultado real — necessário para que a máquina de estados do
# monitor saiba se o incidente foi entregue (cooldown/recovery corretos).
#
# NÃO cria novo webhook, token ou cliente: apenas reutiliza WEBHOOK_URL.
# A URL do webhook nunca é impressa (stderr do curl é descartado).
#
# Uso: notify_monitor_incident <type> <title> <description> [ "nome|valor|inline" ... ]
#   type: success | warning | error | info
# Retorno: 0 = enviado (SUCCESS), 1 = falha (FAILED), 2 = sem canal (DISABLED)
notify_monitor_incident() {
    local type="$1"
    local title="$2"
    local description="$3"
    shift 3

    # Sem webhook configurado ou webhook não-Discord => desabilitado (não é erro)
    [ -z "$WEBHOOK_URL" ] && return 2
    [[ ! "$WEBHOOK_URL" == *"discord.com"* ]] && return 2

    local color
    case "$type" in
        success) color=$COLOR_SUCCESS ;;
        warning) color=$COLOR_WARNING ;;
        error)   color=$COLOR_ERROR ;;
        *)       color=$COLOR_INFO ;;
    esac

    # Campos opcionais (mesmo formato "nome|valor|inline" de send_discord_detailed)
    local fields="" first=true field name value inline
    for field in "$@"; do
        name=$(echo "$field" | cut -d'|' -f1)
        value=$(echo "$field" | cut -d'|' -f2)
        inline=$(echo "$field" | cut -d'|' -f3)
        inline=${inline:-true}
        if [ "$first" = true ]; then first=false; else fields="$fields,"; fi
        fields="$fields{\"name\": \"$name\", \"value\": \"$value\", \"inline\": $inline}"
    done

    # Cabeçalho: hostname + timestamp locais (sem chamada externa a ifconfig.me)
    local host_name timestamp
    host_name=$(hostname 2>/dev/null)
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    local payload
    payload=$(cat <<EOF
{
    "embeds": [{
        "title": "$title",
        "description": "$description",
        "color": $color,
        "fields": [$fields],
        "footer": {"text": "$host_name • $timestamp"}
    }]
}
EOF
)

    # Envio síncrono, com timeout e --fail (HTTP >=400 conta como falha).
    local http_timeout="${MONITOR_ALERT_HTTP_TIMEOUT:-10}"
    if curl -sf -o /dev/null --max-time "$http_timeout" \
        -X POST -H "Content-Type: application/json" \
        -d "$payload" "$WEBHOOK_URL" 2>/dev/null; then
        return 0
    fi
    return 1
}

################################################################################
# SLACK WEBHOOK (básico)
################################################################################

send_slack_notification() {
    local title="$1"
    local message="$2"
    local type="${3:-info}"

    [ -z "$WEBHOOK_URL" ] && return 0
    [[ ! "$WEBHOOK_URL" == *"slack.com"* ]] && return 0

    get_server_info

    local color
    case "$type" in
        success) color="good" ;;
        warning) color="warning" ;;
        error)   color="danger" ;;
        *)       color="#3498db" ;;
    esac

    local payload=$(cat <<EOF
{
    "attachments": [{
        "color": "$color",
        "title": "$title",
        "text": "$message",
        "footer": "$HOSTNAME • $TIMESTAMP"
    }]
}
EOF
)

    curl -s -X POST -H "Content-Type: application/json" -d "$payload" "$WEBHOOK_URL" >/dev/null 2>&1 &
}

################################################################################
# EMAIL (se configurado)
################################################################################

send_email_notification() {
    local subject="$1"
    local body="$2"

    [ -z "$NOTIFICATION_EMAIL" ] && return 0

    # Verificar se mail está disponível
    if command -v mail &> /dev/null; then
        echo -e "$body" | mail -s "[VPS Guardian] $subject" "$NOTIFICATION_EMAIL" 2>/dev/null &
    fi
}

# Exporta apenas a nova função do monitor (as demais mantêm o comportamento atual)
export -f notify_monitor_incident 2>/dev/null || true
