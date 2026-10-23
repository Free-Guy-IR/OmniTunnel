#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2317
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

eval "$(extract "tok_re inst_name_ok tok_ipv4_ok list_instances inst_path inst_conf inst_pf inst_exists load_inst type_is_hysteria dnat_chain norm_port rewrite_without pf_line_parse pf_line_fmt pf_entries pf_spec_parse pf_lock pf_unlock pf_log pf_backup pf_write pf_apply_all pf_add pf_del nat_scan_awk nat_scan nat_rules_for pf_classify pf_chain_owner pf_describe pf_warn_conflicts pf_is_private pf_target_state pf_problems pf_status_report pf_probe pf_check")"
eval "$(grep -E '^(C_|G_)[A-Z_]+=' "$SCRIPT")"

FAILS=0
bad() { echo "FAIL: $*"; FAILS=$((FAILS+1)); }
need_root() { :; }
ok() { echo "OK: $*"; }
info() { echo "INFO: $*"; }
warn() { echo "WARN: $*"; }
die() { echo "DIE: $*" >&2; exit 1; }
logger() { :; }
hy_pf_reconcile() { :; }

WORK="$(mktemp -d)"
LPIDS=()
cleanup() { local p; for p in ${LPIDS[@]+"${LPIDS[@]}"}; do kill "$p" 2>/dev/null; done; rm -rf "$WORK"; }
trap cleanup EXIT
ROOT_DIR="$WORK/etc"; INST_DIR="$ROOT_DIR/inst"
mkdir -p "$INST_DIR"
PF_IPT_NAMES="$WORK/no-legacy"

mk_inst() {
    mkdir -p "$INST_DIR/$1"
    printf 'TYPE=%s\nROLE=client\nLOCAL_IP=1.2.3.4\nPEER_IP=203.0.113.9\nTUN_ADDR=10.201.%s.1\nPEER_ADDR=10.201.%s.2\nPORT=51820\nKEY=\nDEV=ts-%s\nMTU=1400\n' "${4:-gre}" "$2" "$2" "$1" > "$INST_DIR/$1/instance.conf"
    printf '%b' "$3" > "$INST_DIR/$1/pf.conf"
}

