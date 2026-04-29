#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C

VERSION="0.1.0"
VCPU="$(nproc 2>/dev/null || echo 1)"
D="${D:-30}"                                # seconds per timed test
T="${T:-$VCPU}"                             # CPU/memory benchmark threads
SIZE="${SIZE:-auto}"                        # fio test file size; auto-detected unless set
DIR="${DIR:-$PWD/.abs}"                      # disk test location
CPU_PRIME="${CPU_PRIME:-20000}"
DIRECT="${DIRECT:-1}"                       # set DIRECT=0 if direct I/O fails
FIO_ENGINE="${FIO_ENGINE:-libaio}"          # try FIO_ENGINE=psync if libaio fails
JOBS_ENV="${JOBS-}"                         # optional pressure random I/O jobs
DEPTH="${DEPTH:-32}"                        # pressure random I/O queue depth
INSTALL="${INSTALL:-1}"                     # default: one-line run installs missing tools
LOGDIR="${LOGDIR:-/tmp/abs-$(date -u +%Y%m%dT%H%M%SZ)-$$}"

RESULTS="$LOGDIR/results.tsv"
FIO_FILE="$DIR/abs.test"
FIO_BIN=""
JOBS=""
LAST_LOG=""
LAST_JSON=""

usage() {
  cat <<EOF
ABS v$VERSION — AskClaw Benchmark Script

One-line run after hosting:
  curl -fsSL https://raw.githubusercontent.com/getaskclaw/abs/main/abs.sh | bash
  wget -qO- https://raw.githubusercontent.com/getaskclaw/abs/main/abs.sh | bash

Explicit overrides:
  curl -fsSL https://raw.githubusercontent.com/getaskclaw/abs/main/abs.sh | bash -s -- -d 60 -z 8G -t 3

Options:
  -d SECONDS   seconds per timed test   default: $D
  -z SIZE      fio test file size       default: auto (~1/10 free disk, capped at 8G)
  -t THREADS   CPU/memory threads       default: detected vCPU ($T)
  -n           no install; skip missing tools
  -h           help

Env overrides also work: D=60 SIZE=8G T=3 INSTALL=0 bash abs.sh
EOF
}

while getopts ":d:z:t:nh" opt; do
  case "$opt" in
    d) D="$OPTARG" ;;
    z) SIZE="$OPTARG" ;;
    t) T="$OPTARG" ;;
    n) INSTALL=0 ;;
    h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

is_pos_int() { [[ "${1:-}" =~ ^[1-9][0-9]*$ ]]; }
if ! is_pos_int "$D"; then echo "Invalid -d/SECONDS: $D" >&2; exit 2; fi
if ! is_pos_int "$T"; then echo "Invalid -t/THREADS: $T" >&2; exit 2; fi
if ! is_pos_int "$DEPTH"; then echo "Invalid DEPTH: $DEPTH" >&2; exit 2; fi
if [ -n "$JOBS_ENV" ]; then
  JOBS="$JOBS_ENV"
else
  JOBS=$(( T < 4 ? T : 4 ))
fi
if ! is_pos_int "$JOBS"; then echo "Invalid JOBS: $JOBS" >&2; exit 2; fi

mkdir -p "$LOGDIR" "$DIR"
printf 'Metric\tResult\n' > "$RESULTS"

auto_size() {
  local avail_kb avail_mib target_mib
  avail_kb="$(df -Pk "$DIR" 2>/dev/null | awk 'NR==2 {print $4+0}')"
  avail_mib=$(( ${avail_kb:-0} / 1024 ))

  # Default: about 1/10 free disk, bounded for sane one-line VPS runs.
  # Floor: 512M. Cap: 8G. Rounded down to a common fio size.
  target_mib=$(( avail_mib / 10 ))
  [ "$target_mib" -lt 512 ] && target_mib=512
  [ "$target_mib" -gt 8192 ] && target_mib=8192

  if [ "$target_mib" -lt 1024 ]; then
    printf '512M\n'
  elif [ "$target_mib" -lt 2048 ]; then
    printf '1G\n'
  elif [ "$target_mib" -lt 4096 ]; then
    printf '2G\n'
  elif [ "$target_mib" -lt 8192 ]; then
    printf '4G\n'
  else
    printf '8G\n'
  fi
}

if [ "$SIZE" = "auto" ]; then
  SIZE="$(auto_size)"
fi

have() { command -v "$1" >/dev/null 2>&1; }

sudo_cmd() {
  if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    "$@"
  elif have sudo; then
    sudo -n "$@"
  else
    return 1
  fi
}

