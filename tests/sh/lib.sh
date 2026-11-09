#!/bin/sh
# Copyright (c) 2026 Costas Kirgoussios
#
# This software is licensed under the PolyForm Noncommercial License 1.0.0.
# You may obtain a copy of the License at:
# https://polyformproject.org/licenses/noncommercial/1.0.0/

# Test harness, sourced (never run) by every tests/sh/<area>.sh:
#   . "$(dirname "$0")/lib.sh"
# Sets ROOT, exports REA_SETUP_NO_MAIN=1 and sources $ROOT/setup.sh. A missing setup.sh is tolerated only
# when TEST_NO_SOURCE=1 (set by harness.sh), so every later test fails loudly if the script is absent.
# Provides assert_eq, assert_status, assert_match, assert_file and t_done.

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
REA_SETUP_NO_MAIN=1
export REA_SETUP_NO_MAIN
T_PASS=0
T_FAIL=0

if [ "${TEST_NO_SOURCE:-}" != 1 ]; then
  if [ ! -r "$ROOT/setup.sh" ]; then
    echo "lib.sh: $ROOT/setup.sh not found (set TEST_NO_SOURCE=1 to test the harness alone)" >&2
    exit 1
  fi
  # shellcheck source=/dev/null
  . "$ROOT/setup.sh"
fi

t_ok() {
  T_PASS=$((T_PASS + 1))
}

t_fail() {
  T_FAIL=$((T_FAIL + 1))
  printf 'FAIL: %s\n' "$1" >&2
}

# assert_eq EXPECTED ACTUAL LABEL
assert_eq() {
  if [ "$1" = "$2" ]; then
    t_ok
  else
    t_fail "${3:-assert_eq}: expected [$1] got [$2]"
  fi
}

# assert_status CODE LABEL cmd...
assert_status() {
  as_want=$1
  as_label=$2
  shift 2
  as_rc=0
  "$@" >/dev/null 2>&1 || as_rc=$?
  if [ "$as_rc" -eq "$as_want" ]; then
    t_ok
  else
    t_fail "$as_label: expected status $as_want got $as_rc"
  fi
}

# assert_match REGEX TEXT LABEL (extended regular expression)
assert_match() {
  if printf '%s\n' "$2" | grep -Eq -- "$1"; then
    t_ok
  else
    t_fail "${3:-assert_match}: [$2] does not match /$1/"
  fi
}

# assert_file FILE LABEL
assert_file() {
  if [ -f "$1" ]; then
    t_ok
  else
    t_fail "${2:-assert_file}: no such file $1"
  fi
}

# t_done: prints `ok N` or `FAIL N` and exits 0/1. A run that asserted nothing is a failure.
t_done() {
  if [ "$T_FAIL" -ne 0 ]; then
    echo "FAIL $T_FAIL"
    exit 1
  fi
  if [ "$T_PASS" -eq 0 ]; then
    echo "FAIL no assertions ran"
    exit 1
  fi
  echo "ok $T_PASS"
  exit 0
}
