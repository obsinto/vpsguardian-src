#!/bin/bash
################################################################################
# Script: test-monitor-alerts.sh
# Propósito: Testes do marco M5 — motor de alertas / incidentes
# Uso: ./monitor/tests/test-monitor-alerts.sh
#
# Todas as funções de rede de lib/notificacoes.sh são MOCKADAS. Nenhum teste
# chama o webhook real, envia notificação ou modifica o host.
################################################################################

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONITOR_DIR="$(dirname "$TESTS_DIR")"
ROOT_DIR="$(dirname "$MONITOR_DIR")"
FIXTURES="$TESTS_DIR/fixtures"

TEST_TMP=$(mktemp -d /tmp/vpsguardian-m5-test.XXXXXX)
trap 'rm -rf "$TEST_TMP"' EXIT

export MONITOR_CONFIG_FILE=/dev/null
export MONITOR_STATE_DIR="$TEST_TMP/state"
export DEBUG=0

source "$ROOT_DIR/lib/monitor-common.sh" || { echo "✗ monitor-common.sh"; exit 1; }
source "$ROOT_DIR/lib/notificacoes.sh"  || { echo "✗ notificacoes.sh"; exit 1; }
source "$ROOT_DIR/lib/monitor-alerts.sh" || { echo "✗ monitor-alerts.sh"; exit 1; }

monitor_load_config
monitor_init_dirs
export MONITOR_INCIDENT_STATE_FILE="$TEST_TMP/incidents.state"

echo "╔════════════════════════════════════════════════════════════╗"
echo "║          TESTES DO MONITOR PREVENTIVO (M5 — Alertas)       ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

ERROS=0
assert_eq() {
    if [ "$1" = "$2" ]; then echo "  ✓ $3"
    else echo "  ✗ $3 (esperado: '$1', obtido: '$2')"; ((ERROS++)); fi
}
assert_true() {
    if eval "$1"; then echo "  ✓ $2"
    else echo "  ✗ $2 (condição falhou: $1)"; ((ERROS++)); fi
}

# ---- Mock do transporte: registra chamadas e devolve rc configurável ----
CALLS_FILE="$TEST_TMP/calls.log"
: > "$CALLS_FILE"
MOCK_NOTIFY_RC=0
notify_monitor_incident() {
    # $1=type $2=title $3=description
    printf '%s\t%s\n' "$1" "$2" >> "$CALLS_FILE"
    return "${MOCK_NOTIFY_RC:-0}"
}
export -f notify_monitor_incident
mock_calls() { wc -l < "$CALLS_FILE" | tr -d ' '; }
mock_reset() { : > "$CALLS_FILE"; }

reset_all() {
    rm -f "$MONITOR_INCIDENT_STATE_FILE"
    monitor_alerts_reset_current
    mock_reset
    MONITOR_ALERT_DRY_RUN=false
    MONITOR_ALERT_DISCORD_ENABLED=true
    MONITOR_ALERTS_ENABLED=true
    MONITOR_ALERT_MIN_SEVERITY=WARNING
    MONITOR_ALERT_CONSECUTIVE=1
    MONITOR_ALERT_REMINDERS_ENABLED=false
    MOCK_NOTIFY_RC=0
}

state_field() {  # <key> <field-number>
    grep "^$1|" "$MONITOR_INCIDENT_STATE_FILE" 2>/dev/null | head -n1 | cut -d'|' -f"$2"
}

################################################################################
echo "🔍 Teste 1: Adaptador de canal (SUCCESS/FAILED/DISABLED)"
################################################################################

