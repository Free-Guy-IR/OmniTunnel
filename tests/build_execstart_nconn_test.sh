#!/usr/bin/env bash
set -u

SCRIPT="${1:-$(dirname "$0")/../omnitunnel.sh}"
REPO="$(cd "$(dirname "$SCRIPT")" && pwd)"
REF_REV=89c9c61

extract_funcs() {
    grep -E '^(type_uses_key|tok_re)\(\)' "$SCRIPT"
    awk '/^build_execstart\(\) \{/{f=1} f{print} f&&/^\}/{f=0}' "$SCRIPT"
}

eval "$(extract_funcs)"
eval "$(grep -m1 '^ALL_TYPES=' "$SCRIPT")"
SET_LINE="$(grep -m1 -E '^set -' "$SCRIPT")"

v2911_build_execstart() {
    local sflag=""; [[ "$ROLE" == "server" ]] && sflag=" -s"
    if type_uses_key "$TYPE" && [[ -z "$KEY" ]]; then
        echo "build_execstart: $TYPE requires a non-empty PSK but KEY is empty; refusing" >&2
        return 1
    fi
    case "$TYPE" in
        udp)  echo "$TSUITE_BIN udp -L $LOCAL_IP -R $PEER_IP -A $TUN_ADDR -P $PEER_ADDR -p $PORT -k $KEY -T $DEV -M $MTU";;
        tcp)  echo "$TSUITE_BIN tcp -L $LOCAL_IP -R $PEER_IP -A $TUN_ADDR -P $PEER_ADDR -p $PORT -k $KEY$sflag -T $DEV -M $MTU";;
        mux)  echo "$TSUITE_BIN mux -L $LOCAL_IP -R $PEER_IP -A $TUN_ADDR -P $PEER_ADDR -p $PORT -k $KEY$sflag -N $NCONN -T $DEV -M $MTU";;
        ws)   echo "$TSUITE_BIN ws -L $LOCAL_IP -R $PEER_IP -A $TUN_ADDR -P $PEER_ADDR -p $PORT -k $KEY$sflag -N $NCONN -T $DEV -M $MTU";;
        icmp) echo "$TSUITE_BIN icmp -L $LOCAL_IP -R $PEER_IP -A $TUN_ADDR -P $PEER_ADDR -I 4d54 -T $DEV -M $MTU$sflag${ICMP_MODE:+ -r $ICMP_MODE}";;
        reverse-mux) echo "$TSUITE_BIN icmp -L $LOCAL_IP -R $PEER_IP -A $TUN_ADDR -P $PEER_ADDR -I 4d54 -T $DEV -M $MTU$sflag -r ${ICMP_MODE:-reply}";;
        stripe) echo "$OMNISTRIPE_BIN -L $LOCAL_IP -R $PEER_IP -A $TUN_ADDR -P $PEER_ADDR -k $KEY -p $PORT -C ${PCOUNT:-400} -N $NCONN -T $DEV -M $MTU$sflag";;
        ackless) echo "$OMNIACKLESS_BIN -L $LOCAL_IP -R $PEER_IP -A $TUN_ADDR -P $PEER_ADDR -k $KEY -p $PORT -T $DEV -M $MTU$sflag";;
    esac
}

fail() { echo "FAIL: $1" >&2; exit 1; }
FAILS=0
bad() { echo "FAIL: $1" >&2; FAILS=$((FAILS + 1)); }

