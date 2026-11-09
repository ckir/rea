#!/bin/sh
# Copyright (c) 2026 Costas Kirgoussios
#
# This software is licensed under the PolyForm Noncommercial License 1.0.0.
# You may obtain a copy of the License at:
# https://polyformproject.org/licenses/noncommercial/1.0.0/

# Tests for the setup.sh step ghidra: ghidra_version and ghidra_valid on the fixtures
# (tests/fixtures/fake-ghidra, fake-ghidra-12.2.0), the precedence of ghidra_select and the whole install against
# the fake release server of tests/integration (python3, loopback only) with a real, small zip shaped like the
# Ghidra release. The test replaces the embedded digest and size with those of the small zip by assigning the
# shell variables after setup.sh is sourced; the product never reads them from the environment. Every directory
# has a space in its name.
# shellcheck source=/dev/null
. "$(dirname "$0")/lib.sh"
cd "$ROOT" || exit 1

if ! command -v python3 >/dev/null 2>&1; then
  echo "ghidra.sh: python3 is required" >&2
  exit 1
fi

T="$ROOT/tests/.tmp/ghidra work $$"
mkdir -p "$T" || exit 1
SRV_PIDS=""
cleanup_all() {
  for ca_p in $SRV_PIDS; do
    kill "$ca_p" 2>/dev/null
    wait "$ca_p" 2>/dev/null
  done
  rm -rf "$T"
  rmdir "$ROOT/tests/.tmp" 2>/dev/null
}
trap cleanup_all EXIT
trap 'exit 1' INT TERM

NO_PROXY=127.0.0.1
no_proxy=127.0.0.1
export NO_PROXY no_proxy
unset GITHUB_TOKEN JAVA_HOME GHIDRA_INSTALL_DIR

ALLOWED_SCHEMES="https http"
ALLOWED_HOSTS="github.com 127.0.0.1"
RETRY_WAITS="0 0"
SLEEP=true
OS=linux
ARCH=x64
OPT_DRY_RUN=0
OPT_CHECK_UPSTREAM=0
OPT_GHIDRA_DIR=""
TOOLS_DIR="$T/tools dir"
LOG_FILE=$T/unit.log
CONSOLE_LEVEL=ERROR
export ALLOWED_SCHEMES ALLOWED_HOSTS RETRY_WAITS SLEEP OS ARCH OPT_DRY_RUN OPT_CHECK_UPSTREAM OPT_GHIDRA_DIR TOOLS_DIR LOG_FILE CONSOLE_LEVEL
F412=$ROOT/tests/fixtures/fake-ghidra
F122=$ROOT/tests/fixtures/fake-ghidra-12.2.0
REL_PATH=/github.com/NationalSecurityAgency/ghidra/releases/download/Ghidra_12.1.4_build/ghidra_12.1.4_PUBLIC_20260921.zip
DL_PATH=/dl/ghidra.zip
WARN_MAC='the official 12.1.4 archive has no macOS native decompiler; rea doctor will report native_decompiler missing until it is built (rea docs/installation.md, "Missing macOS native decompiler" / "macOS arm64 native decompiler")'

# curl_local ARG...: curl with github.com URLs sent to the fake server (BASE) instead
curl_local() {
  cx_n=$#
  while [ "$cx_n" -gt 0 ]; do
    cx_a=$1
    shift
    case "$cx_a" in
      https://github.com/*) cx_a="$BASE/${cx_a#https://}" ;;
    esac
    set -- "$@" "$cx_a"
    cx_n=$((cx_n - 1))
  done
  curl "$@"
}

# set_pin NAME VALUE: assigns a pin variable of setup.sh (through eval, like summary_set, so the assignment is not
# flagged as unused)
set_pin() {
  eval "$1=\$2"
}

# mk_props DIR VERSION [EXTRA]: DIR/Ghidra/application.properties with that version
mk_props() {
  mkdir -p "$1/Ghidra"
  printf 'application.name=Ghidra\napplication.version=%s\n%s' "$2" "${3:-}" >"$1/Ghidra/application.properties"
}

