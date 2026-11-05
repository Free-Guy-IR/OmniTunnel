#!/bin/bash
# OmniTunnel installer / updater - fetches the repo, drops the right prebuilt
# binaries for this CPU, and installs the manager. No compiler required.
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/Free-Guy-IR/OmniTunnel/main/install.sh) && omnitunnel
#
# Re-running it is also the update path: it detects an existing install, refreshes
# the manager + binaries, and - if the version actually changed - restarts the
# running tunnels so they pick up the new core. Nothing is torn down when the
# version is unchanged.
set -euo pipefail
REPO="https://github.com/Free-Guy-IR/OmniTunnel"
RAW="https://raw.githubusercontent.com/Free-Guy-IR/OmniTunnel/main"
DEST="/opt/omnitunnel"
BINLINK="/usr/local/bin/omnitunnel"

[[ $EUID -eq 0 ]] || { echo "run as root"; exit 1; }

INSTALL_LOCK_FD=""
if command -v flock >/dev/null 2>&1; then
    { exec {INSTALL_LOCK_FD}>/run/omnitunnel-install.lock; } 2>/dev/null \
        || { exec {INSTALL_LOCK_FD}>/tmp/omnitunnel-install.lock; } 2>/dev/null \
        || INSTALL_LOCK_FD=""
fi
if [[ -n "$INSTALL_LOCK_FD" ]] && ! flock -n "$INSTALL_LOCK_FD"; then
    echo "another OmniTunnel install or update is running on this box - waiting for it to finish (up to 15 min)..."
    flock -w 900 "$INSTALL_LOCK_FD" || { echo "the other install did not finish within 15 minutes - nothing was changed; try again later"; exit 1; }
fi

case "$(uname -m)" in
    x86_64|amd64) ARCH=amd64;;
    aarch64|arm64) ARCH=arm64;;
    *) echo "unsupported CPU: $(uname -m)"; exit 1;;
esac

ver_of() { grep -m1 -oE 'VERSION="[0-9.]+"' "$1" 2>/dev/null | grep -oE '[0-9.]+'; }
# echo the checksum, or nothing if the file is missing - and ALWAYS return 0, so a
# fresh install (no binaries yet) can't trip 'set -e' on the assignment below.
sum_of() { [[ -f "$1" ]] || return 0; { sha1sum "$1" 2>/dev/null || md5sum "$1" 2>/dev/null || cksum "$1"; } | awk '{print $1}'; }
OLD_VER="$(ver_of "$DEST/omnitunnel.sh" 2>/dev/null || true)"
# checksum the installed core binaries BEFORE we overwrite them, so we only
# restart running tunnels if the core actually changed - a script-only update
# must not needlessly bounce a production tunnel.
OLD_CORE="$(sum_of /usr/local/bin/omnitun)"; OLD_HY="$(sum_of /usr/local/bin/hysteria)"; OLD_STRIPE="$(sum_of /usr/local/bin/omnistripe)"; OLD_ACKLESS="$(sum_of /usr/local/bin/omniackless)"
[[ -n "$OLD_VER" ]] && echo "OmniTunnel: found existing install v$OLD_VER ($ARCH), checking for updates..." \
                    || echo "OmniTunnel installer - CPU arch: $ARCH"

