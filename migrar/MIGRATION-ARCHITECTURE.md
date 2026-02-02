# Arquitetura de Migração Robusta - VPS Guardian

## 🎯 Problema Resolvido

### ❌ Problema Original (Antes)
```bash
# Script antigo simplesmente copiava bytes brutos dos volumes
docker run --rm -v mysql-data:/source busybox tar -czf backup.tar.gz /source
```

**Resultado**: Redo logs corrompidos, crash loops, dados inconsistentes.

```
[ERROR] [MY-013879] [InnoDB] The redo log file ./#innodb_redo/#ib_redo532
comes from other data directory than redo log file ./#innodb_redo/#ib_redo13
```

### ✅ Solução Implementada (Agora)

**Estratégia "Double-Check"**: Exportação lógica (SQL dump) + Snapshot físico (volume)

---

## 🏗️ Nova Arquitetura

### 1. Detecção Dinâmica de Bancos de Dados

```bash
# Não usa nomes hardcoded como "coolify-db"
# Detecta por imagem Docker e variáveis de ambiente

detect_database_type() {
    local image=$(docker inspect --format='{{.Config.Image}}' "$container")

    if [[ "$image" =~ mysql|mariadb ]]; then echo "mysql"
    elif [[ "$image" =~ postgres ]]; then echo "postgres"
    elif [[ "$image" =~ mongo ]]; then echo "mongodb"
    elif [[ "$image" =~ redis ]]; then echo "redis"
    fi
}
```

**Benefício**: Funciona com qualquer nome de container, qualquer aplicação.

---

### 2. Backup Duplo (Double-Check)

#### Para Bancos de Dados:
1. **SQL Dump** (prioridade) - Garantia de portabilidade
   - MySQL: `mysqldump --single-transaction --quick`
   - PostgreSQL: `pg_dump --clean --if-exists`
   - MongoDB: `mongodump` + tar.gz

2. **Volume Snapshot** (fallback) - Garantia de velocidade
   - Redis: Pausa temporária antes do backup
   - Outros DBs: Snapshot rápido após dump

#### Para Volumes Normais:
- Apenas snapshot físico (suficiente)

#### Metadata Salva:
```bash
# Arquivo .meta para cada volume
VOLUME_NAME=coolify-db-data
IS_DATABASE=true
DB_TYPE=mysql
VOLUME_UID=999
VOLUME_GID=999
SQL_DUMP_FILE=coolify-db-data-dump-20260202_143022.sql
VOLUME_BACKUP_FILE=coolify-db-data-backup-20260202_143022.tar.gz
```

---

### 3. Restore Inteligente com Fallback Automático

#### Fluxo de Decisão:

```
┌─────────────────────────────────┐
│  1. Restaurar Volume Snapshot   │
└────────────┬────────────────────┘
             │
             ▼
┌─────────────────────────────────┐
│  2. Iniciar Container           │
└────────────┬────────────────────┘
             │
             ▼
      ┌──────┴──────┐
      │ Rodando OK? │
      └──────┬──────┘
             │
      ┌─────┴─────┐
      │           │
     SIM         NÃO
      │           │
      ▼           ▼
   ✅ FIM   ┌─────────────────────┐
            │ 3. Detectar Crash   │
            │    Loop?            │
            └──────┬──────────────┘
                   │
            ┌──────┴──────┐
            │             │
          SIM            NÃO
            │             │
            ▼             ▼
   ┌─────────────┐   ⚠️ Aviso
   │ 4. Fallback │   (investigar)
   │    SQL Dump │
   └──────┬──────┘
          │
          ▼
   ┌─────────────────────┐
   │ - Deletar volume    │
   │ - Criar vazio       │
   │ - Subir container   │
   │ - Restaurar SQL     │
   └──────┬──────────────┘
          │
          ▼
        ✅ FIM
```

#### Detecção de Crash Loop

