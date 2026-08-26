#!/bin/bash
################################################################################
# Script: test-monitor-docker.sh
# Propósito: Testes dos marcos M2 (Docker/containerd) e M3 (containers)
# Uso: ./monitor/tests/test-monitor-docker.sh
#
# Usa binários SIMULADOS (docker/ctr/systemctl falsos criados em tempo de
# execução) e fixtures em monitor/tests/fixtures/docker/. Nenhum teste toca
# em Docker real, Coolify real ou altera o host.
################################################################################

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONITOR_DIR="$(dirname "$TESTS_DIR")"
ROOT_DIR="$(dirname "$MONITOR_DIR")"
FIXTURES="$TESTS_DIR/fixtures"

TEST_TMP=$(mktemp -d /tmp/vpsguardian-m2m3-test.XXXXXX)
trap 'rm -rf "$TEST_TMP"' EXIT

# Ambiente isolado
export MONITOR_CONFIG_FILE=/dev/null
export MONITOR_STATE_DIR="$TEST_TMP/state"
export MONITOR_PROC_DIR="$FIXTURES/proc-normal"     # 4 vCPUs determinísticos
export MONITOR_SYS_CGROUP_DIR="$FIXTURES/cgroup-v2"
export MONITOR_CPU_SAMPLE_INTERVAL=0
export DEBUG=0

source "$ROOT_DIR/lib/monitor-common.sh" || { echo "✗ monitor-common.sh"; exit 1; }
source "$ROOT_DIR/lib/monitor-collectors.sh" || { echo "✗ monitor-collectors.sh"; exit 1; }
source "$ROOT_DIR/lib/monitor-docker.sh" || { echo "✗ monitor-docker.sh"; exit 1; }
source "$ROOT_DIR/lib/monitor-containers.sh" || { echo "✗ monitor-containers.sh"; exit 1; }

monitor_load_config
monitor_init_dirs

################################################################################
# Mocks (docker / ctr / systemctl simulados)
################################################################################

MOCKBIN="$TEST_TMP/bin"
mkdir -p "$MOCKBIN"

cat > "$MOCKBIN/docker" <<'MOCK'
#!/bin/bash
mode="${MOCK_DOCKER_MODE:-healthy}"
fixdir="${MOCK_DOCKER_FIXTURES:?}"
case "$mode" in
    timeout) sleep 30 ;;
    permission)
        echo "permission denied while trying to connect to the Docker daemon socket at unix:///var/run/docker.sock" >&2
        exit 1 ;;
    error)
        echo "Cannot connect to the Docker daemon at unix:///var/run/docker.sock" >&2
        exit 1 ;;
    slow) sleep "${MOCK_DOCKER_DELAY:-0.3}" ;;
esac
case "$1" in
    version) echo "27.0.1" ;;
    info) echo "27.0.1" ;;
    ps)
        if printf '%s\n' "$@" | grep -qx -- '-a'; then
            cat "$fixdir/ps-a.txt"
        else
            cat "$fixdir/ps.txt"
        fi ;;
    stats)
        [ "${MOCK_DOCKER_STATS_FAIL:-0}" = "1" ] && { echo "stats error" >&2; exit 1; }
        cat "$fixdir/stats.txt" ;;
    inspect)
        [ "${MOCK_DOCKER_INSPECT_FAIL:-0}" = "1" ] && { echo "inspect error" >&2; exit 1; }
        cat "$fixdir/inspect.txt" ;;
esac
exit 0
MOCK

cat > "$MOCKBIN/ctr" <<'MOCK'
#!/bin/bash
mode="${MOCK_CTR_MODE:-healthy}"
case "$mode" in
    timeout) sleep 30 ;;
    error) echo "ctr: failed to dial" >&2; exit 1 ;;
    permission) echo "ctr: permission denied" >&2; exit 1 ;;
esac
cat "${MOCK_DOCKER_FIXTURES:?}/ctr.txt"
exit 0
MOCK

