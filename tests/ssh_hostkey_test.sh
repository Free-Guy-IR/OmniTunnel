#!/usr/bin/env bash
set -u

SCRIPT="${1:-$(dirname "$0")/../omnitunnel.sh}"
SSHD=/usr/sbin/sshd

[[ $EUID -eq 0 ]] || { echo "SKIP ssh_hostkey_test: needs root to run a throwaway sshd on 127.0.0.1"; exit 0; }
[[ -x "$SSHD" ]] || { echo "SKIP ssh_hostkey_test: $SSHD missing"; exit 0; }
for c in ssh scp ssh-keygen; do
    command -v "$c" >/dev/null 2>&1 || { echo "SKIP ssh_hostkey_test: $c missing"; exit 0; }
done
REAL_SSH="$(command -v ssh)"; REAL_SCP="$(command -v scp)"

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
trap cleanup EXIT

ROOT_DIR="$D/etc"; INST_DIR="$ROOT_DIR/inst"; PEER_DIR="$ROOT_DIR/peers"
# shellcheck disable=SC2034
VERSION="0.0.1"
mkdir -p "$INST_DIR" "$PEER_DIR"
eval "$(grep -E '^[CG]_[A-Z_]+=' "$SCRIPT")"
eval "$(grep -E '^(SSH_KH_DIR|SSH_KNOWN_HOSTS|SSH_OPTS)=' "$SCRIPT")"
eval "$(extract "need_root die ok info warn tok_re tok_host_ok tok_port_ok peer_conf save_peer _peer_creds _proxy_opts peer_ssh peer_scp ssh_kh_init ssh_accept_new_ok ssh_kh_name _hostkey_opts _peer_run hostkey_abort cmd_forget_host ver_gt guard_peer_downgrade")"
cmd_update() { touch "$D/update_called"; return 1; }
KH="${SSH_KNOWN_HOSTS:-$ROOT_DIR/ssh/known_hosts}"

opts=" ${SSH_OPTS[*]:-} "
if [[ "$opts" != *"UserKnownHostsFile=/dev/null"* ]]; then pass "d: SSH_OPTS no longer pins nothing (no UserKnownHostsFile=/dev/null)"
else fail "d: SSH_OPTS still contains UserKnownHostsFile=/dev/null"; fi
if [[ "$opts" != *"StrictHostKeyChecking=no"* ]]; then pass "d: SSH_OPTS has no fixed StrictHostKeyChecking=no"
else fail "d: SSH_OPTS still disables host key checking"; fi
if [[ "$opts" == *"UserKnownHostsFile=$ROOT_DIR/ssh/known_hosts"* ]]; then pass "d: SSH_OPTS uses the OmniTunnel known_hosts under the config dir"
else fail "d: SSH_OPTS does not use $ROOT_DIR/ssh/known_hosts (got:$opts)"; fi
[[ "$KH" == "$ROOT_DIR/ssh/known_hosts" ]] || fail "d: SSH_KNOWN_HOSTS is '$KH', want $ROOT_DIR/ssh/known_hosts"

port_free() { ! (exec 3<>"/dev/tcp/${2:-127.0.0.1}/$1") 2>/dev/null; }
pick_port() {
    local p i
    for i in $(seq 1 200); do
        p=$(( 20000 + (RANDOM * 7 + i) % 40000 ))
        port_free "$p" && { echo "$p"; return 0; }
    done
    return 1
}
PORT="$(pick_port)" || { echo "SKIP ssh_hostkey_test: no free local port"; exit 0; }

ssh-keygen -q -t ed25519 -N '' -C hostA -f "$D/hostA"
ssh-keygen -q -t ed25519 -N '' -C hostB -f "$D/hostB"
ssh-keygen -q -t ed25519 -N '' -C client -f "$D/id"
cp "$D/id.pub" "$D/authorized_keys"
keyA="$(awk '{print $2}' "$D/hostA.pub")"; keyB="$(awk '{print $2}' "$D/hostB.pub")"

