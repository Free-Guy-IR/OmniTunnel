#!/usr/bin/env bash
set -u

SCRIPT="${1:-$(dirname "$0")/../omnitunnel.sh}"
SCRIPT="$(cd "$(dirname "$SCRIPT")" && pwd)/$(basename "$SCRIPT")"

skip() { echo "SKIP: $*"; exit 0; }
fail() { echo "FAIL: $*" >&2; exit 1; }

if [[ "${OMNI_NFT_TEST_NS:-}" != 1 ]]; then
    [[ "$(id -u)" -eq 0 ]] || skip "remove_nft_cleanup_test needs root"
    for c in nft iptables ip unshare flock mount; do
        command -v "$c" >/dev/null 2>&1 || skip "remove_nft_cleanup_test needs $c"
    done
    iptables -V 2>/dev/null | grep -q nf_tables || skip "remove_nft_cleanup_test needs the iptables nf_tables backend"
    unshare -n -m true 2>/dev/null || skip "remove_nft_cleanup_test cannot create a private network+mount namespace"
    exec unshare -n -m env OMNI_NFT_TEST_NS=1 bash "$0" "$SCRIPT"
fi

[[ "$(readlink /proc/self/ns/net)" != "$(readlink /proc/1/ns/net)" ]] || fail "not inside a private network namespace"
[[ "$(readlink /proc/self/ns/mnt)" != "$(readlink /proc/1/ns/mnt)" ]] || fail "not inside a private mount namespace"
if [[ -d /etc/systemd/system ]]; then
    mount -t tmpfs omni-nft-test /etc/systemd/system || fail "cannot shadow /etc/systemd/system inside the private mount namespace"
fi

extract() {
    awk -v names="$1" '
    BEGIN { n=split(names, a, " "); for (i=1;i<=n;i++) want[a[i]]=1 }
    inblock { print; if ($0 ~ /^}/) inblock=0; next }
    {
        if (match($0, /^[A-Za-z0-9_]+\(\)[ \t]*\{/)) {
            nm=$0; sub(/\(\).*/, "", nm)
            if (nm in want) { print; if ($0 !~ /\}/) inblock=1 }
        }
    }' "$SCRIPT"
}

eval "$(extract "tok_re inst_name_ok list_instances inst_path inst_conf inst_pf inst_exists svc_name dnat_chain mux_svc mux_remove load_inst create_inst validate_inst_name type_is_hysteria pf_flush_chain inst_cleanup_residue inst_remove apply_tuning with_mangle_lock nft_mangle_state mss_clamp_rules mss_clamp_add mangle_release inst_sdev_shared inst_nft_cleanup")"

