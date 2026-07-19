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

# Incidentes correntes (registrados a cada ciclo)
declare -A INC_SEV INC_COND INC_VALUE
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
    local cr pr
    cr=$(monitor_severity_rank "$csev")
    pr=$(monitor_severity_rank "$psev")
    if [ "$cr" -gt "$pr" ]; then echo "ESCALATE"; return 0; fi

    # Ainda não notificado com sucesso (ex.: falha anterior) => tentar novamente
    if ! [[ "$pnotified" =~ ^[0-9]+$ ]] || [ "$pnotified" -eq 0 ]; then
        echo "OPEN"; return 0
    fi

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
}

# Registra uma condição corrente. Filtra INFO/UNKNOWN e o que estiver abaixo da
# severidade mínima configurada. Sanitiza chave/condição/valor.
# Uso: monitor_alert_register <key> <severity> <condition> <value>
monitor_alert_register() {
    local key="$1" sev="$2" cond="$3" value="$4"

    local min_rank sev_rank
    min_rank=$(monitor_severity_rank "${MONITOR_ALERT_MIN_SEVERITY:-WARNING}")
    sev_rank=$(monitor_severity_rank "$sev")
    [ "$sev_rank" -lt 1 ] && return 0            # INFO(0) e UNKNOWN(-1) nunca abrem
    [ "$sev_rank" -ge "$min_rank" ] || return 0

    key=$(printf '%s' "$key" | tr -d '|' | tr ' ' '_')
    cond=$(printf '%s' "$cond" | tr -d '"|' | tr '\n\r\t' '   ')
    value=$(printf '%s' "$value" | tr -d '"|' | tr '\n\r\t' '   ')

    if [ -z "${INC_SEV[$key]:-}" ]; then INC_KEYS+=("$key"); fi
    INC_SEV[$key]="$sev"
    INC_COND[$key]="$cond"
    INC_VALUE[$key]="$value"
}

################################################################################
# Persistência do estado de incidentes (mesmo padrão atômico do M0)
################################################################################

monitor_alerts_load_state() {
    ST_STATUS=(); ST_FIRST=(); ST_LASTSEV=(); ST_WORST=()
    ST_NOTIFIED=(); ST_COUNT=(); ST_STREAK=(); ST_COND=()

    local f="${MONITOR_INCIDENT_STATE_FILE:-$MONITOR_STATE_DIR/incidents.state}"
    [ -f "$f" ] || return 0

    local key status first lastsev worst notified count streak cond
    while IFS='|' read -r key status first lastsev worst notified count streak cond; do
        [ -n "$key" ] || continue
        ST_STATUS[$key]="$status"; ST_FIRST[$key]="$first"; ST_LASTSEV[$key]="$lastsev"
        ST_WORST[$key]="$worst"; ST_NOTIFIED[$key]="$notified"; ST_COUNT[$key]="$count"
        ST_STREAK[$key]="$streak"; ST_COND[$key]="$cond"
    done < "$f"
}

################################################################################
# Formatação e despacho de uma mensagem de incidente
################################################################################

_alert_clean() {
    printf '%s' "$1" | tr -d '"\\' | tr '\n\r\t' '   '
}