# --- ghidra_version and ghidra_valid ---
assert_eq 12.1.4 "$(ghidra_version "$F412")" "version: fixture 12.1.4"
assert_eq 12.2.0 "$(ghidra_version "$F122")" "version: fixture 12.2.0"
assert_eq "" "$(ghidra_version "$T/nothing here")" "version: a missing directory is empty"
mkdir -p "$T/no props/Ghidra"
assert_eq "" "$(ghidra_version "$T/no props")" "version: a directory without application.properties is empty"
mk_props "$T/crlf" 12.1.9 'application.revision=3\r\n'
printf 'application.name=Ghidra\r\napplication.version=12.1.9\r\napplication.layout.version=2\r\n' >"$T/crlf/Ghidra/application.properties"
assert_eq 12.1.9 "$(ghidra_version "$T/crlf")" "version: CRLF and extra properties"
printf '  application.version = 12.1.5  \napplication.layout.version=2\n' >"$T/crlf/Ghidra/application.properties"
assert_eq 12.1.5 "$(ghidra_version "$T/crlf")" "version: blanks around the value"
printf 'application.layout.version=2\n' >"$T/crlf/Ghidra/application.properties"
assert_eq "" "$(ghidra_version "$T/crlf")" "version: only application.layout.version is not the version"

assert_status 0 "valid: 12.1.4" ghidra_valid "$F412"
mk_props "$T/v 12.1" 12.1
assert_status 0 "valid: 12.1" ghidra_valid "$T/v 12.1"
mk_props "$T/v 12.1.9" 12.1.9
assert_status 0 "valid: 12.1.9" ghidra_valid "$T/v 12.1.9"
assert_status 1 "valid: 12.2.0 is refused" ghidra_valid "$F122"
assert_match '12\.2\.0' "$(ghidra_valid "$F122")" "valid: the reason names the version"
mk_props "$T/v 11" 11.3.1
assert_status 1 "valid: 11.3.1 is refused" ghidra_valid "$T/v 11"
mk_props "$T/v 12.10" 12.10.0
assert_status 1 "valid: 12.10.0 is not the 12.1 line" ghidra_valid "$T/v 12.10"
mk_props "$T/v 12.1x" 12.1.x
assert_status 1 "valid: 12.1.x is refused" ghidra_valid "$T/v 12.1x"
mk_props "$T/v empty" ""
assert_status 1 "valid: an empty version is refused" ghidra_valid "$T/v empty"
assert_status 1 "valid: a directory without application.properties is refused" ghidra_valid "$T/no props"
assert_status 1 "valid: a missing directory is refused" ghidra_valid "$T/nothing here"

# --- fake release server ---
scn_start() {
  SCN=$1
  SCN_SEP=""
  printf '{' >"$SCN"
}

# scn_ent PATH SPEC: PATH answers SPEC to its first twelve requests
scn_ent() {
  se_list=""
  se_i=0
  while [ "$se_i" -lt 12 ]; do
    se_list="$se_list${se_list:+,}$2"
    se_i=$((se_i + 1))
  done
  printf '%s"%s": [%s]' "$SCN_SEP" "$1" "$se_list" >>"$SCN"
  SCN_SEP=,
}

scn_end() {
  printf '}\n' >>"$SCN"
}

cat >"$T/mkzip.py" <<'PYEOF'
import sys
import zipfile

