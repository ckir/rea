#!/bin/sh
# Copyright (c) 2026 Costas Kirgoussios
#
# This software is licensed under the PolyForm Noncommercial License 1.0.0.
# You may obtain a copy of the License at:
# https://polyformproject.org/licenses/noncommercial/1.0.0/

# Tests for the setup.sh step jdk: jdk_valid on the fake JDK (tests/fixtures/fake-jdk), jdk_home_candidate, the
# fallback pins, the precedence of jdk_select and the whole install against the fake release server of
# tests/integration (python3, loopback only) with real tar.gz archives. A curl wrapper maps api.adoptium.net and
# github.com onto the server, so the product code runs unchanged. Every directory has a space in its name.
# shellcheck source=/dev/null
. "$(dirname "$0")/lib.sh"
cd "$ROOT" || exit 1

if ! command -v python3 >/dev/null 2>&1; then
  echo "jdk.sh: python3 is required" >&2
  exit 1
fi

T="$ROOT/tests/.tmp/jdk work $$"
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
unset GITHUB_TOKEN JAVA_HOME

ALLOWED_SCHEMES="https http"
ALLOWED_HOSTS="github.com api.adoptium.net 127.0.0.1"
RETRY_WAITS="0 0"
SLEEP=true
OS=linux
ARCH=x64
OPT_DRY_RUN=0
OPT_CHECK_UPSTREAM=0
OPT_JAVA_HOME=""
TOOLS_DIR="$T/tools dir"
LOG_FILE=$T/unit.log
CONSOLE_LEVEL=ERROR
export ALLOWED_SCHEMES ALLOWED_HOSTS RETRY_WAITS SLEEP OS ARCH OPT_DRY_RUN OPT_CHECK_UPSTREAM OPT_JAVA_HOME TOOLS_DIR LOG_FILE CONSOLE_LEVEL
FAKE=$ROOT/tests/fixtures/fake-jdk
REL=jdk-21.0.13+9
ARCHIVE=OpenJDK21U-jdk_x64_linux_hotspot_21.0.13_9.tar.gz
API_PATH=/v3/assets/latest/21/hotspot

# curl_local ARG...: curl with api.adoptium.net and github.com URLs sent to the fake server (BASE) instead
curl_local() {
  cx_n=$#
  while [ "$cx_n" -gt 0 ]; do
    cx_a=$1
    shift
    case "$cx_a" in
      https://github.com/* | https://api.adoptium.net/*) cx_a="$BASE/${cx_a#https://}" ;;
    esac
    set -- "$@" "$cx_a"
    cx_n=$((cx_n - 1))
  done
  curl "$@"
}

# mk_fake DIR BANNER [ARCH]: a copy of the fake JDK whose java prints BANNER (printf format) and os.arch ARCH
mk_fake() {
  rm -rf "$1"
  mkdir -p "$1"
  cp -R "$FAKE/bin" "$1/bin"
  if [ -n "$2" ]; then
    printf '%b' "$2" >"$1/banner"
  fi
  if [ -n "${3:-}" ]; then
    printf '%s\n' "$3" >"$1/arch"
  fi
}

BAN21='openjdk version "21.0.13" 2026-10-21 LTS\nOpenJDK Runtime Environment (build 21.0.13+9-LTS)\nOpenJDK 64-Bit Server VM (build 21.0.13+9-LTS, mixed mode)\n'
BAN17='openjdk version "17.0.2" 2022-01-18\nOpenJDK 64-Bit Server VM (build 17.0.2+8, mixed mode)\n'

# --- jdk_valid ---
mk_fake "$T/j 21" "$BAN21"
assert_status 0 "jdk_valid: 21.0.13 64-bit amd64 on x64" jdk_valid "$T/j 21"
assert_eq "" "$(jdk_valid "$T/j 21")" "jdk_valid: nothing is printed on success"

mk_fake "$T/j 17" "$BAN17"
assert_status 1 "jdk_valid: 17 is refused" jdk_valid "$T/j 17"
assert_eq "major 17 < 21" "$(jdk_valid "$T/j 17")" "jdk_valid: the reason names the major"

mk_fake "$T/j 32" 'openjdk version "21"\nOpenJDK Client VM (build 21+35, mixed mode)\nOpenJDK 32-Bit Server VM\n'
assert_status 1 "jdk_valid: a 32-bit banner is refused" jdk_valid "$T/j 32"
assert_match '64-bit' "$(jdk_valid "$T/j 32")" "jdk_valid: 32-bit reason"

