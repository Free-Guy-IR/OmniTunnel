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

eval "$(extract "tok_re lanes_ok inst_name_ok create_id_ok new_create_id inst_create_lock inst_create_unlock type_is_hysteria type_is_stripe type_is_ackless type_is_kernel type_is_revmux type_uses_key inst_path inst_conf inst_pf inst_exists list_instances validate_inst_name norm_port create_inst cmd_peercreate cmd_remove_own peer_inst_state peer_remove_own bench_peer_create bench_peer_remove bench_peer_remove_confirm bench_create_id bench_reg_file bench_reg_lock bench_id_lock bench_reg_add bench_reg_del bench_abandoned_ids bench_migrate_legacy bench_clean_abandoned bench_run_done gen_key")"
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
AB="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
LV="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
LG="cccccccccccccccccccccccccccccccc"
MYID="dddddddddddddddddddddddddddddddd"
HX="203.0.113.9"
HY="198.51.100.9"

FOREIGN=""; FAIL_REMOVE=""
omni_in() { local d="$1"; shift; ( set -euo pipefail; INST_DIR="$d"; omni "$@" ); }
peer_ssh() {
    local host="$1" c="$2"
    case "$c" in
        "uname -m") echo x86_64;;
        *"omnitunnel.sh _peercreate "*) eval "set -- ${c#*omnitunnel.sh _peercreate }"; omni_in "$FOREIGN" _peercreate "$@";;
        *"omnitunnel.sh _remove_own "*)
            if [[ -n "${FAIL_REMOVE:-}" && "$host" == "$FAIL_REMOVE" ]]; then return 255; fi
            eval "set -- ${c#*omnitunnel.sh _remove_own }"; omni_in "$FOREIGN" _remove_own "$@";;
        *) :;;
    esac
}
seed_inst() { omni_in "$1" _peercreate "$3" udp server 203.0.113.9 1.2.3.4 28900 "$K" 10.201.9.2 10.201.9.1 none 8 "" "" "" "$2" >/dev/null 2>&1; }
reg_has() { awk -v x="$1" '$1==x{f=1} END{exit !f}' "$2" 2>/dev/null; }
wait_file() { local f="$1" n=0; while [[ ! -e "$f" ]]; do sleep 0.002; n=$((n+1)); [[ $n -gt 20000 ]] && break; done; }

case_interleave() {
    local i R F dA dB idA idB rid
    for ((i=0; i<ITER; i++)); do
        R="$WORK/il$i.r"; F="$WORK/il$i.f"; mkdir -p "$R" "$F"
        printf '%s\n' "$SEED" > "$R/bench.id"
        dA="0.00$((RANDOM % 6))"; dB="0.00$((RANDOM % 6))"
        (
            wait_file "$WORK/il$i.go"; sleep "$dA"
            ROOT_DIR="$R"; FOREIGN="$F"; BENCH_ID=""
            local a; a="$(bench_create_id "$HX")"; printf '%s' "$a" > "$WORK/il$i.a"
            bench_peer_create 203.0.113.9 "$a" bench-udp udp server 203.0.113.9 1.2.3.4 28900 "$K" 10.201.9.2 10.201.9.1 none 8 "" "" "" >/dev/null 2>&1
            touch "$WORK/il$i.adone"
        ) &
        (
            wait_file "$WORK/il$i.go"; wait_file "$WORK/il$i.adone"; sleep "$dB"
            ROOT_DIR="$R"; FOREIGN="$F"; BENCH_ID=""
            local b; b="$(bench_create_id "$HX")"; printf '%s' "$b" > "$WORK/il$i.b"
            bench_peer_remove 203.0.113.9 "$b" bench-udp
        ) &
        touch "$WORK/il$i.go"; wait
        idA="$(cat "$WORK/il$i.a" 2>/dev/null)"; idB="$(cat "$WORK/il$i.b" 2>/dev/null)"
        [[ -n "$idA" && -n "$idB" ]] || fail "interleave: a concurrent run produced no id (A='$idA' B='$idB')"
        [[ -e "$F/bench-udp/instance.conf" ]] || fail "interleave: run B removed run A's live foreign bench-udp (A=$idA B=$idB)"
        rid="$(grep -m1 '^CREATE_ID=' "$F/bench-udp/instance.conf" 2>/dev/null | cut -d= -f2)"
        [[ "$rid" == "$idA" ]] || fail "interleave: run A's bench-udp CREATE_ID is '$rid', not run A's id '$idA'"
        [[ "$idA" != "$idB" ]] || fail "interleave: two concurrent benchmarks shared one creation id ($idA)"
    done
    echo "interleave: $ITER concurrent pairs, no cross-removal"
}

