# 🧪 Guia de Teste: Backup e Restore via Dump SQL

## 📋 Objetivo do Teste

Validar o sistema completo de backup/restore via dump SQL:
1. ✅ Configurar backups para Local + S3
2. ✅ Executar backup automático com Coolify incluído
3. ✅ Migrar Coolify completo para nova máquina
4. ✅ Restaurar dumps do servidor antigo (via SSH)
5. ✅ Restaurar dumps do S3
6. ✅ Validar controle granular (restaurar sem afetar Coolify)

---

## 📍 PARTE 1: MÁQUINA ANTIGA (Servidor Original)

### **PASSO 1: Configurar Destinos de Backup**

**Menu:**
```
Menu Principal → 2 (Backups) → 11 (Configurar Destinos de Backup)
```

**Configurações:**
```
✅ Backup Local: SIM
   - Retenção: 30 dias

✅ AWS S3: SIM
   - Bucket: seu-bucket
   - Prefixo: backups/vpsguardian/databases
   - Região: us-east-1
   - Storage Class: STANDARD_IA

✅ Incluir coolify-db nos backups: SIM

✅ Remover local após upload: NÃO
   (para manter cópia local também)
```

**Validação:**
```bash
# Verificar arquivo de configuração criado
cat /opt/vpsguardian/config/backup-destinations.conf

# Deve mostrar:
# BACKUP_DEST_LOCAL=true
# BACKUP_DEST_AWS_S3=true
# S3_BUCKET="seu-bucket"
# BACKUP_INCLUDE_COOLIFY=true
```

---

### **PASSO 2: Executar Backup via Dump SQL**

**Menu:**
```
Menu Principal → 2 (Backups) → 2 (Backup de Bancos via Dump SQL)
```

**Escolhas:**
```
Onde deseja salvar o backup?
→ 5 (Todos os destinos)

Executar backup via dump SQL (destino: all)?
→ s (SIM)
```

**O que acontece:**
1. Script detecta todos os bancos (incluindo coolify-db)
2. Cria dumps SQL comprimidos (.sql.gz)
3. Organiza em lote: `lote-YYYYMMDD_HHMMSS/`
4. Salva localmente
5. Cria tarball do lote
6. Envia para S3
7. Limpa backups antigos

**Validação:**
```bash
# 1. Verificar backup local
ls -lh /var/backups/vpsguardian/databases/

# Deve mostrar algo como:
# drwxr-xr-x 2 root root 4.0K Mar  4 02:00 lote-20260304_020000

# 2. Ver conteúdo do lote
ls -lh /var/backups/vpsguardian/databases/lote-20260304_020000/

# Deve mostrar:
# coolify-db-postgres-20260304_020000.sql.gz
# app1-mysql-20260304_020000.sql.gz
# app2-postgres-20260304_020000.sql.gz
# app3-mysql-20260304_020000.sql.gz

# 3. Verificar tarball criado
ls -lh /var/backups/vpsguardian/databases/*.tar.gz

# 4. Verificar upload no S3
aws s3 ls s3://seu-bucket/backups/vpsguardian/databases/

# Deve mostrar:
# 2026-03-04 02:05:00  245678912 lote-20260304_020000.tar.gz

# 5. Ver tamanho total
du -sh /var/backups/vpsguardian/databases/
```

**Resultado Esperado:**
```
✅ Lote criado em /var/backups/vpsguardian/databases/lote-TIMESTAMP/
✅ Tarball criado: lote-TIMESTAMP.tar.gz
✅ Enviado para S3: s3://seu-bucket/backups/vpsguardian/databases/
✅ Inclui coolify-db + todos os apps
✅ Logs em /var/log/vpsguardian/backup-databases-auto-TIMESTAMP.log
```

---

### **PASSO 3: Migrar Coolify Completo para Nova Máquina**

**Menu:**
```
Menu Principal → 4 (Migração) → 1 (Migrar Coolify Completo)
```

**Informações necessárias:**
```
IP de destino: [IP da nova máquina]
Usuário SSH: root
Porta SSH: 22
```

**O que acontece:**
1. Cria backup completo do Coolify atual
2. Para todos os serviços
3. Transfere dados para novo servidor
4. Instala/configura Coolify no destino
5. Restaura dados
6. Inicia serviços

**Validação na NOVA máquina:**
```bash
# Verificar containers rodando
docker ps

# Deve mostrar:
# coolify
# coolify-db
# coolify-proxy
# + aplicações

# Acessar Coolify
http://[IP-NOVA-MAQUINA]:8000
```

**Resultado Esperado:**
```
✅ Coolify rodando na nova máquina
✅ Aplicações funcionando
✅ Configurações preservadas
✅ Banco coolify-db restaurado
```

---

## 📍 PARTE 2: MÁQUINA NOVA (Servidor Destino)