```bash
# Analisa logs em busca de padrões conhecidos
detect_crash_loop() {
    local logs=$(docker logs "$container" 2>&1 | tail -50)

    # MySQL/MariaDB
    if echo "$logs" | grep -qi "redo log.*comes from other data directory"; then
        return 0  # Crash detectado
    fi

    # PostgreSQL
    if echo "$logs" | grep -qi "database system is in recovery mode"; then
        return 0
    fi

    # MongoDB
    if echo "$logs" | grep -qi "exception in initAndListen"; then
        return 0
    fi
}
```

---

## 📦 Novos Scripts

### `backup-database-volumes.sh`
- **Propósito**: Backup inteligente com detecção de DBs
- **Estratégia**: SQL Dump + Volume Snapshot
- **Uso**:
  ```bash
  ./backup-database-volumes.sh
  ```

### `restore-database-volumes.sh`
- **Propósito**: Restore com fallback automático
- **Estratégia**: Volume primeiro, SQL se falhar
- **Uso**:
  ```bash
  export BACKUP_DIR="/root/coolify-volumes-backup"
  ./restore-database-volumes.sh
  ```

### `validate-database-health.sh`
- **Propósito**: Validação pós-restore
- **Testes**: Conectividade, queries, integridade
- **Uso**:
  ```bash
  # Validar todos os DBs
  ./validate-database-health.sh --all

  # Validar específico
  ./validate-database-health.sh --container=coolify-db
  ```

---

## 🚀 Como Usar a Nova Migração

### Migração Completa (Recomendado)

```bash
cd /opt/vpsguardian
./migrar/migrar-completo.sh
```

O script agora:
1. ✅ Detecta automaticamente bancos de dados
2. ✅ Faz dump SQL antes de copiar volumes
3. ✅ Transfere ambos (dump + volume) para novo servidor
4. ✅ Tenta restore de volume primeiro (rápido)
5. ✅ Se crash loop detectado → fallback automático para SQL
6. ✅ Valida integridade pós-restore

### Validação Pós-Migração

```bash
# No servidor novo
./scripts-auxiliares/validate-database-health.sh --all
```

Saída esperada:
```
========== Validando: coolify-db ==========
Estado: running
Tipo: mysql
  🔍 Testando conectividade MySQL...
  ✅ MySQL responde a ping
  ✅ Query test passou
  📊 Databases encontradas: 3
  🔧 Verificando integridade das tabelas...
  ✅ Integridade das tabelas: OK
```

---

## 🔍 Troubleshooting

### Container em Crash Loop Após Restore

**Sintoma**:
```bash
docker ps -a
# coolify-db   Restarting (1) 5 seconds ago
```

**O que o script faz automaticamente**:
1. Detecta o crash loop analisando logs
2. Identifica padrão de erro (ex: "redo log corruption")
3. Deleta o volume corrompido
4. Cria volume limpo
5. Restaura do dump SQL

**Intervenção manual** (se necessário):
```bash
# 1. Parar container
docker stop coolify-db

# 2. Deletar volume
docker volume rm coolify-db-data

# 3. Criar novo
docker volume create coolify-db-data

# 4. Subir container
docker start coolify-db

# 5. Aguardar aceitar conexões
sleep 10

# 6. Restaurar SQL
cat /root/coolify-volumes-backup/coolify-db-data-dump-*.sql | \
  docker exec -i coolify-db mysql -u root -p$MYSQL_ROOT_PASSWORD
```

### Validar Integridade Manualmente

#### MySQL
```bash
docker exec coolify-db mysqlcheck -u root -p$MYSQL_ROOT_PASSWORD \
  --all-databases --check
```

#### PostgreSQL
```bash
docker exec -e PGPASSWORD=$POSTGRES_PASSWORD postgres-db \
  psql -U postgres -c "SELECT version();"
```

#### MongoDB
```bash
docker exec mongo-db mongo --username root --password $MONGO_PASSWORD \
  --authenticationDatabase admin --eval "db.serverStatus()"
```

---

## 📊 Comparação: Antes vs Depois

