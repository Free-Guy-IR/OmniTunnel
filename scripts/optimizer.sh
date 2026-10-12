#!/bin/bash
set -uo pipefail
INST_DIR="${OMNITUN_INST_DIR:-/etc/omnitunnel/inst}"
RUN_DIR="${OMNITUN_RUN_DIR:-/run/omnitunnel}"
STATE_DIR="${OMNITUN_OPT_STATE:-$RUN_DIR/optimizer}"
DEV_ALLOW='^(ts-[A-Za-z0-9._-]+|ts[0-9]{8})$'
RECOMMENDED_TXQLEN="${OMNITUN_OPT_TXQLEN:-2000}"

die() { echo "optimizer: $*" >&2; exit 1; }

usage() {
    cat <<'EOF'
usage: optimizer.sh <command> [<instance>] [--acknowledge]
commands (read-only unless noted):
  status [<instance>]      host sysctl/qdisc/conntrack + per-instance device report
  analyze [<instance>]     same as status, per device
  recommend <instance>     advisory txqueuelen recommendation (no mutation)
  compare                  current vs recommended txqueuelen across instances
  dry-run <instance>       show the apply that WOULD run (no mutation)
  apply <instance> --acknowledge   set TUN txqueuelen (allowlisted device, with snapshot + auto-revert)
  rollback <instance>      restore the snapshotted txqueuelen
advisory only: no guaranteed throughput improvement; measure before and after.
EOF
}

conf_val() {
    local c="$INST_DIR/$1/instance.conf" key="$2"
    [[ -f "$c" ]] || return 0
    grep -m1 -oE "^${key}=.*" "$c" 2>/dev/null | cut -d= -f2-
}

dev_of() { conf_val "$1" DEV; }

