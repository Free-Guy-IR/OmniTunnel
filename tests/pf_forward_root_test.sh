#!/usr/bin/env bash
set -u

SCRIPT="${1:-$(dirname "$0")/../omnitunnel.sh}"
SCRIPT="$(cd "$(dirname "$SCRIPT")" && pwd)/$(basename "$SCRIPT")"

skip() { echo "SKIP: $*"; exit 0; }
fail() { echo "FAIL: $*" >&2; exit 1; }

if [[ "${OMNI_FWD_TEST_NS:-}" != 1 ]]; then
    [[ "$(id -u)" -eq 0 ]] || skip "pf_forward_root_test needs root"
    for c in iptables ip unshare mount python3; do
        command -v "$c" >/dev/null 2>&1 || skip "pf_forward_root_test needs $c"
    done
    unshare -n -m true 2>/dev/null || skip "pf_forward_root_test cannot create a private network+mount namespace"
    exec unshare -n -m env OMNI_FWD_TEST_NS=1 bash "$0" "$SCRIPT"
fi

[[ "$(readlink /proc/self/ns/net)" != "$(readlink /proc/1/ns/net)" ]] || fail "not inside a private network namespace"
[[ "$(readlink /proc/self/ns/mnt)" != "$(readlink /proc/1/ns/mnt)" ]] || fail "not inside a private mount namespace"
mount --make-rprivate / 2>/dev/null || true
mkdir -p /run/netns
mount -t tmpfs omni-fwd-test /run/netns || fail "cannot shadow /run/netns inside the private mount namespace"

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

eval "$(extract "tok_re inst_name_ok inst_path inst_conf inst_pf inst_exists load_inst dnat_chain type_is_hysteria ipt with_pf_lock pf_fwd_apply pf_fwd_drop _pf_apply_all pf_apply_all _pf_flush_chain pf_flush_chain cmd_postup validate_inst_name list_instances norm_port rewrite_without _pf_add pf_add _pf_del pf_del")"

ok() { :; }
warn() { :; }
info() { :; }
die() { echo "DIE: $*" >&2; exit 1; }
need_root() { :; }
apply_tuning() { :; }
hy_pf_reconcile() { :; }

WORK="$(mktemp -d)"
PIDS=()
cleanup() {
    local p
    for p in ${PIDS[@]+"${PIDS[@]}"}; do kill "$p" 2>/dev/null; done
    for p in ${PIDS[@]+"${PIDS[@]}"}; do wait "$p" 2>/dev/null; done
    for ns in otc otp otq; do ip netns del "$ns" 2>/dev/null; done
    rm -rf "$WORK"
}
trap cleanup EXIT
INST_DIR="$WORK/inst"; mkdir -p "$INST_DIR"
RUN_DIR="$WORK/run"; mkdir -p "$RUN_DIR"

cat > "$WORK/echo.py" <<'PY'
import socket, sys, threading
host = sys.argv[1]
def udp(p):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind((host, p))
    while True:
        d, a = s.recvfrom(2048)
        s.sendto(b"echo:" + d, a)
def tcp(p):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind((host, p)); s.listen(64)
    while True:
        c, _ = s.accept()
        d = c.recv(2048)
        c.sendall(b"echo:" + d); c.close()
for p in filter(None, sys.argv[2].split(",")):
    threading.Thread(target=udp, args=(int(p),), daemon=True).start()
for p in filter(None, sys.argv[3].split(",")):
    threading.Thread(target=tcp, args=(int(p),), daemon=True).start()
threading.Event().wait()
PY
cat > "$WORK/probe.py" <<'PY'
import socket, sys
proto, host, port = sys.argv[1], sys.argv[2], int(sys.argv[3])
try:
    if proto == "udp":
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(2)
        s.sendto(b"ping", (host, port)); d = s.recv(2048)
    else:
        s = socket.create_connection((host, port), timeout=2); s.settimeout(2)
        s.sendall(b"ping"); d = s.recv(2048)
    print("OK" if d == b"echo:ping" else "BAD")
