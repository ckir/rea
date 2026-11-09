#!/bin/sh
# Copyright (c) 2026 Costas Kirgoussios
#
# This software is licensed under the PolyForm Noncommercial License 1.0.0.
# You may obtain a copy of the License at:
# https://polyformproject.org/licenses/noncommercial/1.0.0/

# Fails when the pins in setup.sh and setup.ps1 differ, or a pin breaks its own rule.
#
# setup.sh and setup.ps1 each carry the same pin block between `# --- pins begin ---` and `# --- pins end ---`:
#   setup.sh   PIN_<NAME>=<value>               (a value with spaces is quoted)
#   setup.ps1  $script:PIN_<NAME> = '<value>'
# Both lists are reduced to sorted NAME=<value> lines (one pair of surrounding quotes stripped) and diffed.
# Then: PIN_GHIDRA_SHA256 is 64 lower-case hex, and every https://<host>/ inside any pin value names a host
# listed in PIN_ALLOWED_HOSTS. An empty list on either side is an error, not a pass.
#
# Usage: sh scripts/check-drift.sh [setup.sh [setup.ps1]]   (the paths default to the repository root)

set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
sh_file=${1:-$root/setup.sh}
ps_file=${2:-$root/setup.ps1}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

# block <file>: the lines between the markers, markers excluded.
block() {
  sed -n '/^# --- pins begin ---$/,/^# --- pins end ---$/p' "$1" | sed '1d;$d'
}

# strip_quotes: removes one pair of surrounding single or double quotes from the value in NAME=value.
strip_quotes() {
  sed -E -e "s/^([A-Z0-9_]+)=\"(.*)\"\$/\\1=\\2/" -e "s/^([A-Z0-9_]+)='(.*)'\$/\\1=\\2/"
}

# markers <file>: fails unless each marker occurs exactly once (a lost end marker would swallow the file).
markers() {
  [ "$(grep -c '^# --- pins begin ---$' "$1" || true)" -eq 1 ] && [ "$(grep -c '^# --- pins end ---$' "$1" || true)" -eq 1 ]
}

for f in "$sh_file" "$ps_file"; do
  if ! markers "$f"; then
    echo "drift: $f needs exactly one '# --- pins begin ---' and one '# --- pins end ---' line" >&2
    exit 1
  fi
done

block "$sh_file" | grep -E '^PIN_[A-Z0-9_]+=' | strip_quotes | sort >"$tmp/sh.pins" || true
block "$ps_file" | sed -nE "s/^\\\$script:(PIN_[A-Z0-9_]+) = '(.*)'\$/\\1=\\2/p" | strip_quotes | sort >"$tmp/ps.pins"

for side in sh ps; do
  if [ ! -s "$tmp/$side.pins" ]; then
    echo "drift: no pins found for $side (missing file, missing markers or unrecognised syntax)" >&2
    exit 1
  fi
done

if ! diff "$tmp/sh.pins" "$tmp/ps.pins" >"$tmp/diff"; then
  echo "drift: setup.sh (<) and setup.ps1 (>) pins differ:" >&2
  cat "$tmp/diff" >&2
  exit 1
fi

sha=$(sed -n 's/^PIN_GHIDRA_SHA256=//p' "$tmp/sh.pins")
if ! printf '%s\n' "$sha" | grep -Eq '^[0-9a-f]{64}$'; then
  echo "drift: PIN_GHIDRA_SHA256 is not 64 lower-case hex: '$sha'" >&2
  exit 1
fi

hosts=$(sed -n 's/^PIN_ALLOWED_HOSTS=//p' "$tmp/sh.pins")
if [ -z "$hosts" ]; then
  echo "drift: PIN_ALLOWED_HOSTS is missing" >&2
  exit 1
fi
bad=0
if grep -v '^PIN_ALLOWED_HOSTS=' "$tmp/sh.pins" | grep -Eq 'http://'; then
  echo "drift: a pin holds an http:// URL; only https:// is allowed" >&2
  exit 1
fi
grep -v '^PIN_ALLOWED_HOSTS=' "$tmp/sh.pins" | grep -Eo 'https://[^/ ]+/' | sort -u >"$tmp/urls" || true
while IFS= read -r url; do
  host=${url#https://}
  host=${host%/}
  case " $hosts " in
    *" $host "*) ;;
    *)
      echo "drift: host '$host' in a pin is not in PIN_ALLOWED_HOSTS" >&2
      bad=1
      ;;
  esac
done <"$tmp/urls"
[ "$bad" -eq 0 ] || exit 1

echo "drift: $(wc -l <"$tmp/sh.pins" | tr -d ' ') pins identical"
