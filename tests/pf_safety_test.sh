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

eval "$(extract "tok_re inst_name_ok validate_inst_name list_instances inst_path inst_conf inst_pf inst_exists load_inst create_inst type_is_hysteria type_is_stripe type_is_ackless type_is_kernel type_is_revmux type_uses_key type_known dnat_chain norm_port pick_num rewrite_without lanes_ok tok_host_ok tok_ipv4_ok tok_port_ok tok_nc_ok tok_hexkey_ok tok_key_ok tok_shape_ok tok_pmode_ok cmd_server_token pf_line_parse pf_line_fmt pf_entries pf_spec_parse with_pf_lock ipt pf_fwd_apply pf_fwd_drop _pf_flush_chain _pf_apply_all _pf_add _pf_del pf_log pf_backup pf_write pf_archive_removed pf_apply_all pf_add pf_del cmd_pf_del pf_flush_chain pf_confirm_del pick_instance pick_proto pick_fwd_port mux_conf menu_pf _inst_remove_fwd inst_remove pause heading nitem rule_green _drule svc_name cmd_bench_manual _bench_key_for cmd_bench_server bench_run")"
eval "$(grep -E '^(C_|G_)[A-Z_]+=' "$SCRIPT")"
eval "$(grep -m1 '^ALL_TYPES=' "$SCRIPT")"
eval "$(grep -m1 '^UI_W=' "$SCRIPT")"

