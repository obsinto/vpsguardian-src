#!/bin/bash
################################################################################
# Script: monitor-containers.sh
# Propósito: Inventário, consumo e limites de containers (M3)
# Uso: source /opt/vpsguardian/lib/monitor-containers.sh
#      (requer monitor-common.sh e monitor-docker.sh carregados antes)
#
# Estratégia:
#   - 3 chamadas Docker em lote (ps -a, stats --no-stream, inspect com N IDs)
#     independentemente da quantidade de containers;
#   - enriquecimento Coolify por labels (sem custo) e, quando habilitado,
#     pela API via lib/coolify-api.sh (carga única em lote, nunca por container);
#   - falha de um container não interrompe o inventário dos demais;
#   - nenhum dump integral de docker inspect; nenhuma variável de ambiente de
#     container é lida; nenhum token aparece em logs ou saídas.
#
# Referência: docs/MARCOS-MONITOR-PREVENTIVO.md (M3)
# Versão: 1.0.0
################################################################################

# Campos de cada registro em CONTAINERS_DATA (delimitados por '|'):
#  1 id12          9 restart_count      17 cpu_of_allowed_pct  25 coolify_uuid
#  2 name         10 restart_windowed   18 cpu_severity        26 coolify_type
#  3 image        11 restart_severity   19 mem_used_mb         27 coolify_name
#  4 state        12 uptime_seconds     20 mem_limit_mb        28 coolify_project
#  5 status_text  13 cpu_raw_pct        21 mem_reservation_mb  29 coolify_env
#  6 health       14 cpu_norm_pct       22 mem_pct_of_limit    30 worker_hint
#  7 policy       15 cpu_allowed        23 mem_severity        31 full_id
#  8 policy_max   16 cpu_limited        24 severity
# 32 issues (texto livre sem '|')  33 cpu_observed_severity  34 cpu_high_streak

################################################################################
# Conversões e helpers puros (testáveis)
################################################################################

# Converte valores do docker stats ("361.1MiB", "1.5GiB", "512KiB") em MB
monitor_mem_to_mb() {
    local value="$1"
    echo "$value" | awk '
        {
            v = $1
            if (v ~ /GiB/)      { sub(/GiB.*/, "", v); printf "%.0f", v * 1024 }
            else if (v ~ /MiB/) { sub(/MiB.*/, "", v); printf "%.0f", v }
            else if (v ~ /KiB/) { sub(/KiB.*/, "", v); printf "%.0f", v / 1024 }
            else if (v ~ /GB/)  { sub(/GB.*/, "", v);  printf "%.0f", v * 1000 }
            else if (v ~ /MB/)  { sub(/MB.*/, "", v);  printf "%.0f", v }
            else if (v ~ /kB/)  { sub(/kB.*/, "", v);  printf "%.0f", v / 1000 }
            else if (v ~ /B/)   { sub(/B.*/, "", v);   printf "%.0f", v / 1048576 }
            else                { printf "" }
        }'
}

# Conta CPUs de um cpuset ("0-3,8" => 5)
monitor_cpuset_count() {
    local cpuset="$1"
    [ -n "$cpuset" ] || { echo ""; return; }
    echo "$cpuset" | awk -F, '
        {
            total = 0
            for (i = 1; i <= NF; i++) {
                if (split($i, r, "-") == 2) total += r[2] - r[1] + 1
                else if ($i != "") total += 1
            }
            print total
        }'
}

# CPUs efetivamente permitidas a partir dos limites do inspect.
# Uso: monitor_container_cpus_allowed <nano_cpus> <quota> <period> <cpuset> <host_vcpus>
# Saída: "<cpus>|<limitado true/false>"
monitor_container_cpus_allowed() {
    local nano="$1" quota="$2" period="$3" cpuset="$4" host_vcpus="$5"

    if monitor_is_number "$nano" && [ "$nano" -gt 0 ] 2>/dev/null; then
        echo "$(awk -v n="$nano" 'BEGIN{printf "%.2f", n/1000000000}')|true"
        return
    fi
    if monitor_is_number "$quota" && [ "$quota" -gt 0 ] 2>/dev/null && \
        monitor_is_number "$period" && [ "$period" -gt 0 ] 2>/dev/null; then
        echo "$(awk -v q="$quota" -v p="$period" 'BEGIN{printf "%.2f", q/p}')|true"
        return
    fi
    local cset_count
    cset_count=$(monitor_cpuset_count "$cpuset")
    if monitor_is_number "$cset_count" && [ "$cset_count" -gt 0 ] 2>/dev/null; then
        echo "${cset_count}|true"
        return
    fi
    echo "${host_vcpus:-1}|false"
}