# usage: mkzip.py OUT LAYOUT; LAYOUT is normal, badver (application.version 12.1.3), two (a second top
# directory) or badname (the top directory ghidra_12.1.9_PUBLIC)
out, layout = sys.argv[1], sys.argv[2]
top = "ghidra_12.1.9_PUBLIC" if layout == "badname" else "ghidra_12.1.4_PUBLIC"
version = "12.1.3" if layout == "badver" else "12.1.4"
files = [
    ("Ghidra/application.properties", "application.name=Ghidra\napplication.version=%s\n" % version, 0o644),
    ("ghidraRun", "#!/bin/sh\n", 0o755),
    ("support/analyzeHeadless", "#!/bin/sh\n", 0o755),
    ("support/launch.properties", "x=1\n", 0o644),
    ("Ghidra/Features/Decompiler/os/linux_x86_64/decompile", "ELF\n", 0o755),
]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for name, text, mode in files:
        info = zipfile.ZipInfo(top + "/" + name)
        info.external_attr = (0o100000 | mode) << 16
        z.writestr(info, text)
    if layout == "two":
        info = zipfile.ZipInfo("notes/readme")
        info.external_attr = (0o100000 | 0o644) << 16
        z.writestr(info, "x\n")
PYEOF

# mk_srv NAME LAYOUT: builds the zip of LAYOUT and the scenario of one fake server, starts it, sets BASE and
# ZIP_SHA/ZIP_SIZE, and points the embedded digest and size at the small zip
mk_srv() {
  ms_name=$1
  ms_dir="$T/srv $ms_name"
  mkdir -p "$ms_dir"
  python3 -I "$T/mkzip.py" "$ms_dir/ghidra.zip" "$2" || exit 1
  ZIP_SHA=$(sha256_file "$ms_dir/ghidra.zip")
  ZIP_SIZE=$(wc -c <"$ms_dir/ghidra.zip" | tr -d ' ')
  set_pin PIN_GHIDRA_SHA256 "$ZIP_SHA"
  set_pin PIN_GHIDRA_ZIP_BYTES "$ZIP_SIZE"
  scn_start "$ms_dir/scenario.json"
  scn_ent "$REL_PATH" '{"status":302,"location":"{base}/dl/ghidra.zip"}'
  scn_ent "$DL_PATH" '{"status":200,"body_file":"ghidra.zip"}'
  scn_end
  python3 -I "$ROOT/tests/integration/fake_release_server.py" 0 "$ms_dir/scenario.json" >"$ms_dir/server.out" 2>"$ms_dir/server.err" &
  ms_pid=$!
  SRV_PIDS="$SRV_PIDS $ms_pid"
  ms_port=""
  ms_tries=0
  while [ -z "$ms_port" ] && [ "$ms_tries" -lt 100 ]; do
    ms_port=$(sed -n 's/^PORT //p' "$ms_dir/server.out" 2>/dev/null)
    [ -n "$ms_port" ] || sleep 0.1
    ms_tries=$((ms_tries + 1))
  done
  if [ -z "$ms_port" ]; then
    echo "ghidra.sh: the fake server did not start" >&2
    cat "$ms_dir/server.err" >&2
    exit 1
  fi
  BASE=http://127.0.0.1:$ms_port
}

# count_of PATH: the GET requests the fake server has seen for PATH
count_of() {
  curl -sS "$BASE/__count$1"
}

fresh() {
  rm -rf "$TOOLS_DIR"
  mkdir -p "$TOOLS_DIR"
}

# listing DIR: the entries of DIR, one per line (a glob, so odd names are safe)
listing() {
  for li_f in "$1"/* "$1"/.[!.]*; do
    [ -e "$li_f" ] || [ -L "$li_f" ] || continue
    echo "${li_f##*/}"
  done
}

logtext() {
  cat "$T/$1.log"
}

# run_step NAME: step_ghidra under the tools lock, in a subshell with the curl wrapper and the traps; the log
# goes to $T/NAME.log and the result to $T/NAME.state. RS_PRE, a shell command, runs first. The lock is taken
# like step_tools_bin does and released at the end.
run_step() {
  rs_log=$T/$1.log
  : >"$rs_log"
  (
    LOG_FILE=$rs_log
    CURL=curl_local
    export LOG_FILE CURL
    install_traps
    if [ "${OPT_DRY_RUN:-0}" -ne 1 ]; then
      mkdir -p "$TOOLS_DIR"
      lock_acquire "$TOOLS_DIR"
    fi
    eval "${RS_PRE:-:}"
    step_ghidra
    printf 'dir=%s\nsummary=%s\n' "$GHIDRA_DIR_SELECTED" "$(summary_get ghidra)" >"$T/$1.state"
    if [ "${OPT_DRY_RUN:-0}" -ne 1 ]; then
      tools_lock_release
    fi
  ) >/dev/null 2>&1
}