reset_all
MOCK_NOTIFY_RC=0
assert_eq "SUCCESS" "$(monitor_alert_channel_send info T D)" "envio ok => SUCCESS"
MOCK_NOTIFY_RC=1
assert_eq "FAILED" "$(monitor_alert_channel_send info T D)" "falha de rede => FAILED"
MOCK_NOTIFY_RC=2
assert_eq "DISABLED" "$(monitor_alert_channel_send info T D)" "sem webhook => DISABLED"
MOCK_NOTIFY_RC=0
MONITOR_ALERT_DISCORD_ENABLED=false
assert_eq "DISABLED" "$(monitor_alert_channel_send info T D)" "flag desabilitada => DISABLED"
MONITOR_ALERT_DISCORD_ENABLED=true
MONITOR_ALERT_DRY_RUN=true
mock_reset
assert_eq "DISABLED" "$(monitor_alert_channel_send info T D)" "dry-run => DISABLED (não envia)"
assert_eq "0" "$(mock_calls)" "dry-run não chamou o transporte"
MONITOR_ALERT_DRY_RUN=false
echo ""

# Início de um ciclo de coleta (como build_incidents faz no fluxo real)
begin_cycle() { monitor_alerts_reset_current; monitor_alerts_load_state; }

################################################################################
echo "🔍 Teste 2: Máquina de estados (função pura)"
################################################################################

# args: prev_status prev_sev prev_notified now cur_sev cooldown reminders
assert_eq "OPEN"     "$(monitor_incident_decide '' '' 0 1000 WARNING 900 false)"      "novo => OPEN"
assert_eq "NONE"     "$(monitor_incident_decide '' '' 0 1000 INFO 900 false)"         "INFO sem histórico => NONE"
assert_eq "ESCALATE" "$(monitor_incident_decide open WARNING 990 1000 CRITICAL 900 false)" "sobe severidade => ESCALATE"
assert_eq "SUPPRESS" "$(monitor_incident_decide open CRITICAL 990 1000 CRITICAL 900 false)" "mesma sev dentro do cooldown => SUPPRESS"
assert_eq "OPEN"     "$(monitor_incident_decide open CRITICAL 0 1000 CRITICAL 900 false)"    "aberto mas nunca enviado => OPEN (retry)"
assert_eq "RECOVER"  "$(monitor_incident_decide open CRITICAL 990 1000 INFO 900 false)"      "aberto e some => RECOVER"
assert_eq "NONE"     "$(monitor_incident_decide '' '' 0 1000 UNKNOWN 900 false)"       "UNKNOWN => NONE"
assert_eq "SUPPRESS" "$(monitor_incident_decide open WARNING 1500 2000 WARNING 900 true)" "reminder ligado mas dentro do cooldown => SUPPRESS"
assert_eq "SUPPRESS" "$(monitor_incident_decide open WARNING 100 5000 WARNING 900 false)" "reminder desligado, cooldown vencido => SUPPRESS"
assert_eq "REMINDER" "$(monitor_incident_decide open WARNING 100 5000 WARNING 900 true)" "reminder ligado e cooldown vencido => REMINDER"
echo ""

################################################################################
echo "🔍 Teste 3: notify_monitor_incident real sem webhook (sem rede)"
################################################################################

( unset -f notify_monitor_incident
  source "$ROOT_DIR/lib/notificacoes.sh"
  WEBHOOK_URL=""
  notify_monitor_incident info T D; echo "rc_empty=$?"
  WEBHOOK_URL="https://example.com/hook"
  notify_monitor_incident info T D; echo "rc_nondiscord=$?"
) > "$TEST_TMP/real.out" 2>&1
assert_eq "rc_empty=2" "$(grep rc_empty "$TEST_TMP/real.out")" "sem WEBHOOK_URL => 2 (DISABLED, sem curl)"
assert_eq "rc_nondiscord=2" "$(grep rc_nondiscord "$TEST_TMP/real.out")" "URL não-Discord => 2 (DISABLED)"
echo ""

################################################################################
echo "🔍 Teste 4: Abertura de incidente"
################################################################################

