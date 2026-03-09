#!/bin/bash
################################################################################
# Script: restore-databases-dump.sh
# Propósito: Restaurar bancos de dados de dumps SQL organizados em lotes
# Uso: ./restore-databases-dump.sh [--dir=PATH] [--auto]
#
# Suporta:
#   - MySQL/MariaDB (.sql ou .sql.gz)
#   - PostgreSQL (.sql ou .sql.gz)
#   - MongoDB (.tar.gz com mongodump)
################################################################################

# Carregar bibliotecas compartilhadas
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh" 2>/dev/null || {
    # Fallback se common.sh não existir
    log_info() { echo "[ INFO ] $*"; }
    log_success() { echo "[ OK ] $*"; }
    log_error() { echo "[ ERRO ] $*"; }
    log_warning() { echo "[ AVISO ] $*"; }
    log_section() { echo ""; echo "========== $* =========="; echo ""; }
}

# Carregar configurações do VPS Guardian
if [ -f "/opt/vpsguardian/config/config.env" ]; then
    source "/opt/vpsguardian/config/config.env" 2>/dev/null
fi
if [ -f "/opt/vpsguardian/config/default.conf" ]; then
    source "/opt/vpsguardian/config/default.conf" 2>/dev/null
elif [ -f "$SCRIPT_DIR/../config/default.conf" ]; then
    source "$SCRIPT_DIR/../config/default.conf" 2>/dev/null
fi

### ========== CONFIGURAÇÃO ==========
# Usar DATABASE_BACKUP_DIR da configuração ou padrão
DUMP_DIR="${DUMP_DIR:-${DATABASE_BACKUP_DIR:-/var/backups/vpsguardian/database-dumps}}"
AUTO_MODE=false
SELECTED_DUMPS=()

### ========== PARSE ARGUMENTOS ==========
while [[ $# -gt 0 ]]; do
    case $1 in
        --dir=*) DUMP_DIR="${1#*=}"; shift ;;
        --auto) AUTO_MODE=true; shift ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Restaurar bancos de dados de dumps SQL"
            echo ""
            echo "Options:"
            echo "  --dir=PATH       Diretório base (default: ${DATABASE_BACKUP_DIR:-/var/backups/vpsguardian/database-dumps})"
            echo "  --auto           Modo automático (restaurar todos)"
            echo "  -h, --help       Mostrar esta ajuda"
            echo ""
            echo "Formatos suportados:"
            echo "  - MySQL/MariaDB: *-mysql-*.sql.gz ou *-mysql-*.sql"
            echo "  - PostgreSQL: *-postgres-*.sql.gz ou *-postgres-*.sql"
            echo "  - MongoDB: *-mongodb-*.tar.gz"
            echo ""
            exit 0
            ;;
        *) log_error "Opção desconhecida: $1"; exit 1 ;;
    esac
done

### ========== FUNÇÕES DE DETECÇÃO ==========

detect_dump_type() {
    local filename="$1"
    if [[ "$filename" =~ -mysql- ]]; then echo "mysql"
    elif [[ "$filename" =~ -postgres- ]]; then echo "postgres"
    elif [[ "$filename" =~ -mongodb- ]]; then echo "mongodb"
    else echo "unknown"
    fi
}

extract_container_name() {
    local filename="$1"
    echo "$filename" | sed -E 's/-(mysql|postgres|mongodb)-[0-9_]+\.(sql\.gz|sql|tar\.gz)$//'
}

# Lógica ESTREITA e SEGURA: Só retorna se o container original estiver ONLINE
# Aguarda até 30 segundos se o container estiver reiniciando
find_matching_container() {
    local original_name="$1"
    local max_wait=30
    local waited=0

    while [ $waited -lt $max_wait ]; do
        # Verifica se está rodando
        if docker ps --format '{{.Names}}' | grep -q "^${original_name}$"; then
            echo "$original_name"
            return 0
        fi

        # Verifica se está reiniciando
        local status=$(docker inspect --format='{{.State.Status}}' "$original_name" 2>/dev/null)
        if [ "$status" = "restarting" ]; then
            if [ $waited -eq 0 ]; then
                log_warning "  Container '$original_name' está reiniciando, aguardando..."
            fi
            sleep 2
            waited=$((waited + 2))
        else
            # Container não existe ou está parado
            echo ""
            return 1
        fi
    done

    log_error "  Timeout aguardando container '$original_name' ficar pronto"
    echo ""
    return 1
}

