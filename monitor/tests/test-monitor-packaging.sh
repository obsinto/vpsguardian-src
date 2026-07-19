#!/bin/bash
################################################################################
# M9 — integração do monitor ao instalador/atualizador/desinstalador existentes
#
# Toda a árvore de sistema é redirecionada para um diretório mktemp. Este teste
# nunca escreve em /etc, /usr, /opt ou /var/lib reais.
################################################################################

set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
SANDBOX="$(mktemp -d /tmp/vpsguardian-m9-tests.XXXXXX)"
SYSTEM_ROOT="$SANDBOX/root"
INSTALL_ROOT="$SANDBOX/install"
BACKUP_ROOT="$SANDBOX/backups"
LOG_ROOT="$SANDBOX/logs"
STATE_ROOT="$SYSTEM_ROOT/var/lib/vpsguardian/monitor"
INSTALLER="$PROJECT_ROOT/instalar.sh"

TEST_GROUPS=0
ASSERTIONS=0
FAILURES=0

cleanup() {
    rm -rf "$SANDBOX"
}
trap cleanup EXIT

group() {
    TEST_GROUPS=$((TEST_GROUPS + 1))
    printf '\n[%02d] %s\n' "$TEST_GROUPS" "$1"
}

pass() {
    ASSERTIONS=$((ASSERTIONS + 1))
    printf '  ✓ %s\n' "$1"
}

fail() {
    ASSERTIONS=$((ASSERTIONS + 1))
    FAILURES=$((FAILURES + 1))
    printf '  ✗ %s\n' "$1"
}

assert_file() {
    if [ -f "$1" ]; then pass "$2"; else fail "$2 (ausente: $1)"; fi
}

assert_not_file() {
    if [ ! -e "$1" ]; then pass "$2"; else fail "$2 (ainda existe: $1)"; fi
}

assert_dir() {
    if [ -d "$1" ]; then pass "$2"; else fail "$2 (ausente: $1)"; fi
}

assert_contains() {
    if grep -Fq "$2" "$1" 2>/dev/null; then pass "$3"; else fail "$3"; fi
}

assert_equals() {
    if [ "$1" = "$2" ]; then pass "$3"; else fail "$3 (esperado '$1', obtido '$2')"; fi
}

run_installer() {
    local mode="$1"
    shift
    # Executar fora do checkout prova que instalar.sh resolve sua própria origem
    # e não depende do diretório atual do chamador.
    (cd "$SANDBOX" && bash "$INSTALLER" \
        --mode "$mode" \
        --non-interactive \
        --copy \
        --system-root "$SYSTEM_ROOT" \
        --install-root "$INSTALL_ROOT" \
        --backup-root "$BACKUP_ROOT" \
        --log-root "$LOG_ROOT" \
        "$@" >/dev/null)
}

group "Instalação nova usa o instalador existente"
if run_installer install; then
    pass "instalação automatizada concluída"
else
    fail "instalação automatizada concluída"
fi
assert_file "$INSTALL_ROOT/monitor/vps-monitor.sh" "monitor instalado"
assert_file "$INSTALL_ROOT/lib/monitor-alerts.sh" "bibliotecas instaladas"
assert_file "$INSTALL_ROOT/config/monitor.conf.example" "exemplo instalado"
assert_file "$SYSTEM_ROOT/etc/systemd/system/vpsguardian-monitor.service" "service instalado"
assert_file "$SYSTEM_ROOT/etc/systemd/system/vpsguardian-monitor.timer" "timer instalado"
if VPSGUARDIAN_INSTALL_CONFIG="$INSTALL_ROOT/.install.conf" \
   MONITOR_CONFIG_FILE="$INSTALL_ROOT/config/monitor.conf" \
   VPSGUARDIAN_SHARED_CONFIG_FILE="$INSTALL_ROOT/config/backup-destinations.conf" \
   "$SYSTEM_ROOT/usr/local/bin/vps-guardian" monitor config-check >/dev/null; then
    pass "wrapper global encaminha comandos do monitor"
