#!/bin/bash
# tunnelctl.sh - Multi-protocol obfuscated tunnel suite (part of the icmptun
# project). Drives ONE prebuilt static core binary ("tsuite") over an English
# TUI. No compiler needed on the box: the right binary for the CPU (amd64 or
# arm64) is shipped with the project.
#
#   gre      IP-over-GRE (kernel)  - often unpoliced / full line-rate
#   icmp     IP-over-ICMP          - blends in as ping (no key)
#   udp      IP-over-UDP AEAD      - fastest on open / UDP-friendly routes
#   tcp      IP-over-TCP AEAD      - one HTTPS-looking connection
#   mux      multi-connection TCP  - N parallel links; beats UDP-blocking DPI
#   ws       multi-connection WS   - looks like a browser/CDN WebSocket
#   hysteria Hysteria2 / QUIC      - Brutal CC beats UDP rate-policing; looks like HTTP/3
#
# One box runs many independent tunnels at once ("instances"), so any topology
# works: one Iran -> many foreign, one foreign -> many Iran, or many-to-many.
# Each instance has its own tun device, systemd unit, subnet and forward chain.
#
# State lives under /etc/omnitunnel, kept fully separate from any existing
# /etc/icmptun install (this tool never reads, edits or deletes that).
set -euo pipefail

VERSION="2.9.5"
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"

ROOT_DIR="/etc/omnitunnel"
INST_DIR="$ROOT_DIR/inst"
PEER_DIR="$ROOT_DIR/peers"
TSUITE_BIN="${OMNITUN_BIN:-/usr/local/bin/omnitun}"
BINLINK="/usr/local/bin/omnitunnel"   # the 'omnitunnel' command (symlink to this script)
# Hysteria2 is a separate Go engine (QUIC/UDP with the loss-agnostic "Brutal"
# congestion control). We ship its static binary alongside our C core and drive
# it through generated YAML - it is the stealthiest fast transport (looks like
# HTTP/3, with salamander obfs + website masquerade).
HYSTERIA_BIN="${OMNITUN_HYSTERIA_BIN:-/usr/local/bin/hysteria}"
HY_MASQ_HOST="www.bing.com"
# chisel (Go, jpillora/chisel) is the single-flow reverse MUX used to collapse
# many relay->foreign user connections into ONE tunnelled flow (see the mux
# section). A policed/lossy path shreds many parallel flows on upload but carries
# one sustained flow fast+stable, so muxing recovers the full rate. Shipped static
# alongside the core; pulled via raw like the rest.
CHISEL_BIN="${OMNITUN_CHISEL_BIN:-/usr/local/bin/chisel}"
CHISEL_VER="1.10.1"
# where the shipped per-arch binaries live (install.sh drops them here)
ASSET_DIR="${OMNITUN_ASSETS:-/opt/omnitunnel}"
RAW_BASE="https://raw.githubusercontent.com/Free-Guy-IR/OmniTunnel/main"

# shellcheck disable=SC2034
C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'; C_ITAL=$'\033[3m'
C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_YELLOW=$'\033[33m'; C_CYAN=$'\033[36m'
C_BLUE=$'\033[34m'; C_MAG=$'\033[35m'; C_WHITE=$'\033[97m'; C_GREY=$'\033[90m'
C_BGRN=$'\033[92m'; C_BCYN=$'\033[96m'; C_BYEL=$'\033[93m'; C_BRED=$'\033[91m'
C_BMAG=$'\033[95m'; C_BBLU=$'\033[94m'
# UI glyphs (fall back gracefully on dumb terminals - they are plain UTF-8)
G_DOT_ON="●"; G_DOT_OFF="○"; G_ARROW="→"; G_TL="╭"; G_TR="╮"; G_BL="╰"; G_BR="╯"; G_H="─"; G_V="│"

need_root() { [[ $EUID -eq 0 ]] || { printf '%b✗%b must be run as root\n' "$C_BRED$C_BOLD" "$C_RESET"; exit 1; }; }
die()  { printf '%b✗%b %s\n' "$C_BRED$C_BOLD" "$C_RESET" "$*" >&2; exit 1; }
ok()   { printf '%b✓%b %s\n' "$C_BGRN$C_BOLD" "$C_RESET" "$*"; }
info() { printf '%b›%b %s\n' "$C_BCYN$C_BOLD" "$C_RESET" "$*"; }
warn() { printf '%b!%b %s\n' "$C_BYEL$C_BOLD" "$C_RESET" "$*"; }
pause() { printf '\n  %bPress Enter to continue...%b' "$C_GREY" "$C_RESET"; read -r _ || true; }

arch_tag() { case "$(uname -m)" in x86_64|amd64) echo amd64;; aarch64|arm64) echo arm64;; *) echo unknown;; esac; }

pick_num() {
    local v="${1:-}" max="${2:-0}"
    [[ "$v" =~ ^[0-9]+$ ]] || return 1
    [[ ${#v} -le 6 ]] || return 1
    v=$((10#$v))
    [[ "$v" -ge 1 && "$v" -le "$max" ]] || return 1
    printf '%s' "$v"
}

norm_port() {
    local v="${1:-}"
    [[ "$v" =~ ^[0-9]{1,5}$ ]] || return 1
    v=$((10#$v))
    [[ "$v" -ge 1 && "$v" -le 65535 ]] || return 1
    printf '%s' "$v"
}

validate_inst_name() {
    local n="${1:-}" other
    [[ -n "$n" ]] || die "instance name cannot be empty"
    [[ "$n" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$ ]] || die "instance name must start alphanumeric and contain only letters, digits, - or _ (got '$n')"
    for other in $(list_instances); do
        [[ "$other" == "$n" ]] && continue
        case "$n" in
            "$other"-mux|"$other"-pf-*)
                die "name '$n' would collide with a helper unit of instance '$other' - pick another name";;
        esac
        case "$other" in
            "$n"-mux|"$n"-pf-*)
                die "instance '$other' already exists and collides with this one's helper units - remove or rename it first";;
        esac
    done
    return 0
}

rewrite_without() {
    local file="$1" pat="$2" t rc
    if [[ -e "$file" || -L "$file" ]]; then
        [[ -f "$file" ]] || return 2
    else
        return 0
    fi
    t="$(mktemp "$file.XXXXXX" 2>/dev/null)" || return 2
    rc=0; grep -v "$pat" "$file" > "$t" 2>/dev/null || rc=$?
    [[ "$rc" -le 1 ]] || { rm -f "$t"; return 2; }
    mv "$t" "$file" || { rm -f "$t"; return 2; }
    return 0
}

# make sure /usr/local/bin/omnitun exists and matches this CPU
ensure_binary() {
    [[ -x "$TSUITE_BIN" ]] && return 0
    local a; a="$(arch_tag)"; [[ "$a" == unknown ]] && die "unsupported CPU: $(uname -m)"
    local cand=""
    for d in "$ASSET_DIR/bin" "$SCRIPT_DIR/bin"; do [[ -f "$d/omnitun-$a" ]] && cand="$d/omnitun-$a" && break; done
    [[ -n "$cand" ]] || die "core binary omnitun-$a not found (looked in $ASSET_DIR/bin and $SCRIPT_DIR/bin). Run install.sh."
    install -m 0755 "$cand" "$TSUITE_BIN"
}

# locate this box's hysteria binary (shipped in bin/, or downloadable)
hy_local_bin() {
    local a="$1" d
    for d in "$ASSET_DIR/bin" "$SCRIPT_DIR/bin"; do [[ -f "$d/hysteria-$a" ]] && { echo "$d/hysteria-$a"; return 0; }; done
    return 1
}
# make sure /usr/local/bin/hysteria exists for this CPU (ship-first, download-fallback)
ensure_hysteria() {
    [[ -x "$HYSTERIA_BIN" ]] && return 0
    local a; a="$(arch_tag)"; [[ "$a" == unknown ]] && die "unsupported CPU: $(uname -m)"
    local cand; cand="$(hy_local_bin "$a" || true)"
    if [[ -z "$cand" ]]; then
        info "  fetching hysteria core for $a ..."
        mkdir -p "$ASSET_DIR/bin"
        curl -fsSL -o "$ASSET_DIR/bin/hysteria-$a" \
            "https://github.com/apernet/hysteria/releases/download/app%2Fv2.12.0/hysteria-linux-$a" \
            || die "could not obtain hysteria-$a (no shipped copy and download failed)"
        chmod +x "$ASSET_DIR/bin/hysteria-$a"; cand="$ASSET_DIR/bin/hysteria-$a"
    fi
    install -m 0755 "$cand" "$HYSTERIA_BIN"
}

# locate this box's chisel binary (shipped in bin/, or downloadable)
chisel_local_bin() {
    local a="$1" d
    for d in "$ASSET_DIR/bin" "$SCRIPT_DIR/bin"; do [[ -f "$d/chisel-$a" ]] && { echo "$d/chisel-$a"; return 0; }; done
    return 1
}
# make sure /usr/local/bin/chisel exists for this CPU (ship-first, download-fallback)
ensure_chisel() {
    [[ -x "$CHISEL_BIN" ]] && return 0
    local a; a="$(arch_tag)"; [[ "$a" == unknown ]] && die "unsupported CPU: $(uname -m)"
    local cand; cand="$(chisel_local_bin "$a" || true)"
    if [[ -z "$cand" ]]; then
        info "  fetching chisel mux core for $a ..."
        mkdir -p "$ASSET_DIR/bin"
        curl -fsSL "https://github.com/jpillora/chisel/releases/download/v$CHISEL_VER/chisel_${CHISEL_VER}_linux_$a.gz" \
            | gzip -d > "$ASSET_DIR/bin/chisel-$a" 2>/dev/null \
            || die "could not obtain chisel-$a (no shipped copy and download failed)"
        chmod +x "$ASSET_DIR/bin/chisel-$a"; cand="$ASSET_DIR/bin/chisel-$a"
    fi
    install -m 0755 "$cand" "$CHISEL_BIN"
}

# ------------------------------------------------------------ type registry ---
ALL_TYPES="gre icmp udp mux ws hysteria tcp fou vxlan reverse-mux"
type_desc() {
    case "$1" in
        gre)      echo "IP-over-GRE  (kernel; often unpoliced & full line-rate)";;
        icmp)     echo "IP-over-ICMP  (blends in as ping; no key)";;
        udp)      echo "IP-over-UDP AEAD  (fastest where UDP is allowed)";;
        mux)      echo "multi-connection TCP  (N links; for UDP-blocking DPI)";;
        ws)       echo "multi-connection WebSocket  (looks like HTTPS; stealthy)";;
        hysteria) echo "Hysteria2/QUIC  (loss-agnostic; beats UDP rate-policing; looks like HTTP/3)";;
        tcp)      echo "single TCP AEAD  (looks like one HTTPS connection)";;
        fou)      echo "GRE-in-UDP  (kernel; GRE hidden inside plain UDP on its port)";;
        vxlan)    echo "VXLAN L2-over-UDP  (kernel; Ethernet inside UDP)";;
        reverse-mux) echo "ICMP-reply + single-flow MUX  (Iran->foreign relay: beats policed multi-flow UPLOAD)";;
        *) echo "";;
    esac
}
# gre/icmp/fou/vxlan are kernel/plaintext carriers - no PSK; reverse-mux rides icmp (no PSK either)
type_uses_key() { [[ "$1" != icmp && "$1" != gre && "$1" != fou && "$1" != vxlan && "$1" != reverse-mux ]]; }
# reverse-mux is icmp(reply)-under-the-hood + a chisel single-flow MUX layer
type_is_revmux() { [[ "$1" == reverse-mux ]]; }
# native kernel tunnels - no compiled core binary involved
type_is_kernel() { [[ "$1" == gre || "$1" == fou || "$1" == vxlan ]]; }
# Starting port for auto-allocation. udp/fou/vxlan carry REAL UDP, so keep them
# well clear of the 51820-51899 WireGuard range that some ISPs (seen on IR mobile)
# block wholesale - a UDP tunnel landing on 51821 there is silently dropped (this
# bit the plain `udp` transport too). gre's "port" is only a GRE key, and
# tcp/mux/ws are TCP, so those are unaffected and stay at 51820. hysteria runs its
# own QUIC/443 masquerade and manages its own port.
port_base() { case "$1" in udp|fou|vxlan) echo 28820;; *) echo 51820;; esac; }
# hysteria is a separate engine: its own binary + YAML, no tun device, forwards
# ports natively (no iptables DNAT). It gets special-cased throughout.
type_is_hysteria() { [[ "$1" == hysteria ]]; }