reset_all
begin_cycle
monitor_alert_register "host:memoria" CRITICAL "Memória disponível baixa" "842 MB"
monitor_alerts_process
assert_eq "1" "$ALERTS_OPENED" "1 incidente aberto"
assert_eq "1" "$(mock_calls)" "transporte chamado 1 vez"
assert_eq "SUCCESS" "$ALERTS_CHANNEL" "canal SUCCESS"
assert_eq "open" "$(state_field host:memoria 2)" "estado persistido como open"
assert_true '[ "$(state_field host:memoria 6)" -gt 0 ]' "last_notified atualizado após SUCCESS"
assert_true 'grep -q "Incidente detectado" "$CALLS_FILE"' "mensagem de abertura enviada"
echo ""

################################################################################
echo "🔍 Teste 5: Cooldown impede repetição (dedup por severidade)"
################################################################################

mock_reset
begin_cycle
monitor_alert_register "host:memoria" CRITICAL "Memória disponível baixa" "840 MB"
monitor_alerts_process
assert_eq "1" "$ALERTS_SUPPRESSED" "mesma severidade => suprimido"
assert_eq "0" "$(mock_calls)" "nenhuma nova notificação enviada"
echo ""

################################################################################
echo "🔍 Teste 6: Escalonamento"
################################################################################

mock_reset
begin_cycle
monitor_alert_register "host:memoria" EMERGENCY "Memória disponível baixa" "500 MB"
monitor_alerts_process
assert_eq "1" "$ALERTS_ESCALATED" "severidade subiu => escalonado"
assert_eq "1" "$(mock_calls)" "notificação de escalonamento enviada"
assert_true 'grep -q "Incidente escalou" "$CALLS_FILE"' "mensagem de escalonamento"
assert_eq "EMERGENCY" "$(state_field host:memoria 4)" "última severidade EMERGENCY"
echo ""

################################################################################
echo "🔍 Teste 7: Recuperação"
################################################################################

mock_reset
begin_cycle
# nenhum registro corrente => condição sumiu
monitor_alerts_process
assert_eq "1" "$ALERTS_RECOVERED" "incidente recuperado"
assert_eq "1" "$(mock_calls)" "notificação de recuperação enviada"
assert_true 'grep -q "Serviço normalizado" "$CALLS_FILE"' "mensagem de recuperação"
assert_true '! grep -q "^host:memoria|" "$MONITOR_INCIDENT_STATE_FILE"' "incidente removido do estado"
echo ""

################################################################################
echo "🔍 Teste 8: Falha de rede não descarta o incidente nem gera falsa recovery"
################################################################################

reset_all
MOCK_NOTIFY_RC=1   # falha
begin_cycle
monitor_alert_register "host:disco" CRITICAL "Disco quase cheio" "97%"
monitor_alerts_process
assert_eq "1" "$ALERTS_OPENED" "tentou abrir"
assert_eq "1" "$ALERTS_FAILED" "registrou falha de envio"
assert_eq "0" "$(state_field host:disco 6)" "last_notified permanece 0 após FAILED"
# próximo ciclo com o incidente ainda presente: deve RE-tentar (OPEN), não suprimir
mock_reset
begin_cycle
monitor_alert_register "host:disco" CRITICAL "Disco quase cheio" "97%"
monitor_alerts_process
assert_eq "1" "$ALERTS_OPENED" "retenta abertura após falha anterior"
echo ""

################################################################################
echo "🔍 Teste 9: Timeout tratado como FALHA (mock rc!=0)"
################################################################################

reset_all
MOCK_NOTIFY_RC=124   # simula timeout do curl
begin_cycle
monitor_alert_register "host:cpu" CRITICAL "CPU saturada" "99%"
monitor_alerts_process
assert_eq "FAILED" "$ALERTS_CHANNEL" "timeout => FAILED"
assert_eq "1" "$ALERTS_FAILED" "contabilizado como falha"
echo ""

################################################################################
echo "🔍 Teste 10: Severidade mínima e verificações consecutivas"
################################################################################

reset_all
MONITOR_ALERT_MIN_SEVERITY=CRITICAL
begin_cycle
monitor_alert_register "host:swap" WARNING "Swap elevado" "12%"
monitor_alerts_process
assert_eq "0" "$ALERTS_OPENED" "WARNING abaixo do mínimo (CRITICAL) não abre"
assert_eq "0" "$(mock_calls)" "nada enviado abaixo do mínimo"
MONITOR_ALERT_MIN_SEVERITY=WARNING

