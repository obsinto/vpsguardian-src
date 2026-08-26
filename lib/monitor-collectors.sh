#!/bin/bash
################################################################################
# Script: monitor-collectors.sh
# Propósito: Coletores de métricas do host (M1) para o Monitor Preventivo
# Uso: source /opt/vpsguardian/lib/monitor-collectors.sh
#      (requer monitor-common.sh carregado antes)
#
# Coletores:
#   - collect_host_info : identificação do host
#   - collect_load      : load average e load ratio
#   - collect_memory    : RAM via /proc/meminfo
#   - collect_swap      : swap + crescimento entre execuções
#   - collect_cpu       : CPU por delta de /proc/stat (user/system/iowait/steal)
#   - collect_cgroup    : quota e throttling de CPU (cgroup v1 e v2)
#   - collect_processes : top 10 processos por CPU e por memória
#   - collect_disk      : uso e inodes da partição raiz
#
# Todas as fontes usam MONITOR_PROC_DIR / MONITOR_SYS_CGROUP_DIR, permitindo
# testes com fixtures. Nenhum coletor aborta o monitor: falhas resultam em
# severidade UNKNOWN e o restante da coleta continua.
#
# Referência: docs/MARCOS-MONITOR-PREVENTIVO.md (M1)
# Versão: 1.0.0
################################################################################

################################################################################
# Identificação do host
################################################################################

collect_host_info() {
    HOST_HOSTNAME=$(hostname 2>/dev/null || echo "desconhecido")
    HOST_DATETIME=$(date -Iseconds 2>/dev/null || date)
    HOST_KERNEL=$(uname -r 2>/dev/null || echo "desconhecido")

    # vCPUs: preferir /proc/cpuinfo (testável); fallback para nproc
    HOST_VCPUS=$(grep -c '^processor' "$MONITOR_PROC_DIR/cpuinfo" 2>/dev/null)
    if ! monitor_is_number "$HOST_VCPUS" || [ "$HOST_VCPUS" -eq 0 ]; then
        HOST_VCPUS=$(nproc 2>/dev/null || echo 1)
    fi

    # Uptime em segundos (primeiro campo de /proc/uptime)
    HOST_UPTIME_SECONDS=$(awk '{print int($1)}' "$MONITOR_PROC_DIR/uptime" 2>/dev/null)
    monitor_is_number "$HOST_UPTIME_SECONDS" || HOST_UPTIME_SECONDS=""
    HOST_UPTIME_HUMAN=$(monitor_format_uptime "$HOST_UPTIME_SECONDS")

    # Versão do SO quando disponível
    if [ -f /etc/os-release ]; then
        HOST_OS=$(awk -F= '$1=="PRETTY_NAME" {gsub(/"/,"",$2); print $2}' /etc/os-release 2>/dev/null)
    fi
    HOST_OS="${HOST_OS:-desconhecido}"

    return 0
}

################################################################################
# Load average
################################################################################

# Calcula load_ratio = load_1min / vCPUs (função pura, testável)
monitor_calc_load_ratio() {
    local load1="$1" vcpus="$2"
    if ! monitor_is_number "$load1" || ! monitor_is_number "$vcpus" || [ "$vcpus" = "0" ]; then
        echo ""
        return 1
    fi
    awk -v l="$load1" -v c="$vcpus" 'BEGIN{printf "%.2f", l/c}'
}

collect_load() {
    LOAD_1="" LOAD_5="" LOAD_15="" LOAD_RATIO="" LOAD_SEVERITY="UNKNOWN"

    local loadavg="$MONITOR_PROC_DIR/loadavg"
    if [ ! -r "$loadavg" ]; then
        log_debug "Não foi possível ler $loadavg"
        return 1
    fi

    read -r LOAD_1 LOAD_5 LOAD_15 _ < "$loadavg" 2>/dev/null

    if ! monitor_is_number "$LOAD_1"; then
        LOAD_1="" LOAD_5="" LOAD_15=""
        return 1
    fi

    LOAD_RATIO=$(monitor_calc_load_ratio "$LOAD_1" "$HOST_VCPUS")
    LOAD_SEVERITY=$(monitor_classify_high "$LOAD_RATIO" \
        "$MONITOR_LOAD_RATIO_WARNING" \
        "$MONITOR_LOAD_RATIO_CRITICAL" \
        "$MONITOR_LOAD_RATIO_EMERGENCY")

    return 0
}