# ------------------------------------------------------------ instance i/o ----
inst_path() { echo "$INST_DIR/$1"; }
inst_conf() { echo "$INST_DIR/$1/instance.conf"; }
inst_pf()   { echo "$INST_DIR/$1/pf.conf"; }
inst_exists() { [[ -f "$(inst_conf "$1")" ]]; }
list_instances() { [[ -d "$INST_DIR" ]] && ls -1 "$INST_DIR" 2>/dev/null | sort || true; }
svc_name() { echo "omnitun-$1.service"; }
dnat_chain() { echo "TSUITE_$(echo "$1" | tr '[:lower:]-' '[:upper:]_')"; }
gen_key() { head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'; }
default_local_ip() { ip -4 route get 1.1.1.1 2>/dev/null | grep -oE 'src [0-9.]+' | awk '{print $2}' | head -1; }
default_wan_dev() { ip -4 route get 1.1.1.1 2>/dev/null | grep -oE 'dev [^ ]+' | awk '{print $2}' | head -1; }

FWD_SYSCTL_FILE="/etc/sysctl.d/99-omnitunnel-forwarding.conf"
FWD_SYSCTL_BODY='net.ipv4.ip_forward = 1
net.ipv4.conf.all.forwarding = 1
net.ipv4.conf.default.forwarding = 1'
persist_forwarding() {
    local cur tmp
    cur="$(cat "$FWD_SYSCTL_FILE" 2>/dev/null || true)"
    [[ "$cur" == "$FWD_SYSCTL_BODY" ]] && return 0
    mkdir -p "$(dirname "$FWD_SYSCTL_FILE")" 2>/dev/null || return 1
    tmp="$(mktemp "$FWD_SYSCTL_FILE.XXXXXX" 2>/dev/null)" || return 1
    printf '%s\n' "$FWD_SYSCTL_BODY" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
    chmod 644 "$tmp" 2>/dev/null || true
    mv "$tmp" "$FWD_SYSCTL_FILE" 2>/dev/null || { rm -f "$tmp"; return 1; }
    return 0
}
ensure_forwarding() {
    local dev="${1:-}" wan k p
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
    sysctl -w net.ipv4.conf.all.forwarding=1 >/dev/null 2>&1 || true
    sysctl -w net.ipv4.conf.default.forwarding=1 >/dev/null 2>&1 || true
    wan="$(default_wan_dev || true)"
    for k in "$wan" "$dev"; do
        [[ -n "$k" ]] || continue
        p="/proc/sys/net/ipv4/conf/$k/forwarding"
        [[ -w "$p" ]] && printf '1\n' > "$p" 2>/dev/null || true
    done
    persist_forwarding || warn "could not persist forwarding to $FWD_SYSCTL_FILE - it will reset on reboot"
    return 0
}
forwarding_offenders() {
    local i f out=""
    for i in /proc/sys/net/ipv4/conf/*/forwarding; do
        [[ -r "$i" ]] || continue
        f="$(cat "$i" 2>/dev/null)"
        [[ "$f" == 0 ]] || continue
        i="${i#/proc/sys/net/ipv4/conf/}"; i="${i%/forwarding}"
        [[ "$i" == lo ]] && continue
        out+="$i "
    done
    printf '%s' "$out"
}
repair_all_forwarding() {
    local k p
    for k in $(forwarding_offenders); do
        p="/proc/sys/net/ipv4/conf/$k/forwarding"
        [[ -w "$p" ]] && printf '1\n' > "$p" 2>/dev/null || true
    done
    return 0
}
forwarding_conf_overrides() {
    local base d f out="" seen=" " b
    base="$(basename "$FWD_SYSCTL_FILE")"
    for d in /etc/sysctl.d /run/sysctl.d /usr/local/lib/sysctl.d /usr/lib/sysctl.d /lib/sysctl.d; do
        [[ -d "$d" ]] || continue
        for f in "$d"/*.conf; do
            [[ -e "$f" ]] || continue
            b="$(basename "$f")"
            [[ "$seen" == *" $b "* ]] && continue
            seen+="$b "
            [[ "$b" == "$base" ]] && continue
            [[ "$b" > "$base" ]] || continue
            grep -qE '^[[:space:]]*net\.ipv4\.(ip_forward|conf\.[^.]+\.forwarding)[[:space:]]*=' "$f" 2>/dev/null || continue
            out+="$f "
        done
    done
    printf '%s' "$out"
}

load_inst() {
    local n="$1"; inst_exists "$n" || die "no such instance: $n"
    TYPE=""; ROLE=""; LOCAL_IP=""; PEER_IP=""; TUN_ADDR=""; PEER_ADDR=""; PORT=""; KEY=""; DEV=""; MTU="1400"; NCONN="16"; SHAPE="none"; ICMP_MODE=""
    # shellcheck disable=SC1090
    source "$(inst_conf "$n")"; INAME="$n"
}

# create NAME TYPE ROLE LOCAL PEER PORT KEY TUN_ADDR PEER_ADDR [SHAPE] [NCONN]
create_inst() {
    local n="$1" t="$2" role="$3" lip="$4" pip="$5" port="$6" key="$7" ta="$8" pa="$9" shape="${10:-none}" nc="${11:-16}" imode="${12:-}"
    # reverse-mux IS icmp with the reply-type forced (its whole point is the
    # reply-gated dodge), so default its ICMP_MODE to reply if unset.
    [[ "$t" == reverse-mux && -z "$imode" ]] && imode=reply
    validate_inst_name "$n"
    local dev="ts-$n"; [[ ${#dev} -gt 15 ]] && dev="ts$(printf '%s' "$n" | cksum | tr -dc '0-9' | cut -c1-8)"
    mkdir -p "$(inst_path "$n")"; : > "$(inst_pf "$n")"
    cat > "$(inst_conf "$n")" <<EOF
TYPE=$t
ROLE=$role
LOCAL_IP=$lip
PEER_IP=$pip
TUN_ADDR=$ta
PEER_ADDR=$pa
PORT=$port
KEY=$key
DEV=$dev
MTU=1400
NCONN=$nc
SHAPE=$shape
ICMP_MODE=$imode
EOF
}

# ------------------------------------------------- kernel carrier commands ----
# Native kernel tunnels (gre / fou / vxlan) are brought up with plain `ip`
# commands - no core binary. PORT does double duty as the disambiguator so
# several tunnels can share one endpoint pair without colliding:
#   gre   -> GRE key
#   fou   -> FOU UDP port AND the inner GRE key (GRE hidden inside UDP)
#   vxlan -> VXLAN VNI AND UDP dstport
# Called with an instance already loaded (DEV/LOCAL_IP/PEER_IP/... in scope).
kernel_up_cmd() {
    case "$TYPE" in
        gre)
            echo "modprobe ip_gre 2>/dev/null; ip link del $DEV 2>/dev/null; ip link add $DEV type gre local $LOCAL_IP remote $PEER_IP ttl 255 key $PORT; ip addr add $TUN_ADDR peer $PEER_ADDR dev $DEV; ip link set $DEV up mtu $MTU";;
        fou)
            # The FOU receive binding (ip fou add) is a global UDP:PORT -> GRE
            # decap rule. On this kernel 'ip fou del' is unreliable ("Invalid
            # argument"), so we never delete it: 'ip fou add' is idempotent
            # ("in use" is harmless), the binding survives restarts, and a reused
            # port simply reuses the existing rule. Teardown only drops the device.
            echo "modprobe fou 2>/dev/null; modprobe ip_gre 2>/dev/null; ip link del $DEV 2>/dev/null; ip fou add port $PORT ipproto 47 2>/dev/null; ip link add $DEV type gre local $LOCAL_IP remote $PEER_IP ttl 255 key $PORT encap fou encap-sport $PORT encap-dport $PORT; ip addr add $TUN_ADDR peer $PEER_ADDR dev $DEV; ip link set $DEV up mtu $MTU";;
        vxlan)
            echo "modprobe vxlan 2>/dev/null; ip link del $DEV 2>/dev/null; ip link add $DEV type vxlan id $PORT local $LOCAL_IP remote $PEER_IP dstport $PORT ttl 255; ip addr add $TUN_ADDR/24 dev $DEV; ip link set $DEV up mtu $MTU";;
    esac
}
kernel_down_cmd() { echo "ip link del $DEV 2>/dev/null"; }

# ------------------------------------------------------- execstart builder ----
build_execstart() {
    local sflag=""; [[ "$ROLE" == "server" ]] && sflag=" -s"
    case "$TYPE" in
        udp)  echo "$TSUITE_BIN udp -L $LOCAL_IP -R $PEER_IP -A $TUN_ADDR -P $PEER_ADDR -p $PORT -k $KEY -T $DEV -M $MTU";;
        tcp)  echo "$TSUITE_BIN tcp -L $LOCAL_IP -R $PEER_IP -A $TUN_ADDR -P $PEER_ADDR -p $PORT -k $KEY$sflag -T $DEV -M $MTU";;
        mux)  echo "$TSUITE_BIN mux -L $LOCAL_IP -R $PEER_IP -A $TUN_ADDR -P $PEER_ADDR -p $PORT -k $KEY$sflag -N $NCONN -T $DEV -M $MTU";;
        ws)   echo "$TSUITE_BIN ws -L $LOCAL_IP -R $PEER_IP -A $TUN_ADDR -P $PEER_ADDR -p $PORT -k $KEY$sflag -N $NCONN -T $DEV -M $MTU";;
        icmp) echo "$TSUITE_BIN icmp -L $LOCAL_IP -R $PEER_IP -A $TUN_ADDR -P $PEER_ADDR -I 4d54 -T $DEV -M $MTU$sflag${ICMP_MODE:+ -r $ICMP_MODE}";;
        # reverse-mux rides the icmp engine with the reply type forced; the chisel
        # MUX layer lives in separate units (mux-add / mux-token), not here.
        reverse-mux) echo "$TSUITE_BIN icmp -L $LOCAL_IP -R $PEER_IP -A $TUN_ADDR -P $PEER_ADDR -I 4d54 -T $DEV -M $MTU$sflag -r ${ICMP_MODE:-reply}";;
    esac
}

# ------------------------------------------------------- hysteria config ------
# One 64-hex KEY seeds both the auth password and the salamander obfs password,
# so the two ends stay in sync from the same secret.
hy_creds() { HY_AUTH="${KEY:0:32}"; HY_OBFS="${KEY:32:32}"; [[ -n "$HY_OBFS" ]] || HY_OBFS="$HY_AUTH"; }
hy_bw() { case "${1:-}" in ''|none|0) echo 200;; *) echo "${1%%[a-z]*}";; esac; }  # -> mbps number
# self-signed cert (masquerade CN) generated once per instance
hy_cert() {
    local d="$1"; [[ -f "$d/hy.crt" && -f "$d/hy.key" ]] && return 0
    openssl req -x509 -newkey rsa:2048 -keyout "$d/hy.key" -out "$d/hy.crt" \
        -days 3650 -nodes -subj "/CN=$HY_MASQ_HOST" >/dev/null 2>&1 || die "openssl needed for hysteria cert"
    chmod 600 "$d/hy.key"
}
# render the hysteria YAML for instance <n> into file <out>.
# The engine config holds only the transport + a localhost SOCKS5 (always on, so
# it stays connected before any forward is added) + any UDP forwards. TCP
# forwards deliberately live OUTSIDE the engine (see relays below) so that
# adding/removing one never restarts the engine or disturbs the QUIC session.
hy_render_config() {
    local n="$1" out="$2"; load_inst "$n"; local d; d="$(inst_path "$n")"; hy_creds
    if [[ "$ROLE" == server ]]; then
        hy_cert "$d"
        cat > "$out" <<EOF
listen: :$PORT
tls:
  cert: $d/hy.crt
  key: $d/hy.key
obfs:
  type: salamander
  salamander:
    password: $HY_OBFS
auth:
  type: password
  password: $HY_AUTH
masquerade:
  type: proxy
  proxy:
    url: https://$HY_MASQ_HOST/
    rewriteHost: true
quic:
  maxIdleTimeout: 90s
  keepAlivePeriod: 5s
  disablePathMTUDiscovery: true
EOF
    else
        local bw; bw="$(hy_bw "$SHAPE")"
        cat > "$out" <<EOF
server: $PEER_IP:$PORT
auth: $HY_AUTH
tls:
  insecure: true
  sni: $HY_MASQ_HOST
obfs:
  type: salamander
  salamander:
    password: $HY_OBFS
quic:
  maxIdleTimeout: 90s
  keepAlivePeriod: 5s
  disablePathMTUDiscovery: true
bandwidth:
  up: ${bw} mbps
  down: ${bw} mbps
socks5:
  listen: 127.0.0.1:$PORT
EOF
        # UDP forwards can't ride the SOCKS5 relay, so they stay in-config (adding
        # a UDP forward is the one case that still restarts the engine). TCP
        # forwards are normally handled by standalone relays and are NOT emitted
        # here; only the python3-less fallback sets HY_TCP_IN_CONFIG=1.
        local pf udp_e="" tcp_e="" proto port; pf="$(inst_pf "$n")"
        if [[ -s "$pf" ]]; then
            while IFS=: read -r proto port; do [[ -z "$proto" || -z "$port" ]] && continue
                local blk="  - listen: 0.0.0.0:$port"$'\n'"    remote: 127.0.0.1:$port"$'\n'
                [[ "$proto" == udp ]] && udp_e+="$blk"
                [[ "$proto" == tcp && "${HY_TCP_IN_CONFIG:-0}" == 1 ]] && tcp_e+="$blk"
            done < "$pf"
        fi
        [[ -n "$tcp_e" ]] && { echo "tcpForwarding:" >> "$out"; printf '%s' "$tcp_e" >> "$out"; }
        [[ -n "$udp_e" ]] && { echo "udpForwarding:" >> "$out"; printf '%s' "$udp_e" >> "$out"; }
    fi
    chmod 600 "$out" 2>/dev/null || true
}
hy_write_config() { hy_render_config "$1" "$(inst_path "$1")/hy.yaml"; }

# --- zero-disruption TCP forwards: one tiny relay per port, through the SOCKS5 --
# Each relay listens on 0.0.0.0:<port> and dials 127.0.0.1:<port> (resolved at the
# far end) via the client's local SOCKS5. It is its own systemd unit, so adding a
# port starts one relay and touches nothing else; the engine never restarts.
HY_RELAY="$ASSET_DIR/socksfwd.py"
hy_relay_unit() { echo "omnitun-$1-pf-$2.service"; }   # <inst> <port>
hy_write_relay_script() {
    [[ -f "$HY_RELAY" ]] && return 0
    mkdir -p "$(dirname "$HY_RELAY")"
    cat > "$HY_RELAY" <<'PYEOF'
import sys, socket, struct, threading
def s5(sh, sp, th, tp):
    s = socket.create_connection((sh, sp), timeout=10)
    s.sendall(b"\x05\x01\x00")
    if s.recv(2) != b"\x05\x00": s.close(); raise IOError("no-auth refused")
    t = th.encode()
    s.sendall(b"\x05\x01\x00\x03" + bytes([len(t)]) + t + struct.pack(">H", tp))
    r = s.recv(4)
    if len(r) < 2 or r[1] != 0: s.close(); raise IOError("connect refused")
    a = r[3]
    s.recv(4+2) if a == 1 else (s.recv(s.recv(1)[0]+2) if a == 3 else s.recv(16+2))
    return s
def pipe(a, b):
    try:
        while True:
            d = a.recv(65536)
            if not d: break
            b.sendall(d)
    except OSError: pass
    finally:
        try: b.shutdown(socket.SHUT_WR)
        except OSError: pass
def handle(c, sh, sp, th, tp):
    try: u = s5(sh, sp, th, tp)
    except Exception: c.close(); return
    threading.Thread(target=pipe, args=(c, u), daemon=True).start()
    pipe(u, c)
    for x in (c, u):
        try: x.close()
        except OSError: pass
def main():
    lh, lp, sh, sp, th, tp = sys.argv[1], int(sys.argv[2]), sys.argv[3], int(sys.argv[4]), sys.argv[5], int(sys.argv[6])
    srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((lh, lp)); srv.listen(256)
    while True:
        c, _ = srv.accept()
        threading.Thread(target=handle, args=(c, sh, sp, th, tp), daemon=True).start()
main()
PYEOF
    chmod 755 "$HY_RELAY"
}
# reconcile the running per-port relays with pf.conf (client side only)
hy_reconcile_relays() {
    load_inst "$1"; local pf socksport="$PORT" changed=0; pf="$(inst_pf "$1")"
    local want=(); if [[ -s "$pf" ]]; then local pr po
        while IFS=: read -r pr po; do [[ "$pr" == tcp && -n "$po" ]] && want+=("$po"); done < "$pf"; fi
    hy_write_relay_script
    # stop relays whose port is no longer wanted
    local f base port u
    for f in /etc/systemd/system/omnitun-"$1"-pf-*.service; do
        [[ -e "$f" ]] || continue
        base="$(basename "$f")"; port="${base#"omnitun-$1-pf-"}"; port="${port%.service}"
        if ! printf '%s\n' "${want[@]:-}" | grep -qx "$port"; then
            systemctl disable --now "$base" >/dev/null 2>&1 || true; rm -f "$f"; changed=1
        fi
    done
    # write units for wanted ports
    for port in "${want[@]:-}"; do [[ -z "$port" ]] && continue
        u="$(hy_relay_unit "$1" "$port")"
        cat > "/etc/systemd/system/$u" <<EOF
[Unit]
Description=OmniTunnel hysteria forward $1 tcp/$port
After=network-online.target $(svc_name "$1")
Wants=$(svc_name "$1")

[Service]
Type=simple
ExecStart=/usr/bin/env python3 $HY_RELAY 0.0.0.0 $port 127.0.0.1 $socksport 127.0.0.1 $port
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
        changed=1
    done
    [[ "$changed" == 1 ]] && systemctl daemon-reload
    # start only the relays that are not already up (existing ones stay untouched)
    for port in "${want[@]:-}"; do [[ -z "$port" ]] && continue
        u="$(hy_relay_unit "$1" "$port")"
        systemctl enable "$u" >/dev/null 2>&1 || true
        systemctl is-active --quiet "$u" || systemctl start "$u" >/dev/null 2>&1 || true
    done
    return 0
}
# tear down all relays for an instance (used on remove)
hy_remove_relays() {
    local f base changed=0
    for f in /etc/systemd/system/omnitun-"$1"-pf-*.service; do
        [[ -e "$f" ]] || continue
        base="$(basename "$f")"; systemctl disable --now "$base" >/dev/null 2>&1 || true
        rm -f "$f"; changed=1
    done
    [[ "$changed" == 1 ]] && systemctl daemon-reload || true
    return 0
}
# apply pf.conf for a hysteria instance with the least possible disruption:
# rebuild the engine config and restart ONLY if it actually changed (i.e. a UDP
# forward was added/removed, or the python3-less TCP fallback is in play); TCP
# forwards are normally reconciled as standalone relays and never bounce engine.
hy_pf_reconcile() {
    load_inst "$1"
    local have_py=1; command -v python3 >/dev/null 2>&1 || have_py=0
    local d yaml tmp; d="$(inst_path "$1")"; yaml="$d/hy.yaml"; tmp="$d/hy.yaml.new"
    if [[ "$ROLE" != server && "$have_py" == 0 ]]; then
        warn "python3 not found: hysteria TCP forwards stay in-config (engine restarts on change)"
        HY_TCP_IN_CONFIG=1 hy_render_config "$1" "$tmp"
    else
        hy_render_config "$1" "$tmp"
    fi
    if ! cmp -s "$tmp" "$yaml" 2>/dev/null; then
        mv "$tmp" "$yaml"; chmod 600 "$yaml" 2>/dev/null || true
        inst_running "$1" && systemctl restart "$(svc_name "$1")" 2>/dev/null || true
    else rm -f "$tmp"; fi
    [[ "$ROLE" == server ]] && return 0
    [[ "$have_py" == 1 ]] && hy_reconcile_relays "$1"
    return 0
}

# ------------------------------------------------------------- tuning ---------
apply_tuning() {
    local dev="$1" shape="${2:-none}"
    ensure_forwarding "$dev"
    sysctl -w net.core.rmem_max=67108864 >/dev/null 2>&1 || true
    sysctl -w net.core.wmem_max=67108864 >/dev/null 2>&1 || true
    sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1 || true
    modprobe tcp_bbr 2>/dev/null || true
    sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1 || true
    local i; for i in $(seq 1 40); do ip link show "$dev" >/dev/null 2>&1 && break; sleep 0.25; done
    ensure_forwarding "$dev"
    ip link set "$dev" txqueuelen 1000 2>/dev/null || true
    if [[ "$shape" != none && -n "$shape" ]]; then
        tc qdisc replace dev "$dev" root tbf rate "$shape" burst 128kb latency 30ms 2>/dev/null || true
    else
        tc qdisc replace dev "$dev" root fq 2>/dev/null || true
    fi
    iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -o "$dev" -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
        iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -o "$dev" -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
    iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -i "$dev" -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
        iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -i "$dev" -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
}

# --------------------------------------------------- systemd unit + enable ----
write_service() {
    load_inst "$1"
    if type_is_hysteria "$TYPE"; then ensure_hysteria
    elif ! type_is_kernel "$TYPE"; then ensure_binary; fi
    local unit="/etc/systemd/system/$(svc_name "$1")"
    if type_is_hysteria "$TYPE"; then
        hy_write_config "$1"
        local mode=client; [[ "$ROLE" == server ]] && mode=server
        cat > "$unit" <<EOF
[Unit]
Description=OmniTunnel hysteria instance $1 ($ROLE $LOCAL_IP -> $PEER_IP)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$HYSTERIA_BIN $mode -c $(inst_path "$1")/hy.yaml
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    elif type_is_kernel "$TYPE"; then
        # native kernel carrier (gre / fou / vxlan): configured on start, removed
        # on stop. No compiled core binary involved. See kernel_up_cmd for how
        # PORT disambiguates several tunnels sharing one endpoint pair.
        cat > "$unit" <<EOF
[Unit]
Description=OmniTunnel $TYPE instance $1 ($ROLE $LOCAL_IP -> $PEER_IP)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=-$SCRIPT_PATH _prefwd
ExecStart=/bin/sh -c '$(kernel_up_cmd)'
ExecStartPost=$SCRIPT_PATH _postup $1
ExecStop=-/bin/sh -c '$(kernel_down_cmd)'
Restart=no

[Install]
WantedBy=multi-user.target
EOF
    else
        cat > "$unit" <<EOF
[Unit]
Description=OmniTunnel $TYPE instance $1 ($ROLE $LOCAL_IP -> $PEER_IP)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=-/sbin/ip link del $DEV
ExecStartPre=-$SCRIPT_PATH _prefwd
ExecStart=$(build_execstart)
ExecStartPost=$SCRIPT_PATH _postup $1
Restart=always
RestartSec=3
TimeoutStopSec=5

[Install]
WantedBy=multi-user.target
EOF
    fi
    systemctl daemon-reload || true
}
cmd_postup() { load_inst "$1"; apply_tuning "$DEV" "$SHAPE"; pf_apply_all "$1" || true; }
cmd_prefwd() { ensure_forwarding "" >/dev/null 2>&1 || true; return 0; }

# Restart an instance's port-forward relays. A tunnel restart silently kills the
# sockets a relay held open through the OLD tunnel; if the relay is not bounced,
# an upstream proxy (mf-proxy etc.) that kept a long-lived connection alive
# through the relay stays wedged on the dead socket and traffic degrades to
# "very slow" instead of erroring cleanly. Bouncing the relays forces fresh
# connections through the just-restarted tunnel.
restart_pf_relays() {
    local u
    for u in $(systemctl list-units "omnitun-$1-pf-*.service" --state=active --no-legend 2>/dev/null | awk '{print $1}'); do
        systemctl restart "$u" 2>/dev/null || true
    done
}
inst_enable() {
    need_root; load_inst "$1"; write_service "$1"
    systemctl enable "$(svc_name "$1")" >/dev/null 2>&1 || true
    # A failed unit start must NOT silently abort the whole (set -euo pipefail)
    # run - that reads as the tool "cancelling/disconnecting" with no message.
    # Warn and carry on; callers that care check inst_running afterwards.
    systemctl restart "$(svc_name "$1")" 2>/dev/null \
        || warn "service $(svc_name "$1") did not start cleanly - see: journalctl -u $(svc_name "$1")"
    sleep 2; inst_status "$1" || true
    restart_pf_relays "$1"   # drop stale relay connections to the old tunnel
}
inst_running() { systemctl is-active "$(svc_name "$1")" >/dev/null 2>&1; }
inst_header() {
    printf '  %b    %-12s%-12s%-25s%-8s%-5s%b\n' \
        "$C_BCYN" "NAME" "TYPE" "PEER" "RTT" "LOSS" "$C_RESET"
}
# one aligned row per instance:  ● name  type  peer:port  rtt  loss
#                                   └─ endpoint / proxy detail
# name white, type magenta, endpoint cyan; rtt/loss go yellow only when bad,
# and the dot is red for a dead tunnel. pass "full" as $2 for the └─ line.
inst_status() {
    load_inst "$1"
    local running=0; inst_running "$1" && running=1
    local dot col ncol="$C_BOLD$C_WHITE"
    if [[ $running == 1 ]]; then dot="$G_DOT_ON"; col="$C_BGRN"; else dot="$G_DOT_OFF"; col="$C_BRED"; fi
    local peer="$PEER_IP"; [[ -n "$PORT" && "$TYPE" != icmp ]] && peer="$PEER_IP:$PORT"
    local rtt="-" loss="-" rc="$C_WHITE" lc="$C_BGRN"
    if [[ $running == 1 ]]; then
        # what to ping: an L3 tunnel has its peer's tunnel IP; hysteria has no
        # tun device, so measure the path to the foreign box's public IP instead.
        local target=""
        if type_is_hysteria "$TYPE"; then target="$PEER_IP"
        elif ip link show "$DEV" >/dev/null 2>&1; then target="$PEER_ADDR"; fi
        if [[ -n "$target" ]]; then
            local out l r rn; out=$(ping -c2 -W2 "$target" 2>/dev/null || true)
            l=$(echo "$out" | grep -oE '[0-9]+% packet loss' | grep -oE '^[0-9]+' || true)
            r=$(echo "$out" | awk -F'/' '/rtt|round-trip/{print $5}' || true)
            if [[ -n "$r" ]]; then
                rn=$(awk -v x="$r" 'BEGIN{printf "%.0f", x}')
                rtt="${rn}ms"; [[ "$rn" -ge 150 ]] && rc="$C_BYEL"
                loss="${l:-0}%"; [[ -n "$l" && "$l" -gt 0 ]] && lc="$C_BYEL"
            fi
        fi
    fi
    printf '  %b%s%b   %b%-12s%b%b%-12s%b%b%-25s%b%b%-8s%b%b%-5s%b\n' \
        "$col" "$dot" "$C_RESET" "$ncol" "$1" "$C_RESET" \
        "$C_BMAG" "$TYPE" "$C_RESET" "$C_BCYN" "$peer" "$C_RESET" \
        "$rc" "$rtt" "$C_RESET" "$lc" "$loss" "$C_RESET"
    [[ "${2:-}" == full ]] && inst_detail "$1"
    return 0
}
# the └─ endpoint line under a tunnel's row. tun transports (gre/icmp/udp/tcp/
# mux/ws) have a real point-to-point tun interface, so both pingable IPs are
# listed. hysteria has NO L3 tun device - it moves traffic over a QUIC SOCKS5 +
# port-forwards - so its local access point is shown instead. a stopped tunnel
# shows how long ago it was last active.
inst_detail() {
    load_inst "$1"
    local running=0; inst_running "$1" && running=1
    if [[ $running == 0 ]]; then
        local ts es now d rel=""
        ts=$(systemctl show "$(svc_name "$1")" -p InactiveEnterTimestamp --value 2>/dev/null)
        es=$(date -d "$ts" +%s 2>/dev/null || echo "")
        if [[ -n "$es" && "$es" -gt 0 ]]; then now=$(date +%s); d=$((now-es))
            if   (( d<60 ));    then rel="just now"
            elif (( d<3600 ));  then rel="$((d/60))m ago"
            elif (( d<86400 )); then rel="$((d/3600))h ago"
            else                     rel="$((d/86400))d ago"; fi
        fi
        if [[ -n "$rel" ]]; then printf '     %b└─ stopped · last seen %s%b\n' "$C_GREY" "$rel" "$C_RESET"
        else printf '     %b└─ stopped%b\n' "$C_GREY" "$C_RESET"; fi
        return 0
    fi
    if type_is_hysteria "$TYPE"; then
        local nf; nf=$(grep -c . "$(inst_pf "$1")" 2>/dev/null) || nf=0
        printf '     %b└─ socks 127.0.0.1:%s · %s fwd · proxy mode (no L3 IP)%b\n' \
            "$C_GREY" "$PORT" "$nf" "$C_RESET"
    else
        local ir fo
        if [[ "$ROLE" == server ]]; then ir="$PEER_ADDR"; fo="$TUN_ADDR"; else ir="$TUN_ADDR"; fo="$PEER_ADDR"; fi
        printf '     %b└─ %s (iran) ⇄ %s (foreign) · pingable · %s · %s%b\n' \
            "$C_GREY" "$ir" "$fo" "$DEV" "$ROLE" "$C_RESET"
    fi
}

# ------------------------------------------------------------- port fwd -------
pf_apply_all() {
    load_inst "$1"
    # hysteria forwards ports outside iptables: TCP via per-port relays (no engine
    # restart), UDP in-config (restart only if the UDP set changed).
    if type_is_hysteria "$TYPE"; then
        hy_pf_reconcile "$1"
        return 0
    fi
    local pf; pf="$(inst_pf "$1")"; [[ -f "$pf" ]] || return 0
    local ch; ch="$(dnat_chain "$1")"
    iptables -t nat -N "$ch" 2>/dev/null || true; iptables -t nat -F "$ch"
    iptables -t nat -C PREROUTING -j "$ch" 2>/dev/null || iptables -t nat -I PREROUTING 1 -j "$ch"
    iptables -t nat -C POSTROUTING -o "$DEV" -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -o "$DEV" -j MASQUERADE
    local proto port
    while IFS=: read -r proto port; do [[ -z "$proto" ]] && continue
        iptables -t nat -A "$ch" -p "$proto" --dport "$port" -j DNAT --to-destination "$PEER_ADDR:$port"; done < "$pf"
}
pf_add() {
    need_root; load_inst "$1"; local proto="$2" ports="$3"
    [[ "$proto" =~ ^(tcp|udp|both)$ ]] || die "proto must be tcp|udp|both"
    # accept several ports at once, comma-separated: pf-add <inst> tcp 8080,8081,700
    local pf pr p np rc; pf="$(inst_pf "$1")"
    for p in ${ports//,/ }; do
        np="$(norm_port "$p")" || { warn "skipping invalid port '$p'"; continue; }
        [[ -e "$pf" ]] || : > "$pf"
        for pr in $([[ "$proto" == both ]] && echo "tcp udp" || echo "$proto"); do
            rc=0; grep -qx "$pr:$np" "$pf" 2>/dev/null || rc=$?
            [[ "$rc" -le 1 ]] || die "could not read $pf (grep exit $rc) - nothing added"
            [[ "$rc" -eq 0 ]] || echo "$pr:$np" >> "$pf"; done
    done
    pf_apply_all "$1"; ok "forwarding $proto/$ports through '$1' to $PEER_ADDR"
}
pf_del() {
    need_root; load_inst "$1"; local ports="$2" pf p np; pf="$(inst_pf "$1")"
    # accept several ports at once, comma-separated: pf-del <inst> 8080,8081
    if [[ -f "$pf" ]]; then
        for p in ${ports//,/ }; do
            np="$(norm_port "$p")" || { warn "skipping invalid port '$p'"; continue; }
            rewrite_without "$pf" ":0*$np\$" || die "could not rewrite $pf - nothing removed"
        done
    fi
    pf_apply_all "$1"; ok "removed forward(s) on port(s) $ports from '$1'"
}
pf_flush_chain() {
    load_inst "$1" 2>/dev/null || return 0; local ch; ch="$(dnat_chain "$1")"
    iptables -t nat -D PREROUTING -j "$ch" 2>/dev/null || true
    iptables -t nat -F "$ch" 2>/dev/null || true; iptables -t nat -X "$ch" 2>/dev/null || true
    iptables -t nat -D POSTROUTING -o "$DEV" -j MASQUERADE 2>/dev/null || true
}

# ------------------------------------------------------------- mux (chisel) ---
# A "muxed" forward funnels ALL of a relay's user connections for a public port
# into ONE persistent flow (a chisel reverse tunnel) over the instance's tun link,
# then out to a destination reachable from the foreign. Why: a policed/lossy
# relay->foreign path shreds many parallel connections on upload (they collapse to
# a few Mbit) but carries a single sustained flow fast+stable (near line-rate), so
# collapsing everything into one flow recovers the full rate. The RELAY (this box)
# runs the chisel SERVER bound to its OWN tun IP (reachable only over the tunnel,
# never public); the FOREIGN runs the chisel CLIENT that opens one reverse listener
# per mapping ON THE RELAY and forwards each to its <dest>. All forwards on an
# instance share one server + one client = one flow.
mux_conf() { echo "$INST_DIR/$1/mux.conf"; }        # lines: <pub_port>:<dest_host>:<dest_port>
mux_svc()  { echo "omnitun-$1-mux.service"; }
# deterministic control port from the instance subnet (10.201.<X>.y -> 9000+X);
# bound to the tun IP so it is reachable only through the tunnel, never publicly.
mux_ctrl_port() { load_inst "$1"; local x; x=$(echo "$TUN_ADDR" | grep -oE '10\.201\.[0-9]+' | grep -oE '[0-9]+$' || true); [[ "$x" =~ ^[0-9]+$ ]] || x=0; echo $(( 9000 + x )); }
# base64 token carrying the relay tun IP + ctrl port + the full mapping set, for
# the no-SSH path (paste on the foreign). Rebuilt from mux.conf each call.
mux_token() {
    load_inst "$1"; local ctrl; ctrl="$(mux_ctrl_port "$1")"
    { printf 'MUX1|%s|%s|%s\n' "$1" "$TUN_ADDR" "$ctrl"; cat "$(mux_conf "$1")" 2>/dev/null; } | base64 | tr -d '\n'
}
# (re)write + (re)start the relay-side chisel SERVER for an instance; bounce it
# only when its command actually changed (mappings live on the client, so adding
# one never bounces the server). Torn down when no mappings remain.
mux_relay_reconcile() {
    load_inst "$1"; local mc u; mc="$(mux_conf "$1")"; u="$(mux_svc "$1")"
    if [[ ! -s "$mc" ]]; then
        systemctl disable --now "$u" >/dev/null 2>&1 || true
        rm -f "/etc/systemd/system/$u"; systemctl reset-failed "$u" 2>/dev/null || true
        systemctl daemon-reload 2>/dev/null || true; return 0
    fi
    ensure_chisel
    local ctrl; ctrl="$(mux_ctrl_port "$1")"
    local new="/etc/systemd/system/$u.new"
    cat > "$new" <<EOF
[Unit]
Description=OmniTunnel chisel mux server $1 (relay)
After=network-online.target $(svc_name "$1")
Wants=$(svc_name "$1")

[Service]
Type=simple
ExecStart=$CHISEL_BIN server --reverse --host $TUN_ADDR --port $ctrl
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    if ! cmp -s "$new" "/etc/systemd/system/$u" 2>/dev/null; then
        mv "$new" "/etc/systemd/system/$u"; systemctl daemon-reload
        systemctl enable "$u" >/dev/null 2>&1 || true
        systemctl restart "$u" >/dev/null 2>&1 || true
    else
        rm -f "$new"
        systemctl is-active --quiet "$u" || { systemctl enable "$u" >/dev/null 2>&1 || true; systemctl start "$u" >/dev/null 2>&1 || true; }
    fi
    return 0
}
# foreign side: (re)write + (re)start the chisel CLIENT dialing the relay tun IP,
# one reverse listener per mapping forwarding to its <dest>. Rebuilt wholesale from
# the mapping set (idempotent).
mux_client_apply() {
    local inst="$1" relay_ip="$2" ctrl="$3"; shift 3
    ensure_chisel
    local args=() m ph dh dp
    for m in "$@"; do
        IFS=: read -r ph dh dp <<< "$m"
        [[ "$ph" =~ ^[0-9]+$ && -n "$dh" && "$dp" =~ ^[0-9]+$ ]] || continue
        args+=("R:0.0.0.0:$ph:$dh:$dp")
    done
    [[ ${#args[@]} -gt 0 ]] || die "no valid mux mappings"
    local u; u="$(mux_svc "$inst")"
    cat > "/etc/systemd/system/$u" <<EOF
[Unit]
Description=OmniTunnel chisel mux client $inst (foreign)
After=network-online.target $(svc_name "$inst")
Wants=$(svc_name "$inst")

[Service]
Type=simple
ExecStart=$CHISEL_BIN client --keepalive 25s http://$relay_ip:$ctrl ${args[*]}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload; systemctl enable "$u" >/dev/null 2>&1 || true
    systemctl restart "$u" >/dev/null 2>&1 || true
}
# tear down the mux service (either side) for an instance
mux_remove() {
    local u; u="$(mux_svc "$1")"
    [[ -e "/etc/systemd/system/$u" ]] || return 0
    systemctl disable --now "$u" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/$u"; systemctl reset-failed "$u" 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true
}
# push the current mapping set to the foreign: auto over SSH if we can log in,
# else print the token to paste there.
_mux_push_foreign() {
    local inst="$1" fhost="$2" tok; tok="$(mux_token "$inst")"
    _peer_creds "$fhost"
    if [[ -n "${PEER_PASS:-}" ]] && peer_ssh "$fhost" true >/dev/null 2>&1; then
        if peer_ssh "$fhost" "OMNITUN_ASSETS=/opt/omnitunnel /opt/omnitunnel/omnitunnel.sh mux-token $tok" >/dev/null 2>&1; then
            ok "foreign ($fhost) mux client updated automatically"; return 0
        fi
        warn "auto-config over SSH failed - finish it on the foreign by hand:"
    fi
    echo "${C_BOLD}Run this on the FOREIGN ($fhost) to (re)apply the mux:${C_RESET}"
    echo "  ${C_CYAN}omnitunnel mux-token $tok${C_RESET}"
}
# mux-add <inst> <public_port> <dest_host> <dest_port>
cmd_mux_add() {
    need_root; local inst="$1" pub="$2" dh="$3" dp="$4"
    inst_exists "$inst" || die "no such instance: $inst"
    pub="$(norm_port "$pub")" || die "public port must be 1-65535"
    dp="$(norm_port "$dp")" || die "destination port must be 1-65535"
    [[ -n "$dh" ]] || die "usage: mux-add <inst> <public_port> <dest_host> <dest_port>"
    load_inst "$inst"
    [[ "$ROLE" == server ]] && die "run mux-add on the RELAY (client) side of '$inst', not the foreign"
    local mc t rc; mc="$(mux_conf "$inst")"
    [[ ! -e "$mc" || -f "$mc" ]] || die "$mc is not a regular file"
    t="$(mktemp "$mc.XXXXXX" 2>/dev/null)" || die "cannot create a temp file next to $mc"
    rc=0
    if [[ -f "$mc" ]]; then grep -v "^0*$pub:" "$mc" > "$t" 2>/dev/null || rc=$?; fi
    [[ "$rc" -le 1 ]] || { rm -f "$t"; die "could not read $mc (grep exit $rc) - nothing changed"; }
    printf '%s:%s:%s\n' "$pub" "$dh" "$dp" >> "$t" || { rm -f "$t"; die "could not write $t - nothing changed"; }
    mv "$t" "$mc" || { rm -f "$t"; die "could not replace $mc - nothing changed"; }
    mux_relay_reconcile "$inst"
    ok "relay: public $pub muxed over '$inst' -> foreign $dh:$dp (one flow)"
    _mux_push_foreign "$inst" "$PEER_IP"
}
# mux-del <inst> <public_port>
cmd_mux_del() {
    need_root; local inst="$1" pub="$2"
    inst_exists "$inst" || die "no such instance: $inst"
    pub="$(norm_port "$pub")" || die "usage: mux-del <inst> <public_port>"
    load_inst "$inst"
    local mc; mc="$(mux_conf "$inst")"
    rewrite_without "$mc" "^0*$pub:" || die "could not rewrite $mc - nothing removed"
    mux_relay_reconcile "$inst"
    ok "removed muxed forward $pub from '$inst'"
    if [[ -s "$mc" ]]; then _mux_push_foreign "$inst" "$PEER_IP"
    else
        _peer_creds "$PEER_IP"
        if [[ -n "${PEER_PASS:-}" ]] && peer_ssh "$PEER_IP" true >/dev/null 2>&1; then
            peer_ssh "$PEER_IP" "OMNITUN_ASSETS=/opt/omnitunnel /opt/omnitunnel/omnitunnel.sh mux-off '$inst'" >/dev/null 2>&1 || true
        else echo "  No mappings left. On the FOREIGN run: ${C_CYAN}omnitunnel mux-off $inst${C_RESET}"; fi
    fi
}
# mux-token <token>   (run on the FOREIGN) — bring up / refresh the chisel mux client
cmd_mux_token() {
    need_root
    local dec; dec=$(printf '%s' "$1" | base64 -d 2>/dev/null) || die "invalid mux token"
    local head; head=$(printf '%s\n' "$dec" | head -1)
    case "$head" in MUX1\|*) :;; *) die "invalid mux token";; esac
    local _tag inst relay_ip ctrl; IFS='|' read -r _tag inst relay_ip ctrl <<< "$head"
    [[ -n "$inst" && -n "$relay_ip" && -n "$ctrl" ]] || die "invalid mux token"
    local maps=() ln
    while IFS= read -r ln; do case "$ln" in MUX1\|*|'') :;; *) maps+=("$ln");; esac; done <<< "$dec"
    [[ ${#maps[@]} -gt 0 ]] || die "mux token has no forwards"
    mkdir -p "$INST_DIR/$inst"; printf '%s\n' "${maps[@]}" > "$(mux_conf "$inst")"
    mux_client_apply "$inst" "$relay_ip" "$ctrl" "${maps[@]}"
    ok "foreign mux client for '$inst' up: $relay_ip:$ctrl  (${#maps[@]} forward(s))"
}
# mux-off <inst>   (foreign) — remove the mux client for an instance
cmd_mux_off() { need_root; mux_remove "$1"; rm -f "$(mux_conf "$1")" 2>/dev/null || true; ok "mux client for '$1' removed"; }

# --------------------------------------------------------------- remove -------
# Removes ONLY the named instance this tool created. Never touches /etc/icmptun
# or any interface / unit it did not create.
inst_remove() {
    need_root; inst_exists "$1" || { warn "no such instance: $1"; return 0; }
    load_inst "$1"
    type_is_hysteria "$TYPE" && hy_remove_relays "$1"
    mux_remove "$1"   # tear down any chisel mux server/client for this instance
    systemctl disable --now "$(svc_name "$1")" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/$(svc_name "$1")"
    systemctl reset-failed "$(svc_name "$1")" 2>/dev/null || true   # no lingering 'not-found failed' ghost
    systemctl daemon-reload 2>/dev/null || true
    pf_flush_chain "$1"; ip link del "$DEV" 2>/dev/null || true
    rm -rf "$(inst_path "$1")"; ok "removed instance '$1'"
}

# User-facing removal. For a CLIENT tunnel it removes the FAR (foreign) side FIRST
# - actively verifying the foreign no longer has the instance, retrying until it
# does - and only then removes the local side. If the foreign can't be confirmed
# gone, the LOCAL side is kept (so nothing/no info is lost) and it stops with a
# clear message, so a tunnel is never half-deleted with an orphan left abroad.
# 'inst_remove' stays local-only (it is exactly what the foreign runs via _remove).
remove_instance_fully() {
    need_root; local n="$1"
    inst_exists "$n" || { warn "no such instance: $n"; return 0; }
    load_inst "$n"
    # A server-side instance IS the foreign end; just remove it here.
    [[ "$ROLE" == server ]] && { inst_remove "$n"; return 0; }
    local fhost="$PEER_IP"
    [[ -z "$fhost" ]] && { inst_remove "$n"; return 0; }
    # Do we have a way to reach the foreign to delete its side?
    _peer_creds "$fhost"
    local have_login=0
    [[ -n "$PEER_PASS" ]] && have_login=1
    [[ "$have_login" == 0 ]] && ls "$HOME"/.ssh/id_* >/dev/null 2>&1 && have_login=1 || true
    if [[ "$have_login" == 0 ]]; then
        warn "No SSH login saved for the foreign $fhost (this tunnel was set up in MANUAL mode)."
        warn "Remove its side on the foreign yourself:  ${C_CYAN}omnitunnel remove${C_RESET}  (numbered menu item there)."
        local yn; read -rp "  Remove ONLY the local side now, leaving the foreign as-is? [y/N]: " yn || true
        [[ "$yn" =~ ^[Yy] ]] && inst_remove "$n" || info "nothing removed."
        return 0
    fi
    info "Removing the far side on $fhost and verifying it is gone..."
    local i vr gone=0
    # A failing SSH (unreachable / wrong creds) returns non-zero; relax 'set -e'
    # so the loop actually RETRIES instead of aborting on the first failure.
    set +e
    for i in 1 2 3 4 5 6; do
        peer_ssh "$fhost" "OMNITUN_ASSETS=/opt/omnitunnel /opt/omnitunnel/omnitunnel.sh _remove '$n'" >/dev/null 2>&1
        vr=$(peer_ssh "$fhost" "test -e /etc/omnitunnel/inst/'$n'/instance.conf && echo OMNIV_EXISTS || echo OMNIV_GONE" 2>/dev/null)
        case "$vr" in
            *OMNIV_GONE*)   gone=1; break;;
            *OMNIV_EXISTS*) warn "  far side still present (attempt $i/6) - retrying...";;
            *)              warn "  could not reach $fhost to verify (attempt $i/6) - retrying...";;
        esac
        sleep 4
    done
    set -e
    if [[ "$gone" != 1 ]]; then
        warn "Could NOT confirm the far side on $fhost was removed after 6 attempts."
        warn "Keeping the LOCAL tunnel so nothing is lost. Fix the foreign's reachability (SSH / port 22)"
        warn "and run remove again, or delete it on the foreign by hand:  ${C_CYAN}omnitunnel remove${C_RESET}"
        return 1
    fi
    ok "far side on $fhost confirmed removed."
    inst_remove "$n"
    return 0
}

# allocation helpers (non-overlapping subnet + free udp/tcp port per box)
next_subnet_idx() {
    local i=0 n used
    for n in $(list_instances); do
        used=$(grep -oE 'TUN_ADDR=10\.201\.[0-9]+' "$(inst_conf "$n")" 2>/dev/null | grep -oE '[0-9]+$' || true)
        [[ -n "$used" && "$used" -ge "$i" ]] && i=$((used+1)); done
    echo "$i"
}
next_port() {
    local cand="${1:-51820}" used
    used=$(grep -hoE 'PORT=[0-9]+' "$INST_DIR"/*/instance.conf 2>/dev/null | grep -oE '[0-9]+' || true)
    while echo "$used" | grep -qx "$cand"; do cand=$((cand+1)); done; echo "$cand"
}
# Collision-safe allocation across BOTH this box and the foreign: two different
# Iran boxes tunnelling to the SAME foreign must never pick the same 10.201.<n>
# subnet or the same port/GRE-key, or the second one tears the first one down.
# $1 = space-separated indices/ports already in use ON THE FOREIGN.
alloc_subnet() {
    local avoid=" ${1:-} " i n u localused=" "
    for n in $(list_instances); do
        u=$(grep -oE 'TUN_ADDR=10\.201\.[0-9]+' "$(inst_conf "$n")" 2>/dev/null | grep -oE '[0-9]+$' || true)
        [[ -n "$u" ]] && localused+="$u "
    done
    for ((i=0; i<250; i++)); do
        [[ "$localused" == *" $i "* ]] && continue
        [[ "$avoid"     == *" $i "* ]] && continue
        echo "$i"; return
    done
    echo 0
}
alloc_port() {
    local cand="${1:-51820}" avoid=" ${2:-} " localused
    localused=" $(grep -hoE 'PORT=[0-9]+' "$INST_DIR"/*/instance.conf 2>/dev/null | grep -oE '[0-9]+' | tr '\n' ' ') "
    while [[ "$localused" == *" $cand "* || "$avoid" == *" $cand "* ]]; do cand=$((cand+1)); done
    echo "$cand"
}

