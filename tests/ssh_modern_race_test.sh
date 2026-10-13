#!/usr/bin/env bash
set -u

SCRIPT="${1:-$(dirname "$0")/../omnitunnel.sh}"
SSHD=/usr/sbin/sshd
ROUNDS=100

[[ $EUID -eq 0 ]] || { echo "SKIP ssh_modern_race_test: needs root to run throwaway sshds on 127.0.0.1"; exit 0; }
[[ -x "$SSHD" ]] || { echo "SKIP ssh_modern_race_test: $SSHD missing"; exit 0; }
for c in ssh scp ssh-keygen flock setsid timeout; do
    command -v "$c" >/dev/null 2>&1 || { echo "SKIP ssh_modern_race_test: $c missing"; exit 0; }
done
REAL_SSH="$(command -v ssh)"; REAL_KEYGEN="$(command -v ssh-keygen)"
"$REAL_SSH" -o StrictHostKeyChecking=accept-new -V >/dev/null 2>&1 || { echo "SKIP ssh_modern_race_test: this ssh has no StrictHostKeyChecking=accept-new (OpenSSH < 7.6)"; exit 0; }
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

cat > "$D/drive.sh" <<'DRIVE'
#!/bin/bash
set -euo pipefail
. "$PR_D/lib.sh"
[[ -z "${PR_WAIT:-}" ]] || SSH_KH_LOCK_WAIT="$PR_WAIT"
exec {OMNI_ERR_FD}>&2
case "$1" in
    ssh)   peer_ssh 127.0.0.1 "touch $2" </dev/null;;
    hold)  peer_ssh 127.0.0.1 "echo \$\$ > $2.pid; touch $2; exec sleep 30" </dev/null;;
