# Guia Completo: Backup Automático + Deploy em Nova Máquina

> Configurar backups automáticos completos (Coolify + Bancos de Dados) e restaurar em outro servidor

---

## Entendendo os Tipos de Backup

| Tipo | O que salva | Script | Frequência Recomendada |
|------|-------------|--------|------------------------|
| **Backup Coolify** | SSH keys, .env, APP_KEY, certificados SSL, configs | `backup-coolify.sh` | Semanal |
| **Backup Dumps SQL** | Dados dos bancos (MySQL, PostgreSQL, MongoDB) | `backup-databases-dump-auto.sh` | Diário |
| **Backup Volumes** | Arquivos/dados dentro dos volumes Docker | `backup-database-volumes.sh` | Semanal |

**IMPORTANTE:** Para uma migração completa você precisa dos **3 tipos de backup**!

---

## PARTE 1: Pré-requisitos (Instalar Ferramentas)

### 1.1 Instalar rclone (para Google Drive)

```bash
curl https://rclone.org/install.sh | sudo bash
```

### 1.2 Instalar AWS CLI v2 (para Cloudflare R2 / S3)

```bash
sudo apt update && sudo apt install unzip -y
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip && sudo ./aws/install
rm -rf awscliv2.zip aws/
```

Verificar instalação:
```bash
rclone version
aws --version
```

---

## PARTE 2: Configurar Destinos de Backup

### 2.1 Google Drive (rclone)

No servidor, execute:
```bash
rclone config
```

Siga os passos:
```
n) New remote
name> gdrive
Storage> drive
client_id> (Enter - deixe vazio)
client_secret> (Enter - deixe vazio)
scope> 1 (Full access)
service_account_file> (Enter - deixe vazio)
Edit advanced config> n
Use auto config> n
```

Vai aparecer uma mensagem pedindo para executar na sua máquina local:
```
rclone authorize "drive"
```

**Na sua máquina local** (com navegador):
```bash
rclone authorize "drive"
```

Vai abrir o navegador, faça login no Google, autorize. Copie o token JSON que aparece e cole no servidor.

```
Configure as a Shared Drive (Team Drive)> n
y) Yes this is OK
q) Quit config
```

Testar:
```bash
rclone lsd gdrive:
```

### 2.2 Cloudflare R2 (compatível S3)

**No painel da Cloudflare:**
1. **R2 Object Storage** → **Manage R2 API Tokens**
2. **Create API Token**
3. Permissão: **Object Read & Write**
4. Anote: **Access Key ID** e **Secret Access Key**
5. Anote seu **Account ID** (na URL ou página R2)

**No servidor:**
```bash
aws configure
```

```
AWS Access Key ID: <sua_access_key_do_R2>
AWS Secret Access Key: <sua_secret_key_do_R2>
Default region name: auto
Default output format: json
```

Testar:
```bash
aws s3 ls --endpoint-url https://<ACCOUNT_ID>.r2.cloudflarestorage.com
```

---

## PARTE 3: Configurar Destinos no VPS Guardian

```bash
sudo vps-guardian
```

```
Menu Principal → 2 (Backups) → 11 (Configurar Destinos de Backup)
```

Responda as perguntas:

| Pergunta | Resposta Sugerida |
|----------|-------------------|
| Backup Local? | Y |
| Retenção local | 30 dias |
| SSH? | N (ou Y se tiver servidor próprio) |
| Google Drive? | Y |
| Remote name | gdrive |
| Pasta no Drive | backups/vpsguardian |
| AWS S3? | Y |
| Bucket | seu-bucket |
| Prefixo | databases |
| Região | auto |
| Storage Class | STANDARD_IA |
| Endpoint (R2) | `https://<ACCOUNT_ID>.r2.cloudflarestorage.com` |
| Incluir coolify-db? | Y |

---

## PARTE 4: Configurar Backups Automáticos (Cron)

```bash
sudo vps-guardian
```

