# Guia de Migração - Coolify

Migre seu Coolify para um novo servidor de forma segura e sem perda de dados.

## Pré-requisitos

**Servidor Antigo:**
- VPS Guardian instalado
- Coolify funcionando
- Acesso SSH como root

**Servidor Novo:**
- Ubuntu 22.04/24.04 ou Debian 11/12
- 2+ vCPUs, 4GB RAM, 40GB+ disco
- Acesso SSH como root

**Preparação:**
- Chaves SSH configuradas
- TTL DNS reduzido (se mudará IP)
- Janela de manutenção agendada

---

## Método 1: Automatizado (Recomendado)

**Tempo:** 30min-2h | **Downtime:** Sim

### Modo A: Totalmente Automático (Zero Prompts)

**Para migração programada/CI-CD:**

```bash
# 1. Criar arquivo de configuração
cp /opt/vpsguardian/config/migration.conf.example /opt/vpsguardian/config/migration.conf

# 2. Editar configurações
nano /opt/vpsguardian/config/migration.conf

# Conteúdo mínimo:
# NEW_SERVER_IP="192.168.1.100"
# SSH_PRIVATE_KEY_PATH="/root/.ssh/id_rsa"
# MIGRATE_PROXY="true"  # ou "false" para instalar proxy do zero

# 3. Executar migração automática
sudo /opt/vpsguardian/migrar/migrar-coolify.sh --config=/opt/vpsguardian/config/migration.conf --auto

# Pronto! Migração executada sem prompts
```

### Modo B: Interativo (Com Confirmações)

### Passo 1: Preparar Servidor Novo

```bash
# Atualizar sistema
apt update && apt upgrade -y

# Instalar Coolify
curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash

# Verificar se está rodando
docker ps | grep coolify

# Instalar VPS Guardian
cd /opt
git clone https://github.com/SEU-USUARIO/vpsguardian.git
cd vpsguardian
sudo ./instalar.sh
```

### Passo 2: Fazer Backup (Servidor Antigo)

```bash
vps-guardian
# → 2 (Backups)
# → 1 (Backup Completo do Coolify)

# OU via comando
sudo vps-guardian backup

# Verificar
ls -lh /var/backups/vpsguardian/coolify/
```

### Passo 3: Executar Migração (Servidor Antigo)

**Opção 1 - Interativo:**
```bash
vps-guardian
# → 4 (Migração)
# → 1 (Migrar Coolify Completo)

# OU
sudo /opt/vpsguardian/migrar/migrar-coolify.sh

# Confirmar com: YES (em maiúsculas)
```

**Opção 2 - Automático com config:**
```bash
# Configurar primeiro
export NEW_SERVER_IP="192.168.1.100"
export SSH_PRIVATE_KEY_PATH="/root/.ssh/id_rsa"

# Executar
sudo /opt/vpsguardian/migrar/migrar-coolify.sh --auto
```

**Opção 3 - Arquivo de configuração:**
```bash
sudo /opt/vpsguardian/migrar/migrar-coolify.sh \
  --config=/opt/vpsguardian/config/migration.conf \
  --auto
```

**Durante a Migração - Escolha do Proxy:**

O script irá perguntar se você deseja migrar as configurações do proxy:

- **COM Proxy (Recomendado):**
  - ✅ Migra certificados SSL/TLS
  - ✅ Preserva Cloudflare Origin Certificates
  - ✅ Mantém configurações personalizadas
  - ✅ Aplicações funcionam imediatamente com SSL

- **SEM Proxy (Instalação Limpa):**
  - ⚠️ Proxy instalado do zero
  - ⚠️ Certificados precisam ser reconfigurados
  - ⚠️ Útil para mudança de estratégia de proxy
  - ⚠️ Aplicações podem precisar reconfigurar SSL

Para modo automático, defina no arquivo de configuração:
```bash
MIGRATE_PROXY="true"   # Migrar com proxy
# ou
MIGRATE_PROXY="false"  # Proxy do zero
```

