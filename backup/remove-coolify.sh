#!/bin/bash
################################################################################
# Script: remove-coolify.sh
# Propósito: Remove completamente a instalação do Coolify (para reinstalação limpa)
#
# Uso: ./remove-coolify.sh [--force]
#
# ATENÇÃO: Este script é destrutivo! Remove containers, volumes e dados.
#          Use apenas antes de uma reinstalação/restauração completa.
#
# Versão: 1.0.0
################################################################################

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh" 2>/dev/null || {
    log_info() { echo -e "\033[0;34m[ INFO ]\033[0m $*"; }
    log_success() { echo -e "\033[0;32m[ OK ]\033[0m $*"; }
    log_error() { echo -e "\033[0;31m[ ERRO ]\033[0m $*"; }
    log_warning() { echo -e "\033[1;33m[ AVISO ]\033[0m $*"; }
    log_section() { echo ""; echo -e "\033[0;34m========== $* ==========\033[0m"; echo ""; }
}

### ========== CONFIGURAÇÃO ==========
FORCE_MODE=false
COOLIFY_DATA_DIR="/data/coolify"

### ========== PARSE ARGUMENTOS ==========
while [[ $# -gt 0 ]]; do
    case $1 in
        --force|-f)
            FORCE_MODE=true
            shift
            ;;
        -h|--help)
            cat << 'EOF'
================================================================================
     REMOVER COOLIFY COMPLETAMENTE
================================================================================

DESCRIÇÃO:
  Remove completamente a instalação do Coolify para permitir
  reinstalação limpa ou restauração de backup.

USO:
  ./remove-coolify.sh [--force]

OPÇÕES:
  --force, -f    Pular confirmação (CUIDADO!)
  -h, --help     Mostrar esta ajuda

O QUE SERÁ REMOVIDO:
  - Todos os containers do Coolify (coolify, coolify-db, coolify-redis, etc.)
  - Volumes do Coolify (coolify-db, coolify-redis)
  - Diretório de dados (/data/coolify)
  - Redes Docker do Coolify

O QUE NÃO SERÁ AFETADO:
  - Containers das suas aplicações (gerenciados pelo Coolify)
  - Volumes das suas aplicações
  - Backups em /var/backups/vpsguardian
  - Docker em si

AVISO:
  Após remover, você precisará reinstalar o Coolify:
  curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash

EOF
            exit 0
            ;;
        *)
            log_error "Opção desconhecida: $1"
            exit 1
            ;;
    esac
done

### ========== VERIFICAR ROOT ==========
if [ "$EUID" -ne 0 ]; then
    log_error "Este script deve ser executado como root"
    exit 1
fi

### ========== BANNER ==========
echo ""
echo "=============================================================="
echo "     REMOVER COOLIFY COMPLETAMENTE"
echo "=============================================================="
echo ""

### ========== VERIFICAR SE COOLIFY EXISTE ==========
log_section "Verificando Instalação Atual"

COOLIFY_CONTAINERS=$(docker ps -a --filter "name=coolify" --format '{{.Names}}' 2>/dev/null | wc -l)
COOLIFY_VOLUMES=$(docker volume ls --filter "name=coolify" --format '{{.Name}}' 2>/dev/null | wc -l)
COOLIFY_DATA_EXISTS=false
[ -d "$COOLIFY_DATA_DIR" ] && COOLIFY_DATA_EXISTS=true

echo "Containers Coolify encontrados: $COOLIFY_CONTAINERS"
echo "Volumes Coolify encontrados: $COOLIFY_VOLUMES"
echo "Diretório $COOLIFY_DATA_DIR existe: $COOLIFY_DATA_EXISTS"
echo ""

if [ "$COOLIFY_CONTAINERS" -eq 0 ] && [ "$COOLIFY_VOLUMES" -eq 0 ] && [ "$COOLIFY_DATA_EXISTS" = false ]; then
    log_warning "Nenhuma instalação do Coolify encontrada"
    exit 0
fi

### ========== LISTAR O QUE SERÁ REMOVIDO ==========
log_section "O Que Será Removido"

echo "CONTAINERS:"
docker ps -a --filter "name=coolify" --format '  - {{.Names}} ({{.Status}})' 2>/dev/null || echo "  (nenhum)"
echo ""

echo "VOLUMES:"
docker volume ls --filter "name=coolify" --format '  - {{.Name}}' 2>/dev/null || echo "  (nenhum)"
echo ""

