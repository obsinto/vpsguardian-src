# ⚡ Guia Rápido - VPS Guardian

Comandos essenciais para começar a usar o VPS Guardian imediatamente.

---

## 🚀 Instalação (2 minutos)

```bash
cd /opt
git clone <seu-repo> vpsguardian
cd vpsguardian
sudo ./instalar.sh
```

**Pronto!** Comando global `vps-guardian` instalado.

---

## 📦 Backup Rápido

### Backup Completo do Coolify
```bash
sudo /opt/vpsguardian/backup/backup-coolify.sh
```
**Output:** `/var/backups/vpsguardian/coolify/YYYYMMDD_HHMMSS.tar.gz`

### Backup de Bancos de Dados
```bash
sudo /opt/vpsguardian/backup/backup-databases-dump-auto.sh --dest=local
```
Use `--project=NOME` para limitar o backup a um projeto.

### Backup de Volume Específico
```bash
sudo /opt/vpsguardian/backup/backup-volume-interativo.sh
```
Interativo - selecione volumes Docker.

---

## 🔄 Migração Rápida (3 comandos)

### 1. Criar Backup no Servidor Antigo
```bash
sudo /opt/vpsguardian/backup/backup-coolify.sh
```

### 2. Validar Ambiente Antes de Migrar
```bash
sudo /opt/vpsguardian/scripts-auxiliares/validar-pre-migracao.sh
```

### 3. Migrar para Novo Servidor
```bash
sudo /opt/vpsguardian/migrar/migrar-coolify.sh
```
**Siga o assistente interativo**:
- IP do servidor destino
- Credenciais SSH
- Selecione backup
- Confirme e aguarde 10-15min

### 4. Validar Migração (Opcional mas Recomendado)
```bash
sudo /opt/vpsguardian/scripts-auxiliares/validar-pos-migracao.sh --remote <IP-NOVO-SERVIDOR>
```

---

## 🔧 Manutenção Rápida

### Verificar Saúde do Servidor
```bash
sudo /opt/vpsguardian/manutencao/verificar-saude-completa.sh
```
Score geral + detalhes de Docker, Coolify, recursos.

### Limpeza e Manutenção Completa
```bash
sudo /opt/vpsguardian/manutencao/manutencao-completa.sh
```
Limpa logs, remove containers/imagens órfãs, libera espaço.

### Configurar Firewall Seguro
```bash
sudo /opt/vpsguardian/manutencao/firewall-perfil-padrao.sh
```
Permite apenas: SSH (22), HTTP (80), HTTPS (443), Coolify (8000).

### Ativar Updates Automáticos de Segurança
```bash
sudo /opt/vpsguardian/manutencao/configurar-updates-automaticos.sh
```

---

## ⏰ Automatizar Backups (Cron)

### Método 1: Assistente Interativo
```bash
sudo /opt/vpsguardian/scripts-auxiliares/configurar-cron.sh
```

### Método 2: Manual
```bash
sudo crontab -e
```

**Adicionar:**
```bash
# Backup diário do Coolify às 2h
0 2 * * * /opt/vpsguardian/backup/backup-coolify.sh

# Backup semanal de DBs (domingo, 3h)
0 3 * * 0 /opt/vpsguardian/backup/backup-databases-dump-auto.sh --dest=local

# Manutenção mensal (dia 1, 4h)
0 4 1 * * /opt/vpsguardian/manutencao/manutencao-completa.sh

# Verificação de saúde diária (8h)
0 8 * * * /opt/vpsguardian/manutencao/verificar-saude-completa.sh
```

---

## 📂 Locais Importantes

### Backups
```bash
ls -lh /var/backups/vpsguardian/coolify/
ls -lh /var/backups/vpsguardian/databases/
ls -lh /var/backups/vpsguardian/volumes/
```

### Logs
```bash
tail -f /var/log/vpsguardian/backup-coolify.log
tail -f /var/log/vpsguardian/migration-agent.log
ls /var/log/vpsguardian/
```

### Configuração
```bash
nano /opt/vpsguardian/config/default.conf
```

---

## 🔍 Troubleshooting Rápido

### Verificar Status Docker
```bash
sudo systemctl status docker
sudo docker ps
```

### Verificar Coolify
```bash
sudo docker ps | grep coolify
sudo docker logs coolify
```

### Verificar Espaço em Disco
```bash
df -h /
df -h /var/backups
```

### Ver Últimos Backups
```bash
ls -lht /var/backups/vpsguardian/coolify/ | head -5
```

