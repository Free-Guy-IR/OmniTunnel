<p align="center">
  <img src="assets/preview.png" alt="OmniTunnel TUI" width="420">
</p>

# OmniTunnel

**A multi-protocol, obfuscated tunnel suite for bypassing per-destination
traffic policing and DPI.** Prebuilt static binaries, one English
menu-driven manager, nine interchangeable tunnel transports, and any
many-to-many topology you need.

Built and hardened against real Iran ⇄ abroad conditions, where different ISPs
police, throttle, or block traffic very differently depending on the transport
and the destination datacenter. (Formerly the ICMP-only `icmptun` project —
ICMP is now just one of the nine transports.)

---

## Why ten transports?

No single tunnel wins everywhere. What an ISP lets through — and how fast — is
**per-route and per-transport**, and it changes. OmniTunnel ships all ten and
lets you **benchmark them and keep the winner**:

| Mode | What it is | Best when |
|------|------------|-----------|
| `gre`  | IP-over-GRE, native kernel tunnel (no key) | The ISP polices TCP/UDP but leaves protocol-47 alone — often **full line-rate** |
| `icmp` | IP-over-ICMP, blends in as ping (no key) | Only ICMP passes untouched — frequently unpoliced too |
| `udp`  | IP-over-UDP, XChaCha20-Poly1305, no header/handshake | UDP is allowed — usually the fastest of the encrypted carriers |
| `tcp`  | IP-over-TCP, one connection that looks like a long HTTPS session | UDP is blocked but a single TCP stream runs clean |
| `mux`  | **Multi-connection TCP** — N parallel links, each inner flow pinned to one link | Hostile DPI that blocks UDP *and* poisons long-lived TCP 5-tuples |
| `ws`   | **Multi-connection WebSocket** — real HTTP `Upgrade` handshake, AEAD payload inside masked WS frames | You need `mux`'s throughput but the carrier must be **indistinguishable from a browser/CDN WebSocket** on 443/80 |
| `hysteria` | **Hysteria2 / QUIC** — bundled engine with the loss-agnostic *Brutal* congestion control, salamander obfuscation and a real website masquerade | UDP passes but is **rate-policed or lossy**: Brutal ignores the induced loss and pushes at a fixed rate, so a policed UDP path that crawls at a few Mbit for `udp` runs an order of magnitude faster here — while looking exactly like HTTP/3 |
| `fou`  | **GRE-in-UDP** (Foo-over-UDP), native kernel tunnel (no key) — a GRE tunnel wrapped inside an ordinary UDP packet on a port you choose | You want GRE's near-line-rate speed but the ISP blocks raw protocol-47, or the carrier must **look like plain UDP** instead of a GRE tunnel |
| `vxlan` | **VXLAN**, native kernel tunnel (no key) — Ethernet-in-UDP, the standard datacenter overlay | A kernel UDP carrier that blends in as ordinary overlay traffic; useful where `fou`'s GRE-in-UDP is fingerprinted but VXLAN is not |
| `reverse-mux` | **ICMP echo-*reply* + single-flow MUX** (no key) — the icmp engine with the emitted echo type forced to reply, plus a chisel reverse tunnel that collapses every user connection into **one** flow | The relay→foreign **upload** is policed: many parallel connections get shredded (they collapse to a few Mbit) while a single sustained flow stays near line-rate. Also dodges paths that drop echo-*request* (type 8) in one direction but pass echo-*reply* (type 0) |

Many ISPs police only the *common* transports (TCP/UDP) and pass the "tunnel"
protocols — GRE (IP proto 47) and ICMP — at the link's real physical rate. On
one heavily-filtered Iran ISP tested, TCP/UDP were crushed to ~1 Mbit while
**GRE ran at ~650 Mbit and ICMP at ~350 Mbit** to the same foreign box. That is
exactly why you benchmark first and keep the winner. `gre`/`icmp` are plaintext
carriers (the inner proxy traffic is already encrypted); `udp`/`tcp`/`mux` add
their own XChaCha20-Poly1305.