mk_fake "$T/j jre" "$BAN21"
rm -f "$T/j jre/bin/javac"
assert_status 1 "jdk_valid: a JRE (no javac) is refused" jdk_valid "$T/j jre"
assert_match 'javac.*JRE' "$(jdk_valid "$T/j jre")" "jdk_valid: JRE reason"

mk_fake "$T/j nojava" "$BAN21"
rm -f "$T/j nojava/bin/java"
assert_status 1 "jdk_valid: no java is refused" jdk_valid "$T/j nojava"
mk_fake "$T/j noexec" "$BAN21"
chmod -x "$T/j noexec/bin/java"
assert_status 1 "jdk_valid: a non-executable java is refused" jdk_valid "$T/j noexec"
assert_status 1 "jdk_valid: a missing directory is refused" jdk_valid "$T/does not exist"

mk_fake "$T/j 8" 'java version "1.8.0_392"\nJava(TM) SE Runtime Environment (build 1.8.0_392-b08)\nJava HotSpot(TM) 64-Bit Server VM (build 25.392-b08, mixed mode)\n'
assert_status 1 "jdk_valid: 1.8.0_392 is refused" jdk_valid "$T/j 8"
assert_eq "major 8 < 21" "$(jdk_valid "$T/j 8")" "jdk_valid: 1.8 reads as major 8"

mk_fake "$T/j bare" 'openjdk version "21"\nOpenJDK 64-Bit Server VM (build 21+35, mixed mode)\n'
assert_status 0 "jdk_valid: openjdk version \"21\" without dots" jdk_valid "$T/j bare"
mk_fake "$T/j 22" 'openjdk version "22.0.1" 2024-04-16\nOpenJDK 64-Bit Server VM (build 22.0.1+8, mixed mode)\n'
assert_status 0 "jdk_valid: a later major is accepted" jdk_valid "$T/j 22"
mk_fake "$T/j crlf" 'openjdk version "21.0.13" 2026-10-21 LTS\r\nOpenJDK 64-Bit Server VM (build 21.0.13+9-LTS, mixed mode)\r\n' 'amd64'
printf 'amd64\r\n' >"$T/j crlf/arch"
assert_status 0 "jdk_valid: CRLF output" jdk_valid "$T/j crlf"
mk_fake "$T/j out" "$BAN21"
: >"$T/j out/stream"
assert_status 0 "jdk_valid: the banner on stdout" jdk_valid "$T/j out"
mk_fake "$T/j nover" 'something odd\n'
assert_status 1 "jdk_valid: no version in the output" jdk_valid "$T/j nover"
assert_match 'cannot read the version' "$(jdk_valid "$T/j nover")" "jdk_valid: unreadable version reason"
mk_fake "$T/j fail" "$BAN21"
: >"$T/j fail/fail"
assert_status 1 "jdk_valid: a failing java is refused" jdk_valid "$T/j fail"

# architecture mapping
mk_fake "$T/j x86" "$BAN21" x86_64
assert_status 0 "jdk_valid: x86_64 is x64" jdk_valid "$T/j x86"
mk_fake "$T/j arm" "$BAN21" aarch64
assert_status 1 "jdk_valid: aarch64 on an x64 host is refused" jdk_valid "$T/j arm"
assert_match 'architecture aarch64 does not match this host \(x64\)' "$(jdk_valid "$T/j arm")" "jdk_valid: architecture reason"
assert_eq 0 "$(
  ARCH=aarch64
  jdk_valid "$T/j arm" >/dev/null
  echo $?
)" "jdk_valid: aarch64 on an aarch64 host"
mk_fake "$T/j arm64" "$BAN21" arm64
assert_eq 0 "$(
  ARCH=aarch64
  jdk_valid "$T/j arm64" >/dev/null
  echo $?
)" "jdk_valid: arm64 is aarch64"
assert_eq 1 "$(
  ARCH=aarch64
  jdk_valid "$T/j 21" >/dev/null
  echo $?
)" "jdk_valid: amd64 on an aarch64 host is refused"
mk_fake "$T/j 386" "$BAN21" x86
assert_status 1 "jdk_valid: an x86 os.arch is refused" jdk_valid "$T/j 386"

