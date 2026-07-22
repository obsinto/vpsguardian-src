#!/bin/bash
################################################################################
# Script: monitor-correlation.sh
# Propósito: Motor de correlação de sintomas e diagnóstico (M6)
# Uso: source /opt/vpsguardian/lib/monitor-correlation.sh
#      (requer monitor-common.sh e monitor-alerts.sh carregados antes)
#
# Combina os sinais JÁ coletados (M1–M4) e produz diagnósticos prováveis:
#   fato observado -> evidência -> hipótese -> confiança -> recomendação
#
# NÃO faz novas coletas (0 chamadas externas), NÃO executa ações, NÃO cria novo
# webhook. Integra-se ao M5 registrando incidentes `diagnosis:*` na máquina de
# estados existente (respeitando dry-run, cooldown, dedup e recovery).
#
# Cenários obrigatórios:
#   A) Memória / swap-death   -> diagnosis:memory:*
#   B) Throttling do provedor -> diagnosis:provider:*
#   C) Worker Laravel         -> diagnosis:laravel:<rid>:*
#   D) Docker vítima do host  -> diagnosis:docker:*
#
# Confiança: LOW(1-39) MEDIUM(40-64) HIGH(65-84) VERY_HIGH(85-100)
# Papéis: ROOT_CAUSE, AMPLIFIER, IMPACT, CONTRIBUTING_FACTOR
#
# Referência: docs/MARCOS-MONITOR-PREVENTIVO.md (M6)
# Versão: 1.0.0
################################################################################

# Sinais normalizados (preenchidos por collect_signals; nos testes, direto)
declare -A CORR

# Saída da última avaliação (funções puras escrevem aqui)
EVAL_SCORE=0 EVAL_SCENARIO="" EVAL_SEV="INFO" EVAL_CONF="NONE"
EVAL_KEY="" EVAL_RTYPE="" EVAL_RID="" EVAL_TITLE="" EVAL_SUMMARY=""
EVAL_CAUSE="" EVAL_IMPACT="" EVAL_EVIDENCE="" EVAL_COUNTER="" EVAL_RECS="" EVAL_RELATED=""

# Lista de diagnósticos do ciclo (arrays indexados 0..DIAG_N-1)
DIAG_N=0
declare -A D_KEY D_SCENARIO D_ROLE D_TITLE D_SUMMARY D_SEV D_CONF D_SCORE D_STATUS
declare -A D_RTYPE D_RID D_CAUSE D_IMPACT D_EVID D_COUNTER D_RECS D_RELALERTS D_RELDIAG D_FPRINT
declare -A D_FIRST D_LAST D_AFFECTED

DIAG_MAIN_KEY="" DIAG_HIGHEST_SEV="INFO" DIAG_HIGHEST_CONF="NONE"

################################################################################
# Helpers de leitura de sinais (resistentes a dados ausentes)
################################################################################

_cget() { local v="${CORR[$1]:-}"; if [ -n "$v" ]; then printf '%s' "$v"; else printf '%s' "${2:-}"; fi; }
_cnum() { local v="${CORR[$1]:-}"; if [[ "$v" =~ ^-?[0-9]+([.][0-9]+)?$ ]]; then printf '%s' "$v"; else printf '%s' "${2:-0}"; fi; }

# Severidade presente com rank >= MIN? (ausência NÃO conta como saudável)
_sev_ge() {
    local s="${CORR[$1]:-}"
    [ -n "$s" ] || return 1
    [ "$(monitor_severity_rank "$s")" -ge "$(monitor_severity_rank "$2")" ]
}
# Sinal explicitamente saudável (INFO)?  (ausência NÃO satisfaz)
_is_info() { [ "${CORR[$1]:-}" = "INFO" ]; }
# Booleano verdadeiro?
_is_true() { [ "${CORR[$1]:-}" = "true" ]; }
_num_gt() { awk -v a="$(_cnum "$1" 0)" -v b="$2" 'BEGIN{exit !(a>b)}'; }

# Host saturado: qualquer pressão de recurso do host (derivado, resistente a ausência)
_host_saturated() {
    _sev_ge mem_severity CRITICAL && return 0
    _sev_ge swap_severity CRITICAL && return 0
    _sev_ge load_severity EMERGENCY && return 0
    _sev_ge steal_severity CRITICAL && return 0
    _sev_ge iowait_severity CRITICAL && return 0
    return 1
}

################################################################################
# Confiança
################################################################################

monitor_correlation_confidence() {
    local s="$1"
    if   [ "$s" -ge 85 ]; then echo "VERY_HIGH"
    elif [ "$s" -ge 65 ]; then echo "HIGH"
    elif [ "$s" -ge 40 ]; then echo "MEDIUM"
    elif [ "$s" -ge 1 ];  then echo "LOW"
    else echo "NONE"; fi
}

monitor_correlation_conf_rank() {
    case "$1" in
        VERY_HIGH) echo 4 ;; HIGH) echo 3 ;; MEDIUM) echo 2 ;; LOW) echo 1 ;; *) echo 0 ;;
    esac
}

# Ocorrências consecutivas exigidas por faixa de confiança
monitor_correlation_required_occurrences() {
    case "$1" in
        VERY_HIGH) echo 1 ;; HIGH) echo 2 ;; MEDIUM) echo 3 ;; *) echo 0 ;;  # LOW/NONE: nunca alerta
    esac
}

monitor_correlation_eligible() {
    local conf="$1" streak="$2"
    local req; req=$(monitor_correlation_required_occurrences "$conf")
    [ "$req" -gt 0 ] || return 1
    [[ "$streak" =~ ^[0-9]+$ ]] || return 1
    [ "$streak" -ge "$req" ]
}

_cap100() { local s="$1"; [ "$s" -gt 100 ] && s=100; [ "$s" -lt 0 ] && s=0; echo "$s"; }
_join2() { local IFS=';;'; :; }   # placeholder (usamos concatenação manual)

################################################################################
# CENÁRIO A — Esgotamento de memória / swap-death
################################################################################

