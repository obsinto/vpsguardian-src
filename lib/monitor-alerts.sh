#!/bin/bash
################################################################################
# Script: monitor-alerts.sh
# Propósito: Motor de alertas / incidentes (M5) do Monitor Preventivo
# Uso: source /opt/vpsguardian/lib/monitor-alerts.sh
#      (requer monitor-common.sh carregado antes)
#
# Arquitetura:
#   condição detectada
#       -> máquina de estados (OPEN/ESCALATE/REMINDER/RECOVER/SUPPRESS/NONE)
#       -> decisão de notificar (cooldown, dedup por severidade, N consecutivas)
#       -> formatador de incidente
#       -> adaptador (monitor_alert_channel_send)
#       -> notify_monitor_incident() em lib/notificacoes.sh
#       -> webhook Discord JÁ configurado (WEBHOOK_URL)
#
# O motor NÃO conhece URL, curl, headers, timeout de rede ou autenticação:
# essas responsabilidades permanecem em lib/notificacoes.sh. Aqui só existe a
# decisão de "o que" e "quando" notificar. Nenhuma credencial é lida ou impressa.
#
# Estado normalizado do canal: SUCCESS | FAILED | DISABLED. last_notified só é
# atualizado em SUCCESS. Falha do Discord não interrompe o monitor, não descarta
# o incidente, não gera falsa recuperação e não vaza a URL.
#
# Referência: docs/MARCOS-MONITOR-PREVENTIVO.md (M5)
# Versão: 1.0.0
################################################################################

# Carrega o transporte existente (Discord) se ainda não estiver disponível.
# Não-fatal: sem a lib, o canal simplesmente reporta DISABLED.
if ! declare -F notify_monitor_incident >/dev/null 2>&1; then
    for _notif in "$MONITOR_LIB_DIR/notificacoes.sh" "/opt/vpsguardian/lib/notificacoes.sh"; do
        if [ -f "$_notif" ]; then
            source "$_notif"
            break
        fi
    done
    unset _notif
fi

# Estado do incidente persistido entre execuções (carregado de disco)
declare -A ST_STATUS ST_FIRST ST_LASTSEV ST_WORST ST_NOTIFIED ST_COUNT ST_STREAK ST_COND
declare -A ST_RECOVERY_STREAK
declare -A ST_NOTIFIEDSEV

# Incidentes correntes (registrados a cada ciclo)
declare -A INC_SEV INC_COND INC_VALUE
# Todas as medições observadas, inclusive INFO/UNKNOWN. Isso permite que a
# recuperação informe o valor atual que normalizou um incidente.
declare -A OBS_SEV OBS_COND OBS_VALUE OBS_RECOVERY_READY
INC_KEYS=()

################################################################################
# Adaptador de canal (única ponte com lib/notificacoes.sh)
################################################################################

# Mapeia severidade -> tipo de cor do Discord (reutiliza a convenção da lib)
monitor_alert_sev_type() {
    case "$1" in
        RECOVERY) echo "success" ;;
        WARNING)  echo "warning" ;;
        CRITICAL|EMERGENCY) echo "error" ;;
        *)        echo "info" ;;
    esac
}

# Envia por todos os canais configurados e devolve estado normalizado.
# Uso: monitor_alert_channel_send <type> <title> <description> [fields...]
# Echo: SUCCESS | FAILED | DISABLED
#
# Regras:
#   - dry-run nunca envia (retorna DISABLED);
#   - flag MONITOR_ALERT_DISCORD_ENABLED controla o uso do canal existente;
#   - delega o transporte para notify_monitor_incident (nenhum curl aqui).
monitor_alert_channel_send() {
    local type="$1" title="$2" description="$3"
    shift 3

    if [ "${MONITOR_ALERT_DRY_RUN:-false}" = "true" ]; then
        echo "DISABLED"; return 0
    fi
    if [ "${MONITOR_ALERT_DISCORD_ENABLED:-true}" != "true" ]; then
        echo "DISABLED"; return 0
    fi
    if ! declare -F notify_monitor_incident >/dev/null 2>&1; then
        echo "DISABLED"; return 0
    fi

    notify_monitor_incident "$type" "$title" "$description" "$@"
    case $? in
        0) echo "SUCCESS" ;;
        2) echo "DISABLED" ;;
        *) echo "FAILED" ;;
    esac
}