| Aspecto | Antes (backup-volumes.sh) | Depois (backup-database-volumes.sh) |
|---------|---------------------------|-------------------------------------|
| **Detecção de DB** | ❌ Não detecta | ✅ Detecção dinâmica |
| **Dump SQL** | ❌ Não faz | ✅ MySQL, PostgreSQL, MongoDB |
| **Crash Loop** | ❌ Falha silenciosa | ✅ Detecção + fallback automático |
| **Metadata** | ⚠️ Mínima | ✅ Completa (tipo, UID/GID, etc) |
| **Portabilidade** | ❌ Depende de versão exata | ✅ Funciona entre versões |
| **Validação** | ❌ Nenhuma | ✅ Health checks integrados |
| **Production-ready** | ❌ Gambiarra | ✅ Robusto |

---

## 💡 Boas Práticas

### 1. Sempre Validar Após Restore
```bash
./scripts-auxiliares/validate-database-health.sh --all
```

### 2. Testar em Staging Primeiro
```bash
# Fazer backup de produção
./migrar/backup-database-volumes.sh

# Restaurar em staging
export BACKUP_DIR="/path/to/backup"
./migrar/restore-database-volumes.sh

# Validar
./scripts-auxiliares/validate-database-health.sh --all
```

### 3. Manter Dumps SQL Separados
```bash
# Dumps SQL são pequenos e valiosos
# Guardar separadamente dos volumes
cp *-dump-*.sql /backup/sql-dumps/
```

### 4. Documentar Customizações
```bash
# Se adicionar suporte a novo banco
# Ex: CouchDB, Cassandra, etc.
# Documentar aqui e submeter PR
```

---

## 🎓 O "Pulo do Gato" (Dica de Senior)

> **Por que a estratégia "Volume primeiro, SQL depois" funciona?**

1. **90% dos casos**: Volume restore é rápido e funciona
   - ✅ Container sobe OK
   - ✅ Aplicação online em minutos

2. **10% dos casos**: Volume tem corrupção
   - ⚠️ Container entra em crash loop
   - 🤖 Script detecta automaticamente
   - 🔄 Fallback para SQL dump (portabilidade garantida)
   - ✅ Aplicação online em ~15min

3. **Melhor dos dois mundos**:
   - Velocidade do volume quando possível
   - Confiabilidade do SQL quando necessário
   - Zero intervenção manual

---

## 📝 Changelog

### v2.0.0 - Migração Robusta (2026-02-02)

**Adicionado**:
- `backup-database-volumes.sh` - Backup com Double-Check
- `restore-database-volumes.sh` - Restore inteligente
- `validate-database-health.sh` - Validação pós-restore
- Detecção dinâmica de bancos de dados
- Crash loop detection automático
- Metadata completa de volumes
- Health checks integrados

**Modificado**:
- `migrar-completo.sh` - Usa novos scripts robustos

**Depreciado**:
- `backup-volumes.sh` - Mantido para compatibilidade, mas não recomendado

---

## 🤝 Contribuindo

Se você encontrar um novo padrão de crash loop ou quiser adicionar suporte a outro banco de dados:

1. Adicione o padrão em `detect_crash_loop()`
2. Adicione a função de dump em `dump_<database>()`
3. Adicione a função de restore em `restore_<database>_from_dump()`
4. Adicione validação em `check_<database>_health()`
5. Submeta PR com testes

---

## 📚 Referências

- [MySQL InnoDB Redo Log Issues](https://dev.mysql.com/doc/refman/8.0/en/innodb-redo-log.html)
- [PostgreSQL Backup Best Practices](https://www.postgresql.org/docs/current/backup.html)
- [MongoDB Backup Methods](https://docs.mongodb.com/manual/core/backups/)
- [Docker Volume Backup Strategies](https://docs.docker.com/storage/volumes/)

---

**Autor**: VPS Guardian Team
**Data**: 2026-02-02
**Versão**: 2.0.0
**Status**: ✅ Production-Ready
