#!/bin/sh
# Copyright (c) 2026 Costas Kirgoussios
#
# This software is licensed under the PolyForm Noncommercial License 1.0.0.
# You may obtain a copy of the License at:
# https://polyformproject.org/licenses/noncommercial/1.0.0/

# Tests for the setup.sh steps rea-setup and rea-doctor. The npx stub of tests/fixtures/bin (reached through a
# private directory that holds only a link to it, so the real node stays on PATH) records each call's argument
# list and the three environment variables rea gets, prints a doctor fixture and exits as told. The doctor
# fixtures are real `rea doctor --json` answers (paths sanitised). Every run uses a scratch HOME that must end
# empty: the steps never write ~/.claude or ~/.claude.json. Every directory has a space in its name.
# shellcheck source=/dev/null
. "$(dirname "$0")/lib.sh"
cd "$ROOT" || exit 1

T="$ROOT/tests/.tmp/rea work $$"
mkdir -p "$T" || exit 1
cleanup_all() {
  rm -rf "$T"
  rmdir "$ROOT/tests/.tmp" 2>/dev/null
}
trap cleanup_all EXIT
trap 'exit 1' INT TERM

unset GITHUB_TOKEN CLAUDE_CONFIG_DIR GHIDRA_INSTALL_DIR JAVA_HOME
FIX=$ROOT/tests/fixtures
OS=linux
OPT_DRY_RUN=0
OPT_CHECK_UPSTREAM=0
OPT_INSTALL_HOPPER=0
CONSOLE_LEVEL=ERROR
export OS OPT_DRY_RUN OPT_CHECK_UPSTREAM OPT_INSTALL_HOPPER CONSOLE_LEVEL
HOME_DIR="$T/home dir"
CFG="$T/prof dir/claude"
GH="$T/ghidra dir"
JH="$T/jdk dir"
STUBBIN="$T/stub bin"
REAL_PATH=$PATH
mkdir -p "$HOME_DIR" "$CFG" "$GH" "$JH" "$STUBBIN" || exit 1
ln -s "$FIX/bin/npx" "$STUBBIN/npx"
printf '{"mcpServers":{"rea":{"command":"npx","args":["-y","rea-agents@6.8.0","mcp"]}}}\n' >"$T/cfg-ok.json"
printf '{"mcpServers":{}}\n' >"$T/cfg-norea.json"
printf '{"mcpServers":null}\n' >"$T/cfg-null.json"
printf 'not json\n' >"$T/cfg-bad.json"
printf 'this is not json\n' >"$T/notjson.txt"
printf '[1,2]\n' >"$T/array.json"
: >"$T/empty.txt"

CO=$FIX/rea-doctor-client-ok.json
CE=$FIX/rea-doctor-client-empty.json
GO=$FIX/rea-doctor-ghidra-ok.json
GB=$FIX/rea-doctor-ghidra-bad.json
GM=$FIX/rea-doctor-ghidra-mac-nodecomp.json

# --- fixtures: rea_doctor_healthy and rea_ghidra_status ---
assert_status 0 "healthy: client-ok" rea_doctor_healthy "$CO"
assert_status 1 "healthy: client-empty" rea_doctor_healthy "$CE"
assert_status 0 "healthy: ghidra-ok" rea_doctor_healthy "$GO"
assert_status 1 "healthy: ghidra-bad" rea_doctor_healthy "$GB"
assert_status 1 "healthy: not JSON" rea_doctor_healthy "$T/notjson.txt"
assert_status 1 "healthy: empty file" rea_doctor_healthy "$T/empty.txt"
assert_status 1 "healthy: an array" rea_doctor_healthy "$T/array.json"
assert_eq "registration:claude_code skill:identity" "$(rea_doctor_failing "$CE" | tr '\n' ' ' | sed 's/ $//')" "failing: the empty profile names both scope checks"
assert_eq "" "$(rea_doctor_failing "$CO")" "failing: the healthy client names none"
assert_eq "true 12.1.4" "$(rea_ghidra_status "$GO")" "status: ghidra-ok"
assert_eq "true 12.1.4" "$(rea_ghidra_status "$CO")" "status: the ghidra provider of the client answer"
assert_eq "false - installation,java" "$(rea_ghidra_status "$GB")" "status: ghidra-bad names installation and java"
assert_eq "false 12.1.4 native_decompiler" "$(rea_ghidra_status "$GM")" "status: mac-nodecomp names native_decompiler"
printf '{}\n' >"$T/noprov.json"
assert_eq "false - ghidra_provider_missing" "$(rea_ghidra_status "$T/noprov.json")" "status: no providerInspections reads as missing"
printf '{"providerInspections":[null,{"id":"ghidra","available":true,"providerVersion":null,"checks":[null,{"name":"x"}]}]}\n' >"$T/nullish.json"
assert_eq "true - x" "$(rea_ghidra_status "$T/nullish.json")" "status: nulls are tolerated, a check without ok:true is failing"
assert_status 0 "object: client-ok" rea_json_object "$CO"
assert_status 1 "object: an array" rea_json_object "$T/array.json"
assert_status 1 "object: not JSON" rea_json_object "$T/notjson.txt"
assert_eq 1 "$(grep -c '' "$CE")" "fixtures: client-empty is one line"
# the forbidden strings are built here so that this file does not hold them verbatim
BAD1="/home/""user"
BAD2="/tmp/""claude"
BAD3="claude-""1001"
BAD4="Kirgous""sios"
BAD5="Cos""tas"
for bad in "$BAD1" "$BAD2" "$BAD3" "$BAD4" "$BAD5"; do
  assert_eq "" "$(grep -l -F "$bad" "$FIX"/rea-doctor-*.json | tr '\n' ' ')" "fixtures: no session or personal string [$bad]"
