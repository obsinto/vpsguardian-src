#!/bin/bash
################################################################################
# Script: restaurar-dumps-remotos.sh
# Propósito: Baixar dumps SQL de S3/Google Drive e restaurar usando restore-databases-dump.sh
# Uso: ./restaurar-dumps-remotos.sh [--source=s3|gdrive|ssh]
################################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh" 2>/dev/null || {
    log_info() { echo "[ INFO ] $*"; }
    log_success() { echo "[ OK ] $*"; }
    log_error() { echo "[ ERRO ] $*"; }
    log_warning() { echo "[ AVISO ] $*"; }
    log_section() { echo ""; echo "========== $* =========="; echo ""; }
}
source "$SCRIPT_DIR/../lib/reporting.sh" 2>/dev/null || {
    vpsg_json_escape() { printf '%s' "${1:-}"; }
    vpsg_xml_escape() { printf '%s' "${1:-}"; }
    vpsg_prepare_report_path() { mkdir -p "$(dirname "$1")"; }
}

# Carregar configurações
BACKUP_DESTINATIONS_CONFIG="${VPSGUARDIAN_SHARED_CONFIG_FILE:-$VPSGUARDIAN_ROOT/config/backup-destinations.conf}"
if [ -f "$BACKUP_DESTINATIONS_CONFIG" ]; then
    source "$BACKUP_DESTINATIONS_CONFIG"
fi

### ========== CONFIGURAÇÃO ==========
SOURCE=""  # s3, gdrive, ou ssh
TEMP_DIR="/tmp/restore-dumps-$$"
LOCAL_RESTORE_DIR="${LOCAL_RESTORE_DIR:-${BACKUP_ROOT:-/var/backups/vpsguardian}/restore-remote}"
CLEANUP_MODE="ask"
ASSUME_YES=false
REQUESTED_BATCH=""
TARGET_CONTAINER=""
JSON_REPORT=""
JUNIT_REPORT=""
EXPECTED_SHA256=""
DUMP_FILTERS=()
REMOTE_PHASE="arguments"
RESTORE_INVOKED=false
S3_ENDPOINT="${S3_ENDPOINT:-}"
S3_BUCKET="${S3_BUCKET:-}"
S3_PREFIX="${S3_PREFIX:-}"
SSH_REMOTE_SERVER="${SSH_REMOTE_SERVER:-}"
SSH_REMOTE_USER="${SSH_REMOTE_USER:-root}"
SSH_REMOTE_PORT="${SSH_REMOTE_PORT:-22}"
SSH_REMOTE_DIR="${SSH_REMOTE_DIR:-/var/backups/vpsguardian/databases}"
GDRIVE_REMOTE_NAME="${GDRIVE_REMOTE_NAME:-}"
GDRIVE_DIR="${GDRIVE_DIR:-}"

### ========== PARSE ARGUMENTOS ==========
while [[ $# -gt 0 ]]; do
    case $1 in
        --source=*) SOURCE="${1#*=}"; shift ;;
        --endpoint=*) S3_ENDPOINT="${1#*=}"; shift ;;
        --s3-bucket=*) S3_BUCKET="${1#*=}"; shift ;;
        --s3-prefix=*|--prefix=*) S3_PREFIX="${1#*=}"; shift ;;
        --ssh-host=*) SSH_REMOTE_SERVER="${1#*=}"; shift ;;
        --ssh-user=*) SSH_REMOTE_USER="${1#*=}"; shift ;;
        --ssh-port=*) SSH_REMOTE_PORT="${1#*=}"; shift ;;
        --ssh-dir=*) SSH_REMOTE_DIR="${1#*=}"; shift ;;
        --batch=*) REQUESTED_BATCH="${1#*=}"; shift ;;
        --dump=*) DUMP_FILTERS+=("${1#*=}"); shift ;;
        --target-container=*) TARGET_CONTAINER="${1#*=}"; shift ;;
        --yes|--auto) ASSUME_YES=true; shift ;;
        --cleanup) CLEANUP_MODE="always"; shift ;;
        --no-cleanup) CLEANUP_MODE="never"; shift ;;
        --restore-dir=*) LOCAL_RESTORE_DIR="${1#*=}"; shift ;;
        --json-report=*) JSON_REPORT="${1#*=}"; shift ;;
        --junit-report=*) JUNIT_REPORT="${1#*=}"; shift ;;
        --expected-sha256=*|--sha256=*) EXPECTED_SHA256="${1#*=}"; shift ;;
        --include-coolify)
            log_error "Restore remoto de bancos de aplicação não aceita --include-coolify"
            exit 2
            ;;
        -h|--help)
            cat << 'EOF'
