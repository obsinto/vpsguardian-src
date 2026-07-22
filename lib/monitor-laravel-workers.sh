#!/bin/bash
################################################################################
# Script: monitor-laravel-workers.sh
# Propósito: Detecção de workers Laravel/Horizon (M4)
# Uso: source /opt/vpsguardian/lib/monitor-laravel-workers.sh
#      (requer monitor-common.sh carregado; reutiliza dados de M3 quando houver)
#
# Ataca o gatilho do incidente original:
#   php artisan horizon:work --timeout=36000  (6 workers, sem contenção)
#
# Estratégia:
#   - UMA chamada a ps para o host inteiro (funciona mesmo sem Docker);
#   - /proc/<pid>/cgroup e /proc/<pid>/cmdline apenas para PIDs candidatos;
#   - nenhuma chamada docker exec/top; nenhuma chamada Coolify por processo;
#   - inventário e mapa Coolify do M3 reutilizados integralmente;
#   - parsing de flags sem eval e sem interpretar conteúdo como shell;
#   - comandos sanitizados (tokens/senhas/credenciais nunca aparecem).
#
# Tipos: HORIZON_MASTER, HORIZON_WORKER, QUEUE_WORK, QUEUE_LISTEN,
#        SCHEDULE_RUN, SCHEDULE_WORK, OCTANE, UNKNOWN_LARAVEL
#
# Referência: docs/MARCOS-MONITOR-PREVENTIVO.md (M4)
# Versão: 1.0.0
################################################################################

# Campos de cada registro em LARAVEL_WORKERS_DATA (delimitados por '|'):
#  0 pid           8 rss_kb          16 timeout_s          24 restart_policy
#  1 ppid          9 type            17 timeout_source     25 cont_mem_limit_mb
#  2 user         10 container_id    18 memory_opt_mb      26 cont_cpu_allowed
#  3 state        11 container_name  19 memory_source      27 isolation
#  4 elapsed_s    12 coolify_uuid    20 max_time_s         28 severity
#  5 cpu_raw      13 coolify_type    21 max_jobs           29 group_count
#  6 cpu_norm     14 coolify_name    22 tries              30 findings (csv)
#  7 mem_pct      15 queues          23 sleep_s            31 cmd_sanitized
# 32 origin      33 coolify_project  34 coolify_environment

################################################################################
# Funções puras de parsing (testáveis, sem eval)
################################################################################

# Classifica o tipo do worker a partir do subcomando artisan.
# Retorna vazio quando o comando NÃO é um worker monitorado (ex: horizon:status,
# migrate, queue:restart) — evita falsos positivos.
monitor_laravel_worker_type() {
    local cmd="$1"

    # Extrai o token imediatamente após "artisan"
    local subcmd
    subcmd=$(echo "$cmd" | awk '{
        for (i = 1; i < NF; i++) {
            if ($i ~ /(^|\/)artisan$/) { print $(i+1); exit }
        }
    }')
    [ -n "$subcmd" ] || { echo ""; return 1; }

    case "$subcmd" in
        horizon)            echo "HORIZON_MASTER" ;;
        horizon:supervisor) echo "HORIZON_MASTER" ;;
        horizon:work)       echo "HORIZON_WORKER" ;;
        queue:work)         echo "QUEUE_WORK" ;;
        queue:listen)       echo "QUEUE_LISTEN" ;;
        schedule:run)       echo "SCHEDULE_RUN" ;;
        schedule:work)      echo "SCHEDULE_WORK" ;;
        octane|octane:start) echo "OCTANE" ;;
        *)                  echo ""; return 1 ;;
    esac
}

# Extrai o valor de uma opção "--opt=valor" ou "--opt valor" (sem eval).
# Uso: monitor_laravel_parse_option "<cmd>" --timeout
monitor_laravel_parse_option() {
    local cmd="$1" opt="$2"
    echo "$cmd" | awk -v opt="$opt" '{
        for (i = 1; i <= NF; i++) {
            if (index($i, opt "=") == 1) {
                print substr($i, length(opt) + 2)
                exit
            }
            if ($i == opt && i < NF && substr($(i+1), 1, 2) != "--") {
                print $(i+1)
                exit
            }
        }
    }'
}