# Windows names
mk_fake "$T/j win" "$BAN21"
mv "$T/j win/bin/java" "$T/j win/bin/java.exe"
mv "$T/j win/bin/javac" "$T/j win/bin/javac.exe"
assert_eq 0 "$(
  OS=windows
  jdk_valid "$T/j win" >/dev/null
  echo $?
)" "jdk_valid: java.exe and javac.exe on Windows"
assert_status 1 "jdk_valid: java.exe is not java off Windows" jdk_valid "$T/j win"

# --- jdk_home_candidate ---
mkdir -p "$T/h plain" "$T/h mac/Contents/Home"
assert_eq "$T/h plain" "$(jdk_home_candidate "$T/h plain")" "home candidate: plain directory"
assert_eq "$T/h mac" "$(jdk_home_candidate "$T/h mac")" "home candidate: Contents/Home off macOS is ignored"
assert_eq "$T/h mac/Contents/Home" "$(
  OS=mac
  jdk_home_candidate "$T/h mac"
)" "home candidate: macOS with Contents/Home"
assert_eq "$T/h plain" "$(
  OS=mac
  jdk_home_candidate "$T/h plain"
)" "home candidate: macOS without Contents/Home"

# --- jdk_fallback ---
for fb in "linux x64 $PIN_JDK_FALLBACK_LINUX_X64" "mac x64 $PIN_JDK_FALLBACK_MAC_X64" "mac aarch64 $PIN_JDK_FALLBACK_MAC_AARCH64" "windows x64 $PIN_JDK_FALLBACK_WINDOWS_X64"; do
  IFS=' ' read -r fb_os fb_arch fb_pin <<EOF
