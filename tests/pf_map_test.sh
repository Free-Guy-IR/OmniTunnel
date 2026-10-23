#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2317
set -u

SCRIPT="${1:-$(dirname "$0")/../omnitunnel.sh}"
SCRIPT="$(cd "$(dirname "$SCRIPT")" && pwd)/$(basename "$SCRIPT")"

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

eval "$(extract "tok_re inst_name_ok list_instances inst_path inst_conf inst_pf inst_exists load_inst type_is_hysteria dnat_chain norm_port pick_num rewrite_without pf_line_parse pf_line_fmt pf_entries pf_spec_parse with_pf_lock ipt pf_fwd_apply pf_fwd_drop _pf_flush_chain _pf_apply_all _pf_add _pf_del pf_log pf_backup pf_write pf_apply_all pf_add pf_del cmd_pf_del hy_creds hy_bw hy_render_config hy_relay_unit hy_reconcile_relays svc_name pick_instance pick_proto pick_fwd_port pf_confirm_del mux_conf menu_pf pause heading nitem rule_green")"
eval "$(grep -E '^(C_|G_)[A-Z_]+=' "$SCRIPT")"

FAILS=0
bad() { echo "FAIL: $*"; FAILS=$((FAILS+1)); }
need_root() { :; }
ok() { echo "OK: $*"; }
info() { echo "INFO: $*"; }
warn() { echo "WARN: $*"; }
die() { echo "DIE: $*" >&2; exit 1; }
logger() { :; }
banner() { :; }
pf_warn_conflicts() { :; }
hy_pf_reconcile() { :; }
iptables() { printf '%s\n' "$*" >> "$IPT"; case " $* " in *" -C "*) return 1;; esac; return 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ROOT_DIR="$WORK/etc"; INST_DIR="$ROOT_DIR/inst"; RUN_DIR="$WORK/run"; IPT="$WORK/ipt.log"
mkdir -p "$INST_DIR"
HY_MASQ_HOST="www.bing.com"; HY_RELAY="$WORK/socksfwd.py"

mk_inst() {
    mkdir -p "$INST_DIR/$1"
    printf 'TYPE=%s\nROLE=client\nLOCAL_IP=1.2.3.4\nPEER_IP=203.0.113.9\nTUN_ADDR=10.201.%s.1\nPEER_ADDR=10.201.%s.2\nPORT=%s\nKEY=%s\nDEV=ts-%s\nMTU=1400\nSHAPE=200\n' "${4:-gre}" "$2" "$2" "${5:-51820}" "$(printf 'a%.0s' {1..64})" "$1" > "$INST_DIR/$1/instance.conf"
    printf '%b' "$3" > "$INST_DIR/$1/pf.conf"
}
pfc() { tr '\n' ' ' < "$INST_DIR/$1/pf.conf" 2>/dev/null; }
dnats() { grep -- '-j DNAT' "$IPT" | sed -E 's/^-w( [0-9]+)? //' | sort; }

if [[ "${PF_MAP_RELAY:-}" == 1 ]]; then
    mount -t tmpfs pf-map-test /etc/systemd/system || { echo "FAIL: cannot shadow /etc/systemd/system"; exit 1; }
    SYSL="$WORK/systemctl.log"
    systemctl() { printf '%s\n' "$*" >> "$SYSL"; case "$1" in is-active) [[ -e "$WORK/active-${!#}" ]]; return;; esac; return 0; }
    hy_write_relay_script() { :; }
    mk_inst hyr 30 'tcp:443:8443\ntcp:80\n' hysteria 40000
    ( set -euo pipefail; hy_reconcile_relays hyr ) >/dev/null 2>&1 || bad "R1 hy_reconcile_relays failed"
    grep -q 'ExecStart=.* 0\.0\.0\.0 443 127\.0\.0\.1 40000 127\.0\.0\.1 8443$' /etc/systemd/system/omnitun-hyr-pf-443.service 2>/dev/null || bad "R1 the tcp relay for 443 does not dial the far side's port 8443"
    grep -q 'ExecStart=.* 0\.0\.0\.0 80 127\.0\.0\.1 40000 127\.0\.0\.1 80$' /etc/systemd/system/omnitun-hyr-pf-80.service 2>/dev/null || bad "R1 the plain tcp relay for 80 changed"
    : > "$WORK/active-omnitun-hyr-pf-443.service"; : > "$WORK/active-omnitun-hyr-pf-80.service"; : > "$SYSL"
    printf 'tcp:443:9443\ntcp:80\n' > "$INST_DIR/hyr/pf.conf"
    ( set -euo pipefail; hy_reconcile_relays hyr ) >/dev/null 2>&1 || bad "R2 hy_reconcile_relays failed"
    grep -q ' 127\.0\.0\.1 9443$' /etc/systemd/system/omnitun-hyr-pf-443.service 2>/dev/null || bad "R2 changing the target of 443 did not rewrite its relay unit"
    grep -qx 'restart omnitun-hyr-pf-443.service' "$SYSL" || bad "R2 the running relay for 443 was not restarted onto its new target"
    grep -qx 'restart omnitun-hyr-pf-80.service' "$SYSL" && bad "R2 the unchanged relay for 80 was bounced"
    [[ "$FAILS" -eq 0 ]] || exit 1
    echo "RELAY-CASE-PASSED"
    exit 0
