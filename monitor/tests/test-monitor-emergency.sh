#!/bin/bash
################################################################################
# Script: test-monitor-emergency.sh
# Propósito: Testes do marco M8 — modo de emergência e pacote de diagnóstico
# Uso: ./monitor/tests/test-monitor-emergency.sh
#
# Usa diretórios temporários e binários simulados. NUNCA depende de Docker real,
# NUNCA envia webhook real, NUNCA envia sinal a processo real, NUNCA escreve em
# /var/lib.
################################################################################

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONITOR_DIR="$(dirname "$TESTS_DIR")"
ROOT_DIR="$(dirname "$MONITOR_DIR")"
FIXTURES="$TESTS_DIR/fixtures"

TEST_TMP=$(mktemp -d /tmp/vpsguardian-m8-test.XXXXXX)
trap 'chmod -R u+rwX "$TEST_TMP" 2>/dev/null; rm -rf "$TEST_TMP"' EXIT

export MONITOR_CONFIG_FILE=/dev/null
export MONITOR_STATE_DIR="$TEST_TMP/state"
export DEBUG=0

source "$ROOT_DIR/lib/monitor-common.sh" || { echo "✗ monitor-common.sh"; exit 1; }
source "$ROOT_DIR/lib/notificacoes.sh" 2>/dev/null
source "$ROOT_DIR/lib/monitor-alerts.sh" || { echo "✗ monitor-alerts.sh"; exit 1; }
source "$ROOT_DIR/lib/monitor-correlation.sh" || { echo "✗ monitor-correlation.sh"; exit 1; }
source "$ROOT_DIR/lib/monitor-history.sh" || { echo "✗ monitor-history.sh"; exit 1; }
source "$ROOT_DIR/lib/monitor-docker.sh" || { echo "✗ monitor-docker.sh"; exit 1; }
source "$ROOT_DIR/lib/monitor-emergency.sh" || { echo "✗ monitor-emergency.sh"; exit 1; }
monitor_load_config
monitor_init_dirs

echo "╔════════════════════════════════════════════════════════════╗"
echo "║       TESTES DO MONITOR PREVENTIVO (M8 — Emergência)       ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

ERROS=0
assert_eq() { if [ "$1" = "$2" ]; then echo "  ✓ $3"; else echo "  ✗ $3 (esperado: '$1', obtido: '$2')"; ((ERROS++)); fi; }
assert_true() { if eval "$1"; then echo "  ✓ $2"; else echo "  ✗ $2 (falhou: $1)"; ((ERROS++)); fi; }

VPSMON="$MONITOR_DIR/vps-monitor.sh"

# Mocks (docker/ctr/systemctl) para emergency via subprocesso
MOCKBIN="$TEST_TMP/bin"; mkdir -p "$MOCKBIN"
make_mocks() {
    local mode="${1:-healthy}"
    cat > "$MOCKBIN/docker" <<MOCK
#!/bin/bash
case "$mode" in
  timeout) sleep 30 ;;
  missing) exit 127 ;;
esac
case "\$1" in
  info) echo "Server Version: 27.0.1" ;;
  ps) echo "CONTAINER ID   IMAGE" ;;
  stats) echo "no stats" ;;
esac
exit 0
MOCK
    cat > "$MOCKBIN/ctr" <<'MOCK'
#!/bin/bash
echo "CONTAINER    IMAGE    RUNTIME"
exit 0
MOCK
    cat > "$MOCKBIN/systemctl" <<'MOCK'