$fb
EOF
  fb_name=${fb_pin%%:*}
  fb_sha=${fb_pin#*:}
  got=$(
    jdk_fallback "$fb_os" "$fb_arch"
    echo "$JDK_RELEASE $JDK_URL $JDK_SHA256 $JDK_SIDECAR_URL"
  )
  assert_eq "$PIN_JDK_FALLBACK_RELEASE $PIN_JDK_FALLBACK_URL_BASE$fb_name $fb_sha $PIN_JDK_FALLBACK_URL_BASE$fb_name.sha256.txt" "$got" "fallback: $fb_os $fb_arch"
done
assert_status 1 "fallback: linux aarch64 has none" jdk_fallback linux aarch64
assert_match '^jdk-21\.0\.13\+9$' "$PIN_JDK_FALLBACK_RELEASE" "fallback release name"

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

# mk_archive FILE LAYOUT: a tar.gz of a fake JDK. LAYOUT is normal (jdk-21.0.13+9/bin), mac
# (jdk-21.0.13+9/Contents/Home/bin), two (a second top directory), badname (jdk-21.0.99+1) or j17 (a JDK 17)
mk_archive() {
  ma_src="$T/archive src"
  rm -rf "$ma_src"
  mkdir -p "$ma_src"
  ma_top=$REL
  if [ "$2" = badname ]; then
    ma_top=jdk-21.0.99+1
  fi
  ma_home="$ma_src/$ma_top"
  if [ "$2" = mac ]; then
    ma_home="$ma_src/$ma_top/Contents/Home"
  fi
  if [ "$2" = j17 ]; then
    mk_fake "$ma_home" "$BAN17"
  else
    mk_fake "$ma_home" ""
  fi
  if [ "$2" = two ]; then
    mkdir -p "$ma_src/jdk-notes"
    printf 'x\n' >"$ma_src/jdk-notes/readme"
    tar -czf "$1" -C "$ma_src" "$ma_top" jdk-notes
  else
    tar -czf "$1" -C "$ma_src" "$ma_top"
  fi
}

# mk_srv NAME OS LAYOUT APIKIND SIDEKIND: builds the archive, the API answer, the checksum file and the scenario
# of one fake server, starts it and sets BASE. APIKIND: good, badsha (the API checksum is wrong) or
# down (no answer). SIDEKIND: ok, bad (a different checksum) or none (no answer).
mk_srv() {
  ms_name=$1
  ms_os=$2
  ms_dir="$T/srv $ms_name"
  mkdir -p "$ms_dir"
  mk_archive "$ms_dir/jdk.tgz" "$3"
  ms_sha=$(sha256_file "$ms_dir/jdk.tgz")
  ms_bytes=$(wc -c <"$ms_dir/jdk.tgz" | tr -d ' ')
  ms_api_sha=$ms_sha
  if [ "$4" = badsha ]; then
    ms_api_sha=0000000000000000000000000000000000000000000000000000000000000000
  fi
  sed -e "s/\"checksum\": \"[0-9a-f]*\"/\"checksum\": \"$ms_api_sha\"/" -e "s/\"size\": [0-9]*/\"size\": $ms_bytes/" "$ROOT/tests/fixtures/adoptium-linux-x64.json" >"$ms_dir/api.json"
  if [ "$5" = bad ]; then
    printf '%s  %s\n' 1111111111111111111111111111111111111111111111111111111111111111 "$ARCHIVE" >"$ms_dir/side.txt"
  else
    printf '%s  %s\n' "$ms_sha" "$ARCHIVE" >"$ms_dir/side.txt"
  fi
  scn_start "$ms_dir/scenario.json"
  if [ "$4" != down ]; then
    scn_ent "/api.adoptium.net$API_PATH?architecture=x64&image_type=jdk&os=$ms_os&vendor=eclipse" '{"status":200,"body_file":"api.json"}'
  fi
  ms_rel=/github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.13%2B9
  scn_ent "$ms_rel/$ARCHIVE" '{"status":302,"location":"{base}/dl/jdk.tgz"}'
  scn_ent /dl/jdk.tgz '{"status":200,"body_file":"jdk.tgz"}'
  if [ "$5" != none ]; then
    scn_ent "$ms_rel/$ARCHIVE.sha256.txt" '{"status":302,"location":"{base}/dl/side.txt"}'
    scn_ent /dl/side.txt '{"status":200,"body_file":"side.txt"}'
  fi
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
    echo "jdk.sh: the fake server did not start" >&2
    cat "$ms_dir/server.err" >&2
    exit 1
  fi
  BASE=http://127.0.0.1:$ms_port
  ARCHIVE_SHA=$ms_sha
}

# count_of PATH: the GET requests the fake server has seen for PATH
count_of() {
  curl -sS "$BASE/__count$1"
}

# the archive body is served from here once the release URL has redirected; this counts real downloads
DL_PATH=/dl/jdk.tgz

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

# run_step NAME: step_jdk under the tools lock, in a subshell with the curl wrapper and the traps; the log goes to
# $T/NAME.log and the result to $T/NAME.state. Extra settings: the caller sets OPT_DRY_RUN or RS_PRE
# (RS_PRE, a shell command, runs first). The lock is taken like step_tools_bin does and released at the end.
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
    step_jdk
    printf 'home=%s\nsummary=%s\n' "$JAVA_HOME_SELECTED" "$(summary_get jdk)" >"$T/$1.state"
    if [ "${OPT_DRY_RUN:-0}" -ne 1 ]; then
      tools_lock_release
    fi
  ) >/dev/null 2>&1
}

# --- jdk_select: precedence ---
# select_with HOME LOG: jdk_select with the JAVA_HOME environment variable at HOME; prints JAVA_HOME_SELECTED
select_with() {
  JAVA_HOME=$1
  LOG_FILE=$2
  export JAVA_HOME LOG_FILE
  jdk_select
  echo "$JAVA_HOME_SELECTED"
}

fresh
mk_fake "$T/j 21" "$BAN21"
mk_fake "$T/j jre" "$BAN21"
rm -f "$T/j jre/bin/javac"

rc=0
(
  OPT_JAVA_HOME="$T/j jre"
  LOG_FILE=$T/sel1.log
  jdk_select
) >/dev/null 2>&1 || rc=$?
assert_eq 1 "$rc" "select: --java-home at a JRE dies with 1"
assert_match 'not a usable JDK: no bin/javac.*JRE' "$(cat "$T/sel1.log")" "select: the reason for the --java-home failure is logged"
assert_eq "" "$(listing "$TOOLS_DIR")" "select: a failed --java-home installs nothing"

rc=0
(
  OPT_JAVA_HOME="$T/j 17"
  LOG_FILE=$T/sel1b.log
  jdk_select
) >/dev/null 2>&1 || rc=$?
assert_eq 1 "$rc" "select: --java-home at a JDK 17 dies with 1"
assert_match 'major 17 < 21' "$(cat "$T/sel1b.log")" "select: JDK 17 reason is logged"

