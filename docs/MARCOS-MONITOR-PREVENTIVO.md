# Marcos de Execução — Monitor Preventivo (VPS Guardian)

> Plano de implementação do monitor preventivo de recursos para servidores Coolify,
> integrado ao VPS Guardian.
>
> Criado em: 2026-07-17
> Origem: incidente de sobrecarga (load 227, swap 99%, Docker inacessível) causado por
> worker Laravel Horizon mal configurado + containers sem limites + throttling do provedor.

---

## Decisões de arquitetura

| Decisão | Escolha | Justificativa |
|---|---|---|
| Linguagem | **Bash integrado ao VPS Guardian** | Reusa `lib/notificacoes.sh`, `lib/coolify-api.sh`, `lib/common.sh`, padrão de config e instalador. Evita dependência de Python/pip na VPS. |
| Persistência | **JSON Lines** (`/var/lib/vpsguardian/monitor/`) | Sem dependência de SQLite; fácil de consultar com `jq` (já usado no projeto). |
| Execução | **Timer systemd a cada 1 min, no host (fora do Docker)** | O monitor precisa funcionar quando o Docker travar. |
| API do Coolify | **Usar desde o início (já existe em `lib/coolify-api.sh`)** | Enriquecer alertas com projeto/aplicação/UUID. Sempre com fallback para Docker labels quando API indisponível. |
| Alertas | **Discord como canal primário** (já implementado), Slack/e-mail secundários | `lib/notificacoes.sh` já cobre os três canais. |
| Ações automáticas | **Desativadas por padrão** | Primeira versão é somente diagnóstico. Nunca reiniciar VPS automaticamente. |

### Regras invioláveis (aplicam-se a todos os marcos)

1. Todo comando externo executa com `timeout` (padrão 5s, configurável).
2. Nenhuma métrica essencial depende do Docker — coleta primária via `/proc` e `/sys`.
3. `docker ps` travado **não** é interpretado como corrupção do daemon.
4. Tokens/secrets nunca aparecem em logs ou alertas.
5. O próprio monitor deve ser leve (meta: < 2s de CPU e < 50 MB por ciclo).
6. Anti-spam: cooldown, deduplicação e exigência de N verificações consecutivas.

---

## Visão geral dos marcos

```
M0 → M1 → M2 → M3 → M4 → M5 → M6 → M7 → M8 → M9
Fundação  Host  Docker  Containers  Workers  Alertas  Correlação  Histórico  Emergência  Integração
```

Cada marco produz algo executável e testável isoladamente. A partir do M5 o monitor
já entrega valor real em produção (alertas de host); os marcos seguintes ampliam a cobertura.

---

## M0 — Fundação e esqueleto ✅ CONCLUÍDO (2026-07-17)

**Objetivo:** estrutura do módulo, configuração e utilitários base.

**Entregáveis:**
- [x] Diretório `monitor/` com ponto de entrada `monitor/vps-monitor.sh` e subcomandos:
      `check`, `status`, `containers`, `emergency`, `report`, `test-alert`
      (os quatro últimos são stubs que apontam para o marco correspondente)
- [x] `lib/monitor-common.sh` — funções utilitárias: `run_with_timeout`, leitura de
      config, lock, sinais, severidade, estado entre execuções, conversão de unidades
- [x] Arquivo próprio `config/monitor.conf.example` com todos os thresholds da spec
      (memória, swap, load_ratio, CPU, steal, iowait, disco) e exemplo comentado;
      o `monitor.conf` do usuário nunca é sobrescrito em atualizações
- [x] Diretórios de estado: `/var/lib/vpsguardian/monitor/` (criados em runtime,
      com fallback para /tmp quando sem permissão; `incidents/` fica para o M8)
- [x] Entrada no `menu-principal.sh` (Status e Diagnóstico → opção 4) e
      instalação via `instalar.sh`

**Critérios de aceite:** `vps-monitor.sh check` roda sem erro e grava snapshot
JSON em `last-check.json`; sem nenhuma config, usa defaults seguros. ✔ Validado.

---

## M1 — Coletores de host (`/proc`) ✅ CONCLUÍDO (2026-07-17)

**Objetivo:** métricas essenciais sem depender do Docker.

**Entregáveis:**
- [x] Memória: total, disponível, usada, percentual (`/proc/meminfo`, com fallback
      para kernels sem `MemAvailable`)
- [x] Swap: total, usada, percentual, **delta entre verificações** (crescimento)
- [x] Load: 1/5/15 min (`/proc/loadavg`) + `load_ratio = load_1min / vCPUs`
- [x] CPU: uso total, idle, user, system, **steal**, **I/O wait**
      (delta de duas leituras de `/proc/stat` na mesma execução)
- [x] Disco: uso e inodes da partição raiz (`df` com timeout; partição configurável)
- [x] Throttling por cgroup: `cpu.max`/`cfs_quota_us` + `nr_periods`/`nr_throttled`/
      `throttled_usec` (suporte a cgroup v1 e v2), com delta entre verificações
- [x] Top 10 processos por CPU e por memória (`ps -eo ... --sort`)
- [x] Estado anterior persistido para cálculo de deltas (swap crescente, throttling
      crescente) em `previous-metrics.env`, gravação atômica

**Testes:** `monitor/tests/test-monitor.sh` — 13 grupos, fixtures de `/proc` e
`/sys/fs/cgroup` (incluindo cenário do incidente: RAM 742 MB, swap 38%, load 42.7).

**Critérios de aceite:** um ciclo `check` produz JSON com todas as métricas em < 2s
(medido: ~1,1s, dominado pelo intervalo de amostragem de CPU de 1s);
valores validados contra `free -h` e `uptime`. ✔ Validado.

---