cat > "$MOCKBIN/systemctl" <<'MOCK'
#!/bin/bash
if [ "$1" = "is-active" ]; then
    case "$2" in
        docker) echo "${MOCK_SYSTEMCTL_DOCKER:-active}" ;;
        containerd) echo "${MOCK_SYSTEMCTL_CONTAINERD:-active}" ;;
        *) echo "unknown" ;;
    esac
fi
exit 0
MOCK

chmod +x "$MOCKBIN"/*
export MOCK_DOCKER_FIXTURES="$FIXTURES/docker"
export MONITOR_DOCKER_BIN="$MOCKBIN/docker"
export MONITOR_CTR_BIN="$MOCKBIN/ctr"
export MONITOR_SYSTEMCTL_BIN="$MOCKBIN/systemctl"
export MONITOR_DOCKER_SOCKET="$TEST_TMP/docker.sock"   # inexistente por padrão
export MONITOR_DOCKER_TIMEOUT_SECONDS=1
export MONITOR_CONTAINERD_TIMEOUT_SECONDS=1
export MONITOR_DOCKER_SLOW_MS=2000
export MONITOR_CONTAINERD_SLOW_MS=2000
export MONITOR_COOLIFY_ENRICH=false                    # sem API por padrão

echo "╔════════════════════════════════════════════════════════════╗"
echo "║        TESTES DO MONITOR PREVENTIVO (M2 + M3)              ║"
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

reset_state() {
    MONITOR_STATE_BUFFER=""
    rm -f "$MONITOR_STATE_FILE"
}

# Devolve um campo de um registro de container pelo nome
container_field() {
    local cname="$1" field="$2" rec
    for rec in "${CONTAINERS_DATA[@]}"; do
        if [ "$(echo "$rec" | cut -d'|' -f2)" = "$cname" ]; then
            echo "$rec" | cut -d'|' -f"$field"
            return 0
        fi
    done
    return 1
}

################################################################################
echo "🔍 Teste 1: Classificação pura dos quatro estados principais"
################################################################################

assert_eq "HEALTHY" "$(monitor_docker_classify true false true 100 2000 true)" "resposta rápida => HEALTHY"
assert_eq "SLOW" "$(monitor_docker_classify true false true 3500 2000 true)" "latência alta => SLOW"
assert_eq "DOCKER_UNRESPONSIVE_CONTAINERD_HEALTHY" \
    "$(monitor_docker_classify true false false 5000 2000 true)" "docker trava + ctr OK"
assert_eq "DOCKER_AND_CONTAINERD_UNRESPONSIVE" \
    "$(monitor_docker_classify true false false 5000 2000 false)" "ambos travados"
assert_eq "DOCKER_UNRESPONSIVE_CONTAINERD_UNKNOWN" \
    "$(monitor_docker_classify true false false 5000 2000 unknown)" "containerd indeterminado"
assert_eq "DOCKER_NOT_INSTALLED" "$(monitor_docker_classify false false false 0 2000 unknown)" "docker ausente"
assert_eq "PERMISSION_DENIED" "$(monitor_docker_classify true true false 100 2000 true)" "permissão negada"

assert_eq "INFO" "$(monitor_docker_severity_for HEALTHY)" "HEALTHY => INFO"
assert_eq "WARNING" "$(monitor_docker_severity_for SLOW)" "SLOW => WARNING"
assert_eq "CRITICAL" "$(monitor_docker_severity_for DOCKER_UNRESPONSIVE_CONTAINERD_HEALTHY)" "vítima do host => CRITICAL"
assert_eq "EMERGENCY" "$(monitor_docker_severity_for DOCKER_AND_CONTAINERD_UNRESPONSIVE)" "ambos => EMERGENCY"
assert_eq "UNKNOWN" "$(monitor_docker_severity_for DOCKER_NOT_INSTALLED)" "não instalado => UNKNOWN"
MONITOR_DOCKER_REQUIRED=true
assert_eq "CRITICAL" "$(monitor_docker_severity_for DOCKER_NOT_INSTALLED)" "não instalado + esperado => CRITICAL"
MONITOR_DOCKER_REQUIRED=false
echo ""

################################################################################
echo "🔍 Teste 2: Docker saudável (mocks) com latência medida"
################################################################################

reset_state
export MOCK_DOCKER_MODE=healthy MOCK_CTR_MODE=healthy
collect_docker
assert_eq "HEALTHY" "$DOCKER_STATUS" "estado HEALTHY"
assert_eq "INFO" "$DOCKER_SEVERITY" "severidade INFO"
assert_eq "true" "$DOCKER_INSTALLED" "docker detectado como instalado"
assert_eq "5" "$DOCKER_RUNNING_COUNT" "5 containers ativos via docker ps"
assert_true '[ -n "$DOCKER_PS_LATENCY_MS" ] && [ "$DOCKER_PS_LATENCY_MS" -ge 0 ]' "latência do docker ps medida"
assert_true '[ -n "$CONTAINERD_LATENCY_MS" ] && [ "$CONTAINERD_LATENCY_MS" -ge 0 ]' "latência do containerd medida"
assert_eq "HEALTHY" "$CONTAINERD_STATUS" "containerd HEALTHY"
assert_eq "active" "$DOCKER_SERVICE_STATE" "serviço docker active (systemd simulado)"
echo ""

################################################################################
echo "🔍 Teste 3: Docker lento"
################################################################################

reset_state
export MOCK_DOCKER_MODE=slow MOCK_DOCKER_DELAY=0.3
MONITOR_DOCKER_SLOW_MS=100 collect_docker
assert_eq "SLOW" "$DOCKER_STATUS" "latência acima do threshold => SLOW"
assert_eq "WARNING" "$DOCKER_SEVERITY" "SLOW => WARNING"
export MOCK_DOCKER_MODE=healthy
echo ""

################################################################################
echo "🔍 Teste 4: docker ps em timeout, containerd saudável"
################################################################################

reset_state
export MOCK_DOCKER_MODE=timeout MOCK_CTR_MODE=healthy
collect_docker
assert_eq "DOCKER_UNRESPONSIVE_CONTAINERD_HEALTHY" "$DOCKER_STATUS" "Docker vítima do host detectado"
assert_eq "CRITICAL" "$DOCKER_SEVERITY" "severidade CRITICAL"
assert_eq "false" "$DOCKER_PS_OK" "docker ps marcado como falho"
assert_true '[ "$DOCKER_PS_LATENCY_MS" -lt 3000 ]' "timeout de 1s respeitado (não esperou 30s)"
echo ""

################################################################################
echo "🔍 Teste 5: Docker e containerd indisponíveis"
################################################################################

reset_state
export MOCK_DOCKER_MODE=timeout MOCK_CTR_MODE=timeout
export MOCK_SYSTEMCTL_DOCKER=failed MOCK_SYSTEMCTL_CONTAINERD=failed
collect_docker
assert_eq "DOCKER_AND_CONTAINERD_UNRESPONSIVE" "$DOCKER_STATUS" "colapso total detectado"
assert_eq "EMERGENCY" "$DOCKER_SEVERITY" "severidade EMERGENCY"
export MOCK_SYSTEMCTL_DOCKER=active MOCK_SYSTEMCTL_CONTAINERD=active
echo ""

################################################################################
echo "🔍 Teste 6: Docker não instalado e permissão negada"
################################################################################

reset_state
MONITOR_DOCKER_BIN=/nonexistent/docker collect_docker
assert_eq "DOCKER_NOT_INSTALLED" "$DOCKER_STATUS" "binário ausente => DOCKER_NOT_INSTALLED"
assert_eq "UNKNOWN" "$DOCKER_SEVERITY" "sem incidente quando não requerido"

reset_state
export MOCK_DOCKER_MODE=permission MOCK_CTR_MODE=healthy
collect_docker
assert_eq "PERMISSION_DENIED" "$DOCKER_STATUS" "permission denied detectado"
assert_eq "WARNING" "$DOCKER_SEVERITY" "permissão negada => WARNING"
assert_eq "true" "$DOCKER_PERMISSION_ERROR" "flag de permissão marcada"
export MOCK_DOCKER_MODE=healthy
echo ""

################################################################################
echo "🔍 Teste 7: Sistema sem systemd e daemons via /proc"
################################################################################

reset_state
MONITOR_SYSTEMCTL_BIN=/nonexistent/systemctl collect_docker
assert_eq "no-systemd" "$DOCKER_SERVICE_STATE" "ausência de systemd não interrompe"
assert_eq "HEALTHY" "$DOCKER_STATUS" "classificação continua funcionando sem systemd"

# dockerd simulado em /proc fixture
mkdir -p "$TEST_TMP/proc/4242"
echo "dockerd" > "$TEST_TMP/proc/4242/comm"
printf 'State:\tS (sleeping)\nVmRSS:\t  94208 kB\nThreads:\t72\n' > "$TEST_TMP/proc/4242/status"
MONITOR_PROC_DIR="$TEST_TMP/proc" monitor_collect_daemon_info dockerd DOCKERD
assert_eq "4242" "$DOCKERD_PID" "PID do dockerd via /proc"
assert_eq "72" "$DOCKERD_THREADS" "threads do dockerd via /proc"
assert_eq "92" "$DOCKERD_RSS_MB" "RSS do dockerd em MB"
echo ""

################################################################################
echo "🔍 Teste 8: Conversões de memória, cpuset e CPUs permitidas"
################################################################################

assert_eq "361" "$(monitor_mem_to_mb "361.1MiB")" "361.1MiB => 361 MB"
assert_eq "1536" "$(monitor_mem_to_mb "1.5GiB")" "1.5GiB => 1536 MB"
assert_eq "1" "$(monitor_mem_to_mb "1024KiB")" "1024KiB => 1 MB"
assert_eq "5" "$(monitor_cpuset_count "0-3,8")" "cpuset 0-3,8 => 5 CPUs"
assert_eq "1.00|true" "$(monitor_container_cpus_allowed 1000000000 0 0 '' 4)" "NanoCpus 1e9 => 1 CPU limitado"
assert_eq "2.00|true" "$(monitor_container_cpus_allowed 0 200000 100000 '' 4)" "quota 2x período => 2 CPUs"
assert_eq "4|false" "$(monitor_container_cpus_allowed 0 0 0 '' 4)" "sem limites => host inteiro"
echo ""

################################################################################
echo "🔍 Teste 9: Inventário completo de containers (mocks)"
################################################################################

reset_state
export MOCK_DOCKER_MODE=healthy MOCK_CTR_MODE=healthy
unset MOCK_DOCKER_STATS_FAIL MOCK_DOCKER_INSPECT_FAIL
collect_host_info
collect_docker
collect_containers
assert_eq "ok" "$CONTAINERS_STATUS" "inventário completo"
assert_eq "6" "$CONTAINERS_TOTAL" "6 containers no total"
assert_eq "4" "$CONTAINERS_RUNNING" "4 rodando"
assert_eq "1" "$CONTAINERS_STOPPED" "1 parado"
assert_eq "1" "$CONTAINERS_RESTARTING" "1 reiniciando"
assert_eq "1" "$CONTAINERS_UNHEALTHY" "1 unhealthy (somente rodando)"
assert_eq "1" "$CONTAINERS_NO_MEM_LIMIT" "1 rodando sem limite de memória"
echo ""

################################################################################
echo "🔍 Teste 10: Limites de memória por container"
################################################################################

assert_eq "384" "$(container_field bugroyale-worker 20)" "limite de memória 384 MB"
assert_eq "94.0" "$(container_field bugroyale-worker 22)" "94% do limite"
assert_eq "CRITICAL" "$(container_field bugroyale-worker 23)" "94% => CRITICAL"
assert_eq "0" "$(container_field automind 20)" "automind sem limite (0)"
assert_eq "WARNING" "$(container_field automind 23)" "sem limite => WARNING"
assert_eq "WARNING" "$(container_field postgres-x1y2z3 23)" "82% do limite => WARNING"
assert_eq "EMERGENCY" "$(container_field esus 23)" "97.7% do limite => EMERGENCY"
assert_eq "INFO" "$(container_field old-app 23)" "parado sem limite => INFO (sem ruído)"
echo ""

################################################################################
echo "🔍 Teste 11: CPU >100% multicore e limites de CPU"
################################################################################

assert_eq "320.00" "$(container_field automind 13)" "CPU bruta 320% preservada"
assert_eq "80.0" "$(container_field automind 14)" "normalizada por 4 vCPUs => 80%"
assert_eq "80.0" "$(container_field automind 17)" "sem limite: % do host => 80%"
assert_eq "INFO" "$(container_field automind 18)" "1ª amostra alta ainda não afeta a saúde"
assert_eq "WARNING" "$(container_field automind 33)" "1ª amostra preserva severidade observada"
assert_eq "1" "$(container_field automind 34)" "1ª amostra inicia sequência alta"
assert_eq "1.00" "$(container_field bugroyale-worker 15)" "1 CPU permitida (NanoCpus)"
assert_eq "97.3" "$(container_field bugroyale-worker 17)" "97.35% de 1 CPU => 97.3% (arredondamento IEEE)"
assert_eq "INFO" "$(container_field bugroyale-worker 18)" "pico crítico isolado ainda não afeta a saúde"
assert_eq "CRITICAL" "$(container_field bugroyale-worker 33)" "pico crítico permanece observável"
assert_eq "false" "$(container_field automind 16)" "automind sem limite de CPU"
assert_eq "true" "$(container_field postgres-x1y2z3 16)" "postgres com quota de CPU"

# Persistir a primeira coleta e repetir os mesmos valores confirma CPU sustentada.
monitor_state_save
MONITOR_STATE_BUFFER=""
collect_containers
assert_eq "WARNING" "$(container_field automind 18)" "2ª amostra alta confirma WARNING"
assert_eq "2" "$(container_field automind 34)" "sequência WARNING confirmada"
assert_eq "CRITICAL" "$(container_field bugroyale-worker 18)" "2ª amostra alta confirma CRITICAL"
assert_eq "2" "$(container_field bugroyale-worker 34)" "sequência CRITICAL confirmada"
echo ""

################################################################################
echo "🔍 Teste 12: Restart loop por delta e health status"
################################################################################

assert_eq "CRITICAL" "$(container_field flaky-app 11)" "estado restarting => CRITICAL"
assert_eq "unhealthy" "$(container_field esus 6)" "health unhealthy lido"
assert_eq "healthy" "$(container_field postgres-x1y2z3 6)" "health healthy lido"
assert_eq "none" "$(container_field automind 6)" "sem healthcheck => none (não é falha)"

# Delta: salvar estado, aumentar RestartCount de 7 para 10 e recoletar
monitor_state_save
MONITOR_STATE_BUFFER=""
cp -r "$FIXTURES/docker" "$TEST_TMP/docker-delta"
sed -i 's#|/flaky-app|7|#|/flaky-app|10|#' "$TEST_TMP/docker-delta/inspect.txt"
sed -i 's#|flaky:latest|restarting|Restarting (1) 5 seconds ago#|flaky:latest|running|Up 10 seconds#' "$TEST_TMP/docker-delta/ps-a.txt"
MOCK_DOCKER_FIXTURES="$TEST_TMP/docker-delta" collect_containers
assert_eq "3" "$(container_field flaky-app 10)" "delta de 3 restarts na janela"
assert_eq "WARNING" "$(container_field flaky-app 11)" "3 restarts na janela => WARNING"
echo ""

################################################################################
echo "🔍 Teste 13: Política de restart e heurística de worker"
################################################################################

assert_eq "true" "$(container_field bugroyale-worker 30)" "worker detectado pelo nome"
assert_true 'container_field bugroyale-worker 32 | grep -q "unless-stopped"' "worker + unless-stopped sinalizado"
assert_eq "false" "$(container_field postgres-x1y2z3 30)" "postgres não é worker (sem falso positivo)"
echo ""

################################################################################
echo "🔍 Teste 14: Associação Coolify (labels, API simulada e fallback)"
################################################################################

# Por labels (sem API)
assert_eq "uuid-bugroyale-app" "$(container_field bugroyale-worker 25)" "UUID via label coolify.applicationId"
assert_eq "application" "$(container_field bugroyale-worker 26)" "tipo application via label"
assert_eq "Bug Royale" "$(container_field bugroyale-worker 28)" "projeto via label"
assert_eq "" "$(container_field postgres-x1y2z3 25)" "sem label e sem API => não identificado"

# Mapa da API simulado (injetado — sem Coolify real): match por UUID no nome
MONITOR_COOLIFY_MAP_LOADED=true
MONITOR_COOLIFY_MAP["x1y2z3"]="database:postgres-main"
reset_state
collect_containers
assert_eq "x1y2z3" "$(container_field postgres-x1y2z3 25)" "UUID via mapa da API (uuid no nome)"
assert_eq "database" "$(container_field postgres-x1y2z3 26)" "tipo database via API"
assert_eq "postgres-main" "$(container_field postgres-x1y2z3 27)" "nome amigável via API"

# API indisponível: enriquecimento desligado não impede inventário local
unset 'MONITOR_COOLIFY_MAP[x1y2z3]'
MONITOR_COOLIFY_MAP_LOADED=false
MONITOR_COOLIFY_ENRICH=true COOLIFY_API_ENABLED=false reset_state
MONITOR_COOLIFY_ENRICH=true COOLIFY_API_ENABLED=false collect_containers
assert_eq "6" "$CONTAINERS_TOTAL" "inventário local intacto com API desabilitada"
MONITOR_COOLIFY_MAP_LOADED=true
echo ""

################################################################################
echo "🔍 Teste 15: Falhas parciais e inventário vazio"
################################################################################

reset_state
MOCK_DOCKER_STATS_FAIL=1 collect_containers
assert_eq "parcial" "$CONTAINERS_STATUS" "falha em docker stats => parcial"
assert_eq "6" "$CONTAINERS_TOTAL" "inventário continua com stats falho"
assert_eq "" "$(container_field bugroyale-worker 19)" "memória vazia sem stats"

reset_state
MOCK_DOCKER_INSPECT_FAIL=1 collect_containers
assert_eq "parcial" "$CONTAINERS_STATUS" "falha em docker inspect => parcial"
assert_eq "6" "$CONTAINERS_TOTAL" "inventário continua com inspect falho"

mkdir -p "$TEST_TMP/docker-empty"
: > "$TEST_TMP/docker-empty/ps.txt"
: > "$TEST_TMP/docker-empty/ps-a.txt"
: > "$TEST_TMP/docker-empty/stats.txt"
: > "$TEST_TMP/docker-empty/inspect.txt"
cp "$FIXTURES/docker/ctr.txt" "$TEST_TMP/docker-empty/"
reset_state
MOCK_DOCKER_FIXTURES="$TEST_TMP/docker-empty" collect_containers
assert_eq "vazio" "$CONTAINERS_STATUS" "inventário vazio detectado"
echo ""

################################################################################
echo "🔍 Teste 16: Docker indisponível => estado parcial via containerd"
################################################################################

reset_state
export MOCK_DOCKER_MODE=timeout MOCK_CTR_MODE=healthy
collect_docker
collect_containers
assert_eq "parcial" "$CONTAINERS_STATUS" "estado parcial sem Docker"
assert_eq "2" "$CONTAINERS_TOTAL" "2 containers contados via ctr"
assert_true 'echo "$CONTAINERS_STATUS_NOTE" | grep -q containerd' "nota explica origem parcial"
export MOCK_DOCKER_MODE=healthy
echo ""

################################################################################
echo "🔍 Teste 17: Execução fim a fim — JSON, KV e segurança de token"
################################################################################

E2E_ENV=(
    "MONITOR_CONFIG_FILE=/dev/null"
    "MONITOR_STATE_DIR=$TEST_TMP/e2e-state"
    "MONITOR_LOCK_FILE=$TEST_TMP/e2e.lock"
    "MONITOR_PROC_DIR=$FIXTURES/proc-normal"
    "MONITOR_SYS_CGROUP_DIR=$FIXTURES/cgroup-v2"
    "MONITOR_CPU_SAMPLE_INTERVAL=0"
    "MONITOR_DOCKER_BIN=$MOCKBIN/docker"
    "MONITOR_CTR_BIN=$MOCKBIN/ctr"
    "MONITOR_SYSTEMCTL_BIN=$MOCKBIN/systemctl"
    "MONITOR_DOCKER_SOCKET=$TEST_TMP/docker.sock"
    "MOCK_DOCKER_FIXTURES=$FIXTURES/docker"
    "MOCK_DOCKER_MODE=healthy"
    "MOCK_CTR_MODE=healthy"
    "MONITOR_COOLIFY_ENRICH=false"
    "COOLIFY_API_TOKEN=SECRET_TOKEN_XYZ_NUNCA_EXIBIR"
)

json_out=$(env "${E2E_ENV[@]}" "$MONITOR_DIR/vps-monitor.sh" check --json 2>&1)
if command -v python3 &>/dev/null; then
    echo "$json_out" | python3 -m json.tool >/dev/null 2>&1
    assert_eq "0" "$?" "JSON válido com blocos docker/containers"
fi
assert_true 'echo "$json_out" | grep -q "\"status\": \"HEALTHY\""' "JSON contém docker.status"
assert_true 'echo "$json_out" | grep -q "containers_summary"' "JSON contém containers_summary"
assert_true 'echo "$json_out" | grep -q "bugroyale-worker"' "JSON contém inventário"
assert_true '! echo "$json_out" | grep -q "SECRET_TOKEN_XYZ"' "token NUNCA aparece no JSON"

kv_out=$(env "${E2E_ENV[@]}" "$MONITOR_DIR/vps-monitor.sh" check --kv 2>&1)
assert_eq "HEALTHY" "$(echo "$kv_out" | awk -F= '$1=="docker.status"{print $2}')" "KV docker.status"
assert_eq "6" "$(echo "$kv_out" | awk -F= '$1=="containers.total"{print $2}')" "KV containers.total"
assert_eq "1" "$(echo "$kv_out" | awk -F= '$1=="containers.unhealthy"{print $2}')" "KV containers.unhealthy"
assert_true '! echo "$kv_out" | grep -q "SECRET_TOKEN_XYZ"' "token NUNCA aparece no KV"

human_out=$(env "${E2E_ENV[@]}" "$MONITOR_DIR/vps-monitor.sh" check 2>&1)
assert_true 'echo "$human_out" | grep -q "Docker / Containerd"' "saída humana tem seção Docker"
assert_true 'echo "$human_out" | grep -q "Top memória (containers)"' "saída humana tem top de containers"
assert_true '! echo "$human_out" | grep -q "SECRET_TOKEN_XYZ"' "token NUNCA aparece na saída humana"

containers_out=$(env "${E2E_ENV[@]}" "$MONITOR_DIR/vps-monitor.sh" containers 2>&1)
assert_true 'echo "$containers_out" | grep -q "bugroyale-worker"' "subcomando containers lista inventário"
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
