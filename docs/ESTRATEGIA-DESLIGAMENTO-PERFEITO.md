# Estratégia do "Desligamento Perfeito"

## O Problema

Ao migrar volumes Docker que contêm bancos de dados MySQL/MariaDB/PostgreSQL, você pode encontrar erros críticos:

```
[ERROR] InnoDB: The redo log file comes from other data directory
[ERROR] InnoDB: Plugin initialization aborted with error Generic error
[ERROR] Failed to initialize DD Storage Engine
```

**Por que isso acontece?**

Quando você faz backup de um volume com o banco rodando (ou sem shutdown gracioso):

1. ✅ **Arquivos de dados** (.ibd, ibdata1) são capturados
2. ❌ **Redo logs** são capturados em estado "aberto" ou "sujo"
3. ❌ **Buffer pool** ainda está em memória, não gravado
4. ❌ **Transaction logs** estão inconsistentes

Quando restaura em outro servidor, o MySQL tenta fazer recovery desses logs e encontra:
- Metadados que identificam outro servidor
- Transaction IDs que não batem
- LSN (Log Sequence Number) dessincronizado

**Resultado:** O MySQL se recusa a iniciar para proteger seus dados! 🛑

---

## A Solução: "Desligamento Perfeito"

Esta é a estratégia que equilibra a **conveniência do backup de volumes** com a **integridade de dump SQL**.

### Ritual de Despedida (No Servidor Antigo)

Não vamos apenas "puxar a tomada". Vamos dizer ao banco para **colocar a casa em ordem**:

#### 1. Slow Shutdown do MySQL/MariaDB

```bash
# Entrar no container
docker exec -it mysql-container mysql -u root -p

# Forçar flush completo de buffers
SET GLOBAL innodb_fast_shutdown = 0;

# Sair
exit;

# Parar container graciosamente (timeout de 60s)
docker stop -t 60 mysql-container
```

**O que `innodb_fast_shutdown = 0` faz:**
- ✅ Esvazia **todos** os buffers de memória
- ✅ Finaliza **cada escrita pendente** nos arquivos
- ✅ Limpa os **redo logs** completamente
- ✅ Faz **purge completo** de dados antigos
- ✅ Grava o **LSN final** de forma consistente

#### 2. Checkpoint do PostgreSQL

```bash
# Entrar no container
docker exec -it postgres-container psql -U postgres

# Forçar checkpoint
CHECKPOINT;

# Sair
\q

# Parar container graciosamente
docker stop -t 60 postgres-container
```

**O que `CHECKPOINT` faz:**
- ✅ Força escrita de todos os buffers sujos no disco
- ✅ Atualiza arquivos de controle
- ✅ Garante que o WAL (Write-Ahead Log) está consistente

#### 3. Aguardar Parada Completa

```bash
# Aguardar alguns segundos
sleep 3

# Verificar se realmente parou
docker ps --filter "name=mysql-container"
```

---

### Backup Seguro (Dados Limpos)

Agora que o banco está "limpo", podemos fazer o backup:

```bash
# Fazer backup do volume
docker run --rm \
  -v mysql_data:/volume:ro \
  -v /backups:/backup \
  busybox \
  tar czf /backup/mysql_data-backup.tar.gz -C /volume .
```

**Por que está seguro agora:**
- ✅ Redo logs estão limpos
- ✅ Sem transações pendentes
- ✅ Todos os buffers foram gravados
- ✅ LSN está em estado consistente
- ✅ Nenhum metadata de servidor específico nos logs

---

### Limpeza de Terreno (No Servidor Novo)

Antes de restaurar, garantir que não há "restos" de tentativas anteriores:

```bash
# Parar container (se estiver rodando)
docker stop mysql-container

# Obter nome do volume
VOLUME=$(docker inspect --format='{{range .Mounts}}{{if eq .Destination "/var/lib/mysql"}}{{.Name}}{{end}}{{end}}' mysql-container)

# Limpar TUDO no volume
docker run --rm -v "$VOLUME:/mysql" busybox sh -c "rm -rf /mysql/*"

# Restaurar backup limpo
docker run --rm \
  -v mysql_data:/volume \
  -v /backups:/backup \
  busybox \
  tar xzf /backup/mysql_data-backup.tar.gz -C /volume

# Iniciar container
docker start mysql-container
```