esac
for fd in /proc/$$/fd/*; do
    [[ "$(readlink "$fd" 2>/dev/null)" != *.first-contact.lock ]] || { echo "LOCK-FD-LEAK $fd" >&2; exit 97; }
done
DRIVE

port_free() { ! (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }
pick_port() {
    local p i
    for i in $(seq 1 200); do
        p=$(( 20000 + (RANDOM * 7 + i) % 40000 ))
        [[ "$p" != "${1:-}" ]] && port_free "$p" && { echo "$p"; return 0; }
    done
    return 1
}
P1="$(pick_port)" || { echo "SKIP ssh_modern_race_test: no free local port"; exit 0; }
P2="$(pick_port "$P1")" || { echo "SKIP ssh_modern_race_test: no free local port"; exit 0; }

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
terr="$("$SSHD" -t -f "$D/sshd_1" 2>&1)" || { echo "SKIP ssh_modern_race_test: sshd cannot run here: $terr"; exit 0; }
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
    [[ "\$a" == -G || "\$a" == -V ]] && conn=0
done
dest=$P1; alias=()
if [[ \$conn == 1 && -n "\${PR_DEST_PORT:-}" ]]; then dest="\$PR_DEST_PORT"; alias=(-o "HostKeyAlias=[127.0.0.1]:$P1"); fi
[[ \$conn == 0 ]] || echo "ssh \$dest" >> "$D/connections"
exec "$REAL_SSH" -p "\$dest" \${alias[@]+"\${alias[@]}"} -i "$D/id" -o IdentitiesOnly=yes "\$@"
SHIM
mkdir -p "$D/bin"
mv "$D/bin_ssh" "$D/bin/ssh"; chmod 755 "$D/bin/ssh"
: > "$D/connections"

PIN_NAME="[127.0.0.1]:$P1"
stored_key() { "$REAL_KEYGEN" -F "$PIN_NAME" -f "$KH" 2>/dev/null | awk '!/^#/ {print $3; exit}'; }
pin_count() { "$REAL_KEYGEN" -F "$PIN_NAME" -f "$KH" 2>/dev/null | grep -vc '^#'; }
accepted() { grep -c 'Accepted publickey' "$D/sshd_$1.log" 2>/dev/null || true; }
lock_free() { flock -n "$LOCK" true 2>/dev/null; }
reset_round() { : > "$KH"; rm -f "$D"/mark_* "$D"/A.* "$D"/B.*; }
mod_drive() { PATH="$D/bin:$BASE_PATH" timeout 60 bash "$D/drive.sh" "$@" </dev/null; }
DIAG=""
diag() { [[ -n "$DIAG" ]] || DIAG="$1"; }

reset_round
rc=0; mod_drive ssh "$D/mark_N" >"$D/N.out" 2>&1 || rc=$?
if [[ $rc -eq 0 && -e "$D/mark_N" && "$(stored_key)" == "$k1" && "$(pin_count)" == 1 ]]; then
    pass "baseline: a modern first contact pins the key and runs the command"
else
    fail "baseline: modern first contact failed (rc=$rc pin=[$(stored_key)] count=$(pin_count)): $(cat "$D/N.out")"
fi
if lock_free; then pass "baseline: the first-contact lock is released after the connection"
else fail "baseline: the first-contact lock is still held after a modern connection returned"; fi

reset_round
mod_drive ssh "$D/mark_P1" >"$D/P1.out" 2>&1 || true
held=no
PATH="$D/bin:$BASE_PATH" setsid bash "$D/drive.sh" hold "$D/mark_HP" >"$D/HP.out" 2>&1 </dev/null &
hp=$!; PIDS+=("$hp")
for _ in $(seq 1 200); do [[ -s "$D/mark_HP.pid" ]] && break; sleep 0.05; done
lock_free || held=yes
kill -9 -- "-$hp" 2>/dev/null; wait "$hp" 2>/dev/null; forget_pid "$hp"
rpid="$(cat "$D/mark_HP.pid" 2>/dev/null)"; [[ "$rpid" =~ ^[0-9]+$ ]] && kill "$rpid" 2>/dev/null
if [[ "$held" == no ]]; then pass "pinned host: a modern connection to an already pinned host takes no first-contact lock"
else fail "pinned host: a modern connection to an already pinned host held the first-contact lock"; fi

reset_round
rm -f "$D/mark_H" "$D/mark_H.pid"
held=no
PATH="$D/bin:$BASE_PATH" setsid bash "$D/drive.sh" hold "$D/mark_H" >"$D/H.out" 2>&1 </dev/null &
hpid=$!; PIDS+=("$hpid")
for _ in $(seq 1 200); do [[ -s "$D/mark_H.pid" ]] && break; sleep 0.05; done
lock_free || held=yes
ran=no; [[ -e "$D/mark_H" ]] && ran=yes
kill -9 -- "-$hpid" 2>/dev/null; wait "$hpid" 2>/dev/null; forget_pid "$hpid"
rpid="$(cat "$D/mark_H.pid" 2>/dev/null)"; [[ "$rpid" =~ ^[0-9]+$ ]] && kill "$rpid" 2>/dev/null
if [[ "$ran" == yes && "$held" == yes ]]; then
    pass "serialized: an in-flight modern first contact to an unpinned host holds the per-host lock"
else
    fail "serialized: the in-flight modern first contact ran=$ran held-lock=$held (want yes/yes): $(cat "$D/H.out")"
fi

viol=0; none=0; multi=0
for ((i=1; i<=ROUNDS; i++)); do
    reset_round
    ( PR_DEST_PORT="$P2" PATH="$D/bin:$BASE_PATH" timeout 60 bash "$D/drive.sh" ssh "$D/mark_A" >"$D/A.out" 2>&1 </dev/null; echo $? > "$D/A.rc" ) &
    pa=$!
    ( PATH="$D/bin:$BASE_PATH" timeout 60 bash "$D/drive.sh" ssh "$D/mark_B" >"$D/B.out" 2>&1 </dev/null; echo $? > "$D/B.rc" ) &
    pb=$!
    wait "$pa" "$pb"
    pin="$(stored_key)"; n="$(pin_count)"
    if [[ -e "$D/mark_A" && -e "$D/mark_B" ]]; then viol=$((viol+1)); diag "round $i: both commands ran (pin=$pin)"
    elif [[ -e "$D/mark_A" && "$pin" != "$k2" ]]; then viol=$((viol+1)); diag "round $i: A ran but the pin is not K2 (pin=$pin)"
    elif [[ -e "$D/mark_B" && "$pin" != "$k1" ]]; then viol=$((viol+1)); diag "round $i: B ran but the pin is not K1 (pin=$pin)"
    elif [[ ! -e "$D/mark_A" && ! -e "$D/mark_B" ]]; then none=$((none+1)); diag "round $i: neither ran"; fi
    [[ "$n" == 1 ]] || { multi=$((multi+1)); diag "round $i: $n pins for one host"; }
done
if [[ $viol -eq 0 ]]; then pass "modern free race: in $ROUNDS concurrent first contacts with two different keys, no command ran against a key other than the pin"
else fail "modern free race: $viol/$ROUNDS rounds ran a command against a key that differs from the pin"; fi
if [[ $none -eq 0 && $multi -eq 0 ]]; then pass "modern free race: every round ended with exactly one pin and one successful first contact"
else fail "modern free race: $none round(s) with no success, $multi round(s) with more than one pin"; fi

if lock_free; then pass "end: no first-contact lock is left held"
else fail "end: the first-contact lock is still held"; fi

echo
[[ -z "$DIAG" ]] || printf 'first problem seen:\n%s\n\n' "$DIAG" >&2
if [[ "$FAILS" -ne 0 ]]; then
    echo "FAILED - ssh_modern_race_test: $FAILS failure(s), $PASSES check(s) passed"
    exit 1
fi
echo "PASSED - ssh_modern_race_test: $PASSES checks - on modern (accept-new) ssh an unpinned first contact is serialized under the per-host lock and re-checks the pin, so $ROUNDS concurrent first contacts with two different keys end with exactly one pinned key and never run a command against a different key; a pinned host still takes no lock"
