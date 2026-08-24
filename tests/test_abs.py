#!/usr/bin/env python3
"""Regression tests for ABS without third-party dependencies."""

from __future__ import annotations

import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "abs.sh"


def extract_between(source: str, start: str, end: str) -> str:
    before, sep, rest = source.partition(start)
    if not sep:
        raise AssertionError(f"start marker not found: {start}")
    body, sep, _ = rest.partition(end)
    if not sep:
        raise AssertionError(f"end marker not found: {end}")
    return start + body


def write_fake_tools(bin_dir: Path) -> None:
    df = bin_dir / "df"
    df.write_text(
        """#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in *B*) echo 'df: unsupported option B' >&2; exit 1 ;; esac
done
exec /bin/df "$@"
"""
    )
    df.chmod(0o755)

    sysbench = bin_dir / "sysbench"
    sysbench.write_text(
        textwrap.dedent(
            """\
            #!/usr/bin/env bash
            if [ "${1:-}" = "--version" ]; then
              echo 'sysbench 1.0.20'
              exit 0
            fi
            case " ${*} " in
              *" memory "*)
                if [[ " ${*} " == *" --memory-oper=read "* ]]; then
                  echo '102400.00 MiB transferred (30000.00 MiB/sec)'
                else
                  echo '102400.00 MiB transferred (20000.00 MiB/sec)'
                fi
                ;;
              *)
                threads=1
                for arg in "$@"; do
                  case "$arg" in --threads=*) threads="${arg#*=}" ;; esac
                done
                awk -v t="$threads" 'BEGIN {printf "events per second: %.2f\\n95th percentile: 1.00\\n", 400*t}'
                ;;
            esac
            """
        )
    )
    sysbench.chmod(0o755)

    fio = bin_dir / "fio"
    fio.write_text(
        textwrap.dedent(
            """\
            #!/usr/bin/env python3
            import json, os, sys
            if '--version' in sys.argv:
                print('fio-3.33')
                raise SystemExit
            trace = os.environ.get('FAKE_FIO_TRACE')
            if trace:
                with open(trace, 'a', encoding='utf-8') as f:
                    f.write(json.dumps(sys.argv[1:]) + '\\n')
            args = {a.split('=', 1)[0]: a.split('=', 1)[1] for a in sys.argv[1:] if '=' in a}
            rw = args.get('--rw', 'write')
            read_iops = 10000.0 if 'read' in rw else 0.0
            write_iops = 2000.0 if '--fsync' in args else (5000.0 if 'write' in rw else 0.0)
            if rw == 'randrw':
                read_iops, write_iops = 10000.0, 5000.0
            job = {
                'read': {
                    'bw_bytes': read_iops * 4096,
                    'iops': read_iops,
                    'clat_ns': {'percentile': {'95.000000': 1_000_000}},
                },
                'write': {
                    'bw_bytes': write_iops * 4096,
                    'iops': write_iops,
                    'clat_ns': {'percentile': {'95.000000': 1_000_000}},
                },
                'sync': {'lat_ns': {'percentile': {'95.000000': 1_000_000}}},
            }
            print(json.dumps({'jobs': [job]}))
            """
        )
    )
    fio.chmod(0o755)


class AbsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.source = SCRIPT.read_text(encoding="utf-8")

    def test_bash_syntax(self) -> None:
        subprocess.run(["bash", "-n", str(SCRIPT)], check=True)

    def test_score_uses_local_only_and_network_is_reference(self) -> None:
        match = re.search(
            r"abs_score\(\) \{\n  python3 - \"\$LOCAL_SCORE_TEXT\" \"\$NETWORK_SCORE_TEXT\" <<'PY'\n(.*?)\nPY\n\}",
            self.source,
            re.S,
        )
        self.assertIsNotNone(match)
        assert match is not None
        code = match.group(1)
        cases = [
            (
                "FULL 1251 (local only: cpu,mem,disk,fsync; network excluded)",
                "SANITY 2524 (Cloudflare HTTP; reference only, not in score)",
                "FULL 1251 (local only; network reference 2524)",
            ),
            (
                "FULL 1251 (local only: cpu,mem,disk,fsync; network excluded)",
                "N/A - skipped (network excluded; local score is standalone)",
                "FULL 1251 (local only; network excluded from score)",
            ),
            (
                "PARTIAL - not comparable: 700 (local only: cpu,mem; missing disk,fsync; network excluded)",
                "SANITY 2524",
                "PARTIAL - not comparable: 700 (local only: cpu,mem; missing disk,fsync; network excluded)",
            ),
        ]
        for local, network, expected in cases:
            proc = subprocess.run(
                ["python3", "-c", code, local, network],
                text=True,
                capture_output=True,
                check=True,
            )
            self.assertEqual(proc.stdout.strip(), expected)

    def test_verdict_reasons_match_verdict_code(self) -> None:
        match = re.search(
            r"abs_verdict\(\) \{\n  python3 - \"\$SCORE_TEXT\" \"\$RESULTS\" \"\$VM_TYPE\" \"\$T\" <<'PY'\n(.*?)\nPY\n\}",
            self.source,
            re.S,
        )
        self.assertIsNotNone(match)
        assert match is not None
        code = match.group(1)
        with tempfile.NamedTemporaryFile("w", encoding="utf-8") as results:
            results.write("Metric\tResult\n")
            results.flush()
            cases = [
                ("FULL 1300 (local only)", "KEEP - practical VPS profile looks acceptable"),
                ("FULL 1000 (local only)", "MAYBE - usable, but has notable weaknesses"),
                ("FULL 500 (local only)", "AVOID - weak practical VPS performance"),
            ]
            for score, expected in cases:
                proc = subprocess.run(
                    ["python3", "-c", code, score, results.name, "kvm"],
                    text=True,
                    capture_output=True,
                    check=True,
                )
                self.assertEqual(proc.stdout.strip(), expected)

        with tempfile.NamedTemporaryFile("w", encoding="utf-8") as results:
            results.write(
                "Metric\tResult\n"
                "CPU single thread\t1200 events/s\n"
                "CPU all threads (1)\t1200 events/s\n"
                "Memory read (1 threads)\t1 MiB/sec\n"
                "Memory write (1 threads)\t1 MiB/sec\n"
                "Disk random read 4K QD1\t1 IOPS\n"
                "Disk random write 4K QD1\t1 IOPS\n"
                "Disk durable write 4K fsync\t1 writes/s\n"
            )
            results.flush()
            proc = subprocess.run(
                ["python3", "-c", code, "FULL 1203 (local only)", results.name, "kvm"],
                text=True,
                capture_output=True,
                check=True,
            )
            self.assertTrue(proc.stdout.startswith("AVOID - critical"), proc.stdout)

        with tempfile.NamedTemporaryFile("w", encoding="utf-8") as results:
            results.write(
                "Metric\tResult\n"
                "CPU single thread\t1200 events/s\n"
                "CPU all threads (1)\t1200 events/s\n"
                "Memory read (1 threads)\t9000 MiB/sec\n"
                "Memory write (1 threads)\t6000 MiB/sec\n"
                "Disk random read 4K QD1\t10000 IOPS\n"
                "Disk random write 4K QD1\t5000 IOPS\n"
                "Disk durable write 4K fsync\t2000 writes/s\n"
            )
            results.flush()
            proc = subprocess.run(
                ["python3", "-c", code, "FULL 1695 (local only)", results.name, "kvm"],
                text=True,
                capture_output=True,
                check=True,
            )
            self.assertTrue(proc.stdout.startswith("MAYBE - memory component is weak"), proc.stdout)

    def test_component_floor_threshold_boundaries(self) -> None:
        match = re.search(
            r"abs_verdict\(\) \{\n  python3 - \"\$SCORE_TEXT\" \"\$RESULTS\" \"\$VM_TYPE\" \"\$T\" <<'PY'\n(.*?)\nPY\n\}",
            self.source,
            re.S,
        )
        self.assertIsNotNone(match)
        assert match is not None
        code = match.group(1)
        expected = {249: "AVOID", 250: "MAYBE", 499: "MAYBE", 500: "KEEP"}
        for component, expected_code in expected.items():
            with tempfile.NamedTemporaryFile("w", encoding="utf-8") as results:
                results.write(
                    "Metric\tResult\n"
                    "CPU single thread\t1200 events/s\n"
                    "CPU all threads (1)\t1200 events/s\n"
                    f"Memory read (1 threads)\t{30 * component} MiB/sec\n"
                    f"Memory write (1 threads)\t{20 * component} MiB/sec\n"
                    "Disk random read 4K QD1\t10000 IOPS\n"
                    "Disk random write 4K QD1\t5000 IOPS\n"
                    "Disk durable write 4K fsync\t2000 writes/s\n"
                )
                results.flush()
                aggregate = round(1650 + 0.15 * component)
                proc = subprocess.run(
                    ["python3", "-c", code, f"FULL {aggregate} (local only)", results.name, "kvm", "1"],
                    text=True,
                    capture_output=True,
                    check=True,
                )
                self.assertEqual(proc.stdout.split()[0], expected_code, (component, proc.stdout))

    def test_pick_port_rejects_arithmetic_command_injection(self) -> None:
        validator = (
            extract_between(self.source, "valid_port_range() {", "\n}\n\nIPERF_CUSTOM_HOST")
            + "\n}\n"
        )
        function = extract_between(self.source, "pick_port() {", "\n}\n\nrun_iperf_cmd()") + "\n}\n"
        helpers = validator + function
        valid = subprocess.run(
            ["bash", "-c", helpers + '\npick_port "$1"', "bash", "5201"],
            text=True,
            capture_output=True,
        )
        self.assertEqual(valid.returncode, 0, valid.stderr)
        self.assertEqual(valid.stdout.strip(), "5201")
        ranged = subprocess.run(
            ["bash", "-c", helpers + '\npick_port "$1"', "bash", "5200-5209"],
            text=True,
            capture_output=True,
        )
        self.assertEqual(ranged.returncode, 0, ranged.stderr)
        self.assertIn(int(ranged.stdout.strip()), range(5200, 5210))
        with tempfile.TemporaryDirectory() as td:
            marker = Path(td) / "injected"
            payload = f"1-x[$(touch {marker})]"
            proc = subprocess.run(
                ["bash", "-c", helpers + '\npick_port "$1"', "bash", payload],
                text=True,
                capture_output=True,
            )
            self.assertNotEqual(proc.returncode, 0)
            self.assertFalse(marker.exists(), "untrusted port range executed a shell command")

    def test_custom_iperf_endpoint_validation_and_cli_rejection(self) -> None:
        helpers = (
            extract_between(self.source, "valid_port_range() {", "\n}\n\nIPERF_CUSTOM_HOST")
            + "\n}\n\nIPERF_CUSTOM_HOST=''\nIPERF_CUSTOM_PORT=''\n"
            + extract_between(self.source, "parse_custom_iperf() {", "\n}\n\nif ! is_pos_int")
            + "\n}\n"
        )
        cases = [
            ("example.com:5202", "example.com|5202"),
            ("[2001:db8::1]:5203", "2001:db8::1|5203"),
            ("2001:db8::1", "2001:db8::1|5201"),
        ]
        for endpoint, expected in cases:
            proc = subprocess.run(
                [
                    "bash",
                    "-c",
                    helpers + '\nparse_custom_iperf "$1" && printf "%s|%s\\n" "$IPERF_CUSTOM_HOST" "$IPERF_CUSTOM_PORT"',
                    "bash",
                    endpoint,
                ],
                text=True,
                capture_output=True,
            )
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(proc.stdout.strip(), expected)

        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            marker = root / "injected"
            data_dir = root / "must-not-be-created"
            payload = f"host:1-x[$(touch {marker})]"
            env = os.environ.copy()
            env["DIR"] = str(data_dir)
            proc = subprocess.run(
                [str(SCRIPT), "--quick", "-n", "--iperf", payload, "--no-network"],
                env=env,
                text=True,
                capture_output=True,
            )
            self.assertEqual(proc.returncode, 2)
            self.assertIn("Invalid --iperf endpoint", proc.stderr)
            self.assertFalse(marker.exists())
            self.assertFalse(data_dir.exists(), "invalid endpoint must fail before filesystem setup")

    def test_arch_install_does_not_sync_without_upgrade(self) -> None:
        self.assertNotIn("pacman -Sy --noconfirm", self.source)

    def test_default_logdir_is_private_mktemp_directory(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            bin_dir = root / "bin"
            data_dir = root / "data"
            tmp_dir = root / "tmp"
            bin_dir.mkdir()
            data_dir.mkdir()
            tmp_dir.mkdir()
            write_fake_tools(bin_dir)
            env = os.environ.copy()
            env.pop("LOGDIR", None)
            env.update(
                {
                    "PATH": f"{bin_dir}:{env['PATH']}",
                    "DIR": str(data_dir),
                    "TMPDIR": str(tmp_dir),
                    "INSTALL": "0",
                }
            )
            proc = subprocess.run(
                [str(SCRIPT), "--quick", "-n", "--no-network"],
                env=env,
                text=True,
                capture_output=True,
                timeout=60,
            )
            self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
            match = re.search(r"^Logs\s*:\s*(.+)$", proc.stdout, re.M)
            self.assertIsNotNone(match)
            assert match is not None
            log_dir = Path(match.group(1).strip())
            self.assertEqual(log_dir.parent, tmp_dir)
            self.assertEqual(log_dir.stat().st_mode & 0o777, 0o700)

    def test_end_to_end_local_score_and_preserve_existing_files(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            bin_dir = root / "bin"
            data_dir = root / "data"
            log_dir = root / "logs"
            bin_dir.mkdir()
            data_dir.mkdir()
            write_fake_tools(bin_dir)

            sentinels = {
                data_dir / "abs.test.keep": b"keep-test-suffix",
                data_dir / "abs-dd.test": b"keep-dd-name",
            }
            for path, payload in sentinels.items():
                path.write_bytes(payload)

            result_json = root / "result.json"
            env = os.environ.copy()
            env.update(
                {
                    "PATH": f"{bin_dir}:{env['PATH']}",
                    "DIR": str(data_dir),
                    "LOGDIR": str(log_dir),
                    "INSTALL": "0",
                    "FAKE_FIO_TRACE": str(root / "fio-args.jsonl"),
                }
            )
            proc = subprocess.run(
                [str(SCRIPT), "--quick", "-n", "--no-network", "--json-file", str(result_json)],
                env=env,
                text=True,
                capture_output=True,
                timeout=60,
            )
            self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
            result = json.loads(result_json.read_text(encoding="utf-8"))
            self.assertEqual(result["score"]["text"], "FULL 1000 (local only; network excluded from score)")
            self.assertEqual(result["score"]["scope"], "local_only")
            self.assertFalse(result["score"]["includes_network"])
            self.assertEqual(result["network_score"]["weight"], 0.0)
            self.assertEqual(result["verdict"]["code"], "MAYBE")
            calls = [json.loads(line) for line in (root / "fio-args.jsonl").read_text().splitlines()]
            pressure_calls = []
            for call in calls:
                options = dict(arg[2:].split("=", 1) for arg in call if arg.startswith("--") and "=" in arg)
                if int(options.get("numjobs", "1")) > 1:
                    pressure_calls.append(options)
            self.assertEqual(len(pressure_calls), 3)
            for options in pressure_calls:
                jobs = int(options["numjobs"])
                expected_segment = (512 * 1024 * 1024 // jobs) // 4096 * 4096
                self.assertTrue(options["size"].isdigit(), "pressure size must be a byte count")
                self.assertEqual(int(options["size"]), expected_segment)
                self.assertEqual(options.get("offset_increment"), options["size"])
            for path, payload in sentinels.items():
                self.assertTrue(path.exists(), f"pre-existing file was deleted: {path.name}")
                self.assertEqual(path.read_bytes(), payload)

    def test_buffered_fio_cannot_produce_comparable_score(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            bin_dir = root / "bin"
            data_dir = root / "data"
            log_dir = root / "logs"
            bin_dir.mkdir()
            data_dir.mkdir()
            write_fake_tools(bin_dir)
            result_json = root / "result.json"
            env = os.environ.copy()
            env.update(
                {
                    "PATH": f"{bin_dir}:{env['PATH']}",
                    "DIR": str(data_dir),
                    "LOGDIR": str(log_dir),
                    "INSTALL": "0",
                    "DIRECT": "0",
                }
            )
            proc = subprocess.run(
                [str(SCRIPT), "--quick", "-n", "--no-network", "--json-file", str(result_json)],
                env=env,
                text=True,
                capture_output=True,
                timeout=60,
            )
            self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
            result = json.loads(result_json.read_text(encoding="utf-8"))
            self.assertEqual(result["score"]["status"], "partial")
            self.assertFalse(result["score"]["comparable"])
            self.assertEqual(result["score"]["missing_components"], ["disk-buffered", "fsync-buffered"])
            self.assertEqual(result["verdict"]["code"], "INCOMPLETE")

    def test_json_copy_failure_returns_nonzero_without_false_success(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            bin_dir = root / "bin"
            data_dir = root / "data"
            log_dir = root / "logs"
            bin_dir.mkdir()
            data_dir.mkdir()
            write_fake_tools(bin_dir)
            impossible_copy = Path("/proc/abs-audit-no-such-dir/result.json")
            env = os.environ.copy()
            env.update(
                {
                    "PATH": f"{bin_dir}:{env['PATH']}",
                    "DIR": str(data_dir),
                    "LOGDIR": str(log_dir),
                    "INSTALL": "0",
                }
            )
            proc = subprocess.run(
                [str(SCRIPT), "--quick", "-n", "--no-network", "--json-file", str(impossible_copy)],
                env=env,
                text=True,
                capture_output=True,
                timeout=60,
            )
            self.assertNotEqual(proc.returncode, 0)
            self.assertIn(f"FAILED: {impossible_copy}", proc.stdout)
            self.assertIn("==================== ABS RESULT ====================", proc.stdout)
            self.assertFalse(impossible_copy.exists())
            self.assertTrue((log_dir / "result.json").is_file(), "canonical JSON should survive copy failure")


if __name__ == "__main__":
    unittest.main()
