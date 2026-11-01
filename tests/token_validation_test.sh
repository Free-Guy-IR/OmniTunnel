#!/usr/bin/env bash
set -u

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

eval "$(extract "type_uses_key type_is_hysteria type_is_stripe type_is_ackless type_is_kernel type_is_revmux tok_re lanes_ok inst_name_ok type_known tok_host_ok tok_ipv4_ok tok_port_ok tok_nc_ok tok_hexkey_ok tok_key_ok tok_shape_ok tok_pmode_ok mux_map_ok norm_port validate_inst_name list_instances inst_path inst_conf inst_pf inst_exists create_inst load_inst manual_token gen_key mux_conf mux_ctrl_port mux_token cmd_mux_add cmd_mux_token cmd_server_token cmd_bench_server _bench_key_for")"
eval "$(grep -m1 '^ALL_TYPES=' "$SCRIPT")"
BENCH_FMT="$(sed -nE "s/.*token=\\\$\(printf '(bench[^']*)'.*/\1/p" "$SCRIPT" | head -1)"

fail() { echo "FAIL: $1" >&2; exit 1; }
die() { echo "DIE: $*" >&2; exit 1; }
need_root() { :; }
note_ensure() { echo "$1" >> "$WORK/ensure_calls"; }
ensure_binary() { note_ensure binary; }
ensure_hysteria() { note_ensure hysteria; }
ensure_omnistripe() { note_ensure omnistripe; }
ensure_omniackless() { note_ensure omniackless; }
ensure_chisel() { note_ensure chisel; }
inst_enable() { load_inst "$1"; }
inst_running() { return 0; }
inst_remove() { rm -rf "${INST_DIR:?}/$1"; }
svc_name() { echo "omnitun-$1.service"; }
mux_client_apply() { printf '%s\n' "$*" >> "$WORK/mux_applied"; }
mux_relay_reconcile() { :; }
_mux_push_foreign() { :; }
systemctl() { :; }
systemd-run() { :; }
apt-get() { :; }
yum() { :; }
ok() { :; }
info() { :; }
warn() { :; }

if locale -a 2>/dev/null | grep -qix 'en_US.utf8'; then export LC_ALL=en_US.UTF-8; fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
CANARY="$WORK/canary"
INST_DIR="$WORK/a/b/c/inst"; mkdir -p "$INST_DIR"
mkdir -p "$WORK/a/b/c/victim"; printf 'TYPE=tcp\n' > "$WORK/a/b/c/victim/instance.conf"
C_GREEN=""; C_BOLD=""; C_RESET=""; C_CYAN=""; C_DIM=""

KEY="$(gen_key)"
[[ "$KEY" =~ ^[0-9a-f]{64}$ ]] || fail "gen_key no longer emits 64 lowercase hex characters: $KEY"

snapshot() { (cd "$WORK" && find . -print | grep -v -e '^\./ensure_calls$' -e '^\./mux_applied$' | LC_ALL=C sort; cat ./a/b/c/victim/instance.conf 2>/dev/null); }