# deps: iptables, iproute2, iperf3 (benchmark), openssh, sshpass (peer auto-setup), python3 (hysteria relays)
# Only touch the package manager if something is actually missing - so a routine
# update (deps already present) never runs apt at all, and a broken *unrelated*
# third-party repo on the box can't spew "403 / no longer signed" errors into the
# output. When we do install, apt/yum noise is redirected away.
PKG_LOG="${OMNI_PKG_LOG:-/var/log/omnitunnel-install.log}"
APT_OPTS=(-o DPkg::Lock::Timeout=120 -o Acquire::http::Timeout=20 -o Acquire::https::Timeout=20 -o Acquire::Retries=1 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
DEPS=(ip iptables iperf3 ssh sshpass curl python3 nc)
pkg_log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$PKG_LOG" 2>/dev/null || true; }
pkg_run() {
    local limit="$1" rc=0 out=""; shift
    pkg_log "+ $*"
    PKG_LOCKED=0
    out="$(mktemp "${TMPDIR:-/tmp}/omnitunnel-pkg.XXXXXX" 2>/dev/null)" || out=""
    if [[ -z "$out" ]]; then
        env DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1 NEEDRESTART_MODE=l APT_LISTCHANGES_FRONTEND=none \
            timeout -k 10 "$limit" "$@" </dev/null >>"$PKG_LOG" 2>&1 || rc=$?
        return "$rc"
    fi
    env DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1 NEEDRESTART_MODE=l APT_LISTCHANGES_FRONTEND=none \
        timeout -k 10 "$limit" "$@" </dev/null >"$out" 2>&1 || rc=$?
    cat "$out" >>"$PKG_LOG" 2>/dev/null || true
    grep -qiE 'could not get lock|locked by another process|unable to acquire the dpkg' "$out" && PKG_LOCKED=1
    rm -f "$out"
    return "$rc"
}
pkg_log_locked() { [[ "${PKG_LOCKED:-0}" == 1 ]]; }
dpkg_ok() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'; }
pkg_waits_for_input() {
    local st env
    st="$(cat "/proc/$1/stat" 2>/dev/null)" || return 1
    st="${st##*) }"
    [[ "${st%% *}" == S ]] || return 1
    env="$(tr '\0' '\n' 2>/dev/null <"/proc/$1/environ")" || return 0
    grep -qx 'DEBIAN_FRONTEND=noninteractive' <<<"$env" && return 1
    return 0
}
stuck_debconf_pids() {
    local d a p cand=""
    if ps -eo pid=,etimes=,args= >/dev/null 2>&1; then
        cand="$(ps -eo pid=,etimes=,args= 2>/dev/null | awk -v min="${1:-0}" '$2 >= min && $0 ~ /\/var\/lib\/dpkg\/info\/(iperf3|tzdata)\.(config|postinst) configure/ { print $1 }')" || cand=""
    else
        for d in /proc/[0-9]*; do
            a="$(tr '\0' ' ' 2>/dev/null <"$d/cmdline")" || continue
            [[ "$a" =~ /var/lib/dpkg/info/(iperf3|tzdata)\.(config|postinst)\ configure ]] && cand+="${d#/proc/} "
        done
    fi
    for p in $cand; do pkg_waits_for_input "$p" && echo "$p"; done
    return 0
}
dpkg_busy() {
    local f c
    for f in /proc/[0-9]*/comm; do
        { read -r c <"$f"; } 2>/dev/null || continue
        [[ "$c" == dpkg ]] && return 0
    done
    return 1
}
dpkg_broken() {
    command -v dpkg-query >/dev/null 2>&1 || return 1
    dpkg_busy && return 1
    dpkg-query -W -f='${db:Status-Abbrev}\n' 2>/dev/null | grep -qE '^.[UFHWT]|^..R' && return 0
    [[ -n "$(ls -A /var/lib/dpkg/updates 2>/dev/null)" ]]
}
apt_owner_hidden() {
    local p="$1" i c st out
    for i in 1 2 3 4 5 6 7 8; do
        [[ "$p" =~ ^[0-9]+$ && "$p" -gt 1 ]] || return 0
        { read -r c <"/proc/$p/comm"; } 2>/dev/null || return 0
        case "$c" in
            apt-get|apt|aptitude)
                out="$(readlink "/proc/$p/fd/1" 2>/dev/null)" || return 0
                case "$out" in
                    /dev/pts/*|/dev/tty*) [[ -e "$out" ]] && return 1; return 0;;
                    *) return 0;;
                esac;;
        esac
        st="$(cat "/proc/$p/stat" 2>/dev/null)" || return 0
        st="${st##*) }"; st="${st#* }"; p="${st%% *}"
    done
    return 0
}
clear_stuck_install() {
    local pids p i hidden="" shown="" alive=""
    pids="$(stuck_debconf_pids 15)"
    [[ -n "$pids" ]] || return 0
    for p in $pids; do if apt_owner_hidden "$p"; then hidden+=" $p"; else shown+=" $p"; fi; done
    [[ -z "$shown" ]] || echo "  ! another apt is waiting for an answer in an open terminal (pid$shown) - answer it there or close it; this install waits up to 2 minutes for it"
    [[ -n "$hidden" ]] || return 0
    echo "  an earlier package install is stuck on a hidden question (iperf3 'start as a daemon?' or tzdata 'time zone') - stopping it (pid$hidden)"
    pkg_log "stopping stuck debconf pids:$hidden"
    kill $hidden 2>/dev/null || true
    for i in 1 2 3 4 5; do
        alive=""; for p in $hidden; do kill -0 "$p" 2>/dev/null && alive+=" $p"; done
        [[ -z "$alive" ]] && break
        sleep 1
    done
    [[ -z "$alive" ]] || kill -9 $alive 2>/dev/null || true
    [[ -n "$shown" ]] && return 0
    for i in $(seq 1 20); do dpkg_busy || break; sleep 1; done
}
apt_prepare() {
    local i
    clear_stuck_install
    if ! dpkg_ok iperf3 && command -v debconf-set-selections >/dev/null 2>&1; then
        printf 'iperf3 iperf3/start_daemon boolean false\n' | debconf-set-selections >/dev/null 2>&1 || true
    fi
    dpkg_broken || return 0
    echo "  repairing an interrupted package install (dpkg --configure -a)..."
    for i in $(seq 1 24); do
        pkg_run 300 dpkg --force-confdef --force-confold --configure -a && return 0
        pkg_log_locked || break
        sleep 5
    done
    echo "  ! could not finish the interrupted package install (see $PKG_LOG)"
}
apt_install() {
    local p
    echo "  updating package lists (apt-get update, up to 4 min)..."
    pkg_run 240 apt-get "${APT_OPTS[@]}" update || echo "  ! apt-get update did not finish cleanly (a mirror may be unreachable) - trying the install anyway"
    echo "  installing: $* (waits up to 2 min if another apt is running)..."
    pkg_run 900 apt-get "${APT_OPTS[@]}" install -y --no-install-recommends "$@" && return 0
    pkg_log_locked && return 0
    for p in "$@"; do
        dpkg_ok "$p" || pkg_run 600 apt-get "${APT_OPTS[@]}" install -y --no-install-recommends "$p" || true
    done
}
missing=0
for c in "${DEPS[@]}"; do
    command -v "$c" >/dev/null 2>&1 || { missing=1; break; }
done
repair=0
if command -v apt-get >/dev/null 2>&1 && { [[ -n "$(stuck_debconf_pids 15)" ]] || dpkg_broken; }; then repair=1; fi
if [[ $missing == 1 || $repair == 1 ]]; then
    echo "installing dependencies... (details: $PKG_LOG)"
    if command -v apt-get >/dev/null; then
        apt_prepare
        [[ $missing == 1 ]] && apt_install iproute2 iptables iperf3 openssh-client sshpass ca-certificates curl python3 netcat-openbsd
    elif command -v yum >/dev/null; then
        echo "  installing with yum (up to 15 min)..."
        pkg_run 900 yum install -y iproute iptables iperf3 openssh-clients sshpass curl python3 nmap-ncat || true
    fi
    still=""
    for c in "${DEPS[@]}"; do command -v "$c" >/dev/null 2>&1 || still+=" $c"; done
    if [[ -n "$still" ]]; then
        echo "  ! still missing after the install:$still"
        tail -n 40 "$PKG_LOG" 2>/dev/null | uniq | tail -n 12 | sed 's/^/    /' || true
        echo "    full log: $PKG_LOG"
        echo "    (iperf3 is needed only by the benchmark and sshpass only for password SSH to a foreign; the rest of OmniTunnel installs anyway)"
    fi
fi

mkdir -p "$DEST/bin"
# prefer a local checkout (git clone), else download the needed files. The
# hysteria engine ships too (its own static binary), so the 'hysteria' transport
# works even where GitHub is unreachable at runtime.
if [[ -f "$(dirname "$0")/bin/omnitun-$ARCH" ]]; then
    SRC="$(cd "$(dirname "$0")" && pwd)"
    cp "$SRC/bin/omnitun-$ARCH" "$DEST/bin/omnitun-$ARCH"
    cp "$SRC/omnitunnel.sh" "$DEST/omnitunnel.sh"
    [[ -f "$SRC/bin/hysteria-$ARCH" ]] && cp "$SRC/bin/hysteria-$ARCH" "$DEST/bin/hysteria-$ARCH"
    [[ -f "$SRC/bin/chisel-$ARCH" ]] && cp "$SRC/bin/chisel-$ARCH" "$DEST/bin/chisel-$ARCH"
    [[ -f "$SRC/bin/omnistripe-$ARCH" ]] && cp "$SRC/bin/omnistripe-$ARCH" "$DEST/bin/omnistripe-$ARCH"
    [[ -f "$SRC/bin/omniackless-$ARCH" ]] && cp "$SRC/bin/omniackless-$ARCH" "$DEST/bin/omniackless-$ARCH"
else
    echo "downloading core + manager ..."
    # Cache-bust the raw CDN. A stale Fastly edge can otherwise hand back the
    # previous omnitunnel.sh for a few minutes after a release - the version
    # check below then sees NEW_VER == OLD_VER and silently reports "already up
    # to date", so `omnitunnel update` looks like it ran but changed nothing.
    # A unique query key + no-cache headers force a fresh copy every run.
    CB="?cb=$(date +%s)-${RANDOM}${RANDOM}"; NOCACHE=(-H 'Cache-Control: no-cache' -H 'Pragma: no-cache')
    CURL_OPTS=(-fL --connect-timeout 15 --retry 3 --retry-delay 3 --speed-limit 1024 --speed-time 60)
    if [[ -t 2 ]]; then CURL_OPTS+=(--progress-bar); else CURL_OPTS+=(-sS); fi
    fetch() {
        local part
        part="$(mktemp "$2.part.XXXXXX" 2>/dev/null)" || return 1
        if curl "${CURL_OPTS[@]}" "${NOCACHE[@]}" "$1" -o "$part" && [[ -s "$part" ]] && chmod 0644 "$part" && mv -f "$part" "$2"; then return 0; fi
        rm -f "$part"; return 1
    }
    find "$DEST" -maxdepth 2 -name '*.part.*' -mmin +60 -delete 2>/dev/null || true
    echo "  core engine (omnitun-$ARCH)"
    fetch "$RAW/bin/omnitun-$ARCH$CB" "$DEST/bin/omnitun-$ARCH.new" \
        || { echo "could not download the core from raw.githubusercontent.com (blocked or too slow from this box?) - nothing was changed"; exit 1; }
    echo "  manager (omnitunnel.sh)"
    fetch "$RAW/omnitunnel.sh$CB" "$DEST/omnitunnel.sh.new" \
        || { rm -f "$DEST/bin/omnitun-$ARCH.new"; echo "could not download omnitunnel.sh from raw.githubusercontent.com - nothing was changed"; exit 1; }
    bash -n "$DEST/omnitunnel.sh.new" 2>/dev/null \
        || { rm -f "$DEST/bin/omnitun-$ARCH.new" "$DEST/omnitunnel.sh.new"; echo "downloaded omnitunnel.sh is not a valid script (bad mirror / captive portal?) - aborting, nothing was changed"; exit 1; }
    mv -f "$DEST/bin/omnitun-$ARCH.new" "$DEST/bin/omnitun-$ARCH"
    mv -f "$DEST/omnitunnel.sh.new" "$DEST/omnitunnel.sh"
    for b in hysteria chisel omnistripe omniackless; do
        echo "  $b engine"
        fetch "$RAW/bin/$b-$ARCH$CB" "$DEST/bin/$b-$ARCH" \
            || echo "  ! could not download $b-$ARCH - the $b transport tries again when it is first used"
    done
fi

bash -n "$DEST/omnitunnel.sh" 2>/dev/null || { echo "downloaded omnitunnel.sh is not a valid script (bad mirror / captive portal?) - aborting"; exit 1; }
[[ -s "$DEST/bin/omnitun-$ARCH" ]] || { echo "core binary omnitun-$ARCH is missing or empty - aborting"; exit 1; }
chmod +x "$DEST/bin/omnitun-$ARCH" "$DEST/omnitunnel.sh"
install -m 0755 "$DEST/bin/omnitun-$ARCH" /usr/local/bin/omnitun
[[ -f "$DEST/bin/hysteria-$ARCH" ]] && { chmod +x "$DEST/bin/hysteria-$ARCH"; install -m 0755 "$DEST/bin/hysteria-$ARCH" /usr/local/bin/hysteria; }
[[ -s "$DEST/bin/chisel-$ARCH" ]] && { chmod +x "$DEST/bin/chisel-$ARCH"; install -m 0755 "$DEST/bin/chisel-$ARCH" /usr/local/bin/chisel; }
[[ -s "$DEST/bin/omnistripe-$ARCH" ]] && { chmod +x "$DEST/bin/omnistripe-$ARCH"; install -m 0755 "$DEST/bin/omnistripe-$ARCH" /usr/local/bin/omnistripe; }
[[ -s "$DEST/bin/omniackless-$ARCH" ]] && { chmod +x "$DEST/bin/omniackless-$ARCH"; install -m 0755 "$DEST/bin/omniackless-$ARCH" /usr/local/bin/omniackless; }
ln -sf "$DEST/omnitunnel.sh" "$BINLINK"

NEW_VER="$(ver_of "$DEST/omnitunnel.sh" || true)"
NEW_CORE="$(sum_of /usr/local/bin/omnitun)"; NEW_HY="$(sum_of /usr/local/bin/hysteria)"; NEW_STRIPE="$(sum_of /usr/local/bin/omnistripe)"; NEW_ACKLESS="$(sum_of /usr/local/bin/omniackless)"
bin_changed() { [[ -n "$1" && "$1" != "$2" ]]; }
core_changed=0; { bin_changed "$OLD_CORE" "$NEW_CORE" || bin_changed "$OLD_HY" "$NEW_HY" || bin_changed "$OLD_STRIPE" "$NEW_STRIPE" || bin_changed "$OLD_ACKLESS" "$NEW_ACKLESS"; } && core_changed=1

echo
if [[ -z "$OLD_VER" ]]; then
    echo "Installed OmniTunnel v${NEW_VER:-?} - core: $(/usr/local/bin/omnitun version 2>/dev/null)"
    [[ -x /usr/local/bin/hysteria ]] && echo "Hysteria engine: $(/usr/local/bin/hysteria version 2>/dev/null | awk -F'\t' '/Version/{print $2}')"
    echo "Run it with:  omnitunnel"
elif [[ "$OLD_VER" == "$NEW_VER" && "$core_changed" == 0 ]]; then
    echo "Already up to date (v$NEW_VER). Nothing changed; running tunnels left untouched."
else
    [[ "$OLD_VER" == "$NEW_VER" ]] && echo "Refreshed OmniTunnel (v$NEW_VER)" || echo "Updated OmniTunnel  v$OLD_VER  ->  v$NEW_VER"
    if [[ "$core_changed" == 1 ]]; then
        # the core binary actually changed - restart running tunnels to pick it up.
        changed=0
        for u in $(systemctl list-units 'omnitun-*.service' --state=active --no-legend 2>/dev/null | awk '{print $1}'); do
            iname="${u#omnitun-}"; iname="${iname%.service}"
            [[ -f "/etc/omnitunnel/inst/$iname/instance.conf" ]] || continue
            echo "  restarting $u"; systemctl restart "$u" 2>/dev/null || true; changed=1
        done
        # Then bounce the port-forward relays. They don't use the core binary, but
        # the tunnel restart above silently killed the sockets they held open
        # through the OLD tunnel; without this bounce an upstream proxy (mf-proxy
        # etc.) that kept a long-lived connection alive through a relay stays
        # wedged on the dead socket and traffic degrades to "very slow" instead of
        # erroring cleanly. Restarting the relays reconnects through the fresh tunnel.
        if [[ "$changed" == 1 ]]; then
            for u in $(systemctl list-units 'omnitun-*-pf-*.service' 'omnitun-*-mux.service' --state=active --no-legend 2>/dev/null | awk '{print $1}'); do
                iname="${u#omnitun-}"; iname="${iname%.service}"
                [[ -f "/etc/omnitunnel/inst/$iname/instance.conf" ]] && continue
                echo "  restarting relay $u"; systemctl restart "$u" 2>/dev/null || true
            done
        fi
        [[ "$changed" == 1 ]] && echo "Core updated - running tunnels + relays restarted." || echo "Core updated - no running tunnels to restart."
    else
        echo "Manager/installer refreshed only; core unchanged, so running tunnels were left untouched."
    fi
fi
