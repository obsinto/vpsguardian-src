#!/bin/bash
################################################################################
# Script: restaurar-databases.sh
# Propósito: Interface UNIFICADA para restauração de dumps SQL de qualquer origem
#
# Origens suportadas:
#   - Local: Backup em /var/backups/vpsguardian/databases
#   - AWS S3: Bucket S3 configurado
#   - Google Drive: Via rclone
#   - SSH: Servidor remoto via SCP
#
# Uso: ./restaurar-databases.sh [--source=local|s3|gdrive|ssh]
#
# Versão: 1.0.0
################################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh" 2>/dev/null || {
    log_info() { echo -e "\033[0;34m[ INFO ]\033[0m $*"; }
    log_success() { echo -e "\033[0;32m[ OK ]\033[0m $*"; }
    log_error() { echo -e "\033[0;31m[ ERRO ]\033[0m $*"; }
    log_warning() { echo -e "\033[1;33m[ AVISO ]\033[0m $*"; }
    log_section() { echo ""; echo -e "\033[0;34m========== $* ==========\033[0m"; echo ""; }
}

# Carregar configurações
BACKUP_DEST_CONFIG="/opt/vpsguardian/config/backup-destinations.conf"
if [ -f "$BACKUP_DEST_CONFIG" ]; then
    source "$BACKUP_DEST_CONFIG"
fi

### ========== CONFIGURAÇÃO ==========
SOURCE=""
BACKUP_LOCAL_DIR="${DATABASE_BACKUP_DIR:-/var/backups/vpsguardian/databases}"

### ========== PARSE ARGUMENTOS ==========
while [[ $# -gt 0 ]]; do
    case $1 in
        --source=*) SOURCE="${1#*=}"; shift ;;
        --local) SOURCE="local"; shift ;;
        --s3) SOURCE="s3"; shift ;;
        --gdrive) SOURCE="gdrive"; shift ;;
        --ssh) SOURCE="ssh"; shift ;;
        -h|--help)
            cat << 'EOF'
================================================================================
     RESTAURAR BANCOS DE DADOS - Interface Unificada
================================================================================

DESCRIÇÃO:
  Restaura dumps SQL de qualquer origem configurada.
  Suporta: PostgreSQL, MySQL, MongoDB, Redis

USO:
  ./restaurar-databases.sh [--source=ORIGEM]

OPÇÕES:
  --source=local     Restaurar de backup local
  --source=s3        Restaurar de AWS S3
  --source=gdrive    Restaurar de Google Drive (rclone)
  --source=ssh       Restaurar de servidor SSH
  -h, --help         Mostrar esta ajuda

  Sem argumentos: Menu interativo para escolher origem

EXEMPLOS:
  # Menu interativo
  ./restaurar-databases.sh

  # Direto do local
  ./restaurar-databases.sh --source=local

  # Direto do S3
  ./restaurar-databases.sh --source=s3

CONTROLE NO RESTORE:
  Após escolher a origem, você terá controle total:
  - Restaurar TUDO (incluindo Coolify)
  - Restaurar TUDO EXCETO Coolify (recomendado)
  - Escolher dumps específicos

EOF
            exit 0
            ;;
        *)
            log_error "Opção desconhecida: $1"
            exit 1
            ;;
    esac
done

### ========== BANNER ==========
clear
echo ""
echo "=============================================================="
echo "     RESTAURAR BANCOS DE DADOS - Interface Unificada"
echo "=============================================================="
echo ""

### ========== VERIFICAR ROOT ==========
if [ "$EUID" -ne 0 ]; then
    log_error "Este script deve ser executado como root"
    exit 1
fi

