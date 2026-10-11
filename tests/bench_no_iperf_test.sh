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

eval "$(extract "bench_run cmd_bench_manual")"

fail() { echo "FAIL: $1" >&2; exit 1; }

D="$(mktemp -d)"
trap 'rm -rf "$D"' EXIT
BIN="$D/bin"; mkdir -p "$BIN"
printf '#!/bin/sh\nexit 1\n' > "$BIN/apt-get"
printf '#!/bin/sh\nexit 1\n' > "$BIN/yum"
chmod +x "$BIN/apt-get" "$BIN/yum"
PATH="$BIN:$PATH"

need_root() { :; }
ensure_binary() { :; }
save_peer() { :; }
guard_peer_downgrade() { :; }
default_local_ip() { echo 10.0.0.9; }
warn() { echo "WARN: $*"; }
info() { echo "INFO: $*"; }
ok() { echo "OK: $*"; }
die() { echo "UNEXPECTED_DIE: $*"; exit 42; }
peer_ssh() { return 1; }
command() { if [[ "${1:-}" == "-v" && "${2:-}" == "iperf3" ]]; then return 1; fi; builtin command "$@"; }

printf '203.0.113.9\nroot\n\n\n\n' > "$D/in"

rc1=0
bench_run < "$D/in" > "$D/out1" 2>&1 || rc1=$?
echo "REACHED_AFTER_BENCH_RUN rc=$rc1"
[[ "$rc1" -eq 1 ]] || fail "bench_run must return 1 when local iperf3 is missing (got $rc1)"
grep -q "iperf3 is missing on THIS box" "$D/out1" || fail "bench_run must print the loud missing-iperf3 message"
if grep -q "Benchmarking each tunnel" "$D/out1"; then fail "bench_run must NOT emit the benchmark table / transport rows when iperf3 is missing"; fi

rc2=0
cmd_bench_manual 203.0.113.9 10.0.0.9 < /dev/null > "$D/out2" 2>&1 || rc2=$?
echo "REACHED_AFTER_BENCH_MANUAL rc=$rc2"
[[ "$rc2" -eq 1 ]] || fail "cmd_bench_manual must return 1 when local iperf3 is missing (got $rc2)"
grep -q "iperf3 is missing on THIS box" "$D/out2" || fail "cmd_bench_manual must print the loud missing-iperf3 message"
if grep -q "Measuring each tunnel" "$D/out2"; then fail "cmd_bench_manual must NOT emit the benchmark table / transport rows when iperf3 is missing"; fi

echo "PASSED - with iperf3 missing on this box, bench_run and cmd_bench_manual print a loud message and return 1 (no transport rows emitted, caller not terminated)"
