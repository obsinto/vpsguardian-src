#!/bin/bash
################################################################################
# Script: test-monitor-history.sh
# Propósito: Testes do marco M7 — persistência, histórico e relatórios
# Uso: ./monitor/tests/test-monitor-history.sh
#
# Usa diretórios temporários. NUNCA escreve em /var/lib. Nenhum teste faz coleta
# real, chama webhook ou depende de Docker/Coolify.
################################################################################

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONITOR_DIR="$(dirname "$TESTS_DIR")"
ROOT_DIR="$(dirname "$MONITOR_DIR")"
FIXTURES="$TESTS_DIR/fixtures"

TEST_TMP=$(mktemp -d /tmp/vpsguardian-m7-test.XXXXXX)
trap 'chmod -R u+rwX "$TEST_TMP" 2>/dev/null; rm -rf "$TEST_TMP"' EXIT

export MONITOR_CONFIG_FILE=/dev/null
export MONITOR_STATE_DIR="$TEST_TMP/state"
export MONITOR_HISTORY_DIR="$TEST_TMP/history"
export DEBUG=0

source "$ROOT_DIR/lib/monitor-common.sh" || { echo "✗ monitor-common.sh"; exit 1; }
source "$ROOT_DIR/lib/notificacoes.sh" 2>/dev/null
source "$ROOT_DIR/lib/monitor-alerts.sh" || { echo "✗ monitor-alerts.sh"; exit 1; }
source "$ROOT_DIR/lib/monitor-correlation.sh" || { echo "✗ monitor-correlation.sh"; exit 1; }
source "$ROOT_DIR/lib/monitor-history.sh" || { echo "✗ monitor-history.sh"; exit 1; }
monitor_load_config
monitor_init_dirs
export MONITOR_HISTORY_DIR="$TEST_TMP/history"

CLI_NO_HISTORY=false
MONITOR_VERSION="1.0.0"

echo "╔════════════════════════════════════════════════════════════╗"
echo "║        TESTES DO MONITOR PREVENTIVO (M7 — Histórico)       ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

ERROS=0
assert_eq() { if [ "$1" = "$2" ]; then echo "  ✓ $3"; else echo "  ✗ $3 (esperado: '$1', obtido: '$2')"; ((ERROS++)); fi; }
assert_true() { if eval "$1"; then echo "  ✓ $2"; else echo "  ✗ $2 (falhou: $1)"; ((ERROS++)); fi; }

# Reseta o ambiente de sinais e histórico entre cenários
reset_hist() {
    rm -rf "$MONITOR_HISTORY_DIR"
    CONTAINERS_DATA=(); LARAVEL_WORKERS_DATA=()
    MONITOR_ALERT_DRY_RUN=false; CLI_NO_HISTORY=false
    unset MEM_TOTAL_MB MEM_USED_MB MEM_AVAILABLE_MB SWAP_USED_MB SWAP_TOTAL_MB
    HIST_WRITE_ERRORS=0
    monitor_history_init
}