reset_all
MONITOR_ALERT_CONSECUTIVE=3
begin_cycle
monitor_alert_register "host:load" WARNING "Load alto" "ratio 2.0"
monitor_alerts_process
assert_eq "0" "$ALERTS_OPENED" "1ª verificação: pendente (não abre)"
assert_eq "1" "$ALERTS_PENDING" "marcado como pendente"
begin_cycle
monitor_alert_register "host:load" WARNING "Load alto" "ratio 2.0"
monitor_alerts_process
assert_eq "0" "$ALERTS_OPENED" "2ª verificação: ainda pendente"
begin_cycle
monitor_alert_register "host:load" WARNING "Load alto" "ratio 2.0"
monitor_alerts_process
assert_eq "1" "$ALERTS_OPENED" "3ª verificação consecutiva: abre"
MONITOR_ALERT_CONSECUTIVE=1
echo ""

################################################################################
echo "🔍 Teste 11: Segredo (WEBHOOK_URL) nunca aparece no estado"
################################################################################

reset_all
WEBHOOK_URL="https://discord.com/api/webhooks/SEGREDO_M5_123/token_SEGREDO"
begin_cycle
monitor_alert_register "host:memoria" CRITICAL "Memória baixa" "800 MB"
monitor_alerts_process
assert_true '! grep -q SEGREDO_M5 "$MONITOR_INCIDENT_STATE_FILE"' "webhook ausente do arquivo de estado"
WEBHOOK_URL=""
echo ""

################################################################################
echo "🔍 Teste 12: Fim a fim — check --dry-run não envia; segredo fora de JSON/KV"
################################################################################

E2E_ENV=(
    "MONITOR_CONFIG_FILE=/dev/null"
    "MONITOR_STATE_DIR=$TEST_TMP/e2e"
    "MONITOR_LOCK_FILE=$TEST_TMP/e2e.lock"
    "MONITOR_PROC_DIR=$FIXTURES/proc-overload"
    "MONITOR_SYS_CGROUP_DIR=$FIXTURES/cgroup-v2"
    "MONITOR_CPU_SAMPLE_INTERVAL=0"
    "MONITOR_DOCKER_BIN=/nonexistent/docker"
    "MONITOR_LARAVEL_WORKERS_ENABLED=false"
    "MONITOR_DISK_PATH=/"
    "WEBHOOK_URL=https://discord.com/api/webhooks/SEGREDO_E2E/xyz"
)

json_out=$(env "${E2E_ENV[@]}" "$MONITOR_DIR/vps-monitor.sh" check --dry-run --json 2>&1)
if command -v python3 &>/dev/null; then
    echo "$json_out" | python3 -m json.tool >/dev/null 2>&1
    assert_eq "0" "$?" "JSON válido com bloco alerts"
fi
assert_true 'echo "$json_out" | grep -q "\"engine_enabled\""' "JSON contém bloco alerts"
assert_true 'echo "$json_out" | grep -q "\"alerts_dry_run\": true"' "JSON reflete dry-run"
assert_true '! echo "$json_out" | grep -q SEGREDO_E2E' "webhook NUNCA no JSON"

kv_out=$(env "${E2E_ENV[@]}" "$MONITOR_DIR/vps-monitor.sh" check --dry-run --kv 2>&1)
assert_true 'echo "$kv_out" | grep -q "^alerts.dry_run=true"' "KV: dry-run refletido"
assert_true '! echo "$kv_out" | grep -q SEGREDO_E2E' "webhook NUNCA no KV"

state_out=$(cat "$TEST_TMP/e2e/incidents.state" 2>/dev/null)
assert_true '! echo "$state_out" | grep -q SEGREDO_E2E' "webhook NUNCA no estado"
echo ""

