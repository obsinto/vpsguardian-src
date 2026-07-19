# 🔄 Guia Completo de Restauração - VPS Guardian

## 🎯 Visão Geral

O VPS Guardian oferece **restauração automatizada completa** com um único comando.

---

## 📋 Scripts de Restauração Disponíveis

| Script | Propósito | Quando Usar |
|--------|-----------|-------------|
| **`restaurar-completo.sh`** | Restaura TUDO (Coolify + Volumes) | ⭐ Use este! |
| `restaurar-coolify-remoto.sh` | Restaura apenas Coolify | Casos específicos |
| `restore-database-volumes.sh` | Restaura apenas volumes | Casos específicos |

---

## 🚀 Restauração Completa (Recomendado)

### Cenário 1: Restauração Local (Desastre no Mesmo Servidor)

**Quando usar**: Servidor atual teve problema, quer restaurar de backup.

```bash
cd /opt/vpsguardian
sudo ./backup/restaurar-completo.sh --local
```

**O que faz**:
1. ✅ Lista backups disponíveis
2. ✅ Você escolhe qual restaurar (ou usa o mais recente)
3. ✅ Restaura Coolify (banco, configs, SSH keys)
4. ✅ Restaura volumes (dados das aplicações)
5. ✅ Valida restauração
6. ✅ Relatório final

**Tempo estimado**: 10-30 minutos

---

### Cenário 2: Migração para Novo Servidor

**Quando usar**: Quer mover tudo para um servidor novo.

#### Opção A: Modo Interativo (Recomendado)

```bash
# No servidor ANTIGO (onde estão os backups)
cd /opt/vpsguardian
sudo ./backup/restaurar-completo.sh --remote
```

**Perguntas que vai fazer**:
```
IP do novo servidor: 192.168.1.100
Usuário SSH (padrão: root): root
Porta SSH (padrão: 22): 22
```

#### Opção B: Modo Automático (Scriptável)

```bash
sudo ./backup/restaurar-completo.sh \
  --remote \
  --ip=192.168.1.100 \
  --user=root \
  --port=22
```

**O que faz**:
1. ✅ Testa conexão SSH com novo servidor
2. ✅ Transfere backups para novo servidor
3. ✅ Instala Coolify no novo servidor (se necessário)
4. ✅ Restaura tudo remotamente
5. ✅ Valida restauração
6. ✅ Relatório final

**Tempo estimado**: 30min-2h (depende do tamanho dos dados)

---

## 📊 Exemplo de Execução (Modo Local)

```bash
$ sudo ./backup/restaurar-completo.sh --local

╔════════════════════════════════════════════════════════════════╗
║         VPS Guardian - Restauração Completa v2.0               ║
╚════════════════════════════════════════════════════════════════╝

Modo: LOCAL

========== Restauração Local ==========

Este modo restaura backups NESTE servidor
⚠️  ATENÇÃO: Dados atuais serão SUBSTITUÍDOS!

Continuar? (digite 'CONFIRMO' para prosseguir): CONFIRMO

========== Step 1/4: Verificar Backups Disponíveis ==========

✓ 5 backup(s) do Coolify encontrados
✓ 12 backup(s) de volumes encontrados

========== Step 2/4: Selecionar Backup do Coolify ==========

Backups disponíveis:

  [0] coolify-backup-20260202_020000.tar.gz
      Data: 2026-02-02 02:00:00 | Tamanho: 156M

  [1] coolify-backup-20260126_020000.tar.gz
      Data: 2026-01-26 02:00:00 | Tamanho: 142M

Selecione o número do backup (Enter = mais recente):

✓ Selecionado: coolify-backup-20260202_020000.tar.gz

========== Step 3/4: Restaurar Coolify (Configurações) ==========

→ Parando containers do Coolify...
→ Extraindo backup...
→ Restaurando banco de dados do Coolify...
✓ Banco de dados restaurado
→ Restaurando SSH keys...
✓ SSH keys restauradas
→ Restaurando configurações (.env)...
✓ Configurações restauradas
→ Reiniciando Coolify...
✓ Coolify restaurado!

========== Step 4/4: Restaurar Volumes das Aplicações ==========

→ Encontrados 12 volumes para restaurar
→ Restaurando: app-wordpress-abc123-data
  → Tentando restore de volume...
  → Container iniciou OK
  ✅ Volume restaurado e validado

→ Restaurando: app-nodejs-api-xyz789-data
  → Tentando restore de volume...
  → Crash loop detectado!
  → Fallback para SQL dump...
  ✅ Restaurado de SQL dump

... (continua para todos os volumes)

✓ Volumes restaurados!

========== Validação Pós-Restauração ==========

✓ Coolify está rodando
✓ Banco de dados está saudável
✓ 8 aplicações encontradas no Coolify
✓ Bancos de dados validados

========== RESTAURAÇÃO COMPLETA ==========

✅ Coolify restaurado
✅ 12 volumes restaurados
✅ Validação pós-restauração concluída

📍 Acesse: http://localhost:8000

⚠️  PRÓXIMOS PASSOS:
   1. Acesse o Coolify (http://localhost:8000)
   2. Verifique se todas as aplicações aparecem (8 apps esperadas)
   3. Faça DEPLOY de cada aplicação
   4. Teste cada aplicação individualmente

✓ Restauração local concluída com sucesso!
```