except Exception:
    print("FAIL")
PY

ip link set lo up
sysctl -qw net.ipv4.ip_forward=1 || fail "cannot enable forwarding in the private namespace"
for ns in otc otp otq; do ip netns add "$ns" || fail "cannot create netns $ns"; ip -n "$ns" link set lo up; done
ip link add wan0 type veth peer name c0 netns otc
ip link add ts-fwa type veth peer name p0 netns otp
ip link add ts-fwb type veth peer name q0 netns otq
ip addr add 10.88.1.1/24 dev wan0; ip link set wan0 up
ip -n otc addr add 10.88.1.2/24 dev c0; ip -n otc link set c0 up; ip -n otc route add default via 10.88.1.1
ip addr add 10.88.2.1/24 dev ts-fwa; ip link set ts-fwa up
ip -n otp addr add 10.88.2.2/24 dev p0; ip -n otp link set p0 up; ip -n otp route add default via 10.88.2.1
ip addr add 10.88.3.1/24 dev ts-fwb; ip link set ts-fwb up
ip -n otq addr add 10.88.3.2/24 dev q0; ip -n otq link set q0 up; ip -n otq route add default via 10.88.3.1

ip netns exec otp python3 "$WORK/echo.py" 10.88.2.2 5443,7443 5444 & PIDS+=($!)
ip netns exec otq python3 "$WORK/echo.py" 10.88.3.2 6443 6444 & PIDS+=($!)
ip netns exec otc python3 "$WORK/echo.py" 10.88.1.2 7444 "" & PIDS+=($!)
sleep 1

mk_inst() {
    local n="$1" dev="$2" peer="$3"; shift 3
    mkdir -p "$INST_DIR/$n"
    printf 'TYPE=gre\nROLE=client\nLOCAL_IP=10.88.1.1\nPEER_IP=10.88.9.9\nTUN_ADDR=10.201.40.1\nPEER_ADDR=%s\nPORT=51860\nKEY=\nDEV=%s\nMTU=1400\nSHAPE=none\n' "$peer" "$dev" > "$INST_DIR/$n/instance.conf"
    printf '%s\n' "$@" > "$INST_DIR/$n/pf.conf"
}
mk_inst fwa ts-fwa 10.88.2.2 udp:5443 tcp:5444
mk_inst fwb ts-fwb 10.88.3.2 udp:6443 tcp:6444

probe() { ip netns exec otc python3 "$WORK/probe.py" "$1" "$2" "$3"; }
probe_from_peer() { ip netns exec otp python3 "$WORK/probe.py" "$1" "$2" "$3"; }
jumps() { iptables -w -S FORWARD | grep -cxF -- "-A FORWARD -j $1"; }
chain_rules() { iptables -w -S "$1" 2>/dev/null | grep -c "^-A $1 "; }
chain_exists() { iptables -w -S "$1" >/dev/null 2>&1; }
lose_rules() {
    while iptables -w -D FORWARD -j "$1" 2>/dev/null; do :; done
    iptables -w -F "$1" 2>/dev/null; iptables -w -X "$1" 2>/dev/null
    return 0
}
docker_like() {
    iptables -w -N DOCKER-USER 2>/dev/null || true
    iptables -w -F DOCKER-USER
    iptables -w -A DOCKER-USER -j RETURN
    while iptables -w -D FORWARD -j DOCKER-USER 2>/dev/null; do :; done
    iptables -w -I FORWARD 1 -j DOCKER-USER
    iptables -w -P FORWARD DROP
}

docker_like
pf_apply_all fwa
[[ "$(probe udp 10.88.1.1 5443)" == OK ]] || fail "UDP forward through a FORWARD DROP policy carried nothing: $(iptables -w -S | tr '\n' '|')"
[[ "$(probe tcp 10.88.1.1 5444)" == OK ]] || fail "TCP forward through a FORWARD DROP policy carried nothing"
pf_apply_all fwa
[[ "$(jumps TSUITE_FWA)" == 1 && "$(chain_rules TSUITE_FWA)" == 6 ]] || fail "re-apply did not keep exactly one jump and six accepts: $(iptables -w -S | tr '\n' '|')"