################################################################################
# Memória e Swap (/proc/meminfo)
################################################################################

# Extrai campos de um arquivo no formato de /proc/meminfo (função pura, testável)
# Saída: linhas chave=valor_kb (mem_total, mem_available, swap_total, swap_free)
monitor_parse_meminfo() {
    local file="$1"
    [ -r "$file" ] || return 1

    awk '
        /^MemTotal:/     {print "mem_total=" $2}
        /^MemAvailable:/ {print "mem_available=" $2; avail=1}
        /^MemFree:/      {free=$2}
        /^Buffers:/      {buffers=$2}
        /^Cached:/       {cached=$2}
        /^SwapTotal:/    {print "swap_total=" $2}
        /^SwapFree:/     {print "swap_free=" $2}
        END {
            # Kernels antigos sem MemAvailable: aproxima com free+buffers+cached
            if (!avail && free != "") print "mem_available=" free+buffers+cached
        }
    ' "$file" 2>/dev/null
}

collect_memory() {
    MEM_TOTAL_MB="" MEM_AVAILABLE_MB="" MEM_USED_MB=""
    MEM_USED_PERCENT="" MEM_AVAILABLE_PERCENT="" MEM_SEVERITY="UNKNOWN"

    local parsed
    parsed=$(monitor_parse_meminfo "$MONITOR_PROC_DIR/meminfo") || {
        log_debug "Não foi possível ler $MONITOR_PROC_DIR/meminfo"
        return 1
    }

    local mem_total_kb mem_available_kb
    mem_total_kb=$(echo "$parsed" | awk -F= '$1=="mem_total"{print $2}')
    mem_available_kb=$(echo "$parsed" | awk -F= '$1=="mem_available"{print $2}')

    if ! monitor_is_number "$mem_total_kb" || ! monitor_is_number "$mem_available_kb" || \
        [ "$mem_total_kb" -eq 0 ]; then
        return 1
    fi

    MEM_TOTAL_MB=$((mem_total_kb / 1024))
    MEM_AVAILABLE_MB=$((mem_available_kb / 1024))
    MEM_USED_MB=$((MEM_TOTAL_MB - MEM_AVAILABLE_MB))
    MEM_AVAILABLE_PERCENT=$(awk -v a="$mem_available_kb" -v t="$mem_total_kb" \
        'BEGIN{printf "%.1f", a*100/t}')
    MEM_USED_PERCENT=$(awk -v p="$MEM_AVAILABLE_PERCENT" 'BEGIN{printf "%.1f", 100-p}')

    # Classificação por MB disponível (menor = pior)
    MEM_SEVERITY=$(monitor_classify_low "$MEM_AVAILABLE_MB" \
        "$MONITOR_MEM_AVAILABLE_WARNING_MB" \
        "$MONITOR_MEM_AVAILABLE_CRITICAL_MB")

    # Classificação opcional por percentual disponível (0 = desabilitado)
    local sev_percent
    sev_percent=$(monitor_classify_low "$MEM_AVAILABLE_PERCENT" \
        "$MONITOR_MEM_AVAILABLE_WARNING_PERCENT" \
        "$MONITOR_MEM_AVAILABLE_CRITICAL_PERCENT")
    if [ "$sev_percent" != "UNKNOWN" ]; then
        MEM_SEVERITY=$(monitor_severity_max "$MEM_SEVERITY" "$sev_percent")
    fi

    return 0
}