echo "DIRETÓRIOS:"
if [ -d "$COOLIFY_DATA_DIR" ]; then
    echo "  - $COOLIFY_DATA_DIR ($(du -sh "$COOLIFY_DATA_DIR" 2>/dev/null | cut -f1))"
else
    echo "  (nenhum)"
fi
echo ""

### ========== CONFIRMAÇÃO ==========
if [ "$FORCE_MODE" = false ]; then
    echo ""
    log_warning "ATENÇÃO: Esta operação é IRREVERSÍVEL!"
    log_warning "Todos os dados do Coolify serão PERMANENTEMENTE removidos."
    echo ""
    read -p "Digite 'REMOVER' para confirmar: " confirm

    if [ "$confirm" != "REMOVER" ]; then
        log_info "Operação cancelada"
        exit 0
    fi
fi

### ========== REMOVER CONTAINERS ==========
log_section "Removendo Containers"

# Parar containers
RUNNING_CONTAINERS=$(docker ps -q --filter "name=coolify" 2>/dev/null)
if [ -n "$RUNNING_CONTAINERS" ]; then
    log_info "Parando containers..."
    docker stop $RUNNING_CONTAINERS 2>/dev/null || true
    log_success "Containers parados"
fi

# Remover containers
ALL_CONTAINERS=$(docker ps -aq --filter "name=coolify" 2>/dev/null)
if [ -n "$ALL_CONTAINERS" ]; then
    log_info "Removendo containers..."
    docker rm -f $ALL_CONTAINERS 2>/dev/null || true
    log_success "Containers removidos"
else
    log_info "Nenhum container para remover"
fi

### ========== REMOVER VOLUMES ==========
log_section "Removendo Volumes"

COOLIFY_VOLS=$(docker volume ls -q --filter "name=coolify" 2>/dev/null)
if [ -n "$COOLIFY_VOLS" ]; then
    for vol in $COOLIFY_VOLS; do
        log_info "Removendo volume: $vol"
        docker volume rm "$vol" 2>/dev/null || log_warning "Falha ao remover $vol (pode estar em uso)"
    done
    log_success "Volumes removidos"
else
    log_info "Nenhum volume para remover"
fi

### ========== REMOVER REDES ==========
log_section "Removendo Redes Docker"

COOLIFY_NETS=$(docker network ls --filter "name=coolify" -q 2>/dev/null)
if [ -n "$COOLIFY_NETS" ]; then
    for net in $COOLIFY_NETS; do
        log_info "Removendo rede: $net"
        docker network rm "$net" 2>/dev/null || true
    done
    log_success "Redes removidas"
else
    log_info "Nenhuma rede para remover"
fi

### ========== REMOVER DIRETÓRIO DE DADOS ==========
log_section "Removendo Diretório de Dados"

if [ -d "$COOLIFY_DATA_DIR" ]; then
    log_info "Removendo $COOLIFY_DATA_DIR..."
    rm -rf "$COOLIFY_DATA_DIR"
    log_success "Diretório removido"
else
    log_info "Diretório não existe"
fi

### ========== VERIFICAÇÃO FINAL ==========
log_section "Verificação Final"

REMAINING_CONTAINERS=$(docker ps -a --filter "name=coolify" --format '{{.Names}}' 2>/dev/null | wc -l)
REMAINING_VOLUMES=$(docker volume ls --filter "name=coolify" --format '{{.Name}}' 2>/dev/null | wc -l)

if [ "$REMAINING_CONTAINERS" -eq 0 ] && [ "$REMAINING_VOLUMES" -eq 0 ] && [ ! -d "$COOLIFY_DATA_DIR" ]; then
    log_success "Coolify removido completamente!"
else
    log_warning "Alguns itens podem não ter sido removidos:"
    [ "$REMAINING_CONTAINERS" -gt 0 ] && echo "  - $REMAINING_CONTAINERS container(s)"
    [ "$REMAINING_VOLUMES" -gt 0 ] && echo "  - $REMAINING_VOLUMES volume(s)"
    [ -d "$COOLIFY_DATA_DIR" ] && echo "  - Diretório $COOLIFY_DATA_DIR"
fi

echo ""
echo "=============================================================="
echo "  PRÓXIMOS PASSOS"
echo "=============================================================="
echo ""
echo "  1. Instalar Coolify do zero:"
echo "     curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash"
echo ""
echo "  2. Ou restaurar de backup:"
echo "     ./restaurar-coolify.sh"
echo ""
echo "=============================================================="
echo ""
