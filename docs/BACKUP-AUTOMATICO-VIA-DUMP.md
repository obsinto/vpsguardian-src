# Sistema de Backup Automático via Dump SQL

## 📋 Visão Geral

Este sistema permite programar backups automáticos de bancos de dados usando o método **dump SQL** (mesmo script usado na migração - opção 4 do menu), com suporte para múltiplos destinos:

- ✅ **Local** - Salvo em `/var/backups/vpsguardian/database-dumps`
- ✅ **Google Drive** - Via rclone
- ✅ **AWS S3** - Via AWS CLI
- ✅ **SSH (Self-hosted)** - Servidor remoto via rsync/scp

## 🎯 Vantagens do Dump SQL

O sistema usa o script `migrar-databases-dump.sh` que você já testou e funciona bem:

- ✅ Arquivos menores (SQL comprimido)
- ✅ Portável entre versões do banco
- ✅ Sem problemas de redo logs corrompidos
- ✅ Mais fácil de verificar integridade
- ✅ Organizado em lotes com timestamp

## 🚀 Como Configurar

### 1. Configurar Destinos de Backup

Execute via menu ou comando direto:

```bash
# Via menu
sudo ./menu-principal.sh
# Escolha: 2 (Backups) → 11 (Configurar Destinos)

# Ou diretamente
sudo /opt/vpsguardian/backup/configurar-backup-destinos.sh
```

O assistente interativo vai te guiar para configurar:

#### **Backup Local**
- Manter backups locais? (Sim/Não)
- Retenção em dias (padrão: 30 dias)

#### **Backup SSH (Self-hosted)**
- IP/Hostname do servidor remoto
- Usuário SSH (padrão: root)
- Porta SSH (padrão: 22)
- Diretório no servidor remoto
- Caminho da chave SSH
- ✅ Testa conexão automaticamente

#### **Google Drive (rclone)**
- Requer rclone instalado e configurado
- Nome do remote (padrão: gdrive)
- Diretório no Google Drive
- ✅ Valida remote automaticamente

