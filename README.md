<p align="center">
  <img src="assets/preview.png" alt="OmniTunnel TUI" width="420">
</p>

# OmniTunnel

**A multi-protocol, obfuscated tunnel suite for bypassing per-destination
traffic policing and DPI.** Prebuilt static binaries, one English
menu-driven manager, twelve interchangeable tunnel transports, and any
many-to-many topology you need.

Built and hardened against real Iran ⇄ abroad conditions, where different ISPs
police, throttle, or block traffic very differently depending on the transport
and the destination datacenter. (Formerly the ICMP-only `icmptun` project —
ICMP is now just one of the twelve transports.)

---

## Why twelve transports?

No single tunnel wins everywhere. What an ISP lets through — and how fast — is
**per-route and per-transport**, and it changes. OmniTunnel ships all twelve and
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
| `stripe` | **Connection-striping TCP** — shards one flow across many fresh, short-lived connections so no single 5-tuple is ever kept alive long enough to be capped | The ISP **byte-caps each 5-tuple** (e.g. ~8760 B, then the connection is silently blackholed): a single long-lived TCP stream dies after a few KB, so `stripe` keeps spreading the flow over a rolling pool of brand-new connections and no one of them reaches the cap |
| `ackless` | **ACK-less raw-TCP carrier** — data-only `flags=0` raw-TCP segments spread across up to `-Fmax` (default 6) concurrent flows, each inner packet pinned to one flow by a 5-tuple hash, with an app-level ARQ (selective NACK/ACK) instead of the kernel's per-packet ACKs | The ISP **caps packets-per-5-tuple** rather than bytes: a normal TCP stream's ACK/retransmit chatter burns the packet budget, so `ackless` sends only data-bearing segments (and spreads them over several flows) and recovers loss itself |

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

### Near-zero-config: a working tunnel in one more command

You do not have to be an expert. On a fresh Iran box run the one-liner above,
then bring a tunnel up with a single command — the only thing you supply is the
**transport and the foreign IP**:

```bash
omnitunnel add-auto ackless <foreign-ip>        # far side set up for you over SSH
```

If your ISP blocks outbound SSH to the foreign, use the manual path instead —
still just transport + foreign IP, plus pasting two lines on the far side:

```bash
omnitunnel add-manual ackless <foreign-ip>      # prints two lines to paste abroad
```

Either way the manager auto-generates the pre-shared key and allocates the
subnet, port, tun device and MTU, so no other input is needed. The instance name
is derived automatically (`ackless`, then `ackless1`, …) when you omit it.

---

## First run: benchmark & pick the best

From the main menu choose **“Benchmark all tunnels & pick the best.”** Point it
at a foreign server (IP + SSH login) and it will:

1. measure the **raw** path (download, upload + rtt),
2. bring up each of the twelve tunnels in turn and measure **download, upload,
   packet loss and ping** through it,
3. print a comparison table,
4. **remove every test tunnel from both sides**, then let you keep exactly one
   as a permanent instance.

Real numbers, measured end-to-end through the manager on a fast Iran→foreign
route — an Iran server to a foreign box:

```
────────────────────────  Benchmark results  ────────────────────────

  raw path (plain TCP, policed)   down 228 Mbits/sec / up 77.7 Mbits/sec   rtt 83 ms

    TYPE                        DOWNLOAD UPLOAD   LOSS   PING  NOTE
  → gre          ██████████████ 700M     FAIL     0%     71    fastest
    fou          █████████████  641M     4.62M    0%     78    stealth pick
    icmp         ████████████  624M     395M     0%     84
    vxlan        ███████████   562M     120M     0%     77
    mux          ███████████   539M     99.2M    0%     70
    udp          ███████████   532M     81.7M    0%     77
    ws           ██████        300M     79.2M    0%     79
    reverse-mux  █████         233M     FAIL     0%     83
    hysteria     ████          198M     FAIL     0%     83
    tcp          █             69.6M    99.5M    0%     81
    stripe       —             —         —         —        —     not in this run (real-path figures below)
    ackless      ████████████  622M     597M     0%     1     lab (netns, not real-path)
```