assert_eq "$T/j 21" "$(
  OPT_JAVA_HOME="$T/j 21"
  LOG_FILE=$T/sel2.log
  jdk_select
  echo "$JAVA_HOME_SELECTED"
)" "select: a valid --java-home is used"
assert_eq "$T/h mac/Contents/Home" "$(
  mk_fake "$T/h mac/Contents/Home" "$BAN21"
  OS=mac
  OPT_JAVA_HOME="$T/h mac"
  LOG_FILE=$T/sel2m.log
  jdk_select
  echo "$JAVA_HOME_SELECTED"
)" "select: macOS --java-home resolves to Contents/Home"

# JAVA_HOME at the JRE and a valid tools-dir install: WARN, the tools-dir one wins
mk_fake "$TOOLS_DIR/jdk-21.0.13+9" "$BAN21"
: >"$TOOLS_DIR/jdk-21.0.13+9/.install-complete"
out=$(select_with "$T/j jre" "$T/sel3.log")
assert_eq "$TOOLS_DIR/jdk-21.0.13+9" "$out" "select: an invalid JAVA_HOME falls through to the tools dir"
assert_match 'WARN.*JAVA_HOME .*j jre is not a usable JDK .*JRE.*ignoring it' "$(cat "$T/sel3.log")" "select: the invalid JAVA_HOME is a WARN with the reason"
assert_match 'reusing jdk-21\.0\.13\+9' "$(cat "$T/sel3.log")" "select: the tools-dir reuse is logged"

# JAVA_HOME valid: used, the tools dir ignored
out=$(select_with "$T/j 21" "$T/sel4.log")
assert_eq "$T/j 21" "$out" "select: a valid JAVA_HOME wins over the tools dir"
if grep -q WARN "$T/sel4.log"; then
  t_fail "select: a valid JAVA_HOME logs no WARN"
else
  t_ok
fi

# the newest of several valid installs; one without the sentinel and one that is a JDK 17 are skipped
mk_fake "$TOOLS_DIR/jdk-21.0.20+1" "$BAN21"
: >"$TOOLS_DIR/jdk-21.0.20+1/.install-complete"
mk_fake "$TOOLS_DIR/jdk-21.0.99+1" "$BAN21"
mk_fake "$TOOLS_DIR/jdk-21.1.0+1" "$BAN17"
: >"$TOOLS_DIR/jdk-21.1.0+1/.install-complete"
out=$(
  LOG_FILE=$T/sel5.log
  jdk_select
  echo "$JAVA_HOME_SELECTED"
)
assert_eq "$TOOLS_DIR/jdk-21.0.20+1" "$out" "select: newest valid install, skipping no-sentinel and wrong-major ones"
assert_match 'WARN.*ignoring the install jdk-21\.1\.0\+1: major 17 < 21' "$(cat "$T/sel5.log")" "select: the wrong-major install is a WARN with the reason"
assert_match 'DEBUG.*ignoring jdk-21\.0\.99\+1: no \.install-complete' "$(cat "$T/sel5.log")" "select: the no-sentinel install is logged"

# --- install: success, layouts ---
mk_srv ok linux normal good ok
fresh
rc=0
run_step i-ok || rc=$?
assert_eq 0 "$rc" "install: success"
assert_eq "$REL" "$(listing "$TOOLS_DIR")" "install: only jdk-21.0.13+9 is left in the tools dir (no staging, archive or lock)"
assert_file "$TOOLS_DIR/$REL/.install-complete" "install: .install-complete exists"
assert_file "$TOOLS_DIR/$REL/bin/java" "install: bin/java is in place"
assert_eq "home=$TOOLS_DIR/$REL" "$(sed -n 1p "$T/i-ok.state")" "install: JAVA_HOME_SELECTED is the install"
assert_match '^summary=jdk-21\.0\.13\+9 installed' "$(cat "$T/i-ok.state")" "install: SUMMARY_jdk is set"
assert_match 'jdk.* resolved jdk-21\.0\.13\+9: https://github\.com/adoptium/temurin21-binaries/.*\.tar\.gz \([0-9]+ bytes\)' "$(logtext i-ok)" "install: the resolved release, URL and size are logged"
assert_match 'installed jdk-21\.0\.13\+9' "$(logtext i-ok)" "install: the install is logged"
assert_eq 1 "$(count_of "$DL_PATH")" "install: the archive was fetched once"