case_unit() {
    local R a b
    R="$WORK/u.r"; mkdir -p "$R"
    a="$( ROOT_DIR="$R"; BENCH_ID=""; bench_create_id "$HX" )"
    b="$( ROOT_DIR="$R"; BENCH_ID=""; bench_create_id "$HX" )"
    create_id_ok "$a" || fail "unit: malformed id '$a'"
    create_id_ok "$b" || fail "unit: malformed id '$b'"
    [[ "$a" != "$b" ]] || fail "unit: bench_create_id must be distinct per run, got the same twice"
    [[ "$a" != "$SEED" ]] || fail "unit: bench_create_id reused a shared id"
    reg_has "$a" "$R/bench.ids" || fail "unit: run id '$a' not recorded in the registry"
    reg_has "$b" "$R/bench.ids" || fail "unit: run id '$b' not recorded in the registry"
    [[ "$(stat -c %a "$R/bench.ids")" == 600 ]] || fail "unit: registry is not mode 600"
}

case_crash() {
    local R F
    R="$WORK/cr.r"; F="$WORK/cr.f"; mkdir -p "$R" "$F"
    ( ROOT_DIR="$R"; bench_reg_add "$AB" "$HX" )
    : > "$R/bench.$AB.lock"
    seed_inst "$F" "$AB" bench-udp || fail "crash: could not seed abandoned instance"
    ( ROOT_DIR="$R"; FOREIGN="$F"; BENCH_ID="$MYID"; bench_clean_abandoned "$HX" )
    [[ ! -e "$F/bench-udp/instance.conf" ]] || fail "crash: abandoned run's foreign bench-udp was not removed"
    ! reg_has "$AB" "$R/bench.ids" || fail "crash: abandoned id was not dropped from the registry after a confirmed removal"
}

case_live() {
    local R F holder n
    R="$WORK/lv.r"; F="$WORK/lv.f"; mkdir -p "$R" "$F"
    ( ROOT_DIR="$R"; bench_reg_add "$LV" "$HX" )
    seed_inst "$F" "$LV" bench-udp || fail "live: could not seed live instance"
    (
        exec {hfd}>"$R/bench.$LV.lock" 2>/dev/null
        flock "$hfd" 2>/dev/null
        : > "$R/held"
        while [[ -e "$R/go" ]]; do sleep 0.05; done
    ) &
    holder=$!
    : > "$R/go"
    n=0; while [[ ! -e "$R/held" ]]; do sleep 0.01; n=$((n+1)); [[ $n -gt 2000 ]] && break; done
    ( ROOT_DIR="$R"; FOREIGN="$F"; BENCH_ID="$MYID"; bench_clean_abandoned "$HX" )
    rm -f "$R/go"; wait "$holder" 2>/dev/null
    [[ -e "$F/bench-udp/instance.conf" ]] || fail "live: a LIVE concurrent run's foreign bench-udp was removed"
    reg_has "$LV" "$R/bench.ids" || fail "live: a live run's id was dropped from the registry"
}