else
    fail "wrapper global encaminha comandos do monitor"
fi

group "Estrutura mutável e permissões"
assert_dir "$STATE_ROOT/history/metrics" "histórico de métricas criado"
assert_dir "$STATE_ROOT/history/diagnostics" "histórico de diagnósticos criado"
assert_dir "$STATE_ROOT/incidents" "pacotes de emergência possuem diretório"
assert_equals "750" "$(stat -c '%a' "$STATE_ROOT")" "estado tem permissão 0750"
assert_equals "750" "$(stat -c '%a' "$INSTALL_ROOT/config")" "config tem permissão 0750"

group "Configuração real reutiliza Discord e Coolify"
printf '%s\n' \
    'COOLIFY_API_ENABLED=true' \
    'COOLIFY_API_URL="http://coolify.test/api/v1"' \
    'COOLIFY_API_TOKEN="token-m9-preservar"' \
    'WEBHOOK_URL="https://discord.com/api/webhooks/m9-preservar"' \
    > "$INSTALL_ROOT/config/backup-destinations.conf"
printf '%s\n' 'MONITOR_LOAD_RATIO_WARNING=2.5' 'MEMORY_THRESHOLD=80' \
    > "$INSTALL_ROOT/config/monitor.conf"
if MONITOR_CONFIG_FILE="$INSTALL_ROOT/config/monitor.conf" \
   VPSGUARDIAN_SHARED_CONFIG_FILE="$INSTALL_ROOT/config/backup-destinations.conf" \
   "$INSTALL_ROOT/monitor/vps-monitor.sh" config-check >/dev/null; then
    pass "config-check aceita configuração antiga com aviso de depreciação"
else
    fail "config-check aceita configuração antiga com aviso de depreciação"
fi
assert_contains "$INSTALL_ROOT/config/backup-destinations.conf" "token-m9-preservar" "token fica na configuração compartilhada"
assert_contains "$INSTALL_ROOT/config/backup-destinations.conf" "discord.com/api/webhooks/m9-preservar" "webhook fica na configuração compartilhada"

group "Atualização preserva dados M5–M8"
printf 'incidents-m5\n' > "$STATE_ROOT/incidents.state"
printf 'diagnoses-m6\n' > "$STATE_ROOT/diagnoses.state"
printf '{"m7":true}\n' > "$STATE_ROOT/history/metrics/metrics-2026-07-18.jsonl"
printf 'pacote-m8\n' > "$STATE_ROOT/incidents/emergency.txt"
if run_installer update; then pass "update existente concluído"; else fail "update existente concluído"; fi
assert_contains "$STATE_ROOT/incidents.state" "incidents-m5" "estado M5 preservado"
assert_contains "$STATE_ROOT/diagnoses.state" "diagnoses-m6" "estado M6 preservado"
assert_contains "$STATE_ROOT/history/metrics/metrics-2026-07-18.jsonl" '"m7":true' "histórico M7 preservado"
assert_contains "$STATE_ROOT/incidents/emergency.txt" "pacote-m8" "incidente M8 preservado"
assert_contains "$INSTALL_ROOT/config/backup-destinations.conf" "token-m9-preservar" "Coolify preservado no update"
assert_contains "$INSTALL_ROOT/config/backup-destinations.conf" "discord.com/api/webhooks/m9-preservar" "Discord preservado no update"

group "Instalação antiga sem monitor recebe o módulo"
rm -f "$INSTALL_ROOT/monitor/vps-monitor.sh" "$INSTALL_ROOT"/lib/monitor-*.sh
rm -f "$SYSTEM_ROOT/etc/systemd/system/vpsguardian-monitor.service" \
      "$SYSTEM_ROOT/etc/systemd/system/vpsguardian-monitor.timer"
