#!/usr/bin/env python3
"""ClawBench: dependency-light VPS benchmark and inventory script."""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import platform
import socket
import statistics
import tempfile
import time
import urllib.request
from pathlib import Path

DEFAULT_ENDPOINTS = [
    "https://www.cloudflare.com/cdn-cgi/trace",
    "https://www.google.com/generate_204",
    "https://github.com/",
]


def read_text(path: str, default: str = "") -> str:
    try:
        return Path(path).read_text(errors="ignore").strip()
    except Exception:
        return default


def bytes_human(n: float) -> str:
    units = ["B", "KB", "MB", "GB", "TB"]
    v = float(n)
    for unit in units:
        if abs(v) < 1024 or unit == units[-1]:
            return f"{v:.1f} {unit}"
        v /= 1024
    return f"{v:.1f} TB"


def mbps(bytes_count: int, seconds: float) -> float:
    return (bytes_count / 1024 / 1024) / max(seconds, 1e-9)


def system_info(disk_path: str) -> dict:
    cpuinfo = read_text("/proc/cpuinfo")
    model = "unknown"
    for line in cpuinfo.splitlines():
        if line.lower().startswith("model name"):
            model = line.split(":", 1)[1].strip()
            break
    mem_total = None
    for line in read_text("/proc/meminfo").splitlines():
        if line.startswith("MemTotal:"):
            mem_total = int(line.split()[1]) * 1024
            break
    statvfs = os.statvfs(disk_path)
    virt = []
    for marker in ["/proc/vz", "/proc/xen", "/sys/hypervisor/type"]:
        if Path(marker).exists():
            virt.append(marker)
    product = read_text("/sys/class/dmi/id/product_name")
    if product:
        virt.append(product)
    os_release = read_text("/etc/os-release")
    pretty = platform.platform()
    for line in os_release.splitlines():
        if line.startswith("PRETTY_NAME="):
            pretty = line.split("=", 1)[1].strip().strip('"')
            break
    return {
        "hostname": socket.gethostname(),
        "time_utc": dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        "os": pretty,
        "kernel": platform.platform(),
        "machine": platform.machine(),
        "python": platform.python_version(),
        "cpu_model": model,
        "cpu_count": os.cpu_count(),
        "memory_total_bytes": mem_total,
        "disk_path": str(Path(disk_path).resolve()),
        "disk_total_bytes": statvfs.f_frsize * statvfs.f_blocks,
        "disk_available_bytes": statvfs.f_frsize * statvfs.f_bavail,
        "virtualization_hints": virt,
    }


def cpu_bench(seconds: float) -> dict:
    block = b"AskClaw-ClawBench" * 65536  # ~1.1 MiB
    count = 0
    start = time.perf_counter()
    digest = None
    while time.perf_counter() - start < seconds:
        digest = hashlib.sha256(block).digest()
        count += 1
    elapsed = time.perf_counter() - start
    processed = len(block) * count
    return {"seconds": elapsed, "bytes": processed, "mbps": mbps(processed, elapsed), "digest_prefix": digest.hex()[:12] if digest else None}


def memory_bench(size_mb: int) -> dict:
    size = size_mb * 1024 * 1024
    src = bytearray(os.urandom(min(size, 1024 * 1024)))
    if len(src) < size:
        src *= size // len(src)
    rounds = max(4, min(64, 1024 // max(size_mb, 1)))
    timings = []
    for _ in range(rounds):
        start = time.perf_counter()
        dst = bytearray(src)
        dst[0] ^= 1
        timings.append(time.perf_counter() - start)
    best = min(timings)
    return {"size_bytes": size, "rounds": rounds, "best_seconds": best, "mbps": mbps(size, best)}


def disk_bench(path: str, size_mb: int) -> dict:
    directory = Path(path)
    directory.mkdir(parents=True, exist_ok=True)
    block = os.urandom(1024 * 1024)
    total = size_mb * 1024 * 1024
    tmp_name = None
    try:
        fd, tmp_name = tempfile.mkstemp(prefix=".clawbench-", suffix=".tmp", dir=str(directory))
        with os.fdopen(fd, "wb", buffering=0) as f:
            start = time.perf_counter()
            remaining = total
            while remaining > 0:
                chunk = block if remaining >= len(block) else block[:remaining]
                f.write(chunk)
                remaining -= len(chunk)
            f.flush()
            os.fsync(f.fileno())
            write_elapsed = time.perf_counter() - start
        start = time.perf_counter()
        read_total = 0
        with open(tmp_name, "rb", buffering=0) as f:
            while True:
                data = f.read(4 * 1024 * 1024)
                if not data:
                    break
                read_total += len(data)
        read_elapsed = time.perf_counter() - start
        return {
            "size_bytes": total,
            "write_seconds": write_elapsed,
            "write_mbps": mbps(total, write_elapsed),
            "read_seconds": read_elapsed,
            "read_mbps": mbps(read_total, read_elapsed),
        }
    finally:
        if tmp_name:
            try:
                os.remove(tmp_name)
            except FileNotFoundError:
                pass


def fetch_url(url: str, timeout: float = 5.0) -> dict:
    start = time.perf_counter()
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "ClawBench/0.1"})
        with urllib.request.urlopen(req, timeout=timeout) as r:
            body = r.read(4096)
            elapsed = time.perf_counter() - start
            return {"url": url, "ok": True, "status": getattr(r, "status", None), "seconds": elapsed, "bytes_sampled": len(body)}
    except Exception as e:
        elapsed = time.perf_counter() - start
        return {"url": url, "ok": False, "seconds": elapsed, "error": f"{type(e).__name__}: {e}"}


