#!/bin/bash
################################################################################
# Script: validar-pos-migracao.sh
# Propósito: Validar ambiente APÓS a migração no servidor de destino
# Uso: ./validar-pos-migracao.sh [--remote IP] [--use-api]
#
# Com --use-api: Usa API do Coolify para validação avançada de recursos
################################################################################

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LOG_PREFIX="[ Post-Migration Validator ]"
VALIDATION_LOG="/tmp/post-migration-validation-$(date +%Y%m%d_%H%M%S).log"

REMOTE_MODE=false
REMOTE_IP=""
REMOTE_USER="root"
REMOTE_PORT="22"
USE_COOLIFY_API=false

# Carregar configurações de destino de backup (inclui Coolify API)
if [ -f "/opt/vpsguardian/config/backup-destinations.conf" ]; then
    source "/opt/vpsguardian/config/backup-destinations.conf" 2>/dev/null
elif [ -f "$SCRIPT_DIR/../config/backup-destinations.conf" ]; then
    source "$SCRIPT_DIR/../config/backup-destinations.conf" 2>/dev/null
fi

# Carregar biblioteca de API do Coolify
source "$SCRIPT_DIR/../lib/coolify-api.sh" 2>/dev/null || true

log() {
    echo "$LOG_PREFIX [ $1 ] $2" | tee -a "$VALIDATION_LOG"
}

run_command() {
    if [ "$REMOTE_MODE" = true ]; then
        ssh -p "$REMOTE_PORT" "$REMOTE_USER@$REMOTE_IP" "$1" 2>/dev/null
    else
        eval "$1" 2>/dev/null
    fi
}

################################################################################
# PARSE ARGUMENTOS
################################################################################

while [[ $# -gt 0 ]]; do
    case $1 in
        --remote)
            REMOTE_MODE=true
            REMOTE_IP="$2"
            shift 2
            ;;
        --user)
            REMOTE_USER="$2"
            shift 2
            ;;
        --port)
            REMOTE_PORT="$2"
            shift 2
            ;;
        --use-api|--api)
            USE_COOLIFY_API=true
            shift
            ;;
        -h|--help)
            echo "Uso: $0 [OPÇÕES]"
            echo ""
            echo "Valida ambiente após migração do Coolify"
            echo ""
            echo "Opções:"
            echo "  --remote IP    Validar servidor remoto via SSH"
            echo "  --user USER    Usuário SSH (default: root)"
            echo "  --port PORT    Porta SSH (default: 22)"
            echo "  --use-api      Usar API do Coolify para validação avançada"
            echo "  -h, --help     Mostrar esta ajuda"
            echo ""
            exit 0
            ;;
        *)
            shift
            ;;
    esac
done

# Auto-detectar se API está disponível
if [ "$USE_COOLIFY_API" = false ] && [ "$COOLIFY_API_ENABLED" = "true" ] && [ -n "$COOLIFY_API_TOKEN" ]; then
    USE_COOLIFY_API=true
fi

################################################################################
# SETUP
################################################################################

echo "╔════════════════════════════════════════════════════════════╗"
echo "║          POST-MIGRATION VALIDATION CHECKLIST               ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

if [ "$REMOTE_MODE" = true ]; then
    if [ -z "$REMOTE_IP" ]; then
        read -p "$LOG_PREFIX [ INPUT ] Enter remote server IP: " REMOTE_IP
    fi

    log "INFO" "Validating REMOTE server: $REMOTE_USER@$REMOTE_IP:$REMOTE_PORT"

    # Testar conexão SSH
    if ssh -p "$REMOTE_PORT" -o ConnectTimeout=10 "$REMOTE_USER@$REMOTE_IP" "exit" 2>/dev/null; then
        log "✓" "SSH connection successful"
    else
        log "✗" "SSH connection FAILED"
        log "ERROR" "Cannot proceed with remote validation"
        exit 1
    fi
else
    log "INFO" "Validating LOCAL server"
fi

echo ""

