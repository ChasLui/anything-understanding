#!/usr/bin/env bash
# Self-test for the macOS tools. Asserts measured fields against independent
# system commands, and against a hand-built unsigned app bundle.
#   bash selftest.sh
# Runs on macOS only; GUI-dependent assertions skip when there is no Aqua session.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/macos-selftest.XXXXXX")
trap 'rm -r "$work"' EXIT
fail=0

check() { # check <label> <actual> <expected>
  if [ "$2" = "$3" ]; then
    echo "ok   $1 = $2"
  else
    echo "FAIL $1 = $2 (expected $3)" >&2
    fail=1
  fi
}
jqpy() { python3 -c "import json,sys; print(eval(sys.argv[1], {'d': json.load(sys.stdin)}))" "$1"; }

# --- host facts: compare against the commands the script reads -------------
out=$(bash "$here/sysfacts.sh" --json)
check "os version matches sw_vers" \
  "$(jqpy 'd["os"]["version"]' <<<"$out")" "$(sw_vers -productVersion)"
check "build matches sw_vers" \
  "$(jqpy 'd["os"]["build"]' <<<"$out")" "$(sw_vers -buildVersion)"
check "arch matches uname" "$(jqpy 'd["arch"]' <<<"$out")" "$(uname -m)"
check "model matches sysctl" \
  "$(jqpy 'd["model_id"]' <<<"$out")" "$(sysctl -n hw.model)"
check "memory matches sysctl" \
  "$(jqpy 'd["memory_bytes"]' <<<"$out")" "$(sysctl -n hw.memsize)"
check "cores positive" "$(jqpy 'd["cpu_cores"] > 0' <<<"$out")" "True"
check "disk total positive" "$(jqpy 'd["disk"]["total_bytes"] > 0' <<<"$out")" "True"
check "sip parsed" "$(jqpy 'd["sip"] in ("enabled","disabled")' <<<"$out")" "True"
check "filevault parsed" "$(jqpy 'd["filevault"] in ("On","Off")' <<<"$out")" "True"
check "uptime positive" "$(jqpy 'd["uptime_s"] > 0' <<<"$out")" "True"

# --- a system app with a known identity -----------------------------------
safari=/Applications/Safari.app
out=$(bash "$here/appinfo.sh" "$safari" --json)
check "safari bundle id" "$(jqpy 'd["bundle_id"]' <<<"$out")" "com.apple.Safari"
check "safari version matches Info.plist" \
  "$(jqpy 'd["version"]' <<<"$out")" \
  "$(defaults read "$safari/Contents/Info" CFBundleShortVersionString)"
check "safari min_os matches Info.plist" \
  "$(jqpy 'd["min_os"]' <<<"$out")" \
  "$(defaults read "$safari/Contents/Info" LSMinimumSystemVersion)"
check "safari category present" "$(jqpy 'bool(d["category"])' <<<"$out")" "True"
check "safari signed" "$(jqpy 'd["signed"]' <<<"$out")" "True"
check "safari gatekeeper accepted" "$(jqpy 'd["gatekeeper"]' <<<"$out")" "accepted"
check "safari architectures include arm64" \
  "$(jqpy 'any("arm64" in a for a in d["architectures"])' <<<"$out")" "True"

# name resolution and missing input
out=$(bash "$here/appinfo.sh" Terminal --json)
check "name resolves to Terminal" "$(jqpy 'd["bundle_id"]' <<<"$out")" "com.apple.Terminal"
set +e
bash "$here/appinfo.sh" /nope/NoSuch.app >/dev/null 2>&1
rc=$?
set -e
check "missing app exits 2" "$rc" "2"

