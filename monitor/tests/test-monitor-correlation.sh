#!/bin/bash
################################################################################
# Script: test-monitor-correlation.sh
# Propósito: Testes do marco M6 — correlação de sintomas e diagnóstico
# Uso: ./monitor/tests/test-monitor-correlation.sh
#
# As funções de avaliação são puras (leem o mapa CORR). Nenhum teste faz coleta
# real, chama webhook, modifica o host ou depende de Docker/Coolify.
################################################################################

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONITOR_DIR="$(dirname "$TESTS_DIR")"
ROOT_DIR="$(dirname "$MONITOR_DIR")"
FIXTURES="$TESTS_DIR/fixtures"

TEST_TMP=$(mktemp -d /tmp/vpsguardian-m6-test.XXXXXX)
trap 'rm -rf "$TEST_TMP"' EXIT

export MONITOR_CONFIG_FILE=/dev/null
export MONITOR_STATE_DIR="$TEST_TMP/state"
export MONITOR_DIAG_STATE_FILE="$TEST_TMP/diagnoses.state"
export MONITOR_INCIDENT_STATE_FILE="$TEST_TMP/incidents.state"
export DEBUG=0

source "$ROOT_DIR/lib/monitor-common.sh" || { echo "✗ monitor-common.sh"; exit 1; }
source "$ROOT_DIR/lib/notificacoes.sh"  || { echo "✗ notificacoes.sh"; exit 1; }
source "$ROOT_DIR/lib/monitor-alerts.sh" || { echo "✗ monitor-alerts.sh"; exit 1; }
source "$ROOT_DIR/lib/monitor-correlation.sh" || { echo "✗ monitor-correlation.sh"; exit 1; }
monitor_load_config
monitor_init_dirs
export MONITOR_DIAG_STATE_FILE="$TEST_TMP/diagnoses.state"
export MONITOR_INCIDENT_STATE_FILE="$TEST_TMP/incidents.state"

# Mock do transporte (nunca chama rede)
CALLS="$TEST_TMP/calls.log"; : > "$CALLS"
notify_monitor_incident() { printf '%s\n' "$2" >> "$CALLS"; return 0; }
export -f notify_monitor_incident
mock_calls() { wc -l < "$CALLS" | tr -d ' '; }
mock_reset() { : > "$CALLS"; }

echo "╔════════════════════════════════════════════════════════════╗"
echo "║        TESTES DO MONITOR PREVENTIVO (M6 — Correlação)      ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

ERROS=0
assert_eq() { if [ "$1" = "$2" ]; then echo "  ✓ $3"; else echo "  ✗ $3 (esperado: '$1', obtido: '$2')"; ((ERROS++)); fi; }
assert_true() { if eval "$1"; then echo "  ✓ $2"; else echo "  ✗ $2 (falhou: $1)"; ((ERROS++)); fi; }

# Limpa o mapa de sinais
cs() { CORR=(); }

# Diagnóstico presente com prefixo? role/conf de um diagnóstico por prefixo
diag_idx() { local p="$1" i; for ((i=0;i<DIAG_N;i++)); do case "${D_KEY[$i]}" in "$p"*) echo "$i"; return 0;; esac; done; return 1; }
diag_field() { local i; i=$(diag_idx "$1") || { echo ""; return 1; }; local f="$2"; eval "echo \"\${D_${f}[$i]}\""; }

################################################################################
echo "🔍 Teste 1: Confiança e ocorrências (funções puras)"
################################################################################
assert_eq "NONE" "$(monitor_correlation_confidence 0)" "score 0 => NONE"
assert_eq "LOW" "$(monitor_correlation_confidence 39)" "score 39 => LOW"
assert_eq "MEDIUM" "$(monitor_correlation_confidence 40)" "score 40 => MEDIUM"
assert_eq "HIGH" "$(monitor_correlation_confidence 65)" "score 65 => HIGH"
assert_eq "VERY_HIGH" "$(monitor_correlation_confidence 85)" "score 85 => VERY_HIGH"
assert_eq "1" "$(monitor_correlation_required_occurrences VERY_HIGH)" "VERY_HIGH => 1 ocorrência"
assert_eq "2" "$(monitor_correlation_required_occurrences HIGH)" "HIGH => 2"
assert_eq "3" "$(monitor_correlation_required_occurrences MEDIUM)" "MEDIUM => 3"
assert_eq "0" "$(monitor_correlation_required_occurrences LOW)" "LOW => 0 (nunca)"
monitor_correlation_eligible VERY_HIGH 1 && echo "  ✓ VERY_HIGH imediato elegível" || { echo "  ✗ VERY_HIGH"; ((ERROS++)); }
monitor_correlation_eligible MEDIUM 2 && { echo "  ✗ MEDIUM com 2 não deveria"; ((ERROS++)); } || echo "  ✓ MEDIUM exige 3 (2 não basta)"
echo ""

