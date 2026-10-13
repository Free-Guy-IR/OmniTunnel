#!/usr/bin/env bash
set -u

SCRIPT="${1:-$(dirname "$0")/../omnitunnel.sh}"
REPO="$(cd "$(dirname "$SCRIPT")" && pwd)"

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

eval "$(extract "type_uses_key type_is_hysteria type_is_stripe type_is_ackless type_is_kernel type_is_revmux tok_re lanes_ok inst_name_ok type_known tok_host_ok tok_ipv4_ok tok_port_ok tok_nc_ok tok_hexkey_ok tok_key_ok tok_shape_ok tok_pmode_ok new_inst_lanes build_execstart load_inst create_inst validate_inst_name list_instances inst_path inst_conf inst_pf inst_exists manual_token cmd_server_token cmd_peercreate provision_peer cmd_add_auto cmd_add_manual add_parse alloc_and_create alloc_subnet alloc_port alloc_port_span next_port next_subnet_idx occupied_port_ranges remote_port_ranges peer_port_triples type_port_span port_base gen_key auto_name")"
eval "$(grep -m1 '^ALL_TYPES=' "$SCRIPT")"

fail() { echo "FAIL: $1" >&2; exit 1; }
die() { echo "DIE: $*" >&2; exit 1; }
need_root() { :; }
ensure_binary() { :; }
ensure_hysteria() { :; }
ensure_omnistripe() { :; }
ensure_omniackless() { :; }
guard_peer_downgrade() { :; }
save_peer() { :; }
peer_scp() { :; }
omnistripe_local_bin() { echo "$WORK/omnistripe-$1"; }
omniackless_local_bin() { echo "$WORK/omniackless-$1"; }
inst_enable() { :; }
inst_running() { return 0; }
inst_remove() { rm -rf "${INST_DIR:?}/$1"; }
svc_name() { echo "omnitun-$1.service"; }
ok() { :; }
info() { :; }
warn() { :; }
default_local_ip() { echo 1.2.3.4; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
SCRIPT_PATH="$SCRIPT"
ASSET_DIR="$WORK/assets"; SCRIPT_DIR="$WORK/sd"; mkdir -p "$ASSET_DIR/bin" "$SCRIPT_DIR/bin"
: > "$ASSET_DIR/bin/omnitun-amd64"
C_GREEN=""; C_BOLD=""; C_RESET=""; C_CYAN=""; C_DIM=""
RAW_BASE="RAWBASE"

TSUITE_BIN=/opt/omnitunnel/omnitun
OMNISTRIPE_BIN=/opt/omnitunnel/omnistripe
OMNIACKLESS_BIN=/opt/omnitunnel/omniackless
K="$(printf 'a%.0s' {1..64})"

set_inputs() {
    LOCAL_IP=1.2.3.4; PEER_IP=203.0.113.9; TUN_ADDR=10.201.9.1; PEER_ADDR=10.201.9.2
    PORT=49000; DEV=tsx9; MTU=1400; NCONN=16; PCOUNT=400; KEY="$K"
}

set_inputs; TYPE=stripe; ROLE=client; ICMP_MODE=""; unset LANES
out="$(build_execstart)" || fail "stripe build_execstart failed with LANES unset"
[[ "$out" == *" -lanes 1 "* ]] || fail "stripe with LANES unset must run -lanes 1 (old instance.conf has no LANES): $out"

LANES=16
out="$(build_execstart)" || fail "stripe build_execstart failed with LANES=16"
[[ "$out" == *" -lanes 16 "* ]] || fail "stripe with LANES=16 must run -lanes 16: $out"
[[ "$out" == "/opt/omnitunnel/omnistripe -L 1.2.3.4 -R 203.0.113.9 -A 10.201.9.1 -P 10.201.9.2 -k $K -p 49000 -C 400 -N 512 -lanes 16 -w 1024 -to 1500 -F -T tsx9 -M 1400" ]] \
    || fail "stripe client line differs from the expected tuned line: $out"
ROLE=server
out="$(build_execstart)"
[[ "$out" == "/opt/omnitunnel/omnistripe -L 1.2.3.4 -R 203.0.113.9 -A 10.201.9.1 -P 10.201.9.2 -k $K -p 49000 -C 400 -N 512 -lanes 16 -w 1024 -to 1500 -F -T tsx9 -M 1400 -s" ]] \
    || fail "stripe server line differs from the expected tuned line: $out"

for nc in 1 16 90 511 512 513 700 4096; do
    set_inputs; TYPE=stripe; ROLE=client; LANES=16; NCONN=$nc
    out="$(build_execstart)"
    n=$(sed -nE 's/.* -N ([0-9]+) .*/\1/p' <<< "$out")
    w=$(sed -nE 's/.* -w ([0-9]+) .*/\1/p' <<< "$out")
    [[ -n "$n" && -n "$w" ]] || fail "NCONN=$nc: -N/-w missing: $out"
    (( n >= 512 )) || fail "NCONN=$nc: -N $n is below the 512 floor"
    (( nc < 512 || n == nc )) || fail "NCONN=$nc: -N $n should keep a value above the floor"
    (( w == 2 * n )) || fail "NCONN=$nc: -w $w is not 2*N ($((2 * n)))"
    [[ "$out" == *" -to 1500 "* ]] || fail "NCONN=$nc: -to 1500 missing: $out"
    [[ "$out" == *" -F "* ]] || fail "NCONN=$nc: -F missing: $out"
done

golden() {
cat <<EOF
udp|client||/opt/omnitunnel/omnitun udp -L 1.2.3.4 -R 203.0.113.9 -A 10.201.9.1 -P 10.201.9.2 -p 49000 -k ${K} -T tsx9 -M 1400
udp|client|request|/opt/omnitunnel/omnitun udp -L 1.2.3.4 -R 203.0.113.9 -A 10.201.9.1 -P 10.201.9.2 -p 49000 -k ${K} -T tsx9 -M 1400
udp|server||/opt/omnitunnel/omnitun udp -L 1.2.3.4 -R 203.0.113.9 -A 10.201.9.1 -P 10.201.9.2 -p 49000 -k ${K} -T tsx9 -M 1400
udp|server|request|/opt/omnitunnel/omnitun udp -L 1.2.3.4 -R 203.0.113.9 -A 10.201.9.1 -P 10.201.9.2 -p 49000 -k ${K} -T tsx9 -M 1400
tcp|client||/opt/omnitunnel/omnitun tcp -L 1.2.3.4 -R 203.0.113.9 -A 10.201.9.1 -P 10.201.9.2 -p 49000 -k ${K} -T tsx9 -M 1400
tcp|client|request|/opt/omnitunnel/omnitun tcp -L 1.2.3.4 -R 203.0.113.9 -A 10.201.9.1 -P 10.201.9.2 -p 49000 -k ${K} -T tsx9 -M 1400
tcp|server||/opt/omnitunnel/omnitun tcp -L 1.2.3.4 -R 203.0.113.9 -A 10.201.9.1 -P 10.201.9.2 -p 49000 -k ${K} -s -T tsx9 -M 1400
tcp|server|request|/opt/omnitunnel/omnitun tcp -L 1.2.3.4 -R 203.0.113.9 -A 10.201.9.1 -P 10.201.9.2 -p 49000 -k ${K} -s -T tsx9 -M 1400
mux|client||/opt/omnitunnel/omnitun mux -L 1.2.3.4 -R 203.0.113.9 -A 10.201.9.1 -P 10.201.9.2 -p 49000 -k ${K} -N 16 -T tsx9 -M 1400
mux|client|request|/opt/omnitunnel/omnitun mux -L 1.2.3.4 -R 203.0.113.9 -A 10.201.9.1 -P 10.201.9.2 -p 49000 -k ${K} -N 16 -T tsx9 -M 1400
mux|server||/opt/omnitunnel/omnitun mux -L 1.2.3.4 -R 203.0.113.9 -A 10.201.9.1 -P 10.201.9.2 -p 49000 -k ${K} -s -N 16 -T tsx9 -M 1400
mux|server|request|/opt/omnitunnel/omnitun mux -L 1.2.3.4 -R 203.0.113.9 -A 10.201.9.1 -P 10.201.9.2 -p 49000 -k ${K} -s -N 16 -T tsx9 -M 1400
ws|client||/opt/omnitunnel/omnitun ws -L 1.2.3.4 -R 203.0.113.9 -A 10.201.9.1 -P 10.201.9.2 -p 49000 -k ${K} -N 16 -T tsx9 -M 1400
ws|client|request|/opt/omnitunnel/omnitun ws -L 1.2.3.4 -R 203.0.113.9 -A 10.201.9.1 -P 10.201.9.2 -p 49000 -k ${K} -N 16 -T tsx9 -M 1400
ws|server||/opt/omnitunnel/omnitun ws -L 1.2.3.4 -R 203.0.113.9 -A 10.201.9.1 -P 10.201.9.2 -p 49000 -k ${K} -s -N 16 -T tsx9 -M 1400
ws|server|request|/opt/omnitunnel/omnitun ws -L 1.2.3.4 -R 203.0.113.9 -A 10.201.9.1 -P 10.201.9.2 -p 49000 -k ${K} -s -N 16 -T tsx9 -M 1400
icmp|client||/opt/omnitunnel/omnitun icmp -L 1.2.3.4 -R 203.0.113.9 -A 10.201.9.1 -P 10.201.9.2 -I 4d54 -T tsx9 -M 1400
icmp|client|request|/opt/omnitunnel/omnitun icmp -L 1.2.3.4 -R 203.0.113.9 -A 10.201.9.1 -P 10.201.9.2 -I 4d54 -T tsx9 -M 1400 -r request
icmp|server||/opt/omnitunnel/omnitun icmp -L 1.2.3.4 -R 203.0.113.9 -A 10.201.9.1 -P 10.201.9.2 -I 4d54 -T tsx9 -M 1400 -s
icmp|server|request|/opt/omnitunnel/omnitun icmp -L 1.2.3.4 -R 203.0.113.9 -A 10.201.9.1 -P 10.201.9.2 -I 4d54 -T tsx9 -M 1400 -s -r request
reverse-mux|client||/opt/omnitunnel/omnitun icmp -L 1.2.3.4 -R 203.0.113.9 -A 10.201.9.1 -P 10.201.9.2 -I 4d54 -T tsx9 -M 1400 -r reply
reverse-mux|client|request|/opt/omnitunnel/omnitun icmp -L 1.2.3.4 -R 203.0.113.9 -A 10.201.9.1 -P 10.201.9.2 -I 4d54 -T tsx9 -M 1400 -r request
reverse-mux|server||/opt/omnitunnel/omnitun icmp -L 1.2.3.4 -R 203.0.113.9 -A 10.201.9.1 -P 10.201.9.2 -I 4d54 -T tsx9 -M 1400 -s -r reply
reverse-mux|server|request|/opt/omnitunnel/omnitun icmp -L 1.2.3.4 -R 203.0.113.9 -A 10.201.9.1 -P 10.201.9.2 -I 4d54 -T tsx9 -M 1400 -s -r request
ackless|client||/opt/omnitunnel/omniackless -L 1.2.3.4 -R 203.0.113.9 -A 10.201.9.1 -P 10.201.9.2 -k ${K} -p 49000 -T tsx9 -M 1400
ackless|client|request|/opt/omnitunnel/omniackless -L 1.2.3.4 -R 203.0.113.9 -A 10.201.9.1 -P 10.201.9.2 -k ${K} -p 49000 -T tsx9 -M 1400
ackless|server||/opt/omnitunnel/omniackless -L 1.2.3.4 -R 203.0.113.9 -A 10.201.9.1 -P 10.201.9.2 -k ${K} -p 49000 -T tsx9 -M 1400 -s
ackless|server|request|/opt/omnitunnel/omniackless -L 1.2.3.4 -R 203.0.113.9 -A 10.201.9.1 -P 10.201.9.2 -k ${K} -p 49000 -T tsx9 -M 1400 -s
gre|client||
gre|client|request|
gre|server||
gre|server|request|
fou|client||
fou|client|request|
fou|server||
fou|server|request|
vxlan|client||
vxlan|client|request|
vxlan|server||
vxlan|server|request|
hysteria|client||
hysteria|client|request|
hysteria|server||
hysteria|server|request|
EOF
}

for lanes_case in unset 1 16 64; do
    got=""
    for T in udp tcp mux ws icmp reverse-mux ackless gre fou vxlan hysteria; do
        for R in client server; do
            for IM in "" request; do
                set_inputs; TYPE=$T; ROLE=$R; ICMP_MODE=$IM
                if [[ "$lanes_case" == unset ]]; then unset LANES; else LANES=$lanes_case; fi
                got+="$T|$R|$IM|$(build_execstart)"$'\n'
            done
        done
    done
    [[ "$got" == "$(golden)"$'\n' ]] || {
        diff <(golden) <(printf '%s' "$got") >&2
        fail "non-stripe build_execstart lines changed versus the released v2.9.11 output (LANES=$lanes_case)"
    }
done

old_token() {
    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s' "$@" | base64 | tr -d '\n'
}

for T in gre icmp udp mux ws hysteria tcp fou vxlan reverse-mux ackless; do
    for PM in "" reply; do
        args=(tn "$T" 203.0.113.9 1.2.3.4 51820 "$K" 10.201.5.2 10.201.5.1 none 16 "$PM")
        want="$(old_token "${args[@]}")"
        got="$(manual_token "${args[@]}" 16)" || fail "$T: manual_token failed"
        [[ "$got" == "$want" ]] || fail "$T: non-stripe token is no longer byte-identical to the 11-field format"
        got="$(manual_token "${args[@]}")" || fail "$T: manual_token failed without a lane count"
        [[ "$got" == "$want" ]] || fail "$T: non-stripe token without a lane count is not the 11-field format"
    done
done

for L in 1 16 64; do
    tok="$(manual_token sname stripe 203.0.113.9 1.2.3.4 40000 "$K" 10.201.6.2 10.201.6.1 none 16 "" "$L")" || fail "stripe manual_token failed"
    dec="$(printf '%s' "$tok" | base64 -d)"
    nf=$(( $(tr -cd '|' <<< "$dec" | wc -c) + 1 ))
    (( nf == 12 )) || fail "stripe token must have 12 fields, got $nf: $dec"
    [[ "${dec##*|}" == "$L" ]] || fail "stripe token must end in the lane count $L: $dec"
    [[ "${dec%|*}" == "sname|stripe|203.0.113.9|1.2.3.4|40000|$K|10.201.6.2|10.201.6.1|none|16|" ]] \
        || fail "stripe token's first 11 fields changed: $dec"
done
if ( manual_token sname stripe 203.0.113.9 1.2.3.4 40000 "$K" 10.201.6.2 10.201.6.1 none 16 "" ) >/dev/null 2>&1; then
    fail "a stripe token without a lane count was emitted instead of failing loudly"
fi

conf_lanes() { grep -m1 '^LANES=' "$1/$2/instance.conf" | cut -d= -f2; }
lanes_of() {
    ( INST_DIR="$1"; load_inst "$2"; build_execstart ) | sed -nE 's/.* -lanes ([0-9]+) .*/\1/p'
}

FOREIGN="$WORK/foreign"; mkdir -p "$FOREIGN"
INST_DIR="$FOREIGN"
legacy="$(old_token legacy stripe 203.0.113.9 1.2.3.4 40000 "$K" 10.201.7.2 10.201.7.1 none 16 "")"
( cmd_server_token "$legacy" ) || fail "a legacy 11-field stripe token was rejected"
[[ "$(conf_lanes "$FOREIGN" legacy)" == 1 ]] || fail "legacy 11-field stripe token must yield LANES=1, got '$(conf_lanes "$FOREIGN" legacy)'"
[[ "$(lanes_of "$FOREIGN" legacy)" == 1 ]] || fail "legacy stripe token must run -lanes 1"

new16="$(manual_token new16 stripe 203.0.113.9 1.2.3.4 40400 "$K" 10.201.8.2 10.201.8.1 none 16 "" 16)"
( cmd_server_token "$new16" ) || fail "a 12-field stripe token was rejected"
[[ "$(conf_lanes "$FOREIGN" new16)" == 16 ]] || fail "12-field stripe token must yield LANES=16"
[[ "$(lanes_of "$FOREIGN" new16)" == 16 ]] || fail "12-field stripe token must run -lanes 16"

for bad in 0 65 abc -1 01 "16|x" " 16"; do
    tok="$(printf '%s' "bad|stripe|203.0.113.9|1.2.3.4|41000|$K|10.201.9.2|10.201.9.1|none|16||$bad" | base64 | tr -d '\n')"
    if ( cmd_server_token "$tok" ) >/dev/null 2>&1; then fail "server-token accepted lane count '$bad'"; fi
    [[ ! -e "$FOREIGN/bad" ]] || fail "server-token created an instance for lane count '$bad'"
done

mkdir -p "$FOREIGN/old"
printf 'TYPE=stripe\nROLE=server\nLOCAL_IP=203.0.113.9\nPEER_IP=1.2.3.4\nTUN_ADDR=10.201.3.2\nPEER_ADDR=10.201.3.1\nPORT=42000\nKEY=%s\nDEV=ts-old\nMTU=1400\nNCONN=16\nSHAPE=none\nICMP_MODE=\nPCOUNT=400\n' "$K" > "$FOREIGN/old/instance.conf"
got="$( INST_DIR="$FOREIGN"; load_inst new16; load_inst old; build_execstart )"
[[ "$got" == *" -lanes 1 "* ]] || fail "a pre-2.9.12 instance.conf loaded after a 16-lane one must reset to -lanes 1: $got"

for v in 0 65 abc -1 01 100 1.5; do
    if ( STRIPE_LANES="$v"; new_inst_lanes stripe ) >/dev/null 2>&1; then fail "STRIPE_LANES=$v was accepted"; fi
done
( unset STRIPE_LANES; new_inst_lanes stripe; [[ "$NEW_LANES" == 16 ]] ) || fail "new stripe instances must default to 16 lanes"
( STRIPE_LANES=8; new_inst_lanes stripe; [[ "$NEW_LANES" == 8 ]] ) || fail "STRIPE_LANES=8 was not applied"
( STRIPE_LANES=64; new_inst_lanes stripe; [[ "$NEW_LANES" == 64 ]] ) || fail "STRIPE_LANES=64 was not applied"
( STRIPE_LANES=1; new_inst_lanes stripe; [[ "$NEW_LANES" == 1 ]] ) || fail "STRIPE_LANES=1 was not applied"
for T in tcp ackless mux; do
    ( STRIPE_LANES=abc; new_inst_lanes "$T"; [[ "$NEW_LANES" == 1 ]] ) || fail "$T: STRIPE_LANES must not apply to a non-stripe type"
done

PCALLS="$WORK/peer_calls"
OLD_FOREIGN=""
peer_ssh() {
    shift
    echo "$*" >> "$PCALLS"
    local nm
    case "$*" in
        *" _peercreate "*)
            local rest="${*#* _peercreate }"
            eval "set -- $rest"
            if [[ -n "$OLD_FOREIGN" ]]; then
                ( INST_DIR="$FOREIGN"; cmd_peercreate "${@:1:13}" )
                sed -i '/^LANES=/d' "$FOREIGN/$1/instance.conf"
            else
                ( INST_DIR="$FOREIGN"; cmd_peercreate "$@" )
            fi
            ;;
        *"^LANES="*)
            nm="$(sed -nE "s#.*/etc/omnitunnel/inst/'([^']+)'/instance.conf.*#\1#p" <<< "$*")"
            grep -m1 -E '^LANES=' "$FOREIGN/$nm/instance.conf"
            ;;
        *" _remove "*)
            nm="$(sed -nE "s#.* _remove '([^']+)'.*#\1#p" <<< "$*")"
            rm -rf "${FOREIGN:?}/$nm"
            ;;
        "uname -m") echo x86_64;;
        *) :;;
    esac
}

