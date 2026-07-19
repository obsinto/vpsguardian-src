# Release do Monitor Preventivo 1.0.0

Data: 2026-07-18

## Versionamento

Esta entrega preserva a versão global já exposta pelo VPS Guardian (`1.0.0`) e
registra o módulo como `MONITOR_VERSION=1.0.0`, schema `1`. Não foi criado um
produto independente.

## Changelog M0–M9

- coletores do host independentes do Docker;
- diagnóstico de Docker/containerd, containers e workers Laravel/Horizon;
- motor de alertas integrado ao Discord existente;
- correlação, histórico e pacote sanitizado de emergência;
- integração ao `instalar.sh` existente nos modos install/reinstall/update/uninstall;
- atualização transacional e rollback dos artefatos imutáveis gerenciados pelo instalador;
- instalação/atualização/remoção idempotente das units systemd;
- preservação de configuração, estados M5/M6, histórico M7 e incidentes M8;
- `config-check`, `self-check` e auditoria de duplicação;
- testes M9 totalmente isolados por `--system-root`.

## Matriz de compatibilidade

| Cenário | Resultado |
|---|---|
| Instalação nova, modo cópia | suportado |
| Instalação nova, modo symlink | suportado por compatibilidade; cópia é recomendada |
| Instalação antiga sem monitor | adiciona o módulo pelo update normal |
| Configuração antiga | preservada; variáveis depreciadas geram aviso |
| Caminho de instalação customizado | suportado via `.install.conf` e wrapper global |
| Docker indisponível | coleta do host e emergência continuam operacionais |
| API Coolify indisponível | fallback para labels/Docker sem interromper o host |
| systemd indisponível | execução manual suportada; agendamento não é ativado |

## Validação da release

`monitor/tests/test-monitor-packaging.sh` cobre 13 grupos e 65 asserts, incluindo
upgrade legado, credenciais compartilhadas, estados M5–M8, idempotência, rollback,
desinstalação e purge. Os testes usam somente uma árvore criada por `mktemp` e não
tocam nos caminhos reais do sistema.

A release também exige as suítes M0–M8 verdes:

```bash
for test in monitor/tests/test-monitor*.sh; do
    "$test"
done
```

## Plano de rollback

O modo `update` cria um snapshot temporário de todos os artefatos imutáveis
gerenciados pelo instalador. Isso inclui scripts de backup, migração, manutenção,
monitor, bibliotecas, documentação, wrappers, exemplos e units. Se validação,
instalação ou smoke test falhar, o mesmo `instalar.sh` restaura o snapshot e
executa `systemctl daemon-reload`.

Não são revertidos automaticamente:

- `config/monitor.conf`;
- `backup-destinations.conf` e suas credenciais compartilhadas;
- `incidents.state` e `diagnoses.state`;
- histórico;
- pacotes de emergência.

O checkout Git deve ser revertido pelo mecanismo usado para atualizar o próprio
repositório; o VPS Guardian não cria um segundo atualizador para isso.

Instalações legadas em symlink são convertidas em cópia no primeiro update. Se o
checkout já tiver sido alterado antes desse primeiro update, o conteúdo antigo não
estará mais disponível para o snapshot; os updates posteriores já são transacionais.