FAILS=0
bad() { echo "FAIL: $*"; FAILS=$((FAILS+1)); }
need_root() { :; }
ok() { echo "OK: $*"; }
info() { echo "INFO: $*"; }
warn() { echo "WARN: $*"; }
die() { echo "DIE: $*" >&2; exit 1; }
logger() { :; }
banner() { :; }
iptables() { printf '%s\n' "$*" >> "$WORK/ipt.log"; case " $* " in *" -C "*) return 1;; esac; return 0; }
systemctl() { return 0; }
inst_running() { return 0; }
inst_enable() { :; }
ensure_binary() { :; }
ensure_hysteria() { :; }
ensure_omnistripe() { :; }
ensure_omniackless() { :; }
mux_remove() { :; }
hy_remove_relays() { :; }
inst_cleanup_residue() { :; }
inst_nft_cleanup() { :; }
pf_warn_conflicts() { :; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ROOT_DIR="$WORK/etc"; INST_DIR="$ROOT_DIR/inst"; RUN_DIR="$WORK/run"
mkdir -p "$INST_DIR"

mk_inst() {
    local n="$1" role="${2:-client}" sub="${3:-1}"
    mkdir -p "$INST_DIR/$n"
    printf 'TYPE=gre\nROLE=%s\nLOCAL_IP=1.2.3.4\nPEER_IP=203.0.113.9\nTUN_ADDR=10.201.%s.1\nPEER_ADDR=10.201.%s.2\nPORT=51820\nKEY=\nDEV=ts-%s\nMTU=1400\n' "$role" "$sub" "$sub" "$n" > "$INST_DIR/$n/instance.conf"
    printf '%b' "${4:-}" > "$INST_DIR/$n/pf.conf"
}
pfc() { cat "$INST_DIR/$1/pf.conf" 2>/dev/null; }
fwd_lines() { grep -c . "$INST_DIR/$1/pf.conf" 2>/dev/null || true; }
backups() { local b=("$INST_DIR/$1"/pf.conf.bak-*); [[ -e "${b[0]}" ]] && echo "${#b[@]}" || echo 0; }
newest_bak() { local b=("$INST_DIR/$1"/pf.conf.bak-*); [[ -e "${b[0]}" ]] && echo "${b[-1]}"; }
stamp() { stat -c '%i %Y %s' "$INST_DIR/$1/pf.conf" 2>/dev/null; }

mk_inst one client 1 'tcp:400\nudp:400\n'
before="$(pfc one)"
( set -euo pipefail; pf_del one 400 ) >/dev/null 2>&1; rc=$?
[[ $rc -ne 0 ]] || bad "S1 pf-del of the LAST forward (no --force) exited 0"
[[ "$(pfc one)" == "$before" ]] || bad "S1 pf-del of the LAST forward (no --force) changed pf.conf to [$(pfc one | tr '\n' ' ')]"
grep -q 'REFUSED' "$ROOT_DIR/pf.log" 2>/dev/null || bad "S1 the refused emptying is not logged in $ROOT_DIR/pf.log"

( set -euo pipefail; PF_FORCE=1; pf_del one 400 ) >/dev/null 2>&1; rc=$?
[[ $rc -eq 0 ]] || bad "S2 pf-del with force failed (rc=$rc)"
[[ "$(fwd_lines one)" == 0 ]] || bad "S2 pf-del with force did not empty pf.conf"
newest="$(newest_bak one)"
if [[ -z "$newest" ]]; then bad "S2 emptying pf.conf kept no pf.conf.bak-<ts> backup"
elif [[ "$(cat "$newest")" != "$before" ]]; then bad "S2 the backup does not hold the previous forwards"; fi
grep -q 'EMPTIED' "$ROOT_DIR/pf.log" 2>/dev/null || bad "S2 the forced emptying is not logged in $ROOT_DIR/pf.log"

mk_inst two client 2 'tcp:443\n'
( set -euo pipefail; cmd_pf_del two 443 --force ) >/dev/null 2>&1; rc=$?
[[ $rc -eq 0 && "$(fwd_lines two)" == 0 ]] || bad "S2 'pf-del <inst> <port> --force' did not remove the last forward (rc=$rc)"

mk_inst junk client 13 'tcp:400\n#note\n \n'
jbefore="$(pfc junk)"
( set -euo pipefail; pf_del junk 400 ) >/dev/null 2>&1; rc=$?
[[ $rc -ne 0 && "$(pfc junk)" == "$jbefore" ]] || bad "S1 pf-del of the last real forward next to a comment/blank line went through without --force (rc=$rc, pf.conf now [$(pfc junk | tr '\n' ' ')])"

mk_inst three client 3 ''
for p in 1001 1002 1003 1004 1005 1006 1007 1008; do
    ( set -euo pipefail; pf_add three tcp "$p" ) >/dev/null 2>&1 || bad "S3 pf-add three tcp $p failed"
done
[[ "$(backups three)" == 5 ]] || bad "S3 expected exactly the last 5 pf.conf.bak-<ts> backups after 8 changes, found $(backups three)"
newest="$(newest_bak three)"
want="$(printf 'tcp:%s\n' 1001 1002 1003 1004 1005 1006 1007)"
[[ -n "$newest" && "$(cat "$newest")" == "$want" ]] || bad "S3 the newest backup is not the list as it was before the last change"
[[ "$(grep -c 'three pf-add' "$ROOT_DIR/pf.log" 2>/dev/null || true)" == 8 ]] || bad "S3 not every pf-add change is logged"

mk_inst four client 4 'tcp:80\n'
ino1="$(stat -c %i "$INST_DIR/four/pf.conf")"
( set -euo pipefail; pf_add four tcp 81 ) >/dev/null 2>&1 || bad "S4 pf-add four tcp 81 failed"
ino2="$(stat -c %i "$INST_DIR/four/pf.conf")"
[[ "$ino1" != "$ino2" ]] || bad "S4 pf-add edited pf.conf in place (same inode) instead of an atomic temp+rename"
[[ "$(pfc four)" == "$(printf 'tcp:80\ntcp:81')" ]] || bad "S4 pf-add result is [$(pfc four | tr '\n' ' ')]"
[[ -z "$(find "$INST_DIR/four" -name '.pf.conf.*')" ]] || bad "S4 a temp file was left behind"
[[ "$(stat -c %a "$INST_DIR/four/pf.conf")" == 600 ]] || bad "S4 pf.conf mode is $(stat -c %a "$INST_DIR/four/pf.conf"), want 600"

mk_inst five client 5 'tcp:659\nudp:659\ntcp:660\nudp:660\n'
cbefore="$(cat "$INST_DIR/five/instance.conf")"; pbefore="$(pfc five)"
( set -euo pipefail; create_inst five gre client 1.2.3.4 198.51.100.1 51899 "" 10.201.99.1 10.201.99.2 ) >/dev/null 2>&1; rc=$?
[[ $rc -ne 0 ]] || bad "S5 create_inst on an EXISTING instance name succeeded"
[[ "$(pfc five)" == "$pbefore" ]] || bad "S5 create_inst on an existing instance wiped its forwards (now [$(pfc five | tr '\n' ' ')])"
[[ "$(cat "$INST_DIR/five/instance.conf")" == "$cbefore" ]] || bad "S5 create_inst on an existing instance rewrote its instance.conf"

mkdir -p "$INST_DIR/six"; printf 'tcp:9\n' > "$INST_DIR/six/pf.conf"
( set -euo pipefail; create_inst six gre client 1.2.3.4 198.51.100.1 51898 "" 10.201.98.1 10.201.98.2 ) >/dev/null 2>&1 || bad "S6 create_inst over a leftover dir failed"
[[ "$(fwd_lines six)" == 0 ]] || bad "S6 a new instance inherited a leftover pf.conf"
if ! grep -qx 'tcp:9' "$INST_DIR"/six/pf.conf.bak-* 2>/dev/null; then bad "S6 create_inst truncated a leftover pf.conf without keeping a backup"; fi

mk_inst seven client 7 'tcp:700\nudp:700\n'
tok="$(printf 'seven|gre|203.0.113.9|1.2.3.4|51820||10.201.7.2|10.201.7.1|none|16||1' | base64 | tr -d '\n')"
inst_remove() { rm -rf "${INST_DIR:?}/$1"; }
( set -euo pipefail; cmd_server_token "$tok" ) >/dev/null 2>&1; rc=$?
[[ $rc -ne 0 ]] || bad "S7 server-token replaced a local CLIENT instance that has forwards"
[[ "$(pfc seven)" == "$(printf 'tcp:700\nudp:700')" ]] || bad "S7 server-token destroyed the forwards of the local client 'seven'"
mk_inst eight server 8 ''
tok="$(printf 'eight|gre|203.0.113.9|1.2.3.4|51820||10.201.8.2|10.201.8.1|none|16||1' | base64 | tr -d '\n')"
( set -euo pipefail; cmd_server_token "$tok" ) >/dev/null 2>&1 || bad "S7 control: re-running a token over its own forward-less server instance must still work"
eval "$(extract "inst_remove")"

mk_inst nineA client 10 'tcp:1\nudp:1\n'
mk_inst nineB client 11 'tcp:5\nudp:5\ntcp:6\n'
bst="$(stamp nineB)"; bct="$(pfc nineB)"
( set -euo pipefail; pf_add nineA both 2 ) >/dev/null 2>&1
( set -euo pipefail; pf_del nineA 1 ) >/dev/null 2>&1
( set -euo pipefail; pf_apply_all nineA ) >/dev/null 2>&1
( set -euo pipefail; PF_FORCE=1; pf_del nineA 2 ) >/dev/null 2>&1
[[ "$(stamp nineB)" == "$bst" && "$(pfc nineB)" == "$bct" ]] || bad "S8 changing instance nineA touched nineB's pf.conf"

mk_inst ten client 12 'tcp:8443\nudp:8443\n'
( set -euo pipefail; inst_remove ten ) >/dev/null 2>&1 || bad "S9 inst_remove failed"
[[ ! -d "$INST_DIR/ten" ]] || bad "S9 inst_remove left the instance directory"
if ! grep -qx 'tcp:8443' "$ROOT_DIR"/removed/ten.pf.conf.bak-* 2>/dev/null; then bad "S9 removing an instance threw its forwards away without an archived copy"; fi

TUI_DIR="$WORK/tui"; mkdir -p "$TUI_DIR"
sub="$(
    INST_DIR="$TUI_DIR"
    mk_inst tui client 20 'tcp:700\nudp:700\n'
    ( set -euo pipefail; menu_pf <<< $'2\n1\n1\nn\n\n0\n' ) >/dev/null 2>&1
    [[ "$(pfc tui)" == "$(printf 'tcp:700\nudp:700')" ]] || bad "S10 TUI Remove-a-forward removed it although the confirmation was answered 'n'"
    ( set -euo pipefail; menu_pf <<< $'2\n1\n1\ny\n\n0\n' ) >/dev/null 2>&1
    [[ "$(fwd_lines tui)" == 0 ]] || bad "S10 TUI Remove-a-forward answered 'y' did not remove the forward"
    [[ -n "$(newest_bak tui)" ]] || bad "S10 TUI removal of the last forward kept no backup"
)"
[[ -z "$sub" ]] || printf '%s\n' "$sub"
FAILS=$((FAILS + $(grep -c '^FAIL:' <<< "$sub")))

