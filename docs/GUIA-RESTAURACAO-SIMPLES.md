# 🚀 Guia de Restauração Simplificado - VPS Guardian

## 📌 TL;DR - Restauração em 3 Passos

```bash
# 1. Baixar backups (se necessário)
# 2. Rodar script
sudo ./backup/restaurar-completo.sh --local

# 3. Deploy das apps no Coolify
```

**Pronto!** O script é 100% interativo e te guia pelo processo.

---

## 🎯 Cenários Comuns

### Cenário 1: "Meu servidor deu problema, quero restaurar tudo"

**Situação**: Você tem backups em `/var/backups/vpsguardian/`

```bash
cd /opt/vpsguardian
sudo ./backup/restaurar-completo.sh --local
```

**O que acontece**:
1. ✅ Script encontra backups automaticamente
2. ✅ Mostra lista de backups disponíveis
3. ✅ Você escolhe qual restaurar
4. ✅ Restaura Coolify + Volumes
5. ✅ Valida tudo automaticamente

**Tempo**: 20-40 minutos

---

### Cenário 2: "Baixei backups do S3, estão em outra pasta"

**Situação**: Backups estão em `/home/deyvid/backups-s3/`

```bash
sudo ./backup/restaurar-completo.sh --local
```

**O que acontece**:
```
→ Procurando backups em: /var/backups/vpsguardian/coolify
❌ Nenhum backup encontrado neste diretório

Onde estão seus backups do Coolify?
  1. Em outra pasta (você digita o caminho)
  2. Vou baixar do S3 agora
  3. Cancelar

Opção: 1
Digite o caminho completo: /home/deyvid/backups-s3/coolify

✓ 5 backup(s) encontrados!
```

**Fácil!** O script pergunta onde estão os backups.

---

### Cenário 3: "Quero restaurar de backups no S3"

**Situação**: Backups estão no AWS S3

```bash
sudo ./backup/restaurar-do-s3.sh --bucket=meu-bucket-backups
```

**O que acontece**:
1. ✅ Testa credenciais AWS
2. ✅ Lista backups no S3
3. ✅ Baixa tudo para `/var/backups/vpsguardian/`
4. ✅ Instala Coolify (se necessário)
5. ✅ Restaura automaticamente

**Tempo**: 1-3 horas (depende do tamanho)

---

### Cenário 4: "Quero migrar para um servidor novo"

**Situação**: Servidor antigo OK, quer mover para servidor novo

```bash
# No servidor ANTIGO (onde estão os backups)
sudo ./backup/restaurar-completo.sh --remote
```

**O que acontece**:
```
IP do novo servidor: 192.168.1.100
Usuário SSH (padrão: root): root
Porta SSH (padrão: 22): 22

✓ Testando conexão SSH...
✓ Transferindo backups...
✓ Instalando Coolify...
✓ Restaurando remotamente...
```

**Tempo**: 1-2 horas (depende do tamanho dos dados)

---

## 🧪 Modo Dry-Run (Simulação)

**O que é Dry-Run?**
- Simula a restauração **SEM FAZER NADA DE VERDADE**
- Mostra exatamente o que SERIA feito
- Útil para testar antes de executar

### Como usar:

```bash
sudo ./backup/restaurar-completo.sh --local --dry-run
```

**Saída**:
```
========== DRY-RUN MODE (SIMULAÇÃO) ==========
⚠️  NADA será modificado, apenas simulação!

→ [SIMULAÇÃO] Verificando backups...
  ✓ Encontrados: 5 backups do Coolify
  ✓ Encontrados: 12 backups de volumes

→ [SIMULAÇÃO] Selecionado: coolify-backup-20260202.tar.gz

→ [SIMULAÇÃO] Restauraria Coolify:
  • Pararia containers
  • Extrairia backup
  • Restauraria banco de dados
  • Restauraria SSH keys
  • Reiniciaria Coolify

→ [SIMULAÇÃO] Restauraria volumes:
  • app-wordpress-abc123-data
  • app-nodejs-api-xyz789-data
  • ... (12 volumes totais)

✓ Simulação concluída! Nada foi modificado.
```

**Quando usar**:
- ✅ Testar se backups estão OK
- ✅ Ver o que seria restaurado
- ✅ Validar caminhos antes de rodar de verdade

---

## 📂 Onde Colocar os Backups?

### Opção 1: Pasta Padrão (Mais Fácil)

Coloque backups em:
```
/var/backups/vpsguardian/
├── coolify/
│   └── coolify-backup-*.tar.gz
└── volumes/
    ├── app-*-backup-*.tar.gz
    └── app-*-dump-*.sql
```

**Como fazer**:
```bash
# Se baixou do S3
aws s3 sync s3://meu-bucket/backups/coolify/ /var/backups/vpsguardian/coolify/
aws s3 sync s3://meu-bucket/backups/volumes/ /var/backups/vpsguardian/volumes/

# Ou cópia manual
sudo mkdir -p /var/backups/vpsguardian/{coolify,volumes}
sudo cp meus-backups/coolify/* /var/backups/vpsguardian/coolify/
sudo cp meus-backups/volumes/* /var/backups/vpsguardian/volumes/
```