# Valida valor numérico inteiro não-negativo de uma flag; inválido => vazio
monitor_laravel_valid_int() {
    local v="$1"
    if [[ "$v" =~ ^[0-9]+$ ]]; then
        echo "$v"
    else
        echo ""
    fi
}

# Sanitiza a linha de comando para exibição: remove credenciais em URLs,
# valores de flags sensíveis e pares chave=segredo. Nunca usa eval.
monitor_laravel_sanitize_cmd() {
    local cmd="$1" max_len="${2:-200}"
    echo "$cmd" | tr -d '|' | tr '\n' ' ' | sed -E \
        -e 's#(://[^:/@[:space:]]+):[^@[:space:]]+@#\1:***@#g' \
        -e 's#(--(token|api[-_]?token|password|passwd|secret|api[-_]?key|key|env)(=|[[:space:]]+))[^[:space:]]+#\1***#gI' \
        -e 's#(\b(token|password|passwd|pwd|secret|api_key|apikey)=)[^[:space:]]+#\1***#gI' \
        | cut -c1-"$max_len"
}

# Extrai o ID (12 chars) do container a partir do conteúdo de /proc/<pid>/cgroup.
# Suporta cgroup v1 (/docker/<id64>) e v2 (docker-<id64>.scope).
monitor_laravel_cgroup_container_id() {
    local content="$1"
    echo "$content" | grep -oE '[0-9a-f]{64}' | head -n1 | cut -c1-12
}

# Detecta se um comando é um processo web/servidor (para isolamento).
# Cuida para não marcar auxiliares como web.
monitor_laravel_is_web_process() {
    local cmd="$1"
    case "$cmd" in
        *php-fpm*|*nginx*|*apache2*|*caddy*|*frankenphp*) return 0 ;;
        *"artisan serve"*|*"artisan octane"*) return 0 ;;
    esac
    return 1
}

# Componentes internos conhecidos da plataforma não devem ser avaliados com as
# mesmas heurísticas de uma aplicação do usuário. O Coolify usa Horizon com
# timeout longo e processo web no mesmo container por desenho.
monitor_laravel_is_platform_container() {
    local name="${1,,}"
    case "$name" in
        coolify|coolify-realtime|coolify-sentinel|coolify-db|coolify-redis) return 0 ;;
        *) return 1 ;;
    esac
}

monitor_laravel_findings_human() {
    local findings="$1" item label="" out=""
    local IFS=','
    for item in $findings; do
        case "$item" in
            timeout_extremely_high) label="timeout extremamente alto" ;;
            timeout_very_high) label="timeout muito alto" ;;
            timeout_high) label="timeout alto" ;;
            excessive_worker_count) label="quantidade excessiva de workers" ;;
            container_without_memory_limit) label="container sem limite de memória" ;;
            no_memory_limit_anywhere) label="worker e container sem limite de memória" ;;
            missing_memory_option) label="opção de memória ausente" ;;
            missing_max_time) label="tempo máximo ausente" ;;
            shared_with_web) label="worker compartilhado com servidor web" ;;
            queue_listen_in_production) label="queue:listen em produção" ;;
            schedule_run_stuck) label="agendador possivelmente travado" ;;
            zombie_process) label="processo zumbi" ;;
            platform_managed) label="componente gerenciado da plataforma" ;;
            *) label="${item//_/ }" ;;
        esac
        out="${out}${out:+; }${label}"
    done
    printf '%s' "$out"
}

monitor_laravel_worker_label() {
    local origin="$1" project="$2" resource="$3" environment="$4"
    local container_name="$5" container_id="$6" label=""
    if [ "$origin" = "COOLIFY_PLATFORM" ]; then
        label="Plataforma Coolify / ${container_name:-componente interno}"
    elif [ -n "$project" ] || [ -n "$resource" ]; then
        label="Projeto ${project:-Coolify}${resource:+ / $resource}"
        [ -n "$environment" ] && label="${label} (${environment})"
    elif [ -n "$container_name" ]; then
        label="Container $container_name"
    elif [ -n "$container_id" ]; then
        label="Container ${container_id} (não mapeado)"
    else
        label="Host (origem não mapeada)"
    fi
    printf '%s' "$label"
}

