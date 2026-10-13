#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2317
set -u

SCRIPT="${1:-$(dirname "$0")/../omnitunnel.sh}"
ITER="${PEERCREATE_ITER:-100}"

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

eval "$(extract "tok_re lanes_ok inst_name_ok create_id_ok new_create_id inst_create_lock inst_create_unlock type_is_hysteria type_is_stripe type_is_ackless type_is_kernel type_is_revmux type_uses_key inst_path inst_conf inst_pf inst_exists list_instances create_inst cmd_peercreate cmd_remove_own provision_peer peer_inst_state peer_remove_own bench_run bench_create_id bench_reg_file bench_reg_lock bench_id_lock bench_reg_add bench_reg_del bench_abandoned_ids bench_migrate_legacy bench_peer_remove_confirm bench_clean_abandoned bench_run_done bench_peer_create bench_peer_remove bench_far_busy gen_key port_base type_port_span occupied_port_ranges alloc_port_span next_port next_subnet_idx mux_conf pick_num")"
eval "$(grep -m1 '^ALL_TYPES=' "$SCRIPT")"

DISPATCH="$(grep -E '^[[:space:]]+(_peercreate|_remove_own|_remove)\)' "$SCRIPT")"
eval "omni() {
    case \"\${1:-}\" in
$DISPATCH
        *) echo \"usage: omnitunnel.sh [menu|bench|add|list]\";;
    esac
}"

fail() { echo "FAIL: $*"; exit 1; }
need_root() { :; }
ok() { echo "OK: $*"; }
info() { echo "INFO: $*"; }
warn() { echo "WARN: $*"; }
die() { echo "DIE: $*" >&2; exit 1; }
note_ensure() { printf '%s\n' "$1" >> "$WORK/ensure_calls"; }
ensure_binary() { note_ensure binary; }
ensure_hysteria() { note_ensure hysteria; }
ensure_omnistripe() { note_ensure omnistripe; }
ensure_omniackless() { note_ensure omniackless; }
inst_enable() { :; }
validate_inst_name() {
    [[ -z "${VAL_DELAY:-}" ]] || sleep "$VAL_DELAY"
    inst_name_ok "$1" || die "bad instance name '$1'"
}
inst_remove() {
    [[ -z "${RM_DELAY:-}" ]] || sleep "$RM_DELAY"
    [[ -z "${RM_FAIL:-}" ]] || return 1
    rm -rf "${INST_DIR:?}/$1"
}
peer_scp() { :; }
hy_local_bin() { echo "$WORK/hysteria-$1"; }
omnistripe_local_bin() { echo "$WORK/omnistripe-$1"; }
omniackless_local_bin() { echo "$WORK/omniackless-$1"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
: > "$WORK/ensure_calls"
SCRIPT_PATH="$SCRIPT"
ASSET_DIR="$WORK/assets"; SCRIPT_DIR="$WORK/sd"; mkdir -p "$ASSET_DIR/bin" "$SCRIPT_DIR/bin"
: > "$ASSET_DIR/bin/omnitun-amd64"
VERSION="2.9.12"
C_BOLD=""; C_RESET=""; C_GREY=""; C_BGRN=""; C_CYAN=""; C_GREEN=""; C_DIM=""

K="$(printf 'b%.0s' {1..64})"
ID1="0123456789abcdef0123456789abcdef"
ID2="fedcba9876543210fedcba9876543210"
ID3="00112233445566778899aabbccddeeff"
OTHER="99999999999999999999999999999999"

omni_in() { local d="$1"; shift; ( set -euo pipefail; INST_DIR="$d"; omni "$@" ); }
pc_args() {
    PC=("$1" stripe server 203.0.113.9 1.2.3.4 "$2" "$K" 10.201.4.2 10.201.4.1 none 16 "" "" "${4:-16}")
    [[ -z "${3:-}" ]] || PC+=("$3")
}
snap() {
    [[ -d "$1" ]] || { echo ABSENT; return 0; }
    local f
    for f in "$1"/*; do echo "== ${f##*/}"; cat "$f"; done
}
wait_go() { while [[ ! -e "$1" ]]; do sleep 0.002; done; }

