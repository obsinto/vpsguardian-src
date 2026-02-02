# 📦 Sistema de Backup e Retenção - VPS Guardian

## 🎯 Visão Geral

O VPS Guardian possui um sistema completo de backup automático com políticas de retenção inteligentes para garantir proteção de dados sem desperdiçar espaço em disco.

---

## 🏗️ Arquitetura

```
┌─────────────────────────────────────────────────────────────┐
│                   BACKUP AUTOMÁTICO                         │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────┐ │
│  │   Coolify    │  │  Databases   │  │  Volumes (GFS)   │ │
│  │   (Semanal)  │  │   (Diário)   │  │   (Inteligente)  │ │
│  └──────┬───────┘  └──────┬───────┘  └────────┬─────────┘ │
└─────────┼──────────────────┼───────────────────┼───────────┘
          │                  │                   │
          ▼                  ▼                   ▼
┌─────────────────────────────────────────────────────────────┐
│              POLÍTICA DE RETENÇÃO AUTOMÁTICA                │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  Estratégia GFS (Grandfather-Father-Son)             │  │
│  │  • 7 diários   (últimos 7 dias completos)            │  │
│  │  • 4 semanais  (1 por semana - domingos)             │  │
│  │  • 12 mensais  (1 por mês - dia 1)                   │  │
│  └──────────────────────────────────────────────────────┘  │
│  Alternativas: Simple (por idade) | Count (por qtd)        │
└─────────────────────────────────────────────────────────────┘
          │
          ▼
┌─────────────────────────────────────────────────────────────┐
│        UPLOAD AUTOMÁTICO PARA DESTINO REMOTO (Opcional)    │
│        • SSH (self-hosted) • Google Drive • AWS S3          │
└─────────────────────────────────────────────────────────────┘
```

---

## 🚀 Configuração Rápida

### 1. Configurar Tudo de Uma Vez

```bash
sudo ./scripts-auxiliares/configurar-cron.sh
```

Este script interativo configura:
- ✅ Backup automático do Coolify
- ✅ Backup de bancos de dados
- ✅ Limpeza automática (política de retenção)
- ✅ Upload para destino remoto (opcional)
- ✅ Manutenção preventiva
- ✅ Alertas de disco

**Sugestão profissional**: Escolha estratégia **GFS** na opção 6️⃣ .

---

## 📋 Estratégias de Retenção

### 🥇 GFS (Grandfather-Father-Son) - **RECOMENDADO**

Retenção multi-nível inteligente:

| Nível | Frequência | Retenção | Exemplo |
|-------|------------|----------|---------|
| **Diário** (Son) | Todos os dias | 7 dias | Segunda a Domingo |
| **Semanal** (Father) | 1 por semana (domingo) | 4 semanas | 4 domingos |
| **Mensal** (Grandfather) | 1 por mês (dia 1) | 12 meses | Janeiro-Dezembro |

**Vantagens**:
- ✅ Proteção de curto prazo (recuperação rápida)
- ✅ Proteção de médio prazo (erros não detectados imediatamente)
- ✅ Proteção de longo prazo (histórico)
- ✅ Uso eficiente de espaço
- ✅ Padrão da indústria (Veeam, Bacula, etc.)

**Quando usar**: Produção, servidores críticos

---

### 🥈 Simple (Por Idade)

Deleta backups mais antigos que X dias.

```bash
# Exemplo: Manter backups dos últimos 30 dias
RETENTION_STRATEGY=simple
RETENTION_DAYS=30
```

**Vantagens**:
- ✅ Simples de entender
- ✅ Previsível

**Desvantagens**:
- ❌ Pode crescer indefinidamente se backups forem frequentes
- ❌ Sem proteção de longo prazo

**Quando usar**: Desenvolvimento, servidores com muito espaço

---

### 🥉 Count (Por Quantidade)

Mantém últimos X backups, deleta o resto.

```bash
# Exemplo: Manter apenas os últimos 10 backups
RETENTION_STRATEGY=count
RETENTION_COUNT=10
```

**Vantagens**:
- ✅ Controle preciso do espaço usado
- ✅ Ideal para ambientes com espaço limitado

**Desvantagens**:
- ❌ Se backups forem infrequentes, perde proteção de longo prazo
- ❌ Se backups forem muito frequentes, perde backups antigos rapidamente

**Quando usar**: Ambientes com espaço limitado, staging

---

## 📁 Estrutura de Diretórios