################################################################################
echo "🔍 Teste 2: Cenário A — memória (variações e confiança)"
################################################################################
cs; CORR[mem_severity]=WARNING; CORR[mem_available_mb]=1800
monitor_correlation_eval_memory
assert_eq "LOW" "$EVAL_CONF" "memória baixa isolada => baixa confiança"
assert_eq "MEMORY_PRESSURE" "$EVAL_SCENARIO" "variação MEMORY_PRESSURE"

cs; CORR[mem_severity]=WARNING; CORR[swap_severity]=CRITICAL; CORR[swap_used_percent]=25
monitor_correlation_eval_memory
assert_eq "MEMORY_PRESSURE" "$EVAL_SCENARIO" "mem baixa + swap alta => pressão de memória"

cs; CORR[mem_severity]=CRITICAL; CORR[mem_available_mb]=800; CORR[swap_severity]=CRITICAL
CORR[swap_growth_mb]=120; CORR[iowait_severity]=WARNING
monitor_correlation_eval_memory
assert_true '[ "$(monitor_correlation_conf_rank "$EVAL_CONF")" -ge 3 ]' "mem crítica+swap+iowait => alta confiança"
assert_eq "SWAP_DEATH_LIKELY" "$EVAL_SCENARIO" "=> SWAP_DEATH_LIKELY"

cs; CORR[mem_severity]=INFO; CORR[swap_severity]=CRITICAL; CORR[swap_used_percent]=95
monitor_correlation_eval_memory
assert_eq "SWAP_PRESSURE" "$EVAL_SCENARIO" "swap alta SEM mem crítica => NÃO é swap-death"
echo ""

################################################################################
echo "🔍 Teste 3: Cenário D — Docker vítima do host"
################################################################################
cs; CORR[docker_installed]=true; CORR[docker_status]=SLOW; CORR[docker_ps_ok]=true
CORR[containerd_responsive]=true; CORR[dockerd_pid]=100; CORR[mem_severity]=INFO
monitor_correlation_eval_docker
assert_true '[ "$EVAL_SCENARIO" != "DOCKER_DEGRADED_BY_HOST" ]' "docker lento + host saudável NÃO é vítima do host"

cs; CORR[docker_installed]=true; CORR[docker_status]=SLOW; CORR[docker_ps_ok]=true
CORR[containerd_responsive]=true; CORR[dockerd_pid]=100; CORR[swap_severity]=CRITICAL
monitor_correlation_eval_docker
assert_eq "DOCKER_DEGRADED_BY_HOST" "$EVAL_SCENARIO" "docker lento + swap crítica => vítima do host"

cs; CORR[docker_installed]=true; CORR[docker_ps_ok]=false; CORR[containerd_responsive]=true
CORR[containerd_status]=HEALTHY; CORR[dockerd_pid]=100; CORR[mem_severity]=INFO
monitor_correlation_eval_docker
assert_true 'echo "$EVAL_SCENARIO" | grep -qE "CONTAINERD_HEALTHY_DOCKER_SLOW|DOCKER_DEGRADED_BY_HOST"' "docker sem resposta + containerd ok"

cs; CORR[docker_installed]=true; CORR[docker_ps_ok]=false; CORR[containerd_status]=UNRESPONSIVE
CORR[containerd_responsive]=false; CORR[mem_severity]=CRITICAL
monitor_correlation_eval_docker
assert_eq "DOCKER_STACK_UNAVAILABLE" "$EVAL_SCENARIO" "docker e containerd indisponíveis"
echo ""

################################################################################
echo "🔍 Teste 4: Cenário B — throttling do provedor"
################################################################################
cs; CORR[steal_severity]=CRITICAL; CORR[cpu_steal_percent]=25; CORR[mem_severity]=INFO
CORR[swap_severity]=INFO; CORR[swap_used_percent]=0; CORR[iowait_severity]=INFO
monitor_correlation_eval_throttling
assert_eq "PROVIDER_THROTTLING_SUSPECTED" "$EVAL_SCENARIO" "steal alto + memória saudável => throttling do provedor"
assert_true '[ "$(monitor_correlation_conf_rank "$EVAL_CONF")" -ge 2 ]' "confiança MEDIUM+"

