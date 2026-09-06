#!/bin/bash
################################################################################
# Regressões da CLI automatizada de backup/restore/migração.
# Todos os comandos externos são simulados e todos os dados ficam em mktemp.
################################################################################

set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$TEST_DIR")"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/vpsguardian-restore-tests.XXXXXX")
MOCK_BIN="$TMP_ROOT/bin"
FAILURES=0
ASSERTIONS=0

cleanup() { rm -rf "$TMP_ROOT"; }
trap cleanup EXIT

pass() { ASSERTIONS=$((ASSERTIONS + 1)); printf '  ✓ %s\n' "$1"; }
fail() { ASSERTIONS=$((ASSERTIONS + 1)); FAILURES=$((FAILURES + 1)); printf '  ✗ %s\n' "$1"; }
assert_true() { if eval "$1"; then pass "$2"; else fail "$2"; fi; }
assert_contains() {
    if grep -Fq -- "$2" "$1"; then pass "$3"; else fail "$3"; fi
}
assert_not_contains() {
    if ! grep -Fq -- "$2" "$1"; then pass "$3"; else fail "$3"; fi
}

mkdir -p "$MOCK_BIN" "$TMP_ROOT/backups/lote-unit" "$TMP_ROOT/reports"
printf 'SELECT 1;\n' > "$TMP_ROOT/backups/lote-unit/app-db-postgres-20260906_120000.sql"
printf 'SELECT 1;\n' > "$TMP_ROOT/backups/lote-unit/other-db-postgres-20260906_120000.sql"
printf 'SELECT 1;\n' > "$TMP_ROOT/backups/lote-unit/coolify-db-postgres-20260906_120000.sql"

cat > "$MOCK_BIN/docker" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$MOCK_DOCKER_LOG"
case "${1:-}" in
    ps)
        printf '%s\n' app-db other-db target-db coolify-db
        ;;
    inspect)
        if [[ "$*" == *'.Config.Env'* ]]; then
            printf '%s\n' 'POSTGRES_USER=test-user' 'POSTGRES_PASSWORD=test-pass' 'POSTGRES_DB=test-db'
        else
            printf 'running\n'
        fi
        ;;
    exec)
        if [[ "$*" == *'information_schema.tables'* ]]; then
            printf '0\n'
        else
            while IFS= read -r _line; do :; done
            if [ -n "${MOCK_DOCKER_FAIL_CONTAINER:-}" ] && \
               [[ "$*" == *" ${MOCK_DOCKER_FAIL_CONTAINER} psql"* ]]; then
                exit 1
            fi
        fi
        ;;
esac
exit 0
EOF
chmod +x "$MOCK_BIN/docker"
export MOCK_DOCKER_LOG="$TMP_ROOT/docker.log"

printf '\n[1] Restore seletivo com mapeamento e relatórios\n'
: > "$MOCK_DOCKER_LOG"
if PATH="$MOCK_BIN:$PATH" bash "$ROOT/migrar/restore-databases-dump.sh" \
    --dir="$TMP_ROOT/backups" \
    --batch=lote-unit \
    --dump=app-db \
    --target-container=target-db \
    --auto \
    --json-report="$TMP_ROOT/reports/selective.json" \
    --junit-report="$TMP_ROOT/reports/selective.xml" \
    > "$TMP_ROOT/selective.out" 2>&1; then
    pass "restore seletivo conclui sem prompt"
else
    fail "restore seletivo conclui sem prompt"
fi
assert_contains "$MOCK_DOCKER_LOG" "target-db psql" "dump é direcionado ao container mapeado"
assert_not_contains "$MOCK_DOCKER_LOG" "coolify-db psql" "restore seletivo não toca coolify-db"
assert_contains "$TMP_ROOT/reports/selective.json" '"status": "passed"' "relatório JSON registra sucesso"
assert_contains "$TMP_ROOT/reports/selective.json" '"target_container":"target-db"' "JSON registra o mapeamento"
assert_contains "$TMP_ROOT/reports/selective.xml" '<testsuite name="vpsguardian.restore"' "relatório JUnit é criado"
if command -v jq >/dev/null 2>&1 && jq -e . "$TMP_ROOT/reports/selective.json" >/dev/null; then
    pass "relatório JSON é sintaticamente válido"
else
    fail "relatório JSON é sintaticamente válido"