cat > "$WORK/ruleset.nft" <<'EOF'
# Warning: table ip nat is managed by iptables-nft, do not touch!
table ip nat {
	chain PREROUTING {
		type nat hook prerouting priority dstnat; policy accept;
		counter packets 10 bytes 600 jump TSUITE_MOOO
		counter packets 5 bytes 300 jump TSUITE_OLD
		meta l4proto tcp tcp dport 8080 counter packets 0 bytes 0 dnat to 10.202.50.2:8080
		fib daddr type local counter packets 0 bytes 0 jump DOCKER
	}
	chain TSUITE_MOOO {
		meta l4proto tcp tcp dport 700 counter packets 84 bytes 5040 dnat to 10.201.6.2:700
		meta l4proto udp udp dport 700 counter packets 3 bytes 180 dnat to 10.201.6.2:700
		meta l4proto tcp tcp dport 4702 counter packets 0 bytes 0 dnat to 10.201.6.2:4702
		meta l4proto udp udp dport 4702 counter packets 0 bytes 0 dnat to 10.201.6.2:4702
		meta l4proto tcp tcp dport 8080 counter packets 7 bytes 420 dnat to 10.201.6.2:8080
		meta l4proto tcp tcp dport 5000 counter packets 2 bytes 120 dnat to 10.201.6.2:6000
	}
	chain TSUITE_OLD {
		meta l4proto tcp tcp dport 700 counter packets 0 bytes 0 dnat to 10.201.5.2:700
	}
	chain DOCKER {
		iifname "docker0" counter packets 0 bytes 0 return
		iifname != "docker0" meta l4proto tcp tcp dport 5000 counter packets 0 bytes 0 dnat to 172.17.0.2:80
	}
	chain POSTROUTING {
		type nat hook postrouting priority srcnat; policy accept;
		oifname "ts-mooo" counter packets 0 bytes 0 masquerade
	}
}
table ip ackless_pf {
	set blocked {
		type ipv4_addr
		elements = { 1.2.3.4, 5.6.7.8,
			     9.9.9.9 }
	}
	chain pre {
		type nat hook prerouting priority -120; policy accept;
		tcp dport 4702 counter packets 526 bytes 31560 dnat to 10.204.50.2:702
		tcp dport { 4400, 4401-4410 } dnat to 10.204.50.2:400
	}
}
table inet same {
	chain pre {
		type nat hook prerouting priority dstnat; policy accept;
		meta l4proto { tcp, udp } th dport 700 dnat ip to 10.9.9.9:700
	}
}
table ip late {
	chain pre {
		type nat hook prerouting priority 10; policy accept;
		udp dport 4702 dnat to 10.201.6.9:4702
	}
}
table ip filt {
	chain input {
		type filter hook input priority filter; policy accept;
		tcp dport 700 accept
	}
}
EOF
nft() { [[ "$*" == "list ruleset" ]] && cat "$WORK/ruleset.nft"; }
iptables() { case "$1" in -V) echo "iptables v1.8.7 (nf_tables)";; esac; return 0; }
ip() {
    case "$*" in
        "-4 route get 10.204.50.2"|"-4 route get 10.202.50.2"|"-4 route get 10.9.9.9") echo "${4} via 172.31.1.1 dev eth0 src 172.31.1.5 uid 0";;
        "-4 route get 10.201.5.2") echo "10.201.5.2 dev ts-old src 10.201.5.1 uid 0";;
        "-4 route get 10.201.6.2"|"-4 route get 10.201.6.9") echo "${4} dev ts-mooo src 10.201.6.1 uid 0";;
        "-4 route get 172.17.0.2") echo "172.17.0.2 dev docker0 src 172.17.0.1 uid 0";;
        "-o link show dev ts-old") echo "9: ts-old: <POINTOPOINT,NOARP> mtu 1400 qdisc noop state DOWN";;
        "-o link show dev ts-mooo") echo "7: ts-mooo: <POINTOPOINT,NOARP,UP,LOWER_UP> mtu 1400 state UNKNOWN";;
        "-o link show dev docker0") echo "3: docker0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 state UP";;
        *) return 1;;
    esac
}
ping() {
    case "${!#}" in
        10.201.6.2|172.17.0.2) printf '3 packets transmitted, 3 received, 0%% packet loss, time 2003ms\nrtt min/avg/max/mdev = 40.1/41.5/43.0/1.1 ms\n'; return 0;;
    esac
    printf '3 packets transmitted, 0 received, 100%% packet loss\n'; return 1
}

mk_inst mooo 6 'tcp:700\nudp:700\ntcp:4702\nudp:4702\ntcp:8080\ntcp:5000:6000\n'
mk_inst old 5 'tcp:700\n'

recs="$(nat_scan 2>&1)"
grep -qx -- '-120 [0-9]* nft ip ackless_pf pre pre tcp 4702 dnat 10.204.50.2:702 526' <<< "$recs" || bad "C1 nat_scan missed the -120 ackless_pf DNAT on tcp/4702 (records: $(tr '\n' '|' <<< "$recs"))"
grep -qx -- '-120 [0-9]* nft ip ackless_pf pre pre tcp 4400,4401-4410 dnat 10.204.50.2:400 -' <<< "$recs" || bad "C1 nat_scan did not parse a dport set with a range"
grep -qx -- '-100 [0-9]* nft ip nat TSUITE_MOOO PREROUTING tcp 700 dnat 10.201.6.2:700 84' <<< "$recs" || bad "C1 nat_scan missed this tunnel's own DNAT reached through PREROUTING -> TSUITE_MOOO"
grep -qx -- '-100 [0-9]* nft ip nat DOCKER PREROUTING tcp 5000 dnat 172.17.0.2:80 0' <<< "$recs" || bad "C1 nat_scan did not follow the conditional jump into DOCKER"
grep -qx -- '-100 [0-9]* nft inet same pre pre tcp,udp 700 dnat 10.9.9.9:700 -' <<< "$recs" || bad "C1 nat_scan did not read the inet l4proto set rule"
grep -q 'filt\|9\.9\.9\.9 \|masquerade' <<< "$recs" && bad "C1 nat_scan reported a non-DNAT or non-prerouting rule"
[[ "$(grep -c . <<< "$recs")" == 13 ]] || bad "C1 nat_scan returned $(grep -c . <<< "$recs") records, want 13"