cs; CORR[cgroup_throttled_delta]=50; CORR[cpu_severity]=CRITICAL; CORR[mem_severity]=INFO
monitor_correlation_eval_throttling
assert_true 'echo "$EVAL_EVIDENCE" | grep -q "throttling de cgroup"' "nr_throttled crescendo é evidência"

# container atingindo a própria quota NÃO é sinal de host => sem diagnóstico de provedor
cs; CORR[mem_severity]=INFO; CORR[steal_severity]=INFO
monitor_correlation_eval_throttling
assert_eq "0" "$EVAL_SCORE" "quota de container (sem steal do host) => sem throttling do provedor"

cs; CORR[steal_severity]=CRITICAL; CORR[cpu_steal_percent]=22; CORR[docker_status]=SLOW
CORR[docker_ps_latency_ms]=3000; CORR[mem_severity]=INFO; CORR[iowait_severity]=INFO
monitor_correlation_eval_throttling
assert_eq "PROVIDER_THROTTLING_SUSPECTED" "$EVAL_SCENARIO" "steal alto + docker lento => throttling provável"
echo ""

################################################################################
echo "🔍 Teste 5: Cenário C — worker Laravel"
################################################################################
cs; CORR[laravel_total]=1; CORR[laravel_max_timeout]=60; CORR[laravel_max_group_count]=1
CORR[laravel_max_severity]=INFO
monitor_correlation_eval_laravel
assert_eq "0" "$EVAL_SCORE" "worker saudável isolado => nenhum diagnóstico"

cs; CORR[laravel_total]=1; CORR[laravel_max_timeout]=36000; CORR[laravel_max_group_count]=1
monitor_correlation_eval_laravel
assert_true '[ "$EVAL_SCORE" -gt 0 ]' "timeout 36000 isolado => gera diagnóstico Laravel"

cs; CORR[laravel_total]=6; CORR[laravel_max_timeout]=36000; CORR[laravel_max_group_count]=6
monitor_correlation_eval_laravel
assert_true '[ "$EVAL_SCORE" -ge 55 ]' "6 workers + timeout alto => score alto"

cs; CORR[laravel_total]=1; CORR[laravel_max_timeout]=0; CORR[laravel_max_group_count]=1
CORR[laravel_containers_no_mem_limit]=1; CORR[mem_severity]=CRITICAL
monitor_correlation_eval_laravel
assert_true 'echo "$EVAL_EVIDENCE" | grep -q "sem limite de memória"' "worker sem limite + memória crítica"

cs; CORR[laravel_total]=1; CORR[laravel_shared_with_web]=1; CORR[laravel_max_group_count]=1
monitor_correlation_eval_laravel
assert_true 'echo "$EVAL_EVIDENCE" | grep -q "compartilhado com servidor web"' "worker compartilhado com web"

cs; CORR[laravel_total]=1; CORR[laravel_schedule_stuck]=true; CORR[laravel_max_group_count]=1
monitor_correlation_eval_laravel
assert_eq "SCHEDULE_RUN_STUCK" "$EVAL_SCENARIO" "schedule:run travado"

cs; CORR[laravel_total]=2; CORR[laravel_restart_loop]=true; CORR[laravel_max_group_count]=2
monitor_correlation_eval_laravel
assert_true 'echo "$EVAL_EVIDENCE" | grep -q "restart loop"' "restart loop de worker"
echo ""