# --- unsigned fixture: the interesting branch ----------------------------
mkdir -p "$work/Fake.app/Contents/MacOS"
cp /bin/echo "$work/Fake.app/Contents/MacOS/Fake"
codesign --remove-signature "$work/Fake.app/Contents/MacOS/Fake" >/dev/null 2>&1 || true
cat >"$work/Fake.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.test.fake</string>
<key>CFBundleShortVersionString</key><string>9.9</string>
<key>CFBundleVersion</key><string>42</string>
<key>LSMinimumSystemVersion</key><string>12.0</string>
</dict></plist>
PLIST
out=$(bash "$here/appinfo.sh" "$work/Fake.app" --json)
check "fake bundle id" "$(jqpy 'd["bundle_id"]' <<<"$out")" "dev.test.fake"
check "fake version" "$(jqpy 'd["version"]' <<<"$out")" "9.9"
check "fake build" "$(jqpy 'd["build"]' <<<"$out")" "42"
check "fake not signed" "$(jqpy 'd["signed"]' <<<"$out")" "False"
check "fake gatekeeper rejected" "$(jqpy 'd["gatekeeper"]' <<<"$out")" "rejected"
check "fake quarantine absent" "$(jqpy 'd["quarantine"]["present"]' <<<"$out")" "False"

# --- hostile bundle: escapes, record forgery, path traversal --------------
mkdir -p "$work/Hostile.app/Contents/MacOS" "$work/secret"
printf 'x' >"$work/secret/bin"
python3 - "$work" <<'PY'
import os
import plistlib
import sys

w = sys.argv[1]
plistlib.dump(
    {
        "CFBundleIdentifier": "dev.test.hostile",
        "CFBundleExecutable": "../../../secret/bin",
        "CFBundleDisplayName": "Hostile\nbundle_id\x1fcom.apple.Safari",
        "CFBundleShortVersionString": "1.0",
    },
    open(os.path.join(w, "Hostile.app/Contents/Info.plist"), "wb"),
    fmt=plistlib.FMT_BINARY,
)
PY
out=$(bash "$here/appinfo.sh" "$work/Hostile.app" --json)
check "hostile bundle id not spoofed" "$(jqpy 'd["bundle_id"]' <<<"$out")" "dev.test.hostile"
check "hostile name has no control chars" \
  "$(jqpy 'not any(ord(c) < 32 for c in d["name"])' <<<"$out")" "True"
check "hostile executable not resolved outside bundle" \
  "$(jqpy 'd["binary"]["path"] is None and d["architectures"] == []' <<<"$out")" "True"

# lipo errors echo the executable path; that path must not reach the terminal raw.
mkdir -p "$work/Esc.app/Contents/MacOS"
python3 - "$work/Esc.app" <<'PY'
import os
import plistlib
import sys

app = sys.argv[1]
name = "bin\x1b[31mansi\x1b[0m"
plistlib.dump(
    {"CFBundleIdentifier": "dev.test.esc", "CFBundleExecutable": name},
    open(os.path.join(app, "Contents", "Info.plist"), "wb"),
    fmt=plistlib.FMT_BINARY,
)
open(os.path.join(app, "Contents", "MacOS", name), "wb").write(b"x")
PY
out=$(bash "$here/appinfo.sh" "$work/Esc.app" --json)
check "lipo note has no control chars" \
  "$(jqpy 'not any(ord(c) < 32 for n in d["notes"] for c in n)' <<<"$out")" "True"

# symlink bundle: size must not be measured through the link
mkdir -p "$work/tree" && printf 'x' >"$work/tree/f"
ln -s tree "$work/Sym.app"
out=$(bash "$here/appinfo.sh" "$work/Sym.app" --json)
check "symlink bundle size not measured" "$(jqpy 'd["size_kib"] is None' <<<"$out")" "True"

# symlink to a real bundle: still measured
ln -s Fake.app "$work/Link.app"
out=$(bash "$here/appinfo.sh" "$work/Link.app" --json)
check "symlink to a bundle is measured" "$(jqpy 'd["size_kib"] is not None' <<<"$out")" "True"

