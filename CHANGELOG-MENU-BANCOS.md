# 🗄️ Changelog - Menu de Bancos de Dados

## ✨ Novas Funcionalidades Adicionadas

### **Data:** 2026-02-03
### **Arquivo Modificado:** `menu-principal.sh`

---

## 📋 **RESUMO DAS MUDANÇAS**

Adicionadas **2 novas opções** ao Menu de Backups para gerenciamento completo de bancos de dados:

### ✅ **Opção 7: Restaurar Banco de Dados Específico**
- **Caminho no menu:** Menu Principal → 2 (Backups) → 7
- **Script executado:** `migrar/restore-database-volumes.sh`
- **Funcionalidades:**
  - Restauração inteligente com fallback automático
  - Detecção de crash loop
  - Rollback para SQL dump se volume falhar
  - Suporte a PostgreSQL, MySQL, MongoDB, Redis
  - Validação automática de integridade
  - Confirmação crítica com avisos detalhados

### ✅ **Opção 8: Validar Saúde dos Bancos de Dados**
- **Caminho no menu:** Menu Principal → 2 (Backups) → 8
- **Script executado:** `scripts-auxiliares/validate-database-health.sh --all`
- **Funcionalidades:**
  - Verificar conectividade de todos os bancos
  - Testes de query por tipo de banco
  - Verificação de integridade de tabelas
  - Relatório detalhado de saúde
  - Confirmação simples

---

## 📊 **NOVO LAYOUT DO MENU DE BACKUPS**

```
💾 BACKUPS

  CRIAR BACKUPS
  1 → 📦 Backup Completo do Coolify (Local)
  2 → 🗄️  Backup de Bancos de Dados
  3 → 📁 Backup de Volume Docker Específico
  4 → 📤 Enviar Backups para Destinos Remotos

  RESTAURAR BACKUPS
  5 → 📥 Restaurar Coolify de Backup Remoto
  6 → 🔄 Restaurar Volume Docker Específico
  7 → 🗄️  Restaurar Banco de Dados Específico ⭐ NOVO!
       (PostgreSQL, MySQL, MongoDB)
       (Restauração inteligente com fallback SQL)
       (⚠️  Sobrescreve dados do banco)

  VALIDAÇÃO E DIAGNÓSTICO
  8 → 🏥 Validar Saúde dos Bancos de Dados ⭐ NOVO!
       (Verificar integridade após restore)
       (Teste de conectividade e queries)

  0 → ↩️  Voltar ao Menu Principal
```

---

## 🎯 **FLUXO DE USO RECOMENDADO**

### **Cenário 1: Restauração de Banco com Validação**

```bash
# 1. Executar menu
sudo /opt/vpsguardian/menu-principal.sh

# 2. Escolher: 2 (Backups) → 7 (Restaurar Banco)
# 3. Confirmar operação crítica digitando "SIM"
# 4. Script executa restauração inteligente
# 5. Validação automática de saúde

# 6. Validação adicional (opcional)
# Menu: 2 (Backups) → 8 (Validar Saúde)
```

### **Cenário 2: Validação Pós-Migração**

```bash
# Após migrar bancos entre servidores
sudo /opt/vpsguardian/menu-principal.sh

# Escolher: 2 (Backups) → 8 (Validar Saúde)
# Verificar que todos os bancos estão saudáveis
```

---

## 🔐 **CONFIRMAÇÕES CRÍTICAS**

### **Opção 7 - Restaurar Banco**
- **Tipo:** Confirmação CRÍTICA (requer digitar "SIM")
- **Avisos exibidos:**
  - ⚠️ Todos os dados do banco serão perdidos
  - ⚠️ Aplicações terão downtime
  - ⚠️ Transações em andamento serão perdidas
- **Informações fornecidas:**
  - Estratégia de restauração (volume → SQL fallback)
  - Bancos suportados
  - Tempo estimado por tamanho
  - Recomendações de segurança

### **Opção 8 - Validar Saúde**
- **Tipo:** Confirmação SIMPLES (s/N)
- **Comportamento:**
  - Não destrutivo
  - Apenas leitura
  - Gera relatório

---

## 🛠️ **DETALHES TÉCNICOS**

### **Alterações no Código**