## M2 — Saúde do Docker e containerd ✅ CONCLUÍDO (2026-07-17)

**Objetivo:** diagnosticar o Docker sem travar junto com ele.

**Entregáveis:**
- [x] Sondas com timeout e medição de latência (relógio em ms): `docker version`,
      `docker info`, `docker ps` — timeouts e thresholds de lentidão configuráveis
      (`MONITOR_DOCKER_TIMEOUT_SECONDS`, `MONITOR_DOCKER_SLOW_MS`)
- [x] Fallback: `ctr -n moby containers list` com timeout próprio; sem `ctr`
      utilizável, infere containerd por serviço systemd + processo
- [x] `systemctl is-active docker` / `containerd` (ausência de systemd => `no-systemd`,
      sem interromper o monitor)
- [x] Inspeção de processos: PID, estado, threads e RSS de `dockerd`/`containerd`
      via varredura de `/proc` (CPU/etime complementados via `ps` com timeout)
- [x] Classificação nos 4 estados principais: `HEALTHY`, `SLOW`,
      `DOCKER_UNRESPONSIVE_CONTAINERD_HEALTHY`, `DOCKER_AND_CONTAINERD_UNRESPONSIVE`
      + auxiliares (`DOCKER_NOT_INSTALLED`, `PERMISSION_DENIED`,
      `DOCKER_UNRESPONSIVE_CONTAINERD_UNKNOWN`); severidades INFO/WARNING/CRITICAL/
      EMERGENCY conforme o estado; `MONITOR_DOCKER_REQUIRED` torna a ausência crítica
- [x] Latências registradas por sonda no JSON/KV (`docker.latency_ms` etc.) e
      duração do estado persistida (`docker_status_since`) para cooldown futuro

**Critérios de aceite:** validado com binários simulados (timeout, lentidão,
permissão negada, ausência de docker/ctr/systemd) — o ciclo sempre completa e o
estado "Docker vítima do host" é diferenciado de corrupção. ✔ Validado.

---

## M3 — Containers: consumo, limites e restart loops ✅ CONCLUÍDO (2026-07-17)

**Objetivo:** identificar o container causador antes do colapso.

**Entregáveis:**
- [x] Coleta por container: nome, ID (curto e completo), imagem, CPU%, memória,
      limite e reserva de memória, % do limite, restarts, status, health, restart
      policy, uptime — em **3 chamadas Docker em lote** (`ps -a`, `stats --no-stream`,
      `inspect` com todos os IDs), todas com timeout
- [x] Normalização de CPU%: bruto (>100% possível), normalizado por vCPUs do host
      e relativo às CPUs permitidas ao container (NanoCpus/quota/cpuset)
- [x] Detecção de: sem limite de memória (WARNING, com exceções configuráveis para
      infra), sem limite de CPU (INFO configurável), consumo 80/90/97% do limite
      (WARNING/CRITICAL/EMERGENCY), unhealthy (CRITICAL, apenas rodando);
      leituras altas consecutivas persistidas para o M5 (memória crescente e uso
      de swap por container ficam para M5/M6, exigem série histórica)
- [x] Restart loop por **delta na janela** (baseline persistido; padrão 3/5 em
      15 min) + estado `restarting` => CRITICAL; nunca usa só o acumulado
- [x] Associação container → Coolify: labels `coolify.*` sempre; com
      `COOLIFY_API_ENABLED=true`, mapa em lote via `lib/coolify-api.sh`
      (aplicações + databases + services, nunca uma chamada por container);
      falha/ausência da API não impede o inventário; token jamais aparece
- [x] Subcomando `vps-monitor.sh containers` — tabela completa (também `--json`);
      tops de memória/CPU e containers problemáticos no `check`
      (`MONITOR_TOP_CONTAINERS`)
- [x] Docker indisponível => inventário parcial via `ctr` com nota explicativa

**Testes:** `monitor/tests/test-monitor-docker.sh` — 17 grupos com docker/ctr/
systemctl simulados e fixtures (limites, >100% multicore, restart delta,
unhealthy, falhas parciais, Coolify por label e por mapa da API, segurança de token).

**Critérios de aceite:** inventário validado no host real e nos mocks; associação
por label e por API coberta por teste. ✔ Validado.

---

## M4 — Workers Laravel e Horizon ✅ CONCLUÍDO (2026-07-17)

**Objetivo:** detectar o gatilho do incidente original.

**Entregáveis:**
- [x] Varredura de processos via **uma única chamada `ps`** no host (enxerga processos
      dentro de containers): `horizon`, `horizon:work`, `queue:work`, `queue:listen`,
      `schedule:run`, `schedule:work`, `octane`; classificação em 8 tipos
      (`HORIZON_MASTER`/`HORIZON_WORKER`/`QUEUE_WORK`/`QUEUE_LISTEN`/`SCHEDULE_RUN`/
      `SCHEDULE_WORK`/`OCTANE`/`UNKNOWN_LARAVEL`) sem falsos positivos
      (`horizon:status`, `migrate`, `queue:restart` são ignorados)
- [x] Por worker: container de origem via `/proc/<pid>/cgroup` (v1 e v2), tempo de
      execução (`etimes`), CPU bruta/normalizada, memória, RSS, comando completo
      recuperado de `/proc/<pid>/cmdline` quando o `ps` trunca
- [x] Parsing seguro de flags (sem `eval`, formatos `--x=v` e `--x v`): `--timeout`,
      `--memory`, `--max-time`, `--max-jobs`, `--tries`, `--sleep`, `--queue`;
      valores inválidos/negativos rejeitados; `timeout_source=COMMAND|CONFIG_UNKNOWN`,
      `memory_limit_source=COMMAND|CONTAINER|UNKNOWN`
