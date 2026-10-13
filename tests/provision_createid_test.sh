#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2317
set -u

SCRIPT="${1:-$(dirname "$0")/../omnitunnel.sh}"
ITER="${PROVISION_CREATEID_ITER:-100}"

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

eval "$(extract "tok_re lanes_ok inst_name_ok create_id_ok new_create_id inst_create_lock inst_create_unlock type_is_hysteria type_is_stripe type_is_ackless type_is_kernel type_is_revmux type_uses_key inst_path inst_conf inst_pf inst_exists list_instances validate_inst_name norm_port create_inst cmd_peercreate cmd_remove_own provision_peer peer_inst_state peer_remove_own gen_key")"
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
inst_enable() { :; }
inst_remove() { rm -rf "${INST_DIR:?}/$1"; }
peer_scp() { :; }
hy_local_bin() { echo "$WORK/hysteria-$1"; }
omnistripe_local_bin() { echo "$WORK/omnistripe-$1"; }
omniackless_local_bin() { echo "$WORK/omniackless-$1"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
SCRIPT_PATH="$SCRIPT"
ASSET_DIR="$WORK/assets"; SCRIPT_DIR="$WORK/sd"; mkdir -p "$ASSET_DIR/bin" "$SCRIPT_DIR/bin"
: > "$ASSET_DIR/bin/omnitun-amd64"
VERSION="2.9.13t"
C_BOLD=""; C_RESET=""; C_GREY=""; C_BGRN=""; C_CYAN=""; C_GREEN=""; C_DIM=""

K="$(printf 'c%.0s' {1..64})"
K2="$(printf 'd%.0s' {1..64})"
REPLACER_ID="deadbeefdeadbeefdeadbeefdeadbeef"

FOREIGN=""; PCALLS=""; MODE=""; PNAME=""; REPLFLAG=""
relay_env() {
    FOREIGN="$WORK/$1"; PCALLS="$WORK/$1.calls"; MODE="${2:-}"; PNAME="${3:-x}"; REPLFLAG="$WORK/$1.replaced"
    rm -rf "$FOREIGN"; mkdir -p "$FOREIGN"; : > "$PCALLS"; rm -f "$REPLFLAG"
}
omni_in() { local d="$1"; shift; ( set -euo pipefail; INST_DIR="$d"; omni "$@" ); }
inst_nm() { sed -nE "s#.*/etc/omnitunnel/inst/'([^']+)'/instance.conf.*#\1#p" <<< "$1"; }
replace_samelane() {
    omni_in "$FOREIGN" _remove "$PNAME" >/dev/null 2>&1
    omni_in "$FOREIGN" _peercreate "$PNAME" stripe server 203.0.113.9 1.2.3.4 59000 "$K2" 10.201.4.2 10.201.4.1 none 16 "" "" 16 "$REPLACER_ID" >/dev/null 2>&1
}
peer_ssh() {
    local c="$2" nm
    printf '%s\n' "$c" >> "$PCALLS"
    case "$c" in
        "uname -m") echo x86_64;;
        *"omnitunnel.sh _peercreate "*) eval "set -- ${c#*omnitunnel.sh _peercreate }"; omni_in "$FOREIGN" _peercreate "$@";;
        *"omnitunnel.sh _remove_own "*) eval "set -- ${c#*omnitunnel.sh _remove_own }"; omni_in "$FOREIGN" _remove_own "$@";;
        *"^LANES="*)
            if [[ "$MODE" == relanesame && ! -e "$REPLFLAG" ]]; then touch "$REPLFLAG"; replace_samelane; fi
            nm="$(inst_nm "$c")"; grep -m1 -E '^LANES=' "$FOREIGN/$nm/instance.conf" 2>/dev/null || true;;
        *"^CREATE_ID="*)
            nm="$(inst_nm "$c")"
            if [[ -e "$FOREIGN/$nm/instance.conf" ]]; then echo OMNIPRESENT; grep -m1 '^CREATE_ID=' "$FOREIGN/$nm/instance.conf" || true; else echo OMNIABSENT; fi;;
        *) :;;
    esac
}
prov_stripe() {
    ( provision_peer 203.0.113.9 "$1" stripe 203.0.113.9 1.2.3.4 41000 "$K" 10.201.4.2 10.201.4.1 none 16 "" 16 ) 2>&1
}
prov_tcp() {
    ( provision_peer 203.0.113.9 "$1" tcp 203.0.113.9 1.2.3.4 41000 "$K" 10.201.4.2 10.201.4.1 none 16 "" 1 ) 2>&1
}
no_unconditional_remove() { ! grep -qE "omnitunnel\.sh _remove '" "$PCALLS"; }
foreign_cid() { grep -m1 '^CREATE_ID=' "$FOREIGN/$1/instance.conf" 2>/dev/null | cut -d= -f2; }

ctrl_stripe() {
    local rc out
    relay_env ctl_s "" x
    rc=0; out="$(prov_stripe x)" || rc=$?
    [[ $rc -eq 0 ]] || fail "control stripe: a normal provision (no replacement) was rejected: $out"
    [[ -e "$FOREIGN/x/instance.conf" ]] || fail "control stripe: the foreign side is missing after a successful provision"
    local cid; cid="$(foreign_cid x)"
    create_id_ok "$cid" || fail "control stripe: foreign has no valid CREATE_ID after provision"
    [[ "$cid" != "$REPLACER_ID" ]] || fail "control stripe: foreign unexpectedly carries the replacer id"
    grep -qE "omnitunnel\.sh _peercreate 'x' 'stripe' server .* '16' '$cid'\$" "$PCALLS" || fail "control stripe: the run's own CREATE_ID was not the 15th _peercreate argument"
}
ctrl_tcp() {
    local rc out
    relay_env ctl_t "" x
    rc=0; out="$(prov_tcp x)" || rc=$?
    [[ $rc -eq 0 ]] || fail "control tcp (non-stripe): a normal provision was rejected: $out"
    [[ -e "$FOREIGN/x/instance.conf" ]] || fail "control tcp: the foreign side is missing after a successful provision"
    create_id_ok "$(foreign_cid x)" || fail "control tcp: foreign has no valid CREATE_ID after provision"
}
samelane_once() {
    local tag="$1" rc out rid
    relay_env "$tag" relanesame x
    rc=0; out="$(prov_stripe x)" || rc=$?
    [[ $rc -ne 0 ]] || fail "$tag: provision_peer accepted a same-lane replacement of the foreign - the near side would be built against another run's key/port"
    [[ "$out" == *"creation id"* || "$out" == *"another run"* ]] || fail "$tag: the abort message does not explain the creation-id mismatch: $out"
    [[ "$out" != *"was removed"* ]] || fail "$tag: the message wrongly claims the replacing run's foreign side was removed: $out"
    rid="$(foreign_cid x)"
    [[ "$rid" == "$REPLACER_ID" ]] || fail "$tag: the replacing run's foreign instance was removed or changed (CREATE_ID now '$rid')"
    no_unconditional_remove || fail "$tag: provision_peer ran the unconditional _remove against the replacing run's instance"
}

ctrl_stripe
ctrl_tcp
for ((i=0; i<ITER; i++)); do samelane_once "sl$i"; done

echo "PASSED - provision_peer verifies the foreign's CREATE_ID before the near side is built: a normal provision still succeeds (stripe and non-stripe), and $ITER same-lane replacements of the foreign between _peercreate and the near-side build are each aborted, the replacing run's instance left intact, with no unconditional _remove"