PENALTY_LINE=""
write_cfg() {
    cat > "$D/sshd_$1" <<CFG
Port $PORT
ListenAddress $2
HostKey $D/host$1
PidFile $D/sshd_$1.pid
AuthorizedKeysFile $D/authorized_keys
StrictModes no
UsePAM no
PubkeyAuthentication yes
PasswordAuthentication yes
PermitRootLogin prohibit-password
LogLevel DEBUG1
Subsystem sftp internal-sftp
$PENALTY_LINE
CFG
}
write_cfg A 127.0.0.1
if "$SSHD" -t -f "$D/sshd_A" -o PerSourcePenalties=no >/dev/null 2>&1; then PENALTY_LINE="PerSourcePenalties no"; write_cfg A 127.0.0.1; fi
write_cfg B 127.0.0.1
terr="$("$SSHD" -t -f "$D/sshd_A" 2>&1)" || { echo "SKIP ssh_hostkey_test: sshd cannot run here: $terr"; exit 0; }

SPID=""; LADDR=127.0.0.1
start_sshd() {
    local cfg="$1" i
    "$SSHD" -D -f "$D/sshd_$cfg" -E "$D/sshd_$cfg.log" &
    SPID=$!; PIDS+=("$SPID")
    for i in $(seq 1 50); do
        port_free "$PORT" "$LADDR" || return 0
        sleep 0.1
    done
    fail "sshd $cfg did not start on $LADDR:$PORT"
    return 1
}
stop_sshd() {
    [[ -n "$SPID" ]] || return 0
    kill "$SPID" 2>/dev/null; wait "$SPID" 2>/dev/null; SPID=""
    local i; for i in $(seq 1 50); do port_free "$PORT" "$LADDR" && return 0; sleep 0.1; done
}

mkdir -p "$D/bin"
cat > "$D/bin/ssh" <<SHIM
#!/bin/bash
for a in "\$@"; do
    if [[ -n "\${HK_OLD_SSH:-}" && "\$a" == *StrictHostKeyChecking=accept-new* ]]; then
        echo 'command-line line 0: Bad yes/no/ask argument.' >&2; exit 255
    fi
done
exec "$REAL_SSH" -p "$PORT" -i "$D/id" -o IdentitiesOnly=yes "\$@"
SHIM
cat > "$D/bin/scp" <<SHIM
#!/bin/bash
for a in "\$@"; do
    if [[ -n "\${HK_OLD_SSH:-}" && "\$a" == *StrictHostKeyChecking=accept-new* ]]; then
        echo 'command-line line 0: Bad yes/no/ask argument.' >&2; exit 255
    fi
done
exec "$REAL_SCP" -P "$PORT" -i "$D/id" -o IdentitiesOnly=yes "\$@"
SHIM
chmod 755 "$D/bin/ssh" "$D/bin/scp"
export PATH="$D/bin:$PATH"

stored_key() { ssh-keygen -F "[127.0.0.1]:$PORT" -f "$KH" 2>/dev/null | awk '!/^#/ {print $3; exit}'; }
pw_requests() { grep -c "method password" "$D/sshd_$1.log" 2>/dev/null || true; }

start_sshd A || exit 1
rm -f "$D/ran_a"
out="$(peer_ssh 127.0.0.1 "touch $D/ran_a" 2>&1 </dev/null)"; rc=$?
if [[ $rc -eq 0 && -f "$D/ran_a" ]]; then pass "a: first contact runs the remote command"
else fail "a: first peer_ssh failed (rc=$rc): $out"; fi
if [[ "$(stored_key)" == "$keyA" ]]; then pass "a: first contact pinned host key A as [127.0.0.1]:$PORT"
else fail "a: known_hosts does not hold key A for [127.0.0.1]:$PORT"; fi
if [[ "$(stat -c %a "$ROOT_DIR/ssh" 2>/dev/null)" == 700 ]]; then pass "a: known_hosts dir is 0700"
else fail "a: known_hosts dir mode is $(stat -c %a "$ROOT_DIR/ssh" 2>&1)"; fi
if [[ "$(stat -c %a "$KH" 2>/dev/null)" == 600 ]]; then pass "a: known_hosts file is 0600"
else fail "a: known_hosts file mode is $(stat -c %a "$KH" 2>&1)"; fi
echo payload > "$D/payload"
out="$(peer_scp 127.0.0.1 "$D/payload" "$D/scp_a" 2>&1 </dev/null)"; rc=$?
if [[ $rc -eq 0 && -f "$D/scp_a" ]]; then pass "a: peer_scp works against the pinned key"
else fail "a: peer_scp failed (rc=$rc): $out"; fi

