#!/usr/bin/env bash
set -u

SCRIPT="${1:-$(dirname "$0")/../omnitunnel.sh}"
SSHD=/usr/sbin/sshd
ROUNDS=100
SCP_ROUNDS=30

[[ $EUID -eq 0 ]] || { echo "SKIP ssh_pin_race_test: needs root to run throwaway sshds on 127.0.0.1"; exit 0; }
[[ -x "$SSHD" ]] || { echo "SKIP ssh_pin_race_test: $SSHD missing"; exit 0; }
for c in ssh scp ssh-keygen flock setsid timeout; do
    command -v "$c" >/dev/null 2>&1 || { echo "SKIP ssh_pin_race_test: $c missing"; exit 0; }
done
REAL_SSH="$(command -v ssh)"; REAL_SCP="$(command -v scp)"; REAL_KEYGEN="$(command -v ssh-keygen)"
BASE_PATH="$PATH"

extract() {
    awk -v names="$1" '
    BEGIN { n=split(names, a, " "); for (i=1;i<=n;i++) want[a[i]]=1 }
    inblock { print; if ($0 ~ /^}/) inblock=0; next }
    {
        if (match($0, /^[A-Za-z0-9_]+\(\)[ \t]*\{/)) {
            nm=$0; sub(/\(\).*/, "", nm)
            if (nm in want) { print; if ($0 !~ /\}[ \t]*$/) inblock=1 }
        }
    }' "$SCRIPT"
}

FAILS=0; PASSES=0
fail() { echo "FAIL: $1" >&2; FAILS=$((FAILS+1)); }
pass() { echo "ok: $1"; PASSES=$((PASSES+1)); }

D="$(mktemp -d)"; chmod 700 "$D"
PIDS=()
cleanup() {
    local p
    for p in ${PIDS[@]+"${PIDS[@]}"}; do kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; done
    rm -rf "$D"
}
forget_pid() {
    local p keep=()
    for p in ${PIDS[@]+"${PIDS[@]}"}; do [[ "$p" == "$1" ]] || keep+=("$p"); done
    PIDS=(${keep[@]+"${keep[@]}"})
}
trap cleanup EXIT
export PR_D="$D"

ROOT_DIR="$D/etc"; KH="$ROOT_DIR/ssh/known_hosts"; LOCK="$ROOT_DIR/ssh/.first-contact.lock"
mkdir -p "$ROOT_DIR/inst" "$ROOT_DIR/peers" "$ROOT_DIR/ssh"; chmod 700 "$ROOT_DIR/ssh"
: > "$KH"; chmod 600 "$KH"

{
    printf 'ROOT_DIR=%q\nINST_DIR=%q\nPEER_DIR=%q\nVERSION=0.0.1\n' "$ROOT_DIR" "$ROOT_DIR/inst" "$ROOT_DIR/peers"
    grep -E '^[CG]_[A-Z_]+=' "$SCRIPT"
    grep -E '^(SSH_KH_DIR|SSH_KNOWN_HOSTS|SSH_OPTS|SSH_KH_LOCK_WAIT|OMNI_TMP_FILES)=' "$SCRIPT"
    extract "need_root die ok info warn tok_re tok_host_ok tok_port_ok peer_conf _peer_creds _proxy_opts peer_ssh peer_scp ssh_kh_init ssh_accept_new_ok ssh_kh_name _hostkey_opts _hostkey_unlock die_loud tmp_track tmp_cleanup _peer_run hostkey_abort"
} > "$D/lib.sh"
grep -q '^_hostkey_opts()' "$D/lib.sh" || { echo "FAIL: could not extract _hostkey_opts from $SCRIPT" >&2; exit 1; }
bash -c 'source "$1"; [[ "$SSH_KNOWN_HOSTS" == "$2" ]]' _ "$D/lib.sh" "$KH" || { echo "FAIL: SSH_KNOWN_HOSTS is not $KH" >&2; exit 1; }

