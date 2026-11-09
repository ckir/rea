#!/bin/sh
# Copyright (c) 2026 Costas Kirgoussios
#
# This software is licensed under the PolyForm Noncommercial License 1.0.0.
# You may obtain a copy of the License at:
# https://polyformproject.org/licenses/noncommercial/1.0.0/

# Checks that every tool declared in .claude/recommended-tools.json is present, using the entry's
# `in_path` (a command on PATH) or `file_exists` (a list of paths, any one of which suffices; a leading
# `~` is the home directory). Prints `missing: <name>  install: <hint>` per gap; exits 1 if any.
set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
. "$repo_root/scripts/lib/scan-guard.sh"
json="$repo_root/.claude/recommended-tools.json"

command -v jq >/dev/null 2>&1 || {
  echo "tools-check: jq is required (install it first)" >&2
  exit 1
}
[ -r "$json" ] || {
  echo "tools-check: cannot read $json" >&2
  exit 1
}

entries=$(mktemp)
trap 'rm -f "$entries"' EXIT

# Its own statement, so set -e sees a jq failure (no pipefail in POSIX sh).
jq -c '.[]' "$json" >"$entries"
scan_require "$entries" "entries in $json" || exit 1

missing=0
while IFS= read -r entry; do
  name=$(printf '%s' "$entry" | jq -r '.name')
  install=$(printf '%s' "$entry" | jq -r '.install // "see CONTRIBUTING.md"')
  present=1
  cmd=$(printf '%s' "$entry" | jq -r '.in_path // empty')
  if [ -n "$cmd" ]; then
    command -v "$cmd" >/dev/null 2>&1 || present=0
  else
    paths=$(printf '%s' "$entry" | jq -r '.file_exists // empty | if type == "array" then .[] else . end')
    if [ -z "$paths" ]; then
      echo "tools-check: $name declares neither in_path nor file_exists" >&2
      exit 1
    fi
    present=0
    while IFS= read -r p; do
      case "$p" in
        "~"*) p="$HOME${p#"~"}" ;;
      esac
      if [ -e "$p" ]; then
        present=1
      fi
    done <<EOP
$paths
EOP
  fi
  if [ "$present" -eq 0 ]; then
    echo "missing: $name  install: $install"
    missing=$((missing + 1))
  fi
done <"$entries"

if [ "$missing" -ne 0 ]; then
  exit 1
fi
echo "tools-check: all declared tools present"