# Classifica swap com contexto. Percentual ocupado é retenção histórica; só
# promovemos para CRITICAL/EMERGENCY quando há evidência de pressão ativa.
monitor_swap_classify_context() {
    local used="$1" growth="$2" activity_pages="$3" mem_severity="$4"
    local warn="$5" crit="$6" emerg="$7"
    local growth_warn="${8:-${MONITOR_SWAP_GROWTH_WARNING_MB:-64}}"
    local activity_warn="${9:-${MONITOR_SWAP_ACTIVITY_WARNING_PAGES:-256}}"

    local raw active=false
    raw=$(monitor_classify_high "$used" "$warn" "$crit" "$emerg")
    case "$raw" in UNKNOWN|INFO) echo "$raw"; return 0 ;; esac

    if [ "$(monitor_severity_rank "$mem_severity")" -ge "$(monitor_severity_rank WARNING)" ]; then
        active=true
    fi
    if monitor_is_number "$growth" && monitor_is_number "$growth_warn" && \
       awk -v a="$growth" -v b="$growth_warn" 'BEGIN{exit !(a>=b)}'; then
        active=true
    fi
    if monitor_is_number "$activity_pages" && monitor_is_number "$activity_warn" && \
       awk -v a="$activity_pages" -v b="$activity_warn" 'BEGIN{exit !(a>=b)}'; then
        active=true
    fi

    case "$raw" in
        EMERGENCY)
            if [ "$active" = true ] && \
               [ "$(monitor_severity_rank "$mem_severity")" -ge "$(monitor_severity_rank CRITICAL)" ]; then
                echo EMERGENCY
            elif [ "$active" = true ]; then
                echo CRITICAL
            else
                echo WARNING
            fi
            ;;
        CRITICAL)
            [ "$active" = true ] && echo CRITICAL || echo WARNING
            ;;
        *) echo WARNING ;;
    esac
}

monitor_vmstat_counter() {
    local key="$1" file="${2:-$MONITOR_PROC_DIR/vmstat}"
    awk -v k="$key" '$1==k {print $2; found=1; exit} END{if(!found) exit 1}' \
        "$file" 2>/dev/null
}

collect_swap() {
    SWAP_TOTAL_MB="" SWAP_USED_MB="" SWAP_USED_PERCENT=""
    SWAP_GROWTH_MB="n/d" SWAP_PSWPIN_DELTA="n/d" SWAP_PSWPOUT_DELTA="n/d"
    SWAP_ACTIVITY_PAGES_DELTA="n/d" SWAP_ACTIVE_PRESSURE=false
    SWAP_SEVERITY="UNKNOWN" SWAP_ENABLED=true

    local parsed
    parsed=$(monitor_parse_meminfo "$MONITOR_PROC_DIR/meminfo") || return 1

    local swap_total_kb swap_free_kb
    swap_total_kb=$(echo "$parsed" | awk -F= '$1=="swap_total"{print $2}')
    swap_free_kb=$(echo "$parsed" | awk -F= '$1=="swap_free"{print $2}')

    if ! monitor_is_number "$swap_total_kb" || ! monitor_is_number "$swap_free_kb"; then
        return 1
    fi

    SWAP_TOTAL_MB=$((swap_total_kb / 1024))
    local swap_used_kb=$((swap_total_kb - swap_free_kb))
    SWAP_USED_MB=$((swap_used_kb / 1024))

    if [ "$swap_total_kb" -eq 0 ]; then
        # Host sem swap configurada: não é erro, apenas registra
        SWAP_ENABLED=false
        SWAP_USED_PERCENT="0.0"
        SWAP_PSWPIN_DELTA=0 SWAP_PSWPOUT_DELTA=0 SWAP_ACTIVITY_PAGES_DELTA=0
        SWAP_SEVERITY="INFO"
        monitor_state_set "swap_used_kb" "0"
        return 0
    fi

    SWAP_USED_PERCENT=$(awk -v u="$swap_used_kb" -v t="$swap_total_kb" \
        'BEGIN{printf "%.1f", u*100/t}')

    # Crescimento desde a última execução (base para histórico do M7)
    local prev_used_kb
    prev_used_kb=$(monitor_state_get "swap_used_kb")
    if monitor_is_number "$prev_used_kb"; then
        SWAP_GROWTH_MB=$(( (swap_used_kb - prev_used_kb) / 1024 ))
    fi
    monitor_state_set "swap_used_kb" "$swap_used_kb"

    # Atividade real de swap desde a coleta anterior (/proc/vmstat). Na
    # primeira leitura os deltas permanecem n/d para não inventar pressão.
    local pswpin pswpout prev_in prev_out
    pswpin=$(monitor_vmstat_counter pswpin 2>/dev/null || true)
    pswpout=$(monitor_vmstat_counter pswpout 2>/dev/null || true)
    prev_in=$(monitor_state_get "swap_pswpin")
    prev_out=$(monitor_state_get "swap_pswpout")
    if monitor_is_number "$pswpin" && monitor_is_number "$pswpout"; then
        if monitor_is_number "$prev_in" && monitor_is_number "$prev_out" && \
           [ "$pswpin" -ge "$prev_in" ] && [ "$pswpout" -ge "$prev_out" ]; then
            SWAP_PSWPIN_DELTA=$((pswpin - prev_in))
            SWAP_PSWPOUT_DELTA=$((pswpout - prev_out))
            SWAP_ACTIVITY_PAGES_DELTA=$((SWAP_PSWPIN_DELTA + SWAP_PSWPOUT_DELTA))
        fi
        monitor_state_set "swap_pswpin" "$pswpin"
        monitor_state_set "swap_pswpout" "$pswpout"
    fi

    local growth_warn="${MONITOR_SWAP_GROWTH_WARNING_MB:-64}"
    local activity_warn="${MONITOR_SWAP_ACTIVITY_WARNING_PAGES:-256}"
    if [ "$(monitor_severity_rank "${MEM_SEVERITY:-UNKNOWN}")" -ge "$(monitor_severity_rank WARNING)" ]; then
        SWAP_ACTIVE_PRESSURE=true
    elif monitor_is_number "$SWAP_GROWTH_MB" && \
         awk -v a="$SWAP_GROWTH_MB" -v b="$growth_warn" 'BEGIN{exit !(a>=b)}'; then
        SWAP_ACTIVE_PRESSURE=true
    elif monitor_is_number "$SWAP_ACTIVITY_PAGES_DELTA" && \
         awk -v a="$SWAP_ACTIVITY_PAGES_DELTA" -v b="$activity_warn" 'BEGIN{exit !(a>=b)}'; then
        SWAP_ACTIVE_PRESSURE=true
    fi

    SWAP_SEVERITY=$(monitor_swap_classify_context "$SWAP_USED_PERCENT" \
        "$SWAP_GROWTH_MB" "$SWAP_ACTIVITY_PAGES_DELTA" "${MEM_SEVERITY:-UNKNOWN}" \
        "$MONITOR_SWAP_WARNING_PERCENT" \
        "$MONITOR_SWAP_CRITICAL_PERCENT" \
        "$MONITOR_SWAP_EMERGENCY_PERCENT" "$growth_warn" "$activity_warn")

    return 0
}

