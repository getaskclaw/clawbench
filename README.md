# ClawBench

A small YABS-style VPS benchmark from AskClaw.

ClawBench is for quick VPS sanity checks and provider comparisons when you want:

- one-line run, readable results immediately,
- CPU and memory via `sysbench`,
- disk throughput/IOPS/latency via `fio`,
- conservative auto sizing that cleans up after itself,
- clear disclosure of benchmark mode and logs.

## Quick start

```bash
curl -fsSL https://raw.githubusercontent.com/getaskclaw/clawbench/main/bin/clawbench.sh | bash
```

With `wget`:

```bash
wget -qO- https://raw.githubusercontent.com/getaskclaw/clawbench/main/bin/clawbench.sh | bash
```

No-install mode:

```bash
curl -fsSL https://raw.githubusercontent.com/getaskclaw/clawbench/main/bin/clawbench.sh | bash -s -- -n
```

Explicit comparison run:

```bash
curl -fsSL https://raw.githubusercontent.com/getaskclaw/clawbench/main/bin/clawbench.sh | bash -s -- -d 60 -z 8G -t 3
```

## What it measures

| Section | Method |
| --- | --- |
| System inventory | host, kernel, CPU model, vCPU count, RAM, free disk |
| CPU | `sysbench cpu`, single-thread and all selected threads |
| Memory | `sysbench memory`, read/write throughput |
| Disk sequential | `fio` sequential write/read |
| Disk random QD1 | `fio` 4K random read/write at queue depth 1, closer to VPS “feel” |
| Disk pressure | `fio` 4K random read/write/mixed with capped jobs and queue depth 32 |
| Durable write | `fio` 4K random write with `fsync=1`, including sync p95 when fio reports it |

ClawBench intentionally does **not** run Geekbench, Cloudflare speed tests, iperf, OpenSSL speed, or stress-ng. Keep the core signal clean.

## Auto defaults

The default command should be enough for most users.

- Test duration: `30s` per timed test.
- Threads: detected with `nproc`.
- Disk file size: about **1/10 free disk**, rounded down to a common fio size, with a floor of `512M` and cap of `8G`.
- Missing tools: attempts to install `sysbench`, `fio`, and `python3` when possible.
- Disk safety: requires the fio test size plus 20% free-space buffer.

## Options

```text
-d SECONDS   seconds per timed test
-z SIZE      fio test file size, e.g. 2G, 4G, 8G
-t THREADS   CPU/memory benchmark threads
-n           no install; skip missing tools
-h           help
```

Environment overrides also work:

```bash
D=60 SIZE=8G T=3 INSTALL=0 bash clawbench.sh
```

Advanced fio overrides:

```bash
DIRECT=0 FIO_ENGINE=psync bash clawbench.sh
```

## Output

ClawBench prints a table directly and writes full logs plus a TSV summary under `/tmp/clawbench-*`.

Example header:

```text
# Clawbench v0.6.0
vCPU     : 3
Threads  : 3
Fio size : 4G
Mode     : install=1, direct=1, fio_engine=libaio, pressure_jobs=3, pressure_depth=32
Logs     : /tmp/clawbench-...
```

## Interpreting results

Use ClawBench for relative comparisons with the same command and similar time of day. VPS performance is noisy: neighbors, throttling, CPU generation, storage cache, kernel, and region all matter.

Most useful lines for ordinary VPS workloads:

- `CPU single thread`
- `CPU all threads`
- `Disk random read/write 4K QD1`
- `Disk random mixed 4K 60r/40w`
- `Disk durable write 4K fsync`

## Python legacy script

`bin/clawbench.py` is kept as a Python stdlib-only lightweight inventory/check script. The primary one-line benchmark is now `bin/clawbench.sh`.

## Safety

- Creates one temporary fio file in `.clawbench`, then removes it.
- With default install mode, may install `sysbench`, `fio`, `python3`, and small distro support packages such as `ca-certificates`/`procps`; yum systems may also install `epel-release`.
- Use `-n` to skip package installation entirely.
- Does not run network speed tests.
- Does not upload results.

## License

MIT