# ------------------------------------------------------------ peer SSH --------
peer_conf() { echo "$PEER_DIR/$1.conf"; }
# Peer creds are stored base64-encoded and read back by a plain parser (never
# 'source'd) - so a password with shell-special characters ($ # & ; ` ( ) space
# quotes ...) is preserved exactly instead of being mangled (or worse, executed).
save_peer() {
    mkdir -p "$PEER_DIR"; chmod 700 "$PEER_DIR"
    { printf 'PEER_USER=%s\n' "$(printf '%s' "$2" | base64 | tr -d '\n')"
      printf 'PEER_PASS=%s\n' "$(printf '%s' "$3" | base64 | tr -d '\n')"
      [[ -n "${4:-}" ]] && printf 'PEER_PROXY=%s\n' "$(printf '%s' "$4" | base64 | tr -d '\n')"
    } > "$(peer_conf "$1")"
    chmod 600 "$(peer_conf "$1")"
}
_peer_creds() {
    PEER_USER=root; PEER_PASS=""; PEER_PROXY=""
    local f line k v; f="$(peer_conf "$1")"; [[ -f "$f" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == *=* ]] || continue
        k="${line%%=*}"; v="$(printf '%s' "${line#*=}" | base64 -d 2>/dev/null)"
        case "$k" in PEER_USER) PEER_USER="$v";; PEER_PASS) PEER_PASS="$v";; PEER_PROXY) PEER_PROXY="$v";; esac
    done < "$f"
    [[ -n "$PEER_USER" ]] || PEER_USER=root
    return 0
}
# Provisioning SSH: don't let a stale/changed host key block automation
# (servers get reinstalled and their keys rotate). We authenticate with a
# password or an ssh key, not TOFU. An optional saved SOCKS5 proxy routes the
# provisioning SSH/SCP around an ISP that blocks the foreign box's port 22 -
# this only affects the outbound connection we make, never any server's sshd.
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=15 -o ServerAliveInterval=10 -o ServerAliveCountMax=3)
_proxy_opts() { PROXY_OPTS=(); [[ -n "${PEER_PROXY:-}" ]] || return 0
    # Route ONLY the control SSH/SCP to the foreign through a SOCKS5 proxy (for
    # DPI-blocked Iran<->foreign paths). The tunnel data never touches the proxy.
    # OpenBSD nc uses '-X 5 -x host:port'; nmap's ncat uses '--proxy-type socks5'.
    if nc -h 2>&1 | grep -q -- '-X'; then
        PROXY_OPTS=(-o "ProxyCommand=nc -X 5 -x $PEER_PROXY %h %p")
    elif command -v ncat >/dev/null 2>&1; then
        PROXY_OPTS=(-o "ProxyCommand=ncat --proxy $PEER_PROXY --proxy-type socks5 %h %p")
    else
        PROXY_OPTS=(-o "ProxyCommand=nc -X 5 -x $PEER_PROXY %h %p")
    fi
    return 0; }
