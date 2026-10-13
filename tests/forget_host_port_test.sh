#!/usr/bin/env bash
set -u

SCRIPT="${1:-$(dirname "$0")/../omnitunnel.sh}"

for c in ssh ssh-keygen; do
    command -v "$c" >/dev/null 2>&1 || { echo "SKIP forget_host_port_test: $c missing"; exit 0; }
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
exec "$REAL_SSH" -F /dev/null \${FH_SSH_PORT:+-p "\$FH_SSH_PORT"} "\$@"
SHIM
chmod 755 "$D/bin/ssh"
export PATH="$D/bin:$PATH"

for k in a b c d; do ssh-keygen -q -t ed25519 -N '' -C "fh-$k" -f "$D/key_$k"; done
key() { awk '{print $2}' "$D/key_$1.pub"; }

seed() {
    local h="$1"
    {
        printf '%s ssh-ed25519 %s\n' "$h" "$(key a)"
        printf '[%s]:2222 ssh-ed25519 %s\n' "$h" "$(key b)"
        printf '[%s]:2200 ssh-ed25519 %s\n' "$h" "$(key c)"
        printf 'other.example.net ssh-ed25519 %s\n' "$(key d)"
        printf '[other.example.net]:2222 ssh-ed25519 %s\n' "$(key d)"
    } > "$KH"
    chmod 600 "$KH"
}
pinned() { ssh-keygen -F "$1" -f "$KH" >/dev/null 2>&1; }

state() {
    local h="$1" n s=""
    for n in "$h" "[$h]:2222" "[$h]:2200" other.example.net "[other.example.net]:2222"; do
        if pinned "$n"; then s+="$n=pinned "; else s+="$n=gone "; fi
    done
    printf '%s' "${s% }"
}
want_state() {
    local h="$1" g22="$2" g2222="$3"
    printf '%s=%s [%s]:2222=%s [%s]:2200=pinned other.example.net=pinned [other.example.net]:2222=pinned' \
        "$h" "$g22" "$h" "$g2222" "$h"
}

check() {
    local label="$1" h="$2" g22="$3" g2222="$4" rc_want="$5"; shift 5
    local out rc got want
    seed "$h"
    out="$( (cmd_forget_host "$@") 2>&1 )"; rc=$?
    got="$(state "$h")"; want="$(want_state "$h" "$g22" "$g2222")"
    if [[ "$rc" == "$rc_want" && "$got" == "$want" ]]; then pass "$label"
    else fail "$label: rc=$rc (want $rc_want)"$'\n'"    got:  $got"$'\n'"    want: $want"$'\n'"    out:  $out"; fi
    if [[ "$(stat -c %a "$KH" 2>/dev/null)" != 600 ]]; then fail "$label: known_hosts mode is $(stat -c %a "$KH" 2>&1), want 600"; fi
    LAST_OUT="$out"
}

for H in fx.example.net 192.0.2.10 2001:db8::7; do
    check "$H: forget-host $H 2222 removes only [$H]:2222" "$H" pinned gone 0 "$H" 2222
    check "$H: forget-host '[$H]:2222' removes only [$H]:2222" "$H" pinned gone 0 "[$H]:2222"
    check "$H: forget-host $H 22 removes only $H" "$H" gone pinned 0 "$H" 22
    check "$H: forget-host $H removes only $H when ssh resolves port 22" "$H" gone pinned 0 "$H"
    FH_SSH_PORT=2222 check "$H: forget-host $H also removes the ssh-configured port alias [$H]:2222" "$H" gone gone 0 "$H"
    check "$H: forget-host $H 3333 (no pin) removes nothing" "$H" pinned pinned 0 "$H" 3333
    if [[ "$LAST_OUT" == *"no pinned SSH host key for $H port 3333"* ]]; then pass "$H: an unknown port reports nothing to forget"
    else fail "$H: unknown port did not report 'no pinned SSH host key for $H port 3333', got: $LAST_OUT"; fi
done

seed fx.example.net
(cmd_forget_host fx.example.net 2222) >/dev/null 2>&1
out="$( (cmd_forget_host fx.example.net 2222) 2>&1 )"; rc=$?
if [[ $rc -eq 0 && "$out" == *"no pinned SSH host key for fx.example.net port 2222"* ]] && pinned fx.example.net; then
    pass "repeat: a second forget-host for the same port forgets nothing and keeps the port-22 pin"
else
    fail "repeat: second forget-host fx.example.net 2222 (rc=$rc, port-22 pin $(pinned fx.example.net && echo kept || echo LOST)): $out"
fi

seed fx.example.net
out="$( (cmd_forget_host fx.example.net 2222) 2>&1 )"
forgot="$(printf '%s\n' "$out" | grep -o 'forgot the pinned SSH host key for .*' | sed 's/\x1b\[[0-9;]*m//g')"
if [[ "$forgot" == "forgot the pinned SSH host key for [fx.example.net]:2222" ]]; then
    pass "message: forget-host reports only the [host]:port entry it removed"
else
    fail "message: forget-host fx.example.net 2222 reported: $forgot"
fi

bad=0
for p in 0 70000 "22;id" "-1" "2x" "022"; do
    seed fx.example.net
    ( cmd_forget_host fx.example.net "$p" ) >/dev/null 2>&1 && { bad=1; echo "  accepted bad port: [$p]" >&2; }
    [[ "$(state fx.example.net)" == "$(want_state fx.example.net pinned pinned)" ]] || { bad=1; echo "  bad port [$p] changed the pins" >&2; }
done
if [[ "$bad" == 0 ]]; then pass "validation: invalid ports are rejected and remove nothing"
else fail "validation: an invalid port was accepted or changed the pins"; fi

echo
if [[ "$FAILS" -ne 0 ]]; then
    echo "FAILED - forget_host_port_test: $FAILS failure(s), $PASSES check(s) passed"
    exit 1
fi
echo "PASSED - forget_host_port_test: $PASSES checks - forget-host <host> <port> removes only that port's pin, <host> / <host> 22 remove only the default-port pin (plus the ssh-configured alias), [host]:port equals <host> <port>, unknown ports remove nothing"