- [x] Regras puras e testáveis por worker (`severity` + `findings[]`): timeout perigoso
      (300/900/3600), workers em excesso por grupo (2/4/8), `queue:listen` em produção,
      `schedule:run` travado, `--memory`/`--max-time` ausente, container sem limite
      (reuso do M3), política de restart, worker compartilhado com web
      (`ISOLATED`/`SHARED_WITH_WEB`/`UNKNOWN`)
- [x] Reuso integral do inventário e do mapa Coolify do M3 (nenhuma chamada Coolify
      por processo, nenhum `docker exec`/`docker top`)
- [x] Saída humana (grupos por container), JSON (`laravel_workers_summary` +
      `laravel_workers[]`) e KV (`laravel_workers.*`); sanitização de tokens/senhas/
      credenciais em todas as três saídas

**Testes:** `monitor/tests/test-monitor-laravel-workers.sh` — 19 grupos, 141 asserts,
com fixture reproduzindo o incidente (6 Horizon workers, `--timeout=36000`, container
sem limite) e os 32 cenários exigidos (flags, cgroup v1/v2, PID sumido, `/proc` sem
permissão, Docker indisponível, CPU multicore, zombie, secrets, JSON/KV).

**Critérios de aceite:** validado no host real (sem workers → INFO) e via fixture do
incidente (`automind` com 8 workers e timeout 36000 → EMERGENCY). ✔ Validado.
Custo adicionado: **1 chamada `ps`** + leituras de `/proc` apenas para PIDs candidatos.

---

## M5 — Motor de alertas ✅ CONCLUÍDO (2026-07-17)

**Objetivo:** alertar cedo, sem spam. **A partir daqui o monitor entra em produção.**

**Entregáveis:**
- [x] Níveis: `INFO`, `WARNING`, `CRITICAL`, `EMERGENCY`, `RECOVERY` (reuso das
      severidades já calculadas em M1–M4; INFO/UNKNOWN nunca notificam)
- [x] Máquina de estados por incidente (`lib/monitor-alerts.sh`): OPEN, ESCALATE,
      REMINDER, RECOVER, SUPPRESS, NONE — função `monitor_incident_decide` pura
- [x] Exigência de N verificações consecutivas antes de abrir
      (`MONITOR_ALERT_CONSECUTIVE`, anti-flapping)
- [x] Histerese para load e CPU steal e confirmação de N coletas saudáveis antes
      de recuperar (`MONITOR_ALERT_RECOVERY_CONSECUTIVE`, padrão 3)
- [x] Anti-spam: cooldown (`MONITOR_ALERT_COOLDOWN_MINUTES`, padrão 15), dedup por
      severidade (só reenvia ao escalar), contador de ocorrências, lembrete opcional
      após cooldown; `last_notified` só avança em envio com SUCESSO
- [x] Agrupamento de todas as transições do ciclo em um único webhook, com limite
      configurável de detalhes (`MONITOR_ALERT_BATCH_MAX_ITEMS`) sem perder o
      estado individual de cada incidente
- [x] Alerta de `RECOVERY` quando a condição some (com duração e pior severidade);
      falha de envio **não** gera falsa recuperação (mantém aberto e retenta)
- [x] **Reutilização integral do Discord existente**: nova função
      `notify_monitor_incident` em `lib/notificacoes.sh` usa o mesmo `WEBHOOK_URL`
      e o mesmo formato de embed; o motor nunca conhece curl/URL/headers.
      Estado do canal normalizado: `SUCCESS`/`FAILED`/`DISABLED`. Flag
      `MONITOR_ALERT_DISCORD_ENABLED` (sem credenciais) liga/desliga o canal
- [x] Mensagens diferenciadas: abertura (🚨), escalonamento (🆘), lembrete (🔁),
      recuperação (✅) e teste (🧪), com servidor/severidade/condição/valores
- [x] `vps-monitor.sh test-alert` — envia teste pelo canal configurado; `--dry-run`
      (alias `--dry-run-alerts`) e `--no-alerts` no `check`. **Dry-run é 100%
      não-destrutivo**: lê o estado real só para simular (em memória), não grava
      `incidents.state`, não chama o webhook e não move contadores/cooldown;
      relatório `WOULD_OPEN/ESCALATE/RECOVER/KEEP_PENDING`; JSON/KV expõem
      `alerts_dry_run`/`state_persisted`/`notifications_sent`
- [x] Timer systemd: `monitor/systemd/vpsguardian-monitor.service` + `.timer` (1 min)
      + `README.md` de instalação (roda no host, fora do Docker)
- [x] Saídas JSON (`alerts{}`) e KV (`alerts.*`) com contadores; webhook nunca exposto

**Testes:** `monitor/tests/test-monitor-alerts.sh` — cobertura automatizada com
`notify_monitor_incident` mockada (nenhum webhook real). Cobre adaptador
SUCCESS/FAILED/DISABLED, dry-run, flag off, máquina de estados pura, abertura/
escalonamento/recuperação, cooldown, falha de rede/timeout, severidade mínima,
N consecutivas, test-alert, isolamento dos alertas antigos, ausência do segredo
em estado/JSON/KV e **isolamento total do dry-run** (hash byte-a-byte, mtime,
contadores, sem criar arquivo, sem acúmulo entre execuções, dry-run→real abre normal).

**Suíte completa:** scripts isolados por módulo, sem acesso ao webhook real.

**Decisão de reuso Discord:** cumpre todas as regras — não cria novo cliente/webhook/
credencial, não duplica o `curl` fora de `lib/notificacoes.sh`, não altera as
assinaturas existentes e os alertas do Coolify/backup seguem intactos.