out="$( ( set -euo pipefail; pf_add mooo tcp 4702 ) 2>&1 )"
grep -q 'tcp/4702: table ip ackless_pf, chain pre (prerouting priority -120) sends it to 10.204.50.2:702 BEFORE this forward' <<< "$out" || bad "C2 pf-add did not warn that ackless_pf (priority -120) shadows tcp/4702: $out"
out="$( ( set -euo pipefail; pf_add mooo udp 700 ) 2>&1 )"
grep -q 'udp/700: table inet same, chain pre also sends it to 10.9.9.9:700 at the SAME priority -100' <<< "$out" || bad "C3 pf-add did not warn about the equal-priority DNAT in table inet same: $out"
out="$( ( set -euo pipefail; pf_add mooo tcp 8080 ) 2>&1 )"
grep -q 'WARN' <<< "$out" && bad "C4 pf-add warned about a DNAT that runs AFTER this forward: $out"

out="$( ( set -euo pipefail; pf_status_report mooo ) 2>&1 )"
grep -q "tcp/700: duplicate DNAT in OmniTunnel instance 'old' (prerouting priority -100) to 10.201.5.2:700 .*STALE - tunnel device ts-old is down" <<< "$out" || bad "C5 status did not flag the stale duplicate in instance 'old': $out"
grep -q 'tcp/8080: duplicate DNAT in table ip nat, chain PREROUTING (prerouting priority -100) to 10.202.50.2:8080 .*STALE - no tunnel carries 10.202.50.2' <<< "$out" || bad "C5 status did not flag the stale direct PREROUTING DNAT on 8080: $out"
grep -q 'tcp/4702: that rule is STALE - no tunnel carries 10.204.50.2' <<< "$out" || bad "C5 status did not flag the shadowing ackless_pf rule as stale: $out"
grep -q 'udp/4702: duplicate DNAT in table ip late, chain pre (prerouting priority 10) to 10.201.6.9:4702 .*STALE - 10.201.6.9 does not answer ping' <<< "$out" || bad "C5 status did not flag the dead lower-priority duplicate: $out"
grep -q 'tcp/5000: duplicate DNAT in table ip nat, chain DOCKER' <<< "$out" || bad "C5 status did not report the docker duplicate on 5000: $out"
grep -q 'tcp/5000.*STALE' <<< "$out" && bad "C5 a live docker target was called stale: $out"

pf_probe() { echo "probe:$1:$2:$3"; }
out="$( ( set -euo pipefail; pf_check mooo ) 2>&1 | sed 's/\x1b\[[0-9;]*[A-Za-z]//g')"
grep -q 'tunnel: alive - ping 10.201.6.2: rtt 41.5 ms, loss 0%' <<< "$out" || bad "C6 pf-check does not report tunnel liveness: $out"
grep -qE 'tcp +700 +-> 10\.201\.6\.2:700 +rule packets: 84 +peer port: probe:tcp:10\.201\.6\.2:700' <<< "$out" || bad "C6 pf-check line for tcp/700 lacks the counter or the peer probe: $out"
grep -qE 'tcp +5000 +-> 10\.201\.6\.2:6000 +rule packets: 2 +peer port: probe:tcp:10\.201\.6\.2:6000' <<< "$out" || bad "C6 pf-check probes the public port instead of the mapped target port: $out"
grep -q 'problem(s) found' <<< "$out" || bad "C6 pf-check does not summarise the problems: $out"
eval "$(extract "pf_probe")"

mk_inst ghost 7 'tcp:9999\n'
out="$( ( set -euo pipefail; pf_status_report ghost ) 2>&1 )"
grep -q 'tcp/9999: this forward is not in the live ruleset' <<< "$out" || bad "C7 a forward missing from the ruleset is not reported: $out"

mk_inst hy 8 'tcp:4702\n' hysteria
out="$( ( set -euo pipefail; pf_status_report hy ) 2>&1 )"
grep -q 'tcp/4702: table ip ackless_pf, chain pre (prerouting priority -120) sends it to 10.204.50.2:702 BEFORE this forward' <<< "$out" || bad "C8 a DNAT that diverts a hysteria listener's port is not flagged: $out"