# Classifica reinicializações dentro da janela (função pura).
# Uso: monitor_restart_severity <windowed> <state> <warn> <crit>
monitor_restart_severity() {
    local windowed="$1" state="$2" warn="$3" crit="$4"

    if [ "$state" = "restarting" ]; then
        echo "CRITICAL"
        return
    fi
    monitor_is_number "$windowed" || { echo "INFO"; return; }
    if [ "$windowed" -ge "$crit" ]; then
        echo "CRITICAL"
    elif [ "$windowed" -ge "$warn" ]; then
        echo "WARNING"
    else
        echo "INFO"
    fi
}

# Classifica health status (função pura)
monitor_health_severity() {
    case "$1" in
        unhealthy) echo "CRITICAL" ;;
        *) echo "INFO" ;;   # healthy, starting, none: ausência de check não é falha
    esac
}

################################################################################
# Enriquecimento Coolify (carga única em lote, nunca por container)
################################################################################

declare -A MONITOR_COOLIFY_MAP    # uuid => "type:name"
MONITOR_COOLIFY_MAP_LOADED=false
MONITOR_COOLIFY_API_USED=false

monitor_coolify_load_map() {
    [ "$MONITOR_COOLIFY_MAP_LOADED" = true ] && return 0
    MONITOR_COOLIFY_MAP_LOADED=true

    [ "${MONITOR_COOLIFY_ENRICH:-true}" = "true" ] || return 0

    # Config da API vem de backup-destinations.conf (token nunca é logado)
    if [ -z "${COOLIFY_API_ENABLED:-}" ]; then
        local conf
        for conf in "${VPSGUARDIAN_SHARED_CONFIG_FILE:-}" \
                    "$MONITOR_ROOT/config/backup-destinations.conf" \
                    "/etc/vpsguardian/backup-destinations.conf" \
                    "/opt/vpsguardian/config/backup-destinations.conf"; do
            if [ -n "$conf" ] && [ -f "$conf" ]; then
                source "$conf" 2>/dev/null
                break
            fi
        done
    fi

    if [ -z "${COOLIFY_API_LOADED:-}" ]; then
        source "$MONITOR_LIB_DIR/coolify-api.sh" 2>/dev/null || return 0
    fi

    coolify_api_enabled 2>/dev/null || return 0
    coolify_api_available 2>/dev/null || {
        log_debug "API do Coolify habilitada mas indisponível; usando apenas labels"
        return 0
    }

    # 3 chamadas em lote no máximo, reutilizando as funções existentes da lib
    local line uuid name type
    while IFS='|' read -r uuid name type _; do
        [ -n "$uuid" ] && MONITOR_COOLIFY_MAP["$uuid"]="database:$name"
    done < <(coolify_discover_databases 2>/dev/null)

    while IFS=$'\t' read -r uuid name; do
        [ -n "$uuid" ] && MONITOR_COOLIFY_MAP["$uuid"]="application:$name"
    done < <(coolify_list_applications 2>/dev/null | jq -r '.[] | [.uuid, .name] | @tsv' 2>/dev/null)

    while IFS=$'\t' read -r uuid name; do
        [ -n "$uuid" ] && MONITOR_COOLIFY_MAP["$uuid"]="service:$name"
    done < <(coolify_list_services 2>/dev/null | jq -r '.[] | [.uuid, .name] | @tsv' 2>/dev/null)

    [ "${#MONITOR_COOLIFY_MAP[@]}" -gt 0 ] && MONITOR_COOLIFY_API_USED=true
    return 0
}