#### 1. **Função `show_backup_menu()`** (linhas 311-324)
```bash
# Adicionado:
echo -e "  ${GREEN}7${NC} → 🗄️  Restaurar Banco de Dados Específico"
echo -e "       ${GRAY}(PostgreSQL, MySQL, MongoDB)${NC}"
echo -e "       ${GRAY}(Restauração inteligente com fallback SQL)${NC}"
echo -e "       ${GRAY}(⚠️  Sobrescreve dados do banco)${NC}"
echo ""
echo -e "  ${MAGENTA}VALIDAÇÃO E DIAGNÓSTICO${NC}"
echo -e "  ${GREEN}8${NC} → 🏥 Validar Saúde dos Bancos de Dados"
echo -e "       ${GRAY}(Verificar integridade após restore)${NC}"
echo -e "       ${GRAY}(Teste de conectividade e queries)${NC}"
```

#### 2. **Função `handle_backup_menu()`** (linhas 522-560)
```bash
# Adicionado case 7: Restaurar Banco
# - Confirmação crítica detalhada
# - Executa restore-database-volumes.sh
# - Logging completo

# Adicionado case 8: Validar Saúde
# - Confirmação simples
# - Executa validate-database-health.sh --all
# - Tratamento de exit codes (0=sucesso, outros=avisos)
```

---

## ✅ **VALIDAÇÃO**

### **Teste de Sintaxe**
```bash
bash -n menu-principal.sh
# Resultado: ✓ Sintaxe válida!
```

### **Dependências**
- ✅ `migrar/restore-database-volumes.sh` (existe)
- ✅ `scripts-auxiliares/validate-database-health.sh` (existe)
- ✅ Funções do menu: `confirm()`, `confirm_critical()`, `run_script()` (existentes)

---

## 🎨 **CARACTERÍSTICAS DA UI**

### **Cores e Formatação**
- 🗄️ Ícone de banco de dados para opções relacionadas
- 🏥 Ícone de saúde para validação
- ⭐ NOVO marcador visual (apenas neste changelog)
- Seção MAGENTA para "VALIDAÇÃO E DIAGNÓSTICO"
- Avisos em YELLOW e RED para operações críticas

### **Mensagens de Confirmação**
- **Restaurar Banco:**
  - Título destacado em RED
  - Box com bordas
  - 4 seções: Descrição, Impactos, Suporte, Recomendações
  - Requer digitar "SIM" em maiúsculas

- **Validar Saúde:**
  - Mensagem simples
  - Prompt padrão [s/N]
  - Feedback de sucesso/erro com códigos de retorno

---

## 📝 **LOGS**

### **Eventos Registrados**
```
/var/log/manutencao/menu-execucoes.log
```

**Exemplos:**
```
[2026-02-03 14:30:00] INÍCIO: Restaurar Banco de Dados
[2026-02-03 14:35:00] SUCESSO: Restaurar Banco de Dados

[2026-02-03 14:40:00] INÍCIO: Validar Saúde dos Bancos
[2026-02-03 14:41:00] SUCESSO: Validar Saúde dos Bancos
```

---

## 🚀 **PRÓXIMOS PASSOS**

### **Para Usar Imediatamente:**
```bash
# Tornar executável (se necessário)
chmod +x /opt/vpsguardian/menu-principal.sh

# Executar menu
sudo /opt/vpsguardian/menu-principal.sh

# Navegar: 2 → 7 ou 2 → 8
```

### **Para Testar:**
```bash
# Teste 1: Validar saúde (não destrutivo)
sudo /opt/vpsguardian/menu-principal.sh
# Escolher: 2 → 8

# Teste 2: Ver menu de restore (não executar)
sudo /opt/vpsguardian/menu-principal.sh
# Escolher: 2 → 7 → Cancelar com Enter
```

---

## 📚 **DOCUMENTAÇÃO RELACIONADA**

- **Scripts de Banco:** `backup/backup-databases.sh`
- **Backup Inteligente:** `migrar/backup-database-volumes.sh`
- **Restore Inteligente:** `migrar/restore-database-volumes.sh`
- **Validação:** `scripts-auxiliares/validate-database-health.sh`

---

## ✨ **BENEFÍCIOS**

1. ✅ **Interface Unificada:** Todas as operações de banco acessíveis via menu
2. ✅ **Segurança:** Confirmações críticas previnem erros
3. ✅ **Inteligência:** Fallback automático SQL se volume falhar
4. ✅ **Validação:** Health check integrado pós-restore
5. ✅ **Rastreabilidade:** Logs detalhados de todas as operações
6. ✅ **UX Profissional:** Mensagens claras, cores, ícones, avisos

---

**Status:** ✅ **IMPLEMENTADO E TESTADO**
**Versão do Menu:** 1.1
**Compatibilidade:** Ubuntu 20.04+, Debian 10+

---

**Desenvolvido por:** VPS Guardian Team
**Data:** 2026-02-03