################################################################################
# CPU (/proc/stat, delta entre duas leituras)
################################################################################

# Lê a linha agregada "cpu " de um arquivo no formato de /proc/stat
monitor_cpu_read_sample() {
    local file="${1:-$MONITOR_PROC_DIR/stat}"
    grep '^cpu ' "$file" 2>/dev/null | head -n1
}

# Calcula percentuais de CPU a partir de duas amostras (função pura, testável).
# Campos de /proc/stat: cpu user nice system idle iowait irq softirq steal ...
# Saída: linhas chave=valor (cpu_usage, cpu_user, cpu_system, cpu_idle,
#        cpu_iowait, cpu_steal), ou retorno 1 se o delta for inválido.
monitor_cpu_calc_delta() {
    local prev="$1" curr="$2"

    awk -v prev="$prev" -v curr="$curr" '
        BEGIN {
            np = split(prev, p, /[ \t]+/)
            nc = split(curr, c, /[ \t]+/)
            if (np < 9 || nc < 9 || p[1] != "cpu" || c[1] != "cpu") exit 1

            # Índices: 2=user 3=nice 4=system 5=idle 6=iowait 7=irq 8=softirq 9=steal
            for (i = 2; i <= 9; i++) {
                d[i] = c[i] - p[i]
                total += d[i]
            }
            if (total <= 0) exit 1

            # "system"/"index" são reservados no awk; usar nomes curtos
            usr = (d[2] + d[3]) * 100 / total
            sys = (d[4] + d[7] + d[8]) * 100 / total
            idl = d[5] * 100 / total
            iow = d[6] * 100 / total
            stl = d[9] * 100 / total
            usage = 100 - idl - iow

            printf "cpu_usage=%.1f\n", usage
            printf "cpu_user=%.1f\n", usr
            printf "cpu_system=%.1f\n", sys
            printf "cpu_idle=%.1f\n", idl
            printf "cpu_iowait=%.1f\n", iow
            printf "cpu_steal=%.1f\n", stl
        }
    '
}