# Credenciais lidas linha por linha para proteção contra caracteres especiais
get_container_credentials() {
    local container="$1"
    local db_type="$2"

    case "$db_type" in
        mysql)
            local root_pass=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$container" 2>/dev/null | grep -E '^(MYSQL|MARIADB)_ROOT_PASSWORD=' | cut -d'=' -f2 | head -n1)
            local db_name=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$container" 2>/dev/null | grep -E '^(MYSQL|MARIADB)_DATABASE=' | cut -d'=' -f2 | head -n1)
            echo "root"
            echo "$root_pass"
            echo "${db_name:-all}"
            ;;
        postgres)
            local pg_pass=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$container" 2>/dev/null | grep -E '^POSTGRES_PASSWORD=' | cut -d'=' -f2 | head -n1)
            local pg_user=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$container" 2>/dev/null | grep -E '^POSTGRES_USER=' | cut -d'=' -f2 | head -n1)
            local pg_db=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$container" 2>/dev/null | grep -E '^POSTGRES_DB=' | cut -d'=' -f2 | head -n1)
            echo "${pg_user:-postgres}"
            echo "$pg_pass"
            echo "${pg_db:-postgres}"
            ;;
        mongodb)
            local mongo_pass=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$container" 2>/dev/null | grep -E '^MONGO_INITDB_ROOT_PASSWORD=' | cut -d'=' -f2 | head -n1)
            local mongo_user=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$container" 2>/dev/null | grep -E '^MONGO_INITDB_ROOT_USERNAME=' | cut -d'=' -f2 | head -n1)
            echo "${mongo_user:-root}"
            echo "$mongo_pass"
            echo "admin"
            ;;
    esac
}

### ========== FUNÇÕES DE RESTORE (Higienizadas e Falantes) ==========

restore_mysql() {
    local container="$1"
    local dump_file="$2"
    local credentials="$3"

    # Higienização contra Enter invisível
    local user=$(echo "$credentials" | sed -n '1p' | tr -d '\r\n')
    local password=$(echo "$credentials" | sed -n '2p' | tr -d '\r\n')
    local database=$(echo "$credentials" | sed -n '3p' | tr -d '\r\n')

    if [ -z "$password" ]; then log_error "  Senha MySQL/MariaDB não encontrada"; return 1; fi
    if [ -z "$database" ]; then log_error "  Nome do banco de dados não encontrado"; return 1; fi

    local cmd="mysql"
    if docker exec "$container" which mariadb >/dev/null 2>&1; then cmd="mariadb"; fi

    log_info "  Credenciais: user=$user, database=$database"

    # Verificar se o banco já tem dados
    if [ "$database" != "all" ]; then
        local table_count=$(docker exec "$container" $cmd -u "$user" -p"$password" "$database" -e "SHOW TABLES;" 2>/dev/null | wc -l)
        if [ $table_count -gt 1 ]; then
            log_warning "  ⚠️  Banco '$database' já contém $((table_count - 1)) tabela(s)"
            log_info "  O dump contém DROP TABLE, então as tabelas serão substituídas"
        fi
    fi

    # Para MySQL, dumps criados com --add-drop-table incluem DROP TABLE IF EXISTS
    # Isso permite restaurar sobre dados existentes sem erro

    if [ "$database" = "all" ]; then
        log_info "  Restaurando todos os bancos de dados..."
        # Executa e joga qualquer erro para um arquivo de log temporário
        if [[ "$dump_file" =~ \.gz$ ]]; then
            gunzip -c "$dump_file" | docker exec -i "$container" $cmd -u "$user" -p"$password" 2> /tmp/erro-restore.log
        else
            cat "$dump_file" | docker exec -i "$container" $cmd -u "$user" -p"$password" 2> /tmp/erro-restore.log
        fi
    else
        log_info "  Restaurando banco de dados: $database"
        # Para banco específico, SEMPRE especifica o nome do banco
        if [[ "$dump_file" =~ \.gz$ ]]; then
            gunzip -c "$dump_file" | docker exec -i "$container" $cmd -u "$user" -p"$password" "$database" 2> /tmp/erro-restore.log
        else
            cat "$dump_file" | docker exec -i "$container" $cmd -u "$user" -p"$password" "$database" 2> /tmp/erro-restore.log
        fi
    fi

    local status=$?
    if [ $status -ne 0 ]; then
        echo "  🚨 ERRO DO MYSQL/MARIADB:"
        cat /tmp/erro-restore.log
        echo ""
        log_info "  Tentativa de diagnóstico:"
        log_info "    - Verificar se o banco '$database' existe no container"
        docker exec "$container" $cmd -u "$user" -p"$password" -e "SHOW DATABASES LIKE '$database';" 2>/dev/null | grep -v "^Database$" || echo "    ⚠️  Banco '$database' não encontrado!"
    fi
    return $status
}

