#!/bin/sh
# Copyright (c) 2026 Costas Kirgoussios
#
# This software is licensed under the PolyForm Noncommercial License 1.0.0.
# You may obtain a copy of the License at:
# https://polyformproject.org/licenses/noncommercial/1.0.0/

# Tests for scripts/check-ci-tool-pins.sh, the gate that no workflow spells out the version of a tool
# scripts/ci-tools.lock already pins, and that every lock key a workflow reads exists.
#
# The gate takes the workflow directory and the lock as arguments, so each case is a directory holding a
# lock and a wf/ directory of fixture workflows.

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

# fixture <name> <line>...: a case directory with the lock and wf/w.yml holding the jobs skeleton and each
# <line> verbatim after `steps:`. Sets dir.
fixture() {
  dir="$tmp/$1"
  shift
  mkdir -p "$dir/wf"
  {
    echo just=1.58.0
    echo actionlint=1.7.12
    echo pester=5.9.0
    echo psscriptanalyzer=1.25.0
  } >"$dir/lock"
  {
    printf 'name: t\non: push\njobs:\n  j:\n    runs-on: ubuntu-latest\n    steps:\n'
    for l in "$@"; do
      printf '%s\n' "$l"
    done
  } >"$dir/wf/w.yml"
}

# run: sets out and status.
run() {
  set +e
  out=$(sh "$root/scripts/check-ci-tool-pins.sh" "$dir/wf" "$dir/lock" 2>&1)
  status=$?
  set -e
}

# line numbers: the skeleton is 6 lines, so the first fixture line is line 7.

fixture ok \
  '      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1' \
  "        run: echo \"tools=just@\$(sed -n 's/^just=//p' scripts/ci-tools.lock)\"" \
  "        run: go install \"github.com/rhysd/actionlint/cmd/actionlint@v\$(sed -n 's/^actionlint=//p' scripts/ci-tools.lock)\"" \
  "        run: \$p = (Select-String -Path scripts/ci-tools.lock -Pattern '^pester=(.*)\$').Matches[0].Groups[1].Value; Install-Module Pester -RequiredVersion \$p" \
  '      # Pester 5.9.0 and actionlint@v1.7.12 in a comment are prose, not a pin' \
  '        run: npm install --global node@20.1.0'
run
check "versions read from the lock pass" "$status" 0
has "the summary counts the reads" "$out" "3 lock key(s) read, no literal tool versions"

fixture goinstall '        run: go install github.com/rhysd/actionlint/cmd/actionlint@v1.7.12'
run
check "a literal go install version fails" "$status" 1
has "the line is named" "$out" "w.yml:7:"
has "the tool is named" "$out" "spells out the version of 'actionlint'"

fixture install-action '        with: { tool: just@1.58.0 }'
run
check "a literal tool@version fails" "$status" 1
has "the just pin is named" "$out" "spells out the version of 'just'"

fixture case '        run: Install-Module -Name Pester@5.9.0'
run
check "the key match ignores case (Pester vs pester)" "$status" 1
has "the lock key is named" "$out" "'pester'"

fixture required '        run: Install-Module Pester -RequiredVersion 5.9.0 -Force'
run
check "a literal -RequiredVersion fails" "$status" 1
has "the module version is named" "$out" "gives a module version literally"

fixture quoted "        run: Install-Module Pester -RequiredVersion '5.9.0'"
run
check "a quoted -RequiredVersion fails" "$status" 1

fixture minimum '        run: Import-Module Pester -MinimumVersion 5.0'
run
check "a literal -MinimumVersion fails" "$status" 1

fixture comment '      # run: Install-Module Pester -RequiredVersion 5.9.0 and just@1.58.0'
run
check "a commented-out literal is not a pin" "$status" 0

fixture badkey "        run: echo \$(sed -n 's/^lefthook=//p' scripts/ci-tools.lock)"
run
check "reading a key the lock lacks fails" "$status" 1
has "the missing key is named" "$out" "reads 'lefthook' from the lock, which has no such key"

fixture onebad "        run: echo \"just@\$(sed -n 's/^just=//p' scripts/ci-tools.lock),x@\$(sed -n 's/^typos=//p' scripts/ci-tools.lock)\""
run
check "one missing key among several fails" "$status" 1
has "only the missing key is named" "$out" "reads 'typos'"
lacks "the present key is not named" "$out" "reads 'just'"

fixture psbad "        run: (Select-String -Path scripts/ci-tools.lock -Pattern '^pestr=(.*)\$').Matches[0].Groups[1].Value"
run
check "a misspelt key in a Select-String read fails" "$status" 1
has "the misspelling is named" "$out" "reads 'pestr'"

fixture other '        run: npm install --global somethingelse@2.0.0'
run
check "a tool the lock does not pin is out of scope" "$status" 0

fixture two '        run: go install x/actionlint@v1.7.12' '        run: Install-Module Pester -RequiredVersion 5.9.0'
run
check "two violations fail" "$status" 1
has "the count is printed" "$out" "2 violation(s)"

# a broken scan is not a clean one
fixture nolock '      - run: echo hi'
rm "$dir/lock"
run
check "a missing lock fails" "$status" 1
has "the missing lock is named" "$out" "does not exist"

fixture emptylock '      - run: echo hi'
: >"$dir/lock"
run
check "a lock without keys fails" "$status" 1
has "the refusal says nothing was found" "$out" "found nothing to scan"

fixture nowf '      - run: echo hi'
rm "$dir/wf/w.yml"
run
check "a directory without workflows fails" "$status" 1
has "the refusal says nothing was found" "$out" "found nothing to scan"

if [ "$(id -u)" -ne 0 ]; then
  fixture unreadable '        run: echo hi'
  chmod 000 "$dir/wf/w.yml"
  run
  chmod 600 "$dir/wf/w.yml"
  check "an unreadable workflow fails" "$status" 1
  lacks "it does not claim to be clean" "$out" "no literal tool versions"
fi

# the real tree is clean (the gate's own recipe runs it too; this keeps the fixture shapes honest)
set +e
out=$(sh "$root/scripts/check-ci-tool-pins.sh" 2>&1)
status=$?
set -e
check "the repository's workflows pass" "$status" 0

if [ "$failures" -ne 0 ]; then
  echo "$failures failure(s)"
  exit 1
fi
echo "all check-ci-tool-pins tests passed"