---

## 🔍 Restauração de Componentes Específicos

### Apenas Coolify (Configurações)

```bash
./backup/restaurar-coolify-remoto.sh
```

### Apenas Volumes (Dados)

```bash
export BACKUP_DIR=/var/backups/vpsguardian/volumes
./migrar/restore-database-volumes.sh
```

### Apenas Uma Aplicação Específica

```bash
# Listar volumes disponíveis
ls -lh /var/backups/vpsguardian/volumes/

# Restaurar volume específico
docker stop app-wordpress-abc123
docker volume rm app-wordpress-abc123-data
docker volume create app-wordpress-abc123-data

docker run --rm \
  -v app-wordpress-abc123-data:/target \
  -v /var/backups/vpsguardian/volumes:/backup:ro \
  busybox \
  tar -xzf /backup/app-wordpress-abc123-data-backup-*.tar.gz -C /target

# Reiniciar aplicação no Coolify
docker start app-wordpress-abc123
```

---

## ⚠️ Troubleshooting

### Problema: "Nenhum backup encontrado"

**Causa**: Diretórios de backup incorretos

**Solução**:
```bash
# Verificar onde estão os backups
find / -name "coolify-backup-*.tar.gz" 2>/dev/null
find / -name "*-backup-*.meta" 2>/dev/null

# Ajustar variáveis
export BACKUP_COOLIFY_DIR=/caminho/correto/coolify
export BACKUP_VOLUMES_DIR=/caminho/correto/volumes

# Rodar novamente
./backup/restaurar-completo.sh --local
```

---

### Problema: Aplicação não inicia após restore

**Causa**: Container precisa ser recriado (normal)

**Solução**:
```bash
# No Coolify Dashboard:
1. Acesse a aplicação
2. Clique em "Deploy"
3. Aguarde deploy completar

# Ou via CLI:
docker ps -a | grep app-nome
docker start app-nome
docker logs -f app-nome
```

---

### Problema: Banco de dados em crash loop

**Causa**: Redo logs corrompidos (volume backup)

**Solução**: O script faz automaticamente:
```bash
# Detecta crash loop
# Deleta volume corrompido
# Restaura de SQL dump

# Se quiser fazer manual:
docker stop app-mysql-prod
docker volume rm app-mysql-prod-data
docker volume create app-mysql-prod-data
docker start app-mysql-prod

# Aguardar MySQL aceitar conexões
sleep 10

# Restaurar dump
cat /var/backups/vpsguardian/volumes/app-mysql-prod-dump-*.sql | \
  docker exec -i app-mysql-prod mysql -u root -p$PASSWORD
```

---

### Problema: "Conexão SSH recusada" (modo remoto)

**Causa**: Firewall, porta errada, ou SSH não configurado

**Solução**:
```bash
# Testar SSH manualmente
ssh -p 22 root@192.168.1.100

# Verificar firewall no servidor remoto
sudo ufw status
sudo ufw allow 22/tcp

# Usar chave SSH específica
./backup/restaurar-completo.sh \
  --remote \
  --ip=192.168.1.100 \
  --key=/root/.ssh/id_rsa_backup
```

---

## 📋 Checklist Pós-Restauração

### ✅ Validação Imediata (Automática)

- [ ] Coolify está rodando (`docker ps | grep coolify`)
- [ ] Banco do Coolify está saudável
- [ ] Aplicações aparecem no dashboard
- [ ] Volumes foram restaurados