**IMPORTANTE:** A partir daqui, você está trabalhando na **NOVA máquina** (destino da migração).

---

### **TESTE A: Restaurar Dumps do Servidor Antigo (via SSH)**

**Objetivo:** Validar que consegue baixar dumps do servidor antigo e restaurar apenas apps (sem afetar Coolify migrado)

**Menu:**
```
Menu Principal → 4 (Migração) → 6 (Restaurar Dumps de Origem Remota)
```

**Passos:**

#### **1. Escolher Origem**
```
De onde você deseja baixar os dumps SQL?

  [1] AWS S3
  [2] Google Drive (rclone)
  [3] Servidor SSH (rsync/scp)
  [0] Cancelar

Escolha uma opção (0-3): 3
```

#### **2. Configurar SSH**
```
IP/Hostname do servidor remoto: [IP-SERVIDOR-ANTIGO]
Usuário SSH (padrão: root): root
Porta SSH (padrão: 22): 22
Diretório remoto: /var/backups/vpsguardian/databases

[ INFO ] Testando conexão SSH...
[ OK ] SSH configurado: root@[IP-ANTIGO]:/var/backups/...
```

#### **3. Listar e Escolher Lote**
```
[ OK ] 3 lote(s) encontrado(s):

  [0] lote-20260304_020000.tar.gz
      Tamanho: 245M | Data: 2026-03-04 02:00:00

  [1] lote-20260303_020000.tar.gz
      Tamanho: 238M | Data: 2026-03-03 02:00:00

  [2] lote-20260302_020000.tar.gz
      Tamanho: 242M | Data: 2026-03-02 02:00:00

Selecione o número do lote para baixar: 0
```

#### **4. Download do Lote**
```
[ INFO ] Baixando para: /var/backups/vpsguardian/restore-remote/lote-20260304_020000.tar.gz

[=======================================] 100% 245MB/245MB

[ OK ] Download concluído: 245M
```

#### **5. Extração**
```
[ INFO ] Extraindo para: /var/backups/vpsguardian/restore-remote/lote-20260304_020000
[ OK ] Extraído: 8 dump(s)
```

#### **6. Menu de Restore (MOMENTO CRUCIAL)**
```
════════════════════════════════════════════════════════════════
  Você terá CONTROLE TOTAL sobre o que restaurar:
  • Opção 1: Restaurar TUDO (incluindo Coolify)
  • Opção 2: Restaurar TUDO EXCETO Coolify ⭐ RECOMENDADO
  • Opção 3: Escolher dumps específicos
════════════════════════════════════════════════════════════════

Pressione ENTER para continuar...
```

#### **7. Visualizar Dumps Disponíveis**
```
════════════════════════════════════════════════════════════════
  DUMPS NO LOTE SELECIONADO
════════════════════════════════════════════════════════════════

  [0] coolify-db-postgres-20260304_020000.sql.gz ⚠️  COOLIFY
         Tipo: postgres | Container: coolify-db | Tamanho: 15M
         Data: 2026-03-04 02:00:00
         ⚠️  Este é o banco do Coolify - restaurar sobrescreve configurações

  [1] app1-mysql-20260304_020000.sql.gz
         Tipo: mysql | Container: app1 | Tamanho: 5M
         Data: 2026-03-04 02:00:00

  [2] app2-postgres-20260304_020000.sql.gz
         Tipo: postgres | Container: app2 | Tamanho: 8M
         Data: 2026-03-04 02:00:00

  [3] app3-mysql-20260304_020000.sql.gz
         Tipo: mysql | Container: app3 | Tamanho: 12M
         Data: 2026-03-04 02:00:00

[ INFO ] Total: 4 dump(s) encontrado(s)
```

#### **8. Escolher Opção de Restore**
```
════════════════════════════════════════════════════════════════
  💡 OPÇÕES DE RESTAURAÇÃO
════════════════════════════════════════════════════════════════

  [1] Restaurar TODOS os dumps (incluindo Coolify)
  [2] Restaurar TODOS EXCETO Coolify ⭐ RECOMENDADO
  [3] Escolher dumps específicos manualmente
  [0] Cancelar

Escolha uma opção (0-3): 2  ← ESCOLHA ESTA OPÇÃO
```

#### **9. Restauração**
```
[ INFO ] Selecionado: Restaurar TODOS EXCETO Coolify
[ AVISO ] Pulando: coolify-db (Coolify)

[ INFO ] Processando: app1-mysql-20260304_020000.sql.gz
[ INFO ]   Container destino: app1
[ OK ]   Restaurado com sucesso!

[ INFO ] Processando: app2-postgres-20260304_020000.sql.gz
[ INFO ]   Container destino: app2
[ OK ]   Restaurado com sucesso!

[ INFO ] Processando: app3-mysql-20260304_020000.sql.gz
[ INFO ]   Container destino: app3
[ OK ]   Restaurado com sucesso!
```

