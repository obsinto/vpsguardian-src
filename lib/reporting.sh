#!/bin/bash
################################################################################
# VPS Guardian - helpers pequenos para relatórios de automação (JSON/JUnit)
################################################################################

vpsg_json_escape() {
    local value="${1:-}"
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//$'\n'/\\n}
    value=${value//$'\r'/\\r}
    value=${value//$'\t'/\\t}
    printf '%s' "$value"
}

vpsg_xml_escape() {
    printf '%s' "${1:-}" | sed \
        -e 's/\&/\&amp;/g' \
        -e 's/</\&lt;/g' \
        -e 's/>/\&gt;/g' \
        -e 's/"/\&quot;/g' \
        -e "s/'/\&apos;/g"
}

vpsg_prepare_report_path() {
    local report_path="$1"
    local report_dir

    [ -z "$report_path" ] && return 0
    report_dir=$(dirname "$report_path")
    mkdir -p "$report_dir" || return 1
}
