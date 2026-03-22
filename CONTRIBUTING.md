# Guia de Desenvolvimento - VPS Guardian

> Padrões e convenções para implementação de novas funcionalidades

---

## Estrutura de Diretórios

```
vpsguardian/
├── backup/                    # Scripts de backup e restauração
│   ├── backup-*.sh           # Scripts de backup
│   ├── restaurar-*.sh        # Scripts de restauração
│   └── configurar-*.sh       # Scripts de configuração
├── config/                    # Arquivos de configuração
│   ├── default.conf          # Configurações padrão do sistema
│   └── backup-destinations.conf  # Destinos de backup
├── docs/                      # Documentação
├── lib/                       # Bibliotecas compartilhadas
│   ├── common.sh             # Biblioteca principal (carrega todas)
│   ├── colors.sh             # Definição de cores
│   ├── logging.sh            # Funções de log
│   ├── validation.sh         # Funções de validação
│   ├── notificacoes.sh       # Discord/Slack webhooks
│   ├── backup-retention.sh   # Lógica de retenção GFS
│   └── coolify-api.sh        # Integração com API do Coolify
├── manutencao/               # Scripts de manutenção
├── migrar/                   # Scripts de migração
├── scripts-auxiliares/       # Scripts de suporte
├── menu-principal.sh         # Menu interativo principal
└── instalar.sh              # Script de instalação
```

---

## Arquivos de Configuração

### Localização Padrão

| Ambiente | Caminho |
|----------|---------|
| Desenvolvimento | `./config/` |
| Produção | `/opt/vpsguardian/config/` |

### Padrão de Arquivo de Configuração

```bash
#!/bin/bash
################################################################################
# VPS Guardian - [Nome da Configuração]
# [Descrição breve do propósito]
################################################################################

# ========== SEÇÃO 1 ==========
# Comentário explicando a seção
VARIAVEL_ENABLED=false
VARIAVEL_VALOR=""

# ========== SEÇÃO 2 ==========
# Outra seção
OUTRA_VARIAVEL="valor_padrao"
```

### Variáveis Obrigatórias

Ao criar nova funcionalidade que requer configuração:

1. **Adicionar ao `backup-destinations.conf`** se relacionado a backup/destinos
2. **Adicionar ao `default.conf`** se for configuração global do sistema
3. **Usar valores padrão** com `${VAR:-default}` nos scripts

### Exemplo: Adicionando Nova Configuração

```bash
# Em config/backup-destinations.conf

# ========== NOVA FUNCIONALIDADE ==========
NOVA_FEATURE_ENABLED=false
NOVA_FEATURE_ENDPOINT=""
NOVA_FEATURE_TOKEN=""
```

---

## Carregamento de Configurações

### Ordem de Precedência

Sempre carregar configurações na seguinte ordem:
1. **Produção primeiro**: `/opt/vpsguardian/config/`
2. **Fallback para desenvolvimento**: `$SCRIPT_DIR/config/` ou `$SCRIPT_DIR/../config/`

### Padrão Obrigatório

```bash
# Carregar configurações (SEMPRE usar este padrão)
if [ -f "/opt/vpsguardian/config/backup-destinations.conf" ]; then
    source "/opt/vpsguardian/config/backup-destinations.conf" 2>/dev/null
elif [ -f "$SCRIPT_DIR/../config/backup-destinations.conf" ]; then
    source "$SCRIPT_DIR/../config/backup-destinations.conf" 2>/dev/null
fi
```

### Por que este padrão?

| Cenário | Caminho usado |
|---------|---------------|
| Execução em produção (`/opt/vpsguardian/`) | `/opt/vpsguardian/config/` |
| Execução via menu principal | `/opt/vpsguardian/config/` |
| Desenvolvimento local | `./config/` (fallback) |
| Scripts auxiliares configuram em | `/opt/vpsguardian/config/` |

### Exemplo Completo

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Carregar bibliotecas
source "$SCRIPT_DIR/../lib/common.sh" 2>/dev/null || {
    log_info() { echo "[ INFO ] $*"; }
    log_error() { echo "[ ERRO ] $*"; }
}

# Carregar configurações (ordem de precedência)
if [ -f "/opt/vpsguardian/config/backup-destinations.conf" ]; then
    source "/opt/vpsguardian/config/backup-destinations.conf" 2>/dev/null