#### **10. Limpeza**
```
Remover arquivos baixados? (S/n): s

[ INFO ] Removendo arquivos temporários...
[ OK ] Limpeza concluída
```

**Validação:**
```bash
# 1. Verificar dados dos apps
docker exec app1 mysql -u root -p[senha] -e "SELECT COUNT(*) FROM sua_tabela;"

# 2. Verificar que Coolify NÃO foi afetado
docker exec coolify-db psql -U coolify -d coolify -c "SELECT COUNT(*) FROM applications;"
# Deve mostrar mesma quantidade de antes do restore

# 3. Ver logs do restore
tail -100 /var/log/vpsguardian/restore-databases-*.log

# 4. Validar saúde dos bancos
Menu Principal → 2 (Backups) → 10 (Validar Saúde)
```

**Resultado Esperado:**
```
✅ Dumps baixados do servidor antigo via SSH
✅ App1, app2, app3 restaurados com dados do servidor antigo
❌ Coolify-db NÃO restaurado (mantém dados da migração)
✅ Coolify continua funcionando normalmente
✅ Aplicações com dados atualizados
```

---

### **TESTE B: Restaurar Dumps do S3**

**Objetivo:** Validar que consegue baixar dumps do S3 e ter mesmo controle granular

**Menu:**
```
Menu Principal → 4 (Migração) → 6 (Restaurar Dumps de Origem Remota)
```

**Passos:**

#### **1. Escolher Origem**
```
De onde você deseja baixar os dumps SQL?

  [1] AWS S3
  [2] Google Drive (rclone)
  [3] Servidor SSH (rsync/scp)
  [0] Cancelar

Escolha uma opção (0-3): 1
```

#### **2. Configuração S3**
```
[ INFO ] Testando acesso ao S3...
[ OK ] AWS S3 configurado: s3://seu-bucket/backups/vpsguardian/databases/
```

**Nota:** Se não tiver configuração, será perguntado:
```
Nome do bucket S3: seu-bucket
Prefixo/pasta (padrão: backups/vpsguardian/databases): [ENTER]
```

#### **3. Listar e Escolher Lote**
```
[ INFO ] Buscando lotes disponíveis...

[ OK ] 3 lote(s) encontrado(s):

  [0] lote-20260304_020000.tar.gz
      Tamanho: 235M | Data: 2026-03-04 02:05:00

  [1] lote-20260303_020000.tar.gz
      Tamanho: 228M | Data: 2026-03-03 02:05:00

Selecione o número do lote para baixar: 0
```

#### **4. Download do S3**
```
[ INFO ] Baixando para: /var/backups/vpsguardian/restore-remote/lote-20260304_020000.tar.gz

Downloading: 235MB / 235MB [================] 100% 12.5 MB/s

[ OK ] Download concluído: 235M
```

#### **5. Extração e Restore**
```
(Mesmo processo do TESTE A)

Menu de restore:
→ 2 (Restaurar TUDO EXCETO Coolify)
```

**Validação:**
```bash
# 1. Comparar dados com TESTE A
# Os dados devem ser IDÊNTICOS ao TESTE A (mesmo timestamp de backup)

# 2. Verificar que baixou do S3 (não do SSH)
ls -lh /var/backups/vpsguardian/restore-remote/

# 3. Validar integridade
Menu Principal → 2 (Backups) → 10 (Validar Saúde)
```

**Resultado Esperado:**
```
✅ Dumps baixados do S3
✅ Dados restaurados são idênticos ao TESTE A
✅ Coolify-db mantido intacto
✅ Redundância validada (2 fontes funcionando: SSH e S3)
```

---

## 📊 Resumo das Opções de Menu Utilizadas

| Etapa | Máquina | Menu | Opção | Objetivo |
|-------|---------|------|-------|----------|
| **1** | ANTIGA | 2 → 11 | Configurar Destinos | Local + S3 |
| **2** | ANTIGA | 2 → 2 → 5 | Backup Bancos | Todos os destinos |
| **3** | ANTIGA → NOVA | 4 → 1 | Migrar Coolify | Migração completa |
| **4A** | NOVA | 4 → 6 → 3 | Restaurar via SSH | Servidor antigo |
| **4B** | NOVA | 4 → 6 → 1 | Restaurar via S3 | S3 |

---

## ✅ Checklist de Validação Final

### **Configuração (Máquina Antiga)**
- [ ] Arquivo de configuração criado em `/opt/vpsguardian/config/backup-destinations.conf`
- [ ] `BACKUP_DEST_LOCAL=true`
- [ ] `BACKUP_DEST_AWS_S3=true`
- [ ] `BACKUP_INCLUDE_COOLIFY=true`
- [ ] Credenciais AWS configuradas (`~/.aws/credentials`)

