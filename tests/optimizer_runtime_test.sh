#!/bin/bash
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
OPT="$here/../scripts/optimizer.sh"
[[ -f "$OPT" ]] || { echo "SKIP optimizer_runtime_test: scripts/optimizer.sh missing"; exit 0; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

export OMNITUN_INST_DIR="$tmp/inst"
export OMNITUN_RUN_DIR="$tmp/run"
export OMNITUN_OPT_STATE="$tmp/state"
export OMNITUN_OPT_TXQLEN=2000
export OMNITUN_FAKE_DIR="$tmp/fake"
export OMNITUN_FAKE_FROZEN="ts-flaky"
mkdir -p "$OMNITUN_INST_DIR/ok" "$OMNITUN_INST_DIR/bad" "$OMNITUN_INST_DIR/flaky" "$OMNITUN_RUN_DIR" "$OMNITUN_FAKE_DIR"

printf 'TYPE=icmp\nDEV=ts-ok\n'    > "$OMNITUN_INST_DIR/ok/instance.conf"
printf 'TYPE=icmp\nDEV=eth0\n'     > "$OMNITUN_INST_DIR/bad/instance.conf"
printf 'TYPE=icmp\nDEV=ts-flaky\n' > "$OMNITUN_INST_DIR/flaky/instance.conf"
echo 1000 > "$OMNITUN_FAKE_DIR/ts-ok.qlen"
echo 1000 > "$OMNITUN_FAKE_DIR/ts-flaky.qlen"

bindir="$tmp/bin"; mkdir -p "$bindir"
cat > "$bindir/ip" <<'EOS'
#!/bin/bash
dir="$OMNITUN_FAKE_DIR"
frozen=" ${OMNITUN_FAKE_FROZEN:-} "
rest="$*"; first="${1:-}"
dev=""; prev=""
for a in "$@"; do [[ "$prev" == dev ]] && dev="$a"; prev="$a"; done
sticky=" ${OMNITUN_FAKE_STICKY:-} "
if [[ "$rest" == *"link set dev "*" txqueuelen "* ]]; then
    val="${rest##*txqueuelen }"; val="${val%% *}"
    if [[ "$frozen" == *" $dev "* ]]; then :
    elif [[ "$sticky" == *" $dev "* ]]; then echo "${OMNITUN_FAKE_STICKVAL:-1500}" > "$dir/$dev.qlen"
    else echo "$val" > "$dir/$dev.qlen"; fi
    exit 0
fi
if [[ "$rest" == *"link show dev "* ]]; then
    [[ -f "$dir/$dev.qlen" ]] || exit 1
    [[ "$first" == "-o" ]] && echo "1: $dev: <POINTOPOINT,UP> mtu 1400 qlen $(cat "$dir/$dev.qlen") link/none"
    exit 0
fi
exit 0
EOS
chmod +x "$bindir/ip"
export PATH="$bindir:$PATH"

fails=0
pass() { echo "ok: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails+1)); }
qval() { cat "$OMNITUN_FAKE_DIR/$1.qlen" 2>/dev/null; }

out="$(bash "$OPT" recommend ok 2>&1)"
[[ "$out" == *"raise txqueuelen 1000 -> 2000"* ]] && pass "recommend raises below-threshold txqueuelen" || fail "recommend raises below-threshold txqueuelen"

bash "$OPT" apply ok >/dev/null 2>&1 && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] && pass "apply without --acknowledge refuses" || fail "apply without --acknowledge refuses"
[[ "$(qval ts-ok)" == 1000 ]] && pass "apply without --acknowledge did not mutate" || fail "apply without --acknowledge did not mutate"

bash "$OPT" apply ok --acknowledge >/dev/null 2>&1 && rc=0 || rc=$?
[[ "$rc" -eq 0 ]] && pass "apply --acknowledge succeeds" || fail "apply --acknowledge succeeds"
[[ "$(qval ts-ok)" == 2000 ]] && pass "apply set txqueuelen to recommended" || fail "apply set txqueuelen to recommended"
[[ -f "$OMNITUN_OPT_STATE/ts-ok.txqlen" && "$(sed -n 1p "$OMNITUN_OPT_STATE/ts-ok.txqlen")" == 1000 && "$(sed -n 2p "$OMNITUN_OPT_STATE/ts-ok.txqlen")" == 2000 ]] && pass "apply wrote a before/applied snapshot" || fail "apply wrote a before/applied snapshot"

bash "$OPT" rollback ok >/dev/null 2>&1 && rc=0 || rc=$?
[[ "$rc" -eq 0 ]] && pass "rollback succeeds" || fail "rollback succeeds"
[[ "$(qval ts-ok)" == 1000 ]] && pass "rollback restored original txqueuelen" || fail "rollback restored original txqueuelen"
[[ ! -f "$OMNITUN_OPT_STATE/ts-ok.txqlen" ]] && pass "rollback removed the snapshot" || fail "rollback removed the snapshot"

bash "$OPT" apply bad --acknowledge >/dev/null 2>&1 && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] && pass "apply refuses a non-allowlisted device" || fail "apply refuses a non-allowlisted device"