################################################################################
echo "🔍 Teste 6: Fixture do incidente — encadeamento causal completo"
################################################################################
(
  cs
  # shellcheck disable=SC1090
  source "$FIXTURES/correlation/incident.env"
  monitor_correlation_compute

  assert_eq "diagnosis:laravel:bbb222222222:laravel_worker_misconfiguration" "$DIAG_MAIN_KEY" "principal = Laravel misconfiguration"
  assert_eq "VERY_HIGH" "$DIAG_HIGHEST_CONF" "maior confiança VERY_HIGH"
  assert_eq "EMERGENCY" "$DIAG_HIGHEST_SEV" "maior severidade EMERGENCY"

  assert_eq "ROOT_CAUSE" "$(diag_field diagnosis:laravel: ROLE)" "Laravel => ROOT_CAUSE"
  assert_eq "VERY_HIGH" "$(diag_field diagnosis:laravel: CONF)" "Laravel VERY_HIGH"
  assert_eq "AMPLIFIER" "$(diag_field diagnosis:memory: ROLE)" "memória (swap-death) => AMPLIFIER"
  assert_eq "SWAP_DEATH_LIKELY" "$(diag_field diagnosis:memory: SCENARIO)" "=> SWAP_DEATH_LIKELY"
  assert_eq "IMPACT" "$(diag_field diagnosis:docker: ROLE)" "Docker => IMPACT"
  assert_eq "DOCKER_DEGRADED_BY_HOST" "$(diag_field diagnosis:docker: SCENARIO)" "=> DOCKER_DEGRADED_BY_HOST"
  assert_eq "CONTRIBUTING_FACTOR" "$(diag_field diagnosis:provider: ROLE)" "throttling => CONTRIBUTING_FACTOR"
  exit $ERROS
)
ERROS=$((ERROS + $?))
echo ""

################################################################################
echo "🔍 Teste 7: Evidências contrárias e dados ausentes reduzem confiança"
################################################################################
# throttling: steal alto mas memória saturada (contraindício) reduz score
cs; CORR[steal_severity]=CRITICAL; CORR[cpu_steal_percent]=25; CORR[mem_severity]=INFO; CORR[iowait_severity]=INFO
monitor_correlation_eval_throttling; s_full="$EVAL_SCORE"
cs; CORR[steal_severity]=CRITICAL; CORR[cpu_steal_percent]=25; CORR[mem_severity]=CRITICAL; CORR[iowait_severity]=INFO
monitor_correlation_eval_throttling; s_counter="$EVAL_SCORE"
assert_true '[ "$s_counter" -lt "$s_full" ]' "memória saturada reduz score de throttling"

# dados ausentes: memória crítica sem os demais sinais => confiança menor que completo
cs; CORR[mem_severity]=CRITICAL; CORR[mem_available_mb]=800
monitor_correlation_eval_memory; s_partial="$EVAL_SCORE"
cs; CORR[mem_severity]=CRITICAL; CORR[mem_available_mb]=800; CORR[swap_severity]=CRITICAL; CORR[swap_growth_mb]=100; CORR[iowait_severity]=WARNING
monitor_correlation_eval_memory; s_complete="$EVAL_SCORE"
assert_true '[ "$s_partial" -lt "$s_complete" ]' "dados ausentes reduzem a confiança (sem abortar)"
echo ""

################################################################################
echo "🔍 Teste 8: Ordem dos dados não altera o resultado (determinismo)"
################################################################################
cs; CORR[mem_severity]=CRITICAL; CORR[swap_severity]=CRITICAL; CORR[swap_growth_mb]=100; CORR[iowait_severity]=WARNING
monitor_correlation_eval_memory; r1="$EVAL_SCENARIO|$EVAL_SCORE|$EVAL_CONF"
cs; CORR[iowait_severity]=WARNING; CORR[swap_growth_mb]=100; CORR[swap_severity]=CRITICAL; CORR[mem_severity]=CRITICAL
monitor_correlation_eval_memory; r2="$EVAL_SCENARIO|$EVAL_SCORE|$EVAL_CONF"
assert_eq "$r1" "$r2" "mesmo resultado independente da ordem de inserção"
# duas execuções idênticas => idênticas (determinístico)
monitor_correlation_eval_memory; r3="$EVAL_SCENARIO|$EVAL_SCORE|$EVAL_CONF"
assert_eq "$r1" "$r3" "regra determinística"
echo ""

################################################################################
echo "🔍 Teste 9: Fingerprint — variação numérica x mudança material"
################################################################################
fp1=$(monitor_correlation_fingerprint SWAP_DEATH_LIKELY host VERY_HIGH EMERGENCY AMPLIFIER "memória crítica (742 MB);;swap 99%")
fp2=$(monitor_correlation_fingerprint SWAP_DEATH_LIKELY host VERY_HIGH EMERGENCY AMPLIFIER "memória crítica (738 MB);;swap 97%")
assert_eq "$fp1" "$fp2" "variação numérica pequena NÃO altera o fingerprint"
fp3=$(monitor_correlation_fingerprint SWAP_DEATH_LIKELY host HIGH EMERGENCY AMPLIFIER "memória crítica (742 MB);;swap 99%")
assert_true '[ "$fp1" != "$fp3" ]' "mudança de faixa de confiança altera o fingerprint"
fp4=$(monitor_correlation_fingerprint SWAP_DEATH_LIKELY host VERY_HIGH EMERGENCY ROOT_CAUSE "memória crítica (742 MB);;swap 99%")
assert_true '[ "$fp1" != "$fp4" ]' "mudança de papel causal altera o fingerprint"
echo ""

