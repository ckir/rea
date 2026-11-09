#!/bin/sh
# Copyright (c) 2026 Costas Kirgoussios
#
# This software is licensed under the PolyForm Noncommercial License 1.0.0.
# You may obtain a copy of the License at:
# https://polyformproject.org/licenses/noncommercial/1.0.0/

# Counts lint suppressions and fails when one lacks a written reason or the total exceeds the committed
# baseline (scripts/suppressions.baseline). Raising the baseline must be a visible line in the same diff.
#
#   shell:      a `# shellcheck disable=` line must carry a second `#` comment (the reason)
#   PowerShell: a SuppressMessageAttribute must carry a Justification argument, and a
#               `# PSScriptAnalyzer` suppression comment must carry trailing reason text after a second `#`
#               or ` - `
#
# Usage: sh scripts/check-suppressions.sh
set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
. "$repo_root/scripts/lib/scan-guard.sh"
baseline_file="$repo_root/scripts/suppressions.baseline"

[ -r "$baseline_file" ] || {
  echo "check-suppressions: cannot read $baseline_file" >&2
  exit 1
}
baseline=$(tr -d '[:space:]' <"$baseline_file")
case "$baseline" in
  '' | *[!0-9]*)
    echo "check-suppressions: $baseline_file must hold a single non-negative integer" >&2
    exit 1
    ;;
esac

files=$(mktemp)
hits=$(mktemp)
trap 'rm -f "$files" "$hits"' EXIT

# The same pruned find as the shellcheck recipe, plus *.ps1. Its own statement, not a pipe source.
find "$repo_root" \( -path "$repo_root/.clavity" -o -path "$repo_root/tests/.tmp" -o -path "$repo_root/.git" -o -path "$repo_root/.superpowers" -o -path "$repo_root/docs" \) -prune \
  -o \( -name '*.sh' -o -name '*.ps1' \) -type f -print >"$files"
scan_require "$files" "*.sh or *.ps1 files in the repository" || exit 1

count=0
unreasoned=0
scan_broken=0
while IFS= read -r scanned; do
  [ -n "$scanned" ] || continue
  : >"$hits"
  case "$scanned" in
    *.sh) pattern='^[[:space:]]*#[[:space:]]*shellcheck[[:space:]]+disable=' ;;
    *) pattern='SuppressMessageAttribute|^[[:space:]]*#[[:space:]]*PSScriptAnalyzer' ;;
  esac
  if ! scan_grep -nE "$pattern" /dev/null "$scanned" >>"$hits"; then
    scan_broken=1
    continue
  fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    rel=${scanned#"$repo_root"/}
    content=${line#*:}
    content=${content#*:}
    count=$((count + 1))
    ok=0
    case "$scanned" in
      *.sh)
        # Text after the directive's own `#`: strip the leading `# shellcheck disable=...` and look for a second `#`.
        rest=${content#*#}
        case "$rest" in
          *'#'*[![:space:]]*) ok=1 ;;
        esac
        ;;
      *)
        case "$content" in
          *Justification*) ok=1 ;;
          *'#'*'#'*[![:space:]]*) ok=1 ;;
          *' - '*[![:space:]]*) ok=1 ;;
        esac
        ;;
    esac
    if [ "$ok" -eq 0 ]; then
      echo "check-suppressions: $rel has a suppression without a written reason:" >&2
      echo "  $content" >&2
      unreasoned=$((unreasoned + 1))
    fi
  done <"$hits"
done <"$files"

[ "$scan_broken" -eq 0 ] || {
  echo "check-suppressions: part of the tree could not be read, so this scan is broken, not clean." >&2
  exit 1
}

echo "check-suppressions: $count suppression(s), baseline $baseline"
if [ "$unreasoned" -ne 0 ]; then
  exit 1
fi
if [ "$count" -gt "$baseline" ]; then
  echo "check-suppressions: $count exceeds the committed baseline $baseline; raise scripts/suppressions.baseline in the same change if this is intended." >&2
  exit 1
fi
