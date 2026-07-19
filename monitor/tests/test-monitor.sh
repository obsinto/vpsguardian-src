#!/bin/bash
################################################################################
# Script: test-monitor.sh
# Propósito: Testes automatizados do Monitor Preventivo (M0 + M1)
# Uso: ./monitor/tests/test-monitor.sh
#
# Usa fixtures em monitor/tests/fixtures/ simulando /proc e /sys/fs/cgroup.
# Nenhum teste exige que o servidor esteja realmente sob sobrecarga e nenhum
# teste altera o estado real do sistema.
################################################################################

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONITOR_DIR="$(dirname "$TESTS_DIR")"
ROOT_DIR="$(dirname "$MONITOR_DIR")"
FIXTURES="$TESTS_DIR/fixtures"

# Ambiente isolado: nunca tocar no estado real nem carregar config do usuário
TEST_TMP=$(mktemp -d /tmp/vpsguardian-monitor-test.XXXXXX)
trap 'rm -rf "$TEST_TMP"' EXIT

export MONITOR_CONFIG_FILE=/dev/null
export MONITOR_STATE_DIR="$TEST_TMP/state"
export DEBUG=0

source "$ROOT_DIR/lib/monitor-common.sh" || { echo "✗ Falha ao carregar monitor-common.sh"; exit 1; }
source "$ROOT_DIR/lib/monitor-collectors.sh" || { echo "✗ Falha ao carregar monitor-collectors.sh"; exit 1; }

monitor_load_config
monitor_init_dirs

echo "╔════════════════════════════════════════════════════════════╗"
echo "║           TESTES DO MONITOR PREVENTIVO (M0 + M1)           ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

ERROS=0

assert_eq() {
    local expected="$1" actual="$2" label="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  ✓ $label"
    else
        echo "  ✗ $label (esperado: '$expected', obtido: '$actual')"
        ((ERROS++))
    fi
}

assert_rc() {
    local expected="$1" actual="$2" label="$3"
    assert_eq "$expected" "$actual" "$label (código de retorno)"
}

# Reinicia o buffer/arquivo de estado entre cenários
reset_state() {
    MONITOR_STATE_BUFFER=""
    rm -f "$MONITOR_STATE_FILE"
}

################################################################################
echo "🔍 Teste 1: Parsing de /proc/meminfo"
################################################################################

parsed=$(monitor_parse_meminfo "$FIXTURES/proc-normal/meminfo")
assert_eq "16384000" "$(echo "$parsed" | awk -F= '$1=="mem_total"{print $2}')" "mem_total extraído"
assert_eq "8192000" "$(echo "$parsed" | awk -F= '$1=="mem_available"{print $2}')" "mem_available extraído"
assert_eq "4194304" "$(echo "$parsed" | awk -F= '$1=="swap_total"{print $2}')" "swap_total extraído"
assert_eq "4194304" "$(echo "$parsed" | awk -F= '$1=="swap_free"{print $2}')" "swap_free extraído"

# Kernel antigo sem MemAvailable: aproxima com MemFree+Buffers+Cached
parsed=$(monitor_parse_meminfo "$FIXTURES/proc-normal/meminfo-oldkernel")
assert_eq "8000000" "$(echo "$parsed" | awk -F= '$1=="mem_available"{print $2}')" "fallback sem MemAvailable"

monitor_parse_meminfo "$TEST_TMP/nao-existe" >/dev/null 2>&1
assert_rc "1" "$?" "arquivo inexistente falha graciosamente"
echo ""

################################################################################
echo "🔍 Teste 2: Cálculo de load ratio"
################################################################################

assert_eq "1.50" "$(monitor_calc_load_ratio 6.0 4)" "load 6.0 / 4 vCPUs = 1.50"
assert_eq "10.68" "$(monitor_calc_load_ratio 42.70 4)" "load 42.70 / 4 vCPUs = 10.68 (incidente)"
assert_eq "0.10" "$(monitor_calc_load_ratio 1.2 12)" "load 1.2 / 12 vCPUs = 0.10"
assert_eq "" "$(monitor_calc_load_ratio abc 4)" "load inválido retorna vazio"
assert_eq "" "$(monitor_calc_load_ratio 1.0 0)" "divisão por zero protegida"
echo ""

################################################################################
echo "🔍 Teste 3: CPU por delta de /proc/stat"
################################################################################