**Critérios de aceite:** validado no host real via `--dry-run` (abertura de
incidentes de disco/swap, estado atômico persistido, canal `DISABLED` sem envio)
e pela suíte com mocks. ✔ Validado. As quatro suítes anteriores continuam verdes.

---

## M6 — Correlação de sintomas e diagnóstico ✅ CONCLUÍDO (2026-07-17)

**Objetivo:** transformar alertas isolados em diagnóstico provável.

**Entregáveis:**
- [x] `lib/monitor-correlation.sh` — motor de regras com funções puras por cenário
      (`monitor_correlation_eval_memory/_throttling/_laravel/_docker`), sem novas
      coletas (0 chamadas externas): consome apenas os globais de M1–M4
- [x] Cenário A — memória/swap-death (`diagnosis:memory:*`): variações
      `MEMORY_PRESSURE`/`SWAP_PRESSURE`/`SWAP_DEATH_LIKELY` (esta só com memória
      crítica + degradação)
- [x] Cenário B — throttling (`diagnosis:provider:*`): `HYPERVISOR_STEAL`/
      `CGROUP_CPU_THROTTLING`/`PROVIDER_THROTTLING_SUSPECTED`; exige limitação de
      host/VM, não confunde quota de container; I/O wait alto é contraindício
- [x] Cenário C — worker Laravel (`diagnosis:laravel:<rid>:*`):
      `LARAVEL_WORKER_MISCONFIGURATION`/`HORIZON_EXCESSIVE_WORKERS`/
      `SCHEDULE_RUN_STUCK`/`LONG_RUNNING_JOB_SUSPECTED`/`WORKER_RESOURCE_LEAK_SUSPECTED`;
      **não depende do Docker**
- [x] Cenário D — Docker vítima (`diagnosis:docker:*`): `DOCKER_DEGRADED_BY_HOST`/
      `CONTAINERD_HEALTHY_DOCKER_SLOW`/`DOCKERD_UNRESPONSIVE`/`DOCKER_STACK_UNAVAILABLE`;
      só vira "vítima do host" com host saturado (host saudável ⇒ não é vítima)
- [x] Modelo completo por diagnóstico: score, confiança (LOW/MEDIUM/HIGH/VERY_HIGH),
      severidade, status, evidence/counter_evidence, probable_cause, impact,
      recommendations, related_alert_keys/related_diagnosis_keys, affected_resources,
      first/last_detected_at, fingerprint
- [x] Papéis causais (ROOT_CAUSE/AMPLIFIER/IMPACT/CONTRIBUTING_FACTOR) e seleção
      do principal por confiança → especificidade → severidade → score
- [x] Integração M5: diagnósticos elegíveis (confirmação por confiança —
      VERY_HIGH imediato, HIGH 2, MEDIUM 3, LOW só relatório) viram incidentes
      `diagnosis:*` na máquina de estados existente (open/escalate/recover/cooldown);
      alertas brutos individuais preservados; Discord reutilizado (sem novo curl)
- [x] Dedup por fingerprint (cenário+recurso+faixa de confiança+severidade+papel+
      evidências sem números); variação numérica pequena não muda o fingerprint
- [x] Saídas humana (`─── Diagnósticos ───` com gatilho/amplificador/impacto),
      JSON (`diagnostics_summary` + `diagnostics[]`) e KV (`diagnostics.*`)
- [x] Dry-run 100% não-destrutivo: calcula e simula, não grava `diagnoses.state`
      nem `incidents.state`, não chama webhook (hashes idênticos comprovados)

**Pesos das evidências:** documentados no cabeçalho de cada `eval_*`
(ex. memória: mem crítica +25, swap crítica +20, swap crescente +15, iowait +10,
load +10, docker degradado +10, container sem limite +10, worker causador +15).

**Testes:** `monitor/tests/test-monitor-correlation.sh` — 15 grupos, 72 asserts,
com fixture do incidente original (`fixtures/correlation/incident.env`) e cobertura
dos 50 cenários exigidos (confiança, contraindícios, dados parciais, determinismo,
fingerprint, integração M5, dry-run, ausência de segredos, recomendações).

**Critérios de aceite:** fixture do incidente produz LARAVEL_WORKER_MISCONFIGURATION
ROOT_CAUSE VERY_HIGH, SWAP_DEATH_LIKELY AMPLIFIER, DOCKER_DEGRADED_BY_HOST IMPACT,
throttling CONTRIBUTING_FACTOR. ✔ Validado. As cinco suítes passam (82 grupos, 482 asserts).

---

## M7 — Persistência e histórico ✅ CONCLUÍDO (2026-07-18)

**Objetivo:** diagnóstico retroativo.

**Entregáveis:**
- [x] `lib/monitor-history.sh` — camada SEPARADA de `incidents.state`/`diagnoses.state`;
      escrita append com `flock`, uma linha completa, permissões 0640/0750, tolerante
      a FS somente leitura / disco cheio (falha nunca derruba o monitor, conta erros)
- [x] Métricas do host em `metrics/metrics-YYYY-MM-DD.jsonl` (schema completo da spec:
      load, cpu user/system/idle/iowait/steal, cgroup, memória/swap/disco em bytes,
      docker, containers, workers, alertas, diagnósticos); campo ausente => `null`
- [x] Detalhes de containers/workers só quando relevantes (problema, unhealthy,
      restarting, sem limite, top consumidor); identidade estável (id/UUID, não PID)
- [x] Eventos só em **transições reais** (`events/`, `diagnostics/`):
      ALERT_OPENED/ESCALATED/RECOVERED, DIAGNOSIS_DETECTED/ESCALATED/RESOLVED,
      DOCKER_STATE_CHANGED, WORKER_RISK_CHANGED, HISTORY_WRITE_FAILED