expect_rejected() {
    local what="$1" fn="$2" tok="$3" want="${4:-}" before after out rc
    rm -f "$WORK/ensure_calls" "$WORK/mux_applied"; before="$(snapshot)"
    out="$( ( "$fn" "$tok" ) 2>&1 )"; rc=$?
    (( rc != 0 )) || fail "$what: $fn accepted a crafted token"
    [[ -z "$want" || "$out" == *"$want"* ]] || fail "$what: rejected for the wrong reason (want '$want'): $out"
    after="$(snapshot)"
    [[ "$before" == "$after" ]] || { diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") >&2; fail "$what: $fn changed the filesystem before rejecting the token"; }
    [[ ! -e "$CANARY" ]] || fail "$what: a payload in the token was executed"
    [[ ! -e "$WORK/ensure_calls" ]] || fail "$what: $fn installed a binary ($(tr '\n' ' ' < "$WORK/ensure_calls")) before validating the token"
    [[ ! -e "$WORK/mux_applied" ]] || fail "$what: $fn applied mux forwards from a crafted token"
}

b64() { printf '%s' "$1" | base64 | tr -d '\n'; }

F_NAME=good; F_T=stripe; F_FH=203.0.113.9; F_ML=1.2.3.4; F_PORT=40000; F_KEY="$KEY"; F_PTA=10.201.5.2; F_PPA=10.201.5.1; F_SHAPE=none; F_NC=16; F_PM=""; F_LANES=16
server_tok() {
    local name="$F_NAME" t="$F_T" fh="$F_FH" ml="$F_ML" port="$F_PORT" key="$F_KEY" pta="$F_PTA" ppa="$F_PPA" shape="$F_SHAPE" nc="$F_NC" pm="$F_PM" lanes="$F_LANES" kv
    for kv in "$@"; do
        case "${kv%%=*}" in
            name) name="${kv#*=}";; t) t="${kv#*=}";; fh) fh="${kv#*=}";; ml) ml="${kv#*=}";; port) port="${kv#*=}";;
            key) key="${kv#*=}";; pta) pta="${kv#*=}";; ppa) ppa="${kv#*=}";; shape) shape="${kv#*=}";; nc) nc="${kv#*=}";;
            pm) pm="${kv#*=}";; lanes) lanes="${kv#*=}";;
        esac
    done
    b64 "$name|$t|$fh|$ml|$port|$key|$pta|$ppa|$shape|$nc|$pm|$lanes"
}

P_SEMI=";touch $CANARY"
P_SUB="\$(touch $CANARY)"
P_TICK="\`touch $CANARY\`"

for v in "../victim" "../../x" "../../../../escaped" "a b" "a${P_SEMI}" "$P_SUB" "$P_TICK" "" "-x" "a/b" "a.b" "$(printf 'n%.0s' {1..33})" "café"; do
    expect_rejected "server-token name='$v'" cmd_server_token "$(server_tok "name=$v")" "invalid token: name"
done
for v in bogus "stripe${P_SEMI}" "gre icmp" "" STRIPE "stripe$P_SUB" "../stripe"; do
    expect_rejected "server-token type='$v'" cmd_server_token "$(server_tok "t=$v")" "invalid token: type"
done
for f in fh ml; do
    msg="invalid token: foreign address"; [[ "$f" == ml ]] && msg="invalid token: near address"
    for v in "1.2.3.4${P_SEMI}" "$P_SUB" "$P_TICK" "1.2.3.4 203.0.113.10" "" "-oProxyCommand=x" "1.2.3.4/32" "host_name" "a'b"; do
        expect_rejected "server-token $f='$v'" cmd_server_token "$(server_tok "$f=$v")" "$msg"
    done
done
for v in 0 65536 99999 "1$P_SUB" abc "" -1 080 "40000 40001" "4e4"; do
    expect_rejected "server-token port='$v'" cmd_server_token "$(server_tok "port=$v")" "invalid token: port"
done
for v in "$(printf 'z%.0s' {1..64})" "$(printf 'A%.0s' {1..64})" "${KEY:0:63}" "${KEY}0" "" "$P_SUB" "${KEY:0:60}$P_SEMI"; do
    expect_rejected "server-token key='${v:0:20}...'" cmd_server_token "$(server_tok "key=$v")" "invalid token: key"
done
for f in pta ppa; do
    msg="invalid token: tunnel address"; [[ "$f" == ppa ]] && msg="invalid token: peer tunnel address"
    for v in 10.201.5.256 10.201.5 10.201.5.2.1 "10.201.5.2${P_SEMI}" a.b.c.d "" "$P_SUB" 010.201.5.2 "10.201.5.2/24"; do
        expect_rejected "server-token $f='$v'" cmd_server_token "$(server_tok "$f=$v")" "$msg"
    done
done
for v in "none${P_SEMI}" "$P_SUB" "$P_TICK" "90 mbit" "90mbit;x" "mbit" "90megabit" "-1"; do
    expect_rejected "server-token shape='$v'" cmd_server_token "$(server_tok "shape=$v")" "invalid token: shape"
done
for v in 0 16385 99999 "16${P_SEMI}" 1e3 "" -4 016; do
    expect_rejected "server-token nconn='$v'" cmd_server_token "$(server_tok "nc=$v")" "invalid token: nconn"