PREV="cpu 1000 0 500 8000 300 0 0 200 0 0"
CURR="cpu 1400 0 700 8500 400 0 0 400 0 0"
deltas=$(monitor_cpu_calc_delta "$PREV" "$CURR")
assert_eq "57.1" "$(echo "$deltas" | awk -F= '$1=="cpu_usage"{print $2}')" "cpu_usage = 57.1%"
assert_eq "28.6" "$(echo "$deltas" | awk -F= '$1=="cpu_user"{print $2}')" "cpu_user = 28.6%"
assert_eq "14.3" "$(echo "$deltas" | awk -F= '$1=="cpu_system"{print $2}')" "cpu_system = 14.3%"
assert_eq "35.7" "$(echo "$deltas" | awk -F= '$1=="cpu_idle"{print $2}')" "cpu_idle = 35.7%"
assert_eq "7.1" "$(echo "$deltas" | awk -F= '$1=="cpu_iowait"{print $2}')" "cpu_iowait = 7.1%"

monitor_cpu_calc_delta "$PREV" "$PREV" >/dev/null 2>&1
assert_rc "1" "$?" "amostras idênticas (delta zero) falham graciosamente"
monitor_cpu_calc_delta "lixo" "$CURR" >/dev/null 2>&1
assert_rc "1" "$?" "amostra malformada falha graciosamente"
echo ""

################################################################################
echo "🔍 Teste 4: Cálculo de CPU steal"
################################################################################

assert_eq "14.3" "$(echo "$deltas" | awk -F= '$1=="cpu_steal"{print $2}')" "cpu_steal = 14.3%"

# Steal dominante (throttling agressivo do provedor)
deltas2=$(monitor_cpu_calc_delta "cpu 100 0 100 100 0 0 0 100 0 0" "cpu 150 0 150 150 0 0 0 550 0 0")
assert_eq "75.0" "$(echo "$deltas2" | awk -F= '$1=="cpu_steal"{print $2}')" "steal dominante = 75.0%"
echo ""

################################################################################
echo "🔍 Teste 5: Parsing de cgroup v1"
################################################################################

parsed=$(monitor_cgroup_parse_v1 "$FIXTURES/cgroup-v1/cpu")
assert_eq "quota_configurada" "$(echo "$parsed" | awk -F= '$1=="quota_status"{print $2}')" "quota detectada"
assert_eq "50.0" "$(echo "$parsed" | awk -F= '$1=="quota_percent"{print $2}')" "quota = 50% de 1 vCPU"
assert_eq "42" "$(echo "$parsed" | awk -F= '$1=="nr_throttled"{print $2}')" "nr_throttled lido"
assert_eq "123456" "$(echo "$parsed" | awk -F= '$1=="throttled_usec"{print $2}')" "throttled_time convertido ns→usec"
echo ""

################################################################################
echo "🔍 Teste 6: Parsing de cgroup v2"
################################################################################

parsed=$(monitor_cgroup_parse_v2 "$FIXTURES/cgroup-v2")
assert_eq "quota_configurada" "$(echo "$parsed" | awk -F= '$1=="quota_status"{print $2}')" "quota detectada"
assert_eq "150.0" "$(echo "$parsed" | awk -F= '$1=="quota_percent"{print $2}')" "quota = 150% (1,5 vCPU)"
assert_eq "77" "$(echo "$parsed" | awk -F= '$1=="nr_throttled"{print $2}')" "nr_throttled lido"
assert_eq "555555" "$(echo "$parsed" | awk -F= '$1=="throttled_usec"{print $2}')" "throttled_usec lido"

parsed=$(monitor_cgroup_parse_v2 "$FIXTURES/cgroup-v2-noquota")
assert_eq "sem_quota" "$(echo "$parsed" | awk -F= '$1=="quota_status"{print $2}')" "cpu.max 'max' = sem quota"
echo ""

################################################################################
echo "🔍 Teste 7: Classificação de thresholds"
################################################################################

assert_eq "INFO" "$(monitor_classify_high 50 85 95)" "CPU 50% => INFO"
assert_eq "WARNING" "$(monitor_classify_high 87 85 95)" "CPU 87% => WARNING"
assert_eq "CRITICAL" "$(monitor_classify_high 96 85 95)" "CPU 96% => CRITICAL"
assert_eq "EMERGENCY" "$(monitor_classify_high 55 10 20 50)" "swap 55% => EMERGENCY"
assert_eq "WARNING" "$(monitor_classify_high 1.6 1.5 3.0 5.0)" "load ratio 1.6 => WARNING (decimal)"
assert_eq "UNKNOWN" "$(monitor_classify_high abc 85 95)" "valor não numérico => UNKNOWN"