fi

mk_inst m1 1 ''
: > "$IPT"
( set -euo pipefail; pf_add m1 tcp 443:8443 ) >/dev/null 2>&1 || bad "M1 pf-add m1 tcp 443:8443 failed"
[[ "$(pfc m1)" == "tcp:443:8443 " ]] || bad "M1 pf.conf is [$(pfc m1)], want [tcp:443:8443]"
dnats | grep -qx -- '-t nat -A TSUITE_M1 -p tcp --dport 443 -j DNAT --to-destination 10.201.1.2:8443' || bad "M1 no DNAT public 443 -> peer 10.201.1.2:8443 (got: $(dnats | tr '\n' '|'))"

mk_inst m2 2 ''
: > "$IPT"
( set -euo pipefail; pf_add m2 both 8080 ) >/dev/null 2>&1 || bad "M2 pf-add m2 both 8080 failed"
[[ "$(cat "$INST_DIR/m2/pf.conf")" == "$(printf 'tcp:8080\nudp:8080')" ]] || bad "M2 the plain form is no longer byte-compatible: [$(pfc m2)]"
[[ "$(dnats)" == "$(printf '%s\n' '-t nat -A TSUITE_M2 -p tcp --dport 8080 -j DNAT --to-destination 10.201.2.2:8080' '-t nat -A TSUITE_M2 -p udp --dport 8080 -j DNAT --to-destination 10.201.2.2:8080' | sort)" ]] || bad "M2 plain DNAT changed: $(dnats | tr '\n' '|')"

mk_inst m3 3 ''
( set -euo pipefail; pf_add m3 tcp 9000:9001,80,7000:7000 ) >/dev/null 2>&1 || bad "M3 pf-add with a mixed list failed"
[[ "$(pfc m3)" == "tcp:9000:9001 tcp:80 tcp:7000 " ]] || bad "M3 mixed list stored as [$(pfc m3)], want [tcp:9000:9001 tcp:80 tcp:7000]"

mk_inst m4 4 'tcp:400\n\nudp:53\ntcp:8080\n'
: > "$IPT"
( set -euo pipefail; pf_apply_all m4 ) >/dev/null 2>&1 || bad "M4 an old-format pf.conf no longer applies"
[[ "$(dnats)" == "$(printf '%s\n' '-t nat -A TSUITE_M4 -p tcp --dport 400 -j DNAT --to-destination 10.201.4.2:400' '-t nat -A TSUITE_M4 -p udp --dport 53 -j DNAT --to-destination 10.201.4.2:53' '-t nat -A TSUITE_M4 -p tcp --dport 8080 -j DNAT --to-destination 10.201.4.2:8080' | sort)" ]] || bad "M4 an old-format pf.conf applies differently: $(dnats | tr '\n' '|')"
mk_inst m4z 5 'tcp:0400\n'
: > "$IPT"
( set -euo pipefail; pf_apply_all m4z ) >/dev/null 2>&1
dnats | grep -qx -- '-t nat -A TSUITE_M4Z -p tcp --dport 400 -j DNAT --to-destination 10.201.5.2:400' || bad "M4 a zero-padded legacy line is not applied as decimal 400: $(dnats | tr '\n' '|')"

mk_inst m5 6 'tcp:443:8443\nudp:443:8443\ntcp:9000:9001\ntcp:9000\n'
( set -euo pipefail; pf_del m5 443 ) >/dev/null 2>&1 || bad "M5 pf-del m5 443 failed"
[[ "$(pfc m5)" == "tcp:9000:9001 tcp:9000 " ]] || bad "M5 pf-del 443 left [$(pfc m5)], want only the 9000 lines"
( set -euo pipefail; pf_del m5 9000:9001 ) >/dev/null 2>&1 || bad "M5 pf-del m5 9000:9001 failed"
[[ "$(pfc m5)" == "tcp:9000 " ]] || bad "M5 pf-del 9000:9001 left [$(pfc m5)], want [tcp:9000]"