################################################################################
# Máquina de estados (função pura, testável)
################################################################################

# Decide a ação para um incidente a partir do estado anterior e do atual.
# Uso: monitor_incident_decide <prev_status> <prev_sev> <prev_last_notified> \
#                              <now_epoch> <cur_sev> <cooldown_s> <reminders>
# Echo: OPEN | ESCALATE | REMINDER | SUPPRESS | RECOVER | NONE
monitor_incident_decide() {
    local pstatus="$1" psev="$2" pnotified="$3" now="$4" csev="$5"
    local cooldown="$6" reminders="$7"

    local present=false
    case "$csev" in WARNING|CRITICAL|EMERGENCY) present=true ;; esac

    if [ "$present" != true ]; then
        # Condição normalizou/sumiu
        if [ "$pstatus" = "open" ]; then echo "RECOVER"; else echo "NONE"; fi
        return 0
    fi

    # Condição presente
    if [ "$pstatus" != "open" ]; then echo "OPEN"; return 0; fi

    # Já estava aberto
    # Ainda não notificado com sucesso (ex.: falha anterior) => tentar a
    # abertura novamente antes de avaliar qualquer escalada.
    if ! [[ "$pnotified" =~ ^[0-9]+$ ]] || [ "$pnotified" -eq 0 ]; then
        echo "OPEN"; return 0
    fi

    local cr pr
    cr=$(monitor_severity_rank "$csev")
    pr=$(monitor_severity_rank "$psev")
    if [ "$cr" -gt "$pr" ]; then echo "ESCALATE"; return 0; fi

    # Mesma (ou menor) severidade, já notificado: lembrete só após cooldown
    if [ "$reminders" = "true" ] && [ $((now - pnotified)) -ge "$cooldown" ]; then
        echo "REMINDER"; return 0
    fi
    echo "SUPPRESS"
}

################################################################################
# Registro de incidentes correntes
################################################################################

monitor_alerts_reset_current() {
    INC_SEV=(); INC_COND=(); INC_VALUE=(); INC_KEYS=()
    OBS_SEV=(); OBS_COND=(); OBS_VALUE=(); OBS_RECOVERY_READY=()
}

# Registra uma condição corrente. Filtra INFO/UNKNOWN e o que estiver abaixo da
# severidade mínima configurada. Sanitiza chave/condição/valor.
# O quinto argumento opcional indica se a medição já cruzou o limite de
# recuperação. O motor usa essa informação somente para incidentes abertos.
# Uso: monitor_alert_register <key> <severity> <condition> <value> [recovery_ready]
monitor_alert_register() {
    local key="$1" sev="$2" cond="$3" value="$4" recovery_ready="${5:-true}"

    key=$(printf '%s' "$key" | tr -d '|' | tr ' ' '_')
    cond=$(printf '%s' "$cond" | tr -d '"|' | tr '\n\r\t' '   ')
    value=$(printf '%s' "$value" | tr -d '"|' | tr '\n\r\t' '   ')

    OBS_SEV[$key]="$sev"
    OBS_COND[$key]="$cond"
    OBS_VALUE[$key]="$value"
    OBS_RECOVERY_READY[$key]="$recovery_ready"

    local min_rank sev_rank
    min_rank=$(monitor_severity_rank "${MONITOR_ALERT_MIN_SEVERITY:-WARNING}")
    sev_rank=$(monitor_severity_rank "$sev")
    [ "$sev_rank" -lt 1 ] && return 0            # INFO(0) e UNKNOWN(-1) nunca abrem
    [ "$sev_rank" -ge "$min_rank" ] || return 0

    if [ -z "${INC_SEV[$key]:-}" ]; then INC_KEYS+=("$key"); fi
    INC_SEV[$key]="$sev"
    INC_COND[$key]="$cond"
    INC_VALUE[$key]="$value"
}