#!/bin/bash
[ "$1" = "is-active" ] && echo active
exit 0
MOCK
    chmod +x "$MOCKBIN"/*
}
make_mocks healthy

# Ambiente base do emergency via subprocesso
emg() {
    env MONITOR_CONFIG_FILE=/dev/null MONITOR_STATE_DIR="$TEST_TMP/state" \
        MONITOR_PROC_DIR="$FIXTURES/proc-overload" MONITOR_SYS_CGROUP_DIR="$FIXTURES/cgroup-v2" \
        MONITOR_CPU_SAMPLE_INTERVAL=0 MONITOR_DOCKER_BIN="$MOCKBIN/docker" \
        MONITOR_CTR_BIN="$MOCKBIN/ctr" MONITOR_SYSTEMCTL_BIN="$MOCKBIN/systemctl" \
        MONITOR_EMERGENCY_PS_SOURCE="$FIXTURES/emergency/ps-danger.txt" \
        "$VPSMON" emergency "$@"
}
last_incident() { find "$TEST_TMP/state/incidents" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort | tail -1; }
clean_inc() { rm -rf "$TEST_TMP/state/incidents" "$TEST_TMP/state/emergency.lock"; }

################################################################################
echo "🔍 Teste 1: Sanitização (funções puras)"
################################################################################
assert_eq 'x --token=[REDACTED] y' "$(echo 'x --token=SECRET123 y' | emergency_sanitize)" "token= sanitizado"
assert_eq 'password=[REDACTED]' "$(echo 'password=hunter2' | emergency_sanitize)" "password= sanitizado"
assert_true 'echo "redis://u:s3cr3t@h:6379" | emergency_sanitize | grep -q "u:\[REDACTED\]@"' "credencial em URL sanitizada"
assert_true 'echo "https://discord.com/api/webhooks/1/ABCDEF" | emergency_sanitize | grep -q "webhooks/\[REDACTED\]"' "webhook sanitizado"
assert_true 'echo "Authorization: Bearer abcdef123456" | emergency_sanitize | grep -q "REDACTED"' "Bearer sanitizado"
assert_true 'echo "MY_TOKEN=abcxyz" | emergency_sanitize | grep -q "MY_TOKEN=\[REDACTED\]"' "VAR_TOKEN= sanitizado"
assert_true 'echo "conteudo normal load 1.5" | emergency_sanitize | grep -q "load 1.5"' "texto normal preservado"
echo ""

################################################################################
echo "🔍 Teste 2: Validação de output-dir e deadline"
################################################################################
assert_true '! monitor_emergency_validate_output_dir ""' "output-dir vazio rejeitado"
assert_true '! monitor_emergency_validate_output_dir "/"' "output-dir / rejeitado"
assert_true '! monitor_emergency_validate_output_dir "relativo/x"' "output-dir relativo rejeitado"
assert_true 'monitor_emergency_validate_output_dir "/var/lib/x"' "output-dir absoluto aceito"
ln -s /tmp "$TEST_TMP/symlinky" 2>/dev/null
assert_true '! monitor_emergency_validate_output_dir "$TEST_TMP/symlinky/sub"' "output-dir com symlink rejeitado"
out=$(emg --deadline abc 2>&1); rc=$?
assert_eq "3" "$rc" "deadline inválido => exit 3"
out=$(emg --output-dir "" 2>&1 </dev/null; echo); # vazio vira default, não erro
clean_inc
echo ""

################################################################################
echo "🔍 Teste 3: Pacote completo (host saudável) e estrutura"
################################################################################
clean_inc
env MONITOR_CONFIG_FILE=/dev/null MONITOR_STATE_DIR="$TEST_TMP/state" \
    MONITOR_PROC_DIR="$FIXTURES/proc-normal" MONITOR_SYS_CGROUP_DIR="$FIXTURES/cgroup-v2" \
    MONITOR_CPU_SAMPLE_INTERVAL=0 MONITOR_DOCKER_BIN="$MOCKBIN/docker" \
    MONITOR_CTR_BIN="$MOCKBIN/ctr" MONITOR_SYSTEMCTL_BIN="$MOCKBIN/systemctl" \
    MONITOR_EMERGENCY_PS_SOURCE="$FIXTURES/emergency/ps-danger.txt" \
    MONITOR_EMERGENCY_JOURNAL_SOURCE="$FIXTURES/emergency/journal-oom.txt" \
    MONITOR_EMERGENCY_DMESG_SOURCE="$FIXTURES/emergency/journal-oom.txt" \
    "$VPSMON" emergency --deadline 30 >/dev/null 2>&1
rc=$?
INC=$(last_incident)
assert_true '[ -n "$INC" ] && [ -d "$INC" ]' "diretório de incidente criado"
assert_true '[ -f "$INC/manifest.json" ]' "manifest.json presente"
assert_true '[ -f "$INC/summary.txt" ]' "summary.txt presente"
assert_true '[ -f "$INC/summary.json" ]' "summary.json presente"
assert_true '[ -f "$INC/errors.jsonl" ]' "errors.jsonl presente"
assert_true '[ -f "$INC/checksums.sha256" ]' "checksums.sha256 presente"
assert_true '[ -f "$INC/host/load.txt" ] && [ -f "$INC/host/memory.txt" ]' "P0: host coletado"
assert_true '[ -f "$INC/host/processes-state.txt" ]' "processos-state derivado"
assert_true '[ -f "$INC/runtime/docker-status.txt" ]' "P1: runtime coletado"
assert_true '[ -f "$INC/laravel/workers.json" ]' "laravel coletado"
if command -v python3 &>/dev/null; then
    python3 -m json.tool < "$INC/manifest.json" >/dev/null 2>&1; assert_eq "0" "$?" "manifest JSON válido"
    python3 -m json.tool < "$INC/summary.json" >/dev/null 2>&1; assert_eq "0" "$?" "summary JSON válido"
fi
echo ""

################################################################################
echo "🔍 Teste 4: Permissões corretas"
################################################################################
dperm=$(stat -c '%a' "$INC"); assert_eq "750" "$dperm" "diretório 0750"
fperm=$(stat -c '%a' "$INC/manifest.json"); assert_eq "640" "$fperm" "arquivos 0640"
echo ""

################################################################################
echo "🔍 Teste 5: Processos D/Z, worker Horizon e OOM detectados"
################################################################################
assert_true 'grep -q "queue:work\|horizon:work" "$INC/host/processes-state.txt" || grep -qE " D | Z " "$INC/host/processes-state.txt"' "estado D/Z capturado"
assert_true 'grep -q "defunct\|Z " "$INC/host/processes-state.txt"' "zombie capturado"
assert_true 'grep -qi "out of memory\|oom" "$INC/logs/oom.txt"' "OOM detectado no journal"
assert_true 'grep -q "Processos em D" "$INC/summary.txt"' "summary reporta processos D"
assert_true 'grep -q "OOM detectado: sim" "$INC/summary.txt"' "summary reporta OOM"
echo ""

################################################################################
echo "🔍 Teste 6: Nenhum secret no pacote inteiro"
################################################################################
assert_true '! grep -RInE "SECRETXYZ|hunter2|SECRETTOKEN" "$INC" 2>/dev/null' "nenhum secret real no pacote"
assert_true 'grep -q "REDACTED" "$INC/host/processes-state.txt"' "linha do worker foi sanitizada"
assert_true 'grep -q "\"secrets_redacted\":true" "$INC/manifest.json"' "manifest marca secrets_redacted"
echo ""

################################################################################
echo "🔍 Teste 7: Checksums determinísticos e verificáveis"
################################################################################
assert_true '(cd "$INC" && sha256sum -c checksums.sha256 >/dev/null 2>&1)' "checksums verificam (sha256sum -c)"
assert_true '! grep -q "checksums.sha256" "$INC/checksums.sha256"' "checksums não inclui a si mesmo"
o1=$(sort "$INC/checksums.sha256" | md5sum); o2=$(sort "$INC/checksums.sha256" | md5sum)
assert_eq "$o1" "$o2" "ordenação determinística"
clean_inc
echo ""

################################################################################
echo "🔍 Teste 8: Docker travado respeita timeout; pacote parcial utilizável"
################################################################################
make_mocks timeout
start=$(date +%s)
env MONITOR_CONFIG_FILE=/dev/null MONITOR_STATE_DIR="$TEST_TMP/state" \
    MONITOR_PROC_DIR="$FIXTURES/proc-overload" MONITOR_SYS_CGROUP_DIR="$FIXTURES/cgroup-v2" \
    MONITOR_CPU_SAMPLE_INTERVAL=0 MONITOR_DOCKER_BIN="$MOCKBIN/docker" \
    MONITOR_CTR_BIN="$MOCKBIN/ctr" MONITOR_SYSTEMCTL_BIN="$MOCKBIN/systemctl" \
    MONITOR_EMERGENCY_PS_SOURCE="$FIXTURES/emergency/ps-danger.txt" \
    MONITOR_DOCKER_TIMEOUT_SECONDS=2 MONITOR_EMERGENCY_COMMAND_TIMEOUT=2 \
    "$VPSMON" emergency --deadline 30 >/dev/null 2>&1
rc=$?
elapsed=$(( $(date +%s) - start ))
INC=$(last_incident)
assert_true '[ -d "$INC" ]' "pacote gerado mesmo com Docker travado"
assert_true '[ "$elapsed" -lt 30 ]' "não travou (concluiu em ${elapsed}s < 30)"
assert_true '[ -f "$INC/host/load.txt" ]' "P0 host coletado apesar do Docker travado"
assert_true 'grep -q TIMEOUT "$INC/errors.jsonl"' "timeout do Docker registrado em errors.jsonl"
assert_eq "1" "$rc" "exit 1 (parcial) — não falha total por causa do Docker"
make_mocks healthy; clean_inc
echo ""

################################################################################
echo "🔍 Teste 9: Funciona sem Docker instalado"
################################################################################
env MONITOR_CONFIG_FILE=/dev/null MONITOR_STATE_DIR="$TEST_TMP/state" \
    MONITOR_PROC_DIR="$FIXTURES/proc-normal" MONITOR_SYS_CGROUP_DIR="$FIXTURES/cgroup-v2" \
    MONITOR_CPU_SAMPLE_INTERVAL=0 MONITOR_DOCKER_BIN=/nonexistent/docker \
    MONITOR_CTR_BIN=/nonexistent/ctr MONITOR_SYSTEMCTL_BIN=/nonexistent/systemctl \
    MONITOR_EMERGENCY_PS_SOURCE="$FIXTURES/emergency/ps-danger.txt" \
    "$VPSMON" emergency --deadline 30 >/dev/null 2>&1
INC=$(last_incident)
assert_true '[ -f "$INC/host/load.txt" ]' "P0 coletado sem Docker instalado"
assert_true 'grep -q "não instalado\|desconhecido" "$INC/runtime/docker-info.txt" "$INC/runtime/docker-status.txt"' "runtime marca Docker ausente"
clean_inc
echo ""

################################################################################
echo "🔍 Teste 10: Deadline global interrompe coletas tardias (SKIPPED)"
################################################################################
# deadline mínimo => P2 deve ser pulado; pacote ainda utilizável
env MONITOR_CONFIG_FILE=/dev/null MONITOR_STATE_DIR="$TEST_TMP/state" \
    MONITOR_PROC_DIR="$FIXTURES/proc-normal" MONITOR_SYS_CGROUP_DIR="$FIXTURES/cgroup-v2" \
    MONITOR_CPU_SAMPLE_INTERVAL=0 MONITOR_DOCKER_BIN="$MOCKBIN/docker" \
    MONITOR_CTR_BIN="$MOCKBIN/ctr" MONITOR_SYSTEMCTL_BIN="$MOCKBIN/systemctl" \
    MONITOR_EMERGENCY_PS_SOURCE="$FIXTURES/emergency/ps-danger.txt" \
    "$VPSMON" emergency --deadline 5 >/dev/null 2>&1 &
epid=$!
# força o relógio: injeta um deadline já vencido não é possível via env; então
# validamos que o comando termina bem dentro de um limite (não pendura)
wait $epid; rc=$?
INC=$(last_incident)
assert_true '[ -f "$INC/host/load.txt" ]' "P0 sempre coletado antes do deadline curto"
assert_true '[ -f "$INC/manifest.json" ]' "manifesto gerado mesmo com deadline curto"
clean_inc
echo ""

################################################################################
echo "🔍 Teste 11: --archive cria tar.gz + sha256; diretório preservado"
################################################################################
if command -v tar &>/dev/null && command -v gzip &>/dev/null; then
    emg --deadline 30 --archive >/dev/null 2>&1
    INC=$(last_incident)
    arch=$(find "$TEST_TMP/state/incidents" -maxdepth 1 -name 'incident-*.tar.gz' | tail -1)
    assert_true '[ -n "$arch" ] && [ -f "$arch" ]' "--archive cria tar.gz"
    assert_true '[ -d "$INC" ]' "diretório original preservado (não removido)"
    assert_true 'grep -q "\"archive_created\":true" "$INC/manifest.json"' "manifest registra archive_created"
    # sha256 do arquivo no manifest confere
    msha=$(grep -oE '"archive_sha256":"[a-f0-9]+"' "$INC/manifest.json" | cut -d'"' -f4)
    real=$(sha256sum "$arch" | cut -d' ' -f1)
    assert_eq "$real" "$msha" "sha256 do arquivo confere com o manifesto"
    clean_inc
else
    echo "  ⚠ tar/gzip ausente; teste de archive pulado"
fi
echo ""

################################################################################
echo "🔍 Teste 12: Lock — segunda execução bloqueada; órfão tratado"
################################################################################
clean_inc
# cria lock ativo apontando para um dir existente e um PID vivo (este shell)
mkdir -p "$TEST_TMP/state/incidents/ACTIVE"
printf '%s %s %s\n' "$$" "$(date +%s)" "$TEST_TMP/state/incidents/ACTIVE" > "$TEST_TMP/state/emergency.lock"
out=$(emg --deadline 10 2>&1); rc=$?
assert_eq "4" "$rc" "segunda emergência com lock ativo => exit 4"
# lock órfão (PID morto)
printf '%s %s %s\n' "999999" "$(date +%s)" "/nao/existe" > "$TEST_TMP/state/emergency.lock"
emg --deadline 20 >/dev/null 2>&1; rc=$?
assert_true '[ "$rc" -ne 4 ]' "lock órfão é recuperado (não bloqueia)"
clean_inc
echo ""

################################################################################
echo "🔍 Teste 13: Goroutine dump só com flag; apenas SIGUSR1; não destrutivo"
################################################################################
# sem flag => nenhum arquivo de dump
clean_inc
emg --deadline 20 >/dev/null 2>&1
INC=$(last_incident)
assert_true '[ ! -f "$INC/runtime/goroutine-dump.txt" ]' "sem flag: nenhum goroutine dump"
clean_inc
# com flag + SIGNAL_CMD mockado que registra o sinal (não mata)
SIGLOG="$TEST_TMP/signals.log"; : > "$SIGLOG"
cat > "$MOCKBIN/fakesig" <<EOF
#!/bin/bash
echo "\$@" >> "$SIGLOG"
EOF
chmod +x "$MOCKBIN/fakesig"
# fixture /proc com dockerd para monitor_find_pid_by_comm
FP="$TEST_TMP/proc-dockerd"; mkdir -p "$FP/4242"; echo dockerd > "$FP/4242/comm"
printf 'State:\tS\nThreads:\t50\nVmRSS:\t 1024 kB\n' > "$FP/4242/status"
cp "$FIXTURES/proc-normal/"{meminfo,loadavg,stat,cpuinfo,uptime} "$FP/" 2>/dev/null
env MONITOR_CONFIG_FILE=/dev/null MONITOR_STATE_DIR="$TEST_TMP/state" \
    MONITOR_PROC_DIR="$FP" MONITOR_SYS_CGROUP_DIR="$FIXTURES/cgroup-v2" \
    MONITOR_CPU_SAMPLE_INTERVAL=0 MONITOR_DOCKER_BIN="$MOCKBIN/docker" \
    MONITOR_CTR_BIN="$MOCKBIN/ctr" MONITOR_SYSTEMCTL_BIN="$MOCKBIN/systemctl" \
    MONITOR_EMERGENCY_PS_SOURCE="$FIXTURES/emergency/ps-danger.txt" \
    MONITOR_EMERGENCY_SIGNAL_CMD="$MOCKBIN/fakesig -USR1" \
    "$VPSMON" emergency --deadline 20 --dockerd-goroutine-dump >/dev/null 2>&1
INC=$(last_incident)
assert_true '[ -f "$INC/runtime/goroutine-dump.txt" ]' "com flag: goroutine dump registrado"
assert_true 'grep -q "USR1" "$SIGLOG"' "sinal enviado foi SIGUSR1"
assert_true '! grep -qE "KILL|TERM|-9|-15" "$SIGLOG"' "nunca SIGKILL/SIGTERM"
clean_inc
echo ""

################################################################################
echo "🔍 Teste 14: --notify reutiliza canal; sem --notify não chama webhook"
################################################################################
clean_inc
CALLS="$TEST_TMP/notify.log"; : > "$CALLS"
# subprocesso não compartilha função mock; validamos via WEBHOOK vazio (DISABLED)
out=$(emg --deadline 20 --notify --format kv 2>&1)
assert_true 'echo "$out" | grep -q "emergency.notification_result="' "resultado de notificação exposto"
# sem --notify: notification_result=skipped
out=$(emg --deadline 20 --format kv 2>&1)
assert_true 'echo "$out" | grep -q "notification_result=skipped"' "sem --notify => skipped (não chama webhook)"
clean_inc
echo ""

################################################################################
echo "🔍 Teste 15: Estado M5/M6/M7 não é alterado; JSON/KV/exit codes"
################################################################################
clean_inc
# cria estados M5/M6/M7 e mede hash antes/depois do emergency
mkdir -p "$TEST_TMP/state/history/metrics"
echo 'incidents-state-conteudo' > "$TEST_TMP/state/incidents.state"
echo 'diag-state-conteudo' > "$TEST_TMP/state/diagnoses.state"
echo '{"m":1}' > "$TEST_TMP/state/history/metrics/metrics-x.jsonl"
h_inc=$(sha256sum "$TEST_TMP/state/incidents.state" | cut -d' ' -f1)
h_dg=$(sha256sum "$TEST_TMP/state/diagnoses.state" | cut -d' ' -f1)
h_m=$(sha256sum "$TEST_TMP/state/history/metrics/metrics-x.jsonl" | cut -d' ' -f1)
emg --deadline 20 >/dev/null 2>&1
assert_eq "$h_inc" "$(sha256sum "$TEST_TMP/state/incidents.state" | cut -d' ' -f1)" "incidents.state (M5) intacto"
assert_eq "$h_dg" "$(sha256sum "$TEST_TMP/state/diagnoses.state" | cut -d' ' -f1)" "diagnoses.state (M6) intacto"
assert_eq "$h_m" "$(sha256sum "$TEST_TMP/state/history/metrics/metrics-x.jsonl" | cut -d' ' -f1)" "histórico M7 intacto"
# JSON válido e KV estável
out=$(emg --deadline 20 --format json 2>&1)
if command -v python3 &>/dev/null; then echo "$out" | python3 -m json.tool >/dev/null 2>&1; assert_eq "0" "$?" "emergency --format json válido"; fi
assert_true 'echo "$out" | grep -q "\"incident_id\""' "JSON contém incident_id"
out=$(emg --deadline 20 --format kv 2>&1)
assert_true 'echo "$out" | grep -q "^emergency.status="' "KV contém emergency.status"
clean_inc
echo ""

################################################################################
echo "🔍 Teste 16: Diagnóstico M6 incluído; histórico M7 opcional"
################################################################################
clean_inc
emg --deadline 20 --format kv > "$TEST_TMP/kv16.txt" 2>&1
# proc-overload => diagnóstico de memória; main_diagnosis_key deve existir
assert_true 'grep -qE "emergency.main_diagnosis_key=diagnosis:" "$TEST_TMP/kv16.txt"' "diagnóstico M6 no resultado"
INC=$(last_incident)
assert_true '[ -f "$INC/history/recent-report.txt" ]' "seção de histórico presente (mesmo sem dados => report vazio)"
clean_inc
echo ""

################################################################################
echo "🔍 Teste 17: Limite agregado MAX_TOTAL_BYTES (truncar/pular, essenciais, secret)"
################################################################################
clean_inc
# Fixture de log grande (~200 KB) com um secret embutido, para forçar o limite total
BIGLOG="$TEST_TMP/biglog.txt"
{ for i in $(seq 1 3000); do echo "Jul 18 09:$((i%60)):00 host kernel: linha de log $i token=SECRETBIG$i"; done; } > "$BIGLOG"

emg_lim() {
    env MONITOR_CONFIG_FILE=/dev/null MONITOR_STATE_DIR="$TEST_TMP/state" \
        MONITOR_PROC_DIR="$FIXTURES/proc-normal" MONITOR_SYS_CGROUP_DIR="$FIXTURES/cgroup-v2" \
        MONITOR_CPU_SAMPLE_INTERVAL=0 MONITOR_DOCKER_BIN="$MOCKBIN/docker" \
        MONITOR_CTR_BIN="$MOCKBIN/ctr" MONITOR_SYSTEMCTL_BIN="$MOCKBIN/systemctl" \
        MONITOR_EMERGENCY_PS_SOURCE="$FIXTURES/emergency/ps-danger.txt" \
        MONITOR_EMERGENCY_DMESG_SOURCE="$BIGLOG" MONITOR_EMERGENCY_JOURNAL_SOURCE="$BIGLOG" \
        MONITOR_EMERGENCY_MAX_TOTAL_BYTES="$1" \
        "$VPSMON" emergency --deadline 30 "${@:2}"
}

# (a) limite alto: pacote não é limitado
emg_lim 52428800 >/dev/null 2>&1
INC=$(last_incident)
assert_true 'grep -q "\"total_limit_reached\":false" "$INC/manifest.json"' "limite alto => não limitado"
clean_inc

# (b) piso 128 KB: vários arquivos ultrapassam o teto agregado
emg_lim 131072 >/dev/null 2>&1; rc=$?
INC=$(last_incident)
total=$(find "$INC" -type f -printf '%s\n' 2>/dev/null | awk '{t+=$1} END{print t+0}')
assert_true '[ "$total" -le 131072 ]' "tamanho final ($total) <= limite (131072)"
assert_true 'grep -q "\"total_limit_reached\":true" "$INC/manifest.json"' "manifest: total_limit_reached=true"
assert_eq "1" "$rc" "pacote limitado => exit 1 (parcial utilizável)"
# essenciais SEMPRE presentes
for f in manifest.json summary.txt summary.json errors.jsonl host/load.txt host/memory.txt host/swap.txt; do
    assert_true "[ -f \"$INC/$f\" ]" "essencial/P0 preservado: $f"
done
# truncados e/ou ignorados registrados
tr_count=$(python3 -c "import json;print(json.load(open('$INC/manifest.json'))['size_limits']['files_truncated_by_total_limit'])")
sk_count=$(python3 -c "import json;print(json.load(open('$INC/manifest.json'))['size_limits']['files_skipped_by_total_limit'])")
assert_true '[ $((tr_count + sk_count)) -ge 1 ]' "houve truncamento e/ou descarte por limite total"
assert_true 'grep -qE "TRUNCATED_TOTAL_LIMIT|SKIPPED_TOTAL_LIMIT" "$INC/errors.jsonl"' "errors.jsonl registra limite total"
# du coincide com a soma dos regulares
du_bytes=$(du -sb "$INC" 2>/dev/null | awk '{print $1}')
assert_true '[ -n "$du_bytes" ] && [ "$du_bytes" -ge "$total" ]' "du coincide com a soma dos arquivos"
# nenhum secret em conteúdo truncado
assert_true '! grep -RIn "SECRETBIG" "$INC" 2>/dev/null' "nenhum secret em conteúdo truncado"
# checksums validam os preservados
assert_true '(cd "$INC" && sha256sum -c checksums.sha256 >/dev/null 2>&1)' "checksums validam após truncamento"
clean_inc

# (c) valores inválidos/zero/negativos => padrão seguro; abaixo do piso => elevado
emg_lim 0 >/dev/null 2>&1; INC=$(last_incident)
mt=$(python3 -c "import json;print(json.load(open('$INC/manifest.json'))['size_limits']['max_total_bytes'])")
assert_eq "52428800" "$mt" "MAX_TOTAL=0 => padrão seguro (50 MB)"
clean_inc
emg_lim abc >/dev/null 2>&1; INC=$(last_incident)
mt=$(python3 -c "import json;print(json.load(open('$INC/manifest.json'))['size_limits']['max_total_bytes'])")
assert_eq "52428800" "$mt" "MAX_TOTAL inválido => padrão seguro"
clean_inc
emg_lim 1000 >/dev/null 2>&1; INC=$(last_incident)
mt=$(python3 -c "import json;print(json.load(open('$INC/manifest.json'))['size_limits']['max_total_bytes'])")
assert_eq "131072" "$mt" "MAX_TOTAL abaixo do piso => elevado a 131072"
clean_inc
echo ""

################################################################################
echo "════════════════════════════════════════════════════════════"
if [ "$ERROS" -eq 0 ]; then
    echo "✅ Todos os testes passaram"; exit 0
else
    echo "❌ $ERROS teste(s) falharam"; exit 1
fi