mk_inst m6 7 'tcp:443:8443\n'
( set -euo pipefail; pf_add m6 tcp 443:9443 ) >/dev/null 2>&1; rc=$?
[[ $rc -ne 0 ]] || bad "M6 a second target for tcp/443 on the same tunnel was accepted"
[[ "$(pfc m6)" == "tcp:443:8443 " ]] || bad "M6 a conflicting pf-add changed pf.conf to [$(pfc m6)]"
( set -euo pipefail; pf_add m6 tcp 443:8443 ) >/dev/null 2>&1 || bad "M6 re-adding the identical mapping must be a no-op success"
[[ "$(pfc m6)" == "tcp:443:8443 " ]] || bad "M6 re-adding the identical mapping changed pf.conf to [$(pfc m6)]"

mk_inst m7 8 'tcp:1\n'
for spec in 0:1 1:70000 a:b 1:2:3 ''; do
    ( set -euo pipefail; pf_add m7 tcp "$spec" ) >/dev/null 2>&1; rc=$?
    [[ $rc -ne 0 ]] || bad "M7 pf-add with invalid '$spec' exited 0"
done
[[ "$(pfc m7)" == "tcp:1 " ]] || bad "M7 invalid specs changed pf.conf to [$(pfc m7)]"

mk_inst m8 9 'udp:5000:6000\nudp:7000\ntcp:443:8443\n' hysteria 40000
( set -euo pipefail; hy_render_config m8 "$WORK/m8.yaml" ) >/dev/null 2>&1 || bad "M8 hy_render_config failed"
grep -A1 -x '  - listen: 0.0.0.0:5000' "$WORK/m8.yaml" 2>/dev/null | grep -qx '    remote: 127.0.0.1:6000' || bad "M8 hysteria udp forward 5000 does not go to the far side's 6000"
grep -A1 -x '  - listen: 0.0.0.0:7000' "$WORK/m8.yaml" 2>/dev/null | grep -qx '    remote: 127.0.0.1:7000' || bad "M8 plain hysteria udp forward 7000 changed"
grep -q '443' "$WORK/m8.yaml" && bad "M8 a tcp forward leaked into the hysteria engine config"
( set -euo pipefail; HY_TCP_IN_CONFIG=1 hy_render_config m8 "$WORK/m8b.yaml" ) >/dev/null 2>&1
grep -A1 -x '  - listen: 0.0.0.0:443' "$WORK/m8b.yaml" 2>/dev/null | grep -qx '    remote: 127.0.0.1:8443' || bad "M8 python-less hysteria tcp forward 443 does not go to 8443"

TUI_DIR="$WORK/tui"; mkdir -p "$TUI_DIR"
sub="$(
    INST_DIR="$TUI_DIR"
    mk_inst tmap 10 'tcp:443:8443\nudp:443:8443\n'
    ( set -euo pipefail; pick_fwd_port tmap <<< '1' >/dev/null 2>&1; [[ "$PORT_PICK" == 443 ]] ) || bad "M10 pick_fwd_port does not hand back public port 443 for a mapped forward"
    out="$( ( set -euo pipefail; menu_pf <<< $'0\n' ) 2>&1 | sed 's/\x1b\[[0-9;]*[A-Za-z]//g')"
    grep -q 'tcp  443 -> peer port 8443' <<< "$out" || bad "M10 the TUI does not list the mapped forward as 443 -> peer port 8443"
    ( set -euo pipefail; menu_pf <<< $'1\n1\n1\n80:8080,81\n\n0\n' ) >/dev/null 2>&1
    if ! { grep -qx 'tcp:80:8080' "$INST_DIR/tmap/pf.conf" && grep -qx 'tcp:81' "$INST_DIR/tmap/pf.conf"; }; then bad "M10 the TUI does not accept public:target input (pf.conf: $(pfc tmap))"; fi
)"
[[ -z "$sub" ]] || printf '%s\n' "$sub"
FAILS=$((FAILS + $(grep -c '^FAIL:' <<< "$sub")))

if [[ "$(id -u)" -eq 0 ]] && command -v unshare >/dev/null 2>&1 && unshare -m true 2>/dev/null; then
    rout="$(unshare -m env PF_MAP_RELAY=1 bash "$0" "$SCRIPT" 2>&1)"
    if grep -q '^RELAY-CASE-PASSED' <<< "$rout"; then echo "relay case: ran and passed"; else echo "$rout"; FAILS=$((FAILS+1)); fi
else
    echo "SKIP: hysteria relay-unit case needs root and unshare -m"
fi

if [[ "$FAILS" -ne 0 ]]; then echo "pf_map_test: $FAILS failure(s)"; exit 1; fi
echo "PASSED - pf_map_test: public:target forwards store as proto:P:T, DNAT P to peer:T, plain forwards stay byte-compatible, old files load unchanged, mapped forwards are deletable and conflict-checked, hysteria and the TUI follow the mapping"