collect_cpu() {
    CPU_USAGE_PERCENT="" CPU_USER_PERCENT="" CPU_SYSTEM_PERCENT=""
    CPU_IDLE_PERCENT="" CPU_IOWAIT_PERCENT="" CPU_STEAL_PERCENT=""
    CPU_SEVERITY="UNKNOWN" CPU_STEAL_SEVERITY="UNKNOWN" CPU_IOWAIT_SEVERITY="UNKNOWN"

    local sample1 sample2
    sample1=$(monitor_cpu_read_sample)
    if [ -z "$sample1" ]; then
        log_debug "Não foi possível ler $MONITOR_PROC_DIR/stat"
        return 1
    fi

    # Segunda leitura após pequeno intervalo para calcular o delta
    if [ "$MONITOR_CPU_SAMPLE_INTERVAL" != "0" ]; then
        sleep "$MONITOR_CPU_SAMPLE_INTERVAL" 2>/dev/null || true
    fi
    sample2=$(monitor_cpu_read_sample)

    local deltas
    deltas=$(monitor_cpu_calc_delta "$sample1" "$sample2") || {
        log_debug "Delta de CPU inválido (amostras idênticas ou malformadas)"
        return 1
    }

    CPU_USAGE_PERCENT=$(echo "$deltas" | awk -F= '$1=="cpu_usage"{print $2}')
    CPU_USER_PERCENT=$(echo "$deltas" | awk -F= '$1=="cpu_user"{print $2}')
    CPU_SYSTEM_PERCENT=$(echo "$deltas" | awk -F= '$1=="cpu_system"{print $2}')
    CPU_IDLE_PERCENT=$(echo "$deltas" | awk -F= '$1=="cpu_idle"{print $2}')
    CPU_IOWAIT_PERCENT=$(echo "$deltas" | awk -F= '$1=="cpu_iowait"{print $2}')
    CPU_STEAL_PERCENT=$(echo "$deltas" | awk -F= '$1=="cpu_steal"{print $2}')

    CPU_SEVERITY=$(monitor_classify_high "$CPU_USAGE_PERCENT" \
        "$MONITOR_CPU_WARNING_PERCENT" "$MONITOR_CPU_CRITICAL_PERCENT")
    CPU_STEAL_SEVERITY=$(monitor_classify_high "$CPU_STEAL_PERCENT" \
        "$MONITOR_STEAL_WARNING_PERCENT" \
        "$MONITOR_STEAL_CRITICAL_PERCENT" \
        "$MONITOR_STEAL_EMERGENCY_PERCENT")
    CPU_IOWAIT_SEVERITY=$(monitor_classify_high "$CPU_IOWAIT_PERCENT" \
        "$MONITOR_IOWAIT_WARNING_PERCENT" "$MONITOR_IOWAIT_CRITICAL_PERCENT")

    return 0
}

################################################################################
# Cgroup (quota de CPU e throttling — v1 e v2)
################################################################################

# Interpreta cgroup v2 a partir de um diretório (função pura, testável).
# Lê cpu.max ("max <period>" ou "<quota> <period>") e cpu.stat.
# Saída: linhas chave=valor (quota_status, quota_percent, nr_periods,
#        nr_throttled, throttled_usec)
monitor_cgroup_parse_v2() {
    local dir="$1"

    if [ -r "$dir/cpu.max" ]; then
        local quota period
        read -r quota period < "$dir/cpu.max" 2>/dev/null
        if [ "$quota" = "max" ]; then
            echo "quota_status=sem_quota"
        elif monitor_is_number "$quota" && monitor_is_number "$period" && [ "$period" != "0" ]; then
            echo "quota_status=quota_configurada"
            awk -v q="$quota" -v p="$period" 'BEGIN{printf "quota_percent=%.1f\n", q*100/p}'
        else
            echo "quota_status=indeterminado"
        fi
    else
        # Raiz do cgroup v2 não expõe cpu.max: sem quota detectável neste nível
        echo "quota_status=sem_quota_detectavel"
    fi

    if [ -r "$dir/cpu.stat" ]; then
        awk '
            $1=="nr_periods"     {print "nr_periods=" $2}
            $1=="nr_throttled"   {print "nr_throttled=" $2}
            $1=="throttled_usec" {print "throttled_usec=" $2}
        ' "$dir/cpu.stat" 2>/dev/null
    fi
}

