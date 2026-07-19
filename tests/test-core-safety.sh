#!/bin/bash
################################################################################
# Regressões dos fluxos críticos de backup, migração, configuração e update.
# Não acessa Docker, systemd, /etc, /opt ou destinos remotos.
################################################################################

set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$TEST_DIR")"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/vpsguardian-core-safety.XXXXXX")
FAILURES=0
ASSERTIONS=0

cleanup() { rm -rf "$TMP_ROOT"; }
trap cleanup EXIT

pass() { ASSERTIONS=$((ASSERTIONS + 1)); printf '  ✓ %s\n' "$1"; }
fail() { ASSERTIONS=$((ASSERTIONS + 1)); FAILURES=$((FAILURES + 1)); printf '  ✗ %s\n' "$1"; }
assert_true() { if eval "$1"; then pass "$2"; else fail "$2"; fi; }
assert_file_contains() {
    if grep -Fq -- "$2" "$1"; then pass "$3"; else fail "$3"; fi
}
assert_file_not_contains() {
    if ! grep -Fq -- "$2" "$1"; then pass "$3"; else fail "$3"; fi
}

printf '\n[1] Sintaxe de todos os scripts\n'
syntax_failed=0
while IFS= read -r script; do
    bash -n "$script" || syntax_failed=$((syntax_failed + 1))
done < <(find "$ROOT" -type f -name '*.sh' -print | sort)
assert_true '[ "$syntax_failed" -eq 0 ]' "todos os scripts passam em bash -n"

printf '\n[2] Atualização atômica da configuração Coolify\n'
CONFIG_FILE="$TMP_ROOT/backup-destinations.conf"
cat > "$CONFIG_FILE" <<'EOF'
#!/bin/bash
WEBHOOK_URL='https://discord.invalid/api/webhooks/$literal'
COOLIFY_API_ENABLED=true
COOLIFY_API_TOKEN='token com espaços $() `literal` e &'
CUSTOM_SETTING='preservar-me'
EOF
chmod 600 "$CONFIG_FILE"
VPSGUARDIAN_SHARED_CONFIG_FILE="$CONFIG_FILE" \
    bash "$ROOT/scripts-auxiliares/configurar-coolify-api.sh" --disable >/dev/null
assert_file_contains "$CONFIG_FILE" "COOLIFY_API_ENABLED=false" "flag da API atualizada"
assert_file_contains "$CONFIG_FILE" 'COOLIFY_API_TOKEN='"'"'token com espaços $() `literal` e &'"'"'' "token preservado literalmente"
assert_file_contains "$CONFIG_FILE" "CUSTOM_SETTING='preservar-me'" "chave desconhecida preservada"
assert_true '[ "$(stat -c %a "$CONFIG_FILE")" = 600 ]' "configuração permanece 0600"

printf '\n[3] Editor de destinos preserva schema compartilhado\n'
assert_file_contains "$ROOT/backup/configurar-backup-destinos.sh" 'COOLIFY_API_TOKEN=$(printf' "editor grava token Coolify existente"
assert_file_contains "$ROOT/backup/configurar-backup-destinos.sh" 'WEBHOOK_URL=$(printf' "editor serializa webhook com shell quoting"
assert_file_not_contains "$ROOT/backup/configurar-backup-destinos.sh" 'Webhook atual: ${YELLOW}${WEBHOOK_URL' "editor não exibe webhook completo"

printf '\n[4] Backup não mascara falhas\n'
assert_file_contains "$ROOT/backup/backup-coolify.sh" 'BACKUP_FATAL_ERRORS' "backup rastreia falhas obrigatórias"
assert_file_contains "$ROOT/backup/backup-coolify.sh" 'chmod 0600' "arquivo compactado recebe permissão restrita"
assert_file_contains "$ROOT/backup/backup-databases-dump-auto.sh" 'REMOTE_RESULT=1' "wrapper rastreia falha remota"
assert_file_contains "$ROOT/migrar/migrar-databases-dump.sh" 'if [ "$FAIL_COUNT" -gt 0 ]' "dump retorna falha quando algum banco falha"

printf '\n[5] Migração exige autorização destrutiva explícita\n'
assert_file_contains "$ROOT/migrar/migrar-coolify.sh" '--replace-existing' "substituição do destino exige flag"
assert_file_not_contains "$ROOT/migrar/migrar-coolify.sh" 'docker stop \$(docker ps -q)' "migração não para todos os containers"
assert_file_contains "$ROOT/migrar/migrar-completo.sh" '"$SCRIPT_DIR/backup-volumes.sh"' "orquestrador usa o script de volumes existente"
assert_file_not_contains "$ROOT/migrar/migrar-completo.sh" 'backup-database-volumes.sh' "orquestrador não referencia script removido"

