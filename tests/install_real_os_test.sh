#!/usr/bin/env bash
set -u

if [[ "${OT_REAL_OS:-}" != 1 ]]; then
    echo "SKIPPED - install_real_os_test (set OT_REAL_OS=1; it needs root, docker and internet access)"
    exit 0
fi

IMAGE="${OT_IMAGE:-ubuntu:24.04}"
SCENARIO="${OT_SCENARIO:-fresh}"
REPO="${OT_REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
INSTALLER="${OT_INSTALLER:-$REPO/install.sh}"
MANAGER="${OT_MANAGER:-$REPO/omnitunnel.sh}"
LIMIT="${OT_LIMIT:-600}"
NAME="ot-realos-$$"
LOG="$(mktemp)"

case "$(uname -m)" in x86_64|amd64) ARCH=amd64;; aarch64|arm64) ARCH=arm64;; *) echo "FAIL: unsupported CPU $(uname -m)"; exit 1;; esac

cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; rm -f "$LOG" "$LOG.b" "$LOG.brc"; }
trap cleanup EXIT

in_box() { docker exec "$NAME" sh -c "$1"; }

fail() {
    echo "FAIL: $IMAGE/$SCENARIO: $*" >&2
    if [[ -s "$LOG" ]]; then echo "--- last output:" >&2; tail -n 40 "$LOG" >&2; fi
    echo "--- package processes still running in the box:" >&2
    in_box 'for d in /proc/[0-9]*; do a=$(tr "\0" " " < $d/cmdline 2>/dev/null); case "$a" in *apt*|*dpkg*|*debconf*|*iperf3*) echo "${d#/proc/} $a";; esac; done' >&2 || true
    in_box 'tail -n 30 /var/log/omnitunnel-install.log 2>/dev/null' >&2 || true
    exit 1
}

step() { echo "== $IMAGE/$SCENARIO: $*"; }

installed() { [[ "$(in_box "dpkg-query -W -f='\${Status}' $1 2>/dev/null")" == "install ok installed" ]]; }

has_question() { in_box 'test -f /var/lib/dpkg/info/iperf3.templates'; }

stuck_pids() {
    in_box 'for d in /proc/[0-9]*; do [ "${d#/proc/}" = "$$" ] && continue; a=$(tr "\0" " " < $d/cmdline 2>/dev/null); case "$a" in */var/lib/dpkg/info/iperf3.config\ configure*|*/var/lib/dpkg/info/iperf3.postinst\ configure*) echo "${d#/proc/}";; esac; done'
}

make_interrupted_state() {
    local i pids shell
    step "making the state a user is left in after Ctrl+C during 'apt-get install iperf3'"
    timeout 300 docker exec "$NAME" sh -c 'apt-get update -qq >/dev/null 2>&1' || fail "apt-get update failed while preparing the interrupted state"
    docker exec -d -t "$NAME" bash -c 'echo $$ > /tmp/hung-shell; apt-get install -y iperf3 >/dev/null 2>&1; echo done > /tmp/hung-finished'
    pids=""
    for i in $(seq 1 120); do
        pids="$(stuck_pids)"
        [[ -n "$pids" ]] && break
        in_box 'test -f /tmp/hung-finished' && break
        sleep 1
    done
    if [[ -z "$pids" ]]; then
        if in_box 'test -f /tmp/hung-finished'; then
            echo "SKIPPED - install_real_os_test: $IMAGE has no hidden iperf3 question, so a plain install does not hang and there is no interrupted state to repair"
            exit 0
        fi
        fail "the plain install neither finished nor reached the iperf3 question within 120s"
    fi
    shell="$(in_box 'cat /tmp/hung-shell')"
    in_box "kill -INT -- -$shell" 2>/dev/null || true
    sleep 3
    in_box "kill -HUP -- -$shell" 2>/dev/null || true
    sleep 16
    [[ -n "$(stuck_pids)" ]] || fail "precondition: the hidden iperf3 question is no longer pending after the simulated Ctrl+C"
    if in_box 'DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=5 install -y sshpass </dev/null >/dev/null 2>&1'; then
        fail "precondition: another apt-get could still install packages, so the box is not in the broken state"
    fi
    step "broken state confirmed: iperf3 question pending (pid $(echo $(stuck_pids))), dpkg lock held"
}

check_packages() {
    local p
    for p in "$@"; do installed "$p" || fail "package $p is not installed (dpkg says: $(in_box "dpkg-query -W -f='\${db:Status-Abbrev}' $p 2>&1"))"; done
    [[ -z "$(in_box 'dpkg --audit 2>&1')" ]] || fail "dpkg --audit still reports problems: $(in_box 'dpkg --audit 2>&1' | head -5)"
    [[ -z "$(in_box 'ls -A /var/lib/dpkg/updates 2>/dev/null')" ]] || fail "dpkg still has an unfinished journal in /var/lib/dpkg/updates"
    [[ -z "$(stuck_pids)" ]] || fail "a package question is still pending (pids $(echo $(stuck_pids)))"
    if has_question; then
        in_box 'debconf-show iperf3 2>/dev/null' | grep -q 'start_daemon: false' || fail "iperf3/start_daemon is not false: $(in_box 'debconf-show iperf3 2>&1')"
        ! in_box 'ls /etc/systemd/system/multi-user.target.wants/ 2>/dev/null | grep -qi iperf' || fail "an iperf3 daemon was enabled at boot"
        ! in_box 'ls /etc/rc2.d/ 2>/dev/null | grep -qi iperf' || fail "an iperf3 init script was enabled"
    fi
}

