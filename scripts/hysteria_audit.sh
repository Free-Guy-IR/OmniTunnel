#!/bin/bash
set -uo pipefail
HY="${1:-/usr/local/bin/hysteria}"
MANIFEST="${OMNITUN_BUILD_INFO:-/opt/omnitunnel/build-info.json}"

[[ -x "$HY" ]] || { echo "hysteria binary not found or not executable: $HY" >&2; exit 1; }

sha="$( { sha256sum "$HY" 2>/dev/null || shasum -a 256 "$HY" 2>/dev/null; } | awk '{print $1}')"
ver="$("$HY" version 2>/dev/null | awk -F'\t' '/Version/{print $2}')"
[[ -n "$ver" ]] || ver="$("$HY" version 2>/dev/null | head -1)"

echo "binary: $HY"
echo "version: ${ver:-unknown}"
echo "sha256: ${sha:-unknown}"

if [[ -f "$MANIFEST" ]]; then
    expected="$(grep -oE '"hysteria_sha256"[[:space:]]*:[[:space:]]*"[0-9a-f]{64}"' "$MANIFEST" 2>/dev/null | grep -oE '[0-9a-f]{64}' | head -1)"
    if [[ -n "$expected" && "$expected" == "$sha" ]]; then
        echo "provenance: VERIFIED (matches $MANIFEST)"
    elif [[ -n "$expected" ]]; then
        echo "provenance: MISMATCH (manifest expects $expected)" >&2
        exit 2
    else
        echo "provenance: UNVERIFIED (no hysteria_sha256 entry in $MANIFEST)"
    fi
else
    echo "provenance: UNVERIFIED (no build manifest at $MANIFEST)"
fi
