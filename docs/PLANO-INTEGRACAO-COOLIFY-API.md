# Plano de Integração - Coolify API

> Proposta de integração da API REST do Coolify com VPS Guardian

---

## 1. Visão Geral da API

### Autenticação
- **Método**: Bearer Token no header `Authorization`
- **Base URL**: `http://localhost:8000/api/v1`
- **Geração**: UI do Coolify → Keys & Tokens → API tokens

### Permissões Disponíveis
| Permissão | Descrição |
|-----------|-----------|
| `read-only` | Apenas leitura (padrão) |
| `read:sensitive` | Leitura + dados sensíveis |
| `*` | Acesso total |

**Para VPS Guardian**: Recomendado `read:sensitive` ou `*` para acessar credenciais de bancos.

---

## 2. Endpoints Relevantes

### Applications
```bash
GET  /applications                    # Listar todas as aplicações
GET  /applications/{uuid}             # Detalhes de uma aplicação
GET  /applications/{uuid}/envs        # Variáveis de ambiente
GET  /applications/{uuid}/start       # Iniciar aplicação
GET  /applications/{uuid}/stop        # Parar aplicação
GET  /applications/{uuid}/restart     # Reiniciar aplicação
```

### Databases
```bash
GET  /databases                       # Listar todos os bancos
GET  /databases/{uuid}                # Detalhes do banco
GET  /databases/{uuid}/start          # Iniciar banco
GET  /databases/{uuid}/stop           # Parar banco
GET  /databases/{uuid}/restart        # Reiniciar banco
GET  /databases/{uuid}/backups        # Listar backups configurados
```

### Servers
```bash
GET  /servers                         # Listar servidores
GET  /servers/{uuid}                  # Detalhes do servidor
GET  /servers/{uuid}/resources        # Recursos (apps, dbs, services)
GET  /servers/{uuid}/validate         # Validar conectividade
```

### Services (Docker Compose)
```bash
GET  /services                        # Listar serviços
GET  /services/{uuid}                 # Detalhes do serviço
GET  /services/{uuid}/start           # Iniciar serviço
GET  /services/{uuid}/stop            # Parar serviço
```

---

## 3. Casos de Uso no VPS Guardian

### 3.1 Descoberta Automática de Databases
**Hoje**: Parsear nomes de containers Docker
**Com API**: Lista tipada com credenciais

```bash
# Exemplo de resposta GET /databases
{
  "uuid": "abc123",
  "name": "my-postgres",
  "type": "postgresql",
  "status": "running",
  "internal_db_url": "postgresql://user:pass@my-postgres:5432/db"
}
```

**Benefício**: Backup automático de TODOS os bancos gerenciados pelo Coolify, sem configuração manual.

### 3.2 Graceful Shutdown para Backup
**Hoje**: `docker stop` (bruto, pode corromper dados)
**Com API**: Stop/Start respeitando estado do Coolify

```bash
# Parar antes do backup
curl -X GET "http://localhost:8000/api/v1/applications/{uuid}/stop" \
  -H "Authorization: Bearer $TOKEN"

# Fazer backup...

# Reiniciar
curl -X GET "http://localhost:8000/api/v1/applications/{uuid}/start" \
  -H "Authorization: Bearer $TOKEN"
```

### 3.3 Backup por Projeto/Ambiente
**Hoje**: Backup de tudo ou seleção manual
**Com API**: Filtrar por projeto, ambiente, tags

```bash
# Listar recursos de um servidor específico
GET /servers/{uuid}/resources

# Filtrar apenas databases de produção
# (processar resposta JSON)
```

### 3.4 Health Check Pós-Restore
**Hoje**: Verificação manual
**Com API**: Validar que apps voltaram healthy

```bash
GET /applications/{uuid}
# Verificar campo "status": "running"
```

### 3.5 Obter Credenciais de Banco
**Hoje**: Hardcoded ou inferido do nome do container
**Com API**: Direto das variáveis de ambiente

```bash
GET /databases/{uuid}
# Resposta inclui: internal_db_url com user:pass@host:port/db
```

---

## 4. Arquitetura Proposta

### 4.1 Nova Biblioteca: `lib/coolify-api.sh`

```bash
#!/bin/bash
# lib/coolify-api.sh - Wrapper para API do Coolify

# Configuração
COOLIFY_API_URL="${COOLIFY_API_URL:-http://localhost:8000/api/v1}"
COOLIFY_API_TOKEN="${COOLIFY_API_TOKEN:-}"

# Verificar se API está disponível
coolify_api_available() {
    [ -n "$COOLIFY_API_TOKEN" ] && \
    curl -sf "$COOLIFY_API_URL/../health" >/dev/null 2>&1
}

# Chamada genérica à API
coolify_api_call() {
    local method="$1"
    local endpoint="$2"

    curl -sf -X "$method" \
        -H "Authorization: Bearer $COOLIFY_API_TOKEN" \
        -H "Content-Type: application/json" \
        "$COOLIFY_API_URL$endpoint"
}

# Listar databases
coolify_list_databases() {
    coolify_api_call GET "/databases" | jq -r '.[]'
}

# Parar aplicação/database
coolify_stop_resource() {
    local type="$1"  # applications, databases, services
    local uuid="$2"
    coolify_api_call GET "/${type}/${uuid}/stop"
}

# Iniciar aplicação/database
coolify_start_resource() {
    local type="$1"
    local uuid="$2"
    coolify_api_call GET "/${type}/${uuid}/start"
}

# Obter credenciais de database
coolify_get_db_credentials() {
    local uuid="$1"
    coolify_api_call GET "/databases/${uuid}" | jq -r '.internal_db_url'
}
```

