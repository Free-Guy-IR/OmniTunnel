#!/usr/bin/env python3
import os
import re
import sys

PATTERN = re.compile(
    r'\\n[ \t]+'
    r'(\[\[|\]\]|'
    r'if |then\b|else\b|elif |fi\b|'
    r'for |while |do\b|done\b|case |esac\b|'
    r'systemctl\b|iptables\b|ip link\b|ip addr\b|ip route\b|ip tuntap\b)'
)


def iter_shell_files(roots):
    for root in roots:
        if os.path.isfile(root):
            if root.endswith('.sh'):
                yield root
            continue
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = [d for d in dirnames if d != '.git']
            for name in filenames:
                if name.endswith('.sh'):
                    yield os.path.join(dirpath, name)


def scan(path):
    hits = []
    try:
        with open(path, 'r', encoding='utf-8', errors='replace') as fh:
            for lineno, line in enumerate(fh, 1):
                if PATTERN.search(line):
                    hits.append((lineno, line.rstrip('\n')))
    except OSError as exc:
        print(f'shell_escape_regression: cannot read {path}: {exc}', file=sys.stderr)
    return hits


def main(argv):
    roots = argv[1:] or ['.']
    offenders = 0
    for path in sorted(set(iter_shell_files(roots))):
        for lineno, text in scan(path):
            offenders += 1
            print(f'{path}:{lineno}: literal "\\n" followed by a shell statement: {text.strip()}')
    if offenders:
        print(f'shell_escape_regression: {offenders} suspicious escaped-newline(s) found', file=sys.stderr)
        return 1
    print('shell_escape_regression: no escaped-newline-before-command defects')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