restore_postgres() {
    local container="$1"
    local dump_file="$2"
    local credentials="$3"

    # Higienização contra Enter invisível
    local user=$(echo "$credentials" | sed -n '1p' | tr -d '\r\n')
    local password=$(echo "$credentials" | sed -n '2p' | tr -d '\r\n')
    local database=$(echo "$credentials" | sed -n '3p' | tr -d '\r\n')

    if [ -z "$password" ]; then log_error "  Senha PostgreSQL não encontrada"; return 1; fi
    if [ -z "$database" ]; then database="postgres"; log_warning "  Nome do banco não especificado, usando 'postgres'"; fi

    log_info "  Credenciais: user=$user, database=$database"

    # Verificar se o banco já tem dados
    local table_count=$(docker exec -e PGPASSWORD="$password" "$container" psql -U "$user" -d "$database" -t -c "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public';" 2>/dev/null | tr -d ' ')
    if [ -n "$table_count" ] && [ "$table_count" -gt 0 ]; then
        log_warning "  ⚠️  Banco '$database' já contém $table_count tabela(s)"
        log_info "  O dump contém DROP TABLE, então as tabelas serão substituídas"
    fi

    log_info "  Restaurando banco de dados PostgreSQL..."

    # O dump foi criado com --clean --if-exists, então contém DROP TABLE IF EXISTS
    # Isso permite restaurar sobre dados existentes sem erro

    # Executa e joga qualquer erro para um arquivo de log temporário
    if [[ "$dump_file" =~ \.gz$ ]]; then
        gunzip -c "$dump_file" | docker exec -i -e PGPASSWORD="$password" "$container" psql -U "$user" -d "$database" 2> /tmp/erro-restore.log
    else
        cat "$dump_file" | docker exec -i -e PGPASSWORD="$password" "$container" psql -U "$user" -d "$database" 2> /tmp/erro-restore.log
    fi

    local status=$?
    if [ $status -ne 0 ]; then
        echo "  🚨 ERRO DO POSTGRESQL:"
        cat /tmp/erro-restore.log
        echo ""
        log_info "  Tentativa de diagnóstico:"
        log_info "    - Verificar se o banco '$database' existe no container"
        docker exec -e PGPASSWORD="$password" "$container" psql -U "$user" -d postgres -c "\l" 2>/dev/null | grep "$database" || echo "    ⚠️  Banco '$database' não encontrado!"
    fi
    return $status
}