peer_ssh() { local h="$1"; shift; _peer_creds "$h"; _proxy_opts
    if [[ -n "$PEER_PASS" ]] && command -v sshpass >/dev/null; then
        sshpass -p "$PEER_PASS" ssh "${SSH_OPTS[@]}" ${PROXY_OPTS[@]+"${PROXY_OPTS[@]}"} "$PEER_USER@$h" "$@"
    else ssh "${SSH_OPTS[@]}" ${PROXY_OPTS[@]+"${PROXY_OPTS[@]}"} "$PEER_USER@$h" "$@"; fi
}
peer_scp() { local h="$1" s="$2" d="$3"; _peer_creds "$h"; _proxy_opts
    if [[ -n "$PEER_PASS" ]] && command -v sshpass >/dev/null; then
        sshpass -p "$PEER_PASS" scp "${SSH_OPTS[@]}" ${PROXY_OPTS[@]+"${PROXY_OPTS[@]}"} "$s" "$PEER_USER@$h:$d"
    else scp "${SSH_OPTS[@]}" ${PROXY_OPTS[@]+"${PROXY_OPTS[@]}"} "$s" "$PEER_USER@$h:$d"; fi
}

# dotted-version compare: succeeds (0) only if $1 is strictly newer than $2
ver_gt() { [[ "$1" != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" == "$1" ]]; }

# add/bench push THIS box's manager+binary onto the foreign, overwriting whatever
# is there (no version check - keeps provisioning simple). The one hazard is
# DOWNGRADING a foreign that happens to be newer than us. So before provisioning,
# peek at the foreign's version: if it is newer, self-update this box first and
# re-run, so both ends land on the latest build instead of the foreign being
# knocked back to our older one. Runs once per invocation (OMNI_SELFUPDATED).
guard_peer_downgrade() {
    [[ -n "${OMNI_SELFUPDATED:-}" ]] && return 0
    local h="$1" pver=""
    # NB: the '|| true' is essential. Under 'set -euo pipefail', if the foreign
    # has no manager yet (the normal first-time case) the remote grep exits
    # non-zero, pipefail propagates it to the assignment, and set -e would abort
    # the WHOLE add/bench silently right after the "This box public IP" prompt.
    pver=$(peer_ssh "$h" "grep -m1 -oE 'VERSION=\"[0-9.]+\"' /opt/omnitunnel/omnitunnel.sh 2>/dev/null | grep -oE '[0-9.]+'" 2>/dev/null | tr -d '\r\n ') || true
    [[ -n "$pver" ]] || return 0                 # foreign has no OmniTunnel yet - just provision it
    ver_gt "$pver" "$VERSION" || return 0         # we are same-or-newer: safe to push
    warn "The foreign $h runs v$pver but this box is older (v$VERSION)."
    warn "Updating this box first so the tunnel/benchmark can't downgrade the foreign..."
    if cmd_update; then
        ok "Updated to the latest - re-running..."
        OMNI_SELFUPDATED=1 exec "$SCRIPT_PATH" ${OMNI_ARGV[@]+"${OMNI_ARGV[@]}"}
    fi
    die "self-update failed - run 'omnitunnel update' on this box and retry, so the newer foreign ($h v$pver) isn't downgraded."
}

# push the manager + the peer's own-arch binary, then bring up the server side
provision_peer() {
    local h="$1" name="$2" t="$3" plip="$4" prip="$5" port="$6" key="$7" pta="$8" ppa="$9" shape="${10}" nc="${11}" imode="${12:-}"
    local parch; parch=$(peer_ssh "$h" "uname -m" 2>/dev/null | tr -d '\r')
    case "$parch" in x86_64|amd64) parch=amd64;; aarch64|arm64) parch=arm64;; *) die "peer $h has unsupported CPU: $parch";; esac
    info "  far side is $parch; deploying engine + manager to $h ..."
    peer_ssh "$h" "mkdir -p /opt/omnitunnel/bin"
    peer_scp "$h" "$SCRIPT_PATH" "/opt/omnitunnel/omnitunnel.sh"
    peer_ssh "$h" "chmod +x /opt/omnitunnel/omnitunnel.sh"
    if type_is_hysteria "$t"; then
        local hbin; hbin="$(hy_local_bin "$parch" || true)"
        [[ -n "$hbin" ]] || die "no hysteria-$parch binary to send to peer"
        peer_scp "$h" "$hbin" "/opt/omnitunnel/bin/hysteria-$parch"
        peer_ssh "$h" "chmod +x /opt/omnitunnel/bin/hysteria-$parch; install -m0755 /opt/omnitunnel/bin/hysteria-$parch /usr/local/bin/hysteria"
    else
        local pbin=""
        for d in "$ASSET_DIR/bin" "$SCRIPT_DIR/bin"; do [[ -f "$d/omnitun-$parch" ]] && pbin="$d/omnitun-$parch" && break; done
        [[ -n "$pbin" ]] || die "no omnitun-$parch binary to send to peer"
        peer_scp "$h" "$pbin" "/opt/omnitunnel/bin/omnitun-$parch"
        peer_ssh "$h" "chmod +x /opt/omnitunnel/bin/omnitun-$parch; install -m0755 /opt/omnitunnel/bin/omnitun-$parch /usr/local/bin/omnitun"
    fi
    peer_ssh "$h" "OMNITUN_ASSETS=/opt/omnitunnel /opt/omnitunnel/omnitunnel.sh _peercreate '$name' '$t' server '$plip' '$prip' '$port' '$key' '$pta' '$ppa' '$shape' '$nc' '$imode'"
}
cmd_peercreate() {
    need_root
    if type_is_hysteria "$2"; then ensure_hysteria
    elif ! type_is_kernel "$2"; then ensure_binary; fi
    create_inst "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" "${11}" "${12:-}"
    inst_enable "$1" >/dev/null 2>&1 || true; ok "peer instance '$1' up"
}