monitor_correlation_eval_memory() {
    EVAL_SCORE=0 EVAL_SCENARIO="" EVAL_SEV="INFO" EVAL_KEY="" EVAL_TITLE="" EVAL_SUMMARY=""
    EVAL_RTYPE="host" EVAL_RID="host" EVAL_CAUSE="" EVAL_IMPACT=""
    EVAL_EVIDENCE="" EVAL_COUNTER="" EVAL_RECS="" EVAL_RELATED=""

    local score=0 evid="" cev="" rel=""
    local memmb; memmb=$(_cget mem_available_mb "?")
    local swp; swp=$(_cget swap_used_percent "?")

    if _sev_ge mem_severity CRITICAL; then
        score=$((score+25)); evid+="memória disponível crítica (${memmb} MB);;"; rel+="host:memoria;;"
    elif _sev_ge mem_severity WARNING; then
        score=$((score+10)); evid+="memória disponível baixa (${memmb} MB);;"; rel+="host:memoria;;"
    fi
    if _sev_ge swap_severity CRITICAL; then
        score=$((score+20)); evid+="swap elevada (${swp}%);;"; rel+="host:swap;;"
    elif _sev_ge swap_severity WARNING; then
        score=$((score+8)); evid+="swap acima do normal (${swp}%);;"; rel+="host:swap;;"
    fi
    if _num_gt swap_growth_mb 0; then
        score=$((score+15)); evid+="swap em crescimento (+$(_cnum swap_growth_mb 0) MB);;"
    fi
    if _sev_ge iowait_severity WARNING; then
        score=$((score+10)); evid+="I/O wait elevado ($(_cget cpu_iowait_percent ?)%);;"; rel+="host:iowait;;"
    fi
    if _sev_ge load_severity CRITICAL; then
        score=$((score+10)); evid+="load elevado (ratio $(_cget load_ratio ?));;"; rel+="host:load;;"
    fi
    if [ -n "${CORR[docker_status]:-}" ] && [ "${CORR[docker_status]}" != "HEALTHY" ] && _is_true docker_installed; then
        score=$((score+10)); evid+="Docker degradado (${CORR[docker_status]});;"; rel+="docker:status;;"
    fi
    if _num_gt containers_no_mem_limit 0; then
        score=$((score+10)); evid+="$(_cnum containers_no_mem_limit 0) container(s) sem limite de memória;;"
    fi
    if _num_gt laravel_total 0 && { _num_gt laravel_dangerous_timeouts 0 || _num_gt laravel_containers_no_mem_limit 0; }; then
        score=$((score+15)); evid+="worker Laravel provável causador;;"
    fi

    # Evidências contrárias
    if _is_info mem_severity; then cev+="memória disponível saudável;;"; score=$((score-10)); fi
    if _is_info swap_severity || [ "$(_cnum swap_used_percent 100)" = "0" ]; then cev+="swap sem uso relevante;;"; fi
    if _is_info iowait_severity; then cev+="I/O wait baixo;;"; fi
    if _is_info load_severity; then cev+="load baixo;;"; fi

    score=$(_cap100 "$score")
    [ "$score" -le 0 ] && { EVAL_SCORE=0; return 0; }

    # Classificação da variação
    local variation
    if _sev_ge mem_severity CRITICAL && _sev_ge swap_severity CRITICAL && \
       { _num_gt swap_growth_mb 0 || _sev_ge load_severity EMERGENCY || \
         { [ -n "${CORR[docker_status]:-}" ] && [ "${CORR[docker_status]}" != "HEALTHY" ]; }; }; then
        variation="SWAP_DEATH_LIKELY"; EVAL_KEY="diagnosis:memory:swap_death"
        EVAL_TITLE="Provável esgotamento de memória (swap-death)"; EVAL_SEV="EMERGENCY"
    elif _sev_ge mem_severity CRITICAL || { _sev_ge mem_severity WARNING && _sev_ge swap_severity CRITICAL; }; then
        variation="MEMORY_PRESSURE"; EVAL_KEY="diagnosis:memory:pressure"
        EVAL_TITLE="Pressão de memória no host"
        _sev_ge mem_severity CRITICAL && EVAL_SEV="CRITICAL" || EVAL_SEV="WARNING"
    elif _sev_ge swap_severity CRITICAL; then
        variation="SWAP_PRESSURE"; EVAL_KEY="diagnosis:memory:swap_pressure"
        EVAL_TITLE="Uso elevado de swap"; EVAL_SEV="WARNING"
    else
        variation="MEMORY_PRESSURE"; EVAL_KEY="diagnosis:memory:pressure"
        EVAL_TITLE="Pressão de memória no host"; EVAL_SEV="WARNING"
    fi

    EVAL_SCENARIO="$variation"
    EVAL_SUMMARY="Possível esgotamento de memória do host, com swap e degradação associadas."
    EVAL_CAUSE="Consumo de memória acima da capacidade do host"
    EVAL_IMPACT="Uso de swap e lentidão geral; risco de indisponibilidade"
    EVAL_CONF=$(monitor_correlation_confidence "$score")
    EVAL_SCORE="$score"
    EVAL_EVIDENCE="$evid"; EVAL_COUNTER="$cev"; EVAL_RELATED="$rel"
    EVAL_RECS="Identifique os maiores consumidores de memória;;Inspecione workers e containers sem limite;;Evite reiniciar a VPS antes de conter o causador;;Considere parar manualmente o recurso ofensivo"
    return 0
}

################################################################################
# CENÁRIO B — Throttling do provedor
################################################################################