fi

printf '\n[2] Modo automático exclui Coolify por padrão\n'
: > "$MOCK_DOCKER_LOG"
if PATH="$MOCK_BIN:$PATH" bash "$ROOT/migrar/restore-databases-dump.sh" \
    --dir="$TMP_ROOT/backups/lote-unit" --auto > "$TMP_ROOT/auto.out" 2>&1; then
    pass "restore automático dos bancos de aplicação conclui"
else
    fail "restore automático dos bancos de aplicação conclui"
fi
assert_contains "$MOCK_DOCKER_LOG" "app-db psql" "modo automático restaura banco de aplicação"
assert_contains "$MOCK_DOCKER_LOG" "other-db psql" "modo automático restaura demais aplicações"
assert_not_contains "$MOCK_DOCKER_LOG" "coolify-db psql" "modo automático não restaura Coolify implicitamente"

set +e
PATH="$MOCK_BIN:$PATH" bash "$ROOT/migrar/restore-databases-dump.sh" \
    --dir="$TMP_ROOT/backups" --batch=lote-unit --dump=coolify-db --auto \
    > "$TMP_ROOT/coolify-denied.out" 2>&1
coolify_denied_rc=$?
set -e
assert_true '[ "$coolify_denied_rc" -eq 2 ]' "Coolify seletivo exige autorização explícita"
assert_contains "$TMP_ROOT/coolify-denied.out" "--include-coolify" "erro explica a autorização necessária"

: > "$MOCK_DOCKER_LOG"
if PATH="$MOCK_BIN:$PATH" bash "$ROOT/migrar/restore-databases-dump.sh" \
    --dir="$TMP_ROOT/backups" --batch=lote-unit --dump=coolify-db \
    --include-coolify --auto > "$TMP_ROOT/coolify-allowed.out" 2>&1; then
    pass "Coolify pode ser restaurado com opt-in explícito"
else
    fail "Coolify pode ser restaurado com opt-in explícito"
fi
assert_contains "$MOCK_DOCKER_LOG" "coolify-db psql" "opt-in restaura coolify-db"

printf '\n[3] Falhas retornam código não zero e relatório de máquina\n'
set +e
MOCK_DOCKER_FAIL_CONTAINER="app-db" PATH="$MOCK_BIN:$PATH" \
    bash "$ROOT/migrar/restore-databases-dump.sh" \
        --dir="$TMP_ROOT/backups" --batch=lote-unit --dump=app-db --auto \
        --json-report="$TMP_ROOT/reports/failed.json" \
        --junit-report="$TMP_ROOT/reports/failed.xml" \
        > "$TMP_ROOT/failed.out" 2>&1
failed_restore_rc=$?
set -e
assert_true '[ "$failed_restore_rc" -ne 0 ]' "falha do banco produz código diferente de zero"
assert_contains "$TMP_ROOT/reports/failed.json" '"status": "failed"' "JSON registra falha"
assert_contains "$TMP_ROOT/reports/failed.xml" 'failures="1"' "JUnit registra uma falha"

printf '\n[4] Transporte SSH não interativo usa o restaurador real\n'
REMOTE_BATCH="lote-20260906_120000.tar.gz"
mkdir -p "$TMP_ROOT/archive/lote-20260906_120000"
printf 'SELECT 1;\n' > "$TMP_ROOT/archive/lote-20260906_120000/app-db-postgres-20260906_120000.sql"
tar -czf "$TMP_ROOT/$REMOTE_BATCH" -C "$TMP_ROOT/archive" lote-20260906_120000
export MOCK_REMOTE_ARCHIVE="$TMP_ROOT/$REMOTE_BATCH"
export MOCK_REMOTE_BATCH="$REMOTE_BATCH"
REMOTE_SHA256=$(sha256sum "$TMP_ROOT/$REMOTE_BATCH" | awk '{print $1}')

cat > "$MOCK_BIN/ssh" <<'EOF'
#!/bin/bash
case "$*" in
    *"find "*) printf '/remote/%s\n' "$MOCK_REMOTE_BATCH" ;;
    *"du -h"*) printf '1K\t/remote/%s\n' "$MOCK_REMOTE_BATCH" ;;
    *"stat -c"*) printf '2026-09-06 12:00:00.000000000 +0000\n' ;;
    *"cat /etc/machine-id"*) printf '%s\n' "${MOCK_SSH_MACHINE_ID:-destination-machine-id}" ;;
    *"test -f "*) [ "${MOCK_SSH_DENY_MARKER:-}" = "1" ] && exit 1 ;;