**Depois**:
```bash
sudo ./backup/restaurar-completo.sh --local
# ✓ Encontra backups automaticamente!
```

---

### Opção 2: Pasta Customizada (Flexível)

Backups em qualquer lugar:
```bash
# Opção A: Especificar diretórios via argumentos
sudo ./backup/restaurar-completo.sh \
  --local \
  --coolify-dir=/home/deyvid/meus-backups/coolify \
  --volumes-dir=/home/deyvid/meus-backups/volumes
```

```bash
# Opção B: Variáveis de ambiente
export BACKUP_COOLIFY_DIR=/home/deyvid/meus-backups/coolify
export BACKUP_VOLUMES_DIR=/home/deyvid/meus-backups/volumes
sudo -E ./backup/restaurar-completo.sh --local
```

```bash
# Opção C: Deixa o script perguntar
sudo ./backup/restaurar-completo.sh --local
# Script pergunta: "Onde estão os backups?"
# Você digita: /home/deyvid/meus-backups/coolify
```

**Todas as opções funcionam!** Escolha a que preferir.

---

### Opção 3: Usar Script S3 (Automático)

Nem precisa baixar manualmente:
```bash
sudo ./backup/restaurar-do-s3.sh \
  --bucket=meu-bucket-backups \
  --prefix=backups
```

**O script**:
1. Baixa tudo do S3 para `/var/backups/vpsguardian/`
2. Chama `restaurar-completo.sh` automaticamente

---

## 🔍 Entendendo a Restauração

### O Que é Restaurado?

#### Camada 1: Coolify (Configurações)
```
coolify-backup-20260202.tar.gz contém:
├── Banco de dados do Coolify
│   └── Lista de todas as aplicações
│   └── Configurações de deploy
│   └── Variáveis de ambiente
├── SSH Keys de deploy
├── Certificados SSL
└── Configurações gerais (.env)
```

**Resultado**: Coolify "sabe" de todas as apps que existiam

#### Camada 2: Volumes (Dados)
```
volumes/ contém (por aplicação):
├── app-wordpress-abc123-data-backup-*.tar.gz  ← Dados binários
├── app-wordpress-abc123-data-dump-*.sql       ← SQL dump
└── app-wordpress-abc123-data-backup-*.meta    ← Metadata

Dados restaurados:
• Posts do WordPress
• Uploads (imagens)
• Banco de dados MySQL
• Arquivos persistentes
```

**Resultado**: Apps têm seus dados de volta

---

### Como Funciona o Restore Inteligente?

```
┌─────────────────────────────────────┐
│ 1. RESTAURAR COOLIFY                │
│    → Banco do Coolify               │
│    → SSH keys                       │
│    → Configurações                  │
└──────────────┬──────────────────────┘
               │
               ▼
┌─────────────────────────────────────┐
│ 2. RESTAURAR VOLUMES (por app)      │
│    ┌───────────────────────────┐    │
│    │ Tentar: Volume Binário    │    │
│    │ (Rápido: 5-10 min)        │    │
│    └───────────┬───────────────┘    │
│                │                     │
│           ┌────┴────┐               │
│           ▼         ▼               │
│        OK ✅    Crash Loop ❌       │
│           │         │               │
│           │         ▼               │
│           │   ┌─────────────────┐   │
│           │   │ Fallback:       │   │
│           │   │ SQL Dump        │   │
│           │   │ (Lento mas      │   │
│           │   │  confiável)     │   │
│           │   └────────┬────────┘   │
│           │            │            │
│           └────────┬───┘            │
│                    ▼                │
│              ✅ RESTAURADO          │
└─────────────────────────────────────┘
               │
               ▼
┌─────────────────────────────────────┐
│ 3. VALIDAÇÃO AUTOMÁTICA             │
│    ✓ Coolify rodando?               │
│    ✓ Banco de dados saudável?       │
│    ✓ Aplicações aparecem?           │
│    ✓ Volumes restaurados?           │
└─────────────────────────────────────┘
```

**Zero intervenção manual!** O script decide automaticamente.

---

## 📋 Checklist Pós-Restauração

Após o script terminar, você precisa fazer:

### ✅ 1. Acessar Coolify

```bash
# No terminal, pega o IP
hostname -I

# Abre no navegador
http://192.168.1.100:8000
```

### ✅ 2. Fazer Login

```
Email: (mesmo de antes)
Senha: (mesma de antes)
```

### ✅ 3. Verificar Aplicações

No dashboard:
- [ ] Todas as aplicações aparecem na lista?
- [ ] Configurações estão corretas?

### ✅ 4. Deploy de Cada Aplicação

**IMPORTANTE**: Containers não iniciam automaticamente após restore!

Para cada app:
1. Clique na aplicação
2. Clique em **"Deploy"**
3. Aguarde deploy completar
4. Teste a aplicação

### ✅ 5. Validar Dados

- [ ] WordPress: Posts aparecem? Imagens carregam?
- [ ] API: Endpoints respondem? Banco tem dados?
- [ ] Banco: Dados estão lá? Queries funcionam?