restore_mongodb() {
    local container="$1"
    local dump_archive="$2"
    local credentials="$3"

    local user=$(echo "$credentials" | sed -n '1p' | tr -d '\r\n')
    local password=$(echo "$credentials" | sed -n '2p' | tr -d '\r\n')

    log_info "  Extraindo dump MongoDB..."
    local temp_dir="/tmp/mongorestore-$$"
    mkdir -p "$temp_dir"
    tar -xzf "$dump_archive" -C "$temp_dir" 2>/dev/null

    local dump_dir=$(find "$temp_dir" -type d -name "*mongodb*" | head -1)
    if [ -z "$dump_dir" ]; then dump_dir="$temp_dir"; fi

    log_info "  Copiando para container..."
    docker exec "$container" rm -rf /tmp/mongorestore 2>/dev/null
    docker cp "$dump_dir/." "$container:/tmp/mongorestore/" >/dev/null 2>&1

    log_info "  Restaurando..."
    if [ -n "$password" ]; then
        docker exec "$container" mongorestore --username="$user" --password="$password" --authenticationDatabase=admin --drop /tmp/mongorestore/ >/dev/null 2>&1
    else
        docker exec "$container" mongorestore --drop /tmp/mongorestore/ >/dev/null 2>&1
    fi
    local result=$?

    docker exec "$container" rm -rf /tmp/mongorestore 2>/dev/null
    rm -rf "$temp_dir"
    return $result
}

### ========== APRESENTAÇÃO ==========
echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║         RESTAURAR BANCOS DE DADOS DE DUMPS SQL                 ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

### ========== MENU DE LOTES ==========
if [ ! -d "$DUMP_DIR" ]; then
    log_warning "Diretório de backups não existe: $DUMP_DIR"
    log_info "Criando diretório..."
    mkdir -p "$DUMP_DIR"

    if [ $? -eq 0 ]; then
        log_success "Diretório criado com sucesso"
    else
        log_error "Falha ao criar diretório: $DUMP_DIR"
        exit 1
    fi
fi

# Detectar subdiretórios de lotes
LOTES=($(find "$DUMP_DIR" -mindepth 1 -maxdepth 1 -type d | sort -r))