find_fio_bin() {
  local p
  for p in "$(command -v fio 2>/dev/null || true)" /usr/bin/fio /usr/local/bin/fio; do
    [ -n "$p" ] && [ -x "$p" ] || continue
    if "$p" --version 2>/dev/null | grep -q '^fio-'; then
      printf '%s\n' "$p"
      return 0
    fi
  done
  return 1
}

have_fio() {
  FIO_BIN="$(find_fio_bin 2>/dev/null || true)"
  [ -n "$FIO_BIN" ]
}

missing_tools() {
  local missing=()
  have sysbench || missing+=(sysbench)
  have_fio || missing+=(fio)
  have python3 || missing+=(python3)
  printf '%s\n' "${missing[@]}"
}

install_tools() {
  local missing
  missing="$(missing_tools | xargs 2>/dev/null || true)"
  [ -z "$missing" ] && return 0

  if [ "$INSTALL" != "1" ]; then
    return 0
  fi

  echo "Missing tools: $missing"
  echo "Installing missing tools when possible... use -n to skip installation."

  if have apt-get; then
    sudo_cmd env DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null 2>"$LOGDIR/install-apt-update.err" || true
    sudo_cmd env DEBIAN_FRONTEND=noninteractive apt-get install -y sysbench fio python3 ca-certificates procps \
      >"$LOGDIR/install-apt.log" 2>"$LOGDIR/install-apt.err" || true
  elif have dnf; then
    sudo_cmd dnf install -y sysbench fio python3 procps-ng >"$LOGDIR/install-dnf.log" 2>"$LOGDIR/install-dnf.err" || true
  elif have yum; then
    sudo_cmd yum install -y epel-release >"$LOGDIR/install-yum-epel.log" 2>"$LOGDIR/install-yum-epel.err" || true
    sudo_cmd yum install -y sysbench fio python3 procps-ng >"$LOGDIR/install-yum.log" 2>"$LOGDIR/install-yum.err" || true
  elif have pacman; then
    sudo_cmd pacman -Sy --noconfirm sysbench fio python procps >"$LOGDIR/install-pacman.log" 2>"$LOGDIR/install-pacman.err" || true
  elif have apk; then
    sudo_cmd apk add --no-cache sysbench fio python3 procps >"$LOGDIR/install-apk.log" 2>"$LOGDIR/install-apk.err" || true
  fi

  have_fio || true
  missing="$(missing_tools | xargs 2>/dev/null || true)"
  [ -z "$missing" ] || echo "Still missing after install attempt: $missing; affected tests will be skipped."
}

add() {
  printf '%-48s %s\n' "$1" "$2"
  printf '%s\t%s\n' "$1" "$2" >> "$RESULTS"
}

field() { awk -v key="$1" '$0 ~ key {print $NF; exit}' "$2"; }
eps() { field 'events per second' "$1"; }
p95() { field '95th percentile' "$1"; }
memspeed() { awk -F'[()]' '/MiB transferred/ {print $2; exit}' "$1"; }

run_log() {
  local name="$1"
  shift
  LAST_LOG="$LOGDIR/$name.log"
  if "$@" >"$LAST_LOG" 2>&1; then
    return 0
  fi
  return 1
}

fio_run() {
  local name="$1" rw="$2" bs="$3" jobs="$4" depth="$5"
  shift 5

  LAST_JSON="$LOGDIR/$name.json"
  local err="$LOGDIR/$name.err"
  local fio_rw="$rw"
  [ "$rw" = "prepare" ] && fio_rw="write"

  local args=(
    --name="$name"
    --filename="$FIO_FILE"
    --size="$SIZE"
    --rw="$fio_rw"
    --bs="$bs"
    --numjobs="$jobs"
    --iodepth="$depth"
    --group_reporting
    --eta=never
    --direct="$DIRECT"
    --ioengine="$FIO_ENGINE"
    --output-format=json
  )

  if [ "$rw" != "prepare" ]; then
    args+=(--runtime="$D" --time_based)
  else
    args+=(--end_fsync=1)
  fi

  args+=("$@")

  if "$FIO_BIN" "${args[@]}" >"$LAST_JSON" 2>"$err"; then
    return 0
  fi
  return 1
}

size_bytes() {
  python3 - "$1" <<'PY'
import re, sys
s = sys.argv[1].strip()
m = re.fullmatch(r'([0-9]+)([KMGTP]?)(i?B?)?', s, re.I)
if not m:
    print(-1); raise SystemExit
n = int(m.group(1)); unit = m.group(2).upper()
mult = {'':1,'K':1024,'M':1024**2,'G':1024**3,'T':1024**4,'P':1024**5}[unit]
print(n * mult)
PY
}