**Por que limpar tudo:**
- ❌ Evita conflito com redo logs fantasma
- ❌ Evita mistura de arquivos de diferentes servidores
- ❌ Evita metadata inconsistente

---

## Usando o Script Automático

O script `backup-volumes.sh` implementa toda essa estratégia automaticamente:

### Uso Básico

```bash
cd /root/vpsguardian-src/backup

# Backup de todos os volumes com Desligamento Perfeito
./backup-volumes.sh --all

# Backup para diretório específico
./backup-volumes.sh --all --output=/backups

# Backup sem reiniciar containers
./backup-volumes.sh --all --no-restart
```

### O Que o Script Faz

#### Fase 1: Detecção Inteligente
- 🔍 Detecta automaticamente containers MySQL, MariaDB, PostgreSQL
- 🔍 Identifica volumes associados a cada banco
- 🔍 Verifica se estão rodando

#### Fase 2: Desligamento Perfeito
- 🛑 Para MySQL/MariaDB:
  - Configura `innodb_fast_shutdown = 0`
  - Para container com timeout de 60s
  - Aguarda parada completa

- 🛑 Para PostgreSQL:
  - Executa `CHECKPOINT`
  - Para container graciosamente
  - Confirma parada

#### Fase 3: Backup Seguro
- 💾 Cria backup de cada volume
- 💾 Nomeia com timestamp: `volume-backup-20260202_223015.tar.gz`
- 💾 Gera metadata do lote: `.batch-20260202_223015.meta`

#### Fase 4: Reinício (Opcional)
- ▶️ Reinicia containers automaticamente (padrão)
- ▶️ Ou deixa parado se usar `--no-restart`

---

## Comparação: Antes vs Depois

### ❌ ANTES (Backup Tradicional)

```bash
# Container rodando, transações ativas
docker run --rm -v mysql_data:/volume -v /backup:/backup \
  busybox tar czf /backup/backup.tar.gz -C /volume .

# Resultado: Redo logs "sujos", transações pendentes
```

**Ao restaurar:**
```
[ERROR] InnoDB: The redo log file comes from other data directory
[ERROR] Failed to initialize DD Storage Engine
```

### ✅ DEPOIS (Desligamento Perfeito)

```bash
# 1. Preparar banco
docker exec mysql-container mysql -u root -e "SET GLOBAL innodb_fast_shutdown = 0;"

# 2. Parar graciosamente
docker stop -t 60 mysql-container

# 3. Backup com dados limpos
docker run --rm -v mysql_data:/volume -v /backup:/backup \
  busybox tar czf /backup/backup.tar.gz -C /volume .

# 4. Reiniciar
docker start mysql-container
```

**Ao restaurar:**
```
[Note] InnoDB: Starting shutdown...
[Note] InnoDB: Shutdown completed
[Note] mysqld: ready for connections
```

---

## Perguntas Frequentes

### Quanto tempo demora o Slow Shutdown?

Depende do tamanho do buffer pool e quantidade de dados sujos:
- **Banco pequeno** (<1GB): 5-10 segundos
- **Banco médio** (1-10GB): 30-60 segundos
- **Banco grande** (>10GB): 1-3 minutos

### Os dados ficam indisponíveis durante o backup?

**Sim, temporariamente:**
- Tempo de parada = Slow Shutdown + Backup + Reinício
- Para minimizar: use `--no-restart` e reinicie quando quiser
- Para zero downtime: use dump SQL ao invés de backup de volume

### Posso fazer backup sem parar o banco?

**Não recomendado** para migração entre servidores. Você terá os erros de redo log.

**Alternativas:**
1. **Dump SQL**: `mysqldump` funciona com banco rodando
2. **Replicação**: Configure replica e migre pela replica
3. **LVM Snapshot**: Se usar LVM no host

### E se meu banco tem senha?

O script tenta sem senha primeiro. Se falhar, você pode:

**Opção 1: Variável de ambiente**
```bash
docker exec mysql-container sh -c 'mysql -u root -p$MYSQL_ROOT_PASSWORD -e "SET GLOBAL innodb_fast_shutdown = 0;"'
```

**Opção 2: Arquivo .my.cnf**
```bash
docker exec mysql-container sh -c 'echo "[client]\npassword=SUA_SENHA" > /root/.my.cnf'
docker exec mysql-container mysql -u root -e "SET GLOBAL innodb_fast_shutdown = 0;"
```

