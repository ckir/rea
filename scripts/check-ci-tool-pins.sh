#!/bin/sh
# Copyright (c) 2026 Costas Kirgoussios
#
# This software is licensed under the PolyForm Noncommercial License 1.0.0.
# You may obtain a copy of the License at:
# https://polyformproject.org/licenses/noncommercial/1.0.0/

# Fails when a workflow spells out the version of a tool that scripts/ci-tools.lock already pins.
#
# THE RULE: scripts/ci-tools.lock is the one place a CI tool version is written. A workflow step reads it
# (`sed -n 's/^lefthook=//p' scripts/ci-tools.lock` under a POSIX shell, Select-String under PowerShell) and
# never types the number. Two copies of a version drift: bumping the lock then leaves CI installing the old
# tool while every local gate runs the new one, and nothing is red.
#
# Two checks, over every non-comment line of every *.yml under .github/workflows/:
#   1. LITERAL VERSIONS. For each key in the lock, `<key>@<digit>` or `<key>@v<digit>` (`just@1.58.0`,
#      `actionlint@v1.7.12`; the key match ignores case so a module name such as Pester counts), and any
#      `-RequiredVersion`, `-MinimumVersion` or `-MaximumVersion` followed by a digit. `<key>@v$(...)` and
#      `-RequiredVersion $pester` are the correct shapes and pass.
#   2. KEYS THAT DO NOT EXIST. Every `^<key>=` on a line that names ci-tools.lock must be a key the lock
#      holds. A misspelt key makes sed or Select-String return nothing, so the tool installs at "no version"
#      and the step fails late, or worse installs the latest.
#
# Usage: sh scripts/check-ci-tool-pins.sh [workflow-dir [lock-file]]
#        (defaults: <repo>/.github/workflows and <repo>/scripts/ci-tools.lock)
# Output: one `<file>:<line>: <text>` per violation and exit 1; otherwise a one-line count.

set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
. "$repo_root/scripts/lib/scan-guard.sh"

dir=${1:-$repo_root/.github/workflows}
lock=${2:-$repo_root/scripts/ci-tools.lock}

files=$(mktemp)
keys=$(mktemp)
numbered=$(mktemp)
code=$(mktemp)
hits=$(mktemp)
readkeys=$(mktemp)
trap 'rm -f "$files" "$keys" "$numbered" "$code" "$hits" "$readkeys" "$readkeys.out"' EXIT INT TERM

[ -f "$lock" ] || {
  echo "check-ci-tool-pins: $lock does not exist, so there is nothing to compare the workflows with." >&2
  exit 1
}
sed -n 's/^\([a-z0-9_-][a-z0-9_-]*\)=.*/\1/p' "$lock" >"$keys"
scan_require "$keys" "key=version lines in $lock" || exit 1

scan_expand "$files" must-find "workflow files under $dir" "$dir"/*.yml || exit 1

violations=0
reads=0
report() {
  printf '%s:%s: %s\n' "$1" "$2" "$3" >&2
  printf '  %s\n' "$4" >&2
  violations=$((violations + 1))
}

while IFS= read -r file; do
  # Comments may talk about versions freely; only live lines are checked. The line number survives.
  scan_grep -n '' "$file" >"$numbered" || exit 1
  scan_grep -v -E '^[0-9]+:[[:space:]]*#' "$numbered" >"$code" || exit 1

  while IFS= read -r key; do
    scan_grep -i -E "(^|[^A-Za-z0-9_.-])$key@v?[0-9]" "$code" >"$hits" || exit 1
    while IFS= read -r hit; do
      [ -n "$hit" ] || continue
      report "$file" "${hit%%:*}" "spells out the version of '$key', which $lock pins" "${hit#*:}"
    done <"$hits"
  done <"$keys"

  scan_grep -i -E -- '-(Required|Minimum|Maximum)Version[ =]+["'"'"']?[0-9]' "$code" >"$hits" || exit 1
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    report "$file" "${hit%%:*}" "gives a module version literally; read it from $lock" "${hit#*:}"
  done <"$hits"

  scan_grep -E 'ci-tools\.lock' "$code" >"$hits" || exit 1
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    line=${hit%%:*}
    # grep -o prints one `^key=` per match, so a line reading four keys is checked four times.
    printf '%s\n' "${hit#*:}" >"$readkeys"
    scan_grep -o -E '\^[a-z0-9_-]+=' "$readkeys" >"$readkeys.out" || exit 1
    while IFS= read -r read_key; do
      [ -n "$read_key" ] || continue
      read_key=${read_key#^}
      read_key=${read_key%=}
      reads=$((reads + 1))
      if ! grep -q -x -F -- "$read_key" "$keys"; then
        report "$file" "$line" "reads '$read_key' from the lock, which has no such key" "${hit#*:}"
      fi
    done <"$readkeys.out"
  done <"$hits"
done <"$files"

if [ "$violations" -ne 0 ]; then
  echo "check-ci-tool-pins: $violations violation(s). Read the version from $lock instead of typing it." >&2
  exit 1
fi

echo "check-ci-tool-pins: $(wc -l <"$files" | tr -d ' ') workflow(s) checked, $reads lock key(s) read, no literal tool versions"
