#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2317
set -u

SCRIPT="${1:-$(dirname "$0")/../omnitunnel.sh}"
INSTALLER="${2:-$(dirname "$0")/../install.sh}"

extract_from() {
    awk -v names="$2" '
    BEGIN { n=split(names, a, " "); for (i=1;i<=n;i++) want[a[i]]=1 }
    inblock { print; if ($0 ~ /^}/) inblock=0; next }
    {
        if (match($0, /^[A-Za-z0-9_]+\(\)[ \t]*\{/)) {
            nm=$0; sub(/\(\).*/, "", nm)
            if (nm in want) { print; if ($0 !~ /\}/) inblock=1 }
        }
    }' "$1"
}

fail() { echo "FAIL: $*" >&2; exit 1; }
checks=0
pass() { checks=$((checks + 1)); }

D="$(mktemp -d)"
SRV_PID=""
cleanup() { [[ -n "$SRV_PID" ]] && kill "$SRV_PID" 2>/dev/null; rm -rf "$D"; }
trap cleanup EXIT
BIN="$D/bin"; mkdir -p "$BIN"
CALLS="$D/calls"; : > "$CALLS"

cat > "$BIN/apt-get" <<'EOF'
#!/bin/bash
printf 'apt-get|%s|%s|%s|%s\n' "${DEBIAN_FRONTEND:-}" "${NEEDRESTART_SUSPEND:-}" "$(readlink /proc/self/fd/0 2>/dev/null || echo '?')" "$*" >> "$CALLS"
[[ -f "$CALLS.apt_lock" ]] && { echo "E: Could not get lock /var/lib/dpkg/lock-frontend. It is held by process 99 (apt-get)"; exit 100; }
[[ -f "$CALLS.apt_fail_other" ]] && { echo "E: Could not get lock /var/lib/dpkg/lock-frontend. It is held by process 77 (apt-get)" >> "$OMNI_PKG_LOG"; echo "E: Unable to locate package"; exit 100; }
[[ -f "$CALLS.apt_fail" ]] && exit 100
exit 0
EOF
cat > "$BIN/dpkg" <<'EOF'
#!/bin/bash
printf 'dpkg|%s|%s\n' "${DEBIAN_FRONTEND:-}" "$*" >> "$CALLS"
exit 0
EOF
cat > "$BIN/dpkg-query" <<'EOF'
#!/bin/bash
exit 1
EOF
cat > "$BIN/debconf-set-selections" <<'EOF'
#!/bin/bash
printf 'preseed|%s\n' "$(cat)" >> "$CALLS"
EOF
chmod +x "$BIN"/*
export CALLS
PATH="$BIN:$PATH"
export OMNI_PKG_LOG="$D/pkg.log"

for src in "$SCRIPT" "$INSTALLER"; do
    : > "$CALLS"
    (
        eval "$(extract_from "$src" "pkg_log pkg_run")"
        PKG_LOG="$OMNI_PKG_LOG"
        echo "not-a-terminal" > "$D/stdin"
        pkg_run 30 apt-get -o X=1 install -y iperf3 < "$D/stdin"
    )
    line="$(grep '^apt-get|' "$CALLS" | tail -1)"
    [[ "$line" == "apt-get|noninteractive|1|/dev/null|-o X=1 install -y iperf3" ]] || fail "$(basename "$src"): pkg_run must run apt-get with DEBIAN_FRONTEND=noninteractive, NEEDRESTART_SUSPEND=1 and stdin from /dev/null (got: $line)"
    pass
done

run_pkg() {
    (
        eval "$(extract_from "$SCRIPT" "pkg_log pkg_run pkg_log_locked pkg_fail_hint dpkg_ok stuck_debconf_pids dpkg_busy dpkg_broken apt_owner_hidden clear_stuck_install apt_prepare pkg_install")"
        eval "$(grep -m1 '^OMNI_APT_OPTS=' "$SCRIPT")"
        OMNI_APT_PREPARED=0; OMNI_APT_UPDATED=0
        info() { echo "INFO: $*"; }
        warn() { echo "WARN: $*"; }
        kill() { echo "kill|$*" >> "$CALLS"; [[ "${1:-}" == -0 ]] && return 1; return 0; }
        sleep() { :; }
        stuck_debconf_pids() { [[ -f "$D/stuck" ]] && cat "$D/stuck"; return 0; }
        apt_owner_hidden() { [[ ! -f "$D/shown" ]]; }
        dpkg_busy() { return 1; }
        dpkg_broken() { [[ -f "$D/broken" ]]; }
        "$@"
    )
}

: > "$CALLS"
out="$(run_pkg pkg_install iperf3 2>&1)"; rc=$?
[[ $rc -eq 0 ]] || fail "pkg_install iperf3 must succeed when apt-get succeeds (rc=$rc): $out"
grep -qx 'preseed|iperf3 iperf3/start_daemon boolean false' "$CALLS" || fail "pkg_install must preseed iperf3/start_daemon=false before installing: $(cat "$CALLS")"
grep -q '^apt-get|noninteractive|1|/dev/null|.*DPkg::Lock::Timeout=120.* update$' "$CALLS" || fail "pkg_install must run a bounded, non-interactive apt-get update: $(cat "$CALLS")"
grep -q '^apt-get|noninteractive|1|/dev/null|.*DPkg::Lock::Timeout=120.*Dpkg::Options::=--force-confold install -y --no-install-recommends iperf3$' "$CALLS" || fail "pkg_install must install with the lock timeout and confold options: $(cat "$CALLS")"
[[ "$(grep -n '^preseed|' "$CALLS" | cut -d: -f1)" -lt "$(grep -n ' install -y ' "$CALLS" | head -1 | cut -d: -f1)" ]] || fail "the preseed must happen before the install"
pass

: > "$CALLS"; touch "$D/broken"
out="$(run_pkg pkg_install sshpass 2>&1)"; rc=$?
rm -f "$D/broken"
[[ $rc -eq 0 ]] || fail "pkg_install must still install after repairing an interrupted dpkg (rc=$rc): $out"
grep -q '^dpkg|noninteractive|--force-confdef --force-confold --configure -a$' "$CALLS" || fail "an interrupted dpkg must be repaired with a non-interactive dpkg --configure -a: $(cat "$CALLS")"
[[ "$(grep -n '^dpkg|' "$CALLS" | head -1 | cut -d: -f1)" -lt "$(grep -n ' install -y ' "$CALLS" | head -1 | cut -d: -f1)" ]] || fail "the dpkg repair must run before the install"
grep -q 'repairing an interrupted package install' <<< "$out" || fail "the repair must be announced: $out"
pass

: > "$CALLS"; echo 4242 > "$D/stuck"
out="$(run_pkg pkg_install iperf3 2>&1)"; rc=$?
rm -f "$D/stuck"
grep -qx 'kill|4242' "$CALLS" || fail "a package question left pending by an earlier interrupted install must be stopped: $(cat "$CALLS")"
grep -q 'stuck on a hidden question' <<< "$out" || fail "stopping the stuck install must be announced: $out"
[[ "$(grep -n '^kill|' "$CALLS" | head -1 | cut -d: -f1)" -lt "$(grep -n ' install -y ' "$CALLS" | head -1 | cut -d: -f1)" ]] || fail "the stuck install must be stopped before the new install"
grep -q '^kill|-9' "$CALLS" && fail "a stuck install that exited on TERM must not get a KILL: $(cat "$CALLS")"
pass

: > "$CALLS"; echo 4343 > "$D/stuck"; touch "$D/shown"
out="$(run_pkg pkg_install iperf3 2>&1)"; rc=$?
rm -f "$D/stuck" "$D/shown"
grep -q '^kill|' "$CALLS" && fail "an apt that is asking its question in an open terminal must not be killed: $(cat "$CALLS")"
grep -q 'waiting for an answer in an open terminal (pid 4343)' <<< "$out" || fail "an apt waiting in an open terminal must be pointed out to the user: $out"
pass

: > "$CALLS"; touch "$CALLS.apt_lock"
out="$(run_pkg pkg_install iperf3 sshpass 2>&1)"; rc=$?
rm -f "$CALLS.apt_lock"
[[ $rc -ne 0 ]] || fail "pkg_install must fail while another apt holds the lock"
[[ "$(grep -c ' install -y ' "$CALLS")" == 1 ]] || fail "a lock failure must not be retried package by package (each retry would wait for the lock again): $(cat "$CALLS")"
pass

: > "$CALLS"; touch "$CALLS.apt_fail"
out="$(run_pkg pkg_install iperf3 sshpass 2>&1)"; rc=$?
rm -f "$CALLS.apt_fail"
[[ $rc -ne 0 ]] || fail "pkg_install must report failure when apt-get fails"
grep -q ' install -y --no-install-recommends iperf3$' "$CALLS" && grep -q ' install -y --no-install-recommends sshpass$' "$CALLS" || fail "after a failed transaction each package must be retried on its own: $(cat "$CALLS")"
pass

: > "$CALLS"; touch "$CALLS.apt_fail_other"
out="$(run_pkg pkg_install iperf3 sshpass 2>&1)"; rc=$?
rm -f "$CALLS.apt_fail_other"
[[ "$(grep -c ' install -y ' "$CALLS")" == 3 ]] || fail "a lock message written to the shared log by another install while this one failed for a different reason must not count as this run's lock (expected the transaction plus 2 per-package retries): $(cat "$CALLS")"
pass

if [[ -d /proc/self ]] && command -v python3 >/dev/null 2>&1; then
    S1=""; S2=""; S3=""
    env -u DEBIAN_FRONTEND python3 -c 'import time; time.sleep(60)' /var/lib/dpkg/info/iperf3.config configure & S1=$!
    DEBIAN_FRONTEND=noninteractive python3 -c 'import time; time.sleep(60)' /var/lib/dpkg/info/tzdata.config configure & S2=$!
    env -u DEBIAN_FRONTEND python3 -c 'while True: pass' /var/lib/dpkg/info/iperf3.postinst configure & S3=$!
    builtin command sleep 1
    for mode in ps proc; do
        got="$(
            eval "$(extract_from "$SCRIPT" "pkg_waits_for_input stuck_debconf_pids")"
            [[ "$mode" == proc ]] && ps() { return 1; }
            stuck_debconf_pids 0
        )"
        got="$(tr '\n' ' ' <<< "$got")"
        [[ " $got " == *" $S1 "* ]] || { kill "$S1" "$S2" "$S3" 2>/dev/null; fail "[$mode] a process waiting in an interactive debconf script must be found as stuck (got: $got)"; }
        [[ " $got " != *" $S2 "* ]] || { kill "$S1" "$S2" "$S3" 2>/dev/null; fail "[$mode] a configure step running with DEBIAN_FRONTEND=noninteractive cannot be waiting for an answer and must never be treated as stuck (got: $got)"; }
        [[ " $got " != *" $S3 "* ]] || { kill "$S1" "$S2" "$S3" 2>/dev/null; fail "[$mode] a configure step that is busy running (not sleeping) must not be treated as stuck (got: $got)"; }
        pass
    done
    kill "$S1" "$S2" "$S3" 2>/dev/null
fi

peer() {
    (
        eval "$(extract_from "$SCRIPT" "peer_conf save_peer _peer_creds peer_prepare")"
        PEER_DIR="$D/peers"
        info() { echo "INFO: $*"; }
        warn() { echo "WARN: $*"; }
        pkg_fail_hint() { :; }
        pkg_install() { echo "pkg_install|$*" >> "$CALLS"; [[ -f "$D/sshpass_ok" ]] && { printf '#!/bin/sh\n' > "$BIN/sshpass"; chmod +x "$BIN/sshpass"; return 0; }; return 1; }
        command() { if [[ "${1:-}" == -v && "${2:-}" == sshpass ]]; then [[ -x "$BIN/sshpass" ]]; return; fi; builtin command "$@"; }
        "$@"
    )
}
rm -rf "$D/peers"; rm -f "$BIN/sshpass"
: > "$CALLS"; touch "$D/sshpass_ok"
peer save_peer 203.0.113.7 root 'p@ss w0rd' ''
out="$(peer peer_prepare 203.0.113.7 2>&1)"
grep -qx 'pkg_install|sshpass' "$CALLS" || fail "a saved password with sshpass missing must install sshpass: $out"
[[ -x "$BIN/sshpass" ]] || fail "sshpass should now be present"
pass
: > "$CALLS"
out="$(peer peer_prepare 203.0.113.7 2>&1)"
[[ ! -s "$CALLS" ]] || fail "sshpass already present must not trigger an install"
pass
rm -f "$BIN/sshpass" "$D/sshpass_ok"; : > "$CALLS"
out="$(peer peer_prepare 198.51.100.4 2>&1)"
[[ ! -s "$CALLS" ]] || fail "no saved password (key login) must not install sshpass"
pass
out="$(peer peer_prepare 203.0.113.7 2>&1)"; rc=$?
[[ $rc -eq 0 ]] || fail "peer_prepare must not abort when sshpass cannot be installed"
grep -q 'ask for the foreign password at every step' <<< "$out" || fail "a failed sshpass install must be explained to the user: $out"
pass

out="$(
    eval "$(extract_from "$SCRIPT" "tok_re lanes_ok inst_name_ok create_id_ok new_create_id type_is_hysteria type_is_stripe type_is_ackless provision_peer")"
    info() { :; }; warn() { :; }
    die() { echo "DIE: $*" >&2; exit 1; }
    peer_ssh() { [[ "${2:-}" == "uname -m" ]] && { echo "ssh: connect to host 203.0.113.9 port 22: Connection timed out" >&2; return 255; }; return 0; }
    peer_scp() { return 0; }
    ( set -euo pipefail; provision_peer 203.0.113.9 t1 gre 203.0.113.9 192.0.2.1 51820 "" 10.201.9.2 10.201.9.1 none 16 "" 1 ) 2>&1
    echo "rc=$?"
)"
[[ "$(tail -n1 <<< "$out")" == "rc=1" ]] || fail "provision_peer must fail when SSH to the foreign fails: $out"
grep -q 'DIE: cannot run commands on the foreign 203.0.113.9 over SSH' <<< "$out" || fail "provision_peer must say why it stopped instead of exiting silently: $out"
pass

out="$(
    eval "$(extract_from "$SCRIPT" "tok_re lanes_ok inst_name_ok create_id_ok new_create_id type_is_hysteria type_is_stripe type_is_ackless provision_peer")"
    info() { :; }; warn() { :; }
    die() { echo "DIE: $*" >&2; exit 1; }
    peer_ssh() { [[ "${2:-}" == "uname -m" ]] && { echo x86_64; return 0; }; [[ "${2:-}" == mkdir* ]] && return 255; return 0; }
    peer_scp() { return 0; }
    ASSET_DIR="$D/assets"; SCRIPT_DIR="$D/assets"; SCRIPT_PATH="$SCRIPT"; mkdir -p "$ASSET_DIR/bin"
    ( set -euo pipefail; provision_peer 203.0.113.9 t1 gre 203.0.113.9 192.0.2.1 51820 "" 10.201.9.2 10.201.9.1 none 16 "" 1 ) 2>&1
    echo "rc=$?"
)"
[[ "$(tail -n1 <<< "$out")" == "rc=1" ]] && grep -q 'DIE: lost SSH to the foreign 203.0.113.9 while deploying' <<< "$out" || fail "a dropped SSH during deployment must be reported: $out"
pass

if command -v python3 >/dev/null 2>&1 && command -v curl >/dev/null 2>&1; then
    WEB="$D/web"; mkdir -p "$WEB"; printf 'payload-%s\n' "$(seq 1 2000 | tr '\n' ' ')" > "$WEB/file.bin"
    PORT=""
    for _ in 1 2 3 4 5; do
        p=$((20000 + RANDOM % 20000))
        python3 -m http.server "$p" --bind 127.0.0.1 --directory "$WEB" >/dev/null 2>&1 &
        SRV_PID=$!
        for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$p/" 2>/dev/null && { PORT=$p; break; }; kill -0 "$SRV_PID" 2>/dev/null || break; builtin command sleep 0.1; done
        [[ -n "$PORT" ]] && break
        kill "$SRV_PID" 2>/dev/null; SRV_PID=""
    done
    [[ -n "$PORT" ]] || fail "could not start a local HTTP server for the download checks"
    FETCH_INSTALLER="$(sed -n '/^    fetch() {$/,/^    }$/p' "$INSTALLER" | sed 's/^    //')"
    [[ -n "$FETCH_INSTALLER" ]] || fail "install.sh has no fetch() helper"
    for impl in omnitunnel install; do
        out="$(
            if [[ "$impl" == omnitunnel ]]; then
                eval "$(extract_from "$SCRIPT" "fetch_to")"; eval "$(grep -m1 '^CURL_DL=' "$SCRIPT")"; get() { fetch_to "$@"; }
            else
                CURL_OPTS=(-fL --connect-timeout 15 --retry 0 -sS); NOCACHE=(); eval "$FETCH_INSTALLER"; get() { fetch "$@"; }
            fi
            CURL_DL=(-fL --connect-timeout 15 --retry 0 -sS)
            T="$D/dl-$impl"; mkdir -p "$T"
            get "http://127.0.0.1:$PORT/file.bin" "$T/ok" && cmp -s "$T/ok" "$WEB/file.bin" && echo OK1
            ! ls "$T" | grep -q '\.part' && echo OK2
            get "http://127.0.0.1:$PORT/missing.bin" "$T/missing" 2>/dev/null || echo OK3
            [[ ! -e "$T/missing" ]] && ! ls "$T" | grep -q '\.part' && echo OK4
            echo keep > "$T/keep"
            get "http://127.0.0.1:$PORT/missing.bin" "$T/keep" 2>/dev/null || true
            [[ "$(cat "$T/keep")" == keep ]] && echo OK5
            for i in 1 2 3 4 5 6 7 8; do ( get "http://127.0.0.1:$PORT/file.bin" "$T/con"; : > "$T/done-$i" ) & done
            for _ in $(seq 1 300); do [[ "$(ls "$T" | grep -c '^done-')" -ge 8 ]] && break; builtin command sleep 0.1; done
            [[ "$(ls "$T" | grep -c '^done-')" -ge 8 ]] && cmp -s "$T/con" "$WEB/file.bin" && ! ls "$T" | grep -q '\.part' && echo OK6
        )"
        for k in OK1 OK2 OK3 OK4 OK5 OK6; do grep -qx "$k" <<< "$out" || fail "$impl download helper check $k failed (OK1 good file lands intact, OK2 no .part left, OK3 a 404 fails, OK4 a failed download creates nothing, OK5 a failed download keeps the existing file, OK6 eight concurrent downloads of one file leave it intact): $out"; done
        pass
    done
    GZ="$D/chisel.gz"; printf 'chisel-binary-%s\n' "$(seq 1 3000 | tr '\n' ' ')" > "$D/chisel.raw"; gzip -c "$D/chisel.raw" > "$GZ"
    CA="$D/chisel-assets"; mkdir -p "$CA/bin"
    for i in 1 2 3 4 5 6 7 8; do
        ( (
            eval "$(extract_from "$SCRIPT" "chisel_local_bin ensure_chisel")"
            arch_tag() { echo amd64; }
            info() { :; }
            die() { echo "DIE: $*" >&2; exit 1; }
            fetch_to() { builtin command sleep 0.$((RANDOM % 5)); cp "$GZ" "$2"; }
            ASSET_DIR="$CA"; SCRIPT_DIR="$D/none"; CHISEL_BIN="$D/chisel-bin-$i"; CHISEL_VER=1.10.1
            ensure_chisel && cmp -s "$CHISEL_BIN" "$D/chisel.raw" && echo "OKC$i" > "$D/chisel-ok-$i"
        ) 2>"$D/chisel-err-$i"; : > "$D/chisel-done-$i" ) &
    done
    for _ in $(seq 1 600); do [[ "$(ls "$D" | grep -c '^chisel-done-')" -ge 8 ]] && break; builtin command sleep 0.1; done
    [[ "$(ls "$D" | grep -c '^chisel-done-')" -ge 8 ]] || fail "the eight concurrent ensure_chisel runs did not all finish within 60 s"
    for i in 1 2 3 4 5 6 7 8; do [[ -f "$D/chisel-ok-$i" ]] || fail "concurrent first-time ensure_chisel run $i failed: $(cat "$D/chisel-err-$i")"; done
    cmp -s "$CA/bin/chisel-amd64" "$D/chisel.raw" || fail "the published chisel binary is not the decompressed download"
    ! ls "$CA/bin" | grep -qE '\.(gz|part)\.' || fail "concurrent ensure_chisel left staging files behind: $(ls "$CA/bin")"
    pass
else
    echo "NOTE: python3 or curl missing - download checks skipped"
fi

echo "PASSED - install_hang_wiring_test: $checks checks - package installs run non-interactively with stdin from /dev/null and bounded locks, iperf3's daemon question is preseeded to false, an interrupted dpkg is repaired and a stuck hidden earlier install is stopped first (an apt asking in an open terminal is left alone), only a sleeping interactive question is ever treated as stuck (never a noninteractive or busy configure step), failed transactions retry per package except on this run's own held lock (a lock line another install writes into the shared log does not count), a saved password installs sshpass (or explains why not), SSH failures in provision_peer are reported instead of a silent exit, and downloads never leave partial or empty files, even when run concurrently (including eight concurrent first-time chisel fetches)"