out="$(bash "$OPT" recommend bad 2>&1)"
[[ "$out" == *"not an OmniTunnel TUN device"* ]] && pass "recommend flags a non-allowlisted device" || fail "recommend flags a non-allowlisted device"

bash "$OPT" apply flaky --acknowledge >/dev/null 2>&1 && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] && pass "apply auto-reverts when validation fails" || fail "apply auto-reverts when validation fails"
[[ ! -f "$OMNITUN_OPT_STATE/ts-flaky.txqlen" ]] && pass "apply cleaned up snapshot after auto-revert" || fail "apply cleaned up snapshot after auto-revert"
[[ "$(qval ts-flaky)" == 1000 ]] && pass "flaky device unchanged after auto-revert" || fail "flaky device unchanged after auto-revert"

mkdir -p "$OMNITUN_OPT_STATE"
echo 1000 > "$OMNITUN_FAKE_DIR/ts-ok.qlen"; rm -f "$OMNITUN_OPT_STATE/ts-ok.txqlen"
(
    exec 9>"$OMNITUN_OPT_STATE/ts-ok.lock"
    flock -x 9
    sleep 1
) &
holder=$!
sleep 0.3
start_ns=$(date +%s%N)
bash "$OPT" apply ok --acknowledge >/dev/null 2>&1
end_ns=$(date +%s%N)
wait "$holder"
waited_ms=$(( (end_ns - start_ns) / 1000000 ))
[[ "$waited_ms" -ge 500 ]] && pass "apply blocks on a held per-device lock (waited ${waited_ms}ms)" || fail "apply does not serialize on the per-device lock (waited ${waited_ms}ms)"

bash "$OPT" rollback ok >/dev/null 2>&1 || true
echo 1000 > "$OMNITUN_FAKE_DIR/ts-ok.qlen"; rm -f "$OMNITUN_OPT_STATE/ts-ok.txqlen"
bash "$OPT" apply ok --acknowledge >/dev/null 2>&1 &
bash "$OPT" apply ok --acknowledge >/dev/null 2>&1 &
wait
snapval="$(sed -n 1p "$OMNITUN_OPT_STATE/ts-ok.txqlen" 2>/dev/null)"
[[ "$snapval" == 1000 ]] && pass "concurrent apply/apply preserves the original snapshot before (1000, not 2000)" || fail "concurrent apply/apply corrupted the snapshot before (got '${snapval:-none}')"
[[ "$(qval ts-ok)" == 2000 ]] && pass "concurrent apply/apply converged the device to recommended" || fail "concurrent apply/apply left the device at '$(qval ts-ok)'"
bash "$OPT" rollback ok >/dev/null 2>&1 && rc=0 || rc=$?
[[ "$rc" -eq 0 && "$(qval ts-ok)" == 1000 ]] && pass "rollback after concurrent apply restores 1000" || fail "rollback after concurrent apply restores 1000"

