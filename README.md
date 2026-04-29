# ABS — AskClaw Benchmark Script

ABS is a practical VPS decision benchmark: **one line in, keep/maybe/avoid out**.

ABS is designed to finish fast, include a short network sanity check by default, and explain whether a VPS is useful for ordinary workloads.

## Quick start

```bash
curl -fsSL https://raw.githubusercontent.com/getaskclaw/abs/main/abs.sh | bash
```

With `wget`:

```bash
wget -qO- https://raw.githubusercontent.com/getaskclaw/abs/main/abs.sh | bash
```

No-install / lower-mutation mode:

```bash
curl -fsSL https://raw.githubusercontent.com/getaskclaw/abs/main/abs.sh | bash -s -- -n
```

Quick smoke run:

```bash
curl -fsSL https://raw.githubusercontent.com/getaskclaw/abs/main/abs.sh | bash -s -- --quick -n
```

Fuller comparison run:

```bash
curl -fsSL https://raw.githubusercontent.com/getaskclaw/abs/main/abs.sh | bash -s -- --full -z 8G --json
```

## Design target

| Profile | Target | Purpose |
| --- | --- | --- |
| `default` | under 3 minutes, excluding package install time | practical keep/maybe/avoid VPS check |
| `--quick` | about 60 seconds | smoke test / broken-box detection |
| `--full` | about 5–8 minutes | stronger comparison evidence |

Default ABS intentionally runs shorter than YABS. It favors useful signal over exhaustive tables.

## What it measures

| Section | Method |
| --- | --- |
| System inventory | host, uptime, distro, kernel, CPU, vCPU, RAM, swap, disk, VM type, AES-NI, VM-x/SVM |
| Network identity | optional `--net-info` IPv4/IPv6 status and external IP/ASN lookup |
| CPU | `sysbench cpu`, single-thread and all selected threads |
| Memory | `sysbench memory`, read/write throughput |
| Disk sequential | `fio` sequential write/read |
| Disk random QD1 | `fio` 4K random read/write at queue depth 1, closer to VPS “feel” |
| Disk pressure | `fio` 4K random read/write/mixed with capped jobs and queue depth 32 |
| Durable write | `fio` 4K random write with `fsync=1`, including sync p95 when fio reports it |
| Fallback disk | small `dd` sequential fallback if fio is unavailable; not scored |
| Network sanity | default Cloudflare HTTP check with separate network sanity score: about 25 MB download plus 10 MB zero-data upload; `--no-network` skips it |
| ABS score/verdict | internal local score plus `KEEP` / `MAYBE` / `AVOID` / `INCOMPLETE` verdict; network is shown separately |

## Score and verdict

ABS score is **not Geekbench** and **not YABS-compatible**. It is an internal same-tool convenience score for local CPU, memory, and disk. Network is reported as a separate sanity score, not mixed into ABS score.

Rough weighting:

- 40% CPU: sysbench single-thread and per-thread all-core throughput
- 15% memory: sysbench read/write throughput
- 30% disk: fio 4K QD1 read/write IOPS
- 15% durable write: fio 4K fsync writes/s

A full score requires CPU, memory, disk QD1, and fsync. If any core section is missing, ABS prints:

```text
PARTIAL - not comparable
ABS verdict: INCOMPLETE
```

That avoids misleading screenshots when fio or sysbench is missing. ABS also adds caution text when OpenVZ/container-like storage or extremely high write/fsync numbers may be cache-inflated.

## Options

```text
--quick              ~60s smoke profile
--full               stronger 5–8 min profile
-d, --duration SEC   seconds per timed test
-z, --size SIZE      fio test file size, e.g. 512M, 2G, 8G
-t, --threads N      CPU/memory benchmark threads
-n, --no-install     do not install missing packages
--net-info           check IPv4/IPv6 and external IP/ASN
--no-net-info        skip external IP/ASN lookup (default)
--network            run Cloudflare HTTP network sanity test (default)
--no-network         skip network speed sanity test
--json               print JSON result at the end
--json-file PATH     write JSON result to PATH as well as logdir
-h, --help           help
```

Environment overrides also work:

```bash
PROFILE=full SIZE=8G INSTALL=0 bash abs.sh
DIRECT=0 FIO_ENGINE=psync bash abs.sh
```

## Output files

ABS prints a human table and writes local artifacts under `/tmp/abs-*`:

- `results.tsv`
- `result.json`
- raw tool logs

Use `--json-file result.json` to copy JSON somewhere specific.

## Privacy and mutation

- No automatic result upload.
- Default mode may install `sysbench`, `fio`, `python3`, `curl`, and small distro support packages if missing.
- Use `-n` / `--no-install` to skip package installation entirely.
- Default mode calls Cloudflare speed endpoints for a short HTTP network sanity check; use `--no-network` to skip it.
- `--net-info` calls external endpoints for IPv4/IPv6 and IP/ASN lookup.
- Disk tests create temporary files in `.abs`, then remove them.

## License

MIT