# Registra uma métrica onde valores maiores são piores e calcula a zona de
# histerese. Acima (ou igual) ao recovery_threshold, um incidente já aberto é
# mantido mesmo que a severidade corrente tenha caído para INFO.
# Uso: monitor_alert_register_high <key> <severity> <condition> <display_value> \
#                                  <raw_value> <recovery_threshold>
monitor_alert_register_high() {
    local key="$1" sev="$2" cond="$3" display_value="$4"
    local raw_value="$5" recovery_threshold="$6" recovery_ready=false

    if monitor_is_number "$raw_value" && monitor_is_number "$recovery_threshold" && \
       awk -v v="$raw_value" -v t="$recovery_threshold" 'BEGIN { exit !(v < t) }'; then
        recovery_ready=true
    fi
    monitor_alert_register "$key" "$sev" "$cond" "$display_value" "$recovery_ready"
}

################################################################################
# Persistência do estado de incidentes (mesmo padrão atômico do M0)
################################################################################

monitor_alerts_load_state() {
    ST_STATUS=(); ST_FIRST=(); ST_LASTSEV=(); ST_WORST=()
    ST_NOTIFIED=(); ST_COUNT=(); ST_STREAK=(); ST_COND=(); ST_RECOVERY_STREAK=()
    ST_NOTIFIEDSEV=()

    local f="${MONITOR_INCIDENT_STATE_FILE:-$MONITOR_STATE_DIR/incidents.state}"
    [ -f "$f" ] || return 0

    local key status first lastsev worst notified count streak cond recovery_streak notified_sev
    while IFS='|' read -r key status first lastsev worst notified count streak cond recovery_streak notified_sev; do
        [ -n "$key" ] || continue
        ST_STATUS[$key]="$status"; ST_FIRST[$key]="$first"; ST_LASTSEV[$key]="$lastsev"
        ST_WORST[$key]="$worst"; ST_NOTIFIED[$key]="$notified"; ST_COUNT[$key]="$count"
        ST_STREAK[$key]="$streak"; ST_COND[$key]="$cond"
        ST_RECOVERY_STREAK[$key]="${recovery_streak:-0}"
        case "$notified_sev" in
            WARNING|CRITICAL|EMERGENCY) ST_NOTIFIEDSEV[$key]="$notified_sev" ;;
            *)
                # Migração transparente do formato anterior (10 campos).
                # Um incidente com last_notified já havia comunicado seu pico.
                if [[ "$notified" =~ ^[0-9]+$ ]] && [ "$notified" -gt 0 ]; then
                    ST_NOTIFIEDSEV[$key]="${worst:-INFO}"
                else
                    ST_NOTIFIEDSEV[$key]="INFO"
                fi
                ;;
        esac
    done < "$f"
}

################################################################################
# Formatação e despacho de uma mensagem de incidente
################################################################################

_alert_clean() {
    printf '%s' "$1" | tr -d '"\\' | tr '\n\r\t' '   '
}

# Valores podem conter o separador JSON `\n` usado pelo transporte do Discord.
# Preserva somente essa sequência e remove outras barras/aspas, evitando tanto o
# `minutosnPior` quanto escapes arbitrários no payload montado pelo canal legado.
_alert_value_clean() {
    local value="$1" marker=$'\034'
    value="${value//\\n/$marker}"
    value="${value//\\/}"
    value=$(printf '%s' "$value" | tr -d '"' | tr '\n\r\t' '   ')
    value="${value//$marker/\\n}"
    printf '%s' "$value"
}

# Monta título/descrição conforme a ação e envia pelo adaptador.
# Uso: monitor_alert_dispatch <decision> <sev> <srv> <cond> <value> <prevsev> <worst>
# Echo: resultado do canal (SUCCESS|FAILED|DISABLED)
monitor_alert_dispatch() {
    local decision="$1" sev="$2" srv="$3" cond="$4" value="$5" prevsev="$6" worst="$7"
    srv=$(_alert_clean "$srv"); cond=$(_alert_clean "$cond"); value=$(_alert_value_clean "$value")

    local title type description
    case "$decision" in
        OPEN)
            title="🚨 VPS Guardian — Incidente detectado"
            type=$(monitor_alert_sev_type "$sev")
            description="Servidor: $srv\nSeveridade: $sev\nCondição: $cond"
            [ -n "$value" ] && description="$description\n$value"
            ;;
        ESCALATE)
            title="🆘 VPS Guardian — Incidente escalou"
            type=$(monitor_alert_sev_type "$sev")
            description="Servidor: $srv\nIncidente: $cond\nSeveridade anterior: $prevsev\nSeveridade atual: $sev"
            [ -n "$value" ] && description="$description\n$value"
            ;;
        REMINDER)
            title="🔁 VPS Guardian — Incidente em curso"
            type=$(monitor_alert_sev_type "$sev")
            description="Servidor: $srv\nIncidente: $cond\nSeveridade: $sev"
            [ -n "$value" ] && description="$description\n$value"
            ;;
        RECOVER)
            title="✅ VPS Guardian — Serviço normalizado"
            type="success"
            description="Servidor: $srv\nIncidente: $cond\n$value"
            ;;
        *)
            echo "NONE"; return 0
            ;;
    esac

    monitor_alert_channel_send "$type" "$title" "$description"
}