```
/var/backups/vpsguardian/
├── coolify/
│   ├── coolify-backup-20260201_020000.tar.gz
│   ├── coolify-backup-20260208_020000.tar.gz (semanal)
│   └── coolify-backup-20260301_020000.tar.gz (mensal)
│
├── volumes/
│   ├── app-data-backup-20260202_010000.tar.gz
│   ├── app-data-dump-20260202_010000.sql (DB dump)
│   ├── app-data-backup-20260202_010000.meta (metadata)
│   └── .batch-20260202_010000.meta
│
└── databases/
    ├── mysql-prod-20260202_010000.sql.gz
    └── postgres-app-20260202_010000.dump
```

---

## ⚙️ Configuração Manual

### Arquivo de Configuração

```bash
# Copiar exemplo
sudo cp /opt/vpsguardian/config/retention.conf.example \
       /etc/vpsguardian/retention.conf

# Editar
sudo nano /etc/vpsguardian/retention.conf
```

**Exemplo para Produção**:
```bash
# /etc/vpsguardian/retention.conf
RETENTION_STRATEGY=gfs
```

**Exemplo para Desenvolvimento**:
```bash
# /etc/vpsguardian/retention.conf
RETENTION_STRATEGY=count
RETENTION_COUNT=5
```

**Exemplo para Arquivamento**:
```bash
# /etc/vpsguardian/retention.conf
RETENTION_STRATEGY=simple
RETENTION_DAYS=365
```

---

## 🔄 Automação com Cron

### Exemplo Completo (GFS)

```bash
# /etc/crontab

# Backup do Coolify (Domingo 2h)
0 2 * * 0 /opt/vpsguardian/backup-coolify.sh

# Limpeza GFS (Domingo 4h, após backup)
0 4 * * 0 /opt/vpsguardian/scripts-auxiliares/limpar-backups-antigos.sh \
  --dir=/var/backups/vpsguardian/coolify \
  --strategy=gfs \
  --auto

# Backup de volumes robustos (Diário 1h)
0 1 * * * /opt/vpsguardian/migrar/backup-database-volumes.sh

# Limpeza de volumes (Diário 3h, após backup)
0 3 * * * /opt/vpsguardian/scripts-auxiliares/limpar-backups-antigos.sh \
  --dir=/var/backups/vpsguardian/volumes \
  --strategy=gfs \
  --auto
```

---

## 📊 Monitoramento

### Ver Logs

```bash
# Logs de backup
tail -f /var/log/manutencao/cron-backup.log
tail -f /var/log/manutencao/cron-db-backup.log

# Logs de limpeza
tail -f /var/log/manutencao/cron-cleanup-coolify.log
tail -f /var/log/manutencao/cron-cleanup-volumes.log
```

### Verificar Próximas Execuções

```bash
# Ver cron jobs ativos
crontab -l

# Ver histórico de execuções
grep CRON /var/log/syslog | tail -20
```

### Listar Backups Atuais

```bash
# Coolify
ls -lh /var/backups/vpsguardian/coolify/

# Volumes
ls -lh /var/backups/vpsguardian/volumes/

# Ver espaço usado
du -sh /var/backups/vpsguardian/*
```

---

## 🧪 Teste Manual de Limpeza

### Dry-Run (Simular sem deletar)

```bash
# Ver o que seria deletado
./scripts-auxiliares/limpar-backups-antigos.sh \
  --strategy=gfs \
  --dry-run
```

### Limpeza Manual

```bash
# Estratégia GFS
./scripts-auxiliares/limpar-backups-antigos.sh \
  --strategy=gfs

# Deletar backups >30 dias
./scripts-auxiliares/limpar-backups-antigos.sh \
  --strategy=simple \
  --days=30

# Manter apenas últimos 10
./scripts-auxiliares/limpar-backups-antigos.sh \
  --strategy=count \
  --count=10

# Limpar diretório específico
./scripts-auxiliares/limpar-backups-antigos.sh \
  --dir=/var/backups/vpsguardian/volumes \
  --strategy=gfs
```

---

## 🎯 Cenários de Uso

### Servidor de Produção

```bash
# Configuração recomendada
RETENTION_STRATEGY=gfs

# Cron jobs
0 2 * * 0  backup-coolify.sh           # Domingo 2h
0 1 * * *  backup-database-volumes.sh  # Diário 1h
0 4 * * 0  limpar-backups-antigos.sh   # Domingo 4h (GFS)
```

**Resultado**: ~23 backups mantidos (7 diários + 4 semanais + 12 mensais)

