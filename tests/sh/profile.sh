#!/bin/sh
# Copyright (c) 2026 Costas Kirgoussios
#
# This software is licensed under the PolyForm Noncommercial License 1.0.0.
# You may obtain a copy of the License at:
# https://polyformproject.org/licenses/noncommercial/1.0.0/

# Tests for the setup.sh step profile. The agent-profile stub of tests/fixtures/bin (a private directory that holds
# only a link to it, so the real node stays on PATH) answers doctor with a fixture and create with a directory
# under AGENT_PROFILE_HOME. The step must never write in $HOME/.claude or $HOME/.claude.json: every test runs
# with a scratch HOME and ends by listing it. The last tests run the REAL agent-profile, when there is one.
# Every directory has a space in its name.
# shellcheck source=/dev/null
. "$(dirname "$0")/lib.sh"
cd "$ROOT" || exit 1

T="$ROOT/tests/.tmp/profile work $$"
mkdir -p "$T" || exit 1
cleanup_all() {
  rm -rf "$T"
  rmdir "$ROOT/tests/.tmp" 2>/dev/null
}
trap cleanup_all EXIT
trap 'exit 1' INT TERM

unset GITHUB_TOKEN AGENT_PROFILE_HOME CLAUDE_CONFIG_DIR_SELECTED
OS=linux
OPT_DRY_RUN=0
OPT_CHECK_UPSTREAM=0
OPT_PROFILE=t1
LOG_FILE=$T/unit.log
CONSOLE_LEVEL=ERROR
export OS OPT_DRY_RUN OPT_CHECK_UPSTREAM OPT_PROFILE LOG_FILE CONSOLE_LEVEL
FIX=$ROOT/tests/fixtures
HOME_DIR="$T/home dir"
APH="$T/aph dir"
STUBBIN="$T/stub bin"
REAL_PATH=$PATH
REAL_AP=$(command -v agent-profile 2>/dev/null || true)
mkdir -p "$HOME_DIR" "$STUBBIN" || exit 1
ln -s "$FIX/bin/agent-profile" "$STUBBIN/agent-profile"
# NOAP: a PATH with the tools the step needs and no agent-profile, whatever the machine has
NOAP="$T/no ap bin"
mkdir -p "$NOAP" || exit 1
for na_c in node date sed rm cat mkdir tr head tail mktemp dirname basename uname awk grep sh; do
  na_p=$(command -v "$na_c" 2>/dev/null) || continue
  case "$na_p" in
    /*) ln -s "$na_p" "$NOAP/$na_c" ;;
  esac
done
WANT_DIR=/home/u/.local/share/agent-profile/profiles/t1/claude

# mk_doctor FILE VALUE: a doctor answer whose launch_environment check holds VALUE
mk_doctor() {
  printf '{"checks":[{"id":"launch_environment","data":{"value":"%s"}}]}\n' "$2" >"$1"
}

# run_prof NAME: step_profile in a subshell with the scratch HOME, the stub first on PATH and the traps; the log
# goes to $T/NAME.log, what the step set to $T/NAME.state and its console output to $T/NAME.out. RS_PRE, a shell
# command, runs first. Returns the exit code of the subshell.
run_prof() {
  rp_rc=0
  (
    LOG_FILE=$T/$1.log
    : >"$LOG_FILE"
    HOME=$HOME_DIR
    PATH="$STUBBIN:$REAL_PATH"
    AGENT_PROFILE_HOME=$APH
    export LOG_FILE HOME PATH AGENT_PROFILE_HOME
    install_traps
    eval "${RS_PRE:-:}"
    step_profile
    printf 'dir=%s\nsummary=%s\nexported=%s\n' "${CLAUDE_CONFIG_DIR_SELECTED:-}" "$(summary_get profile)" "$(sh -c 'printf %s "$CLAUDE_CONFIG_DIR_SELECTED"')" >"$T/$1.state"
  ) >"$T/$1.out" 2>&1 || rp_rc=$?
  return "$rp_rc"
}

logtext() {
  cat "$T/$1.log"
}

state() {
  sed -n "s/^$2=//p" "$T/$1.state"
}

# home_empty LABEL: nothing was created under the scratch HOME (no .claude, no .claude.json, nothing at all)
home_empty() {
  he_n=0
  for he_f in "$HOME_DIR"/* "$HOME_DIR"/.[!.]*; do
    if [ -e "$he_f" ] || [ -L "$he_f" ]; then
      he_n=$((he_n + 1))
    fi
  done
  assert_eq 0 "$he_n" "$1: nothing was created under HOME"
}

# --- profile_config_dir: the doctor answer ---
cfg() {
  (
    HOME=$HOME_DIR
    PATH="$STUBBIN:$REAL_PATH"
    LOG_FILE=$T/cfg.log
    export HOME PATH LOG_FILE
    eval "${RS_PRE:-:}"
    profile_config_dir t1
  ) 2>"$T/cfg.err"
}

RS_PRE="STUB_AP_DOCTOR_FILE=$FIX/sample-doctor-agent-profile.json; export STUB_AP_DOCTOR_FILE"
assert_eq "$WANT_DIR" "$(cfg)" "config_dir: the 'after create' fixture gives the launch_environment value"

RS_PRE="STUB_AP_DOCTOR_FILE=$FIX/sample-doctor-agent-profile-fail.json; STUB_AP_DOCTOR_EXIT=5; export STUB_AP_DOCTOR_FILE STUB_AP_DOCTOR_EXIT"
rc=0
out=$(cfg) || rc=$?
assert_eq 0 "$rc" "config_dir: exit 5 is accepted"
assert_eq "$WANT_DIR" "$out" "config_dir: exit 5 still gives the directory"
assert_match 'WARN +\[profile\] .*failing checks \(profile_path\).*create decides' "$(cat "$T/cfg.log")" "config_dir: exit 5 is a WARN naming the failing check"

RS_PRE="STUB_AP_DOCTOR_FILE=$FIX/sample-doctor-agent-profile.json; STUB_AP_DOCTOR_EXIT=4; export STUB_AP_DOCTOR_FILE STUB_AP_DOCTOR_EXIT"
rc=0
cfg >/dev/null || rc=$?
assert_eq 1 "$rc" "config_dir: doctor exit 4 dies with 1"
assert_match 'ERROR +\[profile\] agent-profile claude doctor exited 4' "$(cat "$T/cfg.log")" "config_dir: the exit code is logged"

mk_doctor "$T/home-claude.json" "$HOME_DIR/.claude"
mk_doctor "$T/home-claude-slash.json" "$HOME_DIR/.claude/"
mk_doctor "$T/home-claude-sub.json" "$HOME_DIR/.claude/profiles/rea"
mk_doctor "$T/home-claude-dots.json" "$HOME_DIR/.claude/../.claude/x"
mk_doctor "$T/empty.json" ""
printf '{"checks":[]}\n' >"$T/nocheck.json"
printf '{}\n' >"$T/nochecks.json"
printf '{"checks":[{"id":"launch_environment","data":null}]}\n' >"$T/nulldata.json"
printf '{"checks":[{"id":"launch_environment"}]}\n' >"$T/nodata.json"
printf 'this is not json\n' >"$T/notjson.json"
BAD_MSG='agent-profile did not report a profile-specific CLAUDE_CONFIG_DIR'
for bad in home-claude home-claude-slash home-claude-sub empty nocheck nochecks nulldata nodata; do
  RS_PRE="STUB_AP_DOCTOR_FILE='$T/$bad.json'; export STUB_AP_DOCTOR_FILE"
  rc=0
  cfg >/dev/null || rc=$?
  assert_eq 1 "$rc" "config_dir: $bad dies with 1"
  assert_match "ERROR +\\[profile\\] $BAD_MSG\$" "$(cat "$T/cfg.log")" "config_dir: $bad gives the exact message"
  assert_eq "" "$(grep -c 'TypeError' "$T/cfg.err" | sed 's/^0$//')" "config_dir: $bad raises no Node TypeError"
done
# ../ out of ~/.claude is still ~/.claude by prefix after resolution of the existing part
mkdir -p "$HOME_DIR/.claude"
RS_PRE="STUB_AP_DOCTOR_FILE='$T/home-claude-dots.json'; export STUB_AP_DOCTOR_FILE"
rc=0
cfg >/dev/null || rc=$?
assert_eq 1 "$rc" "config_dir: a path through .claude/.. is refused"
# a symlink into ~/.claude
ln -s "$HOME_DIR/.claude" "$T/link to claude"
mk_doctor "$T/via-link.json" "$T/link to claude/p1/claude"
RS_PRE="STUB_AP_DOCTOR_FILE='$T/via-link.json'; export STUB_AP_DOCTOR_FILE"
rc=0
cfg >/dev/null || rc=$?
assert_eq 1 "$rc" "config_dir: a path through a symlink into ~/.claude is refused"
# a ~/.claude that is itself a symlink elsewhere: the real target is refused too
mkdir -p "$T/elsewhere"
rm -rf "$HOME_DIR/.claude"
ln -s "$T/elsewhere" "$HOME_DIR/.claude"
mk_doctor "$T/via-target.json" "$T/elsewhere/p1"
RS_PRE="STUB_AP_DOCTOR_FILE='$T/via-target.json'; export STUB_AP_DOCTOR_FILE"
rc=0
cfg >/dev/null || rc=$?
assert_eq 1 "$rc" "config_dir: the real target of a ~/.claude symlink is refused"
rm -f "$HOME_DIR/.claude"
# a sibling that merely starts with the same letters is fine
mk_doctor "$T/sibling.json" "$HOME_DIR/.claude-other/p1/claude"
RS_PRE="STUB_AP_DOCTOR_FILE='$T/sibling.json'; export STUB_AP_DOCTOR_FILE"
assert_eq "$HOME_DIR/.claude-other/p1/claude" "$(cfg)" "config_dir: .claude-other is not inside .claude"

RS_PRE="STUB_AP_DOCTOR_FILE='$T/notjson.json'; export STUB_AP_DOCTOR_FILE"
rc=0
cfg >/dev/null || rc=$?
assert_eq 1 "$rc" "config_dir: output that is not JSON dies with 1"
assert_match 'ERROR +\[profile\] .*not JSON' "$(cat "$T/cfg.log")" "config_dir: the non-JSON answer is named"
assert_eq "" "$(grep -c 'at Function\|SyntaxError' "$T/cfg.err" | sed 's/^0$//')" "config_dir: no Node stack on the console"
# the capital-case Windows rule
assert_status 0 "within: Windows compares without case" sh -c ". ./setup.sh; OS=windows; profile_within 'C:/Users/X/.CLAUDE/p' 'c:/users/x/.claude'"
assert_status 1 "within: Linux compares with case" sh -c ". ./setup.sh; OS=linux; profile_within '/h/.CLAUDE/p' '/h/.claude'"
rm -f "$T"/*.json.tmp
home_empty "config_dir"

# --- step_profile ---
rm -rf "$APH"
mk_doctor "$T/doc-ok.json" "$APH/profiles/t1/claude"
RS_PRE="STUB_AP_DOCTOR_FILE='$T/doc-ok.json'; export STUB_AP_DOCTOR_FILE"
rc=0
run_prof s1 || rc=$?
assert_eq 0 "$rc" "step: create succeeds"
assert_eq "$APH/profiles/t1/claude" "$(state s1 dir)" "step: CLAUDE_CONFIG_DIR_SELECTED is the doctor directory"
assert_eq "$APH/profiles/t1/claude" "$(state s1 exported)" "step: CLAUDE_CONFIG_DIR_SELECTED is exported"
assert_eq "created t1: $APH/profiles/t1/claude" "$(state s1 summary)" "step: the summary says created"
assert_eq yes "$([ -d "$APH/profiles/t1/claude" ] && echo yes || echo no)" "step: the profile directory exists"
assert_match 'INFO +\[profile\] created t1' "$(logtext s1)" "step: created is logged"
assert_match 'INFO +\[profile\] ok$' "$(logtext s1)" "step: ok is logged"
home_empty "step"

rc=0
run_prof s2 || rc=$?
assert_eq 0 "$rc" "step: a second run succeeds"
assert_eq "reused t1: $APH/profiles/t1/claude" "$(state s2 summary)" "step: already exists gives a reused summary"
assert_match 'INFO +\[profile\] skip \(already exists\)' "$(logtext s2)" "step: already exists is a skip"

# doctor exit 5 (variant B shape) still attempts create
rm -rf "$APH"
mk_doctor "$T/doc-5.json" "$APH/profiles/t1/claude"
RS_PRE="STUB_AP_DOCTOR_FILE='$T/doc-5.json'; STUB_AP_DOCTOR_EXIT=5; export STUB_AP_DOCTOR_FILE STUB_AP_DOCTOR_EXIT"
rc=0
run_prof s3 || rc=$?
assert_eq 0 "$rc" "step: doctor exit 5 does not stop the step"
assert_match 'WARN +\[profile\] .*create decides' "$(logtext s3)" "step: the exit 5 WARN is logged"
assert_eq yes "$([ -d "$APH/profiles/t1/claude" ] && echo yes || echo no)" "step: create was still attempted after exit 5"

# doctor exit 4 stops before create
rm -rf "$APH"
RS_PRE="STUB_AP_DOCTOR_FILE='$T/doc-ok.json'; STUB_AP_DOCTOR_EXIT=4; export STUB_AP_DOCTOR_FILE STUB_AP_DOCTOR_EXIT"
rc=0
run_prof s4 || rc=$?
assert_eq 1 "$rc" "step: doctor exit 4 dies with 1"
assert_eq no "$([ -e "$APH" ] && echo yes || echo no)" "step: create was not attempted after doctor exit 4"

# a doctor directory in ~/.claude: refused, nothing created, exit 1
RS_PRE="STUB_AP_DOCTOR_FILE='$T/home-claude-sub.json'; export STUB_AP_DOCTOR_FILE"
rc=0
run_prof s5 || rc=$?
assert_eq 1 "$rc" "step: a doctor directory inside ~/.claude dies with 1"
assert_eq no "$([ -e "$APH" ] && echo yes || echo no)" "step: nothing is created for it"
home_empty "step refused"

# create fails: exit 1, the stderr tail bounded to 4000 characters and secrets redacted
rm -rf "$APH"
big=$(awk 'BEGIN { s = "HEADMARK"; for (i = 0; i < 700; i++) s = s "0123456789"; print s " ANTHROPIC_API_KEY=sk-secret-123 TAILMARK" }')
RS_PRE="STUB_AP_DOCTOR_FILE='$T/doc-ok.json'; STUB_AP_CREATE_EXIT=4; STUB_AP_CREATE_ERR='$big'; export STUB_AP_DOCTOR_FILE STUB_AP_CREATE_EXIT STUB_AP_CREATE_ERR"
rc=0
run_prof s6 || rc=$?
assert_eq 1 "$rc" "step: create exit 4 dies with 1"
assert_match 'ERROR +\[profile\] agent-profile claude create exited 4: ' "$(logtext s6)" "step: the create exit code is in the error"
assert_match 'TAILMARK' "$(logtext s6)" "step: the end of the stderr is kept"
assert_eq 0 "$(logtext s6 | grep -c 'HEADMARK')" "step: the start of an oversize stderr is cut"
assert_eq 0 "$(logtext s6 | grep -c 'sk-secret-123')" "step: the secret is redacted"
assert_eq 0 "$(grep -c 'sk-secret-123' "$T/s6.out")" "step: the secret is not on the console either"

# create succeeds but the directory the doctor named is not there
rm -rf "$APH"
mk_doctor "$T/doc-missing.json" "$T/never created/claude"
RS_PRE="STUB_AP_DOCTOR_FILE='$T/doc-missing.json'; export STUB_AP_DOCTOR_FILE"
rc=0
run_prof s7 || rc=$?
assert_eq 1 "$rc" "step: a missing directory after create dies with 1"
assert_match 'ERROR +\[profile\] the profile directory does not exist after create' "$(logtext s7)" "step: the missing directory is named"

# dry run: doctor only
rm -rf "$APH"
RS_PRE="OPT_DRY_RUN=1; STUB_AP_DOCTOR_FILE='$T/doc-ok.json'; export OPT_DRY_RUN STUB_AP_DOCTOR_FILE"
rc=0
run_prof s8 || rc=$?
assert_eq 0 "$rc" "dry run: succeeds"
assert_eq no "$([ -e "$APH" ] && echo yes || echo no)" "dry run: create was not run"
assert_match 'INFO +\[profile\] would use .*profiles/t1/claude' "$(logtext s8)" "dry run: the directory is logged"
assert_match 'not created: read-only run' "$(state s8 summary)" "dry run: the summary says so"
RS_PRE="OPT_DRY_RUN=1; STUB_AP_DOCTOR_FILE='$T/home-claude.json'; export OPT_DRY_RUN STUB_AP_DOCTOR_FILE"
rc=0
run_prof s8b || rc=$?
assert_eq 1 "$rc" "dry run: a ~/.claude directory is refused too"
RS_PRE="OPT_DRY_RUN=1; PATH='$NOAP'; export OPT_DRY_RUN PATH"
rc=0
run_prof s8c || rc=$?
assert_eq 0 "$rc" "dry run: without agent-profile it is a note, not a failure"
assert_match 'agent-profile is not installed' "$(logtext s8c)" "dry run: the missing tool is logged"

# --check-upstream: the step is skipped without running anything
RS_PRE="OPT_CHECK_UPSTREAM=1; STUB_AP_DOCTOR_EXIT=9; STUB_AP_CREATE_EXIT=9; export OPT_CHECK_UPSTREAM STUB_AP_DOCTOR_EXIT STUB_AP_CREATE_EXIT"
rc=0
run_prof s9 || rc=$?
assert_eq 0 "$rc" "check-upstream: succeeds without running agent-profile"
assert_match 'INFO +\[profile\] skip \(--check-upstream\)' "$(logtext s9)" "check-upstream: the skip is logged"
assert_eq 0 "$(logtext s9 | grep -c 'run: ')" "check-upstream: no command was run"

# a missing agent-profile in a real run is a step failure
RS_PRE="PATH='$NOAP'; export PATH"
rc=0
run_prof s10 || rc=$?
assert_eq 1 "$rc" "step: no agent-profile on PATH dies with 1"
assert_match 'ERROR +\[profile\] agent-profile not found on PATH' "$(logtext s10)" "step: the missing tool is named"
home_empty "stub tests"

# --- main: the profile step runs after the lock release ---
assert_eq "step_ghidra tools_lock_release step_profile" "$(sed -n '/^main() {/,/^}/p' "$ROOT/setup.sh" | grep -E '^  (step_ghidra|tools_lock_release|step_profile)$' | tr -d ' ' | tr '\n' ' ' | sed 's/ $//')" "main: step_profile runs last, after the tools lock is released"

# --- the REAL agent-profile (the O6 experiment as a test) ---
if [ -z "$REAL_AP" ]; then
  echo "skip: the real agent-profile is not on PATH"
else
  RAPH="$T/real aph"
  RHOME="$T/real home"
  mkdir -p "$RHOME"
  rc=0
  (
    HOME=$RHOME
    LOG_FILE=$T/real1.log
    AGENT_PROFILE_HOME=$RAPH
    export HOME LOG_FILE AGENT_PROFILE_HOME
    CONSOLE_LEVEL=ERROR
    OPT_DRY_RUN=1
    step_profile
    [ ! -e "$RAPH/profiles/t1" ]
  ) >"$T/real1.out" 2>&1 || rc=$?
  assert_eq 0 "$rc" "real agent-profile: a dry run succeeds and creates no profile"
  rc=0
  (
    HOME=$RHOME
    LOG_FILE=$T/real2.log
    AGENT_PROFILE_HOME=$RAPH
    export HOME LOG_FILE AGENT_PROFILE_HOME
    OPT_DRY_RUN=0
    step_profile
    printf '%s\n' "$CLAUDE_CONFIG_DIR_SELECTED" >"$T/real2.dir"
  ) >"$T/real2.out" 2>&1 || rc=$?
  assert_eq 0 "$rc" "real agent-profile: the step succeeds"
  assert_eq "$RAPH/profiles/t1/claude" "$(cat "$T/real2.dir" 2>/dev/null)" "real agent-profile: the directory is under AGENT_PROFILE_HOME"
  assert_eq yes "$([ -d "$RAPH/profiles/t1/claude" ] && echo yes || echo no)" "real agent-profile: the profile directory exists"
  rn=0
  for rf in "$RHOME"/* "$RHOME"/.[!.]*; do
    if [ -e "$rf" ] || [ -L "$rf" ]; then
      rn=$((rn + 1))
    fi
  done
  assert_eq 0 "$rn" "real agent-profile: nothing was created under the temp HOME (no .claude, no .agent-profile)"
  rc=0
  (
    HOME=$RHOME
    LOG_FILE=$T/real3.log
    AGENT_PROFILE_HOME=$RAPH
    export HOME LOG_FILE AGENT_PROFILE_HOME
    step_profile
  ) >"$T/real3.out" 2>&1 || rc=$?
  assert_eq 0 "$rc" "real agent-profile: a second run succeeds"
  assert_match 'skip \(already exists\)' "$(cat "$T/real3.log")" "real agent-profile: the second run is a skip"
fi

t_done