assert_eq "INFO" "$(monitor_classify_low 4096 2048 1024)" "RAM 4096MB => INFO"
assert_eq "WARNING" "$(monitor_classify_low 1500 2048 1024)" "RAM 1500MB => WARNING"
assert_eq "CRITICAL" "$(monitor_classify_low 742 2048 1024)" "RAM 742MB => CRITICAL (incidente)"
assert_eq "UNKNOWN" "$(monitor_classify_low '' 2048 1024)" "valor vazio => UNKNOWN"

assert_eq "CRITICAL" "$(monitor_severity_max WARNING CRITICAL)" "max(WARNING,CRITICAL) = CRITICAL"
assert_eq "EMERGENCY" "$(monitor_severity_max EMERGENCY INFO)" "max(EMERGENCY,INFO) = EMERGENCY"
echo ""

################################################################################
echo "🔍 Teste 8: Cgroup ausente não derruba o monitor"
################################################################################

reset_state
mkdir -p "$TEST_TMP/cgroup-vazio"
MONITOR_SYS_CGROUP_DIR="$TEST_TMP/cgroup-vazio" collect_cgroup
assert_rc "0" "$?" "collect_cgroup com diretório vazio"
MONITOR_SYS_CGROUP_DIR="$TEST_TMP/cgroup-vazio"
collect_cgroup
assert_eq "indeterminado" "$CGROUP_THROTTLING_STATUS" "status = indeterminado sem arquivos"
MONITOR_SYS_CGROUP_DIR="$FIXTURES/cgroup-v2"

# Delta de throttling entre execuções (fixture copiada para poder simular aumento)
reset_state
cp -r "$FIXTURES/cgroup-v2" "$TEST_TMP/cgroup-delta"
MONITOR_SYS_CGROUP_DIR="$TEST_TMP/cgroup-delta"
collect_cgroup
assert_eq "throttling_historico" "$CGROUP_THROTTLING_STATUS" "1ª execução: contador acumulado => histórico"
monitor_state_save
MONITOR_STATE_BUFFER=""
sed -i 's/nr_throttled 77/nr_throttled 80/' "$TEST_TMP/cgroup-delta/cpu.stat"
collect_cgroup
assert_eq "3" "$CGROUP_THROTTLED_DELTA" "2ª execução: delta de throttling = 3"
assert_eq "throttling_detectado" "$CGROUP_THROTTLING_STATUS" "2ª execução: throttling detectado"
assert_eq "WARNING" "$CGROUP_SEVERITY" "throttling ativo => WARNING"
MONITOR_SYS_CGROUP_DIR="$FIXTURES/cgroup-v2"
echo ""

################################################################################
echo "🔍 Teste 9: Timeout de comandos externos"
################################################################################

run_with_timeout 1 sleep 5 >/dev/null 2>&1
assert_rc "124" "$?" "comando travado é morto pelo timeout"
run_with_timeout 5 true
assert_rc "0" "$?" "comando rápido passa"
out=$(run_with_timeout 5 echo "ok")
assert_eq "ok" "$out" "saída do comando preservada"
echo ""

################################################################################
echo "🔍 Teste 10: Lock impede execuções simultâneas"
################################################################################

LOCK_TEST="$TEST_TMP/monitor.lock"
echo $$ > "$LOCK_TEST"   # PID vivo (este próprio teste)
( monitor_acquire_lock "$LOCK_TEST" ) >/dev/null 2>&1
assert_rc "1" "$?" "lock com PID vivo bloqueia nova execução"

# Lock órfão (PID morto) deve ser removido e a execução prossegue
dead_pid=$(bash -c 'echo $$')
echo "$dead_pid" > "$LOCK_TEST"
( monitor_acquire_lock "$LOCK_TEST" && monitor_release_lock ) >/dev/null 2>&1
assert_rc "0" "$?" "lock órfão é recuperado"

# Fim a fim: vps-monitor.sh check deve sair com código 10 se houver lock ativo
echo $$ > "$LOCK_TEST"
MONITOR_LOCK_FILE="$LOCK_TEST" \
MONITOR_PROC_DIR="$FIXTURES/proc-normal" \
MONITOR_CPU_SAMPLE_INTERVAL=0 \
    "$MONITOR_DIR/vps-monitor.sh" check >/dev/null 2>&1
assert_rc "10" "$?" "vps-monitor.sh check respeita lock ativo"
rm -f "$LOCK_TEST"
echo ""

################################################################################
echo "🔍 Teste 11: Saída estruturada (JSON e chave=valor)"
################################################################################