out="$(peer_ssh 127.0.0.1 'echo OUT; echo ERR >&2; exit 3' 2>/dev/null </dev/null)"; rc=$?
if [[ "$out" == OUT && $rc -eq 3 ]]; then pass "plumbing: stdout stays clean and the remote exit code passes through"
else fail "plumbing: got stdout=[$out] rc=$rc, want OUT and 3"; fi
err="$(peer_ssh 127.0.0.1 'echo ERR >&2' 2>&1 >/dev/null </dev/null)"
if [[ "$err" == ERR ]]; then pass "plumbing: remote stderr still reaches the caller's stderr"
else fail "plumbing: remote stderr lost, got [$err]"; fi
got="$(printf 'in-data\n' | peer_ssh 127.0.0.1 cat 2>/dev/null)"
if [[ "$got" == in-data ]]; then pass "plumbing: stdin still reaches the remote command"
else fail "plumbing: stdin did not reach the remote command, got [$got]"; fi

run_parallel() {
    local tag="$1" i pp=() p
    for i in 1 2 3 4 5 6 7 8; do
        ( peer_ssh 127.0.0.1 "touch $D/${tag}_$i" >/dev/null 2>&1 </dev/null; echo $? > "$D/${tag}_rc_$i" ) &
        pp+=("$!")
    done
    for p in "${pp[@]}"; do wait "$p"; done
}
fpA="$(ssh-keygen -l -f "$D/hostA.pub" | awk '{print $2}')"
(cmd_forget_host 127.0.0.1 "$PORT") >/dev/null 2>&1
run_parallel parA
okn=0; for i in 1 2 3 4 5 6 7 8; do [[ "$(cat "$D/parA_rc_$i" 2>/dev/null)" == 0 && -e "$D/parA_$i" ]] && okn=$((okn+1)); done
if [[ "$okn" == 8 ]]; then pass "interleave: 8 concurrent first contacts all succeed"
else fail "interleave: only $okn/8 concurrent first contacts succeeded"; fi
lines="$(grep -c . "$KH")"; listed="$(ssh-keygen -l -f "$KH" 2>/dev/null | wc -l)"
fps="$(ssh-keygen -l -f "$KH" 2>/dev/null | awk '{print $2}' | sort -u | tr '\n' ' ')"
if [[ "$lines" -ge 1 && "$lines" == "$listed" && "$fps" == "$fpA " ]]; then pass "interleave: concurrent pinning left $lines well-formed entries, all key A"
else fail "interleave: known_hosts damaged by concurrent first contacts (lines=$lines parsed=$listed fps=[$fps] want [$fpA])"; fi

stop_sshd; start_sshd B || exit 1

rm -f "$D/canary_ssh"
out="$( (peer_ssh 127.0.0.1 "touch $D/canary_ssh") 2>&1 </dev/null)"; rc=$?
if [[ $rc -ne 0 ]]; then pass "b: peer_ssh refuses a changed host key (rc=$rc)"
else fail "b: peer_ssh succeeded against a changed host key"; fi
if [[ ! -e "$D/canary_ssh" ]]; then pass "b: the remote command did not run"
else fail "b: the remote command RAN on the changed-key server"; fi
if [[ "$out" == *127.0.0.1* && "$out" == *"forget-host 127.0.0.1"* ]]; then pass "b: the message names the host and the forget-host fix"
else fail "b: missing host/forget-host message, got: $out"; fi
if [[ "$out" == *"$PORT"* ]]; then pass "b: the message carries the non-22 port"
else fail "b: the message lacks port $PORT"; fi