# --- ghidra_select: precedence (no network: every case ends before an install) ---
fresh
rc=0
(
  OPT_GHIDRA_DIR="$F122"
  LOG_FILE=$T/sel1.log
  ghidra_select
) >/dev/null 2>&1 || rc=$?
assert_eq 1 "$rc" "select: --ghidra-dir at a 12.2 install dies with 1"
assert_match 'not a usable Ghidra: version 12\.2\.0' "$(cat "$T/sel1.log")" "select: the --ghidra-dir reason is logged"
assert_eq "" "$(listing "$TOOLS_DIR")" "select: a failed --ghidra-dir installs nothing"
rc=0
(
  OPT_GHIDRA_DIR="$T/nothing here"
  LOG_FILE=$T/sel1b.log
  ghidra_select
) >/dev/null 2>&1 || rc=$?
assert_eq 1 "$rc" "select: --ghidra-dir at a missing directory dies with 1"

# select_with FLAG ENV LOG: ghidra_select with the flag and the environment variable; prints the choice
select_with() {
  OPT_GHIDRA_DIR=$1
  set_pin GHIDRA_INSTALL_DIR "$2"
  LOG_FILE=$3
  export LOG_FILE
  ghidra_select
  echo "$GHIDRA_DIR_SELECTED"
}
assert_eq "$F412" "$(select_with "$F412" "$F122" "$T/sel2.log")" "select: a valid flag wins over the environment"
assert_eq "$F412" "$(select_with "" "$F412" "$T/sel3.log")" "select: a valid GHIDRA_INSTALL_DIR is used"
if grep -q WARN "$T/sel3.log"; then
  t_fail "select: a valid GHIDRA_INSTALL_DIR logs no WARN"
else
  t_ok
fi

# an invalid environment value with a valid, marked tools-dir install: WARN and the tools-dir one wins
mkdir -p "$TOOLS_DIR/ghidra_12.1.4_PUBLIC"
cp -R "$F412/Ghidra" "$TOOLS_DIR/ghidra_12.1.4_PUBLIC/Ghidra"
: >"$TOOLS_DIR/ghidra_12.1.4_PUBLIC/.install-complete"
out=$(select_with "" "$T/no props" "$T/sel4.log")
assert_eq "$TOOLS_DIR/ghidra_12.1.4_PUBLIC" "$out" "select: an invalid GHIDRA_INSTALL_DIR falls through to the tools dir"
assert_match 'WARN.*GHIDRA_INSTALL_DIR .*no props is not a usable Ghidra .*ignoring it' "$(cat "$T/sel4.log")" "select: the invalid environment value is a WARN with the reason"
assert_match 'reusing ghidra_12\.1\.4_PUBLIC' "$(cat "$T/sel4.log")" "select: the tools-dir reuse is logged"

# a 12.2 environment value: the verbatim WARN, then the tools dir
out=$(select_with "" "$F122" "$T/sel5.log")
assert_eq "$TOOLS_DIR/ghidra_12.1.4_PUBLIC" "$out" "select: a 12.2 GHIDRA_INSTALL_DIR falls through to the tools dir"
assert_match 'WARN +\[ghidra\] 12\.2 is not accepted by rea 6\.8\.0; installing 12\.1\.4 alongside$' "$(cat "$T/sel5.log")" "select: the 12.2 WARN is verbatim"