╔════════════════════════════════════════════════════════════════╗
║         RESTAURAR DUMPS SQL DE ORIGEM REMOTA                   ║
╚════════════════════════════════════════════════════════════════╝

DESCRIÇÃO:
  Baixa lotes de dumps SQL/Redis de S3/Google Drive e restaura usando
  o menu interativo do restore-databases-dump.sh.

  IMPORTANTE: Este script restaura APENAS dumps de bancos de dados de aplicações.
  Para restaurar o Coolify completo (banco + SSH + .env), use:
    - restaurar-coolify.sh (interface unificada)
    - restaurar-do-s3.sh (direto do S3)

USO:
  ./restaurar-dumps-remotos.sh [--source=ORIGEM]

OPÇÕES:
  --source=s3                 Baixar do AWS S3
  --source=gdrive             Baixar do Google Drive (rclone)
  --source=ssh                Baixar de servidor SSH
  --batch=ARQUIVO             Selecionar lote exato
  --dump=NOME                 Selecionar dump/container exato (repetível)
  --target-container=NOME     Mapear um único dump para outro container
  --yes, --auto               Não exibir prompts; exige --source e --batch
  --cleanup                   Remover download sem perguntar
  --no-cleanup                Manter download sem perguntar
  --s3-bucket=NOME            Sobrescrever bucket configurado
  --s3-prefix=PREFIXO         Sobrescrever prefixo configurado
  --endpoint=URL              Endpoint S3-compatible (Cloudflare R2, MinIO)
  --ssh-host=HOST             Sobrescrever servidor SSH
  --ssh-user=USUARIO          Sobrescrever usuário SSH
  --ssh-port=PORTA            Sobrescrever porta SSH
  --ssh-dir=CAMINHO           Sobrescrever diretório remoto
  --json-report=ARQUIVO       Gravar resultado JSON
  --junit-report=ARQUIVO      Gravar resultado JUnit XML
  --expected-sha256=HASH      Exigir o SHA-256 esperado antes de extrair
  -h, --help                  Mostrar esta ajuda
EOF
            exit 0
            ;;
        *) log_error "Opção desconhecida: $1"; exit 1 ;;
    esac
done

if [ "$ASSUME_YES" = true ]; then
    if [ -z "$SOURCE" ] || [ -z "$REQUESTED_BATCH" ]; then
        log_error "Modo não interativo exige --source e --batch"
        exit 2
    fi
    [ "$CLEANUP_MODE" = "ask" ] && CLEANUP_MODE="never"
fi