# Non-interactive add for scripting/automation.
# add-auto <type> <name> <foreign_ip> [nconn] [shape] [my_ip]
# Far-side SSH password comes from a saved peer file or $OMNITUN_PEER_PASS
# (+ optional $OMNITUN_PEER_USER, default root).
cmd_add_auto() {
    need_root; ensure_binary
    local t="$1" kn="$2" fhost="$3" nc="${4:-16}" shape="${5:-none}" mylip="${6:-$(default_local_ip)}"
    [[ -n "$t" && -n "$kn" && -n "$fhost" ]] || die "usage: add-auto <type> <name> <foreign_ip> [nconn] [shape] [my_ip]"
    inst_exists "$kn" && die "instance $kn exists"
    [[ -n "${OMNITUN_PEER_PASS:-}" || -n "${OMNITUN_PEER_PROXY:-}" ]] && save_peer "$fhost" "${OMNITUN_PEER_USER:-root}" "${OMNITUN_PEER_PASS:-}" "${OMNITUN_PEER_PROXY:-}"
    guard_peer_downgrade "$fhost"
    # Ask the foreign what it already runs, so a second Iran box to the SAME foreign
    # gets its own subnet/port/key (and doesn't reuse a name) instead of clobbering
    # the first box's tunnel.
    local fsub fport fnames
    fsub=$(peer_ssh "$fhost" "grep -hoE 'TUN_ADDR=10\\.201\\.[0-9]+' /etc/omnitunnel/inst/*/instance.conf 2>/dev/null | grep -oE '[0-9]+\$'" 2>/dev/null | tr '\r\n' '  ' || true)
    fport=$(peer_ssh "$fhost" "grep -hoE 'PORT=[0-9]+' /etc/omnitunnel/inst/*/instance.conf 2>/dev/null | grep -oE '[0-9]+'" 2>/dev/null | tr '\r\n' '  ' || true)
    fnames=$(peer_ssh "$fhost" "ls /etc/omnitunnel/inst 2>/dev/null" 2>/dev/null | tr '\r\n' '  ' || true)
    case " $fnames " in *" $kn "*) die "the foreign $fhost already has an instance named '$kn' - choose a different name (each tunnel to a foreign needs a unique name)";; esac
    local sub port key ta pa; sub=$(alloc_subnet "$fsub"); ta="10.201.$sub.1"; pa="10.201.$sub.2"
    port=$(alloc_port "$(( $(port_base "$t") + sub ))" "$fport"); key=$(gen_key); type_uses_key "$t" || key=""
    local imode="${OMNITUN_ICMP_MODE:-}" pmode="${OMNITUN_ICMP_MODE_PEER:-}"
    local m; for m in "$imode" "$pmode"; do [[ -z "$m" || "$m" == reply || "$m" == request ]] || die "icmp mode must be reply|request (got '$m')"; done
    [[ "$t" == icmp ]] || type_is_revmux "$t" || { imode=""; pmode=""; }
    if type_is_revmux "$t" && [[ "$imode" == request || "$pmode" == request ]]; then
        warn "reverse-mux asked to emit echo-request; that gives up its reply-gated dodge"
    fi
    provision_peer "$fhost" "$kn" "$t" "$fhost" "$mylip" "$port" "$key" "$pa" "$ta" "$shape" "$nc" "$pmode"
    create_inst "$kn" "$t" client "$mylip" "$fhost" "$port" "$key" "$ta" "$pa" "$shape" "$nc" "$imode"
    inst_enable "$kn"; ok "instance '$kn' ($t) up: $mylip -> $fhost  (subnet 10.201.$sub.0/24, port/key $port)"
}