done
for v in x "reply${P_SEMI}" "$P_SUB" REPLY; do
    expect_rejected "server-token pmode='$v'" cmd_server_token "$(server_tok "pm=$v")" "invalid token: icmp mode"
done
for v in 0 65 abc 01 "16|x" " 16" "$P_SUB"; do
    expect_rejected "server-token lanes='$v'" cmd_server_token "$(server_tok "lanes=$v")" "invalid token: lanes"
done
expect_rejected "server-token with a 13th field" cmd_server_token "$(b64 "good|stripe|203.0.113.9|1.2.3.4|40000|$KEY|10.201.5.2|10.201.5.1|none|16||16|extra")" "invalid token: lanes"
expect_rejected "server-token with a | inside the name" cmd_server_token "$(b64 "go|od|stripe|203.0.113.9|1.2.3.4|40000|$KEY|10.201.5.2|10.201.5.1|none|16||16")" "invalid token: type"
expect_rejected "server-token with a newline-smuggled field" cmd_server_token "$(b64 "good|stripe|203.0.113.9|1.2.3.4|40000|$KEY|10.201.5.2|10.201.5.1|none${P_SEMI}"$'\n'"|16||16")" "invalid token: shape"
expect_rejected "server-token not base64" cmd_server_token '!!!not-base64!!!' "invalid token"
expect_rejected "server-token empty" cmd_server_token "" "invalid token: name"
expect_rejected "server-token key type with no key" cmd_server_token "$(server_tok "t=tcp" "key=")" "invalid token: key"

mkdir -p "$INST_DIR/foo" "$INST_DIR/foo-mux"
printf 'TYPE=tcp\n' > "$INST_DIR/foo/instance.conf"; printf 'TYPE=tcp\n' > "$INST_DIR/foo-mux/instance.conf"
expect_rejected "server-token whose name collides with another instance's helper unit" cmd_server_token "$(server_tok "name=foo-mux" "t=tcp")" "would collide with a helper unit"
rm -rf "$INST_DIR/foo" "$INST_DIR/foo-mux"

accept_server() {
    local what="$1" tok="$2" name="$3"
    rm -f "$WORK/ensure_calls"
    ( cmd_server_token "$tok" ) >/dev/null 2>&1 || fail "$what: a legitimate token was rejected"
    [[ -f "$INST_DIR/$name/instance.conf" ]] || fail "$what: no instance.conf was written"
    [[ ! -e "$CANARY" ]] || fail "$what: canary appeared"
}
conf_of() { ( load_inst "$1"; printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s' "$TYPE" "$ROLE" "$LOCAL_IP" "$PEER_IP" "$PORT" "$KEY" "$TUN_ADDR" "$PEER_ADDR" "$SHAPE" "$NCONN" "$ICMP_MODE" "$LANES" ); }

i=0
for T in $ALL_TYPES; do
    i=$((i+1))
    k=""; type_uses_key "$T" && k="$(gen_key)"
    shape=none; nc=16; pm=""; lanes=16
    case "$T" in mux) shape=90mbit;; hysteria) shape=200;; stripe) nc=90;; icmp) pm=request;; reverse-mux) pm=reply;; esac
    tok="$(manual_token "t$i" "$T" 203.0.113.9 1.2.3.4 "$((40000 + i))" "$k" "10.201.$i.2" "10.201.$i.1" "$shape" "$nc" "$pm" "$lanes")"
    accept_server "manual_token $T" "$tok" "t$i"
    want="$T|server|203.0.113.9|1.2.3.4|$((40000 + i))|$k|10.201.$i.2|10.201.$i.1|$shape|$nc|$pm|"
    type_is_stripe "$T" && want+="16" || want+="1"
    got="$(conf_of "t$i")"
    [[ "$got" == "$want" ]] || fail "manual_token $T: instance.conf does not carry the token's fields: got [$got] want [$want]"
    accept_server "manual_token $T re-run (idempotent)" "$tok" "t$i"
done