ERRORS=0
WARNINGS=0
SUCCESS=0

################################################################################
# 1. VERIFICAR COOLIFY INSTALADO
################################################################################

log "INFO" "========== COOLIFY INSTALLATION =========="
echo ""

# Verificar diretório do Coolify
if run_command "test -d /data/coolify"; then
    log "✓" "Coolify directory exists"
    ((SUCCESS++))
else
    log "✗" "Coolify directory NOT found"
    ((ERRORS++))
fi

# Verificar .env
if run_command "test -f /data/coolify/source/.env"; then
    log "✓" ".env file exists"
    ((SUCCESS++))
else
    log "✗" ".env file NOT found"
    ((ERRORS++))
fi

# Verificar SSH keys
if run_command "test -d /data/coolify/ssh/keys"; then
    KEY_COUNT=$(run_command "find /data/coolify/ssh/keys -type f 2>/dev/null | wc -l")
    if [ "$KEY_COUNT" -gt 0 ]; then
        log "✓" "SSH keys restored: $KEY_COUNT key(s)"
        ((SUCCESS++))
    else
        log "⚠" "SSH keys directory exists but is empty"
        ((WARNINGS++))
    fi
else
    log "⚠" "SSH keys directory NOT found"
    ((WARNINGS++))
fi

echo ""

################################################################################
# 2. VERIFICAR CONTAINERS DOCKER
################################################################################

log "INFO" "========== DOCKER CONTAINERS =========="
echo ""

# Verificar se Docker está rodando
if run_command "docker ps >/dev/null 2>&1"; then
    log "✓" "Docker is running"
    ((SUCCESS++))
else
    log "✗" "Docker is NOT running"
    ((ERRORS++))
    # Se Docker não está rodando, não podemos continuar muitas verificações
fi

# Verificar containers do Coolify
CONTAINERS=("coolify" "coolify-db" "coolify-proxy")
RUNNING_CONTAINERS=0

for container in "${CONTAINERS[@]}"; do
    if run_command "docker ps --filter name=$container --format '{{.Names}}' | grep -q '^$container\$'"; then
        STATUS=$(run_command "docker ps --filter name=$container --format '{{.Status}}'")
        log "✓" "Container running: $container"
        log "INFO" "  Status: $STATUS"
        ((RUNNING_CONTAINERS++))
        ((SUCCESS++))
    else
        log "✗" "Container NOT running: $container"
        ((ERRORS++))
    fi
done

log "INFO" "Total Coolify containers running: $RUNNING_CONTAINERS/${#CONTAINERS[@]}"

echo ""

################################################################################
# 3. VERIFICAR BANCO DE DADOS
################################################################################

log "INFO" "========== DATABASE VALIDATION =========="
echo ""

# Verificar se banco está pronto
if run_command "docker exec coolify-db pg_isready -U coolify >/dev/null 2>&1"; then
    log "✓" "PostgreSQL is ready"
    ((SUCCESS++))

    # Verificar tamanho do banco
    DB_SIZE=$(run_command "docker exec coolify-db psql -U coolify -d coolify -t -c \"SELECT pg_size_pretty(pg_database_size('coolify'));\" 2>/dev/null | xargs")
    if [ -n "$DB_SIZE" ]; then
        log "✓" "Database size: $DB_SIZE"
        ((SUCCESS++))
    else
        log "⚠" "Could not determine database size"
        ((WARNINGS++))
    fi

    # Contar tabelas
    TABLE_COUNT=$(run_command "docker exec coolify-db psql -U coolify -d coolify -t -c \"SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public';\" 2>/dev/null | xargs")
    if [ -n "$TABLE_COUNT" ] && [ "$TABLE_COUNT" -gt 0 ]; then
        log "✓" "Database has $TABLE_COUNT tables"
        ((SUCCESS++))
    else
        log "⚠" "Could not count tables or database is empty"
        ((WARNINGS++))
    fi

    # Verificar algumas tabelas críticas do Coolify
    CRITICAL_TABLES=("users" "teams" "applications" "servers")
    for table in "${CRITICAL_TABLES[@]}"; do
        if run_command "docker exec coolify-db psql -U coolify -d coolify -t -c \"SELECT COUNT(*) FROM $table;\" >/dev/null 2>&1"; then
            ROW_COUNT=$(run_command "docker exec coolify-db psql -U coolify -d coolify -t -c \"SELECT COUNT(*) FROM $table;\" 2>/dev/null | xargs")
            log "✓" "Table '$table' exists with $ROW_COUNT row(s)"
            ((SUCCESS++))
        else
            log "⚠" "Table '$table' not found or has issues"
            ((WARNINGS++))
        fi
    done