monitor_correlation_eval_throttling() {
    EVAL_SCORE=0 EVAL_SCENARIO="" EVAL_SEV="INFO" EVAL_KEY="" EVAL_TITLE="" EVAL_SUMMARY=""
    EVAL_RTYPE="host" EVAL_RID="host" EVAL_CAUSE="" EVAL_IMPACT=""
    EVAL_EVIDENCE="" EVAL_COUNTER="" EVAL_RECS="" EVAL_RELATED=""

    local score=0 evid="" cev="" rel=""
    local steal; steal=$(_cget cpu_steal_percent "?")

    if _sev_ge steal_severity CRITICAL; then
        score=$((score+25)); evid+="CPU steal elevado (${steal}%);;"; rel+="host:steal;;"
    elif _sev_ge steal_severity WARNING; then
        score=$((score+12)); evid+="CPU steal acima do normal (${steal}%);;"; rel+="host:steal;;"
    fi
    if _num_gt cgroup_throttled_delta 0; then
        score=$((score+20)); evid+="throttling de cgroup crescendo (+$(_cnum cgroup_throttled_delta 0));;"; rel+="host:cgroup;;"
    fi
    if _sev_ge cpu_severity CRITICAL; then
        score=$((score+10)); evid+="CPU no teto ($(_cget cpu_usage_percent ?)%);;"; rel+="host:cpu;;"
    fi
    if _sev_ge load_severity CRITICAL; then
        score=$((score+5)); evid+="load elevado;;"
    fi
    if [ "${CORR[docker_status]:-}" = "SLOW" ] || _num_gt docker_ps_latency_ms 2000; then
        score=$((score+10)); evid+="comandos Docker com alta latência;;"
    fi
    # Memória/IO saudáveis reforçam a hipótese de limitação externa
    if _is_info mem_severity && { _is_info swap_severity || [ "$(_cnum swap_used_percent 100)" = "0" ]; }; then
        score=$((score+10)); evid+="memória e swap saudáveis (não explicam a lentidão);;"
    fi
    if _is_info iowait_severity; then
        score=$((score+5)); evid+="I/O wait baixo (disco não é o gargalo);;"
    fi

    # Evidências contrárias
    if _is_info steal_severity; then cev+="steal baixo;;"; score=$((score-15)); fi
    if [ "$(_cnum cgroup_throttled_delta 0)" = "0" ] && [ -n "${CORR[cgroup_throttled_delta]:-}" ]; then cev+="contadores de throttling estáveis;;"; fi
    if _sev_ge mem_severity CRITICAL || _sev_ge swap_severity CRITICAL; then cev+="memória/swap saturadas explicam a lentidão;;"; score=$((score-15)); fi
    if _sev_ge iowait_severity CRITICAL; then cev+="I/O wait alto indica gargalo de disco;;"; score=$((score-10)); fi

    score=$(_cap100 "$score")
    [ "$score" -le 0 ] && { EVAL_SCORE=0; return 0; }

    # PROVIDER exige limitação em nível de HOST/VM (steal do host), nunca apenas
    # um container atingindo a própria quota. Memória saturada permanece como
    # contraindício (já reduziu o score acima), então a confiança cai sozinha.
    local variation
    if _sev_ge steal_severity CRITICAL && ! _sev_ge iowait_severity CRITICAL; then
        variation="PROVIDER_THROTTLING_SUSPECTED"; EVAL_KEY="diagnosis:provider:cpu_throttling"
        EVAL_TITLE="Suspeita de throttling de CPU do provedor"; EVAL_SEV="CRITICAL"
    elif _num_gt cgroup_throttled_delta 0; then
        variation="CGROUP_CPU_THROTTLING"; EVAL_KEY="diagnosis:provider:cgroup_throttling"
        EVAL_TITLE="Throttling de CPU por cgroup"; EVAL_SEV="WARNING"
    else
        variation="HYPERVISOR_STEAL"; EVAL_KEY="diagnosis:provider:hypervisor_steal"
        EVAL_TITLE="CPU steal elevada (hypervisor)"; EVAL_SEV="WARNING"
    fi

    EVAL_SCENARIO="$variation"
    EVAL_SUMMARY="Há evidências de limitação de CPU no nível da VM/host; memória e I/O não explicam integralmente a lentidão."
    EVAL_CAUSE="Limitação de CPU aplicada fora da VM (provedor/hypervisor)"
    EVAL_IMPACT="Comandos e containers lentos; reconciliação do Docker prejudicada"
    EVAL_CONF=$(monitor_correlation_confidence "$score")
    EVAL_SCORE="$score"
    EVAL_EVIDENCE="$evid"; EVAL_COUNTER="$cev"; EVAL_RELATED="$rel"
    EVAL_RECS="Registre steal, cpu.stat, cpu.max, load e latência do Docker;;Confirme se há quota de cgroup no host;;Abra chamado com o provedor com esses dados;;Não atribua o problema ao Docker sem evidências adicionais"
    return 0
}

################################################################################
# CENÁRIO C — Worker Laravel descontrolado
################################################################################