**Opção 3: Manual**
```bash
docker exec -it mysql-container mysql -u root -p
# Digite a senha
SET GLOBAL innodb_fast_shutdown = 0;
exit;
```

### Funciona com outros bancos (MongoDB, Redis)?

**Parcialmente:**
- ✅ **Redis**: Salva automaticamente com `SAVE` ou `BGSAVE`
- ⚠️ **MongoDB**: Precisa de `db.shutdownServer()`
- ⚠️ **Elasticsearch**: Precisa de flush manual

O script atual foca em MySQL/MariaDB/PostgreSQL. Contribuições são bem-vindas!

---

## Troubleshooting

### "Failed to set innodb_fast_shutdown"

**Causa**: Container sem permissão ou banco sem senha configurada

**Solução**:
```bash
# Verificar se precisa de senha
docker logs mysql-container | grep -i password

# Tentar com senha
docker exec mysql-container sh -c 'mysql -u root -p$MYSQL_ROOT_PASSWORD -e "SET GLOBAL innodb_fast_shutdown = 0;"'
```

### "Container não para após 60 segundos"

**Causa**: Banco com muitos dados sujos ou transações longas

**Solução**:
```bash
# Aumentar timeout
docker stop -t 300 mysql-container  # 5 minutos

# Ou forçar (CUIDADO: pode corromper)
docker kill mysql-container
```

### "Backup restaurado ainda dá erro de redo log"

**Possíveis causas:**
1. Backup foi feito sem Slow Shutdown
2. Limpeza do destino não foi completa
3. Versões diferentes de MySQL

**Solução**:
```bash
# Refazer backup com Slow Shutdown
./backup-volumes.sh --all

# No destino, limpar completamente antes de restaurar
docker stop mysql-container
VOLUME=$(docker inspect --format='{{range .Mounts}}{{if eq .Destination "/var/lib/mysql"}}{{.Name}}{{end}}{{end}}' mysql-container)
docker run --rm -v "$VOLUME:/mysql" busybox rm -rf /mysql/*

# Restaurar
tar xzf backup.tar.gz -C /path/to/volume/

# Iniciar
docker start mysql-container
```

---

## Vantagens vs Dump SQL

| Critério | Backup de Volume | Dump SQL |
|----------|------------------|----------|
| **Velocidade de Backup** | ⚡ Rápido (tar) | 🐌 Lento (mysqldump) |
| **Velocidade de Restore** | ⚡ Rápido (tar) | 🐌 Lento (import) |
| **Tamanho do Arquivo** | 💾 Comprimido | 📝 Texto (maior) |
| **Downtime** | ⏸️ Sim (Slow Shutdown) | ✅ Não (pode rodar em paralelo) |
| **Compatibilidade** | ⚠️ Mesma versão MySQL | ✅ Cross-version |
| **Risco de Corrupção** | ⚠️ Médio (sem Slow Shutdown) | ✅ Baixo |
| **Risco de Corrupção** (com Slow Shutdown) | ✅ Baixo | ✅ Baixo |

---

## Scripts Relacionados

- **backup-volumes.sh**: Backup com Desligamento Perfeito (este documento)
- **migrar-volumes.sh**: Migração de volumes para novo servidor
- **fix-mysql-redo-log.sh**: Corrigir redo logs corrompidos
- **fix-docker-network.sh**: Corrigir problemas de rede Docker

---

## Conclusão

A **Estratégia do "Desligamento Perfeito"** permite:

✅ Manter a conveniência de backups de volumes (rápido)
✅ Garantir integridade total dos dados (seguro)
✅ Migrar entre servidores sem erros de redo log
✅ Evitar dumps SQL gigantes e lentos

**Use quando:**
- Migrar servidores (Coolify, etc)
- Fazer backup para disaster recovery
- Mover volumes entre ambientes

**Evite quando:**
- Precisar de zero downtime
- Migrar entre versões muito diferentes de MySQL
- Banco está sempre com alta carga (difícil encontrar janela)

---

**Autor da Estratégia**: Baseado na experiência real de migração de servidores Coolify com MySQL 8.4

**Implementação**: VPS Guardian - Scripts de Backup e Migração