if [ -n "$TARGET_CONTAINER" ] && [ ${#DUMP_FILTERS[@]} -ne 1 ]; then
    log_error "--target-container exige exatamente um --dump"
    exit 2
fi

if [ -n "$REQUESTED_BATCH" ] && \
   { [[ ! "$REQUESTED_BATCH" =~ ^[A-Za-z0-9._-]+$ ]] || [[ "$REQUESTED_BATCH" == "." || "$REQUESTED_BATCH" == ".." ]]; }; then
    log_error "Nome de lote inválido: $REQUESTED_BATCH"
    exit 2
fi

if [ -n "$EXPECTED_SHA256" ] && [[ ! "$EXPECTED_SHA256" =~ ^[A-Fa-f0-9]{64}$ ]]; then
    log_error "SHA-256 esperado inválido"
    exit 2
fi

write_remote_failure_reports() {
    local exit_code="$1"
    local json_complete=true
    local junit_complete=true

    [ -n "$JSON_REPORT" ] && [ ! -s "$JSON_REPORT" ] && json_complete=false
    [ -n "$JUNIT_REPORT" ] && [ ! -s "$JUNIT_REPORT" ] && junit_complete=false
    if [ "$RESTORE_INVOKED" = true ] && [ "$json_complete" = true ] && [ "$junit_complete" = true ]; then
        return 0
    fi

    if [ -n "$JSON_REPORT" ] && { [ "$RESTORE_INVOKED" != true ] || [ ! -s "$JSON_REPORT" ]; } && \
       vpsg_prepare_report_path "$JSON_REPORT"; then
        {
            printf '{\n'
            printf '  "status": "failed",\n'
            printf '  "exit_code": %s,\n' "$exit_code"
            printf '  "phase": "%s",\n' "$(vpsg_json_escape "$REMOTE_PHASE")"
            printf '  "source": "%s",\n' "$(vpsg_json_escape "${SOURCE:-unknown}")"
            printf '  "batch": "%s",\n' "$(vpsg_json_escape "${REQUESTED_BATCH:-}")"
            printf '  "archive_sha256": "%s",\n' "$(vpsg_json_escape "${ARCHIVE_SHA256:-}")"
            printf '  "selected": 0,\n'
            printf '  "succeeded": 0,\n'
            printf '  "failed": 1,\n'
            printf '  "results": []\n'
            printf '}\n'
        } > "$JSON_REPORT"
    fi

    if [ -n "$JUNIT_REPORT" ] && { [ "$RESTORE_INVOKED" != true ] || [ ! -s "$JUNIT_REPORT" ]; }; then
        if vpsg_prepare_report_path "$JUNIT_REPORT"; then
            {
                printf '<testsuite name="vpsguardian.remote-restore" tests="1" failures="1">\n'
                printf '  <testcase name="remote-restore"><failure message="failed in phase %s"/></testcase>\n' \
                    "$(vpsg_xml_escape "$REMOTE_PHASE")"
                printf '</testsuite>\n'
            } > "$JUNIT_REPORT"
        fi
    fi
}

on_remote_restore_exit() {
    local exit_code=$?
    [ "$exit_code" -ne 0 ] && write_remote_failure_reports "$exit_code"
}

trap on_remote_restore_exit EXIT

### ========== CONSTRUIR COMANDO AWS (SUPORTE R2) ==========
AWS_CMD=(aws)
if [ -n "$S3_ENDPOINT" ]; then 
    AWS_CMD+=(--endpoint-url "$S3_ENDPOINT")
fi

### ========== APRESENTAÇÃO ==========
REMOTE_PHASE="source_preflight"
[ -t 1 ] && clear
echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║        RESTAURAR DUMPS SQL DE ORIGEM REMOTA                    ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

### ========== ESCOLHER ORIGEM ==========
if [ -z "$SOURCE" ]; then
    log_section "Escolha a Origem dos Dumps"
    echo "De onde você deseja baixar os dumps SQL?"
    echo ""
    echo "  [1] AWS S3 / Cloudflare R2"
    echo "  [2] Google Drive (rclone)"
    echo "  [3] Servidor SSH (rsync/scp)"
    echo "  [0] Cancelar"
    echo ""
    read -p "Escolha uma opção (0-3): " source_choice

    case "$source_choice" in
        1) SOURCE="s3" ;;
        2) SOURCE="gdrive" ;;
        3) SOURCE="ssh" ;;
        0) log_info "Operação cancelada"; exit 0 ;;
        *) log_error "Opção inválida"; exit 1 ;;
    esac
    echo ""
fi

### ========== VALIDAR FERRAMENTAS ==========
log_section "Validando Ferramentas"