################################################################################
echo "🔍 Teste 13: Subcomando test-alert (dry-run e sem webhook)"
################################################################################

out=$(env MONITOR_CONFIG_FILE=/dev/null MONITOR_STATE_DIR="$TEST_TMP/ta" \
    "$MONITOR_DIR/vps-monitor.sh" test-alert --dry-run 2>&1)
assert_eq "0" "$?" "test-alert --dry-run sai com 0"
assert_true 'echo "$out" | grep -qi "dry-run"' "test-alert informa dry-run"

out=$(env MONITOR_CONFIG_FILE=/dev/null MONITOR_STATE_DIR="$TEST_TMP/ta2" WEBHOOK_URL="" \
    "$MONITOR_DIR/vps-monitor.sh" test-alert 2>&1)
assert_eq "0" "$?" "test-alert sem webhook sai com 0 (não é erro)"
assert_true 'echo "$out" | grep -qi "webhook"' "test-alert avisa que não há webhook"
echo ""

################################################################################
echo "🔍 Teste 14: Alertas antigos continuam funcionais e isolados"
################################################################################

( unset -f notify_monitor_incident
  source "$ROOT_DIR/lib/notificacoes.sh"
  WEBHOOK_URL=""
  send_discord_simple "T" "M" info; echo "simple_rc=$?"
  send_discord_detailed "T" "D" info "a|b"; echo "detailed_rc=$?"
) > "$TEST_TMP/old.out" 2>&1
assert_eq "simple_rc=0" "$(grep simple_rc "$TEST_TMP/old.out")" "send_discord_simple intacto (rc 0)"
assert_eq "detailed_rc=0" "$(grep detailed_rc "$TEST_TMP/old.out")" "send_discord_detailed intacto (rc 0)"

# Falha no motor novo não afeta chamada subsequente aos alertas antigos
reset_all
MOCK_NOTIFY_RC=1
begin_cycle
monitor_alert_register "host:memoria" CRITICAL "Memória baixa" "800 MB"
monitor_alerts_process
WEBHOOK_URL="" send_discord_simple "T" "M" info
assert_eq "0" "$?" "alerta antigo funciona após falha do motor novo"
echo ""

################################################################################
echo "🔍 Teste 15: Dry-run não altera o estado real (hash, mtime, contadores)"
################################################################################

reset_all
# 1. execução real cria estado com incidente aberto (SUCCESS avança notified/count)
begin_cycle
monitor_alert_register "host:memoria" CRITICAL "Mem baixa" "800 MB"
monitor_alerts_process
before_hash=$(sha256sum "$MONITOR_INCIDENT_STATE_FILE" | cut -d' ' -f1)
before_notified=$(state_field host:memoria 6)
before_count=$(state_field host:memoria 7)
before_mtime=$(stat -c %Y "$MONITOR_INCIDENT_STATE_FILE")
sleep 1   # garante que uma gravação mudaria o mtime
mock_reset

# 2. dry-run com escalonamento + novo incidente
MONITOR_ALERT_DRY_RUN=true
begin_cycle
monitor_alert_register "host:memoria" EMERGENCY "Mem baixa" "400 MB"
monitor_alert_register "host:disco" CRITICAL "Disco cheio" "98%"
monitor_alerts_process
MONITOR_ALERT_DRY_RUN=false

assert_eq "$before_hash" "$(sha256sum "$MONITOR_INCIDENT_STATE_FILE" | cut -d' ' -f1)" "estado byte-a-byte idêntico após dry-run"
assert_eq "0" "$(mock_calls)" "dry-run não chamou notify_monitor_incident"
assert_eq "$before_notified" "$(state_field host:memoria 6)" "last_notified inalterado"
assert_eq "$before_count" "$(state_field host:memoria 7)" "contador inalterado"
assert_eq "$before_mtime" "$(stat -c %Y "$MONITOR_INCIDENT_STATE_FILE")" "mtime inalterado"
assert_true '! grep -q "^host:disco|" "$MONITOR_INCIDENT_STATE_FILE"' "incidente simulado não persistido"
assert_eq "false" "$ALERTS_STATE_PERSISTED" "flag state_persisted=false"
assert_eq "false" "$ALERTS_NOTIFICATIONS_SENT" "flag notifications_sent=false"
assert_true 'printf "%s\n" "${ALERTS_DRYRUN_REPORT[@]}" | grep -q "WOULD_ESCALATE|host:memoria"' "mostra o escalonamento que ocorreria"
assert_true 'printf "%s\n" "${ALERTS_DRYRUN_REPORT[@]}" | grep -q "WOULD_OPEN|host:disco"' "mostra a abertura que ocorreria"
echo ""