---

## ⏱️ Quanto Tempo Demora?

| Cenário | Tempo Estimado |
|---------|----------------|
| Coolify apenas | 5-10 minutos |
| Coolify + 5 apps (10GB) | 20-40 minutos |
| Coolify + 20 apps (100GB) | 1-2 horas |
| Download do S3 (50GB) | +30min-2h |
| Migração remota (50GB) | 1-3 horas |

**Depende de**:
- Tamanho dos dados
- Velocidade do disco
- Velocidade da rede (se S3/remoto)

---

## 🆘 Troubleshooting

### "Nenhum backup encontrado"

**Problema**: Script não acha os backups

**Solução**:
```bash
# 1. Verificar onde estão os backups
find /var/backups -name "coolify-backup-*.tar.gz" 2>/dev/null
find /home -name "coolify-backup-*.tar.gz" 2>/dev/null

# 2. Rodar com caminho correto
sudo ./backup/restaurar-completo.sh --local \
  --coolify-dir=/caminho/correto/coolify \
  --volumes-dir=/caminho/correto/volumes
```

---

### "Aplicação não inicia após restore"

**Problema**: App não sobe depois de restaurar

**Causa**: Normal! Containers precisam ser recriados

**Solução**:
```bash
# No dashboard do Coolify:
1. Acesse a aplicação
2. Clique em "Deploy"
3. Aguarde completar

# Ou via CLI:
docker ps -a | grep app-nome
docker start app-nome
docker logs -f app-nome
```

---

### "Banco de dados em crash loop"

**Problema**: MySQL/PostgreSQL não inicia

**Causa**: Redo logs corrompidos (detectado automaticamente)

**Solução**: O script já faz automaticamente!
```
→ Tentando restore de volume...
❌ Crash loop detectado!
→ Fallback para SQL dump...
✅ Restaurado de SQL dump
```

Se falhar, veja os logs:
```bash
docker logs app-mysql-prod 2>&1 | tail -50
```

---

### "Dry-run passa, mas execução real falha"

**Problema**: Simulação OK, mas falha ao executar

**Causas Comuns**:
- Espaço em disco cheio
- Coolify já rodando
- Permissões incorretas

**Solução**:
```bash
# Verificar espaço
df -h

# Verificar Coolify
docker ps | grep coolify

# Verificar permissões
ls -la /var/backups/vpsguardian/
```

---

## 💡 Dicas Profissionais

### 1. Sempre Teste com Dry-Run Primeiro

```bash
# Simulação
sudo ./backup/restaurar-completo.sh --local --dry-run

# Se OK, rodar de verdade
sudo ./backup/restaurar-completo.sh --local
```

### 2. Mantenha Backups em Múltiplos Locais

```
✅ RECOMENDADO:
• Local: /var/backups/vpsguardian/
• S3: s3://meu-bucket/backups/
• Cópia externa: Outro servidor/HD externo
```

### 3. Teste Restauração Mensalmente

```bash
# Criar servidor de teste
# Restaurar backups
# Validar que tudo funciona
# Destruir servidor de teste
```

### 4. Documente suas Apps

Crie `APPS.md`:
```markdown
# Aplicações

1. Blog WordPress (app-wordpress-abc123)
   - URL: blog.example.com
   - Volumes: app-wordpress-abc123-data

2. API Node (app-nodejs-api-xyz789)
   - URL: api.example.com
   - Volumes: app-nodejs-api-xyz789-data
```

---

## 📊 Comparação: Scripts de Restauração

| Script | Quando Usar | Complexidade |
|--------|-------------|--------------|
| `restaurar-completo.sh --local` | Restaurar no mesmo servidor | ⭐ Fácil |
| `restaurar-completo.sh --remote` | Migrar para novo servidor | ⭐⭐ Médio |
| `restaurar-do-s3.sh` | Restaurar de backups no S3 | ⭐ Fácil |
| `restaurar-coolify-remoto.sh` | Só restaurar Coolify (sem volumes) | ⭐⭐⭐ Avançado |

**Recomendação**: Use `restaurar-completo.sh` para 99% dos casos!

---

## 🎓 FAQ

**P: Posso restaurar só uma aplicação específica?**
R: Sim! Veja `docs/GUIA-RESTAURACAO.md` → "Restauração de Componentes Específicos"

**P: Preciso parar o Coolify antes de restaurar?**
R: Não! O script para automaticamente.

**P: Posso cancelar a restauração no meio?**
R: Não recomendado! Pode deixar o sistema em estado inconsistente.

**P: Como sei se a restauração funcionou?**
R: O script faz validação automática. Veja a seção "Validação Pós-Restauração".

**P: E se eu tiver backups muito antigos?**
R: Funciona! O script restaura qualquer backup compatível.

---

**Última atualização**: 2026-02-02
**Versão**: 2.0.0
**Status**: ✅ Production-Ready

---

## 🚀 Atalho Rápido

```bash
# RESTAURAÇÃO COMPLETA EM 1 COMANDO:
cd /opt/vpsguardian && sudo ./backup/restaurar-completo.sh --local
```

**Pronto!** 🎉