monitor_correlation_eval_laravel() {
    EVAL_SCORE=0 EVAL_SCENARIO="" EVAL_SEV="INFO" EVAL_KEY="" EVAL_TITLE="" EVAL_SUMMARY=""
    EVAL_RTYPE="laravel_worker" EVAL_RID="host" EVAL_CAUSE="" EVAL_IMPACT=""
    EVAL_EVIDENCE="" EVAL_COUNTER="" EVAL_RECS="" EVAL_RELATED=""

    _num_gt laravel_total 0 || { EVAL_SCORE=0; return 0; }

    local score=0 evid="" cev="" rel="host"
    local issues=0
    local maxto; maxto=$(_cnum laravel_max_timeout 0)
    local grp; grp=$(_cnum laravel_max_group_count 0)
    local rid; rid=$(_cget laravel_worst_container host)
    EVAL_RID="$rid"
    rel="worker:$(_cget laravel_worst_container_name "$rid")"

    if [ "$maxto" -gt 3600 ]; then
        score=$((score+30)); evid+="timeout extremamente alto (${maxto}s);;"; ((issues++))
    elif [ "$maxto" -gt 900 ]; then
        score=$((score+18)); evid+="timeout alto (${maxto}s);;"; ((issues++))
    fi
    if [ "$grp" -gt 4 ]; then
        score=$((score+25)); evid+="quantidade excessiva de workers (${grp});;"; ((issues++))
    elif [ "$grp" -gt 2 ]; then
        score=$((score+12)); evid+="muitos workers equivalentes (${grp});;"; ((issues++))
    fi
    local target_no_limit target_shared no_limit_active=false
    target_no_limit=$(_cget laravel_target_no_mem_limit "")
    target_shared=$(_cget laravel_target_shared_with_web "")
    if { [ -n "$target_no_limit" ] && _is_true laravel_target_no_mem_limit; } || \
       { [ -z "$target_no_limit" ] && _num_gt laravel_containers_no_mem_limit 0; }; then
        no_limit_active=true
        score=$((score+15)); evid+="worker em container sem limite de memória;;"; ((issues++))
    fi
    if { [ -n "$target_shared" ] && _is_true laravel_target_shared_with_web; } || \
       { [ -z "$target_shared" ] && _num_gt laravel_shared_with_web 0; }; then
        score=$((score+10)); evid+="worker compartilhado com servidor web;;"; ((issues++))
    fi
    if _is_true laravel_restart_loop; then
        score=$((score+12)); evid+="restart loop de worker;;"; ((issues++))
    fi
    if _is_true laravel_schedule_stuck; then
        score=$((score+18)); evid+="schedule:run travado;;"; ((issues++))
    fi
    # Ligações causais com o host
    if _sev_ge mem_severity CRITICAL; then score=$((score+10)); evid+="memória do host crítica;;"; rel+=";;host:memoria"; fi
    if _num_gt swap_growth_mb 0; then score=$((score+5)); evid+="swap em crescimento;;"; fi

    if _num_gt laravel_dangerous_timeouts 0 && [ "$issues" -eq 0 ]; then
        score=$((score+15)); evid+="timeout perigoso configurado;;"; ((issues++))
    fi

    if _is_info laravel_max_severity && [ "$issues" -eq 0 ]; then
        cev+="workers Laravel sem configuração perigosa detectada;;"
    fi

    score=$(_cap100 "$score")
    [ "$score" -le 0 ] && { EVAL_SCORE=0; return 0; }

    local variation
    if _is_true laravel_schedule_stuck; then
        variation="SCHEDULE_RUN_STUCK"
    elif [ "$issues" -ge 2 ]; then
        variation="LARAVEL_WORKER_MISCONFIGURATION"
    elif [ "$grp" -gt 4 ]; then
        variation="HORIZON_EXCESSIVE_WORKERS"
    elif [ "$maxto" -gt 3600 ]; then
        variation="LONG_RUNNING_JOB_SUSPECTED"
    elif [ "$no_limit_active" = true ]; then
        variation="WORKER_RESOURCE_LEAK_SUSPECTED"
    else
        variation="LARAVEL_WORKER_MISCONFIGURATION"
    fi

    EVAL_SCENARIO="$variation"
    EVAL_KEY="diagnosis:laravel:${rid}:$(echo "$variation" | tr 'A-Z' 'a-z')"
    EVAL_TITLE="Worker Laravel/Horizon descontrolado"
    EVAL_SUMMARY="Worker Laravel/Horizon é o provável gatilho do incidente."
    local cause="Configuração inadequada de worker"
    if [ "$grp" -gt 4 ] && [ "$maxto" -gt 900 ]; then
        cause="Grupo Laravel com ${grp} workers e timeout de ${maxto}s"
    elif [ "$grp" -gt 4 ]; then
        cause="Grupo Laravel com ${grp} workers equivalentes"
    elif [ "$maxto" -gt 900 ]; then
        cause="Worker Laravel com timeout de ${maxto}s"
    fi
    EVAL_CAUSE="$cause"
    EVAL_IMPACT="Pressão de memória/swap e degradação do Docker"
    EVAL_SEV="WARNING"
    { [ "$maxto" -gt 3600 ] && [ "$no_limit_active" = true ]; } && EVAL_SEV="EMERGENCY"
    [ "$EVAL_SEV" = "WARNING" ] && _num_gt laravel_dangerous_timeouts 0 && EVAL_SEV="CRITICAL"
    EVAL_CONF=$(monitor_correlation_confidence "$score")
    [ "$EVAL_CONF" = "VERY_HIGH" ] && EVAL_SEV="EMERGENCY"
    EVAL_SCORE="$score"
    EVAL_EVIDENCE="$evid"; EVAL_COUNTER="$cev"; EVAL_RELATED="$rel"
    EVAL_RECS="Revise timeout, maxProcesses, memory e max-time;;Isole os workers do container web;;Configure limites de memória/CPU no container;;Quebre jobs longos em chunks"
    return 0
}

################################################################################
# CENÁRIO D — Docker é vítima do host
################################################################################

monitor_correlation_eval_docker() {
    EVAL_SCORE=0 EVAL_SCENARIO="" EVAL_SEV="INFO" EVAL_KEY="" EVAL_TITLE="" EVAL_SUMMARY=""
    EVAL_RTYPE="docker" EVAL_RID="host" EVAL_CAUSE="" EVAL_IMPACT=""
    EVAL_EVIDENCE="" EVAL_COUNTER="" EVAL_RECS="" EVAL_RELATED=""

    _is_true docker_installed || { EVAL_SCORE=0; return 0; }

    local score=0 evid="" cev="" rel="docker:status"
    local dstatus; dstatus=$(_cget docker_status UNKNOWN)
    local unresponsive=false slow=false
    [ "${CORR[docker_ps_ok]:-}" = "false" ] && unresponsive=true
    [ "$dstatus" = "SLOW" ] && slow=true
    local containerd_ok=false
    { [ "${CORR[containerd_responsive]:-}" = "true" ] || [ "${CORR[containerd_status]:-}" = "HEALTHY" ] || [ "${CORR[containerd_status]:-}" = "SLOW" ]; } && containerd_ok=true
    local dockerd_active=false
    [ -n "${CORR[dockerd_pid]:-}" ] && dockerd_active=true

    if [ "$unresponsive" = true ]; then
        score=$((score+20)); evid+="docker ps excede timeout;;"
    elif [ "$slow" = true ]; then
        score=$((score+10)); evid+="docker ps lento;;"
    fi
    if [ "$containerd_ok" = true ]; then
        score=$((score+15)); evid+="containerd ainda responde;;"
    fi
    if [ "$dockerd_active" = true ]; then
        score=$((score+10)); evid+="dockerd continua ativo;;"
    fi
    if _host_saturated; then
        score=$((score+25)); evid+="host saturado (memória/swap/load/steal/io);;"
        _sev_ge mem_severity CRITICAL && rel+=";;host:memoria"
        _sev_ge swap_severity CRITICAL && rel+=";;host:swap"
    fi
    if _num_gt dockerd_threads 200; then
        score=$((score+5)); evid+="dockerd com muitas threads ($(_cnum dockerd_threads 0));;"
    fi

    # Evidências contrárias
    if ! _host_saturated; then cev+="host saudável (Docker lento seria falha do próprio Docker);;"; score=$((score-20)); fi
    [ "${CORR[docker_service_state]:-}" = "failed" ] && { cev+="serviço docker em falha;;"; }
    [ "${CORR[containerd_status]:-}" = "UNRESPONSIVE" ] && cev+="containerd também não responde;;"
    [ "${CORR[socket_exists]:-}" = "false" ] && cev+="socket do Docker ausente;;"

    score=$(_cap100 "$score")
    [ "$score" -le 0 ] && { EVAL_SCORE=0; return 0; }

    local variation
    if { [ "$unresponsive" = true ] || [ "$slow" = true ]; } && [ "$containerd_ok" = false ] && \
         { [ "${CORR[containerd_status]:-}" = "UNRESPONSIVE" ] || [ "${CORR[containerd_status]:-}" = "NOT_AVAILABLE" ]; }; then
        variation="DOCKER_STACK_UNAVAILABLE"; EVAL_KEY="diagnosis:docker:stack_unavailable"
        EVAL_TITLE="Stack de containers indisponível"; EVAL_SEV="EMERGENCY"
    elif { [ "$unresponsive" = true ] || [ "$slow" = true ]; } && [ "$containerd_ok" = true ] && _host_saturated; then
        variation="DOCKER_DEGRADED_BY_HOST"; EVAL_KEY="diagnosis:docker:degraded_by_host"
        EVAL_TITLE="Docker degradado pela saturação do host"; EVAL_SEV="CRITICAL"
        _sev_ge mem_severity EMERGENCY && EVAL_SEV="EMERGENCY"
        _sev_ge load_severity EMERGENCY && EVAL_SEV="EMERGENCY"
    elif [ "$unresponsive" = true ] && [ "$containerd_ok" = true ]; then
        variation="CONTAINERD_HEALTHY_DOCKER_SLOW"; EVAL_KEY="diagnosis:docker:containerd_healthy_docker_slow"
        EVAL_TITLE="Docker sem resposta; containerd saudável"; EVAL_SEV="WARNING"
    elif [ "$unresponsive" = true ]; then
        variation="DOCKERD_UNRESPONSIVE"; EVAL_KEY="diagnosis:docker:dockerd_unresponsive"
        EVAL_TITLE="Docker sem resposta"; EVAL_SEV="WARNING"
    else
        variation="CONTAINERD_HEALTHY_DOCKER_SLOW"; EVAL_KEY="diagnosis:docker:containerd_healthy_docker_slow"
        EVAL_TITLE="Docker lento"; EVAL_SEV="WARNING"
    fi

    EVAL_SCENARIO="$variation"
    EVAL_SUMMARY="O Docker provavelmente é afetado pela saturação do host; sem evidência de corrupção do daemon."
    EVAL_CAUSE="Saturação de recursos do host afetando o dockerd"
    EVAL_IMPACT="Comandos Docker lentos ou travados; reconciliação de containers prejudicada"
    EVAL_CONF=$(monitor_correlation_confidence "$score")
    EVAL_SCORE="$score"
    EVAL_EVIDENCE="$evid"; EVAL_COUNTER="$cev"; EVAL_RELATED="$rel"
    EVAL_RECS="Verifique os recursos do host primeiro;;Consulte o containerd como fallback;;Evite reiniciar o Docker repetidamente sob swap elevada;;Corrija a pressão de recursos antes de mexer no Docker"
    return 0
}

