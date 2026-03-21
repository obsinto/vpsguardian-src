# Roadmap: Integração VPS Guardian + Coolify API

> Guia de decisão para evolução do projeto
> Criado em: 2025-03-20

---

## Situação Atual

O VPS Guardian é uma coleção de scripts bash que gerenciam backup, migração e manutenção de servidores com Coolify. Funciona bem, mas opera de forma "cega" - não tem conhecimento direto do estado do Coolify.

```
┌─────────────────────────────────────────────────────────────┐
│                    ARQUITETURA ATUAL                        │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│   Terminal ──▶ menu-principal.sh ──▶ Scripts Bash          │
│                                            │                │
│                                            ▼                │
│                              Docker CLI / Arquivos          │
│                              (docker ps, tar, rsync)        │
│                                                             │
│   Problemas:                                                │
│   • Não sabe quais apps existem no Coolify                 │
│   • Para containers de forma abrupta (docker stop)         │
│   • Não valida se restore funcionou                        │
│   • Migração é processo manual de múltiplos passos         │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

---

## Oportunidade: Coolify API

O Coolify oferece API REST completa em `http://localhost:8000/api/v1`:

| Endpoint | Utilidade para VPS Guardian |
|----------|----------------------------|
| `GET /applications` | Listar todas as apps |
| `POST /applications/{uuid}/stop` | Parar app gracefully |
| `POST /applications/{uuid}/start` | Iniciar app após restore |
| `GET /databases` | Descobrir bancos automaticamente |
| `GET /databases/{uuid}/backups` | Ver backups nativos |
| `GET /servers/{uuid}/validate` | Validar servidor destino |
| `GET /projects` | Mapear estrutura completa |

**Documentação oficial:** https://coolify.io/docs/api-reference/api/

---

## Opções de Arquitetura

### Opção 1: CLI Aprimorado (Menor Esforço)

Manter interface CLI atual, adicionar API como backend inteligente.

```
┌─────────────────────────────────────────────────────────────┐
│                         OPÇÃO 1                             │
│                    CLI + Coolify API                        │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│   Terminal ──▶ menu-principal.sh ──▶ Scripts Bash          │
│                                            │                │
│                                    ┌───────┴───────┐        │
│                                    ▼               ▼        │
│                            Coolify API      Docker/Files    │
│                         (quando disponível)  (fallback)     │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

**O que muda:**
- Novo arquivo: `lib/coolify-api.sh`
- Scripts existentes usam API quando token configurado
- Fallback para método atual se API indisponível

**Vantagens:**
- Menor esforço de implementação
- Zero mudança de UX para usuário
- Compatível com instalações sem API configurada
- Backups mais inteligentes (sabe o que parar/iniciar)

**Desvantagens:**
- Ainda requer SSH para operar
- Sem visibilidade remota do status

**Esforço estimado:**
- `lib/coolify-api.sh`: ~150 linhas
- Adaptação de 5-6 scripts principais: ~200 linhas
- Testes: 1-2 dias
- **Total: 3-5 dias de trabalho**

**Arquivos a criar/modificar:**
```
lib/
├── coolify-api.sh          # NOVO - wrapper da API
├── common.sh               # Adicionar source do coolify-api.sh

config/
├── config.env              # Adicionar COOLIFY_API_TOKEN

backup/
├── backup-coolify.sh       # Usar API para listar/parar/iniciar apps
├── backup-databases-dump-auto.sh  # Usar API para descobrir DBs