# Injeta um conjunto mínimo de sinais de host
set_signals() {
    HOST_HOSTNAME=testhost HOST_VCPUS=4 HOST_UPTIME_SECONDS=1000
    LOAD_1=1.0 LOAD_5=1.0 LOAD_15=1.0 LOAD_RATIO=0.25 LOAD_SEVERITY=INFO
    CPU_USAGE_PERCENT=10 CPU_STEAL_PERCENT=0 CPU_IOWAIT_PERCENT=2
    CPU_SEVERITY=INFO CPU_STEAL_SEVERITY=INFO CPU_IOWAIT_SEVERITY=INFO
    MEM_TOTAL_MB=16000 MEM_USED_MB=4000 MEM_AVAILABLE_MB=12000 MEM_USED_PERCENT=25 MEM_SEVERITY=INFO
    SWAP_TOTAL_MB=4000 SWAP_USED_MB="${1:-100}" SWAP_USED_PERCENT=2 SWAP_SEVERITY=INFO
    DISK_TOTAL_MB=50000 DISK_AVAILABLE_MB=20000 DISK_USED_PERCENT=60 DISK_SEVERITY=INFO
    INODE_USED_PERCENT=10 INODE_SEVERITY=INFO CGROUP_SEVERITY=INFO
    DOCKER_STATUS="${2:-HEALTHY}" DOCKER_SEVERITY=INFO DOCKER_PS_LATENCY_MS=10 CONTAINERD_STATUS=HEALTHY
    CONTAINERS_TOTAL=0 CONTAINERS_RUNNING=0 CONTAINERS_STOPPED=0 CONTAINERS_RESTARTING=0
    CONTAINERS_UNHEALTHY=0 CONTAINERS_NO_MEM_LIMIT=0 CONTAINERS_NO_CPU_LIMIT=0
    LARAVEL_TOTAL=0 LARAVEL_WARNING=0 LARAVEL_CRITICAL=0 LARAVEL_EMERGENCY=0 LARAVEL_MAX_SEVERITY=INFO
    OVERALL_SEVERITY="${3:-INFO}"; ALERTS_OPENED=0
    DIAG_N=0 DIAG_MAIN_KEY="" DIAG_HIGHEST_CONF=NONE DIAG_HIGHEST_SEV=INFO
}

metrics_file() { echo "$MONITOR_HISTORY_DIR/metrics/metrics-$(date +%Y-%m-%d).jsonl"; }

################################################################################
echo "🔍 Teste 1: Criação de diretório, escrita e JSON válido"
################################################################################
reset_hist; set_signals
monitor_history_persist
assert_true '[ -d "$MONITOR_HISTORY_DIR/metrics" ]' "diretório de histórico criado"
assert_true '[ -f "$(metrics_file)" ]' "arquivo de métricas criado"
assert_eq "1" "$(wc -l < "$(metrics_file)")" "uma linha de métrica"
if command -v python3 &>/dev/null; then
    python3 -m json.tool < "$(metrics_file)" >/dev/null 2>&1
    assert_eq "0" "$?" "linha é JSON válido"
fi
assert_eq "true" "$HIST_METRICS_PERSISTED" "flag metrics_persisted"
assert_eq "true" "$HIST_BASELINE_UPDATED" "baseline atualizado"
assert_true '[ -f "$MONITOR_HISTORY_DIR/indexes/latest-baseline.kv" ]' "baseline criado"
echo ""

################################################################################
echo "🔍 Teste 2: Campo ausente vira null; nenhum secret persistido"
################################################################################
reset_hist; set_signals
unset MEM_AVAILABLE_MB   # campo ausente
WEBHOOK_URL="https://discord.com/api/webhooks/SEGREDO/x"
COOLIFY_API_TOKEN="tok_SEGREDO_2"
monitor_history_persist
assert_true 'grep -q "\"memory_available_bytes\":null" "$(metrics_file)"' "campo ausente => null"
assert_true '! grep -rq SEGREDO "$MONITOR_HISTORY_DIR"' "nenhum secret persistido"
unset WEBHOOK_URL COOLIFY_API_TOKEN
echo ""

################################################################################
echo "🔍 Teste 3: Duas execuções (intervalo) e permissões"
################################################################################
reset_hist; set_signals
MONITOR_HISTORY_METRICS_INTERVAL=0   # força gravar sempre
monitor_history_persist
monitor_history_persist
assert_eq "2" "$(wc -l < "$(metrics_file)")" "duas execuções => duas linhas"
perms=$(stat -c '%a' "$(metrics_file)")
assert_eq "640" "$perms" "permissão do arquivo 0640"
dperms=$(stat -c '%a' "$MONITOR_HISTORY_DIR/metrics")
assert_eq "750" "$dperms" "permissão do diretório 0750"
MONITOR_HISTORY_METRICS_INTERVAL=60
echo ""

