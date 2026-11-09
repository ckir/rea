#!/bin/sh
# Copyright (c) 2026 Costas Kirgoussios
#
# This software is licensed under the PolyForm Noncommercial License 1.0.0.
# You may obtain a copy of the License at:
# https://polyformproject.org/licenses/noncommercial/1.0.0/

# Tests for the plan phase, the disclosures, the confirmation, the env file, the summary and the launch step of
# setup.sh. clavity-ls is the stub of tests/fixtures/bin (reached through a private directory that holds only a
# link to it), which records its arguments and environment in STUB_CL_LOG. Every directory has a space in its
# name and the ones the env file holds a quote as well.
# shellcheck source=/dev/null
. "$(dirname "$0")/lib.sh"
cd "$ROOT" || exit 1

T="$ROOT/tests/.tmp/launch work $$"
mkdir -p "$T" || exit 1
cleanup_all() {
  rm -rf "$T"
  rmdir "$ROOT/tests/.tmp" 2>/dev/null
}
trap cleanup_all EXIT
trap 'exit 1' INT TERM

unset GITHUB_TOKEN CLAUDE_CONFIG_DIR GHIDRA_INSTALL_DIR JAVA_HOME STUB_CL_EXIT STUB_CL_STDERR STUB_CL_LOG
FIX=$ROOT/tests/fixtures
LOG_FILE=$T/unit.log
CONSOLE_LEVEL=ERROR
OPT_DRY_RUN=0
OPT_CHECK_UPSTREAM=0
OPT_NO_LAUNCH=0
OPT_YES=0
OPT_PROFILE=rea
OPT_FOLDER="$T/my folder's here"
OPT_GHIDRA_DIR=""
OPT_JAVA_HOME=""
OS=linux
ARCH=x64
TOOLS_DIR="$T/tools dir"
BIN_DIR="$T/bin dir's"
GHIDRA_DIR_SELECTED="$T/ghidra dir's x"
JAVA_HOME_SELECTED="$T/jdk d'ir"
export LOG_FILE CONSOLE_LEVEL OPT_DRY_RUN OPT_CHECK_UPSTREAM OPT_NO_LAUNCH OPT_YES OPT_PROFILE OPT_FOLDER OPT_GHIDRA_DIR OPT_JAVA_HOME OS ARCH
mkdir -p "$TOOLS_DIR" "$BIN_DIR" || exit 1
STUBBIN="$T/stub bin"
mkdir -p "$STUBBIN" || exit 1
ln -s "$FIX/bin/clavity-ls" "$STUBBIN/clavity-ls"
REAL_PATH=$PATH

# setv NAME VALUE: assigns through eval, so a value set in a subshell and read outside it does not trip shellcheck
setv() {
  eval "$1=\$2"
}

# getv NAME: the value of NAME
getv() {
  eval "printf '%s\\n' \"\${$1:-}\""
}

# listing DIR: the entries of DIR, one per line (a glob, so odd names are safe)
listing() {
  for li_f in "$1"/* "$1"/.[!.]*; do
    [ -e "$li_f" ] || [ -L "$li_f" ] || continue
    echo "${li_f##*/}"
  done
}