elif [ -f "$SCRIPT_DIR/../config/backup-destinations.conf" ]; then
    source "$SCRIPT_DIR/../config/backup-destinations.conf" 2>/dev/null
fi
```

---

## Integração API vs Comandos Nativos (Fallback Pattern)

### Conceito

Quando uma funcionalidade pode usar **API externa** (Coolify, etc.) ou **comandos nativos** (docker, systemctl), sempre implementar com fallback:

```
API disponível? → Usar API
        ↓ não
Usar comando nativo (docker, systemctl, etc.)
```

### Benefícios do Fallback

| Aspecto | API | Comando Nativo |
|---------|-----|----------------|
| Respeita estado do orquestrador | ✅ | ❌ |
| Funciona sem configuração extra | ❌ | ✅ |
| Logs/métricas integrados | ✅ | ❌ |
| Funciona offline | ❌ | ✅ |

### Padrão de Implementação

```bash
# 1. Verificar se API está disponível
if coolify_api_available; then
    # Usar API
    coolify_stop_database "$uuid"
else
    # Fallback: comando nativo
    docker stop -t 60 "$container_name"
fi
```

### Funções de Wrapper (lib/coolify-api.sh)

Para simplificar, use os wrappers inteligentes que fazem o fallback automaticamente:

```bash
# Stop inteligente (API se disponível, senão docker stop)
smart_stop_container "container_name" "database"

# Start inteligente (API se disponível, senão docker start)
smart_start_container "container_name" "database"
```

### Verificação de Disponibilidade

```bash
# Verificar se API está habilitada E conectável
if coolify_api_available; then
    echo "API disponível"
fi

# Verificar apenas se está habilitada (sem testar conexão)
if coolify_api_enabled; then
    echo "API configurada"
fi
```

### Ordem de Carregamento para Usar API

```bash
# 1. Carregar configurações primeiro (contém COOLIFY_API_TOKEN)
if [ -f "/opt/vpsguardian/config/backup-destinations.conf" ]; then
    source "/opt/vpsguardian/config/backup-destinations.conf" 2>/dev/null
elif [ -f "$SCRIPT_DIR/../config/backup-destinations.conf" ]; then
    source "$SCRIPT_DIR/../config/backup-destinations.conf" 2>/dev/null
fi

# 2. Depois carregar a biblioteca da API
source "$SCRIPT_DIR/../lib/coolify-api.sh" 2>/dev/null || {
    # Fallback: definir funções vazias
    coolify_api_available() { return 1; }
    smart_stop_container() { docker stop -t 60 "$1"; }
    smart_start_container() { docker start "$1"; }
}

# 3. Agora pode usar
if coolify_api_available; then
    # Código que usa API
fi
```

### Variáveis de Configuração da API

```bash
# Em backup-destinations.conf
COOLIFY_API_ENABLED=true              # Habilitar integração
COOLIFY_API_URL="http://localhost:8000/api/v1"
COOLIFY_API_TOKEN="seu-token-aqui"
COOLIFY_API_TIMEOUT=10                # Timeout em segundos
COOLIFY_USE_API_FOR_STOP=true         # Usar API para stop/start
```

### Exemplo Completo: Script com Fallback

```bash
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Carregar libs
source "$SCRIPT_DIR/../lib/common.sh" 2>/dev/null

# Carregar config (ordem de precedência)
if [ -f "/opt/vpsguardian/config/backup-destinations.conf" ]; then
    source "/opt/vpsguardian/config/backup-destinations.conf"
elif [ -f "$SCRIPT_DIR/../config/backup-destinations.conf" ]; then
    source "$SCRIPT_DIR/../config/backup-destinations.conf"
fi

# Carregar API com fallback
source "$SCRIPT_DIR/../lib/coolify-api.sh" 2>/dev/null || {
    coolify_api_available() { return 1; }
}

# Listar databases
if coolify_api_available; then
    log_info "Usando API do Coolify"
    databases=$(coolify_list_databases)
else
    log_info "Usando Docker diretamente"
    databases=$(docker ps --filter "label=coolify.managed=true" --format "{{.Names}}")
fi

# Parar container
for db in $databases; do
    smart_stop_container "$db" "database"  # Usa API ou docker automaticamente