The `gre`…`tcp` rows were measured 10 September 2026, one Iran relay to one
foreign box, every transport built and torn down in sequence by `omnitunnel
bench` itself. The `ackless` row (622/597 Mbit, 0% loss) is an **interim lab
figure** measured on a single disposable host over a `netns`+`veth` loopback with
`tc-netem` on a clean profile — it is a *relative* sanity measurement, **not a
real Iran→foreign throughput** and not directly comparable to the real rows
above. `stripe` was not part of that run. Real Iran→foreign numbers for both
`ackless` and `stripe`, measured later on three differently policed paths, are in
[the byte-cap section below](#the-third-shape-a-route-that-byte-caps-every-connection).

The bar is scaled to the fastest tunnel; **→** marks the outright winner and
**stealth pick** marks the fastest *fully obfuscated* transport. Read the two
columns against each other: kernel `gre` takes the download at 700 Mbit but
returns **nothing** upstream, and `fou` pairs 641 down with a collapsed 4.62 up.
The only transport that carries both directions here is `icmp` — 624 down and
**395 up, roughly five times the 77.7 Mbit the raw path itself managed**. A
download-only ranking would have picked exactly the wrong tunnel on this link.

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

### The third shape: a route that byte-caps every connection

A newer failure mode some ISPs apply is a **per-5-tuple byte cap**: each
connection is allowed to carry a fixed budget (observed around **~8760 B**) and
is then silently blackholed — no RST, the flow just stops. Every long-lived
carrier (`tcp`, `mux`, `ws`, even the kernel tunnels) dies after that first
budget, because each of their connections is meant to live for the whole
session. `stripe` is the transport for exactly this path: it shards the flow
across a rolling pool of short-lived connections and retires each one well
before it reaches the cap, so the policer never has a long-lived 5-tuple to
punish.

| what was measured | result |
|---|---|
| `stripe`, local network-namespace loopback proof, download-only | **126 Mbit** |
| `stripe`, local netns, bidirectional | **stable** (no stall, no collapse) |
| `stripe` before tuning (v2.9.11 launch flags), real heavily policed Iran→foreign path | **1.22 Mbit** down, upload failing, ~330 ms tunnel RTT |
| `stripe` tuned (v2.9.12), same path | **57–163 Mbit** down / **42–83 Mbit** up, **0 % loss**, ~120 ms tunnel RTT |

The netns rows are a local functional proof only. The last two rows are the real
path, before and after the v2.9.12 tuning: 16 independent reliability lanes
(each inner flow is hashed by its 5-tuple onto one lane, so a loss on one flow
no longer head-of-line-blocks the flows on the other lanes), at least 512
connection workers, an
in-flight window of 2×N, a 1500 ms dial/I/O timeout so policed or dead
connections are abandoned quickly instead of stalling the worker pool, TCP Fast
Open, and a client retransmit backstop derived from that timeout instead of a
fixed 10 s. The frame authentication (HMAC-SHA256) and the anti-replay window
are unchanged.

#### Same day, three paths

The same transports measured on the same day from Iran to three differently
policed foreign paths (download / upload, Mbit/s):

| path | `ackless` | `stripe` | everything else |
|---|---|---|---|
| **A** — heavily policed | 107 / 61 | **57–163 / 42–83** (tuned) | every other transport failed |
| **B** — heavily policed | **538 / 391** | 3.49 down (before tuning) | every other transport failed |
| **C** — lightly policed | failed | 22 / 18 (before tuning) | `reverse-mux` **102 / 61**, `hysteria` 86 / 73, `gre` 76 / 77 |

The `stripe` figures on paths B and C predate the tuning and have not been
re-measured since. The lesson is the same one the headline benchmark teaches:
**transport choice is path-dependent.** On A only the two short-flow carriers
moved traffic at all, on B `ackless` led by a wide margin, and on the lightly
policed C the classic carriers won while `ackless` never came up. Benchmark your
own path and keep the winner.

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

The `<token>` carries the key, port and addresses (and, for `stripe`, the lane
count, so both ends agree) — the tunnel comes straight up. No SSH between the two
boxes is ever used.

**2. SOCKS5 proxy for provisioning.** If you already have a working SOCKS5 proxy
on the Iran box, the auto setup can tunnel its SSH/SCP through it (as the
original icmptun did) — save a peer with a proxy and the manager adds
`ProxyCommand=nc -X 5 -x host:port` to every provisioning connection.

> The tunnel always uses **its own port** (e.g. 51820), never 22. Installing or
> running OmniTunnel never changes any server's SSH login or SSH port.

### Foreign SSH host keys are pinned

The auto setup, the SSH benchmark and `remove` reach the foreign server over
SSH/SCP. OmniTunnel keeps its own `known_hosts` for that at
`/etc/omnitunnel/ssh/known_hosts` (root only, mode 0600). The first connection to
a foreign records its host key; every later connection, direct or through the
SOCKS5 proxy, must present the same key. If the key changes, ssh refuses before
logging in, so neither the saved password nor any command reaches that server,
and OmniTunnel stops with a message that names the server and shows the
fingerprint it now presents.

A reinstalled server legitimately gets a new key. Compare that fingerprint with
the one on the server's own console (`ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`)
and, only if they match, forget the old key (CLI below, or *Manage tunnels → 6*)
and retry. Add the SSH port when the foreign's SSH does not listen on 22:

```bash
omnitunnel forget-host 1.2.3.4
omnitunnel forget-host 1.2.3.4 2222
```

The next connection pins whatever key the server then presents. With OpenSSH
older than 7.6 (no `accept-new`), an unknown server is recorded on first contact
and a pinned one is checked strictly, so a changed key is refused the same way.
After upgrading from an older OmniTunnel, the first connection to each existing
foreign pins its current key.

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
omnitunnel add-auto <type> [name] <foreign_ip> [nconn] [shape] [my_ip]
omnitunnel add-manual <type> [name] <foreign_ip> [nconn] [shape] [my_ip]
omnitunnel server-token <token>      # paste on the foreign for the manual path
omnitunnel list
omnitunnel status  <instance>
omnitunnel remove  <instance>        # removes ONLY that instance (both-side safe)
omnitunnel pf-add  <instance> <tcp|udp|both> <port>
omnitunnel forget-host <foreign_ip> [ssh_port]
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

### Creating a `stripe` tunnel

`stripe` is created the same way as any other transport — pick it in the
interactive wizard or name it on the CLI:

```bash
omnitunnel add
omnitunnel add-auto stripe main <foreign-ip> [N]
omnitunnel add-manual stripe main <foreign-ip> [N]
```

The wizard asks only for the number of **striping connection workers N**
(default 90; the manager always runs at least 512); subnet, port, the
port-count pool and the lane count are allocated for you. It is
provisioned with a generated pre-shared key that authenticates the stripe frames
(the inner proxy traffic is separately encrypted) and, like every other
transport, never touches the box's own SSH or port 22.

**Lanes and upgrading.** Both ends of a `stripe` tunnel must run the same lane
count: a receiver drops every frame that names a lane it does not have. So the
lane count is fixed when a tunnel is created and is always given to both ends at
once:

- **New tunnels (v2.9.12+) run 16 lanes on both ends.** `add`, `add-auto` and
  keeping `stripe` from the SSH benchmark push this same manager to the foreign
  over SSH, create its side with the same lane count and then check that the
  foreign recorded it; if it did not, the foreign side is removed and the add
  stops before this side comes up. `add-manual` carries it
  to the foreign inside the `server-token` (a 12th `|lanes` field that only
  `stripe` tokens have; tokens for every other type are unchanged). The
  benchmark's own throw-away `stripe` test tunnel runs 1 lane on both ends.
- **Existing tunnels keep 1 lane on both ends**, whichever side is updated
  first: their `instance.conf` records no lane count and both the manager and
  `omnistripe` default to 1. They still gain the rest of the tuning (≥512
  workers, window 2×N, 1500 ms timeout, TCP Fast Open) once their unit is
  regenerated, e.g. with `omnitunnel enable <name>` on each end. To move one to
  16 lanes, re-create it with both ends on v2.9.12 or newer.
- **Override:** set `STRIPE_LANES` (an integer 1–64) on the creating (Iran) side,
  e.g. `STRIPE_LANES=8 omnitunnel add-auto stripe main <foreign-ip>`; any other
  value is refused. The foreign side follows automatically (over SSH, or via the
  token in manual mode).
- A foreign still on v2.9.11 or older cannot read a 12-field `stripe` token: it
  stops with an error while loading the new instance (its shell reports
  `16: command not found`) and no service is created, instead of bringing the
  tunnel up. Run the install line the
  manual flow prints before `server-token`, then re-run the same token.
- **Tokens are strictly validated (v2.9.12+).** `server-token`, `mux-token` and
  `bench-server` check every field against the exact format the manager itself
  produces (instance name, known type, address charset, IPv4 tunnel addresses,
  port and connection-count ranges, 64-hex keys, shaper rate, ICMP mode, lane
  count, `port:host:port` forwards) and refuse the whole token before anything
  is installed, written or started.

Unlike the other transports `stripe` runs on its **own static engine**
(`omnistripe`, a separate Go binary in [`bin/`](bin/)), so it is driven directly
through that binary rather than through `omnitun`:

```bash
omnistripe -L <local-ip> -R <peer-ip> -A <local-tun-ip> -P <peer-tun-ip> -k <key> \
           -p 40000 -C 400 -N 512 -lanes 16 -w 1024 -to 1500 -F -T tsstripe0 -M 1400 [-s]
```

That is the line the manager writes for a new tunnel with the default N; a
tunnel created before v2.9.12 gets `-lanes 1` instead.

Flags:

| flag | meaning | default |
|------|---------|---------|
| `-L` | local source/bind IP | — |
| `-R` | peer IP the client dials | — |
| `-A` | this box's tun address | — |
| `-P` | peer's tun address | — |
| `-k` | pre-shared key authenticating the stripe frames (required; the manager generates and provisions it) | — |
| `-p` | base destination port of the striped pool | `40000` |
| `-C` | number of destination ports in the pool | `400` |
| `-N` | connection (striping) workers; the client splits them across the lanes | `90`; the manager passes the instance's N raised to at least `512` |
| `-lanes` | independent per-flow reliability lanes; **must be equal on both ends** | `1`; the manager passes the instance's lane count (`16` for tunnels created by v2.9.12+, `1` for older ones) |
| `-w` | in-flight window, total across lanes (each lane gets `w / lanes`, clamped to 32–512) | `400`; the manager passes `2 × N` |
| `-to` | dial / I/O timeout in ms; the client's retransmit backstop is twice this, at least 500 ms | `5000`; the manager passes `1500` |
| `-F` | enable TCP Fast Open | off; the manager passes it |
| `-dl` | download-side pool size | `0` (derive from `-N`) |
| `-T` | tun device name | `tsstripe0` |
| `-M` | tun MTU | `1400` |
| `-s` | run as the server (listener) side; the client omits it | off |
| `-u` | client→server chunk bytes | `6600` |
| `-d` | server→client chunk bytes | `6600` |

`-u`/`-d` set how much data each striped connection carries before it is
retired. They are **hard-capped at 6660 bytes** (an on-wire ceiling of 6800 B,
five segments at a 1360-byte MSS floor, minus the 140-byte frame header); any
larger value is clamped down to 6660, so no single connection ever outlives a
~8760 B per-5-tuple byte cap.

### Creating an `ackless` tunnel

`ackless` is the transport for a path that **caps packets-per-5-tuple** rather
than bytes. It carries data-only `flags=0` raw-TCP segments — no SYN/ACK/
retransmit chatter to burn the packet budget — and recovers loss itself with an
app-level ARQ (selective NACK/ACK). It spreads those segments across up to
`-Fmax` (default 6) concurrent ACK-less flows, pinning each inner packet to one
flow by a 5-tuple hash. Where `stripe` spreads a flow over short-lived
connections to dodge a per-5-tuple **byte** cap, `ackless` strips the per-packet
ACK overhead (and uses a handful of flows) to dodge a per-5-tuple **packet** cap.

Bring it up like any other transport — the only input is the foreign IP; the
name is auto-derived and the key/subnet/port/device/MTU are allocated for you:

```bash
omnitunnel add                               # interactive wizard, pick ackless
omnitunnel add-auto ackless <foreign-ip>     # name auto-derived; far side over SSH
omnitunnel add-manual ackless <foreign-ip>   # no SSH; prints two lines to paste abroad
```

The manual path prints the two lines to run on the foreign box:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Free-Guy-IR/OmniTunnel/main/install.sh)
omnitunnel server-token <token>
```

Like `stripe`, `ackless` runs on its **own static engine** (`omniackless`, a
separate Go binary in [`bin/`](bin/)), so it can also be driven directly:

```bash
omniackless -L <local-ip> -R <peer-ip> -A <local-tun-ip> -P <peer-tun-ip> \
            -p 49000 -T tsackless0 -M 1400 -k <key> [-s]
