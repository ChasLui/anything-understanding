#!/usr/bin/env bash
# Host facts for one Mac. One pass over the local read-only channels, one shape.
#   sysfacts.sh            # human summary
#   sysfacts.sh --json     # machine-readable (stable keys, unmeasured = null)
#
# Why this exists: "what Mac is this" has no single command. sw_vers knows the OS,
# sysctl the model and memory, system_profiler the chip, df the free space, pmset
# the power, csrutil/fdesetup the security posture. This folds them into one
# object and labels every number with where it came from.
#
# Read-only: nothing here writes state, prompts, or needs sudo.
# Units: memory and disk are bytes in JSON; human output uses binary units
# (GiB = 1024^3, TiB = 1024^4), matching `df -h` and `hw.memsize`.
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: sysfacts.sh [--json]

  os:       product name, version, build (sw_vers)
  kernel:   Darwin kernel release + arch (uname), model id (sysctl hw.model)
  chip:     chip name (system_profiler SPHardwareDataType), cores (sysctl +
            system_profiler), memory bytes (sysctl hw.memsize)
  disk:     total/free bytes and type on / (df -k /, mount)
  power:    supply source and battery percent (pmset -g batt); null if no battery
  security: SIP (csrutil) and FileVault (fdesetup) state
  uptime:   seconds since boot (sysctl kern.boottime math)

Exit: 0 ok, 1 usage, 2 unsupported host (not macOS), 3 required tool missing.
EOF
}

as_json=0
while [ $# -gt 0 ]; do
  case "$1" in
    --json) as_json=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*)
      echo "sysfacts.sh: unknown option: $1" >&2
      usage
      exit 1
      ;;
    *)
      echo "sysfacts.sh: unexpected argument: $1" >&2
      usage
      exit 1
      ;;
  esac
  shift
done

[ "$(uname -s)" = "Darwin" ] || {
  echo "sysfacts.sh: macOS only (this is $(uname -s))" >&2
  exit 2
}
command -v sw_vers >/dev/null 2>&1 || {
  echo "sysfacts.sh: needs sw_vers (macOS system tool)" >&2
  exit 3
}
command -v python3 >/dev/null 2>&1 || {
  echo "sysfacts.sh: needs python3" >&2
  exit 3
}

tmp=$(mktemp -d "${TMPDIR:-/tmp}/sysfacts.XXXXXX")
trap 'rm -r "$tmp"' EXIT

# Capture stdout only; a missing key (e.g. hw.perflevel1 on Intel) must leave an
# empty file, not an error string that looks like a value.
capture() {
  local out=$1
  shift
  "$@" >"$out" 2>/dev/null || true
}

capture "$tmp/sw_vers" sw_vers
capture "$tmp/uname_r" uname -r
capture "$tmp/uname_m" uname -m
capture "$tmp/hw_model" sysctl -n hw.model
capture "$tmp/hw_memsize" sysctl -n hw.memsize
capture "$tmp/hw_ncpu" sysctl -n hw.ncpu
capture "$tmp/perf0" sysctl -n hw.perflevel0.logicalcpu
capture "$tmp/perf1" sysctl -n hw.perflevel1.logicalcpu
capture "$tmp/df" df -k /
capture "$tmp/pmset" pmset -g batt
capture "$tmp/csrutil" csrutil status
capture "$tmp/fdesetup" fdesetup status
capture "$tmp/boottime" sysctl -n kern.boottime
mount 2>/dev/null | grep ' on / ' >"$tmp/mount_root" 2>/dev/null || true

# The JSON form is fast (~0.3 s) and is what we want; older macOS may not know
# -json, so fall back to the text form and record which one was parsed.
if ! system_profiler SPHardwareDataType -json >"$tmp/sp.json" 2>/dev/null ||
  ! python3 -c 'import json, sys; sys.exit(0 if json.load(open(sys.argv[1], encoding="utf-8")).get("SPHardwareDataType") else 1)' "$tmp/sp.json" 2>/dev/null; then
  system_profiler SPHardwareDataType >"$tmp/sp.txt" 2>/dev/null || true
