#!/bin/bash
################################################################################
# Script: backup-volume-interativo.sh
# Propósito: Fazer backup de um volume Docker específico (versão interativa)
# Uso: ./backup-volume-interativo.sh [volume-name] [backup-dir]
################################################################################

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
    read -p "[ Backup Agent ] [ INPUT ] Please enter the directory to save the backup (Optional: press enter to use /root/volume-backups): " BACKUP_DIR
    BACKUP_DIR=${BACKUP_DIR:-/root/volume-backups}
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

# Listar backups existentes deste volume
echo ""
echo "[ Backup Agent ] [ INFO ] All backups for volume '$VOLUME_NAME':"
ls -lh "$BACKUP_DIR/${VOLUME_NAME}"*.tar.gz 2>/dev/null || echo "[ Backup Agent ] [ INFO ] No previous backups found."