json_out=$(MONITOR_LOCK_FILE="$TEST_TMP/json.lock" \
    MONITOR_PROC_DIR="$FIXTURES/proc-normal" \
    MONITOR_SYS_CGROUP_DIR="$FIXTURES/cgroup-v2" \
    MONITOR_CPU_SAMPLE_INTERVAL=0 \
    "$MONITOR_DIR/vps-monitor.sh" check --json 2>/dev/null)

if command -v python3 &>/dev/null; then
    echo "$json_out" | python3 -m json.tool >/dev/null 2>&1
    assert_rc "0" "$?" "JSON válido (python3)"
elif command -v jq &>/dev/null; then
    echo "$json_out" | jq . >/dev/null 2>&1
    assert_rc "0" "$?" "JSON válido (jq)"
else
    echo "  ⚠  python3/jq indisponíveis; validação estrutural pulada"
fi
echo "$json_out" | grep -q '"schema_version": 1' && echo "  ✓ schema_version presente" || { echo "  ✗ schema_version ausente"; ((ERROS++)); }
echo "$json_out" | grep -q '"overall"' && echo "  ✓ bloco overall presente" || { echo "  ✗ bloco overall ausente"; ((ERROS++)); }

kv_out=$(MONITOR_LOCK_FILE="$TEST_TMP/kv.lock" \
    MONITOR_PROC_DIR="$FIXTURES/proc-normal" \
    MONITOR_SYS_CGROUP_DIR="$FIXTURES/cgroup-v2" \
    MONITOR_CPU_SAMPLE_INTERVAL=0 \
    "$MONITOR_DIR/vps-monitor.sh" check --kv 2>/dev/null)
assert_eq "16000" "$(echo "$kv_out" | awk -F= '$1=="mem_total_mb"{print $2}')" "kv: mem_total_mb"
assert_eq "4" "$(echo "$kv_out" | awk -F= '$1=="vcpus"{print $2}')" "kv: vcpus"
echo ""

################################################################################
echo "🔍 Teste 12: Cenário de sobrecarga (fixture do incidente)"
################################################################################

overload_kv=$(MONITOR_LOCK_FILE="$TEST_TMP/over.lock" \
    MONITOR_STATE_DIR="$TEST_TMP/over-state" \
    MONITOR_PROC_DIR="$FIXTURES/proc-overload" \
    MONITOR_SYS_CGROUP_DIR="$FIXTURES/cgroup-v2" \
    MONITOR_CPU_SAMPLE_INTERVAL=0 \
    "$MONITOR_DIR/vps-monitor.sh" check --kv 2>/dev/null)
overload_rc=$?

assert_eq "CRITICAL" "$(echo "$overload_kv" | awk -F= '$1=="mem_severity"{print $2}')" "RAM 742MB => CRITICAL"
assert_eq "CRITICAL" "$(echo "$overload_kv" | awk -F= '$1=="swap_severity"{print $2}')" "swap 38% => CRITICAL"
assert_eq "EMERGENCY" "$(echo "$overload_kv" | awk -F= '$1=="load_severity"{print $2}')" "load ratio 10.68 => EMERGENCY"
assert_eq "UNKNOWN" "$(echo "$overload_kv" | awk -F= '$1=="cpu_severity"{print $2}')" "CPU sem delta => UNKNOWN (não derruba)"
assert_rc "3" "$overload_rc" "código de saída 3 (EMERGENCY)"
echo ""

################################################################################
echo "🔍 Teste 13: Top processos por CPU e memória"
################################################################################

collect_processes
assert_rc "0" "$?" "collect_processes executa"
cpu_lines=$(echo "$TOP_CPU_PROCESSES" | grep -c '|')
[ "$cpu_lines" -ge 1 ] && [ "$cpu_lines" -le 10 ] && \
    echo "  ✓ top CPU com $cpu_lines processo(s) (máx 10)" || \
    { echo "  ✗ top CPU inválido ($cpu_lines linhas)"; ((ERROS++)); }
first_pid=$(echo "$TOP_CPU_PROCESSES" | head -1 | cut -d'|' -f1)
[[ "$first_pid" =~ ^[0-9]+$ ]] && echo "  ✓ formato pid|cpu|mem|etime|comando" || \
    { echo "  ✗ formato inesperado: $first_pid"; ((ERROS++)); }
echo ""

################################################################################
# Resumo
################################################################################

echo "════════════════════════════════════════════════════════════"
if [ "$ERROS" -eq 0 ]; then
    echo "✅ Todos os testes passaram"
    exit 0
else
    echo "❌ $ERROS teste(s) falharam"
    exit 1
fi