FOREIGN=""; PCALLS=""; FOREIGN_MODE=""; PNAME=""
foreign_exec() {
    local sub="$1"
    eval "set -- $2"
    case "$FOREIGN_MODE:$sub" in
        old:_peercreate)
            omni_in "$FOREIGN" _peercreate "${@:1:13}" || return
            sed -i '/^LANES=/d' "$FOREIGN/$1/instance.conf";;
        old:_remove_own) echo "usage: omnitunnel.sh [menu|bench|add|list]";;
        drop_lanes:_peercreate|rm_fail:_peercreate|replaced:_peercreate|unreachable:_peercreate)
            omni_in "$FOREIGN" _peercreate "$@" || return
            sed -i '/^LANES=/d' "$FOREIGN/$1/instance.conf";;
        rm_fail:_remove_own) RM_FAIL=1 omni_in "$FOREIGN" _remove_own "$@";;
        *) omni_in "$FOREIGN" "$sub" "$@";;
    esac
}
replace_now() {
    omni_in "$FOREIGN" _remove "$PNAME" >/dev/null 2>&1
    pc_args "$PNAME" 42000 "$ID2" 1
    omni_in "$FOREIGN" _peercreate "${PC[@]}" >/dev/null 2>&1
    snap "$FOREIGN/$PNAME" > "$WORK/replaced.snap"
}
peer_ssh() {
    local c="$2"
    printf '%s\n' "$c" >> "$PCALLS"
    case "$c" in
        "uname -m") echo x86_64;;
        *"omnitunnel.sh _peercreate "*) foreign_exec _peercreate "${c#*omnitunnel.sh _peercreate }";;
        *"omnitunnel.sh _remove_own "*) foreign_exec _remove_own "${c#*omnitunnel.sh _remove_own }";;
        *"omnitunnel.sh _remove "*) foreign_exec _remove "${c#*omnitunnel.sh _remove }";;
        *"^LANES="*"/etc/omnitunnel/inst/"*|*"/etc/omnitunnel/inst/"*"^CREATE_ID="*)
            if [[ "$FOREIGN_MODE" == unreachable && "$c" == *"^CREATE_ID="* ]]; then return 255; fi
            if [[ "$FOREIGN_MODE" == replaced && "$c" == *"^LANES="* ]]; then replace_now; fi
            sh -c "${c//\/etc\/omnitunnel\/inst\//$FOREIGN/}";;
        *) :;;
    esac
}
relay_env() {
    FOREIGN="$WORK/$1"; PCALLS="$WORK/$1.calls"; FOREIGN_MODE="${2:-}"; PNAME="${3:-x}"
    rm -rf "$FOREIGN"; mkdir -p "$FOREIGN"; : > "$PCALLS"
}
prov() {
    ( provision_peer 203.0.113.9 "$1" stripe 203.0.113.9 1.2.3.4 41000 "$K" 10.201.4.2 10.201.4.1 none 16 "" 16 ) 2>&1
}
no_unconditional_remove() { ! grep -qE "omnitunnel\.sh _remove '" "$PCALLS"; }