done
assert_eq "config_drift" "$(json_query "$GM" '(d.scope_checks.find(c=>c.name==="ghidra-native_decompiler")).classification')" "fixtures: the failing mac scope check is not classified healthy"
assert_eq "false false" "$(json_query "$GM" '[d.scope_checks.find(c=>c.name==="ghidra-native_decompiler").ok,d.checks.find(c=>c.name==="ghidra-native_decompiler").ok].join(" ")')" "fixtures: mac-nodecomp is failing in scope_checks and checks"
assert_eq "false" "$(json_query "$GM" '(d.providerInspections.find(p=>p.id==="ghidra")).available')" "fixtures: mac-nodecomp is unavailable"
assert_eq "executable_missing" "$(json_query "$GM" '((d.providerInspections.find(p=>p.id==="ghidra")).checks.find(c=>c.name==="native_decompiler")).code')" "fixtures: mac-nodecomp code"

# run_rea NAME FN: FN (a step) in a subshell with the scratch HOME, the npx stub first on PATH and the profile,
# Ghidra and JDK directories selected; the stub's log is $T/NAME.npx (.env beside it), the step's log
# $T/NAME.log, its console output $T/NAME.out. RS_PRE, a shell command, runs first. Returns the subshell's
# exit code.
run_rea() {
  rr_rc=0
  (
    LOG_FILE=$T/$1.log
    : >"$LOG_FILE"
    HOME=$HOME_DIR
    PATH="$STUBBIN:$REAL_PATH"
    STUB_NPX_LOG=$T/$1.npx
    CLAUDE_CONFIG_DIR_SELECTED=$CFG
    GHIDRA_DIR_SELECTED=$GH
    JAVA_HOME_SELECTED=$JH
    export LOG_FILE HOME PATH STUB_NPX_LOG CLAUDE_CONFIG_DIR_SELECTED GHIDRA_DIR_SELECTED JAVA_HOME_SELECTED
    install_traps
    eval "${RS_PRE:-:}"
    "$2"
    rr_step_rc=$?
    printf 'summary_setup=%s\nsummary_doctor=%s\nclaude=%s\npath=%s\n' "$(summary_get rea_setup)" "$(summary_get rea_doctor)" "${CLAUDE_CONFIG_DIR:-unset}" "$PATH" >"$T/$1.state"
    exit "$rr_step_rc"
  ) >"$T/$1.out" 2>&1 || rr_rc=$?
  return "$rr_rc"
}
logtext() { cat "$T/$1.log"; }
calls() { cat "$T/$1.npx" 2>/dev/null; }
state() { sed -n "s/^$2=//p" "$T/$1.state"; }
home_empty() {
  he_n=0
  for he_f in "$HOME_DIR"/* "$HOME_DIR"/.[!.]*; do
    if [ -e "$he_f" ] || [ -L "$he_f" ]; then
      he_n=$((he_n + 1))
    fi
  done
  assert_eq 0 "$he_n" "$1: nothing was created under HOME"
}
SETUP_DRY='-y rea-agents@latest setup --client claude_code --dry-run'
SETUP_REAL='-y rea-agents@latest setup --client claude_code --yes'
DOC_CLIENT='-y rea-agents@latest doctor --client claude_code --skill --json'
DOC_GHIDRA='-y rea-agents@latest doctor --provider ghidra --json'
nl='
'

# --- step_rea_setup ---
rm -f "$CFG/.claude.json"
RS_PRE="STUB_NPX_CONFIG_2='$T/cfg-ok.json'; export STUB_NPX_CONFIG_2"
rc=0
run_rea s1 step_rea_setup || rc=$?
assert_eq 0 "$rc" "setup: succeeds and finds mcpServers.rea"
assert_eq "$SETUP_DRY${nl}$SETUP_REAL" "$(calls s1)" "setup: the dry-run call, then the real one, exactly"
assert_eq "1: CLAUDE_CONFIG_DIR=$CFG
1: GHIDRA_INSTALL_DIR=$GH
1: JAVA_HOME=$JH
2: CLAUDE_CONFIG_DIR=$CFG
2: GHIDRA_INSTALL_DIR=$GH
2: JAVA_HOME=$JH" "$(cat "$T/s1.npx.env")" "setup: the child gets the three variables, both calls"
assert_eq unset "$(state s1 claude)" "setup: the parent's CLAUDE_CONFIG_DIR stays unset"
assert_match "registered rea in " "$(state s1 summary_setup)" "setup: the summary says registered"
assert_match 'DEBUG +\[rea-setup\] run: env CLAUDE_CONFIG_DIR=.* npx -y rea-agents@latest setup --client claude_code --dry-run' "$(logtext s1)" "setup: the dry-run is logged"
assert_match 'INFO +\[rea-setup\] ok$' "$(logtext s1)" "setup: ok is logged"
home_empty "setup"

# the dry-run output goes to the log at DEBUG
printf 'would write the registration\n' >"$T/dry-out.txt"
rm -f "$CFG/.claude.json"
RS_PRE="STUB_NPX_FILE_1='$T/dry-out.txt'; STUB_NPX_CONFIG_2='$T/cfg-ok.json'; export STUB_NPX_FILE_1 STUB_NPX_CONFIG_2"
run_rea s2 step_rea_setup
assert_match 'DEBUG +\[rea-setup\] rea setup dry-run output: would write the registration' "$(logtext s2)" "setup: the dry-run stdout is logged at DEBUG"

# the parent's CLAUDE_CONFIG_DIR is unchanged when it was set
rm -f "$CFG/.claude.json"
RS_PRE="CLAUDE_CONFIG_DIR='/parent/own dir'; export CLAUDE_CONFIG_DIR; STUB_NPX_CONFIG_2='$T/cfg-ok.json'; export STUB_NPX_CONFIG_2"
run_rea s3 step_rea_setup
assert_eq "/parent/own dir" "$(state s3 claude)" "setup: the parent's own CLAUDE_CONFIG_DIR is unchanged"
assert_eq "2: CLAUDE_CONFIG_DIR=$CFG" "$(grep '^2: CLAUDE' "$T/s3.npx.env")" "setup: the child still gets the profile directory"

# the stub directory is on PATH for the call only: the caller's PATH is whatever it was
assert_eq "$STUBBIN:$REAL_PATH" "$(state s3 path)" "setup: PATH is not rewritten by the step"
assert_status 1 "setup: the stub directory is not on the test shell's own PATH" sh -c "command -v npx | grep -qF '$STUBBIN'"

# --install-hopper only when asked
rm -f "$CFG/.claude.json"
RS_PRE="OPT_INSTALL_HOPPER=1; STUB_NPX_CONFIG_2='$T/cfg-ok.json'; export STUB_NPX_CONFIG_2"
run_rea s4 step_rea_setup
assert_eq "$SETUP_DRY${nl}$SETUP_REAL --install-hopper" "$(calls s4)" "setup: --install-hopper is appended to the real call only"

# a non-zero real setup: exit 1, doctor not run (main would stop), the stderr tail in the message
rm -f "$CFG/.claude.json"
RS_PRE="STUB_NPX_EXIT_2=3; STUB_NPX_STDERR_2='boom from rea'; export STUB_NPX_EXIT_2 STUB_NPX_STDERR_2"
rc=0
run_rea s5 step_rea_setup || rc=$?
assert_eq 1 "$rc" "setup: a failing rea setup dies with 1"
assert_match 'ERROR +\[rea-setup\] rea setup exited 3: boom from rea' "$(logtext s5)" "setup: the exit code and stderr are named"
assert_eq 2 "$(calls s5 | grep -c '')" "setup: no call after the failure"

# a non-zero dry-run: exit 1 before the real call
RS_PRE="STUB_NPX_EXIT_1=7; export STUB_NPX_EXIT_1"
rc=0
run_rea s6 step_rea_setup || rc=$?
assert_eq 1 "$rc" "setup: a failing dry-run dies with 1"
assert_eq "$SETUP_DRY" "$(calls s6)" "setup: the real call is not made after a failing dry-run"

# no .claude.json afterwards
rm -f "$CFG/.claude.json"
RS_PRE=":"
rc=0
run_rea s7 step_rea_setup || rc=$?
assert_eq 1 "$rc" "setup: a missing .claude.json dies with 1"
assert_match 'ERROR +\[rea-setup\] rea setup left no \.claude\.json' "$(logtext s7)" "setup: the missing file is named"
for bad in norea null bad; do
  rm -f "$CFG/.claude.json"
  RS_PRE="STUB_NPX_CONFIG_2='$T/cfg-$bad.json'; export STUB_NPX_CONFIG_2"
  rc=0
  run_rea "s8$bad" step_rea_setup || rc=$?
  assert_eq 1 "$rc" "setup: a .claude.json ($bad) without mcpServers.rea dies with 1"
  assert_match 'ERROR +\[rea-setup\] .*no mcpServers\.rea' "$(logtext "s8$bad")" "setup: $bad names mcpServers.rea"
  assert_eq "" "$(grep -c 'TypeError' "$T/s8$bad.out" | sed 's/^0$//')" "setup: $bad raises no Node TypeError"
done

# defence in depth: the shared profile and an empty selection
for bad in "$HOME_DIR/.claude" "$HOME_DIR/.claude/profiles/x" ""; do
  RS_PRE="CLAUDE_CONFIG_DIR_SELECTED='$bad'"
  rc=0
  run_rea s9 step_rea_setup || rc=$?
  assert_eq 1 "$rc" "setup: [$bad] is refused with 1"
  assert_eq "" "$(calls s9)" "setup: [$bad] runs no npx"
done
RS_PRE="GHIDRA_DIR_SELECTED=''"
rc=0
run_rea s10 step_rea_setup || rc=$?
assert_eq 1 "$rc" "setup: no Ghidra directory dies with 1"
RS_PRE="JAVA_HOME_SELECTED=''"
rc=0
run_rea s11 step_rea_setup || rc=$?
assert_eq 1 "$rc" "setup: no JDK dies with 1"

# --dry-run: the dry-run call only, never the real setup
RS_PRE="OPT_DRY_RUN=1"
rc=0
run_rea s12 step_rea_setup || rc=$?
assert_eq 0 "$rc" "setup: --dry-run succeeds"
assert_eq "$SETUP_DRY" "$(calls s12)" "setup: --dry-run makes the dry-run call only"
assert_match 'read-only run' "$(logtext s12)" "setup: --dry-run says so"
# --dry-run with nothing selected (an install that did not happen): no npx at all
RS_PRE="OPT_DRY_RUN=1; CLAUDE_CONFIG_DIR_SELECTED=''"
rc=0
run_rea s13 step_rea_setup || rc=$?
assert_eq 0 "$rc" "setup: --dry-run without a selected profile succeeds"
assert_eq "" "$(calls s13)" "setup: --dry-run without a selected profile runs no npx"
# --check-upstream
RS_PRE="OPT_CHECK_UPSTREAM=1"
rc=0
run_rea s14 step_rea_setup || rc=$?
assert_eq 0 "$rc" "setup: --check-upstream succeeds"
assert_eq "" "$(calls s14)" "setup: --check-upstream runs no npx"
assert_match 'skip \(--check-upstream\)' "$(logtext s14)" "setup: --check-upstream is logged"
home_empty "setup cases"

# --- step_rea_doctor ---
RS_PRE="STUB_NPX_FILE_1='$CO'; STUB_NPX_FILE_2='$GO'; export STUB_NPX_FILE_1 STUB_NPX_FILE_2"
rc=0
run_rea d1 step_rea_doctor || rc=$?
assert_eq 0 "$rc" "doctor: healthy client and available ghidra"
assert_eq "$DOC_CLIENT${nl}$DOC_GHIDRA" "$(calls d1)" "doctor: the two calls, exactly"
assert_eq "ok: ghidra 12.1.4" "$(state d1 summary_doctor)" "doctor: the summary says ok"
assert_eq "1: CLAUDE_CONFIG_DIR=$CFG
1: GHIDRA_INSTALL_DIR=$GH
1: JAVA_HOME=$JH
2: CLAUDE_CONFIG_DIR=$CFG
2: GHIDRA_INSTALL_DIR=$GH
2: JAVA_HOME=$JH" "$(cat "$T/d1.npx.env")" "doctor: both calls get the three variables"
assert_match 'INFO +\[rea-doctor\] ok$' "$(logtext d1)" "doctor: ok is logged"

# exit 1 with a parsable unhealthy answer is read, not a crash: exit 5 naming the failing scope checks
RS_PRE="STUB_NPX_FILE_1='$CE'; STUB_NPX_EXIT_1=1; export STUB_NPX_FILE_1 STUB_NPX_EXIT_1"
rc=0
run_rea d2 step_rea_doctor || rc=$?
assert_eq 5 "$rc" "doctor: an unhealthy client dies with 5"
assert_match 'ERROR +\[rea-doctor\] .*registration:claude_code skill:identity' "$(logtext d2)" "doctor: registration:claude_code and skill:identity are named"
assert_eq 1 "$(calls d2 | grep -c '')" "doctor: the ghidra doctor is not run after an unhealthy client"

# ghidra-bad: exit 1 too; installation and java named
RS_PRE="STUB_NPX_FILE_1='$CO'; STUB_NPX_FILE_2='$GB'; STUB_NPX_EXIT_2=1; export STUB_NPX_FILE_1 STUB_NPX_FILE_2 STUB_NPX_EXIT_2"
rc=0
run_rea d3 step_rea_doctor || rc=$?
assert_eq 5 "$rc" "doctor: a bad Ghidra dies with 5"
assert_match 'ERROR +\[rea-doctor\] .*installation,java' "$(logtext d3)" "doctor: installation and java are named"
assert_eq "" "$(grep -c 'rea 6.8.0 accepts Ghidra' "$T/d3.log" | sed 's/^0$//')" "doctor: no version hint when the version check passes or is absent"

# the version check failing gets the pins hint
sed 's/"name":"installation","ok":false/"name":"installation","ok":true/; s/"name":"java","ok":false/"name":"version","ok":false/' "$GB" >"$T/gv.json"
RS_PRE="STUB_NPX_FILE_1='$CO'; STUB_NPX_FILE_2='$T/gv.json'; STUB_NPX_EXIT_2=1; export STUB_NPX_FILE_1 STUB_NPX_FILE_2 STUB_NPX_EXIT_2"
rc=0
run_rea d4 step_rea_doctor || rc=$?
assert_eq 5 "$rc" "doctor: a version failure dies with 5"
assert_match 'rea 6\.8\.0 accepts Ghidra 12\.1\.x; if rea now requires another line, update the pins block \(PIN_GHIDRA_\*\)' "$(logtext d4)" "doctor: the version hint is printed"

# mac + only native_decompiler: WARN, summary warn, success
RS_PRE="OS=mac; STUB_NPX_FILE_1='$CO'; STUB_NPX_FILE_2='$GM'; STUB_NPX_EXIT_2=1; export STUB_NPX_FILE_1 STUB_NPX_FILE_2 STUB_NPX_EXIT_2"
rc=0
run_rea d5 step_rea_doctor || rc=$?
assert_eq 0 "$rc" "doctor: mac with only native_decompiler failing continues"
assert_match 'WARN +\[rea-doctor\] .*Missing macOS native decompiler.*macOS arm64 native decompiler' "$(logtext d5)" "doctor: the WARN names both recipe sections"
assert_match "WARN +\\[rea-doctor\\] .*$GH" "$(logtext d5)" "doctor: the WARN names GHIDRA_INSTALL_DIR"
assert_match '^warn: ' "$(state d5 summary_doctor)" "doctor: the summary is warn"
# the same answer on linux is a failure
RS_PRE="OS=linux; STUB_NPX_FILE_1='$CO'; STUB_NPX_FILE_2='$GM'; STUB_NPX_EXIT_2=1; export STUB_NPX_FILE_1 STUB_NPX_FILE_2 STUB_NPX_EXIT_2"
rc=0
run_rea d6 step_rea_doctor || rc=$?
assert_eq 5 "$rc" "doctor: linux with native_decompiler failing dies with 5"
assert_match 'ERROR +\[rea-doctor\] .*native_decompiler' "$(logtext d6)" "doctor: linux names native_decompiler"
# mac with another failure besides native_decompiler is a failure
sed 's/"name":"java","ok":true/"name":"java","ok":false/' "$GM" >"$T/gm2.json"
RS_PRE="OS=mac; STUB_NPX_FILE_1='$CO'; STUB_NPX_FILE_2='$T/gm2.json'; STUB_NPX_EXIT_2=1; export STUB_NPX_FILE_1 STUB_NPX_FILE_2 STUB_NPX_EXIT_2"
rc=0
run_rea d7 step_rea_doctor || rc=$?
assert_eq 5 "$rc" "doctor: mac with native_decompiler and java failing dies with 5"

# output that is not JSON, empty output, an exit code other than 0 and 1
for bad in notjson empty; do
  RS_PRE="STUB_NPX_FILE_1='$T/$([ "$bad" = notjson ] && echo notjson.txt || echo empty.txt)'; STUB_NPX_STDERR_1='npm ERR! network'; export STUB_NPX_FILE_1 STUB_NPX_STDERR_1"
  rc=0
  run_rea "d8$bad" step_rea_doctor || rc=$?
  assert_eq 5 "$rc" "doctor: $bad output dies with 5"
  assert_match 'ERROR +\[rea-doctor\] .*not a JSON object.*npm ERR! network' "$(logtext "d8$bad")" "doctor: $bad output names the problem and the stderr tail"
done
RS_PRE="STUB_NPX_FILE_1='$CO'; STUB_NPX_EXIT_1=127; STUB_NPX_STDERR_1='npx: not found'; export STUB_NPX_FILE_1 STUB_NPX_EXIT_1 STUB_NPX_STDERR_1"
rc=0
run_rea d9 step_rea_doctor || rc=$?
assert_eq 5 "$rc" "doctor: an exit code of 127 dies with 5 even with parsable output"
assert_match 'exited 127: npx: not found' "$(logtext d9)" "doctor: the exit code and stderr are named"

# the exit code and the JSON must agree: exit 1 with a healthy answer, exit 0 with an unhealthy one
RS_PRE="STUB_NPX_FILE_1='$CO'; STUB_NPX_EXIT_1=1; export STUB_NPX_FILE_1 STUB_NPX_EXIT_1"
rc=0
run_rea e1 step_rea_doctor || rc=$?
assert_eq 5 "$rc" "doctor: exit 1 with healthy:true dies with 5"
assert_match 'ERROR +\[rea-doctor\] .*exit code and the JSON disagree' "$(logtext e1)" "doctor: the disagreement is named"
assert_eq 1 "$(calls e1 | grep -c '')" "doctor: no ghidra doctor after the contradiction"
RS_PRE="STUB_NPX_FILE_1='$CE'; STUB_NPX_EXIT_1=0; export STUB_NPX_FILE_1 STUB_NPX_EXIT_1"
rc=0
run_rea e2 step_rea_doctor || rc=$?
assert_eq 5 "$rc" "doctor: exit 0 with healthy:false dies with 5"
assert_match 'ERROR +\[rea-doctor\] .*registration:claude_code skill:identity' "$(logtext e2)" "doctor: exit 0 with healthy:false names the failing scope checks"
RS_PRE="STUB_NPX_FILE_1='$CO'; STUB_NPX_FILE_2='$GO'; STUB_NPX_EXIT_2=1; export STUB_NPX_FILE_1 STUB_NPX_FILE_2 STUB_NPX_EXIT_2"
rc=0
run_rea e3 step_rea_doctor || rc=$?
assert_eq 5 "$rc" "doctor: exit 1 with available:true dies with 5"
assert_match 'ERROR +\[rea-doctor\] .*exit code and the JSON disagree' "$(logtext e3)" "doctor: the ghidra disagreement is named"
RS_PRE="OS=mac; STUB_NPX_FILE_1='$CO'; STUB_NPX_FILE_2='$GO'; STUB_NPX_EXIT_2=1; export STUB_NPX_FILE_1 STUB_NPX_FILE_2 STUB_NPX_EXIT_2"
rc=0
run_rea e4 step_rea_doctor || rc=$?
assert_eq 5 "$rc" "doctor: the mac exception does not cover available:true with exit 1"
# a signal or exit 2 is a failure with the stderr tail
RS_PRE="STUB_NPX_FILE_1='$CO'; STUB_NPX_FILE_2='$GO'; STUB_NPX_EXIT_2=2; STUB_NPX_STDERR_2='usage error'; export STUB_NPX_FILE_1 STUB_NPX_FILE_2 STUB_NPX_EXIT_2 STUB_NPX_STDERR_2"
rc=0
run_rea e5 step_rea_doctor || rc=$?
assert_eq 5 "$rc" "doctor: ghidra doctor exit 2 dies with 5"
assert_match 'exited 2: usage error' "$(logtext e5)" "doctor: exit 2 names the stderr"

# the raw JSON goes to the log at DEBUG, redacted, and not to the console at INFO
node -e '
const fs=require("fs");const d=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
d.identity.cli_package_version="6.8.0-uniq-4711";d.GITHUB_TOKEN="abc123";
fs.writeFileSync(process.argv[2],JSON.stringify(d,null,1).replace(/\n */g," ")+"\n")' "$CO" "$T/co-secret.json"
RS_PRE="CONSOLE_LEVEL=INFO; STUB_NPX_FILE_1='$T/co-secret.json'; STUB_NPX_FILE_2='$GO'; export STUB_NPX_FILE_1 STUB_NPX_FILE_2"
rc=0
run_rea j1 step_rea_doctor || rc=$?
assert_eq 0 "$rc" "log: the injected-secret answer is otherwise healthy"
assert_match 'DEBUG +\[rea-doctor\] rea doctor --client claude_code --skill --json output: .*6\.8\.0-uniq-4711' "$(logtext j1)" "log: the raw client JSON is in the log file at DEBUG"
assert_match 'DEBUG +\[rea-doctor\] rea doctor --provider ghidra --json output: .*"providerVersion"' "$(logtext j1)" "log: the raw ghidra JSON is in the log file at DEBUG"
assert_eq "" "$(grep -c 'abc123' "$T/j1.log" | sed 's/^0$//')" "log: the secret-looking JSON value is redacted"
assert_match '<redacted>' "$(logtext j1)" "log: the redaction marker is there"
assert_eq "" "$(grep -c 'uniq-4711' "$T/j1.out" | sed 's/^0$//')" "log: the raw JSON is not on the console at INFO"
# the log text of a failing run holds the JSON too
RS_PRE="STUB_NPX_FILE_1='$CE'; STUB_NPX_EXIT_1=1; export STUB_NPX_FILE_1 STUB_NPX_EXIT_1"
run_rea j2 step_rea_doctor || :
assert_match 'output: \{"healthy":false' "$(logtext j2)" "log: the raw JSON of an unhealthy answer is logged"
# bounded to 200000 characters with a marker
node -e 'process.stdout.write(JSON.stringify({healthy:true,pad:"x".repeat(250000)})+"\n")' >"$T/big.json"
RS_PRE="STUB_NPX_FILE_1='$T/big.json'; STUB_NPX_FILE_2='$GO'; export STUB_NPX_FILE_1 STUB_NPX_FILE_2"
rc=0
run_rea j3 step_rea_doctor || rc=$?
assert_eq 0 "$rc" "log: a big answer is still parsed whole"
assert_match '\[output truncated at 200000 characters\]' "$(logtext j3)" "log: the truncation marker"
assert_eq 1 "$(awk 'length($0) > 201000 {n++} END {print n + 0 ? 0 : 1}' "$T/j3.log")" "log: no line is longer than the bound plus its prefix"
assert_status 0 "redact: a JSON-form secret" sh -c ". ./setup.sh; [ \"\$(redact '{\"GITHUB_TOKEN\": \"abc123\", \"x\": 1}')\" = '{\"GITHUB_TOKEN\": \"<redacted>\", \"x\": 1}' ]"