### Testar Conectividade SSH (para migração)
```bash
ssh -p 22 root@<IP-DESTINO> "echo 'Conexão OK'"
```

---

## 📊 Comandos Úteis

### Listar Todos os Volumes Docker
```bash
docker volume ls
```

### Listar Containers de Banco de Dados
```bash
docker ps --format '{{.Names}}' | grep -E 'db|postgres|mysql|mariadb'
```

### Ver Tamanho dos Backups
```bash
du -sh /var/backups/vpsguardian/*
```

### Limpar Backups Antigos Manualmente
```bash
# Remover backups com mais de 60 dias
find /var/backups/vpsguardian/coolify/ -name "*.tar.gz" -mtime +60 -delete
```

### Verificar Cron Jobs Configurados
```bash
sudo crontab -l | grep vpsguardian
```

---

## 🎯 Workflows Comuns

### Workflow 1: Backup Regular
```bash
# 1. Fazer backup
sudo /opt/vpsguardian/backup/backup-coolify.sh

# 2. Verificar backup criado
ls -lh /var/backups/vpsguardian/coolify/

# 3. (Opcional) Copiar para local seguro
scp /var/backups/vpsguardian/coolify/LATEST.tar.gz user@backup-server:/backups/
```

### Workflow 2: Migração Completa
```bash
# No servidor ANTIGO:
sudo /opt/vpsguardian/backup/backup-coolify.sh
sudo /opt/vpsguardian/scripts-auxiliares/validar-pre-migracao.sh

# No servidor ANTIGO (migra para novo):
sudo /opt/vpsguardian/migrar/migrar-coolify.sh

# Após migração (validar no novo):
sudo /opt/vpsguardian/scripts-auxiliares/validar-pos-migracao.sh --remote <NOVO-IP>

# Acessar Coolify no novo servidor:
# http://<NOVO-IP>:8000
```

### Workflow 3: Manutenção Mensal
```bash
# 1. Verificar saúde
sudo /opt/vpsguardian/manutencao/verificar-saude-completa.sh

# 2. Fazer backup antes de qualquer coisa
sudo /opt/vpsguardian/backup/backup-coolify.sh

# 3. Executar manutenção
sudo /opt/vpsguardian/manutencao/manutencao-completa.sh

# 4. Verificar espaço liberado
df -h /
```

### Workflow 4: Restauração de Emergência
```bash
# Se Coolify caiu e precisa restaurar:

# 1. Listar backups disponíveis
ls -lht /var/backups/vpsguardian/coolify/

# 2. Restaurar localmente (se mesmo servidor)
sudo /opt/vpsguardian/backup/restaurar-coolify-remoto.sh
# Selecione localhost ou 127.0.0.1

# 3. OU restaurar em servidor novo
sudo /opt/vpsguardian/migrar/migrar-coolify.sh
```

---

## 🆘 Comandos de Emergência

### Coolify Não Inicia
```bash
# 1. Ver logs
docker logs coolify
docker logs coolify-db

# 2. Reiniciar containers
cd /data/coolify/source
docker compose restart

# 3. Se ainda não funcionar, reinstalar
curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash
```

### Espaço em Disco Cheio
```bash
# 1. Ver o que está ocupando
du -sh /* | sort -h

# 2. Limpar Docker
docker system prune -af --volumes

# 3. Limpar logs
sudo journalctl --vacuum-time=7d

# 4. Remover backups antigos
find /var/backups/vpsguardian/ -mtime +30 -delete
```

### Backup Corrompido
```bash
# Verificar integridade do backup
tar -tzf /var/backups/vpsguardian/coolify/BACKUP.tar.gz > /dev/null

# Se erro, usar backup anterior
ls -lht /var/backups/vpsguardian/coolify/ | head -5
```

---

## 📚 Documentação Completa

- **Instalação Detalhada:** [`INSTALACAO.md`](./INSTALACAO.md)
- **Uso de Todos os Scripts:** [`USO-SCRIPTS.md`](./USO-SCRIPTS.md)
- **README Principal:** [`../README.md`](../README.md)

---

## ✅ Checklist de Segurança

- [ ] Backups automáticos configurados (cron)
- [ ] Backups testados (restauração em ambiente de teste)
- [ ] Backups off-site (outro servidor ou cloud)
- [ ] Firewall configurado e ativo
- [ ] Updates automáticos de segurança ativados
- [ ] Monitoramento de saúde diário
- [ ] SSH com chave (sem senha)
- [ ] Logs monitorados

---

**🚀 VPS Guardian - Seu servidor protegido em minutos!**
