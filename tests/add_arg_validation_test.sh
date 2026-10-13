#!/usr/bin/env bash
set -u

SCRIPT="${1:-$(dirname "$0")/../omnitunnel.sh}"

extract() {
    awk -v names="$1" '
    BEGIN { n=split(names, a, " "); for (i=1;i<=n;i++) want[a[i]]=1 }
    inblock { print; if ($0 ~ /^}/) inblock=0; next }
    {
        if (match($0, /^[A-Za-z0-9_]+\(\)[ \t]*\{/)) {
            nm=$0; sub(/\(\).*/, "", nm)
            if (nm in want) { print; if ($0 !~ /\}[ \t]*$/) inblock=1 }
        }
    }' "$SCRIPT"
}

FAILS=0; PASSES=0
fail() { echo "FAIL: $1" >&2; FAILS=$((FAILS+1)); }
pass() { echo "ok: $1"; PASSES=$((PASSES+1)); }

eval "$(extract "add_parse cmd_add_auto cmd_add_manual tok_re tok_host_ok tok_ipv4_ok tok_shape_ok tok_nc_ok")"
grep -q '^cmd_add_auto()' <(extract "cmd_add_auto") || { echo "FAIL: could not extract cmd_add_auto from $SCRIPT" >&2; exit 1; }

need_root() { :; }
type_is_hysteria() { return 1; }
type_is_stripe() { return 1; }
type_is_ackless() { return 1; }
type_is_kernel() { return 1; }
type_is_revmux() { return 1; }
ensure_hysteria() { :; }
ensure_omnistripe() { :; }
ensure_omniackless() { :; }
ensure_binary() { :; }
inst_exists() { return 1; }
# shellcheck disable=SC2034
new_inst_lanes() { NEW_LANES=1; }
default_local_ip() { echo 203.0.113.1; }
save_peer() { :; }
inst_enable() { :; }
ok() { :; }
info() { :; }
warn() { :; }
die() { echo "DIE: $*"; exit 7; }
guard_peer_downgrade() { echo "REACHED_NET guard_peer_downgrade"; exit 42; }
peer_ssh() { echo "REACHED_NET peer_ssh"; exit 42; }
peer_port_triples() { echo ""; }
provision_peer() { echo "REACHED_NET provision_peer"; exit 42; }
alloc_and_create() { echo "REACHED_NET alloc_and_create"; exit 42; }
manual_token() { echo "REACHED_NET manual_token"; exit 42; }

run_cmd() { ( "$@" ) 2>&1; }

reject() {
    local label="$1" cmd="$2"; shift 2
    local out rc
    out="$(run_cmd "$cmd" "$@")"; rc=$?
    if [[ $rc -eq 7 && "$out" == DIE:* && "$out" != *REACHED_NET* ]]; then
        pass "$label: rejected with a die before any foreign SSH command ($out)"
    else
        fail "$label: rc=$rc out=[$out] (want a die, rc 7, no REACHED_NET)"
    fi
}

accept_to_net() {
    local label="$1" cmd="$2" want="$3"; shift 3
    local out rc
    out="$(run_cmd "$cmd" "$@")"; rc=$?
    if [[ $rc -eq 42 && "$out" == *"REACHED_NET $want"* ]]; then
        pass "$label: valid args pass validation and reach $want"
    else
        fail "$label: rc=$rc out=[$out] (want REACHED_NET $want, rc 42)"
    fi
}

accept_to_net "add-auto clean"   cmd_add_auto   guard_peer_downgrade ackless myname 203.0.113.9 16 none 203.0.113.2
accept_to_net "add-manual clean" cmd_add_manual alloc_and_create     ackless myname 203.0.113.9 16 none 203.0.113.2

reject "add-auto fhost quote"    cmd_add_auto ackless myname "203.0.113.9'; id #"
reject "add-auto mylip quote"    cmd_add_auto ackless myname 203.0.113.9 16 none "203.0.113.2'; id #"
reject "add-auto shape quote"    cmd_add_auto ackless myname 203.0.113.9 16 "90mbit'; id #" 203.0.113.2
reject "add-auto nconn quote"    cmd_add_auto ackless myname 203.0.113.9 "16'; id #" none 203.0.113.2

reject "add-manual fhost quote"  cmd_add_manual ackless myname "203.0.113.9'; id #"
reject "add-manual mylip quote"  cmd_add_manual ackless myname 203.0.113.9 16 none "203.0.113.2'; id #"
reject "add-manual shape quote"  cmd_add_manual ackless myname 203.0.113.9 16 "90mbit'; id #" 203.0.113.2
reject "add-manual nconn quote"  cmd_add_manual ackless myname 203.0.113.9 "16'; id #" none 203.0.113.2

echo
if [[ "$FAILS" -ne 0 ]]; then
    echo "FAILED - add_arg_validation_test: $FAILS failure(s), $PASSES check(s) passed"
    exit 1
fi
echo "PASSED - add_arg_validation_test: $PASSES checks - add-auto/add-manual validate fhost/mylip/shape/nconn with the token validators before provision_peer builds the single-quoted foreign root SSH command, so an injected single quote is rejected while clean args still reach provisioning"
