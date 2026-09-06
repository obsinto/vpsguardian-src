# Plano de Testes E2E — Migração e Restauração

Status: interface de automação pronta; ensaio em infraestrutura real pendente

Última revisão: 2026-09-06

Escopo: VPS Guardian, Coolify, volumes de aplicações e dumps de bancos de dados

## Por que este nome

Este documento é um **plano de testes E2E (end-to-end)** com características de
**runbook**: define ambiente, dados de teste, execução, critérios de aprovação,
evidências e limpeza.

Não deve ser chamado de "marcos de execução". No projeto, marcos representam
etapas de desenvolvimento ou entregas. Aqui o objetivo é repetir e comprovar um
comportamento do sistema já implementado.

Nome canônico deste arquivo:

```text
docs/PLANO-TESTES-E2E-MIGRACAO-RESTAURACAO.md
```

Quando o runner E2E for implementado, este documento continuará sendo a
especificação. O executor deverá ficar em `tests/e2e/`.

## Objetivo

Comprovar, em infraestrutura real e descartável, dois fluxos:

1. **T01 — Migração completa:** migrar uma instalação do Coolify da VPS de
   origem para uma máquina local, incluindo o plano de controle do Coolify,
   configurações, chaves, proxy e dados persistentes das aplicações.
2. **T02 — Restauração de um banco:** baixar um lote de dumps armazenado na
   própria VPS ou em S3 compatível e restaurar somente um banco de aplicação na
   máquina local, sem modificar `coolify-db` nem outro banco.

O plano mede também:

- RTO: duração até o serviço ficar utilizável no destino;
- RPO observado: idade do dado efetivamente restaurado;
- integridade: dados, volumes, configurações e recursos esperados;
- isolamento: componentes não selecionados permanecem inalterados;
- rastreabilidade: cada afirmação de sucesso possui uma evidência arquivada.

Situação do código na data desta revisão:

| Cenário | Situação | Motivo |
|---|---|---|
| T01 | Pronto para o primeiro ensaio controlado | Entry point automático, guardas destrutivas e relatórios de máquina implementados; os oráculos reais ainda precisam ser executados |
| T02 | Pronto para o primeiro ensaio controlado | SSH e S3 aceitam lote/dump exatos, hash esperado, mapeamento de container e execução sem prompts |

## Definição de "completa"

Neste plano, "migração completa" significa:

- banco `coolify-db`;
- `.env`, `APP_KEY` e chaves SSH do Coolify;
- configuração do proxy selecionada para o ensaio;
- cadastro de aplicações, serviços e bancos;
- volumes Docker das aplicações;
- dumps de segurança dos bancos criados pela estratégia `double-check`;
- aplicações e bancos iniciados e validados após o redeploy necessário.

Copiar apenas o banco e as configurações do Coolify **não** satisfaz T01. O
próprio Coolify trata o backup da instância e os dados persistentes das
aplicações como responsabilidades separadas.

## Topologia recomendada

| Papel | Ambiente | Função |
|---|---|---|
| Origem | VPS Linux com Coolify e VPS Guardian | Gera backups e inicia T01 |
| Destino | VM Linux descartável na máquina local | Recebe T01 e executa T02 |
| Off-site | Bucket S3 compatível exclusivo para E2E | Origem alternativa de T02 |
| Rede | Tailscale + OpenSSH | Conecta VPS e VM sem expor o SSH local à internet |

Fluxos de rede:

```text
T01: VPS origem  -- SSH/SCP --> VM local destino
T02/ssh: VM local -- SSH/SCP --> VPS origem (download)
T02/s3: VM local -- HTTPS --> bucket S3 (download)
```

### Decisão de conectividade

Usar o IP Tailscale ou o nome MagicDNS da VM como `NEW_SERVER_IP`. O Tailscale
fornece a conectividade; um serviço SSH continua necessário no destino.