The `mux` transport is the headline. On an ISP that blocks UDP and drops ~half
of new TCP handshakes, a naive single TCP tunnel melts down to a fraction of
the path. `mux` opens N links (each retried from a **fresh source port** until
one lands), spreads inner flows across them, and paces the aggregate just under
the raw rate so the links never overshoot — reaching **~90% of the raw path
speed** where a single tunnel managed under 15%.

All obfuscated transports are **unsignatured**: a random 24-byte nonce followed
by AEAD ciphertext, no magic bytes, no plaintext handshake — indistinguishable
from random traffic to a DPI box.

---

## Install

No compiler needed — the right static binary for your CPU (**amd64** or
**arm64**) ships with the project.

### Run this one line on your **Iran** server:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Free-Guy-IR/OmniTunnel/main/install.sh) && omnitunnel
```

That's it. You run it **only on the Iran side**. When you add a tunnel (or run
the benchmark), the manager asks for the foreign server's IP and SSH login and
then **installs and configures the foreign side for you automatically over
SSH** — deploys the matching binary for the foreign box's CPU, brings up the
server end, and enables it on boot. You never have to log into the foreign box
by hand.

> Prefer to set the foreign side up yourself? Just run the same one-liner there
> too — the tool is symmetric.

From a checkout instead of the one-liner:

```bash
git clone https://github.com/Free-Guy-IR/OmniTunnel
cd OmniTunnel && sudo ./install.sh && omnitunnel
```

---

## First run: benchmark & pick the best

From the main menu choose **“Benchmark all tunnels & pick the best.”** Point it
at a foreign server (IP + SSH login) and it will:

1. measure the **raw** path (download + rtt),
2. bring up each of the nine tunnels in turn and measure **download, packet
   loss and ping** through it,
3. print a comparison table,
4. **remove every test tunnel from both sides**, then let you keep exactly one
   as a permanent instance.

Real numbers, measured end-to-end through the manager on a fast Iran→foreign
route — an Iran server to a foreign box:

```
──────────────────────────  Benchmark results  ──────────────────────────

  raw path (plain TCP, policed)   down 1.91 Gbits/sec / up 850 Mbits/sec   rtt 39 ms

    TYPE                        DOWNLOAD UPLOAD   LOSS   PING  NOTE
  → gre          ██████████████ 925M     —        0%     39    fastest
    fou          █████████████  885M     —        0%     39    stealth pick
    tcp          ██████████     643M     —        0%     41
    vxlan        ████████       561M     —        0%     39
    ws           ████████       554M     —        0%     44
    mux          ████████       508M     —        0%     43
    udp          ███████        480M     —        0%     40
    icmp         ███████        439M     —        0%     40
    hysteria     ███            193M     —        0%     44