### ✅ Validação Manual (Você Faz)

- [ ] Acesse Coolify (http://seu-ip:8000)
- [ ] Login funciona (use credenciais antigas)
- [ ] Todas as aplicações aparecem na lista
- [ ] Deploy de cada aplicação
- [ ] Teste cada aplicação individualmente:
  - [ ] WordPress: Posts aparecem, login funciona
  - [ ] API: Endpoints respondem, banco tem dados
  - [ ] Banco de dados: Dados estão lá
- [ ] Certificados SSL funcionam
- [ ] Domínios apontam corretamente (se migração)

---

## 🎓 Boas Práticas

### 1. Teste Restauração Mensalmente

```bash
# Criar servidor de teste
# Restaurar backups
# Validar tudo funciona
# Destruir servidor de teste
```

### 2. Documente suas Aplicações

Crie `APPS.md`:
```markdown
# Aplicações no Servidor

1. Blog WordPress
   - Volume: app-wordpress-abc123-data
   - URL: blog.example.com
   - Banco: MySQL (no volume)

2. API Node.js
   - Volume: app-nodejs-api-xyz789-data
   - URL: api.example.com
   - Banco: PostgreSQL (no volume)
```

### 3. Mantenha Backups Off-Site

```bash
# Configure upload automático
./scripts-auxiliares/configurar-cron.sh
# Opção 6: Upload Automático → AWS S3
```

### 4. Backups Antes de Mudanças Grandes

```bash
# Antes de atualizar Coolify, migrar, etc.
./backup/backup-coolify.sh
./migrar/backup-volumes.sh
```

---

## 🆘 Cenários de Emergência

### Servidor Destruído Completamente

```bash
# 1. Provisionar novo servidor
# 2. Copiar backups do off-site
scp -r backup-server:/backups /tmp/

# 3. Instalar VPS Guardian
curl -fsSL https://raw.githubusercontent.com/.../install.sh | bash

# 4. Copiar backups
cp -r /tmp/backups/* /var/backups/vpsguardian/

# 5. Restaurar tudo
cd /opt/vpsguardian
./backup/restaurar-completo.sh --local
```

### Apenas Uma Aplicação Corrompida

```bash
# 1. Parar aplicação no Coolify

# 2. Restaurar apenas volume dela
docker volume rm app-problematica-data
docker volume create app-problematica-data

docker run --rm \
  -v app-problematica-data:/target \
  -v /var/backups/vpsguardian/volumes:/backup:ro \
  busybox \
  tar -xzf /backup/app-problematica-data-backup-latest.tar.gz -C /target

# 3. Re-deploy no Coolify
```

### Coolify Quebrou Mas Aplicações OK

```bash
# Restaurar apenas Coolify
./backup/restaurar-coolify-remoto.sh

# Aplicações continuam rodando normalmente
```

---

## 📊 Tempo Estimado de Restauração

| Cenário | Tempo |
|---------|-------|
| **Coolify apenas** | 5-10 min |
| **Volumes apenas** (5 apps, 10GB) | 15-30 min |
| **Completo local** (Coolify + Volumes) | 20-40 min |
| **Migração remota** (50GB dados) | 1-2 horas |

*Depende de: quantidade de dados, velocidade do disco, rede (se remoto)*

---

## 📚 Mais Informações

- **Backup Completo**: `docs/BACKUP-COMPLETO.md`
- **Backup e Retenção**: `docs/BACKUP-E-RETENCAO.md`
- **Migração Robusta**: `migrar/MIGRATION-ARCHITECTURE.md`

---

## 💡 Dicas de Senior

### Dry-Run de Restauração

Não há opção `--dry-run`, mas você pode:
```bash
# Criar servidor temporário
# Restaurar lá
# Validar
# Destruir
```

### Restauração Paralela

```bash
# Restaurar Coolify e volumes em paralelo (avançado)
# NÃO RECOMENDADO: pode causar problemas

# Melhor: Sequencial (script já faz)
```

### Verificar Integridade Antes de Restaurar

```bash
# Testar se backup está íntegro
tar -tzf coolify-backup-20260202.tar.gz > /dev/null
echo $?  # 0 = OK, outro = corrompido

# Testar SQL dump
cat dump.sql | grep "INSERT" | wc -l  # Deve ter dados
```

---

**Última atualização**: 2026-02-02
**Versão**: 2.0.0
**Status**: ✅ Production-Ready
