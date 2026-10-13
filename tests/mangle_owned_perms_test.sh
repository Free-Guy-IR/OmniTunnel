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

eval "$(extract "with_mangle_lock mss_clamp_add")"

umask 000

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
RUN_DIR="$WORK/run"
STATE="$WORK/state"; mkdir -p "$STATE"

nft_mangle_state() { local n; n="$(cat "$STATE/phase" 2>/dev/null || echo before)"; cat "$STATE/$n" 2>/dev/null || true; }
mss_clamp_rules() { echo after > "$STATE/phase"; }
modeof() { stat -c '%a' "$1" 2>/dev/null; }
reset() { rm -rf "$RUN_DIR" "${STATE:?}"/*; echo before > "$STATE/phase"; }

reset
: > "$STATE/before"
printf 'table 42 bare\n' > "$STATE/after"
with_mangle_lock mss_clamp_add omnidummy0 || fail "H9/A: with_mangle_lock mss_clamp_add failed"
[[ -f "$RUN_DIR/mangle.owned" ]] || fail "H9/A: ownership record was not written"
grep -qx 'table 42' "$RUN_DIR/mangle.owned" || fail "H9/A: ownership record content wrong: [$(cat "$RUN_DIR/mangle.owned")]"
[[ "$(modeof "$RUN_DIR/mangle.owned")" == 600 ]] || fail "H9/A: mangle.owned is $(modeof "$RUN_DIR/mangle.owned"), want 600 (world-writable under a permissive umask)"
[[ "$(modeof "$RUN_DIR/mangle.lock")" == 600 ]] || fail "H9/A: mangle.lock is $(modeof "$RUN_DIR/mangle.lock"), want 600"
[[ "$(modeof "$RUN_DIR")" == 700 ]] || fail "H9/A: $RUN_DIR is $(modeof "$RUN_DIR"), want 700"
pass "H9: table-record ownership file, lock, and run dir are not world-writable (umask 000)"

reset
printf 'table 99 used\n' > "$STATE/before"
printf 'table 99 used\nchain FORWARD 7 empty\n' > "$STATE/after"
with_mangle_lock mss_clamp_add omnidummy1 || fail "H9/B: with_mangle_lock mss_clamp_add failed"
[[ -f "$RUN_DIR/mangle.owned" ]] || fail "H9/B: chain ownership record was not written"
grep -qx 'chain 99 FORWARD 7' "$RUN_DIR/mangle.owned" || fail "H9/B: chain record wrong: [$(cat "$RUN_DIR/mangle.owned")]"
[[ "$(modeof "$RUN_DIR/mangle.owned")" == 600 ]] || fail "H9/B: mangle.owned (append path) is $(modeof "$RUN_DIR/mangle.owned"), want 600"
pass "H9: chain-record ownership file written via append is not world-writable (umask 000)"

echo "PASSED - $PASS mangle ownership perms cases"
