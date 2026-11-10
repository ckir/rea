#!/bin/sh
# Copyright (c) 2026 Costas Kirgoussios
#
# This software is licensed under the PolyForm Noncommercial License 1.0.0.
# You may obtain a copy of the License at:
# https://polyformproject.org/licenses/noncommercial/1.0.0/

# Checks that every tool declared in .claude/recommended-tools.json is present, using the entry's
# `in_path` (a command on PATH), `pwsh_module` (a PowerShell module that `pwsh` itself can list, wherever
# Install-Module put it: -Scope and the platform decide the directory, so a path guess misses it) or
# `file_exists` (a list of paths, any one of which suffices; a leading `~` is the home directory).
# TOOLS_CHECK_JSON overrides the list (the test seam of scripts/tests/tools-check.sh). Prints `missing: <name>  install: <hint>` per gap; exits 1 if any.
set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
. "$repo_root/scripts/lib/scan-guard.sh"
json=${TOOLS_CHECK_JSON:-$repo_root/.claude/recommended-tools.json}

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
  elif [ -n "$(printf '%s' "$entry" | jq -r '.pwsh_module // empty')" ]; then
    module=$(printf '%s' "$entry" | jq -r '.pwsh_module')
    # The name goes into a pwsh command line, so it must be a plain identifier.
    case "$module" in
      *[!A-Za-z0-9._-]*)
        echo "tools-check: $name declares an invalid pwsh_module: $module" >&2
        exit 1
        ;;
    esac
    present=0
    if command -v pwsh >/dev/null 2>&1; then
      pwsh -NoProfile -NonInteractive -Command "if (Get-Module -ListAvailable -Name '$module') { exit 0 } else { exit 1 }" >/dev/null 2>&1 && present=1
    fi
  else
    paths=$(printf '%s' "$entry" | jq -r '.file_exists // empty | if type == "array" then .[] else . end')
    if [ -z "$paths" ]; then
      echo "tools-check: $name declares none of in_path, pwsh_module or file_exists" >&2
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
