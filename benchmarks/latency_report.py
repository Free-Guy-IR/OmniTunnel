#!/usr/bin/env python3
import argparse
import json
import math
import re
import sys

RTT_RE = re.compile(r'time[=<]\s*([0-9]+(?:\.[0-9]+)?)\s*ms')


def parse_rtts(text):
    return [float(m) for m in RTT_RE.findall(text)]


def quantile(sorted_vals, q):
    n = len(sorted_vals)
    if n == 0:
        return None
    if n == 1:
        return sorted_vals[0]
    pos = q * (n - 1)
    lo = math.floor(pos)
    hi = math.ceil(pos)
    if lo == hi:
        return sorted_vals[int(pos)]
    frac = pos - lo
    return sorted_vals[lo] * (1 - frac) + sorted_vals[hi] * frac


def summarize(rtts):
    if not rtts:
        return {'samples': 0}
    s = sorted(rtts)
    n = len(s)
    return {
        'samples': n,
        'min_ms': round(s[0], 3),
        'avg_ms': round(sum(s) / n, 3),
        'max_ms': round(s[-1], 3),
        'p50_ms': round(quantile(s, 0.50), 3),
        'p95_ms': round(quantile(s, 0.95), 3),
        'p99_ms': round(quantile(s, 0.99), 3),
    }


def collect_network(host, count):
    import subprocess
    res = subprocess.run(
        ['ping', '-n', '-c', str(count), host],
        capture_output=True, text=True, timeout=count * 2 + 10)
    return res.stdout


def main(argv):
    ap = argparse.ArgumentParser(description='offline RTT quantiles from a ping log')
    ap.add_argument('--file', help='ping log file (default: stdin)')
    ap.add_argument('--host', help='host to ping (requires --allow-network)')
    ap.add_argument('--count', type=int, default=20)
    ap.add_argument('--allow-network', action='store_true')
    ap.add_argument('--json', action='store_true')
    args = ap.parse_args(argv[1:])

    if args.host:
        if not args.allow_network:
            print('refusing to ping without --allow-network', file=sys.stderr)
            return 2
        text = collect_network(args.host, args.count)
    elif args.file:
        with open(args.file, 'r', encoding='utf-8', errors='replace') as fh:
            text = fh.read()
    else:
        text = sys.stdin.read()

    summary = summarize(parse_rtts(text))
    if args.json:
        print(json.dumps(summary))
    elif summary['samples'] == 0:
        print('no RTT samples found')
    else:
        for key, val in summary.items():
            print(f'{key}: {val}')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
