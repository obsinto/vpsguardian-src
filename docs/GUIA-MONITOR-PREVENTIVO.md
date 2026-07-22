# Monitor Preventivo integrado ao VPS Guardian

O monitor preventivo faz parte do VPS Guardian. Ele não possui instalador,
atualizador, webhook ou configuração da API do Coolify próprios.

## Caminhos reais

O `instalar.sh` grava a instalação escolhida em `$INSTALL_ROOT/.install.conf` e
registra o mesmo metadado em `/etc/vpsguardian/install.conf`. Consulte sem assumir
que a instalação está em `/opt/vpsguardian`:

```bash
sudo cat /etc/vpsguardian/install.conf
source /etc/vpsguardian/install.conf
vps-guardian --version
```

Os padrões de uma instalação feita a partir de uma pasta chamada `vpsguardian`
são `/opt/vpsguardian`, `/var/backups/vpsguardian` e `/var/log/vpsguardian`.
O nome da pasta de origem e as escolhas do instalador podem alterar esses valores.

| Origem no repositório | Destino instalado | Proprietário/grupo | Permissão | Atualiza | Remove | Preservação |
|---|---|---|---:|---|---|---|
| `monitor/vps-monitor.sh` | `$INSTALL_ROOT/monitor/vps-monitor.sh` | usuário da instalação; normalmente `root:root` | `0755` em modo cópia; destino mantém modo do repositório em symlink | `instalar.sh` (`install`, `reinstall`, `update`) | `instalar.sh` (`uninstall`) | imutável |
| `lib/monitor-*.sh` | `$INSTALL_ROOT/lib/monitor-*.sh` | usuário da instalação; normalmente `root:root` | `0644` em modo cópia | `instalar.sh` | `instalar.sh` | imutável |
| `config/monitor.conf.example` | `$INSTALL_ROOT/config/monitor.conf.example` | usuário da instalação; normalmente `root:root` | `0640` em modo cópia | `instalar.sh` | `instalar.sh` | imutável |
| `config/monitor.conf` | `$INSTALL_ROOT/config/monitor.conf` | `root:root` em instalação normal | `0640` | administrador | somente purge explícito | preservada |
| `incidents.state` e `diagnoses.state` | `$MONITOR_STATE_ROOT/` | `root:root` em instalação normal | diretório `0750` | monitor | somente purge explícito | preservados |
| Histórico M7 | `$MONITOR_STATE_ROOT/history/` | `root:root` em instalação normal | `0750` | monitor | `--purge-history`/`--purge-all` | preservado |
| Pacotes M8 | `$MONITOR_STATE_ROOT/incidents/` | `root:root` em instalação normal | `0750` | monitor | `--purge-incidents`/`--purge-all` | preservados |
| Units | `/etc/systemd/system/vpsguardian-monitor.{service,timer}` | `root:root` | `0644` | `instalar.sh` | `instalar.sh` | imutáveis |

`MONITOR_STATE_ROOT` é registrado em `.install.conf`; o padrão atual é
`/var/lib/vpsguardian/monitor`.

## Instalar ou atualizar

Use sempre o instalador principal:

```bash
cd /caminho/do/repositorio
sudo ./instalar.sh
```

Em instalação existente, selecione **Atualizar**. Em automação:

```bash
sudo ./instalar.sh --mode update --non-interactive
```

O update atualiza código e units, executa `daemon-reload`, valida sintaxe,
`config-check`, `self-check` e um smoke test. Antes de modificar os artefatos
imutáveis gerenciados pelo instalador, cria um snapshot temporário para rollback.
Em falha, restaura scripts, bibliotecas, documentação, units, wrappers e exemplos
anteriores sem reverter configuração, estado, histórico ou incidentes.

O comando `vps-guardian updates` tem outra função: configura atualizações de
segurança do sistema operacional. Ele não atualiza o código do VPS Guardian.

## Verificar se está ativo

```bash
sudo vps-guardian monitor config-check
sudo vps-guardian monitor self-check
systemctl status vpsguardian-monitor.timer
systemctl list-timers vpsguardian-monitor.timer
journalctl -u vpsguardian-monitor.service --since "30 minutes ago"
sudo vps-guardian monitor status
```

`config-check` valida sintaxe, herança, tipos, variáveis antigas, chaves
compartilhadas indevidamente e configurações concorrentes. `self-check` valida o
caminho instalado, bibliotecas, units, timer, diretórios mutáveis, última execução
e versões do VPS Guardian/monitor.

## Configurar thresholds

Crie o arquivo ativo a partir do exemplo instalado:

```bash
sudo cp "$INSTALL_ROOT/config/monitor.conf.example" "$INSTALL_ROOT/config/monitor.conf"
sudo chmod 0640 "$INSTALL_ROOT/config/monitor.conf"
sudo editor "$INSTALL_ROOT/config/monitor.conf"
sudo vps-guardian monitor config-check
```

Use somente chaves `MONITOR_*` nesse arquivo. O webhook Discord, URL/token do
Coolify e e-mail continuam em `$INSTALL_ROOT/config/backup-destinations.conf`.
Nunca os copie para `monitor.conf`.

## Testar o Discord existente

```bash
sudo vps-guardian monitor test-alert --dry-run
sudo vps-guardian monitor test-alert
```

O primeiro comando não chama o webhook. O segundo usa o mesmo `WEBHOOK_URL` das
rotinas existentes de backup e manutenção.