################################################################################
echo "🔍 Teste 10: Integração M5 — confirmação por confiança e recovery"
################################################################################
rm -f "$MONITOR_DIAG_STATE_FILE" "$MONITOR_INCIDENT_STATE_FILE"
MONITOR_ALERT_DRY_RUN=false; MONITOR_ALERT_DISCORD_ENABLED=true; MONITOR_ALERTS_ENABLED=true
MONITOR_ALERT_CONSECUTIVE=1; MONITOR_ALERT_MIN_SEVERITY=WARNING

# Um diagnóstico MEDIUM não deve alertar até 3 ocorrências
sim_medium() {
    cs; monitor_correlation_reset
    # força um único diagnóstico MEDIUM de memória (score ~45)
    EVAL_SCORE=45 EVAL_CONF=MEDIUM EVAL_SEV=WARNING EVAL_SCENARIO=MEMORY_PRESSURE
    EVAL_KEY="diagnosis:memory:pressure" EVAL_RTYPE=host EVAL_RID=host
    EVAL_TITLE="Pressão de memória" EVAL_SUMMARY="x" EVAL_CAUSE="x" EVAL_IMPACT="x"
    EVAL_EVIDENCE="memória baixa" EVAL_COUNTER="" EVAL_RECS="a;;b" EVAL_RELATED="host:memoria"
    _corr_add_from_eval
    monitor_correlation_assign_roles
    monitor_alerts_load_state; monitor_alerts_reset_current
    monitor_correlation_register
    monitor_alerts_process
}
mock_reset; sim_medium
assert_eq "0" "$(mock_calls)" "MEDIUM 1ª ocorrência: não alerta"
mock_reset; sim_medium
assert_eq "0" "$(mock_calls)" "MEDIUM 2ª ocorrência: não alerta"
mock_reset; sim_medium
assert_eq "1" "$(mock_calls)" "MEDIUM 3ª ocorrência: alerta (confirmado)"
assert_true 'grep -q "^diagnosis:memory:pressure|" "$MONITOR_INCIDENT_STATE_FILE"' "diagnóstico virou incidente M5"

# VERY_HIGH deve alertar imediatamente
rm -f "$MONITOR_DIAG_STATE_FILE" "$MONITOR_INCIDENT_STATE_FILE"
sim_vh() {
    cs; monitor_correlation_reset
    EVAL_SCORE=90 EVAL_CONF=VERY_HIGH EVAL_SEV=EMERGENCY EVAL_SCENARIO=SWAP_DEATH_LIKELY
    EVAL_KEY="diagnosis:memory:swap_death" EVAL_RTYPE=host EVAL_RID=host
    EVAL_TITLE="Swap-death" EVAL_SUMMARY="x" EVAL_CAUSE="x" EVAL_IMPACT="x"
    EVAL_EVIDENCE="mem crítica" EVAL_COUNTER="" EVAL_RECS="a" EVAL_RELATED="host:memoria"
    _corr_add_from_eval; monitor_correlation_assign_roles
    monitor_alerts_load_state; monitor_alerts_reset_current
    monitor_correlation_register; monitor_alerts_process
}
mock_reset; sim_vh
assert_eq "1" "$(mock_calls)" "VERY_HIGH: alerta imediato"

# Recovery: diagnóstico some => incidente recupera
mock_reset
cs; monitor_correlation_reset
monitor_alerts_load_state; monitor_alerts_reset_current
monitor_correlation_register; monitor_alerts_process
assert_eq "1" "$ALERTS_RECOVERED" "diagnóstico ausente => recuperação"
echo ""