Para o primeiro ensaio, usar **OpenSSH convencional sobre a interface do
Tailscale**, com autenticação por chave. Isso é compatível com os usos atuais de
`ssh`, `scp`, `ssh-agent` e `ControlMaster` nos scripts. Não publicar a porta 22
da máquina local no roteador.

### Requisitos do destino

- VM nova, dedicada ao ensaio; não usar diretamente o desktop de trabalho;
- distribuição Linux suportada pelo Coolify, preferencialmente Ubuntu LTS;
- arquitetura de CPU suportada pelas imagens das aplicações;
- no mínimo 2 CPUs, 4 GiB de RAM e 40 GiB livres para o ensaio;
- espaço adicional maior que o total dos volumes e arquivos temporários;
- acesso SSH como `root` por chave a partir da VPS;
- portas 8000, 80 e 443 livres dentro da VM;
- snapshot ou outra forma simples de recriar a VM desde zero;
- Tailscale ativo nos dois lados e ACL limitada ao tráfego necessário.

## Princípios de segurança

Estes testes são destrutivos no destino e podem causar indisponibilidade
temporária na origem durante a captura consistente de volumes.

Regras obrigatórias:

1. Executar primeiro contra uma VPS de homologação ou clone restaurado da
   produção. Um ensaio em produção exige janela de manutenção própria.
2. O destino deve possuir o marcador `/etc/vpsguardian-e2e-destination`. Passar
   esse caminho a `migrar-completo.sh`, que aborta se ele não existir.
3. Comparar `/etc/machine-id` de origem e destino e abortar se forem iguais.
4. Exigir `ALLOW_DESTRUCTIVE_E2E=YES` para qualquer operação que substitua dados.
5. Proibir `--replace-existing` fora de uma VM marcada como descartável.
6. Não alterar DNS público durante o ensaio. Testar hostnames com
   `curl --resolve` ou com resolução local temporária.
7. Usar um bucket S3 exclusivo de teste e o prefixo configurável
   `e2e/vpsguardian/<RUN_ID>/` tanto no backup quanto no restore.
8. Nunca salvar tokens, senhas, `.env`, chaves privadas ou conteúdo de dumps nos
   artefatos do teste. Salvar somente fingerprints ou hashes quando necessário.
9. Não usar automaticamente o "backup mais recente". Registrar e selecionar o
   nome exato e o SHA-256 do artefato criado para o ensaio.
10. Não apagar backups ou snapshots até que todas as evidências tenham sido
    revisadas.

## Identificação de uma execução

Cada execução deve ter um identificador imutável:

```text
RUN_ID=YYYYMMDD-HHMMSS-<commit-curto>
```

Variáveis mínimas, mantidas fora do Git em arquivo com permissão `0600`:

| Variável | Exemplo não secreto | Observação |
|---|---|---|
| `RUN_ID` | `20260906-143000-a1b2c3d` | Identifica dados e evidências |
| `SOURCE_HOST` | `vps-origem` | IP Tailscale ou MagicDNS |
| `SOURCE_USER` | `root` | Origem |
| `SOURCE_PORT` | `22` | Origem |
| `DEST_HOST` | `vpsg-e2e-local` | IP Tailscale ou MagicDNS |
| `DEST_USER` | `root` | Destino |
| `DEST_PORT` | `22` | Destino |
| `DEST_KEY_ON_SOURCE` | `/root/.ssh/vpsguardian-e2e` | Chave usada pela VPS em T01 |
| `TEST_PROJECT` | `vpsguardian-e2e` | Projeto isolado no Coolify |
| `TEST_DB_SOURCE_CONTAINER` | `<nome-no-dump>` | Nome codificado no arquivo produzido na origem |
| `TEST_DB_CONTAINER` | `<nome-no-destino>` | Container local que receberá o dump |
| `TEST_DB_ENGINE` | `postgres` | `postgres`, `mysql` ou `mongodb` |
| `TEST_DB_NAME` | `vpsguardian_e2e` | Banco que pode ser sobrescrito |
| `RESTORE_SOURCE` | `ssh` | `ssh` ou `s3` |
| `S3_BUCKET` | `backup-e2e` | Bucket exclusivo ou credencial limitada ao ensaio |
| `S3_PREFIX` | `e2e/vpsguardian/<RUN_ID>` | Mesmo valor no produtor e no consumidor do lote |
| `ARTIFACT_DIR` | `/var/tmp/vpsguardian-e2e/<RUN_ID>` | Conteúdo sanitizado |

