#!/usr/bin/env bash
set -u

SCRIPT="${1:-$(dirname "$0")/../omnitunnel.sh}"

extract() {
    awk -v names="$1" '
    BEGIN { n=split(names, a, " "); for (i=1;i<=n;i++) want[a[i]]=1 }
    inblock { print; if ($0 ~ /^}/) inblock=0; next }
    {
        if (match($0, /^[A-Za-z0-9_]+\(\)[ \t]*\{/)) {
            nm=$0; sub(/\(\).*/, "", nm)
            if (nm in want) { print; if ($0 !~ /\}/) inblock=1 }
        }
    }' "$SCRIPT"
}

eval "$(extract "tok_re inst_name_ok inst_path inst_conf inst_pf inst_exists load_inst dnat_chain type_is_hysteria norm_port pf_line_parse pf_entries with_pf_lock _pf_apply_all pf_apply_all ipt pf_fwd_apply pf_fwd_drop _pf_flush_chain pf_flush_chain")"

fail() { echo "FAIL: $1" >&2; exit 1; }
die() { echo "DIE: $*" >&2; exit 1; }
ok() { :; }
warn() { echo "$*" >> "$WARN_LOG"; }
info() { :; }
HY_CALLS=0
hy_pf_reconcile() { HY_CALLS=$((HY_CALLS + 1)); }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
INST_DIR="$WORK/inst"; mkdir -p "$INST_DIR"
RUN_DIR="$WORK/run"; mkdir -p "$RUN_DIR"
BIN="$WORK/bin"; mkdir -p "$BIN"
export IPT_DB="$WORK/ipt.db" IPT_LOG="$WORK/ipt.log" IPT_LOCK="$WORK/ipt.lock" IPT_TRACE="$WORK/ipt.trace"
WARN_LOG="$WORK/warn.log"; : > "$WARN_LOG"

cat > "$BIN/iptables" <<'FAKE'
#!/usr/bin/env python3
import fcntl, os, sys

args = sys.argv[1:]
table, action, chain, pos, spec, wait = "filter", None, None, None, [], False
i = 0
while i < len(args):
    a = args[i]
    if a == "-t":
        table = args[i + 1]; i += 2; continue
    if a == "-w":
        wait = True; i += 1
        if i < len(args) and args[i].isdigit():
            i += 1
        continue
    if action is None and a in ("-N", "-X", "-F", "-I", "-A", "-C", "-D", "-S", "-P"):
        action = a
        if i + 1 < len(args) and not args[i + 1].startswith("-"):
            chain = args[i + 1]; i += 2
            if action == "-I" and i < len(args) and args[i].isdigit():
                pos = int(args[i]); i += 1
            continue
        i += 1; continue
    spec.append(a); i += 1
with open(os.environ["IPT_LOG"], "a") as lg:
    lg.write(table + "\t" + action + "\t" + " ".join(args) + "\n")
key = " ".join(spec)
lock = open(os.environ["IPT_LOCK"], "a")
if wait:
    fcntl.flock(lock, fcntl.LOCK_EX)
else:
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        sys.stderr.write("Another app is currently holding the xtables lock.\n")
        sys.exit(4)
db = os.environ["IPT_DB"]
rows = [l.rstrip("\n").split("\t") for l in open(db)] if os.path.exists(db) else []
chains = {(r[0], r[1]) for r in rows if r[2] == ""}
builtin = {"INPUT", "FORWARD", "OUTPUT", "PREROUTING", "POSTROUTING"}
def save():
    with open(db + ".t", "w") as f:
        for r in rows:
            f.write("\t".join(r) + "\n")
    os.replace(db + ".t", db)
    if table == "filter" and chain and chain.startswith("TSUITE_"):
        n = sum(1 for r in rows if r[0] == "filter" and r[1] == chain and r[2] != "")
        with open(os.environ["IPT_TRACE"], "a") as t:
            t.write("%s %d\n" % (chain, n))
def exists(c):
    return c in builtin or (table, c) in chains
def referenced(c):
    return any(r[0] == table and r[2] and r[2].split()[-2:] == ["-j", c] for r in rows)
def in_chain():
    return [n for n, r in enumerate(rows) if r[0] == table and r[1] == chain and r[2] != ""]
rc = 0
if action == "-N":
    if exists(chain):
        rc = 1
    else:
        rows.append([table, chain, ""]); save()
elif action == "-X":
    if not exists(chain) or chain in builtin or referenced(chain) or in_chain():
        rc = 1
    else:
        rows = [r for r in rows if not (r[0] == table and r[1] == chain)]; save()
elif action == "-F":
    if not exists(chain):
        rc = 1
    else:
        rows = [r for r in rows if not (r[0] == table and r[1] == chain and r[2] != "")]; save()
elif action in ("-I", "-A"):
    if not exists(chain):
        rc = 1
    else:
        idx = in_chain()
        new = [table, chain, key]
        if action == "-A" or not idx:
            rows.append(new)
        else:
            p = (pos or 1) - 1
            rows.insert(idx[p] if p < len(idx) else idx[-1] + 1, new)
        save()