# Resolve recurso Coolify para um container.
# Uso: monitor_coolify_resolve <name> <label_uuid>
# Saída: "uuid|type|name" (campos vazios quando não identificado)
monitor_coolify_resolve() {
    local cname="$1" label_uuid="$2"
    local uuid type_name

    # 1. UUID vindo das labels + mapa da API
    if [ -n "$label_uuid" ] && [ -n "${MONITOR_COOLIFY_MAP[$label_uuid]:-}" ]; then
        type_name="${MONITOR_COOLIFY_MAP[$label_uuid]}"
        echo "$label_uuid|${type_name%%:*}|${type_name#*:}"
        return 0
    fi
    # 2. UUID contido no nome do container (padrão comum do Coolify)
    for uuid in "${!MONITOR_COOLIFY_MAP[@]}"; do
        if [[ "$cname" == *"$uuid"* ]]; then
            type_name="${MONITOR_COOLIFY_MAP[$uuid]}"
            echo "$uuid|${type_name%%:*}|${type_name#*:}"
            return 0
        fi
    done
    # 3. Nome do recurso igual/prefixo do nome do container
    for uuid in "${!MONITOR_COOLIFY_MAP[@]}"; do
        type_name="${MONITOR_COOLIFY_MAP[$uuid]}"
        local rname="${type_name#*:}"
        if [ -n "$rname" ] && [[ "$cname" == "$rname"* ]]; then
            echo "$uuid|${type_name%%:*}|$rname"
            return 0
        fi
    done
    # 4. Apenas labels (sem API)
    if [ -n "$label_uuid" ]; then
        echo "$label_uuid||"
        return 0
    fi
    echo "||"
    return 1
}

################################################################################
# Coletor principal do M3
################################################################################

CONTAINERS_DATA=()
CONTAINERS_ALERTS=()

