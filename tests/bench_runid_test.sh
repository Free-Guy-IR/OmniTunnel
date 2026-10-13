#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2317
set -u

SCRIPT="${1:-$(dirname "$0")/../omnitunnel.sh}"
ITER="${BENCH_RUNID_ITER:-100}"

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

eval "$(extract "tok_re lanes_ok inst_name_ok create_id_ok new_create_id inst_create_lock inst_create_unlock type_is_hysteria type_is_stripe type_is_ackless type_is_kernel type_is_revmux type_uses_key inst_path inst_conf inst_pf inst_exists list_instances validate_inst_name norm_port create_inst cmd_peercreate cmd_remove_own peer_inst_state peer_remove_own bench_peer_create bench_peer_remove bench_create_id bench_reg_file bench_reg_lock bench_id_lock bench_reg_add bench_reg_del bench_abandoned_ids bench_clean_abandoned bench_run_done gen_key")"
eval "$(grep -m1 '^ALL_TYPES=' "$SCRIPT")"

DISPATCH="$(grep -E '^[[:space:]]+(_peercreate|_remove_own|_remove)\)' "$SCRIPT")"
eval "omni() {
    case \"\${1:-}\" in
$DISPATCH
        *) echo \"usage: omnitunnel.sh\";;
    esac
}"

fail() { echo "FAIL: $*" >&2; exit 1; }
need_root() { :; }
ok() { :; }
info() { :; }
warn() { :; }
die() { echo "DIE: $*" >&2; exit 1; }
ensure_binary() { :; }
ensure_hysteria() { :; }
ensure_omnistripe() { :; }
ensure_omniackless() { :; }
peer_scp() { :; }
inst_enable() { :; }
inst_remove() { rm -rf "${INST_DIR:?}/$1"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
C_BOLD=""; C_RESET=""; C_GREY=""; C_BGRN=""; C_CYAN=""; C_GREEN=""; C_DIM=""

K="$(printf 'e%.0s' {1..64})"
SEED="0123456789abcdef0123456789abcdef"

FOREIGN=""
omni_in() { local d="$1"; shift; ( set -euo pipefail; INST_DIR="$d"; omni "$@" ); }
peer_ssh() {
    local c="$2"
    case "$c" in
        "uname -m") echo x86_64;;
        *"omnitunnel.sh _peercreate "*) eval "set -- ${c#*omnitunnel.sh _peercreate }"; omni_in "$FOREIGN" _peercreate "$@";;
        *"omnitunnel.sh _remove_own "*) eval "set -- ${c#*omnitunnel.sh _remove_own }"; omni_in "$FOREIGN" _remove_own "$@";;
        *) :;;
    esac
}
foreign_cid() { grep -m1 '^CREATE_ID=' "$FOREIGN/$1/instance.conf" 2>/dev/null | cut -d= -f2; }
wait_file() { local f="$1" n=0; while [[ ! -e "$f" ]]; do sleep 0.002; n=$((n+1)); [[ $n -gt 20000 ]] && break; done; }

interleave_once() {
    local tag="$1" R F dA dB idA idB rid
    R="$WORK/$tag.r"; F="$WORK/$tag.f"
    mkdir -p "$R" "$F"
    printf '%s\n' "$SEED" > "$R/bench.id"
    dA="0.00$((RANDOM % 6))"; dB="0.00$((RANDOM % 6))"
    (
        wait_file "$WORK/$tag.go"; sleep "$dA"
        ROOT_DIR="$R"; FOREIGN="$F"; BENCH_ID=""
        local a; a="$(bench_create_id)"; printf '%s' "$a" > "$WORK/$tag.a"
        bench_peer_create 203.0.113.9 "$a" bench-udp udp server 203.0.113.9 1.2.3.4 28900 "$K" 10.201.9.2 10.201.9.1 none 8 "" "" "" >/dev/null 2>&1
        touch "$WORK/$tag.adone"
    ) &
    (
        wait_file "$WORK/$tag.go"; wait_file "$WORK/$tag.adone"; sleep "$dB"
        ROOT_DIR="$R"; FOREIGN="$F"; BENCH_ID=""
        local b; b="$(bench_create_id)"; printf '%s' "$b" > "$WORK/$tag.b"
        bench_peer_remove 203.0.113.9 "$b" bench-udp
    ) &
    touch "$WORK/$tag.go"; wait
    idA="$(cat "$WORK/$tag.a" 2>/dev/null)"; idB="$(cat "$WORK/$tag.b" 2>/dev/null)"
    [[ -n "$idA" && -n "$idB" ]] || fail "$tag: one of the concurrent runs produced no benchmark id (A='$idA' B='$idB')"
    [[ -e "$F/bench-udp/instance.conf" ]] || fail "$tag: run B's benchmark cleanup removed run A's live foreign bench-udp (A=$idA B=$idB)"
    rid="$(grep -m1 '^CREATE_ID=' "$F/bench-udp/instance.conf" 2>/dev/null | cut -d= -f2)"
    [[ "$rid" == "$idA" ]] || fail "$tag: run A's foreign bench-udp CREATE_ID is '$rid', not run A's id '$idA' (B clobbered it)"
    [[ "$idA" != "$idB" ]] || fail "$tag: two concurrent benchmarks from one relay shared one creation id ($idA)"
}