case_a() {
    local F="$WORK/a" before out rc
    mkdir -p "$F"
    pc_args n1 41000 "$ID1"
    omni_in "$F" _peercreate "${PC[@]}" >/dev/null 2>&1 || fail "the first _peercreate of n1 failed"
    before="$(snap "$F/n1")"
    : > "$WORK/ensure_calls"
    pc_args n1 42000 "$ID2"
    rc=0; out="$(omni_in "$F" _peercreate "${PC[@]}" 2>&1)" || rc=$?
    [[ $rc -ne 0 ]] || fail "_peercreate over an existing instance succeeded (it must be refused)"
    [[ "$out" == *"instance 'n1' already exists on this server"* ]] || fail "refusal message missing: $out"
    [[ "$(snap "$F/n1")" == "$before" ]] || fail "the existing instance.conf changed after a refused _peercreate"
    [[ ! -s "$WORK/ensure_calls" ]] || fail "a refused _peercreate still installed engine binaries"
    pc_args n2 43000
    omni_in "$F" _peercreate "${PC[@]}" >/dev/null 2>&1 || fail "the first 14-argument _peercreate of n2 failed"
    before="$(snap "$F/n2")"
    for id in "" "$ID2"; do
        pc_args n2 44000 "$id"
        rc=0; omni_in "$F" _peercreate "${PC[@]}" >/dev/null 2>&1 || rc=$?
        [[ $rc -ne 0 ]] || fail "_peercreate over an existing legacy instance succeeded (id='$id')"
        [[ "$(snap "$F/n2")" == "$before" ]] || fail "a legacy instance changed after a refused _peercreate (id='$id')"
    done
    relay_env a_relay "" n3
    pc_args n3 45000 "$ID2"
    omni_in "$FOREIGN" _peercreate "${PC[@]}" >/dev/null 2>&1 || fail "seeding n3 on the foreign failed"
    before="$(snap "$FOREIGN/n3")"
    rc=0; out="$( ( provision_peer 203.0.113.9 n3 stripe 203.0.113.9 1.2.3.4 41000 "$K" 10.201.4.2 10.201.4.1 none 16 "" 16 ) 2>&1 )" || rc=$?
    [[ $rc -ne 0 ]] || fail "provision_peer succeeded against a foreign that already has n3"
    [[ "$(snap "$FOREIGN/n3")" == "$before" ]] || fail "provision_peer changed the foreign's existing n3"
    no_unconditional_remove || fail "provision_peer ran _remove after a refused create"
    ! grep -q "_remove_own" "$PCALLS" || fail "provision_peer tried to clean up an instance it never created"
}

case_b() {
    local i F ra rb w expA expB
    pc_args race 41000 "$ID1"; omni_in "$WORK/bexpA" _peercreate "${PC[@]}" >/dev/null 2>&1
    expA="$(snap "$WORK/bexpA/race")"
    pc_args race 42000 "$ID2"; omni_in "$WORK/bexpB" _peercreate "${PC[@]}" >/dev/null 2>&1
    expB="$(snap "$WORK/bexpB/race")"
    [[ "$expA" != ABSENT && "$expB" != ABSENT && "$expA" != "$expB" ]] || fail "could not build the expected instance.conf files"
    for ((i=0; i<ITER; i++)); do
        F="$WORK/b$i"; mkdir -p "$F"
        ( wait_go "$F.go"; pc_args race 41000 "$ID1"; VAL_DELAY=0.03 omni_in "$F" _peercreate "${PC[@]}" >/dev/null 2>&1; echo $? > "$F.ra" ) &
        ( wait_go "$F.go"; pc_args race 42000 "$ID2"; VAL_DELAY=0.03 omni_in "$F" _peercreate "${PC[@]}" >/dev/null 2>&1; echo $? > "$F.rb" ) &
        touch "$F.go"; wait
        ra="$(cat "$F.ra")"; rb="$(cat "$F.rb")"
        if [[ "$ra" == 0 && "$rb" != 0 ]]; then w="$expA"
        elif [[ "$ra" != 0 && "$rb" == 0 ]]; then w="$expB"
        else fail "iteration $i: concurrent _peercreate exits A=$ra B=$rb (want exactly one success)"; fi
        [[ "$(snap "$F/race")" == "$w" ]] || fail "iteration $i: the surviving instance is not the winner's intact instance"
        rm -rf "$F" "$F.go" "$F.ra" "$F.rb"
    done
    echo "b: $ITER concurrent same-name creations, exactly one success each, winner intact"
}