rm -f "$D/canary_scp"
out="$( (peer_scp 127.0.0.1 "$D/payload" "$D/canary_scp") 2>&1 </dev/null)"; rc=$?
if [[ $rc -ne 0 ]]; then pass "b: peer_scp refuses a changed host key (rc=$rc)"
else fail "b: peer_scp succeeded against a changed host key"; fi
if [[ ! -e "$D/canary_scp" ]]; then pass "b: nothing was copied"
else fail "b: scp delivered a file to the changed-key server"; fi
if [[ "$out" == *"forget-host 127.0.0.1"* ]]; then pass "b: peer_scp shows the forget-host fix"
else fail "b: peer_scp gave no forget-host message, got: $out"; fi

run_parallel parB
badn=0; for i in 1 2 3 4 5 6 7 8; do { [[ "$(cat "$D/parB_rc_$i" 2>/dev/null)" == 0 ]] || [[ -e "$D/parB_$i" ]]; } && badn=$((badn+1)); done
if [[ "$badn" == 0 ]]; then pass "interleave: 8 concurrent connections to the changed-key server are all refused, none ran"
else fail "interleave: $badn/8 concurrent connections got through the changed key"; fi
if [[ "$(stored_key)" == "$keyA" ]]; then pass "interleave: the pin still holds key A after the concurrent refusals"
else fail "interleave: concurrent refusals changed the pinned key"; fi

: > "$D/errfd.log"
rm -f "$D/canary_quiet"
rc=0
(
    # shellcheck disable=SC2034
    exec {OMNI_ERR_FD}>"$D/errfd.log"
    peer_ssh 127.0.0.1 "touch $D/canary_quiet" >/dev/null 2>&1 </dev/null
    touch "$D/after_quiet"
) || rc=$?
if [[ $rc -ne 0 && ! -e "$D/after_quiet" && ! -e "$D/canary_quiet" ]]; then pass "b: a changed key aborts the flow even when the caller drops stderr"
else fail "b: quiet call did not abort (rc=$rc, after_quiet=$([[ -e "$D/after_quiet" ]] && echo yes || echo no))"; fi
if grep -q "forget-host 127.0.0.1" "$D/errfd.log"; then pass "b: the message still reaches the operator through the saved stderr"
else fail "b: message lost when the caller drops stderr: $(cat "$D/errfd.log")"; fi

rc=0
( guard_peer_downgrade 127.0.0.1 >/dev/null 2>&1 </dev/null; touch "$D/after_guard" ) || rc=$?
if [[ $rc -ne 0 && ! -e "$D/after_guard" ]]; then pass "b: the add/bench entry guard stops before any provisioning step"
else fail "b: guard_peer_downgrade let the flow continue past a changed key (rc=$rc)"; fi
[[ ! -e "$D/update_called" ]] || fail "b: a changed key must not trigger a self-update"

if command -v sshpass >/dev/null 2>&1; then
    save_peer 127.0.0.1 root "omni-hostkey-test-not-a-password" ""
    before="$(pw_requests B)"
    rm -f "$D/canary_pw"
    out="$( (peer_ssh 127.0.0.1 "touch $D/canary_pw") 2>&1 </dev/null)"; rc=$?
    out2="$( (peer_scp 127.0.0.1 "$D/payload" "$D/canary_pw2") 2>&1 </dev/null)"; rc2=$?
    after="$(pw_requests B)"
    if [[ $rc -ne 0 && $rc2 -ne 0 && ! -e "$D/canary_pw" && ! -e "$D/canary_pw2" ]]; then pass "e: with a saved password, ssh and scp still refuse the changed key"
    else fail "e: password path did not refuse (rc=$rc rc2=$rc2): $out $out2"; fi
    if [[ "$before" == "$after" ]]; then pass "e: sshd log shows the saved password was never offered to the changed-key server"
    else fail "e: the changed-key server received password requests ($before -> $after)"; fi
    sshpass -p "omni-hostkey-test-not-a-password" "$REAL_SSH" -p "$PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR -o PubkeyAuthentication=no -o PreferredAuthentications=password -o NumberOfPasswordPrompts=1 \
        root@127.0.0.1 true >/dev/null 2>&1 </dev/null
    control="$(pw_requests B)"
    if [[ "$control" -gt "$after" ]]; then pass "e: positive control: the old /dev/null options DO hand the password over (sshd log $after -> $control)"
    else fail "e: positive control did not register a password request; the log check is blind"; fi
    rm -f "$(peer_conf 127.0.0.1)"