migrar/
├── migrar-coolify.sh       # Validar destino via API
├── validar-pre-migracao.sh # Checks via API
├── validar-pos-migracao.sh # Health check via API
```

---

### Opção 2: CLI + Dashboard Web Mínimo

CLI para operações, web para monitoramento.

```
┌─────────────────────────────────────────────────────────────┐
│                         OPÇÃO 2                             │
│                   CLI + Web Mínimo                          │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│   ┌─────────────────┐      ┌─────────────────────────────┐ │
│   │   CLI (SSH)     │      │   Web (Browser)             │ │
│   │   ───────────   │      │   ─────────────             │ │
│   │   • Backup      │      │   • Status                  │ │
│   │   • Migrate     │      │   • Logs                    │ │
│   │   • Config      │      │   • Trigger backup          │ │
│   └────────┬────────┘      └─────────────┬───────────────┘ │
│            │                             │                  │
│            └──────────┬──────────────────┘                  │
│                       ▼                                     │
│              VPS Guardian Core                              │
│                       │                                     │
│            ┌──────────┴──────────┐                          │
│            ▼                     ▼                          │
│      Coolify API           Docker/Files                     │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

**Stack sugerida:**
- Backend: Python (FastAPI) ou Go - leve e rápido
- Frontend: HTML + HTMX (sem build, sem node_modules)
- Auth: Token simples ou integração com Coolify
- Deploy: Container gerenciado pelo próprio Coolify

**Vantagens:**
- Ver status sem SSH
- Trigger backup pelo celular
- Notificações visuais
- Histórico de operações

**Desvantagens:**
- Mais código para manter
- Nova superfície de ataque (segurança)
- Precisa de domínio/subdomínio

**Esforço estimado:**
- Tudo da Opção 1: 3-5 dias
- Backend API: 2-3 dias
- Frontend básico: 2-3 dias
- Auth e segurança: 1-2 dias
- **Total: 8-13 dias de trabalho**

**Estrutura de arquivos:**
```
web/
├── Dockerfile
├── requirements.txt        # fastapi, uvicorn
├── main.py                 # API endpoints
├── static/
│   ├── index.html
│   ├── style.css
│   └── app.js              # HTMX ou vanilla JS
└── templates/
    └── dashboard.html
```

**Endpoints da API web:**
```
GET  /api/status          # Status geral do servidor
GET  /api/backups         # Lista de backups
POST /api/backups         # Trigger novo backup
GET  /api/logs            # Logs recentes
GET  /api/apps            # Apps do Coolify (via API dele)
POST /api/apps/{id}/restart  # Reiniciar app
```

---

### Opção 3: Dashboard Web Completo

Interface web completa substituindo CLI para maioria das operações.