[[ "$(probe udp 10.88.2.2 5443)" != OK ]] || fail "untranslated UDP routed straight to the tunnel peer was accepted"
[[ "$(probe tcp 10.88.2.2 5444)" != OK ]] || fail "untranslated TCP routed straight to the tunnel peer was accepted"

iptables -w -t nat -A PREROUTING -i wan0 -p udp --dport 7443 -j DNAT --to-destination 10.88.2.2:7443
[[ "$(probe udp 10.88.1.1 7443)" != OK ]] || fail "a DNAT that is not one of the instance's forwards was let through the tunnel device"
iptables -w -t nat -D PREROUTING -i wan0 -p udp --dport 7443 -j DNAT --to-destination 10.88.2.2:7443
iptables -w -t nat -A PREROUTING -i ts-fwa -p udp --dport 7444 -j DNAT --to-destination 10.88.1.2:7444
[[ "$(probe_from_peer udp 10.88.2.1 7444)" != OK ]] || fail "a connection started from the tunnel side was let through by the reply-direction accept"
iptables -w -t nat -D PREROUTING -i ts-fwa -p udp --dport 7444 -j DNAT --to-destination 10.88.1.2:7444

[[ "$(probe_from_peer udp 10.88.2.1 5443)" != OK ]] || fail "tunnel-initiated traffic to the instance's own forwarded port was reflected back out the tunnel"

lose_rules TSUITE_FWA
if ! { [[ "$(jumps TSUITE_FWA)" == 0 ]] && ! chain_exists TSUITE_FWA; }; then fail "could not simulate the reboot loss of the accept chain"; fi
[[ "$(probe udp 10.88.1.1 5443)" != OK ]] || fail "forward still worked without the accept chain, the DROP policy is not effective"
cmd_postup fwa
[[ "$(jumps TSUITE_FWA)" == 1 && "$(chain_rules TSUITE_FWA)" == 6 ]] || fail "unit start (_postup) did not rebuild the accept chain"
[[ "$(probe udp 10.88.1.1 5443)" == OK && "$(probe tcp 10.88.1.1 5444)" == OK ]] || fail "forward did not recover after the unit start"

for _ in $(seq 1 20); do
    ( pf_apply_all fwa ) & c1=$!
    ( pf_apply_all fwa ) & c2=$!
    wait "$c1" "$c2"
    [[ "$(jumps TSUITE_FWA)" == 1 && "$(chain_rules TSUITE_FWA)" == 6 ]] || fail "concurrent apply/apply on one instance corrupted its chain: $(iptables -w -S | tr '\n' '|')"
done
[[ "$(probe udp 10.88.1.1 5443)" == OK && "$(probe tcp 10.88.1.1 5444)" == OK ]] || fail "forward stopped after concurrent apply/apply"

pf_flush_chain fwa
iptables -w -P FORWARD ACCEPT
while iptables -w -D FORWARD -j DOCKER-USER 2>/dev/null; do :; done
pf_apply_all fwa
docker_like
[[ "$(probe udp 10.88.1.1 5443)" == OK && "$(probe tcp 10.88.1.1 5444)" == OK ]] || fail "forward broke when a Docker-like firewall started after the tunnel: $(iptables -w -S FORWARD | tr '\n' '|')"

pf_apply_all fwb
for _ in $(seq 1 20); do
    ( pf_apply_all fwa ) & a1=$!
    ( pf_apply_all fwb ) & a2=$!
    ( pf_flush_chain fwa ) & a3=$!
    wait "$a1" "$a2" "$a3"
