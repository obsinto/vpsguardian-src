#!/bin/bash
################################################################################
# Script de Alerta de Disco
# Propósito: Verifica espaço em disco e envia alerta se ultrapassar limite
################################################################################

# Carregar biblioteca de notificações
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/notificacoes.sh" 2>/dev/null || true

# Configuração
LIMITE=80
HOSTNAME=$(hostname)

# Obter informações de disco
USO=$(df / 2>/dev/null | awk 'NR==2 {print $5}' | sed 's/%//')
LIVRE=$(df -h / 2>/dev/null | awk 'NR==2 {print $4}')
TOTAL=$(df -h / 2>/dev/null | awk 'NR==2 {print $2}')

# Validar se obteve o valor corretamente
if [ -z "$USO" ] || ! [[ "$USO" =~ ^[0-9]+$ ]]; then
    echo "[ ERRO ] Erro ao obter informações de disco"
    send_discord_simple "❌ Erro no Alerta de Disco" "Não foi possível obter informações de disco." "error"
    exit 1
fi

# Verificar limite e notificar
if [ "$USO" -gt "$LIMITE" ]; then
    echo "[ ALERTA ] Disco em ${USO}% (limite: ${LIMITE}%)"
    echo "  Livre: $LIVRE | Total: $TOTAL"

    # Notificar via webhook
    notify_disk_alert "${USO}%" "$LIVRE" "$TOTAL"

    exit 1
else
    echo "[ OK ] Disco em ${USO}% - OK (limite: ${LIMITE}%)"
    echo "  Livre: $LIVRE | Total: $TOTAL"

    # Opcional: notificar que está OK (descomente se quiser notificação diária)
    # notify_disk_ok "${USO}%" "$LIVRE"

    exit 0
fi
