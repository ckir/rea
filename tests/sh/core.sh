#!/bin/sh
# Copyright (c) 2026 Costas Kirgoussios
#
# This software is licensed under the PolyForm Noncommercial License 1.0.0.
# You may obtain a copy of the License at:
# https://polyformproject.org/licenses/noncommercial/1.0.0/

# Tests for the setup.sh core: logging, redaction, arguments, platform, validation, versions.
# shellcheck source=/dev/null
. "$(dirname "$0")/lib.sh"
cd "$ROOT" || exit 1

assert_eq "2026-01-02T03:04:05Z INFO  [ghidra] hello" "$(LOG_FILE=/dev/null log_format INFO ghidra hello 2026-01-02T03:04:05Z)" "log format"
assert_match '^ERROR \[x\]' "$(CONSOLE_LEVEL=INFO LOG_FILE=/dev/null log ERROR x boom 2>&1 | cut -d' ' -f2-)" "console shows ERROR"
assert_eq "" "$(CONSOLE_LEVEL=WARN LOG_FILE=/dev/null log INFO x hidden 2>&1)" "quiet hides INFO"
assert_eq "GITHUB_TOKEN=<redacted> KEY=<redacted>" "$(redact 'GITHUB_TOKEN=abc KEY=def')" "redact names"
assert_eq "https://h/p" "$(redact 'https://u:p@h/p?x=1')" "redact userinfo and query"
t_tilde='~'
assert_eq "$t_tilde/x" "$(HOME=/home/u abbrev_home /home/u/x)" "abbrev home"
assert_status 2 "unknown flag" sh -c '. ./setup.sh; parse_args --bogus'
assert_status 0 "profile ok" profile_name_valid rea-1.x
for bad in doctor Doctor CON con.txt -x '' 'a b' 'ok.'; do assert_status 1 "reject $bad" profile_name_valid "$bad"; done
assert_eq 0.17.0 "$(semver_from_output 'clavity-ls 0.17.0+c356375b')" "semver from clavity-ls"
assert_eq 0.1.1 "$(semver_from_output 'agent-profile 0.1.1')" "semver from agent-profile"
assert_eq -1 "$(semver_compare 0.1.1 0.1.2)" "compare lt"
assert_eq 1 "$(semver_compare 0.17.0 0.9.9)" "compare gt"
assert_status 1 "node 24.21.0 too old" node_version_ok v24.21.0
assert_status 0 "node 24.22.2 ok" node_version_ok v24.22.2
assert_status 0 "node 26.12.1 ok" node_version_ok v26.12.1
assert_status 1 "node 23 unsupported" node_version_ok v23.5.0
assert_status 2 "non-interactive without --yes" sh -c '. ./setup.sh; OPT_YES=0; confirm "Proceed?" </dev/null'
assert_eq "linux x64" "$(
  UNAME_S=Linux UNAME_M=x86_64 platform_detect
  echo "$OS $ARCH"
)" "platform linux"
assert_eq "mac aarch64" "$(
  UNAME_S=Darwin UNAME_M=arm64 platform_detect
  echo "$OS $ARCH"
)" "platform mac arm"
assert_status 1 "linux arm64 unsupported" sh -c '. ./setup.sh; UNAME_S=Linux UNAME_M=aarch64 platform_detect'

# An inherited UNAME_S must not spoof detection in a real run.
t_tmp=$(mktemp -d)
t_out=$(UNAME_S=Darwin UNAME_M=arm64 REA_SETUP_NO_MAIN=0 sh "$ROOT/setup.sh" --dry-run --yes --log-dir "$t_tmp" 2>&1)
if [ "$(uname -s)" = Linux ] && [ "$(uname -m)" = x86_64 ]; then
  assert_match 'platform: linux' "$t_out" "main ignores inherited UNAME_S"
fi
assert_eq 1 "$(find "$t_tmp" -name 'setup-*.log' | wc -l | tr -d ' ')" "main wrote one log file"
rm -rf "$t_tmp"
t_done