### ========== ESCOLHER ORIGEM ==========
if [ -z "$SOURCE" ]; then
    log_section "De onde deseja restaurar?"
    echo ""
    echo "  [1] Backup Local"
    echo "      Restaurar de $BACKUP_LOCAL_DIR"
    echo ""
    echo "  [2] AWS S3"
    if [ -n "$S3_BUCKET" ]; then
        echo "      Bucket configurado: $S3_BUCKET"
    else
        echo "      (Requer configuração)"
    fi
    echo ""
    echo "  [3] Google Drive"
    if [ -n "$GDRIVE_REMOTE_NAME" ]; then
        echo "      Remote configurado: ${GDRIVE_REMOTE_NAME}:${GDRIVE_DIR:-backups}"
    else
        echo "      (Requer rclone configurado)"
    fi
    echo ""
    echo "  [4] Servidor SSH"
    if [ -n "$SSH_REMOTE_SERVER" ]; then
        echo "      Servidor configurado: $SSH_REMOTE_USER@$SSH_REMOTE_SERVER"
    else
        echo "      (Perguntará configuração)"
    fi
    echo ""
    echo "  [0] Cancelar"
    echo ""
    read -p "Escolha uma opção (0-4): " source_choice

    case "$source_choice" in
        1) SOURCE="local" ;;
        2) SOURCE="s3" ;;
        3) SOURCE="gdrive" ;;
        4) SOURCE="ssh" ;;
        0) log_info "Operação cancelada"; exit 0 ;;
        *) log_error "Opção inválida"; exit 1 ;;
    esac
fi

echo ""
log_info "Origem selecionada: $SOURCE"
echo ""

### ========== RESTAURAR DO LOCAL ==========
if [ "$SOURCE" = "local" ]; then
    log_section "Restauração de Backup Local"

    # Perguntar diretório
    echo "Diretórios comuns com dumps:"
    echo "  1) $BACKUP_LOCAL_DIR (padrão)"
    echo "  2) /root/database-dumps-migration"
    echo "  3) Outro diretório"
    echo ""
    read -p "Escolha (1-3): " dir_choice

    case $dir_choice in
        1) DUMP_PATH="$BACKUP_LOCAL_DIR" ;;
        2) DUMP_PATH="/root/database-dumps-migration" ;;
        3)
            read -p "Digite o caminho completo: " DUMP_PATH
            ;;
        *) DUMP_PATH="$BACKUP_LOCAL_DIR" ;;
    esac

    # Verificar se diretório existe
    if [ ! -d "$DUMP_PATH" ]; then
        log_error "Diretório não encontrado: $DUMP_PATH"
        exit 1
    fi

    # Verificar se tem dumps
    DUMP_COUNT=$(find "$DUMP_PATH" -maxdepth 2 \( -name "*.sql.gz" -o -name "*.tar.gz" -o -name "*.rdb.gz" \) 2>/dev/null | wc -l)

    if [ "$DUMP_COUNT" -eq 0 ]; then
        log_error "Nenhum dump encontrado em: $DUMP_PATH"
        exit 1
    fi

    log_success "Encontrados $DUMP_COUNT dump(s) em $DUMP_PATH"
    echo ""

    # Usar script de restore
    RESTORE_SCRIPT="$SCRIPT_DIR/../migrar/restore-databases-dump.sh"
    if [ -x "$RESTORE_SCRIPT" ]; then
        exec "$RESTORE_SCRIPT" --dir="$DUMP_PATH"
    else
        log_error "Script restore-databases-dump.sh não encontrado"
        exit 1
    fi
fi

### ========== RESTAURAR DO S3/GDRIVE/SSH (Origem Remota) ==========
if [ "$SOURCE" = "s3" ] || [ "$SOURCE" = "gdrive" ] || [ "$SOURCE" = "ssh" ]; then
    log_section "Restauração de Origem Remota ($SOURCE)"

    # Usar script existente de restaurar dumps remotos
    RESTORE_REMOTE_SCRIPT="$SCRIPT_DIR/../migrar/restaurar-dumps-remotos.sh"

    if [ -x "$RESTORE_REMOTE_SCRIPT" ]; then
        exec "$RESTORE_REMOTE_SCRIPT" --source="$SOURCE"
    else
        log_error "Script restaurar-dumps-remotos.sh não encontrado"
        exit 1
    fi
fi

log_error "Origem '$SOURCE' não reconhecida"
exit 1