else
    log "✗" "PostgreSQL is NOT ready"
    ((ERRORS++))
fi

echo ""

################################################################################
# 4. VERIFICAR CONECTIVIDADE
################################################################################

log "INFO" "========== CONNECTIVITY CHECKS =========="
echo ""

# Verificar porta 8000 (Coolify)
if run_command "nc -z localhost 8000 2>/dev/null"; then
    log "✓" "Coolify port 8000 is open"
    ((SUCCESS++))
else
    log "✗" "Coolify port 8000 is NOT open"
    ((ERRORS++))
fi

# Verificar porta 5432 (PostgreSQL) - deve estar acessível internamente
if run_command "docker exec coolify-db nc -z localhost 5432 2>/dev/null"; then
    log "✓" "PostgreSQL port 5432 is accessible"
    ((SUCCESS++))
else
    log "⚠" "PostgreSQL port 5432 check failed"
    ((WARNINGS++))
fi

# Testar HTTP do Coolify
HTTP_STATUS=$(run_command "curl -s -o /dev/null -w '%{http_code}' http://localhost:8000 2>/dev/null")
if [ -n "$HTTP_STATUS" ]; then
    if [ "$HTTP_STATUS" = "200" ] || [ "$HTTP_STATUS" = "302" ] || [ "$HTTP_STATUS" = "301" ]; then
        log "✓" "Coolify HTTP responds with status: $HTTP_STATUS"
        ((SUCCESS++))
    else
        log "⚠" "Coolify HTTP status: $HTTP_STATUS (unexpected)"
        ((WARNINGS++))
    fi
else
    log "✗" "Coolify HTTP does not respond"
    ((ERRORS++))
fi

echo ""

################################################################################
# 5. VERIFICAR LOGS
################################################################################

log "INFO" "========== CONTAINER LOGS CHECK =========="
echo ""

# Verificar logs do Coolify para erros críticos
ERROR_COUNT=$(run_command "docker logs coolify --tail 100 2>&1 | grep -i 'error\|fatal\|exception' | wc -l")
if [ "$ERROR_COUNT" -eq 0 ]; then
    log "✓" "No critical errors in Coolify logs"
    ((SUCCESS++))
elif [ "$ERROR_COUNT" -lt 5 ]; then
    log "⚠" "Found $ERROR_COUNT potential errors in Coolify logs (review recommended)"
    ((WARNINGS++))
else
    log "⚠" "Found $ERROR_COUNT potential errors in Coolify logs (review required)"
    ((WARNINGS++))
fi

# Verificar logs do banco
DB_ERROR_COUNT=$(run_command "docker logs coolify-db --tail 100 2>&1 | grep -i 'error\|fatal' | grep -v 'already exists\|does not exist' | wc -l")
if [ "$DB_ERROR_COUNT" -eq 0 ]; then
    log "✓" "No critical errors in database logs"
    ((SUCCESS++))
elif [ "$DB_ERROR_COUNT" -lt 5 ]; then
    log "⚠" "Found $DB_ERROR_COUNT potential errors in database logs (review recommended)"
    ((WARNINGS++))
else
    log "⚠" "Found $DB_ERROR_COUNT potential errors in database logs (review required)"
    ((WARNINGS++))
fi

echo ""

################################################################################
# 6. VERIFICAR VOLUMES
################################################################################

