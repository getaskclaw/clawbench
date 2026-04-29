# ClawBench

A small, dependency-light VPS benchmark and inventory script from AskClaw.

ClawBench is a practical alternative to heavyweight one-shot benchmark scripts such as YABS when you want:

- readable output for humans,
- machine-readable JSON for agents/automation,
- no package installation by default,
- conservative disk tests that clean up after themselves,
- clear disclosure of what was measured.

It is intended for quick VPS sanity checks, provider comparisons, migration notes, and reproducible server inventory.

## Quick start

```bash
curl -fsSL https://raw.githubusercontent.com/getaskclaw/clawbench/main/bin/clawbench.py | python3
```

Save JSON as well as the Markdown report:

```bash
python3 bin/clawbench.py --json result.json --output report.md
```

Run a larger disk test:

```bash
python3 bin/clawbench.py --disk-size-mb 1024
```

Skip network calls for offline/private environments:

```bash
python3 bin/clawbench.py --no-network
```

## What it measures

ClawBench uses Python 3 standard library only.

| Section | Method |
| --- | --- |
| System inventory | OS, kernel, CPU model/count, memory, disk filesystem, virtualization hints |
| CPU | SHA-256 hashing throughput over repeated in-memory blocks |
| Memory | bytearray copy throughput |
| Disk write/read | sequential write + fsync and sequential read of a temporary file |
| Network identity | public IP lookup and optional HTTP latency to a few endpoints |

The benchmark intentionally avoids destructive tests, root-only actions, package installs, and long-running stress loops.

## Example

```text
# ClawBench Report

- Host: example-vps
- Time UTC: 2026-04-29T00:00:00Z
- OS: Debian GNU/Linux 12 (bookworm)
- Kernel: Linux 6.1.0 x86_64

## Summary

| Metric | Value |
| --- | ---: |
| CPU SHA-256 | 1450.2 MB/s |
| Memory copy | 8200.5 MB/s |
| Disk write | 510.4 MB/s |
| Disk read | 930.1 MB/s |
```

## CLI options

```text
--output PATH        Write Markdown report to PATH
--json PATH          Write raw JSON results to PATH
--disk-path PATH     Directory to use for disk benchmark (default: current directory)
--disk-size-mb N     Temporary disk test size, default 256
--cpu-seconds N      Approximate CPU benchmark duration, default 2.0
--mem-size-mb N      Memory buffer size, default 128
--no-network         Disable public-IP and HTTP latency checks
--endpoint URL       Add an HTTP endpoint for latency checks; can be repeated
```

## Interpreting results

ClawBench is best used for relative comparisons on the same day with the same flags. VPS performance is noisy: neighbors, throttling, storage cache, region, kernel, and CPU generation all matter. Run it multiple times before making a purchasing or migration decision.

Suggested comparison workflow:

```bash
python3 bin/clawbench.py --json "$(hostname)-$(date -u +%Y%m%dT%H%M%SZ).json" --output report.md
```

Then compare JSON files with your preferred tool.

## Differences from YABS

YABS is excellent for widely recognized VPS community comparisons. ClawBench takes a different position:

- Python standard library only instead of downloading helper binaries.
- JSON-first output for automation and AI agents.
- Conservative, explainable tests rather than broad benchmark suites.
- No automatic Geekbench, fio, or iperf dependency.

Use YABS when you need community-comparable scores. Use ClawBench when you need a quick, transparent, automation-friendly VPS check.

## Safety

- Creates one temporary file in `--disk-path`, then removes it.
- Does not require root.
- Does not install packages.
- Network checks are limited to HTTP GET requests unless `--no-network` is used.

## License

MIT