### 4.2 Configuração

Adicionar ao `config/backup-destinations.conf`:

```bash
# ========== COOLIFY API ==========
# Habilitar integração com API do Coolify
COOLIFY_API_ENABLED=false

# URL da API (padrão: localhost)
COOLIFY_API_URL="http://localhost:8000/api/v1"

# Token de API (gerar em Keys & Tokens no Coolify)
COOLIFY_API_TOKEN=""

# Usar API para operações de stop/start (graceful)
COOLIFY_USE_API_FOR_STOP=true
```

### 4.3 Fallback Transparente

Todos os scripts manterão funcionamento sem API:

```bash
# Em backup-volumes.sh
stop_container() {
    local container="$1"

    if coolify_api_available && [ "$COOLIFY_USE_API_FOR_STOP" = "true" ]; then
        # Tentar via API (graceful)
        local uuid=$(get_coolify_uuid_for_container "$container")
        if [ -n "$uuid" ]; then
            coolify_stop_resource "applications" "$uuid"
            return $?
        fi
    fi

    # Fallback: Docker direto
    docker stop "$container"
}
```

---

## 5. Fases de Implementação

### Fase 1: Fundação (Prioridade Alta)
- [ ] Criar `lib/coolify-api.sh` com funções básicas
- [ ] Adicionar configuração ao `backup-destinations.conf`
- [ ] Criar script `scripts-auxiliares/configurar-coolify-api.sh`
- [ ] Adicionar opção no menu de configuração

### Fase 2: Backup Inteligente (Prioridade Alta)
- [ ] Integrar descoberta de databases no `backup-databases-dump-auto.sh`
- [ ] Usar API para stop/start graceful no `backup-volumes.sh`
- [ ] Adicionar backup seletivo por projeto

### Fase 3: Migração Melhorada (Prioridade Média)
- [ ] Usar API para listar recursos a migrar
- [ ] Validar health pós-migração via API
- [ ] Exportar/importar configurações via API

### Fase 4: Monitoramento (Prioridade Baixa)
- [ ] Health check de aplicações via API
- [ ] Notificações de status no Discord
- [ ] Dashboard de status no menu

---

## 6. Dependências

### Obrigatórias
- `curl` - Já presente na maioria dos sistemas
- `jq` - Parser JSON para Bash

### Instalação de jq
```bash
# Ubuntu/Debian
apt-get install -y jq

# CentOS/RHEL
yum install -y jq

# Alpine
apk add jq
```

---

## 7. Segurança

### Armazenamento do Token
- Token armazenado em `/opt/vpsguardian/config/backup-destinations.conf`
- Arquivo deve ter permissões `600` (apenas root)
- Nunca logar o token

### Permissões Mínimas
- Para backup/restore: `read:sensitive`
- Para stop/start: `*` (full access)

### Validação
- Verificar token antes de operações críticas
- Timeout em chamadas API (5 segundos)
- Fallback automático se API indisponível

---

## 8. Exemplo de Uso Final

### Menu Interativo
```
╔════════════════════════════════════════════════════════════╗
║         BACKUP DE BANCOS DE DADOS - VIA COOLIFY API        ║
╚════════════════════════════════════════════════════════════╝

Databases detectados via API:

  [1] my-postgres (PostgreSQL) - Projeto: website-prod
      Status: running | UUID: abc123

  [2] app-mysql (MySQL) - Projeto: ecommerce
      Status: running | UUID: def456

  [3] cache-redis (Redis) - Projeto: website-prod
      Status: running | UUID: ghi789

Escolha os databases para backup (1-3, all, ou 0 para cancelar):
```

### Backup Automático (Cron)
```bash
# Descobre todos os databases via API e faz backup
./backup-databases-dump-auto.sh --dest=s3 --use-coolify-api

# Resultado:
# ✓ Descobertos 5 databases via Coolify API
# ✓ Backup my-postgres: 150MB
# ✓ Backup app-mysql: 80MB
# ✓ Backup cache-redis: 5MB
# ✓ Upload para S3 concluído
```

---

## Referências

- [Coolify API Reference](https://coolify.io/docs/api-reference/api/)
- [Coolify Authorization](https://coolify.io/docs/api-reference/authorization)
- [Coolify Backup Strategy](https://massivegrid.com/blog/coolify-backup-strategy/)
- [Environment Variables](https://coolify.io/docs/knowledge-base/environment-variables)