def network_info(endpoints: list[str]) -> dict:
    public_ip = None
    for url in ["https://api.ipify.org", "https://ifconfig.me/ip"]:
        try:
            with urllib.request.urlopen(url, timeout=5) as r:
                public_ip = r.read(128).decode("utf-8", "ignore").strip()
                break
        except Exception:
            continue
    checks = [fetch_url(u) for u in endpoints]
    ok_latencies = [c["seconds"] for c in checks if c.get("ok")]
    return {
        "public_ip": public_ip,
        "http_checks": checks,
        "median_http_latency_ms": round(statistics.median(ok_latencies) * 1000, 1) if ok_latencies else None,
    }


def render_markdown(results: dict) -> str:
    sysinfo = results["system"]
    cpu = results["cpu"]
    mem = results["memory"]
    disk = results["disk"]
    net = results.get("network")
    lines = [
        "# ClawBench Report",
        "",
        f"- Host: `{sysinfo['hostname']}`",
        f"- Time UTC: {sysinfo['time_utc']}",
        f"- OS: {sysinfo['os']}",
        f"- Kernel: {sysinfo['kernel']}",
        f"- CPU: {sysinfo['cpu_model']} ({sysinfo['cpu_count']} logical cores)",
        f"- Memory: {bytes_human(sysinfo['memory_total_bytes'] or 0)}",
        f"- Disk available at `{sysinfo['disk_path']}`: {bytes_human(sysinfo['disk_available_bytes'])} / {bytes_human(sysinfo['disk_total_bytes'])}",
        "",
        "## Summary",
        "",
        "| Metric | Value |",
        "| --- | ---: |",
        f"| CPU SHA-256 | {cpu['mbps']:.1f} MB/s |",
        f"| Memory copy | {mem['mbps']:.1f} MB/s |",
        f"| Disk write | {disk['write_mbps']:.1f} MB/s |",
        f"| Disk read | {disk['read_mbps']:.1f} MB/s |",
    ]
    if net:
        lines.append(f"| Median HTTP latency | {net['median_http_latency_ms']} ms |")
    lines += ["", "## Details", "", "```json", json.dumps(results, indent=2, sort_keys=True), "```", ""]
    return "\n".join(lines)


def main() -> int:
    ap = argparse.ArgumentParser(description="Dependency-light VPS benchmark and inventory script")
    ap.add_argument("--output", help="write Markdown report to path")
    ap.add_argument("--json", dest="json_path", help="write JSON results to path")
    ap.add_argument("--disk-path", default=".", help="directory for temporary disk benchmark file")
    ap.add_argument("--disk-size-mb", type=int, default=256, help="temporary disk test size in MiB")
    ap.add_argument("--cpu-seconds", type=float, default=2.0, help="approximate CPU benchmark duration")
    ap.add_argument("--mem-size-mb", type=int, default=128, help="memory benchmark buffer size in MiB")
    ap.add_argument("--no-network", action="store_true", help="disable public-IP and HTTP latency checks")
    ap.add_argument("--endpoint", action="append", default=[], help="HTTP endpoint for latency check; repeatable")
    args = ap.parse_args()

    endpoints = args.endpoint or DEFAULT_ENDPOINTS
    results = {
        "tool": {"name": "ClawBench", "version": "0.1.0"},
        "system": system_info(args.disk_path),
        "cpu": cpu_bench(args.cpu_seconds),
        "memory": memory_bench(args.mem_size_mb),
        "disk": disk_bench(args.disk_path, args.disk_size_mb),
    }
    if not args.no_network:
        results["network"] = network_info(endpoints)

    md = render_markdown(results)
    if args.output:
        Path(args.output).write_text(md)
    if args.json_path:
        Path(args.json_path).write_text(json.dumps(results, indent=2, sort_keys=True) + "\n")
    print(md)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
