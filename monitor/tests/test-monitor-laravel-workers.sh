#!/bin/bash
################################################################################
# Script: test-monitor-laravel-workers.sh
# Propósito: Testes do marco M4 — detecção de workers Laravel/Horizon
# Uso: ./monitor/tests/test-monitor-laravel-workers.sh
#
# Usa fixtures em monitor/tests/fixtures/laravel-workers/ (snapshot de ps e
# /proc simulados) e os mocks docker/ctr/systemctl do M2/M3. Nenhum teste
# exige Laravel, Docker ou Coolify reais, nem modifica o host.
################################################################################

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONITOR_DIR="$(dirname "$TESTS_DIR")"
ROOT_DIR="$(dirname "$MONITOR_DIR")"
FIXTURES="$TESTS_DIR/fixtures"

TEST_TMP=$(mktemp -d /tmp/vpsguardian-m4-test.XXXXXX)
trap 'chmod -R u+rwX "$TEST_TMP" 2>/dev/null; rm -rf "$TEST_TMP"' EXIT

# /proc simulado copiado para permitir chmod (PID sem permissão de leitura)
cp -r "$FIXTURES/laravel-workers/proc" "$TEST_TMP/proc"
chmod 000 "$TEST_TMP/proc/5556"

# Ambiente isolado
export MONITOR_CONFIG_FILE=/dev/null
export MONITOR_STATE_DIR="$TEST_TMP/state"
export MONITOR_PROC_DIR="$TEST_TMP/proc"
export MONITOR_SYS_CGROUP_DIR="$FIXTURES/cgroup-v2"
export MONITOR_CPU_SAMPLE_INTERVAL=0
export MONITOR_LARAVEL_PS_SOURCE="$FIXTURES/laravel-workers/ps-incident.txt"
export DEBUG=0

source "$ROOT_DIR/lib/monitor-common.sh" || { echo "✗ monitor-common.sh"; exit 1; }
source "$ROOT_DIR/lib/monitor-collectors.sh" || { echo "✗ monitor-collectors.sh"; exit 1; }
source "$ROOT_DIR/lib/monitor-docker.sh" || { echo "✗ monitor-docker.sh"; exit 1; }
source "$ROOT_DIR/lib/monitor-containers.sh" || { echo "✗ monitor-containers.sh"; exit 1; }
source "$ROOT_DIR/lib/monitor-laravel-workers.sh" || { echo "✗ monitor-laravel-workers.sh"; exit 1; }

monitor_load_config
monitor_init_dirs

# ---- Mocks docker/ctr/systemctl (mesmo padrão da suíte M2/M3) ----
MOCKBIN="$TEST_TMP/bin"
mkdir -p "$MOCKBIN"
cat > "$MOCKBIN/docker" <<'MOCK'
#!/bin/bash
mode="${MOCK_DOCKER_MODE:-healthy}"
fixdir="${MOCK_DOCKER_FIXTURES:?}"
case "$mode" in
    timeout) sleep 30 ;;
esac
case "$1" in
    version|info) echo "27.0.1" ;;
    ps)
        if printf '%s\n' "$@" | grep -qx -- '-a'; then cat "$fixdir/ps-a.txt"
        else cat "$fixdir/ps.txt"; fi ;;
    stats) cat "$fixdir/stats.txt" ;;
    inspect) cat "$fixdir/inspect.txt" ;;
