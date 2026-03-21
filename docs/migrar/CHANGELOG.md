# Changelog - migrar-coolify.sh

## [3.1] - 2025-12-12

### 🔴 CRÍTICO - Bug Corrigido
- **Bug #1:** APP_KEY não era encontrado durante migração
  - Causa: Diretório temporário removido antes da leitura
  - Linha antiga: 1094 (remoção) < 1125 (leitura) ❌
  - Linha nova: 370 (leitura) < 423 (remoção) ✅
  - Impacto: Dados criptografados eram perdidos ("The MAC is invalid")

### ✨ Melhorias Adicionadas
- Busca inteligente de .env usando `find` (funciona com qualquer estrutura)
- Captura de APP_PREVIOUS_KEYS para rotação completa de chaves
- Fallback para APP_KEY do sistema local quando backup não tem .env
- Remoção de código duplicado (linhas 1120-1148)
- Mensagens de debug mais detalhadas

### 📝 Documentação Criada
- README_CORRECOES.md - Resumo completo
- ANALISE_VERSOES.md - Análise técnica
- INSTRUCOES_TESTE.md - Guia de testes
- RESUMO_FINAL.md - Quick start

### 🧪 Ferramentas de Teste
- test-app-key-logic.sh - Testa extração sem migrar
- validar-script.sh - Valida se correções foram aplicadas

### 🔄 Backup
- migrar-coolify.sh.backup-20251212_203538 - Script original preservado

---

## [3.0] - Anterior
- Versão com bug crítico de APP_KEY
- Backup disponível para rollback se necessário