O arquivo real de ambiente não deve ser versionado. Quando o runner existir,
versionar somente `tests/e2e/e2e.env.example` com valores vazios.

## Fixture e oráculo dos dados

Não considerar "container está rodando" como prova de restauração. Cada banco
testado precisa de um dado cujo valor esperado seja conhecido.

Para homologação, criar uma tabela ou coleção dedicada, por exemplo
`vpsguardian_e2e_probe`, contendo:

| Campo | Valor |
|---|---|
| `run_id` | valor de `RUN_ID` |
| `phase` | `SOURCE_BEFORE_BACKUP` |
| `payload` | string determinística |
| `created_at` | data UTC |

O manifesto do ensaio deve registrar uma consulta **somente leitura** que gere
uma saída determinística, além do SHA-256 dessa saída. Em produção, não criar
tabela de teste: usar uma consulta estável previamente aprovada ou executar o
ensaio sobre um clone.

Também preparar:

- um arquivo sentinela em ao menos um volume de aplicação;
- um endpoint HTTP de saúde da aplicação;
- inventário de aplicações, serviços e bancos cadastrados no Coolify;
- fingerprint da `APP_KEY`, sem gravar a chave;
- lista de volumes e contagem de arquivos dos volumes escolhidos.

## Preflight comum

O preflight deve falhar cedo e sem alterar dados se qualquer item obrigatório
não for atendido.

- [ ] `RUN_ID` é único e o commit do VPS Guardian foi registrado.
- [ ] Origem e destino são máquinas diferentes.
- [ ] O marcador de destino descartável existe.
- [ ] O snapshot inicial da VM foi identificado.
- [ ] O destino não contém uma instalação do Coolify ou dados que precisem ser
      preservados.
- [ ] A origem consegue executar `ssh` não interativo no destino.
- [ ] O destino consegue executar `ssh` não interativo na origem para T02/ssh.
- [ ] A VM possui CPU, memória e disco suficientes.
- [ ] Não há backup, restore ou deploy concorrente.
- [ ] Os relógios estão sincronizados.
- [ ] Versões de SO, Docker, Coolify e arquitetura foram registradas.
- [ ] O nome exato do container do banco de teste foi registrado.
- [ ] As consultas-oráculo retornam o valor esperado antes do backup.
- [ ] O bucket ou prefixo S3 de teste está isolado e acessível, quando aplicável.
- [ ] O plano de retorno da origem foi conferido.

Comandos auxiliares já existentes:

```bash
sudo /opt/vpsguardian/scripts-auxiliares/validar-pre-migracao.sh
ssh -o BatchMode=yes -p "<PORTA>" root@"<DESTINO>" 'test -f /etc/vpsguardian-e2e-destination'
```

## T01 — Migração completa da VPS para a máquina local

### Intenção

Provar que uma VM limpa pode assumir o estado completo do Coolify e dos dados
persistentes da origem sem fazer cutover de DNS.

### Entrada

Criar na **VPS de origem** um arquivo de configuração não versionado:

```bash
NEW_SERVER_IP="<IP_TAILSCALE_OU_MAGICDNS_DA_VM>"
NEW_SERVER_USER="root"
NEW_SERVER_PORT="22"
SSH_PRIVATE_KEY_PATH="/root/.ssh/vpsguardian-e2e"
BACKUP_FILE=""
MIGRATE_PROXY="true"
KEY_ROTATION_MODE="1"
DESTINATION_MARKER_FILE="/etc/vpsguardian-e2e-destination"
```

