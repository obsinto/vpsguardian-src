# Padrão de Scripts VPS Guardian

## Modo Automático vs Interativo

Scripts que podem ser executados via cron (automático) ou manualmente (interativo) devem seguir este padrão:

### 1. Detectar Modo de Execução

```bash
# Modo automático = usa configurações do arquivo, sem interação
AUTO_MODE=false

# Detectar via argumento --dest=, --auto, ou similar
for arg in "$@"; do
    case $arg in
        --dest=*|--auto)
            AUTO_MODE=true
            ;;
    esac
done
```

### 2. Carregar Configurações

```bash
CONFIG_FILE="/opt/vpsguardian/config/backup-destinations.conf"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
fi
```

### 3. Usar Config ou Pedir Input

```bash
if [ "$AUTO_MODE" = true ]; then
    # Usar configuração do arquivo
    REMOTE_IP="$SSH_REMOTE_SERVER"
    REMOTE_USER="${SSH_REMOTE_USER:-root}"

    # Validar se está configurado
    if [ -z "$REMOTE_IP" ]; then
        log_error "SSH_REMOTE_SERVER não configurado em $CONFIG_FILE"
        exit 1
    fi

    log_info "Usando configuração: $REMOTE_USER@$REMOTE_IP"
else
    # Modo interativo - pedir inputs
    read -p "IP do servidor: " REMOTE_IP
    read -p "Usuário (padrão: root): " REMOTE_USER
    REMOTE_USER=${REMOTE_USER:-root}
fi
```

### 4. Verificar Destinos Habilitados (para --dest=all)

```bash
if [ "$AUTO_MODE" = true ]; then
    # Só habilitar destinos que estão CONFIGURADOS
    if [ "$BACKUP_DEST_SSH" = true ] && [ -n "$SSH_REMOTE_SERVER" ]; then
        UPLOAD_SSH=true
        log_info "✓ SSH habilitado: $SSH_REMOTE_SERVER"
    elif [ "$BACKUP_DEST_SSH" = true ]; then
        log_warning "✗ SSH habilitado mas não configurado"
    fi

    # Verificar se há pelo menos um destino
    if [ "$UPLOAD_SSH" != true ] && [ "$UPLOAD_S3" != true ]; then
        log_error "Nenhum destino configurado!"
        exit 1
    fi
else
    # Modo interativo: habilitar todos
    UPLOAD_SSH=true
    UPLOAD_S3=true
fi
```

### 5. Suprimir Output Verboso em Modo Automático

```bash
if [ "$AUTO_MODE" = true ]; then
    # Sem --progress para não poluir logs do cron
    rclone copy "$FILE" "gdrive:$DIR"
else
    # Com --progress para feedback visual
    rclone copy "$FILE" "gdrive:$DIR" --progress
fi
```

## Variáveis do Config

| Variável | Descrição |
|----------|-----------|
| `BACKUP_DEST_SSH` | Habilita upload SSH (true/false) |
| `BACKUP_DEST_GOOGLE_DRIVE` | Habilita Google Drive (true/false) |
| `BACKUP_DEST_AWS_S3` | Habilita S3/R2 (true/false) |
| `SSH_REMOTE_SERVER` | IP/hostname do servidor SSH |
| `SSH_REMOTE_USER` | Usuário SSH (padrão: root) |
| `SSH_REMOTE_PORT` | Porta SSH (padrão: 22) |
| `SSH_REMOTE_DIR` | Diretório destino |
| `GDRIVE_REMOTE_NAME` | Nome do remote rclone (padrão: gdrive) |
| `GDRIVE_DIR` | Diretório no Google Drive |
| `S3_BUCKET` | Nome do bucket S3/R2 |
| `S3_PREFIX` | Prefixo/pasta dentro do bucket |
| `S3_ENDPOINT` | Endpoint customizado (R2, MinIO) |

## Resumo

```
┌─────────────────────────────────────────────────────────┐
│  Execução via Cron (--dest=all, --auto)                │
│  → AUTO_MODE=true                                       │
│  → Usar variáveis do config                            │
│  → Validar se estão preenchidas                        │
│  → Falhar silenciosamente se não configurado           │
│  → Sem prompts interativos (read)                      │
├─────────────────────────────────────────────────────────┤
│  Execução Manual (sem argumentos)                      │
│  → AUTO_MODE=false                                      │
│  → Mostrar menu interativo                             │
│  → Usar read para pedir inputs                         │
│  → Mostrar --progress em uploads                       │
└─────────────────────────────────────────────────────────┘
```