case_empty() {
    local R F
    R="$WORK/e.r"; F="$WORK/e.f"; mkdir -p "$R" "$F"
    ( ROOT_DIR="$R"; FOREIGN="$F"; BENCH_ID=""; bench_clean_abandoned "$HX" ) || fail "empty: non-zero exit on an empty registry"
}

case_crosshost() {
    local R F
    R="$WORK/ch.r"; F="$WORK/ch.f"; mkdir -p "$R" "$F"
    ( ROOT_DIR="$R"; bench_reg_add "$AB" "$HX" )
    : > "$R/bench.$AB.lock"
    seed_inst "$F" "$AB" bench-udp || fail "crosshost: could not seed hostX instance"
    ( ROOT_DIR="$R"; FOREIGN="$WORK/ch.fy"; mkdir -p "$FOREIGN"; BENCH_ID="$MYID"; bench_clean_abandoned "$HY" )
    reg_has "$AB" "$R/bench.ids" || fail "crosshost: run B on a DIFFERENT host dropped run A's abandoned id (orphaning A's instances on its own host)"
    [[ -e "$F/bench-udp/instance.conf" ]] || fail "crosshost: run B removed run A's foreign bench-udp on the other host"
}

case_failremove() {
    local R F
    R="$WORK/fr.r"; F="$WORK/fr.f"; mkdir -p "$R" "$F"
    ( ROOT_DIR="$R"; bench_reg_add "$AB" "$HX" )
    : > "$R/bench.$AB.lock"
    seed_inst "$F" "$AB" bench-udp || fail "failremove: could not seed instance"
    ( ROOT_DIR="$R"; FOREIGN="$F"; FAIL_REMOVE="$HX"; BENCH_ID="$MYID"; bench_clean_abandoned "$HX" )
    reg_has "$AB" "$R/bench.ids" || fail "failremove: an abandoned id was dropped although its foreign removal failed"
    [[ -e "$F/bench-udp/instance.conf" ]] || fail "failremove: the foreign instance vanished although removal was supposed to fail"
}

case_legacy() {
    local R F
    R="$WORK/lg.r"; F="$WORK/lg.f"; mkdir -p "$R" "$F"
    printf '%s\n' "$LG" > "$R/bench.id"
    seed_inst "$F" "$LG" bench-udp || fail "legacy: could not seed legacy instance"
    ( ROOT_DIR="$R"; FOREIGN="$F"; BENCH_ID="$MYID"; bench_clean_abandoned "$HX" )
    [[ ! -e "$R/bench.id" ]] || fail "legacy: a crashed 2.9.12 bench.id was left in place (never migrated/cleaned)"
    [[ ! -e "$F/bench-udp/instance.conf" ]] || fail "legacy: the legacy bench.id's foreign leftovers were not cleaned"
    ! reg_has "$LG" "$R/bench.ids" || fail "legacy: the migrated legacy id was not dropped after a confirmed removal"
}

RESULTS=(); BAD=0
run_case() {
    local id="$1" out rc=0
    out="$( "case_$id" 2>&1 )" || rc=$?
    if [[ $rc -eq 0 ]]; then RESULTS+=("PASS ($id)${out:+ - $(tail -n1 <<<"$out")}")
    else RESULTS+=("FAIL ($id): $(grep -m1 '^FAIL' <<<"$out" || tail -n1 <<<"$out")"); BAD=1; fi
}

for c in interleave unit crash live empty crosshost failremove legacy; do run_case "$c"; done
printf '%s\n' "${RESULTS[@]}"
[[ $BAD -eq 0 ]] || { echo "bench_runid_test FAILED" >&2; exit 1; }
echo "PASSED - distinct per-run benchmark ids ($ITER concurrent pairs never cross-remove), host-tagged registry with flock liveness: an abandoned id is dropped only after a CONFIRMED same-host removal, kept when the host differs (crosshost) or the removal fails (failremove), a live concurrent run is untouched, and a legacy 2.9.12 bench.id is migrated and cleaned"