`KEY_ROTATION_MODE=1` mantém a chave durante o ensaio e permite validar dados
criptografados. Rotação de chaves merece um teste separado. O wrapper exporta
`MIGRATE_PROXY` e `KEY_ROTATION_MODE` para o processo filho; ainda assim,
confirmar a estratégia registrada nos logs antes de aceitar o resultado.

### Preparação de evidências

Na origem, antes da execução:

1. salvar inventário sanitizado de containers e volumes;
2. salvar inventário de recursos do Coolify via API, se configurada;
3. executar e salvar as consultas-oráculo dos bancos;
4. calcular o hash do arquivo sentinela do volume;
5. salvar somente a fingerprint da `APP_KEY`;
6. registrar estado e resposta HTTP das aplicações de teste;
7. iniciar cronômetro do RTO imediatamente antes do comando de migração.

### Execução

Executar na VPS de origem:

```bash
sudo env ALLOW_DESTRUCTIVE_E2E=YES \
  /opt/vpsguardian/migrar/migrar-completo.sh \
  --config=/opt/vpsguardian/config/e2e-migration.conf \
  --auto \
  --require-destination-marker=/etc/vpsguardian-e2e-destination \
  --json-report="<ARTIFACT_DIR>/T01/migration.json" \
  --junit-report="<ARTIFACT_DIR>/T01/migration.xml"
```

Adicionar `--replace-existing` somente quando houver uma instalação descartável
preexistente a ser substituída. A flag falha antes do backup se o marcador, a
autorização explícita ou a identidade distinta das máquinas não forem
comprovados.

`migrar-completo.sh` é o entrypoint correto para T01. Não substituir por
`migrar-coolify.sh --auto`: esse comando migra o plano de controle e ignora a
migração adicional dos volumes de aplicações no modo automático.

### Validação do destino

Executar primeiro, a partir da origem ou de outro host que possua o VPS
Guardian, a validação remota fornecida pelo projeto:

```bash
sudo /opt/vpsguardian/scripts-auxiliares/validar-pos-migracao.sh \
  --remote "<DESTINO>" --user root --port 22
```

Depois, validar os oráculos específicos:

- [ ] o comando de migração terminou com código zero;
- [ ] `coolify`, `coolify-db`, `coolify-redis` e `coolify-realtime` estão rodando;
- [ ] a interface do Coolify responde na VM;
- [ ] a fingerprint da `APP_KEY` é igual à da origem;
- [ ] aplicações, serviços e bancos esperados estão cadastrados;
- [ ] chaves SSH públicas esperadas possuem as mesmas fingerprints;
- [ ] proxy e certificados selecionados foram copiados;
- [ ] todos os volumes escolhidos existem no destino;
- [ ] o arquivo sentinela possui o mesmo SHA-256;
- [ ] os containers de banco estão saudáveis após serem recriados/redeployados;
- [ ] as consultas-oráculo dos bancos retornam os mesmos resultados;
- [ ] os endpoints HTTP de teste respondem no destino;
- [ ] a origem voltou ao estado operacional após a captura dos volumes;
- [ ] não houve alteração no DNS público.

Para testar um hostname sem alterar DNS:

```bash
curl --resolve '<APP_HOST>:443:<IP_DESTINO>' 'https://<APP_HOST>/up'
```

Se o ensaio usa certificado Origin da Cloudflare, separar "roteamento funciona"
de "cadeia pública é confiável". Não transformar `curl -k` em critério de TLS
válido.

### Critério de aprovação de T01

T01 passa somente quando:

1. todas as validações obrigatórias acima passam;
2. o conteúdo persistente é comprovado por sentinela e consulta, não só por
   existência de volume;
3. o Coolify de destino consegue controlar os recursos restaurados;
4. a origem está operacional ou seu estado final planejado foi comprovado;
5. RTO, RPO e evidências foram registrados.

Uma migração que exige correção manual não deve receber `PASS`; usar
`PASS_WITH_OBSERVATION` somente para uma exceção previamente aceita e descrita.