# Interpreta cgroup v1 a partir do diretório do controller cpu (função pura).
# Lê cpu.cfs_quota_us / cpu.cfs_period_us e cpu.stat (throttled_time em ns).
monitor_cgroup_parse_v1() {
    local dir="$1"

    if [ -r "$dir/cpu.cfs_quota_us" ]; then
        local quota period
        quota=$(cat "$dir/cpu.cfs_quota_us" 2>/dev/null)
        period=$(cat "$dir/cpu.cfs_period_us" 2>/dev/null)
        if [ "$quota" = "-1" ]; then
            echo "quota_status=sem_quota"
        elif monitor_is_number "$quota" && monitor_is_number "$period" && [ "$period" != "0" ]; then
            echo "quota_status=quota_configurada"
            awk -v q="$quota" -v p="$period" 'BEGIN{printf "quota_percent=%.1f\n", q*100/p}'
        else
            echo "quota_status=indeterminado"
        fi
    else
        echo "quota_status=sem_quota_detectavel"
    fi

    if [ -r "$dir/cpu.stat" ]; then
        awk '
            $1=="nr_periods"     {print "nr_periods=" $2}
            $1=="nr_throttled"   {print "nr_throttled=" $2}
            $1=="throttled_time" {print "throttled_usec=" int($2/1000)}
        ' "$dir/cpu.stat" 2>/dev/null
    fi
}

collect_cgroup() {
    CGROUP_VERSION="indeterminado"
    CGROUP_QUOTA_STATUS="indeterminado"
    CGROUP_QUOTA_PERCENT=""
    CGROUP_NR_PERIODS="" CGROUP_NR_THROTTLED="" CGROUP_THROTTLED_USEC=""
    CGROUP_THROTTLED_DELTA="n/d"
    CGROUP_THROTTLING_STATUS="indeterminado"
    CGROUP_SEVERITY="UNKNOWN"

    local base="$MONITOR_SYS_CGROUP_DIR"
    local parsed=""

    if [ -f "$base/cgroup.controllers" ]; then
        CGROUP_VERSION="v2"
        parsed=$(monitor_cgroup_parse_v2 "$base")
    elif [ -d "$base/cpu" ]; then
        CGROUP_VERSION="v1"
        parsed=$(monitor_cgroup_parse_v1 "$base/cpu")
    else
        # Ambiente sem cgroup acessível: registra e segue sem falhar
        CGROUP_THROTTLING_STATUS="indeterminado"
        return 0
    fi

    CGROUP_QUOTA_STATUS=$(echo "$parsed" | awk -F= '$1=="quota_status"{print $2}')
    CGROUP_QUOTA_STATUS="${CGROUP_QUOTA_STATUS:-indeterminado}"
    CGROUP_QUOTA_PERCENT=$(echo "$parsed" | awk -F= '$1=="quota_percent"{print $2}')
    CGROUP_NR_PERIODS=$(echo "$parsed" | awk -F= '$1=="nr_periods"{print $2}')
    CGROUP_NR_THROTTLED=$(echo "$parsed" | awk -F= '$1=="nr_throttled"{print $2}')
    CGROUP_THROTTLED_USEC=$(echo "$parsed" | awk -F= '$1=="throttled_usec"{print $2}')

    if monitor_is_number "$CGROUP_NR_THROTTLED"; then
        # Delta de throttling desde a última execução
        local prev_throttled
        prev_throttled=$(monitor_state_get "cgroup_nr_throttled")
        if monitor_is_number "$prev_throttled" && [ "$CGROUP_NR_THROTTLED" -ge "$prev_throttled" ]; then
            CGROUP_THROTTLED_DELTA=$((CGROUP_NR_THROTTLED - prev_throttled))
        fi
        monitor_state_set "cgroup_nr_throttled" "$CGROUP_NR_THROTTLED"

        if [ "$CGROUP_THROTTLED_DELTA" != "n/d" ] && [ "$CGROUP_THROTTLED_DELTA" -gt 0 ]; then
            CGROUP_THROTTLING_STATUS="throttling_detectado"
            CGROUP_SEVERITY="WARNING"
        elif [ "$CGROUP_NR_THROTTLED" -gt 0 ] && [ "$CGROUP_THROTTLED_DELTA" = "n/d" ]; then
            # Primeira execução com contador acumulado > 0: houve throttling no passado
            CGROUP_THROTTLING_STATUS="throttling_historico"
            CGROUP_SEVERITY="INFO"
        else
            CGROUP_THROTTLING_STATUS="sem_throttling"
            CGROUP_SEVERITY="INFO"
        fi
    else
        # Sem cpu.stat legível: só informa o status da quota
        case "$CGROUP_QUOTA_STATUS" in
            sem_quota|sem_quota_detectavel)
                CGROUP_THROTTLING_STATUS="sem_quota"
                CGROUP_SEVERITY="INFO"
                ;;
            *)
                CGROUP_THROTTLING_STATUS="indeterminado"
                CGROUP_SEVERITY="UNKNOWN"
                ;;
        esac
    fi

    return 0
}

