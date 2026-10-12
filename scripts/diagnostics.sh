#!/bin/bash
set -uo pipefail
INST_DIR="${OMNITUN_INST_DIR:-/etc/omnitunnel/inst}"
RUN_DIR="${OMNITUN_RUN_DIR:-/run/omnitunnel}"

inst="${1:-}"
dev=""
if [[ -n "$inst" ]]; then
    conf="$INST_DIR/$inst/instance.conf"
    [[ -f "$conf" ]] || { echo "no such instance: $inst" >&2; exit 1; }
    DEV=""; TYPE=""
    # shellcheck disable=SC1090
    source "$conf"
    dev="$DEV"
fi

sec() { printf '\n===== %s =====\n' "$1"; }

sec "host"
uname -a
uptime 2>/dev/null || true

sec "interfaces (ip -s link)"
if [[ -n "$dev" ]]; then ip -s link show "$dev" 2>/dev/null || echo "device $dev not present"; else ip -s link 2>/dev/null || true; fi

sec "qdisc (tc)"
if [[ -n "$dev" ]]; then tc -s qdisc show dev "$dev" 2>/dev/null || echo "no qdisc for $dev"; else tc qdisc show 2>/dev/null || true; fi

sec "systemd units"
systemctl list-units 'omnitun-*' --all --no-legend 2>/dev/null || true
if [[ -n "$inst" ]]; then systemctl status "omnitun-$inst.service" --no-pager -l 2>/dev/null | head -20 || true; fi

sec "ICMP (/proc/net/snmp)"
grep -E '^Icmp' /proc/net/snmp 2>/dev/null || echo "unavailable"

sec "softnet (/proc/net/softnet_stat)"
head /proc/net/softnet_stat 2>/dev/null || echo "unavailable"

sec "sockets (ss -s)"
ss -s 2>/dev/null || echo "ss unavailable"

sec "conntrack count"
cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo "conntrack module not loaded"

sec "icmptun JSON stats"
if [[ -n "$dev" ]]; then
    j="$RUN_DIR/icmp-$dev.json"
    if [[ -f "$j" ]]; then cat "$j"; echo; else echo "not available ($j absent; icmptun JSON emission is a later core feature)"; fi
elif compgen -G "$RUN_DIR/icmp-*.json" >/dev/null 2>&1; then
    for j in "$RUN_DIR"/icmp-*.json; do echo "--- $j ---"; cat "$j"; echo; done
else
    echo "not available (no $RUN_DIR/icmp-*.json)"
fi