## T02 — Restauração seletiva de um banco na máquina local

### Intenção

Provar que um dump produzido na VPS pode ser baixado por uma origem selecionada
e aplicado a **um único banco de aplicação**, sem modificar o banco do Coolify
ou os demais bancos.

### Matriz de transporte

T02 é um caso parametrizado:

| Caso | `RESTORE_SOURCE` | Origem do lote | Obrigatório inicialmente |
|---|---|---|---|
| T02a | `ssh` | storage local da VPS | Sim |
| T02b | `s3` | bucket S3 compatível | Sim, se S3 faz parte do produto suportado |

Executar os dois casos com o mesmo lote comprova paridade. Restaurar o snapshot
da VM entre T02a e T02b para evitar que um caso masque o outro.

### Pré-condições específicas

- o container de destino do banco está rodando e saudável;
- o nome de origem codificado no dump e o nome do container de destino foram
  registrados; se forem diferentes, usar `--target-container`;
- `TEST_DB_NAME` é descartável e pode ser sobrescrito;
- `coolify-db` não está selecionado;
- existem hashes antes do restore para `coolify-db` e para todos os bancos não
  selecionados;
- o lote exato e seu SHA-256 foram registrados.

### Produção do lote na origem

Para storage local:

```bash
sudo /opt/vpsguardian/backup/backup-databases-dump-auto.sh \
  --dest=local --project="<TEST_PROJECT>"
```

Para S3:

```bash
sudo /opt/vpsguardian/backup/backup-databases-dump-auto.sh \
  --dest=aws-s3 \
  --project="<TEST_PROJECT>" \
  --prefix="e2e/vpsguardian/<RUN_ID>"
```

O valor de `--prefix` sobrescreve o prefixo S3 configurado para esta execução. O
restore deve receber exatamente o mesmo valor, evitando procurar o lote em um
caminho diferente daquele usado pelo produtor.

Após o backup:

1. identificar o lote criado nesta execução, sem usar implicitamente o mais
   recente;
2. registrar nome, tamanho, timestamp, origem e SHA-256;
3. confirmar que o dump do banco escolhido existe;
4. confirmar que o objeto S3 está no bucket de teste e no prefixo ativo;
5. alterar somente o banco descartável no destino para o marcador
   `DEST_AFTER_BACKUP`, tornando o efeito do restore observável.

### Execução automatizada

Via storage local da VPS:

```bash
sudo /opt/vpsguardian/backup/restaurar-dumps-remotos.sh \
  --source=ssh \
  --ssh-host="<SOURCE_HOST>" \
  --ssh-user="<SOURCE_USER>" \
  --ssh-port="<SOURCE_PORT>" \
  --ssh-dir=/var/backups/vpsguardian/databases \
  --batch="<LOTE_EXATO.tar.gz>" \
  --dump="<TEST_DB_SOURCE_CONTAINER>" \
  --target-container="<TEST_DB_CONTAINER>" \
  --expected-sha256="<SHA256_DO_LOTE>" \
  --yes --no-cleanup \
  --json-report="<ARTIFACT_DIR>/T02/restore-ssh.json" \
  --junit-report="<ARTIFACT_DIR>/T02/restore-ssh.xml"
```

Via S3:

```bash
sudo /opt/vpsguardian/backup/restaurar-dumps-remotos.sh \
  --source=s3 \
  --s3-bucket="<S3_BUCKET>" \
  --s3-prefix="e2e/vpsguardian/<RUN_ID>" \
  --batch="<LOTE_EXATO.tar.gz>" \
  --dump="<TEST_DB_SOURCE_CONTAINER>" \
  --target-container="<TEST_DB_CONTAINER>" \
  --expected-sha256="<SHA256_DO_LOTE>" \
  --yes --no-cleanup \
  --json-report="<ARTIFACT_DIR>/T02/restore-s3.json" \
  --junit-report="<ARTIFACT_DIR>/T02/restore-s3.xml"
```