# a second run reuses it without touching the network
rc=0
run_step i-again || rc=$?
assert_eq 0 "$rc" "reuse: second run succeeds"
assert_match 'reusing jdk-21\.0\.13\+9' "$(logtext i-again)" "reuse: the install is reused"
assert_eq 1 "$(count_of "$DL_PATH")" "reuse: no second download"

# macOS layout: Contents/Home inside the top directory
mk_srv mac mac mac good ok
fresh
rc=0
RS_PRE="OS=mac"
run_step i-mac || rc=$?
RS_PRE=""
assert_eq 0 "$rc" "install mac: success"
assert_eq "home=$TOOLS_DIR/$REL/Contents/Home" "$(sed -n 1p "$T/i-mac.state")" "install mac: JAVA_HOME_SELECTED is Contents/Home"
assert_file "$TOOLS_DIR/$REL/.install-complete" "install mac: .install-complete is at the top"
assert_file "$TOOLS_DIR/$REL/Contents/Home/bin/javac" "install mac: bin/javac under Contents/Home"

# --- install: failures leave nothing ---
mk_srv sbad linux normal good bad
fresh
rc=0
run_step i-sbad || rc=$?
assert_eq 5 "$rc" "sidecar mismatch: exit 5"
assert_match 'checksum mismatch for jdk-21\.0\.13\+9' "$(logtext i-sbad)" "sidecar mismatch: logged"
assert_eq "" "$(listing "$TOOLS_DIR")" "sidecar mismatch: nothing installed or left"
assert_eq 0 "$(count_of "$DL_PATH")" "sidecar mismatch: the archive was never downloaded"

mk_srv apibad linux normal badsha none
fresh
rc=0
run_step i-apibad || rc=$?
assert_eq 5 "$rc" "archive checksum mismatch: exit 5"
assert_match 'checksum mismatch' "$(logtext i-apibad)" "archive checksum mismatch: logged"
assert_eq "" "$(listing "$TOOLS_DIR")" "archive checksum mismatch: nothing installed, no archive left"

mk_srv apibad2 linux normal badsha ok
fresh
rc=0
run_step i-apibad2 || rc=$?
assert_eq 5 "$rc" "API checksum vs sidecar disagree: exit 5"
assert_eq "" "$(listing "$TOOLS_DIR")" "API checksum vs sidecar disagree: nothing installed"

mk_srv noside linux normal good none
fresh
rc=0
run_step i-noside || rc=$?
assert_eq 0 "$rc" "sidecar unreachable: success"
assert_match 'WARN.*checksum sidecar of jdk-21\.0\.13\+9 is unreachable' "$(logtext i-noside)" "sidecar unreachable: WARN"
assert_eq "$REL" "$(listing "$TOOLS_DIR")" "sidecar unreachable: installed"

mk_srv two linux two good ok
fresh
rc=0
run_step i-two || rc=$?
assert_eq 5 "$rc" "two top directories: exit 5"
assert_match 'exactly one top directory' "$(logtext i-two)" "two top directories: logged"
assert_eq "" "$(listing "$TOOLS_DIR")" "two top directories: nothing installed"

mk_srv badname linux badname good ok
fresh
rc=0
run_step i-badname || rc=$?
assert_eq 5 "$rc" "wrong top directory name: exit 5"
assert_eq "" "$(listing "$TOOLS_DIR")" "wrong top directory name: nothing installed"

mk_srv j17 linux j17 good ok
fresh
rc=0
run_step i-j17 || rc=$?
assert_eq 5 "$rc" "downloaded JDK 17: exit 5"
assert_match 'not a usable JDK: major 17 < 21' "$(logtext i-j17)" "downloaded JDK 17: the reason is logged"
assert_eq "" "$(listing "$TOOLS_DIR")" "downloaded JDK 17: nothing installed"

# --- fallback pin when Adoptium is unreachable ---
mk_srv down linux normal down ok
fresh
rc=0
RS_PRE="PIN_JDK_FALLBACK_LINUX_X64=$ARCHIVE:$ARCHIVE_SHA"
run_step i-down || rc=$?
RS_PRE=""
assert_eq 0 "$rc" "fallback: success with the embedded pin"
assert_match 'WARN.*Adoptium API unreachable; installing the embedded fallback jdk-21\.0\.13\+9, possibly outdated' "$(logtext i-down)" "fallback: the WARN text"
assert_eq "$REL" "$(listing "$TOOLS_DIR")" "fallback: installed"
assert_match 'resolved jdk-21\.0\.13\+9: https://github\.com/adoptium/temurin21-binaries/releases/download/jdk-21\.0\.13%2B9/OpenJDK21U-jdk_x64_linux' "$(logtext i-down)" "fallback: the pin URL is used"