esac
exit 0
MOCK
cat > "$MOCKBIN/ctr" <<'MOCK'
#!/bin/bash
cat "${MOCK_DOCKER_FIXTURES:?}/ctr.txt"
exit 0
MOCK
cat > "$MOCKBIN/systemctl" <<'MOCK'
#!/bin/bash
[ "$1" = "is-active" ] && echo "active"
exit 0
MOCK
chmod +x "$MOCKBIN"/*
export MOCK_DOCKER_FIXTURES="$FIXTURES/docker"
export MONITOR_DOCKER_BIN="$MOCKBIN/docker"
export MONITOR_CTR_BIN="$MOCKBIN/ctr"
export MONITOR_SYSTEMCTL_BIN="$MOCKBIN/systemctl"
export MONITOR_DOCKER_SOCKET="$TEST_TMP/docker.sock"
export MONITOR_DOCKER_TIMEOUT_SECONDS=1
export MONITOR_CONTAINERD_TIMEOUT_SECONDS=1
export MONITOR_COOLIFY_ENRICH=false

echo "╔════════════════════════════════════════════════════════════╗"
echo "║       TESTES DO MONITOR PREVENTIVO (M4 — Laravel)          ║"
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

assert_true() {
    local label="$2"
    if eval "$1"; then
        echo "  ✓ $label"
    else
        echo "  ✗ $label (condição falhou: $1)"
        ((ERROS++))
    fi
}

# Campo (1-based) do registro de um worker pelo PID
worker_field() {
    local pid="$1" field="$2" rec
    for rec in "${LARAVEL_WORKERS_DATA[@]}"; do
        if [ "$(echo "$rec" | cut -d'|' -f1)" = "$pid" ]; then
            echo "$rec" | cut -d'|' -f"$field"
            return 0
        fi
    done
    return 1
}

worker_exists() {
    worker_field "$1" 1 >/dev/null 2>&1
}

################################################################################
echo "🔍 Teste 1: Classificação de tipos (sem falsos positivos)"
################################################################################

assert_eq "HORIZON_MASTER" "$(monitor_laravel_worker_type 'php artisan horizon')" "horizon => HORIZON_MASTER"
assert_eq "HORIZON_MASTER" "$(monitor_laravel_worker_type 'php artisan horizon:supervisor x:y')" "horizon:supervisor => HORIZON_MASTER"
assert_eq "HORIZON_WORKER" "$(monitor_laravel_worker_type 'php artisan horizon:work redis --timeout=36000')" "horizon:work => HORIZON_WORKER"
assert_eq "QUEUE_WORK" "$(monitor_laravel_worker_type 'php artisan queue:work')" "queue:work => QUEUE_WORK"
assert_eq "QUEUE_LISTEN" "$(monitor_laravel_worker_type 'php artisan queue:listen')" "queue:listen => QUEUE_LISTEN"
assert_eq "SCHEDULE_RUN" "$(monitor_laravel_worker_type 'php artisan schedule:run')" "schedule:run => SCHEDULE_RUN"
assert_eq "SCHEDULE_WORK" "$(monitor_laravel_worker_type 'php artisan schedule:work')" "schedule:work => SCHEDULE_WORK"
assert_eq "OCTANE" "$(monitor_laravel_worker_type 'php artisan octane:start --workers=4')" "octane:start => OCTANE"
assert_eq "" "$(monitor_laravel_worker_type 'php artisan horizon:status')" "horizon:status NÃO é worker"
assert_eq "" "$(monitor_laravel_worker_type 'php artisan migrate --force')" "migrate NÃO é worker"
assert_eq "" "$(monitor_laravel_worker_type 'php artisan queue:restart')" "queue:restart NÃO é worker"
assert_eq "" "$(monitor_laravel_worker_type 'php script.php horizon')" "php sem artisan NÃO é worker"
monitor_laravel_is_platform_container coolify && echo "  ✓ container coolify reconhecido como plataforma" || { echo "  ✗ coolify não reconhecido"; ((ERROS++)); }
monitor_laravel_is_platform_container automind && { echo "  ✗ aplicação confundida com plataforma"; ((ERROS++)); } || echo "  ✓ aplicação não confundida com plataforma"
echo ""

################################################################################
echo "🔍 Teste 2: Parsing seguro de flags (--opt=v e --opt v)"
################################################################################

CMD='php artisan queue:work --timeout=300 --memory 128 --queue=high,default --tries=3'
assert_eq "300" "$(monitor_laravel_parse_option "$CMD" --timeout)" "--timeout=300"
assert_eq "128" "$(monitor_laravel_parse_option "$CMD" --memory)" "--memory 128 (separado por espaço)"
assert_eq "high,default" "$(monitor_laravel_parse_option "$CMD" --queue)" "--queue com múltiplas filas"
assert_eq "" "$(monitor_laravel_parse_option "$CMD" --max-time)" "flag ausente => vazio"
assert_eq "" "$(monitor_laravel_parse_option 'php artisan queue:work --timeout --memory=64' --timeout)" "--timeout sem valor => vazio"
assert_eq "" "$(monitor_laravel_valid_int "abc")" "valor não numérico rejeitado"
assert_eq "" "$(monitor_laravel_valid_int "-5")" "valor negativo rejeitado"
assert_eq "999999999" "$(monitor_laravel_valid_int "999999999")" "valor grande aceito (classificação decide)"
echo ""

################################################################################
echo "🔍 Teste 3: Severidade de timeout (regras puras)"
################################################################################

assert_eq "INFO" "$(monitor_laravel_timeout_severity 300)" "timeout 300 => INFO"
assert_eq "WARNING" "$(monitor_laravel_timeout_severity 301)" "timeout 301 => WARNING"
assert_eq "WARNING" "$(monitor_laravel_timeout_severity 900)" "timeout 900 => WARNING"
assert_eq "CRITICAL" "$(monitor_laravel_timeout_severity 901)" "timeout 901 => CRITICAL"
assert_eq "CRITICAL" "$(monitor_laravel_timeout_severity 3600)" "timeout 3600 => CRITICAL"
assert_eq "EMERGENCY" "$(monitor_laravel_timeout_severity 36000)" "timeout 36000 => EMERGENCY (incidente)"
assert_eq "INFO" "$(monitor_laravel_timeout_severity '')" "timeout ausente => INFO"
echo ""

################################################################################
echo "🔍 Teste 4: Severidade por quantidade de workers"
################################################################################

assert_eq "INFO" "$(monitor_laravel_count_severity 2)" "2 workers => INFO"
assert_eq "WARNING" "$(monitor_laravel_count_severity 3)" "3 workers => WARNING"
assert_eq "CRITICAL" "$(monitor_laravel_count_severity 6)" "6 workers => CRITICAL (incidente)"
assert_eq "EMERGENCY" "$(monitor_laravel_count_severity 9)" "9 workers => EMERGENCY"
echo ""

################################################################################
echo "🔍 Teste 5: Sanitização de comandos (secrets nunca expostos)"
################################################################################

SAN=$(monitor_laravel_sanitize_cmd 'php artisan queue:work --token=abc123 --env=production redis://user:s3cr3t@redis:6379 password=topsecret')
assert_true '! echo "$SAN" | grep -q abc123' "valor de --token removido"
assert_true '! echo "$SAN" | grep -q s3cr3t' "senha em URL removida"
assert_true '! echo "$SAN" | grep -q topsecret' "password= removido"
assert_true '! echo "$SAN" | grep -q production' "valor de --env removido"
assert_true 'echo "$SAN" | grep -q "queue:work"' "comando base preservado"
echo ""

################################################################################
echo "🔍 Teste 6: Extração de container do cgroup (v1 e v2)"
################################################################################

assert_eq "bbb222222222" "$(monitor_laravel_cgroup_container_id '0::/system.slice/docker-bbb222222222ffffffffffffffffffffffffffffffffffffffffffffffffffff.scope')" "cgroup v2 => id12"
assert_eq "ccc333333333" "$(monitor_laravel_cgroup_container_id '2:cpu:/docker/ccc333333333ffffffffffffffffffffffffffffffffffffffffffffffffffff')" "cgroup v1 => id12"
assert_eq "" "$(monitor_laravel_cgroup_container_id '0::/system.slice/app.service')" "processo do host => vazio"
echo ""

################################################################################
echo "🔍 Teste 7: Regras de avaliação combinadas (função pura)"
################################################################################

r=$(monitor_laravel_evaluate QUEUE_LISTEN "" 1 100 "" "" "" UNKNOWN S)
assert_eq "WARNING" "${r%%|*}" "queue:listen => WARNING"
assert_true 'echo "$r" | grep -q queue_listen_in_production' "finding queue_listen_in_production"

r=$(monitor_laravel_evaluate SCHEDULE_RUN "" 1 1000 "" "" "" UNKNOWN S)
assert_eq "CRITICAL" "${r%%|*}" "schedule:run 1000s => CRITICAL"

r=$(monitor_laravel_evaluate QUEUE_WORK "" 1 100 0 "" "" ISOLATED S)
assert_true 'echo "$r" | grep -q no_memory_limit_anywhere' "sem --memory + container sem limite"
assert_eq "WARNING" "${r%%|*}" "=> WARNING"

r=$(monitor_laravel_evaluate QUEUE_WORK "" 1 100 512 128 3600 ISOLATED S)
assert_eq "INFO" "${r%%|*}" "worker bem configurado => INFO"

r=$(monitor_laravel_evaluate QUEUE_WORK "" 1 100 512 "" "" SHARED_WITH_WEB S)
assert_true 'echo "$r" | grep -q shared_with_web' "compartilhado com web sinalizado"
assert_eq "WARNING" "${r%%|*}" "=> WARNING"

r=$(monitor_laravel_evaluate HORIZON_WORKER 36000 1 100 0 128 0 SHARED_WITH_WEB S COOLIFY_PLATFORM)
assert_eq "INFO" "${r%%|*}" "Horizon interno do Coolify não gera falso EMERGENCY"
assert_true 'echo "$r" | grep -q platform_managed' "worker interno permanece inventariado como plataforma"
assert_true '! echo "$r" | grep -q timeout_extremely_high' "timeout esperado do Coolify não vira finding perigoso"
assert_eq "timeout extremamente alto; container sem limite de memória; worker compartilhado com servidor web" \
    "$(monitor_laravel_findings_human timeout_extremely_high,container_without_memory_limit,shared_with_web)" \
    "findings técnicos são apresentados em português"
echo ""

################################################################################
echo "🔍 Teste 8: Coleta completa com a fixture do incidente"
################################################################################

collect_host_info
collect_docker
collect_containers
collect_laravel_workers
assert_eq "ok" "$LARAVEL_STATUS" "coleta concluída"
assert_eq "22" "$LARAVEL_TOTAL" "22 workers detectados"
assert_eq "1" "$LARAVEL_HORIZON_MASTERS" "1 horizon master"
assert_eq "6" "$LARAVEL_HORIZON_WORKERS" "6 horizon workers"
assert_eq "12" "$LARAVEL_QUEUE_WORKERS" "12 queue:work"
assert_eq "1" "$LARAVEL_QUEUE_LISTENERS" "1 queue:listen"
assert_eq "2" "$LARAVEL_SCHEDULERS" "2 schedulers"
assert_true '! worker_exists 9001' "horizon:status não vira worker"
assert_true '! worker_exists 9002' "migrate não vira worker"
assert_true '! worker_exists 9003' "linha do grep ignorada"
assert_true '! worker_exists 9004' "wrapper sh -c ignorado (sem dupla contagem)"
echo ""

################################################################################
echo "🔍 Teste 9: Cenário do incidente (6 workers, timeout 36000, sem limite)"
################################################################################

assert_eq "HORIZON_WORKER" "$(worker_field 4821 10)" "tipo HORIZON_WORKER"
assert_eq "bbb222222222" "$(worker_field 4821 11)" "container via cgroup v2"
assert_eq "automind" "$(worker_field 4821 12)" "nome do container via inventário M3"
assert_eq "36000" "$(worker_field 4821 17)" "timeout 36000 extraído"
assert_eq "COMMAND" "$(worker_field 4821 18)" "timeout_source=COMMAND"
assert_eq "6" "$(worker_field 4821 30)" "grupo com 6 workers equivalentes"
assert_eq "EMERGENCY" "$(worker_field 4821 29)" "severidade EMERGENCY"
assert_true 'worker_field 4821 31 | grep -q timeout_extremely_high' "finding timeout_extremely_high"
assert_true 'worker_field 4821 31 | grep -q excessive_worker_count' "finding excessive_worker_count"
assert_true 'worker_field 4821 31 | grep -q container_without_memory_limit' "finding container_without_memory_limit"
assert_eq "ISOLATED" "$(worker_field 4821 28)" "container exclusivo de worker"
assert_eq "0" "$(worker_field 4821 26)" "limite de memória do container = 0 (M3)"
assert_eq "always" "$(worker_field 4821 25)" "restart policy do container (M3)"
assert_eq "7" "$LARAVEL_DANGEROUS_TIMEOUTS" "7 timeouts perigosos (6 horizon + 1 absurdo)"
assert_eq "1" "$LARAVEL_CONTAINERS_NO_MEM_LIMIT" "1 container de worker sem limite"
assert_eq "EMERGENCY" "$LARAVEL_MAX_SEVERITY" "severidade máxima EMERGENCY"
echo ""

################################################################################
echo "🔍 Teste 10: Formatos de flag, cmdline truncado e valores inválidos"
################################################################################

assert_eq "300" "$(worker_field 5003 17)" "--timeout 300 (separado por espaço)"
assert_eq "300" "$(worker_field 5013 17)" "comando truncado recuperado via /proc/cmdline"
assert_eq "high" "$(worker_field 5013 16)" "fila do comando recuperado"
assert_eq "" "$(worker_field 5010 17)" "--timeout=abc rejeitado"
assert_eq "CONFIG_UNKNOWN" "$(worker_field 5010 18)" "timeout inválido => CONFIG_UNKNOWN"
assert_eq "" "$(worker_field 5010 19)" "--memory=-5 rejeitado"
assert_eq "INFO" "$(worker_field 5010 29)" "flags inválidas não geram falso alerta"
assert_eq "EMERGENCY" "$(worker_field 5011 29)" "timeout 999999999 => EMERGENCY"
echo ""

################################################################################
echo "🔍 Teste 11: Fontes de limite de memória e max-time"
################################################################################

assert_eq "COMMAND" "$(worker_field 5001 20)" "--memory=128 => memory_source=COMMAND"
assert_eq "CONTAINER" "$(worker_field 5014 20)" "sem --memory + container limitado => CONTAINER"
assert_eq "INFO" "$(worker_field 5014 29)" "worker sem opções em container limitado => INFO"
assert_eq "UNKNOWN" "$(worker_field 5015 20)" "sem --memory + sem limite => UNKNOWN"
assert_eq "WARNING" "$(worker_field 5015 29)" "sem limite em lugar nenhum => WARNING"
assert_true 'worker_field 5015 31 | grep -q no_memory_limit_anywhere' "finding no_memory_limit_anywhere"
assert_true 'worker_field 5015 31 | grep -q missing_max_time' "finding missing_max_time"
echo ""

################################################################################
echo "🔍 Teste 12: queue:listen, schedule:run e zombie"
################################################################################

assert_eq "WARNING" "$(worker_field 6001 29)" "queue:listen => WARNING"
assert_eq "CRITICAL" "$(worker_field 7001 29)" "schedule:run 1200s => CRITICAL"
assert_true 'worker_field 7001 31 | grep -q schedule_run_stuck' "finding schedule_run_stuck"
assert_eq "INFO" "$(worker_field 7002 29)" "schedule:run 30s => INFO"
assert_eq "Z" "$(worker_field 8001 4)" "estado zombie capturado"
assert_true 'worker_field 8001 31 | grep -q zombie_process' "finding zombie_process"
echo ""

################################################################################
echo "🔍 Teste 13: Isolamento web, cgroup v1 e CPU multicore"
################################################################################

assert_eq "ccc333333333" "$(worker_field 5001 11)" "associação via cgroup v1"
assert_eq "SHARED_WITH_WEB" "$(worker_field 5001 28)" "queue:work junto de php-fpm => SHARED_WITH_WEB"
assert_eq "WARNING" "$(worker_field 5001 29)" "compartilhado com web => WARNING"
assert_eq "ISOLATED" "$(worker_field 5003 28)" "worker em container exclusivo => ISOLATED"
assert_eq "1" "$LARAVEL_SHARED_WITH_WEB" "1 container compartilhado com web"
assert_eq "3" "$LARAVEL_CONTAINERS_WITH_WORKERS" "3 containers com workers"
assert_eq "400.0" "$(worker_field 5555 6)" "CPU bruta 400% preservada"
assert_eq "100.0" "$(worker_field 5555 7)" "CPU normalizada por 4 vCPUs => 100%"
echo ""

################################################################################
echo "🔍 Teste 14: Falhas de /proc não interrompem a coleta"
################################################################################

assert_true 'worker_exists 5555' "PID sem /proc (desapareceu) ainda inventariado"
assert_eq "" "$(worker_field 5555 11)" "container desconhecido para PID sumido"
assert_eq "UNKNOWN" "$(worker_field 5555 28)" "isolamento UNKNOWN sem cgroup"
assert_true 'worker_exists 5556' "PID com /proc sem permissão ainda inventariado"
assert_eq "" "$(worker_field 5556 11)" "cgroup ilegível => container vazio"
echo ""

################################################################################
echo "🔍 Teste 15: Filas distintas formam grupos distintos"
################################################################################

assert_eq "high,default" "$(worker_field 5001 16)" "filas high,default capturadas"
assert_eq "emails" "$(worker_field 5016 16)" "fila emails capturada"
assert_eq "1" "$(worker_field 5016 30)" "grupos separados por fila (contagem 1)"
echo ""

################################################################################
echo "🔍 Teste 16: Associação Coolify preservada sem API (labels do M3)"
################################################################################

assert_eq "uuid-bugroyale-app" "$(worker_field 5003 13)" "UUID Coolify herdado do inventário"
assert_eq "bugroyale-worker" "$(worker_field 5003 15)" "nome Coolify herdado das labels"
assert_eq "Bug Royale" "$(worker_field 5003 34)" "projeto Coolify herdado das labels"
assert_eq "production" "$(worker_field 5003 35)" "ambiente Coolify herdado das labels"
assert_eq "" "$(worker_field 4821 13)" "container sem labels => sem UUID (sem inventar)"
assert_eq "Projeto Bug Royale / bugroyale-worker (production)" \
    "$(monitor_laravel_worker_label APPLICATION "Bug Royale" bugroyale-worker production bugroyale-worker aaa111111111)" \
    "rótulo usa projeto, recurso e ambiente em vez do nome técnico isolado"
assert_eq "Host (origem não mapeada)" \
    "$(monitor_laravel_worker_label HOST "" "" "" "" "")" \
    "origem desconhecida é explícita e não inventa projeto"
assert_true '! printf "%s\n" "${LARAVEL_WORKERS_ALERTS[@]}" | grep -q "timeout_extremely_high"' \
    "alerta não expõe finding interno em inglês"
echo ""

################################################################################
echo "🔍 Teste 17: Docker indisponível não impede a detecção por processos"
################################################################################

CONTAINERS_DATA=()
export MOCK_DOCKER_MODE=timeout
collect_docker
collect_containers
collect_laravel_workers
assert_eq "ok" "$LARAVEL_STATUS" "coleta funciona sem Docker"
assert_eq "22" "$LARAVEL_TOTAL" "22 workers detectados sem Docker"
assert_eq "bbb222222222" "$(worker_field 4821 11)" "container via cgroup mesmo sem Docker"
assert_eq "" "$(worker_field 4821 12)" "nome do container indisponível (sem inventário)"
assert_eq "EMERGENCY" "$(worker_field 4821 29)" "timeout perigoso detectado sem Docker"
export MOCK_DOCKER_MODE=healthy
echo ""

################################################################################
echo "🔍 Teste 18: Nenhum worker encontrado (não é erro)"
################################################################################

printf ' 1234     1 root S 100 0.1 0.1 4096 nginx: master process\n' > "$TEST_TMP/ps-clean.txt"
MONITOR_LARAVEL_PS_SOURCE="$TEST_TMP/ps-clean.txt" collect_laravel_workers
rc=$?
assert_eq "0" "$rc" "retorno 0 sem workers"
assert_eq "sem_workers" "$LARAVEL_STATUS" "status sem_workers"
assert_eq "0" "$LARAVEL_TOTAL" "total zero"
echo ""

################################################################################
echo "🔍 Teste 19: Fim a fim — JSON, KV, humana e segurança"
################################################################################

E2E_ENV=(
    "MONITOR_CONFIG_FILE=/dev/null"
    "MONITOR_STATE_DIR=$TEST_TMP/e2e-state"
    "MONITOR_LOCK_FILE=$TEST_TMP/e2e.lock"
    "MONITOR_PROC_DIR=$TEST_TMP/proc"
    "MONITOR_SYS_CGROUP_DIR=$FIXTURES/cgroup-v2"
    "MONITOR_CPU_SAMPLE_INTERVAL=0"
    "MONITOR_DOCKER_BIN=$MOCKBIN/docker"
    "MONITOR_CTR_BIN=$MOCKBIN/ctr"
    "MONITOR_SYSTEMCTL_BIN=$MOCKBIN/systemctl"
    "MONITOR_DOCKER_SOCKET=$TEST_TMP/docker.sock"
    "MOCK_DOCKER_FIXTURES=$FIXTURES/docker"
    "MOCK_DOCKER_MODE=healthy"
    "MONITOR_COOLIFY_ENRICH=false"
    "MONITOR_LARAVEL_PS_SOURCE=$FIXTURES/laravel-workers/ps-incident.txt"
    "COOLIFY_API_TOKEN=SECRET_TOKEN_M4_NUNCA_EXIBIR"
)

json_out=$(env "${E2E_ENV[@]}" "$MONITOR_DIR/vps-monitor.sh" check --json 2>&1)
if command -v python3 &>/dev/null; then
    echo "$json_out" | python3 -m json.tool >/dev/null 2>&1
    assert_eq "0" "$?" "JSON válido com blocos laravel_workers"
fi
assert_true 'echo "$json_out" | grep -q "laravel_workers_summary"' "JSON contém laravel_workers_summary"
assert_true 'echo "$json_out" | grep -q HORIZON_WORKER' "JSON contém workers"
assert_true 'echo "$json_out" | grep -q timeout_extremely_high' "JSON contém findings"
assert_true '! echo "$json_out" | grep -q SECRET_TOKEN_M4' "token NUNCA no JSON"
assert_true '! echo "$json_out" | grep -q s3cr3t' "senha de URL NUNCA no JSON"
assert_true '! echo "$json_out" | grep -q topsecret' "password= NUNCA no JSON"

kv_out=$(env "${E2E_ENV[@]}" "$MONITOR_DIR/vps-monitor.sh" check --kv 2>&1)
assert_eq "22" "$(echo "$kv_out" | awk -F= '$1=="laravel_workers.total"{print $2}')" "KV laravel_workers.total"
assert_eq "7" "$(echo "$kv_out" | awk -F= '$1=="laravel_workers.horizon"{print $2}')" "KV laravel_workers.horizon"
assert_eq "7" "$(echo "$kv_out" | awk -F= '$1=="laravel_workers.dangerous_timeout"{print $2}')" "KV dangerous_timeout"
assert_eq "1" "$(echo "$kv_out" | awk -F= '$1=="laravel_workers.shared_with_web"{print $2}')" "KV shared_with_web"
assert_eq "EMERGENCY" "$(echo "$kv_out" | awk -F= '$1=="laravel_workers.max_severity"{print $2}')" "KV max_severity"
assert_true '! echo "$kv_out" | grep -q SECRET_TOKEN_M4' "token NUNCA no KV"

human_out=$(env "${E2E_ENV[@]}" "$MONITOR_DIR/vps-monitor.sh" check 2>&1)
assert_true 'echo "$human_out" | grep -q "Laravel / Horizon"' "seção humana presente"
assert_true 'echo "$human_out" | grep -q "timeout: 36000s"' "timeout do incidente exibido"
assert_true 'echo "$human_out" | grep -q "sem limite de memória"' "container sem limite exibido"
assert_true '! echo "$human_out" | grep -q SECRET_TOKEN_M4' "token NUNCA na humana"
assert_true '! echo "$human_out" | grep -q s3cr3t' "senha NUNCA na humana"

# Sem workers: mensagem INFO na saída humana
none_out=$(env "${E2E_ENV[@]}" MONITOR_LARAVEL_PS_SOURCE="$TEST_TMP/ps-clean.txt" \
    "$MONITOR_DIR/vps-monitor.sh" check 2>&1)
assert_true 'echo "$none_out" | grep -q "Nenhum worker Laravel/Horizon detectado"' "mensagem de ausência (INFO)"
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