echo 1000 > "$OMNITUN_FAKE_DIR/ts-ok.qlen"; rm -f "$OMNITUN_OPT_STATE/ts-ok.txqlen"
bash "$OPT" apply ok --acknowledge >/dev/null 2>&1
bash "$OPT" rollback ok >/dev/null 2>&1 &
bash "$OPT" apply ok --acknowledge >/dev/null 2>&1 &
wait
fin_dev="$(qval ts-ok)"
fin_snap="$(sed -n 1p "$OMNITUN_OPT_STATE/ts-ok.txqlen" 2>/dev/null)"
[[ "$fin_dev" == 1000 || "$fin_dev" == 2000 ]] && pass "concurrent rollback+apply leaves the device at a known value ($fin_dev)" || fail "concurrent rollback+apply left the device at '${fin_dev:-none}'"
if [[ -z "$fin_snap" || "$fin_snap" == 1000 ]]; then pass "concurrent rollback+apply never corrupts the snapshot (${fin_snap:-absent})"; else fail "concurrent rollback+apply corrupted the snapshot (got '$fin_snap')"; fi
bash "$OPT" rollback ok >/dev/null 2>&1 || true

export OMNITUN_FAKE_STICKY="ts-stick"; export OMNITUN_FAKE_STICKVAL=1500
mkdir -p "$OMNITUN_INST_DIR/stick"
printf 'TYPE=icmp\nDEV=ts-stick\n' > "$OMNITUN_INST_DIR/stick/instance.conf"
echo 1000 > "$OMNITUN_FAKE_DIR/ts-stick.qlen"; rm -f "$OMNITUN_OPT_STATE/ts-stick.txqlen"
out="$(bash "$OPT" apply stick --acknowledge 2>&1)"; rc=$?
[[ "$rc" -ne 0 ]] && pass "apply fails when the revert cannot restore the device" || fail "apply fails when the revert cannot restore the device"
[[ "$out" == *"snapshot kept"* && "$out" == *1500* ]] && pass "apply reports the real current value and keeps the snapshot" || fail "apply reports the real current value and keeps the snapshot"
[[ -f "$OMNITUN_OPT_STATE/ts-stick.txqlen" && "$(cat "$OMNITUN_OPT_STATE/ts-stick.txqlen")" == 1000 ]] && pass "apply kept the honest original snapshot for manual recovery" || fail "apply kept the honest original snapshot for manual recovery"

printf '1000\n1500\n' > "$OMNITUN_OPT_STATE/ts-stick.txqlen"
echo 1500 > "$OMNITUN_FAKE_DIR/ts-stick.qlen"
out="$(bash "$OPT" rollback stick 2>&1)"; rc=$?
[[ "$rc" -ne 0 ]] && pass "rollback fails when the read-back does not match" || fail "rollback fails when the read-back does not match"
[[ "$out" == *"snapshot kept"* ]] && pass "rollback keeps the snapshot on a read-back mismatch" || fail "rollback keeps the snapshot on a read-back mismatch"
[[ -f "$OMNITUN_OPT_STATE/ts-stick.txqlen" ]] && pass "rollback did not delete the snapshot after a failed restore" || fail "rollback did not delete the snapshot after a failed restore"
unset OMNITUN_FAKE_STICKY OMNITUN_FAKE_STICKVAL

