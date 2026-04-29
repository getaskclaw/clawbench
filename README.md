# ABS — AskClaw Benchmark Script

ABS is a practical VPS benchmark: **one command, quick result, keep/maybe/avoid verdict**.

It is not a YABS clone. YABS answers “how fast is this box?”

ABS tries to answer: **“should I keep this VPS?”**

## Run

```bash
curl -fsSL https://raw.githubusercontent.com/getaskclaw/abs/main/abs.sh | bash
```

That runs the default benchmark: CPU, memory, disk, fsync, and a short Cloudflare network sanity check.

Default target: **under 3 minutes**, excluding package install time.

## Common modes

```bash
# normal run
curl -fsSL https://raw.githubusercontent.com/getaskclaw/abs/main/abs.sh | bash

# quick smoke test
curl -fsSL https://raw.githubusercontent.com/getaskclaw/abs/main/abs.sh | bash -s -- --quick

# stronger local test
curl -fsSL https://raw.githubusercontent.com/getaskclaw/abs/main/abs.sh | bash -s -- --full

# stronger network test: Cloudflare + 3 public iperf3 regions
curl -fsSL https://raw.githubusercontent.com/getaskclaw/abs/main/abs.sh | bash -s -- --network-full

# YABS-style network mode: Cloudflare + current YABS public iperf3 list
curl -fsSL https://raw.githubusercontent.com/getaskclaw/abs/main/abs.sh | bash -s -- --network-yabs

# no package install
curl -fsSL https://raw.githubusercontent.com/getaskclaw/abs/main/abs.sh | bash -s -- -n
```

## What ABS measures

- CPU: sysbench single-thread and all-thread throughput
- Memory: sysbench read/write throughput
- Disk: fio sequential and 4K random tests
- Durable write: fio 4K fsync test
- Network: Cloudflare HTTP sanity check by default
- Optional network: public iperf3 via `--network-full` or `--network-yabs`

If fio is missing and cannot be installed, ABS falls back to a small `dd` disk sanity check, but `dd` is **not scored**.

## Score

ABS now prints a clear result block at the end:

```text
==================== ABS RESULT ====================
SCORE   : FULL ...
VERDICT : KEEP ...
LOCAL   : FULL ...
NETWORK : SANITY/FULL ...
====================================================
```

It also keeps the component lines in the table:

```text
ABS SCORE          FULL ...
Local component    FULL ...
Network component  SANITY/FULL ...
```

Headline score:

```text
80% local CPU/memory/disk/fsync + 20% network
```

A score is `PARTIAL - not comparable` if required sections are missing or skipped.

Public iperf3 servers are useful but noisy. They can be busy, overloaded, or routing-dependent. Use them as rough route evidence, not perfect truth.

## Verdict

ABS prints one of:

```text
KEEP
MAYBE
AVOID
INCOMPLETE
```

The verdict is meant for practical VPS decisions. It may warn about OpenVZ/container storage or suspiciously high cached disk results.

## Options

```text
--quick              ~60s smoke profile
--full               stronger 5–8 min profile
-d, --duration SEC   seconds per timed test
-z, --size SIZE      fio test file size, e.g. 512M, 2G, 8G
-t, --threads N      CPU/memory benchmark threads
-n, --no-install     do not install missing packages

--network            Cloudflare network sanity test (default)
--network-full       Cloudflare + 3 public iperf3 regions
--network-yabs       Cloudflare + current YABS public iperf3 list
--no-network         skip network checks; score becomes partial
--iperf HOST[:PORT]  add your own iperf3 server

--net-info           check IPv4/IPv6 and external IP/ASN
--json               print JSON result
--json-file PATH     copy JSON result to PATH
-h, --help           help
```

## Privacy and mutation

- No benchmark result upload.
- Default network check uses Cloudflare: about 25 MB download and 10 MB zero-data upload.
- `--network-full` and `--network-yabs` call public iperf3 servers.
- `--net-info` calls external IP/ASN endpoints.
- Default mode may install missing tools (`sysbench`, `fio`, `python3`, `curl`, and sometimes `iperf3`).
- Use `-n` to avoid package installation.
- Disk tests create temporary files in `.abs`, then remove them.

## Output files

ABS writes local artifacts under `/tmp/abs-*`:

- `results.tsv`
- `result.json`
- raw tool logs

## License

MIT