- [x] Baseline atômico (`indexes/latest-baseline.kv`) com deltas/tendências: swap
      delta + `monitor_history_trend` (RISING/STABLE/FALLING/UNKNOWN) e rate por
      minuto (clock retrocedendo => 0); corrompido é recuperado
- [x] Intervalos configuráveis (métricas 60s, containers 300s) por timestamp, sem `sleep`
- [x] Retenção segura (só arquivos reconhecidos, `-maxdepth 1`, sem seguir symlink,
      com timeout, caminho `/`/vazio rejeitado) + compressão gzip **opcional**;
      manutenção no máximo 1×/dia
- [x] `vps-monitor.sh report` — `--last 1h|24h|7d`, `--from/--to`, `--incident`,
      `--diagnosis`, `--format human|json|csv`; lê `.jsonl` e `.jsonl.gz`; estatísticas
      min/máx/média, timeline, ignora linha inválida e informa; sem `jq` obrigatório
- [x] Bloco `history` no JSON e chaves `history.*` no KV; aviso humano só em erro
- [x] Dry-run não grava histórico/baseline/retenção; `--no-history` desativa;
      **`--no-alerts` continua gravando histórico**; report não altera nenhum estado
- [x] Instalador cria diretórios de histórico e os **preserva** em atualização;
      desinstalador preserva o histórico por padrão

**Testes:** `monitor/tests/test-monitor-history.sh` — 15 grupos, 61 asserts, com
diretórios temporários (nunca `/var/lib`): escrita/JSON válido, null, sem secrets,
permissões, intervalos, swap delta/tendência, eventos por transição, dry-run/
--no-history, FS somente leitura, baseline corrompido, retenção segura, report
humano/JSON/CSV/gz/filtros, determinismo.

**Critérios de aceite:** validado no host real (check grava, `--no-alerts` grava,
`--no-history`/dry-run não gravam, report não altera estado, 0 chamadas externas
no report). ✔ Validado. As seis suítes passam (97 grupos, 543 asserts).

---

## M8 — Modo de emergência ✅ CONCLUÍDO (2026-07-18)

**Objetivo:** coletar evidências mesmo com o host agonizando.

**Entregáveis:**
- [x] `lib/monitor-emergency.sh` — coleta com prioridades **P0 (host, sem Docker)
      → P1 (runtime, com timeout) → P2 (logs/rede/histórico, se sobrar tempo)**,
      **deadline global** (`--deadline`, padrão 45s) verificado entre etapas;
      todo subprocesso com timeout; termina mesmo com comandos travados
- [x] Pacote autocontido em `incidents/YYYY-MM-DD_HH-MM-SS_<host>/` com
      `manifest.json`, `summary.txt`/`summary.json`, `errors.jsonl`,
      `checksums.sha256` e subdiretórios `host/`, `runtime/`, `laravel/`, `logs/`,
      `network/`, `history/` (estrutura completa da spec)
- [x] Coleta: identidade, uptime, loadavg, meminfo, /proc/stat, PSI, swapon, df,
      inodes, mounts, vmstat, cgroup, limites, **um único snapshot ps** derivado em
      cpu/memory/state (D e Z), docker info/ps/stats + ctr + daemons via /proc
- [x] Reuso de **M6** (diagnóstico no summary) e **M7** (histórico recente no pacote,
      report read-only, sem alterar estado)
- [x] **Sanitização obrigatória** de todo conteúdo (stdout/stderr/comandos/logs/
      manifest/summary): WEBHOOK_URL, Bearer/Authorization, token/secret/password/
      apikey, URL com credencial, VAR_TOKEN/SECRET/PASSWORD, cookies, chaves privadas
      → `[REDACTED]`
- [x] Limites de tamanho por arquivo **e agregado** (`MAX_TOTAL_BYTES`, medido em
      disco a cada escrita): reserva para essenciais, descarte P2→P1 preservando P0,
      truncamento/skip marcados em `errors.jsonl` (`TRUNCATED_TOTAL_LIMIT`/
      `SKIPPED_TOTAL_LIMIT`) e bloco `size_limits` no manifesto; valor inválido =>
      padrão, abaixo do piso => elevado a 128 KB. Checksums determinísticos
      (ordenados, sem incluir a si mesmos); `--archive` opcional (tar.gz + sha256,
      diretório preservado; não cria se faltar espaço livre; ausência de tar/gzip não falha)
- [x] Lock próprio (PID+timestamp, órfão tratado); goroutine dump **só com flag**
      `--dockerd-goroutine-dump`, **apenas SIGUSR1**, nunca TERM/KILL
- [x] Discord reutilizado só com `--notify` (resumo curto, nunca anexa o pacote);
      falha de Discord não invalida o pacote
- [x] Saídas humana (progresso 1/8..8/8), JSON (`--format json`) e KV (`--format kv`);
      **exit codes**: 0 completo · 1 parcial utilizável · 2 falha mínima · 3 args
      inválidos · 4 já em execução
- [x] **Nenhuma ação destrutiva** (sem restart/stop/kill/reboot); estados M5/M6 e
      histórico M7 não são alterados (comprovado por hash)

**Testes:** `monitor/tests/test-monitor-emergency.sh` — 16 grupos, 67 asserts, com
binários simulados e fixtures (ps com D/Z/worker/secret, journal com OOM), sem
Docker/Coolify/webhook/sinais reais: sanitização, validação de output-dir/deadline,
pacote completo/parcial, Docker travado com timeout, sem Docker, deadline, archive,
lock, goroutine dump (só USR1), notify, intocabilidade de M5/M6/M7, JSON/KV/exit codes.

**Critérios de aceite:** validado no host real (pacote gerado sem Docker, checksums
verificam, nenhum secret real, archive+sha256, < 60s). ✔ Validado. As sete suítes
passam (113 grupos, 610 asserts).

