#!/usr/bin/env bash
# Deep, read-only look at one installed app bundle.
#   appinfo.sh Safari                     # resolve the name in the standard dirs
#   appinfo.sh /Applications/Safari.app   # explicit bundle path
#   appinfo.sh Summer --json              # machine-readable (stable keys, unknown = null)
#
# Every verdict is quoted with its source, and the sources do not prove the same
# thing: `codesign -dv` reports that a signature is present (it does not verify
# it), `spctl` is the local policy verdict (not a notarization lookup), and an
# absent quarantine xattr means "no download marker", not "safe". The script
# says so in the output instead of collapsing them into one "valid" boolean.
#
# Exit codes: 0 ok | 1 usage | 2 app not found / not a bundle | 3 tool missing.
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: appinfo.sh <app-path|app-name> [--json]

  identity    name, path, CFBundleIdentifier, version/build, minimum macOS,
              LSApplicationCategoryType
  binary      CFBundleExecutable path, lipo architectures, du -sk size
  signing     codesign -dv: Identifier, first 3 Authorities, TeamIdentifier, flags
  gatekeeper  spctl -a -vv verdict (local policy, not notarization proof)
  quarantine  com.apple.quarantine xattr, raw value
  running     exact bundleID match in `lsappinfo list`, with pid when parseable

Names are resolved from /Applications, ~/Applications, /System/Applications and
/System/Applications/Utilities, with or without the .app suffix.

exit: 0 ok | 1 usage | 2 not found / not a bundle | 3 required tool missing
EOF
}

as_json=0
input=""
while [ $# -gt 0 ]; do
  case $1 in
    --json) as_json=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*)
      echo "appinfo.sh: unknown option: $1" >&2
      usage
      exit 1
      ;;
    *)
      if [ -n "$input" ]; then
        echo "appinfo.sh: one app at a time" >&2
        exit 1
      fi
      input=$1
      ;;
  esac
  shift
done
if [ -z "$input" ]; then
  usage
  exit 1
fi

[ -x /usr/libexec/PlistBuddy ] || {
  echo "appinfo.sh: needs /usr/libexec/PlistBuddy" >&2
  exit 3
}
for tool in lipo codesign spctl xattr du lsappinfo python3; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "appinfo.sh: needs $tool (macOS system tool)" >&2
    exit 3
  }
done