# the fallback with its real pinned checksum does not match this fake archive: nothing is installed
mk_srv down2 linux normal down ok
fresh
rc=0
run_step i-down2 || rc=$?
assert_eq 5 "$rc" "fallback: a pin whose checksum does not match is refused with 5"
assert_eq "" "$(listing "$TOOLS_DIR")" "fallback: nothing installed on a mismatch"

# --- dry run: logs the plan, writes nothing ---
mk_srv dry linux normal good ok
rm -rf "$TOOLS_DIR"
rc=0
OPT_DRY_RUN=1
run_step i-dry || rc=$?
OPT_DRY_RUN=0
assert_eq 0 "$rc" "dry run: success"
assert_match 'resolved jdk-21\.0\.13\+9: https://github\.com/.*\.tar\.gz \([0-9]+ bytes\)' "$(logtext i-dry)" "dry run: release, URL and size are logged"
assert_match 'read-only run, nothing installed' "$(logtext i-dry)" "dry run: says nothing was installed"
if [ -e "$TOOLS_DIR" ]; then
  t_fail "dry run: the tools dir must not be created"
else
  t_ok
fi
assert_eq 0 "$(count_of "$DL_PATH")" "dry run: the archive is not downloaded"

# --- prune: keeps the newest two, never touches jdk-notes ---
mk_srv prune linux normal good ok
fresh
for v in 21.0.1+1 21.0.2+1 21.0.3+1; do
  mk_fake "$TOOLS_DIR/jdk-$v" "$BAN21"
  : >"$TOOLS_DIR/jdk-$v/.install-complete"
  : >"$TOOLS_DIR/jdk-$v/bin/marker"
done
mkdir -p "$TOOLS_DIR/jdk-notes"
printf 'keep\n' >"$TOOLS_DIR/jdk-notes/readme.txt"
mkdir -p "$TOOLS_DIR/jdk-21.0.0+1 stray"
printf 'x\n' >"$TOOLS_DIR/jdk-21.0.0+1 stray/file"
# the newest valid install is jdk-21.0.3+1, so the step reuses it; call jdk_install to force the new one
rc=0
RS_PRE="jdk_install"
run_step i-prune || rc=$?
RS_PRE=""
assert_eq 0 "$rc" "prune: success"
assert_eq "jdk-21.0.0+1 stray
jdk-21.0.13+9
jdk-21.0.3+1
jdk-notes" "$(listing "$TOOLS_DIR" | LC_ALL=C sort)" "prune: the two newest stay and the older ones go; jdk-notes and a no-marker directory are untouched"
assert_file "$TOOLS_DIR/jdk-notes/readme.txt" "prune: jdk-notes content is intact"

# --- main runs the steps in order, the lock released after the last ---
assert_eq "step_tools_bin step_jdk tools_lock_release" "$(sed -n '/^main() {/,/^}/p' "$ROOT/setup.sh" | grep -E '^  (step_tools_bin|step_jdk|tools_lock_release)$' | tr -d ' ' | tr '\n' ' ' | sed 's/ $//')" "main: step_jdk runs after step_tools_bin and before the lock release"

# --- an install plan is re-checked under the lock: what another run installed meanwhile is reused ---
# (run in a child shell: the stubs replace the real functions)
r3=$(sh -c '. ./setup.sh; PLAN_jdk=install; jdk_choose() { JDK_REUSED=1; return 0; }; jdk_install() { echo INSTALLED; }; step_jdk' 2>/dev/null)
assert_eq "" "$r3" "step_jdk: the plan said install, the recheck found one, nothing is installed"
r3=$(sh -c '. ./setup.sh; PLAN_jdk=install; jdk_choose() { JDK_REUSED=0; return 1; }; jdk_install() { echo INSTALLED; }; step_jdk' 2>/dev/null)
assert_match "INSTALLED" "$r3" "step_jdk: still installs when the recheck finds nothing"

t_done
