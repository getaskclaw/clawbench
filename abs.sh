#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C

VERSION="0.4.7"
TIME_START_EPOCH="$(date +%s)"
TIME_START_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
VCPU="$(nproc 2>/dev/null || echo 1)"

PROFILE="${PROFILE:-default}"
D="${D:-}"
T="${T:-$VCPU}"
SIZE="${SIZE:-auto}"
DIR="${DIR:-$PWD/.abs}"
CPU_PRIME="${CPU_PRIME:-20000}"
DIRECT="${DIRECT:-1}"
FIO_ENGINE="${FIO_ENGINE:-libaio}"
JOBS_ENV="${JOBS-}"
DEPTH="${DEPTH:-32}"
INSTALL="${INSTALL:-1}"
NET_INFO="${NET_INFO:-0}"
NETWORK="${NETWORK:-1}"
NETWORK_PROFILE="${NETWORK_PROFILE:-cloudflare}"
IPERF_SERVER="${IPERF_SERVER:-}"
IPERF_TIME="${IPERF_TIME:-5}"
IPERF_PARALLEL="${IPERF_PARALLEL:-2}"
VERBOSE="${VERBOSE:-0}"
JSON_PRINT="${JSON_PRINT:-0}"
JSON_FILE="${JSON_FILE:-}"
LOGDIR="${LOGDIR:-/tmp/abs-$(date -u +%Y%m%dT%H%M%SZ)-$$}"

RESULTS="$LOGDIR/results.tsv"
JSON_RESULT="$LOGDIR/result.json"
FIO_FILE="$DIR/abs.test"
FIO_BIN=""
JOBS=""
LAST_LOG=""
LAST_JSON=""
SCORE_TEXT="n/a"
LOCAL_SCORE_TEXT="n/a"
NETWORK_SCORE_TEXT="skipped"
VERDICT_TEXT="n/a"
INSTALL_ATTEMPTED="0"
MISSING_AFTER_INSTALL=""

usage() {
  cat <<EOF
ABS v$VERSION — AskClaw Benchmark Script

One-line run:
  curl -fsSL https://raw.githubusercontent.com/getaskclaw/abs/main/abs.sh | bash
  wget -qO- https://raw.githubusercontent.com/getaskclaw/abs/main/abs.sh | bash

Default profile targets under 3 minutes and includes a short network sanity check. No result upload.

Options:
  --quick              ~60s smoke profile
  --full               stronger 5–8 min profile
  -d, --duration SEC   seconds per timed test
  -z, --size SIZE      fio test file size, e.g. 512M, 2G, 8G; default auto
  -t, --threads N      CPU/memory threads; default detected vCPU ($T)
  -n, --no-install     do not install missing packages
  --net-info           check IPv4/IPv6 and external IP/ASN
  --no-net-info        skip external IP/ASN lookup (default)
  --network            run Cloudflare HTTP network sanity test (default)
  --network-full       Cloudflare + 3 public iperf3 regions
  --network-yabs       Cloudflare + full YABS public iperf3 list
  --no-network         skip network speed sanity test
  --iperf HOST[:PORT]  optional iperf3 send/recv against your own server
  --verbose            print full system/tool header
  --json               print JSON result at the end
  --json-file PATH     write JSON result to PATH as well as logdir
  -h, --help           help

Examples:
  curl -fsSL https://raw.githubusercontent.com/getaskclaw/abs/main/abs.sh | bash
  curl -fsSL https://raw.githubusercontent.com/getaskclaw/abs/main/abs.sh | bash -s -- --quick -n
  curl -fsSL https://raw.githubusercontent.com/getaskclaw/abs/main/abs.sh | bash -s -- --full -z 8G --json

Env overrides also work: PROFILE=full SIZE=8G INSTALL=0 bash abs.sh
EOF
}

D_SET=0
SIZE_SET=0
[ -n "$D" ] && D_SET=1
[ "$SIZE" != "auto" ] && SIZE_SET=1

while [ "$#" -gt 0 ]; do
  case "$1" in
    --quick) PROFILE="quick" ;;
    --full) PROFILE="full" ;;
    -d|--duration)
      shift; [ "$#" -gt 0 ] || { echo "Missing value for -d/--duration" >&2; exit 2; }
      D="$1"; D_SET=1 ;;
    -z|--size)
      shift; [ "$#" -gt 0 ] || { echo "Missing value for -z/--size" >&2; exit 2; }
      SIZE="$1"; SIZE_SET=1 ;;
    -t|--threads)
      shift; [ "$#" -gt 0 ] || { echo "Missing value for -t/--threads" >&2; exit 2; }
      T="$1" ;;
    -n|--no-install) INSTALL=0 ;;
    --net-info) NET_INFO=1 ;;
    --no-net-info) NET_INFO=0 ;;
    --network) NETWORK=1; NETWORK_PROFILE="cloudflare" ;;
    --network-full) NETWORK=1; NETWORK_PROFILE="full" ;;
    --network-yabs) NETWORK=1; NETWORK_PROFILE="yabs" ;;
    --no-network) NETWORK=0; NETWORK_PROFILE="none" ;;
    --iperf)
      shift; [ "$#" -gt 0 ] || { echo "Missing value for --iperf" >&2; exit 2; }
      IPERF_SERVER="$1"; NETWORK=1 ;;
    --verbose) VERBOSE=1 ;;
    --json) JSON_PRINT=1 ;;
    --json-file)
      shift; [ "$#" -gt 0 ] || { echo "Missing value for --json-file" >&2; exit 2; }
      JSON_FILE="$1" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

case "$PROFILE" in
  quick)
    PROFILE_TARGET="60s"
    [ "$D_SET" -eq 1 ] || D=5
    [ "$SIZE_SET" -eq 1 ] || SIZE=512M
    ;;
  default)
    PROFILE_TARGET="under 3 minutes"
    [ "$D_SET" -eq 1 ] || D=8
    ;;
  full)
    PROFILE_TARGET="5–8 minutes"
    [ "$D_SET" -eq 1 ] || D=30
    ;;
  *) echo "Invalid PROFILE: $PROFILE" >&2; exit 2 ;;