done
```

---

## Padrão de Scripts

### Cabeçalho Obrigatório

```bash
#!/bin/bash
################################################################################
# Script: nome-do-script.sh
# Propósito: Descrição clara do que o script faz
# Uso: ./nome-do-script.sh [--opcao1] [--opcao2=valor]
#
# Versão: 1.0.0
################################################################################
```

### Carregamento de Bibliotecas

```bash
# Determinar diretório do script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Carregar bibliotecas (SEMPRE usar common.sh)
source "$SCRIPT_DIR/../lib/common.sh" 2>/dev/null || {
    # Fallback se bibliotecas não estiverem disponíveis
    log_info() { echo "[ INFO ] $*"; }
    log_success() { echo "[ OK ] $*"; }
    log_error() { echo "[ ERRO ] $*"; }
    log_warning() { echo "[ AVISO ] $*"; }
    log_section() { echo ""; echo "========== $* =========="; echo ""; }
}

# Carregar notificações se necessário
source "$SCRIPT_DIR/../lib/notificacoes.sh" 2>/dev/null || true

# Inicializar script (cria diretórios, configura log)
init_script
```

### Parse de Argumentos

```bash
# Valores padrão
OPCAO1=""
OPCAO2="valor_padrao"
DRY_RUN=false

# Parse de argumentos
while [[ $# -gt 0 ]]; do
    case $1 in
        --opcao1) OPCAO1="$2"; shift 2 ;;
        --opcao2=*) OPCAO2="${1#*=}"; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        -h|--help)
            cat << 'EOF'
USO:
  ./nome-do-script.sh [OPÇÕES]

OPÇÕES:
  --opcao1 VALOR    Descrição da opção 1
  --opcao2=VALOR    Descrição da opção 2 (padrão: valor_padrao)
  --dry-run         Simular sem executar
  -h, --help        Mostrar esta ajuda
EOF
            exit 0
            ;;
        *) log_error "Opção desconhecida: $1"; exit 1 ;;
    esac
done
```

### Exit Codes

| Código | Significado |
|--------|-------------|
| 0 | Sucesso |
| 1 | Erro genérico |
| 2 | Argumento inválido |
| 3 | Dependência não encontrada |
| 4 | Permissão negada |
| 5 | Arquivo/diretório não encontrado |

---

## Sistema de Logging

### Funções Disponíveis

```bash
log_info "Mensagem informativa"
log_success "Operação concluída"
log_warning "Aviso importante"
log_error "Erro ocorreu"
log_debug "Informação de debug"
log_section "TÍTULO DA SEÇÃO"
```

### Formato de Log

```
[2024-03-21 14:30:45] [INFO] [nome-do-script] Mensagem
```

### Arquivo de Log

| Tipo | Localização |
|------|-------------|
| Scripts de backup | `/var/log/vpsguardian/cron-backup.log` |
| Manutenção | `/var/log/vpsguardian/cron-manutencao.log` |
| Alertas | `/var/log/vpsguardian/cron-alerta.log` |
| Uploads | `/var/log/vpsguardian/cron-upload.log` |
| Updates | `/var/log/vpsguardian/cron-updates-notify.log` |

---

## Sistema de Notificações

### Uso da Biblioteca

```bash
source "$SCRIPT_DIR/../lib/notificacoes.sh"

# Notificação simples
send_discord_simple "Título" "Mensagem" "success"  # success, warning, error, info

# Notificação detalhada com campos
send_discord_detailed "Título" "Descrição" "success" \
    "Campo1|Valor1" \
    "Campo2|Valor2"

# Notificações de backup (funções prontas)
notify_backup_start "Coolify" "Descrição..."
notify_backup_success "Coolify" "100MB" "5 arquivos"
notify_backup_error "Coolify" "Erro: disco cheio"
```

### Configuração de Webhook

```bash
# Em /opt/vpsguardian/config/backup-destinations.conf
WEBHOOK_URL="https://discord.com/api/webhooks/ID/TOKEN"
```

---

## Integração com Menu Principal

### Estrutura do Menu

O menu usa funções para cada submenu:

```bash
# Em menu-principal.sh