case "$SOURCE" in
    s3)
        if ! command -v aws &> /dev/null; then
            log_error "AWS CLI não está instalado"
            exit 1
        fi

        # Usar configuração ou perguntar
        if [ -z "$S3_BUCKET" ]; then
            if [ "$ASSUME_YES" = true ]; then
                log_error "Modo não interativo exige S3_BUCKET ou --s3-bucket"
                exit 2
            fi
            read -p "Nome do bucket S3/R2: " S3_BUCKET
            read -p "Prefixo/pasta (padrão: backups/vpsguardian/databases): " S3_PREFIX
            S3_PREFIX=${S3_PREFIX:-backups/vpsguardian/databases}
        fi
        S3_PREFIX=${S3_PREFIX:-databases}

        if [[ ! "$S3_PREFIX" =~ ^[A-Za-z0-9._/-]+$ ]] || \
           [[ "/$S3_PREFIX/" == *"/../"* ]] || [[ "/$S3_PREFIX/" == *"/./"* ]]; then
            log_error "Prefixo S3 inválido: $S3_PREFIX"
            exit 2
        fi

        # Tratar S3_PREFIX para evitar barras duplas e construir a URL alvo
        S3_TARGET="s3://$S3_BUCKET"
        if [ -n "$S3_PREFIX" ]; then
            CLEAN_PREFIX=$(echo "$S3_PREFIX" | sed 's/^\/*//;s/\/*$//')
            if [ -n "$CLEAN_PREFIX" ]; then
                S3_TARGET="s3://$S3_BUCKET/$CLEAN_PREFIX"
            fi
        fi

        log_info "Testando acesso ao bucket..."
        if [ -n "$S3_ENDPOINT" ]; then
            log_info "Usando Endpoint: $S3_ENDPOINT"
        fi
        
        if ! "${AWS_CMD[@]}" s3 ls "s3://$S3_BUCKET" >/dev/null 2>&1; then
            log_error "Falha ao acessar o bucket s3://$S3_BUCKET"
            echo "Verifique o nome do bucket, as credenciais e o endpoint"
            exit 1
        fi

        log_success "Conexão S3/R2 configurada. Alvo: $S3_TARGET/"
        ;;

    gdrive)
        if ! command -v rclone &> /dev/null; then
            log_error "rclone não está instalado"
            exit 1
        fi

        if [ -z "$GDRIVE_REMOTE_NAME" ]; then
            if [ "$ASSUME_YES" = true ]; then
                log_error "Modo não interativo exige GDRIVE_REMOTE_NAME configurado"
                exit 2
            fi
            read -p "Nome do remote (padrão: gdrive): " GDRIVE_REMOTE_NAME
            GDRIVE_REMOTE_NAME=${GDRIVE_REMOTE_NAME:-gdrive}
        fi

        if [ -z "$GDRIVE_DIR" ]; then
            if [ "$ASSUME_YES" = true ]; then
                log_error "Modo não interativo exige GDRIVE_DIR configurado"
                exit 2
            fi
            read -p "Diretório no Google Drive: " GDRIVE_DIR
            GDRIVE_DIR=${GDRIVE_DIR:-backups/vpsguardian/databases}
        fi

        log_info "Testando acesso ao Google Drive..."
        if ! rclone lsd "${GDRIVE_REMOTE_NAME}:${GDRIVE_DIR}" >/dev/null 2>&1; then
            log_error "Falha ao acessar ${GDRIVE_REMOTE_NAME}:${GDRIVE_DIR}"
            exit 1
        fi
        log_success "Google Drive configurado: ${GDRIVE_REMOTE_NAME}:${GDRIVE_DIR}"
        ;;

    ssh)
        if [ -z "$SSH_REMOTE_SERVER" ]; then
            if [ "$ASSUME_YES" = true ]; then
                log_error "Modo não interativo exige SSH_REMOTE_SERVER ou --ssh-host"
                exit 2
            fi
            read -p "IP/Hostname do servidor remoto: " SSH_REMOTE_SERVER
            read -p "Usuário SSH (padrão: root): " SSH_REMOTE_USER
            SSH_REMOTE_USER=${SSH_REMOTE_USER:-root}
            read -p "Porta SSH (padrão: 22): " SSH_REMOTE_PORT
            SSH_REMOTE_PORT=${SSH_REMOTE_PORT:-22}
            read -p "Diretório remoto: " SSH_REMOTE_DIR
            SSH_REMOTE_DIR=${SSH_REMOTE_DIR:-/var/backups/vpsguardian/databases}
        fi

        log_info "Testando conexão SSH..."
        if ! ssh -p "$SSH_REMOTE_PORT" -o ConnectTimeout=10 "$SSH_REMOTE_USER@$SSH_REMOTE_SERVER" "exit" 2>/dev/null; then
            log_error "Falha na conexão SSH"
            exit 1
        fi
        log_success "SSH configurado: $SSH_REMOTE_USER@$SSH_REMOTE_SERVER:$SSH_REMOTE_DIR"
        ;;
    *)
        log_error "Origem inválida: $SOURCE"
        exit 2
        ;;
esac

echo ""

### ========== LISTAR LOTES DISPONÍVEIS ==========
REMOTE_PHASE="list_batches"
log_section "Lotes de Dumps Disponíveis"