---

### Servidor de Desenvolvimento

```bash
# Configuração recomendada
RETENTION_STRATEGY=count
RETENTION_COUNT=5

# Cron jobs
0 3 * * *  backup-coolify.sh           # Diário 3h
0 5 * * *  limpar-backups-antigos.sh   # Diário 5h (count=5)
```

**Resultado**: Apenas 5 backups mais recentes

---

### Servidor com Espaço Limitado

```bash
# Configuração recomendada
RETENTION_STRATEGY=count
RETENTION_COUNT=3

# Upload imediato para cloud
AUTO_UPLOAD=yes
UPLOAD_DEST=aws-s3
```

**Resultado**: 3 backups locais + todos na cloud

---

## 🔧 Integração com Scripts de Backup

### Backup do Coolify

O script `backup-coolify.sh` automaticamente aplica a política de retenção configurada em `/etc/vpsguardian/retention.conf`.

```bash
# Apenas rode o backup
./backup-coolify.sh

# A limpeza é aplicada automaticamente no final
```

### Backup de Volumes Robusto

O script `backup-database-volumes.sh` também aplica retenção automaticamente:

```bash
# Backup com retenção automática
./migrar/backup-database-volumes.sh
```

---

## ❓ FAQ

### Como mudar a estratégia de retenção?

```bash
# Editar configuração
sudo nano /etc/vpsguardian/retention.conf

# Mudar para GFS
RETENTION_STRATEGY=gfs

# Ou reconfigurar tudo
sudo ./scripts-auxiliares/configurar-cron.sh
```

### Posso ter estratégias diferentes para cada tipo de backup?

Sim! Use o parâmetro `--strategy` ao chamar o script de limpeza:

```bash
# Coolify com GFS (longo prazo)
limpar-backups-antigos.sh --dir=/var/backups/vpsguardian/coolify --strategy=gfs

# Volumes com Count (espaço limitado)
limpar-backups-antigos.sh --dir=/var/backups/vpsguardian/volumes --strategy=count --count=5
```

### Como desabilitar limpeza automática temporariamente?

```bash
# Editar cron
crontab -e

# Comentar linha de limpeza com #
# 0 4 * * * /opt/vpsguardian/scripts-auxiliares/limpar-backups-antigos.sh ...
```

### Os backups são testados automaticamente?

Atualmente não, mas você pode adicionar validação:

```bash
# Após backup do Coolify, testar se é válido
tar -tzf /var/backups/vpsguardian/coolify/coolify-backup-latest.tar.gz >/dev/null
```

---

## 🎓 Boas Práticas

### 1. **Teste Restauração Regularmente**

```bash
# Teste pelo menos uma vez por mês
# Ver docs/RESTAURACAO.md
```

### 2. **Monitore Espaço em Disco**

```bash
# Alerta automático (configurado via configurar-cron.sh)
# Ou manual:
df -h /var/backups
```

### 3. **Mantenha Backups Off-Site**

```bash
# Configure upload automático
configurar-cron.sh  # Opção 5: Upload Automático
```

### 4. **Documente Customizações**

Se modificar a política de retenção, documente o motivo:

```bash
# /etc/vpsguardian/retention.conf
# Modificado em 2026-02-02: Mudamos para count=5 devido espaço limitado
RETENTION_STRATEGY=count
RETENTION_COUNT=5
```

### 5. **Estratégia 3-2-1**

- **3** cópias dos dados (original + 2 backups)
- **2** tipos de mídia diferentes (disco local + cloud)
- **1** cópia off-site (outro servidor/região)

Exemplo:
```
1. Original: Coolify rodando
2. Backup local: /var/backups/vpsguardian/
3. Backup remoto: AWS S3 (upload automático)
```

---

## 📚 Referências

- **GFS Backup Scheme**: [Wikipedia](https://en.wikipedia.org/wiki/Backup_rotation_scheme#Grandfather-father-son)
- **Veeam Best Practices**: Estratégia 3-2-1
- **Docker Backup**: [Docker Docs](https://docs.docker.com/storage/volumes/#backup-restore-or-migrate-data-volumes)

---

## 🆘 Suporte

- **Logs**: `/var/log/manutencao/`
- **Configuração**: `/etc/vpsguardian/retention.conf`
- **Issues**: [GitHub Issues](https://github.com/vpsguardian/issues)

---

**Última atualização**: 2026-02-02
**Versão**: 2.0.0
**Status**: ✅ Production-Ready