```

Flags:

| flag | meaning | default |
|------|---------|---------|
| `-L` | local source/bind IP | — |
| `-R` | peer IP the client dials | — |
| `-A` | this box's tun address | — |
| `-P` | peer's tun address | — |
| `-k` | pre-shared key authenticating the carrier (the manager generates and provisions it) | — |
| `-p` | base port | `49000` |
| `-T` | tun device name | `tsackless0` |
| `-M` | tun MTU | `1400` |
| `-s` | run as the server (listener) side; the client omits it | off |
| `-Fmax` | number of concurrent ACK-less flows the carrier runs; inner packets are hashed across them | `6` |
| `-F` / `-Fmin` / `-auto` | initial / minimum flow count and the adaptive-scaling toggle — accepted for forward compatibility, but this build runs the full `-Fmax` set | `2` / `1` / `true` |

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
- **Bundled `omnistripe` engine** — the `stripe` transport is powered by its own
  self-contained static Go binary ([`src/omnistripe`](src/omnistripe)), shipped
  in [`bin/`](bin/) for both CPUs as `omnistripe-amd64` / `omnistripe-arm64`. It
  owns a `tsstripe*` tun device and shards the inner flow across a rolling pool
  of short-lived TCP connections (base port `-p`, `-C` ports wide), each retired
  before it reaches the per-5-tuple byte cap. Like the C core it needs no shared
  libraries and cross-compiles trivially.
- **Bundled `omniackless` engine** — the `ackless` transport is powered by its
  own self-contained static Go binary ([`src/omniackless`](src/omniackless)),
  shipped in [`bin/`](bin/) for both CPUs as `omniackless-amd64` /
  `omniackless-arm64`. It owns a `tsackless*` tun device and carries data-only
  `flags=0` raw-TCP segments across up to `-Fmax` (default 6) concurrent flows
  with an app-level ARQ, self-managing its raw sockets and the `nft` rules that
  suppress the kernel's RST/ACK for those flows (set up on start, torn down on
  exit). Like the C core it needs no shared libraries and cross-compiles trivially.
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