esac
exit 0
EOF
cat > "$MOCK_BIN/scp" <<'EOF'
#!/bin/bash
destination=""
for argument in "$@"; do destination="$argument"; done
cp "$MOCK_REMOTE_ARCHIVE" "$destination"
EOF
chmod +x "$MOCK_BIN/ssh" "$MOCK_BIN/scp"

: > "$MOCK_DOCKER_LOG"
if PATH="$MOCK_BIN:$PATH" \
   bash "$ROOT/backup/restaurar-dumps-remotos.sh" \
       --source=ssh \
       --ssh-host=source.test \
       --ssh-user=root \
       --ssh-port=22 \
       --ssh-dir=/remote \
       --batch="$REMOTE_BATCH" \
       --dump=app-db \
       --target-container=target-db \
       --expected-sha256="$REMOTE_SHA256" \
       --yes \
       --no-cleanup \
       --restore-dir="$TMP_ROOT/remote-restore" \
       --json-report="$TMP_ROOT/reports/remote.json" \
       > "$TMP_ROOT/remote.out" 2>&1; then
    pass "download SSH e restore seletivo concluem sem interação"
else
    fail "download SSH e restore seletivo concluem sem interação"
    sed -n '1,240p' "$TMP_ROOT/remote.out"
fi
assert_contains "$TMP_ROOT/reports/remote.json" '"source": "ssh"' "relatório identifica o transporte SSH"
assert_contains "$TMP_ROOT/reports/remote.json" "$REMOTE_SHA256" "relatório registra SHA-256 do lote"
assert_contains "$MOCK_DOCKER_LOG" "target-db psql" "restore remoto usa container de destino mapeado"
assert_contains "$ROOT/backup/restaurar-dumps-remotos.sh" '../migrar/restore-databases-dump.sh' "entrypoint remoto aponta para o restaurador existente"

: > "$MOCK_DOCKER_LOG"
set +e
PATH="$MOCK_BIN:$PATH" bash "$ROOT/backup/restaurar-dumps-remotos.sh" \
    --source=ssh --ssh-host=source.test --ssh-dir=/remote \
    --batch="$REMOTE_BATCH" --dump=app-db --yes \
    --expected-sha256="$(printf '0%.0s' {1..64})" \
    --restore-dir="$TMP_ROOT/hash-mismatch" \
    --json-report="$TMP_ROOT/reports/hash-mismatch.json" \
    --junit-report="$TMP_ROOT/reports/hash-mismatch.xml" \
    > "$TMP_ROOT/hash-mismatch.out" 2>&1
hash_mismatch_rc=$?
set -e
assert_true '[ "$hash_mismatch_rc" -ne 0 ]' "hash divergente interrompe o fluxo"
assert_contains "$TMP_ROOT/hash-mismatch.out" "não corresponde" "erro de integridade é explícito"
assert_true '[ ! -s "$MOCK_DOCKER_LOG" ]' "hash divergente aborta antes de acessar o banco"
assert_contains "$TMP_ROOT/reports/hash-mismatch.json" '"phase": "integrity"' "falha pré-restore gera JSON com a fase"
assert_contains "$TMP_ROOT/reports/hash-mismatch.xml" 'failures="1"' "falha pré-restore gera JUnit"

printf '\n[5] Transporte S3 usa o mesmo prefixo do produtor\n'
cat > "$MOCK_BIN/aws" <<'EOF'
#!/bin/bash
case "$*" in
    "s3 ls s3://bucket.test/e2e/vpsguardian/run-1/")
        printf '2026-09-06 12:00:00 %s %s\n' "$(stat -c %s "$MOCK_REMOTE_ARCHIVE")" "$MOCK_REMOTE_BATCH"
        ;;
    "s3 ls s3://bucket.test")
        ;;
    s3\ cp\ *)
        destination=""
        for argument in "$@"; do destination="$argument"; done
        cp "$MOCK_REMOTE_ARCHIVE" "$destination"
        ;;
esac
exit 0
EOF
chmod +x "$MOCK_BIN/aws"