################################################################################
echo "🔍 Teste 16: Dry-run sem estado prévio não cria arquivo; recovery simulada"
################################################################################

reset_all   # remove o arquivo de estado
MONITOR_ALERT_DRY_RUN=true
begin_cycle
monitor_alert_register "host:cpu" CRITICAL "CPU saturada" "99%"
monitor_alerts_process
MONITOR_ALERT_DRY_RUN=false
assert_true '[ ! -f "$MONITOR_INCIDENT_STATE_FILE" ]' "arquivo de estado NÃO criado em dry-run"
assert_true 'printf "%s\n" "${ALERTS_DRYRUN_REPORT[@]}" | grep -q "WOULD_OPEN|host:cpu"' "mostra abertura simulada"

# recovery simulada: estado real tem incidente aberto, dry-run sem a condição
reset_all
begin_cycle
monitor_alert_register "host:swap" CRITICAL "Swap alto" "60%"
monitor_alerts_process           # abre de verdade
rec_hash=$(sha256sum "$MONITOR_INCIDENT_STATE_FILE" | cut -d' ' -f1)
mock_reset
MONITOR_ALERT_DRY_RUN=true
begin_cycle                       # nenhuma condição corrente
monitor_alerts_process
MONITOR_ALERT_DRY_RUN=false
assert_true 'printf "%s\n" "${ALERTS_DRYRUN_REPORT[@]}" | grep -q "WOULD_RECOVER|host:swap"' "mostra a recuperação que ocorreria"
assert_eq "0" "$(mock_calls)" "recovery simulada não envia"
assert_eq "$rec_hash" "$(sha256sum "$MONITOR_INCIDENT_STATE_FILE" | cut -d' ' -f1)" "incidente NÃO recuperado de verdade (estado intacto)"
assert_true 'grep -q "^host:swap|" "$MONITOR_INCIDENT_STATE_FILE"' "incidente real permanece aberto"
echo ""

################################################################################
echo "🔍 Teste 17: Dry-runs consecutivos não acumulam; real abre normalmente"
################################################################################

reset_all
for i in 1 2 3; do
    MONITOR_ALERT_DRY_RUN=true
    begin_cycle
    monitor_alert_register "host:load" CRITICAL "Load alto" "ratio 5"
    monitor_alerts_process
    MONITOR_ALERT_DRY_RUN=false
done
assert_true '[ ! -f "$MONITOR_INCIDENT_STATE_FILE" ]' "nenhum estado após 3 dry-runs"

mock_reset
begin_cycle
monitor_alert_register "host:load" CRITICAL "Load alto" "ratio 5"
monitor_alerts_process
assert_eq "1" "$ALERTS_OPENED" "execução real abre normalmente após os dry-runs"
assert_eq "1" "$(mock_calls)" "notificação real enviada"
assert_eq "1" "$(state_field host:load 8)" "streak começa em 1 (dry-runs não acumularam)"
assert_eq "1" "$(state_field host:load 7)" "contador começa em 1 (sem acúmulo)"
echo ""

################################################################################
echo "🔍 Teste 18: E2E — check --dry-run preserva estado; JSON/KV/segredo"
################################################################################