################################################################################
# Regras de severidade (funções puras, testáveis)
################################################################################

# Severidade do timeout do worker (estritamente maior que o threshold).
# Uso: monitor_laravel_timeout_severity <timeout_s>
monitor_laravel_timeout_severity() {
    local t="$1"
    local warn="${MONITOR_LARAVEL_TIMEOUT_WARNING:-300}"
    local crit="${MONITOR_LARAVEL_TIMEOUT_CRITICAL:-900}"
    local emerg="${MONITOR_LARAVEL_TIMEOUT_EMERGENCY:-3600}"

    [[ "$t" =~ ^[0-9]+$ ]] || { echo "INFO"; return; }
    if [ "$t" -gt "$emerg" ]; then echo "EMERGENCY"
    elif [ "$t" -gt "$crit" ]; then echo "CRITICAL"
    elif [ "$t" -gt "$warn" ]; then echo "WARNING"
    else echo "INFO"; fi
}

# Severidade da quantidade de workers equivalentes ("mais de N")
monitor_laravel_count_severity() {
    local c="$1"
    local warn="${MONITOR_LARAVEL_WORKERS_WARNING:-2}"
    local crit="${MONITOR_LARAVEL_WORKERS_CRITICAL:-4}"
    local emerg="${MONITOR_LARAVEL_WORKERS_EMERGENCY:-8}"

    [[ "$c" =~ ^[0-9]+$ ]] || { echo "INFO"; return; }
    if [ "$c" -gt "$emerg" ]; then echo "EMERGENCY"
    elif [ "$c" -gt "$crit" ]; then echo "CRITICAL"
    elif [ "$c" -gt "$warn" ]; then echo "WARNING"
    else echo "INFO"; fi
}

