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
            if (nm in want) {
                print
                if ($0 !~ /\}/) inblock=1
            }
        }
    }' "$SCRIPT"
}

eval "$(extract "ensure_binary ensure_omnistripe ensure_omniackless type_is_hysteria type_is_stripe type_is_ackless type_is_kernel type_uses_key tok_re lanes_ok inst_name_ok type_known tok_host_ok tok_ipv4_ok tok_port_ok tok_nc_ok tok_hexkey_ok tok_key_ok tok_shape_ok tok_pmode_ok validate_inst_name list_instances cmd_server_token")"
eval "$(grep -m1 '^ALL_TYPES=' "$SCRIPT")"

fail() { echo "FAIL: $1" >&2; exit 1; }

need_root() { :; }
ensure_hysteria() { HY_CALLED=1; }
create_inst() { exit 0; }
inst_enable() { :; }
inst_running() { return 0; }
inst_exists() { return 1; }
svc_name() { echo "omnitun-$1.service"; }
ok() { :; }
warn() { :; }
info() { :; }
arch_tag() { echo amd64; }
die() { echo "DIE: $*"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
INST_DIR="$WORK/inst"; mkdir -p "$INST_DIR"
ASSET_DIR="$WORK/assets"; SCRIPT_DIR="$WORK/sd"; mkdir -p "$ASSET_DIR/bin" "$SCRIPT_DIR/bin"
TSUITE_BIN="$WORK/nonexistent-omnitun"
OMNISTRIPE_BIN="$WORK/omnistripe"; : > "$OMNISTRIPE_BIN"; chmod +x "$OMNISTRIPE_BIN"
OMNIACKLESS_BIN="$WORK/omniackless"; : > "$OMNIACKLESS_BIN"; chmod +x "$OMNIACKLESS_BIN"

KEY64="$(printf 'a%.0s' {1..64})"
mk_token() {
    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s' \
        tname "$1" 203.0.113.9 1.2.3.4 40000 "$KEY64" 10.201.5.2 10.201.5.1 none 16 "" \
        | base64 | tr -d '\n'
}

for T in stripe ackless; do
    out="$(cmd_server_token "$(mk_token "$T")" 2>&1)"; rc=$?
    (( rc == 0 )) || fail "$T: server-token exited $rc on a box with no omnitun core (out: $out)"
    case "$out" in
        *"omnitun"*"not found"*) fail "$T: server-token wrongly demanded the omnitun core binary: $out";;
    esac
done

out="$(cmd_server_token "$(mk_token tcp)" 2>&1)"; rc=$?
(( rc != 0 )) || fail "control: a tcp token did NOT require omnitun - the harness cannot detect the bug"
case "$out" in
    *"omnitun"*"not found"*) :;;
    *) fail "control: tcp token failed for the wrong reason (expected missing omnitun core): $out";;
esac

echo "PASSED - server-token for stripe/ackless uses ensure_omnistripe/ensure_omniackless and does not require the omnitun core (tcp still does)"