declare -a LOTE_NAMES
declare -a LOTE_SIZES
declare -a LOTE_DATES

log_info "Buscando lotes disponíveis..."

case "$SOURCE" in
    s3)
        while IFS= read -r line; do
            if [[ "$line" =~ lote-.*\.tar\.gz$ ]]; then
                filename=$(echo "$line" | awk '{print $4}')
                size=$(echo "$line" | awk '{print $3}')
                date=$(echo "$line" | awk '{print $1" "$2}')
                
                size_mb=$((size / 1024 / 1024))
                
                LOTE_NAMES+=("$filename")
                LOTE_SIZES+=("${size_mb}MB")
                LOTE_DATES+=("$date")
            fi
        done < <("${AWS_CMD[@]}" s3 ls "$S3_TARGET/" 2>/dev/null)
        ;;

    gdrive)
        while IFS= read -r line; do
            if [[ "$line" =~ lote-.*\.tar\.gz$ ]]; then
                size=$(echo "$line" | awk '{print $1}')
                date=$(echo "$line" | awk '{print $2" "$3}')
                filename=$(echo "$line" | awk '{print $4}')

                size_mb=$((size / 1024 / 1024))
                size="${size_mb}M"

                LOTE_NAMES+=("$filename")
                LOTE_SIZES+=("$size")
                LOTE_DATES+=("$date")
            fi
        done < <(rclone lsl "${GDRIVE_REMOTE_NAME}:${GDRIVE_DIR}" 2>/dev/null | grep "lote-.*\.tar\.gz$")
        ;;

    ssh)
        while IFS= read -r line; do
            if [[ "$line" =~ lote-.*\.tar\.gz$ ]]; then
                filename=$(basename "$line")
                size=$(ssh -p "$SSH_REMOTE_PORT" "$SSH_REMOTE_USER@$SSH_REMOTE_SERVER" "du -h '$line' 2>/dev/null" | cut -f1)
                date=$(ssh -p "$SSH_REMOTE_PORT" "$SSH_REMOTE_USER@$SSH_REMOTE_SERVER" "stat -c %y '$line' 2>/dev/null" | cut -d'.' -f1)

                LOTE_NAMES+=("$filename")
                LOTE_SIZES+=("$size")
                LOTE_DATES+=("$date")
            fi
        done < <(ssh -p "$SSH_REMOTE_PORT" "$SSH_REMOTE_USER@$SSH_REMOTE_SERVER" "find '$SSH_REMOTE_DIR' -name 'lote-*.tar.gz' -type f 2>/dev/null" | sort -r)
        ;;
esac

if [ ${#LOTE_NAMES[@]} -eq 0 ]; then
    log_warning "Nenhum lote de dumps encontrado na origem remota"
    [ "$ASSUME_YES" = true ] && exit 2
    exit 0
fi

echo ""
log_success "${#LOTE_NAMES[@]} lote(s) encontrado(s):"
echo ""

for i in "${!LOTE_NAMES[@]}"; do
    echo "  [$i] ${LOTE_NAMES[$i]}"
    echo "      Tamanho: ${LOTE_SIZES[$i]} | Data: ${LOTE_DATES[$i]}"
    echo ""
done

### ========== ESCOLHER LOTE ==========
if [ -n "$REQUESTED_BATCH" ]; then
    SELECTED_LOTE=""
    for candidate in "${LOTE_NAMES[@]}"; do
        if [ "$candidate" = "$REQUESTED_BATCH" ]; then
            SELECTED_LOTE="$candidate"
            break
        fi
    done

    if [ -z "$SELECTED_LOTE" ]; then
        log_error "Lote solicitado não foi encontrado na origem: $REQUESTED_BATCH"
        exit 2
    fi
else
    read -p "Selecione o número do lote para baixar (ou 'q' para cancelar): " lote_choice

    if [ "$lote_choice" = "q" ]; then
        log_info "Operação cancelada"
        exit 0
    fi

    if ! [[ "$lote_choice" =~ ^[0-9]+$ ]] || [ "$lote_choice" -ge "${#LOTE_NAMES[@]}" ]; then
        log_error "Seleção inválida"
        exit 1
    fi

    SELECTED_LOTE="${LOTE_NAMES[$lote_choice]}"
fi

log_info "Selecionado: $SELECTED_LOTE"
echo ""

### ========== BAIXAR LOTE ==========
REMOTE_PHASE="download"
log_section "Download do Lote"

mkdir -p "$LOCAL_RESTORE_DIR"
DOWNLOAD_FILE="$LOCAL_RESTORE_DIR/$SELECTED_LOTE"

log_info "Baixando para: $DOWNLOAD_FILE"
echo ""

case "$SOURCE" in
    s3)
        "${AWS_CMD[@]}" s3 cp "$S3_TARGET/$SELECTED_LOTE" "$DOWNLOAD_FILE"
        ;;
    gdrive)
        rclone copy "${GDRIVE_REMOTE_NAME}:${GDRIVE_DIR}/$SELECTED_LOTE" "$LOCAL_RESTORE_DIR/" --progress
        ;;
    ssh)
        scp -P "$SSH_REMOTE_PORT" \
            "$SSH_REMOTE_USER@$SSH_REMOTE_SERVER:$SSH_REMOTE_DIR/$SELECTED_LOTE" \
            "$DOWNLOAD_FILE"
        ;;