# a tools-dir install of another version and one without the mark are not reused (the install path is run
# against a dry run, which logs what it would fetch and writes nothing)
rm -f "$TOOLS_DIR/ghidra_12.1.4_PUBLIC/.install-complete"
out=$(
  OPT_DRY_RUN=1
  OPT_GHIDRA_DIR=""
  unset GHIDRA_INSTALL_DIR
  LOG_FILE=$T/sel6.log
  ghidra_select
  echo "$GHIDRA_DIR_SELECTED"
)
assert_eq "" "$out" "select: a tools-dir install without .install-complete is treated as absent"
assert_match 'will install Ghidra 12\.1\.4 from https://github\.com/NationalSecurityAgency/' "$(cat "$T/sel6.log")" "select: it goes to the install path"
assert_match 'DEBUG.*ignoring ghidra_12\.1\.4_PUBLIC: no \.install-complete' "$(cat "$T/sel6.log")" "select: the unmarked install is logged"
: >"$TOOLS_DIR/ghidra_12.1.4_PUBLIC/.install-complete"
mk_props "$TOOLS_DIR/ghidra_12.1.4_PUBLIC" 12.2.0
out=$(
  OPT_DRY_RUN=1
  OPT_GHIDRA_DIR=""
  unset GHIDRA_INSTALL_DIR
  LOG_FILE=$T/sel7.log
  ghidra_select
  echo "$GHIDRA_DIR_SELECTED"
)
assert_eq "" "$out" "select: a marked tools-dir install of 12.2 is not reused"
assert_match 'WARN.*ignoring the install ghidra_12\.1\.4_PUBLIC: version 12\.2\.0' "$(cat "$T/sel7.log")" "select: the wrong-version install is a WARN with the reason"

# --- install: success ---
mk_srv ok normal
fresh
rc=0
run_step i-ok || rc=$?
assert_eq 0 "$rc" "install: success"
assert_eq ghidra_12.1.4_PUBLIC "$(listing "$TOOLS_DIR")" "install: only ghidra_12.1.4_PUBLIC is left in the tools dir (no staging, zip or lock)"
assert_file "$TOOLS_DIR/ghidra_12.1.4_PUBLIC/.install-complete" "install: .install-complete exists"
assert_file "$TOOLS_DIR/ghidra_12.1.4_PUBLIC/Ghidra/application.properties" "install: application.properties is in place"
assert_status 0 "install: ghidraRun is executable" test -x "$TOOLS_DIR/ghidra_12.1.4_PUBLIC/ghidraRun"
assert_status 0 "install: analyzeHeadless is executable" test -x "$TOOLS_DIR/ghidra_12.1.4_PUBLIC/support/analyzeHeadless"
assert_status 0 "install: the linux decompiler is executable" test -x "$TOOLS_DIR/ghidra_12.1.4_PUBLIC/Ghidra/Features/Decompiler/os/linux_x86_64/decompile"
assert_status 1 "install: a properties file is not executable" test -x "$TOOLS_DIR/ghidra_12.1.4_PUBLIC/support/launch.properties"
assert_eq "dir=$TOOLS_DIR/ghidra_12.1.4_PUBLIC" "$(sed -n 1p "$T/i-ok.state")" "install: GHIDRA_DIR_SELECTED is the install"
assert_match '^summary=12\.1\.4 installed' "$(cat "$T/i-ok.state")" "install: SUMMARY_ghidra is set"
assert_match "will install Ghidra 12\\.1\\.4 from https://github\\.com/.*\\.zip \\($ZIP_SIZE bytes\\) into" "$(logtext i-ok)" "install: URL, size and target are logged"
assert_match 'installed Ghidra 12\.1\.4' "$(logtext i-ok)" "install: the install is logged"
if grep -q WARN "$T/i-ok.log"; then
  t_fail "install on Linux: no WARN"
else
  t_ok
fi
assert_eq 1 "$(count_of "$DL_PATH")" "install: the zip was fetched once"