# --- shell_quote and write_env_files ---
cat >"$T/source.sh" <<'SRC'
. "$1"
printf '%s\n%s\n%s\n%s\n' "$GHIDRA_INSTALL_DIR" "$JAVA_HOME" "${PATH%%:*}" "${PATH#*:}"
SRC
assert_eq "'plain'" "$(shell_quote plain)" "quote: plain text"
assert_eq "'a'\\''b'" "$(shell_quote "a'b")" "quote: an embedded quote is closed, escaped and reopened"
assert_eq "'a b \$x \`y\` \"z\"'" "$(shell_quote "a b \$x \`y\` \"z\"")" "quote: nothing else is special inside single quotes"

OPT_DRY_RUN=1
(write_env_files "$TOOLS_DIR")
assert_eq "" "$(listing "$TOOLS_DIR")" "env: a dry run writes nothing"
OPT_DRY_RUN=0

write_env_files "$TOOLS_DIR"
assert_file "$TOOLS_DIR/env.sh" "env: env.sh exists"
assert_eq "env.sh" "$(listing "$TOOLS_DIR")" "env: no temporary file is left"
assert_match '^-rw-r--r--' "$(ls -l "$TOOLS_DIR/env.sh")" "env: mode 0644"
for env_sh in dash sh bash; do
  command -v "$env_sh" >/dev/null 2>&1 || continue
  got=$(env -i PATH=/usr/bin:/bin "$env_sh" "$T/source.sh" "$TOOLS_DIR/env.sh")
  assert_eq "$GHIDRA_DIR_SELECTED
$JAVA_HOME_SELECTED
$BIN_DIR
/usr/bin:/bin" "$got" "env: sources under $env_sh and sets the three values exactly (spaces and quotes)"
done
assert_eq "" "$(grep -c 'TOKEN\|SECRET\|PASSWORD' "$TOOLS_DIR/env.sh" | grep -v '^0$')" "env: nothing secret in it"
GHIDRA_DIR_SELECTED="$T/other ghidra"
(
  umask 077
  write_env_files "$TOOLS_DIR"
)
assert_match "other ghidra" "$(cat "$TOOLS_DIR/env.sh")" "env: overwritten on the next run"
assert_match '^-rw-r--r--' "$(ls -l "$TOOLS_DIR/env.sh")" "env: mode 0644 under umask 077"
assert_eq "env.sh" "$(listing "$TOOLS_DIR")" "env: still no temporary file"
OPT_CHECK_UPSTREAM=1
rm -f "$TOOLS_DIR/env.sh"
write_env_files "$TOOLS_DIR"
assert_eq "" "$(listing "$TOOLS_DIR")" "env: --check-upstream writes nothing"
OPT_CHECK_UPSTREAM=0
GHIDRA_DIR_SELECTED="$T/ghidra dir's x"
(
  setv JAVA_HOME_SELECTED ""
  write_env_files "$TOOLS_DIR"
) >/dev/null 2>&1
assert_eq 1 "$?" "env: no selected JDK is a step failure"

# --- plan_needed_mb ---
setv PLAN_ghidra reuse
setv PLAN_jdk reuse
assert_eq 200 "$(plan_needed_mb)" "needed: nothing pending is 200"
setv PLAN_jdk install
assert_eq 800 "$(plan_needed_mb)" "needed: the JDK adds 600"
setv PLAN_ghidra install
setv PLAN_jdk reuse
assert_eq 1700 "$(plan_needed_mb)" "needed: Ghidra adds 1500"
setv PLAN_jdk install
assert_eq 2300 "$(plan_needed_mb)" "needed: both"
setv PLAN_ghidra skip
setv PLAN_jdk skip
assert_eq 200 "$(plan_needed_mb)" "needed: skip counts nothing"

# --- disclosures and the plan summary ---
PLAN_ghidra_bytes=569649598
PLAN_jdk_bytes=218103808
disc=$(print_disclosures)
assert_match 'Download: 751\.3 MB in total \(Ghidra 543\.3 MB, JDK 208\.0 MB\)' "$disc" "disclosures: the computed total"
assert_match "unpacked under $TOOLS_DIR" "$disc" "disclosures: where it goes"
assert_match 'clavity-ls start always runs agy with --dangerously-skip-permissions, and agy is not isolated by the profile \(it shares ~/\.gemini/antigravity-cli/\)' "$disc" "disclosures: agy"
assert_match -- '--install-hopper may ask for administrator rights and installs commercial demo software' "$disc" "disclosures: hopper"
assert_match 'npx -y rea-agents@latest downloads and runs the newest published npm package with your rights' "$disc" "disclosures: npx"
assert_eq 4 "$(printf '%s\n' "$disc" | grep -c '^  [1-4]\. ')" "disclosures: four numbered items"
PLAN_ghidra_bytes=0
PLAN_jdk_bytes=0
assert_match 'Download: nothing for Ghidra and the JDK' "$(print_disclosures)" "disclosures: nothing pending"

setv PLAN_tools_bin update
setv PLAN_tools_bin_text "clavity-ls 1.0.0 (update)"
setv PLAN_jdk install
setv PLAN_jdk_text "jdk-21.0.13+9 into $TOOLS_DIR"
PLAN_jdk_bytes=218103808
setv PLAN_ghidra reuse
setv PLAN_ghidra_text "$GHIDRA_DIR_SELECTED"
plan=$(plan_summary)
assert_eq 7 "$(printf '%s\n' "$plan" | grep -c '^  [a-z-]*: ')" "plan: one line per step (tools-bin jdk ghidra profile rea-setup rea-doctor launch)"
assert_match 'tools-bin: +would update clavity-ls' "$plan" "plan: tools-bin update"
assert_match 'jdk: +would install jdk-21\.0\.13\+9 into .* \(208\.0 MB\)' "$plan" "plan: jdk install with its size"
assert_match 'ghidra: +would reuse ' "$plan" "plan: ghidra reuse"
setv PLAN_ghidra skip
assert_match 'ghidra: +skip ' "$(plan_summary)" "plan: skip"
OPT_NO_LAUNCH=1
assert_match 'launch: +skip \(--no-launch\)' "$(plan_summary)" "plan: --no-launch is a skip"
OPT_NO_LAUNCH=0

# --- plan_confirm: the free-space check, the prompt, the refusal ---
setv PLAN_ghidra install
PLAN_ghidra_bytes=569649598
setv PLAN_jdk install
PLAN_jdk_bytes=218103808
rc=0
(
  eval 'confirm() { return 1; }'
  plan_confirm
) >"$T/decl.out" 2>"$T/decl.err" || rc=$?
assert_eq 0 "$rc" "declined: exit 0"
assert_eq "nothing changed" "$(cat "$T/decl.out")" "declined: stdout is exactly nothing changed"
assert_match 'Download: ' "$(cat "$T/decl.err")" "declined: the disclosures were shown first"
assert_match 'Plan:' "$(cat "$T/decl.err")" "declined: the plan was shown first"
rc=0
(
  eval 'confirm() { return 0; }'
  plan_confirm
) >"$T/acc.out" 2>"$T/acc.err" || rc=$?
assert_eq 0 "$rc" "accepted: exit 0"
assert_eq "" "$(cat "$T/acc.out")" "accepted: nothing on stdout (it is for the summary)"
rc=0
(plan_confirm) >"$T/nt.out" 2>"$T/nt.err" </dev/null || rc=$?
assert_eq 2 "$rc" "no terminal and no --yes: exit 2"
assert_eq "" "$(cat "$T/nt.out")" "no terminal and no --yes: no nothing-changed claim"
rc=0
(
  OPT_YES=1
  plan_confirm
) >"$T/yes.out" 2>"$T/yes.err" </dev/null || rc=$?
assert_eq 0 "$rc" "--yes: no question"
assert_match 'Download: ' "$(cat "$T/yes.err")" "--yes: the disclosures are still printed"
rc=0
(
  OPT_DRY_RUN=1
  plan_confirm
) >"$T/dry.out" 2>"$T/dry.err" </dev/null || rc=$?
assert_eq 0 "$rc" "dry run: no question, exit 0"
assert_match 'Plan:' "$(cat "$T/dry.err")" "dry run: the plan is printed"
rc=0
(
  OPT_CHECK_UPSTREAM=1
  plan_confirm
) >"$T/cu.out" 2>"$T/cu.err" </dev/null || rc=$?
assert_eq "0 " "$rc $(cat "$T/cu.err")" "--check-upstream: no prompt, no output"

# not enough space: one check for the sum, exit 1 with the shortfall, and nothing is shown before it
rc=0
(
  eval 'df() { printf "Filesystem 1048576-blocks Used Available Capacity Mounted\\nx 9999 1 1000 1%% /\\n"; }'
  eval 'confirm() { return 0; }'
  plan_confirm
) >"$T/low.out" 2>"$T/low.err" || rc=$?
assert_eq 1 "$rc" "low disk: exit 1"
assert_match 'need 2300 MB, have 1000 MB \(short by 1300 MB\)' "$(cat "$T/low.err")" "low disk: the sum of both installs and the shortfall"
assert_eq 0 "$(grep -c 'Download: ' "$T/low.err")" "low disk: no disclosures before the failure"
rc=0
(
  eval 'df() { printf "Filesystem 1048576-blocks Used Available Capacity Mounted\\nx 9999 1 1000 1%% /\\n"; }'
  setv PLAN_ghidra reuse
  setv PLAN_jdk reuse
  eval 'confirm() { return 0; }'
  plan_confirm
) >/dev/null 2>&1 || rc=$?
assert_eq 0 "$rc" "low disk: 1000 MB is enough when nothing is pending (needs 200)"

# --- jdk_plan and ghidra_plan: resolution and checks only ---
mkdir -p "$T/plan tools"
rc=0
(
  setv TOOLS_DIR "$T/plan tools"
  OPT_GHIDRA_DIR="$FIX/fake-ghidra"
  ghidra_plan
  printf '%s|%s|%s\n' "$(getv PLAN_ghidra)" "$PLAN_ghidra_bytes" "$GHIDRA_DIR_SELECTED" >"$T/gplan1"
  OPT_GHIDRA_DIR=""
  ghidra_plan
  printf '%s|%s\n' "$(getv PLAN_ghidra)" "$PLAN_ghidra_bytes" >"$T/gplan2"
) >/dev/null 2>&1 || rc=$?
assert_eq 0 "$rc" "ghidra_plan runs"
assert_eq "reuse|0|$FIX/fake-ghidra" "$(cat "$T/gplan1")" "ghidra_plan: a valid --ghidra-dir is reused"
assert_eq "install|$PIN_GHIDRA_ZIP_BYTES" "$(cat "$T/gplan2")" "ghidra_plan: nothing valid means install of the pinned size"
rc=0
(
  setv TOOLS_DIR "$T/plan tools"
  OPT_JAVA_HOME="$FIX/fake-jdk"
  jdk_plan
  printf '%s|%s|%s\n' "$(getv PLAN_jdk)" "$PLAN_jdk_bytes" "$(getv JAVA_HOME_SELECTED)" >"$T/jplan1"
  OPT_JAVA_HOME=""
  eval 'adoptium_resolve() {
    JDK_RELEASE=jdk-21.0.13+9
    JDK_URL=https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.13%2B9/x.tar.gz
    JDK_SHA256=0000000000000000000000000000000000000000000000000000000000000000
    JDK_SIDECAR_URL=""
    JDK_BYTES=12345678
    return 0
  }'
  jdk_plan
  printf '%s|%s|%s\n' "$(getv PLAN_jdk)" "$PLAN_jdk_bytes" "${JDK_PLANNED:-}" >"$T/jplan2"
) >/dev/null 2>&1 || rc=$?
assert_eq 0 "$rc" "jdk_plan runs"
assert_eq "reuse|0|$FIX/fake-jdk" "$(cat "$T/jplan1")" "jdk_plan: a valid --java-home is reused"
assert_eq "install|12345678|1" "$(cat "$T/jplan2")" "jdk_plan: install with the size of the listing, the resolution kept"
assert_eq "" "$(listing "$T/plan tools")" "the plan phase wrote nothing into the tools dir"
rc=0
(
  setv TOOLS_DIR "$T/plan tools"
  OPT_GHIDRA_DIR="$T/nothing here"
  ghidra_plan
) >/dev/null 2>&1 || rc=$?
assert_eq 1 "$rc" "ghidra_plan: an invalid --ghidra-dir fails before the prompt"

# --- print_summary ---
summary_set profile "created rea: /p/claude"
summary_set tools_bin "agent-profile 1.0.0: install${NL}clavity-ls 1.0.0: skip (already latest)"
summary_set jdk "jdk-21.0.13+9 installed: /j"
summary_set ghidra "12.1.4 installed: /g"
summary_set rea_setup "registered rea in /p/claude"
summary_set rea_doctor "ok: ghidra 12.1.4"
setv ENV_FILE "$TOOLS_DIR/env.sh"
LOG_FILE="/some/log file.log"
sum=$(print_summary)
LOG_FILE=$T/unit.log
assert_match 'profile: +created rea: /p/claude' "$sum" "summary: profile"
assert_match 'agent-profile 1\.0\.0: install' "$sum" "summary: agent-profile"
assert_match 'clavity-ls 1\.0\.0: skip' "$sum" "summary: clavity-ls"
assert_match 'jdk: +jdk-21\.0\.13\+9 installed: /j' "$sum" "summary: jdk"
assert_match 'ghidra: +12\.1\.4 installed: /g' "$sum" "summary: ghidra"
assert_match 'rea doctor: +ok: ghidra 12\.1\.4' "$sum" "summary: rea doctor"
assert_match 'log file: +/some/log file\.log' "$sum" "summary: the log path"
assert_match "env file: +$TOOLS_DIR/env\.sh" "$sum" "summary: the env file"
assert_match "clavity-ls start \"$OPT_FOLDER\" --profile rea" "$sum" "summary: the next command"
setv ENV_FILE ""
assert_match 'env file: +not written' "$(print_summary)" "summary: no env file"

# --- step_launch ---
# run_launch NAME DISPLAY WAYLAND OS EXIT STDERR: step_launch in a subshell with the stub first on PATH and the
# given environment (EXIT and STDERR are what the stub does; empty for its defaults); stdout goes to
# $T/NAME.out, stderr to $T/NAME.err, the stub's record to $T/NAME.rec and the log to $T/NAME.log; prints the
# exit code
run_launch() {
  rl_rc=0
  mkdir -p "$T/launch tmp"
  (
    PATH="$STUBBIN:$REAL_PATH"
    export PATH
    setv TMPDIR "$T/launch tmp"
    export TMPDIR
    setv DISPLAY "$2"
    setv WAYLAND_DISPLAY "$3"
    setv OS "$4"
    setv STUB_CL_EXIT "$5"
    setv STUB_CL_STDERR "$6"
    setv STUB_CL_LOG "$T/$1.rec"
    setv LOG_FILE "$T/$1.log"
    export DISPLAY WAYLAND_DISPLAY STUB_CL_EXIT STUB_CL_STDERR STUB_CL_LOG LOG_FILE
    install_traps
    step_launch
    echo "returned" >"$T/$1.returned"
  ) >"$T/$1.out" 2>"$T/$1.err" </dev/null || rl_rc=$?
  echo "$rl_rc"
}

OPT_NO_LAUNCH=1
assert_eq 0 "$(run_launch nl :0 "" linux "" "")" "launch: --no-launch exits 0"
assert_eq "launch skipped (--no-launch); run: clavity-ls start \"$OPT_FOLDER\" --profile rea" "$(cat "$T/nl.out")" "launch: --no-launch prints the command"
assert_eq "" "$(ls "$T/nl.rec" 2>/dev/null)" "launch: --no-launch does not call clavity-ls"
OPT_NO_LAUNCH=0

for ll_case in headless mac; do
  if [ "$ll_case" = mac ]; then
    ll_os=mac
    ll_disp=":0"
  else
    ll_os=linux
    ll_disp=""
  fi
  assert_eq 0 "$(run_launch "two-$ll_case" "$ll_disp" "" "$ll_os" "" "")" "launch: $ll_case prints the two-terminal flow and exits 0"
  out=$(cat "$T/two-$ll_case.out")
  assert_eq 2 "$(printf '%s\n' "$out" | grep -cF ". \"$TOOLS_DIR/env.sh\"")" "launch: $ll_case sources env.sh in both terminals"
  assert_match "clavity-ls agy \"$OPT_FOLDER\"" "$out" "launch: $ll_case terminal 1"
  assert_match "clavity-ls start \"$OPT_FOLDER\" --attach --profile rea" "$out" "launch: $ll_case terminal 2"
  assert_match 'hint that clavity-ls agy prints omits --profile' "$out" "launch: $ll_case warns about the agy hint"
  assert_eq "" "$(ls "$T/two-$ll_case.rec" 2>/dev/null)" "launch: $ll_case does not call clavity-ls"
done
assert_eq 0 "$(run_launch wl "" wayland-0 linux "" "")" "launch: Wayland alone counts as a display"
assert_match 'arg: start' "$(cat "$T/wl.rec")" "launch: Wayland calls start"

assert_eq 0 "$(run_launch ok :0 "" linux "" "")" "launch: with a display, exit 0"
assert_eq "arg: start
arg: $OPT_FOLDER
arg: --profile
arg: rea" "$(grep '^arg: ' "$T/ok.rec")" "launch: start <folder> --profile rea, one argument each"
assert_match "env GHIDRA_INSTALL_DIR=$GHIDRA_DIR_SELECTED\$" "$(cat "$T/ok.rec")" "launch: the child has GHIDRA_INSTALL_DIR"
assert_match "env JAVA_HOME=$JAVA_HOME_SELECTED\$" "$(cat "$T/ok.rec")" "launch: the child has JAVA_HOME"
assert_match "path-head: $BIN_DIR\$" "$(cat "$T/ok.rec")" "launch: the bin dir heads the child's PATH"
assert_eq "" "$(grep -c CLAUDE_CONFIG_DIR "$T/ok.rec" | grep -v '^0$')" "launch: no CLAUDE_CONFIG_DIR is passed"
assert_match 'launch exited 0' "$(cat "$T/ok.log")" "launch: exit 0 is logged"
assert_eq "" "$(ls "$T/ok.returned" 2>/dev/null)" "launch: step_launch never returns"
assert_eq "" "$(cat "$T/ok.out")" "launch: nothing is added to stdout"

assert_eq 7 "$(run_launch e7 :0 "" linux 7 "")" "launch: the script exits with clavity-ls's code"
assert_match 'launch exited 7' "$(cat "$T/e7.log")" "launch: exit 7 is logged"
assert_eq 0 "$(grep -c 'Terminal 1' "$T/e7.out")" "launch: exit 7 prints no instructions"

assert_eq 1 "$(run_launch t1 :0 "" linux 1 "no terminal could be opened")" "launch: exit 1 with terminal on stderr keeps the code 1"
assert_match "clavity-ls start \"$OPT_FOLDER\" --attach --profile rea" "$(cat "$T/t1.out")" "launch: the fallback instructions are printed"
assert_match 'no terminal could be opened' "$(cat "$T/t1.err")" "launch: the child's stderr reaches the console"
assert_match 'launch exited 1' "$(cat "$T/t1.log")" "launch: exit 1 is logged"
assert_eq 1 "$(run_launch t2 :0 "" linux 1 "something else failed")" "launch: exit 1 without terminal keeps the code 1"
assert_eq 0 "$(grep -c 'Terminal 1' "$T/t2.out")" "launch: exit 1 without terminal prints no instructions"
assert_eq 2 "$(run_launch t3 :0 "" linux 2 "terminal")" "launch: exit 2 keeps the code"
assert_eq 0 "$(grep -c 'Terminal 1' "$T/t3.out")" "launch: only exit 1 prints the instructions"

OPT_DRY_RUN=1
assert_eq 0 "$(run_launch dry :0 "" linux "" "")" "launch: a dry run exits 0"
assert_match 'would run: clavity-ls start' "$(cat "$T/dry.log")" "launch: a dry run logs would"
assert_eq "" "$(ls "$T/dry.rec" 2>/dev/null)" "launch: a dry run does not call clavity-ls"
OPT_DRY_RUN=0
OPT_CHECK_UPSTREAM=1
assert_eq "returned" "$(
  step_launch
  echo returned
)" "launch: --check-upstream returns without launching"
OPT_CHECK_UPSTREAM=0
assert_eq "" "$(listing "$T/launch tmp")" "launch: no temporary file is left behind (private TMPDIR)"

# --- main: the order of the steps ---
main_order=$(sed -n '/^main() {/,/^}/p' "$ROOT/setup.sh" | sed -n 's/^  \([a-z_]*\)\( "[^"]*"\)\{0,1\}$/\1/p' | grep -E '^(step_|tools_|jdk_plan|ghidra_plan|plan_confirm|write_env_files|print_summary)' | tr '\n' ' ' | sed 's/ $//')
assert_eq "step_preflight step_prereq tools_bin_plan jdk_plan ghidra_plan plan_confirm step_tools_bin step_jdk step_ghidra tools_lock_release step_profile step_rea_setup step_rea_doctor write_env_files print_summary step_launch" "$main_order" "main: the full order"

t_done
