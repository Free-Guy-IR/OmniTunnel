#!/bin/bash
set -uo pipefail
INST_DIR="${OMNITUN_INST_DIR:-/etc/omnitunnel/inst}"
RUN_DIR="${OMNITUN_RUN_DIR:-/run/omnitunnel}"

usage() {
    cat <<'EOF'
usage: monitor.sh stats [<instance>] [--json]
       monitor.sh monitor [<instance>] [--interval N] [--json]
read-only per-instance counters: kernel /sys/class/net stats, process RSS/CPU,
icmptun JSON when the core emits it. Nothing is mutated.
EOF
}

list_instances() {
    local d
    for d in "$INST_DIR"/*/; do
        [[ -f "${d}instance.conf" ]] || continue
        basename "$d"
    done
}

conf_val() {
    local c="$INST_DIR/$1/instance.conf" key="$2"
    [[ -f "$c" ]] || return 0
    grep -m1 -oE "^${key}=.*" "$c" 2>/dev/null | cut -d= -f2-
}

counter() { cat "/sys/class/net/$1/statistics/$2" 2>/dev/null || echo 0; }

main_pid() { systemctl show -p MainPID --value "omnitun-$1.service" 2>/dev/null || echo 0; }

rss_kb() {
    local pid="$1"
    [[ -n "$pid" && "$pid" != 0 && -r "/proc/$pid/status" ]] || { echo 0; return; }
    awk '/^VmRSS:/{print $2}' "/proc/$pid/status" 2>/dev/null || echo 0
}

cpu_ticks() {
    local pid="$1"
    [[ -n "$pid" && "$pid" != 0 && -r "/proc/$pid/stat" ]] || { echo 0; return; }
    awk '{print $14+$15}' "/proc/$pid/stat" 2>/dev/null || echo 0
}

icmp_json() {
    local dev="$1" j="$RUN_DIR/icmp-$1.json"
    [[ -f "$j" ]] && cat "$j" 2>/dev/null
}

emit_text() {
    local inst dev type pid rx tx rxp txp rxd txd
    for inst in "$@"; do
        dev="$(conf_val "$inst" DEV)"
        type="$(conf_val "$inst" TYPE)"
        pid="$(main_pid "$inst")"
        rx="$(counter "$dev" rx_bytes)"; tx="$(counter "$dev" tx_bytes)"
        rxp="$(counter "$dev" rx_packets)"; txp="$(counter "$dev" tx_packets)"
        rxd="$(counter "$dev" rx_dropped)"; txd="$(counter "$dev" tx_dropped)"
        printf '%-16s type=%-11s dev=%-12s pid=%-7s\n' "$inst" "${type:-?}" "${dev:-?}" "${pid:-none}"
        printf '    rx_bytes=%s tx_bytes=%s rx_pkts=%s tx_pkts=%s rx_drop=%s tx_drop=%s\n' "$rx" "$tx" "$rxp" "$txp" "$rxd" "$txd"
        printf '    rss_kb=%s cpu_ticks=%s\n' "$(rss_kb "$pid")" "$(cpu_ticks "$pid")"
        local jc; jc="$(icmp_json "$dev")"
        if [[ -n "$jc" ]]; then printf '    icmp_json=%s\n' "$jc"; else printf '    icmp_json=not-available\n'; fi
    done
}

json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

emit_json() {
    local inst dev type pid first=1
    printf '['
    for inst in "$@"; do
        dev="$(conf_val "$inst" DEV)"
        type="$(conf_val "$inst" TYPE)"
        pid="$(main_pid "$inst")"
        [[ "$first" == 1 ]] || printf ','
        first=0
        printf '{"instance":"%s","type":"%s","dev":"%s","pid":"%s","rx_bytes":%s,"tx_bytes":%s,"rx_packets":%s,"tx_packets":%s,"rx_dropped":%s,"tx_dropped":%s,"rss_kb":%s,"cpu_ticks":%s,"icmp_json_present":%s}' \
            "$(json_escape "$inst")" "$(json_escape "${type:-}")" "$(json_escape "${dev:-}")" "${pid:-0}" \
            "$(counter "$dev" rx_bytes)" "$(counter "$dev" tx_bytes)" \
            "$(counter "$dev" rx_packets)" "$(counter "$dev" tx_packets)" \
            "$(counter "$dev" rx_dropped)" "$(counter "$dev" tx_dropped)" \
            "$(rss_kb "$pid")" "$(cpu_ticks "$pid")" \
            "$([[ -f "$RUN_DIR/icmp-$dev.json" ]] && echo true || echo false)"
    done
    printf ']\n'
}

cmd="${1:-stats}"; shift || true
json=0; interval=2; target=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --json) json=1;;
        --interval) interval="${2:-2}"; shift;;
        -h|--help) usage; exit 0;;
        *) target="$1";;
    esac
    shift
done

targets=()
if [[ -n "$target" ]]; then
    [[ -f "$INST_DIR/$target/instance.conf" ]] || { echo "no such instance: $target" >&2; exit 1; }
    targets=("$target")
else
    mapfile -t targets < <(list_instances)
fi
[[ ${#targets[@]} -gt 0 ]] || { echo "no instances found under $INST_DIR" >&2; exit 0; }

render() { if [[ "$json" == 1 ]]; then emit_json "${targets[@]}"; else emit_text "${targets[@]}"; fi; }

case "$cmd" in
    stats) render;;
    monitor)
        while :; do
            [[ "$json" == 1 ]] || { clear 2>/dev/null || true; date; }
            render
            sleep "$interval" || break
        done
        ;;
    -h|--help) usage;;
    *) usage; exit 1;;
esac