fi

python3 - "$tmp" "$as_json" <<'PY'
import json
import os
import re
import sys
import time

tmp, json_flag = sys.argv[1], sys.argv[2] == "1"


def text(name):
    try:
        with open(os.path.join(tmp, name), encoding="utf-8", errors="replace") as fh:
            return fh.read().strip()
    except OSError:
        return ""


def as_int(raw):
    raw = raw.strip()
    return int(raw) if raw.isdigit() else None


notes = []


def sw_value(key):
    for line in text("sw_vers").splitlines():
        name, _, value = line.partition(":")
        if name.strip() == key:
            return value.strip() or None
    return None


os_name = sw_value("ProductName")
os_version = sw_value("ProductVersion")
os_build = sw_value("BuildVersion")
if not (os_name and os_version and os_build):
    notes.append("os identity incomplete: sw_vers lacks ProductName/ProductVersion/BuildVersion")

kernel = text("uname_r") or None
arch = text("uname_m") or None
if kernel is None:
    notes.append("kernel not reported (uname -r)")
if arch is None:
    notes.append("arch not reported (uname -m)")

model_id = text("hw_model") or None
if model_id is None:
    notes.append("model_id not reported (sysctl hw.model)")

memory_bytes = as_int(text("hw_memsize"))
if memory_bytes is None:
    notes.append("memory_bytes not reported (sysctl hw.memsize)")

cores = as_int(text("hw_ncpu"))
perf = as_int(text("perf0"))
eff = as_int(text("perf1"))

# Chip name and the performance/efficiency split live in system_profiler.
chip = None
sp_text = text("sp.txt")
if sp_text:
    m = re.search(r"^\s*Chip:\s*(.+)$", sp_text, re.M)
    chip = m.group(1).strip() if m else None
    if cores is None:
        m = re.search(r"^\s*Total Number of Cores:\s*(\d+)", sp_text, re.M)
        cores = int(m.group(1)) if m else None
    if perf is None or eff is None:
        m = re.search(r"(\d+)\s*Performance and\s*(\d+)\s*Efficiency", sp_text, re.I)
        if m:
            if perf is None:
                perf = int(m.group(1))
            if eff is None:
                eff = int(m.group(2))
    notes.append("hardware details parsed from system_profiler text output (JSON form unavailable)")
else:
    try:
        entries = json.loads(text("sp.json")).get("SPHardwareDataType") or []
        info = entries[0] if entries and isinstance(entries[0], dict) else {}
    except ValueError:
        info = {}
    chip = info.get("chip_type") or None
    nums = [int(x) for x in re.findall(r"\d+", str(info.get("number_processors") or ""))]
    if nums:
        if cores is None:
            cores = nums[0]
        # "proc 10:0:8:2" = total:?:performance:efficiency
        if len(nums) >= 4:
            if perf is None:
                perf = nums[2]
            if eff is None:
                eff = nums[3]
if chip is None:
    notes.append("chip not reported by system_profiler")
if cores is None:
    notes.append("cpu_cores not reported")

df_line = None
for line in text("df").splitlines()[1:]:
    parts = line.split()
    if parts and parts[-1] == "/":
        df_line = parts
        break
disk_total = disk_free = disk_device = None
if df_line and len(df_line) >= 4:
    try:
        disk_total = int(df_line[1]) * 1024
        disk_free = int(df_line[3]) * 1024
        disk_device = df_line[0]
    except ValueError:
        disk_total = disk_free = disk_device = None
if disk_total is None or disk_free is None:
    notes.append("disk total/free not reported (df -k /)")

m = re.search(r" on / \(([^,)]+)", text("mount_root"))
filesystem = m.group(1).strip() if m else None
if filesystem is None:
    filesystem = disk_device
    if disk_device:
        notes.append("filesystem type not reported by mount; filesystem is the root device")