# ---------------------------------------------------------- MANUAL mode --------
# For hostile ISPs where the near box cannot reach the foreign box's SSH at all
# (e.g. port 22 blocked). NO SSH between the boxes is used: this brings up the
# near (client) side and prints a single token to paste on the foreign box.
# It never touches any server's own sshd or port 22.
# add-manual <type> <name> <foreign_ip> [nconn] [shape] [my_ip]
cmd_add_manual() {
    need_root
    if type_is_hysteria "$1"; then ensure_hysteria
    elif ! type_is_kernel "$1"; then ensure_binary; fi
    local t="$1" kn="$2" fhost="$3" nc="${4:-16}" shape="${5:-none}" mylip="${6:-$(default_local_ip)}" want_port="${7:-}"
    [[ -n "$t" && -n "$kn" && -n "$fhost" ]] || die "usage: add-manual <type> <name> <foreign_ip> [nconn] [shape] [my_ip] [foreign_port]"
    inst_exists "$kn" && die "instance $kn exists"
    local sub port key ta pa; sub=$(next_subnet_idx); ta="10.201.$sub.1"; pa="10.201.$sub.2"
    port=$(next_port "${want_port:-$(( $(port_base "$t") + sub ))}"); key=$(gen_key); type_uses_key "$t" || key=""
    # icmp: this end's emitted ICMP type (OMNITUN_ICMP_MODE) and the foreign end's
    # (OMNITUN_ICMP_MODE_PEER), for paths that drop one echo type in one direction.
    local imode="${OMNITUN_ICMP_MODE:-}" pmode="${OMNITUN_ICMP_MODE_PEER:-}"
    local m; for m in "$imode" "$pmode"; do [[ -z "$m" || "$m" == reply || "$m" == request ]] || die "icmp mode must be reply|request (got '$m')"; done
    [[ "$t" == icmp ]] || type_is_revmux "$t" || { imode=""; pmode=""; }
    if type_is_revmux "$t" && [[ "$imode" == request || "$pmode" == request ]]; then
        warn "reverse-mux asked to emit echo-request; that gives up its reply-gated dodge"
    fi
    create_inst "$kn" "$t" client "$mylip" "$fhost" "$port" "$key" "$ta" "$pa" "$shape" "$nc" "$imode"
    inst_enable "$kn"
    # Server-side params (tun IPs swapped). Encoded so it is a single paste.
    local token; token=$(printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s' "$kn" "$t" "$fhost" "$mylip" "$port" "$key" "$pa" "$ta" "$shape" "$nc" "$pmode" | base64 | tr -d '\n')
    echo
    echo "${C_GREEN}${C_BOLD}Near (Iran) side '$kn' is up.${C_RESET}"
    echo "${C_BOLD}Now run these TWO lines on the FOREIGN server ($fhost):${C_RESET}"
    echo
    echo "  ${C_CYAN}bash <(curl -fsSL $RAW_BASE/install.sh)${C_RESET}"
    echo "  ${C_CYAN}omnitunnel server-token $token${C_RESET}"
    echo
    echo "${C_DIM}No SSH is used between the servers, and nothing changes any server's"
    echo "own SSH login or port 22. The tunnel uses its own port ($port).${C_RESET}"
}
# Consume a token on the foreign box to bring up the matching server side.
cmd_server_token() {
    need_root
    local dec; dec=$(printf '%s' "$1" | base64 -d 2>/dev/null) || die "invalid token"
    local name t fhost mylip port key pta ppa shape nc pmode
    IFS='|' read -r name t fhost mylip port key pta ppa shape nc pmode <<< "$dec"
    [[ -n "$name" && -n "$t" ]] || die "invalid token"
    if type_is_hysteria "$t"; then ensure_hysteria
    elif ! type_is_kernel "$t"; then ensure_binary; fi
    # Re-running the SAME token must be idempotent. A first attempt that half-
    # failed (or was Ctrl-C'd) leaves the instance dir behind and this used to
    # die "already exists" on every retry - so the foreign could never be set up.
    # Replace it, then verify the unit actually came up and roll back if it did
    # not, so the token stays retryable.
    inst_exists "$name" && { warn "instance '$name' already exists - replacing it"; inst_remove "$name" >/dev/null 2>&1 || true; }
    create_inst "$name" "$t" server "$fhost" "$mylip" "$port" "$key" "$pta" "$ppa" "$shape" "$nc" "$pmode"
    inst_enable "$name"
    if ! inst_running "$name"; then
        inst_remove "$name" >/dev/null 2>&1 || true
        die "server side '$name' failed to start (cleaned up - fix the cause and re-run the token). check: journalctl -u $(svc_name "$name")"
    fi
    ok "foreign (server) side '$name' is up: $fhost <- $mylip"
}

# ------------------------------------------------------------ add wizard ------
wizard_add() {
    need_root; ensure_binary
    echo; echo "${C_BOLD}Add a tunnel  (this box = near side / client; far = foreign / server)${C_RESET}"
    local ci=1 types=() t ch x fhost fu fp fpx kn
    for t in $ALL_TYPES; do printf "  %2d) %-12s %s\n" "$ci" "$t" "$(type_desc "$t")"; types+=("$t"); ci=$((ci+1)); done
    read -erp "Tunnel type [1]: " ch; ch="${ch:-1}"
    ch="$(pick_num "$ch" "${#types[@]}")" || { warn "pick a number between 1 and ${#types[@]}"; return; }
    t="${types[$((ch-1))]}"
    local mylip; mylip="$(default_local_ip)"
    read -erp "This box public IP [$mylip]: " x; mylip="${x:-$mylip}"
    read -erp "Far (foreign) server IP: " fhost; [[ -z "$fhost" ]] && { warn "need a foreign IP"; return; }
    read -erp "Far SSH user [root]: " fu; fu="${fu:-root}"
    read -rsp "Far SSH password (blank = ssh key): " fp; echo
    read -erp "SOCKS5 proxy to reach the foreign, if the direct path is DPI-blocked (host:port, blank = direct): " fpx; fpx="${fpx:-${OMNITUN_PEER_PROXY:-}}"
    { [[ -n "$fp" || -n "$fpx" ]]; } && save_peer "$fhost" "$fu" "$fp" "$fpx"
    guard_peer_downgrade "$fhost"
    read -erp "Instance name [main]: " kn; kn="${kn:-main}"; inst_exists "$kn" && { warn "instance exists"; return; }
    local nc=16 shape=none
    if [[ "$t" == mux ]]; then
        read -erp "Parallel links N [16]: " nc; nc="${nc:-16}"
        read -erp "Download shaper rate to stabilise (e.g. 90mbit / none) [none]: " shape; shape="${shape:-none}"
    elif [[ "$t" == hysteria ]]; then
        read -erp "Brutal-CC target bandwidth in mbps (higher pushes harder through loss) [200]: " shape; shape="${shape:-200}"
    fi
    # collision-safe allocation vs whatever the foreign already runs (see cmd_add_auto)
    local fsub fport fnames
    fsub=$(peer_ssh "$fhost" "grep -hoE 'TUN_ADDR=10\\.201\\.[0-9]+' /etc/omnitunnel/inst/*/instance.conf 2>/dev/null | grep -oE '[0-9]+\$'" 2>/dev/null | tr '\r\n' '  ' || true)
    fport=$(peer_ssh "$fhost" "grep -hoE 'PORT=[0-9]+' /etc/omnitunnel/inst/*/instance.conf 2>/dev/null | grep -oE '[0-9]+'" 2>/dev/null | tr '\r\n' '  ' || true)
    fnames=$(peer_ssh "$fhost" "ls /etc/omnitunnel/inst 2>/dev/null" 2>/dev/null | tr '\r\n' '  ' || true)
    case " $fnames " in *" $kn "*) warn "the foreign already has an instance named '$kn' - pick a different name"; return;; esac
    local sub port key ta pa; sub=$(alloc_subnet "$fsub"); ta="10.201.$sub.1"; pa="10.201.$sub.2"
    port=$(alloc_port "$(( $(port_base "$t") + sub ))" "$fport"); key=$(gen_key); type_uses_key "$t" || key=""
    provision_peer "$fhost" "$kn" "$t" "$fhost" "$mylip" "$port" "$key" "$pa" "$ta" "$shape" "$nc"
    create_inst "$kn" "$t" client "$mylip" "$fhost" "$port" "$key" "$ta" "$pa" "$shape" "$nc"
    inst_enable "$kn"; ok "instance '$kn' ($t) is up on both sides.  (subnet 10.201.$sub.0/24, port/key $port)"
    if type_is_revmux "$t"; then
        echo; info "reverse-mux carries user traffic over ONE muxed flow. Add its first forward now"
        info "(a public port on THIS relay -> a destination the FOREIGN can reach, e.g. its local proxy):"
        local rp rdh rdp
        read -erp "  Public port on this relay [443]: " rp; rp="${rp:-443}"
        read -erp "  Destination host from the foreign [127.0.0.1]: " rdh; rdh="${rdh:-127.0.0.1}"
        read -erp "  Destination port [443]: " rdp; rdp="${rdp:-443}"
        cmd_mux_add "$kn" "$rp" "$rdh" "$rdp"
        info "add more later with:  ${C_CYAN}omnitunnel mux-add $kn <pubport> <dsthost> <dstport>${C_RESET}"
    fi
}

# Manual add: brings up the near side and prints a token to paste on the
# foreign box. Use it when this box cannot reach the foreign box over SSH.
wizard_add_manual() {
    need_root; ensure_binary
    echo; echo "${C_BOLD}Add a tunnel - MANUAL${C_RESET} ${C_DIM}(no SSH to the foreign; nothing touches port 22)${C_RESET}"
    local ci=1 types=() t ch x fhost kn
    for t in $ALL_TYPES; do printf "  %2d) %-12s %s\n" "$ci" "$t" "$(type_desc "$t")"; types+=("$t"); ci=$((ci+1)); done
    read -erp "Tunnel type [2]: " ch; ch="${ch:-2}"
    ch="$(pick_num "$ch" "${#types[@]}")" || { warn "pick a number between 1 and ${#types[@]}"; return; }
    t="${types[$((ch-1))]}"
    local mylip; mylip="$(default_local_ip)"
    read -erp "This box public IP [$mylip]: " x; mylip="${x:-$mylip}"
    read -erp "Far (foreign) server IP: " fhost; [[ -z "$fhost" ]] && { warn "need a foreign IP"; return; }
    read -erp "Instance name [main]: " kn; kn="${kn:-main}"; inst_exists "$kn" && { warn "instance exists"; return; }
    local nc=16 shape=none
    if [[ "$t" == mux ]]; then
        read -erp "Parallel links N [16]: " nc; nc="${nc:-16}"
        read -erp "Download shaper rate (e.g. 90mbit / none) [none]: " shape; shape="${shape:-none}"
    fi
    cmd_add_manual "$t" "$kn" "$fhost" "$nc" "$shape" "$mylip"
}

# ----------------------------------------------------------- benchmark --------
# The measurement server (iperf3) MUST be listening on :5599 on the foreign, or
# every tunnel measures nothing and the table is all-FAIL. Ensure it is up (or
# report clearly why it can't be) so the user isn't left guessing.
bench_ensure_iperf() {
    local h="$1" i
    # fast path: already listening
    peer_ssh "$h" "timeout 12 sh -c 'ss -lntu 2>/dev/null | grep -q :5599'" && return 0
    # install iperf3 if missing - HARD-BOUNDED so a held dpkg lock or a slow/broken
    # mirror can never hang the benchmark for hours (it used to). Non-interactive,
    # gives up on the lock after 30s and on the whole step after 100s.
    peer_ssh "$h" "timeout 100 sh -c 'command -v iperf3 >/dev/null 2>&1 || DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=30 install -y iperf3 >/dev/null 2>&1 || yum install -y iperf3 >/dev/null 2>&1 || true'" >/dev/null 2>&1 || true
    # then start it (each attempt bounded); bail out fast if iperf3 still isn't there
    for i in 1 2 3; do
        peer_ssh "$h" "timeout 15 sh -c '
            command -v iperf3 >/dev/null 2>&1 || exit 3
            ss -lntu 2>/dev/null | grep -q :5599 && exit 0
            systemctl reset-failed tsbench-iperf 2>/dev/null
            systemd-run --unit=tsbench-iperf --collect iperf3 -s -p 5599 >/dev/null 2>&1 || (setsid iperf3 -s -p 5599 >/dev/null 2>&1 </dev/null &)
            sleep 1; ss -lntu 2>/dev/null | grep -q :5599'" && return 0
        sleep 1
    done
    return 1
}
# A curl-served test file on the foreign (:5598) is the FALLBACK measurement path:
# when iperf3 can't measure through a tunnel (its control channel is fragile over
# e.g. the hysteria SOCKS5 relay) but the tunnel is actually up, we download this
# file through the tunnel instead. Best-effort - needs python3 on the foreign.
bench_ensure_httpfile() {
    local h="$1"
    # run the file server under systemd-run (like iperf) so it survives the SSH
    # session and the outer timeout - a plain 'setsid ... &' inside sh -c did not.
    peer_ssh "$h" "timeout 90 sh -c '
        command -v python3 >/dev/null 2>&1 || exit 3
        [ -f /tmp/omnibench.bin ] || fallocate -l 200M /tmp/omnibench.bin 2>/dev/null || dd if=/dev/zero of=/tmp/omnibench.bin bs=1M count=200 2>/dev/null
        ss -lntu 2>/dev/null | grep -q :5598 && exit 0
        systemctl reset-failed tsbench-http 2>/dev/null
        systemd-run --unit=tsbench-http --collect python3 -m http.server 5598 --directory /tmp >/dev/null 2>&1 || (setsid python3 -m http.server 5598 --directory /tmp >/dev/null 2>&1 </dev/null &)
        sleep 1; ss -lntu 2>/dev/null | grep -q :5598'" >/dev/null 2>&1
}
# measure download speed of a URL and print it iperf-style ("NNN Mbits/sec"); empty on failure
bench_curl_mbps() {
    # Sum 8 PARALLEL streams: a single download is window-limited on a high
    # latency path (a 150 ms link needs a huge window one stream never fills), so
    # one curl badly undersells a fast tunnel. The hysteria SOCKS relay is
    # threaded (listen 256) so parallel streams aggregate. Fall back to a single
    # stream if the parallel run yields nothing, so it is never worse than before.
    local url="$1" i tot tmp m
    tmp=$(mktemp -d 2>/dev/null)
    if [[ -n "$tmp" ]]; then
        for i in 1 2 3 4 5 6 7 8; do
            ( curl -s -o /dev/null -w '%{speed_download}\n' --max-time 15 "$url" 2>/dev/null > "$tmp/$i" || true ) &
        done
        wait
        tot=$(cat "$tmp"/* 2>/dev/null | awk '{s+=$1} END{print s+0}'); rm -rf "$tmp"
        m=$(awk -v b="${tot:-0}" 'BEGIN{ printf "%.3g", b*8/1000000 }')
        awk -v x="$m" 'BEGIN{ exit !(x+0 >= 0.05) }' && { printf "%s Mbits/sec" "$m"; return 0; }
    fi
    local bps; bps=$(curl -s -o /dev/null -w '%{speed_download}' --max-time 15 "$url" 2>/dev/null || true)
    [[ -n "$bps" ]] || return 1
    awk -v b="$bps" 'BEGIN{ m=b*8/1000000; if(m<0.05) exit 1; printf "%.3g Mbits/sec", m }'
}
bench_run() {
    need_root; ensure_binary
    local fhost fu fp mylip x
    read -erp "Foreign server IP to benchmark against: " fhost; [[ -z "$fhost" ]] && { warn "need a foreign IP"; return; }
    read -erp "Foreign SSH user [root]: " fu; fu="${fu:-root}"
    read -rsp "Foreign SSH password (blank = ssh key): " fp; echo
    read -erp "SOCKS5 proxy to reach the foreign, if the direct path is DPI-blocked (host:port, blank = direct): " fpx; fpx="${fpx:-${OMNITUN_PEER_PROXY:-}}"
    { [[ -n "$fp" || -n "$fpx" ]]; } && save_peer "$fhost" "$fu" "$fp" "$fpx"
    mylip="$(default_local_ip)"; read -erp "This box public IP [$mylip]: " x; mylip="${x:-$mylip}"
    guard_peer_downgrade "$fhost"
    command -v iperf3 >/dev/null || { warn "installing iperf3..."; apt-get install -y iperf3 >/dev/null 2>&1 || yum install -y iperf3 >/dev/null 2>&1 || true; }

    # deploy core + iperf3 server on the far side
    local parch; parch=$(peer_ssh "$fhost" "uname -m" 2>/dev/null | tr -d '\r')
    case "$parch" in x86_64|amd64) parch=amd64;; aarch64|arm64) parch=arm64;; *) die "peer CPU $parch unsupported";; esac
    local pbin=""; for d in "$ASSET_DIR/bin" "$SCRIPT_DIR/bin"; do [[ -f "$d/omnitun-$parch" ]] && { pbin="$d/omnitun-$parch"; break; }; done
    [[ -n "$pbin" ]] || die "no omnitun-$parch binary to send to $fhost (looked in $ASSET_DIR/bin and $SCRIPT_DIR/bin)"
    info "Deploying suite to $fhost ($parch)..."
    peer_ssh "$fhost" "mkdir -p /opt/omnitunnel/bin" || die "cannot reach $fhost"
    peer_scp "$fhost" "$pbin" "/opt/omnitunnel/bin/omnitun-$parch"
    peer_scp "$fhost" "$SCRIPT_PATH" "/opt/omnitunnel/omnitunnel.sh"
    peer_ssh "$fhost" "chmod +x /opt/omnitunnel/omnitunnel.sh; install -m0755 /opt/omnitunnel/bin/omnitun-$parch /usr/local/bin/omnitun" >/dev/null 2>&1 || true
    # hysteria engine for the far side too (so its bench server can come up)
    local hbin; hbin="$(hy_local_bin "$parch" || true)"
    [[ -n "$hbin" ]] && { peer_scp "$fhost" "$hbin" "/opt/omnitunnel/bin/hysteria-$parch"; peer_ssh "$fhost" "chmod +x /opt/omnitunnel/bin/hysteria-$parch; install -m0755 /opt/omnitunnel/bin/hysteria-$parch /usr/local/bin/hysteria" >/dev/null 2>&1 || true; }
    # bring up (and verify) the iperf3 measurement server on the foreign
    info "Starting measurement server on $fhost ..."
    if ! bench_ensure_iperf "$fhost"; then
        echo
        warn "Could not start iperf3 on $fhost - the benchmark can't measure without it."
        echo "  The foreign box needs the 'iperf3' package (it listens on port 5599 during"
        echo "  the test). Fix it one of these ways, then run the benchmark again:"
        echo "    - let it auto-install: make sure the foreign box can reach its apt/yum mirrors"
        echo "    - or install it by hand on the foreign:  ${C_CYAN}apt install -y iperf3${C_RESET}  (or ${C_CYAN}yum install -y iperf3${C_RESET})"
        die "measurement server unavailable on $fhost"
    fi
    bench_ensure_httpfile "$fhost" || true   # best-effort curl fallback server
    sleep 1

    echo; printf "%b\n" "${C_BOLD}Raw path (no tunnel):${C_RESET}"
    local raw_dl raw_ul raw_ping
    raw_ping=$(ping -c3 -W2 "$fhost" 2>/dev/null | awk -F'/' '/rtt|round-trip/{print $5}' || true)
    if nc -z -w4 "$fhost" 5599 2>/dev/null; then
        raw_dl=$(timeout 20 iperf3 -c "$fhost" -p 5599 -t 6 -O 2 -P 8 -R 2>/dev/null | grep -oE '[0-9.]+ [KMG]bits/sec +receiver' | tail -1 | awk '{print $1" "$2}' || true)
        raw_ul=$(timeout 20 iperf3 -c "$fhost" -p 5599 -t 6 -O 2 -P 8    2>/dev/null | grep -oE '[0-9.]+ [KMG]bits/sec +receiver' | tail -1 | awk '{print $1" "$2}' || true)
    else raw_dl="n/a (foreign 5599 not reachable directly)"; raw_ul="n/a"; fi
    printf "  download %s   rtt %s ms\n" "${raw_dl:-n/a}" "${raw_ping:-n/a}"

    # Auto-scale hysteria's Brutal-CC target to the measured raw path bandwidth.
    # Brutal sends at its TARGET rate regardless of loss, so a fixed low target
    # (the old hard-coded 200) capped hysteria at ~200 Mbit even on a 1-gig path
    # (measured: 188 where fou/gre did ~1 Gbit). Use ~90% of the raw download,
    # floored at 200 and capped at 2000 mbps. If raw couldn't be measured
    # (n/a) this yields 200 - the old safe default.
    local hy_target
    hy_target=$(awk -v s="$raw_dl" 'BEGIN{ n=s+0; if (s ~ /Kbits/) n/=1000; else if (s ~ /Gbits/) n*=1000; t=int(n*0.9); if (t<200) t=200; if (t>2000) t=2000; print t }')
    printf "  %bhysteria Brutal-CC target auto-scaled to %s mbps%b\n" "$C_GREY" "$hy_target" "$C_RESET"

    echo; printf "%b\n" "${C_BOLD}Benchmarking each tunnel (a few minutes)...${C_RESET}"
    local rows=() base; base=$(next_subnet_idx); local i=0 t
    # Best-effort measurement: one tunnel failing (a ping with no reply, an iperf
    # that times out, a far-side bring-up hiccup) must NOT abort the whole run
    # under 'set -e'. Relax it for the loop; each type just records FAIL instead.
    set +e
    for t in $ALL_TYPES; do
        local name="bench-$t" sub=$((base+i)); i=$((i+1))
        local ta="10.201.$sub.1" pa="10.201.$sub.2" port key nc=8 shape=none
        port=$(next_port $(( $(port_base "$t") + sub ))); key=$(gen_key)
        type_uses_key "$t" || key=""
        echo -n "  $t ... "
        # hysteria has no tun/ping: forward the iperf port through it and measure
        if type_is_hysteria "$t"; then
            peer_ssh "$fhost" "OMNITUN_ASSETS=/opt/omnitunnel /opt/omnitunnel/omnitunnel.sh _peercreate '$name' hysteria server '$fhost' '$mylip' '$port' '$key' '$pa' '$ta' '$hy_target' '$nc'" >/dev/null 2>&1
            create_inst "$name" hysteria client "$mylip" "$fhost" "$port" "$key" "$ta" "$pa" "$hy_target" "$nc"
            # download = parallel curl of the foreign's file server (forwarded
            # here on 5598); upload = iperf to the foreign's iperf server through
            # a second relay on 5599. Both ride the SOCKS5.
            printf 'tcp:5598\ntcp:5599\n' > "$(inst_pf "$name")"
            inst_enable "$name" >/dev/null 2>&1; pf_apply_all "$name" >/dev/null 2>&1
            # wait (bounded ~30s) until the QUIC tunnel actually carries data before measuring
            local w hrtt hdl="" hul="" sz
            for w in $(seq 1 15); do
                sz=$(curl -s -o /dev/null -w '%{size_download}' --max-time 3 "http://127.0.0.1:5598/omnibench.bin" 2>/dev/null || echo 0)
                [[ "$sz" =~ ^[1-9] ]] && break
                sleep 2
            done
            hrtt=$(ping -c3 -W2 "$fhost" 2>/dev/null | awk -F'/' '/rtt|round-trip/{print $5}')
            hdl=$(bench_curl_mbps "http://127.0.0.1:5598/omnibench.bin")
            hul=$(timeout 25 iperf3 -c 127.0.0.1 -p 5599 -t 8 -O 2 -P 8 2>/dev/null | grep -oE '[0-9.]+ [KMG]bits/sec +receiver' | tail -1 | awk '{print $1" "$2}')
            rows+=("$t|${hdl:-FAIL}|${hul:-FAIL}|0%|${hrtt:-n/a}"); echo "${hdl:-FAIL} / up ${hul:-FAIL}"
            inst_remove "$name" >/dev/null 2>&1
            peer_ssh "$fhost" "OMNITUN_ASSETS=/opt/omnitunnel /opt/omnitunnel/omnitunnel.sh _remove '$name'" >/dev/null 2>&1 || true
            continue
        fi
        # reverse-mux: icmp(reply) tunnel + chisel single-flow MUX. Measured THROUGH
        # the mux public port (bench port -> foreign iperf 5599), so the row shows
        # the muxed throughput - the whole point is that this holds up under the
        # -P 8 parallelism where a raw icmp upload collapses on a policed path.
        if type_is_revmux "$t"; then
            local bport=$((20000 + sub))
            peer_ssh "$fhost" "OMNITUN_ASSETS=/opt/omnitunnel /opt/omnitunnel/omnitunnel.sh _peercreate '$name' reverse-mux server '$fhost' '$mylip' '$port' '' '$pa' '$ta' none '$nc' reply" >/dev/null 2>&1
            create_inst "$name" reverse-mux client "$mylip" "$fhost" "$port" "" "$ta" "$pa" none "$nc" reply
            inst_enable "$name" >/dev/null 2>&1; sleep 6
            local rout rloss rrtt
            rout=$(ping -c5 -W2 "$pa" 2>/dev/null || true)
            rrtt=$(echo "$rout" | awk -F'/' '/rtt|round-trip/{print $5}')
            rloss=$(echo "$rout" | grep -oE '[0-9]+% packet loss' | grep -oE '^[0-9]+')
            echo "$bport:127.0.0.1:5599" > "$(mux_conf "$name")"
            mux_relay_reconcile "$name" >/dev/null 2>&1
            peer_ssh "$fhost" "OMNITUN_ASSETS=/opt/omnitunnel /opt/omnitunnel/omnitunnel.sh mux-token $(mux_token "$name")" >/dev/null 2>&1
            sleep 4
            local rdl rul
            rdl=$(timeout 25 iperf3 -c 127.0.0.1 -p "$bport" -t 12 -O 4 -P 8 -R 2>/dev/null | grep -oE '[0-9.]+ [KMG]bits/sec +receiver' | tail -1 | awk '{print $1" "$2}')
            rul=$(timeout 25 iperf3 -c 127.0.0.1 -p "$bport" -t 12 -O 4 -P 8    2>/dev/null | grep -oE '[0-9.]+ [KMG]bits/sec +receiver' | tail -1 | awk '{print $1" "$2}')
            rows+=("$t|${rdl:-FAIL}|${rul:-FAIL}|${rloss:-100}%|${rrtt:-n/a}")
            echo "${rdl:-FAIL} / up ${rul:-FAIL} (muxed)"
            inst_remove "$name" >/dev/null 2>&1
            peer_ssh "$fhost" "OMNITUN_ASSETS=/opt/omnitunnel /opt/omnitunnel/omnitunnel.sh mux-off '$name'; OMNITUN_ASSETS=/opt/omnitunnel /opt/omnitunnel/omnitunnel.sh _remove '$name'" >/dev/null 2>&1 || true
            continue
        fi
        peer_ssh "$fhost" "OMNITUN_ASSETS=/opt/omnitunnel /opt/omnitunnel/omnitunnel.sh _peercreate '$name' '$t' server '$fhost' '$mylip' '$port' '$key' '$pa' '$ta' '$shape' '$nc'" >/dev/null 2>&1
        create_inst "$name" "$t" client "$mylip" "$fhost" "$port" "$key" "$ta" "$pa" "$shape" "$nc"
        inst_enable "$name" >/dev/null 2>&1; sleep 6
        local out loss rtt dl ul
        out=$(ping -c5 -W2 "$pa" 2>/dev/null || true)
        rtt=$(echo "$out" | awk -F'/' '/rtt|round-trip/{print $5}')
        loss=$(echo "$out" | grep -oE '[0-9]+% packet loss' | grep -oE '^[0-9]+')
        dl=$(timeout 25 iperf3 -c "$pa" -p 5599 -t 12 -O 4 -P 8 -R 2>/dev/null | grep -oE '[0-9.]+ [KMG]bits/sec +receiver' | tail -1 | awk '{print $1" "$2}')
        # if iperf couldn't measure but the tunnel is actually up (loss < 100),
        # fall back to a curl download through the tun to the foreign's file server
        [[ -z "$dl" && "${loss:-100}" != 100 ]] && dl=$(bench_curl_mbps "http://$pa:5598/omnibench.bin")
        # upload = same iperf WITHOUT -R (Iran -> foreign). 'receiver' is what the
        # far side actually got, so a stalled/policed upload records FAIL instead
        # of a phantom sender rate.
        ul=$(timeout 25 iperf3 -c "$pa" -p 5599 -t 12 -O 4 -P 8 2>/dev/null | grep -oE '[0-9.]+ [KMG]bits/sec +receiver' | tail -1 | awk '{print $1" "$2}')
        rows+=("$t|${dl:-FAIL}|${ul:-FAIL}|${loss:-100}%|${rtt:-n/a}")
        echo "${dl:-FAIL} / up ${ul:-FAIL}"
        inst_remove "$name" >/dev/null 2>&1
        peer_ssh "$fhost" "OMNITUN_ASSETS=/opt/omnitunnel /opt/omnitunnel/omnitunnel.sh _remove '$name'" >/dev/null 2>&1 || true
    done
    # belt-and-braces: make sure no bench-* survived on either side
    for t in $ALL_TYPES; do
        inst_exists "bench-$t" && inst_remove "bench-$t" >/dev/null 2>&1 || true
        peer_ssh "$fhost" "OMNITUN_ASSETS=/opt/omnitunnel /opt/omnitunnel/omnitunnel.sh _remove 'bench-$t'" >/dev/null 2>&1 || true
    done
    # tear down the foreign measurement helpers (iperf + curl file server)
    peer_ssh "$fhost" "systemctl stop tsbench-iperf tsbench-http 2>/dev/null; pkill -f '[h]ttp.server 5598' 2>/dev/null; rm -f /tmp/omnibench.bin" >/dev/null 2>&1 || true
    set -e

    ROWS=("${rows[@]}"); RAW_DL="${raw_dl:-n/a}"; RAW_UL="${raw_ul:-n/a}"; RAW_PING="${raw_ping:-n/a}"; bench_table
    printf '  %bevery test tunnel was removed from both sides.%b\n\n' "$C_GREY" "$C_RESET"
    rule_green
    printf '  %bKeep one as a permanent instance?%b ' "$C_BGRN" "$C_RESET"
    local ci=1 ch keep; for t in $ALL_TYPES; do printf "  %2d) %-12s %s\n" "$ci" "$t" "$(type_desc "$t")"; ci=$((ci+1)); done
    echo "   0) keep none"
    read -erp "Choice: " ch || true; [[ -z "$ch" ]] && { info "nothing kept."; return 0; }
    [[ "$ch" =~ ^[0-9]+$ ]] || { warn "pick a number"; return; }
    [[ "$ch" =~ ^0+$ ]] && { info "nothing kept."; return 0; }
    local tarr=(); read -r -a tarr <<< "$ALL_TYPES"
    ch="$(pick_num "$ch" "${#tarr[@]}")" || { warn "no transport numbered $ch"; return; }
    keep="${tarr[$((ch-1))]}"
    read -erp "Name for the kept instance [main]: " kn; kn="${kn:-main}"; inst_exists "$kn" && die "instance $kn exists"
    local nc=16 shape=none
    [[ "$keep" == mux ]] && { read -erp "mux links N [16]: " nc; nc="${nc:-16}"; read -erp "download shaper (e.g. 90mbit / none) [none]: " shape; shape="${shape:-none}"; }
    [[ "$keep" == hysteria ]] && { read -erp "Brutal-CC target bandwidth mbps [$hy_target]: " shape; shape="${shape:-$hy_target}"; }
    local fsub fport fnames
    fsub=$(peer_ssh "$fhost" "grep -hoE 'TUN_ADDR=10\\.201\\.[0-9]+' /etc/omnitunnel/inst/*/instance.conf 2>/dev/null | grep -oE '[0-9]+\$'" 2>/dev/null | tr '\r\n' '  ' || true)
    fport=$(peer_ssh "$fhost" "grep -hoE 'PORT=[0-9]+' /etc/omnitunnel/inst/*/instance.conf 2>/dev/null | grep -oE '[0-9]+'" 2>/dev/null | tr '\r\n' '  ' || true)
    fnames=$(peer_ssh "$fhost" "ls /etc/omnitunnel/inst 2>/dev/null" 2>/dev/null | tr '\r\n' '  ' || true)
    case " $fnames " in *" $kn "*) die "the foreign already has an instance named '$kn' - choose a different name";; esac
    local sub port key ta pa; sub=$(alloc_subnet "$fsub"); ta="10.201.$sub.1"; pa="10.201.$sub.2"; port=$(alloc_port "$(( $(port_base "$keep") + sub ))" "$fport"); key=$(gen_key); type_uses_key "$keep" || key=""
    provision_peer "$fhost" "$kn" "$keep" "$fhost" "$mylip" "$port" "$key" "$pa" "$ta" "$shape" "$nc"
    create_inst "$kn" "$keep" client "$mylip" "$fhost" "$port" "$key" "$ta" "$pa" "$shape" "$nc"
    inst_enable "$kn"; ok "kept '$keep' as instance '$kn' on both sides."
}

# --------------------------------------------------- MANUAL benchmark ----------
# Same benchmark, but with no SSH to the foreign box. The foreign side is
# brought up once from a single pasted token; this side measures all four
# tunnels, prints the table, and lets you keep one. Fixed bench subnets
# (10.201.100-103) / ports (51900-51903) so both sides match deterministically.
_bench_key_for() { case "$1" in udp) echo "$B_KUDP";; mux) echo "$B_KMUX";; tcp) echo "$B_KTCP";; *) echo "";; esac; }
cmd_bench_manual() {
    need_root; ensure_binary
    local fhost="$1" mylip="${2:-$(default_local_ip)}"
    [[ -n "$fhost" ]] || die "usage: bench-manual <foreign_ip> [my_ip]"
    command -v iperf3 >/dev/null || { warn "installing iperf3..."; apt-get install -y iperf3 >/dev/null 2>&1 || true; }
    local ku km kt; ku=$(gen_key); km=$(gen_key); kt=$(gen_key)
    B_KUDP=$ku B_KMUX=$km B_KTCP=$kt
    local token; token=$(printf 'bench|%s|%s|%s|%s|%s' "$fhost" "$mylip" "$ku" "$km" "$kt" | base64 | tr -d '\n')
    echo
    echo "${C_BOLD}Manual benchmark${C_RESET} ${C_DIM}(no SSH to the foreign box)${C_RESET}"
    echo "1) On the FOREIGN server ($fhost) run these two lines:"
    echo "   ${C_CYAN}bash <(curl -fsSL $RAW_BASE/install.sh)${C_RESET}"
    echo "   ${C_CYAN}omnitunnel bench-server $token${C_RESET}"
    read -erp "2) Press Enter here once it prints 'benchmark server ready'... " _
    local raw_dl raw_ul raw_ping
    raw_ping=$(ping -c3 -W2 "$fhost" 2>/dev/null | awk -F'/' '/rtt|round-trip/{print $5}' || true)
    if nc -z -w4 "$fhost" 5599 2>/dev/null; then
        raw_dl=$(timeout 20 iperf3 -c "$fhost" -p 5599 -t 6 -O 2 -P 8 -R 2>/dev/null | grep -oE '[0-9.]+ [KMG]bits/sec +receiver' | tail -1 | awk '{print $1" "$2}' || true)
        raw_ul=$(timeout 20 iperf3 -c "$fhost" -p 5599 -t 6 -O 2 -P 8    2>/dev/null | grep -oE '[0-9.]+ [KMG]bits/sec +receiver' | tail -1 | awk '{print $1" "$2}' || true)
    else raw_dl="n/a (foreign 5599 not reachable directly)"; raw_ul="n/a"; fi
    echo; printf "%b\n" "${C_BOLD}Measuring each tunnel...${C_RESET}"
    local rows=() i=0 t
    set +e   # best-effort measurement (see bench_run): never abort mid-run
    for t in $ALL_TYPES; do
        { type_is_hysteria "$t" || type_is_revmux "$t"; } && { i=$((i+1)); continue; }  # manual bench (fixed keys) skips hysteria; use auto bench for it
        local name="bench-$t" sub=$((100+i)) port=$((51900+i)) key; key=$(_bench_key_for "$t")
        local ta="10.201.$sub.1" pa="10.201.$sub.2"
        echo -n "  $t ... "
        create_inst "$name" "$t" client "$mylip" "$fhost" "$port" "$key" "$ta" "$pa" none 8
        inst_enable "$name" >/dev/null 2>&1; sleep 6
        local out loss rtt dl ul
        out=$(ping -c5 -W2 "$pa" 2>/dev/null || true)
        rtt=$(echo "$out" | awk -F'/' '/rtt|round-trip/{print $5}')
        loss=$(echo "$out" | grep -oE '[0-9]+% packet loss' | grep -oE '^[0-9]+')
        dl=$(timeout 25 iperf3 -c "$pa" -p 5599 -t 12 -O 4 -P 8 -R 2>/dev/null | grep -oE '[0-9.]+ [KMG]bits/sec +receiver' | tail -1 | awk '{print $1" "$2}')
        ul=$(timeout 25 iperf3 -c "$pa" -p 5599 -t 12 -O 4 -P 8 2>/dev/null | grep -oE '[0-9.]+ [KMG]bits/sec +receiver' | tail -1 | awk '{print $1" "$2}')
        rows+=("$t|${dl:-FAIL}|${ul:-FAIL}|${loss:-100}%|${rtt:-n/a}"); echo "${dl:-FAIL} / up ${ul:-FAIL}"
        inst_remove "$name" >/dev/null 2>&1
        i=$((i+1))
    done
    set -e
    ROWS=("${rows[@]}"); RAW_DL="${raw_dl:-n/a}"; RAW_UL="${raw_ul:-n/a}"; RAW_PING="${raw_ping:-n/a}"; bench_table
    warn "on the FOREIGN server, remove the test tunnels with:  ${C_CYAN}omnitunnel bench-clean${C_RESET}"
    echo
    rule_green
    printf '  %bKeep one as a permanent instance?%b %b(sets up its own fresh token)%b ' "$C_BGRN" "$C_RESET" "$C_GREY" "$C_RESET"
    local ci=1 ch keep
    for t in $ALL_TYPES; do
        if type_is_hysteria "$t" || type_is_revmux "$t"; then
            printf "  %2d) %-12s %s\n" "$ci" "$t" "not measured above - use the SSH benchmark for it"
        else
            printf "  %2d) %-12s %s\n" "$ci" "$t" "$(type_desc "$t")"
        fi
        ci=$((ci+1))
    done
    echo "   0) keep none"
    read -erp "Choice: " ch || true; [[ -z "$ch" ]] && { info "nothing kept."; return 0; }
    [[ "$ch" =~ ^[0-9]+$ ]] || { warn "pick a number"; return; }
    [[ "$ch" =~ ^0+$ ]] && { info "nothing kept."; return 0; }
    local tarr=(); read -r -a tarr <<< "$ALL_TYPES"
    ch="$(pick_num "$ch" "${#tarr[@]}")" || { warn "no transport numbered $ch"; return; }
    keep="${tarr[$((ch-1))]}"
    read -erp "Name for the kept instance [main]: " kn; kn="${kn:-main}"
    local nc=16 shape=none
    [[ "$keep" == mux ]] && { read -erp "mux links N [16]: " nc; nc="${nc:-16}"; read -erp "download shaper (e.g. 90mbit / none) [none]: " shape; shape="${shape:-none}"; }
    cmd_add_manual "$keep" "$kn" "$fhost" "$nc" "$shape" "$mylip"
}
# Foreign side: bring up all four server tunnels + an iperf3 server, from a token.
cmd_bench_server() {
    need_root; ensure_binary
    local dec; dec=$(printf '%s' "$1" | base64 -d 2>/dev/null) || die "invalid token"
    local tag fhost mylip ku km kt; IFS='|' read -r tag fhost mylip ku km kt <<< "$dec"
    [[ "$tag" == bench ]] || die "not a benchmark token"
    B_KUDP=$ku B_KMUX=$km B_KTCP=$kt
    command -v iperf3 >/dev/null || { apt-get install -y iperf3 >/dev/null 2>&1 || yum install -y iperf3 >/dev/null 2>&1 || true; }
    systemctl reset-failed omnitun-bench-iperf 2>/dev/null || true
    systemd-run --unit=omnitun-bench-iperf --collect iperf3 -s -p 5599 >/dev/null 2>&1 || (setsid iperf3 -s -p 5599 >/dev/null 2>&1 &)
    local i=0 t
    set +e   # best-effort bring-up: don't abort if one type fails to come up
    for t in $ALL_TYPES; do
        { type_is_hysteria "$t" || type_is_revmux "$t"; } && { i=$((i+1)); continue; }  # manual bench skips hysteria (fixed-key token path)
        local name="bench-$t" sub=$((100+i)) port=$((51900+i)) key; key=$(_bench_key_for "$t")
        local ta="10.201.$sub.1" pa="10.201.$sub.2"
        inst_exists "$name" && inst_remove "$name" >/dev/null 2>&1
        create_inst "$name" "$t" server "$fhost" "$mylip" "$port" "$key" "$pa" "$ta" none 8
        inst_enable "$name" >/dev/null 2>&1
        i=$((i+1))
    done
    set -e
    ok "benchmark server ready - now press Enter on the Iran side."
}
cmd_bench_clean() {
    need_root; local t
    for t in $ALL_TYPES; do inst_remove "bench-$t" >/dev/null 2>&1 || true; done
    systemctl stop omnitun-bench-iperf 2>/dev/null || true
    ok "benchmark test tunnels removed."
}

# ------------------------------------------------------------ self-update -----
# Re-run the canonical installer from GitHub. It is idempotent and version-aware:
# it refreshes the manager + core binaries and, only if the version changed,
# restarts the running tunnels. Returns non-zero (without aborting the menu) if
# GitHub can't be reached - e.g. a box with no direct egress, which you update by
# re-pushing the files the same way you first installed it.
cmd_update() {
    need_root
    command -v curl >/dev/null 2>&1 || { warn "curl is required to update"; return 1; }
    info "Checking GitHub for a newer OmniTunnel (current v$VERSION)..."
    local tmp; tmp="$(mktemp)"
    # cache-bust the raw CDN so a stale edge can't hand back the old install.sh
    # (which would then fetch an old manager and report "already up to date")
    if ! curl -fsSL -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' \
              "$RAW_BASE/install.sh?cb=$(date +%s)-${RANDOM}${RANDOM}" -o "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        warn "Could not reach GitHub from this box."
        warn "If it has no direct internet egress, update it by re-pushing the files"
        warn "(run the installer on a box that can reach GitHub, or copy them over)."
        return 1
    fi
    bash "$tmp"; local rc=$?; rm -f "$tmp"
    [[ $rc -eq 0 ]] || { warn "update failed"; return 1; }
    return 0
}

# ----------------------------------------------------------- full uninstall ---
# Remove EVERYTHING this tool created: every instance (including any leftover
# bench-* ones) with its unit, relays, tun device and iptables chain; the core
# binaries; all state; and finally its own files and the 'omnitunnel' command.
# It never touches anything it did not create.
cmd_uninstall() {
    need_root
    echo
    warn "This completely removes OmniTunnel and everything it created:"
    echo "  - every tunnel/instance (including any 'bench-*'), its systemd unit,"
    echo "    port-forward relays, tun device and iptables chain"
    echo "  - the core binaries: $TSUITE_BIN and $HYSTERIA_BIN"
    echo "  - all state in $ROOT_DIR and the files in $ASSET_DIR"
    echo "  - the 'omnitunnel' command itself"
    echo "  ${C_DIM}(it does not touch anything OmniTunnel didn't create)${C_RESET}"
    echo
    local a; read -erp "Type 'DELETE' to remove everything: " a || true
    [[ "$a" == "DELETE" ]] || { info "aborted - nothing removed."; return 0; }
    echo
    # 1) clean removal of each instance the tool knows about
    local n
    for n in $(list_instances); do echo "  removing instance '$n'"; inst_remove "$n" >/dev/null 2>&1 || true; done
    # 2) sweep any stray omnitun-* units (relays, bench iperf, half-removed ones)
    local u
    for u in $(systemctl list-units 'omnitun-*' --all --no-legend 2>/dev/null | awk '{print $1}'); do
        systemctl disable --now "$u" >/dev/null 2>&1 || true
        rm -f "/etc/systemd/system/$u"
    done
    systemctl reset-failed 2>/dev/null || true; systemctl daemon-reload 2>/dev/null || true
    # 3) sweep any leftover TSUITE nat chains
    local ch
    for ch in $(iptables -t nat -S 2>/dev/null | grep -oE 'TSUITE_[A-Z0-9_]+' | sort -u); do
        iptables -t nat -D PREROUTING -j "$ch" 2>/dev/null || true
        iptables -t nat -F "$ch" 2>/dev/null || true
        iptables -t nat -X "$ch" 2>/dev/null || true
    done
    # 4) core binaries + relay helper
    rm -f "$TSUITE_BIN" "$HYSTERIA_BIN" "$HY_RELAY" "$FWD_SYSCTL_FILE"
    # 5) state, the command symlink, then the install dir (this script lives there)
    rm -rf "$ROOT_DIR"
    rm -f "$BINLINK"
    ok "OmniTunnel removed. Deleting its own files now - goodbye."
    rm -rf "$ASSET_DIR"
    exit 0
}

# -------------------------------------------------------------------- menus ---
# count instances by state for the header strip
_state_counts() {
    RUN=0; STOP=0; local n
    for n in $(list_instances); do inst_running "$n" && RUN=$((RUN+1)) || STOP=$((STOP+1)); done
}
UI_W=62
_rule() { local i s=""; for ((i=0;i<UI_W;i++)); do s="$s${G_H}"; done; printf '%s' "$s"; }
rule() { printf '  %b%s%b\n' "$C_GREY" "$(_rule)" "$C_RESET"; }
# A double rule used between the header blocks of the home screen.
_drule() { local i s=""; for ((i=0;i<UI_W;i++)); do s="${s}═"; done; printf '%s' "$s"; }
rule_amber() { printf '  %b%s%b\n' "$C_BYEL" "$(_drule)" "$C_RESET"; }
rule_green() { printf '  %b%s%b\n' "$C_BGRN" "$(_drule)" "$C_RESET"; }
# label: value line of the header blocks
kv() { printf '  %b%-16s%b %b%s%b\n' "$C_BCYN" "$1" "$C_RESET" "${3:-$C_WHITE}" "$2" "$C_RESET"; }
# home-screen menu entry:  1. Label
nitem() { printf '   %b%s. %s%b\n' "${3:-$C_WHITE}" "$1" "$2" "$C_RESET"; }
# Choose an existing tunnel by NUMBER (never by typing its name - that is
# error-prone and impossible for a non-ASCII / Persian name, and the terminal's
# backspace can eat into the prompt when editing multibyte input). Sets PICK to
# the chosen instance name; returns non-zero if there are none or the user cancels.
pick_instance() {
    PICK=""; local names=() n i=1
    for n in $(list_instances); do names+=("$n"); done
    if [[ ${#names[@]} -eq 0 ]]; then warn "no tunnels yet"; return 1; fi
    printf '  %bpick a tunnel:%b\n' "$C_DIM" "$C_RESET"
    for n in "${names[@]}"; do printf '   %b%d%b. %s\n' "$C_BCYN$C_BOLD" "$i" "$C_RESET" "$n"; i=$((i+1)); done
    printf '   %b0%b. cancel\n  %b❯%b ' "$C_DIM" "$C_RESET" "$C_BCYN$C_BOLD" "$C_RESET"
    local ch; read -r ch || true
    [[ "$ch" =~ ^[0-9]+$ ]] || { warn "please enter a number"; return 1; }
    [[ "$ch" =~ ^0+$ ]] && return 1
    ch="$(pick_num "$ch" "${#names[@]}")" || { warn "no tunnel numbered $ch"; return 1; }
    PICK="${names[$((ch-1))]}"
    return 0
}
# Choose the forward protocol by number. Sets PROTO to tcp / udp / both.
pick_proto() {
    PROTO=""
    printf '  %bprotocol:%b\n' "$C_DIM" "$C_RESET"
    printf '   %b1%b. tcp\n   %b2%b. udp\n   %b3%b. udp + tcp  (both)\n' \
        "$C_BCYN$C_BOLD" "$C_RESET" "$C_BCYN$C_BOLD" "$C_RESET" "$C_BCYN$C_BOLD" "$C_RESET"
    printf '  %b❯%b ' "$C_BCYN$C_BOLD" "$C_RESET"; local pn; read -r pn || true
    case "$pn" in 1) PROTO=tcp;; 2) PROTO=udp;; 3) PROTO=both;; *) warn "pick 1, 2 or 3"; return 1;; esac
    return 0
}
# List instance $1's forwarded ports by number; set PORT_PICK to the chosen one.
pick_fwd_port() {
    PORT_PICK=""; PORT_KIND=""; local pf mc p dh dp ports=() kinds=() labels=() seen=" " i=1 x ch
    pf="$(inst_pf "$1")"; mc="$(mux_conf "$1")"
    if [[ -s "$pf" ]]; then
        while IFS=: read -r _ p; do [[ -z "$p" || "$seen" == *" $p "* ]] && continue
            seen+="$p "; ports+=("$p"); kinds+=(pf); labels+=("port $p"); done < "$pf"
    fi
    if [[ -s "$mc" ]]; then
        while IFS=: read -r p dh dp; do [[ -z "$p" ]] && continue
            ports+=("$p"); kinds+=(mux); labels+=("port $p  (muxed -> $dh:$dp)"); done < "$mc"
    fi
    [[ ${#ports[@]} -eq 0 ]] && { warn "this tunnel has no forwards"; return 1; }
    printf '  %bwhich forward to remove:%b\n' "$C_DIM" "$C_RESET"
    for x in "${labels[@]}"; do printf '   %b%d%b. %s\n' "$C_BCYN$C_BOLD" "$i" "$C_RESET" "$x"; i=$((i+1)); done
    printf '   %b0%b. cancel\n  %b❯%b ' "$C_DIM" "$C_RESET" "$C_BCYN$C_BOLD" "$C_RESET"; read -r ch || true
    [[ "$ch" =~ ^[0-9]+$ ]] || { warn "enter a number"; return 1; }
    [[ "$ch" =~ ^0+$ ]] && return 1
    ch="$(pick_num "$ch" "${#ports[@]}")" || { warn "no forward numbered $ch"; return 1; }
    PORT_PICK="${ports[$((ch-1))]}"; PORT_KIND="${kinds[$((ch-1))]}"
    return 0
}

# The home screen: wordmark, build info, this box, then the menu. Sub-screens
# get the compact one-line header instead (pass a crumb).
banner() {
    clear 2>/dev/null || true
    local crumb="${1:-}" myip; myip="$(default_local_ip 2>/dev/null)"
    _state_counts
    local fwd=0 n c m pf mc
    for n in $(list_instances); do
        pf="$(inst_pf "$n")"; mc="$(mux_conf "$n")"; c=0; m=0
        [[ -s "$pf" ]] && c=$(grep -c . "$pf" 2>/dev/null || true)
        [[ -s "$mc" ]] && m=$(grep -c . "$mc" 2>/dev/null || true)
        [[ "$c" =~ ^[0-9]+$ ]] || c=0
        [[ "$m" =~ ^[0-9]+$ ]] || m=0
        fwd=$((fwd+c+m))
    done
    if [[ -n "$crumb" ]]; then
        local right; right="${myip:-?} · $(arch_tag)"
        local pad=$(( UI_W - ${#crumb} - ${#right} - 14 )); [[ $pad -lt 1 ]] && pad=1
        printf '\n  %bOMNITUNNEL%b  %b%s%b%*s%b%s%b\n' \
            "$C_BCYN$C_BOLD" "$C_RESET" "$C_WHITE$C_BOLD" "$crumb" "$C_RESET" \
            "$pad" "" "$C_GREY" "$right" "$C_RESET"
        rule_amber
        printf '  %b%-16s%b %b%s running%b, %b%s stopped%b   %b%-10s%b %b%s%b\n' \
            "$C_BCYN" "Tunnels:" "$C_RESET" \
            "$([[ $RUN -gt 0 ]] && printf '%s' "$C_BGRN" || printf '%s' "$C_GREY")" "$RUN" "$C_RESET" \
            "$([[ $STOP -gt 0 ]] && printf '%s' "$C_BRED" || printf '%s' "$C_GREY")" "$STOP" "$C_RESET" \
            "$C_BCYN" "Forwards:" "$C_RESET" "$C_WHITE" "$fwd" "$C_RESET"
        rule_amber
        return 0
    fi
    printf '%b\n' "$C_BCYN$C_BOLD"
    cat <<'EOF'
  █████ █   █ █   █ █████ █████ █   █ █   █ █   █ █████ █
  █   █ ██ ██ ██  █   █     █   █   █ ██  █ ██  █ █     █
  █   █ █ █ █ █ █ █   █     █   █   █ █ █ █ █ █ █ ████  █
  █   █ █   █ █  ██   █     █   █   █ █  ██ █  ██ █     █
  █████ █   █ █   █ █████   █   █████ █   █ █   █ █████ █████
EOF
    printf '%b' "$C_RESET"
    printf '  %bMulti-protocol obfuscated tunnel suite%b\n\n' "$C_WHITE" "$C_RESET"
    kv "Script Version:" "$VERSION"
    kv "Core Version:" "$("$TSUITE_BIN" version 2>/dev/null || echo 'not installed')"
    kv "Source:" "github.com/Free-Guy-IR/OmniTunnel"
    rule_amber
    kv "IP Address:" "${myip:-unknown}"
    kv "Architecture:" "$(arch_tag)"
    kv "Tunnels:" "$RUN running, $STOP stopped" "$([[ $RUN -gt 0 ]] && printf '%s' "$C_BGRN" || printf '%s' "$C_GREY")"
    kv "Port forwards:" "$fwd"
    kv "Core:" "$([[ -x "$TSUITE_BIN" ]] && echo Installed || echo missing)" "$([[ -x "$TSUITE_BIN" ]] && printf '%s' "$C_BGRN" || printf '%s' "$C_BRED")"
    local off; off="$(forwarding_offenders)"
    if [[ -n "$off" ]]; then
        kv "IP forwarding:" "OFF on ${off% }" "$C_BRED"
        printf '  %b%s%b\n' "$C_BYEL" "forwards silently drop while this is off - fix with: omnitunnel fix-forwarding" "$C_RESET"
    fi
    local ovr; ovr="$(forwarding_conf_overrides)"
    if [[ -n "$ovr" ]]; then
        kv "Forwarding conf:" "overridden at boot by ${ovr% }" "$C_BYEL"
    fi
    rule_amber
    return 0
}
# a section heading used inside the sub-screens
heading() { printf '  %b%s%b\n' "$C_GREY" "$1" "$C_RESET"; }
# a numbered menu item:  key  label  [hint]  [key-colour]
mitem() {
    local kc="${4:-$C_BCYN$C_BOLD}"
    printf '    %b%s%b  %b%-24s%b %b%s%b\n' "$kc" "$1" "$C_RESET" "$C_WHITE" "$2" "$C_RESET" "$C_GREY" "${3:-}" "$C_RESET"
}
# the persistent key legend that closes every screen
keyhint() { printf '\n'; rule; printf '  %b%s%b\n' "$C_GREY" "$1" "$C_RESET"; }
prompt() { printf '\n  %b❯%b ' "$C_BCYN$C_BOLD" "$C_RESET"; }
# ------------------------------------------------------- benchmark table ------
# "652 Mbits/sec" / "870 Kbits/sec" / "1.2 Gbits/sec" -> a plain mbit number
_mbit() { awk -v s="$1" 'BEGIN{ n=s+0; if (s ~ /Kbits/) n/=1000; else if (s ~ /Gbits/) n*=1000; if (s !~ /[0-9]/) n=0; printf "%.6g", n }'; }
_bar()  { local n="$1" i s=""; for ((i=0;i<n;i++)); do s="${s}█"; done; printf '%s' "$s"; }
_gt()   { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a>b)}'; }
# Sorted, bar-charted results. Reads ROWS[] (type|download|loss|ping), RAW_DL,
# RAW_PING. Marks the outright winner and, separately, the fastest fully
# obfuscated transport - the distinction the whole run exists to answer.
bench_table() {
    local r t dl ul ls pg v max=0 sv=0 stealth="" sorted=() line
    banner "Benchmark results"
    for r in "${ROWS[@]}"; do
        IFS='|' read -r t dl ul ls pg <<< "$r"; v="$(_mbit "$dl")"
        sorted+=("$(printf '%012.3f|%s' "$v" "$r")")
        if _gt "$v" "$max"; then max="$v"; fi
        case "$t" in udp|tcp|mux|ws|hysteria|fou|icmp|reverse-mux) if _gt "$v" "$sv"; then sv="$v"; stealth="$t"; fi;; esac
    done
    local OIFS="$IFS"; IFS=$'\n'; sorted=($(printf '%s\n' "${sorted[@]}" | sort -r)); IFS="$OIFS"
    echo
    printf '  %braw path (plain TCP, policed)%b   down %b%s%b / up %b%s%b   rtt %b%s ms%b\n\n' \
        "$C_GREY" "$C_RESET" "$C_WHITE" "${RAW_DL:-n/a}" "$C_RESET" "$C_WHITE" "${RAW_UL:-n/a}" "$C_RESET" "$C_WHITE" "${RAW_PING:-n/a}" "$C_RESET"
    printf '    %b%-12s %-14s %-8s %-8s %-6s %-5s %s%b\n' "$C_GREY" "TYPE" "" "DOWNLOAD" "UPLOAD" "LOSS" "PING" "NOTE" "$C_RESET"
    local first=1 n bar bc lcol lsc ucol mark note dnum unum
    for line in "${sorted[@]}"; do
        v="${line%%|*}"; r="${line#*|}"; IFS='|' read -r t dl ul ls pg <<< "$r"
        n=$(awk -v a="$v" -v m="$max" 'BEGIN{ if (m<=0) {print 0; exit} k=int(14*a/m+0.5); if (k<1 && a>0) k=1; print k }')
        bar="$(_bar "$n")$(printf '%*s' $((14-n)) '')"
        bc="$C_BCYN"; lcol="$C_WHITE"; mark=" "; note=""
        if [[ "$first" == 1 ]]; then bc="$C_BGRN"; mark="$G_ARROW"; note="fastest"; first=0; fi
        if [[ "$t" == "$stealth" ]]; then note="${note:+$note · }stealth pick"; fi
        if _gt "$(awk -v m="$max" 'BEGIN{print m/50}')" "$v"; then bc="$C_GREY"; lcol="$C_GREY"; fi
        lsc="$C_BGRN"; [[ "$ls" != "0%" ]] && lsc="$C_BYEL"
        dnum="$dl"; [[ "$dl" == *bits/sec* ]] && dnum="${dl%% *}$(printf '%s' "${dl#* }" | cut -c1)"
        unum="$ul"; [[ "$ul" == *bits/sec* ]] && unum="${ul%% *}$(printf '%s' "${ul#* }" | cut -c1)"
        ucol="$lcol"; [[ "$ul" == FAIL || "$ul" == n/a ]] && ucol="$C_BYEL"
        printf '  %b%s%b %b%-12s%b %b%s%b %b%-8s%b %b%-8s%b %b%-6s%b %-5s %b%s%b\n' \
            "$C_BGRN" "$mark" "$C_RESET" "$lcol" "$t" "$C_RESET" \
            "$bc" "$bar" "$C_RESET" "$lcol" "$dnum" "$C_RESET" \
            "$ucol" "$unum" "$C_RESET" \
            "$lsc" "$ls" "$C_RESET" "$pg" "$C_GREY" "$note" "$C_RESET"
    done
    echo
    return 0
}
menu_instances() {
    while true; do
        banner "Manage tunnels"
        local any=0 n
        echo; inst_header; rule
        for n in $(list_instances); do inst_status "$n" full; any=1; done
        [[ "$any" == 0 ]] && printf '  %b%s no tunnels yet - add one below%b\n' "$C_GREY" "$G_DOT_OFF" "$C_RESET"
        echo
        nitem 1 "Add a tunnel  (auto - sets up the foreign over SSH)" "$C_BGRN$C_BOLD"
        nitem 2 "Add a tunnel  (manual - paste a token abroad)"       "$C_BCYN$C_BOLD"
        nitem 3 "Remove a tunnel"                                     "$C_BRED$C_BOLD"
        nitem 4 "Restart a tunnel"
        nitem 5 "Live logs"
        nitem 0 "Back"
        rule_green
        printf '  %bEnter your choice [0-5]:%b ' "$C_BGRN" "$C_RESET"
        read -r c || exit 0
        case "$c" in
            1) wizard_add; pause;;
            2) wizard_add_manual; pause;;
            3) if pick_instance; then remove_instance_fully "$PICK"; fi; pause;;
            4) if pick_instance; then inst_enable "$PICK"; fi; pause;;
            5) if pick_instance; then journalctl -u "$(svc_name "$PICK")" -n 40 --no-pager 2>/dev/null || true; fi; pause;;
            0) return;;
        esac
    done
}
menu_pf() {
    while true; do
        banner "Port forwarding"
        heading "a port hit on this box is tunneled to the far side"
        local n pf mc any=0
        for n in $(list_instances); do
            pf="$(inst_pf "$n")"; mc="$(mux_conf "$n")"; any=1
            printf '  %b%s%b %b%s%b\n' "$C_MAG" "$G_V" "$C_RESET" "$C_BOLD$C_WHITE" "$n" "$C_RESET"
            local shown=0
            if [[ -s "$pf" ]]; then
                local proto port
                while IFS=: read -r proto port; do [[ -z "$proto" ]] && continue
                    shown=1
                    printf '       %b%s%b %b%-4s%b %s\n' "$C_GREEN" "$G_ARROW" "$C_RESET" "$C_CYAN" "$proto" "$C_RESET" "$port"; done < "$pf"
            fi
            if [[ -s "$mc" ]]; then
                local mp mdh mdp
                while IFS=: read -r mp mdh mdp; do [[ -z "$mp" ]] && continue
                    shown=1
                    printf '       %b%s%b %b%-4s%b %s %b-> %s:%s%b\n' "$C_GREEN" "$G_ARROW" "$C_RESET" \
                        "$C_BMAG" "mux" "$C_RESET" "$mp" "$C_GREY" "$mdh" "$mdp" "$C_RESET"; done < "$mc"
            fi
            [[ "$shown" == 0 ]] && printf '       %b(no forwards)%b\n' "$C_DIM" "$C_RESET"
        done
        [[ "$any" == 0 ]] && printf '  %b(add a tunnel first)%b\n' "$C_DIM" "$C_RESET"
        echo
        nitem 1 "Add a forward     (pick tunnel · protocol · port)" "$C_BGRN$C_BOLD"
        nitem 2 "Remove a forward  (pick tunnel · port)"            "$C_BRED$C_BOLD"
        nitem 0 "Back"
        rule_green
        printf '  %bEnter your choice [0-2]:%b ' "$C_BGRN" "$C_RESET"
        read -r c || exit 0
        case "$c" in
            1) if pick_instance; then n="$PICK"
                 if pick_proto; then read -erp "  port number: " po
                     if [[ "$po" =~ ^[0-9]+$ ]]; then pf_add "$n" "$PROTO" "$po"; else warn "port must be a number"; fi
                 fi
               fi; pause;;
            2) if pick_instance; then n="$PICK"
                 if pick_fwd_port "$n"; then
                     if [[ "$PORT_KIND" == mux ]]; then cmd_mux_del "$n" "$PORT_PICK"; else pf_del "$n" "$PORT_PICK"; fi
                 fi
               fi; pause;;
            0) return;;
        esac
    done
}
group() { printf '\n  %b%s%b\n' "$C_GREY" "$1" "$C_RESET"; }
menu_main() {
    while true; do
        banner
        echo
        nitem 1 "Benchmark all tunnels & pick the best" "$C_BGRN$C_BOLD"
        nitem 2 "Benchmark - manual (no SSH)"           "$C_BCYN$C_BOLD"
        nitem 3 "Manage tunnels"                        "$C_BLUE$C_BOLD"
        nitem 4 "Port forwarding"
        nitem 5 "Status of everything"
        nitem 6 "Update OmniTunnel"
        nitem 7 "Remove OmniTunnel"                     "$C_BRED$C_BOLD"
        nitem 0 "Exit"
        rule_green
        printf '  %bEnter your choice [0-7]:%b ' "$C_BGRN" "$C_RESET"
        read -r c || exit 0
        case "$c" in
            1) bench_run; pause;;
            2) local fh mip; read -erp "Foreign server IP: " fh; mip="$(default_local_ip)"; read -erp "This box public IP [$mip]: " x; mip="${x:-$mip}"; [[ -n "$fh" ]] && cmd_bench_manual "$fh" "$mip"; pause;;
            3) menu_instances;;
            4) menu_pf;;
            5) banner "Status of everything"; echo; inst_header; rule; local a5=0
               for n in $(list_instances); do inst_status "$n" full; a5=1; done
               [[ "$a5" == 0 ]] && printf '  %b%s no tunnels%b\n' "$C_GREY" "$G_DOT_OFF" "$C_RESET"; pause;;
            6) if cmd_update; then ok "Reloading the updated manager..."; sleep 1; exec "$SCRIPT_PATH" menu; else pause; fi;;
            7) cmd_uninstall; pause;;
            0) exit 0;;
        esac
    done
}