```
Menu Principal → 5 (Configuração) → 1 (Configurar Tarefas Agendadas)
```

### Configuração Recomendada:

| Tipo | Frequência | Horário | Dia |
|------|------------|---------|-----|
| Backup de Bancos (Dumps) | Diário | 01:00 | - |
| Backup de Volumes | Semanal | 01:30 | Domingo (0) |
| Backup Coolify (configs) | Semanal | 02:00 | Domingo (0) |
| Manutenção Preventiva | Semanal | 03:00 | Domingo (0) |
| Alerta de Disco | Diário | 09:00 | - |
| Upload Automático | Após backup | 1h delay | - |
| Limpeza (GFS) | Semanal | 04:00 | Domingo (0) |

### Verificar Cron Configurado:

```bash
sudo crontab -l
```

---

## PARTE 5: Onde Ficam os Backups

| Tipo | Local | Remoto |
|------|-------|--------|
| Coolify (configs) | `/var/backups/vpsguardian/coolify/*.tar.gz` | gdrive:backups/vpsguardian/ |
| Databases (dumps) | `/var/backups/vpsguardian/databases/lote-*/` | R2: databases/ |
| Volumes | `/var/backups/vpsguardian/volumes/*.tar.gz` | gdrive:backups/vpsguardian/ |

### Verificar Backups:

```bash
# Ver backups locais
ls -lah /var/backups/vpsguardian/*/

# Ver tamanho total
du -sh /var/backups/vpsguardian/*

# Ver backups no Google Drive
rclone lsd gdrive:backups/vpsguardian/

# Ver backups no R2
aws s3 ls s3://vps-guardian/databases/ --endpoint-url https://<ACCOUNT_ID>.r2.cloudflarestorage.com
```

---

## PARTE 6: Backup Manual (Teste)

### Backup Completo do Coolify (SSH keys, .env, configs):
```bash
sudo /opt/vpsguardian/backup/backup-coolify.sh
```

### Backup de Todos os Bancos de Dados:
```bash
sudo /opt/vpsguardian/backup/backup-databases-dump-auto.sh --dest=local
```

### Backup + Upload para Nuvem:
```bash
# Para Google Drive
sudo /opt/vpsguardian/backup/backup-databases-dump-auto.sh --dest=google-drive

# Para R2/S3
sudo /opt/vpsguardian/backup/backup-databases-dump-auto.sh --dest=aws-s3

# Para todos os destinos
sudo /opt/vpsguardian/backup/backup-databases-dump-auto.sh --dest=all
```

---

## PARTE 7: Baixar Backups para Máquina Pessoal

Na sua **máquina local**:

```bash
# Criar pasta local
mkdir -p ~/backups-vps

# Baixar do servidor via rsync
rsync -avz --progress root@IP_DO_SERVIDOR:/var/backups/vpsguardian/ ~/backups-vps/

# OU baixar do Google Drive
rclone copy gdrive:backups/vpsguardian/ ~/backups-vps/ --progress

# OU baixar do R2
aws s3 sync s3://vps-guardian/ ~/backups-vps/ --endpoint-url https://<ACCOUNT_ID>.r2.cloudflarestorage.com
```

---

## PARTE 8: Deploy em Nova Máquina

### 8.1 Preparar Novo Servidor

```bash
# Instalar Coolify
curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash
```

Acesse `http://NOVO_IP:8000` e complete o setup inicial.

### 8.2 Instalar VPS Guardian

```bash
cd /usr/local/src
git clone https://github.com/SEU-USUARIO/vpsguardian.git
cd vpsguardian
sudo ./instalar.sh
```

### 8.3 Transferir Backups

```bash
# Do servidor antigo para o novo
rsync -avz --progress /var/backups/vpsguardian/ root@NOVO_IP:/var/backups/vpsguardian/

# OU da sua máquina local
rsync -avz --progress ~/backups-vps/ root@NOVO_IP:/var/backups/vpsguardian/

# OU baixar direto do Google Drive no novo servidor
rclone copy gdrive:backups/vpsguardian/ /var/backups/vpsguardian/ --progress
```

