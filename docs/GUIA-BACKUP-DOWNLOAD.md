# Guia Completo: Backup Automático + Deploy em Nova Máquina

> Como configurar backups automáticos e restaurar tudo em outro servidor
2->11
---
  ---
  1. Google Drive (rclone)

  Execute:

  rclone config

  Siga os passos:
  n) New remote
  name> gdrive
  Storage> drive
  client_id> (deixe vazio, Enter)
  client_secret> (deixe vazio, Enter)
  scope> 1 (Full access)
  root_folder_id> (deixe vazio, Enter)
  service_account_file> (deixe vazio, Enter)
  Edit advanced config> n
  Use auto config> n (você está em servidor remoto)

  Vai aparecer um link. Abra no seu navegador, faça login no Google, autorize, e cole o código de volta no terminal.

  Configure as a team drive> n
  y) Yes this is OK
  q) Quit config

  Teste:
  rclone lsd gdrive:

  ---
  2. Cloudflare R2 (compatível S3)

  No painel da Cloudflare:
  1. R2 → Seu bucket → Manage R2 API Tokens
  2. Crie um token com permissão Edit
  3. Copie: Access Key ID e Secret Access Key
  4. Copie o endpoint (ex: https://<account_id>.r2.cloudflarestorage.com)

  Agora configure o AWS CLI:

  aws configure

  AWS Access Key ID: <sua_access_key_do_R2>
  AWS Secret Access Key: <sua_secret_key_do_R2>
  Default region name: auto
  Default output format: json

  Teste a conexão com R2:
  aws s3 ls --endpoint-url https://<ACCOUNT_ID>.r2.cloudflarestorage.com

  ---
 
## PARTE 1: Configurar Backups Automáticos

### Passo 1.1: Acessar o Menu

```bash
sudo vps-guardian
```

### Passo 1.2: Configurar Cron (Agendamento)

```
Menu Principal → 5 (Configuração) → 1 (Configurar Tarefas Agendadas)
```

O script irá perguntar interativamente:

#### Backup de Bancos de Dados (Dumps SQL)
```
Habilitar backup automático de bancos? (Y/n): Y
Frequência (daily/weekly): daily
Horário (HH:MM): 01:00
```

#### Backup do Coolify (Configurações)
```
Dia da semana (0=Domingo): 0
Horário (HH:MM): 02:00
```

#### Backup de Volumes (Dados das Apps)
```
Habilitar backup de volumes? (Y/n): Y
Frequência (daily/weekly): weekly
Dia da semana: 0
Horário: 01:00
```

#### Manutenção Preventiva
```
Dia da semana (1=Segunda): 1
Horário: 03:00
```

#### Alerta de Disco
```
Horário: 09:00
```

#### Upload Automático (Opcional)
```
Enviar para destino remoto? (y/N): y
Destino: 1 (SSH), 2 (Google Drive), 3 (S3), 4 (Todos)
Delay após backup: 1 hora
```

#### Limpeza Automática (Retenção)
```
Habilitar limpeza? (Y/n): Y
Estratégia: 1 (GFS - Recomendado)
```

### Passo 1.3: Verificar Cron Configurado

```bash
sudo crontab -l
```

Deve mostrar algo como:
```
# Backup automático de bancos de dados (diário às 01:00)
0 1 * * * /opt/vpsguardian/backup-databases.sh >> /var/log/manutencao/cron-db-backup.log 2>&1

# Backup de volumes das aplicações (semanal)
0 1 * * 0 /opt/vpsguardian/migrar/backup-database-volumes.sh >> /var/log/manutencao/cron-volumes-backup.log 2>&1

# Backup completo do Coolify (semanal às 02:00)
0 2 * * 0 /opt/vpsguardian/backup-coolify.sh >> /var/log/manutencao/cron-backup.log 2>&1
```

---

## PARTE 2: Onde Ficam os Backups

| Tipo | Caminho | Conteúdo |
|------|---------|----------|
| Coolify | `/var/backups/vpsguardian/coolify/*.tar.gz` | DB + SSH + .env + configs |
| Databases | `/var/backups/vpsguardian/databases/lote-*/` | Dumps SQL de todas as apps |
| Volumes | `/var/backups/vpsguardian/volumes/*.tar.gz` | Dados dos volumes Docker |

### Verificar Backups Existentes

```bash
# Ver todos os backups
ls -lah /var/backups/vpsguardian/*/

# Ver tamanho total
du -sh /var/backups/vpsguardian/*

# Ver logs dos backups automáticos
tail -50 /var/log/manutencao/cron-backup.log
tail -50 /var/log/manutencao/cron-db-backup.log
```

---

## PARTE 3: Baixar Backups para Máquina Pessoal

Na sua **máquina local**, execute:

```bash
# Criar pasta local
mkdir -p ~/backups-vps

# Baixar tudo
rsync -avz --progress root@IP_DO_SERVIDOR:/var/backups/vpsguardian/ ~/backups-vps/

# OU usando scp
scp -r root@IP_DO_SERVIDOR:/var/backups/vpsguardian/* ~/backups-vps/
```

---

## PARTE 4: Deploy em Nova Máquina

### Passo 4.1: Preparar o Novo Servidor

No **novo servidor**, instale o Coolify:

```bash
curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash
```

Aguarde a instalação completar e acesse `http://NOVO_IP:8000` para fazer o setup inicial.

### Passo 4.2: Instalar VPS Guardian no Novo Servidor

```bash
cd /usr/local/src
sudo git clone https://github.com/SEU-USUARIO/vpsguardian.git
cd vpsguardian
sudo ./instalar.sh
```

### Passo 4.3: Transferir Backups para o Novo Servidor

Da sua **máquina local**:

```bash
# Transferir backups
rsync -avz --progress ~/backups-vps/ root@NOVO_IP:/var/backups/vpsguardian/
```

Ou diretamente entre servidores (do **servidor antigo**):

```bash
rsync -avz --progress /var/backups/vpsguardian/ root@NOVO_IP:/var/backups/vpsguardian/
```

### Passo 4.4: Restaurar no Novo Servidor

No **novo servidor**:

```bash
sudo vps-guardian
```

#### Opção A: Restauração Completa (Coolify + Volumes)

```
Menu Principal → 2 (Backups) → 7 (Restaurar de Backup Local)
→ Escolha: 1 (Coolify completo)
→ Digite 'CONFIRMO'
→ Selecione o backup mais recente [0]
```

#### Opção B: Restaurar Apenas os Dumps SQL (Recomendado)

Depois de restaurar o Coolify, restaure os bancos das aplicações:

```
Menu Principal → 2 (Backups) → 9 (Restaurar Dumps SQL de Bancos)
→ Escolha: 1 (Backup local)
→ Escolha: 1 (/var/backups/vpsguardian/databases)
→ Digite 'SIM'
→ Selecione o lote mais recente [0]
→ Escolha: 2 (Restaurar TODOS EXCETO Coolify) ← RECOMENDADO
```

### Passo 4.5: Validar Restauração

```
Menu Principal → 2 (Backups) → 10 (Validar Saúde dos Bancos)
```

---

## PARTE 5: Pós-Restauração

### Checklist Obrigatório

1. **Acessar Coolify**: `http://NOVO_IP:8000`
2. **Verificar aplicações**: Todas devem aparecer no dashboard
3. **Fazer DEPLOY de cada aplicação**:
   - Os dados estão restaurados, mas os containers precisam ser recriados
   - Clique em cada app → Deploy
4. **Atualizar DNS**: Apontar domínios para o novo IP
5. **Renovar SSL**: Certificados podem precisar ser renovados

### Comandos Úteis de Verificação

```bash
# Ver containers rodando
docker ps

# Ver logs do Coolify
docker logs coolify -f

# Verificar banco do Coolify
docker exec coolify-db psql -U coolify -d coolify -c "SELECT COUNT(*) FROM applications;"

# Ver logs de restauração
tail -100 /var/log/vpsguardian/*.log
```

---

## Resumo Visual do Fluxo

```
┌─────────────────────────────────────────────────────────────────┐
│                    SERVIDOR ANTIGO                              │
├─────────────────────────────────────────────────────────────────┤
│  1. Configurar Cron (Menu 5 → 1)                                │
│     ↓                                                           │
│  2. Backups Automáticos (diário/semanal)                        │
│     • /var/backups/vpsguardian/coolify/                         │
│     • /var/backups/vpsguardian/databases/                       │
│     • /var/backups/vpsguardian/volumes/                         │
│     ↓                                                           │
│  3. rsync para máquina local ou novo servidor                   │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│                    SERVIDOR NOVO                                │
├─────────────────────────────────────────────────────────────────┤
│  4. Instalar Coolify                                            │
│     curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash│
│     ↓                                                           │
│  5. Instalar VPS Guardian                                       │
│     ↓                                                           │
│  6. Transferir backups (rsync/scp)                              │
│     ↓                                                           │
│  7. Restaurar (Menu 2 → 7 → Coolify completo)                   │
│     ↓                                                           │
│  8. Restaurar dumps (Menu 2 → 9 → Tudo exceto Coolify)          │
│     ↓                                                           │
│  9. Validar (Menu 2 → 10)                                       │
│     ↓                                                           │
│  10. Deploy de cada aplicação no dashboard                      │
│     ↓                                                           │
│  11. Atualizar DNS                                              │
└─────────────────────────────────────────────────────────────────┘
```

---

## Estratégias de Retenção (GFS Recomendado)

| Estratégia | Descrição |
|------------|-----------|
| **GFS** | 7 diários + 4 semanais + 12 mensais (Recomendado) |
| Simple | Deleta backups mais antigos que X dias |
| Count | Mantém apenas os últimos X backups |

---

## Troubleshooting

### Backup não está sendo criado

```bash
# Verificar se cron está ativo
systemctl status cron

# Ver últimas execuções
grep CRON /var/log/syslog | tail -20

# Executar manualmente para testar
/opt/vpsguardian/backup-coolify.sh
```

### Container offline durante restore

O script de restore detecta containers offline e avisa. Para resolver:

1. Acesse o Coolify (`http://IP:8000`)
2. Inicie a aplicação correspondente
3. Execute o restore novamente

### Erro de permissão

```bash
# Verificar permissões
ls -la /var/backups/vpsguardian/

# Corrigir se necessário
sudo chown -R root:root /var/backups/vpsguardian/
sudo chmod 700 /var/backups/vpsguardian/
```