esac

if [ $? -ne 0 ]; then
    log_error "Falha no download"
    exit 1
fi

log_success "Download concluído: $(du -h "$DOWNLOAD_FILE" | cut -f1)"
REMOTE_PHASE="integrity"
if command -v sha256sum >/dev/null 2>&1; then
    ARCHIVE_SHA256=$(sha256sum "$DOWNLOAD_FILE" | awk '{print $1}')
else
    ARCHIVE_SHA256=""
fi
if [ -n "$EXPECTED_SHA256" ]; then
    if [ -z "$ARCHIVE_SHA256" ]; then
        log_error "sha256sum não está disponível para validar o lote"
        exit 1
    fi
    if [ "${ARCHIVE_SHA256,,}" != "${EXPECTED_SHA256,,}" ]; then
        log_error "SHA-256 do lote não corresponde ao valor esperado"
        exit 1
    fi
    log_success "SHA-256 do lote validado"
fi
echo ""

### ========== EXTRAIR LOTE ==========
REMOTE_PHASE="extract"
log_section "Extraindo Lote"

EXTRACT_BATCH_NAME="$(basename "$SELECTED_LOTE" .tar.gz)-extract-$$"
EXTRACT_DIR="$LOCAL_RESTORE_DIR/$EXTRACT_BATCH_NAME"
mkdir -p "$EXTRACT_DIR"

log_info "Extraindo para: $EXTRACT_DIR"
if ! tar -tzf "$DOWNLOAD_FILE" 2>/dev/null | \
    awk 'BEGIN { bad=0 } /(^\/|(^|\/)\.\.($|\/))/ { bad=1 } END { exit bad }'; then
    log_error "Arquivo compactado inválido ou com caminhos inseguros"
    exit 1
fi
tar -xzf "$DOWNLOAD_FILE" -C "$EXTRACT_DIR" --strip-components=1 2>/dev/null

if [ $? -ne 0 ]; then
    log_error "Falha ao extrair arquivo"
    exit 1
fi

# Contar dumps extraídos
DUMP_COUNT=$(find "$EXTRACT_DIR" -type f \
    \( -name "*-mysql-*.sql*" -o -name "*-postgres-*.sql*" -o -name "*-mongodb-*.tar.gz" -o -name "*.rdb.gz" \) | wc -l)
log_success "Extraído: $DUMP_COUNT dump(s)"
[ "$DUMP_COUNT" -eq 0 ] && { log_error "O lote não contém dumps suportados"; exit 1; }
echo ""

### ========== RESTAURAR ==========
REMOTE_PHASE="restore"
log_section "Iniciar Restauração"