E2E=(
    "MONITOR_CONFIG_FILE=/dev/null"
    "MONITOR_STATE_DIR=$TEST_TMP/dre2e"
    "MONITOR_LOCK_FILE=$TEST_TMP/dre2e.lock"
    "MONITOR_PROC_DIR=$FIXTURES/proc-overload"
    "MONITOR_SYS_CGROUP_DIR=$FIXTURES/cgroup-v2"
    "MONITOR_CPU_SAMPLE_INTERVAL=0"
    "MONITOR_DOCKER_BIN=/nonexistent/docker"
    "MONITOR_LARAVEL_WORKERS_ENABLED=false"
    "WEBHOOK_URL=https://discord.com/api/webhooks/SEGREDO_DRE2E/xyz"
)
STATE="$TEST_TMP/dre2e/incidents.state"

# 1. execução real cria estado
env "${E2E[@]}" "$MONITOR_DIR/vps-monitor.sh" check >/dev/null 2>&1
h_before=$(sha256sum "$STATE" | cut -d' ' -f1)

# 2. dry-run via subprocesso não altera o estado
json_out=$(env "${E2E[@]}" "$MONITOR_DIR/vps-monitor.sh" check --dry-run --json 2>&1)
h_after=$(sha256sum "$STATE" | cut -d' ' -f1)
assert_eq "$h_before" "$h_after" "check --dry-run preserva o estado (sha256 idêntico)"

if command -v python3 &>/dev/null; then
    echo "$json_out" | python3 -m json.tool >/dev/null 2>&1
    assert_eq "0" "$?" "JSON continua válido em dry-run"
fi
assert_true 'echo "$json_out" | grep -q "\"alerts_dry_run\": true"' "JSON: alerts_dry_run=true"
assert_true 'echo "$json_out" | grep -q "\"state_persisted\": false"' "JSON: state_persisted=false"
assert_true 'echo "$json_out" | grep -q "\"notifications_sent\": false"' "JSON: notifications_sent=false"
assert_true '! echo "$json_out" | grep -q SEGREDO_DRE2E' "webhook NUNCA no JSON (dry-run)"

kv_out=$(env "${E2E[@]}" "$MONITOR_DIR/vps-monitor.sh" check --dry-run --kv 2>&1)
assert_true 'echo "$kv_out" | grep -q "^alerts.dry_run=true"' "KV: alerts.dry_run=true"
assert_true 'echo "$kv_out" | grep -q "^alerts.state_persisted=false"' "KV: alerts.state_persisted=false"
assert_true 'echo "$kv_out" | grep -q "^alerts.notifications_sent=false"' "KV: alerts.notifications_sent=false"
assert_true '! echo "$kv_out" | grep -q SEGREDO_DRE2E' "webhook NUNCA no KV (dry-run)"

# 3. nenhum diretório temporário de dry-run remanescente (abordagem em memória)
assert_true '! ls -d /tmp/vpsguardian-dry-run.* 2>/dev/null | grep -q .' "nenhum temp de dry-run remanescente"

# 4. --no-alerts também não cria/altera estado
rm -rf "$TEST_TMP/na"
env MONITOR_CONFIG_FILE=/dev/null MONITOR_STATE_DIR="$TEST_TMP/na" \
    MONITOR_PROC_DIR="$FIXTURES/proc-overload" MONITOR_SYS_CGROUP_DIR="$FIXTURES/cgroup-v2" \
    MONITOR_CPU_SAMPLE_INTERVAL=0 MONITOR_DOCKER_BIN=/nonexistent/docker \
    MONITOR_LARAVEL_WORKERS_ENABLED=false \
    "$MONITOR_DIR/vps-monitor.sh" check --no-alerts >/dev/null 2>&1
assert_true '[ ! -f "$TEST_TMP/na/incidents.state" ]' "--no-alerts não cria estado de incidentes"
echo ""

################################################################################
echo "════════════════════════════════════════════════════════════"
if [ "$ERROS" -eq 0 ]; then
    echo "✅ Todos os testes passaram"
    exit 0
else
    echo "❌ $ERROS teste(s) falharam"
    exit 1
fi
