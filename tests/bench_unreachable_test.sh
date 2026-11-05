#!/usr/bin/env bash
set -eu

SCRIPT="${1:-$(dirname "$0")/../omnitunnel.sh}"

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

eval "$(extract "bench_run")"

fail() { echo "FAIL: $1" >&2; exit 1; }

D="$(mktemp -d)"
trap 'rm -rf "$D"' EXIT
BIN="$D/bin"; mkdir -p "$BIN"
printf '#!/bin/sh\nexit 0\n' > "$BIN/apt-get"
printf '#!/bin/sh\nexit 0\n' > "$BIN/yum"
chmod +x "$BIN/apt-get" "$BIN/yum"
PATH="$BIN:$PATH"

need_root() { :; }
ensure_binary() { :; }
save_peer() { :; }
guard_peer_downgrade() { :; }
peer_prepare() { :; }
pkg_install() { return 0; }
pkg_fail_hint() { :; }
default_local_ip() { echo 10.0.0.9; }
warn() { echo "WARN: $*"; }
info() { echo "INFO: $*"; }
ok() { echo "OK: $*"; }
die() { echo "UNEXPECTED_DIE: $*"; exit 42; }
peer_ssh() { return 1; }

printf '203.0.113.9\nroot\n\n\n\n' > "$D/inputs"

rc=0
bench_run < "$D/inputs" || rc=$?
echo "REACHED_AFTER_BENCH rc=$rc"
[[ "$rc" -ne 0 ]] || fail "bench_run must return non-zero when the foreign is unreachable over SSH (got rc=$rc)"
[[ "$rc" -ne 42 ]] || fail "bench_run must not exit via die on an unreachable foreign; it must return to the caller"

echo "PASSED - on an unreachable foreign bench_run returns non-zero and returns to its caller (no exit/die), so the menu stays alive instead of crashing to the shell"