Em operação normal, cada incidente mantém estado e cooldown próprios, mas todas
as transições de uma coleta são enviadas em uma única mensagem resumida. Por
padrão uma condição WARNING/CRITICAL precisa aparecer em duas coletas consecutivas
antes de abrir; EMERGENCY continua imediato. Uma métrica observada precisa
permanecer saudável por três coletas antes de normalizar. Load e CPU steal também
usam histerese: abrem respectivamente em ratio 1,5 e 10%, mas só iniciam a
recuperação abaixo de 1,2 e 8%. Ajuste `MONITOR_ALERT_CONSECUTIVE`,
`MONITOR_ALERT_RECOVERY_CONSECUTIVE`, os limites `*_RECOVERY` e
`MONITOR_ALERT_BATCH_MAX_ITEMS` somente se necessário.

## Executar e gerar relatórios

```bash
sudo vps-guardian monitor check
sudo vps-guardian monitor containers
sudo vps-guardian monitor report --last 24h
sudo vps-guardian monitor report --last 7d --format json
sudo vps-guardian monitor report --from "2026-07-17 10:00" --to "2026-07-17 12:00" --format csv
```

Se o timer já estiver coletando, o menu mostra o último snapshot concluído em
vez de iniciar uma segunda coleta. Na linha de comando, o código `10` continua
reservado para uma tentativa concorrente.

### Painel visual no terminal

No menu **Status e Diagnóstico**, a opção **Painel Visual em Tempo Real** abre o
`btop`, com gráficos de CPU, RAM, swap, disco, rede e processos. Se o pacote não
estiver disponível, o menu oferece a instalação pelo gerenciador da distribuição
e só prossegue após confirmação explícita. Dentro do painel, use `q` para voltar
ao VPS Guardian e `?` para consultar os atalhos.

## Gerar pacote de emergência

```bash
sudo vps-guardian monitor emergency
sudo vps-guardian monitor emergency --archive
sudo vps-guardian monitor emergency --archive --notify
```

`--notify` envia somente um resumo sanitizado pelo Discord; o pacote permanece
local em `$MONITOR_STATE_ROOT/incidents/`.

Exemplo sanitizado de resumo:

```text
incidente: 2026-07-18_14-30-00_vps-producao
severidade: EMERGENCY
diagnóstico: LARAVEL_WORKER_MISCONFIGURATION
evidências: workers=8, timeout=36000, container_memory_limit=ausente
token: [REDACTED]
webhook: [REDACTED]
```

## Simular diagnósticos sem afetar produção

As fixtures do repositório reproduzem os cenários sem usar Docker, Discord ou
arquivos reais do host:

```bash
monitor/tests/test-monitor-correlation.sh
monitor/tests/test-monitor-alerts.sh
monitor/tests/test-monitor-emergency.sh
```

Cobertura dos cenários:

- A: pressão de memória, swap crescente e provável swap-death;
- B: CPU steal e throttling por cgroup/provedor;
- C: workers Laravel/Horizon excessivos ou mal configurados;
- D: Docker degradado como consequência da saturação do host.

Para observar somente as transições que ocorreriam no host atual:

```bash
sudo vps-guardian monitor check --dry-run --no-history
```

## Desabilitar ou remover somente o monitor

Desabilitar o agendamento sem remover arquivos:

```bash
sudo systemctl disable --now vpsguardian-monitor.timer
```

Reativar:

```bash
sudo systemctl enable --now vpsguardian-monitor.timer
```

Remover apenas o monitor pelo fluxo existente, preservando seus dados:

```bash
sudo ./instalar.sh --mode uninstall --monitor-only
```

Purges explícitos disponíveis:

```bash
sudo ./instalar.sh --mode uninstall --monitor-only --purge-config
sudo ./instalar.sh --mode uninstall --monitor-only --purge-state
sudo ./instalar.sh --mode uninstall --monitor-only --purge-history
sudo ./instalar.sh --mode uninstall --monitor-only --purge-incidents
sudo ./instalar.sh --mode uninstall --monitor-only --purge-all
```

`--purge-all` limita-se à configuração e aos dados próprios do monitor; não apaga
`WEBHOOK_URL`, token do Coolify, backups ou logs gerais.

## Desinstalar o VPS Guardian

```bash
sudo ./instalar.sh --mode uninstall
```

O fluxo para/desabilita o timer, remove as units, executa `daemon-reload`, remove
scripts e comandos globais e preserva backups, logs, configurações ativas e dados
do monitor por padrão.

## Release e compatibilidade

O VPS Guardian continua expondo a versão global existente `1.0.0`. O monitor tem
versionamento próprio (`MONITOR_VERSION=1.0.0`) e schema `1`. O M9 é compatível
com instalações sem monitor, configurações antigas e instalações em modo cópia ou
symlink. Cópia é o modo recomendado; no primeiro update, uma instalação legada
em symlink é convertida em cópia para permitir atualizações transacionais futuras.

Limitações conhecidas:

- o rollback cobre todos os artefatos imutáveis gerenciados pelo instalador. Em uma
  instalação legada ainda ligada por symlink ao checkout que acabou de ser alterado,
  o conteúdo anterior já não está disponível para o primeiro snapshot; a conversão
  para cópia elimina essa limitação nos updates seguintes;
- `systemd` é necessário para o agendamento automático, mas o monitor pode ser
  executado manualmente sem ele;
- o enriquecimento Coolify requer API habilitada, token válido e `jq`; a coleta do
  host continua funcionando quando a API ou o Docker estão indisponíveis.