################################################################################
# Top processos por CPU e memória
################################################################################

# Coleta os N maiores consumidores (formato: pid|%cpu|%mem|etime|comando)
# Uso interno: monitor_top_processes <campo_de_ordenacao> [quantidade]
monitor_top_processes() {
    local sort_field="$1" count="${2:-10}"
    run_with_timeout "$MONITOR_COMMAND_TIMEOUT" \
        ps -eo pid,pcpu,pmem,etime,comm --sort="-$sort_field" --no-headers 2>/dev/null | \
        head -n "$count" | \
        awk '{printf "%s|%s|%s|%s|%s\n", $1, $2, $3, $4, $5}'
}

collect_processes() {
    TOP_CPU_PROCESSES=""
    TOP_MEM_PROCESSES=""

    TOP_CPU_PROCESSES=$(monitor_top_processes pcpu 10)
    TOP_MEM_PROCESSES=$(monitor_top_processes pmem 10)

    [ -n "$TOP_CPU_PROCESSES" ] || return 1
    return 0
}

################################################################################
# Disco e inodes (partição raiz)
################################################################################

collect_disk() {
    DISK_PATH="$MONITOR_DISK_PATH"
    DISK_TOTAL_MB="" DISK_AVAILABLE_MB="" DISK_USED_PERCENT=""
    INODE_USED_PERCENT=""
    DISK_SEVERITY="UNKNOWN" INODE_SEVERITY="UNKNOWN"

    # df com timeout: pode travar com NFS/filesystem problemático
    local df_out
    df_out=$(run_with_timeout "$MONITOR_COMMAND_TIMEOUT" df -Pk "$DISK_PATH" 2>/dev/null | awk 'NR==2')
    if [ -n "$df_out" ]; then
        DISK_TOTAL_MB=$(echo "$df_out" | awk '{print int($2/1024)}')
        DISK_AVAILABLE_MB=$(echo "$df_out" | awk '{print int($4/1024)}')
        DISK_USED_PERCENT=$(echo "$df_out" | awk '{gsub(/%/,"",$5); print $5}')
        monitor_is_number "$DISK_USED_PERCENT" || DISK_USED_PERCENT=""
    fi

    local dfi_out
    dfi_out=$(run_with_timeout "$MONITOR_COMMAND_TIMEOUT" df -Pi "$DISK_PATH" 2>/dev/null | awk 'NR==2')
    if [ -n "$dfi_out" ]; then
        INODE_USED_PERCENT=$(echo "$dfi_out" | awk '{gsub(/%/,"",$5); print $5}')
        # Alguns filesystems reportam "-" para inodes
        monitor_is_number "$INODE_USED_PERCENT" || INODE_USED_PERCENT=""
    fi

    DISK_SEVERITY=$(monitor_classify_high "$DISK_USED_PERCENT" \
        "$MONITOR_DISK_WARNING_PERCENT" "$MONITOR_DISK_CRITICAL_PERCENT")
    INODE_SEVERITY=$(monitor_classify_high "$INODE_USED_PERCENT" \
        "$MONITOR_INODE_WARNING_PERCENT" "$MONITOR_INODE_CRITICAL_PERCENT")

    [ -n "$DISK_USED_PERCENT" ] || return 1
    return 0
}

################################################################################
# Export das funções
################################################################################

export -f collect_host_info
export -f monitor_calc_load_ratio collect_load
export -f monitor_parse_meminfo collect_memory collect_swap
export -f monitor_swap_classify_context monitor_vmstat_counter
export -f monitor_cpu_read_sample monitor_cpu_calc_delta collect_cpu
export -f monitor_cgroup_parse_v1 monitor_cgroup_parse_v2 collect_cgroup
export -f monitor_top_processes collect_processes
export -f collect_disk

# Marca que monitor-collectors.sh foi carregado
MONITOR_COLLECTORS_LOADED=1
export MONITOR_COLLECTORS_LOADED