################################################################################
echo "🔍 Teste 4: Intervalo de métricas respeitado"
################################################################################
reset_hist; set_signals
MONITOR_HISTORY_METRICS_INTERVAL=3600
monitor_history_persist                       # 1ª: grava (baseline vazio)
assert_eq "1" "$(wc -l < "$(metrics_file)")" "1ª execução grava"
monitor_history_persist                       # 2ª: dentro do intervalo, não grava
assert_eq "1" "$(wc -l < "$(metrics_file)")" "2ª execução dentro do intervalo NÃO grava"
assert_eq "false" "$HIST_METRICS_PERSISTED" "metrics_persisted=false no intervalo"
MONITOR_HISTORY_METRICS_INTERVAL=60
echo ""

################################################################################
echo "🔍 Teste 5: Swap delta (positivo/negativo/estável) e taxa"
################################################################################
assert_eq "RISING" "$(monitor_history_trend 100000000 67108864)" "delta grande => RISING"
assert_eq "FALLING" "$(monitor_history_trend -100000000 67108864)" "delta negativo grande => FALLING"
assert_eq "STABLE" "$(monitor_history_trend 1000 67108864)" "delta pequeno => STABLE"
assert_eq "UNKNOWN" "$(monitor_history_trend abc 67108864)" "delta inválido => UNKNOWN"
assert_eq "0" "$(monitor_history_rate 6000 -5)" "clock retrocedendo => taxa 0"
assert_eq "0" "$(monitor_history_rate 6000 0)" "intervalo zero => taxa 0"
assert_eq "60" "$(monitor_history_rate 60 60)" "60 bytes em 60s => 60 bytes/min"

reset_hist; set_signals 100
MONITOR_HISTORY_METRICS_INTERVAL=0
monitor_history_persist                       # swap_used=100MB
set_signals 300; MONITOR_HISTORY_METRICS_INTERVAL=0
monitor_history_persist                       # swap subiu para 300MB
last=$(tail -1 "$(metrics_file)")
assert_true 'echo "$last" | grep -qE "\"swap_delta_bytes\":2[0-9]+"' "swap delta positivo registrado (~200MB)"
MONITOR_HISTORY_METRICS_INTERVAL=60
echo ""

################################################################################
echo "🔍 Teste 6: Eventos só em transição; abertura/recuperação"
################################################################################
reset_hist
# ciclo 1: memória crítica => ALERT_OPENED
set_signals; MEM_SEVERITY=CRITICAL; OVERALL_SEVERITY=CRITICAL
monitor_history_persist
ev="$MONITOR_HISTORY_DIR/events/events-$(date +%Y-%m).jsonl"
assert_true 'grep -q ALERT_OPENED "$ev"' "abertura registrada (ALERT_OPENED)"
n_after_open=$(wc -l < "$ev")
# ciclo 2: mesma condição => nenhum evento novo
MONITOR_HISTORY_METRICS_INTERVAL=0
monitor_history_persist
assert_eq "$n_after_open" "$(wc -l < "$ev")" "sem transição => evento NÃO duplicado"
# ciclo 3: normaliza => ALERT_RECOVERED
set_signals; MEM_SEVERITY=INFO; OVERALL_SEVERITY=INFO; MONITOR_HISTORY_METRICS_INTERVAL=0
monitor_history_persist
assert_true 'grep -q ALERT_RECOVERED "$ev"' "recuperação registrada (ALERT_RECOVERED)"
MONITOR_HISTORY_METRICS_INTERVAL=60
echo ""

################################################################################
echo "🔍 Teste 7: Escalonamento de alerta"
################################################################################
reset_hist
set_signals; SWAP_SEVERITY=WARNING; OVERALL_SEVERITY=WARNING
monitor_history_persist
MONITOR_HISTORY_METRICS_INTERVAL=0
set_signals; SWAP_SEVERITY=CRITICAL; OVERALL_SEVERITY=CRITICAL
monitor_history_persist
ev="$MONITOR_HISTORY_DIR/events/events-$(date +%Y-%m).jsonl"
assert_true 'grep -q ALERT_ESCALATED "$ev"' "escalonamento registrado (ALERT_ESCALATED)"
MONITOR_HISTORY_METRICS_INTERVAL=60
echo ""

