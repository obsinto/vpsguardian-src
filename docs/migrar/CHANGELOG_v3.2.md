# Changelog v3.2 - Opção de Manter Mesma Chave

## [3.2] - 2025-12-12

### ✨ Nova Funcionalidade: Escolha de Estratégia de Chaves

Adicionado prompt interativo para escolher como tratar a APP_KEY durante migração.

---

## 🎯 O Que Mudou

### ANTES (v3.1):
```bash
# Sempre gerava nova chave e acumulava antigas
APP_KEY=base64:NOVA  ← Gerada pelo Coolify
APP_PREVIOUS_KEYS=base64:ANTIGA1,base64:ANTIGA2  ← Acumula
```

### AGORA (v3.2):
```bash
# Opção 1: Manter mesma chave (NOVO!)
APP_KEY=base64:ANTIGA  ← Mesma do backup
APP_PREVIOUS_KEYS=base64:PREVIOUS1,base64:PREVIOUS2  ← Mantém as que tinha

# Opção 2: Rotação (comportamento anterior)
APP_KEY=base64:NOVA  ← Nova
APP_PREVIOUS_KEYS=base64:ANTIGA,base64:PREVIOUS1  ← Acumula
```

---

## 📋 Tela de Escolha

Durante a migração, você verá:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Estratégia de Chaves de Criptografia
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Escolha como tratar a APP_KEY na migração:

  1. Manter mesma chave (Recomendado para migrações)
     • Servidor novo usa a MESMA APP_KEY do backup
     • Mantém APP_PREVIOUS_KEYS (se tiver)
     • Sem acumulação de chaves
     • Mais simples e direto

  2. Gerar nova chave (Rotação de segurança)
     • Servidor novo gera NOVA APP_KEY
     • Chave antiga vai para APP_PREVIOUS_KEYS
     • Acumula chaves a cada migração
     • Recomendado se houver suspeita de comprometimento

Escolha (1-2, padrão=1): _
```

---

## 🔧 Detalhes Técnicos

### Opção 1: Manter Mesma Chave

**Quando usar:**
- ✅ Migração normal de VPS
- ✅ Mudança de datacenter
- ✅ Upgrade de hardware
- ✅ Disaster recovery

**O que acontece:**
```bash
# Servidor Antigo
APP_KEY=base64:KEY123
APP_PREVIOUS_KEYS=base64:OLD1,base64:OLD2

# ↓ Migração (Opção 1) ↓

# Servidor Novo
APP_KEY=base64:KEY123  ← MESMA!
APP_PREVIOUS_KEYS=base64:OLD1,base64:OLD2  ← MESMAS!
```

**Vantagens:**
- ✅ Sem acumulação
- ✅ Simples
- ✅ Performance ligeiramente melhor (menos chaves para testar)

---

### Opção 2: Gerar Nova Chave (Rotação)

**Quando usar:**
- ⚠️ Suspeita de comprometimento
- ⚠️ Política de segurança exige rotação
- ⚠️ Compliance (LGPD, SOC2)
- ⚠️ Transferência de propriedade

**O que acontece:**
```bash
# Servidor Antigo
APP_KEY=base64:KEY123
APP_PREVIOUS_KEYS=base64:OLD1,base64:OLD2

# ↓ Migração (Opção 2) ↓

# Servidor Novo
APP_KEY=base64:NEWKEY  ← Nova (gerada pelo Coolify)
APP_PREVIOUS_KEYS=base64:KEY123,base64:OLD1,base64:OLD2  ← Acumula!
```

**Vantagens:**
- ✅ Rotação de segurança
- ✅ Invalida chaves antigas gradualmente
- ✅ Auditável

**Desvantagens:**
- ⚠️ Acumula chaves
- ⚠️ Mais complexo

---

## 🤖 Modo Automático

Para scripts automatizados, configure via variável de ambiente:

```bash
# Manter mesma chave (padrão)
export KEY_ROTATION_MODE=1
./migrar-coolify.sh --auto

# OU gerar nova chave
export KEY_ROTATION_MODE=2
./migrar-coolify.sh --auto
```

---

## 📊 Comparação: Múltiplas Migrações

### Cenário: 3 migrações seguidas

#### Com Opção 1 (Manter Mesma Chave):
```bash
# 1ª Migração
APP_KEY=base64:ORIGINAL
APP_PREVIOUS_KEYS=

# 2ª Migração
APP_KEY=base64:ORIGINAL  ← Mesma
APP_PREVIOUS_KEYS=  ← Vazio

# 3ª Migração
APP_KEY=base64:ORIGINAL  ← Mesma
APP_PREVIOUS_KEYS=  ← Vazio

# Total: SEMPRE 1 chave
```

#### Com Opção 2 (Rotação):
```bash
# 1ª Migração
APP_KEY=base64:NEW1
APP_PREVIOUS_KEYS=base64:ORIGINAL

# 2ª Migração
APP_KEY=base64:NEW2
APP_PREVIOUS_KEYS=base64:NEW1,base64:ORIGINAL

# 3ª Migração
APP_KEY=base64:NEW3
APP_PREVIOUS_KEYS=base64:NEW2,base64:NEW1,base64:ORIGINAL

# Total: 1 + 3 = 4 chaves (cresce)
```

---

## ✅ Validação

Execute para testar:

```bash
cd /home/deyvid/Repositories/manutencao_backup_vps/migrar

# Verificar se opção interativa está implementada
grep -A 5 "Estratégia de Chaves" migrar-coolify.sh

# Deve mostrar:
#   1. Manter mesma chave (Recomendado para migrações)
#   2. Gerar nova chave (Rotação de segurança)
```

---

## 🎯 Recomendação

### Para 99% dos casos:
```
✅ Escolha Opção 1: Manter mesma chave
```

**Motivo:** Você está apenas mudando de servidor, não há motivo para rotacionar chaves.

### Apenas escolha Opção 2 se:
- Suspeita que alguém teve acesso à chave
- Política de empresa exige
- Auditoria de segurança solicitou

---

## 🔄 Retrocompatibilidade

- ✅ Scripts antigos continuam funcionando
- ✅ Modo automático sem `KEY_ROTATION_MODE` usa Opção 1 (manter)
- ✅ Backup do .env é preservado

---

## 📝 Arquivos Modificados

- ✅ `migrar-coolify.sh` - Adicionada lógica de escolha
- ✅ Backup criado: `migrar-coolify.sh.v3.2-TIMESTAMP`

---

## 🧪 Como Testar

```bash
# Teste de validação rápida
./TESTE_RAPIDO.sh

# Teste com backup real (sem migrar)
./test-app-key-logic.sh /var/backups/vpsguardian/coolify/SEU_BACKUP.tar.gz

# Migração real (servidor de teste!)
./migrar-coolify.sh
# → Escolha opção 1 quando perguntado
```

---

## 📖 Documentação Relacionada

- `README_CORRECOES.md` - Correções anteriores (v3.1)
- `ANALISE_VERSOES.md` - Análise técnica
- `INSTRUCOES_TESTE.md` - Guia de testes

---

**Versão:** 3.2
**Data:** 2025-12-12
**Contribuição:** Sugestão do usuário
**Status:** ✅ Implementado e Testado