elif action == "-C":
    rc = 0 if [table, chain, key] in rows else 1
elif action == "-D":
    if len(spec) == 1 and spec[0].isdigit():
        idx = in_chain(); k = int(spec[0]) - 1
        if 0 <= k < len(idx):
            del rows[idx[k]]; save()
        else:
            rc = 1
    elif [table, chain, key] in rows:
        rows.remove([table, chain, key]); save()
    else:
        rc = 1
elif action == "-S":
    if chain is not None and not exists(chain):
        rc = 1
    else:
        for r in rows:
            if r[0] == table and (chain is None or r[1] == chain) and r[2] != "":
                print("-A %s %s" % (r[1], r[2]))
sys.exit(rc)
FAKE
chmod +x "$BIN/iptables"
PATH="$BIN:$PATH"

fwd() { iptables -w -S FORWARD; }
jumps() { fwd | grep -cxF -- "-A FORWARD -j $1"; }
line_of() { fwd | grep -nxF -- "-A FORWARD $1" | head -1 | cut -d: -f1; }
chain_rules() { iptables -w -S "$1" 2>/dev/null | grep -c "^-A $1 "; }
chain_has() { iptables -w -S "$1" 2>/dev/null | grep -qxF -- "-A $1 $2"; }
chain_exists() { iptables -w -S "$1" >/dev/null 2>&1; }
orig_rule() { printf -- '! -i %s -o %s -d %s -p %s --dport %s -m conntrack --ctstate DNAT --ctdir ORIGINAL --ctorigdstport %s -j ACCEPT' "$1" "$1" "$2" "$3" "$4" "$4"; }
repl_rule() { printf -- '-i %s -s %s -p %s --sport %s -m conntrack --ctstate DNAT --ctdir REPLY --ctorigdstport %s -j ACCEPT' "$1" "$2" "$3" "$4" "$4"; }
icmp_rule() { printf -- '%s %s -p icmp -m conntrack --ctstate RELATED --ctreplsrc %s -m conntrack --ctstate DNAT -j ACCEPT' "$1" "$2" "$3"; }
dump() { iptables -w -S | tr '\n' '|'; }
no_state() { [[ "$(jumps "$1")" == 0 ]] && ! chain_exists "$1"; }