sub="$(
    INST_DIR="$WORK/tui2"; mkdir -p "$INST_DIR"
    mk_inst race client 21 'tcp:443\ntcp:80\n'
    eval "_real_$(declare -f pf_del)"
    pf_del() { printf 'tcp:443\n' > "$INST_DIR/$1/pf.conf"; _real_pf_del "$@"; }
    ( set -euo pipefail; menu_pf <<< $'2\n1\n1\ny\n\n0\n' ) >/dev/null 2>&1
    [[ "$(pfc race)" == "tcp:443" ]] || bad "S10 a TUI removal confirmed while it was NOT the last forward emptied the instance after a concurrent pf-del made it the last (pf.conf now [$(pfc race | tr '\n' ' ')])"
)"
[[ -z "$sub" ]] || printf '%s\n' "$sub"
FAILS=$((FAILS + $(grep -c '^FAIL:' <<< "$sub")))

bt=""; for t in $ALL_TYPES; do type_is_hysteria "$t" || type_is_revmux "$t" || { bt="$t"; break; }; done
mk_inst "bench-$bt" client 31 'tcp:7000\nudp:7000\n'
pbefore="$(pfc "bench-$bt")"; cbefore="$(cat "$INST_DIR/bench-$bt/instance.conf")"
out="$(
    ALL_TYPES="$bt"; RAW_BASE="https://example.invalid"
    gen_key() { echo 00; }
    ping() { return 1; }
    nc() { return 1; }
    iperf3() { return 1; }
    sleep() { :; }
    bench_table() { :; }
    type_desc() { :; }
    ( set -euo pipefail; cmd_bench_manual 203.0.113.50 192.0.2.1 <<< $'\n\n' ) 2>&1
    echo "rc=$?"
)"
[[ "$(tail -n1 <<< "$out")" == "rc=0" ]] || bad "S11 the manual benchmark aborted ($(tail -n1 <<< "$out")) because a local instance named bench-$bt already exists"
[[ -d "$INST_DIR/bench-$bt" && "$(pfc "bench-$bt")" == "$pbefore" && "$(cat "$INST_DIR/bench-$bt/instance.conf" 2>/dev/null)" == "$cbefore" ]] || bad "S11 the manual benchmark overwrote or removed the existing local instance bench-$bt and its forwards"
grep -q "bench-$bt' already exists" <<< "$out" || bad "S11 the manual benchmark did not say why it skipped bench-$bt"

