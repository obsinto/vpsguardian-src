#!/bin/bash
################################################################################
# Script: backup-volume-interativo.sh
# Propósito: Fazer backup de um volume Docker específico (versão interativa)
# Uso: ./backup-volume-interativo.sh [volume-name] [backup-dir]
################################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Diretório padrão padronizado com o resto do sistema
DEFAULT_BACKUP_DIR="/var/backups/vpsguardian/volumes"

# Carregar configurações de destino
BACKUP_DEST_CONFIG="/opt/vpsguardian/config/backup-destinations.conf"
if [ -f "$BACKUP_DEST_CONFIG" ]; then
    source "$BACKUP_DEST_CONFIG"
fi

# === INPUT PROMPTS ===

# Se o volume não foi passado como parâmetro, perguntar
if [ -z "$1" ]; then
    read -p "[ Backup Agent ] [ INPUT ] Please enter the Docker volume name to back up: " VOLUME_NAME
else
    VOLUME_NAME="$1"
fi

# Informar o volume selecionado
echo "[ Backup Agent ] [ INFO ] Backup Volume is set to $VOLUME_NAME"

# Validar se o volume existe
if ! docker volume ls --quiet | grep -q "^$VOLUME_NAME$"; then
    echo "[ Backup Agent ] [ ERROR ] Volume '$VOLUME_NAME' doesn't exist, aborting backup."
    echo "[ Backup Agent ] [ ERROR ] Backup Failed!"
    exit 1
else
    echo "[ Backup Agent ] [ INFO ] Volume '$VOLUME_NAME' exists, continuing backup..."
fi

# Se o diretório não foi passado como parâmetro, perguntar
if [ -z "$2" ]; then
    read -p "[ Backup Agent ] [ INPUT ] Please enter the directory to save the backup (Optional: press enter to use $DEFAULT_BACKUP_DIR): " BACKUP_DIR
    BACKUP_DIR=${BACKUP_DIR:-$DEFAULT_BACKUP_DIR}
else
    BACKUP_DIR="$2"
fi

# Informar o diretório de backup
echo "[ Backup Agent ] [ INFO ] Backup location is set to $BACKUP_DIR"

# Definir nome do arquivo de backup com timestamp
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="${VOLUME_NAME}-${TIMESTAMP}.tar.gz"

# Informar o nome do arquivo
echo "[ Backup Agent ] [ INFO ] Backup file name is set to $BACKUP_FILE"

# === SCRIPT START ===

# Verificar se o diretório existe
if [ -d "$BACKUP_DIR" ]; then
    echo "[ Backup Agent ] [ INFO ] Directory '$BACKUP_DIR' already exists, skipping directory creation."
else
    echo "[ Backup Agent ] [ INFO ] Directory '$BACKUP_DIR' does not exist, creating directory."
    mkdir -p "$BACKUP_DIR" || {
        echo "[ Backup Agent ] [ ERROR ] Failed to create directory '$BACKUP_DIR', aborting backup."
        echo "[ Backup Agent ] [ ERROR ] Backup Failed!"
        exit 1
    }
fi

# Realizar o backup
echo "[ Backup Agent ] [ INFO ] Backing up volume: $VOLUME_NAME to $BACKUP_DIR/$BACKUP_FILE"

# Executar container Docker para criar o backup
docker run --rm \
  -v "$VOLUME_NAME":/volume \
  -v "$BACKUP_DIR":/backup \
  busybox \
  tar czf /backup/"$BACKUP_FILE" -C /volume . || {
    echo "[ Backup Agent ] [ ERROR ] Backup process failed, aborting."
    echo "[ Backup Agent ] [ ERROR ] Backup Failed!"
    exit 1
}

# Calcular tamanho do backup
BACKUP_SIZE=$(du -h "$BACKUP_DIR/$BACKUP_FILE" | cut -f1)

# Sucesso!
echo "[ Backup Agent ] [ SUCCESS ] Backup completed!"
echo "[ Backup Agent ] [ INFO ] Backup file: $BACKUP_DIR/$BACKUP_FILE"
echo "[ Backup Agent ] [ INFO ] Backup size: $BACKUP_SIZE"

BACKUP_FILE_PATH="$BACKUP_DIR/$BACKUP_FILE"

# === ENVIAR PARA DESTINOS REMOTOS ===
echo ""
echo "[ Backup Agent ] [ INFO ] ========== Upload para Destinos Remotos =========="

# Verificar se há destinos remotos habilitados
HAS_REMOTE_DEST=false
[ "$BACKUP_DEST_SSH" = "true" ] && HAS_REMOTE_DEST=true
[ "$BACKUP_DEST_GOOGLE_DRIVE" = "true" ] && HAS_REMOTE_DEST=true
[ "$BACKUP_DEST_AWS_S3" = "true" ] && HAS_REMOTE_DEST=true

if [ "$HAS_REMOTE_DEST" = "true" ] && [ -f "$BACKUP_FILE_PATH" ]; then
    echo "[ Backup Agent ] [ INFO ] Enviando backup para destinos configurados..."

    # Chamar script de upload com prefixo 'volumes'
    if [ -x "$SCRIPT_DIR/backup-destinos.sh" ]; then
        "$SCRIPT_DIR/backup-destinos.sh" "$BACKUP_FILE_PATH" --dest=all --prefix=volumes

        if [ $? -eq 0 ]; then
            echo "[ Backup Agent ] [ SUCCESS ] Backup enviado para destinos remotos"
        else
            echo "[ Backup Agent ] [ WARNING ] Alguns uploads falharam"
        fi
    else
        echo "[ Backup Agent ] [ WARNING ] Script backup-destinos.sh não encontrado"
    fi
else
    if [ "$HAS_REMOTE_DEST" != "true" ]; then
        echo "[ Backup Agent ] [ INFO ] Nenhum destino remoto configurado"
        echo "[ Backup Agent ] [ INFO ] Configure em: Menu → Configuração → Configurar Destinos de Backup"
    fi
fi

# Listar backups existentes deste volume
echo ""
echo "[ Backup Agent ] [ INFO ] All backups for volume '$VOLUME_NAME':"
ls -lh "$BACKUP_DIR/${VOLUME_NAME}"*.tar.gz 2>/dev/null || echo "[ Backup Agent ] [ INFO ] No previous backups found."