#### **AWS S3**
- Requer AWS CLI instalado e configurado
- Nome do bucket (sem s3://)
- Prefixo/pasta no bucket
- Região (padrão: us-east-1)
- Storage Class (STANDARD_IA recomendado)
- ✅ Testa acesso ao bucket

#### **Opções Adicionais**
- Remover backup local após upload? (Sim/Não)
- Webhook para notificações (Discord/Slack)
- Email para notificações

### 2. Agendar Backups Automáticos

Após configurar os destinos, agende via cron:

```bash
# Via menu
sudo ./menu-principal.sh
# Escolha: 5 (Configuração) → 1 (Configurar Cron)

# Ou diretamente
sudo /opt/vpsguardian/scripts-auxiliares/configurar-cron.sh
```

O assistente vai perguntar:
- **Frequência**: Diário ou Semanal
- **Dia da semana**: 0=Domingo, 1=Segunda, etc
- **Horário**: Formato 24h (ex: 02:00)
- **Incluir containers Coolify**: Sim/Não

## 📦 Estrutura de Arquivos

### Backups Locais
```
/var/backups/vpsguardian/database-dumps/
├── lote-20260304_020000/
│   ├── container1-mysql-20260304_020000.sql.gz
│   ├── container2-postgres-20260304_020000.sql.gz
│   └── migration-metadata-20260304_020000.txt
├── lote-20260305_020000/
│   └── ...
└── lote-20260304_020000.tar.gz  (tarball para upload)
```

### Configuração
```
/opt/vpsguardian/config/
├── backup-destinations.conf  (destinos configurados)
└── default.conf              (configurações globais)
```

### Logs
```
/var/log/vpsguardian/
└── backup-databases-auto-TIMESTAMP.log
```

## 🔧 Uso Manual

### Executar Backup Manualmente

```bash
# Backup local apenas
sudo /opt/vpsguardian/backup/backup-databases-dump-auto.sh --dest=local

# Backup + upload para Google Drive
sudo /opt/vpsguardian/backup/backup-databases-dump-auto.sh --dest=google-drive

# Backup + upload para AWS S3
sudo /opt/vpsguardian/backup/backup-databases-dump-auto.sh --dest=aws-s3

# Backup + upload para SSH
sudo /opt/vpsguardian/backup/backup-databases-dump-auto.sh --dest=self-hosted

# Backup + upload para TODOS os destinos
sudo /opt/vpsguardian/backup/backup-databases-dump-auto.sh --dest=all
```

### Restaurar Backups

Use a opção 5 do menu de Migração:

```bash
sudo ./menu-principal.sh
# Escolha: 4 (Migração) → 5 (Restaurar Dumps SQL)
```

Ou diretamente:

```bash
# Restaurar de lote local
sudo /opt/vpsguardian/migrar/restore-databases-dump.sh \
  --dir=/var/backups/vpsguardian/database-dumps/lote-20260304_020000

# Modo automático (restaura tudo)
sudo /opt/vpsguardian/migrar/restore-databases-dump.sh \
  --dir=/var/backups/vpsguardian/database-dumps/lote-20260304_020000 \
  --auto
```

## ⚙️ Configuração Avançada

### Editar Configuração Manualmente

```bash
sudo nano /opt/vpsguardian/config/backup-destinations.conf
```

**Exemplo de configuração:**

```bash
# Destinos habilitados
BACKUP_DEST_LOCAL=true
BACKUP_DEST_SSH=false
BACKUP_DEST_GOOGLE_DRIVE=true
BACKUP_DEST_AWS_S3=true

# Google Drive
GDRIVE_ENABLED=true
GDRIVE_REMOTE_NAME="gdrive"
GDRIVE_DIR="backups/vpsguardian/databases"

# AWS S3
S3_ENABLED=true
S3_BUCKET="meu-bucket"
S3_PREFIX="backups/vpsguardian/databases"
S3_REGION="us-east-1"
S3_STORAGE_CLASS="STANDARD_IA"

# Retenção
REMOVE_LOCAL_AFTER_UPLOAD=false
LOCAL_BACKUP_RETENTION_DAYS=7

# Notificações
WEBHOOK_URL="https://discord.com/api/webhooks/..."
```

### Testar Destinos Individualmente

```bash
# Testar Google Drive
rclone lsd gdrive:backups/vpsguardian

# Testar AWS S3
aws s3 ls s3://meu-bucket/backups/vpsguardian/databases/ --region us-east-1

# Testar SSH
ssh -p 22 root@servidor-remoto "ls -lh /root/backups"
```

## 📊 Monitoramento

### Ver Logs de Backup

```bash
# Log do último backup
tail -100 /var/log/vpsguardian/backup-databases-auto-*.log | tail -100

# Logs de cron
tail -f /var/log/manutencao/cron-db-backup.log
```

### Verificar Cron Jobs

```bash
# Ver jobs agendados
sudo crontab -l | grep database

# Ver próximas execuções
grep CRON /var/log/syslog | grep database | tail -20
```

### Verificar Backups Criados

```bash
# Listar lotes locais
ls -lh /var/backups/vpsguardian/database-dumps/

# Ver conteúdo de um lote
ls -lh /var/backups/vpsguardian/database-dumps/lote-20260304_020000/

# Ver tamanho total
du -sh /var/backups/vpsguardian/database-dumps/
```

## 🔐 Segurança

### Permissões de Arquivos

```bash
# Configurações (somente root)
chmod 600 /opt/vpsguardian/config/backup-destinations.conf

# Scripts (executáveis)
chmod +x /opt/vpsguardian/backup/*.sh

# Backups (somente root)
chmod 700 /var/backups/vpsguardian/
```

### Credenciais Seguras

- ✅ Chaves SSH: Use chaves sem senha ou via ssh-agent
- ✅ AWS: Use IAM roles ou credenciais em `~/.aws/credentials`
- ✅ Google Drive: rclone armazena tokens em `~/.config/rclone/rclone.conf`
- ✅ Webhooks: Mantenha URLs secretas

## 🚨 Troubleshooting

### Backup não está rodando

```bash
# Verificar se cron está ativo
systemctl status cron

# Verificar se job está agendado
sudo crontab -l | grep database

# Ver erros de cron
grep database /var/log/syslog | tail -20
```

### Upload para Google Drive falha

```bash
# Testar rclone
rclone lsd gdrive:

# Reconfigurar remote
rclone config

# Ver logs detalhados
rclone lsd gdrive: -vv
```

### Upload para S3 falha

```bash
# Testar AWS CLI
aws s3 ls

# Verificar credenciais
cat ~/.aws/credentials

# Testar acesso ao bucket
aws s3 ls s3://meu-bucket/ --region us-east-1
```

### SSH não conecta

```bash
# Testar conexão
ssh -p 22 root@servidor-remoto "echo ok"

# Ver detalhes da conexão
ssh -vvv -p 22 root@servidor-remoto "echo ok"

# Adicionar chave ao ssh-agent
ssh-add ~/.ssh/id_rsa
```

## 🔄 Migração do Sistema Antigo

Se você estava usando o `backup/backup-databases.sh` antigo:

1. **Configure os destinos** usando o novo assistente
2. **Reconfigure o cron** para usar o novo sistema
3. **Mantenha backups antigos** - o novo sistema cria em `/var/backups/vpsguardian/database-dumps`
4. **Teste** antes de desabilitar o antigo

O novo sistema é **compatível** com o antigo - ambos podem coexistir.

## 📞 Suporte

- **Logs**: `/var/log/vpsguardian/`
- **Configuração**: `/opt/vpsguardian/config/`
- **Scripts**: `/opt/vpsguardian/backup/` e `/opt/vpsguardian/migrar/`

## 🎉 Próximos Passos

1. ✅ Configure os destinos: `sudo ./backup/configurar-backup-destinos.sh`
2. ✅ Teste manualmente: `sudo ./backup/backup-databases-dump-auto.sh --dest=local`
3. ✅ Agende via cron: `sudo ./scripts-auxiliares/configurar-cron.sh`
4. ✅ Monitore os logs após primeira execução automática
5. ✅ Teste restauração de um backup
