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

eval "$(extract "auto_name alloc_and_create next_subnet_idx next_port alloc_port_span occupied_port_ranges remote_port_ranges type_port_span list_instances inst_conf inst_path inst_pf inst_exists validate_inst_name tok_re inst_name_ok create_inst gen_key type_uses_key port_base")"

fail() { echo "FAIL: $1" >&2; exit 1; }
die() { echo "DIE: $*" >&2; exit 1; }

D1="$(mktemp -d)"; D2="$(mktemp -d)"
trap 'rm -rf "$D1" "$D2"' EXIT

dup_addrs() { grep -h '^TUN_ADDR=' "$INST_DIR"/*/instance.conf 2>/dev/null | sort | uniq -d; }
dup_ports() { grep -h '^PORT=' "$INST_DIR"/*/instance.conf 2>/dev/null | sort | uniq -d; }

N=8
BASE=ackless
T=ackless

unlocked_auto_create() {
    local base="$1" t="$2" n sub port key
    n="$(auto_name "$base")"
    sleep 0.3
    sub=$(next_subnet_idx)
    port=$(next_port "$(( $(port_base "$t") + sub ))" "$t")
    key=$(gen_key); type_uses_key "$t" || key=""
    create_inst "$n" "$t" client 1.2.3.4 203.0.113.9 "$port" "$key" "10.201.$sub.1" "10.201.$sub.2" none 16 ""
}

INST_DIR="$D1"
for i in $(seq 0 $((N-1))); do ( unlocked_auto_create "$BASE" "$T" ) & done
wait
names1=$(ls -1 "$INST_DIR" 2>/dev/null | grep -c "^$BASE")
[[ "$names1" -lt "$N" ]] || fail "control: picking the auto-name OUTSIDE the lock did NOT collide (got $names1 distinct of $N) - the race is not being exercised, so the locked result would prove nothing"

INST_DIR="$D2"
WINS="$D2/.wins"; : > "$WINS"
for i in $(seq 0 $((N-1))); do ( alloc_and_create "$BASE" "$T" client 1.2.3.4 203.0.113.9 none 16 "" "" "auto" >/dev/null 2>&1 && echo "$ALLOC_NAME" >> "$WINS" ) & done
wait

w=$(grep -c . "$WINS" 2>/dev/null || true)
[[ "$w" -eq "$N" ]] || fail "locked-auto: all $N concurrent auto-adds must succeed with no 'instance exists' death; got $w"
distinct=$(sort -u "$WINS" | grep -c . || true)
[[ "$distinct" -eq "$N" ]] || fail "locked-auto: the $N auto-names must be DISTINCT; got $distinct unique"
cnt=$(ls -1 "$INST_DIR" 2>/dev/null | grep -c "^$BASE" || true)
[[ "$cnt" -eq "$N" ]] || fail "locked-auto: expected $N ${BASE}* instances on disk, got $cnt"
d="$(dup_addrs)"; [[ -z "$d" ]] || fail "locked-auto: two instances share a TUN_ADDR under concurrency: $d"
d="$(dup_ports)"; [[ -z "$d" ]] || fail "locked-auto: two instances share a PORT under concurrency: $d"

exp="$( { echo "$BASE"; for i in $(seq 1 $((N-1))); do echo "$BASE$i"; done; } | sort )"
got="$(sort -u "$WINS")"
[[ "$exp" == "$got" ]] || fail "locked-auto: auto-name set mismatch; got [$(echo $got)] want [$(echo $exp)]"

echo "PASSED - without the flock $N concurrent auto-adds all resolve '$BASE' and collide; with alloc_and_create's in-lock auto_name they get $N DISTINCT names ($BASE, ${BASE}1 … ${BASE}$((N-1))), all succeed, zero dup subnet/port"