[[ "$SET_LINE" == "set -"* ]] || fail "could not read the shell options line of $SCRIPT"
declare -F build_execstart >/dev/null || fail "build_execstart was not extracted from $SCRIPT"
read -ra TYPES <<< "$ALL_TYPES"
(( ${#TYPES[@]} == 12 )) || fail "expected 12 transports in ALL_TYPES, got ${#TYPES[@]}: $ALL_TYPES"
[[ " $ALL_TYPES " == *" stripe "* ]] || fail "stripe is missing from ALL_TYPES: $ALL_TYPES"

REF_SOURCE="embedded copy of $REF_REV build_execstart"
REF_SRC="$(git -C "$REPO" show "$REF_REV:omnitunnel.sh" 2>/dev/null | awk '/^build_execstart\(\) \{/{f=1} f{print} f&&/^\}/{f=0}')"
if [[ -n "$REF_SRC" ]]; then
    eval "git_ref_$REF_SRC"
    [[ "$(declare -f git_ref_build_execstart | tail -n +2)" == "$(declare -f v2911_build_execstart | tail -n +2)" ]] \
        || fail "the embedded v2.9.11 reference differs from build_execstart at $REF_REV"
    REF_SOURCE="git $REF_REV build_execstart"
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
OUTF="$WORK/out"; ERRF="$WORK/err"; PWN="$WORK/pwned"

TSUITE_BIN=/opt/omnitunnel/omnitun
OMNISTRIPE_BIN=/opt/omnitunnel/omnistripe
OMNIACKLESS_BIN=/opt/omnitunnel/omniackless
K="$(printf 'a%.0s' {1..64})"

CASES=(
    "16|512"
    "08|512"
    "0900|900"
    "512|512"
    "16384|16384"
    "|512"
    "abc|512"
    "0|512"
    "513|513"
    "0000000000000900|900"
    "99999999999999999999|512"
    "x[\$(touch $PWN)]|512"
)

set_inputs() {
    LOCAL_IP=1.2.3.4; PEER_IP=203.0.113.9; TUN_ADDR=10.201.9.1; PEER_ADDR=10.201.9.2
    PORT=49000; DEV=tsx9; MTU=1400; PCOUNT=400; LANES=16; KEY="$K"
    TYPE="$1"; ROLE="$2"; ICMP_MODE="$3"; NCONN="$4"
}

run_under_script_opts() {
    ( eval "$SET_LINE"; "$1" ) >"$OUTF" 2>"$ERRF"
}

checked=0; stripe_checked=0
for T in "${TYPES[@]}"; do
    for R in client server; do
        for M in "" request; do
            for c in "${CASES[@]}"; do
                nc="${c%|*}"; want_n="${c##*|}"
                label="type=$T role=$R mode=${M:-none} NCONN='$nc'"
                set_inputs "$T" "$R" "$M" "$nc"
                if ! run_under_script_opts build_execstart; then
                    bad "$label: build_execstart aborted under '$SET_LINE': $(tr '\n' ' ' < "$ERRF")"
                    continue
                fi
                out="$(cat "$OUTF")"
                [[ -s "$ERRF" ]] && bad "$label: build_execstart wrote to stderr: $(tr '\n' ' ' < "$ERRF")"
                if [[ "$T" == stripe ]]; then
                    sflag=""; [[ "$R" == server ]] && sflag=" -s"
                    want="$OMNISTRIPE_BIN -L 1.2.3.4 -R 203.0.113.9 -A 10.201.9.1 -P 10.201.9.2 -k $K -p 49000 -C 400 -N $want_n -lanes $LANES -w $((want_n * 2)) -to 1500 -F -T tsx9 -M 1400$sflag"
                    [[ "$out" == "$want" ]] || bad "$label: stripe line is not base-10 -N $want_n -w $((want_n * 2)): $out"
                    stripe_checked=$((stripe_checked + 1))
                else
                    run_under_script_opts v2911_build_execstart || fail "$label: the v2.9.11 reference itself failed"
                    ref="$(cat "$OUTF")"
                    [[ "$out" == "$ref" ]] || bad "$label: differs from v2.9.11 output: got [$out] want [$ref]"
                fi
                checked=$((checked + 1))
            done
        done
    done
done

[[ -e "$PWN" ]] && bad "a stored NCONN value was evaluated as an arithmetic expression and ran a command"
(( stripe_checked == 4 * ${#CASES[@]} )) || bad "expected $((4 * ${#CASES[@]})) stripe cases, checked $stripe_checked"
(( checked == 12 * 4 * ${#CASES[@]} )) || bad "expected $((12 * 4 * ${#CASES[@]})) cases, checked $checked"

if (( FAILS > 0 )); then
    echo "FAILED - build_execstart_nconn_test: $FAILS failure(s) in $checked cases" >&2
    exit 1
fi
echo "PASSED - build_execstart_nconn_test: $checked cases, all 12 transports build under '$SET_LINE' for every stored NCONN; non-stripe lines equal $REF_SOURCE; stripe -N/-w read as base 10 with the 512 floor"
