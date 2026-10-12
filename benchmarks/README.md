# OmniTunnel benchmarks

Offline, read-only measurement helpers. Nothing here mutates the host or the
tunnels, and no network traffic is generated unless you explicitly opt in.

## latency_report.py

Computes RTT quantiles (min/avg/max/P50/P95/P99) from a ping log.

```
# from an existing ping log
python3 benchmarks/latency_report.py --file ping.log

# from stdin
ping -c 50 1.2.3.4 | python3 benchmarks/latency_report.py

# JSON output
python3 benchmarks/latency_report.py --file ping.log --json

# collect live (opt-in only; refuses without the flag)
python3 benchmarks/latency_report.py --host 1.2.3.4 --count 50 --allow-network
```

Quantiles only describe the samples you feed it. Goodput, jitter under load and
tail behaviour on a real Iran path are NOT measured by this tool; measure those
end to end from a real vantage.

## hysteria_audit.sh

`scripts/hysteria_audit.sh [path-to-hysteria]` prints the hysteria binary's
version and SHA-256 and, when a `build-info.json` manifest with a
`hysteria_sha256` field is present, reports whether provenance is VERIFIED. With
no manifest it reports UNVERIFIED (it never fabricates a result).

## Running the unit tests

```
python3 -m unittest benchmarks/test_latency_report.py
```