esac

is_pos_int() { [[ "${1:-}" =~ ^[1-9][0-9]*$ ]]; }
if ! is_pos_int "$D"; then echo "Invalid duration: $D" >&2; exit 2; fi
if ! is_pos_int "$T"; then echo "Invalid threads: $T" >&2; exit 2; fi
if ! is_pos_int "$DEPTH"; then echo "Invalid DEPTH: $DEPTH" >&2; exit 2; fi
if ! is_pos_int "$IPERF_TIME"; then echo "Invalid IPERF_TIME: $IPERF_TIME" >&2; exit 2; fi
if ! is_pos_int "$IPERF_PARALLEL"; then echo "Invalid IPERF_PARALLEL: $IPERF_PARALLEL" >&2; exit 2; fi
if [ "$NET_INFO" != "0" ] && [ "$NET_INFO" != "1" ]; then echo "Invalid NET_INFO: $NET_INFO" >&2; exit 2; fi
if [ "$NETWORK" != "0" ] && [ "$NETWORK" != "1" ]; then echo "Invalid NETWORK: $NETWORK" >&2; exit 2; fi
case "$NETWORK_PROFILE" in cloudflare|full|yabs|none) ;; *) echo "Invalid NETWORK_PROFILE: $NETWORK_PROFILE" >&2; exit 2 ;; esac
if [ "$VERBOSE" != "0" ] && [ "$VERBOSE" != "1" ]; then echo "Invalid VERBOSE: $VERBOSE" >&2; exit 2; fi

if [ -n "$JOBS_ENV" ]; then
  JOBS="$JOBS_ENV"
else
  JOBS=$(( T < 4 ? T : 4 ))
fi
if ! is_pos_int "$JOBS"; then echo "Invalid JOBS: $JOBS" >&2; exit 2; fi

mkdir -p "$LOGDIR" "$DIR"
printf 'Metric\tResult\n' > "$RESULTS"

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

human_kib() {
  awk -v kib="${1:-0}" 'BEGIN {
    n=kib+0; split("KiB MiB GiB TiB PiB", u, " "); i=1;
    while (n >= 1024 && i < 5) { n/=1024; i++ }
    if (i == 1) printf "%.0f %s", n, u[i]; else printf "%.1f %s", n, u[i]
  }'
}

auto_size() {
  local avail_kb avail_mib target_mib
  avail_kb="$(df -Pk "$DIR" 2>/dev/null | awk 'NR==2 {print $4+0}')"
  avail_mib=$(( ${avail_kb:-0} / 1024 ))

  # Default: about 1/10 free disk, bounded for sane one-line VPS runs.
  # Floor: 512M. Cap: default 1G, full 8G. Rounded down to a common fio size.
  local cap_mib=1024
  [ "$PROFILE" = "full" ] && cap_mib=8192
  target_mib=$(( avail_mib / 10 ))
  [ "$target_mib" -lt 512 ] && target_mib=512
  [ "$target_mib" -gt "$cap_mib" ] && target_mib="$cap_mib"

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
  if [ "$NETWORK" = "1" ] || [ "$NET_INFO" = "1" ]; then
    have curl || missing+=(curl)
  fi
  if [ "$NETWORK" = "1" ] && { [ -n "$IPERF_SERVER" ] || [ "$NETWORK_PROFILE" = "full" ] || [ "$NETWORK_PROFILE" = "yabs" ]; }; then
    have iperf3 || missing+=(iperf3)
  fi
  printf '%s\n' "${missing[@]}"
}

install_tools() {
  local missing
  missing="$(missing_tools | xargs 2>/dev/null || true)"
  [ -z "$missing" ] && return 0

  if [ "$INSTALL" != "1" ]; then
    MISSING_AFTER_INSTALL="$missing"
    return 0
  fi

  INSTALL_ATTEMPTED="1"
  echo "Missing tools: $missing"
  echo "Installing missing tools when possible... use -n/--no-install to skip installation."

  local curl_pkg="" iperf_pkg=""
  if [ "$NETWORK" = "1" ] || [ "$NET_INFO" = "1" ]; then
    curl_pkg="curl"
  fi
  if [ "$NETWORK" = "1" ] && { [ -n "$IPERF_SERVER" ] || [ "$NETWORK_PROFILE" = "full" ] || [ "$NETWORK_PROFILE" = "yabs" ]; }; then
    iperf_pkg="iperf3"
  fi

  if have apt-get; then
    sudo_cmd env DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null 2>"$LOGDIR/install-apt-update.err" || true
    sudo_cmd env DEBIAN_FRONTEND=noninteractive apt-get install -y sysbench fio python3 ca-certificates procps $curl_pkg $iperf_pkg \
      >"$LOGDIR/install-apt.log" 2>"$LOGDIR/install-apt.err" || true
  elif have dnf; then
    sudo_cmd dnf install -y sysbench fio python3 procps-ng $curl_pkg $iperf_pkg >"$LOGDIR/install-dnf.log" 2>"$LOGDIR/install-dnf.err" || true
  elif have yum; then
    sudo_cmd yum install -y epel-release >"$LOGDIR/install-yum-epel.log" 2>"$LOGDIR/install-yum-epel.err" || true
    sudo_cmd yum install -y sysbench fio python3 procps-ng $curl_pkg $iperf_pkg >"$LOGDIR/install-yum.log" 2>"$LOGDIR/install-yum.err" || true
  elif have pacman; then
    sudo_cmd pacman -Sy --noconfirm sysbench fio python procps $curl_pkg $iperf_pkg >"$LOGDIR/install-pacman.log" 2>"$LOGDIR/install-pacman.err" || true
  elif have apk; then
    sudo_cmd apk add --no-cache sysbench fio python3 procps $curl_pkg $iperf_pkg >"$LOGDIR/install-apk.log" 2>"$LOGDIR/install-apk.err" || true
  fi

  have_fio || true
  missing="$(missing_tools | xargs 2>/dev/null || true)"
  MISSING_AFTER_INSTALL="$missing"
  [ -z "$missing" ] || echo "Still missing after install attempt: $missing; affected tests will be skipped."
}