# Avalia um worker e devolve "severidade|finding1,finding2,..."
# Uso: monitor_laravel_evaluate <type> <timeout_s> <group_count> <elapsed_s> \
#                               <cont_mem_limit_mb> <memory_opt> <max_time_opt> \
#                               <isolation> <state> [origin]
# cont_mem_limit_mb: ""=container desconhecido | 0=sem limite | N=limite em MB
monitor_laravel_evaluate() {
    local type="$1" timeout_s="$2" group_count="$3" elapsed_s="$4"
    local cont_mem_limit="$5" memory_opt="$6" max_time_opt="$7"
    local isolation="$8" state="$9"
    local origin="${10:-APPLICATION}"

    local sched_warn="${MONITOR_LARAVEL_SCHEDULE_RUN_WARNING:-300}"
    local sched_crit="${MONITOR_LARAVEL_SCHEDULE_RUN_CRITICAL:-900}"
    local cfg_listen="${MONITOR_LARAVEL_QUEUE_LISTEN_WARNING:-true}"
    local cfg_missing_mem="${MONITOR_LARAVEL_MISSING_MEMORY_WARNING:-true}"
    local cfg_missing_maxtime="${MONITOR_LARAVEL_MISSING_MAX_TIME_WARNING:-true}"
    local cfg_shared="${MONITOR_LARAVEL_SHARED_WEB_WARNING:-true}"
    local count_warn="${MONITOR_LARAVEL_WORKERS_WARNING:-2}"

    local sev="INFO" findings=""

    _add_finding() {
        findings="${findings}${findings:+,}$1"
        sev=$(monitor_severity_max "$sev" "$2")
    }

    # Timeout longo, ausência de hard-limit e compartilhamento com web são
    # esperados no container principal do Coolify. Continuamos inventariando os
    # processos, mas não os tratamos como aplicação Laravel descontrolada.
    if [ "$origin" = "COOLIFY_PLATFORM" ]; then
        _add_finding "platform_managed" "INFO"
    fi

    # Timeout perigoso (apenas quando informado na linha de comando)
    if [ -n "$timeout_s" ] && [ "$origin" != "COOLIFY_PLATFORM" ]; then
        case "$(monitor_laravel_timeout_severity "$timeout_s")" in
            EMERGENCY) _add_finding "timeout_extremely_high" "EMERGENCY" ;;
            CRITICAL)  _add_finding "timeout_very_high" "CRITICAL" ;;
            WARNING)   _add_finding "timeout_high" "WARNING" ;;
        esac
    fi

    # Workers em excesso no mesmo grupo
    local count_sev
    count_sev=$(monitor_laravel_count_severity "$group_count")
    [ "$count_sev" != "INFO" ] && _add_finding "excessive_worker_count" "$count_sev"

    # queue:listen em produção (reinicializa o framework a cada job)
    if [ "$type" = "QUEUE_LISTEN" ] && [ "$cfg_listen" = "true" ]; then
        _add_finding "queue_listen_in_production" "WARNING"
    fi

    # schedule:run deveria ser curto
    if [ "$type" = "SCHEDULE_RUN" ] && [[ "$elapsed_s" =~ ^[0-9]+$ ]]; then
        if [ "$elapsed_s" -gt "$sched_crit" ]; then
            _add_finding "schedule_run_stuck" "CRITICAL"
        elif [ "$elapsed_s" -gt "$sched_warn" ]; then
            _add_finding "schedule_run_stuck" "WARNING"
        fi
    fi

    # Container sem limite de memória (dados do M3)
    if [ "$cont_mem_limit" = "0" ] && [ "$origin" != "COOLIFY_PLATFORM" ]; then
        _add_finding "container_without_memory_limit" "WARNING"
    fi

    # --memory ausente em workers de fila (pode estar em config => não é erro absoluto)
    if { [ "$type" = "QUEUE_WORK" ] || [ "$type" = "HORIZON_WORKER" ]; } && \
       [ "$origin" != "COOLIFY_PLATFORM" ]; then
        if [ -z "$memory_opt" ]; then
            if [ "$cont_mem_limit" = "0" ] && [ "$cfg_missing_mem" = "true" ]; then
                _add_finding "no_memory_limit_anywhere" "WARNING"
            else
                _add_finding "missing_memory_option" "INFO"
            fi
        fi
    fi

    # --max-time ausente: INFO isolado; sobe se combinado com outros sinais
    if [ "$type" = "QUEUE_WORK" ] && [ -z "$max_time_opt" ] && \
       [ "$origin" != "COOLIFY_PLATFORM" ]; then
        local maxtime_sev="INFO"
        if [ "$cfg_missing_maxtime" = "true" ]; then
            if [ "$cont_mem_limit" = "0" ] || \
                { [[ "$group_count" =~ ^[0-9]+$ ]] && [ "$group_count" -gt "$count_warn" ]; } || \
                { [[ "$elapsed_s" =~ ^[0-9]+$ ]] && [ "$elapsed_s" -gt 86400 ]; }; then
                maxtime_sev="WARNING"
            fi
        fi
        _add_finding "missing_max_time" "$maxtime_sev"
    fi

    # Worker no mesmo container do servidor web
    if [ "$isolation" = "SHARED_WITH_WEB" ] && [ "$cfg_shared" = "true" ] && \
       [ "$origin" != "COOLIFY_PLATFORM" ]; then
        _add_finding "shared_with_web" "WARNING"
    fi

    # Processo zombie: registrado sem elevar severidade
    case "$state" in
        Z*) _add_finding "zombie_process" "INFO" ;;
    esac

    unset -f _add_finding
    echo "$sev|$findings"
}

################################################################################
# Coletor principal do M4
################################################################################

LARAVEL_WORKERS_DATA=()
LARAVEL_WORKERS_ALERTS=()