### Passo 4: Validar (Servidor Novo)

```bash
# Verificar containers
docker ps | grep coolify

# Verificar banco de dados
docker exec coolify-db psql -U coolify -d coolify -c "SELECT COUNT(*) FROM applications;"

# Acessar Coolify
# http://IP-NOVO:8000
```

### Passo 5: Atualizar DNS (se IP mudou)

```bash
# No seu provedor DNS:
# seu-dominio.com → IP-NOVO

# Verificar propagação
dig seu-dominio.com +short
```

---

## Método 2: Manual (Avançado)

### Passo 1: Fazer Backup (Servidor Antigo)

```bash
mkdir -p /tmp/migracao-coolify
cd /tmp/migracao-coolify

# Banco de dados
docker exec coolify-db pg_dump -U coolify -d coolify -F c -f /tmp/backup.dmp
docker cp coolify-db:/tmp/backup.dmp ./coolify-db.dmp

# SSH keys
cp -r /data/coolify/ssh/keys ./ssh-keys

# .env
cp /data/coolify/source/.env ./coolify.env
grep "^APP_KEY=" ./coolify.env > app-key.txt

# authorized_keys
cp /root/.ssh/authorized_keys ./authorized_keys.bak

# Compactar
cd /tmp
tar -czf migracao-coolify-$(date +%Y%m%d_%H%M%S).tar.gz migracao-coolify/
```

### Passo 2: Transferir Backup

```bash
# Via SCP
scp /tmp/migracao-coolify-*.tar.gz root@IP-NOVO:/tmp/

# Ou via rsync
rsync -avz /tmp/migracao-coolify-*.tar.gz root@IP-NOVO:/tmp/
```

### Passo 3: Restaurar (Servidor Novo)

```bash
cd /tmp
tar -xzf migracao-coolify-*.tar.gz
cd migracao-coolify

# Parar containers
docker ps --filter name=coolify --format '{{.Names}}' | grep -v 'coolify-db' | xargs docker stop

# Restaurar banco
cat coolify-db.dmp | docker exec -i coolify-db \
  pg_restore --verbose --clean --no-acl --no-owner -U coolify -d coolify

# Restaurar SSH keys
rm -rf /data/coolify/ssh/keys/*
cp -r ssh-keys/* /data/coolify/ssh/keys/
chown -R 9999:9999 /data/coolify/ssh/keys

# Restaurar APP_KEY
cd /data/coolify/source
APP_KEY=$(grep "^APP_KEY=" /tmp/migracao-coolify/app-key.txt | cut -d '=' -f2-)
sed -i '/^APP_PREVIOUS_KEYS=/d' .env
echo "APP_PREVIOUS_KEYS=$APP_KEY" >> .env

# Restaurar authorized_keys
cat /tmp/migracao-coolify/authorized_keys >> /root/.ssh/authorized_keys

# Reiniciar Coolify
curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash
```

---

## Método 3: S3 (Intermediário)

### Passo 1: Backup para S3 (Servidor Antigo)

```bash
# Configurar
sudo nano /etc/vpsguardian/backup-s3.conf

# Conteúdo:
S3_PROVIDER="aws"  # ou backblaze, wasabi
S3_BUCKET="migracao-coolify"
S3_REGION="us-east-1"
S3_ACCESS_KEY="sua-chave"
S3_SECRET_KEY="sua-secreta"
ENCRYPT_BACKUP=false

# Fazer backup
sudo vps-guardian backup-s3 --config=/etc/vpsguardian/backup-s3.conf

# Anotar nome do arquivo (ex: 20241209_153045.tar.gz)
```

### Passo 2: Restaurar do S3 (Servidor Novo)