add() {
  printf '%-48s %s\n' "$1" "$2"
  printf '%s\t%s\n' "$1" "$2" >> "$RESULTS"
}

add_note() {
  printf '%-48s %s\n' "$1" "$2"
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

abs_local_score() {
  python3 - "$RESULTS" "$T" <<'PY'
import csv, math, re, sys
path = sys.argv[1]
threads = float(sys.argv[2]) if len(sys.argv) > 2 else 1.0
rows = {}
try:
    with open(path, newline='', encoding='utf-8', errors='replace') as f:
        for row in csv.reader(f, delimiter='\t'):
            if len(row) >= 2 and row[0] != 'Metric':
                rows[row[0]] = row[1]
except Exception:
    print('n/a')
    raise SystemExit

def first_num(text):
    text = text or ''
    low = text.lower()
    if any(word in low for word in ('failed', 'skipped', 'invalid', 'not enough', 'not installed')):
        return None
    m = re.search(r'[0-9]+(?:\.[0-9]+)?', text)
    return float(m.group(0)) if m else None

def metric(prefix):
    for k, v in rows.items():
        if k.startswith(prefix):
            return v
    return None

def clamp(x, lo=0, hi=3000):
    return max(lo, min(hi, x))

components = []
missing = []

single = first_num(metric('CPU single thread'))
all_cpu = first_num(metric('CPU all threads'))
if single and all_cpu and threads > 0:
    per_thread = all_cpu / threads
    cpu = 1000 * math.sqrt((single / 400.0) * (per_thread / 400.0))
    components.append(('cpu', clamp(cpu), 0.40))
else:
    missing.append('cpu')

mem_read = first_num(metric('Memory read'))
mem_write = first_num(metric('Memory write'))
if mem_read and mem_write:
    mem = 1000 * math.sqrt((mem_read / 30000.0) * (mem_write / 20000.0))
    components.append(('mem', clamp(mem), 0.15))
else:
    missing.append('mem')

qd1_read = first_num(metric('Disk random read 4K QD1'))
qd1_write = first_num(metric('Disk random write 4K QD1'))
if qd1_read and qd1_write:
    disk = 1000 * math.sqrt((qd1_read / 10000.0) * (qd1_write / 5000.0))
    components.append(('disk', clamp(disk), 0.30))
else:
    missing.append('disk')

fsync = first_num(metric('Disk durable write 4K fsync'))
if fsync:
    dur = 1000 * math.sqrt(fsync / 2000.0)
    components.append(('fsync', clamp(dur), 0.15))
else:
    missing.append('fsync')

if not components:
    print('n/a')
    raise SystemExit

total_w = sum(w for _, _, w in components)
score = round(sum(v * w for _, v, w in components) / total_w)
parts = ','.join(name for name, _, _ in components)
if missing:
    print(f'PARTIAL - not comparable: {score} (local only: {parts}; missing {",".join(missing)}; network excluded)')
else:
    print(f'FULL {score} (local only: {parts}; network excluded)')
PY
}

network_score() {
  if [ "$NETWORK" != "1" ]; then
    printf 'PARTIAL - not comparable: missing network (--no-network)'
    return 0
  fi
  NETWORK_PROFILE_IN="$NETWORK_PROFILE" IPERF_SERVER_IN="$IPERF_SERVER" python3 - "$RESULTS" <<'PY'
import csv, math, os, re, statistics, sys
rows = {}
try:
    with open(sys.argv[1], newline='', encoding='utf-8', errors='replace') as f:
        for row in csv.reader(f, delimiter='\t'):
            if len(row) >= 2 and row[0] != 'Metric':
                rows[row[0]] = row[1]
except Exception:
    print('n/a')
    raise SystemExit

def parse_num(v):
    low = (v or '').lower()
    if any(w in low for w in ('failed', 'skipped', 'not installed', 'missing')):
        return None
    m = re.search(r'[0-9]+(?:\.[0-9]+)?', v or '')
    return float(m.group(0)) if m else None

def first_num(prefix):
    for k, v in rows.items():
        if k.startswith(prefix):
            return parse_num(v)
    return None

def nums(prefix):
    out = []
    for k, v in rows.items():
        if k.startswith(prefix):
            n = parse_num(v)
            if n is not None:
                out.append(n)
    return out

lat = first_num('Network Cloudflare TTFB')
down = first_num('Network Cloudflare download')
up = first_num('Network Cloudflare upload')
missing = []
if lat is None: missing.append('ttfb')
if down is None: missing.append('download')
if up is None: missing.append('upload')
if missing:
    print('PARTIAL - not comparable: missing ' + ','.join(missing))
    raise SystemExit

lat_component = min(3.0, max(0.1, 100.0 / max(lat, 1.0)))
down_component = min(3.0, max(0.1, down / 100.0))
up_component = min(3.0, max(0.1, up / 50.0))
cf_score = round(1000 * (lat_component * down_component * up_component) ** (1/3))

send_vals = nums('Network iperf3 send')
recv_vals = nums('Network iperf3 recv')
profile = os.environ.get('NETWORK_PROFILE_IN', 'cloudflare')
custom = bool(os.environ.get('IPERF_SERVER_IN', ''))
expected = {'full': 3, 'yabs': 7}.get(profile, 0) + (1 if custom else 0)
requires_iperf = expected > 0

if send_vals and recv_vals and (not requires_iperf or (len(send_vals) >= expected and len(recv_vals) >= expected)):
    send = statistics.median(send_vals)
    recv = statistics.median(recv_vals)
    send_component = min(3.0, max(0.1, send / 500.0))
    recv_component = min(3.0, max(0.1, recv / 500.0))
    iperf_score = round(1000 * math.sqrt(send_component * recv_component))
    score = round(cf_score * 0.6 + iperf_score * 0.4)
    if profile == 'yabs':
        label = 'current YABS iperf3 list'
    elif profile == 'full':
        label = '3-region public iperf3'
    else:
        label = 'custom iperf3'
    print(f'FULL {score} (Cloudflare + {label}; cf {cf_score}, iperf {iperf_score})')
elif requires_iperf:
    pairs = min(len(send_vals), len(recv_vals))
    print(f'PARTIAL - not comparable: iperf3 results {pairs}/{expected} pairs')
else:
    print(f'SANITY {cf_score} (Cloudflare HTTP; included in ABS score)')
PY
}


abs_score() {
  python3 - "$LOCAL_SCORE_TEXT" "$NETWORK_SCORE_TEXT" <<'PY'
import re, sys
local_text, net_text = sys.argv[1], sys.argv[2]
ml = re.search(r'FULL\s+(\d+)', local_text or '')
mn = re.search(r'(?:FULL|SANITY)\s+(\d+)', net_text or '')
if not ml:
    print('PARTIAL - not comparable: missing local core')
    raise SystemExit
local = int(ml.group(1))
if not mn:
    print(f'PARTIAL - not comparable: {local} (local only; missing network)')
    raise SystemExit
network = int(mn.group(1))
score = round(local * 0.80 + network * 0.20)
print(f'FULL {score} (80% local + 20% network; local {local}, network {network})')
PY
}

abs_verdict() {
  python3 - "$SCORE_TEXT" "$RESULTS" "$VM_TYPE" <<'PY'
import csv, re, sys
score_text, results, vm_type = sys.argv[1], sys.argv[2], (sys.argv[3] or '').lower()
if score_text.startswith('PARTIAL') or score_text == 'n/a':
    print('INCOMPLETE - missing required benchmark sections')
    raise SystemExit
m = re.search(r'FULL\s+(\d+)', score_text)
score = int(m.group(1)) if m else 0
rows = {}
try:
    with open(results, newline='', encoding='utf-8', errors='replace') as f:
        for row in csv.reader(f, delimiter='\t'):
            if len(row) >= 2 and row[0] != 'Metric': rows[row[0]] = row[1]
except Exception:
    pass

def num(prefix):
    for k, v in rows.items():
        if k.startswith(prefix):
            mm = re.search(r'[0-9]+(?:\.[0-9]+)?', v)
            return float(mm.group(0)) if mm else None
    return None
fsync = num('Disk durable write 4K fsync')
qd1_write = num('Disk random write 4K QD1')
if score >= 1200:
    verdict = 'KEEP'
elif score >= 800:
    verdict = 'MAYBE'
else:
    verdict = 'AVOID'
why = []
if fsync is not None and fsync < 500:
    why.append('weak durable-write/fsync')
if 'openvz' in vm_type:
    why.append('OpenVZ/container storage can be cache-inflated')
if (qd1_write is not None and qd1_write > 100000) or (fsync is not None and fsync > 8000):
    why.append('very high write/fsync numbers; verify with --full before buying')
if why:
    print(f'{verdict} - {"; ".join(why)}')
else:
    print(f'{verdict} - practical VPS profile looks acceptable')
PY
}

check_ip() {
  local version="$1"
  if [ "$NET_INFO" != "1" ]; then
    printf 'skipped'
    return 0
  fi
  if have ping && ping -"$version" -c 1 -W 3 google.com >/dev/null 2>&1; then
    printf 'online'
    return 0
  fi
  if have curl && curl -"$version" -fsS --max-time 4 https://icanhazip.com >/dev/null 2>&1; then
    printf 'online'
    return 0
  fi
  printf 'offline/unknown'
}

ip_info_summary() {
  if [ "$NET_INFO" != "1" ]; then
    printf 'skipped'
    return 0
  fi
  if ! have curl; then
    printf 'curl missing'
    return 0
  fi
  local response
  response="$(curl -fsS --max-time 4 http://ip-api.com/json/ 2>/dev/null || true)"
  if [ -z "$response" ]; then
    printf 'unavailable'
    return 0
  fi
  if have python3; then
    IPINFO_RESPONSE="$response" python3 - <<'PY'
import json, os
try:
    d=json.loads(os.environ.get('IPINFO_RESPONSE',''))
except Exception:
    print('unavailable'); raise SystemExit
parts=[]
for key in ('isp','as','city','country'):
    val=d.get(key)
    if val: parts.append(str(val))
print(' | '.join(parts) if parts else 'unavailable')
PY
  else
    printf 'available; python3 missing for parse'
  fi
}

network_sanity() {
  if [ "$NETWORK" != "1" ]; then
    return 0
  fi
  if ! have curl; then
    add "Network sanity" "curl not installed; skipped"
    return 0
  fi

  local lat down up
  if lat="$(curl -fL -sS --max-time 8 -o /dev/null -w '%{time_starttransfer}' 'https://speed.cloudflare.com/__down?bytes=0' 2>"$LOGDIR/net-ttfb.err")" && awk -v x="$lat" 'BEGIN{exit !(x+0>0)}'; then
    add "Network Cloudflare TTFB" "$(awk -v s="$lat" 'BEGIN{printf "%.2f ms", s*1000}')"
  else
    add "Network Cloudflare TTFB" "FAILED; see $LOGDIR/net-ttfb.err"
  fi

  if down="$(curl -fL -sS --max-time 20 -o /dev/null -w '%{speed_download}' 'https://speed.cloudflare.com/__down?bytes=25000000' 2>"$LOGDIR/net-down.err")" && awk -v x="$down" 'BEGIN{exit !(x+0>0)}'; then
    add "Network Cloudflare download" "$(awk -v b="$down" 'BEGIN{printf "%.2f Mbps", b*8/1000000}')"
  else
    add "Network Cloudflare download" "FAILED; see $LOGDIR/net-down.err"
  fi

  if up="$(head -c 10000000 /dev/zero | curl -fL -sS --max-time 20 -o /dev/null -w '%{speed_upload}' -X POST --data-binary @- 'https://speed.cloudflare.com/__up' 2>"$LOGDIR/net-up.err")" && awk -v x="$up" 'BEGIN{exit !(x+0>0)}'; then
    add "Network Cloudflare upload" "$(awk -v b="$up" 'BEGIN{printf "%.2f Mbps", b*8/1000000}')"
  else
    add "Network Cloudflare upload" "FAILED; see $LOGDIR/net-up.err"
  fi
}

pick_port() {
  local range="$1" low high
  if [[ "$range" == *-* ]]; then
    low="${range%-*}"
    high="${range#*-}"
    printf '%s\n' $(( low + RANDOM % (high - low + 1) ))
  else
    printf '%s\n' "$range"
  fi
}

run_iperf_cmd() {
  if have timeout; then
    timeout 18 "$@"
  else
    "$@"
  fi
}

parse_iperf_bps() {
  python3 - "$1" "$2" <<'PY'
import json, sys
path, direction = sys.argv[1], sys.argv[2]
try:
    with open(path) as f:
        d=json.load(f)
    end=d.get('end', {})
    key='sum_sent' if direction == 'send' else 'sum_received'
    print(end.get(key, {}).get('bits_per_second') or end.get('sum', {}).get('bits_per_second') or 0)
except Exception:
    print(0)
PY
}

iperf_pair() {
  local host="$1" ports="$2" label="$3"
  local safe_label port attempt json bps ok
  safe_label="$(printf '%s' "$label" | tr -c 'A-Za-z0-9_.-' '_')"

  ok=0
  for attempt in 1 2; do
    port="$(pick_port "$ports")"
    json="$LOGDIR/iperf3-${safe_label}-send-${attempt}.json"
    if run_iperf_cmd iperf3 -J -t "$IPERF_TIME" -P "$IPERF_PARALLEL" -c "$host" -p "$port" >"$json" 2>"$json.err"; then
      bps="$(parse_iperf_bps "$json" send)"
      if awk -v b="$bps" 'BEGIN{exit !(b+0>0)}'; then
        add "Network iperf3 send $label" "$(awk -v b="$bps" 'BEGIN{printf "%.2f Mbps", b/1000000}')"
        ok=1
        break
      fi
    fi
  done
  [ "$ok" = "1" ] || add "Network iperf3 send $label" "FAILED; see $LOGDIR/iperf3-${safe_label}-send-*.err"

  ok=0
  for attempt in 1 2; do
    port="$(pick_port "$ports")"
    json="$LOGDIR/iperf3-${safe_label}-recv-${attempt}.json"
    if run_iperf_cmd iperf3 -J -R -t "$IPERF_TIME" -P "$IPERF_PARALLEL" -c "$host" -p "$port" >"$json" 2>"$json.err"; then
      bps="$(parse_iperf_bps "$json" recv)"
      if awk -v b="$bps" 'BEGIN{exit !(b+0>0)}'; then
        add "Network iperf3 recv $label" "$(awk -v b="$bps" 'BEGIN{printf "%.2f Mbps", b/1000000}')"
        ok=1
        break
      fi
    fi
  done
  [ "$ok" = "1" ] || add "Network iperf3 recv $label" "FAILED; see $LOGDIR/iperf3-${safe_label}-recv-*.err"
}

iperf_sanity() {
  [ "$NETWORK" = "1" ] || return 0
  if [ -z "$IPERF_SERVER" ] && [ "$NETWORK_PROFILE" != "full" ] && [ "$NETWORK_PROFILE" != "yabs" ]; then
    return 0
  fi
  if ! have iperf3; then
    add "Network iperf3" "iperf3 missing; skipped"
    return 0
  fi

  if [ -n "$IPERF_SERVER" ]; then
    local host port label
    if [[ "$IPERF_SERVER" == *:* && "$IPERF_SERVER" != \[* ]]; then
      host="${IPERF_SERVER%:*}"
      port="${IPERF_SERVER##*:}"
    else
      host="$IPERF_SERVER"
      port=5201
    fi
    label="custom $host:$port"
    iperf_pair "$host" "$port" "$label"
  fi

  if [ "$NETWORK_PROFILE" = "full" ]; then
    iperf_pair "speedtest.sin1.sg.leaseweb.net" "5201-5210" "Singapore Leaseweb"
    iperf_pair "lon.speedtest.clouvider.net" "5200-5209" "London Clouvider"
    iperf_pair "speedtest.nyc1.us.leaseweb.net" "5201-5210" "NYC Leaseweb"
  elif [ "$NETWORK_PROFILE" = "yabs" ]; then
    iperf_pair "lon.speedtest.clouvider.net" "5200-5209" "London Clouvider"
    iperf_pair "iperf-ams-nl.eranium.net" "5201-5210" "Amsterdam Eranium"
    iperf_pair "speedtest.uztelecom.uz" "5200-5209" "Tashkent Uztelecom"
    iperf_pair "speedtest.sin1.sg.leaseweb.net" "5201-5210" "Singapore Leaseweb"
    iperf_pair "la.speedtest.clouvider.net" "5200-5209" "Los_Angeles Clouvider"
    iperf_pair "speedtest.nyc1.us.leaseweb.net" "5201-5210" "NYC Leaseweb"
    iperf_pair "speedtest.sao1.edgoo.net" "9204-9240" "Sao_Paulo Edgoo"
  fi
}

dd_fallback() {
  if ! have dd; then
    add "Disk fallback dd" "dd not installed; skipped"
    return 0
  fi
  local dd_file="$DIR/abs-dd.test"
  local write_log="$LOGDIR/dd-write.log"
  local read_log="$LOGDIR/dd-read.log"
  rm -f "$dd_file" 2>/dev/null || true
  if dd if=/dev/zero of="$dd_file" bs=64M count=4 oflag=direct conv=fdatasync >"$write_log" 2>&1; then
    add "Disk fallback dd write" "$(awk 'END{print}' "$write_log") (not scored)"
  elif dd if=/dev/zero of="$dd_file" bs=64M count=4 conv=fdatasync >"$write_log" 2>&1; then
    add "Disk fallback dd write" "$(awk 'END{print}' "$write_log") (buffered; not scored)"
  else
    add "Disk fallback dd write" "FAILED; see $write_log"
  fi
  if [ -f "$dd_file" ]; then
    if dd if="$dd_file" of=/dev/null bs=64M iflag=direct >"$read_log" 2>&1; then
      add "Disk fallback dd read" "$(awk 'END{print}' "$read_log") (not scored)"
    elif dd if="$dd_file" of=/dev/null bs=64M >"$read_log" 2>&1; then
      add "Disk fallback dd read" "$(awk 'END{print}' "$read_log") (buffered; not scored)"
    else
      add "Disk fallback dd read" "FAILED; see $read_log"
    fi
  fi
  rm -f "$dd_file" 2>/dev/null || true
}

json_report() {
  [ -n "$JSON_FILE" ] && mkdir -p "$(dirname "$JSON_FILE")" 2>/dev/null || true
  ABS_JSON_TARGET="$JSON_RESULT" \
  ABS_JSON_COPY="$JSON_FILE" \
  ABS_VERSION="$VERSION" ABS_PROFILE="$PROFILE" ABS_TARGET="$PROFILE_TARGET" \
  ABS_START_UTC="$TIME_START_UTC" ABS_END_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  ABS_ELAPSED="$ELAPSED_SECONDS" ABS_HOST="$HOST" ABS_DISTRO="$DISTRO" ABS_KERNEL="$KERNEL" \
  ABS_CPU_MODEL="$CPU_MODEL" ABS_CPU_CORES="$CPU_CORES" ABS_CPU_FREQ="$CPU_FREQ" \
  ABS_AES_NI="$AES_NI" ABS_CPU_VIRT="$CPU_VIRT" ABS_RAM_KIB="$RAM_KIB" ABS_SWAP_KIB="$SWAP_KIB" \
  ABS_DISK_TOTAL_KB="$DISK_TOTAL_KB" ABS_DISK_FREE_KB="$DISK_FREE_KB" ABS_VM_TYPE="$VM_TYPE" \
  ABS_IPV4="$IPV4_STATUS" ABS_IPV6="$IPV6_STATUS" ABS_IP_INFO="$IP_INFO" \
  ABS_THREADS="$T" ABS_DURATION="$D" ABS_SIZE="$SIZE" ABS_INSTALL="$INSTALL" ABS_INSTALL_ATTEMPTED="$INSTALL_ATTEMPTED" \
  ABS_NET_INFO="$NET_INFO" ABS_NETWORK="$NETWORK" ABS_NETWORK_PROFILE="$NETWORK_PROFILE" \
  ABS_MISSING_TOOLS="$MISSING_AFTER_INSTALL" ABS_DIRECT="$DIRECT" ABS_FIO_ENGINE="$FIO_ENGINE" \
  ABS_JOBS="$JOBS" ABS_DEPTH="$DEPTH" ABS_IPERF_SERVER="$IPERF_SERVER" ABS_IPERF_TIME="$IPERF_TIME" ABS_IPERF_PARALLEL="$IPERF_PARALLEL" \
  ABS_SCORE="$SCORE_TEXT" ABS_LOCAL_SCORE="$LOCAL_SCORE_TEXT" ABS_NETWORK_SCORE="$NETWORK_SCORE_TEXT" ABS_VERDICT="$VERDICT_TEXT" \
  python3 - "$RESULTS" <<'PY'
import csv, json, os, re, shutil, sys
results_path = sys.argv[1]
rows = []
try:
    with open(results_path, newline='', encoding='utf-8', errors='replace') as f:
        for row in csv.reader(f, delimiter='\t'):
            if len(row) >= 2 and row[0] != 'Metric':
                rows.append({'metric': row[0], 'result': row[1]})
except Exception:
    pass

def env(name, default=''):
    return os.environ.get(name, default)

def env_int(name):
    try: return int(float(env(name, '0') or 0))
    except Exception: return 0
score_text = env('ABS_SCORE')
local_score_text = env('ABS_LOCAL_SCORE')
score_status = 'none'
score_value = None
missing_components = []
if score_text.startswith('FULL'):
    score_status = 'full'
    m = re.search(r'FULL\s+(\d+)', score_text)
    if m: score_value = int(m.group(1))
elif score_text.startswith('PARTIAL'):
    score_status = 'partial'
    m = re.search(r':\s*(\d+)', score_text)
    if m: score_value = int(m.group(1))
    mm = re.search(r'missing ([^;)]*)', score_text)
    if mm: missing_components = [x for x in mm.group(1).split(',') if x]
verdict_text = env('ABS_VERDICT')
network_score_text = env('ABS_NETWORK_SCORE')
verdict_code = verdict_text.split(' ', 1)[0] if verdict_text else 'UNKNOWN'
verdict_reason = verdict_text.split(' - ', 1)[1] if ' - ' in verdict_text else verdict_text
out = {
    'version': env('ABS_VERSION'),
    'profile': env('ABS_PROFILE'),
    'target_time': env('ABS_TARGET'),
    'started_utc': env('ABS_START_UTC'),
    'ended_utc': env('ABS_END_UTC'),
    'elapsed_seconds': env_int('ABS_ELAPSED'),
    'system': {
        'host': env('ABS_HOST'), 'distro': env('ABS_DISTRO'), 'kernel': env('ABS_KERNEL'),
        'cpu_model': env('ABS_CPU_MODEL'), 'cpu_cores': env('ABS_CPU_CORES'), 'cpu_freq': env('ABS_CPU_FREQ'),
        'aes_ni': env('ABS_AES_NI') == 'enabled', 'cpu_virtualization': env('ABS_CPU_VIRT') == 'enabled',
        'ram_kib': env_int('ABS_RAM_KIB'), 'swap_kib': env_int('ABS_SWAP_KIB'),
        'disk_total_kb': env_int('ABS_DISK_TOTAL_KB'), 'disk_free_kb': env_int('ABS_DISK_FREE_KB'),
        'vm_type': env('ABS_VM_TYPE'),
    },
    'network_identity': {'ipv4': env('ABS_IPV4'), 'ipv6': env('ABS_IPV6'), 'ip_info': env('ABS_IP_INFO')},
    'mode': {
        'threads': env_int('ABS_THREADS'), 'duration_seconds': env_int('ABS_DURATION'), 'fio_size': env('ABS_SIZE'),
        'install': env('ABS_INSTALL') == '1', 'install_attempted': env('ABS_INSTALL_ATTEMPTED') == '1',
        'net_info': env('ABS_NET_INFO') == '1', 'network': env('ABS_NETWORK') == '1', 'network_profile': env('ABS_NETWORK_PROFILE'),
        'missing_tools': env('ABS_MISSING_TOOLS'), 'direct': env('ABS_DIRECT'), 'fio_engine': env('ABS_FIO_ENGINE'),
        'pressure_jobs': env_int('ABS_JOBS'), 'pressure_depth': env_int('ABS_DEPTH'),
        'iperf_server': env('ABS_IPERF_SERVER'), 'iperf_time': env_int('ABS_IPERF_TIME'), 'iperf_parallel': env_int('ABS_IPERF_PARALLEL'),
    },
    'score': {
        'text': score_text,
        'scope': 'local_plus_network',
        'includes_network': True,
        'status': score_status,
        'value': score_value,
        'comparable': score_status == 'full',
        'missing_components': missing_components,
    },
    'local_score': {'text': local_score_text, 'scope': 'local_cpu_memory_disk_fsync'},
    'network_score': {'text': network_score_text, 'included_in_score': True, 'weight': 0.20},
    'verdict': {'text': verdict_text, 'code': verdict_code, 'reason': verdict_reason},
    'results': rows,
}
target = env('ABS_JSON_TARGET')
with open(target, 'w', encoding='utf-8') as f:
    json.dump(out, f, ensure_ascii=False, indent=2)
    f.write('\n')
copy = env('ABS_JSON_COPY')
if copy:
    try:
        shutil.copyfile(target, copy)
    except Exception as e:
        print(f'warning: could not copy JSON to {copy}: {e}', file=sys.stderr)
print(target)
PY
}

cleanup() {
  rm -f "$FIO_FILE" "$FIO_FILE".* "$DIR/abs-dd.test" 2>/dev/null || true
}
trap cleanup EXIT

if [ "$NET_INFO" = "1" ]; then
  echo "Network info lookup enabled: checks IPv4/IPv6 and external IP/ASN. Use --no-net-info to skip."
fi
if [ "$NETWORK" = "1" ] && [ "$VERBOSE" = "1" ]; then
  echo "Network sanity enabled: downloads 25 MB and uploads 10 MB of zero data to Cloudflare. No result upload."
fi
if [ "$NETWORK_PROFILE" = "full" ]; then
  echo "Network-full enabled: adds 3 short public iperf3 regional tests. Public iperf3 can be noisy."
elif [ "$NETWORK_PROFILE" = "yabs" ]; then
  echo "YABS-style network enabled: adds the full public YABS iperf3 list. This is slower/noisier."
fi
if [ -n "$IPERF_SERVER" ]; then
  echo "iperf3 enabled against $IPERF_SERVER for optional send/recv network signal."
fi

install_tools
have_fio || true

HOST="$(hostname 2>/dev/null || true)"
KERNEL="$(uname -srmo 2>/dev/null || uname -a 2>/dev/null || echo unknown)"
DISTRO="$(awk -F= '/^PRETTY_NAME=/ {gsub(/^"|"$/, "", $2); print $2; exit}' /etc/os-release 2>/dev/null || echo unknown)"
UPTIME_TEXT="$(uptime -p 2>/dev/null | sed 's/^up //' || awk '{printf "%s seconds", int($1)}' /proc/uptime 2>/dev/null || echo unknown)"
CPU_MODEL="$(awk -F: '/model name/ {gsub(/^[ \t]+/, "", $2); print $2; exit}' /proc/cpuinfo 2>/dev/null || lscpu 2>/dev/null | awk -F: '/Model name/ {gsub(/^[ \t]+/, "", $2); print $2; exit}' || echo unknown)"
CPU_CORES="$(awk -F: '/model name/ {core++} END {print core+0}' /proc/cpuinfo 2>/dev/null || echo "$VCPU")"
[ "${CPU_CORES:-0}" = "0" ] && CPU_CORES="$VCPU"
CPU_FREQ="$(awk -F: '/cpu MHz/ {freq=$2} END {gsub(/^[ \t]+/, "", freq); if (freq) print freq " MHz"}' /proc/cpuinfo 2>/dev/null || echo unknown)"
AES_NI="$(grep -qiE '(^| )aes( |$)' /proc/cpuinfo 2>/dev/null && echo enabled || echo disabled)"
CPU_VIRT="$(grep -qiE '(^| )(vmx|svm)( |$)' /proc/cpuinfo 2>/dev/null && echo enabled || echo disabled)"
RAM_KIB="$(free 2>/dev/null | awk '/^Mem:/ {print $2+0}' || echo 0)"
SWAP_KIB="$(free 2>/dev/null | awk '/^Swap:/ {print $2+0}' || echo 0)"
RAM_TEXT="$(human_kib "$RAM_KIB")"
SWAP_TEXT="$(human_kib "$SWAP_KIB")"
DISK_FREE_KB="$(df -Pk "$DIR" 2>/dev/null | awk 'NR==2 {print $4+0}' || echo 0)"
DISK_TOTAL_KB="$(df -Pk "$DIR" 2>/dev/null | awk 'NR==2 {print $2+0}' || echo 0)"
DISK_TEXT="$(human_kib "$DISK_FREE_KB") free / $(human_kib "$DISK_TOTAL_KB") total"
VM_TYPE="$(systemd-detect-virt 2>/dev/null || echo unknown)"

IPV4_STATUS="$(check_ip 4)"
IPV6_STATUS="$(check_ip 6)"
IP_INFO="$(ip_info_summary)"
NETWORK_MODE="skipped (use --network)"
[ "$NETWORK" = "1" ] && NETWORK_MODE="Cloudflare HTTP sanity"
[ "$NETWORK" = "1" ] && [ "$NETWORK_PROFILE" = "full" ] && NETWORK_MODE="Cloudflare HTTP sanity + 3 public iperf3 regions"
[ "$NETWORK" = "1" ] && [ "$NETWORK_PROFILE" = "yabs" ] && NETWORK_MODE="Cloudflare HTTP sanity + YABS public iperf3 list"
[ "$NETWORK" = "1" ] && [ -n "$IPERF_SERVER" ] && NETWORK_MODE="$NETWORK_MODE + iperf3($IPERF_SERVER)"

if [ "$VERBOSE" = "1" ]; then
  cat <<EOF
# ABS v$VERSION
Profile  : $PROFILE ($PROFILE_TARGET)
Date UTC : $(date -u)
Host     : $HOST
Uptime   : $UPTIME_TEXT
Distro   : $DISTRO
Kernel   : $KERNEL
CPU      : $CPU_MODEL
CPU cores: $CPU_CORES @ $CPU_FREQ
AES-NI   : $AES_NI
VM-x/SVM : $CPU_VIRT
vCPU     : $VCPU
Threads  : $T
RAM      : $RAM_TEXT
Swap     : $SWAP_TEXT
Disk     : $DISK_TEXT on $DIR
VM Type  : $VM_TYPE
IPv4/IPv6: $IPV4_STATUS / $IPV6_STATUS
IP info  : $IP_INFO
Network  : $NETWORK_MODE
Fio size : $SIZE
Mode     : install=$INSTALL, direct=$DIRECT, fio_engine=$FIO_ENGINE, pressure_jobs=$JOBS, pressure_depth=$DEPTH, net_info=$NET_INFO, network=$NETWORK, network_profile=$NETWORK_PROFILE, iperf=${IPERF_SERVER:-none}
Duration : ${D}s/timed test
Tools    : sysbench=$(sysbench --version 2>/dev/null | awk '{print $2}' || echo no), fio=$([ -n "$FIO_BIN" ] && "$FIO_BIN" --version 2>/dev/null || echo no), python3=$(python3 --version 2>/dev/null | awk '{print $2}' || echo no), curl=$(curl --version 2>/dev/null | awk 'NR==1{print $2}' || echo no)
Logs     : $LOGDIR
EOF
else
  cat <<EOF
# ABS v$VERSION — $PROFILE ($PROFILE_TARGET)
Host     : $HOST | $VCPU vCPU | $RAM_TEXT RAM | $VM_TYPE
CPU      : $CPU_MODEL
Disk     : $(human_kib "$DISK_FREE_KB") free | fio $SIZE | ${D}s/test
Network  : $NETWORK_MODE
Logs     : $LOGDIR
EOF
fi

printf '\n%-48s %s\n' "Metric" "Result"
printf '%-48s %s\n' "------" "------"

if [ "$INSTALL_ATTEMPTED" = "1" ]; then
  add "Install mode" "package install attempted before benchmark; use -n for no-mutation mode"
else
  add "Install mode" "no package install attempted"
fi

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
      dd_fallback
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
  dd_fallback
fi

network_sanity
iperf_sanity

if have python3; then
  LOCAL_SCORE_TEXT="$(abs_local_score)"
  NETWORK_SCORE_TEXT="$(network_score)"
  SCORE_TEXT="$(abs_score)"
  add "ABS SCORE" "$SCORE_TEXT"
  add "Local component" "$LOCAL_SCORE_TEXT"
  add "Network component" "$NETWORK_SCORE_TEXT"
  VERDICT_TEXT="$(abs_verdict)"
  add "ABS VERDICT" "$VERDICT_TEXT"
else
  SCORE_TEXT="n/a (python3 missing)"
  LOCAL_SCORE_TEXT="n/a (python3 missing)"
  NETWORK_SCORE_TEXT="n/a (python3 missing)"
  VERDICT_TEXT="INCOMPLETE - python3 missing"
  add "ABS SCORE" "$SCORE_TEXT"
  add "Local component" "$LOCAL_SCORE_TEXT"
  add "Network component" "$NETWORK_SCORE_TEXT"
  add "ABS VERDICT" "$VERDICT_TEXT"
fi
add_note "Score note" "ABS score includes network: 80% local CPU/memory/disk/fsync + 20% network. Default network is Cloudflare sanity; --network-full adds 3 public iperf3 regions; --network-yabs uses the YABS list. Use --no-network only for a non-comparable local-only run."
add_note "Privacy note" "No result upload. Default network sanity uses Cloudflare (25 MB down, 10 MB zero-data up); package install may contact distro mirrors unless -n is used. --net-info calls IP/ASN endpoints; --no-network skips speed checks."

ELAPSED_SECONDS=$(( $(date +%s) - TIME_START_EPOCH ))
if have python3; then
  JSON_WRITTEN="$(json_report)"
  add_note "JSON result" "$JSON_WRITTEN"
  [ -n "$JSON_FILE" ] && add_note "JSON copy" "$JSON_FILE"
  if [ "$JSON_PRINT" = "1" ]; then
    printf '\nJSON:\n'
    python3 -m json.tool "$JSON_RESULT" 2>/dev/null || true
  fi
else
  add_note "JSON result" "n/a (python3 missing)"
fi

printf '\n%s\n' "==================== ABS RESULT ===================="
printf 'SCORE   : %s\n' "$SCORE_TEXT"
printf 'VERDICT : %s\n' "$VERDICT_TEXT"
printf 'LOCAL   : %s\n' "$LOCAL_SCORE_TEXT"
printf 'NETWORK : %s\n' "$NETWORK_SCORE_TEXT"
printf '%s\n' "===================================================="

trap - EXIT
cleanup

printf '\nCompleted in %dm %02ds. TSV summary: %s\n' $((ELAPSED_SECONDS / 60)) $((ELAPSED_SECONDS % 60)) "$RESULTS"