with_lanes_env() {
    if [[ "$1" == unset ]]; then unset STRIPE_LANES; else STRIPE_LANES="$1"; fi
}

add_auto_case() {
    local name="$1" t="$2" want="$3" sl="$4"
    : > "$PCALLS"
    ( INST_DIR="$NEAR"; unset OMNITUN_PEER_PASS OMNITUN_PEER_PROXY OMNITUN_ICMP_MODE OMNITUN_ICMP_MODE_PEER; with_lanes_env "$sl"; cmd_add_auto "$t" "$name" 203.0.113.9 16 none 1.2.3.4 ) >/dev/null \
        || fail "add-auto $t $name failed"
    grep -q " _peercreate '$name' '$t' server .* '' '$want'\$" "$PCALLS" \
        || fail "add-auto $t: provision_peer did not pass lane count $want to the foreign's _peercreate: $(grep _peercreate "$PCALLS")"
    [[ "$(conf_lanes "$NEAR" "$name")" == "$want" ]] || fail "add-auto $t: client LANES='$(conf_lanes "$NEAR" "$name")' want $want"
    [[ "$(conf_lanes "$FOREIGN" "$name")" == "$want" ]] || fail "add-auto $t: server LANES='$(conf_lanes "$FOREIGN" "$name")' want $want"
    if type_is_stripe "$t"; then
        [[ "$(lanes_of "$NEAR" "$name")" == "$want" && "$(lanes_of "$FOREIGN" "$name")" == "$want" ]] \
            || fail "add-auto $t: client/server ExecStart lane counts differ or are not $want"
    fi
}