list_instances() {
    local d
    for d in "$INST_DIR"/*/; do
        [[ -f "${d}instance.conf" ]] || continue
        basename "$d"
    done
}

dev_allowed() { [[ "$1" =~ $DEV_ALLOW ]]; }
dev_exists() { ip link show dev "$1" >/dev/null 2>&1; }
cur_txqlen() { ip -o link show dev "$1" 2>/dev/null | grep -oE 'qlen [0-9]+' | awk '{print $2}'; }
set_txqlen() { ip link set dev "$1" txqueuelen "$2"; }

sysv() { sysctl -n "$1" 2>/dev/null || echo "?"; }

report_host() {
    echo "===== host ====="
    echo "kernel: $(uname -r)"
    echo "tcp_congestion_control: $(sysv net.ipv4.tcp_congestion_control)"
    echo "default_qdisc: $(sysv net.core.default_qdisc)"
    echo "rmem_max: $(sysv net.core.rmem_max)"
    echo "wmem_max: $(sysv net.core.wmem_max)"
    echo "netdev_max_backlog: $(sysv net.core.netdev_max_backlog)"
    echo "somaxconn: $(sysv net.core.somaxconn)"
    local cc; cc=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo "?")
    local cm; cm=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo "?")
    echo "conntrack: $cc/$cm"
}

report_dev() {
    local dev="$1"
    echo "----- device $dev -----"
    if dev_exists "$dev"; then
        echo "  txqueuelen: $(cur_txqlen "$dev")"
        ip -s link show "$dev" 2>/dev/null | sed 's/^/  /'
        tc -s qdisc show dev "$dev" 2>/dev/null | sed 's/^/  /'
    else
        echo "  (device not present)"
    fi
    local j="$RUN_DIR/icmp-$dev.json"
    if [[ -f "$j" ]]; then echo "  icmptun_json:"; sed 's/^/    /' "$j"; else echo "  icmptun_json: not available"; fi
}

targets_from() {
    local t="${1:-}"
    if [[ -n "$t" ]]; then
        [[ -f "$INST_DIR/$t/instance.conf" ]] || die "no such instance: $t"
        echo "$t"
    else
        list_instances
    fi
}

cmd_status() {
    report_host
    local n
    for n in $(targets_from "${1:-}"); do
        echo "===== instance $n (type=$(conf_val "$n" TYPE)) ====="
        report_dev "$(dev_of "$n")"
    done
}

cmd_recommend() {
    local inst="$1" dev cur
    [[ -n "$inst" ]] || die "recommend needs an instance"
    dev="$(dev_of "$inst")"
    [[ -n "$dev" ]] || die "instance $inst has no DEV"
    cur="$(cur_txqlen "$dev")"
    echo "instance: $inst  dev: $dev  current_txqueuelen: ${cur:-unknown}"
    echo "advisory only: no guaranteed improvement; measure before and after."
    if ! dev_allowed "$dev"; then
        echo "recommend: $dev is not an OmniTunnel TUN device; the apply path will refuse to touch it"
        return 0
    fi
    if [[ -n "$cur" && "$cur" -lt "$RECOMMENDED_TXQLEN" ]]; then
        echo "recommend: raise txqueuelen ${cur} -> ${RECOMMENDED_TXQLEN}"
        echo "apply with: optimizer.sh apply $inst --acknowledge"
    else
        echo "recommend: no change (txqueuelen ${cur:-unknown} already >= ${RECOMMENDED_TXQLEN})"
    fi
}

cmd_compare() {
    printf '%-18s %-12s %-10s %-12s\n' "instance" "dev" "current" "recommended"
    local n dev cur
    for n in $(targets_from "${1:-}"); do
        dev="$(dev_of "$n")"
        cur="$(cur_txqlen "$dev")"
        printf '%-18s %-12s %-10s %-12s\n' "$n" "${dev:-?}" "${cur:-?}" "$RECOMMENDED_TXQLEN"
    done
}

cmd_dry_run() {
    local inst="$1" dev cur
    [[ -n "$inst" ]] || die "dry-run needs an instance"
    dev="$(dev_of "$inst")"
    [[ -n "$dev" ]] || die "instance $inst has no DEV"
    cur="$(cur_txqlen "$dev")"
    echo "DRY-RUN (no mutation):"
    echo "  device: $dev  allowlisted: $(dev_allowed "$dev" && echo yes || echo no)"
    echo "  would set txqueuelen ${cur:-unknown} -> ${RECOMMENDED_TXQLEN}"
    echo "  would snapshot to $STATE_DIR/$dev.txqlen and auto-revert on validation failure"
}

cmd_apply() {
    local inst="$1" ack="$2" dev before after snap
    [[ -n "$inst" ]] || die "apply needs an instance"
    dev="$(dev_of "$inst")"
    [[ -n "$dev" ]] || die "instance $inst has no DEV"
    dev_allowed "$dev" || die "refusing to mutate '$dev': not an OmniTunnel TUN device (allowlist ts-* / ts<8 digits>)"
    dev_exists "$dev" || die "device $dev not present"
    [[ "$ack" == 1 ]] || die "apply mutates txqueuelen on $dev; re-run with --acknowledge to proceed"
    before="$(cur_txqlen "$dev")"
    [[ -n "$before" ]] || die "cannot read current txqueuelen for $dev"
    mkdir -p "$STATE_DIR"
    snap="$STATE_DIR/$dev.txqlen"
    echo "$before" > "$snap"
    echo "snapshot: $dev txqueuelen=$before -> $snap"
    set_txqlen "$dev" "$RECOMMENDED_TXQLEN" || { rm -f "$snap"; die "failed to set txqueuelen on $dev"; }
    after="$(cur_txqlen "$dev")"
    if [[ "$after" != "$RECOMMENDED_TXQLEN" ]]; then
        echo "validation failed on $dev (got '${after:-}', wanted $RECOMMENDED_TXQLEN); reverting" >&2
        set_txqlen "$dev" "$before" 2>/dev/null || true
        rm -f "$snap"
        die "apply did not take; reverted $dev to $before"
    fi
    echo "applied: $dev txqueuelen $before -> $after  (rollback: optimizer.sh rollback $inst)"
}

cmd_rollback() {
    local inst="$1" dev snap before
    [[ -n "$inst" ]] || die "rollback needs an instance"
    dev="$(dev_of "$inst")"
    [[ -n "$dev" ]] || die "instance $inst has no DEV"
    dev_allowed "$dev" || die "refusing: $dev is not an OmniTunnel TUN device"
    snap="$STATE_DIR/$dev.txqlen"
    [[ -f "$snap" ]] || die "no snapshot for $dev ($snap); nothing to roll back"
    before="$(cat "$snap")"
    [[ "$before" =~ ^[0-9]+$ ]] || die "corrupt snapshot $snap"
    dev_exists "$dev" || die "device $dev not present"
    set_txqlen "$dev" "$before" || die "rollback failed on $dev"
    rm -f "$snap"
    echo "rolled back: $dev txqueuelen -> $before"
}

cmd="${1:-status}"; shift || true
inst=""; ack=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --acknowledge) ack=1;;
        -h|--help) usage; exit 0;;
        *) inst="$1";;
    esac
    shift
done

case "$cmd" in
    status) cmd_status "$inst";;
    analyze) cmd_status "$inst";;
    recommend) cmd_recommend "$inst";;
    compare) cmd_compare "$inst";;
    dry-run) cmd_dry_run "$inst";;
    apply) cmd_apply "$inst" "$ack";;
    rollback) cmd_rollback "$inst";;
    -h|--help) usage;;
    *) usage; exit 1;;
esac
