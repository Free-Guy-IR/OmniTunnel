#!/usr/bin/env python3
import json
import os
import subprocess
import sys

INST_DIR = os.environ.get('OMNITUN_INST_DIR', '/etc/omnitunnel/inst')
RUN_DIR = os.environ.get('OMNITUN_RUN_DIR', '/run/omnitunnel')


def list_instances():
    try:
        names = sorted(os.listdir(INST_DIR))
    except OSError:
        return []
    return [n for n in names if os.path.isfile(os.path.join(INST_DIR, n, 'instance.conf'))]


def strip_quotes(val):
    if len(val) >= 2 and val[0] == val[-1] and val[0] in ('"', "'"):
        return val[1:-1]
    return val


def conf_values(inst):
    out = {}
    path = os.path.join(INST_DIR, inst, 'instance.conf')
    try:
        with open(path, 'r', encoding='utf-8', errors='replace') as fh:
            for line in fh:
                line = line.strip()
                if '=' in line and not line.startswith('#'):
                    key, _, val = line.partition('=')
                    out[key] = strip_quotes(val)
    except OSError:
        pass
    return out


def read_int(path):
    try:
        with open(path, 'r', encoding='utf-8') as fh:
            return int(fh.read().strip())
    except (OSError, ValueError):
        return 0


def dev_counters(dev):
    base = f'/sys/class/net/{dev}/statistics'
    keys = ('rx_bytes', 'tx_bytes', 'rx_packets', 'tx_packets', 'rx_dropped', 'tx_dropped')
    return {k: read_int(os.path.join(base, k)) for k in keys}


def main_pid(inst):
    try:
        res = subprocess.run(
            ['systemctl', 'show', '-p', 'MainPID', '--value', f'omnitun-{inst}.service'],
            capture_output=True, text=True, timeout=5)
        return int(res.stdout.strip() or '0')
    except (OSError, ValueError, subprocess.SubprocessError):
        return 0


def proc_rss_cpu(pid):
    if not pid:
        return 0, 0
    rss = 0
    try:
        with open(f'/proc/{pid}/status', 'r', encoding='utf-8') as fh:
            for line in fh:
                if line.startswith('VmRSS:'):
                    rss = int(line.split()[1])
                    break
    except (OSError, ValueError, IndexError):
        rss = 0
    cpu = 0
    try:
        with open(f'/proc/{pid}/stat', 'r', encoding='utf-8') as fh:
            parts = fh.read().split()
            cpu = int(parts[13]) + int(parts[14])
    except (OSError, ValueError, IndexError):
        cpu = 0
    return rss, cpu


def icmp_json(dev):
    path = os.path.join(RUN_DIR, f'icmp-{dev}.json')
    if not os.path.isfile(path):
        return None
    try:
        with open(path, 'r', encoding='utf-8') as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def snapshot(inst):
    cfg = conf_values(inst)
    dev = cfg.get('DEV', '')
    pid = main_pid(inst)
    rss, cpu = proc_rss_cpu(pid)
    rec = {
        'instance': inst,
        'type': cfg.get('TYPE', ''),
        'dev': dev,
        'pid': pid,
        'rss_kb': rss,
        'cpu_ticks': cpu,
        'counters': dev_counters(dev) if dev else {},
    }
    ij = icmp_json(dev)
    rec['icmp_json'] = ij if ij is not None else 'not-available'
    return rec


def main(argv):
    as_json = '--json' in argv[1:]
    args = [a for a in argv[1:] if a != '--json']
    targets = args or list_instances()
    if not targets:
        print(f'no instances found under {INST_DIR}', file=sys.stderr)
        return 0
    records = [snapshot(t) for t in targets]
    if as_json:
        print(json.dumps(records))
        return 0
    for rec in records:
        print(f"{rec['instance']} type={rec['type']} dev={rec['dev']} pid={rec['pid']} "
              f"rss_kb={rec['rss_kb']} cpu_ticks={rec['cpu_ticks']}")
        c = rec['counters']
        if c:
            print('    ' + ' '.join(f'{k}={v}' for k, v in c.items()))
        print(f"    icmp_json={rec['icmp_json']}")
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