accept_server "legacy 11-field stripe token" "$(b64 "leg11|stripe|203.0.113.9|1.2.3.4|41000|$KEY|10.201.60.2|10.201.60.1|none|90|")" leg11
[[ "$(conf_of leg11)" == "stripe|server|203.0.113.9|1.2.3.4|41000|$KEY|10.201.60.2|10.201.60.1|none|90||1" ]] || fail "legacy 11-field stripe token: wrong conf $(conf_of leg11)"
accept_server "legacy 10-field mux token" "$(b64 "leg10|mux|203.0.113.9|1.2.3.4|51820|$KEY|10.201.61.2|10.201.61.1|90mbit|16")" leg10
accept_server "legacy icmp token without a key" "$(b64 "legicmp|icmp|203.0.113.9|1.2.3.4|51821||10.201.62.2|10.201.62.1|none|16|reply")" legicmp
accept_server "ipv6 and hostname endpoints" "$(server_tok "name=v6" "fh=2001:db8::1" "ml=relay-1.example" "pta=10.201.63.2" "ppa=10.201.63.1")" v6
accept_server "fractional and upper-case shaper rate" "$(server_tok "name=shp" "t=mux" "shape=1.5Gbit" "pta=10.201.64.2" "ppa=10.201.64.1")" shp

RELAY_DIR="$WORK/relay"; mkdir -p "$RELAY_DIR"
( INST_DIR="$RELAY_DIR"; create_inst rmux reverse-mux client 1.2.3.4 203.0.113.9 51830 "" 10.201.7.1 10.201.7.2 none 16 reply )
printf '443:127.0.0.1:443\n8443:localhost:8080\n0080:backend_1.internal:80\n' > "$RELAY_DIR/rmux/mux.conf"
MUXTOK="$( INST_DIR="$RELAY_DIR"; mux_token rmux )"
rm -f "$WORK/mux_applied"
( cmd_mux_token "$MUXTOK" ) >/dev/null 2>&1 || fail "a real mux token from mux_token was rejected"
[[ "$(cat "$WORK/mux_applied")" == "rmux 10.201.7.1 9007 443:127.0.0.1:443 8443:localhost:8080 0080:backend_1.internal:80" ]] \
    || fail "real mux token: mux_client_apply got the wrong arguments: $(cat "$WORK/mux_applied")"
[[ "$(cat "$INST_DIR/rmux/mux.conf")" == "$(cat "$RELAY_DIR/rmux/mux.conf")" ]] || fail "real mux token: the foreign mux.conf differs from the relay's"
rm -f "$WORK/mux_applied"

mux_tok() { b64 "$1"$'\n'"$2"; }
for v in "../../x" "../victim" "a b" "a${P_SEMI}" "$P_SUB" "" "a/b"; do
    expect_rejected "mux-token instance='$v'" cmd_mux_token "$(mux_tok "MUX1|$v|10.201.7.1|9007" "443:127.0.0.1:443")" "invalid token: instance name"
done
for v in "10.201.7.1${P_SEMI}" "$P_SUB" "10.201.7" "999.1.1.1" "relay.example" "" "10.201.7.1 x"; do
    expect_rejected "mux-token relay='$v'" cmd_mux_token "$(mux_tok "MUX1|rmux|$v|9007" "443:127.0.0.1:443")" "invalid token: relay address"
done
for v in 0 70000 "9007|x" "9007${P_SEMI}" "" abc; do
    expect_rejected "mux-token ctrl='$v'" cmd_mux_token "$(mux_tok "MUX1|rmux|10.201.7.1|$v" "443:127.0.0.1:443")" "invalid token: control port"
done
for v in "443:127.0.0.1:443${P_SEMI}" "443:host name:443" "443:${P_SUB}:443" "443:${P_TICK}:443" "443:-oProxy:443" "0:h:443" "443:h:65536" "443:h" "443:h:443:9" " 443:h:443" "443:[::1]:443" "x:h:443" "443:hôst:443"; do
    expect_rejected "mux-token forward='$v'" cmd_mux_token "$(mux_tok "MUX1|rmux|10.201.7.1|9007" "443:127.0.0.1:443"$'\n'"$v")" "invalid token: forward"