NEAR="$WORK/near"; mkdir -p "$NEAR"
add_auto_case auto16 stripe 16 unset
add_auto_case auto5 stripe 5 5
add_auto_case autoack ackless 1 5
add_auto_case autotcp tcp 1 unset

for v in 0 65 abc; do
    : > "$PCALLS"
    if ( INST_DIR="$NEAR"; STRIPE_LANES="$v"; cmd_add_auto stripe "bad$v" 203.0.113.9 16 none 1.2.3.4 ) >/dev/null 2>&1; then
        fail "add-auto accepted STRIPE_LANES=$v"
    fi
    [[ ! -s "$PCALLS" ]] || fail "add-auto touched the foreign before rejecting STRIPE_LANES=$v"
    [[ ! -e "$NEAR/bad$v" && ! -e "$FOREIGN/bad$v" ]] || fail "add-auto created an instance despite STRIPE_LANES=$v"
done

OLD_FOREIGN=1
if ( INST_DIR="$NEAR"; unset STRIPE_LANES; cmd_add_auto stripe stale16 203.0.113.9 16 none 1.2.3.4 ) >/dev/null 2>&1; then
    fail "add-auto brought up a 16-lane client against a foreign whose manager ignored the lane count"
fi
[[ ! -e "$NEAR/stale16" ]] || fail "add-auto left a 16-lane client behind after the foreign failed to record the lane count"
[[ ! -e "$FOREIGN/stale16" ]] || fail "add-auto left the mismatched 1-lane server side on the foreign"
( INST_DIR="$NEAR"; STRIPE_LANES=1; cmd_add_auto stripe stale1 203.0.113.9 16 none 1.2.3.4 ) >/dev/null \
    || fail "a 1-lane stripe add against a foreign with no LANES line must succeed (both ends run 1 lane)"
