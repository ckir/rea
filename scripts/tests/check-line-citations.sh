#!/bin/sh
# Copyright (c) 2026 Costas Kirgoussios
#
# This software is licensed under the PolyForm Noncommercial License 1.0.0.
# You may obtain a copy of the License at:
# https://polyformproject.org/licenses/noncommercial/1.0.0/

# Tests for scripts/check-line-citations.sh, the gate that no comment cites another file by line number.
#
# The gate finds the repository from its own location, so each case copies it (with its scan-guard
# library) into a fresh tree holding only that case's fixture files. Fixture comment lines are built
# with printf from separate words, so this file never contains a comment line the gate itself would flag.

set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
failures=0
tmp=$(mktemp -d)
trap 'chmod -R u+rwx "$tmp" 2>/dev/null || true; rm -rf "$tmp"' EXIT INT TERM

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

lacks() {
  case "$2" in
    *"$3"*)
      echo "FAIL - $1: output mentions '$3': $2"
      failures=$((failures + 1))
      ;;
    *) echo "ok   - $1" ;;
  esac
}

# tree <name>: a fresh repository copy with the gate and its library, and the scan roots present.
# Sets dir.
tree() {
  dir="$tmp/$1"
  mkdir -p "$dir/scripts/lib" "$dir/tests" "$dir/.github/workflows" "$dir/docs"
  cp "$root/scripts/check-line-citations.sh" "$dir/scripts/"
  cp "$root/scripts/lib/scan-guard.sh" "$dir/scripts/lib/"
}

# run: sets out and status.
run() {
  set +e
  out=$(sh "$dir/scripts/check-line-citations.sh" 2>&1)
  status=$?
  set -e
}

# cite <comment-leader> <file> <line-spec>: one comment line that cites <file> at <line-spec>.
cite() { printf '%s see %s:%s for the details\n' "$1" "$2" "$3"; }

# clean tree: a comment that names a file without a line number, and a bare number
tree ok
{
  echo '#!/bin/sh'
  printf '%s\n' '# see other.sh for the details, in the function named main'
  printf '%s\n' '# the answer is 192'
} >"$dir/scripts/a.sh"
run
check "a tree without line citations passes" "$status" 0
has "the clean message is printed" "$out" "no line-pinned citations found"

# a comment citing file:line fails and names file and line
tree cite
{
  echo '#!/bin/sh'
  cite '#' other.sh 192
} >"$dir/scripts/bad.sh"
run
check "a comment citing file:line fails" "$status" 1
has "the file and line are named" "$out" "scripts/bad.sh:2 cites another file by line number"
has "the count is printed" "$out" "1 line-pinned citation(s)"

# the range form
tree range
{
  echo '#!/bin/sh'
  cite '#' x.rs '17-18'
} >"$dir/scripts/range.sh"
run
check "a file:a-b range citation fails" "$status" 1
has "the range file and line are named" "$out" "scripts/range.sh:2 cites another file by line number"

# the double-slash comment form is a comment too
tree slashes
{
  echo '#!/bin/sh'
  cite '//' x.rs 5
} >"$dir/scripts/slashes.sh"
run
check "a // comment citing file:line fails" "$status" 1

# the marker on the same line exempts it; the line after it is still checked
tree marker
{
  echo '#!/bin/sh'
  printf '%s line-cite-ok\n' "$(cite '#' other.sh 192)"
} >"$dir/scripts/ok.sh"
run
check "the line-cite-ok marker exempts the line" "$status" 0
{
  echo '#!/bin/sh'
  printf '%s line-cite-ok\n' "$(cite '#' other.sh 192)"
  cite '#' third.sh 7
} >"$dir/scripts/ok.sh"
run
check "the marker exempts only its own line" "$status" 1
has "the unmarked line is named" "$out" "scripts/ok.sh:3 cites another file by line number"
lacks "the marked line is not named" "$out" "scripts/ok.sh:2"

# a path:line inside CODE is data, not a citation
tree code
{
  echo '#!/bin/sh'
  printf '%s\n' 'trace="other.sh:192"'
  printf '%s\n' 'echo "x.rs:17-18"'
} >"$dir/scripts/code.sh"
run
check "path:line in non-comment code is not flagged" "$status" 0

# every scanned file kind, location and the root: .ps1, .yml, tests/, .github/ and root-level scripts
tree ps1
{
  cite '#' other.sh 192
} >"$dir/tests/t.ps1"
run
check "a .ps1 comment is scanned" "$status" 1
has "the .ps1 file is named" "$out" "tests/t.ps1:1 cites another file by line number"

tree yml
{
  printf '%s\n' 'name: t'
  cite '#' other.sh 192
} >"$dir/.github/workflows/w.yml"
run
check "a .yml comment is scanned" "$status" 1
has "the .yml file is named" "$out" ".github/workflows/w.yml:2 cites another file by line number"

tree rootsh
{
  echo '#!/bin/sh'
  cite '#' other.sh 192
} >"$dir/setup.sh"
run
check "a root-level script comment is scanned" "$status" 1
has "the root file is named" "$out" "setup.sh:2 cites another file by line number"

# two files are both reported
tree two
{
  echo '#!/bin/sh'
  cite '#' other.sh 192
} >"$dir/scripts/one.sh"
cite '#' other.sh 193 >"$dir/tests/two.ps1"
run
check "two citing files fail" "$status" 1
has "the count covers both" "$out" "2 line-pinned citation(s)"

# docs/ is a historical record and is not scanned, and neither are non-source extensions
tree docs
{
  echo '#!/bin/sh'
  cite '#' other.sh 192
} >"$dir/docs/old.sh"
cite '#' other.sh 192 >"$dir/docs/note.md"
cite '#' other.sh 192 >"$dir/scripts/notes.md"
echo '#!/bin/sh' >"$dir/scripts/a.sh"
run
check "docs/ and non-source files are not scanned" "$status" 0

# scan-guard: nothing to scan is a refusal, not a clean tree. The gate lives in a directory the scan
# roots do not cover, and the library it sources is a symlink, which `find -type f` does not list; the
# scan roots exist and hold nothing.
dir="$tmp/empty"
mkdir -p "$dir/gate" "$dir/scripts/lib" "$dir/tests" "$dir/.github"
cp "$root/scripts/check-line-citations.sh" "$dir/gate/"
ln -s "$root/scripts/lib/scan-guard.sh" "$dir/scripts/lib/scan-guard.sh"
set +e
out=$(sh "$dir/gate/check-line-citations.sh" 2>&1)
status=$?
set -e
check "a tree with nothing to scan fails" "$status" 1
has "the refusal says nothing was found to scan" "$out" "found nothing to scan"
lacks "it does not claim to be clean" "$out" "no line-pinned citations found"

# a file that cannot be read is a broken scan, not a clean one (skipped as root, which can read anything)
if [ "$(id -u)" -ne 0 ]; then
  tree unreadable
  echo '#!/bin/sh' >"$dir/scripts/a.sh"
  cite '#' other.sh 192 >"$dir/scripts/locked.sh"
  chmod 000 "$dir/scripts/locked.sh"
  run
  chmod 600 "$dir/scripts/locked.sh"
  check "an unreadable file fails" "$status" 1
  has "the broken scan is named" "$out" "could not be read, so this scan is broken"
  lacks "it does not claim to be clean" "$out" "no line-pinned citations found"
fi

if [ "$failures" -ne 0 ]; then
  echo "$failures failure(s)"
  exit 1
fi
echo "all check-line-citations tests passed"