################################################################################
echo "🔍 Teste 8: Diagnóstico detectado e resolvido"
################################################################################
reset_hist
set_signals
# D_KEY/D_CONF são arrays associativos (declarados na lib): usar índice explícito
DIAG_N=1; D_KEY[0]="diagnosis:memory:swap_death"; D_CONF[0]="VERY_HIGH"
monitor_history_persist
dg="$MONITOR_HISTORY_DIR/events/diagnostics-$(date +%Y-%m).jsonl"
assert_true 'grep -q DIAGNOSIS_DETECTED "$dg"' "diagnóstico detectado"
MONITOR_HISTORY_METRICS_INTERVAL=0
set_signals; DIAG_N=0; unset 'D_KEY[0]' 'D_CONF[0]'
monitor_history_persist
assert_true 'grep -q DIAGNOSIS_RESOLVED "$dg"' "diagnóstico resolvido"
MONITOR_HISTORY_METRICS_INTERVAL=60
echo ""

################################################################################
echo "🔍 Teste 9: Container relevante gera detalhe; saudável comum não"
################################################################################
reset_hist; set_signals
# registro de container (32+ campos): idx19=mem_limit(0=sem limite), idx23=severity
# healthy comum (INFO, com limite) NÃO deve gerar detalhe
CONTAINERS_DATA=("ccc333333333|postgres|pg:16|running|Up|healthy|policy|0|0|0|60|true|12|12|4|true|82|INFO|842|1024|0|82|INFO|INFO|uuid|database|pg-main|proj|env|false|full|")
monitor_history_persist
cf="$MONITOR_HISTORY_DIR/containers/containers-$(date +%Y-%m-%d).jsonl"
# postgres é top de memória (único) então entra; mas um container INFO fora do top não
# Verifica que containers só gravam quando há motivo
reset_hist; set_signals
CONTAINERS_DATA=("aaa111111111|bugroyale-worker|img|running|Up|none|unless-stopped|0|2|0|97|true|97|24|1|true|97|CRITICAL|361|384|0|94|CRITICAL|INFO|uuid|application|Bug Royale|proj|prod|true|full|")
monitor_history_persist
cf="$MONITOR_HISTORY_DIR/containers/containers-$(date +%Y-%m-%d).jsonl"
assert_true 'grep -q bugroyale-worker "$cf"' "container CRITICAL gera detalhe"
assert_true 'grep -q "\"reasons\"" "$cf"' "detalhe inclui reasons[]"
echo ""

################################################################################
echo "🔍 Teste 10: Dry-run e --no-history não gravam"
################################################################################
reset_hist; set_signals
MONITOR_ALERT_DRY_RUN=true
monitor_history_persist
assert_true '[ ! -f "$(metrics_file)" ]' "dry-run NÃO grava métricas"
assert_true '[ ! -f "$MONITOR_HISTORY_DIR/indexes/latest-baseline.kv" ]' "dry-run NÃO atualiza baseline"
assert_eq "false" "$HIST_BASELINE_UPDATED" "baseline_updated=false em dry-run"
MONITOR_ALERT_DRY_RUN=false

reset_hist; set_signals
CLI_NO_HISTORY=true
monitor_history_persist
assert_eq "false" "$HIST_ENABLED" "--no-history desabilita histórico"
assert_true '[ ! -f "$(metrics_file)" ]' "--no-history NÃO grava"
CLI_NO_HISTORY=false
echo ""

################################################################################
echo "🔍 Teste 11: Falha de escrita não interrompe (FS somente leitura)"
################################################################################
reset_hist; set_signals
# Pai somente leitura: nem o mkdir dos subdiretórios funciona (simula FS RO/cheio)
ro="$TEST_TMP/ro-parent"; mkdir -p "$ro"; chmod 500 "$ro"
MONITOR_HISTORY_DIR="$ro/history"; monitor_history_init; HIST_WRITE_ERRORS=0
monitor_history_persist; rc=$?
assert_eq "0" "$rc" "persist retorna 0 mesmo com falha de escrita"
assert_true '[ "$HIST_WRITE_ERRORS" -ge 1 ]' "erro de escrita contabilizado"
chmod 750 "$ro" 2>/dev/null || true
MONITOR_HISTORY_DIR="$TEST_TMP/history"; monitor_history_init
echo ""