[[ "$(lanes_of "$NEAR" stale1)" == 1 && "$(lanes_of "$FOREIGN" stale1)" == 1 ]] || fail "1-lane add against an old foreign: ends disagree"
OLD_FOREIGN=""

manual_case() {
    local name="$1" t="$2" want="$3" sl="$4" out tok
    out="$( INST_DIR="$NEAR"; unset OMNITUN_ICMP_MODE OMNITUN_ICMP_MODE_PEER; with_lanes_env "$sl"; cmd_add_manual "$t" "$name" 203.0.113.9 16 none 1.2.3.4 )" \
        || fail "add-manual $t $name failed"
    tok="$(awk '/server-token /{print $3}' <<< "$out")"
    [[ -n "$tok" ]] || fail "add-manual $t printed no token"
    [[ "$(conf_lanes "$NEAR" "$name")" == "$want" ]] || fail "add-manual $t: client LANES='$(conf_lanes "$NEAR" "$name")' want $want"
    MANUAL_TOKEN="$tok"
    ( INST_DIR="$FOREIGN"; cmd_server_token "$tok" ) >/dev/null || fail "add-manual $t: its own token was rejected by server-token"
    [[ "$(conf_lanes "$FOREIGN" "$name")" == "$want" ]] || fail "add-manual $t: server LANES='$(conf_lanes "$FOREIGN" "$name")' want $want"
}

