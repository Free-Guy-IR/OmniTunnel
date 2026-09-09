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
OLD_CORE="$(sum_of /usr/local/bin/omnitun)"; OLD_HY="$(sum_of /usr/local/bin/hysteria)"
[[ -n "$OLD_VER" ]] && echo "OmniTunnel: found existing install v$OLD_VER ($ARCH), checking for updates..." \
                    || echo "OmniTunnel installer - CPU arch: $ARCH"

# deps: iptables, iproute2, iperf3 (benchmark), openssh, sshpass (peer auto-setup), python3 (hysteria relays)
# Only touch the package manager if something is actually missing - so a routine
# update (deps already present) never runs apt at all, and a broken *unrelated*
# third-party repo on the box can't spew "403 / no longer signed" errors into the
# output. When we do install, apt/yum noise is redirected away.
missing=0
for c in ip iptables iperf3 ssh sshpass curl python3 nc; do
    command -v "$c" >/dev/null 2>&1 || { missing=1; break; }
done
if [[ $missing == 1 ]]; then
    echo "installing dependencies..."
    if command -v apt-get >/dev/null; then
        apt-get update -qq >/dev/null 2>&1 || true
        apt-get install -y iproute2 iptables iperf3 openssh-client sshpass ca-certificates curl python3 netcat-openbsd >/dev/null 2>&1 || true
    elif command -v yum >/dev/null; then
        yum install -y iproute iptables iperf3 openssh-clients sshpass curl python3 nmap-ncat >/dev/null 2>&1 || true
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
else
    echo "downloading core + manager ..."
    # Cache-bust the raw CDN. A stale Fastly edge can otherwise hand back the
    # previous omnitunnel.sh for a few minutes after a release - the version
    # check below then sees NEW_VER == OLD_VER and silently reports "already up
    # to date", so `omnitunnel update` looks like it ran but changed nothing.
    # A unique query key + no-cache headers force a fresh copy every run.
    CB="?cb=$(date +%s)-${RANDOM}${RANDOM}"; NOCACHE=(-H 'Cache-Control: no-cache' -H 'Pragma: no-cache')
    curl -fsSL "${NOCACHE[@]}" "$RAW/bin/omnitun-$ARCH$CB" -o "$DEST/bin/omnitun-$ARCH"
    curl -fsSL "${NOCACHE[@]}" "$RAW/omnitunnel.sh$CB"      -o "$DEST/omnitunnel.sh"
    curl -fsSL "${NOCACHE[@]}" "$RAW/bin/hysteria-$ARCH$CB" -o "$DEST/bin/hysteria-$ARCH" || true
    curl -fsSL "${NOCACHE[@]}" "$RAW/bin/chisel-$ARCH$CB"   -o "$DEST/bin/chisel-$ARCH" || true
fi

bash -n "$DEST/omnitunnel.sh" 2>/dev/null || { echo "downloaded omnitunnel.sh is not a valid script (bad mirror / captive portal?) - aborting"; exit 1; }
[[ -s "$DEST/bin/omnitun-$ARCH" ]] || { echo "core binary omnitun-$ARCH is missing or empty - aborting"; exit 1; }
chmod +x "$DEST/bin/omnitun-$ARCH" "$DEST/omnitunnel.sh"
install -m 0755 "$DEST/bin/omnitun-$ARCH" /usr/local/bin/omnitun
[[ -f "$DEST/bin/hysteria-$ARCH" ]] && { chmod +x "$DEST/bin/hysteria-$ARCH"; install -m 0755 "$DEST/bin/hysteria-$ARCH" /usr/local/bin/hysteria; }
[[ -s "$DEST/bin/chisel-$ARCH" ]] && { chmod +x "$DEST/bin/chisel-$ARCH"; install -m 0755 "$DEST/bin/chisel-$ARCH" /usr/local/bin/chisel; }
ln -sf "$DEST/omnitunnel.sh" "$BINLINK"

NEW_VER="$(ver_of "$DEST/omnitunnel.sh" || true)"
NEW_CORE="$(sum_of /usr/local/bin/omnitun)"; NEW_HY="$(sum_of /usr/local/bin/hysteria)"
core_changed=0; [[ "$OLD_CORE" != "$NEW_CORE" || "$OLD_HY" != "$NEW_HY" ]] && core_changed=1

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
