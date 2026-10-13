#!/usr/bin/env bash
set -u

SCRIPT="${1:-$(dirname "$0")/../omnitunnel.sh}"
SCRIPT="$(cd "$(dirname "$SCRIPT")" && pwd)/$(basename "$SCRIPT")"

fail() { echo "FAIL: $*" >&2; exit 1; }
PASS=0
pass() { PASS=$((PASS+1)); echo "ok - $1"; }

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

eval "$(extract "ssh_kh_name _hostkey_opts")"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
BIN="$WORK/bin"; mkdir -p "$BIN"
export OMNI_T_SSHG="$WORK/sshg"
cat > "$BIN/ssh" <<'FAKE'
#!/usr/bin/env bash
if [[ "${1:-}" == -G ]]; then
    m="$(cat "${OMNI_T_SSHG:-/dev/null}" 2>/dev/null || echo 22)"
    [[ "$m" == FAIL ]] && exit 3
    printf 'port %s\n' "$m"
    exit 0
fi
exit 0
FAKE
printf '#!/usr/bin/env bash\nexit 1\n' > "$BIN/ssh-keygen"
chmod +x "$BIN/ssh" "$BIN/ssh-keygen"
PATH="$BIN:$PATH"

# shellcheck disable=SC2034
SSH_OPTS=(-o BatchMode=yes)
# shellcheck disable=SC2034
PEER_USER=root
SSH_KH_DIR="$WORK/kh"; mkdir -p "$SSH_KH_DIR"
SSH_KNOWN_HOSTS="$SSH_KH_DIR/known_hosts"; : > "$SSH_KNOWN_HOSTS"
ssh_accept_new_ok() { return 1; }
die_loud() { echo "DIE_LOUD: $*" >&2; exit 44; }
die() { echo "DIE: $*" >&2; exit 45; }

echo 22 > "$OMNI_T_SSHG"
out="$(ssh_kh_name myhost)"; rc=$?
[[ $rc -eq 0 && "$out" == myhost ]] || fail "D2: port-22 should resolve to the bare host (rc=$rc out='$out')"
pass "D2: ssh -G ok, port 22 -> bare host"

echo 2222 > "$OMNI_T_SSHG"
out="$(ssh_kh_name myhost)"; rc=$?
[[ $rc -eq 0 && "$out" == '[myhost]:2222' ]] || fail "D2: non-22 port should resolve to [host]:port (rc=$rc out='$out')"
pass "D2: ssh -G ok, non-22 port -> [host]:port"

echo FAIL > "$OMNI_T_SSHG"
out="$(ssh_kh_name myhost)"; rc=$?
[[ $rc -ne 0 ]] || fail "D2: ssh_kh_name masked an 'ssh -G' failure and returned success with target '$out' (must fail closed)"
[[ -z "$out" ]] || fail "D2: ssh_kh_name emitted target '$out' although 'ssh -G' failed (must act on nothing)"
pass "D2: ssh -G failure -> ssh_kh_name fails closed (nonzero, no target)"

echo FAIL > "$OMNI_T_SSHG"
probe() { ( HOSTKEY_OPTS=(); _hostkey_opts myhost || exit $?; printf 'OPTS:%s\n' "${HOSTKEY_OPTS[*]}" ); }
res="$(probe 2>/dev/null)"; rc=$?
if [[ $rc -eq 0 && "$res" == *"StrictHostKeyChecking=no"* ]]; then
    fail "D2: _hostkey_opts fell through to StrictHostKeyChecking=no after 'ssh -G' failed (removal/teardown would act on an unverified target)"
fi
[[ $rc -ne 0 ]] || fail "D2: _hostkey_opts did not fail closed after an 'ssh -G' failure (rc=$rc res='$res')"
pass "D2: ssh -G failure -> _hostkey_opts fails closed (no StrictHostKeyChecking=no on a wrong target)"

echo "PASSED - $PASS D2 ssh -G fail-closed cases"