: > "$MOCK_DOCKER_LOG"
if PATH="$MOCK_BIN:$PATH" \
   bash "$ROOT/backup/restaurar-dumps-remotos.sh" \
       --source=s3 \
       --s3-bucket=bucket.test \
       --s3-prefix=e2e/vpsguardian/run-1 \
       --batch="$REMOTE_BATCH" \
       --dump=app-db \
       --target-container=target-db \
       --expected-sha256="$REMOTE_SHA256" \
       --yes \
       --cleanup \
       --restore-dir="$TMP_ROOT/s3-restore" \
       --json-report="$TMP_ROOT/reports/s3.json" \
       > "$TMP_ROOT/s3.out" 2>&1; then
    pass "download S3 e restore seletivo concluem sem interação"
else
    fail "download S3 e restore seletivo concluem sem interação"
    sed -n '1,240p' "$TMP_ROOT/s3.out"
fi
assert_contains "$TMP_ROOT/reports/s3.json" '"source": "s3"' "relatório identifica o transporte S3"
assert_contains "$MOCK_DOCKER_LOG" "target-db psql" "restore S3 usa container de destino mapeado"
assert_true '! find "$TMP_ROOT/s3-restore" -mindepth 1 -print -quit 2>/dev/null | grep -q .' "--cleanup remove artefatos baixados"

printf '\n[6] Prefixo remoto é encaminhado sem alterar o menu\n'
MOCK_DATABASE_DIR="$TMP_ROOT/database-backups"
MOCK_UPLOAD_ARGS="$TMP_ROOT/upload.args"
MOCK_CONFIG="$TMP_ROOT/backup-destinations.conf"
mkdir -p "$MOCK_DATABASE_DIR" "$TMP_ROOT/logs" "$TMP_ROOT/locks"
printf '%s\n' 'S3_PREFIX="configurado/databases"' 'BACKUP_INCLUDE_COOLIFY=false' > "$MOCK_CONFIG"

cat > "$TMP_ROOT/mock-dump.sh" <<'EOF'
#!/bin/bash
batch="$DATABASE_BACKUP_DIR/lote-20990101_000000"
mkdir -p "$batch"
printf 'SELECT 1;\n' > "$batch/app-db-postgres-20990101_000000.sql.gz"
EOF
cat > "$TMP_ROOT/mock-upload.sh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" > "$MOCK_UPLOAD_ARGS"
EOF
chmod +x "$TMP_ROOT/mock-dump.sh" "$TMP_ROOT/mock-upload.sh"
export MOCK_UPLOAD_ARGS

if VPSGUARDIAN_DUMP_SCRIPT="$TMP_ROOT/mock-dump.sh" \
   VPSGUARDIAN_DESTINATIONS_SCRIPT="$TMP_ROOT/mock-upload.sh" \
   VPSGUARDIAN_SHARED_CONFIG_FILE="$MOCK_CONFIG" \
   DATABASE_BACKUP_DIR="$MOCK_DATABASE_DIR" \
   BACKUP_ROOT="$TMP_ROOT" LOG_DIR="$TMP_ROOT/logs" LOCK_DIR="$TMP_ROOT/locks" \
   bash "$ROOT/backup/backup-databases-dump-auto.sh" \
       --dest=aws-s3 --prefix=e2e/vpsguardian/run-1 \
       > "$TMP_ROOT/backup-prefix.out" 2>&1; then
    pass "backup aceita prefixo explícito"
else
    fail "backup aceita prefixo explícito"
fi
assert_contains "$MOCK_UPLOAD_ARGS" "--prefix=e2e/vpsguardian/run-1" "prefixo geral é encaminhado"
assert_contains "$MOCK_UPLOAD_ARGS" "--s3-prefix=e2e/vpsguardian/run-1" "prefixo S3 usa o mesmo contrato do restore"
assert_contains "$ROOT/menu-principal.sh" 'run_script "$SCRIPT_DIR/backup/restaurar-dumps-remotos.sh" "Restaurar Dumps Remotos"' "chamada do menu permanece sem flags novas"
assert_contains "$ROOT/backup/restaurar-dumps-remotos.sh" 'if [ -z "$SOURCE" ]' "restore remoto continua abrindo seleção de origem sem flags"
assert_contains "$ROOT/migrar/restore-databases-dump.sh" 'AUTO_MODE=false' "restore local continua interativo por padrão"