show_meu_submenu() {
    print_header
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${WHITE}TÍTULO DO MENU${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${GREEN}1${NC} → Opção 1"
    echo -e "       ${GRAY}(Descrição)${NC}"
    echo ""
    echo -e "  ${RED}0${NC} → ↩️  Voltar"
    echo ""
    echo -ne "${WHITE}Escolha uma opção: ${NC}"
}

handle_meu_submenu() {
    while true; do
        show_meu_submenu
        read -r option

        case $option in
            1) run_script "$SCRIPT_DIR/pasta/meu-script.sh" "Descrição" ;;
            0) return ;;
            *) echo -e "${RED}Opção inválida!${NC}"; sleep 1 ;;
        esac
    done
}
```

### Executar Script do Menu

```bash
# Executa script com tratamento de erros e logging
run_script "$SCRIPT_DIR/caminho/script.sh" "Nome para Log"

# Com confirmação prévia
if confirm "Executar operação?"; then
    run_script "$SCRIPT_DIR/caminho/script.sh" "Nome"
fi

# Com confirmação crítica (digitação obrigatória)
if confirm_critical "TÍTULO" "descrição" "consequências" "checklist"; then
    run_script "$SCRIPT_DIR/caminho/script.sh" "Nome"
fi
```

---

## Integração com Cron

### Padrão para Scripts Automáticos

Scripts que rodam via cron devem:

1. **Não ser interativos** (sem `read`)
2. **Usar flags** para modo automático: `--auto`, `--dest=local`
3. **Enviar saída para log**: `>> /var/log/vpsguardian/cron-*.log 2>&1`

### Adicionar ao configurar-cron.sh

```bash
# Em scripts-auxiliares/configurar-cron.sh

# Nova seção
echo "N️⃣  NOME DA FUNCIONALIDADE"
echo ""
read -p "$LOG_PREFIX [ INPUT ] Habilitar funcionalidade? (Y/n): " ENABLE_FEATURE
ENABLE_FEATURE=${ENABLE_FEATURE:-y}

# ... lógica de configuração ...

# Adicionar ao crontab
if [[ "$ENABLE_FEATURE" =~ ^[Yy]$ ]]; then
    cat >> "$TEMP_CRON" << EOF
# Descrição da tarefa (horário)
$MIN $HOUR * * $DAY $INSTALL_ROOT/pasta/script.sh --auto >> /var/log/vpsguardian/cron-feature.log 2>&1

EOF
fi
```

### Formato de Entrada Cron

```bash
# Minuto Hora Dia Mês DiaSemana Comando
0 2 * * 0 /opt/vpsguardian/backup/backup-coolify.sh >> /var/log/vpsguardian/cron-backup.log 2>&1
```

---

## Registro no Instalador

### Adicionar Script ao instalar.sh

1. **Copiar arquivo**:
```bash
# Na seção de cópia de arquivos
cp -r pasta/ "$INSTALL_ROOT/"
```

2. **Tornar executável**:
```bash
# Na seção de permissões
chmod +x "$INSTALL_ROOT/pasta/meu-script.sh"
```

3. **Verificar no checklist**:
```bash
# Na seção de verificação
for script in menu-principal.sh backup/backup-coolify.sh pasta/meu-script.sh; do
    if [ ! -x "$INSTALL_ROOT/$script" ]; then
        log_error "Script não encontrado: $script"
    fi
done
```

---

## Checklist para Nova Implementação

### Antes de Começar

- [ ] Definir em qual pasta o script ficará (`backup/`, `manutencao/`, `migrar/`, `scripts-auxiliares/`)
- [ ] Identificar se precisa de novas variáveis de configuração
- [ ] Identificar dependências externas (aws, rclone, docker, etc.)

### Durante o Desenvolvimento

- [ ] Usar cabeçalho padrão com descrição e uso
- [ ] Carregar `lib/common.sh` no início
- [ ] **Usar padrão de carregamento de config** (`/opt/vpsguardian` primeiro, fallback local)
- [ ] **Implementar fallback API → nativo** se usar Coolify API
- [ ] Usar funções de log (`log_info`, `log_error`, etc.)
- [ ] Implementar `--help` com documentação
- [ ] Usar exit codes padronizados
- [ ] Adicionar suporte a `--dry-run` se aplicável

### Integração

- [ ] Adicionar entrada no menu principal (se interativo)
- [ ] Adicionar seção no `configurar-cron.sh` (se automático)
- [ ] Adicionar status na opção "Mostrar Configurações Atuais"
- [ ] Registrar no `instalar.sh`
- [ ] Adicionar notificações Discord se relevante

### Documentação

- [ ] Atualizar README.md se for feature principal
- [ ] Criar/atualizar guia em `docs/` se necessário
- [ ] Adicionar ao CHANGELOG.md

### Testes

- [ ] Testar execução manual
- [ ] Testar com `--dry-run`
- [ ] Testar via menu
- [ ] Testar via cron (simular)
- [ ] Testar notificações

---

## Exemplo Completo: Novo Script de Backup

```bash
#!/bin/bash
################################################################################
# Script: backup-exemplo.sh
# Propósito: Exemplo de script seguindo os padrões do VPS Guardian
# Uso: ./backup-exemplo.sh [--dest=local|s3|gdrive] [--dry-run]
#
# Versão: 1.0.0
################################################################################