cat > "$D/drive.sh" <<'DRIVE'
#!/bin/bash
set -euo pipefail
. "$PR_D/lib.sh"
[[ -z "${PR_WAIT:-}" ]] || SSH_KH_LOCK_WAIT="$PR_WAIT"
exec {OMNI_ERR_FD}>&2
case "$1" in
    ssh)   peer_ssh 127.0.0.1 "touch $2" </dev/null;;
    subst) got="$(peer_ssh 127.0.0.1 "touch $2; echo via-subst" </dev/null)"; [[ "$got" == via-subst ]];;
    quiet) peer_ssh 127.0.0.1 "touch $2" </dev/null >/dev/null 2>&1;;
    scp)   peer_scp 127.0.0.1 "$PR_D/payload" "$2" </dev/null;;
    hold)  peer_ssh 127.0.0.1 "echo \$\$ > $2.pid; touch $2; exec sleep 30" </dev/null;;
esac
for fd in /proc/$$/fd/*; do
    [[ "$(readlink "$fd" 2>/dev/null)" != *.first-contact.lock ]] || { echo "LOCK-FD-LEAK $fd" >&2; exit 97; }
done
DRIVE
echo payload > "$D/payload"

port_free() { ! (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }
pick_port() {
    local p i
    for i in $(seq 1 200); do
        p=$(( 20000 + (RANDOM * 7 + i) % 40000 ))
        [[ "$p" != "${1:-}" ]] && port_free "$p" && { echo "$p"; return 0; }
    done
    return 1
}
P1="$(pick_port)" || { echo "SKIP ssh_pin_race_test: no free local port"; exit 0; }
P2="$(pick_port "$P1")" || { echo "SKIP ssh_pin_race_test: no free local port"; exit 0; }

ssh-keygen -q -t ed25519 -N '' -C k1 -f "$D/host1"
ssh-keygen -q -t ed25519 -N '' -C k2 -f "$D/host2"
ssh-keygen -q -t ed25519 -N '' -C client -f "$D/id"
cp "$D/id.pub" "$D/authorized_keys"
k1="$(awk '{print $2}' "$D/host1.pub")"; k2="$(awk '{print $2}' "$D/host2.pub")"

PENALTY_LINE=""
write_cfg() {
    cat > "$D/sshd_$1" <<CFG
Port $2
ListenAddress 127.0.0.1
HostKey $D/host$1
PidFile $D/sshd_$1.pid
AuthorizedKeysFile $D/authorized_keys
StrictModes no
UsePAM no
PubkeyAuthentication yes
PasswordAuthentication no
PermitRootLogin prohibit-password
MaxStartups 100:30:200
LogLevel INFO
$PENALTY_LINE
CFG
}
write_cfg 1 "$P1"
if "$SSHD" -t -f "$D/sshd_1" -o PerSourcePenalties=no >/dev/null 2>&1; then PENALTY_LINE="PerSourcePenalties no"; write_cfg 1 "$P1"; fi
write_cfg 2 "$P2"
terr="$("$SSHD" -t -f "$D/sshd_1" 2>&1)" || { echo "SKIP ssh_pin_race_test: sshd cannot run here: $terr"; exit 0; }
for n in 1 2; do
    "$SSHD" -D -f "$D/sshd_$n" -E "$D/sshd_$n.log" &
    PIDS+=("$!")
done
for p in "$P1" "$P2"; do
    for _ in $(seq 1 50); do port_free "$p" || break; sleep 0.1; done
    port_free "$p" && { echo "FAIL: sshd did not start on 127.0.0.1:$p" >&2; exit 1; }
done

cat > "$D/bin_ssh" <<SHIM
#!/bin/bash
conn=1
for a in "\$@"; do
    if [[ -n "\${HK_OLD_SSH:-}" && "\$a" == *StrictHostKeyChecking=accept-new* ]]; then
        echo 'command-line line 0: Bad yes/no/ask argument.' >&2; exit 255
    fi
    [[ "\$a" == -G || "\$a" == -V ]] && conn=0
done
dest=$P1; alias=()
if [[ \$conn == 1 && -n "\${PR_DEST_PORT:-}" ]]; then dest="\$PR_DEST_PORT"; alias=(-o "HostKeyAlias=[127.0.0.1]:$P1"); fi
[[ \$conn == 0 ]] || echo "ssh \$dest" >> "$D/connections"
exec "$REAL_SSH" -p "\$dest" \${alias[@]+"\${alias[@]}"} -i "$D/id" -o IdentitiesOnly=yes "\$@"
SHIM
cat > "$D/bin_scp" <<SHIM
#!/bin/bash
for a in "\$@"; do
    if [[ -n "\${HK_OLD_SSH:-}" && "\$a" == *StrictHostKeyChecking=accept-new* ]]; then
        echo 'command-line line 0: Bad yes/no/ask argument.' >&2; exit 255
    fi
done
dest=$P1; alias=()
if [[ -n "\${PR_DEST_PORT:-}" ]]; then dest="\$PR_DEST_PORT"; alias=(-o "HostKeyAlias=[127.0.0.1]:$P1"); fi
echo "scp \$dest" >> "$D/connections"
exec "$REAL_SCP" -P "\$dest" \${alias[@]+"\${alias[@]}"} -i "$D/id" -o IdentitiesOnly=yes "\$@"
SHIM
cat > "$D/bin_keygen" <<SHIM
#!/bin/bash
if [[ "\${1:-}" == -F && -e "$D/trigger" ]] && mv "$D/trigger" "$D/trigger.used" 2>/dev/null; then
    "$REAL_KEYGEN" "\$@"; rc=\$?
    env -u PR_DEST_PORT PATH="$D/bin:$BASE_PATH" HK_OLD_SSH=1 timeout 30 bash "$D/drive.sh" "\$(cat "$D/b_mode")" "$D/mark_B" >"$D/B.out" 2>&1 </dev/null
    echo \$? > "$D/B.rc"
    exit \$rc
fi
exec "$REAL_KEYGEN" "\$@"
SHIM
mkdir -p "$D/bin" "$D/binA"
mv "$D/bin_ssh" "$D/bin/ssh"; mv "$D/bin_scp" "$D/bin/scp"; mv "$D/bin_keygen" "$D/binA/ssh-keygen"
chmod 755 "$D/bin/ssh" "$D/bin/scp" "$D/binA/ssh-keygen"
: > "$D/connections"

PIN_NAME="[127.0.0.1]:$P1"
stored_key() { "$REAL_KEYGEN" -F "$PIN_NAME" -f "$KH" 2>/dev/null | awk '!/^#/ {print $3; exit}'; }
pin_count() { "$REAL_KEYGEN" -F "$PIN_NAME" -f "$KH" 2>/dev/null | grep -vc '^#'; }
accepted() { grep -c 'Accepted publickey' "$D/sshd_$1.log" 2>/dev/null || true; }
conns() { wc -l < "$D/connections"; }
lock_free() { flock -n "$LOCK" true 2>/dev/null; }
reset_round() {
    : > "$KH"
    rm -f "$D"/mark_* "$D"/A.* "$D"/B.* "$D/trigger" "$D/trigger.used"
}
old_drive() { HK_OLD_SSH=1 PATH="$D/bin:$BASE_PATH" timeout 60 bash "$D/drive.sh" "$@" </dev/null; }
DIAG=""
diag() { [[ -n "$DIAG" ]] || DIAG="$1"$'\n'"--- A:"$'\n'"$(head -c 1500 "$D/A.out" 2>/dev/null)"$'\n'"--- B (rc=$(cat "$D/B.rc" 2>/dev/null)):"$'\n'"$(head -c 1500 "$D/B.out" 2>/dev/null)"; }

reset_round
rc=0; old_drive ssh "$D/mark_N" >"$D/N.out" 2>&1 || rc=$?
if [[ $rc -eq 0 && -e "$D/mark_N" && "$(stored_key)" == "$k1" ]]; then pass "no race: pre-7.6 first contact pins the key and runs the command"
else fail "no race: first contact failed (rc=$rc): $(cat "$D/N.out")"; fi
if lock_free; then pass "no race: the first-contact lock is released after the connection"
else fail "no race: the first-contact lock is still held after the connection returned"; fi

run_injected() {
    local rounds="$1" amode_odd="$2" amode_even="$3" bmode_odd="$4" bmode_even="$5" tag="$6"
    local i rc amode viol=0 noinj=0 bbad=0 arc0=0 nomsg=0 pinbad=0 acc_before acc_after
    acc_before="$(accepted 2)"
    for ((i=1; i<=rounds; i++)); do
        reset_round
        if (( i % 2 )); then amode="$amode_odd"; echo "$bmode_odd" > "$D/b_mode"
        else amode="$amode_even"; echo "$bmode_even" > "$D/b_mode"; fi
        touch "$D/trigger"
        rc=0
        HK_OLD_SSH=1 PR_DEST_PORT="$P2" PATH="$D/binA:$D/bin:$BASE_PATH" timeout 60 \
            bash "$D/drive.sh" "$amode" "$D/mark_A" >"$D/A.out" 2>&1 </dev/null || rc=$?
        [[ -e "$D/trigger.used" ]] || { noinj=$((noinj+1)); diag "$tag round $i: B was not injected"; }
        [[ "$(cat "$D/B.rc" 2>/dev/null)" == 0 && -e "$D/mark_B" ]] || { bbad=$((bbad+1)); diag "$tag round $i: B did not pin K1 and run"; }
        [[ ! -e "$D/mark_A" ]] || { viol=$((viol+1)); diag "$tag round $i: A's $amode reached the impostor"; }
        [[ $rc -ne 0 ]] || { arc0=$((arc0+1)); diag "$tag round $i: A returned success"; }
        grep -q "forget-host 127.0.0.1" "$D/A.out" || { nomsg=$((nomsg+1)); diag "$tag round $i: no host-key failure message"; }
        [[ "$(stored_key)" == "$k1" && "$(pin_count)" == 1 ]] || { pinbad=$((pinbad+1)); diag "$tag round $i: pin is not exactly K1"; }
    done
    acc_after="$(accepted 2)"
    if [[ $noinj -eq 0 && $bbad -eq 0 ]]; then pass "$tag: in all $rounds rounds B pinned K1 between A's host check and A's connection"
    else fail "$tag: harness did not interleave as designed (not injected: $noinj, B failed: $bbad)"; fi
    if [[ $viol -eq 0 ]]; then pass "$tag: 0/$rounds remote commands reached the impostor key K2"
    else fail "$tag: $viol/$rounds rounds ran A's command on the impostor key K2"; fi
    if [[ "$acc_before" == "$acc_after" ]]; then pass "$tag: the impostor sshd never accepted a login"
    else fail "$tag: the impostor sshd accepted $((acc_after - acc_before)) login(s)"; fi
    if [[ $arc0 -eq 0 && $nomsg -eq 0 ]]; then pass "$tag: every A run stopped with the host-key failure message"
    else fail "$tag: A succeeded in $arc0 round(s), lacked the message in $nomsg round(s)"; fi
    if [[ $pinbad -eq 0 ]]; then pass "$tag: the pin is exactly K1 after every round"
    else fail "$tag: the pin was not exactly K1 in $pinbad round(s)"; fi
}

run_injected "$ROUNDS" ssh subst subst ssh "injected race (peer_ssh, direct and inside \$(...))"
run_injected "$SCP_ROUNDS" scp scp ssh subst "injected race (peer_scp)"

viol=0; none=0; multi=0
for ((i=1; i<=ROUNDS; i++)); do
    reset_round
    ( HK_OLD_SSH=1 PR_DEST_PORT="$P2" PATH="$D/bin:$BASE_PATH" timeout 60 bash "$D/drive.sh" ssh "$D/mark_A" >"$D/A.out" 2>&1 </dev/null; echo $? > "$D/A.rc" ) &
    pa=$!
    ( HK_OLD_SSH=1 PATH="$D/bin:$BASE_PATH" timeout 60 bash "$D/drive.sh" ssh "$D/mark_B" >"$D/B.out" 2>&1 </dev/null; echo $? > "$D/B.rc" ) &
    pb=$!
    wait "$pa" "$pb"
    pin="$(stored_key)"; n="$(pin_count)"
    if [[ -e "$D/mark_A" && -e "$D/mark_B" ]]; then viol=$((viol+1)); diag "free race round $i: both commands ran (pin=$pin)"
    elif [[ -e "$D/mark_A" && "$pin" != "$k2" ]]; then viol=$((viol+1)); diag "free race round $i: A ran but the pin is not K2"
    elif [[ -e "$D/mark_B" && "$pin" != "$k1" ]]; then viol=$((viol+1)); diag "free race round $i: B ran but the pin is not K1"
    elif [[ ! -e "$D/mark_A" && ! -e "$D/mark_B" ]]; then none=$((none+1)); diag "free race round $i: neither ran"; fi
    [[ "$n" == 1 ]] || { multi=$((multi+1)); diag "free race round $i: $n pins for one host"; }
done
if [[ $viol -eq 0 ]]; then pass "free race: in $ROUNDS concurrent first contacts with two different keys, no command ran against a key other than the pin"
else fail "free race: $viol/$ROUNDS rounds ran a command against a key that differs from the pin"; fi
if [[ $none -eq 0 && $multi -eq 0 ]]; then pass "free race: every round ended with exactly one pin and one successful first contact"
else fail "free race: $none round(s) with no success, $multi round(s) with more than one pin"; fi

reset_round; rm -f "$LOCK"; mkdir "$LOCK"
rc=0; PATH="$D/bin:$BASE_PATH" timeout 60 bash "$D/drive.sh" ssh "$D/mark_M" >"$D/M.out" 2>&1 </dev/null || rc=$?
if [[ $rc -eq 0 && -e "$D/mark_M" && "$(stored_key)" == "$k1" ]]; then pass "modern ssh: accept-new needs no lock (works with the lock path unusable)"
else fail "modern ssh: first contact failed with the lock path unusable (rc=$rc): $(cat "$D/M.out")"; fi
rc=0; old_drive ssh "$D/mark_P" >"$D/P.out" 2>&1 || rc=$?
if [[ $rc -eq 0 && -e "$D/mark_P" ]]; then pass "pinned host: pre-7.6 ssh to an already pinned host needs no lock"
else fail "pinned host: connection failed with the lock path unusable (rc=$rc): $(cat "$D/P.out")"; fi

reset_round
c0="$(conns)"
rc=0; old_drive ssh "$D/mark_U" >"$D/U.out" 2>&1 || rc=$?
rc2=0; old_drive scp "$D/mark_U2" >"$D/U2.out" 2>&1 || rc2=$?
rc3=0; old_drive quiet "$D/mark_U3" >"$D/U3.out" 2>&1 || rc3=$?
c1="$(conns)"
if [[ $rc -ne 0 && $rc2 -ne 0 && $rc3 -ne 0 && ! -e "$D/mark_U" && ! -e "$D/mark_U2" && ! -e "$D/mark_U3" && "$c0" == "$c1" && -z "$(stored_key)" ]]; then
    pass "unwritable lock: pre-7.6 first contact stops without connecting (ssh, scp, quiet)"
else
    fail "unwritable lock: rc=$rc/$rc2/$rc3 connections $c0->$c1 pin=[$(stored_key)]: $(cat "$D/U.out")"
fi
if grep -qi "lock" "$D/U.out" && grep -qi "lock" "$D/U2.out" && grep -qi "lock" "$D/U3.out"; then
    pass "unwritable lock: the error names the lock, also when the caller drops stderr"
else
    fail "unwritable lock: unclear error: [$(cat "$D/U.out")] [$(cat "$D/U3.out")]"
fi
rmdir "$LOCK"

reset_round
rm -f "$D/held"
bash -c 'exec 9>"$1"; flock 9; : > "$2"; exec sleep 30' _ "$LOCK" "$D/held" &
holder=$!; PIDS+=("$holder")
for _ in $(seq 1 100); do [[ -e "$D/held" ]] && break; sleep 0.05; done
c0="$(conns)"; t0=$SECONDS
rc=0; PR_WAIT=2 old_drive ssh "$D/mark_T" >"$D/T.out" 2>&1 || rc=$?
dt=$((SECONDS - t0)); c1="$(conns)"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null; forget_pid "$holder"
if [[ $rc -ne 0 && ! -e "$D/mark_T" && "$c0" == "$c1" && $dt -ge 1 && $dt -lt 20 ]] && grep -qi "lock" "$D/T.out"; then
    pass "busy lock: pre-7.6 first contact waits, then stops with a lock error and never connects (${dt}s)"
else
    fail "busy lock: rc=$rc connections $c0->$c1 after ${dt}s: $(cat "$D/T.out")"
fi

reset_round
rm -f "$D/mark_H" "$D/mark_H.pid"
HK_OLD_SSH=1 PATH="$D/bin:$BASE_PATH" setsid bash "$D/drive.sh" hold "$D/mark_H" >"$D/H.out" 2>&1 </dev/null &
hpid=$!; PIDS+=("$hpid")
for _ in $(seq 1 200); do [[ -s "$D/mark_H.pid" ]] && break; sleep 0.05; done
held=no; lock_free || held=yes
kill -9 -- "-$hpid" 2>/dev/null; wait "$hpid" 2>/dev/null; forget_pid "$hpid"
rpid="$(cat "$D/mark_H.pid" 2>/dev/null)"
[[ "$rpid" =~ ^[0-9]+$ ]] && kill "$rpid" 2>/dev/null
: > "$KH"
t0=$SECONDS
rc=0; PR_WAIT=5 old_drive ssh "$D/mark_K" >"$D/K.out" 2>&1 || rc=$?
dt=$((SECONDS - t0))
if [[ "$held" == yes ]]; then pass "killed holder: the in-flight pre-7.6 first contact held the lock"
else fail "killed holder: the in-flight pre-7.6 first contact did not hold the first-contact lock"; fi
if [[ $rc -eq 0 && -e "$D/mark_K" && $dt -lt 5 ]]; then pass "killed holder: the next first contact proceeds at once after the holder is killed (${dt}s)"
else fail "killed holder: next run rc=$rc after ${dt}s: $(cat "$D/K.out")"; fi

if lock_free; then pass "end: no first-contact lock is left held"
else fail "end: the first-contact lock is still held"; fi

echo
[[ -z "$DIAG" ]] || printf 'first problem seen:\n%s\n\n' "$DIAG" >&2
if [[ "$FAILS" -ne 0 ]]; then
    echo "FAILED - ssh_pin_race_test: $FAILS failure(s), $PASSES check(s) passed"
    exit 1
fi
echo "PASSED - ssh_pin_race_test: $PASSES checks - on pre-7.6 ssh a first contact re-checks the pin under a per-relay lock, so a key pinned by another process between the check and the connection stops the run before any command ($ROUNDS injected + $SCP_ROUNDS scp + $ROUNDS free rounds); modern ssh and pinned hosts never lock; an unusable or busy lock stops without connecting; a killed holder never blocks the next run"
