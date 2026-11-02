#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2317
set -u

SCRIPT="${1:-$(dirname "$0")/../omnitunnel.sh}"
ROUNDS="${PF_ILV_ROUNDS:-3}"

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

eval "$(extract "tok_re inst_name_ok list_instances inst_path inst_conf inst_pf inst_exists load_inst type_is_hysteria dnat_chain norm_port rewrite_without pf_line_parse pf_line_fmt pf_entries pf_spec_parse with_pf_lock ipt pf_fwd_apply pf_fwd_drop _pf_flush_chain _pf_apply_all _pf_add _pf_del pf_log pf_backup pf_write pf_apply_all pf_add pf_del cmd_pf_del cmd_postup")"

FAILS=0
bad() { echo "FAIL: $*"; FAILS=$((FAILS+1)); }
need_root() { :; }
ok() { :; }
info() { :; }
warn() { :; }
die() { echo "DIE: $*" >&2; exit 1; }
logger() { :; }
apply_tuning() { :; }
pf_warn_conflicts() { :; }
iptables() {
    local op="" ch="" proto="" dport="" sport="" orig="" dir="" to="" tgt="" tab=filter i rc=0 mfd
    local args=("$@")
    for ((i = 0; i < ${#args[@]}; i++)); do
        case "${args[i]}" in
            -t) tab="${args[i+1]}";;
            -N|-F|-A|-C|-I|-D|-X|-S) op="${args[i]}"; ch="${args[i+1]:-}";;
            -p) proto="${args[i+1]}";;
            --dport) dport="${args[i+1]}";;
            --sport) sport="${args[i+1]}";;
            --ctorigdstport) orig="${args[i+1]}";;
            --ctdir) dir="${args[i+1]}";;
            --to-destination) to="${args[i+1]}";;
            -j) tgt="${args[i+1]}";;
        esac
    done
    sleep "0.00$((RANDOM % 6))"
    if [[ "$tab" == nat ]]; then
        case "$op" in
            -N) [[ -e "$NAT/$ch" ]] && return 1; : >> "$NAT/$ch";;
            -F) : > "$NAT/$ch";;
            -A) [[ "$ch" == TSUITE_* ]] && printf '%s %s %s\n' "$proto" "$dport" "$to" >> "$NAT/$ch";;
        esac
        return 0
    fi
    exec {mfd}>>"$FLT/.xtables.lock"; flock "$mfd"
    case "$op$ch" in
        -AFORWARD) printf '%s\n' "$tgt" >> "$FLT/FORWARD";;
        -CFORWARD) grep -qxF -- "$tgt" "$FLT/FORWARD" 2>/dev/null || rc=1;;
        -DFORWARD)
            if grep -qxF -- "$tgt" "$FLT/FORWARD" 2>/dev/null; then
                awk -v t="$tgt" '!d && $0 == t { d = 1; next } 1' "$FLT/FORWARD" > "$FLT/FORWARD.t"; mv -f "$FLT/FORWARD.t" "$FLT/FORWARD"
            else rc=1; fi;;
        -SFORWARD) sed 's/^/-A FORWARD -j /' "$FLT/FORWARD" 2>/dev/null;;
        -NTSUITE_*) if [[ -e "$FLT/$ch" ]]; then rc=1; else : > "$FLT/$ch"; fi;;
        -ATSUITE_*)
            if [[ ! -e "$FLT/$ch" ]]; then rc=1
            elif [[ "$proto" == icmp ]]; then echo icmp >> "$FLT/$ch"
            else printf '%s %s %s %s\n' "$proto" "${dport:-$sport}" "$orig" "$dir" >> "$FLT/$ch"; fi;;
        -DTSUITE_*) if [[ -s "$FLT/$ch" ]]; then sed -i '1d' "$FLT/$ch"; else rc=1; fi;;
        -STSUITE_*) if [[ -e "$FLT/$ch" ]]; then sed "s/^/-A $ch /" "$FLT/$ch"; else rc=1; fi;;
        -FTSUITE_*) if [[ -e "$FLT/$ch" ]]; then : > "$FLT/$ch"; else rc=1; fi;;
        -XTSUITE_*) if [[ -e "$FLT/$ch" ]]; then rm -f "$FLT/$ch"; else rc=1; fi;;
    esac
    exec {mfd}>&-
    return "$rc"
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mk_inst() {
    mkdir -p "$INST_DIR/$1"
    printf 'TYPE=gre\nROLE=client\nLOCAL_IP=1.2.3.4\nPEER_IP=203.0.113.9\nTUN_ADDR=10.201.%s.1\nPEER_ADDR=10.201.%s.2\nPORT=51820\nKEY=\nDEV=ts-%s\nMTU=1400\n' "$2" "$2" "$1" > "$INST_DIR/$1/instance.conf"
    printf '%b' "$3" > "$INST_DIR/$1/pf.conf"
}
chain_vs_file() {
    local n="$1" ch want have
    ch="TSUITE_$(echo "$n" | tr '[:lower:]-' '[:upper:]_')"
    want="$(awk -F: -v pa="$2" 'NF >= 2 { print $1, $2 + 0, pa ":" (NF == 3 ? $3 + 0 : $2 + 0) }' "$INST_DIR/$n/pf.conf" | sort)"
    have="$(sort "$NAT/$ch" 2>/dev/null)"
    [[ "$want" == "$have" ]] || bad "round $r: kernel chain $ch [$(tr '\n' ' ' <<< "$have")] does not match ${n}'s pf.conf [$(tr '\n' ' ' <<< "$want")] - a stale or interleaved apply won"
    want="$(awk -F: 'NF >= 2 { t = (NF == 3 ? $3 + 0 : $2 + 0); print $1, t, $2 + 0, "ORIGINAL"; print $1, t, $2 + 0, "REPLY" }' "$INST_DIR/$n/pf.conf" | sort)"
    have="$(grep -v '^icmp$' "$FLT/$ch" 2>/dev/null | sort)"
    [[ "$want" == "$have" ]] || bad "round $r: FORWARD accept chain $ch [$(tr '\n' ' ' <<< "$have")] does not match ${n}'s pf.conf - a stale or interleaved rebuild won"
    [[ "$(grep -cx icmp "$FLT/$ch" 2>/dev/null)" == 2 ]] || bad "round $r: FORWARD accept chain $ch does not hold exactly the 2 related-icmp accepts"
    [[ "$(grep -cxF -- "$ch" "$FLT/FORWARD" 2>/dev/null)" == 1 ]] || bad "round $r: FORWARD jumps to $ch $(grep -cxF -- "$ch" "$FLT/FORWARD" 2>/dev/null) time(s), want exactly 1"
}