### **Backup (Máquina Antiga)**
- [ ] Lote criado em `/var/backups/vpsguardian/databases/lote-TIMESTAMP/`
- [ ] Contém dump do coolify-db
- [ ] Contém dumps de todos os apps
- [ ] Tarball criado: `lote-TIMESTAMP.tar.gz`
- [ ] Tarball enviado para S3
- [ ] Log criado em `/var/log/vpsguardian/backup-databases-auto-*.log`

### **Migração (Antiga → Nova)**
- [ ] Coolify rodando na nova máquina
- [ ] Aplicações funcionando
- [ ] Acesso ao painel: `http://[IP-NOVA]:8000`
- [ ] Banco coolify-db restaurado e funcional

### **Restore SSH (Máquina Nova)**
- [ ] Conexão SSH com servidor antigo funcionou
- [ ] Listou lotes disponíveis
- [ ] Download via SSH concluído
- [ ] Extração bem-sucedida
- [ ] Menu de 3 opções exibido
- [ ] Dumps do Coolify destacados com ⚠️
- [ ] Opção 2 (Tudo EXCETO Coolify) funcionou
- [ ] Apps restaurados, Coolify intacto
- [ ] Limpeza de arquivos funcionou

### **Restore S3 (Máquina Nova)**
- [ ] Credenciais AWS funcionaram
- [ ] Listou lotes disponíveis no S3
- [ ] Download do S3 concluído
- [ ] Dados idênticos ao restore SSH
- [ ] Menu de controle granular funcionou
- [ ] Coolify mantido intacto novamente

### **Validação Final**
- [ ] Saúde dos bancos validada (Menu 2 → 10)
- [ ] Aplicações acessíveis
- [ ] Dados corretos nos apps
- [ ] Coolify funcional
- [ ] 2 caminhos de restore validados

---

## 🎯 Resultados Esperados

### ✅ **O que deve FUNCIONAR:**
1. Configuração de múltiplos destinos via menu
2. Backup incluindo coolify-db automaticamente
3. Upload para S3 em paralelo ao backup local
4. Migração completa do Coolify
5. Restauração de dumps remotos (SSH e S3)
6. Menu de 3 opções sempre presente
7. Controle granular sobre incluir/excluir Coolify
8. Destaque visual dos dumps do Coolify
9. Limpeza automática de arquivos temporários
10. Redundância (2 fontes: local via SSH + S3)

### ✅ **O que deve ser PRESERVADO:**
- Coolify migrado permanece intacto durante restores
- Dados dos apps são restaurados do servidor antigo
- Configurações de destinos persistem entre reinícios
- Logs detalhados de todas operações

---

## 🚨 Problemas Comuns e Soluções

### **Problema: AWS CLI não configurado**
```bash
# Solução:
aws configure

# Informar:
# AWS Access Key ID: [sua-key]
# AWS Secret Access Key: [sua-secret]
# Default region: us-east-1
# Default output format: json
```

### **Problema: Conexão SSH falha**
```bash
# Verificar conectividade:
ssh -p 22 root@[IP-SERVIDOR-ANTIGO] "echo ok"

# Se falhar, verificar:
# - IP está correto
# - Porta SSH está correta
# - Chave SSH está configurada
# - Firewall não está bloqueando
```

### **Problema: Bucket S3 não encontrado**
```bash
# Listar buckets disponíveis:
aws s3 ls

# Verificar acesso ao bucket:
aws s3 ls s3://seu-bucket/
```

### **Problema: Dumps não aparecem**
```bash
# Verificar se backup foi executado:
ls -lh /var/backups/vpsguardian/databases/

# Ver log do backup:
tail -100 /var/log/vpsguardian/backup-databases-auto-*.log
```

---

## 📝 Notas Importantes

1. **Timestamps:** Anote os timestamps dos lotes para rastreabilidade
2. **Comparação de Dados:** Compare dados restaurados entre SSH e S3 para validar integridade
3. **Testes em VMs:** Use VMs diferentes para simular cenário real
4. **Snapshots:** Considere fazer snapshot da nova máquina antes dos testes de restore
5. **Documentação:** Documente qualquer comportamento inesperado

---

## 🎉 Sucesso do Teste

Se todos os checkboxes acima estiverem marcados, o teste foi **100% bem-sucedido**!

Você terá comprovado que:
- ✅ Sistema de backup completo funciona
- ✅ Múltiplos destinos funcionam
- ✅ Controle granular de Coolify funciona
- ✅ Redundância (SSH + S3) funciona
- ✅ Migração + Restore combinados funcionam
- ✅ Menu intuitivo e seguro

**Pronto para produção!** 🚀