# Carregar bibliotecas
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh" 2>/dev/null || {
    log_info() { echo "[ INFO ] $*"; }
    log_success() { echo "[ OK ] $*"; }
    log_error() { echo "[ ERRO ] $*"; }
}
source "$SCRIPT_DIR/../lib/notificacoes.sh" 2>/dev/null || true

# Carregar configurações
BACKUP_DEST_CONFIG="/opt/vpsguardian/config/backup-destinations.conf"
if [ -f "$BACKUP_DEST_CONFIG" ]; then
    source "$BACKUP_DEST_CONFIG"
fi

# Valores padrão
DEST="local"
DRY_RUN=false

# Parse de argumentos
while [[ $# -gt 0 ]]; do
    case $1 in
        --dest=*) DEST="${1#*=}"; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        -h|--help)
            cat << 'EOF'
BACKUP EXEMPLO - VPS Guardian

USO:
  ./backup-exemplo.sh [OPÇÕES]

OPÇÕES:
  --dest=DESTINO    Destino: local, s3, gdrive, all (padrão: local)
  --dry-run         Simular sem executar
  -h, --help        Mostrar esta ajuda

EXEMPLOS:
  ./backup-exemplo.sh --dest=local
  ./backup-exemplo.sh --dest=s3 --dry-run
EOF
            exit 0
            ;;
        *) log_error "Opção desconhecida: $1"; exit 1 ;;
    esac
done

# Iniciar
log_section "Backup Exemplo"
notify_backup_start "Exemplo" "Iniciando backup..."

# Verificar dependências
if ! command -v docker &> /dev/null; then
    log_error "Docker não está instalado"
    exit 3
fi

# Executar backup
if [ "$DRY_RUN" = true ]; then
    log_info "[DRY-RUN] Simulando backup..."
else
    log_info "Executando backup..."
    # ... lógica de backup ...
fi

# Finalizar
log_success "Backup concluído!"
notify_backup_success "Exemplo" "10MB" "5 arquivos"

exit 0
```

---

## Convenções de Nomenclatura

| Tipo | Padrão | Exemplo |
|------|--------|---------|
| Scripts de backup | `backup-*.sh` | `backup-coolify.sh` |
| Scripts de restauração | `restaurar-*.sh` | `restaurar-do-s3.sh` |
| Scripts de configuração | `configurar-*.sh` | `configurar-cron.sh` |
| Scripts de manutenção | Nome descritivo | `alerta-disco.sh` |
| Variáveis de config | `MAIUSCULAS_COM_UNDERSCORE` | `BACKUP_DEST_LOCAL` |
| Funções | `minusculas_com_underscore` | `log_success()` |
| Logs cron | `cron-*.log` | `cron-backup.log` |

---

## Cores do Terminal

```bash
# Disponíveis via lib/colors.sh
${RED}     # Erros, perigo
${GREEN}   # Sucesso, confirmação
${YELLOW}  # Avisos
${BLUE}    # Info, links
${MAGENTA} # Títulos de seção
${CYAN}    # Bordas, separadores
${WHITE}   # Texto principal
${GRAY}    # Texto secundário
${NC}      # Reset (No Color)
```

---

## Commits

### Formato

```
tipo: descrição curta

Descrição detalhada (opcional)

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>
```

### Tipos

| Tipo | Uso |
|------|-----|
| `feat` | Nova funcionalidade |
| `fix` | Correção de bug |
| `refactor` | Refatoração sem mudança de comportamento |
| `docs` | Apenas documentação |
| `style` | Formatação, sem mudança de código |
| `test` | Adição/correção de testes |
| `chore` | Manutenção, dependências |