else
    echo "SKIP e: sshpass missing"
fi

out="$( (cmd_forget_host 127.0.0.1 "$PORT") 2>&1 )"; rc=$?
if [[ $rc -eq 0 && -z "$(stored_key)" ]]; then pass "c: forget-host 127.0.0.1 $PORT removed the pinned key"
else fail "c: forget-host failed (rc=$rc): $out"; fi
rm -f "$D/ran_c"
out="$(peer_ssh 127.0.0.1 "touch $D/ran_c" 2>&1 </dev/null)"; rc=$?
if [[ $rc -eq 0 && -f "$D/ran_c" ]]; then pass "c: after forget-host the reconnect works"
else fail "c: reconnect after forget failed (rc=$rc): $out"; fi
if [[ "$(stored_key)" == "$keyB" ]]; then pass "c: the reconnect pinned key B"
else fail "c: known_hosts does not hold key B after the reconnect"; fi

out="$( (cmd_forget_host 127.0.0.1) 2>&1 )"; rc=$?
if [[ $rc -eq 0 && -z "$(stored_key)" ]]; then pass "c: forget-host without a port finds the effective non-22 port"
else fail "c: forget-host without port left the key (rc=$rc): $out"; fi
peer_ssh 127.0.0.1 true >/dev/null 2>&1 </dev/null
out="$( (cmd_forget_host "[127.0.0.1]:$PORT") 2>&1 )"; rc=$?
if [[ $rc -eq 0 && -z "$(stored_key)" ]]; then pass "c: forget-host accepts the [host]:port form ssh prints"
else fail "c: [host]:port form failed (rc=$rc): $out"; fi
peer_ssh 127.0.0.1 true >/dev/null 2>&1 </dev/null

PROXY_RAN=0
if command -v python3 >/dev/null 2>&1 && { nc -h 2>&1 | grep -q -- '-X' || command -v ncat >/dev/null 2>&1; }; then
    SPORT="$(pick_port)"
    cat > "$D/socks.py" <<'PY'
import socket, struct, sys, threading
port, log = int(sys.argv[1]), sys.argv[2]
srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", port)); srv.listen(16)
def pipe(a, b):
    try:
        while True:
            d = a.recv(65536)
            if not d: break
            b.sendall(d)
    except OSError: pass
    for s in (a, b):
        try: s.shutdown(socket.SHUT_RDWR)
        except OSError: pass
def handle(c):
    try:
        n = c.recv(2)[1]; c.recv(n); c.sendall(b"\x05\x00")
        h = c.recv(4); atyp = h[3]
        if atyp == 1: host = socket.inet_ntoa(c.recv(4))
        elif atyp == 3: host = c.recv(c.recv(1)[0]).decode()
        else: host = socket.inet_ntop(socket.AF_INET6, c.recv(16))
        dport = struct.unpack(">H", c.recv(2))[0]
        u = socket.create_connection((host, dport))
        with open(log, "a") as f: f.write("%s %d\n" % (host, dport))
        c.sendall(b"\x05\x00\x00\x01" + socket.inet_aton("0.0.0.0") + b"\x00\x00")
    except Exception:
        c.close(); return
    threading.Thread(target=pipe, args=(c, u), daemon=True).start()
    pipe(u, c)
while True:
    c, _ = srv.accept()
    threading.Thread(target=handle, args=(c,), daemon=True).start()
