#!/bin/sh
# Copyright (c) 2026 Costas Kirgoussios
#
# This software is licensed under the PolyForm Noncommercial License 1.0.0.
# You may obtain a copy of the License at:
# https://polyformproject.org/licenses/noncommercial/1.0.0/

# Tests for scripts/check-drift.sh: the real pins pass, and each way of drifting or breaking a pin fails.

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

# case_ <name> <expected status> <sed expr for setup.sh> <sed expr for setup.ps1> <pattern the output must match>
case_() {
  sed -e "$3" "$root/setup.sh" >"$tmp/setup.sh"
  sed -e "$4" "$root/setup.ps1" >"$tmp/setup.ps1"
  set +e
  sh "$root/scripts/check-drift.sh" "$tmp/setup.sh" "$tmp/setup.ps1" >"$tmp/out" 2>&1
  status=$?
  set -e
  check "$1" "$status" "$2"
  if ! grep -Eq "$5" "$tmp/out"; then
    echo "FAIL - $1: output does not match '$5': $(cat "$tmp/out")"
    failures=$((failures + 1))
  fi
}

case_ "real pins are identical" 0 "" "" "pins identical"
case_ "a changed ps1 value fails" 1 "" "s/^\\(.script:PIN_GHIDRA_ZIP_BYTES = '\\)[0-9]*/\\19/" "pins differ"
case_ "a changed sh value fails" 1 "s/^PIN_JDK_MAJOR=21/PIN_JDK_MAJOR=22/" "" "pins differ"
case_ "a pin missing from ps1 fails" 1 "" "/PIN_REA_SPEC/d" "pins differ"
case_ "a bad sha fails on both sides" 1 "s/^PIN_GHIDRA_SHA256=dd/PIN_GHIDRA_SHA256=DD/" "s/PIN_GHIDRA_SHA256 = 'dd/PIN_GHIDRA_SHA256 = 'DD/" "not 64 lower-case hex"
case_ "a host outside the allow list fails" 1 "s#github.com/NationalSecurityAgency#evil.example/NationalSecurityAgency#" "s#github.com/NationalSecurityAgency#evil.example/NationalSecurityAgency#" "not in PIN_ALLOWED_HOSTS"
case_ "empty ps1 pin list fails" 1 "" "s/pins begin/pins start/" "exactly one"
case_ "empty sh pin list fails" 1 "s/pins end/pins stop/" "" "exactly one"

case_ "version 0.1.0 passes" 0 "s/^PIN_SCRIPT_VERSION=.*/PIN_SCRIPT_VERSION=0.1.0/" "" "pins identical"
case_ "a two-part version fails in both files" 1 "s/^PIN_SCRIPT_VERSION=.*/PIN_SCRIPT_VERSION=0.1/" "s/PIN_SCRIPT_VERSION = '.*'/PIN_SCRIPT_VERSION = '0.1'/" "not X.Y.Z"
case_ "a v-prefixed version fails in both files" 1 "s/^PIN_SCRIPT_VERSION=.*/PIN_SCRIPT_VERSION=v0.1.0/" "s/PIN_SCRIPT_VERSION = '.*'/PIN_SCRIPT_VERSION = 'v0.1.0'/" "not X.Y.Z"
case_ "a four-part version fails in both files" 1 "s/^PIN_SCRIPT_VERSION=.*/PIN_SCRIPT_VERSION=0.1.0.1/" "s/PIN_SCRIPT_VERSION = '.*'/PIN_SCRIPT_VERSION = '0.1.0.1'/" "not X.Y.Z"
case_ "a suffixed version fails in both files" 1 "s/^PIN_SCRIPT_VERSION=.*/PIN_SCRIPT_VERSION=0.1.0-rc1/" "s/PIN_SCRIPT_VERSION = '.*'/PIN_SCRIPT_VERSION = '0.1.0-rc1'/" "not X.Y.Z"
case_ "a bad version in setup.sh only fails" 1 "s/^PIN_SCRIPT_VERSION=.*/PIN_SCRIPT_VERSION=0.1/" "" "pins differ"
case_ "a bad version in setup.ps1 only fails" 1 "" "s/PIN_SCRIPT_VERSION = '.*'/PIN_SCRIPT_VERSION = '0.1'/" "pins differ"
case_ "an empty version fails in both files" 1 "s/^PIN_SCRIPT_VERSION=.*/PIN_SCRIPT_VERSION=/" "s/PIN_SCRIPT_VERSION = '.*'/PIN_SCRIPT_VERSION = ''/" "not X.Y.Z"
case_ "a pin only in ps1 fails" 1 "" "/pins begin/a\\
\$script:PIN_EXTRA = 'x'" "pins differ"
case_ "a pin only in sh fails" 1 "/pins begin/a\\
PIN_EXTRA=x" "" "pins differ"
case_ "a duplicated marker fails" 1 "/pins end/a\\
# --- pins end ---" "" "exactly one"
case_ "an http URL in a pin fails" 1 "s#^PIN_AGENT_PROFILE_REPO=.*#PIN_AGENT_PROFILE_REPO=http://github.com/x/#" "s#^\\(.script:PIN_AGENT_PROFILE_REPO = \\).*#\\1'http://github.com/x/'#" "http://"
exit "$failures"
