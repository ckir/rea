#!/bin/sh
# Copyright (c) 2026 Costas Kirgoussios
#
# This software is licensed under the PolyForm Noncommercial License 1.0.0.
# You may obtain a copy of the License at:
# https://polyformproject.org/licenses/noncommercial/1.0.0/

# Tests the harness itself.
TEST_NO_SOURCE=1
export TEST_NO_SOURCE
# shellcheck source=/dev/null
. "$(dirname "$0")/lib.sh"

assert_eq a a "assert_eq equal strings pass"
assert_status 3 "assert_status matches the exit code" sh -c 'exit 3'
assert_match '^a+$' aaa "assert_match matches"
assert_file "$ROOT/tests/sh/lib.sh" "assert_file finds lib.sh"

# A failing assertion must be counted and make t_done exit 1. Run in a subshell so it cannot taint this run.
sub_rc=0
(
  assert_eq a b "deliberate failure" 2>/dev/null
  t_done >/dev/null
) || sub_rc=$?
assert_eq 1 "$sub_rc" "a failed assert_eq makes t_done exit 1"

t_done
