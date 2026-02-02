# 🎯 Sistema de Backup Completo - VPS Guardian

## 📋 Entendendo os Dois Tipos de Backup

O VPS Guardian implementa **backup completo em duas camadas**:

### 1️⃣ **Backup do Coolify** (Configurações)
**Arquivo**: `backup/backup-coolify.sh`

**O que salva**:
- ✅ Banco de dados do Coolify (PostgreSQL)
- ✅ Configurações de todas as aplicações
- ✅ Variáveis de ambiente
- ✅ SSH Keys de deploy
- ✅ Certificados SSL
- ✅ Configurações Nginx/Traefik
- ✅ APP_KEY

**O que NÃO salva**:
- ❌ Dados das aplicações (posts, uploads, etc.)
- ❌ Bancos de dados das aplicações

**Resultado**: 1 arquivo `.tar.gz` com TUDO do Coolify
```
coolify-backup-20260202_020000.tar.gz  (~50MB-200MB)
```

---

### 2️⃣ **Backup de Volumes** (Dados das Aplicações)
**Arquivo**: `migrar/backup-database-volumes.sh`

**O que salva**:
- ✅ **Dados** de todas as aplicações (volumes Docker)
- ✅ Bancos de dados das aplicações (MySQL, PostgreSQL, MongoDB)
- ✅ Arquivos enviados (uploads, imagens)
- ✅ Dados persistentes

**Estratégia Double-Check**:
- 📤 **SQL Dump** (para bancos de dados) - Prioridade
- 📦 **Volume Snapshot** (para todos) - Fallback

**Resultado**: 1 arquivo por volume
```
/var/backups/vpsguardian/volumes/
├── app-wordpress-abc123-data-backup-20260202.tar.gz
├── app-wordpress-abc123-data-dump-20260202.sql
├── app-nodejs-api-xyz789-data-backup-20260202.tar.gz
└── app-nodejs-api-xyz789-dump-20260202.sql
```

---

## 🎯 Por Que Dois Backups?

| Aspecto | Backup Coolify | Backup Volumes |
|---------|----------------|----------------|
| **Tamanho** | Pequeno (~100MB) | Grande (GB) |
| **Frequência** | Semanal | Semanal/Diário |
| **Conteúdo** | "Cérebro" | "Corpo" |
| **Restauração** | Rápida (5min) | Lenta (30min-2h) |
| **Crítico?** | ✅ Sim | ✅ Sim |

**Analogia**:
- **Coolify** = Planta da casa (como construir tudo de novo)
- **Volumes** = Móveis e objetos (os dados reais)

**Você precisa de AMBOS para restauração completa!**

---

## 🚀 Configuração Automática Completa

### Passo 1: Executar Configurador

```bash
cd /opt/vpsguardian
sudo ./scripts-auxiliares/configurar-cron.sh
```

### Passo 2: Responder Perguntas

```
1️⃣  BACKUP DE BANCOS DE DADOS
    → Habilitar? (Y/n): y
    → Frequência: daily
    → Horário: 01:00

2️⃣  BACKUP DO COOLIFY (Configurações)
    → Dia da semana: 0 (Domingo)
    → Horário: 02:00

3️⃣  BACKUP DE VOLUMES (Dados das Aplicações) ⭐ NOVO!
    → Habilitar? (Y/n): y                    ← IMPORTANTE: Diga Y!
    → Frequência: weekly
    → Dia da semana: 0 (Domingo)
    → Horário: 01:00                         ← Antes do Coolify

4️⃣  MANUTENÇÃO PREVENTIVA
    → Dia: 1 (Segunda)
    → Horário: 03:00

5️⃣  ALERTA DE DISCO
    → Horário: 09:00

6️⃣  UPLOAD AUTOMÁTICO (Opcional)
    → Habilitar? (y/N): n                    ← Opcional

7️⃣  RETENÇÃO DE BACKUPS
    → Habilitar? (Y/n): y
    → Estratégia: 1 (GFS) ⭐ RECOMENDADO!
```

---

## 📅 Cron Jobs Criados (Exemplo)