case_c() {
    local F="$WORK/c" before rc
    mkdir -p "$F"
    pc_args n1 41000 "$ID1"; omni_in "$F" _peercreate "${PC[@]}" >/dev/null 2>&1 || fail "create n1"
    rc=0; omni_in "$F" _remove_own n1 "$ID1" >/dev/null 2>&1 || rc=$?
    [[ $rc -eq 0 ]] || fail "_remove_own with the matching id exited $rc (want 0)"
    [[ ! -e "$F/n1" ]] || fail "_remove_own with the matching id left the instance"
    pc_args n2 42000 "$ID1"; omni_in "$F" _peercreate "${PC[@]}" >/dev/null 2>&1 || fail "create n2"
    before="$(snap "$F/n2")"
    rc=0; omni_in "$F" _remove_own n2 "$ID2" >/dev/null 2>&1 || rc=$?
    [[ $rc -eq 3 ]] || fail "_remove_own with a different id exited $rc (want 3)"
    [[ "$(snap "$F/n2")" == "$before" ]] || fail "_remove_own with a different id changed the instance"
    pc_args n3 43000; omni_in "$F" _peercreate "${PC[@]}" >/dev/null 2>&1 || fail "create n3"
    before="$(snap "$F/n3")"
    rc=0; omni_in "$F" _remove_own n3 "$ID1" >/dev/null 2>&1 || rc=$?
    [[ $rc -eq 3 ]] || fail "_remove_own on an instance without CREATE_ID exited $rc (want 3)"
    [[ "$(snap "$F/n3")" == "$before" ]] || fail "_remove_own changed an instance without CREATE_ID"
    rc=0; omni_in "$F" _remove_own ghost "$ID1" >/dev/null 2>&1 || rc=$?
    [[ $rc -eq 4 ]] || fail "_remove_own on an absent name exited $rc (want 4)"
    pc_args n4 44000 "$ID1"; omni_in "$F" _peercreate "${PC[@]}" >/dev/null 2>&1 || fail "create n4"
    rc=0; RM_FAIL=1 omni_in "$F" _remove_own n4 "$ID1" >/dev/null 2>&1 || rc=$?
    [[ $rc -ne 0 && $rc -ne 3 && $rc -ne 4 ]] || fail "_remove_own whose removal failed exited $rc (want a failure other than 0/3/4)"
}

case_d() {
    local F="$WORK/d" before rc i ra rb expB da db
    mkdir -p "$F"
    pc_args r 41000 "$ID1"; omni_in "$F" _peercreate "${PC[@]}" >/dev/null 2>&1 || fail "A's create"
    omni_in "$F" _remove r >/dev/null 2>&1 || fail "B's remove"
    pc_args r 42000 "$ID2"; omni_in "$F" _peercreate "${PC[@]}" >/dev/null 2>&1 || fail "B's create"
    before="$(snap "$F/r")"
    rc=0; omni_in "$F" _remove_own r "$ID1" >/dev/null 2>&1 || rc=$?
    [[ $rc -eq 3 ]] || fail "A's cleanup of a replaced instance exited $rc (want 3)"
    [[ "$(snap "$F/r")" == "$before" ]] || fail "A's cleanup removed or changed B's instance"
    expB="$before"
    for ((i=0; i<ITER; i++)); do
        F="$WORK/d$i"; mkdir -p "$F"
        pc_args r 41000 "$ID1"; omni_in "$F" _peercreate "${PC[@]}" >/dev/null 2>&1 || fail "iteration $i: A's create"
        da="0.0$((RANDOM % 7))"; db="0.0$((RANDOM % 4))"
        ( wait_go "$F.go"; RM_DELAY="$da" omni_in "$F" _remove_own r "$ID1" >/dev/null 2>&1; echo $? > "$F.ra" ) &
        ( wait_go "$F.go"; RM_DELAY="$db" omni_in "$F" _remove r >/dev/null 2>&1
          pc_args r 42000 "$ID2"; omni_in "$F" _peercreate "${PC[@]}" >/dev/null 2>&1; echo $? > "$F.rb" ) &
        touch "$F.go"; wait
        ra="$(cat "$F.ra")"; rb="$(cat "$F.rb")"
        [[ "$rb" == 0 ]] || fail "iteration $i: B's replace failed ($rb)"
        [[ "$(snap "$F/r")" == "$expB" ]] || fail "iteration $i: B's instance was removed or damaged by A's cleanup (A exit $ra, delays $da/$db)"
        [[ "$ra" == 0 || "$ra" == 3 || "$ra" == 4 ]] || fail "iteration $i: A's _remove_own exited $ra"
        rm -rf "$F" "$F.go" "$F.ra" "$F.rb"
    done
    echo "d: $ITER interleavings of A's cleanup with B's remove+create, B's instance always intact"
}

