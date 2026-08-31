# ABS — AskClaw VPS Benchmark

[简体中文](README.md)

ABS benchmarks CPU, memory, disk, and fsync on a Linux VPS, then gives one simple verdict: **keep, keep with caution, avoid, or incomplete**.

## Run

```bash
curl -fsSL https://raw.githubusercontent.com/getaskclaw/abs/main/abs.sh | bash
```

Terminal output is Chinese by default. A normal run usually finishes within three minutes after dependencies are installed. ABS may install `sysbench`, `fio`, `python3`, and `curl`.

```bash
# English output
curl -fsSL https://raw.githubusercontent.com/getaskclaw/abs/main/abs.sh | bash -s -- --lang en

# Do not install missing tools
curl -fsSL https://raw.githubusercontent.com/getaskclaw/abs/main/abs.sh | bash -s -- -n
```

> `curl | bash` executes downloaded code directly. To inspect it first:
>
> ```bash
> curl -fsSLo abs.sh https://raw.githubusercontent.com/getaskclaw/abs/main/abs.sh
> less abs.sh
> bash abs.sh --lang en
> ```

## Result

English mode keeps the stable result codes:

```text
==================== ABS RESULT ====================
SCORE   : FULL 1568 (local only; network reference 136)
VERDICT : MAYBE - disk component is weak (component score 306); weak durable-write/fsync
LOCAL   : FULL 1568 (local only: cpu,mem,disk,fsync; network excluded)
NETWORK : SANITY 136 (Cloudflare HTTP; reference only, not in score)
====================================================
```

- **KEEP**: local performance is healthy
- **MAYBE**: usable, but has a clear weakness
- **AVOID**: weak local performance or a critical bottleneck
- **INCOMPLETE**: CPU, memory, disk, or fsync data is missing

`FULL` means all core tests completed; it does not mean the VPS is fast. Do not compare a `PARTIAL - not comparable` result with a full result.

## Tests and score

- **CPU**: single-thread and all-thread throughput
- **Memory**: sequential read and write
- **Disk**: sequential, 4K QD1, and pressure tests
- **fsync**: durable 4K writes
- **Network**: a short Cloudflare reference check

```text
40% CPU + 15% memory + 30% 4K QD1 disk + 15% fsync
```

Network never changes the headline score. ABS also applies a component floor: below 250 forces `AVOID`; below 500 prevents `KEEP`.

Compare results only when ABS version, profile, thread count, fio size, and `DIRECT` setting match. Only a full local result with `DIRECT=1` is directly comparable.

## Common commands

```bash
# Quick check, about 60 seconds
curl -fsSL https://raw.githubusercontent.com/getaskclaw/abs/main/abs.sh | bash -s -- --quick

# Full test, about 5–8 minutes
curl -fsSL https://raw.githubusercontent.com/getaskclaw/abs/main/abs.sh | bash -s -- --full

# Skip network; the local score remains valid
curl -fsSL https://raw.githubusercontent.com/getaskclaw/abs/main/abs.sh | bash -s -- --no-network

# Save JSON
curl -fsSL https://raw.githubusercontent.com/getaskclaw/abs/main/abs.sh | bash -s -- --json-file result.json

# Cloudflare plus three public iperf3 regions
curl -fsSL https://raw.githubusercontent.com/getaskclaw/abs/main/abs.sh | bash -s -- --network-full
```

Run `bash abs.sh --lang en --help` for every option.

## Language and machine output

- Terminal output defaults to Chinese; use `--lang en` or `ABS_LANG=en` for English
- `results.tsv` metric names and `result.json` fields and values remain stable English
- Language selection does not change scoring or machine output

## Installation and network behavior

If dependency installation fails, ABS prints a short cause, a repair hint when known, and the log path. It then continues with an incomplete result. ABS does not run system repair commands such as `dpkg --configure -a` automatically.

The default Cloudflare check downloads 10 MB and uploads 5 MB of zero data. Each attempt has a 45-second timeout and one retry. Use `--network-full` or `--network-yabs` for broader network checks.

## Safety and files

- ABS uploads no benchmark result
- Logs use a private random `/tmp/abs.*` directory
- Disk test files use a separate temporary directory and are removed afterward
- Existing `abs.test*` and `abs-dd.test` files are preserved
- A `dd` fallback may run when fio is missing, but it is not scored
- Minimal Alpine systems need Bash first: `apk add bash`

## Tests

```bash
python3 -m unittest -v tests/test_abs.py
```

GitHub Actions runs the suite on every push and pull request.

## License

MIT