# A bundle path (with or without .app) or a bare name looked up in the standard
# directories. `-d` follows symlinks, so /Applications/Safari.app resolves.
resolve_app() {
  local want dir cand
  want=$1
  if [[ $want == */* ]]; then
    for cand in "$want" "$want.app"; do
      if [ -d "$cand" ]; then
        printf '%s\n' "$cand"
        return 0
      fi
      # A regular *.app file is a broken bundle, not a missing one.
      if [ -e "$cand" ] && [[ $cand == *.app ]]; then
        printf '%s\n' "$cand"
        return 0
      fi
    done
    return 1
  fi
  for dir in /Applications "${HOME:-/nonexistent}/Applications" /System/Applications /System/Applications/Utilities; do
    if [ -d "$dir/$want.app" ]; then
      printf '%s\n' "$dir/$want.app"
      return 0
    fi
    if [ -e "$dir/$want.app" ]; then
      printf '%s\n' "$dir/$want.app"
      return 0
    fi
    if [ -d "$dir/$want" ]; then
      printf '%s\n' "$dir/$want"
      return 0
    fi
  done
  return 1
}

app=""
if ! app=$(resolve_app "$input"); then
  if [ -e "$input" ] || [ -L "$input" ]; then
    echo "appinfo.sh: not an app bundle: $input" >&2
  else
    echo "appinfo.sh: app not found: $input" >&2
  fi
  exit 2
fi
app=${app%/}
case $app in
  *.app) ;;
  *)
    echo "appinfo.sh: not an app bundle: $input" >&2
    exit 2
    ;;
esac

tmp=$(mktemp -d "${TMPDIR:-/tmp}/appinfo.XXXXXX")
trap 'rm -r "$tmp"' EXIT

add() {
  # Bundle-supplied text is untrusted: strip control characters so it cannot
  # forge a new \x1f record or emit terminal escape sequences.
  local v=${2//[[:cntrl:]]/ }
  printf '%s\x1f%s\n' "$1" "$v" >>"$tmp/rec"
}
: >"$tmp/rec"

trimmed=${app%/}
base=${trimmed##*/}
name_default=${base%.app}

plist="$app/Contents/Info.plist"
plist_reader="none"
plist_ok=0
if [ -f "$plist" ]; then
  plist_ok=1
  plist_reader="PlistBuddy"
fi

# PlistBuddy is the primary reader; `defaults read` covers a plist PlistBuddy
# refuses. Only call PlistBuddy when the file exists: with a missing file it
# offers to *create* one, which would mutate the bundle.
plist_get() {
  local key value
  key=$1
  value=$(/usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null) || value=""
  if [ -n "$value" ]; then
    printf '%s' "$value"
    return 0
  fi
  value=$(defaults read "$plist" "$key" 2>/dev/null) || value=""
  if [ -n "$value" ]; then
    : >"$tmp/plist_fallback"
    printf '%s' "$value"
    return 0
  fi
  return 1
}

bundle_id=""
version=""
build=""
min_os=""
category=""
exe_name=""
display_name=""
bundle_name=""
if [ "$plist_ok" -eq 1 ]; then
  bundle_id=$(plist_get CFBundleIdentifier || true)
  version=$(plist_get CFBundleShortVersionString || true)
  build=$(plist_get CFBundleVersion || true)
  min_os=$(plist_get LSMinimumSystemVersion || true)
  category=$(plist_get LSApplicationCategoryType || true)
  exe_name=$(plist_get CFBundleExecutable || true)
  case $exe_name in
    */*)
      add note "CFBundleExecutable is not a plain file name: $exe_name"
      exe_name=""
      ;;
  esac
  display_name=$(plist_get CFBundleDisplayName || true)
  bundle_name=$(plist_get CFBundleName || true)
  if [ -e "$tmp/plist_fallback" ]; then
    plist_reader="PlistBuddy+defaults read"
  fi
fi

name=$name_default
if [ -n "$display_name" ]; then
  name=$display_name
elif [ -n "$bundle_name" ]; then
  name=$bundle_name
fi

resolved=""
if resolved=$(cd "$app" 2>/dev/null && pwd -P); then
  :
else
  resolved=""
fi
if [[ $app == /* ]] && [ -n "$resolved" ] && [ "$resolved" != "$app" ]; then
  add note "path resolves through symlinks to: $resolved"
fi

# A bundle that is itself a symlink is only measured when the target still looks
# like an app bundle; otherwise du would walk an arbitrary directory tree.
size_kib=""
size_path=$app
if [ -n "$resolved" ]; then
  size_path=$resolved
fi
if [ -L "$app" ] && [ ! -d "$size_path/Contents" ]; then
  add note "bundle path is a symlink to a non-bundle directory; size not measured"
else
  du_out=$(du -sk "$size_path" 2>/dev/null) || du_out=""
  if [ -n "$du_out" ]; then
    size_kib=$(printf '%s' "$du_out" | cut -f1)
  fi
fi
exe_path=""
exe_exists=0
if [ -n "$exe_name" ]; then
  exe_path="$app/Contents/MacOS/$exe_name"
  if [ -f "$exe_path" ]; then
    exe_exists=1
  else
    add note "CFBundleExecutable $exe_name is missing from Contents/MacOS"
  fi
fi

lipo_out=""
lipo_rc=0
if [ "$exe_exists" -eq 1 ]; then
  if lipo_out=$(lipo -info "$exe_path" 2>&1); then
    lipo_rc=0
  else
    lipo_rc=$?
  fi
fi
printf '%s' "$lipo_out" >"$tmp/lipo"
printf '%s' "$lipo_rc" >"$tmp/lipo.rc"

sign_out=""
sign_rc=0
if sign_out=$(codesign -dv --verbose=2 "$app" 2>&1); then
  sign_rc=0
else
  sign_rc=$?
fi
printf '%s' "$sign_out" >"$tmp/signing"
# codesign echoes bundle paths and certificate names; drop control characters
# so a self-signed certificate cannot inject terminal escapes.
tr -d '\000-\010\013-\037\177' <"$tmp/signing" >"$tmp/signing.clean" &&
  mv "$tmp/signing.clean" "$tmp/signing"
printf '%s' "$sign_rc" >"$tmp/signing.rc"

gk_out=""
gk_rc=0
if gk_out=$(spctl -a -vv "$app" 2>&1); then
  gk_rc=0
else
  gk_rc=$?
fi
printf '%s' "$gk_out" >"$tmp/gatekeeper"
printf '%s' "$gk_rc" >"$tmp/gatekeeper.rc"

q_present=0
q_raw=""
if q_raw=$(xattr -p com.apple.quarantine "$app" 2>"$tmp/xattr.err"); then
  q_present=1
else
  q_present=0
  q_raw=""
fi
printf '%s' "$q_present" >"$tmp/quarantine.present"
printf '%s' "$q_raw" >"$tmp/quarantine.raw"
# spctl and xattr echo the bundle path; same scrub before it reaches the report.
for f in gatekeeper quarantine.raw; do
  tr -d '\000-\010\013-\037\177' <"$tmp/$f" >"$tmp/$f.clean" 2>/dev/null &&
    mv "$tmp/$f.clean" "$tmp/$f"
done
q_err=$(cat "$tmp/xattr.err")
if [ -n "$q_err" ] && ! grep -q "No such xattr" "$tmp/xattr.err"; then
  add note "xattr: $q_err"
fi

: >"$tmp/pids"
running_state="skip"
if [ -n "$bundle_id" ]; then
  if lsa=$(lsappinfo list 2>/dev/null); then
    running_state="ok"
    printf '%s\n' "$lsa" | awk -v id="$bundle_id" '
      BEGIN { want = "bundleID=\"" id "\"" }
      function flush() {
        if (hit) print (pid == "" ? "?" : pid)
        hit = 0
        pid = ""
      }
      /^ *[0-9]+\) / { flush() }
      {
        line = $0
        sub(/^[ \t]+/, "", line)
        if (line == want) hit = 1
        if (line ~ /^pid = [0-9]+/) {
          split(line, parts, " ")
          pid = parts[3]
        }
      }
      END { flush() }
    ' >"$tmp/pids"
  else
    running_state="error"
    add note "lsappinfo list failed (no GUI session?)"
  fi
fi
printf '%s' "$running_state" >"$tmp/running"

if [ "$plist_ok" -eq 0 ]; then
  add note "Contents/Info.plist missing: identity fields unavailable (broken bundle?)"
elif [ -z "$bundle_id" ]; then
  add note "no CFBundleIdentifier in Contents/Info.plist"
fi

add name "$name"
add path "$app"
add resolved_path "$resolved"
add bundle_id "$bundle_id"
add version "$version"
add build "$build"
add min_os "$min_os"
add category "$category"
add plist_reader "$plist_reader"
add executable_name "$exe_name"
add executable_path "$exe_path"
add executable_exists "$exe_exists"
add size_kib "$size_kib"

python3 - "$tmp" "$as_json" <<'PY'
import json
import os
import re
import sys

tmp = sys.argv[1]
as_json = sys.argv[2] == "1"


def read(name):
    path = os.path.join(tmp, name)
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except FileNotFoundError:
        return ""


records = {}
for line in read("rec").splitlines():
    if "\x1f" not in line:
        continue
    key, value = line.split("\x1f", 1)
    records.setdefault(key, []).append(value)


def one(key):
    values = records.get(key) or [""]
    return values[0] if values[0] != "" else None


def flag(key):
    return one(key) == "1"


def first_line(text):
    for line in text.splitlines():
        if line.strip():
            return line.strip()
    return None


def category_label(raw):
    if not raw:
        return None
    prefix = "public.app-category."
    if raw.startswith(prefix):
        return raw[len(prefix):].replace("-", " ").replace("_", " ")
    return raw


def parse_signing(raw):
    identifier = None
    team_id = None
    flags = None
    authorities = []
    for line in raw.splitlines():
        if line.startswith("Identifier="):
            identifier = line.split("=", 1)[1]
        elif line.startswith("Authority="):
            authorities.append(line.split("=", 1)[1])
        elif line.startswith("TeamIdentifier="):
            value = line.split("=", 1)[1]
            team_id = None if value == "not set" else value
        elif flags is None and " flags=" in line:
            match = re.search(r"\bflags=(\S+)", line)
            if match:
                flags = match.group(1)
    return identifier, authorities, team_id, flags


def parse_gatekeeper(raw, rc):
    source = None
    origin = None
    for line in raw.splitlines():
        if line.startswith("source="):
            source = line.split("=", 1)[1]
        elif line.startswith("origin="):
            origin = line.split("=", 1)[1]
    return {
        "status": "accepted" if rc == 0 else "rejected",
        "source": source,
        "origin": origin,
        "exit_code": rc,
        "message": first_line(raw),
        "scope": "local policy verdict, not a notarization lookup",
    }


name = one("name") or ""
path = one("path") or ""
resolved_path = one("resolved_path")
bundle_id = one("bundle_id")
category = one("category")
label = category_label(category)

size_kib = one("size_kib")
size_kib = int(size_kib) if size_kib and size_kib.isdigit() else None

exe_exists = flag("executable_exists")
exe_path = one("executable_path")

lipo_raw = read("lipo").strip()
try:
    lipo_rc = int(read("lipo.rc").strip() or "0")
except ValueError:
    lipo_rc = 1
architectures = []
match = re.search(r"(?:are|architecture):\s*(.+)$", lipo_raw)
if match:
    architectures = match.group(1).split()

sign_raw = read("signing")
try:
    sign_rc = int(read("signing.rc").strip() or "1")
except ValueError:
    sign_rc = 1
signed = sign_rc == 0
sign_identifier, authorities, team_id, sign_flags = parse_signing(sign_raw)
sign_error = None if signed else first_line(sign_raw)

gk_raw = read("gatekeeper")
try:
    gk_rc = int(read("gatekeeper.rc").strip() or "1")
except ValueError:
    gk_rc = 1
gatekeeper = parse_gatekeeper(gk_raw, gk_rc)

quarantine = {
    "attribute": "com.apple.quarantine",
    "present": read("quarantine.present").strip() == "1",
    "raw": read("quarantine.raw") or None,
}

running_state = read("running").strip() or "skip"
pid_lines = [line for line in read("pids").splitlines() if line]
pids = [pid for pid in pid_lines if pid.isdigit()]

notes = list(records.get("note") or [])
if category is None and one("plist_reader") != "none":
    notes.append("no LSApplicationCategoryType declared: category unknown")
if lipo_rc != 0 and exe_exists:
    notes.append("lipo could not read the executable: %s" % first_line(lipo_raw))
if signed and sign_identifier and bundle_id and sign_identifier != bundle_id:
    notes.append(
        "signature identifier %s differs from bundle id %s: "
        "the bundle is not signed as a whole" % (sign_identifier, bundle_id)
    )
if running_state == "ok":
    running = bool(pid_lines)
elif running_state == "error":
    running = None
    notes.append("running state unknown: lsappinfo failed")
else:
    running = None
    notes.append("no bundle identifier: running check skipped")

seen = set()
deduped = []
for note in notes:
    if note not in seen:
        seen.add(note)
        deduped.append(note)
notes = deduped

payload = {
    "name": name,
    "path": path,
    "resolved_path": resolved_path,
    "bundle_id": bundle_id,
    "version": one("version"),
    "build": one("build"),
    "min_os": one("min_os"),
    "category": category,
    "category_label": label,
    "plist_reader": one("plist_reader") or "none",
    "binary": {
        "executable": one("executable_name"),
        "path": exe_path,
        "exists": exe_exists,
    },
    "architectures": architectures,
    "architectures_raw": lipo_raw or None,
    "size_kib": size_kib,
    "size_bytes": size_kib * 1024 if size_kib is not None else None,
    "signed": signed,
    "signing": {
        "identifier": sign_identifier,
        "authorities": authorities[:3],
        "authority_count": len(authorities),
        "team_id": team_id,
        "flags": sign_flags,
        "error": sign_error,
    },
    "gatekeeper": gatekeeper["status"],
    "gatekeeper_detail": gatekeeper,
    "quarantine": quarantine,
    "running": {"running": running, "pids": pids},
    "notes": notes,
}

if as_json:
    json.dump(payload, sys.stdout, ensure_ascii=False, indent=2)
    sys.stdout.write("\n")
    raise SystemExit(0)


def show(value):
    return "-" if value is None else str(value)


out = [
    "name: %s" % name,
    "path: %s" % path,
    "bundle id: %s" % show(bundle_id),
    "version: %s%s"
    % (
        show(payload["version"]),
        " (build %s)" % payload["build"] if payload["build"] else "",
    ),
    "min macOS: %s" % show(payload["min_os"]),
    "category: %s"
    % (
        "%s (%s)" % (category, label)
        if category and label != category
        else show(category)
    ),
    "plist: %s" % payload["plist_reader"],
    "binary: %s%s"
    % (show(exe_path), "" if exe_exists else " (missing)"),
    "architectures: %s" % (" ".join(architectures) if architectures else "-"),
    "size: %s KiB (du -sk disk usage, not logical size)" % show(size_kib),
]
if signed:
    out.append(
        "signature: signed | Identifier=%s | TeamIdentifier=%s | flags=%s"
        % (show(sign_identifier), show(team_id), show(sign_flags))
    )
    if authorities:
        out.append("authority: %s" % "; ".join(authorities[:3]))
else:
    out.append("signature: unsigned (%s)" % show(sign_error))

gk_line = "gatekeeper: %s" % gatekeeper["status"]
extras = []
if gatekeeper["source"]:
    extras.append("source=%s" % gatekeeper["source"])
if gatekeeper["origin"]:
    extras.append("origin=%s" % gatekeeper["origin"])
if extras:
    gk_line += " | " + " | ".join(extras)
gk_line += " (local policy verdict, not a notarization proof)"
out.append(gk_line)

if quarantine["present"]:
    out.append("quarantine: present | %s" % show(quarantine["raw"]))
else:
    out.append("quarantine: absent")

if running is None:
    out.append("running: unknown")
elif not running:
    out.append("running: no")
elif pids:
    out.append("running: yes (pid %s)" % ", ".join(pids))
else:
    out.append("running: yes")

for note in notes:
    out.append("note: %s" % note)
print("\n".join(out))
PY