# no temporary file survives a failing doctor or a successful step, under a private TMPDIR
PRIV="$T/priv tmp"
mkdir -p "$PRIV"
RS_PRE="TMPDIR='$PRIV'; export TMPDIR; STUB_NPX_FILE_1='$CE'; STUB_NPX_EXIT_1=1; export STUB_NPX_FILE_1 STUB_NPX_EXIT_1"
run_rea t1 step_rea_doctor || :
assert_eq 0 "$(find "$PRIV" -type f | grep -c '')" "tmp: a doctor that fails leaves no file"
RS_PRE="TMPDIR='$PRIV'; export TMPDIR; STUB_NPX_FILE_1='$T/notjson.txt'; export STUB_NPX_FILE_1"
run_rea t2 step_rea_doctor || :
assert_eq 0 "$(find "$PRIV" -type f | grep -c '')" "tmp: a doctor with unparsable output leaves no file"
RS_PRE="TMPDIR='$PRIV'; export TMPDIR; STUB_NPX_FILE_1='$CO'; STUB_NPX_FILE_2='$GO'; export STUB_NPX_FILE_1 STUB_NPX_FILE_2"
run_rea t3 step_rea_doctor || :
assert_eq 0 "$(find "$PRIV" -type f | grep -c '')" "tmp: a passing doctor leaves no file"
RS_PRE="TMPDIR='$PRIV'; export TMPDIR; STUB_NPX_EXIT_2=3; export STUB_NPX_EXIT_2"
run_rea t4 step_rea_setup || :
assert_eq 0 "$(find "$PRIV" -type f | grep -c '')" "tmp: a setup that fails leaves no file"