mkdir -p "$INST_DIR/half"; printf 'TYPE=gre\n' > "$INST_DIR/half/instance.conf"; : > "$INST_DIR/half/pf.conf"
tok="$(printf 'half|gre|203.0.113.9|1.2.3.4|51830||10.201.32.2|10.201.32.1|none|16||1' | base64 | tr -d '\n')"
( set -euo pipefail; cmd_server_token "$tok" ) >/dev/null 2>&1; rc=$?
[[ $rc -eq 0 ]] || bad "S7 re-running a token over a half-written instance (no ROLE, no forwards) is refused (rc=$rc) - the token is no longer retryable"
mk_inst stuck server 33 ''
tok="$(printf 'stuck|gre|203.0.113.9|1.2.3.4|51831||10.201.33.2|10.201.33.1|none|16||1' | base64 | tr -d '\n')"
out="$( inst_remove() { :; }; ( set -euo pipefail; cmd_server_token "$tok" ) 2>&1 )"; rc=$?
[[ $rc -ne 0 ]] && grep -q "could not remove the old instance 'stuck'" <<< "$out" || bad "S7 a token whose old instance could not be removed (pf lock busy) does not say so: rc=$rc [$(tail -n1 <<< "$out")]"

mk_inst "bench-$bt" server 34 'tcp:7100\n'
pbefore="$(pfc "bench-$bt")"
ktok="$(printf 'a%.0s' {1..64})"
btok="$(printf 'bench|203.0.113.50|192.0.2.1|%s|%s|%s' "$ktok" "$ktok" "$ktok" | base64 | tr -d '\n')"
out="$(
    ALL_TYPES="$bt"
    ensure_binary() { :; }
    iperf3() { :; }
    systemd-run() { :; }
    inst_remove() { :; }
    ( set -euo pipefail; cmd_bench_server "$btok" ) 2>&1
    echo "rc=$?"
)"
[[ "$(tail -n1 <<< "$out")" == "rc=0" ]] && grep -q 'benchmark server ready' <<< "$out" || bad "S11 bench-server aborted when it could not replace an old bench-$bt instance: $(tail -n2 <<< "$out" | tr '\n' ' ')"
[[ "$(pfc "bench-$bt")" == "$pbefore" ]] || bad "S11 bench-server overwrote the forwards of an instance it could not replace"