mkdir -p "$OMNITUN_OPT_STATE"
mkdir -p "$OMNITUN_INST_DIR/quoted"
printf 'TYPE="icmp"\nDEV="ts-ok"\n' > "$OMNITUN_INST_DIR/quoted/instance.conf"
echo 1000 > "$OMNITUN_FAKE_DIR/ts-ok.qlen"; rm -f "$OMNITUN_OPT_STATE/ts-ok.txqlen"
out="$(bash "$OPT" recommend quoted 2>&1)"
[[ "$out" == *"dev: ts-ok"* ]] && pass "quoted DEV resolves to ts-ok (surrounding quotes stripped)" || fail "quoted DEV resolves to ts-ok (got: $out)"
[[ "$out" != *'dev: "ts-ok"'* ]] && pass "quoted DEV does not keep the quotes" || fail "quoted DEV kept the quotes"
[[ "$out" == *"raise txqueuelen 1000 -> 2000"* ]] && pass "quoted DEV is accepted by the allowlist" || fail "quoted DEV rejected by the allowlist"
[[ "$out" != *"not an OmniTunnel TUN device"* ]] && pass "quoted DEV is not refused as non-TUN" || fail "quoted DEV wrongly refused as non-TUN"
bash "$OPT" apply quoted --acknowledge >/dev/null 2>&1 && rc=0 || rc=$?
[[ "$rc" -eq 0 && "$(qval ts-ok)" == 2000 ]] && pass "quoted DEV apply succeeds and mutates ts-ok" || fail "quoted DEV apply (rc=$rc dev=$(qval ts-ok))"
bash "$OPT" rollback quoted >/dev/null 2>&1 || true
echo 1000 > "$OMNITUN_FAKE_DIR/ts-ok.qlen"; rm -f "$OMNITUN_OPT_STATE/ts-ok.txqlen"

bash "$OPT" apply ok --acknowledge >/dev/null 2>&1
echo 1500 > "$OMNITUN_FAKE_DIR/ts-ok.qlen"
out="$(bash "$OPT" rollback ok 2>&1)"; rc=$?
[[ "$rc" -ne 0 ]] && pass "rollback aborts when the device drifted since apply" || fail "rollback aborts on drift"
[[ "$out" == *drifted* ]] && pass "rollback drift abort names the drift" || fail "rollback drift message (got: $out)"
[[ "$(qval ts-ok)" == 1500 ]] && pass "rollback on drift did not clobber the device (stayed 1500)" || fail "rollback on drift clobbered the device to '$(qval ts-ok)'"
[[ -f "$OMNITUN_OPT_STATE/ts-ok.txqlen" ]] && pass "rollback on drift kept the snapshot" || fail "rollback on drift deleted the snapshot"
rm -f "$OMNITUN_OPT_STATE/ts-ok.txqlen"; echo 1000 > "$OMNITUN_FAKE_DIR/ts-ok.qlen"

printf '1000\n' > "$OMNITUN_OPT_STATE/ts-ok.txqlen"
echo 2000 > "$OMNITUN_FAKE_DIR/ts-ok.qlen"
bash "$OPT" rollback ok >/dev/null 2>&1 && rc=0 || rc=$?
[[ "$rc" -eq 0 && "$(qval ts-ok)" == 1000 ]] && pass "legacy single-line snapshot still rolls back (no applied field)" || fail "legacy single-line snapshot rollback (rc=$rc dev=$(qval ts-ok))"
[[ ! -f "$OMNITUN_OPT_STATE/ts-ok.txqlen" ]] && pass "legacy snapshot removed after rollback" || fail "legacy snapshot not removed"
echo 1000 > "$OMNITUN_FAKE_DIR/ts-ok.qlen"; rm -f "$OMNITUN_OPT_STATE/ts-ok.txqlen"

mkdir -p "$OMNITUN_INST_DIR/swap"
printf 'TYPE=icmp\nDEV=ts-swap\n' > "$OMNITUN_INST_DIR/swap/instance.conf"
echo 1000 > "$OMNITUN_FAKE_DIR/ts-swap.qlen"
echo 1000 > "$OMNITUN_FAKE_DIR/ts-other.qlen"
rm -f "$OMNITUN_OPT_STATE/ts-swap.txqlen" "$OMNITUN_OPT_STATE/ts-other.txqlen"
(
    exec 9>"$OMNITUN_OPT_STATE/ts-swap.lock"
    flock -x 9
    sleep 1.2
) &
holder=$!
sleep 0.3
bash "$OPT" apply swap --acknowledge >"$tmp/swap.out" 2>&1 &
applypid=$!
sleep 0.3
printf 'TYPE=icmp\nDEV=ts-other\n' > "$OMNITUN_INST_DIR/swap/instance.conf"
wait "$holder"
wait "$applypid"; rc=$?
swapout="$(cat "$tmp/swap.out" 2>/dev/null)"
[[ "$rc" -ne 0 ]] && pass "apply aborts when the DEV mapping changes under the lock" || fail "apply aborts on under-lock DEV change (rc=$rc)"
[[ "$swapout" == *"changed under lock"* ]] && pass "apply names the under-lock DEV change" || fail "apply under-lock message (got: $swapout)"
[[ "$(qval ts-swap)" == 1000 ]] && pass "apply did not mutate the pre-lock device after the mapping change" || fail "apply mutated ts-swap to '$(qval ts-swap)'"
[[ "$(qval ts-other)" == 1000 ]] && pass "apply did not mutate the swapped-in device either" || fail "apply mutated ts-other to '$(qval ts-other)'"
[[ ! -f "$OMNITUN_OPT_STATE/ts-swap.txqlen" ]] && pass "apply left no snapshot after the under-lock abort" || fail "apply left a stray snapshot after the under-lock abort"

