#!/bin/sh
# Copyright (c) 2026 Costas Kirgoussios
#
# This software is licensed under the PolyForm Noncommercial License 1.0.0.
# You may obtain a copy of the License at:
# https://polyformproject.org/licenses/noncommercial/1.0.0/

# Tests for scripts/check-action-pins.sh, the gate that every workflow `uses:` is a commit SHA.
#
# Each case is its own directory holding one w.yml. A rejection must name the offending line exactly
# once; a broken scan (nothing to read) must fail rather than report a clean tree.

set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
failures=0
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

sha=3d3c42e5aac5ba805825da76410c181273ba90b1

check() {
  if [ "$2" = "$3" ]; then
    echo "ok   - $1"
  else
    echo "FAIL - $1: expected '$3', got '$2'"
    failures=$((failures + 1))
  fi
}

# run <dir>: sets out and status.
run() {
  set +e
  out=$(sh "$root/scripts/check-action-pins.sh" "$1" 2>&1)
  status=$?
  set -e
}

# header: the minimal jobs skeleton every fixture starts with.
header() {
  printf 'name: t\n'
  printf 'on: push\n'
  printf 'jobs:\n'
  printf '  j:\n'
  printf '    runs-on: ubuntu-latest\n'
  printf '    steps:\n'
}
skeleton=$(header | wc -l)

# at <n>: the file line number of the n-th (1-based) fixture line.
at() {
  echo $((skeleton + $1))
}

# fixture <name> <line>...: a directory holding w.yml with the header; each <line> is written verbatim
# after `steps:`. Sets dir.
fixture() {
  dir="$tmp/$1"
  shift
  mkdir -p "$dir"
  {
    header
    for line in "$@"; do
      printf '%s\n' "$line"
    done
  } >"$dir/w.yml"
}

# accepted <name> <line>...
accepted() {
  name=$1
  fixture "$@"
  run "$dir"
  check "$name: status" "$status" "0"
}

# rejected <name> <n-th-fixture-line-of-offender> <line>...
rejected() {
  name=$1
  lineno=$(at "$2")
  shift 2
  fixture "$name" "$@"
  run "$dir"
  check "$name: status" "$status" "1"
  check "$name: names the line" "$(printf '%s\n' "$out" | grep -c "w.yml:$lineno:")" "1"
}

accepted "sha plus tag is accepted" \
  "      - uses: actions/checkout@$sha # v7.0.1"
accepted "bare uses form is accepted" \
  "        uses: actions/checkout@$sha # v7.0.1"
accepted "sub-path action is accepted" \
  "      - uses: owner/repo/sub/dir@$sha # v1.2.3"
accepted "job-level local workflow is exempt" \
  "    uses: ./.github/workflows/release.yml"
accepted "commented-out floating uses is ignored" \
  "      # - uses: actions/checkout@v7" \
  "      - uses: actions/checkout@$sha # v7.0.1"

rejected "floating tag is rejected" 1 \
  "      - uses: actions/checkout@v7"
rejected "branch name is rejected" 1 \
  "      - uses: dtolnay/rust-toolchain@stable"
rejected "39-hex sha is rejected" 1 \
  "      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b # v7.0.1"
rejected "upper-case sha is rejected" 1 \
  "      - uses: actions/checkout@3D3C42E5AAC5BA805825DA76410C181273BA90B1 # v7.0.1"
rejected "sha without a comment is rejected" 1 \
  "      - uses: actions/checkout@$sha"
rejected "sha only in the comment is rejected" 1 \
  "      - uses: actions/checkout@v7 # $sha"
rejected "docker reference is rejected" 1 \
  "      - uses: docker://alpine:3.20"

fixture "every violation in a file is named" \
  "      - uses: actions/checkout@v7" \
  "      - uses: actions/cache@v4"
run "$dir"
check "every violation in a file is named: status" "$status" "1"
check "every violation in a file is named: first" "$(printf '%s\n' "$out" | grep -c "w.yml:$(at 1):")" "1"
check "every violation in a file is named: second" "$(printf '%s\n' "$out" | grep -c "w.yml:$(at 2):")" "1"

# Flow style is refused outright (block style only), so a floating action cannot hide beside a pinned one.
rejected "flow-style floating use beside a pinned one is rejected" 2 \
  "      - uses: actions/checkout@$sha # v7.0.1" \
  "      - { uses: actions/checkout@v7 }"
rejected "flow-style pinned use is rejected" 1 \
  "      - { uses: actions/checkout@$sha # v7.0.1 }"
accepted "commented-out flow-style use is ignored" \
  "      # - { uses: x/y@v1 }" \
  "      - uses: actions/checkout@$sha # v7.0.1"

