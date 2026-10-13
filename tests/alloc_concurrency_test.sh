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

eval "$(extract "alloc_and_create next_subnet_idx next_port alloc_port_span occupied_port_ranges remote_port_ranges type_port_span list_instances inst_conf inst_path inst_pf inst_exists validate_inst_name tok_re inst_name_ok create_inst gen_key type_uses_key port_base")"

fail() { echo "FAIL: $1" >&2; exit 1; }
die() { echo "DIE: $*" >&2; exit 1; }

D1="$(mktemp -d)"; D2="$(mktemp -d)"; D3="$(mktemp -d)"
trap 'rm -rf "$D1" "$D2" "$D3"' EXIT

dup_addrs() { grep -h '^TUN_ADDR=' "$INST_DIR"/*/instance.conf 2>/dev/null | sort | uniq -d; }
dup_ports() { grep -h '^PORT=' "$INST_DIR"/*/instance.conf 2>/dev/null | sort | uniq -d; }
inst_count() { ls -1 "$INST_DIR" 2>/dev/null | grep -c '^inst' ; }

N=8

unlocked_alloc_create() {
    local n="$1" t="$2" sub port key
    sub=$(next_subnet_idx)
    sleep 0.3
    port=$(next_port "$(( $(port_base "$t") + sub ))" "$t")
    key=$(gen_key); type_uses_key "$t" || key=""
    create_inst "$n" "$t" client 1.2.3.4 203.0.113.9 "$port" "$key" "10.201.$sub.1" "10.201.$sub.2" none 16 ""
}

INST_DIR="$D1"
for i in $(seq 0 $((N-1))); do ( unlocked_alloc_create "inst$i" tcp ) & done
wait
[[ "$(inst_count)" -eq "$N" ]] || fail "control: expected $N instances, got $(inst_count)"
[[ -n "$(dup_addrs)$(dup_ports)" ]] || fail "control: the unlocked allocator did NOT collide - the race is not being exercised, so the locked result would prove nothing"

INST_DIR="$D2"
for i in $(seq 0 $((N-1))); do ( alloc_and_create "inst$i" tcp client 1.2.3.4 203.0.113.9 none 16 "" ) & done
wait
[[ "$(inst_count)" -eq "$N" ]] || fail "locked: expected $N instances, got $(inst_count)"
d="$(dup_addrs)"; [[ -z "$d" ]] || fail "locked: two instances share a TUN_ADDR under concurrency: $d"
d="$(dup_ports)"; [[ -z "$d" ]] || fail "locked: two instances share a PORT under concurrency: $d"

INST_DIR="$D3"
WINS="$D3/.wins"; : > "$WINS"
for i in $(seq 0 $((N-1))); do ( alloc_and_create "samename" tcp client 1.2.3.4 203.0.113.9 none 16 "" >/dev/null 2>&1 && echo x >> "$WINS" ) & done
wait
w=$(grep -c x "$WINS" 2>/dev/null || true)
[[ "$w" -eq 1 ]] || fail "same-name: exactly one concurrent add must create the instance (the rest must die on the in-lock existence recheck); got $w"
na=$(grep -c '^TUN_ADDR=' "$D3/samename/instance.conf" 2>/dev/null || true)
[[ "$na" -eq 1 ]] || fail "same-name: surviving instance.conf has $na TUN_ADDR lines (clobbered by a concurrent create)"

echo "PASSED - without the flock $N concurrent adds collide on subnet/port; with alloc_and_create's flock all $N get a unique TUN_ADDR and PORT, and $N concurrent SAME-name adds leave exactly one intact instance"