run_limited() {
    local rc=0 started now
    started="$(date +%s)"
    timeout "$LIMIT" docker exec -t "$NAME" "$@" >"$LOG" 2>&1 || rc=$?
    now="$(date +%s)"
    ELAPSED=$((now - started))
    [[ "$rc" != 124 ]] || fail "did not finish within ${LIMIT}s - it hung"
    return "$rc"
}

step "starting a clean $IMAGE container with a terminal"
read -r -a DOCKER_EXTRA <<< "${OT_DOCKER_ARGS:-}"
[[ "$SCENARIO" == no-mirror ]] && DOCKER_EXTRA+=(--dns 192.0.2.1)
docker run -d -t --memory 512m ${DOCKER_EXTRA[@]+"${DOCKER_EXTRA[@]}"} --name "$NAME" "$IMAGE" sleep "$((LIMIT * 3 + 600))" >/dev/null || fail "cannot start $IMAGE"
in_box 'mkdir -p /tmp/ot/bin' || fail "cannot prepare /tmp/ot"
docker cp "$INSTALLER" "$NAME:/tmp/ot/install.sh" >/dev/null || fail "cannot copy the installer"
docker cp "$MANAGER" "$NAME:/tmp/ot/omnitunnel.sh" >/dev/null || fail "cannot copy the manager"
for b in omnitun hysteria chisel omnistripe omniackless; do
    [[ -f "$REPO/bin/$b-$ARCH" ]] && { docker cp "$REPO/bin/$b-$ARCH" "$NAME:/tmp/ot/bin/$b-$ARCH" >/dev/null || fail "cannot copy $b-$ARCH"; }
done

DEPS="iproute2 iptables iperf3 openssh-client sshpass ca-certificates curl python3 netcat-openbsd"

case "$SCENARIO" in
    fresh)
        step "running install.sh on a fresh box"
        run_limited bash /tmp/ot/install.sh || fail "install.sh exited non-zero"
        ;;
    concurrent)
        step "running two install.sh at the same time on a fresh box"
        ( timeout "$LIMIT" docker exec -t "$NAME" bash /tmp/ot/install.sh >"$LOG.b" 2>&1; echo "$?" >"$LOG.brc" ) &
        bpid=$!
        run_limited bash /tmp/ot/install.sh || fail "the first install.sh exited non-zero"
        wait "$bpid"
        [[ "$(cat "$LOG.brc" 2>/dev/null)" == 0 ]] || fail "the second install.sh exited non-zero: $(tail -n 8 "$LOG.b" 2>/dev/null)"
        grep -q 'another OmniTunnel install or update is running' "$LOG" "$LOG.b" || fail "neither run reported that it waited for the other"
        ;;
    interrupted)
        make_interrupted_state
        step "running install.sh again, as the user does after the Ctrl+C"
        run_limited bash /tmp/ot/install.sh || fail "install.sh exited non-zero"
        grep -q 'stuck on a hidden question' "$LOG" || fail "install.sh did not report the stuck question it cleared"
        ;;
    no-mirror)
        step "running install.sh on a box whose package mirrors cannot be reached (its DNS never answers)"
        run_limited bash /tmp/ot/install.sh || fail "install.sh exited non-zero"
        grep -q 'still missing after the install' "$LOG" || fail "install.sh did not tell the user which dependencies are missing"
        DEPS=""
        ;;
    manager-interrupted)
        in_box 'mkdir -p /opt/omnitunnel && cp /tmp/ot/omnitunnel.sh /opt/omnitunnel/omnitunnel.sh && chmod +x /opt/omnitunnel/omnitunnel.sh' || fail "cannot place the manager"
        make_interrupted_state
        step "running the manager's own iperf3 install (the benchmark path) on the broken box"
        run_limited /opt/omnitunnel/omnitunnel.sh _pkg-ensure iperf3 || fail "omnitunnel _pkg-ensure iperf3 exited non-zero"
        grep -q 'stuck on a hidden question' "$LOG" || fail "the manager did not report the stuck question it cleared"
        DEPS="iperf3"
        ;;
    *) fail "unknown scenario $SCENARIO";;
esac

step "finished in ${ELAPSED}s; checking the result"
check_packages $DEPS
if [[ "$SCENARIO" != manager-interrupted ]]; then
    want="$(grep -m1 -oE 'VERSION="[0-9.]+"' "$MANAGER" | grep -oE '[0-9.]+')"
    got="$(in_box 'omnitunnel version 2>&1')"
    [[ "$got" == *"tunnelctl $want"* ]] || fail "the omnitunnel command is not installed or reports '$got' instead of v$want"
    in_box '/usr/local/bin/omnitun version >/dev/null 2>&1' || fail "the core binary does not run"
fi
if [[ "$SCENARIO" == no-mirror ]]; then
    echo "PASSED - install_real_os_test $IMAGE/$SCENARIO: finished in ${ELAPSED}s with every mirror unreachable, named the missing dependencies, dpkg clean, the omnitunnel command installed"
else
    echo "PASSED - install_real_os_test $IMAGE/$SCENARIO: finished in ${ELAPSED}s, all dependencies installed, dpkg clean, no pending question, no iperf3 daemon enabled"
fi