---

## M9 — Integração ao ciclo de vida existente do VPS Guardian ✅ CONCLUÍDO (2026-07-18)

> **Correção de escopo:** o VPS Guardian já possui instalação funcional,
> `instalar.sh`, fluxo de atualização, fluxo de desinstalação, estrutura de
> diretórios, configurações em produção, bibliotecas compartilhadas e integrações
> com Discord e com a API do Coolify. O M9 não deve criar um instalador,
> atualizador ou produto paralelo.

**Objetivo:** integrar completamente o monitor preventivo entregue em M0–M8 ao
ciclo de instalação, atualização, rollback, desinstalação e operação já existente
do VPS Guardian.

O trabalho deste marco segue obrigatoriamente esta sequência:

```text
auditoria
→ integração
→ compatibilidade
→ documentação
→ validação
→ preparação da release
```

Não faz parte do M9 reconstruir a infraestrutura de instalação do projeto.

### M9.1 — Auditoria obrigatória antes de modificar os fluxos

Antes de alterar instalação, atualização, rollback ou desinstalação, ler
integralmente e tratar como fontes de verdade:

- `instalar.sh`, inclusive os modos de atualização e desinstalação nele embutidos;
- qualquer atualizador ou helper chamado pelo fluxo existente;
- o desinstalador existente;
- a estrutura instalada atual e o arquivo `.install.conf`;
- os arquivos de configuração usados em produção;
- as bibliotecas compartilhadas;
- os serviços, timers e agendamentos existentes;
- `README.md`, `docs/COMANDOS.md` e a documentação operacional relacionada.

A auditoria deve registrar, antes da implementação:

- diretório real de instalação e como ele é descoberto;
- diretório real de configuração;
- diretório real de dados mutáveis;
- como atualizações são detectadas e aplicadas;
- como backups pré-atualização são feitos;
- como rollback funciona;
- como arquivos novos entram em instalações antigas;
- como configurações existentes são preservadas;
- como serviços systemd são registrados;
- como o desinstalador preserva ou remove dados;
- quais convenções de versão o projeto utiliza.

Não assumir `/opt/vpsguardian`, `/etc/vpsguardian`,
`/var/lib/vpsguardian` ou qualquer outro caminho sem confirmar o valor pelo fluxo
real de instalação. Caminhos padrão podem existir, mas a integração deve respeitar
os valores configurados e instalações legadas.

Se a auditoria não encontrar um mecanismo mencionado neste marco — por exemplo,
backup pré-atualização ou rollback — a lacuna deve ser registrada. A correção deve
ser incorporada ao fluxo existente, sem criar um segundo atualizador.

### M9.2 — Integração ao instalador existente

Modificar o instalador atual somente no necessário para incluir:

- `monitor/vps-monitor.sh`;
- bibliotecas `lib/monitor-*.sh`;
- configuração de exemplo do monitor;
- service e timer systemd, caso a auditoria confirme o timer próprio;
- diretórios mutáveis de estado, histórico e incidentes;
- proprietários, grupos e permissões necessários;
- validação de sintaxe e smoke test do monitor.

Preservar toda a lógica do instalador que não pertence ao monitor. A instalação
do monitor deve ser:

- idempotente;
- compatível com instalações antigas;
- segura durante reinstalação;
- não interativa quando o instalador estiver em modo automatizado;
- incapaz de sobrescrever credenciais ou configurações existentes.

Não criar um segundo instalador nem documentar o monitor como instalação separada,
salvo se a auditoria confirmar que o VPS Guardian já suporta módulos instaláveis.

### M9.3 — Integração ao atualizador existente

Integrar o monitor ao mecanismo atual de atualização. Se o modo `update` estiver
embutido em `instalar.sh`, ele continua sendo o ponto de entrada; não criar outro
script de update para o monitor.

A atualização deve reconhecer o monitor como parte normal do projeto e:

1. atualizar scripts e bibliotecas imutáveis;
2. preservar a configuração ativa;
3. preservar `incidents.state`;
4. preservar `diagnoses.state`;
5. preservar o histórico;
6. preservar pacotes de emergência;
7. instalar unidades systemd novas quando ausentes;
8. atualizar unidades existentes quando necessário;
9. executar `systemctl daemon-reload` quando houver unidades;
10. validar a sintaxe dos arquivos atualizados;
11. executar smoke test não destrutivo;
12. utilizar o mecanismo de rollback existente.

A atualização não pode:

- zerar estado;
- apagar histórico ou incidentes;
- alterar o webhook compartilhado;
- alterar URL ou token da API do Coolify;
- reiniciar Docker;
- reiniciar containers;
- reiniciar a VPS;
- criar um segundo mecanismo de atualização.

### M9.4 — Rollback

Primeiro verificar como o atualizador atual realiza backup e rollback. Reutilizar
esse mecanismo e apenas complementá-lo para que também restaure:

- scripts do monitor;
- bibliotecas do monitor;
- versões anteriores das unidades systemd;
- arquivo anterior de exemplo de configuração;
- versão anterior do código.

O rollback automático não deve reverter dados mutáveis:

```text
configuração do usuário
estado
histórico
incidentes
pacotes de emergência
```

### M9.5 — Integração ao desinstalador existente

Estender o fluxo atual de desinstalação, sem criar uma interface incompatível. Ao
remover todo o VPS Guardian ou somente o monitor, quando a arquitetura existente
permitir remoção modular, o fluxo deve:

- parar e desabilitar o timer do monitor;
- remover as unidades systemd do monitor;
- remover os scripts e bibliotecas instalados do monitor;
- executar `systemctl daemon-reload`;
- preservar configuração, estado, histórico, incidentes e pacotes de emergência
  por padrão.