collect_laravel_workers() {
    LARAVEL_WORKERS_DATA=()
    LARAVEL_WORKERS_ALERTS=()
    LARAVEL_STATUS="desabilitado"
    LARAVEL_TOTAL=0
    LARAVEL_HORIZON_MASTERS=0 LARAVEL_HORIZON_WORKERS=0
    LARAVEL_QUEUE_WORKERS=0 LARAVEL_QUEUE_LISTENERS=0
    LARAVEL_SCHEDULERS=0 LARAVEL_OCTANE=0
    LARAVEL_CONTAINERS_WITH_WORKERS=0
    LARAVEL_SHARED_WITH_WEB=0
    LARAVEL_WARNING=0 LARAVEL_CRITICAL=0 LARAVEL_EMERGENCY=0
    LARAVEL_DANGEROUS_TIMEOUTS=0
    LARAVEL_CONTAINERS_NO_MEM_LIMIT=0
    LARAVEL_MAX_SEVERITY="INFO"

    [ "${MONITOR_LARAVEL_WORKERS_ENABLED:-true}" = "true" ] || return 0

    local ps_timeout="${MONITOR_LARAVEL_COMMAND_TIMEOUT:-$MONITOR_COMMAND_TIMEOUT}"

    # ---- UMA chamada a ps (ou fixture nos testes) ----
    local ps_out
    if [ -n "${MONITOR_LARAVEL_PS_SOURCE:-}" ]; then
        ps_out=$(cat "$MONITOR_LARAVEL_PS_SOURCE" 2>/dev/null)
    else
        ps_out=$(run_with_timeout "$ps_timeout" \
            ps -eo pid,ppid,user,stat,etimes,pcpu,pmem,rss,args --no-headers 2>/dev/null)
    fi
    if [ -z "$ps_out" ]; then
        LARAVEL_STATUS="sem_ps"
        return 1
    fi
    LARAVEL_STATUS="ok"

    # ---- Mapa de containers do M3 (reuso integral, custo zero) ----
    declare -A C_NAME C_POLICY C_MEM_LIMIT C_CPU_ALLOWED C_UUID C_TYPE C_CNAME C_PROJECT C_ENV
    local rec
    for rec in "${CONTAINERS_DATA[@]}"; do
        local -a CF
        IFS='|' read -r -a CF <<< "$rec"
        local key="${CF[0]}"
        C_NAME["$key"]="${CF[1]}"
        C_POLICY["$key"]="${CF[6]}"
        C_CPU_ALLOWED["$key"]="${CF[14]}"
        C_MEM_LIMIT["$key"]="${CF[19]}"
        C_UUID["$key"]="${CF[24]}"
        C_TYPE["$key"]="${CF[25]}"
        C_CNAME["$key"]="${CF[26]}"
        C_PROJECT["$key"]="${CF[27]}"
        C_ENV["$key"]="${CF[28]}"
    done

    # ---- Passo 1: identificar candidatos (workers) e processos web ----
    local -a W_PID W_PPID W_USER W_STAT W_ELAPSED W_CPU W_MEM W_RSS W_CMD W_TYPE W_CID
    local -a WEB_PIDS
    declare -A GROUP_COUNT WORKER_CONTAINERS WEB_CONTAINERS
    local -a W_GROUP

    local pid ppid user stat etimes pcpu pmem rss cmd
    while read -r pid ppid user stat etimes pcpu pmem rss cmd; do
        [ -n "$pid" ] || continue
        # Ignora wrappers de shell e o próprio grep (evita dupla contagem)
        case "$cmd" in
            grep*|sh\ -c*|bash\ -c*|/bin/sh\ -c*|/bin/bash\ -c*) continue ;;
        esac

        if monitor_laravel_is_web_process "$cmd"; then
            WEB_PIDS+=("$pid")
        fi

        case "$cmd" in *artisan*) ;; *) continue ;; esac

        # Comando completo: preferir /proc/<pid>/cmdline (ps pode truncar).
        # Falhas de leitura (PID sumiu, sem permissão) não interrompem a coleta.
        local full_cmd="$cmd"
        local cmdline_file="$MONITOR_PROC_DIR/$pid/cmdline"
        if [ -r "$cmdline_file" ]; then
            local proc_cmd
            proc_cmd=$(tr '\0' ' ' < "$cmdline_file" 2>/dev/null | sed 's/ $//')
            [ -n "$proc_cmd" ] && full_cmd="$proc_cmd"
        fi

        local wtype
        wtype=$(monitor_laravel_worker_type "$full_cmd")
        [ -n "$wtype" ] || continue

        # Container de origem via /proc/<pid>/cgroup (v1 e v2)
        local cid=""
        local cgroup_file="$MONITOR_PROC_DIR/$pid/cgroup"
        if [ -r "$cgroup_file" ]; then
            cid=$(monitor_laravel_cgroup_container_id "$(cat "$cgroup_file" 2>/dev/null)")
        fi

        # Grupo: container + tipo + filas (workers equivalentes)
        local queues
        queues=$(monitor_laravel_parse_option "$full_cmd" --queue)
        local gkey="${cid:-host}:${wtype}:${queues}"
        GROUP_COUNT["$gkey"]=$(( ${GROUP_COUNT[$gkey]:-0} + 1 ))
        [ -n "$cid" ] && WORKER_CONTAINERS["$cid"]=1

        W_PID+=("$pid"); W_PPID+=("$ppid"); W_USER+=("$user"); W_STAT+=("$stat")
        W_ELAPSED+=("$etimes"); W_CPU+=("$pcpu"); W_MEM+=("$pmem"); W_RSS+=("$rss")
        W_CMD+=("$full_cmd"); W_TYPE+=("$wtype"); W_CID+=("$cid"); W_GROUP+=("$gkey")
    done <<< "$ps_out"

    if [ "${#W_PID[@]}" -eq 0 ]; then
        LARAVEL_STATUS="sem_workers"
        return 0
    fi

    # ---- Passo 2: cgroup dos processos web, só para containers com workers ----
    local web_scan_max="${MONITOR_LARAVEL_WEB_SCAN_MAX:-200}"
    local scanned=0 wpid wcid
    if [ "${#WORKER_CONTAINERS[@]}" -gt 0 ]; then
        for wpid in "${WEB_PIDS[@]}"; do
            [ "$scanned" -ge "$web_scan_max" ] && break
            ((scanned++))
            local wfile="$MONITOR_PROC_DIR/$wpid/cgroup"
            [ -r "$wfile" ] || continue
            wcid=$(monitor_laravel_cgroup_container_id "$(cat "$wfile" 2>/dev/null)")
            [ -n "$wcid" ] && [ -n "${WORKER_CONTAINERS[$wcid]:-}" ] && WEB_CONTAINERS["$wcid"]=1
        done
    fi

    # ---- Passo 3: classificar cada worker e montar registros ----
    declare -A NO_LIMIT_CONTAINERS
    local i
    for i in "${!W_PID[@]}"; do
        local p_pid="${W_PID[$i]}" p_type="${W_TYPE[$i]}" p_cid="${W_CID[$i]}"
        local p_cmd="${W_CMD[$i]}" p_stat="${W_STAT[$i]}" p_elapsed="${W_ELAPSED[$i]}"
        local gcount="${GROUP_COUNT[${W_GROUP[$i]}]:-1}"

        # Flags relevantes (parsing seguro, valores inválidos viram vazio)
        local timeout_s memory_mb max_time_s max_jobs tries sleep_s queues
        timeout_s=$(monitor_laravel_valid_int "$(monitor_laravel_parse_option "$p_cmd" --timeout)")
        memory_mb=$(monitor_laravel_valid_int "$(monitor_laravel_parse_option "$p_cmd" --memory)")
        max_time_s=$(monitor_laravel_valid_int "$(monitor_laravel_parse_option "$p_cmd" --max-time)")
        max_jobs=$(monitor_laravel_valid_int "$(monitor_laravel_parse_option "$p_cmd" --max-jobs)")
        tries=$(monitor_laravel_valid_int "$(monitor_laravel_parse_option "$p_cmd" --tries)")
        sleep_s=$(monitor_laravel_valid_int "$(monitor_laravel_parse_option "$p_cmd" --sleep)")
        queues=$(monitor_laravel_parse_option "$p_cmd" --queue)

        local timeout_source="CONFIG_UNKNOWN"
        [ -n "$timeout_s" ] && timeout_source="COMMAND"

        # Dados do container vindos do M3
        local cname="" cpolicy="" cmem_limit="" ccpu_allowed="" cuuid="" cctype="" ccname="" cproject="" cenv=""
        if [ -n "$p_cid" ]; then
            cname="${C_NAME[$p_cid]:-}"
            cpolicy="${C_POLICY[$p_cid]:-}"
            cmem_limit="${C_MEM_LIMIT[$p_cid]:-}"
            ccpu_allowed="${C_CPU_ALLOWED[$p_cid]:-}"
            cuuid="${C_UUID[$p_cid]:-}"
            cctype="${C_TYPE[$p_cid]:-}"
            ccname="${C_CNAME[$p_cid]:-}"
            cproject="${C_PROJECT[$p_cid]:-}"
            cenv="${C_ENV[$p_cid]:-}"
        fi

        local memory_source="UNKNOWN"
        if [ -n "$memory_mb" ]; then
            memory_source="COMMAND"
        elif [ -n "$cmem_limit" ] && [ "$cmem_limit" != "0" ]; then
            memory_source="CONTAINER"
        fi

        # Isolamento: worker no mesmo container que processo web?
        local isolation="UNKNOWN"
        if [ -n "$p_cid" ]; then
            if [ -n "${WEB_CONTAINERS[$p_cid]:-}" ]; then
                isolation="SHARED_WITH_WEB"
            else
                isolation="ISOLATED"
            fi
        fi

        local origin="APPLICATION"
        monitor_laravel_is_platform_container "$cname" && origin="COOLIFY_PLATFORM"

        # Severidade e findings (regras puras)
        local eval_result severity findings
        eval_result=$(monitor_laravel_evaluate "$p_type" "$timeout_s" "$gcount" \
            "$p_elapsed" "$cmem_limit" "$memory_mb" "$max_time_s" "$isolation" "$p_stat" "$origin")
        severity="${eval_result%%|*}"
        findings="${eval_result#*|}"

        # CPU normalizada pelas vCPUs do host (convenção do M3)
        local cpu_norm=""
        if monitor_is_number "${W_CPU[$i]}"; then
            cpu_norm=$(awk -v c="${W_CPU[$i]}" -v v="${HOST_VCPUS:-1}" 'BEGIN{printf "%.1f", c/v}')
        fi

        local cmd_sanitized
        cmd_sanitized=$(monitor_laravel_sanitize_cmd "$p_cmd")

        # ---- Contadores agregados ----
        ((LARAVEL_TOTAL++))
        case "$p_type" in
            HORIZON_MASTER) ((LARAVEL_HORIZON_MASTERS++)) ;;
            HORIZON_WORKER) ((LARAVEL_HORIZON_WORKERS++)) ;;
            QUEUE_WORK)     ((LARAVEL_QUEUE_WORKERS++)) ;;
            QUEUE_LISTEN)   ((LARAVEL_QUEUE_LISTENERS++)) ;;
            SCHEDULE_RUN|SCHEDULE_WORK) ((LARAVEL_SCHEDULERS++)) ;;
            OCTANE)         ((LARAVEL_OCTANE++)) ;;
        esac
        case "$severity" in
            WARNING)   ((LARAVEL_WARNING++)) ;;
            CRITICAL)  ((LARAVEL_CRITICAL++)) ;;
            EMERGENCY) ((LARAVEL_EMERGENCY++)) ;;
        esac
        if [ "$origin" != "COOLIFY_PLATFORM" ] && [ -n "$timeout_s" ] && \
            [ "$(monitor_laravel_timeout_severity "$timeout_s")" != "INFO" ]; then
            ((LARAVEL_DANGEROUS_TIMEOUTS++))
        fi
        [ "$origin" != "COOLIFY_PLATFORM" ] && [ "$cmem_limit" = "0" ] && \
            [ -n "$p_cid" ] && NO_LIMIT_CONTAINERS["$p_cid"]=1
        LARAVEL_MAX_SEVERITY=$(monitor_severity_max "$LARAVEL_MAX_SEVERITY" "$severity")

        LARAVEL_WORKERS_DATA+=("$p_pid|${W_PPID[$i]}|${W_USER[$i]}|$p_stat|$p_elapsed|${W_CPU[$i]}|$cpu_norm|${W_MEM[$i]}|${W_RSS[$i]}|$p_type|$p_cid|$cname|$cuuid|$cctype|$ccname|$queues|$timeout_s|$timeout_source|$memory_mb|$memory_source|$max_time_s|$max_jobs|$tries|$sleep_s|$cpolicy|$cmem_limit|$ccpu_allowed|$isolation|$severity|$gcount|$findings|$cmd_sanitized|$origin|$cproject|$cenv")

        if [ "$severity" != "INFO" ]; then
            local wdesc human_findings
            wdesc=$(monitor_laravel_worker_label "$origin" "$cproject" "$ccname" "$cenv" "$cname" "$p_cid")
            human_findings=$(monitor_laravel_findings_human "$findings")
            LARAVEL_WORKERS_ALERTS+=("$severity|$wdesc|$p_type PID $p_pid: ${human_findings}${timeout_s:+ [timeout=${timeout_s}s]}${gcount:+ [${gcount} no grupo]}")
        fi
    done

    LARAVEL_CONTAINERS_WITH_WORKERS="${#WORKER_CONTAINERS[@]}"
    LARAVEL_SHARED_WITH_WEB="${#WEB_CONTAINERS[@]}"
    LARAVEL_CONTAINERS_NO_MEM_LIMIT="${#NO_LIMIT_CONTAINERS[@]}"

    return 0
}