```

> This capture predates the UPLOAD column (added in 2.7.7), so its upload cells
> read `—`; a run on today's build fills both directions.

The bar is scaled to the fastest tunnel; **→** marks the outright winner and
**stealth pick** marks the fastest *fully obfuscated* transport. Here kernel `gre` leads at 925 Mbit and `fou` (GRE-in-UDP) sits right behind at
885 while looking like ordinary UDP on the wire — and the encrypted `tcp`, `ws`
and `mux` carriers all clear 500 Mbit on this path too. (This ISP polices neither
plain TCP nor arbitrary UDP; it only blocks the narrow WireGuard port range,
which `fou`/`vxlan`/`udp` sidestep.)

The winner is **link-specific**: where the ISP fingerprints GRE the encrypted
UDP carriers lead, where it rate-crushes UDP the plaintext `gre`/`icmp` do, and
on a lossy path `hysteria` does. Nothing wins everywhere — which is the whole
point of benchmarking: **run it on your own link and keep the winner.** Re-run it
from the menu any time conditions change.

> A real measurement taken end-to-end through the manager on one representative
> route; your own link will land differently — benchmark it and keep the winner.

### The other shape: a route that polices *upload*

Download-fast is not the whole story. On a hostile Iran→foreign path the
**relay→foreign upload** is often the policed direction, and it fails in a
specific way: **one** sustained flow runs near line-rate, but the moment real
users open many parallel connections the aggregate collapses. Measured on such a
route (relay → NL, `iperf3` through the tunnel):

| what was measured | upload |
|---|---|
| plain ICMP tunnel, single flow (`-P 1`, 20 s sustained) | **185 Mbit** — stable |
| plain ICMP tunnel, 8 parallel flows (`-P 8`) | **21.8 Mbit** — collapses |
| `reverse-mux` (same tunnel + single-flow MUX), `-P 8` | **226 Mbit** |
| `reverse-mux`, `-P 32` | **240 Mbit** |

Same link, same ICMP carrier — the only difference is that `reverse-mux` funnels
every connection into one flow, so the policer never sees the parallel burst it
punishes. On that route it is a **~10×** upload difference, which is why the
benchmark measures both directions rather than download alone.

On the very same path, raw ICMP echo-*request* (type 8) was **100 % dropped**
while echo-*reply* (type 0) passed untouched — the directional, type-specific
block `reverse-mux` is built to walk around.

---

## When the foreign box can't be reached over SSH

Some Iran ISPs block **outbound port 22** (and DNS to GitHub) entirely, so the
automatic "set up the far side over SSH" step can't run. Two built-in ways
around it — **neither touches any server's own SSH or port 22:**

**1. Manual mode (no SSH at all).** From the manage menu pick *“Add a tunnel —
MANUAL”*, or:

```bash
omnitunnel add-manual mux main <foreign_ip> 16 90mbit
```

It brings up the near (Iran) side and prints two lines to paste on the foreign
box (which abroad can reach GitHub fine):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Free-Guy-IR/OmniTunnel/main/install.sh)
omnitunnel server-token <token>
```

The `<token>` carries the key, port and addresses — the tunnel comes straight
up. No SSH between the two boxes is ever used.

**2. SOCKS5 proxy for provisioning.** If you already have a working SOCKS5 proxy
on the Iran box, the auto setup can tunnel its SSH/SCP through it (as the
original icmptun did) — save a peer with a proxy and the manager adds
`ProxyCommand=nc -X 5 -x host:port` to every provisioning connection.

> The tunnel always uses **its own port** (e.g. 51820), never 22. Installing or
> running OmniTunnel never changes any server's SSH login or SSH port.

---

## Topologies (many-to-many)

Each tunnel is an **instance** with its own tun device, systemd unit, subnet,
port and port-forward chain, so any shape works and instances never collide:

- **one Iran → many foreign** — add several instances on one box
- **many Iran → one foreign** — the foreign box hosts one server instance per
  Iran box
- **many → many** — any combination of the above

The manager auto-allocates a non-overlapping subnet and a free port for every
new instance, and (given an SSH login to the far side) brings up both ends.

---

## Port forwarding

Expose a port on one side and have it tunneled to the other:

```bash
omnitunnel pf-add <instance> both 443     # tcp+udp 443 -> peer over the tunnel
omnitunnel pf-add <instance> tcp  8080
omnitunnel pf-del <instance> 443
```

or use the **Port forwarding** menu.

---

## CLI (for scripting)

```bash
omnitunnel add                       # interactive add wizard
omnitunnel add-auto <type> <name> <foreign_ip> [nconn] [shape] [my_ip]
omnitunnel list
omnitunnel status  <instance>
omnitunnel remove  <instance>        # removes ONLY that instance (both-side safe)
omnitunnel pf-add  <instance> <tcp|udp|both> <port>
omnitunnel bench
omnitunnel update                    # pull the latest from GitHub (see below)
omnitunnel uninstall                 # remove every tunnel + all files, incl. itself
```

