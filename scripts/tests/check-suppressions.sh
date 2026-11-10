#!/bin/sh
# Copyright (c) 2026 Costas Kirgoussios
#
# This software is licensed under the PolyForm Noncommercial License 1.0.0.
# You may obtain a copy of the License at:
# https://polyformproject.org/licenses/noncommercial/1.0.0/

# Tests for scripts/check-suppressions.sh, the gate that every lint suppression carries a written reason
# and that the total stays within scripts/suppressions.baseline.
#
# The gate finds the repository from its own location, so each case copies it (with its scan-guard
# library) into a fresh tree holding only that case's fixture files. Fixture suppression lines are built
# with printf so this file never contains a line the gate itself would count.

set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
failures=0
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

check() {
  if [ "$2" = "$3" ]; then
    echo "ok   - $1"
  else
    echo "FAIL - $1: expected '$3', got '$2'"
    failures=$((failures + 1))
  fi
}

has() {
  case "$2" in
    *"$3"*) echo "ok   - $1" ;;
    *)
      echo "FAIL - $1: output lacks '$3': $2"
      failures=$((failures + 1))
      ;;
  esac
}

# tree <name> <baseline>: a fresh repository copy with the gate, its library and the given baseline.
# Sets dir.
tree() {
  dir="$tmp/$1"
  mkdir -p "$dir/scripts/lib"
  cp "$root/scripts/check-suppressions.sh" "$dir/scripts/"
  cp "$root/scripts/lib/scan-guard.sh" "$dir/scripts/lib/"
  printf '%s\n' "$2" >"$dir/scripts/suppressions.baseline"
}

# run: sets out and status.
run() {
  set +e
  out=$(sh "$dir/scripts/check-suppressions.sh" 2>&1)
  status=$?
  set -e
}

sc() { printf '%s\n' "# shellcheck disable=SC2034$1"; }

# clean tree: one reasoned shell suppression, one reasoned PowerShell one, baseline exactly equal
tree ok 2
{
  echo '#!/bin/sh'
  sc ' # the variable is read by a sourcing script'
} >"$dir/a.sh"
printf '%s\n' "[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'plural by design')]" >"$dir/a.ps1"
run
check "reasoned suppressions at the baseline pass" "$status" 0
has "the count and baseline are printed" "$out" "2 suppression(s), baseline 2"

# a shell suppression without a reason is rejected and named
tree bare 5
{
  echo '#!/bin/sh'
  sc ''
} >"$dir/bad.sh"
run
check "an unreasoned shellcheck suppression fails" "$status" 1
has "the offending file is named" "$out" "bad.sh has a suppression without a written reason"

# a PowerShell attribute without Justification is rejected
tree psbare 5
printf '%s\n' "[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '')]" >"$dir/bad.ps1"
run
check "a SuppressMessageAttribute without Justification fails" "$status" 1
has "the PowerShell file is named" "$out" "bad.ps1 has a suppression without a written reason"

# one over the baseline fails even when every suppression has a reason
tree over 1
{
  echo '#!/bin/sh'
  sc ' # first reason'
  sc ' # second reason'
} >"$dir/a.sh"
run
check "a reasoned count above the baseline fails" "$status" 1
has "the baseline message is printed" "$out" "exceeds the committed baseline 1"

# a baseline that is not a number is a broken gate, not a clean one
tree badbase 'two'
echo '#!/bin/sh' >"$dir/a.sh"
run
check "a non-numeric baseline fails" "$status" 1
has "the baseline file is named" "$out" "must hold a single non-negative integer"

if [ "$failures" -ne 0 ]; then
  echo "$failures failure(s)"
  exit 1
fi
echo "all check-suppressions tests passed"