# Monta título/descrição conforme a ação e envia pelo adaptador.
# Uso: monitor_alert_dispatch <decision> <sev> <srv> <cond> <value> <prevsev> <worst>
# Echo: resultado do canal (SUCCESS|FAILED|DISABLED)
monitor_alert_dispatch() {
    local decision="$1" sev="$2" srv="$3" cond="$4" value="$5" prevsev="$6" worst="$7"
    srv=$(_alert_clean "$srv"); cond=$(_alert_clean "$cond")

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

################################################################################
# Processamento: compara estado anterior x atual, despacha e persiste
################################################################################

monitor_alerts_process() {
    ALERTS_OPENED=0 ALERTS_ESCALATED=0 ALERTS_REMINDED=0 ALERTS_RECOVERED=0
    ALERTS_SUPPRESSED=0 ALERTS_FAILED=0 ALERTS_PENDING=0 ALERTS_CHANNEL="none"
    ALERTS_DRY_RUN="${MONITOR_ALERT_DRY_RUN:-false}"
    ALERTS_STATE_PERSISTED=false
    ALERTS_NOTIFICATIONS_SENT=false
    ALERTS_DRYRUN_REPORT=()

    if [ "${MONITOR_ALERTS_ENABLED:-true}" != "true" ]; then
        ALERTS_CHANNEL="engine_disabled"
        return 0
    fi

    # DRY-RUN: o estado real é lido apenas para simulação e NUNCA é gravado; o
    # webhook não é chamado. As transições ficam nas arrays locais (descartadas).
    local dry_run="$ALERTS_DRY_RUN"

    local now cooldown consecutive reminders srv
    now=$(date +%s)
    cooldown=$(( ${MONITOR_ALERT_COOLDOWN_MINUTES:-15} * 60 ))
    consecutive="${MONITOR_ALERT_CONSECUTIVE:-1}"
    reminders="${MONITOR_ALERT_REMINDERS_ENABLED:-false}"
    srv="${MONITOR_SERVER_NAME:-${HOST_HOSTNAME:-$(hostname 2>/dev/null)}}"

    local dr_note="seria enviada pelo Discord"
    [ "${MONITOR_ALERT_DISCORD_ENABLED:-true}" = "true" ] || dr_note="canal Discord desabilitado"

    # Estado novo, apenas em memória (persistido ao final somente fora do dry-run)
    local -A N_STATUS N_FIRST N_LASTSEV N_WORST N_NOTIFIED N_COUNT N_STREAK N_COND
    local -A seen
    local key

    # ---- Incidentes correntes ----
    for key in "${INC_KEYS[@]}"; do
        seen[$key]=1
        local csev="${INC_SEV[$key]}" cond="${INC_COND[$key]}" value="${INC_VALUE[$key]}"
        local pstatus="${ST_STATUS[$key]:-}" psev="${ST_LASTSEV[$key]:-}"
        local pnotified="${ST_NOTIFIED[$key]:-0}" pfirst="${ST_FIRST[$key]:-$now}"
        local pworst="${ST_WORST[$key]:-INFO}" pcount="${ST_COUNT[$key]:-0}" pstreak="${ST_STREAK[$key]:-0}"
        local nstreak=$(( pstreak + 1 ))
        local worst; worst=$(monitor_severity_max "$pworst" "$csev")

        # Exigência de N verificações consecutivas antes de abrir (anti-flapping)
        if [ "$pstatus" != "open" ] && [ "$nstreak" -lt "$consecutive" ]; then
            N_STATUS[$key]="pending"; N_FIRST[$key]="$pfirst"; N_LASTSEV[$key]="$csev"
            N_WORST[$key]="$worst"; N_NOTIFIED[$key]="0"; N_COUNT[$key]="$pcount"
            N_STREAK[$key]="$nstreak"; N_COND[$key]="$cond"
            ((ALERTS_PENDING++))
            [ "$dry_run" = "true" ] && ALERTS_DRYRUN_REPORT+=("WOULD_KEEP_PENDING|$key|$csev|ocorrências simuladas: ${nstreak}/${consecutive}")
            continue
        fi

        local decision
        decision=$(monitor_incident_decide "$pstatus" "$psev" "$pnotified" "$now" \
            "$csev" "$cooldown" "$reminders")

        local result="" nnotified="$pnotified" ncount="$pcount"
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
                    result=$(monitor_alert_dispatch "$decision" "$csev" "$srv" "$cond" \
                        "$value" "$psev" "$worst")
                    ALERTS_CHANNEL="$result"
                    if [ "$result" = "SUCCESS" ]; then
                        nnotified="$now"; ncount=$((pcount + 1)); ALERTS_NOTIFICATIONS_SENT=true
                    elif [ "$result" = "FAILED" ]; then
                        ((ALERTS_FAILED++))
                    fi
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
        N_STREAK[$key]="$nstreak"; N_COND[$key]="$cond"
    done

    # ---- Incidentes anteriores ausentes agora: recuperação ou descarte ----
    for key in "${!ST_STATUS[@]}"; do
        [ -n "${seen[$key]:-}" ] && continue

        if [ "${ST_STATUS[$key]}" = "open" ]; then
            local dur=$(( (now - ${ST_FIRST[$key]:-$now}) / 60 ))
            local rworst="${ST_WORST[$key]:-INFO}" rcond="${ST_COND[$key]:-incidente}"

            if [ "$dry_run" = "true" ]; then
                ((ALERTS_RECOVERED++))
                ALERTS_DRYRUN_REPORT+=("WOULD_RECOVER|$key|$rworst|duração ${dur}min | notificação: ${dr_note}")
                continue
            fi

            local rvalue="Duração: ${dur} minutos\nPior severidade: ${rworst}"
            local result
            result=$(monitor_alert_dispatch RECOVER RECOVERY "$srv" "$rcond" "$rvalue" "" "$rworst")
            ALERTS_CHANNEL="$result"

            if [ "$result" = "FAILED" ]; then
                # Não normalizou de fato: mantém aberto para retentar recuperação
                ((ALERTS_FAILED++))
                N_STATUS[$key]="${ST_STATUS[$key]}"; N_FIRST[$key]="${ST_FIRST[$key]}"
                N_LASTSEV[$key]="${ST_LASTSEV[$key]}"; N_WORST[$key]="${ST_WORST[$key]}"
                N_NOTIFIED[$key]="${ST_NOTIFIED[$key]}"; N_COUNT[$key]="${ST_COUNT[$key]}"
                N_STREAK[$key]="${ST_STREAK[$key]}"; N_COND[$key]="${ST_COND[$key]}"
            else
                # SUCCESS ou DISABLED: incidente encerrado (removido do estado)
                ((ALERTS_RECOVERED++))
                [ "$result" = "SUCCESS" ] && ALERTS_NOTIFICATIONS_SENT=true
            fi
        fi
        # status "pending" ausente agora: descartado (reset do streak)
    done

    # ---- Persistência: nunca grava em dry-run ----
    if [ "$dry_run" = "true" ]; then
        ALERTS_STATE_PERSISTED=false
    else
        if monitor_alerts_save_state N_STATUS N_FIRST N_LASTSEV N_WORST \
            N_NOTIFIED N_COUNT N_STREAK N_COND; then
            ALERTS_STATE_PERSISTED=true
        fi
    fi
    return 0
}

# Grava o estado a partir das arrays nomeadas (via nameref)
monitor_alerts_save_state() {
    local -n _status="$1" _first="$2" _lastsev="$3" _worst="$4"
    local -n _notified="$5" _count="$6" _streak="$7" _cond="$8"

    local f="${MONITOR_INCIDENT_STATE_FILE:-$MONITOR_STATE_DIR/incidents.state}"
    local tmp="$f.tmp.$$"
    local key
    : > "$tmp" 2>/dev/null || { log_debug "Sem permissão para gravar estado de incidentes"; return 1; }
    for key in "${!_status[@]}"; do
        printf '%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
            "$key" "${_status[$key]}" "${_first[$key]}" "${_lastsev[$key]}" \
            "${_worst[$key]}" "${_notified[$key]}" "${_count[$key]}" \
            "${_streak[$key]}" "${_cond[$key]}" >> "$tmp"
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
export -f monitor_alerts_reset_current monitor_alert_register
export -f monitor_alerts_load_state monitor_alerts_save_state monitor_alerts_process
export -f monitor_alert_dispatch monitor_alert_test

MONITOR_ALERTS_LOADED=1
export MONITOR_ALERTS_LOADED