collect_containers() {
    local docker_bin="${MONITOR_DOCKER_BIN:-docker}"
    local t="${MONITOR_DOCKER_TIMEOUT_SECONDS:-5}"
    local stats_t="${MONITOR_DOCKER_STATS_TIMEOUT_SECONDS:-10}"

    CONTAINERS_DATA=()
    CONTAINERS_ALERTS=()
    CONTAINERS_STATUS="indisponivel"
    CONTAINERS_STATUS_NOTE=""
    CONTAINERS_TOTAL=0 CONTAINERS_RUNNING=0 CONTAINERS_STOPPED=0
    CONTAINERS_RESTARTING=0 CONTAINERS_UNHEALTHY=0
    CONTAINERS_NO_MEM_LIMIT=0 CONTAINERS_NO_CPU_LIMIT=0
    CONTAINERS_RESTART_LOOPS=0 CONTAINERS_PROBLEMS=0
    CONTAINERS_MAX_SEVERITY="INFO"

    # Docker indisponível: estado parcial via containerd, sem travar
    if [ "${DOCKER_PS_OK:-false}" != "true" ]; then
        CONTAINERS_STATUS_NOTE="métricas completas indisponíveis (Docker sem resposta)"
        if [ "${CONTAINERD_PROBE_OK:-unknown}" = "true" ] && [ "${CTR_AVAILABLE:-false}" = "true" ]; then
            local ctr_bin="${MONITOR_CTR_BIN:-ctr}"
            monitor_probe "${MONITOR_CONTAINERD_TIMEOUT_SECONDS:-5}" "$ctr_bin" -n moby containers list
            if [ "$PROBE_RC" -eq 0 ]; then
                # Primeira linha é cabeçalho
                CONTAINERS_TOTAL=$(echo "$PROBE_OUT" | grep -c '.' )
                [ "$CONTAINERS_TOTAL" -gt 0 ] && CONTAINERS_TOTAL=$((CONTAINERS_TOTAL - 1))
                CONTAINERS_STATUS="parcial"
                CONTAINERS_STATUS_NOTE="inventário parcial via containerd ($CONTAINERS_TOTAL containers registrados)"
            fi
        fi
        CONTAINERS_MAX_SEVERITY="UNKNOWN"
        return 0
    fi

    # ---- 3 chamadas em lote (independente do número de containers) ----
    local ps_out ps_rc
    ps_out=$(run_with_timeout "$t" "$docker_bin" ps -a \
        --format '{{.ID}}|{{.Names}}|{{.Image}}|{{.State}}|{{.Status}}' 2>/dev/null)
    ps_rc=$?
    if [ "$ps_rc" -ne 0 ]; then
        CONTAINERS_STATUS="indisponivel"
        CONTAINERS_STATUS_NOTE="docker ps -a falhou (rc=$ps_rc)"
        CONTAINERS_MAX_SEVERITY="UNKNOWN"
        return 0
    fi
    if [ -z "$ps_out" ]; then
        CONTAINERS_STATUS="vazio"
        CONTAINERS_STATUS_NOTE="nenhum container encontrado"
        return 0
    fi

    local stats_out stats_rc
    stats_out=$(run_with_timeout "$stats_t" "$docker_bin" stats --no-stream \
        --format '{{.ID}}|{{.CPUPerc}}|{{.MemUsage}}|{{.MemPerc}}' 2>/dev/null)
    stats_rc=$?

    local ids=()
    while IFS='|' read -r cid _; do
        [ -n "$cid" ] && ids+=("$cid")
    done <<< "$ps_out"

    # Nota: {{with index .State "Health"}} em vez de {{.State.Health}} porque
    # Docker recente falha o template inteiro quando a chave não existe
    local inspect_tpl='{{.Id}}|{{.Name}}|{{.RestartCount}}|{{.HostConfig.RestartPolicy.Name}}|{{.HostConfig.RestartPolicy.MaximumRetryCount}}|{{.State.StartedAt}}|{{.State.Status}}|{{with index .State "Health"}}{{index . "Status"}}{{else}}none{{end}}|{{.HostConfig.Memory}}|{{.HostConfig.MemoryReservation}}|{{.HostConfig.NanoCpus}}|{{.HostConfig.CpuQuota}}|{{.HostConfig.CpuPeriod}}|{{.HostConfig.CpusetCpus}}|{{index .Config.Labels "coolify.managed"}}|{{index .Config.Labels "coolify.applicationId"}}|{{index .Config.Labels "coolify.serviceId"}}|{{index .Config.Labels "coolify.name"}}|{{index .Config.Labels "coolify.projectName"}}|{{index .Config.Labels "coolify.environmentName"}}|{{.Config.Image}}'
    local inspect_out inspect_rc
    inspect_out=$(run_with_timeout "$t" "$docker_bin" inspect --format "$inspect_tpl" "${ids[@]}" 2>/dev/null)
    inspect_rc=$?

    CONTAINERS_STATUS="ok"
    if [ "$stats_rc" -ne 0 ] || [ "$inspect_rc" -ne 0 ]; then
        CONTAINERS_STATUS="parcial"
        CONTAINERS_STATUS_NOTE="falha parcial em docker stats/inspect; alguns campos podem faltar"
    fi

    # ---- Índices por ID (12 chars) ----
    declare -A S_CPU S_MEM_MB
    local line cid cpu mem_usage _memperc
    while IFS='|' read -r cid cpu mem_usage _memperc; do
        [ -n "$cid" ] || continue
        cid="${cid:0:12}"
        S_CPU["$cid"]="${cpu%\%}"
        S_MEM_MB["$cid"]=$(monitor_mem_to_mb "${mem_usage%% /*}")
    done <<< "$stats_out"

    declare -A I_LINE
    local full_id rest
    while IFS='|' read -r full_id rest; do
        [ -n "$full_id" ] || continue
        I_LINE["${full_id:0:12}"]="$full_id|$rest"
    done <<< "$inspect_out"

    # ---- Enriquecimento Coolify (carga única) ----
    monitor_coolify_load_map || true

    # ---- Configuração ----
    local mem_warn="${MONITOR_CONTAINER_MEM_WARNING_PERCENT:-80}"
    local mem_crit="${MONITOR_CONTAINER_MEM_CRITICAL_PERCENT:-90}"
    local mem_emerg="${MONITOR_CONTAINER_MEM_EMERGENCY_PERCENT:-97}"
    local no_mem_sev="${MONITOR_CONTAINER_NO_MEM_LIMIT_SEVERITY:-WARNING}"
    local no_cpu_sev="${MONITOR_CONTAINER_NO_CPU_LIMIT_SEVERITY:-INFO}"
    local cpu_warn="${MONITOR_CONTAINER_CPU_WARNING_PERCENT:-80}"
    local cpu_crit="${MONITOR_CONTAINER_CPU_CRITICAL_PERCENT:-95}"
    local cpu_consecutive="${MONITOR_CONTAINER_CPU_CONSECUTIVE:-2}"
    [[ "$cpu_consecutive" =~ ^[1-9][0-9]*$ ]] || cpu_consecutive=2
    local restart_warn="${MONITOR_CONTAINER_RESTART_WARNING:-3}"
    local restart_crit="${MONITOR_CONTAINER_RESTART_CRITICAL:-5}"
    local restart_window_min="${MONITOR_CONTAINER_RESTART_WINDOW_MINUTES:-15}"
    local exceptions="${MONITOR_CONTAINER_LIMIT_EXCEPTIONS:-^coolify(-|$)|^coolify-proxy|^coolify-db|^coolify-redis|^coolify-realtime|^coolify-sentinel}"
    local worker_regex="${MONITOR_WORKER_NAME_REGEX:-worker|queue|horizon}"
    local now_epoch
    now_epoch=$(date +%s)

    # ---- Loop por container (falha individual não interrompe os demais) ----
    local name image state status_text
    while IFS='|' read -r cid name image state status_text; do
        [ -n "$cid" ] || continue
        cid="${cid:0:12}"
        ((CONTAINERS_TOTAL++))

        case "$state" in
            running) ((CONTAINERS_RUNNING++)) ;;
            restarting) ((CONTAINERS_RESTARTING++)) ;;
            *) ((CONTAINERS_STOPPED++)) ;;
        esac

        # Campos do inspect (podem faltar em falha parcial)
        local i_full="" i_restart_count="" i_policy="" i_policy_max="" i_started=""
        local i_state="" i_health="none" i_mem="" i_mem_res="" i_nano="" i_quota=""
        local i_period="" i_cpuset="" l_managed="" l_appid="" l_svcid="" l_name=""
        local l_project="" l_env="" i_image=""
        if [ -n "${I_LINE[$cid]:-}" ]; then
            IFS='|' read -r i_full _ i_restart_count i_policy i_policy_max i_started \
                i_state i_health i_mem i_mem_res i_nano i_quota i_period i_cpuset \
                l_managed l_appid l_svcid l_name l_project l_env i_image \
                <<< "${I_LINE[$cid]}"
        fi
        [ -n "$i_image" ] && image="$i_image"
        [ "$i_health" = "<no value>" ] && i_health="none"

        # Uptime
        local uptime_seconds=""
        if [ "$state" = "running" ] && [ -n "$i_started" ]; then
            local started_epoch
            started_epoch=$(date -d "$i_started" +%s 2>/dev/null)
            monitor_is_number "$started_epoch" && uptime_seconds=$((now_epoch - started_epoch))
        fi

        # ---- Memória: limite vs consumo ----
        local mem_used_mb="${S_MEM_MB[$cid]:-}"
        local mem_limit_mb="" mem_res_mb="" mem_pct="" mem_sev="INFO"
        local issues=""
        if monitor_is_number "$i_mem"; then
            mem_limit_mb=$(( i_mem / 1048576 ))
        fi
        if monitor_is_number "$i_mem_res" && [ "$i_mem_res" -gt 0 ] 2>/dev/null; then
            mem_res_mb=$(( i_mem_res / 1048576 ))
        fi

        if [ "$state" != "running" ]; then
            # Container parado: inventariado, mas sem alertas de limite/consumo
            # (health/limite de container parado é informação obsoleta)
            mem_sev="INFO"
        elif [ -z "$mem_limit_mb" ]; then
            mem_sev="UNKNOWN"
        elif [ "$mem_limit_mb" -eq 0 ]; then
            # Sem limite: exceção configurável para containers de infraestrutura
            if echo "$name" | grep -qE "$exceptions"; then
                mem_sev="INFO"
                issues="${issues}sem limite de memória (exceção de infra); "
            else
                mem_sev="$no_mem_sev"
                issues="${issues}sem limite de memória; "
            fi
            ((CONTAINERS_NO_MEM_LIMIT++))
        elif monitor_is_number "$mem_used_mb"; then
            mem_pct=$(awk -v u="$mem_used_mb" -v l="$mem_limit_mb" \
                'BEGIN{if (l>0) printf "%.1f", u*100/l}')
            mem_sev=$(monitor_classify_high "$mem_pct" "$mem_warn" "$mem_crit" "$mem_emerg")
            case "$mem_sev" in
                WARNING|CRITICAL|EMERGENCY)
                    issues="${issues}${mem_pct}% do limite de memória (${mem_used_mb} de ${mem_limit_mb} MB); " ;;
            esac
        fi

        # ---- CPU: bruto, normalizado e relativo ao permitido ----
        local cpu_raw="${S_CPU[$cid]:-}"
        local cpu_allowed cpu_limited cpu_norm="" cpu_of_allowed=""
        local cpu_sev="INFO" cpu_observed_sev="INFO" cpu_high_streak=0
        IFS='|' read -r cpu_allowed cpu_limited <<< \
            "$(monitor_container_cpus_allowed "$i_nano" "$i_quota" "$i_period" "$i_cpuset" "$HOST_VCPUS")"

        if [ "$cpu_limited" = "false" ] && [ "$state" = "running" ]; then
            ((CONTAINERS_NO_CPU_LIMIT++))
            if [ "$no_cpu_sev" != "INFO" ]; then
                issues="${issues}sem limite de CPU; "
            fi
        fi
        if monitor_is_number "$cpu_raw"; then
            cpu_norm=$(awk -v c="$cpu_raw" -v v="${HOST_VCPUS:-1}" 'BEGIN{printf "%.1f", c/v}')
            cpu_of_allowed=$(awk -v c="$cpu_raw" -v a="$cpu_allowed" \
                'BEGIN{if (a>0) printf "%.1f", c/a}')
            cpu_observed_sev=$(monitor_classify_high "$cpu_of_allowed" "$cpu_warn" "$cpu_crit")
        elif [ "$state" = "running" ]; then
            cpu_observed_sev="UNKNOWN"
            cpu_sev="UNKNOWN"
        fi

        # CPU instantânea é observação; só vira severidade efetiva após N ciclos.
        # O contador é explicitamente zerado quando a leitura normaliza.
        if [ "$cpu_observed_sev" = "WARNING" ] || [ "$cpu_observed_sev" = "CRITICAL" ]; then
            local prev_high
            prev_high=$(monitor_state_get "ch_$cid")
            monitor_is_number "$prev_high" || prev_high=0
            cpu_high_streak=$((prev_high + 1))
            monitor_state_set "ch_$cid" "$cpu_high_streak"
            if [ "$cpu_high_streak" -ge "$cpu_consecutive" ]; then
                cpu_sev="$cpu_observed_sev"
                issues="${issues}CPU sustentada por ${cpu_high_streak} coleta(s): ${cpu_of_allowed}% do permitido (${cpu_raw}% bruto); "
            else
                cpu_sev="INFO"
            fi
        elif [ "$cpu_observed_sev" = "INFO" ]; then
            monitor_state_set "ch_$cid" "0"
            cpu_high_streak=0
            cpu_sev="INFO"
        else
            # Uma coleta sem dado de CPU interrompe a sequência: duas leituras
            # altas separadas por uma falha de stats não são consecutivas.
            monitor_state_set "ch_$cid" "0"
            cpu_high_streak=0
        fi

        # Sem limite de CPU só eleva severidade se explicitamente configurado.
        if [ "$cpu_limited" = "false" ] && [ "$cpu_sev" = "INFO" ] && \
           [ "$cpu_observed_sev" = "INFO" ]; then
            cpu_sev="$no_cpu_sev"
        fi

        # ---- Restart loop por delta dentro da janela ----
        local restart_windowed=0 restart_sev="INFO"
        monitor_is_number "$i_restart_count" || i_restart_count=""
        if [ -n "$i_restart_count" ] && [ "$i_restart_count" -gt 0 ]; then
            local baseline baseline_count baseline_epoch
            baseline=$(monitor_state_get "cw_$cid")
            baseline_count="${baseline%%:*}"
            baseline_epoch="${baseline##*:}"
            if ! monitor_is_number "$baseline_count" || ! monitor_is_number "$baseline_epoch" || \
                [ $((now_epoch - baseline_epoch)) -gt $((restart_window_min * 60)) ]; then
                # Janela nova: baseline vira o contador atual
                baseline_count="$i_restart_count"
                baseline_epoch="$now_epoch"
            fi
            restart_windowed=$((i_restart_count - baseline_count))
            [ "$restart_windowed" -lt 0 ] && restart_windowed=0
            monitor_state_set "cw_$cid" "${baseline_count}:${baseline_epoch}"
        fi
        restart_sev=$(monitor_restart_severity "$restart_windowed" "$state" \
            "$restart_warn" "$restart_crit")
        if [ "$restart_sev" != "INFO" ]; then
            ((CONTAINERS_RESTART_LOOPS++))
            issues="${issues}${restart_windowed} restart(s) em ${restart_window_min}min [política: ${i_policy:-n/d}]; "
            [ "$state" = "restarting" ] && issues="${issues}em estado restarting; "
        fi

        # ---- Health (relevante apenas para containers rodando) ----
        local health_sev="INFO"
        if [ "$state" = "running" ]; then
            health_sev=$(monitor_health_severity "$i_health")
            if [ "$i_health" = "unhealthy" ]; then
                ((CONTAINERS_UNHEALTHY++))
                issues="${issues}unhealthy; "
            fi
        fi

        # ---- Worker + política de restart (heurística leve; M4 aprofunda) ----
        local worker_hint=false
        if echo "$name $image ${l_name}" | grep -qiE "$worker_regex"; then
            worker_hint=true
            if [ "$i_policy" = "unless-stopped" ] || [ "$i_policy" = "always" ]; then
                issues="${issues}possível worker com restart ${i_policy}; "
            fi
        fi

        # ---- Coolify ----
        local label_uuid="" coolify_uuid="" coolify_type="" coolify_name=""
        [ "$l_appid" != "" ] && [ "$l_appid" != "<no value>" ] && label_uuid="$l_appid"
        [ -z "$label_uuid" ] && [ "$l_svcid" != "" ] && [ "$l_svcid" != "<no value>" ] && label_uuid="$l_svcid"
        IFS='|' read -r coolify_uuid coolify_type coolify_name <<< \
            "$(monitor_coolify_resolve "$name" "$label_uuid")"
        [ -z "$coolify_type" ] && [ -n "$l_appid" ] && [ "$l_appid" != "<no value>" ] && coolify_type="application"
        [ -z "$coolify_type" ] && [ -n "$l_svcid" ] && [ "$l_svcid" != "<no value>" ] && coolify_type="service"
        [ -z "$coolify_name" ] && [ "$l_name" != "<no value>" ] && coolify_name="$l_name"
        [ "$l_project" = "<no value>" ] && l_project=""
        [ "$l_env" = "<no value>" ] && l_env=""
        [ "$l_managed" = "<no value>" ] && l_managed=""

        # ---- Severidade do container ----
        local severity="INFO"
        severity=$(monitor_severity_max "$severity" "$mem_sev")
        severity=$(monitor_severity_max "$severity" "$cpu_sev")
        severity=$(monitor_severity_max "$severity" "$restart_sev")
        severity=$(monitor_severity_max "$severity" "$health_sev")
        [ "$severity" = "UNKNOWN" ] && severity="INFO"

        CONTAINERS_MAX_SEVERITY=$(monitor_severity_max "$CONTAINERS_MAX_SEVERITY" "$severity")
        case "$severity" in
            WARNING|CRITICAL|EMERGENCY) ((CONTAINERS_PROBLEMS++)) ;;
        esac

        # Sanitiza campos livres (sem '|' nem quebras de linha)
        issues="${issues%; }"
        issues=$(echo "$issues" | tr -d '|' | tr '\n' ' ')
        name=$(echo "$name" | tr -d '|')
        image=$(echo "$image" | tr -d '|')

        CONTAINERS_DATA+=("$cid|$name|$image|$state|$status_text|$i_health|${i_policy:-}|${i_policy_max:-}|${i_restart_count:-}|$restart_windowed|$restart_sev|${uptime_seconds:-}|${cpu_raw:-}|${cpu_norm:-}|${cpu_allowed:-}|${cpu_limited:-}|${cpu_of_allowed:-}|$cpu_sev|${mem_used_mb:-}|${mem_limit_mb:-}|${mem_res_mb:-}|${mem_pct:-}|$mem_sev|$severity|${coolify_uuid:-}|${coolify_type:-}|${coolify_name:-}|${l_project:-}|${l_env:-}|$worker_hint|${i_full:-}|$issues|$cpu_observed_sev|$cpu_high_streak")

        # Alertas por container (limitados pelo chamador na exibição)
        if [ "$severity" != "INFO" ]; then
            local coolify_desc=""
            [ -n "$coolify_name" ] && coolify_desc=" [Coolify: ${l_project:+$l_project / }$coolify_name]"
            CONTAINERS_ALERTS+=("$severity|$name|${issues:-sem detalhes}${coolify_desc}")
        fi
    done <<< "$ps_out"

    return 0
}