printf '#!/bin/bash\n# legado\n' > "$INSTALL_ROOT/backup/backup-coolify-s3.sh"
if run_installer update; then pass "instalação antiga atualizada"; else fail "instalação antiga atualizada"; fi
assert_file "$INSTALL_ROOT/monitor/vps-monitor.sh" "monitor adicionado à instalação antiga"
assert_file "$SYSTEM_ROOT/etc/systemd/system/vpsguardian-monitor.timer" "timer adicionado quando ausente"
assert_not_file "$INSTALL_ROOT/backup/backup-coolify-s3.sh" "script legado duplicado removido no update"

group "Reinstalação e timer são idempotentes"
if run_installer reinstall; then pass "reinstalação concluída"; else fail "reinstalação concluída"; fi
if run_installer reinstall; then pass "segunda reinstalação concluída"; else fail "segunda reinstalação concluída"; fi
unit_count=$(find "$SYSTEM_ROOT/etc/systemd/system" -maxdepth 1 -type f -name 'vpsguardian-monitor.*' | wc -l)
assert_equals "2" "$unit_count" "há exatamente um service e um timer"
assert_contains "$INSTALL_ROOT/config/backup-destinations.conf" "token-m9-preservar" "reinstalação não sobrescreve credenciais"

group "Rollback restaura todo o código imutável"
printf '#!/bin/bash\necho versao-anterior\n' > "$INSTALL_ROOT/monitor/vps-monitor.sh"
chmod +x "$INSTALL_ROOT/monitor/vps-monitor.sh"
printf '#!/bin/bash\necho backup-anterior\n' > "$INSTALL_ROOT/backup/backup-coolify.sh"
chmod +x "$INSTALL_ROOT/backup/backup-coolify.sh"
printf '#!/bin/bash\necho menu-anterior\n' > "$INSTALL_ROOT/menu-principal.sh"
chmod +x "$INSTALL_ROOT/menu-principal.sh"
printf '# unit-anterior\n' > "$SYSTEM_ROOT/etc/systemd/system/vpsguardian-monitor.service"
printf '# exemplo-anterior\n' > "$INSTALL_ROOT/config/monitor.conf.example"
set +e
VPSGUARDIAN_TEST_FAIL_AFTER_INSTALL=true run_installer update
rollback_rc=$?
set -e
if [ "$rollback_rc" -ne 0 ]; then pass "falha injetada aciona rollback"; else fail "falha injetada aciona rollback"; fi
assert_contains "$INSTALL_ROOT/monitor/vps-monitor.sh" "versao-anterior" "script anterior restaurado"
assert_contains "$INSTALL_ROOT/backup/backup-coolify.sh" "backup-anterior" "script de backup anterior restaurado"
assert_contains "$INSTALL_ROOT/menu-principal.sh" "menu-anterior" "menu anterior restaurado"
assert_contains "$SYSTEM_ROOT/etc/systemd/system/vpsguardian-monitor.service" "unit-anterior" "unit anterior restaurada"
assert_contains "$INSTALL_ROOT/config/monitor.conf.example" "exemplo-anterior" "exemplo anterior restaurado"
assert_contains "$STATE_ROOT/incidents.state" "incidents-m5" "rollback não reverte estado"
assert_contains "$INSTALL_ROOT/config/backup-destinations.conf" "token-m9-preservar" "rollback não reverte configuração"

group "Atualização posterior recupera versão válida"
if run_installer update; then pass "update após rollback concluído"; else fail "update após rollback concluído"; fi
if bash -n "$INSTALL_ROOT/monitor/vps-monitor.sh"; then pass "script atualizado tem sintaxe válida"; else fail "script atualizado tem sintaxe válida"; fi
assert_contains "$SYSTEM_ROOT/etc/systemd/system/vpsguardian-monitor.service" "/usr/local/bin/vps-guardian monitor check --quiet" "unit usa descoberta da instalação real"