manual_case man16 stripe 16 unset
[[ "$(lanes_of "$NEAR" man16)" == 16 && "$(lanes_of "$FOREIGN" man16)" == 16 ]] || fail "add-manual stripe: the two ends do not both run -lanes 16"
manual_case man7 stripe 7 7
[[ "$(lanes_of "$NEAR" man7)" == 7 && "$(lanes_of "$FOREIGN" man7)" == 7 ]] || fail "add-manual stripe STRIPE_LANES=7: the two ends do not both run -lanes 7"

manual_case mantcp tcp 1 7
mantcp_want="$( INST_DIR="$NEAR"; load_inst mantcp; old_token mantcp tcp "$PEER_IP" "$LOCAL_IP" "$PORT" "$KEY" "$PEER_ADDR" "$TUN_ADDR" "$SHAPE" "$NCONN" "" )"
[[ "$MANUAL_TOKEN" == "$mantcp_want" ]] || fail "add-manual tcp: the printed token is not byte-identical to the 11-field format"

for v in 0 65 abc; do
    if ( INST_DIR="$NEAR"; STRIPE_LANES="$v"; cmd_add_manual stripe "mbad$v" 203.0.113.9 16 none 1.2.3.4 ) >/dev/null 2>&1; then
        fail "add-manual accepted STRIPE_LANES=$v"
    fi
    [[ ! -e "$NEAR/mbad$v" ]] || fail "add-manual created an instance despite STRIPE_LANES=$v"