printf '\n[7] Fluxo legado por menu continua funcional\n'
: > "$MOCK_DOCKER_LOG"
if printf '3\nsource.test\nroot\n22\n/remote\n0\n\n3\n0\nn\n' | \
   LOCAL_RESTORE_DIR="$TMP_ROOT/menu-restore" PATH="$MOCK_BIN:$PATH" \
   bash "$ROOT/backup/restaurar-dumps-remotos.sh" \
       > "$TMP_ROOT/menu-restore.out" 2>&1; then
    pass "restore remoto sem flags conclui pelo menu"
else
    fail "restore remoto sem flags conclui pelo menu"
    sed -n '1,260p' "$TMP_ROOT/menu-restore.out"
fi
assert_contains "$TMP_ROOT/menu-restore.out" "Escolha a Origem dos Dumps" "menu de origem continua disponível"
assert_contains "$TMP_ROOT/menu-restore.out" "OPÇÕES DE RESTAURAÇÃO" "menu seletivo do restaurador continua disponível"
assert_contains "$MOCK_DOCKER_LOG" "app-db psql" "seleção interativa continua restaurando o dump escolhido"

printf '\n[8] Guardas destrutivas falham antes da migração\n'
printf 'mock-key\n' > "$TMP_ROOT/id_e2e"
chmod 600 "$TMP_ROOT/id_e2e"
set +e
NEW_SERVER_IP="destination.test" \
SSH_PRIVATE_KEY_PATH="$TMP_ROOT/id_e2e" \
bash "$ROOT/migrar/migrar-completo.sh" \
    --auto --skip-volumes --replace-existing \
    --json-report="$TMP_ROOT/reports/migration-denied.json" \
    > "$TMP_ROOT/migration-denied.out" 2>&1
migration_denied_rc=$?
set -e
assert_true '[ "$migration_denied_rc" -eq 2 ]' "replace existente exige marcador descartável"
assert_contains "$TMP_ROOT/reports/migration-denied.json" '"status": "failed"' "falha da guarda gera JSON"

set +e
ALLOW_DESTRUCTIVE_E2E=YES MOCK_SSH_DENY_MARKER=1 PATH="$MOCK_BIN:$PATH" \
NEW_SERVER_IP="destination.test" SSH_PRIVATE_KEY_PATH="$TMP_ROOT/id_e2e" \
bash "$ROOT/migrar/migrar-completo.sh" \
    --auto --skip-volumes \
    --require-destination-marker="$TMP_ROOT/destination.marker" \
    > "$TMP_ROOT/migration-marker-denied.out" 2>&1
migration_marker_denied_rc=$?
set -e
assert_true '[ "$migration_marker_denied_rc" -eq 2 ]' "migração exige que o marcador exista no destino"
assert_contains "$TMP_ROOT/migration-marker-denied.out" "marker not found" "erro identifica marcador remoto ausente"

set +e
ALLOW_DESTRUCTIVE_E2E=YES \
MOCK_SSH_MACHINE_ID="$(cat /etc/machine-id)" PATH="$MOCK_BIN:$PATH" \
NEW_SERVER_IP="destination.test" SSH_PRIVATE_KEY_PATH="$TMP_ROOT/id_e2e" \
bash "$ROOT/migrar/migrar-completo.sh" \
    --auto --skip-volumes \
    --require-destination-marker="$TMP_ROOT/destination.marker" \
    > "$TMP_ROOT/migration-same-machine.out" 2>&1
migration_same_machine_rc=$?
set -e
assert_true '[ "$migration_same_machine_rc" -eq 2 ]' "migração rejeita origem e destino com a mesma identidade"
assert_contains "$TMP_ROOT/migration-same-machine.out" "same /etc/machine-id" "erro identifica máquinas iguais"

assert_contains "$ROOT/migrar/migrar-completo.sh" 'export MIGRATE_PROXY' "orquestrador propaga estratégia do proxy"
assert_contains "$ROOT/migrar/migrar-completo.sh" 'export KEY_ROTATION_MODE' "orquestrador propaga estratégia de chaves"

printf '\nRestore automation: %d asserts, %d falhas\n' "$ASSERTIONS" "$FAILURES"
exit "$FAILURES"