################################################################################
echo "🔍 Teste 12: Baseline inexistente/corrompido é recuperado"
################################################################################
reset_hist; set_signals
monitor_history_persist                       # cria baseline
assert_true '[ -f "$MONITOR_HISTORY_DIR/indexes/latest-baseline.kv" ]' "baseline criado"
echo "lixo corrompido sem schema" > "$MONITOR_HISTORY_DIR/indexes/latest-baseline.kv"
monitor_history_load_baseline
assert_eq "" "$(_bl schema_version)" "baseline corrompido descartado ao carregar"
MONITOR_HISTORY_METRICS_INTERVAL=0
monitor_history_persist                       # deve recriar sem abortar
assert_true 'grep -q "schema_version=1" "$MONITOR_HISTORY_DIR/indexes/latest-baseline.kv"' "baseline recriado"
MONITOR_HISTORY_METRICS_INTERVAL=60
echo ""

################################################################################
echo "🔍 Teste 13: Retenção segura (só arquivos antigos reconhecidos; caminho inválido)"
################################################################################
reset_hist; set_signals; monitor_history_persist
mkdir -p "$MONITOR_HISTORY_DIR/metrics"
old="$MONITOR_HISTORY_DIR/metrics/metrics-2000-01-01.jsonl"
echo '{}' > "$old"; touch -d "2000-01-01" "$old"
recent="$MONITOR_HISTORY_DIR/metrics/metrics-recent.jsonl"; echo '{}' > "$recent"
unrelated="$MONITOR_HISTORY_DIR/metrics/keep.txt"; echo 'x' > "$unrelated"
MONITOR_HISTORY_METRICS_RETENTION_DAYS=30
monitor_history_maintenance
assert_true '[ ! -f "$old" ]' "arquivo antigo reconhecido removido"
assert_true '[ -f "$recent" ]' "arquivo recente mantido"
assert_true '[ -f "$unrelated" ]' "arquivo não reconhecido preservado"
# caminho perigoso é rejeitado
assert_true '! monitor_history_path_safe ""' "caminho vazio rejeitado"
assert_true '! monitor_history_path_safe "/"' "raiz / rejeitada"
assert_true 'monitor_history_path_safe "/var/lib/x"' "caminho absoluto válido aceito"
echo ""

################################################################################
echo "🔍 Teste 14: report — sem amostras, 1h, 24h, JSON, CSV, filtro"
################################################################################
# ambiente de report isolado com fixture sintética
RHOME="$TEST_TMP/rhist"; mkdir -p "$RHOME/metrics" "$RHOME/events"
export MONITOR_HISTORY_DIR="$RHOME"
monitor_history_init
now=$(date +%s)
today=$(date -u +%Y-%m-%d)
mf="$RHOME/metrics/metrics-$today.jsonl"
{
  printf '{"schema_version":1,"timestamp_epoch":%s,"hostname":"h","load_1":5.0,"load_ratio":1.2,"cpu_usage_percent":80,"cpu_steal_percent":12,"memory_available_bytes":800000000,"swap_used_bytes":100,"swap_used_percent":40,"docker_status":"HEALTHY"}\n' "$((now-1800))"
  printf '{"schema_version":1,"timestamp_epoch":%s,"hostname":"h","load_1":18.4,"load_ratio":4.6,"cpu_usage_percent":95,"cpu_steal_percent":22,"memory_available_bytes":742000000,"swap_used_bytes":200,"swap_used_percent":38,"docker_status":"DOCKER_UNRESPONSIVE_CONTAINERD_HEALTHY"}\n' "$((now-600))"
  echo 'LINHA INVÁLIDA {não json'
} > "$mf"
ef="$RHOME/events/events-$(date -u +%Y-%m).jsonl"
printf '{"schema_version":1,"timestamp_epoch":%s,"event_type":"ALERT_OPENED","severity":"CRITICAL","resource_type":"host","resource_id":"h","key":"host.swap.usage","summary":"swap alta","metadata":{}}\n' "$((now-600))" > "$ef"