done
pf_flush_chain fwa
if ! { [[ "$(jumps TSUITE_FWA)" == 0 ]] && ! chain_exists TSUITE_FWA; }; then fail "interleaving left state for the flushed instance: $(iptables -w -S | tr '\n' '|')"; fi
[[ "$(jumps TSUITE_FWB)" == 1 && "$(chain_rules TSUITE_FWB)" == 6 ]] || fail "interleaving did not leave exactly one jump and six accepts for the surviving instance: $(iptables -w -S | tr '\n' '|')"
[[ "$(probe udp 10.88.1.1 6443)" == OK && "$(probe tcp 10.88.1.1 6444)" == OK ]] || fail "surviving instance stopped forwarding after the interleaving"

pf_flush_chain fwb
if ! { [[ "$(jumps TSUITE_FWB)" == 0 ]] && ! chain_exists TSUITE_FWB; }; then fail "flush left state for fwb"; fi
iptables -w -S FORWARD | grep -qxF -- '-A FORWARD -j DOCKER-USER' || fail "teardown removed the Docker-like jump"
iptables -w -S FORWARD | grep -qxF -- '-P FORWARD DROP' || fail "teardown changed the FORWARD policy"

mk_inst fwd ts-fwd 10.88.9.9 udp:7200 udp:7201 udp:7202
pf_apply_all fwd
for _ in $(seq 1 20); do
    ( pf_add fwd udp 7300 ) & d1=$!
    ( pf_del fwd 7200 ) & d2=$!
    wait "$d1" "$d2"
    grep -qxF 'udp:7300' "$INST_DIR/fwd/pf.conf" || fail "concurrent pf-add lost its port under a racing pf-del: $(tr '\n' ',' < "$INST_DIR/fwd/pf.conf")"
    ! grep -qxF 'udp:7200' "$INST_DIR/fwd/pf.conf" || fail "concurrent pf-del did not remove its port: $(tr '\n' ',' < "$INST_DIR/fwd/pf.conf")"
    if ! grep -qxF 'udp:7201' "$INST_DIR/fwd/pf.conf" || ! grep -qxF 'udp:7202' "$INST_DIR/fwd/pf.conf"; then fail "concurrent add/del dropped an untouched port: $(tr '\n' ',' < "$INST_DIR/fwd/pf.conf")"; fi
    pf_del fwd 7300 >/dev/null 2>&1
    pf_add fwd udp 7200 >/dev/null 2>&1
done
pf_flush_chain fwd

_teardown_fwe() { _pf_flush_chain fwe; rm -rf "${INST_DIR:?}/fwe"; }
for _ in $(seq 1 15); do
    mkdir -p "$INST_DIR/fwe"
    printf 'TYPE=gre\nROLE=client\nLOCAL_IP=10.88.1.1\nPEER_IP=10.88.9.9\nTUN_ADDR=10.201.41.1\nPEER_ADDR=10.88.9.9\nPORT=51861\nKEY=\nDEV=ts-fwe\nMTU=1400\nSHAPE=none\n' > "$INST_DIR/fwe/instance.conf"
    printf 'udp:7400\n' > "$INST_DIR/fwe/pf.conf"
    pf_apply_all fwe
    ( with_pf_lock fwe _teardown_fwe ) & e1=$!
    ( pf_add fwe udp 7401 2>/dev/null ) & e2=$!
    wait "$e1" "$e2"
    if [[ ! -e "$INST_DIR/fwe/instance.conf" ]] && chain_exists TSUITE_FWE; then fail "instance removal raced a pf-add and left an orphaned filter chain with no config: $(iptables -w -S TSUITE_FWE 2>/dev/null | tr '\n' '|')"; fi
done
pf_fwd_drop TSUITE_FWE 2>/dev/null || true; rm -rf "$INST_DIR/fwe"

echo "PASSED - pf_forward_root_test: UDP and TCP forwards cross a FORWARD DROP policy, untranslated traffic, foreign DNATs and tunnel-initiated connections stay dropped, rules rebuilt on unit start and survive a late Docker-like firewall, 20-round apply/apply and apply/flush interleaving keeps the other instance intact, concurrent pf-add/pf-del never lose a port, instance removal under the pf lock never orphans a chain against a racing pf-add, exact teardown"