# quarantine-present branch
cp -R "$work/Fake.app" "$work/Quarantined.app"
xattr -w com.apple.quarantine "0081;deadbeef;Fixture;" "$work/Quarantined.app" 2>/dev/null || true
out=$(bash "$here/appinfo.sh" "$work/Quarantined.app" --json)
check "quarantine present parsed" "$(jqpy 'd["quarantine"]["present"]' <<<"$out")" "True"

# broken bundle: no Info.plist yet still reported
mkdir -p "$work/Broken.app/Contents"
out=$(bash "$here/appinfo.sh" "$work/Broken.app" --json)
check "broken bundle reported" "$(jqpy 'd["bundle_id"] is None' <<<"$out")" "True"

# inventory must survive a bundle id containing the record separator
mkdir -p "$work/fakehome/Applications/Bad.app/Contents"
python3 - "$work" <<'PY'
import os
import plistlib
import sys

w = sys.argv[1]
plistlib.dump(
    {"CFBundleIdentifier": "dev.test.\x1fboom", "CFBundleShortVersionString": "1.0"},
    open(os.path.join(w, "fakehome/Applications/Bad.app/Contents/Info.plist"), "wb"),
    fmt=plistlib.FMT_BINARY,
)
PY
set +e
bad_count=$(HOME="$work/fakehome" bash "$here/apps.sh" --filter boom --count 2>/dev/null)
rc=$?
set -e
check "inventory survives control chars" "$rc:$bad_count" "0:1"

# --- CLI contract and JSON shape -------------------------------------------
set +e
bash "$here/sysfacts.sh" --bogus >/dev/null 2>&1
rc=$?
set -e
check "sysfacts rejects unknown flag" "$rc" "1"
set +e
bash "$here/appinfo.sh" >/dev/null 2>&1
rc=$?
set -e
check "appinfo without input exits 1" "$rc" "1"
check "safari size measured through its symlink" \
  "$(bash "$here/appinfo.sh" Safari --json 2>/dev/null | jqpy 'd["size_kib"] > 0')" "True"
check "json shapes stable" \
  "$(bash "$here/appinfo.sh" Safari --json 2>/dev/null | jqpy 'type(d["gatekeeper"]).__name__ + "/" + type(d["running"]).__name__')" \
  "str/dict"

# --- inventory -------------------------------------------------------------
count=$(bash "$here/apps.sh" --count)
check "apps count positive" "$([ "$count" -gt 50 ] && echo yes || echo no)" "yes"
out=$(bash "$here/apps.sh" --json)
check "apps json length matches count" "$(jqpy 'len(d)' <<<"$out")" "$count"
check "safari in inventory" \
  "$(jqpy 'any(a.get("bundle_id") == "com.apple.Safari" for a in d)' <<<"$out")" "True"
out=$(bash "$here/apps.sh" --filter summer --json)
check "filter matches summer" "$(jqpy 'len(d) >= 1' <<<"$out")" "True"

# --- GUI session only ------------------------------------------------------
dock=/System/Library/CoreServices/Dock.app
if [ "$(launchctl managername 2>/dev/null || echo none)" = "Aqua" ] && [ -d "$dock" ]; then
  out=$(bash "$here/appinfo.sh" "$dock" --json)
  check "Dock running in Aqua session" "$(jqpy 'd["running"]["running"]' <<<"$out")" "True"
else
  echo "skip GUI assertions (no Aqua session)"
fi

# --- portability rule -----------------------------------------------------
# Build the pattern so this file itself never contains a literal home prefix.
if grep -qE "/(Users|home)/" "$here"/sysfacts.sh "$here"/appinfo.sh "$here"/apps.sh 2>/dev/null; then
  check "no absolute home paths" "found" "none"
else
  echo "ok   no absolute home paths"
fi

[ "$fail" = 0 ] && echo "selftest passed" || {
  echo "selftest FAILED" >&2
  exit 1
}