# a second run reuses it without touching the network
rc=0
run_step i-again || rc=$?
assert_eq 0 "$rc" "reuse: second run succeeds"
assert_match 'reusing ghidra_12\.1\.4_PUBLIC' "$(logtext i-again)" "reuse: the install is reused"
assert_eq 1 "$(count_of "$DL_PATH")" "reuse: no second download"

# --- install over an aborted earlier install (Review Focus 4) ---
fresh
mkdir -p "$TOOLS_DIR/ghidra_12.1.4_PUBLIC/Ghidra"
cp "$F412/Ghidra/application.properties" "$TOOLS_DIR/ghidra_12.1.4_PUBLIC/Ghidra/"
printf 'half\n' >"$TOOLS_DIR/ghidra_12.1.4_PUBLIC/stale-file"
rc=0
run_step i-over || rc=$?
assert_eq 0 "$rc" "over an unmarked directory: success"
assert_file "$TOOLS_DIR/ghidra_12.1.4_PUBLIC/.install-complete" "over an unmarked directory: the new install is marked"
assert_file "$TOOLS_DIR/ghidra_12.1.4_PUBLIC/ghidraRun" "over an unmarked directory: the new content is in place"
assert_eq 0 "$(
  [ -e "$TOOLS_DIR/ghidra_12.1.4_PUBLIC/stale-file" ] && echo 1 || echo 0
)" "over an unmarked directory: the old content is gone"
assert_eq ghidra_12.1.4_PUBLIC "$(listing "$TOOLS_DIR")" "over an unmarked directory: no .old or staging left"

# --- macOS: installed, WARN, warn summary, exit 0 ---
fresh
rc=0
RS_PRE="OS=mac"
run_step i-mac || rc=$?
RS_PRE=""
assert_eq 0 "$rc" "install mac: exit 0"
assert_file "$TOOLS_DIR/ghidra_12.1.4_PUBLIC/.install-complete" "install mac: .install-complete exists"
assert_eq 1 "$(grep -cF "WARN  [ghidra] $WARN_MAC" "$T/i-mac.log")" "install mac: the verbatim WARN is logged once"
assert_match '^summary=warn: 12\.1\.4 installed' "$(cat "$T/i-mac.state")" "install mac: the summary is warn-class"

# --- env GHIDRA_INSTALL_DIR at a 12.2 install: WARN, then the install proceeds ---
fresh
rc=0
RS_PRE="GHIDRA_INSTALL_DIR='$F122'; export GHIDRA_INSTALL_DIR"
run_step i-122 || rc=$?
RS_PRE=""
assert_eq 0 "$rc" "env 12.2: exit 0"
assert_eq 1 "$(grep -cF 'WARN  [ghidra] 12.2 is not accepted by rea 6.8.0; installing 12.1.4 alongside' "$T/i-122.log")" "env 12.2: the verbatim WARN is logged"
assert_file "$TOOLS_DIR/ghidra_12.1.4_PUBLIC/.install-complete" "env 12.2: Ghidra 12.1.4 is installed alongside"
assert_eq "dir=$TOOLS_DIR/ghidra_12.1.4_PUBLIC" "$(sed -n 1p "$T/i-122.state")" "env 12.2: the new install is selected"

# --- install: failures leave nothing ---
mk_srv badver badver
fresh
rc=0
run_step i-badver || rc=$?
assert_eq 5 "$rc" "wrong version in the archive: exit 5"
assert_match "reports version '12\\.1\\.3', expected 12\\.1\\.4" "$(logtext i-badver)" "wrong version: logged"
assert_eq "" "$(listing "$TOOLS_DIR")" "wrong version: nothing installed or left"

mk_srv two two
fresh
rc=0
run_step i-two || rc=$?
assert_eq 5 "$rc" "two top directories: exit 5"
assert_match 'exactly one top directory' "$(logtext i-two)" "two top directories: logged"
assert_eq "" "$(listing "$TOOLS_DIR")" "two top directories: nothing installed"

