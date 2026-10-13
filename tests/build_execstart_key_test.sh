#!/usr/bin/env bash
set -u

SCRIPT="${1:-$(dirname "$0")/../omnitunnel.sh}"

extract_funcs() {
    grep -E '^(type_uses_key|tok_re)\(\)' "$SCRIPT"
    awk '/^build_execstart\(\) \{/{f=1} f{print} f&&/^\}/{f=0}' "$SCRIPT"
}

eval "$(extract_funcs)"

fail() { echo "FAIL: $1" >&2; exit 1; }

TSUITE_BIN=/opt/omnitunnel/omnitun
OMNISTRIPE_BIN=/opt/omnitunnel/omnistripe
OMNIACKLESS_BIN=/opt/omnitunnel/omniackless
LOCAL_IP=1.2.3.4
PEER_IP=203.0.113.9
TUN_ADDR=10.201.9.1
PEER_ADDR=10.201.9.2
PORT=49000
DEV=tsackless9
MTU=1400
NCONN=16
PCOUNT=400

GOODKEY="$(printf 'a%.0s' {1..64})"

for T in ackless stripe; do
    TYPE="$T"; ROLE=server; KEY=""
    if out="$(build_execstart 2>/dev/null)"; then
        fail "$T: build_execstart accepted an empty PSK and emitted a unit line: $out"
    fi

    TYPE="$T"; ROLE=server; KEY="$GOODKEY"
    out="$(build_execstart)" || fail "$T: build_execstart refused a valid 64-char PSK"
    [[ "$out" == *"-k $GOODKEY"* ]] || fail "$T: -k is not followed by the PSK value: $out"
    [[ "$out" == *" -s"* ]] || fail "$T: server role dropped -s: $out"

    TYPE="$T"; ROLE=client; KEY="$GOODKEY"
    out="$(build_execstart)" || fail "$T: client build_execstart refused a valid PSK"
    [[ "$out" == *"-k $GOODKEY"* ]] || fail "$T: client -k is not followed by the PSK value: $out"
done

echo "PASSED - build_execstart refuses an empty PSK for key transports and keeps -s/-k with a real key"