mk_inst() {
    local n="$1" t="$2" dev="$3" peer="$4"; shift 4
    mkdir -p "$INST_DIR/$n"
    printf 'TYPE=%s\nROLE=client\nLOCAL_IP=192.0.2.10\nPEER_IP=198.51.100.20\nTUN_ADDR=10.201.40.1\nPEER_ADDR=%s\nPORT=51860\nKEY=\nDEV=%s\nMTU=1400\n' "$t" "$peer" "$dev" > "$INST_DIR/$n/instance.conf"
    : > "$INST_DIR/$n/pf.conf"
    if [[ $# -gt 0 ]]; then printf '%s\n' "$@" > "$INST_DIR/$n/pf.conf"; fi
}

seed() {
    : > "$IPT_DB"
    iptables -w -N DOCKER-USER
    iptables -w -A DOCKER-USER -j RETURN
    iptables -w -A FORWARD -j DOCKER-USER
    iptables -w -A FORWARD -j DOCKER-FORWARD
    iptables -w -A FORWARD -o eth9 -j ACCEPT
    : > "$IPT_LOG"; : > "$IPT_TRACE"; : > "$WARN_LOG"
}

mk_inst a gre ts-a 10.201.40.2 udp:443 tcp:8443
mk_inst b udp ts-b 10.201.41.2 udp:5000
mk_inst h hysteria ts-h 10.201.42.2 tcp:9000
mk_inst e gre ts-e 10.201.43.2
mk_inst m gre ts-m 10.201.44.2
rm -f "$INST_DIR/m/pf.conf"

seed
pf_apply_all a
[[ "$(jumps TSUITE_A)" == 1 ]] || fail "apply did not add exactly one FORWARD jump to the instance chain: $(dump)"
[[ "$(line_of "-j TSUITE_A")" -gt "$(line_of "-o eth9 -j ACCEPT")" && "$(line_of "-j TSUITE_A")" -gt "$(line_of "-j DOCKER-USER")" ]] || fail "the instance jump must be appended after existing FORWARD rules so admin rules keep precedence: $(dump)"
[[ "$(chain_rules TSUITE_A)" == 6 ]] || fail "want exactly 6 rules (2 per forward + 2 related icmp), got $(chain_rules TSUITE_A): $(dump)"
chain_has TSUITE_A "$(orig_rule ts-a 10.201.40.2 udp 443)" || fail "missing the original-direction accept for udp 443: $(dump)"
chain_has TSUITE_A "$(repl_rule ts-a 10.201.40.2 udp 443)" || fail "missing the reply-direction accept for udp 443: $(dump)"
chain_has TSUITE_A "$(orig_rule ts-a 10.201.40.2 tcp 8443)" || fail "missing the original-direction accept for tcp 8443: $(dump)"
chain_has TSUITE_A "$(repl_rule ts-a 10.201.40.2 tcp 8443)" || fail "missing the reply-direction accept for tcp 8443: $(dump)"
chain_has TSUITE_A "$(icmp_rule -o ts-a 10.201.40.2)" || fail "missing the related icmp accept toward the peer: $(dump)"
chain_has TSUITE_A "$(icmp_rule -i ts-a 10.201.40.2)" || fail "missing the related icmp accept from the peer: $(dump)"
fwd | grep -q 'ts-a' && fail "a broad FORWARD accept names the tunnel device directly: $(dump)"
if grep -vqE '(^|[[:space:]])-w([[:space:]]|$)' "$IPT_LOG"; then
    fail "an iptables call (nat or filter) ran without waiting for the xtables lock: $(grep -vE -- '-w' "$IPT_LOG" | head -3 | tr '\n' '|')"
fi
[[ ! -s "$WARN_LOG" ]] || fail "a clean apply warned: $(cat "$WARN_LOG")"

: > "$IPT_TRACE"
pf_apply_all a
[[ "$(jumps TSUITE_A)" == 1 && "$(chain_rules TSUITE_A)" == 6 ]] || fail "re-apply duplicated the jump or the rules: $(dump)"
grep -qx 'TSUITE_A 0' "$IPT_TRACE" && fail "re-apply left the accept chain empty for a moment (live flows would hit the DROP policy): $(tr '\n' ' ' < "$IPT_TRACE")"

printf 'udp:443\n' > "$INST_DIR/a/pf.conf"
pf_apply_all a
[[ "$(chain_rules TSUITE_A)" == 4 ]] || fail "removing a forward did not drop its accept rules: $(dump)"
chain_has TSUITE_A "$(orig_rule ts-a 10.201.40.2 tcp 8443)" && fail "accept for a removed forward survived"
: > "$INST_DIR/a/pf.conf"
pf_apply_all a
no_state TSUITE_A || fail "an instance whose last forward was removed kept its filter chain or jump: $(dump)"
printf 'udp:443\ntcp:8443\n' > "$INST_DIR/a/pf.conf"
pf_apply_all a

HY_CALLS=0
pf_apply_all h
[[ "$HY_CALLS" == 1 ]] || fail "hysteria apply did not go through hy_pf_reconcile"
no_state TSUITE_H || fail "hysteria instance got filter state"
pf_apply_all e
no_state TSUITE_E || fail "instance with an empty pf.conf got filter state"
pf_apply_all m
no_state TSUITE_M || fail "instance without pf.conf got filter state"

pf_apply_all b
iptables -w -I FORWARD 1 -j TSUITE_A
iptables -w -A FORWARD -j TSUITE_A
pf_flush_chain a
no_state TSUITE_A || fail "flush left FORWARD jumps or the filter chain for a: $(dump)"
[[ "$(jumps TSUITE_B)" == 1 && "$(chain_rules TSUITE_B)" == 4 ]] || fail "flush of a touched b: $(dump)"
[[ "$(jumps DOCKER-USER)" == 1 && "$(jumps DOCKER-FORWARD)" == 1 && "$(fwd | grep -cxF -- '-A FORWARD -o eth9 -j ACCEPT')" == 1 ]] || fail "flush touched Docker or unrelated rules: $(dump)"

seed
iptables -w -A FORWARD -j DROP
pf_apply_all a
grep -q 'unconditional DROP/REJECT above' "$WARN_LOG" || fail "no warning when an unconditional DROP sits above the instance jump"
pf_flush_chain a

seed
pf_apply_all b
for _ in $(seq 1 20); do
    ( pf_apply_all b ) & q1=$!
    ( pf_apply_all b ) & q2=$!
    wait "$q1" "$q2"
    [[ "$(jumps TSUITE_B)" == 1 && "$(chain_rules TSUITE_B)" == 4 ]] || fail "concurrent apply/apply on one instance corrupted its chain: $(dump)"
done
for _ in $(seq 1 20); do
    ( pf_apply_all a ) & p1=$!
    ( pf_apply_all b ) & p2=$!
    ( pf_flush_chain a ) & p3=$!
    wait "$p1" "$p2" "$p3"
done
[[ "$(jumps TSUITE_B)" == 1 && "$(chain_rules TSUITE_B)" == 4 ]] || fail "interleaving broke b (want 1 jump, 4 rules): $(dump)"
pf_flush_chain a
no_state TSUITE_A || fail "a final flush did not clear a after the interleaving: $(dump)"
[[ "$(jumps DOCKER-USER)" == 1 && "$(fwd | grep -cxF -- '-A FORWARD -o eth9 -j ACCEPT')" == 1 ]] || fail "interleaving touched Docker or unrelated rules"
iptables -w -t nat -S | grep -q -- '-A TSUITE_B ' || fail "interleaving lost b's nat rules"

echo "PASSED - pf_forward_accept_test: per-instance FORWARD chain appended after admin rules, exact per-forward original/reply accepts bound to the original port, related icmp, no broad device accept, gap-free idempotent rebuild, follows pf-del down to no state, every call lock-bounded, warns on an unconditional DROP above it, nothing for hysteria or an empty forward set, exact teardown, 20-round interleaving"