done
expect_rejected "mux-token wrong tag" cmd_mux_token "$(mux_tok "MUX2|rmux|10.201.7.1|9007" "443:127.0.0.1:443")"
expect_rejected "mux-token without forwards" cmd_mux_token "$(b64 "MUX1|rmux|10.201.7.1|9007")"

( INST_DIR="$RELAY_DIR"; cmd_mux_add rmux 9443 'evil;touch x' 443 ) >/dev/null 2>&1 && fail "mux-add accepted a destination host with shell metacharacters"
grep -q '^9443:' "$RELAY_DIR/rmux/mux.conf" && fail "mux-add wrote a forward with a bad destination host"
( INST_DIR="$RELAY_DIR"; cmd_mux_add rmux 9443 db.internal 5432 ) >/dev/null 2>&1 || fail "mux-add rejected a normal destination host"
grep -qx '9443:db.internal:5432' "$RELAY_DIR/rmux/mux.conf" || fail "mux-add did not record a normal forward"

[[ -n "$BENCH_FMT" ]] || fail "could not find the bench token format in $SCRIPT"
bench_tok() { local f; printf -v f "$BENCH_FMT" "$@"; b64 "$f"; }
KU="$(gen_key)"; KM="$(gen_key)"; KT="$(gen_key)"
for v in "1.2.3.4${P_SEMI}" "$P_SUB" "" "a b"; do
    expect_rejected "bench-server foreign='$v'" cmd_bench_server "$(bench_tok "$v" 1.2.3.4 "$KU" "$KM" "$KT")" "invalid token: foreign address"
    expect_rejected "bench-server near='$v'" cmd_bench_server "$(bench_tok 203.0.113.9 "$v" "$KU" "$KM" "$KT")" "invalid token: near address"
done
for v in "$(printf 'z%.0s' {1..64})" "${KU:0:63}" "" "$P_SUB" "${KU^^}"; do
    expect_rejected "bench-server udp key" cmd_bench_server "$(bench_tok 203.0.113.9 1.2.3.4 "$v" "$KM" "$KT")" "invalid token: udp key"
    expect_rejected "bench-server mux key" cmd_bench_server "$(bench_tok 203.0.113.9 1.2.3.4 "$KU" "$v" "$KT")" "invalid token: mux key"
    expect_rejected "bench-server tcp key" cmd_bench_server "$(bench_tok 203.0.113.9 1.2.3.4 "$KU" "$KM" "$v")" "invalid token: tcp key"
done
expect_rejected "bench-server key overflow" cmd_bench_server "$(bench_tok 203.0.113.9 1.2.3.4 "$KU" "$KM" "$KT|x")" "invalid token: tcp key"
expect_rejected "bench-server wrong tag" cmd_bench_server "$(b64 "Bench|203.0.113.9|1.2.3.4|$KU|$KM|$KT")"

BDIR="$WORK/benchinst"; mkdir -p "$BDIR"
( INST_DIR="$BDIR"; cmd_bench_server "$(bench_tok 203.0.113.9 1.2.3.4 "$KU" "$KM" "$KT")" ) >/dev/null 2>&1 || fail "a real bench token was rejected"
for T in $ALL_TYPES; do
    { type_is_hysteria "$T" || type_is_revmux "$T"; } && continue
    [[ -f "$BDIR/bench-$T/instance.conf" ]] || fail "real bench token: bench-$T was not created"
done
[[ "$(grep -m1 '^KEY=' "$BDIR/bench-udp/instance.conf")" == "KEY=$KU" ]] || fail "real bench token: bench-udp did not get the udp key"

[[ ! -e "$CANARY" ]] || fail "canary exists at the end"
[[ -f "$WORK/a/b/c/victim/instance.conf" ]] || fail "the instance outside INST_DIR was removed"

echo "PASSED - server-token, mux-token and bench-server reject crafted names, types, hosts, ports, keys, tunnel addresses, shapes, nconn, icmp modes, lanes, forwards and | or newline overflow before touching the filesystem or installing anything; every legitimate token (all types, legacy 10/11-field, real mux and bench tokens) still works"
