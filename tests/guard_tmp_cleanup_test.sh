#!/usr/bin/env bash
set -u

SCRIPT="${1:-$(dirname "$0")/../omnitunnel.sh}"

for c in ssh-keygen mktemp; do
    command -v "$c" >/dev/null 2>&1 || { echo "SKIP guard_tmp_cleanup_test: $c missing"; exit 0; }
done

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
KILL_PIDS=()
cleanup() {
    local p
    for p in ${KILL_PIDS[@]+"${KILL_PIDS[@]}"}; do kill "$p" 2>/dev/null; done
    rm -rf "$D"
}
trap cleanup EXIT

{
    cat <<'VARS'
ROOT_DIR="$GT_ROOT"
INST_DIR="$ROOT_DIR/inst"
PEER_DIR="$ROOT_DIR/peers"
VERSION=0.0.1
SCRIPT_PATH=/nonexistent
OMNI_ARGV=()
VARS
    grep -E '^[CG]_[A-Z_]+=' "$SCRIPT"
    grep -E '^(SSH_KH_DIR|SSH_KNOWN_HOSTS|SSH_OPTS|SSH_KH_LOCK_WAIT|OMNI_TMP_FILES)=' "$SCRIPT"
    extract "need_root die ok info warn tok_re tok_host_ok tok_port_ok peer_conf _peer_creds _proxy_opts peer_ssh ssh_kh_init ssh_accept_new_ok ssh_kh_name _hostkey_opts _hostkey_unlock die_loud tmp_track tmp_cleanup _peer_run hostkey_abort ver_gt guard_peer_downgrade"
} > "$D/lib.sh"

cat > "$D/run_guard.sh" <<'RUN'
#!/bin/bash
set -euo pipefail
. "$GT_D/lib.sh"
exec {OMNI_ERR_FD}>&2
cmd_update() { touch "$GT_D/update_called"; return 1; }
[[ -z "${GT_PRETRAP:-}" ]] || trap 'echo pre-trap-ran' EXIT
guard_peer_downgrade 127.0.0.1
echo "trap-after:[$(trap -p EXIT)]"
echo after-guard
RUN

mkdir -p "$D/bin"
cat > "$D/bin/ssh" <<'SHIM'
#!/bin/bash
for a in "$@"; do
    if [[ -n "${GT_OLD:-}" && "$a" == *StrictHostKeyChecking=accept-new* ]]; then
        echo 'command-line line 0: Bad yes/no/ask argument.' >&2; exit 255
    fi
    [[ "$a" == -V ]] && exit 0
    [[ "$a" == -G ]] && { printf 'user root\nhostname 127.0.0.1\nport 22\n'; exit 0; }
done
banner() {
    cat >&2 <<'TXT'
@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @
@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
IT IS POSSIBLE THAT SOMEONE IS DOING SOMETHING NASTY!
The fingerprint for the ED25519 key sent by the remote host is
SHA256:Gt0kVGuardTmpCleanupTestFingerprintAAAAAAAAAA.
TXT
}
case "${GT_MODE:-fresh}" in
    changed) banner; echo 'Host key verification failed.' >&2; exit 255;;
    warned)  banner; echo 'Password authentication is disabled to avoid man-in-the-middle attacks.' >&2; echo 0.0.1; exit 0;;
    fresh)   exit 1;;
    same)    echo 0.0.1; exit 0;;
    hang)    echo "$$" > "$GT_D/hang.pid"; exec sleep 30;;
esac
exit 1
SHIM
chmod 755 "$D/bin/ssh" "$D/run_guard.sh"
BASE_PATH="$PATH"

CASE_N=0
new_case() {
    CASE_N=$((CASE_N+1))
    CT="$D/case$CASE_N"; mkdir -p "$CT/tmp" "$CT/root"; chmod 700 "$CT/tmp"
}
run_case() {
    env GT_D="$D" GT_ROOT="$CT/root" TMPDIR="$CT/tmp" PATH="$D/bin:$BASE_PATH" "$@" \
        bash "$D/run_guard.sh" >"$CT/out" 2>"$CT/err" </dev/null
}
leftovers() { find "$CT/tmp" -mindepth 1 2>/dev/null | sed "s|^$CT/tmp/||" | tr '\n' ' '; }
lock_path() { printf '%s/ssh/.first-contact.lock' "$CT/root"; }

