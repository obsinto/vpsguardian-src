# Guia de Resolução de Problemas: Sessão e Cookies no Laravel

> **Contexto**: Problemas encontrados após migração de aplicações Laravel para Coolify
> **Data**: 2026-03-03
> **Aplicações**: TopMix, AgilyGov

---

## 📋 Índice

1. [Resumo dos Problemas](#resumo-dos-problemas)
2. [Erro: ERR_CERT_AUTHORITY_INVALID](#erro-err_cert_authority_invalid)
3. [Erro: 419 Page Expired (CSRF)](#erro-419-page-expired-csrf)
4. [Configurações Críticas de Sessão](#configurações-críticas-de-sessão)
5. [Comandos Úteis para Diagnóstico](#comandos-úteis-para-diagnóstico)
6. [Checklist Preventivo](#checklist-preventivo)
7. [Notas Técnicas](#notas-técnicas)

---

## Resumo dos Problemas

Durante a migração de aplicações Laravel para ambiente Coolify com Traefik, foram encontrados os seguintes problemas:

1. **ERR_CERT_AUTHORITY_INVALID**: Aplicação forçando HTTPS em ambiente local sem certificado SSL válido
2. **419 Page Expired**: CSRF token não validado devido a configurações incorretas de sessão/cookies

---

## Erro: ERR_CERT_AUTHORITY_INVALID

### 🔴 Sintomas

```
Failed to load resource: net::ERR_CERT_AUTHORITY_INVALID
Uncaught (in promise) AxiosError: Network Error
url: "https://topmix.localhost/login"
```

- Navegador tenta usar HTTPS mesmo acessando via HTTP
- JavaScript (Ziggy/Inertia) gera URLs com `https://`
- Todos os recursos (CSS, JS) falham ao carregar

### 🔍 Diagnóstico

#### 1. Verificar APP_URL e APP_ENV

```bash
# Verificar variáveis de ambiente
docker exec CONTAINER_ID env | grep -E "APP_URL|APP_ENV|FORCE_HTTPS"
```

**Saída problemática:**
```
APP_URL=http://topmix.localhost
APP_ENV=production           # ← PROBLEMA
FORCE_HTTPS=true             # ← PROBLEMA
```

#### 2. Verificar URLs geradas pelo Ziggy

```bash
curl -s http://topmix.localhost/login | grep -o "url\":\"[^\"]*" | head -1
```

**Saída problemática:**
```
url":"https:\/\/topmix.localhost    # ← HTTPS forçado
```

#### 3. Verificar código do AppServiceProvider

```bash
docker exec CONTAINER_ID cat /app/app/Providers/AppServiceProvider.php
```

**Código problemático:**
```php
public function boot(): void
{
    // Força HTTPS em produção
    if ($this->app->environment('production')) {
        URL::forceScheme('https');  // ← ESTE É O PROBLEMA
    }
}
```

### ✅ Solução

#### Opção 1: Mudar Ambiente para Local (Recomendado para desenvolvimento)

No **Coolify**, altere as variáveis de ambiente:

```env
# De:
APP_ENV=production
FORCE_HTTPS=true

# Para:
APP_ENV=local
FORCE_HTTPS=false
```

#### Opção 2: Aceitar Certificado Autoassinado (Se quiser manter HTTPS)

1. Acesse `https://dominio.localhost` (com HTTPS)
2. Clique em "Avançado" → "Continuar para o site (não seguro)"
3. O navegador aceitará temporariamente o certificado

#### Opção 3: Modificar AppServiceProvider (Mais controle)

Altere o código para verificar a variável `FORCE_HTTPS`:

```php
public function boot(): void
{
    Vite::prefetch(concurrency: 3);

    // Força HTTPS apenas se explicitamente configurado
    if (config('app.force_https', false)) {
        URL::forceScheme('https');
    }
}
```

E configure no `.env`:
```env
FORCE_HTTPS=false
```

### 🔄 Passos Pós-Correção

Após alterar as variáveis no Coolify:

```bash
# 1. Aguardar novo deploy ou pegar novo container ID
docker ps --filter "name=CONTAINER_NAME"

# 2. Limpar todos os caches
docker exec CONTAINER_ID php artisan cache:clear
docker exec CONTAINER_ID php artisan config:clear
docker exec CONTAINER_ID php artisan route:clear
docker exec CONTAINER_ID php artisan view:clear

# 3. Recriar caches
docker exec CONTAINER_ID php artisan config:cache
docker exec CONTAINER_ID php artisan route:cache

# 4. Reiniciar container
docker restart CONTAINER_ID

# 5. Verificar se URLs estão corretas
curl -s http://dominio.localhost/login | grep -o "url\":\"[^\"]*"
# Deve retornar: url":"http:\/\/dominio.localhost
```

---

## Erro: 419 Page Expired (CSRF)

### 🔴 Sintomas

```
POST http://agily.localhost/login
Status Code: 419
Page Expired
```

- Formulário de login retorna erro 419
- CSRF token não está sendo validado
- Cookies de sessão não estão sendo salvos/enviados pelo navegador

### 🔍 Diagnóstico

#### 1. Verificar Configurações de Sessão

```bash
docker exec CONTAINER_ID env | grep -E "SESSION_|APP_URL|APP_ENV"
```

**Configurações problemáticas encontradas:**

```env
SESSION_DOMAIN=http://agily.localhost     # ❌ NÃO deve ter http://
SESSION_SECURE_COOKIE=true                # ❌ Deve ser false para HTTP
SESSION_PARTITIONED_COOKIE=true           # ❌ Pode causar problemas em alguns navegadores
SESSION_DRIVER=database                   # ✅ OK
SESSION_ENCRYPT=true                      # ✅ OK
SESSION_SAME_SITE=lax                     # ✅ OK
SESSION_HTTP_ONLY=false                   # ⚠️ Depende da aplicação
APP_URL=http://agily.localhost            # ✅ OK
```

#### 2. Verificar se Cookies Estão Sendo Enviados

```bash
curl -s -I http://agily.localhost/login | grep -i "set-cookie"
```

**Saída esperada:**
```
Set-Cookie: XSRF-TOKEN=...; domain=agily.localhost; samesite=lax
Set-Cookie: agilygov_session=...; domain=agily.localhost; samesite=lax
```

#### 3. Verificar CSRF Token no HTML

```bash
curl -s http://agily.localhost/login | grep -o 'csrf-token" content="[^"]*"'
```

**Saída esperada:**
```
csrf-token" content="sCmYSbmfKqkM9jWk3hfYTeHjEHKKUg0gGnXk6GiI"
```

#### 4. Verificar Cookies no Navegador

**DevTools (F12)** → **Application** → **Cookies** → `http://agily.localhost`

Deve aparecer:
- `XSRF-TOKEN`
- `agilygov_session` (ou nome da sua aplicação)

**Se os cookies NÃO aparecerem**, o navegador está bloqueando devido a configurações incorretas.

### ✅ Solução

#### Correções Necessárias no Coolify

Altere as seguintes variáveis de ambiente:

```env
# 1. SESSION_DOMAIN - REMOVER protocolo http://
# De:
SESSION_DOMAIN=http://agily.localhost
# Para:
SESSION_DOMAIN=agily.localhost

# 2. SESSION_SECURE_COOKIE - Deve ser false para HTTP
# De:
SESSION_SECURE_COOKIE=true
# Para:
SESSION_SECURE_COOKIE=false

# 3. SESSION_PARTITIONED_COOKIE - Desativar se houver problemas
# De:
SESSION_PARTITIONED_COOKIE=true
# Para:
SESSION_PARTITIONED_COOKIE=false
```

### 🔄 Passos Pós-Correção

```bash
# 1. Após salvar no Coolify, pegar novo container ID
docker ps --filter "name=CONTAINER_NAME"

# 2. Limpar caches
docker exec CONTAINER_ID php artisan cache:clear
docker exec CONTAINER_ID php artisan config:clear
docker exec CONTAINER_ID php artisan view:clear

# 3. Recriar cache de configuração
docker exec CONTAINER_ID php artisan config:cache

# 4. Verificar se cookies estão sendo enviados
curl -s -I http://agily.localhost/login | grep -i "set-cookie"
```

#### No Navegador

1. **Limpar cookies antigos**:
   - DevTools (F12) → **Application** → **Cookies**
   - Delete todos os cookies de `agily.localhost`

2. **Limpar cache do navegador**:
   - Ctrl+Shift+Delete (ou Cmd+Shift+Delete no Mac)
   - Ou usar aba anônima/privada

3. **Recarregar página**:
   - Acesse `http://agily.localhost/login`
   - Verifique se os cookies aparecem no DevTools
   - Tente fazer login

---

## Configurações Críticas de Sessão

### ⚙️ Variáveis de Ambiente Recomendadas

#### Para Ambiente Local (development/local)

```env
# Ambiente
APP_ENV=local
APP_DEBUG=true
APP_URL=http://seu-app.localhost

# Segurança HTTPS
FORCE_HTTPS=false

# Sessão
SESSION_DRIVER=database              # ou file, redis, etc
SESSION_LIFETIME=120                 # minutos
SESSION_DOMAIN=seu-app.localhost     # SEM http:// ou https://
SESSION_SECURE_COOKIE=false          # false para HTTP
SESSION_PARTITIONED_COOKIE=false     # evita problemas de compatibilidade
SESSION_SAME_SITE=lax                # lax ou strict
SESSION_HTTP_ONLY=true               # recomendado para segurança
SESSION_ENCRYPT=false                # opcional, pode ser true
```

#### Para Ambiente de Produção (HTTPS)

```env
# Ambiente
APP_ENV=production
APP_DEBUG=false
APP_URL=https://seu-app.com

# Segurança HTTPS
FORCE_HTTPS=true

# Sessão
SESSION_DRIVER=redis                 # recomendado para produção
SESSION_LIFETIME=120
SESSION_DOMAIN=seu-app.com           # SEM protocolo
SESSION_SECURE_COOKIE=true           # true para HTTPS
SESSION_PARTITIONED_COOKIE=false     # ou true dependendo do caso
SESSION_SAME_SITE=lax                # ou strict para mais segurança
SESSION_HTTP_ONLY=true               # sempre true em produção
SESSION_ENCRYPT=true                 # recomendado para produção
```

### 🔐 Explicação das Configurações

| Variável | Valores | Quando Usar |
|----------|---------|-------------|
| `SESSION_DOMAIN` | `exemplo.com` (sem protocolo) | **Sempre** sem `http://` ou `https://` |
| `SESSION_SECURE_COOKIE` | `true` / `false` | `false` para HTTP, `true` para HTTPS |
| `SESSION_PARTITIONED_COOKIE` | `true` / `false` | `false` se houver problemas de compatibilidade |
| `SESSION_SAME_SITE` | `lax` / `strict` / `none` | `lax` é mais compatível, `strict` mais seguro |
| `SESSION_HTTP_ONLY` | `true` / `false` | `true` previne acesso via JavaScript (mais seguro) |
| `SESSION_ENCRYPT` | `true` / `false` | `true` criptografa dados da sessão (recomendado) |
| `SESSION_DRIVER` | `file` / `database` / `redis` | `redis` para produção, `file`/`database` para dev |

---

## Comandos Úteis para Diagnóstico

### 🔍 Verificação Rápida de Container

```bash
# Listar containers ativos
docker ps

# Buscar container por label Traefik
docker ps --format "{{.ID}}" | xargs -I {} sh -c \
  'echo "=== {} ===" && docker inspect {} | jq -r \
  ".[0].Config.Labels | to_entries | map(select(.key | startswith(\"traefik\"))) | \
  .[] | \"\(.key)=\(\(.value)\""' | grep -B 1 "SEU_DOMINIO"

# Verificar variáveis de ambiente
docker exec CONTAINER_ID env | grep -E "SESSION_|APP_URL|APP_ENV|FORCE_HTTPS"
```

### 🧹 Limpeza de Cache Laravel

```bash
# Limpar todos os caches (usar após mudanças de configuração)
docker exec CONTAINER_ID php artisan cache:clear
docker exec CONTAINER_ID php artisan config:clear
docker exec CONTAINER_ID php artisan route:clear
docker exec CONTAINER_ID php artisan view:clear

# Recriar caches otimizados
docker exec CONTAINER_ID php artisan config:cache
docker exec CONTAINER_ID php artisan route:cache
docker exec CONTAINER_ID php artisan view:cache
```

### 🍪 Teste de Cookies e CSRF

```bash
# Verificar se servidor envia cookies
curl -s -I http://dominio.localhost/login | grep -i "set-cookie"

# Verificar CSRF token no HTML
curl -s http://dominio.localhost/login | grep -o 'csrf-token" content="[^"]*"'

# Verificar URLs geradas pelo Ziggy
curl -s http://dominio.localhost/login | grep -o "url\":\"[^\"]*" | head -3

# Testar código de resposta
curl -s -o /dev/null -w "%{http_code}" http://dominio.localhost/login
```

### 🔄 Reiniciar e Verificar

```bash
# Reiniciar container
docker restart CONTAINER_ID

# Aguardar container ficar healthy
sleep 5 && docker ps --filter "name=CONTAINER_NAME" --format "{{.Status}}"

# Verificar logs em tempo real
docker logs -f CONTAINER_ID

# Verificar últimas linhas de log
docker logs CONTAINER_ID --tail 50
```

---

## Checklist Preventivo

### ✅ Antes de Deploy/Migração

- [ ] Confirmar `APP_ENV` correto (`local` para dev, `production` para prod)
- [ ] Verificar `APP_URL` com protocolo correto (`http://` ou `https://`)
- [ ] Verificar `SESSION_DOMAIN` **SEM** protocolo (apenas `dominio.com`)
- [ ] Configurar `SESSION_SECURE_COOKIE`:
  - `false` para HTTP/localhost
  - `true` para HTTPS/produção
- [ ] Configurar `FORCE_HTTPS`:
  - `false` para ambiente local
  - `true` para produção com SSL
- [ ] Testar cookies no navegador antes de publicar

### ✅ Após Deploy/Migração

- [ ] Limpar todos os caches Laravel
- [ ] Recriar caches otimizados
- [ ] Reiniciar container
- [ ] Verificar se cookies estão sendo enviados (`curl -I`)
- [ ] Verificar se CSRF token está no HTML
- [ ] Testar login em aba anônima
- [ ] Verificar DevTools → Application → Cookies

### ✅ Se Houver Problemas

- [ ] Verificar logs do container (`docker logs`)
- [ ] Verificar variáveis de ambiente atuais
- [ ] Comparar com configurações recomendadas deste guia
- [ ] Limpar cookies do navegador
- [ ] Testar em navegador diferente
- [ ] Verificar código do `AppServiceProvider.php`

---

## Notas Técnicas

### 🎯 Por que `SESSION_DOMAIN` não pode ter protocolo?

O atributo `domain` do cookie HTTP **não aceita protocolo**. Deve ser apenas o domínio:

```
✅ Correto:   domain=exemplo.com
❌ Incorreto: domain=http://exemplo.com
```

Se você colocar o protocolo, o navegador não reconhece como domínio válido e **não salva o cookie**.

### 🔒 Por que `SESSION_SECURE_COOKIE=true` quebra HTTP?

A flag `Secure` no cookie instrui o navegador a **só enviar o cookie via HTTPS**. Se você está usando HTTP:

- Cookie é enviado pelo servidor ✅
- Navegador salva o cookie ✅
- Navegador **NÃO envia o cookie de volta** em requisições HTTP ❌
- CSRF token não é validado ❌
- Resultado: **419 Page Expired** ❌

**Solução**: `SESSION_SECURE_COOKIE=false` para ambientes HTTP.

### 🧩 O que é `SESSION_PARTITIONED_COOKIE`?

Esta configuração adiciona o atributo `Partitioned` ao cookie, que faz parte da [CHIPS (Cookies Having Independent Partitioned State)](https://developers.google.com/privacy-sandbox/3pcd/chips).

- **Objetivo**: Melhorar privacidade separando cookies por contexto
- **Problema**: Alguns navegadores ainda não suportam completamente
- **Recomendação**: Use `false` se houver problemas de compatibilidade

### 📦 Diferença entre `SESSION_DRIVER`

| Driver | Quando Usar | Prós | Contras |
|--------|-------------|------|---------|
| `file` | Desenvolvimento local | Simples, sem dependências | Não escala, lento com muitos usuários |
| `database` | Apps pequenas/médias | Persistente, fácil de debugar | Mais lento que Redis |
| `redis` | Produção/alta carga | Muito rápido, escalável | Requer Redis instalado |
| `cookie` | Casos específicos | Não precisa servidor | Limite de 4KB, menos seguro |

### 🔄 Ciclo de Vida do CSRF Token

1. **Usuário acessa** `/login` (GET)
2. **Laravel gera** CSRF token e salva na sessão
3. **Laravel envia** cookies: `XSRF-TOKEN` + `app_session`
4. **Navegador salva** os cookies
5. **Frontend inclui** token no formulário/header
6. **Usuário submete** formulário (POST)
7. **Navegador envia** cookies de volta
8. **Laravel valida** se token do POST == token da sessão
9. **Se válido**: processa request ✅
10. **Se inválido**: retorna **419 Page Expired** ❌

**Se algum cookie não for salvo/enviado, o passo 8 falha!**

---

## 📚 Referências

- [Laravel Session Documentation](https://laravel.com/docs/11.x/session)
- [Laravel CSRF Protection](https://laravel.com/docs/11.x/csrf)
- [MDN - Set-Cookie](https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers/Set-Cookie)
- [CHIPS - Partitioned Cookies](https://developers.google.com/privacy-sandbox/3pcd/chips)
- [SameSite Cookie Attribute](https://web.dev/articles/samesite-cookies-explained)

---

## 📝 Changelog

| Data | Problema | Solução Aplicada |
|------|----------|------------------|
| 2026-03-03 | TopMix - ERR_CERT_AUTHORITY_INVALID | `APP_ENV=local`, `FORCE_HTTPS=false` |
| 2026-03-03 | AgilyGov - 419 Page Expired | `SESSION_DOMAIN` sem protocolo, `SESSION_SECURE_COOKIE=false`, `SESSION_PARTITIONED_COOKIE=false` |

---

**Criado por**: Claude Code
**Última atualização**: 2026-03-03
**Versão**: 1.0