fio_metric() {
  local metric="$1"
  python3 - "$LAST_JSON" "$metric" <<'PY'
import json, sys
path, metric = sys.argv[1], sys.argv[2]
try:
    with open(path, 'r', encoding='utf-8', errors='replace') as f:
        data = json.load(f)
except Exception:
    print('0.00')
    raise SystemExit
jobs = data.get('jobs') or []

def nums(path):
    out = []
    for job in jobs:
        cur = job
        for key in path:
            if not isinstance(cur, dict) or key not in cur:
                break
            cur = cur[key]
        else:
            if isinstance(cur, (int, float)):
                out.append(float(cur))
    return out

def sum_path(path):
    return sum(nums(path))

def max_p95(section, lat='clat_ns'):
    vals = []
    for job in jobs:
        p = (((job.get(section) or {}).get(lat) or {}).get('percentile') or {})
        v = p.get('95.000000') or p.get('95')
        if isinstance(v, (int, float)):
            vals.append(float(v) / 1_000_000)
    return max(vals) if vals else 0.0

def sync_p95():
    vals = []
    for job in jobs:
        sync = job.get('sync') or {}
        for lat_key in ('lat_ns', 'clat_ns'):
            p = ((sync.get(lat_key) or {}).get('percentile') or {})
            v = p.get('95.000000') or p.get('95')
            if isinstance(v, (int, float)):
                vals.append(float(v) / 1_000_000)
    return max(vals) if vals else None

if metric == 'read_mib':
    val = sum_path(['read', 'bw_bytes']) / 1048576
elif metric == 'write_mib':
    val = sum_path(['write', 'bw_bytes']) / 1048576
elif metric == 'read_iops':
    val = sum_path(['read', 'iops'])
elif metric == 'write_iops':
    val = sum_path(['write', 'iops'])
elif metric == 'read_p95_ms':
    val = max_p95('read')
elif metric == 'write_p95_ms':
    val = max_p95('write')
elif metric == 'mixed_p95_ms':
    val = max(max_p95('read'), max_p95('write'))
elif metric == 'sync_p95_ms':
    val = sync_p95()
    if val is None:
        print('n/a')
        raise SystemExit
else:
    val = 0.0
print(f'{val:.2f}')
PY
}

cleanup() {
  rm -f "$FIO_FILE" "$FIO_FILE".* 2>/dev/null || true
}
trap cleanup EXIT

install_tools
have_fio || true

cat <<EOF
# ABS v$VERSION
Date UTC : $(date -u)
Host     : $(hostname 2>/dev/null || true)
Kernel   : $(uname -srmo)
CPU      : $(awk -F: '/model name/ {gsub(/^[ \t]+/, "", $2); print $2; exit}' /proc/cpuinfo 2>/dev/null || echo unknown)
vCPU     : $VCPU
Threads  : $T
RAM      : $(free -h 2>/dev/null | awk '/^Mem:/ {print $2}' || echo unknown)
Disk     : $(df -h "$DIR" 2>/dev/null | awk 'NR==2 {print $4 " free on " $1}' || echo unknown)
Fio size : $SIZE
Mode     : install=$INSTALL, direct=$DIRECT, fio_engine=$FIO_ENGINE, pressure_jobs=$JOBS, pressure_depth=$DEPTH
Duration : ${D}s/test
Tools    : sysbench=$(sysbench --version 2>/dev/null | awk '{print $2}' || echo no), fio=$([ -n "$FIO_BIN" ] && "$FIO_BIN" --version 2>/dev/null || echo no), python3=$(python3 --version 2>/dev/null | awk '{print $2}' || echo no)
Logs     : $LOGDIR
EOF

echo
printf '%-48s %s\n' "Metric" "Result"
printf '%-48s %s\n' "------" "------"

if have sysbench; then
  if run_log cpu-1t sysbench cpu --threads=1 --time="$D" --events=0 --percentile=95 --cpu-max-prime="$CPU_PRIME" run; then
    add "CPU single thread" "$(eps "$LAST_LOG") events/s, p95 $(p95 "$LAST_LOG") ms"
  else
    add "CPU single thread" "FAILED; see $LAST_LOG"
  fi

  if run_log cpu-all sysbench cpu --threads="$T" --time="$D" --events=0 --percentile=95 --cpu-max-prime="$CPU_PRIME" run; then
    add "CPU all threads ($T)" "$(eps "$LAST_LOG") events/s, p95 $(p95 "$LAST_LOG") ms"
  else
    add "CPU all threads ($T)" "FAILED; see $LAST_LOG"
  fi

  if run_log mem-read sysbench memory --threads="$T" --time="$D" --events=0 --percentile=95 --memory-block-size=1M --memory-total-size=100T --memory-oper=read --memory-access-mode=seq run; then
    add "Memory read ($T threads)" "$(memspeed "$LAST_LOG")"
  else
    add "Memory read" "FAILED; see $LAST_LOG"
  fi

  if run_log mem-write sysbench memory --threads="$T" --time="$D" --events=0 --percentile=95 --memory-block-size=1M --memory-total-size=100T --memory-oper=write --memory-access-mode=seq run; then
    add "Memory write ($T threads)" "$(memspeed "$LAST_LOG")"
  else
    add "Memory write" "FAILED; see $LAST_LOG"
  fi