PY
    python3 "$D/socks.py" "$SPORT" "$D/socks.log" &
    PIDS+=("$!")
    for i in $(seq 1 50); do port_free "$SPORT" || break; sleep 0.1; done
    save_peer 127.0.0.1 root "" "127.0.0.1:$SPORT"
    stop_sshd; start_sshd A || exit 1
    : > "$D/socks.log"
    rm -f "$D/canary_proxy"
    out="$( (peer_ssh 127.0.0.1 "touch $D/canary_proxy") 2>&1 </dev/null)"; rc=$?
    used="$(wc -l < "$D/socks.log")"
    if [[ "$used" -ge 1 ]]; then pass "proxy: the provisioning SSH really went through the saved SOCKS5 proxy ($used connection(s))"
    else fail "proxy: the SOCKS5 proxy saw no connection, the test did not exercise the proxy path"; fi
    if [[ $rc -ne 0 && ! -e "$D/canary_proxy" && "$out" == *"forget-host 127.0.0.1"* ]]; then pass "proxy: a changed key behind the proxy is refused with the same pin file"
    else fail "proxy: changed key behind the proxy not refused (rc=$rc): $out"; fi
    (cmd_forget_host 127.0.0.1 "$PORT") >/dev/null 2>&1
    out="$(peer_ssh 127.0.0.1 "touch $D/ran_proxy" 2>&1 </dev/null)"; rc=$?
    if [[ $rc -eq 0 && -f "$D/ran_proxy" && "$(stored_key)" == "$keyA" ]]; then pass "proxy: after forget the proxied reconnect pins key A"
    else fail "proxy: proxied reconnect failed (rc=$rc): $out"; fi
    rm -f "$(peer_conf 127.0.0.1)"
    PROXY_RAN=1
else
    echo "SKIP proxy: needs python3 and an nc with -X (or ncat)"
fi
[[ "$PROXY_RAN" == 1 ]] || { stop_sshd; start_sshd A || exit 1; }

export HK_OLD_SSH=1
if ssh_accept_new_ok; then fail "old: the simulated pre-7.6 ssh was not detected"; else pass "old: runtime detection sees no accept-new support"; fi
(cmd_forget_host 127.0.0.1 "$PORT") >/dev/null 2>&1
rm -f "$D/ran_old"
out="$(peer_ssh 127.0.0.1 "touch $D/ran_old" 2>&1 </dev/null)"; rc=$?
if [[ $rc -eq 0 && -f "$D/ran_old" && "$(stored_key)" == "$keyA" ]]; then pass "old: first contact without accept-new still pins the key in the persistent file"
else fail "old: first contact failed or did not pin (rc=$rc): $out"; fi
stop_sshd; start_sshd B || exit 1
rm -f "$D/canary_old"
out="$( (peer_ssh 127.0.0.1 "touch $D/canary_old") 2>&1 </dev/null)"; rc=$?
if [[ $rc -ne 0 && ! -e "$D/canary_old" ]]; then pass "old: a changed key is refused even with key auth (StrictHostKeyChecking=yes once pinned)"
else fail "old: changed key not refused on the fallback path (rc=$rc): $out"; fi
if [[ "$out" == *"forget-host 127.0.0.1"* ]]; then pass "old: the fallback shows the forget-host message"
else fail "old: no forget-host message on the fallback: $out"; fi
if command -v sshpass >/dev/null 2>&1; then
    save_peer 127.0.0.1 root "omni-hostkey-test-not-a-password" ""
    before="$(pw_requests B)"
    (peer_ssh 127.0.0.1 "touch $D/canary_old_pw") >/dev/null 2>&1 </dev/null
    after="$(pw_requests B)"
    if [[ "$before" == "$after" && ! -e "$D/canary_old_pw" ]]; then pass "old: the fallback never offers the saved password to a changed key"
    else fail "old: fallback offered the password ($before -> $after)"; fi
    rm -f "$(peer_conf 127.0.0.1)"
fi
unset HK_OLD_SSH

bad=0
for h in "-oProxyCommand=touch $D/pwn" "../etc/passwd" "a/b" "" ".hidden" "host name" 'x;touch '"$D"'/pwn'; do
    ( cmd_forget_host "$h" ) >/dev/null 2>&1 && { bad=1; echo "  accepted bad host: [$h]" >&2; }
done
for p in 0 70000 "22;id" "-1" "2x"; do
    ( cmd_forget_host 127.0.0.1 "$p" ) >/dev/null 2>&1 && { bad=1; echo "  accepted bad port: [$p]" >&2; }
done
if [[ "$bad" == 0 && ! -e "$D/pwn" ]]; then pass "forget: invalid hosts and ports are rejected, nothing injected"
else fail "forget: an invalid host/port was accepted"; fi

