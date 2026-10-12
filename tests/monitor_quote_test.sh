#!/bin/bash
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
MON="$here/../scripts/monitor.sh"
MONPY="$here/../scripts/monitor_legacy.py"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export OMNITUN_INST_DIR="$tmp/inst"
export OMNITUN_RUN_DIR="$tmp/run"
mkdir -p "$OMNITUN_INST_DIR/q" "$OMNITUN_RUN_DIR"
printf 'TYPE="icmp"\nDEV="ts-ok"\n' > "$OMNITUN_INST_DIR/q/instance.conf"

fails=0
pass() { echo "ok: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails+1)); }

if [[ -f "$MON" ]]; then
    out="$(bash "$MON" stats q 2>&1)"
    [[ "$out" == *"dev=ts-ok"* ]] && pass "monitor.sh strips surrounding quotes from DEV" || fail "monitor.sh strips quotes from DEV (got: $out)"
    [[ "$out" != *'dev="ts-ok"'* ]] && pass "monitor.sh does not keep the DEV quotes" || fail "monitor.sh kept the DEV quotes"
    [[ "$out" == *"type=icmp"* ]] && pass "monitor.sh strips surrounding quotes from TYPE" || fail "monitor.sh strips quotes from TYPE (got: $out)"
else
    echo "SKIP monitor_quote_test monitor.sh: missing"
fi

if [[ -f "$MONPY" ]]; then
    out="$(python3 "$MONPY" --json q 2>&1)"
    [[ "$out" == *'"dev": "ts-ok"'* ]] && pass "monitor_legacy.py strips surrounding quotes from DEV" || fail "monitor_legacy.py strips quotes from DEV (got: $out)"
    [[ "$out" == *'"type": "icmp"'* ]] && pass "monitor_legacy.py strips surrounding quotes from TYPE" || fail "monitor_legacy.py strips quotes from TYPE (got: $out)"
else
    echo "SKIP monitor_quote_test monitor_legacy.py: missing"
fi

if [[ "$fails" -ne 0 ]]; then echo "monitor_quote_test: $fails failure(s)"; exit 1; fi
echo "monitor_quote_test PASS"