else
  add "sysbench CPU/memory" "sysbench not installed; skipped"
fi

if [ -n "$FIO_BIN" ] && have python3; then
  need_bytes="$(size_bytes "$SIZE" 2>/dev/null || echo -1)"
  avail_bytes="$(df -PB1 "$DIR" 2>/dev/null | awk 'NR==2 {print $4+0}')"
  required_bytes=$(( need_bytes + need_bytes / 5 ))

  if [ "${need_bytes:-0}" -le 0 ]; then
    add "fio disk tests" "invalid SIZE=$SIZE; skipped"
  elif [ "${avail_bytes:-0}" -le "$required_bytes" ]; then
    add "fio disk tests" "not enough free space for SIZE=$SIZE plus 20% buffer; skipped"
  else
    cleanup

    if ! fio_run fio-prepare prepare 1M 1 1; then
      add "fio prepare" "FAILED; see $LOGDIR/fio-prepare.err"
    else
      if fio_run fio-seq-write write 1M 1 1 --end_fsync=1; then
        add "Disk sequential write" "$(fio_metric write_mib) MiB/s, p95 $(fio_metric write_p95_ms) ms"
      else
        add "Disk sequential write" "FAILED; see $LOGDIR/fio-seq-write.err"
      fi

      if fio_run fio-seq-read read 1M 1 1; then
        add "Disk sequential read" "$(fio_metric read_mib) MiB/s, p95 $(fio_metric read_p95_ms) ms"
      else
        add "Disk sequential read" "FAILED; see $LOGDIR/fio-seq-read.err"
      fi

      if fio_run fio-rand-read-q1 randread 4k 1 1 --randrepeat=0; then
        add "Disk random read 4K QD1" "$(fio_metric read_iops) IOPS, $(fio_metric read_mib) MiB/s, p95 $(fio_metric read_p95_ms) ms"
      else
        add "Disk random read 4K QD1" "FAILED; see $LOGDIR/fio-rand-read-q1.err"
      fi

      if fio_run fio-rand-write-q1 randwrite 4k 1 1 --randrepeat=0; then
        add "Disk random write 4K QD1" "$(fio_metric write_iops) IOPS, $(fio_metric write_mib) MiB/s, p95 $(fio_metric write_p95_ms) ms"
      else
        add "Disk random write 4K QD1" "FAILED; see $LOGDIR/fio-rand-write-q1.err"
      fi

      if fio_run fio-rand-read-pressure randread 4k "$JOBS" "$DEPTH" --randrepeat=0; then
        add "Disk random read 4K pressure" "$(fio_metric read_iops) IOPS, $(fio_metric read_mib) MiB/s, p95 $(fio_metric read_p95_ms) ms"
      else
        add "Disk random read 4K pressure" "FAILED; see $LOGDIR/fio-rand-read-pressure.err"
      fi

      if fio_run fio-rand-write-pressure randwrite 4k "$JOBS" "$DEPTH" --randrepeat=0; then
        add "Disk random write 4K pressure" "$(fio_metric write_iops) IOPS, $(fio_metric write_mib) MiB/s, p95 $(fio_metric write_p95_ms) ms"
      else
        add "Disk random write 4K pressure" "FAILED; see $LOGDIR/fio-rand-write-pressure.err"
      fi

      if fio_run fio-rand-rw-pressure randrw 4k "$JOBS" "$DEPTH" --rwmixread=60 --randrepeat=0; then
        add "Disk random mixed 4K 60r/40w" "R $(fio_metric read_iops) / W $(fio_metric write_iops) IOPS, p95 $(fio_metric mixed_p95_ms) ms"
      else
        add "Disk random mixed 4K 60r/40w" "FAILED; see $LOGDIR/fio-rand-rw-pressure.err"
      fi

      if fio_run fio-fsync-write randwrite 4k 1 1 --fsync=1 --randrepeat=0; then
        add "Disk durable write 4K fsync" "$(fio_metric write_iops) writes/s, write p95 $(fio_metric write_p95_ms) ms, sync p95 $(fio_metric sync_p95_ms) ms"
      else
        add "Disk durable write 4K fsync" "FAILED; see $LOGDIR/fio-fsync-write.err"
      fi
    fi
  fi
else
  add "fio disk tests" "fio or python3 not installed; skipped"
fi

trap - EXIT
cleanup

echo
echo "Done. TSV summary: $RESULTS"