if [ "$ASSUME_YES" = true ] || [ ${#DUMP_FILTERS[@]} -gt 0 ]; then
    log_info "Chamando restore-databases-dump.sh em modo não interativo..."
else
    log_info "Chamando restore-databases-dump.sh com menu interativo..."
fi
echo ""
echo "════════════════════════════════════════════════════════════════"
echo "  Você terá CONTROLE TOTAL sobre o que restaurar:"
echo "  • Opção 1: Restaurar TUDO (incluindo banco do Coolify)"
echo "  • Opção 2: Restaurar TUDO EXCETO banco do Coolify ⭐ RECOMENDADO"
echo "  • Opção 3: Escolher dumps específicos"
echo ""
echo "  NOTA: Este script restaura apenas DUMPS SQL/Redis de aplicações."
echo "        Para restaurar o Coolify completo (DB + SSH + .env + volumes),"
echo "        use: restaurar-coolify.sh ou restaurar-do-s3.sh"
echo "════════════════════════════════════════════════════════════════"
echo ""
[ "$ASSUME_YES" = false ] && read -p "Pressione ENTER para continuar..."

# Chamar script de restore
RESTORE_SCRIPT="${VPSGUARDIAN_RESTORE_SCRIPT:-$SCRIPT_DIR/../migrar/restore-databases-dump.sh}"

if [ ! -x "$RESTORE_SCRIPT" ]; then
    log_error "Script de restore não encontrado: $RESTORE_SCRIPT"
    exit 1
fi

RESTORE_ARGS=(--dir="$LOCAL_RESTORE_DIR" --batch="$EXTRACT_BATCH_NAME")
if [ "$ASSUME_YES" = true ] || [ ${#DUMP_FILTERS[@]} -gt 0 ]; then
    RESTORE_ARGS+=(--exclude-coolify)
fi
[ "$ASSUME_YES" = true ] && RESTORE_ARGS+=(--auto)
for dump_filter in "${DUMP_FILTERS[@]}"; do
    RESTORE_ARGS+=(--dump="$dump_filter")
done
[ -n "$TARGET_CONTAINER" ] && RESTORE_ARGS+=(--target-container="$TARGET_CONTAINER")
[ -n "$JSON_REPORT" ] && RESTORE_ARGS+=(--json-report="$JSON_REPORT")
[ -n "$JUNIT_REPORT" ] && RESTORE_ARGS+=(--junit-report="$JUNIT_REPORT")

RESTORE_INVOKED=true
VPSGUARDIAN_RESTORE_SOURCE="$SOURCE" \
VPSGUARDIAN_RESTORE_BATCH="$SELECTED_LOTE" \
VPSGUARDIAN_RESTORE_ARCHIVE_SHA256="$ARCHIVE_SHA256" \
    bash "$RESTORE_SCRIPT" "${RESTORE_ARGS[@]}"
RESTORE_EXIT_CODE=$?

echo ""

### ========== LIMPEZA ==========
REMOTE_PHASE="cleanup"
if [ "$CLEANUP_MODE" = "ask" ]; then
    log_section "Limpeza"

    read -p "Remover arquivos baixados? (S/n): " cleanup_choice
    cleanup_choice=${cleanup_choice:-S}

    if [[ "$cleanup_choice" =~ ^[Ss]$ ]]; then
        log_info "Removendo arquivos temporários..."
        rm -f "$DOWNLOAD_FILE"
        rm -rf "$EXTRACT_DIR"
        log_success "Limpeza concluída"
    else
        log_info "Arquivos mantidos em:"
        echo "  • Tarball: $DOWNLOAD_FILE"
        echo "  • Extraído: $EXTRACT_DIR"
    fi
elif [ "$CLEANUP_MODE" = "always" ]; then
    log_section "Limpeza"
    log_info "Removendo arquivos temporários..."
    rm -f "$DOWNLOAD_FILE"
    rm -rf "$EXTRACT_DIR"
    log_success "Limpeza concluída"
else
    log_info "Arquivos mantidos em $LOCAL_RESTORE_DIR"
fi

echo ""

### ========== RESUMO FINAL ==========
if [ "$RESTORE_EXIT_CODE" -eq 0 ]; then
    REMOTE_PHASE="complete"
else
    REMOTE_PHASE="restore"
fi
log_section "RESUMO"
echo ""
if [ $RESTORE_EXIT_CODE -eq 0 ]; then
    log_success "Restauração concluída com sucesso!"
else
    log_warning "Restauração concluída com avisos (código: $RESTORE_EXIT_CODE)"
fi
echo ""
echo "  📥 Origem: $SOURCE"
echo "  📦 Lote: $SELECTED_LOTE"
echo "  💾 Dumps processados: $DUMP_COUNT"
echo ""

exit $RESTORE_EXIT_CODE
