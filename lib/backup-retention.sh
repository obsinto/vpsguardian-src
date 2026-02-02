#!/bin/bash
################################################################################
# VPS Guardian - Biblioteca de Retenção de Backups
# Funções compartilhadas para aplicar políticas de retenção
################################################################################

# Carregar configuração se existir
if [ -f "/etc/vpsguardian/retention.conf" ]; then
    source "/etc/vpsguardian/retention.conf"
fi

# Configurações padrão
DEFAULT_RETENTION_STRATEGY="${RETENTION_STRATEGY:-gfs}"
DEFAULT_RETENTION_DAYS="${RETENTION_DAYS:-30}"
DEFAULT_RETENTION_COUNT="${RETENTION_COUNT:-10}"

################################################################################
# Aplicar retenção após backup
################################################################################

apply_retention() {
    local backup_dir="$1"
    local strategy="${2:-$DEFAULT_RETENTION_STRATEGY}"
    local silent="${3:-false}"

    # Verificar se diretório existe
    if [ ! -d "$backup_dir" ]; then
        return 0
    fi

    # Verificar se há backups
    local backup_count=$(find "$backup_dir" -name "*.tar.gz*" -type f 2>/dev/null | wc -l)
    if [ "$backup_count" -eq 0 ]; then
        return 0
    fi

    # Construir comando de limpeza
    local cleanup_cmd="/opt/vpsguardian/scripts-auxiliares/limpar-backups-antigos.sh"
    local cleanup_args="--dir=$backup_dir --strategy=$strategy --auto"

    case "$strategy" in
        simple)
            cleanup_args="$cleanup_args --days=$DEFAULT_RETENTION_DAYS"
            ;;
        count)
            cleanup_args="$cleanup_args --count=$DEFAULT_RETENTION_COUNT"
            ;;
    esac

    # Executar limpeza
    if [ "$silent" = "true" ]; then
        $cleanup_cmd $cleanup_args >/dev/null 2>&1
    else
        if [ -f "$cleanup_cmd" ]; then
            $cleanup_cmd $cleanup_args
        fi
    fi
}

################################################################################
# Obter política de retenção configurada
################################################################################

get_retention_policy() {
    cat <<EOF
Política de Retenção Atual:
  Estratégia: $DEFAULT_RETENTION_STRATEGY
  $(case "$DEFAULT_RETENTION_STRATEGY" in
    simple)
        echo "Dias de retenção: $DEFAULT_RETENTION_DAYS"
        ;;
    count)
        echo "Backups mantidos: $DEFAULT_RETENTION_COUNT"
        ;;
    gfs)
        echo "7 diários + 4 semanais + 12 mensais"
        ;;
  esac)

Configuração: /etc/vpsguardian/retention.conf
EOF
}

################################################################################
# Exportar funções
################################################################################

export -f apply_retention get_retention_policy