case_e() {
    local out a b
    relay_env e2 rm_fail x
    out="$(prov x)"
    [[ "$out" != *"was removed"* ]] || fail "failed removal: message claims it was removed: $out"
    [[ "$out" == *"may still exist"* ]] || fail "failed removal: message does not say the foreign side may still exist: $out"
    [[ -e "$FOREIGN/x/instance.conf" ]] || fail "failed removal: harness did not keep the instance"
    relay_env e1 drop_lanes x
    out="$(prov x)"
    [[ "$out" == *"the foreign side was removed"* ]] || fail "verified removal: message does not say it was removed: $out"
    [[ ! -e "$FOREIGN/x" ]] || fail "verified removal: the foreign side is still there"
    grep -qE " _peercreate 'x' 'stripe' server .* '16' '[0-9a-f]{32}'\$" "$PCALLS" || fail "provision_peer did not pass a 32-hex creation id as the 15th _peercreate argument"
    a="$(sed -nE "s/.* _peercreate 'x' .* '([0-9a-f]{32})'\$/\1/p" "$PCALLS")"
    grep -qF " _remove_own 'x' '$a'" "$PCALLS" || fail "the lane-mismatch cleanup did not call _remove_own with this run's id"
    no_unconditional_remove || fail "the lane-mismatch cleanup still runs the unconditional _remove"
    relay_env e1b drop_lanes x
    prov x >/dev/null
    b="$(sed -nE "s/.* _peercreate 'x' .* '([0-9a-f]{32})'\$/\1/p" "$PCALLS")"
    [[ -n "$b" && "$a" != "$b" ]] || fail "two runs used the same creation id ($a / $b)"
    relay_env e3 replaced x
    out="$(prov x)"
    [[ "$(snap "$FOREIGN/x")" == "$(cat "$WORK/replaced.snap")" ]] || fail "replaced: the other run's instance was removed or changed"
    [[ "$out" == *"belongs to another run"* ]] || fail "replaced: message does not say the instance belongs to another run: $out"
    [[ "$out" != *"was removed"* ]] || fail "replaced: message claims the foreign side was removed: $out"
    no_unconditional_remove || fail "replaced: the cleanup ran the unconditional _remove"
    relay_env e4 unreachable x
    out="$(prov x)"
    [[ "$out" == *"may still exist"* ]] || fail "unverifiable: message does not say the foreign side may still exist: $out"
    [[ "$out" != *"was removed"* ]] || fail "unverifiable: message claims it was removed: $out"
}

case_f() {
    local F="$WORK/f" before bad rc
    mkdir -p "$F"
    pc_args keep 41000 "$ID1"; omni_in "$F" _peercreate "${PC[@]}" >/dev/null 2>&1 || fail "create keep"
    before="$(snap "$F/keep")"
    for bad in ABCDEF0123456789ABCDEF0123456789 "${ID1:0:31}" "${ID1}0" "g${ID1:1}" "${ID1:0:16} ${ID1:17}" "$ID1"$'\n' "';touch $WORK/pwned;'" "-1"; do
        pc_args fbad 42000 "$bad"
        rc=0; omni_in "$F" _peercreate "${PC[@]}" >/dev/null 2>&1 || rc=$?
        [[ $rc -ne 0 ]] || fail "_peercreate accepted the malformed creation id '$bad'"
        [[ ! -e "$F/fbad" ]] || fail "_peercreate created an instance for the malformed id '$bad'"
        rc=0; omni_in "$F" _remove_own keep "$bad" >/dev/null 2>&1 || rc=$?
        [[ $rc -ne 0 && $rc -ne 3 && $rc -ne 4 ]] || fail "_remove_own accepted the malformed id '$bad' (exit $rc)"
        [[ "$(snap "$F/keep")" == "$before" ]] || fail "_remove_own with the malformed id '$bad' touched an instance"
    done
    for bad in "" "../keep" "a/b" "-x"; do
        rc=0; omni_in "$F" _remove_own "$bad" "$ID1" >/dev/null 2>&1 || rc=$?
        [[ $rc -ne 0 && $rc -ne 3 && $rc -ne 4 ]] || fail "_remove_own accepted the instance name '$bad' (exit $rc)"
    done
    [[ "$(snap "$F/keep")" == "$before" ]] || fail "a rejected _remove_own touched the instance"
    [[ ! -e "$WORK/pwned" ]] || fail "a creation id was executed"
}