mk_inst "bench-$bt" client 35 'tcp:7200\n'
pbefore="$(pfc "bench-$bt")"
out="$(
    ALL_TYPES="$bt"; ASSET_DIR="$WORK/asset"; SCRIPT_DIR="$WORK/asset"; SCRIPT_PATH="$WORK/asset/omnitunnel.sh"
    mkdir -p "$ASSET_DIR/bin"; : > "$ASSET_DIR/bin/omnitun-amd64"
    ensure_binary() { :; }; save_peer() { :; }; default_local_ip() { echo 192.0.2.1; }; guard_peer_downgrade() { :; }
    iperf3() { return 1; }
    peer_ssh() { [[ "${2:-}" == "uname -m" ]] && echo x86_64; return 0; }
    peer_scp() { :; }; hy_local_bin() { return 1; }; omnistripe_local_bin() { return 1; }; omniackless_local_bin() { return 1; }
    bench_ensure_iperf() { :; }; bench_ensure_httpfile() { :; }; sleep() { :; }; ping() { return 1; }; nc() { return 1; }
    bench_create_id() { BENCH_ID=t1; }; bench_clean_abandoned() { :; }; next_subnet_idx() { echo 60; }
    bench_peer_remove() { :; }; bench_run_done() { :; }; bench_table() { :; }; type_desc() { :; }
    ( set -euo pipefail; bench_run <<< $'203.0.113.50\nroot\n\n\n\n\n' ) 2>&1
    echo "rc=$?"
)"
[[ -d "$INST_DIR/bench-$bt" && "$(pfc "bench-$bt")" == "$pbefore" ]] || bad "S11 the SSH benchmark said it skipped the existing local bench-$bt and then removed it in its cleanup: $(tail -n2 <<< "$out" | tr '\n' ' ')"
grep -q "bench-$bt' already exists" <<< "$out" || bad "S11 the SSH benchmark did not report the existing local bench-$bt"

if [[ "$FAILS" -ne 0 ]]; then echo "pf_safety_test: $FAILS failure(s)"; exit 1; fi
echo "PASSED - pf_safety_test: last-forward removal needs --force/confirmation and is logged, every change is atomic with the last 5 backups, create_inst and server-token never overwrite an existing instance's forwards, removal archives forwards, no cross-instance writes, the last-forward guard counts real forwards, a TUI removal is forced only when it was confirmed as the last, re-running a token over a half-written instance works and a stuck one is reported, no benchmark path replaces or removes an existing local instance"