printf 'filter\nnat\n' > "$WORK/legacy-names"
cat > "$WORK/legacy.save" <<'EOF'
# Generated by iptables-save v1.8.4
*nat
:PREROUTING ACCEPT [0:0]
:TSUITE_LEG - [0:0]
:OBSC_DNAT - [0:0]
[12:720] -A PREROUTING -j TSUITE_LEG
[3:180] -A PREROUTING -j OBSC_DNAT
[0:0] -A PREROUTING -p udp -m multiport --dports 559,560:570 -j DNAT --to-destination 10.202.50.2
[9:540] -A TSUITE_LEG -p tcp -m tcp --dport 400 -j DNAT --to-destination 10.201.2.2:400
[0:0] -A OBSC_DNAT ! -p udp -j RETURN
[0:0] -A OBSC_DNAT -p tcp -m tcp --dport 400 -j DNAT --to-destination 10.152.0.2:400
COMMIT
EOF
sub="$(
    PF_IPT_NAMES="$WORK/legacy-names"
    nft() { return 1; }
    iptables() { case "$1" in -V) echo "iptables v1.8.4 (legacy)";; esac; return 0; }
    iptables-save() { [[ "$*" == "-c -t nat" ]] && cat "$WORK/legacy.save"; }
    recs="$(nat_scan 2>&1)"
    grep -qx -- '-100 [0-9]* legacy ip nat TSUITE_LEG PREROUTING tcp 400 dnat 10.201.2.2:400 9' <<< "$recs" || bad "C9 legacy iptables-save rules are not scanned with their counters: $(tr '\n' '|' <<< "$recs")"
    grep -qx -- '-100 [0-9]* legacy ip nat PREROUTING PREROUTING udp 559,560-570 dnat 10.202.50.2 0' <<< "$recs" || bad "C9 a legacy multiport range is not parsed"
    mk_inst leg 2 'tcp:400\n'
    out="$( ( set -euo pipefail; printf '%s\n' "$recs" | pf_classify leg tcp 400 ) 2>&1 )"
    if ! { grep -q '^OURS .* TSUITE_LEG ' <<< "$out" && grep -q '^LOSES .* OBSC_DNAT ' <<< "$out"; }; then bad "C9 legacy precedence: want OURS for TSUITE_LEG and LOSES for OBSC_DNAT: $out"; fi
)"
[[ -z "$sub" ]] || printf '%s\n' "$sub"
FAILS=$((FAILS + $(grep -c '^FAIL:' <<< "$sub")))

if command -v python3 >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1; then
    free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'; }
    TP="$(free_port)"; UP="$(free_port)"; CP="$(free_port)"; UC="$(free_port)"
    python3 -c 'import socket,sys,time; s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(4); time.sleep(30)' "$TP" &
    LPIDS+=("$!")
    python3 -c 'import socket,sys
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.bind(("127.0.0.1", int(sys.argv[1]))); s.settimeout(30)
while True:
    d, a = s.recvfrom(2048); s.sendto(d, a)' "$UP" &
    LPIDS+=("$!")
    sleep 1
    [[ "$(pf_probe tcp 127.0.0.1 "$TP")" == "open (tcp connect ok)" ]] || bad "C10 pf-check TCP probe did not see an open port"
    [[ "$(pf_probe tcp 127.0.0.1 "$CP")" == "CLOSED or filtered (tcp connect failed)" ]] || bad "C10 pf-check TCP probe called a closed port open"
    [[ "$(pf_probe udp 127.0.0.1 "$UP")" == "open (udp reply)" ]] || bad "C10 pf-check UDP probe missed a replying service"
    [[ "$(pf_probe udp 127.0.0.1 "$UC")" == "CLOSED (ICMP port unreachable)" ]] || bad "C10 pf-check UDP probe did not report ICMP port unreachable"
else
    echo "SKIP: C10 needs python3 and timeout"
fi

if [[ "$FAILS" -ne 0 ]]; then echo "pf_check_test: $FAILS failure(s)"; exit 1; fi
echo "PASSED - pf_check_test: nat ruleset scan (nft + iptables-legacy, sets, ranges, jumps), shadowing/equal-priority warnings on pf-add, stale and duplicate DNAT reports in status, pf-check counters, mapped-port probes and tunnel liveness"