```bash
# Instalar Coolify e VPS Guardian (ver Método 1, Passo 1)

# Instalar AWS CLI
apt install awscli -y

# Configurar mesmas credenciais S3

# Download
cd /tmp
aws s3 cp s3://migracao-coolify/backups/20241209_153045.tar.gz .

# Restaurar (mesmos passos do Método 2, Passo 3)
```

---

## Pós-Migração

### Validação

```bash
# Checklist
- [ ] Coolify web acessível
- [ ] Todas as aplicações listadas
- [ ] Banco de dados respondendo
- [ ] SSH keys presentes
- [ ] Deploy de teste funciona
- [ ] Certificados SSL funcionando

# Validar via script
sudo /opt/vpsguardian/scripts-auxiliares/validar-pos-migracao.sh
```

### Monitorar (Primeiros 7 Dias)

```bash
# Verificar logs
docker logs coolify | grep -i error

# Verificar recursos
df -h
free -h

# Verificar aplicações via Coolify dashboard
```

### Configurar Backups

```bash
vps-guardian
# → 5 (Configuração)
# → 1 (Cron)

# Configurar:
# - Backup diário às 2h
# - Backup semanal S3 às 3h
# - Limpeza semanal às 4h
```

---

## Troubleshooting

### Erro ao Conectar no Banco

```bash
docker ps | grep coolify-db
docker logs coolify-db
docker exec coolify-db psql -U coolify -d coolify -c "SELECT 1;"

# Se falhar, restaurar banco novamente
cat /tmp/backup.dmp | docker exec -i coolify-db \
  pg_restore --verbose --clean --no-acl --no-owner -U coolify -d coolify
```

### Aplicações Não Aparecem

```bash
# Verificar banco
docker exec coolify-db psql -U coolify -d coolify \
  -c "SELECT id, name FROM applications LIMIT 5;"

# Se vazio, restaurar banco
# (ver erro anterior)

# Limpar cache browser: Ctrl+Shift+R
```

### SSH Keys Não Funcionam

```bash
# Verificar permissões
ls -lh /data/coolify/ssh/keys/

# Deve ser 9999:9999
chown -R 9999:9999 /data/coolify/ssh/keys
chmod 700 /data/coolify/ssh/keys
chmod 600 /data/coolify/ssh/keys/*

# Reiniciar
docker restart coolify
```

### SSL/Certificados Inválidos

```bash
# Aguardar DNS propagar
dig seu-dominio.com +short

# Renovar no Coolify
# Dashboard → Server → SSL → Renew All

# Ou deletar e recriar
# Dashboard → Application → Settings → SSL → Delete & Recreate
```

---

## Checklist Pós-Migração

**Antes de Destruir Servidor Antigo:**
- [ ] Migração validada completamente
- [ ] Todas as aplicações funcionando
- [ ] DNS atualizado e propagado
- [ ] Backup do servidor antigo em local seguro
- [ ] Novo servidor rodando por 7+ dias
- [ ] Backups automáticos configurados
- [ ] Monitoramento ativo

**Após 7 Dias:**
- [ ] Sem erros críticos
- [ ] Performance aceitável
- [ ] Aplicações estáveis
- [ ] Webhooks e deploys funcionando

**Só então:**
- [ ] Fazer snapshot do servidor novo
- [ ] Destruir servidor antigo
- [ ] Deletar backups temporários

---

## Resumo Rápido

```bash
# SERVIDOR NOVO: Instalar Coolify
curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash

# SERVIDOR ANTIGO: Migrar
vps-guardian
# → 4 (Migração) → 1

# SERVIDOR NOVO: Validar
vps-guardian status

# Atualizar DNS se necessário
```

**Tempo Total:** 30min-2h | **Downtime:** Sim | **Dificuldade:** Fácil/Médio

---

**Logs:** `/var/log/vpsguardian/`
**Validação:** `sudo /opt/vpsguardian/scripts-auxiliares/validar-pos-migracao.sh`
**Status:** `vps-guardian status`