printf '\n[6] Atualizador possui rollback global\n'
assert_file_contains "$ROOT/instalar.sh" 'for item in backup manutencao migrar scripts-auxiliares docs lib monitor menu-principal.sh' "snapshot inclui todos os artefatos imutáveis"
assert_file_contains "$ROOT/instalar.sh" 'Rollback global concluído' "rollback global é explícito"

printf '\n[7] Backup Coolify com Docker simulado\n'
MOCK_BIN="$TMP_ROOT/bin"
MOCK_COOLIFY="$TMP_ROOT/coolify"
MOCK_CONFIG="$TMP_ROOT/shared.conf"
mkdir -p "$MOCK_BIN" "$MOCK_COOLIFY/source" "$TMP_ROOT/backups" "$TMP_ROOT/logs" "$TMP_ROOT/locks"
printf 'APP_KEY=base64:segredo-de-teste\n' > "$MOCK_COOLIFY/source/.env"
printf 'WEBHOOK_URL=""\n' > "$MOCK_CONFIG"
cat > "$MOCK_BIN/docker" <<'EOF'
#!/bin/bash
case "${1:-}" in
    ps)
        if [[ "$*" == *'{{.Image}}'* ]]; then
            printf 'coollabsio/coolify:mock\n'
        else
            printf 'coolify-db\n'
        fi
        ;;
    exec)
        if [[ "$*" == *'pg_dump'* ]]; then
            exit "${MOCK_PGDUMP_RC:-0}"
        fi
        ;;
    cp)
        printf 'mock-dump\n' > "$3"
        ;;
    volume)
        printf 'mock-volume\n'
        ;;
    --version)
        printf 'Docker mock 1.0\n'
        ;;
esac
exit 0
EOF
chmod +x "$MOCK_BIN/docker"

run_mock_backup() {
    local pgdump_rc="$1"
    MOCK_PGDUMP_RC="$pgdump_rc" \
    PATH="$MOCK_BIN:$PATH" \
    COOLIFY_DATA_DIR="$MOCK_COOLIFY" \
    BACKUP_ROOT="$TMP_ROOT/backups" \
    LOG_DIR="$TMP_ROOT/logs" \
    LOCK_DIR="$TMP_ROOT/locks" \
    VPSGUARDIAN_SHARED_CONFIG_FILE="$MOCK_CONFIG" \
        bash "$ROOT/backup/backup-coolify.sh" >/dev/null 2>&1
}

if run_mock_backup 1; then mock_failure_rc=0; else mock_failure_rc=$?; fi
assert_true '[ "$mock_failure_rc" -ne 0 ]' "falha do pg_dump produz código não zero"
assert_true '! find "$TMP_ROOT/backups/coolify" -maxdepth 1 -name "*.tar.gz" -print -quit 2>/dev/null | grep -q .' "falha obrigatória não cria tarball válido"
rm -rf "$TMP_ROOT/backups/coolify"

if run_mock_backup 0; then mock_success_rc=0; else mock_success_rc=$?; fi
assert_true '[ "$mock_success_rc" -eq 0 ]' "backup simulado válido conclui com sucesso"
MOCK_ARCHIVE=$(find "$TMP_ROOT/backups/coolify" -maxdepth 1 -name '*.tar.gz' -print -quit)
assert_true '[ -n "$MOCK_ARCHIVE" ] && [ -s "$MOCK_ARCHIVE" ]' "backup válido cria tarball não vazio"
assert_true '[ "$(stat -c %a "$MOCK_ARCHIVE")" = 600 ]' "tarball sensível fica 0600"

printf '\n[8] Configuração respeita os caminhos reais da instalação\n'
MOCK_INSTALL="$TMP_ROOT/custom-install"
mkdir -p "$MOCK_INSTALL/lib" "$MOCK_INSTALL/config"
cp "$ROOT"/lib/{common,colors,logging,validation}.sh "$MOCK_INSTALL/lib/"
cp "$ROOT/config/default.conf" "$MOCK_INSTALL/config/"
cat > "$MOCK_INSTALL/.install.conf" <<EOF
INSTALL_ROOT='$MOCK_INSTALL'
BACKUP_ROOT='$TMP_ROOT/custom-backups'
LOG_ROOT='$TMP_ROOT/custom-logs'
EOF
CONFIG_OUTPUT=$(bash -c 'source "$1/lib/common.sh"; printf "%s|%s|%s" "$VPSGUARDIAN_ROOT" "$BACKUP_ROOT" "$LOG_DIR"' _ "$MOCK_INSTALL")
assert_true '[ "$CONFIG_OUTPUT" = "'$MOCK_INSTALL'|'$TMP_ROOT'/custom-backups|'$TMP_ROOT'/custom-logs" ]' "common.sh herda install, backup e log customizados"

printf '\nCore safety: %d asserts, %d falhas\n' "$ASSERTIONS" "$FAILURES"
exit "$FAILURES"