Se o desinstalador já possuir opções de purge, estender seus nomes e seu padrão.
As categorias conceituais a cobrir são:

```text
purge de configuração
purge de estado
purge de histórico
purge de incidentes
purge completo
```

Os nomes finais das opções devem seguir a interface real encontrada na auditoria.

### M9.6 — Estrutura instalada e ciclo de vida dos arquivos

Não definir estrutura arbitrária. Depois da auditoria, a documentação deve conter
uma tabela preenchida com os destinos reais:

| Origem no repositório | Destino real instalado | Proprietário | Grupo | Permissão | Atualizado por | Removido por | Política de preservação |
|---|---|---|---|---:|---|---|---|
| `monitor/vps-monitor.sh` | `$INSTALL_ROOT/monitor/vps-monitor.sh` | usuário instalador (normalmente `root`) | grupo instalador (normalmente `root`) | `0755` em cópia | modos install/reinstall/update de `instalar.sh` | modo uninstall de `instalar.sh` | imutável |
| `lib/monitor-*.sh` | `$INSTALL_ROOT/lib/monitor-*.sh` | usuário instalador | grupo instalador | `0644` em cópia | modos install/reinstall/update de `instalar.sh` | modo uninstall de `instalar.sh` | imutável |
| `config/monitor.conf.example` | `$INSTALL_ROOT/config/monitor.conf.example` | usuário instalador | grupo instalador | `0640` em cópia | modos install/reinstall/update de `instalar.sh` | modo uninstall de `instalar.sh` | imutável |
| configuração ativa | `$INSTALL_ROOT/config/monitor.conf` | `root` em produção | `root` em produção | `0640` | administrador | somente purge explícito | preservada |
| estado M5/M6 | `$MONITOR_STATE_ROOT/{incidents,diagnoses}.state` | `root` em produção | `root` em produção | diretório `0750` | monitor | `--purge-state`/`--purge-all` | preservado |
| histórico M7 | `$MONITOR_STATE_ROOT/history/` | `root` em produção | `root` em produção | `0750` | monitor | `--purge-history`/`--purge-all` | preservado |
| incidentes M8 | `$MONITOR_STATE_ROOT/incidents/` | `root` em produção | `root` em produção | `0750` | monitor | `--purge-incidents`/`--purge-all` | preservados |
| units systemd | `/etc/systemd/system/vpsguardian-monitor.{service,timer}` | `root` | `root` | `0644` | modos install/reinstall/update de `instalar.sh` | modo uninstall de `instalar.sh` | imutáveis |

`INSTALL_ROOT` e `MONITOR_STATE_ROOT` são lidos de `.install.conf`; os modos
symlink mantêm proprietário e permissão do destino no checkout.

### M9.7 — Configuração e credenciais compartilhadas

Descobrir como o VPS Guardian carrega configurações e seguir o padrão existente.
São aceitáveis somente estas alternativas:

- **Opção A — configuração integrada:** adicionar as chaves `MONITOR_*` ao arquivo
  de configuração já utilizado pelo VPS Guardian;
- **Opção B — arquivo dedicado:** manter `monitor.conf` somente se o projeto já
  utilizar arquivos modulares ou se isso estiver previsto na arquitetura atual.

A decisão deve ser consequência da auditoria, não uma preferência isolada do
monitor. Em qualquer opção, nunca duplicar:

- `WEBHOOK_URL` ou o cliente Discord;
- URL ou token da API do Coolify;
- credenciais de e-mail;
- qualquer configuração já compartilhada.

O arquivo de exemplo pode apresentar referências às chaves compartilhadas, mas não
deve incentivar uma segunda fonte ativa para os mesmos segredos.

### M9.8 — Integração com o scheduler real

Antes de instalar unidades novas, verificar:

- se já existe timer principal do VPS Guardian;
- se há um serviço recorrente geral apropriado;
- se o monitor deve manter timer próprio;
- se o instalador possui helpers para registrar unidades;
- qual é o padrão real de nomes das unidades.

Se já houver scheduler apropriado, avaliar a integração nele. Se a auditoria
confirmar a decisão do M5 de manter `vpsguardian-monitor.service` e
`vpsguardian-monitor.timer`, o M9 deve apenas integrá-los ao ciclo existente,
validar caminhos e permissões e garantir instalação, atualização e remoção
idempotentes.

### M9.9 — `config-check` e `self-check`

Os comandos continuam obrigatórios, mas devem validar a instalação real.

`config-check` deve conhecer:

- arquivo real de configuração e ordem de herança;
- chaves compartilhadas;
- variáveis antigas;
- novas chaves ausentes;
- configurações depreciadas;
- conflitos entre duas configurações ativas.

`self-check` deve conhecer:

- caminho real instalado;
- timer ou scheduler real;
- última execução;
- diretórios reais e suas permissões;
- integrações reais do projeto;
- versão geral do VPS Guardian;
- versão e schema do monitor.

Ambos devem ser seguros para execução em produção e não alterar estado operacional.

### M9.10 — Testes de instalação, atualização e empacotamento

A suíte M9 deve exercitar o instalador, o atualizador, o rollback e o desinstalador
existentes, não versões simuladas inventadas apenas para o monitor. Deve cobrir:

1. instalação nova do VPS Guardian com o monitor;
2. instalação existente sem monitor sendo atualizada;
3. instalação existente com configuração antiga;
4. reinstalação idempotente;
5. atualização preservando o webhook;
6. atualização preservando a configuração da API do Coolify;
7. atualização preservando estado M5;
8. atualização preservando estado M6;
9. atualização preservando histórico M7;
10. atualização preservando incidentes M8;
11. rollback pelo mecanismo existente;
12. timer ou entrada no scheduler instalado apenas uma vez;
13. desinstalação preservando dados;
14. purge utilizando o padrão real do projeto;
15. ausência de segundo instalador;
16. ausência de segundo atualizador;
17. ausência de arquivos duplicados em caminhos paralelos;
18. ausência de configuração concorrente.