# the stderr tail is cut at a line boundary: a secret name sliced by the 1000-byte cut must not leak its value
node -e 'process.stdout.write("first line\nANTHROPIC_API_KEY=sk-secret-123\n"+"y".repeat(983))' >"$T/err-cut.txt"
RS_PRE="STUB_NPX_EXIT_2=3; STUB_NPX_STDERR_2=\"\$(cat '$T/err-cut.txt')\"; export STUB_NPX_EXIT_2 STUB_NPX_STDERR_2"
run_rea c1 step_rea_setup || :
assert_match 'ERROR +\[rea-setup\] rea setup exited 3: ' "$(logtext c1)" "tail: the failure is reported"
assert_eq "" "$(grep -c 'sk-secret-123' "$T/c1.log" | sed 's/^0$//')" "tail: a secret value sliced by the cut does not reach the log"
assert_match 'yyyyyyyy' "$(logtext c1)" "tail: the end of stderr is kept"

# --- redaction: the corpus shared with the Pester suite, timings, the stderr tail fallback ---
rd_n=0
while IFS= read -r rd_line; do
  rd_n=$((rd_n + 1))
  rd_in=${rd_line%%"	"*}
  rd_want=${rd_line#*"	"}
  assert_eq "$rd_want" "$(redact "$rd_in")" "redact corpus line $rd_n: $rd_in"
done <"$FIX/redact-corpus.txt"
assert_eq 1 "$([ "$rd_n" -ge 39 ] && echo 1 || echo 0)" "redact corpus: at least 39 lines were read ($rd_n)"
# a 200000-character run must not take quadratic time
for rd_unit in KEY TOKEN_ http:// 'a=' '"a' 'a:'; do
  rd_big=$(node -e 'process.stdout.write(process.argv[1].repeat(Math.floor(200000/process.argv[1].length)))' -- "$rd_unit")
  rd_t0=$(date +%s)
  redact "$rd_big" >/dev/null
  rd_t1=$(date +%s)
  assert_eq 1 "$([ $((rd_t1 - rd_t0)) -lt 5 ] && echo 1 || echo 0)" "redact: 200000 characters of [$rd_unit] take under 5 s"
done
# invalid UTF-8 bytes must not stop the redaction (GNU sed's . stops at one in a UTF-8 locale): every sed in
# redact runs under LC_ALL=C
for rd_loc in C.UTF-8 en_US.UTF-8; do
  if ! locale -a 2>/dev/null | grep -qix "$rd_loc\|$(printf '%s' "$rd_loc" | sed 's/UTF-8/utf8/')"; then
    echo "skip: locale $rd_loc is not installed: invalid-byte redaction tests under it skipped"
    continue
  fi
  rd_bad1=$(printf 'Authorization: Bearer ab\377SECRETPART')
  rd_bad2=$(printf '{"token":"ab\377SECRETPART"}')
  rd_bad3=$(printf 'KEY=abc\377')
  rd_bad4=$(printf 'x-api-key: \377SECRETPART')
  rd_bad5=$(printf 'KEY = \377SECRETPART tail')
  rd_got=$( (
    LC_ALL=$rd_loc
    export LC_ALL
    redact "$rd_bad1"
  ))
  assert_eq "Authorization: <redacted>" "$rd_got" "redact [$rd_loc]: an invalid byte before the rest of a header"
  rd_got=$( (
    LC_ALL=$rd_loc
    export LC_ALL
    redact "$rd_bad2"
  ))
  assert_eq '{"token":"<redacted>"}' "$rd_got" "redact [$rd_loc]: an invalid byte in the middle of a JSON string"
  rd_got=$( (
    LC_ALL=$rd_loc
    export LC_ALL
    redact "$rd_bad3"
  ))
  assert_eq "KEY=<redacted>" "$rd_got" "redact [$rd_loc]: an invalid byte at the end"
  rd_got=$( (
    LC_ALL=$rd_loc
    export LC_ALL
    redact "$rd_bad4"
  ))
  assert_eq "x-api-key: <redacted>" "$rd_got" "redact [$rd_loc]: an invalid byte right after a colon"
  rd_got=$( (
    LC_ALL=$rd_loc
    export LC_ALL
    redact "$rd_bad5"
  ))
  assert_eq "KEY = <redacted> tail" "$rd_got" "redact [$rd_loc]: an invalid byte in a spaced-equals value"
  rd_got=$( (
    LC_ALL=$rd_loc
    export LC_ALL
    redact 'KEY=héllo wörld'
  ))
  assert_eq "KEY=<redacted> wörld" "$rd_got" "redact [$rd_loc]: valid multibyte input still redacts byte-wise"
done
rd_got=$( (
  LC_ALL=C
  export LC_ALL
  redact "$(printf 'Authorization: Bearer ab\377SECRETPART')"
))
assert_eq "Authorization: <redacted>" "$rd_got" "redact [C]: an invalid byte before the rest of a header"

# the tail trims like the PowerShell one: a trailing CR, trailing and leading whitespace
node -e 'process.stdout.write("z".repeat(5000)+"\n   ")' >"$T/tw1.txt"
node -e 'process.stdout.write("z".repeat(5000)+"\r")' >"$T/tw2.txt"
node -e 'process.stdout.write("z".repeat(5000)+"\n  tail words  ")' >"$T/tw3.txt"
printf '   hello   \r' >"$T/tw4.txt"
Z1000=$(node -e 'process.stdout.write("z".repeat(1000))')
for tw in 1 2 3 4; do
  RS_PRE="STUB_NPX_EXIT_2=3; STUB_NPX_STDERR_2=\"\$(cat '$T/tw$tw.txt')\"; export STUB_NPX_EXIT_2 STUB_NPX_STDERR_2"
  run_rea "tw$tw" step_rea_setup || :
done
assert_eq "...$Z1000" "$(sed -n 's/.*rea setup exited 3: //p' "$T/tw1.log" | head -n 1)" "tail: a long line then whitespace-only line gives the marked window"
assert_eq "...$Z1000" "$(sed -n 's/.*rea setup exited 3: //p' "$T/tw2.log" | head -n 1 | tr -d '\r')" "tail: a long line and a trailing CR gives the marked window"
assert_eq 0 "$(grep -c "$(printf '\r')" "$T/tw2.log" | sed 's/^[1-9].*/1/')" "tail: no CR survives in the tail"
assert_match 'rea setup exited 3: tail words$' "$(logtext tw3)" "tail: the line after the long one is trimmed at both ends"
assert_match 'rea setup exited 3: hello$' "$(logtext tw4)" "tail: a short stderr is trimmed at both ends and loses its CR"
# the tail fallback: no usable line boundary gives the last 1000 characters marked with ...
node -e 'process.stdout.write("z".repeat(5000))' >"$T/long1.txt"
RS_PRE="STUB_NPX_EXIT_2=3; STUB_NPX_STDERR_2=\"\$(cat '$T/long1.txt')\"; export STUB_NPX_EXIT_2 STUB_NPX_STDERR_2"
run_rea f1 step_rea_setup || :
assert_match 'ERROR +\[rea-setup\] rea setup exited 3: \.\.\.zzzzzzzz' "$(logtext f1)" "tail: a single long line gives ... and its last characters"
assert_eq 1003 "$(sed -n 's/.*rea setup exited 3: //p' "$T/f1.log" | head -n 1 | awk '{print length($0)}')" "tail: the fallback is 1000 characters plus the marker"
node -e 'process.stdout.write("z".repeat(5000)+"\nshort line")' >"$T/long2.txt"
RS_PRE="STUB_NPX_EXIT_2=3; STUB_NPX_STDERR_2=\"\$(cat '$T/long2.txt')\"; export STUB_NPX_EXIT_2 STUB_NPX_STDERR_2"
run_rea f2 step_rea_setup || :
assert_match 'rea setup exited 3: short line$' "$(logtext f2)" "tail: a long line then a short one gives the short one"
RS_PRE="STUB_NPX_EXIT_2=3; STUB_NPX_STDERR_2=''; export STUB_NPX_EXIT_2 STUB_NPX_STDERR_2"
run_rea f3 step_rea_setup || :
assert_match 'rea setup exited 3: $' "$(logtext f3)" "tail: empty stderr gives an empty tail"

# --dry-run and --check-upstream skip it
RS_PRE="OPT_DRY_RUN=1"
rc=0
run_rea d10 step_rea_doctor || rc=$?
assert_eq 0 "$rc" "doctor: --dry-run succeeds"
assert_eq "" "$(calls d10)" "doctor: --dry-run runs no npx"
assert_match 'skip \(--dry-run\)' "$(logtext d10)" "doctor: --dry-run is logged"
RS_PRE="OPT_CHECK_UPSTREAM=1"
rc=0
run_rea d11 step_rea_doctor || rc=$?
assert_eq 0 "$rc" "doctor: --check-upstream succeeds"
assert_eq "" "$(calls d11)" "doctor: --check-upstream runs no npx"
# the shared profile is refused here too
RS_PRE="CLAUDE_CONFIG_DIR_SELECTED='$HOME_DIR/.claude'"
rc=0
run_rea d12 step_rea_doctor || rc=$?
assert_eq 1 "$rc" "doctor: the shared profile directory is refused with 1"
assert_eq "" "$(calls d12)" "doctor: the shared profile directory runs no npx"
home_empty "doctor cases"

# --- secrets in rea's own output never reach the log unredacted ---
printf 'token=abcd ANTHROPIC_API_KEY=sk-secret-123\n' >"$T/secret.txt"
RS_PRE="STUB_NPX_FILE_1='$T/secret.txt'; export STUB_NPX_FILE_1"
run_rea d13 step_rea_doctor || :
assert_eq "" "$(grep -c 'sk-secret-123' "$T/d13.log" | sed 's/^0$//')" "doctor: a secret in rea's output is redacted in the log"

# --- the pin and the main order ---
assert_eq "rea-agents@latest" "$PIN_REA_SPEC" "pin: PIN_REA_SPEC"
assert_eq "step_ghidra tools_lock_release step_profile step_rea_setup step_rea_doctor write_env_files" "$(sed -n '/^main() {/,/^}/p' "$ROOT/setup.sh" | grep -E '^  (step_ghidra|tools_lock_release|step_profile|step_rea_setup|step_rea_doctor|write_env_files)( "[^"]*")?$' | sed 's/ "[^"]*"$//' | tr -d ' ' | tr '\n' ' ' | sed 's/ $//')" "main: rea-setup and rea-doctor run after profile, then the env file"
assert_eq "" "$(grep -n 'HOME/.claude.json' "$ROOT/setup.sh" | grep -v '^[0-9]*:#' | sed 's/^/found /')" "setup.sh never names \$HOME/.claude.json outside comments"

t_done