pmset = text("pmset")
m = re.search(r"drawing from '([^']+)'", pmset)
power_source = m.group(1).strip() if m else None
if power_source is None:
    notes.append("power source not reported (pmset -g batt)")
m = re.search(r"(\d+)%", pmset)
battery = int(m.group(1)) if m else None
if battery is None:
    notes.append("battery percent not reported: no battery, or pmset unavailable")

m = re.search(r"status:\s*(enabled|disabled)", text("csrutil"), re.I)
sip = m.group(1).lower() if m else None
if sip is None:
    notes.append("sip not reported (csrutil status)")
m = re.search(r"FileVault is (On|Off)", text("fdesetup"))
filevault = m.group(1) if m else None
if filevault is None:
    notes.append("filevault not reported (fdesetup status)")

m = re.search(r"\bsec\s*=\s*(\d+)", text("boottime"))
uptime_s = max(0, int(time.time()) - int(m.group(1))) if m else None
if uptime_s is None:
    notes.append("uptime_s not reported (sysctl kern.boottime)")

payload = {
    "os": {"name": os_name, "version": os_version, "build": os_build},
    "kernel": kernel,
    "arch": arch,
    "model_id": model_id,
    "chip": chip,
    "cpu_cores": cores,
    "cpu_cores_detail": {"performance": perf, "efficiency": eff},
    "memory_bytes": memory_bytes,
    "disk": {"total_bytes": disk_total, "free_bytes": disk_free, "filesystem": filesystem},
    "power": {"source": power_source, "battery_percent": battery},
    "sip": sip,
    "filevault": filevault,
    "uptime_s": uptime_s,
    "notes": notes,
}

if json_flag:
    json.dump(payload, sys.stdout, ensure_ascii=False, indent=2)
    sys.stdout.write("\n")
    raise SystemExit(0)


def human_bytes(n):
    if n is None:
        return "?"
    # 3 significant digits, like `df -h`: 808 GiB, 1.8 TiB, 64 GiB.
    for unit, scale in (("TiB", 2**40), ("GiB", 2**30), ("MiB", 2**20), ("KiB", 2**10)):
        if n >= scale:
            value = n / scale
            value_s = "%.0f" % value if value >= 100 else "%.1f" % value
            if value_s.endswith(".0"):
                value_s = value_s[:-2]
            return "%s %s" % (value_s, unit)
    return "%d B" % n


def human_uptime(seconds):
    if seconds is None:
        return "?"
    minutes, sec = divmod(seconds, 60)
    hours, minutes = divmod(minutes, 60)
    days, hours = divmod(hours, 24)
    parts = []
    if days:
        parts.append("%dd" % days)
    if hours:
        parts.append("%dh" % hours)
    if minutes:
        parts.append("%dm" % minutes)
    if not parts:
        parts.append("%ds" % sec)
    return "%s (%d s)" % (" ".join(parts), seconds)


def show(value):
    return "?" if value is None else str(value)


cores_text = show(cores)
if perf is not None or eff is not None:
    cores_text += " (%s performance + %s efficiency)" % (show(perf), show(eff))

out = [
    "os: %s %s (%s)" % (show(os_name), show(os_version), show(os_build)),
    "kernel: %s  arch: %s  model: %s" % (show(kernel), show(arch), show(model_id)),
    "chip: %s  cores: %s  memory: %s" % (show(chip), cores_text, human_bytes(memory_bytes)),
    "disk: %s total, %s free on / (%s)"
    % (human_bytes(disk_total), human_bytes(disk_free), show(filesystem)),
    "power: %s, battery %s"
    % (show(power_source), "?" if battery is None else "%d%%" % battery),
    "sip: %s  filevault: %s" % (show(sip), show(filevault)),
    "uptime: %s" % human_uptime(uptime_s),
]
out.extend("note: %s" % note for note in notes)
print("\n".join(out))
PY