O modo automático exclui qualquer dump do Coolify por padrão e rejeita a seleção
explícita de `coolify-db` no fluxo remoto. `--target-container` exige exatamente
um `--dump`. Se origem e destino usam o mesmo nome, a opção de mapeamento pode
ser omitida.

Sem `--yes`, `--batch` e `--dump`, o mesmo script mantém a seleção por menus para
uso humano. As opções novas são aditivas e a chamada existente do menu principal
permanece sem argumentos.

### Validação

- [ ] o download veio do transporte solicitado (`ssh` ou `s3`);
- [ ] o SHA-256 do lote baixado corresponde ao registrado na origem;
- [ ] apenas o dump de `TEST_DB_SOURCE_CONTAINER` foi selecionado e seu destino
      registrado é `TEST_DB_CONTAINER`;
- [ ] o restore terminou com código zero e informou uma restauração bem-sucedida;
- [ ] a consulta-oráculo voltou a `SOURCE_BEFORE_BACKUP`;
- [ ] o marcador `DEST_AFTER_BACKUP` deixou de existir conforme esperado;
- [ ] `coolify-db` possui o mesmo fingerprint lógico de antes do restore;
- [ ] todos os bancos não selecionados possuem os mesmos fingerprints lógicos;
- [ ] o container restaurado continua saudável;
- [ ] a aplicação consumidora consulta os dados e responde no endpoint de teste;
- [ ] logs não contêm senha, token ou conteúdo sensível.

### Critério de aprovação de T02

T02 passa somente se o lote correto for autenticado por hash, o dado esperado
for recuperado e nenhum componente fora do escopo sofrer mudança observável.

## Evidências

Estrutura sugerida, fora do repositório:

```text
<ARTIFACT_DIR>/
├── manifest.txt
├── preflight.log
├── versions.txt
├── T01/
│   ├── migration.log
│   ├── migration.json
│   ├── migration.xml
│   ├── source-before.txt
│   ├── source-after.txt
│   ├── destination-after.txt
│   ├── oracle-hashes.txt
│   └── timing.txt
└── T02/
    ├── restore-ssh.log
    ├── restore-ssh.json
    ├── restore-ssh.xml
    ├── restore-s3.log
    ├── restore-s3.json
    ├── restore-s3.xml
    ├── batch-sha256.txt
    ├── selected-dump.txt
    └── oracle-hashes.txt
```

`manifest.txt` deve conter:

- `RUN_ID` e commit do VPS Guardian;
- datas UTC de início e fim;
- nomes das máquinas e versões sanitizadas;
- nome exato do backup/lote;
- resultado `PASS`, `FAIL`, `BLOCKED` ou `PASS_WITH_OBSERVATION`;
- RTO e RPO observados;
- lista dos arquivos de evidência e seus hashes;
- observações e links para issues encontradas.

## Limpeza e retorno

1. coletar evidências antes de qualquer limpeza;
2. confirmar que a origem está operacional;
3. desligar ou destruir a VM descartável, ou restaurar seu snapshot inicial;
4. remover a chave pública temporária dos dois lados;
5. revogar credenciais S3 temporárias;
6. remover somente os objetos do ensaio no bucket S3 de teste, depois de
   confirmar individualmente o alvo;
7. remover arquivos temporários do ensaio sem afetar a retenção real;
8. registrar a conclusão da limpeza no manifesto.

## Lacunas de CLI corrigidas nesta revisão

Os bloqueios identificados durante o desenho deste plano foram tratados:

1. **Entry point remoto:** o wrapper usa
   `migrar/restore-databases-dump.sh`, que é o restaurador existente.
2. **Execução sem prompts:** `--source`, `--batch`, `--dump`, `--yes`, opções de
   transporte e política explícita de limpeza formam o contrato automatizado.
3. **Proteção do Coolify:** o modo automático exclui Coolify por padrão; o
   restaurador local exige `--include-coolify` para uma autorização explícita,
   e o wrapper remoto de bancos de aplicação não aceita esse opt-in.