################################################################################
echo "🔍 Teste 11: LOW não alerta; alertas brutos preservados"
################################################################################
rm -f "$MONITOR_DIAG_STATE_FILE" "$MONITOR_INCIDENT_STATE_FILE"
mock_reset
cs; monitor_correlation_reset
EVAL_SCORE=20 EVAL_CONF=LOW EVAL_SEV=WARNING EVAL_SCENARIO=MEMORY_PRESSURE
EVAL_KEY="diagnosis:memory:pressure" EVAL_RTYPE=host EVAL_RID=host EVAL_TITLE="x" EVAL_SUMMARY="x"
EVAL_CAUSE="x" EVAL_IMPACT="x" EVAL_EVIDENCE="x" EVAL_COUNTER="" EVAL_RECS="a" EVAL_RELATED=""
_corr_add_from_eval; monitor_correlation_assign_roles
monitor_alerts_load_state; monitor_alerts_reset_current
# registra também um alerta bruto de host
monitor_alert_register "host:disco" CRITICAL "Disco cheio" "97%"
monitor_correlation_register; monitor_alerts_process
assert_true '! grep -q "^diagnosis:" "$MONITOR_INCIDENT_STATE_FILE"' "diagnóstico LOW NÃO gera alerta"
assert_true 'grep -q "^host:disco|" "$MONITOR_INCIDENT_STATE_FILE"' "alerta bruto individual preservado"
echo ""

################################################################################
echo "🔍 Teste 12: Dados parciais — Docker/Coolify ausentes não impedem Laravel"
################################################################################
cs
# Sem nenhum sinal de Docker/Coolify, apenas workers
CORR[laravel_total]=6; CORR[laravel_max_timeout]=36000; CORR[laravel_max_group_count]=6
CORR[laravel_containers_no_mem_limit]=1
monitor_correlation_eval_laravel
assert_true '[ "$EVAL_SCORE" -gt 0 ]' "Docker indisponível NÃO impede diagnóstico Laravel"
assert_true 'echo "$EVAL_KEY" | grep -q "^diagnosis:laravel:"' "chave de diagnóstico Laravel gerada"

# Host saudável => nenhum diagnóstico
cs; CORR[mem_severity]=INFO; CORR[swap_severity]=INFO; CORR[load_severity]=INFO
CORR[cpu_severity]=INFO; CORR[steal_severity]=INFO; CORR[iowait_severity]=INFO
CORR[docker_installed]=true; CORR[docker_status]=HEALTHY; CORR[docker_ps_ok]=true; CORR[laravel_total]=0
monitor_correlation_reset
monitor_correlation_eval_memory; _corr_add_from_eval
monitor_correlation_eval_throttling; _corr_add_from_eval
monitor_correlation_eval_laravel; _corr_add_from_eval
monitor_correlation_eval_docker; _corr_add_from_eval
assert_eq "0" "$DIAG_N" "host saudável => nenhum diagnóstico"
echo ""

################################################################################
echo "🔍 Teste 13: Dry-run — não grava estado, não chama webhook (E2E)"
################################################################################
E2E=(
    "MONITOR_CONFIG_FILE=/dev/null"
    "MONITOR_STATE_DIR=$TEST_TMP/e2e"
    "MONITOR_LOCK_FILE=$TEST_TMP/e2e.lock"
    "MONITOR_PROC_DIR=$FIXTURES/proc-overload"
    "MONITOR_SYS_CGROUP_DIR=$FIXTURES/cgroup-v2"
    "MONITOR_CPU_SAMPLE_INTERVAL=0"
    "MONITOR_DOCKER_BIN=/nonexistent/docker"
    "MONITOR_LARAVEL_WORKERS_ENABLED=false"
    "WEBHOOK_URL=https://discord.com/api/webhooks/SEGREDO_M6/xyz"
)
mkdir -p "$TEST_TMP/e2e"
# cria estado real
env "${E2E[@]}" "$MONITOR_DIR/vps-monitor.sh" check >/dev/null 2>&1
h_before=$(sha256sum "$TEST_TMP/e2e/incidents.state" 2>/dev/null | cut -d' ' -f1)
dh_before=$(sha256sum "$TEST_TMP/e2e/diagnoses.state" 2>/dev/null | cut -d' ' -f1)
# dry-run
json=$(env "${E2E[@]}" "$MONITOR_DIR/vps-monitor.sh" check --dry-run --json 2>&1)
h_after=$(sha256sum "$TEST_TMP/e2e/incidents.state" 2>/dev/null | cut -d' ' -f1)
dh_after=$(sha256sum "$TEST_TMP/e2e/diagnoses.state" 2>/dev/null | cut -d' ' -f1)
assert_eq "$h_before" "$h_after" "dry-run preserva incidents.state (hash)"
assert_eq "$dh_before" "$dh_after" "dry-run preserva diagnoses.state (hash)"
if command -v python3 &>/dev/null; then
    echo "$json" | python3 -m json.tool >/dev/null 2>&1
    assert_eq "0" "$?" "JSON válido com diagnostics"