mkdir -p "$OMNITUN_INST_DIR/rbswap"
printf 'TYPE=icmp\nDEV=ts-rba\n' > "$OMNITUN_INST_DIR/rbswap/instance.conf"
echo 1000 > "$OMNITUN_FAKE_DIR/ts-rba.qlen"
echo 1000 > "$OMNITUN_FAKE_DIR/ts-rbb.qlen"
rm -f "$OMNITUN_OPT_STATE/ts-rba.txqlen" "$OMNITUN_OPT_STATE/ts-rbb.txqlen"
bash "$OPT" apply rbswap --acknowledge >/dev/null 2>&1
[[ "$(qval ts-rba)" == 2000 && "$(sed -n 1p "$OMNITUN_OPT_STATE/ts-rba.txqlen")" == 1000 && "$(sed -n 2p "$OMNITUN_OPT_STATE/ts-rba.txqlen")" == 2000 ]] && pass "rollback-dev-change setup: apply on ts-rba wrote a before/applied snapshot" || fail "rollback-dev-change setup (dev=$(qval ts-rba))"
(
    exec 9>"$OMNITUN_OPT_STATE/ts-rba.lock"
    flock -x 9
    sleep 1.2
) &
holder=$!
sleep 0.3
bash "$OPT" rollback rbswap >"$tmp/rbswap.out" 2>&1 &
rbpid=$!
sleep 0.3
printf 'TYPE=icmp\nDEV=ts-rbb\n' > "$OMNITUN_INST_DIR/rbswap/instance.conf"
wait "$holder"
wait "$rbpid"; rc=$?
rbout="$(cat "$tmp/rbswap.out" 2>/dev/null)"
[[ "$rc" -ne 0 ]] && pass "rollback aborts when the DEV mapping changes under the lock" || fail "rollback aborts on under-lock DEV change (rc=$rc)"
[[ "$rbout" == *"changed under lock"* ]] && pass "rollback names the under-lock DEV change" || fail "rollback under-lock message (got: $rbout)"
[[ "$(qval ts-rba)" == 2000 ]] && pass "rollback did not clobber the pre-lock device after the mapping change (ts-rba stayed 2000)" || fail "rollback clobbered ts-rba to '$(qval ts-rba)'"
[[ "$(qval ts-rbb)" == 1000 ]] && pass "rollback did not touch the swapped-in device (ts-rbb stayed 1000)" || fail "rollback mutated ts-rbb to '$(qval ts-rbb)'"
[[ -f "$OMNITUN_OPT_STATE/ts-rba.txqlen" && "$(sed -n 1p "$OMNITUN_OPT_STATE/ts-rba.txqlen")" == 1000 && "$(sed -n 2p "$OMNITUN_OPT_STATE/ts-rba.txqlen")" == 2000 ]] && pass "rollback preserved the snapshot after the under-lock abort" || fail "rollback lost or altered the snapshot after the under-lock abort"
rm -f "$OMNITUN_OPT_STATE/ts-rba.txqlen" "$OMNITUN_OPT_STATE/ts-rbb.txqlen"

if [[ "$fails" -ne 0 ]]; then echo "optimizer_runtime_test: $fails failure(s)"; exit 1; fi
echo "optimizer_runtime_test PASS"