################################################################################
# Fingerprint de diagnóstico (dedup): ignora variações numéricas pequenas
################################################################################

monitor_correlation_fingerprint() {
    local scenario="$1" rid="$2" conf="$3" sev="$4" role="$5" evidence="$6"
    # Assinatura de evidência = itens sem dígitos (variação numérica não conta)
    local evsig; evsig=$(printf '%s' "$evidence" | tr -d '0-9' | tr 'A-Z' 'a-z')
    local raw="${scenario}|${rid}|${conf}|${sev}|${role}|${evsig}"
    if command -v sha256sum &>/dev/null; then
        printf '%s' "$raw" | sha256sum | cut -c1-16
    else
        printf '%s' "$raw" | cksum | tr -d ' '
    fi
}

################################################################################
# Coleta de sinais a partir dos globais já preenchidos (0 chamadas externas)
################################################################################

_cset() { [ -n "$2" ] && CORR["$1"]="$2"; }

monitor_correlation_collect_signals() {
    CORR=()
    _cset mem_severity "${MEM_SEVERITY:-}"
    _cset mem_available_mb "${MEM_AVAILABLE_MB:-}"
    _cset swap_severity "${SWAP_SEVERITY:-}"
    _cset swap_used_percent "${SWAP_USED_PERCENT:-}"
    [ -n "${SWAP_GROWTH_MB:-}" ] && [ "${SWAP_GROWTH_MB}" != "n/d" ] && CORR[swap_growth_mb]="$SWAP_GROWTH_MB"
    _cset load_severity "${LOAD_SEVERITY:-}"
    _cset load_ratio "${LOAD_RATIO:-}"
    _cset cpu_severity "${CPU_SEVERITY:-}"
    _cset cpu_usage_percent "${CPU_USAGE_PERCENT:-}"
    _cset steal_severity "${CPU_STEAL_SEVERITY:-}"
    _cset cpu_steal_percent "${CPU_STEAL_PERCENT:-}"
    _cset iowait_severity "${CPU_IOWAIT_SEVERITY:-}"
    _cset cpu_iowait_percent "${CPU_IOWAIT_PERCENT:-}"
    _cset cgroup_severity "${CGROUP_SEVERITY:-}"
    [ -n "${CGROUP_THROTTLED_DELTA:-}" ] && [ "${CGROUP_THROTTLED_DELTA}" != "n/d" ] && CORR[cgroup_throttled_delta]="$CGROUP_THROTTLED_DELTA"
    _cset disk_severity "${DISK_SEVERITY:-}"
    _cset disk_used_percent "${DISK_USED_PERCENT:-}"
    _cset inode_severity "${INODE_SEVERITY:-}"
    _cset docker_status "${DOCKER_STATUS:-}"
    _cset docker_severity "${DOCKER_SEVERITY:-}"
    _cset docker_ps_ok "${DOCKER_PS_OK:-}"
    _cset docker_ps_latency_ms "${DOCKER_PS_LATENCY_MS:-}"
    _cset docker_installed "${DOCKER_INSTALLED:-}"
    _cset docker_service_state "${DOCKER_SERVICE_STATE:-}"
    _cset socket_exists "${DOCKER_SOCKET_EXISTS:-}"
    _cset containerd_status "${CONTAINERD_STATUS:-}"
    _cset containerd_responsive "${CONTAINERD_PROBE_OK:-}"
    _cset dockerd_pid "${DOCKERD_PID:-}"
    _cset dockerd_threads "${DOCKERD_THREADS:-}"
    _cset containers_no_mem_limit "${CONTAINERS_NO_MEM_LIMIT:-}"
    _cset containers_unhealthy "${CONTAINERS_UNHEALTHY:-}"
    _cset containers_restart_loops "${CONTAINERS_RESTART_LOOPS:-}"

    # Agregados de workers Laravel (derivados de LARAVEL_WORKERS_DATA — sem novas coletas)
    _cset laravel_total "${LARAVEL_TOTAL:-0}"
    _cset laravel_horizon_workers "${LARAVEL_HORIZON_WORKERS:-0}"
    _cset laravel_dangerous_timeouts "${LARAVEL_DANGEROUS_TIMEOUTS:-0}"
    _cset laravel_shared_with_web "${LARAVEL_SHARED_WITH_WEB:-0}"
    _cset laravel_containers_no_mem_limit "${LARAVEL_CONTAINERS_NO_MEM_LIMIT:-0}"
    _cset laravel_max_severity "${LARAVEL_MAX_SEVERITY:-INFO}"

    # Seleciona um único worker/grupo alvo. Antes, o maior timeout e a maior
    # quantidade eram coletados independentemente e podiam pertencer a
    # aplicações diferentes, produzindo uma causa composta inexistente.
    local max_to=0 max_grp=0 restart_loop=false sched_stuck=false worst_c="host" worst_cn="" worst_rss=0
    local target_no_limit=false target_shared=false best_score=-1 best_id=""
    local rec
    local -a F
    for rec in "${LARAVEL_WORKERS_DATA[@]}"; do
        IFS='|' read -r -a F <<< "$rec"
        local to="${F[16]}" grp="${F[29]}" cid="${F[10]}" cname="${F[11]}" rss="${F[8]}" find="${F[30]}"
        [[ "$to" =~ ^[0-9]+$ ]] || to=0
        [[ "$grp" =~ ^[0-9]+$ ]] || grp=1

        local candidate=0 has_no_limit=false has_shared=false candidate_id
        if [ "$to" -gt 3600 ]; then candidate=$((candidate+30))
        elif [ "$to" -gt 900 ]; then candidate=$((candidate+18)); fi
        if [ "$grp" -gt 4 ]; then candidate=$((candidate+25))
        elif [ "$grp" -gt 2 ]; then candidate=$((candidate+12)); fi
        case ",$find," in *,container_without_memory_limit,*) candidate=$((candidate+15)); has_no_limit=true ;; esac
        case ",$find," in *,shared_with_web,*) candidate=$((candidate+10)); has_shared=true ;; esac
        case ",$find," in *,schedule_run_stuck,*) candidate=$((candidate+18)); sched_stuck=true ;; esac
        candidate_id="${cid:-host}|${F[9]:-worker}|${F[15]:-}"

        if [ "$candidate" -gt "$best_score" ] || \
           { [ "$candidate" -eq "$best_score" ] && { [ -z "$best_id" ] || [[ "$candidate_id" < "$best_id" ]]; }; }; then
            best_score="$candidate"; best_id="$candidate_id"
            max_to="$to"; max_grp="$grp"; worst_c="${cid:-host}"; worst_cn="$cname"
            target_no_limit="$has_no_limit"; target_shared="$has_shared"
        fi
        [[ "$rss" =~ ^[0-9]+$ ]] && [ "$((rss/1024))" -gt "$worst_rss" ] && worst_rss=$((rss/1024))
    done
    # restart loop de worker vem do inventário M3
    [ "$(_cnum containers_restart_loops 0)" -gt 0 ] && _num_gt laravel_total 0 && restart_loop=true
    CORR[laravel_max_timeout]="$max_to"
    CORR[laravel_max_group_count]="$max_grp"
    CORR[laravel_target_no_mem_limit]="$target_no_limit"
    CORR[laravel_target_shared_with_web]="$target_shared"
    CORR[laravel_restart_loop]="$restart_loop"
    CORR[laravel_schedule_stuck]="$sched_stuck"
    CORR[laravel_worst_container]="$worst_c"
    [ -n "$worst_cn" ] && CORR[laravel_worst_container_name]="$worst_cn"
    CORR[laravel_worst_rss_mb]="$worst_rss"
}