printf '2001:db8::1 ssh-ed25519 %s\n[2001:db8::1]:2222 ssh-ed25519 %s\n' "$keyA" "$keyB" >> "$KH"
(cmd_forget_host 2001:db8::1) >/dev/null 2>&1
if ssh-keygen -F 2001:db8::1 -f "$KH" >/dev/null 2>&1; then fail "ipv6: forget-host 2001:db8::1 left the entry"
else pass "ipv6: forget-host removes an IPv6 literal"; fi
if ssh-keygen -F "[2001:db8::1]:2222" -f "$KH" >/dev/null 2>&1; then pass "ipv6: other ports of the same host are untouched"
else fail "ipv6: an unrelated [host]:port entry was removed"; fi
(cmd_forget_host "[2001:db8::1]:2222") >/dev/null 2>&1
if ssh-keygen -F "[2001:db8::1]:2222" -f "$KH" >/dev/null 2>&1; then fail "ipv6: [2001:db8::1]:2222 not removed"
else pass "ipv6: forget-host [v6]:port removes the bracketed entry"; fi
if [[ "$(stat -c %a "$KH" 2>/dev/null)" == 600 ]]; then pass "forget: known_hosts stays 0600 after ssh-keygen -R"
else fail "forget: known_hosts mode changed to $(stat -c %a "$KH" 2>&1)"; fi

stop_sshd
write_cfg A ::1
LADDR=::1
V6_FAILS="$FAILS"
if "$SSHD" -t -f "$D/sshd_A" >/dev/null 2>&1 && start_sshd A 2>/dev/null; then
    if ! port_free "$PORT" ::1; then
        rm -f "$D/ran_v6" "$D/scp_v6"
        out="$(peer_ssh ::1 "touch $D/ran_v6" 2>&1 </dev/null)"; rc=$?
        out2="$(peer_scp ::1 "$D/payload" "$D/scp_v6" 2>&1 </dev/null)"; rc2=$?
        if [[ $rc -eq 0 && -f "$D/ran_v6" && $rc2 -eq 0 && -f "$D/scp_v6" ]]; then pass "ipv6: peer_ssh and peer_scp work with an IPv6 literal"
        else fail "ipv6: IPv6 literal failed (ssh rc=$rc scp rc=$rc2): $out $out2"; fi
        if ssh-keygen -F "[::1]:$PORT" -f "$KH" >/dev/null 2>&1; then pass "ipv6: the IPv6 host was pinned as [::1]:$PORT"
        else fail "ipv6: no [::1]:$PORT pin"; fi
    else
        echo "SKIP ipv6 live: ::1 not reachable"
    fi
    stop_sshd
else
    FAILS="$V6_FAILS"
    stop_sshd
    echo "SKIP ipv6 live: sshd cannot listen on ::1 here"
fi

eval "$(extract "menu_instances")"
# shellcheck disable=SC2317
menu_out="$(
    banner() { :; }; inst_header() { :; }; rule() { :; }; rule_green() { :; }; list_instances() { :; }
    nitem() { printf '%s. %s\n' "$1" "$2"; }; pause() { read -r _ || true; }
    cmd_forget_host() { printf '%s|%s\n' "$1" "$2" > "$D/menu_forget"; }
    printf '6\n1.2.3.4\n2222\n\n0\n' | menu_instances 2>&1
)"
if [[ "$menu_out" == *"6. Forget a foreign"* && "$(cat "$D/menu_forget" 2>/dev/null)" == "1.2.3.4|2222" ]]; then
    pass "menu: Manage tunnels item 6 forgets a host key through cmd_forget_host"
else
    fail "menu: item 6 missing or not wired (menu said: $menu_out; forget got: $(cat "$D/menu_forget" 2>&1))"
fi

echo
if [[ "$FAILS" -ne 0 ]]; then
    echo "FAILED - ssh_hostkey_test: $FAILS failure(s), $PASSES check(s) passed"
    exit 1
fi
echo "PASSED - ssh_hostkey_test: $PASSES checks - foreign SSH host keys are pinned in the OmniTunnel known_hosts (accept-new, or yes-once-pinned on pre-7.6 ssh); a changed key is refused before any password or command, over direct and SOCKS5 paths, with a forget-host fix; forget-host validates its input"