```cron
# Domingo 1h - Backup de volumes (DADOS)
0 1 * * 0 /opt/vpsguardian/migrar/backup-database-volumes.sh

# Domingo 2h - Backup do Coolify (CONFIGURAÇÕES)
0 2 * * 0 /opt/vpsguardian/backup-coolify.sh

# Domingo 4h - Limpeza GFS (Coolify)
0 4 * * 0 /opt/vpsguardian/scripts-auxiliares/limpar-backups-antigos.sh \
  --dir=/var/backups/vpsguardian/coolify --strategy=gfs --auto

# Domingo 4h - Limpeza GFS (Volumes)
0 4 * * 0 /opt/vpsguardian/scripts-auxiliares/limpar-backups-antigos.sh \
  --dir=/var/backups/vpsguardian/volumes --strategy=gfs --auto
```

---

## 📊 Estrutura Completa de Backups

```
/var/backups/vpsguardian/
│
├── coolify/                                          ← Configurações
│   ├── coolify-backup-20260126_020000.tar.gz       (4 semanais)
│   ├── coolify-backup-20260201_020000.tar.gz       (1 mensal)
│   └── coolify-backup-20260202_020000.tar.gz       (último)
│
└── volumes/                                         ← Dados
    ├── app-wordpress-abc123-data-backup-*.tar.gz   (snapshot)
    ├── app-wordpress-abc123-data-dump-*.sql        (SQL dump)
    ├── app-wordpress-abc123-data-backup-*.meta     (metadata)
    │
    ├── app-nodejs-api-xyz789-data-backup-*.tar.gz
    ├── app-nodejs-api-xyz789-dump-*.sql
    │
    └── coolify-db-backup-*.tar.gz                   (banco do Coolify)
```

---

## 🔍 Como Identificar Aplicações nos Backups

### Listar Volumes Atuais

```bash
docker volume ls
```

**Saída**:
```
VOLUME NAME
coolify-db                          ← Banco do Coolify
app-wordpress-abc123-data           ← WordPress (ID: abc123)
app-nodejs-api-xyz789-data          ← API Node (ID: xyz789)
app-mysql-prod-def456-data          ← MySQL (ID: def456)
```

### Padrão de Nomenclatura

```
app-{nome-da-app}-{id-unico}-data
     └─────┬─────┘  └───┬───┘
       Nome visual   ID gerado pelo Coolify
```

### Ver Metadata de um Volume

```bash
cat /var/backups/vpsguardian/volumes/app-wordpress-abc123-data-backup-*.meta
```

**Saída**:
```
VOLUME_NAME=app-wordpress-abc123-data
IS_DATABASE=true
DB_TYPE=mysql
CONTAINER_NAME=app-wordpress-abc123
SQL_DUMP_FILE=app-wordpress-abc123-data-dump-20260202.sql
VOLUME_BACKUP_FILE=app-wordpress-abc123-data-backup-20260202.tar.gz
```

---

## 🎯 Cenários de Restauração

### Cenário 1: Perdi TUDO (servidor destruído)

**Você precisa de**:
1. ✅ Último backup do Coolify (`coolify-backup-*.tar.gz`)
2. ✅ Todos os backups de volumes (`volumes/`)

**Passo a passo**:
```bash
# 1. Instalar Coolify novo
curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash

# 2. Restaurar Coolify
./backup/restaurar-coolify-remoto.sh

# 3. Restaurar volumes
./migrar/restore-database-volumes.sh

# 4. Deploy de cada aplicação no Coolify
```

---

### Cenário 2: Só uma aplicação deu problema

**Você precisa de**:
- ✅ Backup do volume específico

**Passo a passo**:
```bash
# 1. Parar aplicação no Coolify

# 2. Deletar volume
docker volume rm app-wordpress-abc123-data

# 3. Restaurar volume
docker volume create app-wordpress-abc123-data

docker run --rm \
  -v app-wordpress-abc123-data:/target \
  -v /var/backups/vpsguardian/volumes:/backup:ro \
  busybox \
  tar -xzf /backup/app-wordpress-abc123-data-backup-20260202.tar.gz -C /target

# 4. Re-deploy da aplicação no Coolify
```

---

### Cenário 3: Banco de dados corrompido (crash loop)

**O restore inteligente faz automaticamente**:

1. Tenta restaurar do volume (rápido)
2. Se detectar crash loop → Deleta volume
3. Restaura do SQL dump (confiável)

**Manual**:
```bash
# Se tiver SQL dump
docker stop app-mysql-prod-def456
docker volume rm app-mysql-prod-def456-data
docker volume create app-mysql-prod-def456-data
docker start app-mysql-prod-def456

# Aguardar MySQL aceitar conexões
sleep 10

# Restaurar dump
cat /var/backups/vpsguardian/volumes/app-mysql-prod-def456-dump-*.sql | \
  docker exec -i app-mysql-prod-def456 mysql -u root -p$MYSQL_ROOT_PASSWORD
```

