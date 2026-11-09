#!/bin/sh
# Copyright (c) 2026 Costas Kirgoussios
#
# This software is licensed under the PolyForm Noncommercial License 1.0.0.
# You may obtain a copy of the License at:
# https://polyformproject.org/licenses/noncommercial/1.0.0/

# Tests for the setup.sh steps preflight and prereq. Prerequisites are stubs from tests/fixtures/bin,
# linked into a scratch directory whose name contains a space (so every path is also a quoting test);
# PATH is rebuilt for every case from that scratch directory plus links to the coreutils the steps need,
# so a tool that is installed on this machine can still be hidden.
# shellcheck source=/dev/null
. "$(dirname "$0")/lib.sh"
cd "$ROOT" || exit 1

FIX=$ROOT/tests/fixtures/bin
T="$ROOT/tests/.tmp/prereq work $$"
mkdir -p "$T" || exit 1
trap 'rm -rf "$T"; rmdir "$ROOT/tests/.tmp" 2>/dev/null' EXIT

# sys_tools: the coreutils the steps run; linked into every constructed PATH
SYS_TOOLS="awk basename cat chmod cp cut date df dirname env expr find grep head id kill ln ls mkdir mktemp mv od ps pwd rm sed sleep sort stat tail tee tr uname wc"

# mkpath NAME STUB...: builds $T/NAME with links to the system tools and to the named stubs (and, for the
# names curl, tar, unzip, bsdtar, the real ones when present); prints the directory
mkpath() {
  mp_dir=$T/$1
  shift
  mkdir -p "$mp_dir" || return 1
  for mp_t in $SYS_TOOLS; do
    mp_p=$(command -v "$mp_t" 2>/dev/null) || continue
    case "$mp_p" in
      /*) ln -sf "$mp_p" "$mp_dir/$mp_t" ;;
    esac
  done
  for mp_t in "$@"; do
    if [ -x "$FIX/$mp_t" ]; then
      ln -sf "$FIX/$mp_t" "$mp_dir/$mp_t"
    else
      mp_p=$(command -v "$mp_t" 2>/dev/null) || continue
      case "$mp_p" in
        /*) ln -sf "$mp_p" "$mp_dir/$mp_t" ;;
      esac
    fi
  done
  printf '%s\n' "$mp_dir"
}

# run_step LOGNAME PATHDIR STEP: runs the step in a subshell with PATH=PATHDIR; the log goes to
# $T/LOGNAME.log; prints nothing; returns the step's exit status
run_step() {
  rs_log=$T/$1.log
  : >"$rs_log"
  (
    PATH=$2
    LOG_FILE=$rs_log
    CONSOLE_LEVEL=ERROR
    "$3"
  ) >/dev/null 2>&1
}

logtext() {
  cat "$T/$1.log"
}

OPT_PROFILE=rea
OPT_TOOLS_DIR="$T/tools dir"
OPT_BIN_DIR="$T/bin dir"
OPT_DRY_RUN=0
OPT_CHECK_UPSTREAM=0
export OPT_PROFILE OPT_TOOLS_DIR OPT_BIN_DIR OPT_DRY_RUN OPT_CHECK_UPSTREAM
# step_prereq runs after step_preflight in main, which sets OS; the prereq cases set it by hand
OS=linux
ARCH=x64
export OS ARCH

# --- step_prereq: node ---
P=$(mkpath all node npx claude agy ps)
STUB_node_VERSION=v24.21.0
export STUB_node_VERSION
rc=0
run_step node-old "$P" step_prereq || rc=$?
assert_eq 4 "$rc" "node 24.21.0 is below the floor: exit 4"
assert_match 'install Node 24: fnm install 24 \(https://github.com/Schniz/fnm\) or https://nodejs.org' "$(logtext node-old)" "node hint in the log"
assert_match 'v24.21.0' "$(logtext node-old)" "the log names the version found"

STUB_node_VERSION=v24.22.2
rc=0
run_step node-ok "$P" step_prereq || rc=$?
assert_eq 0 "$rc" "node 24.22.2 passes"
assert_match 'prereq.* ok' "$(logtext node-ok)" "ok is logged"

STUB_node_VERSION=v22.23.3
rc=0
run_step node-22 "$P" step_prereq || rc=$?
assert_eq 4 "$rc" "node 22.23.3 is below the 22.x floor"
STUB_node_VERSION=v22.23.4
rc=0
run_step node-22ok "$P" step_prereq || rc=$?
assert_eq 0 "$rc" "node 22.23.4 passes"
STUB_node_VERSION=garbage
rc=0
run_step node-garbage "$P" step_prereq || rc=$?
assert_eq 4 "$rc" "an unparsable node version fails closed"
unset STUB_node_VERSION

STUB_node_EXIT=1
export STUB_node_EXIT
rc=0
run_step node-broken "$P" step_prereq || rc=$?
assert_eq 4 "$rc" "a node that exits non-zero fails closed"
unset STUB_node_EXIT

P=$(mkpath nonode npx claude agy ps)
rc=0
run_step node-missing "$P" step_prereq || rc=$?
assert_eq 4 "$rc" "missing node: exit 4"
assert_match 'fnm install 24' "$(logtext node-missing)" "missing node carries the fnm hint"

# --- step_prereq: the other tools ---
P=$(mkpath noagy node npx claude ps)
rc=0
run_step agy-missing "$P" step_prereq || rc=$?
assert_eq 4 "$rc" "missing agy: exit 4"
assert_match 'agy' "$(logtext agy-missing)" "the log names agy"

P=$(mkpath noclaude node npx agy ps)
rc=0
run_step claude-missing "$P" step_prereq || rc=$?
assert_eq 4 "$rc" "missing claude: exit 4"
assert_match 'claude' "$(logtext claude-missing)" "the log names claude"

P=$(mkpath nonpx node claude agy ps)
rc=0
run_step npx-missing "$P" step_prereq || rc=$?
assert_eq 4 "$rc" "missing npx: exit 4"
assert_match 'npx' "$(logtext npx-missing)" "the log names npx"

# --check-upstream skips claude, agy and wt
P=$(mkpath upstream node npx ps)
OPT_CHECK_UPSTREAM=1
rc=0
run_step upstream "$P" step_prereq || rc=$?
assert_eq 0 "$rc" "--check-upstream does not need claude or agy"
assert_match 'check-upstream' "$(logtext upstream)" "the skip is logged"
rc=0
P=$(mkpath upstream-nonode npx ps)
run_step upstream-nonode "$P" step_prereq || rc=$?
assert_eq 4 "$rc" "--check-upstream still needs node"
OPT_CHECK_UPSTREAM=0

# --- step_prereq: ps from procps (Linux only) ---
if [ "$(uname -s)" = Linux ]; then
  P=$(mkpath nops node npx claude agy)
  rm -f "$P/ps"
  rc=0
  run_step ps-missing "$P" step_prereq || rc=$?
  assert_eq 4 "$rc" "missing ps on Linux: exit 4"
  assert_match 'procps' "$(logtext ps-missing)" "the ps hint names procps"
fi

# Windows: a claude that does not resolve to a .exe (here the extensionless stub) is refused
OS=windows
rc=0
run_step claude-shim "$P" step_prereq || rc=$?
assert_eq 4 "$rc" "windows: claude without .exe is refused"
assert_match "agent-profile refuses npm .cmd shims; install Claude Code's native installer" "$(logtext claude-shim)" "the .cmd hint is logged"
OS=linux

# --- step_prereq: credential overrides warn by name, never by value ---
P=$(mkpath all2 node npx claude agy ps)
ANTHROPIC_API_KEY=sk-secret-value-123
CLAUDE_CODE_USE_BEDROCK=1
export ANTHROPIC_API_KEY CLAUDE_CODE_USE_BEDROCK
rc=0
run_step cred "$P" step_prereq || rc=$?
assert_eq 0 "$rc" "credential overrides are a warning, not a failure"
assert_match 'WARN.*ANTHROPIC_API_KEY' "$(logtext cred)" "the variable name is warned about"
assert_match 'CLAUDE_CODE_USE_BEDROCK' "$(logtext cred)" "the second name is warned about"
if grep -q 'sk-secret-value-123' "$T/cred.log"; then
  t_fail "the credential value reached the log"
else
  t_ok
fi
unset ANTHROPIC_API_KEY CLAUDE_CODE_USE_BEDROCK
rc=0
run_step cred-none "$P" step_prereq || rc=$?
assert_eq 0 "$rc" "no overrides: ok"
if grep -q 'WARN' "$T/cred-none.log"; then
  t_fail "a warning without any override variable set"
else
  t_ok
fi

# --- step_preflight ---
P=$(mkpath pf curl tar unzip)
rc=0
(
  UNAME_S=Linux
  UNAME_M=aarch64
  export UNAME_S UNAME_M
  PATH=$P
  LOG_FILE=$T/pf-arm.log
  CONSOLE_LEVEL=ERROR
  : >"$LOG_FILE"
  step_preflight
) >/dev/null 2>&1 || rc=$?
assert_eq 3 "$rc" "linux aarch64: exit 3"
assert_match 'unsupported platform: linux aarch64 \(no agent-profile, clavity-ls or Ghidra native build\)' "$(logtext pf-arm)" "platform hint"

OPT_PROFILE=doctor
rc=0
run_step pf-profile "$P" step_preflight || rc=$?
assert_eq 2 "$rc" "--profile doctor: exit 2"
assert_match 'invalid profile name: doctor' "$(logtext pf-profile)" "profile message"
OPT_PROFILE=rea

rc=0
run_step pf-ok "$P" step_preflight || rc=$?
assert_eq 0 "$rc" "preflight passes with curl, tar and unzip"
assert_match 'preflight.* ok' "$(logtext pf-ok)" "ok is logged"

# probe_vars LOGNAME PATHDIR: runs step_preflight in a subshell and prints what it set
probe_vars() {
  (
    PATH=$2
    LOG_FILE=$T/$1.log
    : >"$LOG_FILE"
    OS=""
    step_preflight >/dev/null 2>&1
    printf '%s|%s|%s|%s\n' "$TOOLS_DIR" "$BIN_DIR" "$ZIP_TOOL" "$(summary_get preflight)"
  )
}

CONSOLE_LEVEL=ERROR
export CONSOLE_LEVEL
assert_eq "$T/tools dir|$T/bin dir|unzip|ok" "$(probe_vars pf-vars "$P")" "TOOLS_DIR, BIN_DIR, ZIP_TOOL and the summary"

P2=$(mkpath pf-bsd curl tar)
printf '#!/bin/sh\nexit 0\n' >"$P2/bsdtar"
chmod 755 "$P2/bsdtar"
assert_match '\|bsdtar\|' "$(probe_vars pf-bsd "$P2")" "ZIP_TOOL is bsdtar without unzip"

P3=$(mkpath pf-jar curl tar)
assert_match '\|jar\|' "$(probe_vars pf-jar "$P3")" "ZIP_TOOL is jar when unzip and bsdtar are hidden"
assert_match 'jar' "$(logtext pf-jar)" "the jar fallback is logged"

# curl or tar missing: exit 4 with an install hint
P4=$(mkpath pf-nocurl tar unzip)
rc=0
run_step pf-nocurl "$P4" step_preflight || rc=$?
assert_eq 4 "$rc" "missing curl: exit 4"
assert_match 'curl' "$(logtext pf-nocurl)" "curl is named"
assert_match 'install' "$(logtext pf-nocurl)" "an install hint is given"
P5=$(mkpath pf-notar curl unzip)
rc=0
run_step pf-notar "$P5" step_preflight || rc=$?
assert_eq 4 "$rc" "missing tar: exit 4"
assert_match 'tar' "$(logtext pf-notar)" "tar is named"

# orphans in both directories are removed, except under --dry-run
mkdir -p "$T/tools dir" "$T/bin dir" || exit 1
mkdir "$T/tools dir/x.tmp.999999" "$T/bin dir/y.tmp.999999"
OPT_DRY_RUN=1
run_step pf-dry "$P" step_preflight || true
if [ -d "$T/tools dir/x.tmp.999999" ]; then t_ok; else t_fail "--dry-run removed an orphan"; fi
OPT_DRY_RUN=0
run_step pf-clean "$P" step_preflight || true
if [ ! -e "$T/tools dir/x.tmp.999999" ] && [ ! -e "$T/bin dir/y.tmp.999999" ]; then t_ok; else t_fail "orphans in both directories are removed"; fi

t_done
