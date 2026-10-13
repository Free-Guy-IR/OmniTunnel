#!/usr/bin/env bash
set -u

SCRIPT="${1:-$(dirname "$0")/../omnitunnel.sh}"

for c in ssh ssh-keygen; do
    command -v "$c" >/dev/null 2>&1 || { echo "SKIP hostkeyalias_test: $c missing"; exit 0; }
done
REAL_SSH="$(command -v ssh)"

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

D="$(mktemp -d)"; chmod 700 "$D"
trap 'rm -rf "$D"' EXIT

ROOT_DIR="$D/etc"
eval "$(grep -E '^[CG]_[A-Z_]+=' "$SCRIPT")"
eval "$(grep -E '^(SSH_KH_DIR|SSH_KNOWN_HOSTS|SSH_OPTS)=' "$SCRIPT")"
eval "$(extract "die ok info warn tok_re tok_host_ok tok_port_ok ssh_kh_name cmd_forget_host")"
need_root() { :; }
KH="$SSH_KNOWN_HOSTS"
[[ "$KH" == "$ROOT_DIR/ssh/known_hosts" ]] || { echo "FAIL: SSH_KNOWN_HOSTS is '$KH', want $ROOT_DIR/ssh/known_hosts" >&2; exit 1; }
mkdir -p "$SSH_KH_DIR"; chmod 700 "$SSH_KH_DIR"

mkdir -p "$D/bin"
cat > "$D/bin/ssh" <<SHIM
#!/bin/bash
exec "$REAL_SSH" -F /dev/null \${FH_HK_ALIAS:+-o HostKeyAlias="\$FH_HK_ALIAS"} \${FH_SSH_PORT:+-p "\$FH_SSH_PORT"} "\$@"
SHIM
chmod 755 "$D/bin/ssh"
export PATH="$D/bin:$PATH"

ssh-keygen -q -t ed25519 -N '' -C fh-key -f "$D/key"
KEY="$(awk '{print $2}' "$D/key.pub")"
pinned() { ssh-keygen -F "$1" -f "$KH" >/dev/null 2>&1; }

HOST=fx.example.net
ALIAS=stable-alias.example

eq() { if [[ "$1" == "$2" ]]; then pass "$3"; else fail "$3 (got '$1', want '$2')"; fi; }

eq "$(ssh_kh_name "$HOST")" "$HOST" "no alias: ssh_kh_name returns the host itself"
eq "$(FH_SSH_PORT=2222 ssh_kh_name "$HOST")" "[$HOST]:2222" "no alias, port 2222: ssh_kh_name returns [$HOST]:2222"
eq "$(FH_HK_ALIAS="$ALIAS" ssh_kh_name "$HOST")" "$ALIAS" "alias set: ssh_kh_name returns the HostKeyAlias as the known_hosts name"
eq "$(FH_HK_ALIAS="$ALIAS" FH_SSH_PORT=2222 ssh_kh_name "$HOST")" "$ALIAS" "alias set wins over a non-default port"

printf '%s ssh-ed25519 %s\n' "$ALIAS" "$KEY" > "$KH"; chmod 600 "$KH"
out="$( (FH_HK_ALIAS="$ALIAS" cmd_forget_host "$HOST") 2>&1 )"; rc=$?
if [[ $rc -eq 0 ]] && ! pinned "$ALIAS"; then
    pass "forget-host honors the HostKeyAlias and removes the aliased pin"
else
    fail "forget-host alias: rc=$rc alias still pinned=$(pinned "$ALIAS" && echo yes || echo no): $out"
fi
if [[ "$(stat -c %a "$KH" 2>/dev/null)" == 600 ]]; then pass "forget-host keeps known_hosts mode 600"; else fail "known_hosts mode is $(stat -c %a "$KH" 2>&1), want 600"; fi

printf '%s ssh-ed25519 %s\n' "$ALIAS" "$KEY" > "$KH"; chmod 600 "$KH"
out="$( (FH_HK_ALIAS="$ALIAS" cmd_forget_host "$HOST" 2222) 2>&1 )"; rc=$?
if [[ $rc -eq 0 ]] && ! pinned "$ALIAS"; then
    pass "forget-host honors the HostKeyAlias even when an explicit port is given"
else
    fail "forget-host alias+port: rc=$rc alias still pinned=$(pinned "$ALIAS" && echo yes || echo no): $out"
fi

printf '%s ssh-ed25519 %s\n' "$HOST" "$KEY" > "$KH"; chmod 600 "$KH"
out="$( (cmd_forget_host "$HOST") 2>&1 )"; rc=$?
if [[ $rc -eq 0 ]] && ! pinned "$HOST"; then
    pass "no alias: forget-host still removes the plain host pin"
else
    fail "no alias forget-host: rc=$rc host still pinned=$(pinned "$HOST" && echo yes || echo no): $out"
fi

echo
if [[ "$FAILS" -ne 0 ]]; then
    echo "FAILED - hostkeyalias_test: $FAILS failure(s), $PASSES check(s) passed"
    exit 1
fi
echo "PASSED - hostkeyalias_test: $PASSES checks - ssh_kh_name resolves an effective HostKeyAlias from ssh -G and uses it as the known_hosts name for both the pin lookup and forget-host, while the no-alias host/port behavior is unchanged"