log "INFO" "========== DOCKER VOLUMES =========="
echo ""

COOLIFY_VOLUMES=$(run_command "docker volume ls --filter name=coolify -q 2>/dev/null")
if [ -n "$COOLIFY_VOLUMES" ]; then
    VOLUME_COUNT=$(echo "$COOLIFY_VOLUMES" | wc -l)
    log "✓" "Found $VOLUME_COUNT Coolify volume(s)"
    ((SUCCESS++))

    # Verificar se volumes têm conteúdo
    for volume in $COOLIFY_VOLUMES; do
        FILE_COUNT=$(run_command "docker run --rm -v $volume:/volume busybox find /volume -type f 2>/dev/null | wc -l")
        if [ "$FILE_COUNT" -gt 0 ]; then
            log "✓" "Volume '$volume' has $FILE_COUNT file(s)"
        else
            log "⚠" "Volume '$volume' appears empty"
            ((WARNINGS++))
        fi
    done
else
    log "⚠" "No Coolify volumes found"
    ((WARNINGS++))
fi

echo ""

################################################################################
# 7. VERIFICAR CONFIGURAÇÕES
################################################################################

log "INFO" "========== CONFIGURATION CHECKS =========="
echo ""

# Verificar APP_KEY
if run_command "test -f /data/coolify/source/.env"; then
    if run_command "grep -q '^APP_KEY=' /data/coolify/source/.env"; then
        log "✓" "APP_KEY is set in .env"
        ((SUCCESS++))
    else
        log "✗" "APP_KEY NOT found in .env"
        ((ERRORS++))
    fi

    # Verificar APP_PREVIOUS_KEYS (usado para descriptografia após migração)
    if run_command "grep -q '^APP_PREVIOUS_KEYS=' /data/coolify/source/.env"; then
        log "✓" "APP_PREVIOUS_KEYS is set (migration key preserved)"
        ((SUCCESS++))
    else
        log "⚠" "APP_PREVIOUS_KEYS not set (may cause decryption issues)"
        ((WARNINGS++))
    fi

    # Verificar APP_URL
    APP_URL=$(run_command "grep '^APP_URL=' /data/coolify/source/.env | cut -d'=' -f2-")
    if [ -n "$APP_URL" ]; then
        log "✓" "APP_URL is set: $APP_URL"
        ((SUCCESS++))
    else
        log "⚠" "APP_URL not set in .env"
        ((WARNINGS++))
    fi
else
    log "✗" ".env file not found"
    ((ERRORS++))
fi

echo ""

################################################################################
# 8. VERIFICAR VERSÃO DO COOLIFY
################################################################################

log "INFO" "========== VERSION CHECK =========="
echo ""

COOLIFY_IMAGE=$(run_command "docker ps --filter name=coolify --format '{{.Image}}' | grep coollabsio/coolify | head -n1")
if [ -n "$COOLIFY_IMAGE" ]; then
    log "✓" "Coolify version: $COOLIFY_IMAGE"
    ((SUCCESS++))
else
    log "⚠" "Could not detect Coolify version"
    ((WARNINGS++))
fi

echo ""

################################################################################
# 9. VERIFICAR RECURSOS DO SISTEMA
################################################################################

log "INFO" "========== SYSTEM RESOURCES =========="
echo ""

# Verificar uso de disco
DISK_USAGE=$(run_command "df -h / | awk 'NR==2 {print \$5}' | sed 's/%//'")
if [ -n "$DISK_USAGE" ]; then
    if [ "$DISK_USAGE" -lt 80 ]; then
        log "✓" "Disk usage: ${DISK_USAGE}%"
        ((SUCCESS++))
    else
        log "⚠" "Disk usage high: ${DISK_USAGE}%"
        ((WARNINGS++))
    fi
fi

