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

# Review fixes: redaction is case-insensitive and handles quoted values
assert_eq "api_key=<redacted> x" "$(redact 'api_key=abc x')" "redact lowercase name"
assert_eq "password=<redacted>" "$(redact 'password=hunter2')" "redact lowercase password"
assert_eq "Github_Token=<redacted>" "$(redact 'Github_Token=x')" "redact mixed case"
assert_eq "PASSWORD=<redacted> next" "$(redact 'PASSWORD="a b c" next')" "redact double-quoted value"
assert_eq "my_secret=<redacted> next" "$(redact "my_secret='a b c' next")" "redact single-quoted value"
assert_eq "AUTHORIZATION: <redacted>" "$(redact 'AUTHORIZATION: Bearer abc')" "redact AUTHORIZATION"
assert_eq "authorization: <redacted>" "$(redact 'authorization: Bearer abc')" "redact authorization"
assert_eq "plain=value" "$(redact 'plain=value')" "redact leaves others"

# Review fixes: log() abbreviates the home directory in console and file
t_log=$(mktemp)
t_con=$(HOME=/home/u CONSOLE_LEVEL=INFO LOG_FILE="$t_log" log INFO x "see /home/u/x and ~/y" 2>&1)
assert_match 'see ~/x and ~/y$' "$t_con" "console abbreviates home"
assert_match 'see ~/x and ~/y$' "$(cat "$t_log")" "file abbreviates home"
t_con=$(HOME=/home/u CONSOLE_LEVEL=INFO LOG_FILE=/dev/null log INFO x "near /home/ux and /home/u" 2>&1)
assert_match 'near /home/ux and ~$' "$t_con" "home boundary respected"
rm -f "$t_log"

# Review fixes: minor
assert_eq "/etc/passwd" "$(HOME='' abbrev_home /etc/passwd)" "empty HOME does nothing"
assert_eq "0" "$(semver_compare 24.22.1-rc 24.22.1)" "semver suffix"
assert_eq "-1" "$(semver_compare 22 22.0.1)" "semver missing parts"
assert_status 0 "node 24.22.1-rc ok" node_version_ok v24.22.1-rc
assert_status 1 "node v22 too old" node_version_ok v22
assert_status 0 "node 27 ok" node_version_ok v27.0.0
assert_eq "warning: cannot write the log file; continuing without one" "$(LOG_FILE=/nonexistent-dir/x.log CONSOLE_LEVEL=ERROR log INFO x hi 2>&1)" "unwritable log: only the script warning shows"

# An inherited UNAME_S must not spoof detection in a real run.
t_tmp=$(mktemp -d)
t_out=$(UNAME_S=Darwin UNAME_M=arm64 REA_SETUP_NO_MAIN=0 sh "$ROOT/setup.sh" --dry-run --yes --log-dir "$t_tmp" 2>&1)
if [ "$(uname -s)" = Linux ] && [ "$(uname -m)" = x86_64 ]; then
  assert_match 'platform: linux' "$t_out" "main ignores inherited UNAME_S"
fi
assert_eq 1 "$(find "$t_tmp" -name 'setup-*.log' | wc -l | tr -d ' ')" "main wrote one log file"
rm -rf "$t_tmp"
# --- abs_path and the path options ---
assert_eq "$PWD/tools" "$(abs_path tools)" "relative path made absolute"
assert_eq "$PWD/tools" "$(abs_path ./tools)" "leading ./ dropped"
assert_eq "$PWD" "$(abs_path .)" "dot is the current directory"
assert_eq "/opt/x" "$(abs_path /opt/x)" "absolute path unchanged"
assert_eq "" "$(abs_path '')" "empty stays empty"
assert_eq "$PWD" "$(abs_path ./)" "./ is the current directory"
assert_eq "$PWD" "$(abs_path .//)" ".// is the current directory"
assert_eq "$PWD" "$(abs_path ././)" "././ is the current directory"
assert_eq "$PWD/tools" "$(abs_path .//tools)" ".//tools"
assert_eq "$PWD/tools" "$(abs_path tools/)" "trailing slash dropped"
assert_eq "$PWD/tools" "$(abs_path tools//)" "trailing slashes dropped"
assert_eq "$PWD/a/../b" "$(abs_path a/../b)" "dot-dot kept (symlinks decide), made absolute"
assert_eq "/opt/x" "$(abs_path /opt/x/)" "absolute path loses its trailing slash"
assert_eq "/" "$(abs_path /)" "root stays root"
for dot in ./ .//; do
  parse_args --folder "$dot" --tools-dir "$dot"
  assert_eq "$PWD" "$OPT_FOLDER" "--folder $dot is the current directory"
  assert_eq "$PWD" "$OPT_TOOLS_DIR" "--tools-dir $dot is the current directory"
done
parse_args --tools-dir tools --bin-dir ../bin --ghidra-dir gh --java-home ./jh --folder proj
assert_eq "$PWD/tools" "$OPT_TOOLS_DIR" "--tools-dir absolute"
assert_eq "$PWD/../bin" "$OPT_BIN_DIR" "--bin-dir absolute"
assert_eq "$PWD/gh" "$OPT_GHIDRA_DIR" "--ghidra-dir absolute"
assert_eq "$PWD/jh" "$OPT_JAVA_HOME" "--java-home absolute"
assert_eq "$PWD/proj" "$OPT_FOLDER" "--folder absolute"
parse_args
assert_eq "" "$OPT_TOOLS_DIR" "unset tools dir stays empty"

# --- main: seams are not reachable from the environment, the log path is the first console line, the hash is real ---
sm=$(ARCHIVE_TAR=x ARCHIVE_ZIP_TOOL=y LOCK_POLLS=1 sh -c '. ./setup.sh; usage() { echo "T=${ARCHIVE_TAR-unset} Z=${ARCHIVE_ZIP_TOOL-unset} L=${LOCK_POLLS-unset} N=${REA_SETUP_NO_MAIN-unset}"; }; main --help' 2>&1)
assert_eq "T=unset Z=unset L=unset N=unset" "$sm" "main unsets the test seams"
# a leftover REA_SETUP_NO_MAIN in the caller's environment must not turn a real run into a silent no-op
bogus_rc=0
bogus_out=$(REA_SETUP_NO_MAIN=1 sh "$ROOT/setup.sh" --bogus 2>&1) || bogus_rc=$?
assert_eq 2 "$bogus_rc" "setup.sh --bogus exits 2 even with REA_SETUP_NO_MAIN=1 in the environment"
assert_match "unknown option: --bogus" "$bogus_out" "the usage error is printed"
ld=$(mktemp -d "${TMPDIR:-/tmp}/rea-core-main.XXXXXX")
first=$(env -u REA_SETUP_NO_MAIN HOME="$ld" sh "$ROOT/setup.sh" --log-dir "$ld/logs" --dry-run --yes 2>&1 | head -n 1)
assert_match "^[^ ]+ INFO +\\[preflight\\] log file: ~/logs/setup-[0-9TZ]+-[0-9]+\\.log" "$first" "first console line names the log"
want=$(sha256_file "$ROOT/setup.sh")
assert_match "script version .* sha256 $want" "$(cat "$ld"/logs/setup-*.log)" "the log carries the real script hash"
rm -rf "$ld"

t_done
