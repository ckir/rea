#!/bin/sh
# Copyright (c) 2026 Costas Kirgoussios
#
# This software is licensed under the PolyForm Noncommercial License 1.0.0.
# You may obtain a copy of the License at:
# https://polyformproject.org/licenses/noncommercial/1.0.0/

# Tests for scripts/tools-check.sh, in particular the `pwsh_module` check form: a PowerShell module is
# found by asking pwsh itself (Get-Module -ListAvailable), not by guessing the directory Install-Module
# chose, which differs per platform and per -Scope (CI installs AllUsers on Linux and macOS).
#
# pwsh is a stub on PATH here, so every case is deterministic on any machine.

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

# A PATH holding only what tools-check.sh needs, so "no pwsh" can be tested on a machine that has it.
base="$tmp/base"
mkdir -p "$base"
for t in sh jq dirname mktemp rm cat wc grep sed tr awk head; do
  p=$(command -v "$t") || {
    echo "FAIL - the test needs $t"
    exit 1
  }
  ln -s "$p" "$base/$t"
done

# stub <dir> <exit-code>: a pwsh that records its arguments and exits with the code.
stub() {
  mkdir -p "$1"
  {
    printf '#!/bin/sh\n'
    printf 'printf "%%s\\n" "$*" >"%s/args"\n' "$1"
    printf 'exit %s\n' "$2"
  } >"$1/pwsh"
  chmod +x "$1/pwsh"
}

# json <name>: a one-entry list declaring a pwsh_module.
json="$tmp/tools.json"
printf '[{"name":"Fake","install":"do-install","pwsh_module":"FakeMod"}]\n' >"$json"

sh_bin=$(command -v sh)

run() {
  set +e
  out=$(TOOLS_CHECK_JSON="$json" PATH="$1" "$sh_bin" "$root/scripts/tools-check.sh" 2>&1)
  status=$?
  set -e
}

stub "$tmp/yes" 0
run "$tmp/yes:$base"
check "a module pwsh lists is present: status" "$status" 0
check "a module pwsh lists is present: no missing line" "$(printf '%s' "$out" | grep -c '^missing:' || true)" 0
check "pwsh is asked about the module by name" "$(grep -c 'FakeMod' "$tmp/yes/args")" 1
check "pwsh is run without a profile" "$(grep -c -- '-NoProfile' "$tmp/yes/args")" 1

stub "$tmp/no" 1
run "$tmp/no:$base"
check "a module pwsh does not list is missing: status" "$status" 1
check "a module pwsh does not list is missing: line" "$out" "missing: Fake  install: do-install"

run "$base"
check "no pwsh on PATH makes the module missing: status" "$status" 1
check "no pwsh on PATH makes the module missing: line" "$out" "missing: Fake  install: do-install"

printf '[{"name":"Odd","install":"x","pwsh_module":"Bad Name; rm"}]\n' >"$json"
run "$tmp/yes:$base"
check "a module name that is not a plain identifier is refused: status" "$status" 1
check "a module name that is not a plain identifier is refused: message" "$(printf '%s' "$out" | grep -c 'invalid pwsh_module' || true)" 1

printf '[{"name":"Old","install":"x","pwsh_module":"FakeMod","pwsh_min_version":"5.0"}]\n' >"$json"
run "$tmp/yes:$base"
check "the minimum version reaches pwsh: status" "$status" 0
check "the minimum version reaches pwsh: argument" "$(grep -c "ModuleVersion = '5.0'" "$tmp/yes/args")" 1

printf '[{"name":"Odd","install":"x","pwsh_module":"FakeMod","pwsh_min_version":"5; rm"}]\n' >"$json"
run "$tmp/yes:$base"
check "a version that is not digits and dots is refused: status" "$status" 1
check "a version that is not digits and dots is refused: message" "$(printf '%s' "$out" | grep -c 'invalid pwsh_min_version' || true)" 1

printf '[{"name":"Plain","install":"x","in_path":"sh"}]\n' >"$json"
run "$base"
check "in_path still works: status" "$status" 0

printf '[{"name":"None","install":"x"}]\n' >"$json"
run "$base"
check "an entry declaring no check is an error: status" "$status" 1

if [ "$failures" -ne 0 ]; then
  echo "$failures failure(s)"
  exit 1
fi
echo "all passed"