case_g() {
    local F="$WORK/g"
    mkdir -p "$F"
    pc_args g14 41000
    omni_in "$F" _peercreate "${PC[@]}" >/dev/null 2>&1 || fail "the 14-argument _peercreate failed"
    grep -qx 'LANES=16' "$F/g14/instance.conf" || fail "the 14-argument _peercreate lost the lane count"
    ! grep -q '^CREATE_ID=' "$F/g14/instance.conf" || fail "the 14-argument _peercreate wrote a CREATE_ID"
    omni_in "$F" _peercreate g13 stripe server 203.0.113.9 1.2.3.4 42000 "$K" 10.201.5.2 10.201.5.1 none 16 "" "" >/dev/null 2>&1 \
        || fail "the 13-argument _peercreate failed"
    grep -qx 'LANES=1' "$F/g13/instance.conf" || fail "the 13-argument _peercreate must record LANES=1"
    omni_in "$F" _peercreate g11 tcp server 203.0.113.9 1.2.3.4 43000 "$K" 10.201.6.2 10.201.6.1 none 8 >/dev/null 2>&1 \
        || fail "the 11-argument (bench) _peercreate failed"
    grep -qx 'PORT=43000' "$F/g11/instance.conf" || fail "the 11-argument _peercreate wrote a wrong instance.conf"
}

case_h() {
    local out
    relay_env h old x
    out="$(prov x)"
    [[ "$out" == *"may still exist"* ]] || fail "old foreign manager: message does not say the foreign side may still exist: $out"
    [[ "$out" != *"was removed"* ]] || fail "old foreign manager: message claims the foreign side was removed: $out"
    no_unconditional_remove || fail "old foreign manager: the relay fell back to the unconditional _remove"
    grep -q " _remove_own 'x' " "$PCALLS" || fail "old foreign manager: the relay did not try _remove_own"
    [[ -e "$FOREIGN/x/instance.conf" ]] || fail "old foreign manager: the foreign side was removed without proof of ownership"
}