The core binary can also be driven directly:

```bash
omnitun mux -L <local-ip> -R <peer-ip> -A <local-tun-ip> -P <peer-tun-ip> \
            -p <port> -k <64-hex-key> -N 16 [-s] -T <dev> -M 1400
omnitun udp  ...     omnitun tcp  ...     omnitun icmp ...
```

`-s` marks the server (listening) side; the client omits it.

---

## Updating & removing

**Update.** Re-running the one-liner is the update path — it's idempotent and
version-aware:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Free-Guy-IR/OmniTunnel/main/install.sh) && omnitunnel
```

It detects the installed version, refreshes the manager and the core binaries,
and **only if the version actually changed** restarts the running tunnels so they
pick up the new core (an unchanged version touches nothing). Or do it from inside
the tool — main menu → **Update OmniTunnel** — or `omnitunnel update`. A box with
no direct GitHub egress is updated the same way you first set it up: re-push the
files from a box that can reach GitHub.

**Uninstall.** Main menu → **Uninstall**, or `omnitunnel uninstall`. It removes
every tunnel it created (including any leftover `bench-*`), their units, relays,
tun devices and iptables chains, the core binaries, all state under
`/etc/omnitunnel`, and finally its own files in `/opt/omnitunnel` and the
`omnitunnel` command. It never touches anything it didn't create.

---

## Architecture

- **One static core binary** (`omnitun`) — a busybox-style multi-call program
  that dispatches to `udp` / `tcp` / `mux` / `ws` / `icmp`. No shared-library
  dependencies: crypto is vendored ([Monocypher](https://monocypher.org),
  XChaCha20-Poly1305), so it builds and cross-compiles trivially and runs on
  any modern Linux kernel.
- **Bundled `hysteria` engine** — the `hysteria` transport is powered by the
  upstream [Hysteria2](https://github.com/apernet/hysteria) static binary,
  shipped in [`bin/`](bin/) for both CPUs. The manager generates its YAML
  (salamander obfs + website masquerade + self-signed TLS) and runs it under
  systemd. The engine keeps an always-on localhost SOCKS5, and each **TCP
  port-forward is a tiny standalone relay** that dials through that SOCKS5 as
  its own systemd unit — so adding or removing a forward starts/stops one relay
  and **never restarts the engine or disturbs the live QUIC session or other
  forwards** (UDP forwards are the one exception and still live in-config). No
  tun device or iptables DNAT is used for this type.
- Prebuilt for **amd64** and **arm64** under [`bin/`](bin/), also attached to
  each release.
- **`omnitunnel.sh`** — the English TUI manager: benchmark, instance
  add/remove/restart, port forwarding, systemd persistence, BBR + fq/tbf
  tuning, and automatic far-side provisioning over SSH.
- State lives under `/etc/omnitunnel` and never touches an existing
  `/etc/icmptun` install.

Build from source (any Linux with gcc):

```bash
cd src
gcc -O2 -Wall -o omnitun main.c obsctun.c obsctcp.c obscmux.c icmptun.c monocypher.c -lpthread -static
# arm64:
aarch64-linux-gnu-gcc -O2 -Wall -o omnitun-arm64 main.c obsctun.c obsctcp.c obscmux.c icmptun.c monocypher.c -lpthread -static
```

---

## Notes on performance

- Throughput is **per-route and time-variable**; benchmark on your own pair of
  servers, and re-benchmark whenever conditions change.
- No tunnel exceeds the raw path — obfuscation defeats *recognition/policing*,
  not physics. If the raw route to a given foreign datacenter is capped, pick a
  different foreign IP/datacenter.
- `mux` performs best with a shaper set a touch under the raw rate (the add
  wizard asks); use the sustainable, not the burst, path capacity.

---

## License

MIT — see [LICENSE](LICENSE).