```
┌─────────────────────────────────────────────────────────────┐
│                         OPÇÃO 3                             │
│                   Dashboard Completo                        │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│   Browser: https://guardian.seudominio.com                 │
│   ┌─────────────────────────────────────────────────────┐  │
│   │  ┌──────┐                                           │  │
│   │  │ Logo │  VPS Guardian          [User ▼] [Logout]  │  │
│   │  └──────┘                                           │  │
│   │  ─────────────────────────────────────────────────  │  │
│   │  │ Dashboard │ Backups │ Apps │ Migrate │ Settings │  │
│   │  ─────────────────────────────────────────────────  │  │
│   │                                                     │  │
│   │  ┌─────────────┐ ┌─────────────┐ ┌─────────────┐   │  │
│   │  │ CPU         │ │ Memory      │ │ Disk        │   │  │
│   │  │ ████░░ 67%  │ │ ██████░ 82% │ │ ███░░░ 45%  │   │  │
│   │  └─────────────┘ └─────────────┘ └─────────────┘   │  │
│   │                                                     │  │
│   │  Recent Backups                    Apps Status      │  │
│   │  ┌─────────────────────────┐ ┌─────────────────┐   │  │
│   │  │ ✓ 2025-03-20 02:00     │ │ app1    ● Run   │   │  │
│   │  │ ✓ 2025-03-19 02:00     │ │ app2    ● Run   │   │  │
│   │  │ ✓ 2025-03-18 02:00     │ │ db-main ● Run   │   │  │
│   │  └─────────────────────────┘ └─────────────────┘   │  │
│   │                                                     │  │
│   │  [Backup Now]  [View All Logs]  [System Health]    │  │
│   └─────────────────────────────────────────────────────┘  │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

**Stack sugerida:**
- Backend: Go (Fiber/Echo) ou Python (FastAPI)
- Frontend: Vue 3 / Svelte / React (SPA)
- Database: SQLite (logs, configs, histórico)
- Auth: JWT + opcional SSO
- Deploy: Docker Compose ou Coolify

**Vantagens:**
- Experiência completa sem terminal
- Gráficos e histórico visual
- Multi-usuário possível
- Agendamento visual de backups
- Logs em tempo real (websocket)

**Desvantagens:**
- Significativamente mais complexo
- Precisa manter frontend + backend
- Mais dependências
- Maior superfície de ataque

**Esforço estimado:**
- Tudo da Opção 1 e 2
- Frontend SPA: 5-10 dias
- Features avançadas: 5-10 dias
- **Total: 20-35 dias de trabalho**

---

### Opção 4: Plugin/Contribuição ao Coolify

Contribuir funcionalidades diretamente ao Coolify.

```
┌─────────────────────────────────────────────────────────────┐
│                         OPÇÃO 4                             │
│                  Plugin no Coolify                          │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│   Coolify Dashboard (já existente)                         │
│   ┌─────────────────────────────────────────────────────┐  │
│   │                                                     │  │
│   │  Servers │ Projects │ Settings │ 🛡️ Guardian       │  │
│   │                                 ▲                   │  │
│   │                                 │                   │  │
│   │                         Nova aba/seção              │  │
│   │                                                     │  │
│   │  ┌─────────────────────────────────────────────┐   │  │
│   │  │  Backup & Migration Tools                   │   │  │
│   │  │  ─────────────────────────────────────────  │   │  │
│   │  │  [Backup All]  [Migrate Server]  [Restore] │   │  │
│   │  │                                             │   │  │
│   │  │  Scheduled Backups: ✓ Daily at 02:00       │   │  │
│   │  │  Retention: 7 daily, 4 weekly, 3 monthly   │   │  │
│   │  │  Destination: S3 (Backblaze)               │   │  │
│   │  └─────────────────────────────────────────────┘   │  │
│   │                                                     │  │
│   └─────────────────────────────────────────────────────┘  │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

**Realidade:**
- Coolify é open source (MIT) - contribuições são aceitas
- Stack: Laravel (PHP) + Livewire + Alpine.js
- Não tem sistema formal de plugins ainda
- Seria feature request + PR

**Vantagens:**
- UX 100% integrada
- Mantido pela comunidade Coolify
- Sem infraestrutura adicional
- Beneficia todos os usuários Coolify

**Desvantagens:**
- Depende da aprovação do time Coolify
- Precisa aprender stack deles (Laravel/Livewire)
- Menos controle sobre roadmap
- Pode levar meses para ser aceito

**Esforço estimado:**
- Aprender stack Coolify: 3-5 dias
- Implementar feature: 10-15 dias
- Code review / ajustes: 5-10 dias
- **Total: 20-30 dias (sem garantia de merge)**

**Como começar:**
1. Abrir issue no GitHub do Coolify discutindo a feature
2. Esperar feedback do time
3. Se positivo, fazer fork e implementar
4. Abrir PR e iterar

---

## Comparativo

| Critério | Opção 1 | Opção 2 | Opção 3 | Opção 4 |
|----------|---------|---------|---------|---------|
| **Esforço** | 3-5 dias | 8-13 dias | 20-35 dias | 20-30 dias |
| **Risco** | Baixo | Médio | Alto | Alto |
| **Manutenção** | Baixa | Média | Alta | Zero* |
| **Controle** | Total | Total | Total | Parcial |
| **UX** | CLI | CLI+Web | Web | Integrada |
| **Valor imediato** | Alto | Alto | Muito Alto | Muito Alto |
| **Acesso remoto** | Não | Sim | Sim | Sim |
| **Multi-servidor** | Não | Possível | Sim | Sim |