# Envia todas as transições de um ciclo em uma única mensagem. O estado continua
# individual por chave; o agrupamento existe apenas no transporte para evitar uma
# rajada de dezenas de webhooks na primeira coleta ou após perda de estado.
monitor_alert_batch_dispatch() {
    local srv="$1"
    local total="${#ALERT_BATCH_DECISION[@]}"
    [ "$total" -gt 0 ] || { echo "NONE"; return 0; }

    # Mantém o texto tradicional quando há uma única transição.
    if [ "$total" -eq 1 ]; then
        monitor_alert_dispatch "${ALERT_BATCH_DECISION[0]}" "${ALERT_BATCH_SEV[0]}" \
            "$srv" "${ALERT_BATCH_COND[0]}" "${ALERT_BATCH_VALUE[0]}" \
            "${ALERT_BATCH_PREV[0]}" "${ALERT_BATCH_WORST[0]}"
        return
    fi

    local opened=0 escalated=0 reminded=0 recovered=0 worst="INFO" i
    for ((i=0; i<total; i++)); do
        case "${ALERT_BATCH_DECISION[$i]}" in
            OPEN) ((opened++)) ;;
            ESCALATE) ((escalated++)) ;;
            REMINDER) ((reminded++)) ;;
            RECOVER) ((recovered++)) ;;
        esac
        if [ "${ALERT_BATCH_DECISION[$i]}" != "RECOVER" ]; then
            worst=$(monitor_severity_max "$worst" "${ALERT_BATCH_SEV[$i]}")
        fi
    done

    local type title description
    if [ "$opened" -eq 0 ] && [ "$escalated" -eq 0 ] && [ "$reminded" -eq 0 ]; then
        type="success"
        title="✅ VPS Guardian — Serviços normalizados"
    else
        type=$(monitor_alert_sev_type "$worst")
        title="🚨 VPS Guardian — Resumo do monitor"
    fi

    srv=$(_alert_clean "$srv")
    description="Servidor: $srv\nTransições: ${opened} nova(s), ${escalated} escalada(s), ${reminded} lembrete(s), ${recovered} normalizada(s)"

    local max_items="${MONITOR_ALERT_BATCH_MAX_ITEMS:-10}"
    [[ "$max_items" =~ ^[0-9]+$ ]] || max_items=10
    [ "$max_items" -gt 0 ] || max_items=10
    local shown=0 label sev cond value entry
    local description_budget=3850
    for ((i=0; i<total && shown<max_items; i++)); do
        case "${ALERT_BATCH_DECISION[$i]}" in
            OPEN) label="NOVA" ;;
            ESCALATE) label="ESCALOU" ;;
            REMINDER) label="EM CURSO" ;;
            RECOVER) label="NORMALIZOU" ;;
            *) label="EVENTO" ;;
        esac
        sev="${ALERT_BATCH_SEV[$i]}"
        [ "${ALERT_BATCH_DECISION[$i]}" = "RECOVER" ] && sev="${ALERT_BATCH_WORST[$i]}"
        cond=$(_alert_clean "${ALERT_BATCH_COND[$i]}")
        value=$(_alert_value_clean "${ALERT_BATCH_VALUE[$i]}")
        # Blocos legíveis, preservando o contexto mais importante. O limite é
        # aplicado ao embed inteiro, em vez de truncar cada diagnóstico cedo.
        cond="${cond:0:220}"
        value="${value:0:500}"
        entry="\n\n• **$label · $sev**\n  $cond"
        [ -n "$value" ] && entry="$entry\n  $value"
        [ $(( ${#description} + ${#entry} )) -gt "$description_budget" ] && break
        description="${description}${entry}"
        ((shown++))
    done
    [ "$total" -gt "$shown" ] && description="$description\n• … e $((total-shown)) outra(s) transição(ões) registradas no estado local"

    monitor_alert_channel_send "$type" "$title" "$description"
}

################################################################################
# Processamento: compara estado anterior x atual, despacha e persiste
################################################################################

monitor_alerts_process() {
    ALERTS_OPENED=0 ALERTS_ESCALATED=0 ALERTS_REMINDED=0 ALERTS_RECOVERED=0
    ALERTS_SUPPRESSED=0 ALERTS_FAILED=0 ALERTS_PENDING=0
    ALERTS_RECOVERY_PENDING=0 ALERTS_CHANNEL="none"
    ALERTS_DRY_RUN="${MONITOR_ALERT_DRY_RUN:-false}"
    ALERTS_STATE_PERSISTED=false
    ALERTS_NOTIFICATIONS_SENT=false
    ALERTS_DRYRUN_REPORT=()
    ALERT_BATCH_DECISION=(); ALERT_BATCH_KEY=(); ALERT_BATCH_SEV=()
    ALERT_BATCH_COND=(); ALERT_BATCH_VALUE=(); ALERT_BATCH_PREV=(); ALERT_BATCH_WORST=()

    if [ "${MONITOR_ALERTS_ENABLED:-true}" != "true" ]; then
        ALERTS_CHANNEL="engine_disabled"
        return 0
    fi

    # DRY-RUN: o estado real é lido apenas para simulação e NUNCA é gravado; o
    # webhook não é chamado. As transições ficam nas arrays locais (descartadas).
    local dry_run="$ALERTS_DRY_RUN"

    local now cooldown consecutive recovery_consecutive reminders srv
    now=$(date +%s)
    cooldown=$(( ${MONITOR_ALERT_COOLDOWN_MINUTES:-15} * 60 ))
    consecutive="${MONITOR_ALERT_CONSECUTIVE:-2}"
    recovery_consecutive="${MONITOR_ALERT_RECOVERY_CONSECUTIVE:-3}"
    [[ "$consecutive" =~ ^[1-9][0-9]*$ ]] || consecutive=2
    [[ "$recovery_consecutive" =~ ^[1-9][0-9]*$ ]] || recovery_consecutive=3
    reminders="${MONITOR_ALERT_REMINDERS_ENABLED:-false}"
    srv="${MONITOR_SERVER_NAME:-${HOST_HOSTNAME:-$(hostname 2>/dev/null)}}"

    local dr_note="seria enviada pelo Discord"
    [ "${MONITOR_ALERT_DISCORD_ENABLED:-true}" = "true" ] || dr_note="canal Discord desabilitado"

    # Estado novo, apenas em memória (persistido ao final somente fora do dry-run)
    local -A N_STATUS N_FIRST N_LASTSEV N_WORST N_NOTIFIED N_COUNT N_STREAK N_COND
    local -A N_RECOVERY_STREAK
    local -A N_NOTIFIEDSEV
    local -A seen
    local key

    # ---- Incidentes correntes ----
    for key in "${INC_KEYS[@]}"; do
        seen[$key]=1
        local csev="${INC_SEV[$key]}" cond="${INC_COND[$key]}" value="${INC_VALUE[$key]}"
        local pstatus="${ST_STATUS[$key]:-}" psev="${ST_LASTSEV[$key]:-}"
        local pnotified="${ST_NOTIFIED[$key]:-0}" pfirst="${ST_FIRST[$key]:-$now}"
        local pworst="${ST_WORST[$key]:-INFO}" pcount="${ST_COUNT[$key]:-0}" pstreak="${ST_STREAK[$key]:-0}"
        local pnotifiedsev="${ST_NOTIFIEDSEV[$key]:-INFO}"
        local nstreak=$(( pstreak + 1 )) required_streak="$consecutive"
        # Emergências normalmente não aguardam confirmação adicional. CPU
        # steal é a exceção: picos isolados do hypervisor são comuns e não
        # representam degradação sustentada, então respeitam o mesmo
        # anti-flapping configurado para WARNING/CRITICAL.
        if [ "$csev" = "EMERGENCY" ] && [ "$key" != "host:steal" ]; then
            required_streak=1
        fi
        local worst; worst=$(monitor_severity_max "$pworst" "$csev")

        # Exigência de N verificações consecutivas antes de abrir (anti-flapping)
        if [ "$pstatus" != "open" ] && [ "$nstreak" -lt "$required_streak" ]; then
            N_STATUS[$key]="pending"; N_FIRST[$key]="$pfirst"; N_LASTSEV[$key]="$csev"
            N_WORST[$key]="$worst"; N_NOTIFIED[$key]="0"; N_COUNT[$key]="$pcount"
            N_STREAK[$key]="$nstreak"; N_COND[$key]="$cond"; N_RECOVERY_STREAK[$key]=0
            N_NOTIFIEDSEV[$key]="$pnotifiedsev"
            ((ALERTS_PENDING++))
            [ "$dry_run" = "true" ] && ALERTS_DRYRUN_REPORT+=("WOULD_KEEP_PENDING|$key|$csev|ocorrências simuladas: ${nstreak}/${required_streak}")
            continue
        fi

        local decision
        # Compara contra o pico já notificado, não contra a leitura anterior.
        # Sem isso, EMERGENCY -> WARNING -> CRITICAL notificaria uma falsa
        # "escalada", embora CRITICAL não ultrapasse o nível já comunicado.
        decision=$(monitor_incident_decide "$pstatus" "$pnotifiedsev" "$pnotified" "$now" \
            "$csev" "$cooldown" "$reminders")

        local nnotified="$pnotified" ncount="$pcount"
        case "$decision" in
            OPEN|ESCALATE|REMINDER)
                if [ "$dry_run" = "true" ]; then
                    # Simulação: registra a transição, NÃO envia e NÃO altera contadores
                    case "$decision" in
                        OPEN)     ALERTS_DRYRUN_REPORT+=("WOULD_OPEN|$key|$csev|ocorrências simuladas: ${nstreak} | notificação: ${dr_note}") ;;
                        ESCALATE) ALERTS_DRYRUN_REPORT+=("WOULD_ESCALATE|$key|$csev|de ${psev} para ${csev} | notificação: ${dr_note}") ;;
                        REMINDER) ALERTS_DRYRUN_REPORT+=("WOULD_REMIND|$key|$csev|lembrete | notificação: ${dr_note}") ;;
                    esac
                else
                    ALERT_BATCH_DECISION+=("$decision"); ALERT_BATCH_KEY+=("$key")
                    ALERT_BATCH_SEV+=("$csev"); ALERT_BATCH_COND+=("$cond")
                    ALERT_BATCH_VALUE+=("$value"); ALERT_BATCH_PREV+=("$psev")
                    ALERT_BATCH_WORST+=("$worst")
                fi
                ;;
            SUPPRESS)
                [ "$dry_run" = "true" ] && ALERTS_DRYRUN_REPORT+=("WOULD_SUPPRESS|$key|$csev|dentro do cooldown")
                ;;
        esac

        case "$decision" in
            OPEN)     ((ALERTS_OPENED++)) ;;
            ESCALATE) ((ALERTS_ESCALATED++)) ;;
            REMINDER) ((ALERTS_REMINDED++)) ;;
            SUPPRESS) ((ALERTS_SUPPRESSED++)) ;;
        esac

        N_STATUS[$key]="open"; N_FIRST[$key]="$pfirst"; N_LASTSEV[$key]="$csev"
        N_WORST[$key]="$worst"; N_NOTIFIED[$key]="$nnotified"; N_COUNT[$key]="$ncount"
        N_STREAK[$key]="$nstreak"; N_COND[$key]="$cond"; N_RECOVERY_STREAK[$key]=0
        N_NOTIFIEDSEV[$key]="$pnotifiedsev"
    done

    # ---- Incidentes anteriores ausentes agora: recuperação ou descarte ----
    for key in "${!ST_STATUS[@]}"; do
        [ -n "${seen[$key]:-}" ] && continue

        if [ "${ST_STATUS[$key]}" = "open" ]; then
            local dur=$(( (now - ${ST_FIRST[$key]:-$now}) / 60 ))
            local rworst="${ST_WORST[$key]:-INFO}" rcond="${ST_COND[$key]:-incidente}"
            local current_value="${OBS_VALUE[$key]:-}"

            # Uma métrica observada precisa cruzar o limite de recuperação
            # (histerese) e permanecer saudável por N ciclos. UNKNOWN nunca é
            # saúde. Chaves ausentes do inventário (ex.: processo removido)
            # continuam recuperando imediatamente.
            if [ -n "${OBS_SEV[$key]+x}" ]; then
                local observed_sev="${OBS_SEV[$key]}"
                local recovery_ready="${OBS_RECOVERY_READY[$key]:-true}"
                local recovery_streak="${ST_RECOVERY_STREAK[$key]:-0}"
                [[ "$recovery_streak" =~ ^[0-9]+$ ]] || recovery_streak=0

                if [ "$observed_sev" = "UNKNOWN" ] || [ "$recovery_ready" != "true" ]; then
                    recovery_streak=0
                else
                    recovery_streak=$((recovery_streak + 1))
                fi

                if [ "$recovery_streak" -lt "$recovery_consecutive" ]; then
                    N_STATUS[$key]="${ST_STATUS[$key]}"
                    N_FIRST[$key]="${ST_FIRST[$key]}"
                    N_LASTSEV[$key]="${ST_LASTSEV[$key]}"
                    N_WORST[$key]="${ST_WORST[$key]}"
                    N_NOTIFIED[$key]="${ST_NOTIFIED[$key]}"
                    N_COUNT[$key]="${ST_COUNT[$key]}"
                    N_STREAK[$key]="${ST_STREAK[$key]}"
                    N_COND[$key]="${ST_COND[$key]}"
                    N_RECOVERY_STREAK[$key]="$recovery_streak"
                    N_NOTIFIEDSEV[$key]="${ST_NOTIFIEDSEV[$key]:-INFO}"
                    ((ALERTS_RECOVERY_PENDING++))
                    continue
                fi
            fi

            if [ "$dry_run" = "true" ]; then
                ((ALERTS_RECOVERED++))
                ALERTS_DRYRUN_REPORT+=("WOULD_RECOVER|$key|$rworst|duração ${dur}min | notificação: ${dr_note}")
                continue
            fi

            local rvalue=""
            [ -n "$current_value" ] && rvalue="Medição atual: ${current_value}\n"
            rvalue="${rvalue}Duração: ${dur} minutos\nPior severidade: ${rworst}"
            ALERT_BATCH_DECISION+=("RECOVER"); ALERT_BATCH_KEY+=("$key")
            ALERT_BATCH_SEV+=("RECOVERY"); ALERT_BATCH_COND+=("$rcond")
            ALERT_BATCH_VALUE+=("$rvalue"); ALERT_BATCH_PREV+=("")
            ALERT_BATCH_WORST+=("$rworst")
        fi
        # status "pending" ausente agora: descartado (reset do streak)
    done

    # Um único webhook por ciclo. O resultado é aplicado a todas as transições
    # incluídas no lote, preservando retry e recovery por chave.
    if [ "$dry_run" != "true" ] && [ "${#ALERT_BATCH_DECISION[@]}" -gt 0 ]; then
        local batch_result batch_i batch_key batch_decision
        batch_result=$(monitor_alert_batch_dispatch "$srv")
        ALERTS_CHANNEL="$batch_result"
        [ "$batch_result" = "SUCCESS" ] && ALERTS_NOTIFICATIONS_SENT=true

        for ((batch_i=0; batch_i<${#ALERT_BATCH_DECISION[@]}; batch_i++)); do
            batch_key="${ALERT_BATCH_KEY[$batch_i]}"
            batch_decision="${ALERT_BATCH_DECISION[$batch_i]}"
            if [ "$batch_decision" = "RECOVER" ]; then
                if [ "$batch_result" = "FAILED" ]; then
                    # Falha no resumo: mantém aberto para retentar a recuperação.
                    N_STATUS[$batch_key]="${ST_STATUS[$batch_key]}"
                    N_FIRST[$batch_key]="${ST_FIRST[$batch_key]}"
                    N_LASTSEV[$batch_key]="${ST_LASTSEV[$batch_key]}"
                    N_WORST[$batch_key]="${ST_WORST[$batch_key]}"
                    N_NOTIFIED[$batch_key]="${ST_NOTIFIED[$batch_key]}"
                    N_COUNT[$batch_key]="${ST_COUNT[$batch_key]}"
                    N_STREAK[$batch_key]="${ST_STREAK[$batch_key]}"
                    N_COND[$batch_key]="${ST_COND[$batch_key]}"
                    N_RECOVERY_STREAK[$batch_key]="${ST_RECOVERY_STREAK[$batch_key]:-0}"
                    N_NOTIFIEDSEV[$batch_key]="${ST_NOTIFIEDSEV[$batch_key]:-INFO}"
                else
                    # SUCCESS ou DISABLED: incidente encerrado.
                    ((ALERTS_RECOVERED++))
                fi
            elif [ "$batch_result" = "SUCCESS" ]; then
                N_NOTIFIED[$batch_key]="$now"
                N_COUNT[$batch_key]=$(( ${ST_COUNT[$batch_key]:-0} + 1 ))
                N_NOTIFIEDSEV[$batch_key]=$(monitor_severity_max \
                    "${N_NOTIFIEDSEV[$batch_key]:-INFO}" "${ALERT_BATCH_SEV[$batch_i]}")
            fi
        done
        if [ "$batch_result" = "FAILED" ]; then
            ALERTS_FAILED=$((ALERTS_FAILED + ${#ALERT_BATCH_DECISION[@]}))
        fi
    fi

    # ---- Persistência: nunca grava em dry-run ----
    if [ "$dry_run" = "true" ]; then
        ALERTS_STATE_PERSISTED=false
    else
        if monitor_alerts_save_state N_STATUS N_FIRST N_LASTSEV N_WORST \
            N_NOTIFIED N_COUNT N_STREAK N_COND N_RECOVERY_STREAK N_NOTIFIEDSEV; then
            ALERTS_STATE_PERSISTED=true
        fi
    fi
    return 0
}

# Grava o estado a partir das arrays nomeadas (via nameref)
monitor_alerts_save_state() {
    local -n _status="$1" _first="$2" _lastsev="$3" _worst="$4"
    local -n _notified="$5" _count="$6" _streak="$7" _cond="$8"
    local -n _recovery_streak="$9"
    local -n _notified_sev="${10}"

    local f="${MONITOR_INCIDENT_STATE_FILE:-$MONITOR_STATE_DIR/incidents.state}"
    local tmp="$f.tmp.$$"
    local key
    : > "$tmp" 2>/dev/null || { log_debug "Sem permissão para gravar estado de incidentes"; return 1; }
    for key in "${!_status[@]}"; do
        printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
            "$key" "${_status[$key]}" "${_first[$key]}" "${_lastsev[$key]}" \
            "${_worst[$key]}" "${_notified[$key]}" "${_count[$key]}" \
            "${_streak[$key]}" "${_cond[$key]}" \
            "${_recovery_streak[$key]:-0}" "${_notified_sev[$key]:-INFO}" >> "$tmp"
    done
    mv -f "$tmp" "$f" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
}

################################################################################
# Teste manual de alerta (subcomando test-alert)
################################################################################

monitor_alert_test() {
    local description="Este é um teste do motor preventivo.\nNenhum incidente real foi criado."
    monitor_alert_channel_send "info" "🧪 VPS Guardian — Teste de alerta" "$description"
}

################################################################################
# Export das funções
################################################################################

export -f monitor_alert_sev_type monitor_alert_channel_send
export -f monitor_incident_decide
export -f monitor_alerts_reset_current monitor_alert_register monitor_alert_register_high
export -f monitor_alerts_load_state monitor_alerts_save_state monitor_alerts_process
export -f monitor_alert_dispatch monitor_alert_batch_dispatch monitor_alert_test

MONITOR_ALERTS_LOADED=1
export MONITOR_ALERTS_LOADED