for r in $(seq 1 "$ROUNDS"); do
    ROOT_DIR="$WORK/r$r/etc"; INST_DIR="$ROOT_DIR/inst"; NAT="$WORK/r$r/nat"; FLT="$WORK/r$r/filter"; RUN_DIR="$WORK/r$r/run"
    mkdir -p "$INST_DIR" "$NAT" "$FLT"; : > "$FLT/FORWARD"
    mk_inst alpha 1 ''
    mk_inst beta 2 'tcp:3999\n'
    for i in $(seq 0 11); do
        spec="$((2000 + i))"; (( i % 2 )) || spec="$spec:$((2100 + i))"
        ( set -euo pipefail; pf_add alpha tcp "$spec" ) >/dev/null 2>&1 &
        ( set -euo pipefail; pf_add beta tcp "$((3000 + i))" ) >/dev/null 2>&1 &
        ( set -euo pipefail; pf_add beta udp 999 ) >/dev/null 2>&1 &
        ( set -euo pipefail; pf_del beta 999 ) >/dev/null 2>&1 &
        ( set -euo pipefail; cmd_postup alpha; cmd_postup beta ) >/dev/null 2>&1 &
    done
    wait

    want="$(for i in $(seq 0 11); do if (( i % 2 )); then echo "tcp:$((2000 + i))"; else echo "tcp:$((2000 + i)):$((2100 + i))"; fi; done | sort)"
    have="$(sort "$INST_DIR/alpha/pf.conf")"
    [[ "$have" == "$want" ]] || bad "round $r: alpha lost or duplicated forwards under concurrency: got [$(tr '\n' ' ' <<< "$have")]"
    for i in $(seq 0 11) 999; do
        p=$((3000 + i)); [[ "$i" == 999 ]] && p=3999
        c="$(grep -cx "tcp:$p" "$INST_DIR/beta/pf.conf" || true)"
        [[ "$c" == 1 ]] || bad "round $r: beta has tcp:$p $c time(s) - a concurrent pf-del rewrote the file over a concurrent pf-add"
    done
    c="$(grep -cx 'udp:999' "$INST_DIR/beta/pf.conf" || true)"
    [[ "$c" -le 1 ]] || bad "round $r: beta has udp:999 $c times"
    bogus="$(grep -cvE '^(tcp|udp):[0-9]+(:[0-9]+)?$' "$INST_DIR/beta/pf.conf" "$INST_DIR/alpha/pf.conf" | awk -F: '{s+=$2} END {print s+0}')"
    [[ "$bogus" == 0 ]] || bad "round $r: corrupted lines in a pf.conf"
    [[ -z "$(find "$INST_DIR" -name '.pf.conf.*' -o -name 'pf.conf.??????')" ]] || bad "round $r: temp files left behind"

    chain_vs_file alpha 10.201.1.2
    chain_vs_file beta 10.201.2.2
done

if [[ "$FAILS" -ne 0 ]]; then echo "pf_interleave_test: $FAILS failure(s)"; exit 1; fi
echo "PASSED - pf_interleave_test: $ROUNDS rounds of concurrent pf-add/pf-del on two instances plus concurrent _postup applies (install restarts), plain and public:target, lose no forward, duplicate none, leave no temp file, and both the nat chains and the FORWARD accept chains end equal to pf.conf with one jump each"