check_abort() {
    local label="$1" want_msg="$2" rc="$3" left
    left="$(leftovers)"
    if [[ $rc -ne 0 ]] && ! grep -q after-guard "$CT/out"; then pass "$label: the run stops at the version check (rc=$rc)"
    else fail "$label: the run went on after the version check (rc=$rc): $(cat "$CT/out")"; fi
    if [[ -z "$left" ]]; then pass "$label: no temp file left in TMPDIR"
    else fail "$label: temp files left behind in TMPDIR: $left"; fi
    if grep -qF -- "$want_msg" "$CT/err"; then pass "$label: the operator sees '$want_msg'"
    else fail "$label: missing '$want_msg' in: $(cat "$CT/err")"; fi
}
check_normal() {
    local label="$1" rc="$2" want_trap="$3" left
    left="$(leftovers)"
    if [[ $rc -eq 0 ]] && grep -q after-guard "$CT/out"; then pass "$label: the version check returns and the run continues"
    else fail "$label: guard did not return normally (rc=$rc): $(cat "$CT/out" "$CT/err")"; fi
    if [[ -z "$left" ]]; then pass "$label: no temp file left in TMPDIR"
    else fail "$label: temp files left behind in TMPDIR: $left"; fi
    if grep -qxF "trap-after:[$want_trap]" "$CT/out"; then pass "$label: the caller's EXIT trap is as before the check"
    else fail "$label: EXIT trap after the check is $(grep trap-after "$CT/out"), want [$want_trap]"; fi
}

new_case; rc=0; run_case GT_MODE=changed || rc=$?
check_abort "abort (ssh refused the changed key)" "forget-host 127.0.0.1" "$rc"
new_case; rc=0; run_case GT_MODE=warned || rc=$?
check_abort "abort (pre-7.6 ssh warned and went on)" "forget-host 127.0.0.1" "$rc"
[[ ! -e "$D/update_called" ]] || fail "abort: a changed key must not trigger a self-update"

new_case; rc=0; run_case GT_MODE=fresh || rc=$?
check_normal "normal (foreign has no OmniTunnel yet)" "$rc" ""
new_case; rc=0; run_case GT_MODE=same || rc=$?
check_normal "normal (foreign runs the same version)" "$rc" ""
new_case; rc=0; run_case GT_MODE=fresh GT_PRETRAP=1 || rc=$?
check_normal "normal (caller already had an EXIT trap)" "$rc" "trap -- 'echo pre-trap-ran' EXIT"
if [[ "$(tail -n1 "$CT/out")" == pre-trap-ran ]]; then pass "normal: the caller's own EXIT trap still runs at exit"
else fail "normal: the caller's EXIT trap did not run at exit: $(cat "$CT/out")"; fi

new_case; : > "$CT/root/ssh"; rc=0; run_case GT_MODE=same || rc=$?
check_abort "die (pinned-keys dir cannot be prepared)" "cannot prepare the pinned SSH host keys file" "$rc"

new_case; mkdir -p "$(lock_path)"; rc=0; run_case GT_MODE=fresh GT_OLD=1 || rc=$?
check_abort "die (pre-7.6 ssh, first-contact lock cannot be opened)" "lock" "$rc"

new_case; rm -f "$D/hang.pid"
env GT_D="$D" GT_ROOT="$CT/root" TMPDIR="$CT/tmp" PATH="$D/bin:$BASE_PATH" GT_MODE=hang \
    bash "$D/run_guard.sh" >"$CT/out" 2>"$CT/err" </dev/null &
gpid=$!; KILL_PIDS+=("$gpid")
for _ in $(seq 1 100); do [[ -s "$D/hang.pid" ]] && break; sleep 0.05; done
hpid="$(cat "$D/hang.pid" 2>/dev/null)"; [[ -n "$hpid" ]] && KILL_PIDS+=("$hpid")
during="$(leftovers)"
kill -TERM "$gpid" 2>/dev/null; wait "$gpid" 2>/dev/null
[[ -n "$hpid" ]] && kill "$hpid" 2>/dev/null
KILL_PIDS=()
sleep 0.2
left="$(leftovers)"
if [[ -n "$hpid" && -n "$during" ]]; then pass "SIGTERM: the version check was in flight with its temp file(s) present ($during)"
else fail "SIGTERM: the harness did not catch the version check in flight (hang pid=[$hpid] files=[$during])"; fi
if [[ -z "$left" ]]; then pass "SIGTERM: no temp file left after the run is terminated during the version check"
else fail "SIGTERM: temp files left behind after termination: $left"; fi

echo
if [[ "$FAILS" -ne 0 ]]; then
    echo "FAILED - guard_tmp_cleanup_test: $FAILS failure(s), $PASSES check(s) passed"
    exit 1
fi
echo "PASSED - guard_tmp_cleanup_test: $PASSES checks - the foreign version check leaves no temp file on a host-key abort (refused or warned), on die, on a first-contact lock failure, on SIGTERM, or on the normal path, and restores the caller's EXIT trap"
