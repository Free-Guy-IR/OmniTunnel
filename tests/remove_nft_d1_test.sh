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

eval "$(extract "_peer_run")"

TMPDIR="$(mktemp -d)"; export TMPDIR; trap 'rm -rf "$TMPDIR"' EXIT
tmp_track() { :; }
tmp_cleanup() { :; }
_hostkey_unlock() { :; }
hostkey_abort() { echo "HOSTKEY_ABORT" >&2; exit 42; }

emit() { local code="$1"; shift; [[ $# -gt 0 ]] && printf '%s\n' "$@" >&2; return "$code"; }
run_peer() { ( _peer_run myhost "$@" ) >/dev/null 2>&1; echo $?; }

rc="$(run_peer emit 0 'note: REMOTE HOST IDENTIFICATION HAS CHANGED earlier today, ignore')"
[[ "$rc" == 0 ]] || fail "D1: a successful SSH whose stderr merely mentions 'REMOTE HOST IDENTIFICATION HAS CHANGED' false-aborted (rc=$rc)"
pass "D1: benign changed-key substring on a successful command does not abort"

rc="$(run_peer emit 3 'probe: Host key verification failed for a downstream check (informational)')"
[[ "$rc" == 3 ]] || fail "D1: a failing command whose stderr contains a benign 'Host key verification failed' phrase false-aborted (rc=$rc, expected 3)"
pass "D1: benign 'Host key verification failed' phrase on a failing command does not abort"

rc="$(run_peer emit 0 '@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @')"
[[ "$rc" == 42 ]] || fail "D1 regression: the real ssh changed-key WARNING banner must still abort even on rc 0 (rc=$rc)"
pass "D1: the real changed-key WARNING banner still aborts (true positive kept)"

rc="$(run_peer emit 255 'Host key verification failed.')"
[[ "$rc" == 42 ]] || fail "D1 regression: a real 'Host key verification failed.' line on a failed login must still abort (rc=$rc)"
pass "D1: the real 'Host key verification failed.' line still aborts (true positive kept)"

echo "PASSED - $PASS D1 peer-run stderr cases"