ok() { :; }
warn() { :; }
info() { :; }
die() { echo "DIE: $*" >&2; exit 1; }
need_root() { :; }
ensure_forwarding() { :; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
ROOT_DIR="$WORK/etc"; INST_DIR="$ROOT_DIR/inst"; VARLIB_DIR="$WORK/varlib"; RUN_DIR="$WORK/run"
mkdir -p "$INST_DIR" "$VARLIB_DIR"
export SYSTEMCTL_ACTIVE_DIR="$WORK/active"; mkdir -p "$SYSTEMCTL_ACTIVE_DIR"
BIN="$WORK/bin"; mkdir -p "$BIN"
cat > "$BIN/systemctl" <<'FAKE'
#!/usr/bin/env bash
if [[ "${1:-}" == is-active ]]; then
    [[ -e "${SYSTEMCTL_ACTIVE_DIR:?}/${!#}" ]] && exit 0
    exit 3
fi
exit 0
FAKE
export REAL_NFT; REAL_NFT="$(command -v nft)"
cat > "$BIN/nft" <<'FAKE'
#!/usr/bin/env bash
"$REAL_NFT" "$@"; rc=$?
if [[ -n "${NFT_GATE_DIR:-}" && "$*" == "-a list table ip mangle" ]]; then
    : > "$NFT_GATE_DIR/listed"
    for _ in $(seq 1 250); do [[ -e "$NFT_GATE_DIR/go" ]] && break; sleep 0.02; done
fi
exit "$rc"
FAKE
chmod +x "$BIN/nft"
printf '#!/bin/sh\nexit 0\n' > "$BIN/sysctl"
printf '#!/bin/sh\nexit 0\n' > "$BIN/modprobe"
chmod +x "$BIN/systemctl" "$BIN/sysctl" "$BIN/modprobe"
PATH="$BIN:$PATH"

KEY="$(printf '%064d' 7)"
PEER=10.77.0.2

ruleset() { nft list ruleset 2>/dev/null; }
has_table() { nft list table ip "$1" >/dev/null 2>&1; }
sdev_of() { local d; d="$(sed -n 's/^DEV=//p' "$(inst_conf "$1")")"; printf '%s' "${d//[^A-Za-z0-9_]/_}"; }
dev_of() { sed -n 's/^DEV=//p' "$(inst_conf "$1")"; }
clamp_present() {
    iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -o "$1" -j TCPMSS --clamp-mss-to-pmtu >/dev/null 2>&1 &&
        iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -i "$1" -j TCPMSS --clamp-mss-to-pmtu >/dev/null 2>&1
}
clamp_absent() {
    ! iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -o "$1" -j TCPMSS --clamp-mss-to-pmtu >/dev/null 2>&1 &&
        ! iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -i "$1" -j TCPMSS --clamp-mss-to-pmtu >/dev/null 2>&1
}

ackless_tables() {
    local tbl="ackless_$1" pr="49000-49099"
    nft add table ip "$tbl" &&
    nft add chain ip "$tbl" out "{" type filter hook output priority 0 ";" policy accept ";" "}" &&
    nft add rule ip "$tbl" out ip daddr "$PEER" tcp sport "$pr" tcp flags rst drop &&
    nft add rule ip "$tbl" out ip daddr "$PEER" tcp dport "$pr" tcp flags rst drop &&
    nft add chain ip "$tbl" in "{" type filter hook input priority 0 ";" policy accept ";" "}" &&
    nft add rule ip "$tbl" in ip saddr "$PEER" tcp dport "$pr" drop &&
    nft add rule ip "$tbl" in ip saddr "$PEER" tcp sport "$pr" drop
}
stripe_tables() {
    nft -f - <<EOF
table ip omnistripe_$1 {
	chain pre {
		type filter hook prerouting priority -300; policy accept;
		ip saddr $PEER tcp sport 20000-24095 notrack
		ip saddr $PEER tcp dport 20000-24095 notrack
		ip saddr $PEER tcp sport 40000-40399 notrack
		ip saddr $PEER tcp dport 40000-40399 notrack
	}
	chain out {
		type filter hook output priority -300; policy accept;
		ip daddr $PEER tcp sport 20000-24095 notrack
		ip daddr $PEER tcp dport 20000-24095 notrack
		ip daddr $PEER tcp sport 40000-40399 notrack
		ip daddr $PEER tcp dport 40000-40399 notrack
	}
}
EOF
}

bring_up() {
    local n="$1" t="$2" sub="$3" dev sdev rc
    ( set -euo pipefail; create_inst "$n" "$t" server 10.77.0.1 "$PEER" "$((49000 + sub))" "$KEY" "10.201.$sub.1" "10.201.$sub.2" ) ||
        fail "create_inst $n"
    dev="$(dev_of "$n")"; sdev="$(sdev_of "$n")"
    ip link add "$dev" type dummy 2>/dev/null || true
    ( set -euo pipefail; apply_tuning "$dev" none >/dev/null ); rc=$?
    [[ $rc -eq 0 ]] || fail "apply_tuning $dev aborted under set -euo pipefail"
    clamp_present "$dev" || fail "apply_tuning did not install the clamp rules for $dev"
    case "$t" in
        ackless) ackless_tables "$sdev" || fail "could not create ackless table for $sdev";;
        stripe) stripe_tables "$sdev" || fail "could not create stripe table for $sdev";;
    esac
}
remove() {
    local rc
    ( set -euo pipefail; inst_remove "$1" >/dev/null ); rc=$?
    [[ $rc -eq 0 ]] || fail "inst_remove $1 aborted (rc=$rc) under set -euo pipefail"
    [[ ! -e "$INST_DIR/$1" ]] || fail "inst_remove $1 did not finish (instance dir still present)"
}
reset_ns() {
    nft flush ruleset
    rm -rf "${INST_DIR:?}"/* "${RUN_DIR:?}" "${SYSTEMCTL_ACTIVE_DIR:?}"/*
    local l; for l in $(ip -o link show type dummy 2>/dev/null | awk -F': ' '{print $2}'); do ip link del "$l" 2>/dev/null || true; done
}
same_as() {
    local want="$1" got; got="$(ruleset)"
    [[ "$got" == "$want" ]] || { printf 'expected ruleset:\n%s\n--- got:\n%s\n' "$want" "$got" >&2; fail "$2"; }
}
PASS=0
pass() { PASS=$((PASS+1)); echo "ok - $1"; }

reset_ns
BASE="$(ruleset)"
[[ -z "$BASE" ]] || fail "fresh namespace is expected to have an empty ruleset"
bring_up nftA ackless 1
has_table mangle || fail "precondition: TCPMSS add should have created table ip mangle"
has_table ackless_ts_nftA || fail "precondition: ackless table missing"
remove nftA
same_as "$BASE" "ackless instance teardown left nft state behind"
[[ ! -e "$RUN_DIR/mangle.owned" ]] || fail "ownership record left after its table was deleted"
pass "ackless instance: baseline -> up -> _remove -> baseline"

reset_ns
bring_up nftS stripe 2
has_table omnistripe_ts_nftS || fail "precondition: stripe table missing"
remove nftS
same_as "$BASE" "stripe instance teardown left nft state behind"
pass "stripe instance: baseline -> up -> _remove -> baseline"

reset_ns
iptables -t mangle -A PREROUTING -p udp --dport 5353 -j MARK --set-mark 7 || fail "host rule setup"
HOSTBASE="$(ruleset)"
bring_up nftA ackless 1
grep -q '^table ' "$RUN_DIR/mangle.owned" 2>/dev/null && fail "claimed ownership of a mangle table that already existed"
grep -q '^chain [0-9]* FORWARD [0-9]*$' "$RUN_DIR/mangle.owned" || fail "the FORWARD chain OmniTunnel added to the host table was not recorded"
remove nftA
same_as "$HOSTBASE" "pre-existing mangle table with a host rule was not restored exactly"
pass "pre-existing mangle table with someone else's rule survives with its rule"

reset_ns
iptables -t mangle -A PREROUTING -p udp --dport 5353 -j MARK --set-mark 7 || fail "host rule setup"
bring_up nftA ackless 1
iptables -t mangle -A FORWARD -p udp --dport 5353 -j MARK --set-mark 8 || fail "host forward rule setup"
remove nftA
iptables -t mangle -C FORWARD -p udp --dport 5353 -j MARK --set-mark 8 >/dev/null 2>&1 || fail "a host rule in the FORWARD chain OmniTunnel created was lost"
iptables -t mangle -C PREROUTING -p udp --dport 5353 -j MARK --set-mark 7 >/dev/null 2>&1 || fail "host PREROUTING rule lost"
pass "a FORWARD chain OmniTunnel created in a host table is kept while another rule uses it"

reset_ns
nft add table ip mangle
nft add chain ip mangle FORWARD "{" type filter hook forward priority mangle ";" policy accept ";" "}"
HOSTBASE="$(ruleset)"
bring_up nftA ackless 1
[[ ! -e "$RUN_DIR/mangle.owned" ]] || fail "claimed ownership of an empty host mangle table"
remove nftA
same_as "$HOSTBASE" "an empty mangle table the host created was deleted"
pass "pre-existing empty host mangle table survives"

reset_ns
bring_up nftA ackless 1
bring_up nftB stripe 2
DEVA="$(dev_of nftA)"; DEVB="$(dev_of nftB)"
[[ -s "$RUN_DIR/mangle.owned" ]] || fail "ownership of the mangle table OmniTunnel created was not recorded"
remove nftA
clamp_absent "$DEVA" || fail "removed instance's clamp rules are still present"
clamp_present "$DEVB" || fail "removing nftA deleted nftB's clamp rules"
has_table ackless_ts_nftA && fail "removed instance's ackless table is still present"
has_table omnistripe_ts_nftB || fail "removing nftA deleted nftB's stripe table"
has_table mangle || fail "removing nftA deleted the mangle table nftB still uses"
[[ -s "$RUN_DIR/mangle.owned" ]] || fail "ownership record dropped while the table is still in use"
remove nftB
same_as "$BASE" "removing the last instance did not restore the baseline"
pass "two instances: removing one leaves the other's objects; removing both restores baseline"

reset_ns
bring_up nftA ackless 1
SAVED="$(iptables-save -t mangle)"
printf '%s\n' "$SAVED" | iptables-restore || fail "iptables-restore"
remove nftA
has_table mangle || fail "a mangle table recreated by someone else (new handle) was deleted"
[[ ! -e "$RUN_DIR/mangle.owned" ]] || fail "stale ownership record kept after the table was recreated"
pass "mangle table recreated by another writer is not ours and survives"

reset_ns
bring_up nftA ackless 1
iptables -t mangle -A PREROUTING -p udp --dport 5353 -j MARK --set-mark 9 || fail "host rule setup"
remove nftA
iptables -t mangle -C PREROUTING -p udp --dport 5353 -j MARK --set-mark 9 >/dev/null 2>&1 || fail "host rule added to the OmniTunnel-created table was lost"
[[ -s "$RUN_DIR/mangle.owned" ]] || fail "ownership record dropped while a host rule still uses the table"
iptables -t mangle -D PREROUTING -p udp --dport 5353 -j MARK --set-mark 9
bring_up nftB stripe 2
remove nftB
same_as "$BASE" "OmniTunnel-created mangle table not released once it became bare again"
pass "host rule in an OmniTunnel-created table keeps it; released once bare"

reset_ns
bring_up nft-c ackless 3
bring_up nft_c ackless 4
[[ "$(sdev_of nft-c)" == "$(sdev_of nft_c)" ]] || fail "precondition: expected colliding sanitized device names"
SD="$(sdev_of nft-c)"
remove nft-c
has_table "ackless_$SD" || fail "removing nft-c deleted a per-instance table nft_c also maps to"
remove nft_c
has_table "ackless_$SD" && fail "per-instance table left after the last instance using that name was removed"
same_as "$BASE" "colliding-name teardown did not restore the baseline"
pass "sanitized-name collision keeps the table until the last owner is removed"

reset_ns
bring_up nftA ackless 1
: > "$SYSTEMCTL_ACTIVE_DIR/omnitun-nftA.service"
remove nftA
has_table ackless_ts_nftA || fail "per-instance table deleted while the unit was still active"
pass "per-instance table is kept while the instance's unit is still active"

reset_ns
ackless_tables ts_x_y || fail "setup"
( set -euo pipefail; inst_nft_cleanup 'bad name' 'ts-x;y' ) || fail "inst_nft_cleanup aborted on an invalid name"
has_table ackless_ts_x_y || fail "nft was called with a name that fails inst_name_ok"
pass "an invalid instance name never reaches nft"

reset_ns
GATE="$WORK/gate"; mkdir -p "$GATE"
bring_up nftA ackless 1
( set -euo pipefail; create_inst nftB stripe server 10.77.0.1 "$PEER" 49002 "$KEY" 10.201.2.1 10.201.2.2 ) || fail "create_inst nftB"
DEVB="$(dev_of nftB)"; ip link add "$DEVB" type dummy 2>/dev/null || true
( export NFT_GATE_DIR="$GATE"; set -euo pipefail; inst_remove nftA >/dev/null ) & PA=$!
for _ in $(seq 1 250); do [[ -e "$GATE/listed" ]] && break; sleep 0.02; done
[[ -e "$GATE/listed" ]] || fail "interleaving: nftA's release never inspected the mangle table"
( set -euo pipefail; apply_tuning "$DEVB" none >/dev/null ) & PB=$!
for _ in $(seq 1 50); do kill -0 "$PB" 2>/dev/null || break; sleep 0.02; done
: > "$GATE/go"
wait "$PA" || fail "interleaving: inst_remove nftA aborted"
wait "$PB" || fail "interleaving: apply_tuning nftB aborted"
clamp_present "$DEVB" || fail "interleaving: nftB's clamp rules were added between nftA's bare-check and its delete, and were lost"
has_table ackless_ts_nftA && fail "interleaving: nftA's table survived its removal"
remove nftB
same_as "$BASE" "interleaving: ownership of the mangle table was lost across the race"
pass "interleaving: tuning of one instance inside another's release window keeps its rules"

ROUNDS="${OMNI_NFT_TEST_ROUNDS:-10}"

reset_ns
for r in $(seq 1 "$ROUNDS"); do
    bring_up nftA ackless 1
    bring_up nftB stripe 2
    ( set -euo pipefail; inst_remove nftA >/dev/null ) & PA=$!
    ( set -euo pipefail; inst_remove nftB >/dev/null ) & PB=$!
    wait "$PA" || fail "round $r: concurrent inst_remove nftA aborted"
    wait "$PB" || fail "round $r: concurrent inst_remove nftB aborted"
    same_as "$BASE" "round $r: two concurrent removals did not restore the baseline"
done
pass "interleaving: two concurrent _remove calls restore the baseline, $ROUNDS rounds"

echo "PASSED - $PASS remove/nft cleanup cases"