group "self-check valida a instalação simulada"
if MONITOR_CONFIG_FILE="$INSTALL_ROOT/config/monitor.conf" \
   VPSGUARDIAN_SHARED_CONFIG_FILE="$INSTALL_ROOT/config/backup-destinations.conf" \
   MONITOR_STATE_DIR="$STATE_ROOT" \
   MONITOR_SYSTEMD_DIR="$SYSTEM_ROOT/etc/systemd/system" \
   MONITOR_SELF_CHECK_SKIP_SYSTEMCTL=1 \
   "$INSTALL_ROOT/monitor/vps-monitor.sh" self-check >/dev/null; then
    pass "self-check aprovado"
else
    fail "self-check aprovado"
fi

group "Auditoria não encontra produto ou updater paralelo"
installer_count=$(find "$PROJECT_ROOT" -path "$PROJECT_ROOT/.git" -prune -o -type f \
    \( -iname '*install*monitor*.sh' -o -iname '*monitor*install*.sh' \) -print | wc -l)
updater_count=$(find "$PROJECT_ROOT" -path "$PROJECT_ROOT/.git" -prune -o -type f \
    \( -iname '*update*monitor*.sh' -o -iname '*monitor*update*.sh' \) -print | wc -l)
assert_equals "0" "$installer_count" "nenhum instalador paralelo"
assert_equals "0" "$updater_count" "nenhum atualizador paralelo"
monitor_count=$(find "$INSTALL_ROOT" -type f -name vps-monitor.sh | wc -l)
assert_equals "1" "$monitor_count" "uma única cópia instalada do monitor"

group "Desinstalação do monitor preserva dados por padrão"
if run_installer uninstall --monitor-only; then pass "remoção modular concluída"; else fail "remoção modular concluída"; fi
assert_not_file "$INSTALL_ROOT/monitor/vps-monitor.sh" "script do monitor removido"
assert_not_file "$SYSTEM_ROOT/etc/systemd/system/vpsguardian-monitor.timer" "timer removido"
assert_file "$INSTALL_ROOT/config/monitor.conf" "configuração do usuário preservada"
assert_file "$STATE_ROOT/incidents.state" "estado preservado"
assert_file "$STATE_ROOT/history/metrics/metrics-2026-07-18.jsonl" "histórico preservado"
assert_file "$STATE_ROOT/incidents/emergency.txt" "incidentes preservados"

group "Purge segue opções do instalador existente"
if run_installer update; then pass "monitor reinstalado pelo update normal"; else fail "monitor reinstalado pelo update normal"; fi
if run_installer uninstall --monitor-only --purge-all; then pass "purge completo do monitor concluído"; else fail "purge completo do monitor concluído"; fi
assert_not_file "$INSTALL_ROOT/config/monitor.conf" "configuração do monitor removida no purge"
assert_not_file "$STATE_ROOT/incidents.state" "estado removido no purge"
assert_not_file "$STATE_ROOT/history/metrics/metrics-2026-07-18.jsonl" "histórico removido no purge"
assert_not_file "$STATE_ROOT/incidents/emergency.txt" "incidentes removidos no purge"
assert_contains "$INSTALL_ROOT/config/backup-destinations.conf" "token-m9-preservar" "purge do monitor não apaga credenciais compartilhadas"

group "Desinstalação completa preserva configuração e dados por padrão"
if run_installer update; then pass "instalação recomposta pelo fluxo normal"; else fail "instalação recomposta pelo fluxo normal"; fi
printf 'estado-pos-purge\n' > "$STATE_ROOT/incidents.state"
if run_installer uninstall; then pass "desinstalação completa concluída"; else fail "desinstalação completa concluída"; fi
assert_not_file "$INSTALL_ROOT/monitor/vps-monitor.sh" "monitor removido com o VPS Guardian"
assert_not_file "$SYSTEM_ROOT/usr/local/bin/vps-guardian" "wrapper global removido"
assert_file "$INSTALL_ROOT/config/backup-destinations.conf" "configuração compartilhada preservada"
assert_file "$STATE_ROOT/incidents.state" "dados mutáveis preservados"

printf '\nM9: %d grupos, %d asserts, %d falhas\n' "$TEST_GROUPS" "$ASSERTIONS" "$FAILURES"
[ "$FAILURES" -eq 0 ]