case_i() {
    local NEAR="$WORK/i_near" OUT="$WORK/i.out" tcp_before mux_before t bid_used u1 u2
    relay_env i_foreign "" bench
    ROOT_DIR="$WORK/i_root"; mkdir -p "$ROOT_DIR" "$NEAR"
    omni_in "$FOREIGN" _peercreate bench-tcp tcp server 203.0.113.7 198.51.100.7 51900 "$K" 10.201.8.2 10.201.8.1 none 8 >/dev/null 2>&1 || fail "seed bench-tcp"
    printf 'CREATE_ID=%s\n' "$OTHER" >> "$FOREIGN/bench-tcp/instance.conf"
    omni_in "$FOREIGN" _peercreate bench-mux mux server 203.0.113.7 198.51.100.7 51901 "$K" 10.201.7.2 10.201.7.1 none 8 >/dev/null 2>&1 || fail "seed bench-mux"
    tcp_before="$(snap "$FOREIGN/bench-tcp")"; mux_before="$(snap "$FOREIGN/bench-mux")"
    sleep() { :; }
    ping() { return 1; }
    nc() { return 1; }
    timeout() { return 1; }
    iperf3() { return 1; }
    curl() { echo 0; }
    bench_ensure_iperf() { return 0; }
    bench_ensure_httpfile() { return 0; }
    bench_curl_mbps() { return 1; }
    pf_apply_all() { :; }
    mux_relay_reconcile() { :; }
    mux_token() { echo tok; }
    bench_table() { :; }
    rule_green() { :; }
    type_desc() { echo d; }
    save_peer() { :; }
    guard_peer_downgrade() { :; }
    default_local_ip() { echo 1.2.3.4; }
    hy_local_bin() { return 1; }
    omnistripe_local_bin() { return 1; }
    omniackless_local_bin() { return 1; }
    INST_DIR="$NEAR"
    printf '203.0.113.9\nroot\n\n\n1.2.3.4\n0\n' | bench_run > "$OUT" 2>&1
    set +e
    [[ "$(snap "$FOREIGN/bench-tcp")" == "$tcp_before" ]] || fail "bench overwrote or removed another relay's bench-tcp on the foreign (now: $(snap "$FOREIGN/bench-tcp" | head -1))"
    [[ "$(snap "$FOREIGN/bench-mux")" == "$mux_before" ]] || fail "bench overwrote or removed a bench-mux it did not create"
    bid_used="$(sed -nE "s/.* _peercreate 'bench-udp' .* '([0-9a-f]{32})'\$/\1/p" "$PCALLS" | head -1)"
    [[ -n "$bid_used" ]] || fail "bench did not create bench-udp with a per-run creation id: $(grep _peercreate "$PCALLS" | head -3)"
    [[ "$bid_used" != "$OTHER" ]] || fail "bench used another relay's creation id as its own run id"
    for t in $ALL_TYPES; do
        case "$t" in tcp|mux) continue;; esac
        [[ ! -e "$FOREIGN/bench-$t" ]] || fail "bench left its own bench-$t on the foreign"
    done
    no_unconditional_remove || fail "bench still runs the unconditional _remove on the foreign"
    ! grep -q " mux-off " "$PCALLS" || fail "bench still runs the unconditional mux-off on the foreign"
    grep -q "bench-clean" "$OUT" || fail "bench did not tell the operator how to clear the instances in its way"
    rm -f "$ROOT_DIR/bench.ids" "$ROOT_DIR"/bench.*.lock 2>/dev/null
    u1="$(bench_create_id)" || fail "bench_create_id failed"
    create_id_ok "$u1" || fail "bench_create_id returned a malformed id '$u1'"
    awk -v x="$u1" '$1==x{f=1} END{exit !f}' "$ROOT_DIR/bench.ids" || fail "bench_create_id did not record its run id in the registry"
    [[ "$(stat -c %a "$ROOT_DIR/bench.ids")" == 600 ]] || fail "the bench id registry is not mode 600"
    u2="$(bench_create_id)" || fail "bench_create_id failed on a second run"
    create_id_ok "$u2" || fail "bench_create_id returned a malformed id '$u2'"
    [[ "$u1" != "$u2" ]] || fail "bench_create_id must return a distinct id per run, got the same twice"
}

RESULTS=(); BAD=0
run_case() {
    local id="$1" out rc=0
    out="$( "case_$id" 2>&1 )" || rc=$?
    if [[ $rc -eq 0 ]]; then
        RESULTS+=("PASS ($id)${out:+ - $(tail -n 1 <<< "$out")}")
    else
        RESULTS+=("FAIL ($id): $(grep -m1 '^FAIL' <<< "$out" || tail -n 2 <<< "$out" | tr '\n' ' ')")
        BAD=1
    fi
}

for c in a b c d e f g h i; do run_case "$c"; done
printf '%s\n' "${RESULTS[@]}"
[[ $BAD -eq 0 ]] || { echo "peercreate_exclusive_test FAILED" >&2; exit 1; }
echo "PASSED - foreign creation is exclusive under a lock (refused names stay byte-identical, $ITER concurrent same-name creations end with exactly one intact winner), _remove_own removes only this run's CREATE_ID instance (0/3/4/other), $ITER interleaved cleanups never touch the replacing run's instance, the relay's lane-mismatch cleanup reports the verified outcome and never falls back to _remove, old argument counts still work, and the benchmark replaces only its own leftovers"