# Verificar memória disponível
AVAILABLE_MEM=$(run_command "free -m | awk 'NR==2 {print \$7}'")
if [ -n "$AVAILABLE_MEM" ]; then
    if [ "$AVAILABLE_MEM" -gt 500 ]; then
        log "✓" "Available memory: ${AVAILABLE_MEM}MB"
        ((SUCCESS++))
    else
        log "⚠" "Low memory: ${AVAILABLE_MEM}MB"
        ((WARNINGS++))
    fi
fi

echo ""

################################################################################
# 10. TESTE FUNCIONAL BÁSICO
################################################################################

log "INFO" "========== FUNCTIONAL TESTS =========="
echo ""

# Testar criação de arquivo no volume (para verificar write permissions)
if run_command "docker exec coolify touch /tmp/test-write 2>/dev/null && docker exec coolify rm /tmp/test-write 2>/dev/null"; then
    log "✓" "Container has write permissions"
    ((SUCCESS++))
else
    log "⚠" "Write permission test failed"
    ((WARNINGS++))
fi

# Verificar se proxy está funcionando
if run_command "docker exec coolify-proxy nginx -t >/dev/null 2>&1"; then
    log "✓" "Nginx proxy configuration is valid"
    ((SUCCESS++))
else
    log "⚠" "Nginx proxy configuration may have issues"
    ((WARNINGS++))
fi

echo ""

################################################################################
# 11. VALIDAÇÃO VIA API DO COOLIFY (se disponível)
################################################################################

if [ "$USE_COOLIFY_API" = true ] && [ "$REMOTE_MODE" = false ]; then
    log "INFO" "========== COOLIFY API HEALTH CHECK =========="
    echo ""

    if type coolify_api_available &>/dev/null && coolify_api_available 2>/dev/null; then
        log "✓" "Coolify API está disponível"
        ((SUCCESS++))

        # Contar recursos
        if type coolify_count_resources &>/dev/null; then
            RESOURCE_COUNT=$(coolify_count_resources "summary" 2>/dev/null)
            if [ -n "$RESOURCE_COUNT" ]; then
                log "INFO" "Recursos detectados: $RESOURCE_COUNT"
            fi
        fi

        # Verificar applications
        log "INFO" "Verificando Applications..."
        APP_ISSUES=0
        if type coolify_check_applications_health &>/dev/null; then
            APPS_HEALTH=$(coolify_check_applications_health 2>/dev/null)
            if [ -n "$APPS_HEALTH" ]; then
                while IFS='|' read -r uuid name status health; do
                    if [ "$status" = "running" ]; then
                        log "✓" "  App: $name (running)"
                        ((SUCCESS++))
                    else
                        log "⚠" "  App: $name ($status)"
                        ((WARNINGS++))
                        ((APP_ISSUES++))
                    fi
                done <<< "$APPS_HEALTH"
            else
                log "INFO" "  Nenhuma application encontrada"
            fi
        fi

        # Verificar databases
        log "INFO" "Verificando Databases..."
        DB_ISSUES=0
        if type coolify_check_databases_health &>/dev/null; then
            DBS_HEALTH=$(coolify_check_databases_health 2>/dev/null)
            if [ -n "$DBS_HEALTH" ]; then
                while IFS='|' read -r uuid name type status is_public; do
                    if [ "$status" = "running" ]; then
                        log "✓" "  DB: $name ($type) - running"
                        ((SUCCESS++))
                    else
                        log "⚠" "  DB: $name ($type) - $status"
                        ((WARNINGS++))
                        ((DB_ISSUES++))
                    fi
                done <<< "$DBS_HEALTH"
            else
                log "INFO" "  Nenhum database encontrado"
            fi
        fi

        # Verificar services
        log "INFO" "Verificando Services..."
        SVC_ISSUES=0
        if type coolify_check_services_health &>/dev/null; then
            SVCS_HEALTH=$(coolify_check_services_health 2>/dev/null)
            if [ -n "$SVCS_HEALTH" ]; then
                while IFS='|' read -r uuid name status; do
                    if [ "$status" = "running" ]; then
                        log "✓" "  Service: $name (running)"
                        ((SUCCESS++))
                    else
                        log "⚠" "  Service: $name ($status)"
                        ((WARNINGS++))
                        ((SVC_ISSUES++))
                    fi
                done <<< "$SVCS_HEALTH"
            else
                log "INFO" "  Nenhum service encontrado"
            fi
        fi

        # Resumo da API
        TOTAL_ISSUES=$((APP_ISSUES + DB_ISSUES + SVC_ISSUES))
        if [ $TOTAL_ISSUES -eq 0 ]; then
            log "✓" "Todos os recursos do Coolify estão saudáveis via API"
            ((SUCCESS++))
        else
            log "⚠" "$TOTAL_ISSUES recurso(s) com problemas detectados via API"
        fi
    else
        log "⚠" "API do Coolify não disponível (validação via API ignorada)"
        log "INFO" "  Configure com: scripts-auxiliares/configurar-coolify-api.sh"
        ((WARNINGS++))
    fi

    echo ""