4. **Mapeamento de container:** `--target-container` permite restaurar um único
   dump em um container cujo nome difere da origem.
5. **Guardas destrutivas:** `migrar-completo.sh` compara `/etc/machine-id` e,
   quando o marcador é exigido, valida também sua existência e
   `ALLOW_DESTRUCTIVE_E2E=YES` antes de criar backups.
6. **Propagação pelo wrapper:** `MIGRATE_PROXY` e `KEY_ROTATION_MODE` são
   exportados para o migrador filho.
7. **Contrato S3:** `--prefix` do produtor chega ao uploader como prefixo S3, e
   o consumidor aceita `--s3-prefix` com o mesmo valor isolado por `RUN_ID`.
8. **Saída de máquina:** migração e restauração produzem JSON e JUnit XML, além
   dos logs humanos, inclusive em falhas anteriores ao acesso ao banco.

Esses contratos possuem regressões com Docker, SSH e S3 simulados em
`tests/test-restore-automation.sh`. Isso valida a lógica sem tocar uma VPS real;
não substitui a execução de T01 e T02 nem seus oráculos de dados.

As pendências para uma automação E2E completamente autônoma são o runner que
orquestra preflight, fixture, coleta de evidências, oráculos e teardown, além de
timeouts globais e dois ensaios reais consecutivos a partir de VM limpa.

Não automatizar menus com `expect` como solução definitiva. Um contrato de CLI
não interativo é mais seguro, auditável e estável.

## Estrutura futura da automação

```text
tests/e2e/
├── README.md
├── e2e.env.example
├── run.sh
├── lib/
│   ├── guards.sh
│   ├── evidence.sh
│   └── oracles.sh
└── fixtures/
    └── database/
```

Interface sugerida:

```bash
tests/e2e/run.sh preflight --env /caminho/e2e.env
tests/e2e/run.sh migration --env /caminho/e2e.env
tests/e2e/run.sh restore --source=ssh --env /caminho/e2e.env
tests/e2e/run.sh restore --source=s3 --env /caminho/e2e.env
tests/e2e/run.sh collect --env /caminho/e2e.env
tests/e2e/run.sh teardown --env /caminho/e2e.env
```

Cada fase deve ser reexecutável quando seguro, possuir timeout, capturar código
de saída e coletar evidência mesmo em caso de falha.

## Registro de execuções

| RUN_ID | Commit | Cenário | Transporte | Resultado | RTO | RPO | Evidências | Observações |
|---|---|---|---|---|---|---|---|---|
| — | — | T01 | Tailscale/SSH | NOT_RUN | — | — | — | — |
| — | — | T02a | SSH | NOT_RUN | — | — | — | — |
| — | — | T02b | S3 | NOT_RUN | — | — | — | — |

## Definição de pronto

O conjunto está pronto para uso recorrente quando:

- [ ] T01 e T02 passam duas vezes consecutivas a partir de uma VM limpa;
- [ ] T02a e T02b produzem o mesmo resultado lógico para o mesmo lote;
- [ ] nenhuma etapa depende de resposta interativa;
- [ ] guardas destrutivas possuem testes próprios;
- [ ] falha em qualquer oráculo gera código de saída diferente de zero;
- [ ] logs e relatórios não vazam segredos;
- [ ] teardown remove somente recursos associados ao `RUN_ID`;
- [ ] a documentação operacional aponta para este plano.

## Referências

- [Instalação e requisitos do Coolify](https://coolify.io/docs/get-started/installation)
- [Backup e restauração do Coolify](https://coolify.io/docs/knowledge-base/how-to/backup-restore-coolify)
- [Conectar dispositivos com Tailscale](https://tailscale.com/kb/1452/connect-to-devices)
- `docs/GUIA-MIGRACAO-COMPLETA.md`
- `docs/GUIA-TESTE-BACKUP-RESTORE.md`
- `docs/GUIA-RESTAURACAO.md`
- `docs/migrar/MIGRATION-ARCHITECTURE.md`