################################################################################
# Saída JSON
################################################################################

_ljv() {
    if [ -z "$1" ]; then
        printf 'null'
    else
        monitor_json_value "$1"
    fi
}

# Array JSON com os workers detectados
monitor_laravel_workers_json() {
    local out="" rec
    local -a F
    for rec in "${LARAVEL_WORKERS_DATA[@]}"; do
        IFS='|' read -r -a F <<< "$rec"

        local findings_json="" f
        if [ -n "${F[30]}" ]; then
            for f in ${F[30]//,/ }; do
                findings_json="${findings_json}${findings_json:+,}\"$f\""
            done
        fi

        [ -n "$out" ] && out+=","
        out+="{\"pid\":$(_ljv "${F[0]}"),\"ppid\":$(_ljv "${F[1]}"),\"user\":$(_ljv "${F[2]}"),\"process_state\":$(_ljv "${F[3]}"),\"elapsed_seconds\":$(_ljv "${F[4]}"),\"cpu_percent_raw\":$(_ljv "${F[5]}"),\"cpu_percent_normalized\":$(_ljv "${F[6]}"),\"memory_percent\":$(_ljv "${F[7]}"),\"rss_kb\":$(_ljv "${F[8]}"),\"worker_type\":$(_ljv "${F[9]}"),\"container_id\":$(_ljv "${F[10]}"),\"container_name\":$(_ljv "${F[11]}"),\"coolify_uuid\":$(_ljv "${F[12]}"),\"coolify_type\":$(_ljv "${F[13]}"),\"coolify_name\":\"$(monitor_json_escape "${F[14]}")\",\"coolify_project\":\"$(monitor_json_escape "${F[33]}")\",\"coolify_environment\":\"$(monitor_json_escape "${F[34]}")\",\"queue_names\":$(_ljv "${F[15]}"),\"timeout_seconds\":$(_ljv "${F[16]}"),\"timeout_source\":$(_ljv "${F[17]}"),\"memory_option_mb\":$(_ljv "${F[18]}"),\"memory_limit_source\":$(_ljv "${F[19]}"),\"max_time_seconds\":$(_ljv "${F[20]}"),\"max_jobs\":$(_ljv "${F[21]}"),\"tries\":$(_ljv "${F[22]}"),\"sleep_seconds\":$(_ljv "${F[23]}"),\"restart_policy\":$(_ljv "${F[24]}"),\"container_memory_limit_mb\":$(_ljv "${F[25]}"),\"container_cpu_limit\":$(_ljv "${F[26]}"),\"worker_isolation\":$(_ljv "${F[27]}"),\"severity\":$(_ljv "${F[28]}"),\"group_count\":$(_ljv "${F[29]}"),\"findings\":[$findings_json],\"command_sanitized\":\"$(monitor_json_escape "${F[31]}")\",\"origin\":$(_ljv "${F[32]:-APPLICATION}")}"
    done
    printf '%s' "$out"
}

################################################################################
# Export das funções
################################################################################

export -f monitor_laravel_worker_type monitor_laravel_parse_option
export -f monitor_laravel_valid_int monitor_laravel_sanitize_cmd
export -f monitor_laravel_cgroup_container_id monitor_laravel_is_web_process
export -f monitor_laravel_is_platform_container
export -f monitor_laravel_findings_human monitor_laravel_worker_label
export -f monitor_laravel_timeout_severity monitor_laravel_count_severity
export -f monitor_laravel_evaluate
export -f collect_laravel_workers monitor_laravel_workers_json

# Marca que monitor-laravel-workers.sh foi carregado
MONITOR_LARAVEL_LOADED=1
export MONITOR_LARAVEL_LOADED