# Verificar se há lotes disponíveis
if [ ${#LOTES[@]} -eq 0 ]; then
    echo ""
    log_warning "Nenhum lote de backup encontrado em: $DUMP_DIR"
    echo ""
    echo "Para criar backups, execute:"
    echo "  • Menu Principal → 2 (Backups) → 2 (Backup de Bancos via Dump SQL)"
    echo "  • Ou diretamente: $SCRIPT_DIR/migrar-databases-dump.sh --target=local --auto"
    echo ""
    exit 0
fi

if [ ${#LOTES[@]} -gt 0 ] && [ "$AUTO_MODE" = false ]; then
    log_section "Lotes de Backup Disponíveis"
    
    for i in "${!LOTES[@]}"; do
        nome_lote=$(basename "${LOTES[$i]}")
        qtd_arquivos=$(ls -1 "${LOTES[$i]}"/*.gz 2>/dev/null | wc -l)
        echo "  [$i] $nome_lote ($qtd_arquivos arquivos compactados)"
    done
    
    echo ""
    read -p "Selecione o número do lote para abrir (ou 'q' para sair): " sel_lote
    
    if [ "$sel_lote" = "q" ]; then exit 0; fi
    
    if [[ "$sel_lote" =~ ^[0-9]+$ ]] && [ "$sel_lote" -lt "${#LOTES[@]}" ]; then
        DUMP_DIR="${LOTES[$sel_lote]}"
        log_info "Lote selecionado: $(basename "$DUMP_DIR")"
    else
        log_error "Seleção inválida!"
        exit 1
    fi
fi

### ========== LISTAR DUMPS DISPONÍVEIS ==========
log_section "Dumps no Lote Selecionado"

DUMP_FILES=()
while IFS= read -r -d '' file; do
    DUMP_FILES+=("$file")
done < <(find "$DUMP_DIR" -type f \( -name "*-mysql-*.sql*" -o -name "*-postgres-*.sql*" -o -name "*-mongodb-*.tar.gz" \) -print0 2>/dev/null | sort -z)

if [ ${#DUMP_FILES[@]} -eq 0 ]; then
    log_warning "Nenhum dump encontrado em $DUMP_DIR"
    exit 0
fi

declare -A DUMP_INFO
INDEX=0

for dump_file in "${DUMP_FILES[@]}"; do
    filename=$(basename "$dump_file")
    db_type=$(detect_dump_type "$filename")
    container_name=$(extract_container_name "$filename")
    size=$(du -h "$dump_file" | cut -f1)
    date_modified=$(stat -c %y "$dump_file" 2>/dev/null | cut -d'.' -f1)

    # Destacar dumps do Coolify
    if [[ "$container_name" =~ coolify ]]; then
        echo "  [$INDEX] $filename ⚠️  COOLIFY"
        echo "         Tipo: $db_type | Container: $container_name | Tamanho: $size"
        echo "         Data: $date_modified"
        echo "         ⚠️  Este é o banco do Coolify - restaurar sobrescreve configurações do Coolify"
    else
        echo "  [$INDEX] $filename"
        echo "         Tipo: $db_type | Container: $container_name | Tamanho: $size"
        echo "         Data: $date_modified"
    fi
    echo ""

    DUMP_INFO["$INDEX,file"]="$dump_file"
    DUMP_INFO["$INDEX,type"]="$db_type"
    DUMP_INFO["$INDEX,container"]="$container_name"

    ((INDEX++))
done

log_info "Total: ${#DUMP_FILES[@]} dump(s) encontrado(s)"
echo ""

### ========== SELECIONAR DUMPS ==========
if [ "$AUTO_MODE" = true ]; then
    for ((i=0; i<${#DUMP_FILES[@]}; i++)); do
        SELECTED_DUMPS+=($i)
    done
else
    echo "════════════════════════════════════════════════════════════"
    echo "  💡 OPÇÕES DE RESTAURAÇÃO"
    echo "════════════════════════════════════════════════════════════"
    echo ""
    echo "  [1] Restaurar TODOS os dumps (incluindo Coolify)"
    echo "  [2] Restaurar TODOS EXCETO Coolify ⭐ RECOMENDADO"
    echo "  [3] Escolher dumps específicos manualmente"
    echo "  [0] Cancelar"
    echo ""
    read -p "Escolha uma opção (0-3): " restore_option

    case "$restore_option" in
        1)
            # Restaurar tudo
            log_info "Selecionado: Restaurar TODOS os dumps (incluindo Coolify)"
            for ((i=0; i<${#DUMP_FILES[@]}; i++)); do
                SELECTED_DUMPS+=($i)
            done
            ;;
        2)
            # Restaurar tudo exceto Coolify
            log_info "Selecionado: Restaurar TODOS EXCETO Coolify"
            for ((i=0; i<${#DUMP_FILES[@]}; i++)); do
                container_name="${DUMP_INFO["$i,container"]}"
                # Pular containers que tenham "coolify" no nome
                if [[ ! "$container_name" =~ coolify ]]; then
                    SELECTED_DUMPS+=($i)
                else
                    log_warning "  Pulando: $container_name (Coolify)"
                fi
            done
            ;;
        3)
            # Escolha manual
            echo ""
            echo "Digite os números separados por espaço (ex: 0 2 3)"
            echo "Ou digite 'all' para todos, 'q' para cancelar"
            echo ""
            read -p "Selecione os dumps: " selection

            if [ "$selection" = "q" ]; then
                log_info "Operação cancelada"
                exit 0
            elif [ "$selection" = "all" ]; then
                for ((i=0; i<${#DUMP_FILES[@]}; i++)); do
                    SELECTED_DUMPS+=($i)
                done
            else
                for num in $selection; do
                    if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -lt "${#DUMP_FILES[@]}" ]; then
                        SELECTED_DUMPS+=($num)
                    fi
                done
            fi
            ;;
        0|q|Q)
            log_info "Operação cancelada"
            exit 0
            ;;
        *)
            log_error "Opção inválida!"
            exit 1
            ;;
    esac
fi

if [ ${#SELECTED_DUMPS[@]} -eq 0 ]; then log_warning "Nenhum dump válido selecionado"; exit 0; fi

### ========== RESTAURAR DUMPS ==========
log_section "Restaurando Dumps"

SUCCESS_COUNT=0
FAIL_COUNT=0
OFFLINE_CONTAINERS=()
FAILED_CONTAINERS=()
OFFLINE_DUMPS=()

for idx in "${SELECTED_DUMPS[@]}"; do
    dump_file="${DUMP_INFO["$idx,file"]}"
    db_type="${DUMP_INFO["$idx,type"]}"
    target_container="${DUMP_INFO["$idx,container"]}"
    filename=$(basename "$dump_file")

    echo ""
    log_info "Processando: $filename"

    # Validação Severa: O container está online?
    if [ -z "$(find_matching_container "$target_container")" ]; then
        log_error "  O container original '$target_container' está OFFLINE ou não existe mais."
        log_info "  Pulando restauração para evitar corromper outros bancos."
        OFFLINE_CONTAINERS+=("$target_container")
        OFFLINE_DUMPS+=("$idx")
        ((FAIL_COUNT++))
        continue
    fi

    log_info "  Container destino: $target_container"
    log_info "  Tipo de banco: $db_type"
    credentials=$(get_container_credentials "$target_container" "$db_type")

    if [ -z "$credentials" ]; then
        log_error "  Não foi possível obter credenciais do container"
        FAILED_CONTAINERS+=("$target_container (sem credenciais)")
        ((FAIL_COUNT++))
        continue
    fi

    case "$db_type" in
        mysql)
            if restore_mysql "$target_container" "$dump_file" "$credentials"; then
                log_success "  Restaurado com sucesso!"
                ((SUCCESS_COUNT++))
            else
                log_error "  Falha na restauração."
                FAILED_CONTAINERS+=("$target_container (erro MySQL)")
                ((FAIL_COUNT++))
            fi
            ;;
        postgres)
            if restore_postgres "$target_container" "$dump_file" "$credentials"; then
                log_success "  Restaurado com sucesso!"
                ((SUCCESS_COUNT++))
            else
                log_error "  Falha na restauração."
                FAILED_CONTAINERS+=("$target_container (erro PostgreSQL)")
                ((FAIL_COUNT++))
            fi
            ;;
        mongodb)
            if restore_mongodb "$target_container" "$dump_file" "$credentials"; then
                log_success "  Restaurado com sucesso!"
                ((SUCCESS_COUNT++))
            else
                log_error "  Falha na restauração."
                FAILED_CONTAINERS+=("$target_container (erro MongoDB)")
                ((FAIL_COUNT++))
            fi
            ;;
        *)
            log_error "  Tipo de banco desconhecido"
            FAILED_CONTAINERS+=("$target_container (tipo desconhecido)")
            ((FAIL_COUNT++))
            ;;
    esac
done

### ========== RESUMO FINAL ==========
echo ""
log_section "RESUMO DO RESTORE"
echo ""
echo "  ✅ Restaurados com sucesso: $SUCCESS_COUNT"

if [ ${#OFFLINE_CONTAINERS[@]} -gt 0 ]; then
    echo "  ⏭️  Pulados (offline): ${#OFFLINE_CONTAINERS[@]}"
fi

if [ ${#FAILED_CONTAINERS[@]} -gt 0 ]; then
    echo "  ❌ Falhas (erros): ${#FAILED_CONTAINERS[@]}"
fi

echo ""

# Se todos foram restaurados com sucesso
if [ $FAIL_COUNT -eq 0 ]; then
    log_success "Todos os dumps foram processados perfeitamente!"
    exit 0
fi

# Se tem containers offline
if [ ${#OFFLINE_CONTAINERS[@]} -gt 0 ]; then
    echo "════════════════════════════════════════════════════════════"
    echo "  ⚠️  CONTAINERS OFFLINE QUE PRECISAM SER INICIADOS"
    echo "════════════════════════════════════════════════════════════"
    echo ""

    # Remover duplicatas
    UNIQUE_OFFLINE=($(printf '%s\n' "${OFFLINE_CONTAINERS[@]}" | sort -u))

    for container in "${UNIQUE_OFFLINE[@]}"; do
        echo "  📦 $container"
    done

    echo ""
    echo "⚠️  Para restaurar estes bancos de dados:"
    echo "  1. Acesse o painel do Coolify (https://seu-servidor)"
    echo "  2. Vá em 'Resources' ou 'Services'"
    echo "  3. Encontre e inicie os containers/aplicações correspondentes"
    echo "  4. Aguarde os containers ficarem 'healthy' (verde)"
    echo "  5. Execute novamente este script"
    echo ""
    echo "💡 Dica: Use 'docker ps -a | grep <nome-container>' para verificar o status"
    echo ""
fi

# Se tem containers com erro
if [ ${#FAILED_CONTAINERS[@]} -gt 0 ]; then
    echo "════════════════════════════════════════════════════════════"
    echo "  ❌ CONTAINERS COM ERRO NA RESTAURAÇÃO"
    echo "════════════════════════════════════════════════════════════"
    echo ""

    for container in "${FAILED_CONTAINERS[@]}"; do
        echo "  🔴 $container"
    done

    echo ""
    echo "⚠️  Estes containers apresentaram erros durante a restauração:"
    echo "  - Revise os logs acima para detalhes do erro"
    echo "  - Verifique credenciais do banco de dados"
    echo "  - Verifique se o banco de dados existe no container"
    echo "  - Verifique logs do container: docker logs <nome-container>"
    echo ""
fi

# Oferecer retry apenas se tem containers offline
if [ ${#OFFLINE_CONTAINERS[@]} -gt 0 ]; then
    read -p "Deseja tentar restaurar os dumps pendentes agora? (s/N): " retry
    retry=${retry,,}  # Converter para minúsculas

    if [ "$retry" = "s" ] || [ "$retry" = "sim" ] || [ "$retry" = "y" ] || [ "$retry" = "yes" ]; then
        echo ""
        log_info "Tentando novamente apenas os dumps que falharam..."
        echo ""

        # Resetar contadores
        RETRY_SUCCESS=0
        RETRY_FAIL=0

        for idx in "${OFFLINE_DUMPS[@]}"; do
            dump_file="${DUMP_INFO["$idx,file"]}"
            db_type="${DUMP_INFO["$idx,type"]}"
            target_container="${DUMP_INFO["$idx,container"]}"
            filename=$(basename "$dump_file")

            echo ""
            log_info "Processando: $filename"

            # Verificar se container está online agora
            if [ -z "$(find_matching_container "$target_container")" ]; then
                log_error "  Container '$target_container' ainda está offline"
                ((RETRY_FAIL++))
                continue
            fi

            log_info "  Container destino: $target_container (ONLINE!)"
            log_info "  Tipo de banco: $db_type"
            credentials=$(get_container_credentials "$target_container" "$db_type")

            if [ -z "$credentials" ]; then
                log_error "  Não foi possível obter credenciais"
                ((RETRY_FAIL++))
                continue
            fi

            case "$db_type" in
                mysql)
                    if restore_mysql "$target_container" "$dump_file" "$credentials"; then
                        log_success "  Restaurado com sucesso!"
                        ((RETRY_SUCCESS++))
                    else
                        log_error "  Falha na restauração."
                        ((RETRY_FAIL++))
                    fi
                    ;;
                postgres)
                    if restore_postgres "$target_container" "$dump_file" "$credentials"; then
                        log_success "  Restaurado com sucesso!"
                        ((RETRY_SUCCESS++))
                    else
                        log_error "  Falha na restauração."
                        ((RETRY_FAIL++))
                    fi
                    ;;
                mongodb)
                    if restore_mongodb "$target_container" "$dump_file" "$credentials"; then
                        log_success "  Restaurado com sucesso!"
                        ((RETRY_SUCCESS++))
                    else
                        log_error "  Falha na restauração."
                        ((RETRY_FAIL++))
                    fi
                    ;;
            esac
        done

        echo ""
        log_section "RESULTADO DO RETRY"
        echo "  ✅ Restaurados: $RETRY_SUCCESS"
        echo "  ❌ Ainda pendentes: $RETRY_FAIL"
        echo ""

        if [ $RETRY_FAIL -eq 0 ]; then
            log_success "Todos os dumps pendentes foram restaurados!"
        else
            log_warning "Ainda existem $RETRY_FAIL dump(s) que não puderam ser restaurados."
        fi
    fi
fi

exit 0