*Zero se merge for aceito, senão vira fork para manter

---

## Recomendação: Abordagem Faseada

```
┌─────────────────────────────────────────────────────────────┐
│                    ROADMAP SUGERIDO                         │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  FASE 1 (Semana 1)                                         │
│  ─────────────────                                         │
│  Opção 1: Integrar API do Coolify nos scripts              │
│  • Criar lib/coolify-api.sh                                │
│  • Adaptar backup-coolify.sh                               │
│  • Adaptar validadores de migração                         │
│  • Testar em ambiente de dev                               │
│                                                             │
│  Entregável: CLI mais inteligente, zero mudança de UX     │
│                                                             │
│  ─────────────────────────────────────────────────────────  │
│                                                             │
│  FASE 2 (Semana 2-3)                                       │
│  ──────────────────                                        │
│  Opção 2: Adicionar API web mínima                         │
│  • Backend FastAPI (~200 linhas)                           │
│  • Endpoints: /status, /backups, /logs                     │
│  • Frontend: HTML + HTMX (sem build)                       │
│  • Deploy via Coolify                                      │
│                                                             │
│  Entregável: Dashboard de status acessível via browser    │
│                                                             │
│  ─────────────────────────────────────────────────────────  │
│                                                             │
│  FASE 3 (Semana 4+)                                        │
│  ──────────────────                                        │
│  Decisão: Expandir dashboard OU contribuir ao Coolify     │
│  • Se dashboard próprio: adicionar features gradualmente  │
│  • Se contribuir: abrir issue, discutir, implementar PR   │
│                                                             │
│  Entregável: Depende da decisão                           │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

---

## Próximos Passos por Opção

### Se escolher Opção 1 (CLI + API):

```bash
# 1. Criar estrutura
touch lib/coolify-api.sh

# 2. Implementar funções básicas
# - coolify_api_request()
# - coolify_list_apps()
# - coolify_stop_app()
# - coolify_start_app()
# - coolify_list_databases()
# - coolify_health_check()

# 3. Adicionar config
echo "COOLIFY_API_TOKEN=" >> config/config.env

# 4. Adaptar backup-coolify.sh para usar API

# 5. Testar
./backup/backup-coolify.sh --dry-run
```

### Se escolher Opção 2 (CLI + Web):

```bash
# 1. Criar estrutura web
mkdir -p web/{static,templates}

# 2. Criar backend mínimo
cat > web/main.py << 'EOF'
from fastapi import FastAPI
from fastapi.staticfiles import StaticFiles
# ... implementação
EOF

# 3. Criar Dockerfile
# 4. Criar docker-compose.yml
# 5. Adicionar ao Coolify como serviço
```

### Se escolher Opção 3 (Dashboard completo):

```bash
# 1. Escolher framework frontend (Vue/Svelte/React)
# 2. Criar projeto com scaffolding
# 3. Definir design system
# 4. Implementar iterativamente
```

### Se escolher Opção 4 (Plugin Coolify):

```bash
# 1. Abrir issue no GitHub
# https://github.com/coollabsio/coolify/issues/new

# 2. Título sugerido:
# "Feature Request: Built-in Backup & Migration Tools"

# 3. Descrever funcionalidades desejadas
# 4. Aguardar feedback
# 5. Se positivo, fazer fork e implementar
```

---

## Decisão

**Data para decisão:** ____/____/______

**Opção escolhida:** [ ] 1  [ ] 2  [ ] 3  [ ] 4

**Justificativa:**

_____________________________________________

_____________________________________________

_____________________________________________

**Primeiro passo após decisão:**

_____________________________________________

---

## Referências

- [Coolify API Reference](https://coolify.io/docs/api-reference/api/)
- [Coolify GitHub](https://github.com/coollabsio/coolify)
- [FastAPI Documentation](https://fastapi.tiangolo.com/)
- [HTMX](https://htmx.org/) - Frontend sem JavaScript complexo