elif [ "$USE_COOLIFY_API" = true ] && [ "$REMOTE_MODE" = true ]; then
    log "INFO" "========== COOLIFY API HEALTH CHECK =========="
    log "⚠" "Validação via API não suportada em modo remoto"
    log "INFO" "  Execute localmente no servidor de destino para usar API"
    ((WARNINGS++))
    echo ""
fi

################################################################################
# RESUMO FINAL
################################################################################

echo "╔════════════════════════════════════════════════════════════╗"
echo "║                   VALIDATION SUMMARY                       ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

TOTAL_CHECKS=$((SUCCESS + WARNINGS + ERRORS))

echo "  ✅ Successful checks: $SUCCESS"
echo "  ⚠️  Warnings: $WARNINGS"
echo "  ❌ Errors: $ERRORS"
echo "  📊 Total checks: $TOTAL_CHECKS"
echo ""

if [ $ERRORS -eq 0 ] && [ $WARNINGS -eq 0 ]; then
    log "SUCCESS" "Migration validation PASSED! Coolify is fully operational."
    echo ""
    log "INFO" "Next steps:"
    echo "  1. Access Coolify: http://$REMOTE_IP:8000 (or http://localhost:8000)"
    echo "  2. Login with your credentials"
    echo "  3. Verify all applications are listed"
    echo "  4. Update DNS records to point to new server"
    echo "  5. Test all applications"
    EXIT_CODE=0
elif [ $ERRORS -eq 0 ]; then
    log "WARNING" "Migration validation PASSED with $WARNINGS warning(s)"
    echo ""
    log "INFO" "Review warnings above"
    log "INFO" "Coolify should be functional but some features may need attention"
    echo ""
    log "INFO" "Next steps:"
    echo "  1. Review warnings in the log"
    echo "  2. Access Coolify and verify functionality"
    echo "  3. Check container logs if needed: docker logs coolify"
    EXIT_CODE=0
else
    log "ERROR" "Migration validation FAILED with $ERRORS error(s) and $WARNINGS warning(s)"
    echo ""
    log "INFO" "Critical issues detected - fix before using Coolify"
    log "INFO" "Common issues:"
    echo "  - Coolify containers not running: docker compose up -d"
    echo "  - Database not ready: docker restart coolify-db"
    echo "  - APP_KEY missing: check /data/coolify/source/.env"
    echo ""
    log "INFO" "Check detailed logs:"
    echo "  - docker logs coolify"
    echo "  - docker logs coolify-db"
    EXIT_CODE=1
fi

echo ""
log "INFO" "Full validation log saved to: $VALIDATION_LOG"
echo ""

# Se estiver em modo remoto, copiar log para máquina local
if [ "$REMOTE_MODE" = true ]; then
    LOCAL_LOG="/tmp/post-migration-remote-$(date +%Y%m%d_%H%M%S).log"
    cp "$VALIDATION_LOG" "$LOCAL_LOG" 2>/dev/null || true
    log "INFO" "Local copy of log: $LOCAL_LOG"
fi

exit $EXIT_CODE