################################################################################
# Registro de um diagnóstico na lista do ciclo
################################################################################

_corr_add_from_eval() {
    [ "${EVAL_SCORE:-0}" -gt 0 ] || return 0
    [ "$EVAL_CONF" = "NONE" ] && return 0
    local i="$DIAG_N"
    D_KEY[$i]="$EVAL_KEY"; D_SCENARIO[$i]="$EVAL_SCENARIO"; D_TITLE[$i]="$EVAL_TITLE"
    D_SUMMARY[$i]="$EVAL_SUMMARY"; D_SEV[$i]="$EVAL_SEV"; D_CONF[$i]="$EVAL_CONF"
    D_SCORE[$i]="$EVAL_SCORE"; D_STATUS[$i]="active"; D_RTYPE[$i]="$EVAL_RTYPE"
    D_RID[$i]="$EVAL_RID"; D_CAUSE[$i]="$EVAL_CAUSE"; D_IMPACT[$i]="$EVAL_IMPACT"
    D_EVID[$i]="$EVAL_EVIDENCE"; D_COUNTER[$i]="$EVAL_COUNTER"; D_RECS[$i]="$EVAL_RECS"
    D_RELALERTS[$i]="$EVAL_RELATED"; D_ROLE[$i]="CONTRIBUTING_FACTOR"; D_RELDIAG[$i]=""
    D_FIRST[$i]="" D_LAST[$i]="" D_AFFECTED[$i]="$EVAL_RID"
    D_FPRINT[$i]=$(monitor_correlation_fingerprint "$EVAL_SCENARIO" "$EVAL_RID" "$EVAL_CONF" "$EVAL_SEV" "CONTRIBUTING_FACTOR" "$EVAL_EVIDENCE")
    DIAG_N=$((DIAG_N+1))
}

# Especificidade (desempate): laravel > throttling > memory > docker > outros
_corr_specificity() {
    case "$1" in
        diagnosis:laravel:*) echo 4 ;;
        diagnosis:provider:*) echo 3 ;;
        diagnosis:memory:*) echo 2 ;;
        diagnosis:docker:*) echo 1 ;;
        *) echo 0 ;;
    esac
}

_corr_is_cause_capable() {
    case "$1" in
        diagnosis:laravel:*|diagnosis:memory:*|diagnosis:provider:*) return 0 ;;
        *) return 1 ;;
    esac
}

################################################################################
# Atribuição de papéis, encadeamento e seleção do diagnóstico principal
################################################################################