done

OLDFG="$(mktemp -d)"
old_server_token_pmode() {
    local dec name t fhost mylip port key pta ppa shape nc pmode
    dec="$(printf '%s' "$1" | base64 -d)"
    IFS='|' read -r name t fhost mylip port key pta ppa shape nc pmode <<< "$dec"
    printf '%s' "$pmode"
}
old_load_reaches_unit() {
    printf 'TYPE=stripe\nROLE=server\nICMP_MODE=%s\nPCOUNT=400\n' "$1" > "$OLDFG/instance.conf"
    bash -c 'set -euo pipefail; source "$1"; echo REACHED' _ "$OLDFG/instance.conf" 2>/dev/null
}
oldtok="$(manual_token oldfg stripe 203.0.113.9 1.2.3.4 40800 "$K" 10.201.9.2 10.201.9.1 none 16 "" 16)"
oldpm="$(old_server_token_pmode "$oldtok")"
[[ "$oldpm" == "|16" ]] || fail "the v2.9.11 server-token parser should read a 12-field stripe token's tail into pmode as '|16', got '$oldpm'"
[[ "$(old_load_reaches_unit "")" == REACHED ]] || fail "control: a v2.9.11 conf with an empty ICMP_MODE must load under set -euo pipefail"
[[ "$(old_load_reaches_unit "$oldpm")" != REACHED ]] || fail "a v2.9.11 foreign given a 12-field stripe token must abort while loading its conf (set -euo pipefail), before any unit is written"
legacytok="$(printf '%s' 'legacy|stripe|203.0.113.9|1.2.3.4|40900|k|10.201.9.2|10.201.9.1|none|16|' | base64 | tr -d '\n')"
[[ "$(old_server_token_pmode "$legacytok")" == "" ]] || fail "an 11-field stripe token must leave pmode empty for the v2.9.11 parser"
rm -rf "$OLDFG"

MAINGO="$REPO/src/omnistripe/main.go"
[[ -f "$MAINGO" ]] || fail "cannot find $MAINGO"
grep -qE 'flag\.Int\("lanes", 1,' "$MAINGO" \
    || fail "omnistripe's -lanes default must stay 1: units written before 2.9.12 pass no -lanes and must keep matching their peer"

echo "PASSED - stripe runs -lanes \${LANES:-1} with the tuned N/w/to/F, new add-auto/add-manual stripe tunnels get the same lane count on both ends (16 or STRIPE_LANES), a foreign that does not record that lane count is refused and cleaned up, legacy tokens and confs stay at 1 lane, non-stripe tokens and ExecStart lines are unchanged"