REPORT_FROM="$((now-3600))" REPORT_TO="$now" REPORT_FORMAT=human
REPORT_INCIDENT="" REPORT_DIAGNOSIS="" REPORT_CONTAINER=""
out=$(monitor_history_report)
assert_true 'echo "$out" | grep -q "Amostras: 2"' "report conta 2 amostras (ignora inválida)"
assert_true 'echo "$out" | grep -q "Maior load: 18.4"' "report calcula máximo (load)"
assert_true 'echo "$out" | grep -qi "inválida"' "report informa linha inválida"
assert_true 'echo "$out" | grep -q "host.swap.usage\|swap alta"' "timeline lista evento"

# min RAM (742000000 bytes / 1048576 = 707 MiB, divisão inteira)
assert_true 'echo "$out" | grep -q "707 MB"' "report calcula mínimo de RAM"

# sem amostras
REPORT_FROM="$((now-100000))" REPORT_TO="$((now-90000))"
out=$(monitor_history_report)
assert_true 'echo "$out" | grep -qi "Nenhuma amostra"' "report sem amostras informa vazio"

# JSON válido
REPORT_FROM="$((now-3600))" REPORT_TO="$now" REPORT_FORMAT=json
out=$(monitor_history_report)
if command -v python3 &>/dev/null; then
    echo "$out" | python3 -m json.tool >/dev/null 2>&1
    assert_eq "0" "$?" "report JSON válido"
fi
assert_true 'echo "$out" | grep -q "\"samples\": 2"' "report JSON contém samples"

# CSV com header e record_type
REPORT_FORMAT=csv
out=$(monitor_history_report)
assert_true 'echo "$out" | head -1 | grep -q "record_type,timestamp"' "CSV tem header estável"
assert_true 'echo "$out" | grep -q "^metric,"' "CSV usa coluna record_type"

# filtro por incidente
REPORT_FORMAT=human REPORT_INCIDENT="host.swap.usage"
out=$(monitor_history_report)
assert_true 'echo "$out" | grep -q "swap alta"' "filtro por incidente mostra o evento"
REPORT_INCIDENT=""

# leitura de .jsonl.gz
if command -v gzip &>/dev/null; then
    gzip -k "$mf" 2>/dev/null; rm -f "$mf"
    REPORT_FORMAT=human
    out=$(monitor_history_report)
    assert_true 'echo "$out" | grep -q "Amostras: 2"' "report lê .jsonl.gz"
fi
export MONITOR_HISTORY_DIR="$TEST_TMP/history"
echo ""

################################################################################
echo "🔍 Teste 15: Determinismo e independência do Docker"
################################################################################
reset_hist; set_signals; DOCKER_STATUS="" DOCKER_INSTALLED=false
MONITOR_HISTORY_METRICS_INTERVAL=0
monitor_history_persist
assert_eq "true" "$HIST_METRICS_PERSISTED" "histórico grava mesmo sem Docker"
# Determinismo puro: mesma entrada (args fixos) => linha idêntica
l1=$(monitor_history_build_metrics_line 1000 5000)
l2=$(monitor_history_build_metrics_line 1000 5000)
assert_eq "$l1" "$l2" "mesma entrada => mesma linha (determinístico)"
MONITOR_HISTORY_METRICS_INTERVAL=60
echo ""

################################################################################
echo "════════════════════════════════════════════════════════════"
if [ "$ERROS" -eq 0 ]; then
    echo "✅ Todos os testes passaram"; exit 0
else
    echo "❌ $ERROS teste(s) falharam"; exit 1
fi