---

## 📊 Monitoramento

### Ver Status dos Backups

```bash
# Último backup do Coolify
ls -lth /var/backups/vpsguardian/coolify/ | head -5

# Últimos backups de volumes
ls -lth /var/backups/vpsguardian/volumes/*.tar.gz | head -10

# Espaço usado
du -sh /var/backups/vpsguardian/*
```

### Ver Logs

```bash
# Backup do Coolify
tail -f /var/log/manutencao/cron-backup.log

# Backup de volumes
tail -f /var/log/manutencao/cron-volumes-backup.log

# Limpeza
tail -f /var/log/manutencao/cron-cleanup-coolify.log
tail -f /var/log/manutencao/cron-cleanup-volumes.log
```

### Verificar Próximas Execuções

```bash
# Ver cron jobs
crontab -l

# Ver histórico
grep CRON /var/log/syslog | grep backup | tail -20
```

---

## ⚠️ Avisos Importantes

### 1. Ambos os Backups São Necessários

```
❌ ERRADO: Só backup do Coolify
   → Você perde todos os dados das aplicações!

❌ ERRADO: Só backup de volumes
   → Você perde as configurações do Coolify!

✅ CORRETO: Ambos os backups
   → Restauração completa possível
```

### 2. Backup de Volumes Consome Espaço

```bash
# Exemplo de consumo (10 aplicações):
Coolify:  150 MB
Volumes:  50 GB (depende dos dados)

# Com GFS (7 diários + 4 semanais + 12 mensais):
Total: ~23 backups × 50 GB = 1.15 TB
```

**Solução**: Upload automático para S3/Cloud

### 3. Frequência Recomendada

| Tipo | Frequência | Motivo |
|------|------------|--------|
| **Coolify** | Semanal | Configurações mudam pouco |
| **Volumes** | Semanal/Diário | Dados mudam constantemente |
| **Limpeza** | Semanal | Após backups |

---

## 🎓 Boas Práticas

### 1. Teste Restauração Mensalmente

```bash
# Criar servidor de teste
# Restaurar backups
# Validar que tudo funciona
```

### 2. Monitore Espaço em Disco

```bash
# Alerta automático configurado em:
configurar-cron.sh → Opção 5 (Alerta de Disco)
```

### 3. Mantenha Backups Off-Site

```bash
# Configure upload automático
configurar-cron.sh → Opção 6 (Upload Automático)
```

### 4. Documente suas Aplicações

Crie um arquivo `APPS.md` com:
```markdown
# Aplicações no Coolify

1. WordPress (app-wordpress-abc123)
   - URL: blog.example.com
   - Banco: MySQL
   - Volume: app-wordpress-abc123-data

2. API Node.js (app-nodejs-api-xyz789)
   - URL: api.example.com
   - Banco: PostgreSQL
   - Volume: app-nodejs-api-xyz789-data
```

---

## 🆘 Troubleshooting

### Backup de volume falhou

```bash
# Ver log
tail -100 /var/log/manutencao/cron-volumes-backup.log

# Testar manualmente
BACKUP_OUTPUT_DIR=/tmp/test-backup \
  /opt/vpsguardian/migrar/backup-database-volumes.sh
```

### Espaço em disco cheio

```bash
# Limpar backups antigos manualmente
/opt/vpsguardian/scripts-auxiliares/limpar-backups-antigos.sh \
  --dir=/var/backups/vpsguardian/volumes \
  --strategy=count \
  --count=3

# Ou mudar estratégia de retenção
sudo nano /etc/vpsguardian/retention.conf
# RETENTION_STRATEGY=count
# RETENTION_COUNT=5
```

### Banco de dados não restaurou

```bash
# Verificar se tem dump SQL
ls -lh /var/backups/vpsguardian/volumes/*-dump-*.sql

# Restaurar manualmente do dump
cat /path/to/dump.sql | docker exec -i container_name mysql ...
```

---

## 📚 Mais Informações

- **Backup e Retenção**: `docs/BACKUP-E-RETENCAO.md`
- **Migração Robusta**: `migrar/MIGRATION-ARCHITECTURE.md`
- **Restauração**: `docs/RESTAURACAO.md` (criar se necessário)

---

**Última atualização**: 2026-02-02
**Versão**: 2.0.0
**Status**: ✅ Production-Ready