# Fail closed on any shape of the `uses` key: each is refused beside a valid pinned use (fixture line 2).
tab=$(printf '\t')
shape() {
  rejected "$1" 2 "      - uses: actions/checkout@$sha # v7.0.1" "$2"
}
shape "two spaces after the hyphen are refused when floating" "      -  uses: actions/checkout@v7"
shape "tab after the hyphen is refused when floating" "      -${tab}uses: actions/checkout@v7"
shape "double-quoted key is refused" '      - "uses": actions/checkout@v7'
shape "single-quoted key is refused" "      - 'uses': actions/checkout@v7"
shape "space before the colon is refused" "      - uses : actions/checkout@v7"
shape "array form is refused" "      - [ uses: actions/checkout@v7 ]"
shape "space before the colon without a hyphen is refused" "        uses : actions/checkout@v7"
# The runner matches keys exactly, so `Uses:` is not `uses` to it; it is still refused, as a spelling this gate
# does not vouch for. An explicit key (`? uses` with its value on the next line) IS the `uses` key to a YAML
# parser while carrying no colon on its own line, so the scan refuses every explicit-key indicator.
shape "capitalised key is refused" "      - Uses: actions/checkout@v7"
shape "upper-case key is refused" "      - USES: actions/checkout@v7"
shape "capitalised key with a sha is refused" "      - Uses: actions/checkout@$sha # v7.0.1"
rejected "explicit key after a hyphen is refused" 2 \
  "      - uses: actions/checkout@$sha # v7.0.1" \
  "      - ? uses" \
  "        : actions/checkout@v7"
rejected "explicit key in a block mapping is refused" 2 \
  "      - uses: actions/checkout@$sha # v7.0.1" \
  "        ? uses" \
  "        : actions/checkout@v7"
rejected "quoted explicit key is refused" 2 \
  "      - uses: actions/checkout@$sha # v7.0.1" \
  "      - ? \"uses\"" \
  "        : actions/checkout@v7"
# A double-quoted key may spell `uses` with an escape (`"\u0075ses"`) that no text match for the word can see, and a
# YAML parser reads it as the real key. Single-quoted scalars have no escapes, so `'uses'` is already refused literally.
# The scan refuses any closed double-quoted token followed by a colon, wherever it sits on the line.
shape "unicode-escaped key is refused" '      - "\u0075ses": actions/checkout@v7'
shape "hex-escaped key with a spaced colon is refused" '      - "\x75ses"   : actions/checkout@v7'
shape "escaped key with an escaped quote is refused" '      - "\"\u0075ses": actions/checkout@v7'
shape "escaped key in a flow mapping is refused" '      - { "\u0075ses": actions/checkout@v7 }'
shape "escaped key in a flow mapping without spaces is refused" '      - {"\u0075ses":actions/checkout@v7}'
shape "escaped key followed by a doubled colon is refused" '      - {"\u0075ses"::actions/checkout@v7}'
shape "escaped key in an array is refused" '      - [ "\u0075ses": actions/checkout@v7 ]'
shape "escaped key after a tag is refused" '      - !!str "\u0075ses": actions/checkout@v7'
shape "escaped key after an anchor is refused" '      - &a "\u0075ses": actions/checkout@v7'
shape "escaped key after a comma is refused" '      - { name: x, "\u0075ses": actions/checkout@v7 }'
# Quoted text that is not a key must still pass, so the rule does not break ordinary run lines.
accepted "quoted annotation and shell strings are accepted" \
  "      - uses: actions/checkout@$sha # v7.0.1" \
  '        run: echo "::error::x"' \
  '        run: echo "a: b"' \
  '        run: cut -d":" -f1 file' \
  "        run: export PATH=\":\$PATH\"" \
  '        name: "foo: bar"'
accepted "extra spaces after the hyphen with a sha are accepted" \
  "      -   uses: actions/checkout@$sha # v7.0.1"
accepted "local use with a trailing comment is accepted" \
  "      - uses: ./.github/workflows/x.yml # local"
accepted "local use with two spaces after the hyphen is accepted" \
  "      -  uses: ./.github/workflows/x.yml"

mkdir -p "$tmp/empty"
run "$tmp/empty"
if [ "$status" -ne 0 ]; then got=nonzero; else got=zero; fi
check "empty directory is a broken scan: status" "$got" "nonzero"
check "empty directory is a broken scan: message" "$(printf '%s\n' "$out" | grep -c 'found nothing to scan')" "1"

run "$tmp/absent"
if [ "$status" -ne 0 ]; then got=nonzero; else got=zero; fi
check "missing directory is a broken scan: status" "$got" "nonzero"
check "missing directory is a broken scan: message" "$(printf '%s\n' "$out" | grep -c 'found nothing to scan')" "1"

mkdir -p "$tmp/nouses"
printf 'name: x\n' >"$tmp/nouses/w.yml"
run "$tmp/nouses"
if [ "$status" -ne 0 ]; then got=nonzero; else got=zero; fi
check "a file with no uses lines is a broken scan: status" "$got" "nonzero"
check "a file with no uses lines is a broken scan: message" "$(printf '%s\n' "$out" | grep -c 'found nothing to scan')" "1"

fixture "success reports the count" \
  "      - uses: actions/checkout@$sha # v7.0.1" \
  "      - uses: actions/cache@$sha # v4.0.0"
run "$dir"
check "success reports the count: status" "$status" "0"
check "success reports the count: output" "$out" "check-action-pins: 2 uses checked"

if [ "$failures" -gt 0 ]; then
  echo "$failures check(s) failed"
  exit 1
fi
echo "all check-action-pins checks passed"