unit_distinct() {
    local R a b
    R="$WORK/u.r"; mkdir -p "$R"
    printf '%s\n' "$SEED" > "$R/bench.id"
    a="$( ROOT_DIR="$R"; BENCH_ID=""; bench_create_id )"
    b="$( ROOT_DIR="$R"; BENCH_ID=""; bench_create_id )"
    create_id_ok "$a" || fail "unit: bench_create_id returned a malformed id '$a'"
    create_id_ok "$b" || fail "unit: bench_create_id returned a malformed id '$b'"
    [[ "$a" != "$b" ]] || fail "unit: bench_create_id returned the same id on two runs (must be distinct per run)"
    [[ "$a" != "$SEED" && "$b" != "$SEED" ]] || fail "unit: bench_create_id reused the shared per-relay bench.id instead of a fresh run id"
    grep -qxF "$a" "$R/bench.ids" || fail "unit: bench_create_id did not record run id '$a' in the registry"
    grep -qxF "$b" "$R/bench.ids" || fail "unit: bench_create_id did not record run id '$b' in the registry"
    [[ "$(stat -c %a "$R/bench.ids")" == 600 ]] || fail "unit: the bench id registry is not mode 600"
}

crash_abandoned() {
    local R F AB
    R="$WORK/ab.r"; F="$WORK/ab.f"; AB="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    mkdir -p "$R" "$F"
    printf '%s\n' "$AB" > "$R/bench.ids"; chmod 600 "$R/bench.ids"
    : > "$R/bench.$AB.lock"
    omni_in "$F" _peercreate bench-udp udp server 203.0.113.9 1.2.3.4 28900 "$K" 10.201.9.2 10.201.9.1 none 8 "" "" "" "$AB" >/dev/null 2>&1 || fail "crash: could not seed the abandoned foreign instance"
    ( ROOT_DIR="$R"; FOREIGN="$F"; BENCH_ID="cccccccccccccccccccccccccccccccc"; bench_clean_abandoned 203.0.113.9 )
    [[ ! -e "$F/bench-udp/instance.conf" ]] || fail "crash: bench_clean_abandoned did not remove an abandoned run's foreign bench-udp"
    ! grep -qxF "$AB" "$R/bench.ids" 2>/dev/null || fail "crash: bench_clean_abandoned did not drop the abandoned id from the registry"
}

live_protected() {
    local R F LV holder n
    R="$WORK/lv.r"; F="$WORK/lv.f"; LV="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    mkdir -p "$R" "$F"
    printf '%s\n' "$LV" > "$R/bench.ids"; chmod 600 "$R/bench.ids"
    omni_in "$F" _peercreate bench-udp udp server 203.0.113.9 1.2.3.4 28900 "$K" 10.201.9.2 10.201.9.1 none 8 "" "" "" "$LV" >/dev/null 2>&1 || fail "live: could not seed the live foreign instance"
    (
        exec {hfd}>"$R/bench.$LV.lock" 2>/dev/null
        flock "$hfd" 2>/dev/null
        : > "$R/held"
        while [[ -e "$R/go" ]]; do sleep 0.05; done
    ) &
    holder=$!
    : > "$R/go"
    n=0; while [[ ! -e "$R/held" ]]; do sleep 0.01; n=$((n+1)); [[ $n -gt 2000 ]] && break; done
    ( ROOT_DIR="$R"; FOREIGN="$F"; BENCH_ID="cccccccccccccccccccccccccccccccc"; bench_clean_abandoned 203.0.113.9 )
    rm -f "$R/go"; wait "$holder" 2>/dev/null
    [[ -e "$F/bench-udp/instance.conf" ]] || fail "live: bench_clean_abandoned removed a LIVE concurrent run's foreign bench-udp"
    grep -qxF "$LV" "$R/bench.ids" 2>/dev/null || fail "live: bench_clean_abandoned dropped a live run's id from the registry"
}

empty_noop() {
    local R F
    R="$WORK/e.r"; F="$WORK/e.f"; mkdir -p "$R" "$F"
    ( ROOT_DIR="$R"; FOREIGN="$F"; BENCH_ID=""; bench_clean_abandoned 203.0.113.9 ) || fail "empty: bench_clean_abandoned failed with an empty registry"
}

for ((i=0; i<ITER; i++)); do interleave_once "il$i"; done
unit_distinct
crash_abandoned
live_protected
empty_noop

echo "PASSED - each benchmark run gets a distinct creation id: $ITER concurrent benchmark pairs from one relay never remove each other's foreign bench instance, two runs' ids are always distinct and recorded in the registry, an abandoned run's leftovers are cleaned while a live concurrent run's instance is left untouched, and an empty registry is a no-op"