Quando o instalador permitir uma raiz simulada, os testes devem utilizá-la. Caso
isso ainda não exista, o suporte deve ser incorporado de forma compatível ao fluxo
atual. Testes automatizados nunca podem tocar em `/etc`, `/usr`, `/opt` ou
`/var/lib` reais.

### M9.11 — Auditoria de duplicação

Adicionar validação automatizada que falhe ao encontrar:

- duas cópias ativas de `vps-monitor.sh`;
- duas versões instaladas das bibliotecas do monitor;
- duas unidades systemd ou entradas de scheduler equivalentes;
- dois arquivos de configuração ativos para o monitor;
- duas definições de webhook;
- duas definições de token do Coolify;
- dois mecanismos de atualização;
- caminhos antigos abandonados.

### M9.12 — Documentação operacional

Criar `docs/GUIA-MONITOR-PREVENTIVO.md` e atualizar `README.md` e
`docs/COMANDOS.md` para ensinar o fluxo real:

```text
instalar o VPS Guardian
atualizar o VPS Guardian
verificar se o monitor está ativo
configurar thresholds
testar o Discord existente
gerar relatório
gerar pacote de emergência
desabilitar somente o monitor
desinstalar ou fazer purge
```

Incluir simulação documentada dos cenários de diagnóstico A–D, exemplo sanitizado
de relatório de incidente, limitações conhecidas e procedimentos de rollback. Não
apresentar o monitor como produto separado, salvo se o repositório já suportar
instalação modular.

### M9.13 — Preparação da release

Respeitar a estratégia de versão já existente. Não alterar automaticamente a
versão global do VPS Guardian para `v1.0.0` apenas por causa do monitor.

A auditoria deve decidir e documentar uma das alternativas compatíveis:

- incrementar a versão global do VPS Guardian conforme a convenção existente; ou
- manter a versão global e registrar separadamente `MONITOR_VERSION=1.0.0`.

A release deve conter changelog, matriz de compatibilidade com instalações antigas,
resultado da suíte M9 e plano de rollback.

### Critérios de aceite corrigidos do M9

O M9 foi concluído com os seguintes resultados:

- [x] O monitor está integrado ao instalador existente.
- [x] O monitor está integrado ao atualizador existente.
- [x] O rollback existente cobre o monitor, e a lacuna encontrada foi
      corrigida dentro do mesmo fluxo.
- [x] O desinstalador existente cobre o monitor.
- [x] Nenhum instalador paralelo existe.
- [x] Nenhum atualizador paralelo existe.
- [x] Nenhuma configuração de Discord foi duplicada.
- [x] Nenhuma configuração da API do Coolify foi duplicada.
- [x] Uma instalação antiga pode ser atualizada.
- [x] Configuração e dados mutáveis são preservados.
- [x] Instalação, reinstalação e atualização são idempotentes.
- [x] O timer segue a arquitetura atual e usa o wrapper que descobre `INSTALL_ROOT`.
- [x] `config-check` valida a configuração real.
- [x] `self-check` valida a instalação real.
- [x] A documentação reflete caminhos e comandos reais.
- [x] Os testes simulam o fluxo atual sem tocar no host real.
- [x] A release preserva a versão global e registra `MONITOR_VERSION=1.0.0`.
- [x] Todos os marcos M0–M9 e os 20 critérios da seção 15 estão concluídos.

**Validação M9:** `monitor/tests/test-monitor-packaging.sh` — 13 grupos,
62 asserts. Todas as oito suítes `monitor/tests/test-monitor*.sh` passam.

---

## Pós-v1 (backlog, fora do escopo inicial)

- Ações automáticas opt-in: reiniciar/pausar container, parar worker, dump de goroutines
  do dockerd (sempre `automatic_actions.enabled=true` explícito; **nunca** reboot automático)
- Consulta ao Horizon via API/artisan com timeout
- Links diretos para a aplicação no Coolify nos alertas (base já existe na lib)
- Correlação incidente ↔ deploy recente via API do Coolify
- Exportação Prometheus/Netdata
- Verificação preventiva: soma dos limites de memória dos containers vs RAM física
  (regra: total ≤ RAM − 2,5 GB de reserva do host)

---

## Rastreabilidade — critérios de aceitação da spec (seção 15)

| # | Critério | Marco |
|---|---|---|
| 1 | Executa no host, independe do Docker | M0/M2 |
| 2 | Coleta CPU, RAM, swap, load, steal, I/O | M1 |
| 3 | Containers com maior consumo | M3 |
| 4 | Containers sem limites | M3 |
| 5 | Reinicializações repetidas | M3 |
| 6 | `docker ps` excede timeout | M2 |
| 7 | containerd como alternativa | M2 |
| 8 | Workers Laravel descontrolados | M4 |
| 9 | Correlação e diagnóstico provável | M6 |
| 10 | Alertas por pelo menos um canal | M5 |
| 11 | Alerta de recuperação | M5 |
| 12 | Sem restart por padrão | M0 (regra) |
| 13 | Pacote de diagnóstico de emergência | M8 |
| 14 | Persistência local de métricas | M7 |
| 15 | README com instalação e exemplos | M9 |
| 16 | Config de exemplo | M0 |
| 17 | Unit/timer systemd | M5 |
| 18 | Funciona com Docker indisponível | M2/M8 |
| 19 | Timeout em todos os comandos externos | M0 (regra) |
| 20 | Nunca expor tokens nos logs | M0 (regra) |
