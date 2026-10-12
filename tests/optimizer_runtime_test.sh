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
if [[ "$rest" == *"link set dev "*" txqueuelen "* ]]; then
    val="${rest##*txqueuelen }"; val="${val%% *}"
    [[ "$frozen" == *" $dev "* ]] || echo "$val" > "$dir/$dev.qlen"
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
[[ -f "$OMNITUN_OPT_STATE/ts-ok.txqlen" && "$(cat "$OMNITUN_OPT_STATE/ts-ok.txqlen")" == 1000 ]] && pass "apply wrote a snapshot" || fail "apply wrote a snapshot"

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

if [[ "$fails" -ne 0 ]]; then echo "optimizer_runtime_test: $fails failure(s)"; exit 1; fi
echo "optimizer_runtime_test PASS"