### 8.4 Restaurar Coolify (Configs + SSH Keys)

```bash
sudo vps-guardian
```

```
Menu Principal → 2 (Backups) → 7 (Restaurar de Backup Local)
→ Selecione o backup do Coolify
→ Digite 'CONFIRMO'
```

### 8.5 Restaurar Bancos de Dados

```
Menu Principal → 2 (Backups) → 9 (Restaurar Dumps SQL de Bancos)
→ Selecione o lote mais recente
→ Escolha: 2 (Restaurar TODOS EXCETO Coolify)
```

### 8.6 Validar Restauração

```
Menu Principal → 2 (Backups) → 10 (Validar Saúde dos Bancos)
```

---

## PARTE 9: Pós-Restauração (Checklist)

1. **Acessar Coolify:** `http://NOVO_IP:8000`
2. **Verificar aplicações:** Todas devem aparecer no dashboard
3. **Deploy de cada app:** Clique em cada aplicação → Deploy
4. **Atualizar DNS:** Apontar domínios para o novo IP
5. **Renovar SSL:** Certificados serão renovados automaticamente após DNS

### Verificações:

```bash
# Ver containers rodando
docker ps

# Verificar banco do Coolify
docker exec coolify-db psql -U coolify -d coolify -c "SELECT COUNT(*) FROM applications;"

# Ver logs
tail -100 /var/log/vpsguardian/*.log
```

---

## Resumo Visual

```
SERVIDOR ANTIGO
┌────────────────────────────────────────────────────────────┐
│  Backup Coolify (semanal)                                  │
│    └─► /var/backups/vpsguardian/coolify/*.tar.gz           │
│        (SSH keys, .env, certificados, configs)             │
│                                                            │
│  Backup Dumps SQL (diário)                                 │
│    └─► /var/backups/vpsguardian/databases/lote-*/          │
│        (MySQL, PostgreSQL, MongoDB - dados das apps)       │
│                                                            │
│  Upload Automático                                         │
│    └─► Google Drive: gdrive:backups/vpsguardian/           │
│    └─► Cloudflare R2: s3://vps-guardian/databases/         │
└────────────────────────────────────────────────────────────┘
                           │
                           ▼
SERVIDOR NOVO
┌────────────────────────────────────────────────────────────┐
│  1. Instalar Coolify                                       │
│  2. Instalar VPS Guardian                                  │
│  3. Baixar backups (rsync/rclone/aws s3)                   │
│  4. Restaurar Coolify (Menu 2 → 7)                         │
│  5. Restaurar Dumps (Menu 2 → 9)                           │
│  6. Validar (Menu 2 → 10)                                  │
│  7. Deploy de cada aplicação                               │
│  8. Atualizar DNS                                          │
└────────────────────────────────────────────────────────────┘
```

---

## Troubleshooting

### Erro de upload S3/R2

Verifique se o endpoint está configurado:
```bash
cat /opt/vpsguardian/config/backup-destinations.conf | grep S3_ENDPOINT
```

Teste manualmente:
```bash
aws s3 ls s3://seu-bucket/ --endpoint-url https://<ACCOUNT_ID>.r2.cloudflarestorage.com
```

### Backup não está rodando no cron

```bash
# Verificar cron
systemctl status cron
sudo crontab -l

# Ver logs
tail -50 /var/log/vpsguardian/cron-backup.log
grep CRON /var/log/syslog | tail -20

# Testar manualmente
/opt/vpsguardian/backup/backup-coolify.sh
```

### Container offline durante restore

1. Acesse Coolify (`http://IP:8000`)
2. Inicie a aplicação correspondente
3. Execute o restore novamente

### Webhook Discord não funciona

O formato do webhook deve ser:
```
https://discord.com/api/webhooks/ID/TOKEN
```

Não funciona com URLs do tipo `https://discordapp.com/...`