fi
assert_true 'echo "$json" | grep -q "diagnostics_summary"' "JSON contém diagnostics_summary"
assert_true '! echo "$json" | grep -q SEGREDO_M6' "webhook NUNCA no JSON"
kv=$(env "${E2E[@]}" "$MONITOR_DIR/vps-monitor.sh" check --dry-run --kv 2>&1)
assert_true 'echo "$kv" | grep -q "^diagnostics.total="' "KV contém diagnostics.total"
assert_true '! echo "$kv" | grep -q SEGREDO_M6' "webhook NUNCA no KV"
echo ""

################################################################################
echo "🔍 Teste 14: Nenhum segredo nas evidências"
################################################################################
(
  cs; source "$FIXTURES/correlation/incident.env"
  monitor_correlation_compute
  json_out=$(monitor_correlation_json)
  echo "$json_out" | grep -qiE 'token|password|secret|webhook' && { echo "  ✗ segredo em evidência"; exit 1; }
  echo "  ✓ nenhuma evidência contém termos sensíveis"
  exit 0
) || ((ERROS++))
echo ""

################################################################################
echo "🔍 Teste 15: Recomendações corretas por cenário"
################################################################################
cs; CORR[steal_severity]=CRITICAL; CORR[cpu_steal_percent]=25; CORR[mem_severity]=INFO; CORR[iowait_severity]=INFO
monitor_correlation_eval_throttling
assert_true 'echo "$EVAL_RECS" | grep -qi "provedor"' "recomendação de throttling menciona provedor"
cs; CORR[laravel_total]=6; CORR[laravel_max_timeout]=36000; CORR[laravel_max_group_count]=6
monitor_correlation_eval_laravel
assert_true 'echo "$EVAL_RECS" | grep -qi "timeout"' "recomendação Laravel menciona timeout"
cs; CORR[docker_installed]=true; CORR[docker_ps_ok]=false; CORR[containerd_responsive]=true; CORR[swap_severity]=CRITICAL
monitor_correlation_eval_docker
assert_true 'echo "$EVAL_RECS" | grep -qi "containerd"' "recomendação Docker menciona containerd"
echo ""

################################################################################
echo "🔍 Teste 16: Timeout e quantidade de aplicações distintas não são combinados"
################################################################################
cs
LARAVEL_TOTAL=13; LARAVEL_HORIZON_WORKERS=1; LARAVEL_DANGEROUS_TIMEOUTS=1
LARAVEL_SHARED_WITH_WEB=1; LARAVEL_CONTAINERS_NO_MEM_LIMIT=2; LARAVEL_MAX_SEVERITY=EMERGENCY
LARAVEL_WORKERS_DATA=(
  "100|1|www-data|S|7200|1|0|1|100000|HORIZON_WORKER|aaa111111111|coolify||||default|36000|COMMAND||UNKNOWN||||3|always|0|4|SHARED_WITH_WEB|EMERGENCY|1|timeout_extremely_high,container_without_memory_limit,shared_with_web|php artisan horizon:work"
  "200|1|www-data|S|7200|1|0|1|100000|QUEUE_WORK|bbb222222222|app-workers||||default||CONFIG_UNKNOWN||UNKNOWN||||3|always|0|4|ISOLATED|EMERGENCY|12|excessive_worker_count,container_without_memory_limit|php artisan queue:work"
)
monitor_correlation_collect_signals
monitor_correlation_eval_laravel
assert_eq "aaa111111111" "$EVAL_RID" "diagnóstico escolhe um único recurso alvo"
assert_eq "1" "${CORR[laravel_max_group_count]}" "quantidade pertence ao mesmo worker do timeout"
assert_true 'echo "$EVAL_CAUSE" | grep -q "timeout de 36000s"' "causa mantém o timeout real"
assert_true '! echo "$EVAL_CAUSE" | grep -q "12 workers"' "causa não combina os 12 workers de outra aplicação"
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