monitor_correlation_assign_roles() {
    DIAG_MAIN_KEY="" DIAG_HIGHEST_SEV="INFO" DIAG_HIGHEST_CONF="NONE"
    [ "$DIAG_N" -eq 0 ] && return 0

    # 1. Raiz: prioridade da spec = confiança (faixa) > relação causal/especificidade
    #    > severidade > score. Isso faz um diagnóstico específico (Laravel) vencer
    #    um genérico (memória) quando ambos estão na mesma faixa de confiança.
    # Chave de comparação por diagnóstico: conf_rank, specificity, sev_rank, score.
    local i root=-1 any=-1
    local root_cr=-1 root_sp=-1 root_sr=-1 root_sc=-1
    local any_cr=-1 any_sp=-1 any_sr=-1 any_sc=-1
    for ((i=0; i<DIAG_N; i++)); do
        local cr sp sr sc
        cr=$(monitor_correlation_conf_rank "${D_CONF[$i]}")
        sp=$(_corr_specificity "${D_KEY[$i]}")
        sr=$(monitor_severity_rank "${D_SEV[$i]}")
        sc="${D_SCORE[$i]}"
        # comparação lexicográfica (cr, sp, sr, sc)
        if [ "$cr" -gt "$any_cr" ] || \
           { [ "$cr" -eq "$any_cr" ] && [ "$sp" -gt "$any_sp" ]; } || \
           { [ "$cr" -eq "$any_cr" ] && [ "$sp" -eq "$any_sp" ] && [ "$sr" -gt "$any_sr" ]; } || \
           { [ "$cr" -eq "$any_cr" ] && [ "$sp" -eq "$any_sp" ] && [ "$sr" -eq "$any_sr" ] && [ "$sc" -gt "$any_sc" ]; }; then
            any=$i; any_cr="$cr"; any_sp="$sp"; any_sr="$sr"; any_sc="$sc"
        fi
        if _corr_is_cause_capable "${D_KEY[$i]}"; then
            if [ "$cr" -gt "$root_cr" ] || \
               { [ "$cr" -eq "$root_cr" ] && [ "$sp" -gt "$root_sp" ]; } || \
               { [ "$cr" -eq "$root_cr" ] && [ "$sp" -eq "$root_sp" ] && [ "$sr" -gt "$root_sr" ]; } || \
               { [ "$cr" -eq "$root_cr" ] && [ "$sp" -eq "$root_sp" ] && [ "$sr" -eq "$root_sr" ] && [ "$sc" -gt "$root_sc" ]; }; then
                root=$i; root_cr="$cr"; root_sp="$sp"; root_sr="$sr"; root_sc="$sc"
            fi
        fi
    done
    [ "$root" -lt 0 ] && root=$any

    # 2. Papéis
    for ((i=0; i<DIAG_N; i++)); do
        local role
        if [ "$i" -eq "$root" ]; then
            role="ROOT_CAUSE"
        else
            case "${D_KEY[$i]}" in
                diagnosis:memory:*) role="AMPLIFIER" ;;
                diagnosis:docker:*) role="IMPACT" ;;
                diagnosis:provider:*) role="CONTRIBUTING_FACTOR" ;;
                diagnosis:laravel:*) role="CONTRIBUTING_FACTOR" ;;
                *) role="CONTRIBUTING_FACTOR" ;;
            esac
        fi
        D_ROLE[$i]="$role"
        # Recalcula fingerprint agora que o papel é conhecido
        D_FPRINT[$i]=$(monitor_correlation_fingerprint "${D_SCENARIO[$i]}" "${D_RID[$i]}" \
            "${D_CONF[$i]}" "${D_SEV[$i]}" "$role" "${D_EVID[$i]}")
    done

    # 3. Encadeamento (related_diagnosis_keys) e principal
    DIAG_MAIN_KEY="${D_KEY[$root]}"
    local reldiag=""
    for ((i=0; i<DIAG_N; i++)); do
        [ "$i" -ne "$root" ] && reldiag+="${D_KEY[$i]};;"
        # maiores severidade/confiança globais
        [ "$(monitor_severity_rank "${D_SEV[$i]}")" -gt "$(monitor_severity_rank "$DIAG_HIGHEST_SEV")" ] && DIAG_HIGHEST_SEV="${D_SEV[$i]}"
        [ "$(monitor_correlation_conf_rank "${D_CONF[$i]}")" -gt "$(monitor_correlation_conf_rank "$DIAG_HIGHEST_CONF")" ] && DIAG_HIGHEST_CONF="${D_CONF[$i]}"
    done
    D_RELDIAG[$root]="$reldiag"
    return 0
}

################################################################################
# Orquestração — cálculo (sempre) e registro no M5 (quando habilitado)
################################################################################

monitor_correlation_reset() {
    DIAG_N=0
    D_KEY=(); D_SCENARIO=(); D_ROLE=(); D_TITLE=(); D_SUMMARY=(); D_SEV=(); D_CONF=()
    D_SCORE=(); D_STATUS=(); D_RTYPE=(); D_RID=(); D_CAUSE=(); D_IMPACT=(); D_EVID=()
    D_COUNTER=(); D_RECS=(); D_RELALERTS=(); D_RELDIAG=(); D_FPRINT=()
    D_FIRST=(); D_LAST=(); D_AFFECTED=()
    DIAG_MAIN_KEY="" DIAG_HIGHEST_SEV="INFO" DIAG_HIGHEST_CONF="NONE"
}

# Calcula todos os diagnósticos (sem persistência e sem registro). Sempre seguro.
monitor_correlation_compute() {
    monitor_correlation_collect_signals
    monitor_correlation_reset

    monitor_correlation_eval_memory;    _corr_add_from_eval
    monitor_correlation_eval_throttling; _corr_add_from_eval
    monitor_correlation_eval_laravel;   _corr_add_from_eval
    monitor_correlation_eval_docker;    _corr_add_from_eval

    monitor_correlation_assign_roles

    # Timestamps (leitura do estado; sem gravar — seguro em dry-run)
    monitor_correlation_load_diag_state
    local now i
    now=$(date +%s)
    for ((i=0; i<DIAG_N; i++)); do
        local k="${D_KEY[$i]}"
        D_FIRST[$i]="${DGST_FIRST[$k]:-$now}"
        D_LAST[$i]="$now"
        D_AFFECTED[$i]="${D_RID[$i]}"
    done
}