################################################################################
# Saídas derivadas (tops e JSON)
################################################################################

# Extrai "chave_de_ordenacao|resto do registro" e devolve top N.
# Uso: monitor_containers_top <campo> [N]
monitor_containers_top() {
    local field="$1" limit="${2:-${MONITOR_TOP_CONTAINERS:-10}}"
    local rec
    for rec in "${CONTAINERS_DATA[@]}"; do
        local value
        value=$(echo "$rec" | cut -d'|' -f"$field")
        monitor_is_number "$value" || continue
        printf '%s|%s\n' "$value" "$rec"
    done | sort -t'|' -k1 -rn | head -n "$limit"
}

# JSON helper local: vazio => null
_cjv() {
    if [ -z "$1" ]; then
        printf 'null'
    else
        monitor_json_value "$1"
    fi
}

# Array JSON com o inventário (limitado por MONITOR_MAX_CONTAINERS_JSON)
monitor_containers_json() {
    local max="${MONITOR_MAX_CONTAINERS_JSON:-200}"
    local count=0 out="" rec
    local f_id f_name f_image f_state f_status f_health f_policy f_policy_max
    local f_rcount f_rwin f_rsev f_uptime f_craw f_cnorm f_callowed f_climited
    local f_callowedpct f_csev f_mused f_mlimit f_mres f_mpct f_msev f_sev
    local f_cuuid f_ctype f_cname f_cproj f_cenv f_worker f_fullid f_issues
    local f_cobserved f_cstreak

    for rec in "${CONTAINERS_DATA[@]}"; do
        [ "$count" -ge "$max" ] && break
        IFS='|' read -r f_id f_name f_image f_state f_status f_health f_policy \
            f_policy_max f_rcount f_rwin f_rsev f_uptime f_craw f_cnorm f_callowed \
            f_climited f_callowedpct f_csev f_mused f_mlimit f_mres f_mpct f_msev \
            f_sev f_cuuid f_ctype f_cname f_cproj f_cenv f_worker f_fullid f_issues \
            f_cobserved f_cstreak \
            <<< "$rec"

        [ -n "$out" ] && out+=","
        local cpu_pending=false
        if { [ "$f_cobserved" = "WARNING" ] || [ "$f_cobserved" = "CRITICAL" ]; } && \
           [ "$f_csev" = "INFO" ]; then
            cpu_pending=true
        fi
        out+="{\"id\":\"$f_id\",\"full_id\":$(_cjv "$f_fullid"),\"name\":\"$(monitor_json_escape "$f_name")\",\"image\":\"$(monitor_json_escape "$f_image")\",\"state\":$(_cjv "$f_state"),\"status\":\"$(monitor_json_escape "$f_status")\",\"health\":$(_cjv "$f_health"),\"restart_policy\":$(_cjv "$f_policy"),\"restart_max_retries\":$(_cjv "$f_policy_max"),\"restart_count\":$(_cjv "$f_rcount"),\"restarts_in_window\":$(_cjv "$f_rwin"),\"restart_severity\":$(_cjv "$f_rsev"),\"uptime_seconds\":$(_cjv "$f_uptime"),\"cpu_percent\":$(_cjv "$f_craw"),\"cpu_percent_normalized\":$(_cjv "$f_cnorm"),\"cpu_allowed\":$(_cjv "$f_callowed"),\"cpu_limited\":${f_climited:-null},\"cpu_of_allowed_percent\":$(_cjv "$f_callowedpct"),\"cpu_observed_severity\":$(_cjv "$f_cobserved"),\"cpu_high_streak\":$(_cjv "$f_cstreak"),\"cpu_pending\":$cpu_pending,\"cpu_severity\":$(_cjv "$f_csev"),\"mem_used_mb\":$(_cjv "$f_mused"),\"mem_limit_mb\":$(_cjv "$f_mlimit"),\"mem_reservation_mb\":$(_cjv "$f_mres"),\"mem_percent_of_limit\":$(_cjv "$f_mpct"),\"mem_severity\":$(_cjv "$f_msev"),\"severity\":$(_cjv "$f_sev"),\"issues\":\"$(monitor_json_escape "$f_issues")\",\"worker_hint\":${f_worker:-false},\"coolify\":{\"resource_uuid\":$(_cjv "$f_cuuid"),\"resource_type\":$(_cjv "$f_ctype"),\"resource_name\":\"$(monitor_json_escape "$f_cname")\",\"project\":\"$(monitor_json_escape "$f_cproj")\",\"environment\":\"$(monitor_json_escape "$f_cenv")\"}}"
        ((count++))
    done
    printf '%s' "$out"
}

################################################################################
# Export das funções
################################################################################

export -f monitor_mem_to_mb monitor_cpuset_count monitor_container_cpus_allowed
export -f monitor_restart_severity monitor_health_severity
export -f monitor_coolify_load_map monitor_coolify_resolve
export -f collect_containers monitor_containers_top monitor_containers_json

# Marca que monitor-containers.sh foi carregado
MONITOR_CONTAINERS_LOADED=1
export MONITOR_CONTAINERS_LOADED
