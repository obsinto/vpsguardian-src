# Guia Completo - Integração com API do Coolify

> Documentação completa da integração do VPS Guardian com a API REST do Coolify
>
> Implementado em: Março 2026
> Versão: 1.0.0

---

## Índice

1. [Visão Geral](#1-visão-geral)
2. [Arquivos Criados/Modificados](#2-arquivos-criadosmodificados)
3. [Fase 1 - Fundação](#3-fase-1---fundação)
4. [Fase 2 - Backup Inteligente](#4-fase-2---backup-inteligente)
5. [Fase 3 - Migração Melhorada](#5-fase-3---migração-melhorada)
6. [Fase 4 - Monitoramento](#6-fase-4---monitoramento)
7. [Referência de Funções](#7-referência-de-funções)
8. [Configuração](#8-configuração)
9. [Exemplos de Uso](#9-exemplos-de-uso)
10. [Troubleshooting](#10-troubleshooting)

---

## 1. Visão Geral

### O que é

A integração com a API do Coolify permite que o VPS Guardian:

- **Descubra automaticamente** todos os recursos (apps, databases, services) gerenciados pelo Coolify
- **Faça backups seletivos** por projeto ou ambiente
- **Pare/Inicie containers** de forma graceful (respeitando o estado do Coolify)
- **Valide migrações** comparando inventários antes e depois
- **Monitore a saúde** dos recursos em tempo real
- **Envie notificações** quando há problemas

### Benefícios vs. Método Anterior

| Aspecto | Antes (Docker) | Agora (API) |
|---------|---------------|-------------|
| Descoberta de DBs | Parsing de nomes de containers | Lista tipada com credenciais |
| Stop/Start | `docker stop` (bruto) | API graceful (respeita Coolify) |
| Credenciais | Hardcoded ou inferido | Direto das variáveis do Coolify |
| Seleção | Manual ou tudo | Por projeto/ambiente |
| Validação | Manual | Automatizada via API |
| Monitoramento | Nenhum | Dashboard + notificações |

### Fallback Transparente

Todos os scripts mantêm funcionamento **sem a API**. Se a API não estiver configurada ou disponível, o sistema automaticamente usa o método tradicional via Docker.

---

## 2. Arquivos Criados/Modificados

### Novos Arquivos

| Arquivo | Linhas | Descrição |
|---------|--------|-----------|
| `lib/coolify-api.sh` | ~800 | Biblioteca principal de integração |
| `scripts-auxiliares/configurar-coolify-api.sh` | ~425 | Script de configuração interativa |
| `scripts-auxiliares/monitorar-coolify.sh` | ~400 | Dashboard e monitoramento |
| `docs/PLANO-INTEGRACAO-COOLIFY-API.md` | ~340 | Plano original de integração |

### Arquivos Modificados

| Arquivo | Modificações |
|---------|-------------|
| `config/backup-destinations.conf` | +22 linhas (seção COOLIFY API) |
| `menu-principal.sh` | +180 linhas (opções 3, 6, 12) |
| `migrar/backup-volumes.sh` | +32 linhas (smart_stop/start) |
| `migrar/migrar-databases-dump.sh` | +264 linhas (filtro por projeto) |
| `backup/backup-databases-dump-auto.sh` | +20 linhas (--project) |
| `scripts-auxiliares/validar-pos-migracao.sh` | +146 linhas (validação API) |
| `migrar/migrar-coolify.sh` | +105 linhas (validação pós-migração) |

---

## 3. Fase 1 - Fundação

### Objetivo
Criar a infraestrutura básica para comunicação com a API do Coolify.

### Implementações

#### 3.1 Biblioteca `lib/coolify-api.sh`

Funções básicas de comunicação:

```bash
# Verificar se API está disponível
coolify_api_available()

# Verificar se API está habilitada (sem testar conectividade)
coolify_api_enabled()

# Chamada genérica à API
coolify_api_call <method> <endpoint> [data]

# Verificar dependência jq
coolify_check_jq()
```

#### 3.2 Configuração em `backup-destinations.conf`

```bash
# ========== COOLIFY API ==========
COOLIFY_API_ENABLED=false
COOLIFY_API_URL="http://localhost:8000/api/v1"
COOLIFY_API_TOKEN=""
COOLIFY_USE_API_FOR_STOP=true
COOLIFY_API_TIMEOUT=10
```

#### 3.3 Script de Configuração

`scripts-auxiliares/configurar-coolify-api.sh`:

- Menu interativo para configurar token
- Teste de conexão com a API
- Habilitar/desabilitar integração
- Validação de dependências (curl, jq)

#### 3.4 Menu Principal

Nova opção no menu de Configuração:
- **Opção 6**: "🔌 Configurar API do Coolify"

---

## 4. Fase 2 - Backup Inteligente

### Objetivo
Usar a API para descobrir recursos e fazer backups seletivos.

### Implementações

#### 4.1 Funções de Databases

```bash
# Listar todos os databases
coolify_list_databases()

# Obter detalhes de um database
coolify_get_database <uuid>

# Obter URL de conexão
coolify_get_db_connection_url <uuid>

# Descobrir databases (formato estruturado)
coolify_discover_databases()
# Retorna: uuid|name|type|status|container_name|connection_url
```

#### 4.2 Funções de Projetos

```bash
# Listar todos os projetos
coolify_list_projects()

# Obter detalhes de um projeto
coolify_get_project <uuid>

# Listar databases de um projeto
coolify_list_project_databases <project_uuid_or_name>

# Obter UUID pelo nome
coolify_get_project_uuid_by_name <name>

# Listar nomes (para seleção)
coolify_list_project_names()
# Retorna: uuid|name|description
```

#### 4.3 Funções de Stop/Start Graceful

```bash
# Parar database via API
coolify_stop_database <uuid>

# Iniciar database via API
coolify_start_database <uuid>

# Wrapper inteligente (API com fallback Docker)
smart_stop_container <container_name> [resource_type]
smart_start_container <container_name> [resource_type]
```

#### 4.4 Modificações em Scripts de Backup

**`migrar/migrar-databases-dump.sh`:**

```bash
# Novas opções
--project=UUID_ou_nome   # Filtrar por projeto
--list-projects          # Listar projetos disponíveis

# Menu interativo de seleção de projeto
# (quando API disponível e modo interativo)
```

**`backup/backup-databases-dump-auto.sh`:**

```bash
# Nova opção
--project=UUID_ou_nome   # Passa filtro para o dump
```

**`migrar/backup-volumes.sh`:**

```bash
# Integração com smart_stop/start_container
# Usa API se disponível, fallback para Docker
```

#### 4.5 Menu Principal

Nova opção no menu de Backup:
- **Opção 3**: "🎯 Backup por Projeto (Coolify API)"
  - Lista projetos disponíveis
  - Permite selecionar projeto
  - Escolher destino (local, S3, Google Drive)

---

## 5. Fase 3 - Migração Melhorada

### Objetivo
Usar a API para validar migrações e exportar/importar configurações.

### Implementações

#### 5.1 Funções de Health Check

```bash
# Verificar health de applications
coolify_check_applications_health()
# Retorna: uuid|name|status|health

# Verificar health de databases
coolify_check_databases_health()
# Retorna: uuid|name|type|status|is_public

# Verificar health de services
coolify_check_services_health()
# Retorna: uuid|name|status

# Listar todos os recursos
coolify_list_all_resources()
# Retorna: type|uuid|name|status|extra_info

# Contar recursos por status
coolify_count_resources [running|stopped|all]
# Retorna: apps|dbs|services

# Verificar se todos estão healthy
coolify_all_resources_healthy()
# Retorna: 0 se todos running, 1 caso contrário

# Gerar relatório formatado
coolify_migration_health_report()
```

#### 5.2 Funções de Exportação/Importação

```bash
# Exportar inventário completo (JSON)
coolify_export_inventory [output_file]
# Cria: /tmp/coolify-inventory-TIMESTAMP.json

# Exportar variáveis de ambiente de uma app
coolify_export_app_envs <app_uuid> [output_file]

# Exportar lista de recursos (CSV)
coolify_export_resources_list [output_file]
# Formato: type,uuid,name,status,extra

# Comparar dois inventários
coolify_compare_inventories <pre_file> <post_file>
# Exibe: diferenças de contagem, recursos ausentes, status

# Exportar configuração de servidor
coolify_export_server_config <server_uuid> [output_file]

# Listar servidores
coolify_list_servers()
# Retorna: uuid|name|ip|status
```

#### 5.3 Validação Pós-Migração

**`scripts-auxiliares/validar-pos-migracao.sh`:**

```bash
# Nova opção
--use-api   # Usar API para validação avançada

# Auto-detecta se API está configurada
# Valida applications, databases, services
# Mostra status detalhado de cada recurso
```

**Seção adicionada:**
```
========== COOLIFY API HEALTH CHECK ==========

✓ Coolify API está disponível
INFO Recursos detectados: apps:3/3|dbs:2/2|services:1/1

INFO Verificando Applications...
  ✓ App: minha-app (running)
  ✓ App: api-backend (running)

INFO Verificando Databases...
  ✓ DB: postgres-prod (postgres) - running
  ✓ DB: redis-cache (redis) - running

✓ Todos os recursos do Coolify estão saudáveis via API
```

#### 5.4 Integração no `migrar-coolify.sh`

- Carrega biblioteca coolify-api.sh
- Exporta inventário pré-migração (origem)
- Após migração, valida via API no destino
- Compara contagem de recursos
- Exibe resultado no resumo final

---

## 6. Fase 4 - Monitoramento

### Objetivo
Dashboard de status e notificações de problemas.

### Implementações

#### 6.1 Script de Monitoramento

**`scripts-auxiliares/monitorar-coolify.sh`:**

```bash
# Modos de operação
--dashboard   # Exibir dashboard visual
--notify      # Monitorar e notificar problemas
--cron        # Modo silencioso para cron

# Funcionalidades
- Coleta status de todos os recursos
- Exibe dashboard formatado
- Detecta mudanças de status (evita spam)
- Envia notificações Discord
- Notifica recuperação quando recursos voltam
```

#### 6.2 Dashboard Visual

```
╔══════════════════════════════════════════════════════════════╗
║             COOLIFY MONITORING DASHBOARD                     ║
╚══════════════════════════════════════════════════════════════╝

  Servidor: meu-servidor
  Data/Hora: 2026-03-22 15:30:00
  API URL: http://localhost:8000/api/v1

  ┌─────────────────────────────────────────────────────────┐
  │  RESUMO                                                 │
  ├─────────────────────────────────────────────────────────┤
  │  Applications     3 total │   3 running │   0 stopped │
  │  Databases        2 total │   2 running │   0 stopped │
  │  Services         1 total │   1 running │   0 stopped │
  └─────────────────────────────────────────────────────────┘

  APPLICATIONS:
    ✓ minha-app (running)
    ✓ api-backend (running)
    ✓ website (running)

  DATABASES:
    ✓ postgres-prod [postgresql] (running)
    ✓ redis-cache [redis] (running)

  SERVICES:
    ✓ traefik (running)

  ✅ Todos os recursos estão saudáveis!
```

#### 6.3 Notificações Discord

**Notificação de Problema:**
```
⚠️ Coolify - Recursos com Problemas

Alguns recursos não estão running

Apps: 2/3 running
DBs: 2/2 running
Services: 1/1 running

Problemas:
App: api-backend (stopped)
```

**Notificação de Recuperação:**
```
✅ Coolify - Todos os Recursos OK

Todos os 3 apps, 2 databases e 1 services estão running
```

#### 6.4 Configuração de Cron

```bash
# Monitorar a cada 5 minutos
*/5 * * * * /opt/vpsguardian/scripts-auxiliares/monitorar-coolify.sh --cron

# Monitorar a cada hora
0 * * * * /opt/vpsguardian/scripts-auxiliares/monitorar-coolify.sh --cron
```

#### 6.5 Menu Principal

Nova opção no menu de Backup:
- **Opção 12**: "📡 Monitorar Status do Coolify (API)"

---

## 7. Referência de Funções

### Funções de Verificação

| Função | Descrição | Retorno |
|--------|-----------|---------|
| `coolify_api_available` | Verifica se API está disponível e funcionando | 0=sim, 1=não |
| `coolify_api_enabled` | Verifica se API está habilitada (sem testar) | 0=sim, 1=não |
| `coolify_check_jq` | Verifica se jq está instalado | 0=sim, 1=não |

### Funções de API

| Função | Parâmetros | Descrição |
|--------|------------|-----------|
| `coolify_api_call` | method, endpoint, [data] | Chamada genérica à API |
| `coolify_list_databases` | - | Lista todos os databases (JSON) |
| `coolify_get_database` | uuid | Detalhes de um database |
| `coolify_list_applications` | - | Lista todas as applications |
| `coolify_list_services` | - | Lista todos os services |
| `coolify_list_projects` | - | Lista todos os projetos |
| `coolify_get_project` | uuid | Detalhes de um projeto |
| `coolify_list_servers` | - | Lista servidores |

### Funções de Projetos

| Função | Parâmetros | Retorno |
|--------|------------|---------|
| `coolify_list_project_names` | - | uuid\|name\|description |
| `coolify_list_project_databases` | uuid_ou_nome | uuid\|name\|type\|status\|container\|url |
| `coolify_get_project_uuid_by_name` | nome | UUID do projeto |
| `coolify_discover_projects` | - | project_uuid\|name\|env\|type\|uuid\|name |

### Funções de Stop/Start

| Função | Parâmetros | Descrição |
|--------|------------|-----------|
| `coolify_stop_database` | uuid | Para database via API |
| `coolify_start_database` | uuid | Inicia database via API |
| `coolify_stop_application` | uuid | Para application via API |
| `coolify_start_application` | uuid | Inicia application via API |
| `coolify_stop_service` | uuid | Para service via API |
| `coolify_start_service` | uuid | Inicia service via API |
| `smart_stop_container` | container, [type] | API com fallback Docker |
| `smart_start_container` | container, [type] | API com fallback Docker |
| `coolify_graceful_stop` | type, uuid_ou_container | Stop genérico |
| `coolify_graceful_start` | type, uuid_ou_container | Start genérico |

### Funções de Health Check

| Função | Retorno |
|--------|---------|
| `coolify_check_applications_health` | uuid\|name\|status\|health |
| `coolify_check_databases_health` | uuid\|name\|type\|status\|is_public |
| `coolify_check_services_health` | uuid\|name\|status |
| `coolify_list_all_resources` | type\|uuid\|name\|status\|extra |
| `coolify_count_resources` | apps\|dbs\|services |
| `coolify_all_resources_healthy` | 0=todos OK, 1=problemas |
| `coolify_migration_health_report` | Relatório formatado (stdout) |

### Funções de Exportação

| Função | Parâmetros | Descrição |
|--------|------------|-----------|
| `coolify_export_inventory` | [output_file] | Exporta JSON completo |
| `coolify_export_app_envs` | uuid, [output_file] | Exporta envs de app |
| `coolify_export_resources_list` | [output_file] | Exporta CSV |
| `coolify_compare_inventories` | pre_file, post_file | Compara inventários |
| `coolify_export_server_config` | uuid, [output_file] | Exporta config servidor |

### Funções de Cache

| Função | Descrição |
|--------|-----------|
| `coolify_load_cache` | Carrega cache de recursos |
| `coolify_get_uuid_by_container` | Busca UUID no cache |
| `coolify_get_db_type` | Obtém tipo de database |

### Funções de Diagnóstico

| Função | Descrição |
|--------|-----------|
| `coolify_test_connection` | Testa conexão e exibe informações |

---

## 8. Configuração

### 8.1 Obter Token da API

1. Acesse a UI do Coolify
2. Vá em: **Settings → Keys & Tokens → API tokens**
3. Crie um novo token com permissão:
   - `read:sensitive` - Para backup/descoberta
   - `*` (full access) - Para stop/start via API (recomendado)
4. Copie o token gerado

### 8.2 Configurar via Script

```bash
# Executar configuração interativa
./scripts-auxiliares/configurar-coolify-api.sh

# Apenas testar conexão atual
./scripts-auxiliares/configurar-coolify-api.sh --test

# Desabilitar integração
./scripts-auxiliares/configurar-coolify-api.sh --disable
```

### 8.3 Configurar Manualmente

Edite `/opt/vpsguardian/config/backup-destinations.conf`:

```bash
# ========== COOLIFY API ==========
COOLIFY_API_ENABLED=true
COOLIFY_API_URL="http://localhost:8000/api/v1"
COOLIFY_API_TOKEN="seu-token-aqui"
COOLIFY_USE_API_FOR_STOP=true
COOLIFY_API_TIMEOUT=10
```

### 8.4 Variáveis de Configuração

| Variável | Padrão | Descrição |
|----------|--------|-----------|
| `COOLIFY_API_ENABLED` | false | Habilitar integração |
| `COOLIFY_API_URL` | http://localhost:8000/api/v1 | URL da API |
| `COOLIFY_API_TOKEN` | (vazio) | Token de autenticação |
| `COOLIFY_USE_API_FOR_STOP` | true | Usar API para stop/start |
| `COOLIFY_API_TIMEOUT` | 10 | Timeout em segundos |

---

## 9. Exemplos de Uso

### 9.1 Backup de Projeto Específico

```bash
# Via CLI
./backup/backup-databases-dump-auto.sh --project=meu-projeto --dest=s3

# Via menu
./menu-principal.sh
# → Backups → Backup por Projeto (Coolify API)
```

### 9.2 Listar Projetos Disponíveis

```bash
./migrar/migrar-databases-dump.sh --list-projects

# Saída:
#   UUID                                  NOME                            DESCRIÇÃO
#   abc123...                             website-prod                    Produção
#   def456...                             api-staging                     Staging
```

### 9.3 Monitorar Status

```bash
# Dashboard interativo
./scripts-auxiliares/monitorar-coolify.sh --dashboard

# Monitorar e notificar
./scripts-auxiliares/monitorar-coolify.sh --notify

# Via menu
./menu-principal.sh
# → Backups → Monitorar Status do Coolify (API)
```

### 9.4 Validar Migração

```bash
# Após migração, no servidor de destino
./scripts-auxiliares/validar-pos-migracao.sh --use-api

# Comparar inventários
source lib/coolify-api.sh
coolify_compare_inventories pre-migration.json post-migration.json
```

### 9.5 Health Check Rápido

```bash
source lib/coolify-api.sh

# Verificar se todos estão OK
if coolify_all_resources_healthy; then
    echo "Todos os recursos estão saudáveis"
else
    echo "Há problemas com alguns recursos"
    coolify_migration_health_report
fi
```

### 9.6 Exportar Inventário

```bash
source lib/coolify-api.sh

# Exportar inventário completo
INVENTORY=$(coolify_export_inventory)
echo "Inventário salvo em: $INVENTORY"

# Exportar lista CSV
CSV=$(coolify_export_resources_list)
cat "$CSV"
```

---

## 10. Troubleshooting

### API não está disponível

```
[ ERRO ] API do Coolify não está disponível
```

**Soluções:**
1. Verificar se Coolify está rodando: `docker ps | grep coolify`
2. Verificar se token está configurado: `grep COOLIFY_API_TOKEN /opt/vpsguardian/config/backup-destinations.conf`
3. Testar conexão: `./scripts-auxiliares/configurar-coolify-api.sh --test`

### jq não está instalado

```
[ ERRO ] jq não está instalado
```

**Solução:**
```bash
apt install jq
```

### Token inválido

```
[ERRO] Falha na autenticação
```

**Soluções:**
1. Gerar novo token no Coolify
2. Verificar permissões do token (precisa de `read:sensitive` ou `*`)
3. Atualizar token na configuração

### Timeout nas requisições

```
[ERRO] Falha na requisição
```

**Soluções:**
1. Aumentar timeout: `COOLIFY_API_TIMEOUT=30`
2. Verificar se Coolify não está sobrecarregado
3. Verificar conectividade de rede

### Nenhum projeto encontrado

```
⚠ Nenhum projeto encontrado via API
```

**Soluções:**
1. Verificar se há projetos criados no Coolify
2. Verificar permissões do token
3. Usar `--list-projects` para debug

### Fallback para Docker

Se a API não estiver funcionando, o sistema automaticamente usa Docker:

```
[ INFO ] Usando detecção via Docker (API não disponível)
```

Isso é normal e não é um erro. O sistema continuará funcionando sem a API.

---

## Commits Relacionados

| Hash | Descrição |
|------|-----------|
| `4524a0b` | feat: integração com API do Coolify para backup seletivo por projeto |
| `898027b` | feat: migração melhorada com validação via API do Coolify (Fase 3) |
| `b163efb` | feat: monitoramento de recursos do Coolify via API (Fase 4) |

---

## Referências

- [Coolify API Reference](https://coolify.io/docs/api-reference/api/)
- [Coolify Authorization](https://coolify.io/docs/api-reference/authorization)
- [VPS Guardian - Plano Original](PLANO-INTEGRACAO-COOLIFY-API.md)

---

*Documentação gerada em Março 2026*