# ------------------------------------------------------------------- main -----
mkdir -p "$INST_DIR" "$PEER_DIR" 2>/dev/null || true
# remember how we were invoked so guard_peer_downgrade can re-exec after a
# self-update (see that function).
OMNI_ARGV=("$@")
case "${1:-menu}" in
    menu|"")          need_root; ensure_binary; menu_main;;
    bench)            need_root; bench_run;;
    add)              need_root; wizard_add;;
    add-auto)         shift; cmd_add_auto "$@";;
    add-manual)       shift; cmd_add_manual "$@";;
    server-token)     need_root; cmd_server_token "${2:?token}";;
    bench-manual)     shift; cmd_bench_manual "$@";;
    bench-server)     need_root; cmd_bench_server "${2:?token}";;
    bench-clean)      need_root; cmd_bench_clean;;
    list)             for n in $(list_instances); do inst_status "$n"; done;;
    status)           inst_status "${2:?instance}";;
    enable)           inst_enable "${2:?instance}";;
    remove)           need_root; remove_instance_fully "${2:?instance}";;
    _remove)          need_root; inst_remove "${2:?instance}";;
    pf-add)           pf_add "${2:?}" "${3:?}" "${4:?}";;
    pf-del)           pf_del "${2:?}" "${3:?}";;
    mux-add)          shift; cmd_mux_add "$@";;
    mux-del)          shift; cmd_mux_del "$@";;
    mux-token)        need_root; cmd_mux_token "${2:?token}";;
    mux-off)          need_root; cmd_mux_off "${2:?instance}";;
    _postup)          cmd_postup "${2:?}";;
    _prefwd)          cmd_prefwd;;
    _peercreate)      shift; cmd_peercreate "$@";;
    ensure-binary)    ensure_binary; ok "core ready at $TSUITE_BIN ($(arch_tag))";;
    fix-forwarding)   need_root; ensure_forwarding ""
                      for n in $(list_instances); do
                          inst_exists "$n" || continue
                          load_inst "$n"; ensure_forwarding "$DEV"
                      done
                      repair_all_forwarding
                      off="$(forwarding_offenders)"
                      if persist_forwarding; then pmsg="persisted in $FWD_SYSCTL_FILE"
                      else pmsg="NOT persisted ($FWD_SYSCTL_FILE unwritable) - will reset on reboot"; fi
                      if [[ -z "$off" ]]; then ok "IP forwarding on for every interface; $pmsg"
                      else warn "could not turn it on for: ${off% }; $pmsg"; fi
                      ovr="$(forwarding_conf_overrides)"
                      [[ -n "$ovr" ]] && warn "these sysctl files are applied AFTER $FWD_SYSCTL_FILE and decide the value at boot: ${ovr% }"
                      true;;
    update|upgrade)   need_root; cmd_update;;
    uninstall|purge)  need_root; cmd_uninstall;;
    version|-v|--version) echo "tunnelctl $VERSION (core: $($TSUITE_BIN version 2>/dev/null || echo n/a))";;
    *) echo "usage: $0 [menu|bench|add|list|status <n>|enable <n>|remove <n>|pf-add <n> <proto> <port>|pf-del <n> <port>|mux-add <n> <pubport> <dsthost> <dstport>|mux-del <n> <pubport>|mux-token <tok>|fix-forwarding|update|uninstall]";;
esac