# Estado de ocorrências dos diagnósticos (para confirmação por confiança)
declare -A DGST DGST_FIRST DGST_LAST
monitor_correlation_load_diag_state() {
    DGST=(); DGST_FIRST=(); DGST_LAST=()
    local f="${MONITOR_DIAG_STATE_FILE:-$MONITOR_STATE_DIR/diagnoses.state}"
    [ -f "$f" ] || return 0
    local key streak first last
    while IFS='|' read -r key streak first last; do
        [ -n "$key" ] || continue
        DGST["$key"]="$streak"
        [ -n "$first" ] && DGST_FIRST["$key"]="$first"
        [ -n "$last" ] && DGST_LAST["$key"]="$last"
    done < "$f"
}

# Registra diagnósticos elegíveis como incidentes M5 e persiste o streak
# (dry-run: simula, não grava, não registra envio real — o M5 cuida disso).
DIAG_ALERTED=0 DIAG_PENDING_CONF=0
monitor_correlation_register() {
    DIAG_ALERTED=0 DIAG_PENDING_CONF=0
    local dry_run="${MONITOR_ALERT_DRY_RUN:-false}"
    monitor_correlation_load_diag_state

    local -A newstreak
    local i
    for ((i=0; i<DIAG_N; i++)); do
        local key="${D_KEY[$i]}" conf="${D_CONF[$i]}"
        local prev="${DGST[$key]:-0}"
        [[ "$prev" =~ ^[0-9]+$ ]] || prev=0
        local streak=$((prev+1))
        newstreak[$key]="$streak"

        if monitor_correlation_eligible "$conf" "$streak"; then
            # Corpo compacto e sanitizado (sem segredos: derivado de métricas)
            local top3; top3=$(printf '%s' "${D_EVID[$i]}" | awk -F';;' '{n=0; for(j=1;j<=NF;j++){if($j!=""){printf "%s%s",(n?" • ":""),$j; n++; if(n>=3)break}}}')
            local body="Confiança: ${conf} | Papel: ${D_ROLE[$i]}\nCausa provável: ${D_CAUSE[$i]}\nImpacto: ${D_IMPACT[$i]}\nEvidências: ${top3}"
            monitor_alert_register "$key" "${D_SEV[$i]}" "Diagnóstico: ${D_TITLE[$i]}" "$body"
            D_STATUS[$i]="alerting"
            ((DIAG_ALERTED++))
        else
            [ "$conf" != "NONE" ] && [ "$conf" != "LOW" ] && ((DIAG_PENDING_CONF++))
            D_STATUS[$i]="pending_confidence"
        fi
    done

    # Persistência do streak + timestamps (nunca em dry-run)
    if [ "$dry_run" != "true" ]; then
        local now2; now2=$(date +%s)
        local f="${MONITOR_DIAG_STATE_FILE:-$MONITOR_STATE_DIR/diagnoses.state}"
        local tmp="$f.tmp.$$" key
        if : > "$tmp" 2>/dev/null; then
            for key in "${!newstreak[@]}"; do
                printf '%s|%s|%s|%s\n' "$key" "${newstreak[$key]}" \
                    "${DGST_FIRST[$key]:-$now2}" "$now2" >> "$tmp"
            done
            mv -f "$tmp" "$f" 2>/dev/null || rm -f "$tmp" 2>/dev/null
        fi
    fi
    return 0
}

################################################################################
# Saída JSON dos diagnósticos
################################################################################

_djv() { if [ -z "$1" ]; then printf 'null'; else monitor_json_value "$1"; fi; }
_dj_arr() {
    # Converte lista ';;'-separada em array JSON de strings
    local s="$1" out="" item
    local IFS=';;'
    local -a parts
    read -ra parts <<< "$s"
    for item in "${parts[@]}"; do
        [ -n "$item" ] || continue
        [ -n "$out" ] && out+=","
        out+="\"$(monitor_json_escape "$item")\""
    done
    printf '[%s]' "$out"
}

monitor_correlation_json() {
    local out="" i
    for ((i=0; i<DIAG_N; i++)); do
        [ -n "$out" ] && out+=","
        out+="{\"diagnosis_key\":\"${D_KEY[$i]}\",\"scenario\":\"${D_SCENARIO[$i]}\",\"role\":\"${D_ROLE[$i]}\",\"title\":\"$(monitor_json_escape "${D_TITLE[$i]}")\",\"summary\":\"$(monitor_json_escape "${D_SUMMARY[$i]}")\",\"severity\":\"${D_SEV[$i]}\",\"confidence\":\"${D_CONF[$i]}\",\"confidence_score\":${D_SCORE[$i]},\"status\":\"${D_STATUS[$i]}\",\"resource_type\":\"${D_RTYPE[$i]}\",\"resource_id\":$(_djv "${D_RID[$i]}"),\"probable_cause\":\"$(monitor_json_escape "${D_CAUSE[$i]}")\",\"impact\":\"$(monitor_json_escape "${D_IMPACT[$i]}")\",\"fingerprint\":\"${D_FPRINT[$i]}\",\"evidence\":$(_dj_arr "${D_EVID[$i]}"),\"counter_evidence\":$(_dj_arr "${D_COUNTER[$i]}"),\"recommendations\":$(_dj_arr "${D_RECS[$i]}"),\"affected_resources\":$(_dj_arr "${D_AFFECTED[$i]}"),\"related_alert_keys\":$(_dj_arr "${D_RELALERTS[$i]}"),\"related_diagnosis_keys\":$(_dj_arr "${D_RELDIAG[$i]}"),\"first_detected_at\":$(_djv "${D_FIRST[$i]}"),\"last_detected_at\":$(_djv "${D_LAST[$i]}")}"
    done
    printf '%s' "$out"
}

################################################################################
# Export
################################################################################

export -f monitor_correlation_confidence monitor_correlation_conf_rank
export -f monitor_correlation_required_occurrences monitor_correlation_eligible
export -f monitor_correlation_eval_memory monitor_correlation_eval_throttling
export -f monitor_correlation_eval_laravel monitor_correlation_eval_docker
export -f monitor_correlation_fingerprint monitor_correlation_collect_signals
export -f monitor_correlation_assign_roles monitor_correlation_reset
export -f monitor_correlation_compute monitor_correlation_register
export -f monitor_correlation_load_diag_state monitor_correlation_json

MONITOR_CORRELATION_LOADED=1
export MONITOR_CORRELATION_LOADED