mk_srv badname badname
fresh
rc=0
run_step i-badname || rc=$?
assert_eq 5 "$rc" "wrong top directory name: exit 5"
assert_eq "" "$(listing "$TOOLS_DIR")" "wrong top directory name: nothing installed"

mk_srv size normal
set_pin PIN_GHIDRA_ZIP_BYTES $((ZIP_SIZE + 1))
fresh
rc=0
run_step i-size || rc=$?
assert_eq 5 "$rc" "size mismatch: exit 5"
assert_match "is $ZIP_SIZE bytes, expected $((ZIP_SIZE + 1))" "$(logtext i-size)" "size mismatch: logged"
assert_eq "" "$(listing "$TOOLS_DIR")" "size mismatch: nothing installed, no zip left"

mk_srv hash normal
set_pin PIN_GHIDRA_SHA256 0000000000000000000000000000000000000000000000000000000000000000
fresh
rc=0
run_step i-hash || rc=$?
assert_eq 5 "$rc" "hash mismatch: exit 5"
assert_match 'checksum mismatch' "$(logtext i-hash)" "hash mismatch: logged"
assert_eq "" "$(listing "$TOOLS_DIR")" "hash mismatch: nothing installed, no zip left"
assert_eq 1 "$(count_of "$DL_PATH")" "hash mismatch: the zip was fetched (and refused)"

# an unmarked earlier directory survives a failed install untouched
mkdir -p "$TOOLS_DIR/ghidra_12.1.4_PUBLIC"
printf 'keep\n' >"$TOOLS_DIR/ghidra_12.1.4_PUBLIC/old-file"
rc=0
run_step i-hash2 || rc=$?
assert_eq 5 "$rc" "hash mismatch over an old directory: exit 5"
assert_file "$TOOLS_DIR/ghidra_12.1.4_PUBLIC/old-file" "hash mismatch over an old directory: it is left as it was"
assert_eq ghidra_12.1.4_PUBLIC "$(listing "$TOOLS_DIR")" "hash mismatch over an old directory: nothing else is left"

# --- dry run: logs URL, size and target; no download; writes nothing ---
mk_srv dry normal
rm -rf "$TOOLS_DIR"
rc=0
OPT_DRY_RUN=1
run_step i-dry || rc=$?
OPT_DRY_RUN=0
assert_eq 0 "$rc" "dry run: success"
assert_match "will install Ghidra 12\\.1\\.4 from https://github\\.com/.*\\.zip \\($ZIP_SIZE bytes\\) into .*ghidra_12\\.1\\.4_PUBLIC" "$(logtext i-dry)" "dry run: URL, size and target are logged"
assert_match 'read-only run, nothing installed' "$(logtext i-dry)" "dry run: says nothing was installed"
if [ -e "$TOOLS_DIR" ]; then
  t_fail "dry run: the tools dir must not be created"
else
  t_ok
fi
assert_eq 0 "$(count_of "$DL_PATH")" "dry run: the zip is not downloaded"
assert_eq 0 "$(count_of "$REL_PATH")" "dry run: the release URL is not requested"

# --check-upstream is read-only too
fresh
rc=0
OPT_CHECK_UPSTREAM=1
run_step i-chk || rc=$?
OPT_CHECK_UPSTREAM=0
assert_eq 0 "$rc" "check-upstream: success"
assert_eq "" "$(listing "$TOOLS_DIR")" "check-upstream: nothing written"
assert_eq 0 "$(count_of "$DL_PATH")" "check-upstream: the zip is not downloaded"

# --- main runs the steps in order, the lock released after the last ---
assert_eq "step_tools_bin step_jdk step_ghidra tools_lock_release" "$(sed -n '/^main() {/,/^}/p' "$ROOT/setup.sh" | grep -E '^  (step_tools_bin|step_jdk|step_ghidra|tools_lock_release)$' | tr -d ' ' | tr '\n' ' ' | sed 's/ $//')" "main: step_ghidra runs after step_jdk and before the lock release"

t_done
