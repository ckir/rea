#!/bin/sh
# Copyright (c) 2026 Costas Kirgoussios
#
# This software is licensed under the PolyForm Noncommercial License 1.0.0.
# You may obtain a copy of the License at:
# https://polyformproject.org/licenses/noncommercial/1.0.0/

# setup.sh: takes a stock machine to a running clavity-ls session with morluto/rea registered in an
# isolated agent-profile Claude profile. POSIX sh, one file. Run with --help for the flags.

# --- pins begin ---
PIN_SCRIPT_VERSION=0.1.0
PIN_GHIDRA_VERSION=12.1.4
PIN_GHIDRA_TOPDIR=ghidra_12.1.4_PUBLIC
PIN_GHIDRA_URL=https://github.com/NationalSecurityAgency/ghidra/releases/download/Ghidra_12.1.4_build/ghidra_12.1.4_PUBLIC_20260921.zip
PIN_GHIDRA_SHA256=ddac49f903da9d5bac833e5cc79395098b9c33cfd3279be5f31bd00387d2d4db
PIN_GHIDRA_ZIP_BYTES=569649598
PIN_GHIDRA_UNPACKED_MB=882
PIN_JDK_MAJOR=21
PIN_JDK_UNPACKED_MB=346
PIN_JDK_FALLBACK_RELEASE=jdk-21.0.13+9
PIN_JDK_FALLBACK_LINUX_X64=OpenJDK21U-jdk_x64_linux_hotspot_21.0.13_9.tar.gz:d7f5d5cf865a2902b70ff549b97586a7d3f234e016f041ab447ea740c7d66d1c
PIN_JDK_FALLBACK_MAC_X64=OpenJDK21U-jdk_x64_mac_hotspot_21.0.13_9.tar.gz:9aa1d1c17ae5467a022679e7e0af5c00797d94ac462ed1a46f4db07a8a34a6dd
PIN_JDK_FALLBACK_MAC_AARCH64=OpenJDK21U-jdk_aarch64_mac_hotspot_21.0.13_9.tar.gz:bf036b35b071bfb2f54f2c0af8ee8d88afa95ee6eb3dce02c0f94cfc2524d04a
PIN_JDK_FALLBACK_WINDOWS_X64=OpenJDK21U-jdk_x64_windows_hotspot_21.0.13_9.zip:a4dbaa05fca4bd89d84584e58c459bd732efebb1722af80ab13c6516832004f9
PIN_JDK_FALLBACK_URL_BASE=https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.13%2B9/
PIN_AGENT_PROFILE_REPO=ckir/aiprofiles
PIN_CLAVITY_REPO=ckir/clavity
PIN_REA_SPEC=rea-agents@latest
PIN_ALLOWED_HOSTS="github.com api.github.com release-assets.githubusercontent.com api.adoptium.net registry.npmjs.org raw.githubusercontent.com"
# --- pins end ---

EX_OK=0
EX_STEP=1
EX_USAGE=2
EX_PLATFORM=3
EX_PREREQ=4
EX_VERIFY=5

CONSOLE_LEVEL=${CONSOLE_LEVEL:-INFO}
LOG_FILE=${LOG_FILE:-/dev/null}
OS=""
ARCH=""

usage() {
  cat <<'EOF'
Usage: sh setup.sh [options]

  --profile NAME      profile name (default: rea)
  --folder PATH       folder handed to clavity-ls start (default: current directory)
  --ghidra-dir PATH   use this Ghidra install (env GHIDRA_INSTALL_DIR)
  --java-home PATH    use this JDK (env JAVA_HOME)
  --tools-dir PATH    where the JDK and Ghidra are installed
  --bin-dir PATH      where agent-profile and clavity-ls are installed (default: ~/.local/bin)
  --install-hopper    pass --install-hopper to rea setup (Linux and macOS only)
  --yes               do not prompt; without a terminal and without --yes, refuse (exit 2)
  --dry-run           plan only
  --no-launch         do everything except clavity-ls start
  --check-upstream    read-only drift check of every pinned and resolved release
  --verbose           console level DEBUG
  --quiet             console level WARN
  --log-dir PATH      log location
  --help              print this text and exit 0

Exit codes: 0 ok, 1 step failed, 2 usage, 3 unsupported platform, 4 prerequisite, 5 verification failed.
EOF
}

# --- logging ---

# level_rank LEVEL: prints 0..3 for DEBUG INFO WARN ERROR (unknown levels rank as INFO)
level_rank() {
  case "$1" in
    DEBUG) echo 0 ;;
    INFO) echo 1 ;;
    WARN) echo 2 ;;
    ERROR) echo 3 ;;
    *) echo 1 ;;
  esac
}

# log_format LEVEL STEP MSG [TIMESTAMP]: the one log line on stdout; the timestamp argument is for tests
log_format() {
  lf_ts=${4:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
  printf '%s %-5s [%s] %s\n' "$lf_ts" "$1" "$2" "$3"
}

# log LEVEL STEP MSG: the file always gets the line; stderr gets it when LEVEL >= CONSOLE_LEVEL
log() {
  l_line=$(log_format "$1" "$2" "$(abbrev_text "$(redact "$3")")")
  if ! { printf '%s\n' "$l_line" >>"$LOG_FILE"; } 2>/dev/null; then
    LOG_FILE=/dev/null
    printf 'warning: cannot write the log file; continuing without one\n' >&2
  fi
  if [ "$(level_rank "$1")" -ge "$(level_rank "$CONSOLE_LEVEL")" ]; then
    printf '%s\n' "$l_line" >&2
  fi
  return 0
}

# die CODE STEP MSG: logs ERROR with the log path and exits CODE
die() {
  d_code=$1
  d_step=$2
  shift 2
  log ERROR "$d_step" "$*"
  if [ "$LOG_FILE" != /dev/null ]; then
    log ERROR "$d_step" "details: $(abbrev_home "$LOG_FILE")"
  fi
  exit "$d_code"
}

# run_cmd STEP cmd...: logs the argument list, exit code and duration; stdout goes to the file named by
# RUN_STDOUT, stderr to the log (bounded to 4000 characters on failure). Returns the command's exit code.
run_cmd() {
  rc_step=$1
  shift
  RUN_STDOUT=$(mktemp "${TMPDIR:-/tmp}/rea-setup-out.XXXXXX") || return 1
  rc_err=$(mktemp "${TMPDIR:-/tmp}/rea-setup-err.XXXXXX") || {
    rm -f "$RUN_STDOUT"
    return 1
  }
  log DEBUG "$rc_step" "run: $*"
  rc_start=$(date +%s)
  rc=0
  "$@" >"$RUN_STDOUT" 2>"$rc_err" || rc=$?
  rc_secs=$(($(date +%s) - rc_start))
  log DEBUG "$rc_step" "exit $rc after ${rc_secs}s"
  if [ "$rc" -ne 0 ]; then
    log DEBUG "$rc_step" "stderr: $(head -c 4000 "$rc_err")"
  fi
  rm -f "$rc_err"
  return "$rc"
}

# log_open: creates the log directory and file, keeps the newest 20, prints the file path
log_open() {
  lo_dir=${OPT_LOG_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/rea-setup/logs}
  lo_file="$lo_dir/setup-$(date -u +%Y%m%dT%H%M%SZ)-$$.log"
  if mkdir -p "$lo_dir" 2>/dev/null && : >"$lo_file" 2>/dev/null; then
    # Names sort oldest first (UTC timestamp), so drop all but the last 20.
    lo_total=0
    for lo_old in "$lo_dir"/setup-*.log; do
      lo_total=$((lo_total + 1))
    done
    lo_n=0
    for lo_old in "$lo_dir"/setup-*.log; do
      lo_n=$((lo_n + 1))
      if [ $((lo_total - lo_n)) -ge 20 ]; then
        rm -f "$lo_old"
      fi
    done
    printf '%s\n' "$lo_file"
  else
    printf 'warning: cannot create a log file in %s; continuing without one\n' "$lo_dir" >&2
    printf '%s\n' /dev/null
  fi
}

# redact TEXT: hides secrets in a log message. Names are matched case-insensitively with explicit letter
# classes (portable: no GNU sed I flag); quoted values are consumed whole.
redact() {
  rd_q="'"
  rd_names='[Tt][Oo][Kk][Ee][Nn]|[Kk][Ee][Yy]|[Ss][Ee][Cc][Rr][Ee][Tt]|[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]'
  rd_auth='[Aa][Uu][Tt][Hh][Oo][Rr][Ii][Zz][Aa][Tt][Ii][Oo][Nn]'
  printf '%s\n' "$1" | sed -E \
    -e "s/([A-Za-z0-9_]*($rd_names)[A-Za-z0-9_]*)=(\"[^\"]*\"|${rd_q}[^${rd_q}]*${rd_q}|[^ ]*)/\\1=<redacted>/g" \
    -e "s/($rd_auth:)[^\"]*/\\1 <redacted>/g" \
    -e 's#(https?://)[^/@ ]*@#\1#g' \
    -e 's#(https?://[^ ?]*)\?[^ ]*#\1#g'
}

# abbrev_home PATH: prints PATH with the home directory as ~ (nothing when HOME is empty or /)
abbrev_home() {
  case "${HOME:-}" in
    '' | /) printf '%s\n' "$1" ;;
    *)
      case "$1" in
        "$HOME") printf '%s\n' "~" ;;
        "$HOME"/*) printf '~%s\n' "${1#"$HOME"}" ;;
        *) printf '%s\n' "$1" ;;
      esac
      ;;
  esac
}

# abbrev_text TEXT: replaces the home directory inside free text with ~ (whole path components only)
abbrev_text() {
  case "${HOME:-}" in
    '' | /)
      printf '%s\n' "$1"
      return 0
      ;;
  esac
  at_home=$(printf '%s' "$HOME" | sed -e 's/[][\\.*^$+?(){}|#]/\\&/g')
  printf '%s\n' "$1" | sed -E -e "s#(^|[^A-Za-z0-9._/-])${at_home}(/|[^A-Za-z0-9._-]|\$)#\\1~\\2#g"
}

# --- arguments ---

# need_value FLAG COUNT: dies EX_USAGE when the flag has no value after it
need_value() {
  if [ "$2" -lt 2 ]; then
    die "$EX_USAGE" args "option $1 needs a value"
  fi
}

parse_args() {
  OPT_PROFILE=rea
  OPT_FOLDER=$PWD
  OPT_GHIDRA_DIR=""
  OPT_JAVA_HOME=""
  OPT_TOOLS_DIR=""
  OPT_BIN_DIR=""
  OPT_INSTALL_HOPPER=0
  OPT_YES=0
  OPT_DRY_RUN=0
  OPT_NO_LAUNCH=0
  OPT_CHECK_UPSTREAM=0
  OPT_CONSOLE_LEVEL=INFO
  OPT_LOG_DIR=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --profile) need_value "$1" $# && OPT_PROFILE=$2 && shift 2 ;;
      --folder) need_value "$1" $# && OPT_FOLDER=$2 && shift 2 ;;
      --ghidra-dir) need_value "$1" $# && OPT_GHIDRA_DIR=$2 && shift 2 ;;
      --java-home) need_value "$1" $# && OPT_JAVA_HOME=$2 && shift 2 ;;
      --tools-dir) need_value "$1" $# && OPT_TOOLS_DIR=$2 && shift 2 ;;
      --bin-dir) need_value "$1" $# && OPT_BIN_DIR=$2 && shift 2 ;;
      --log-dir) need_value "$1" $# && OPT_LOG_DIR=$2 && shift 2 ;;
      --install-hopper) OPT_INSTALL_HOPPER=1 && shift ;;
      --yes) OPT_YES=1 && shift ;;
      --dry-run) OPT_DRY_RUN=1 && shift ;;
      --no-launch) OPT_NO_LAUNCH=1 && shift ;;
      --check-upstream) OPT_CHECK_UPSTREAM=1 && shift ;;
      --verbose) OPT_CONSOLE_LEVEL=DEBUG && shift ;;
      --quiet) OPT_CONSOLE_LEVEL=WARN && shift ;;
      --help)
        usage
        exit "$EX_OK"
        ;;
      *) die "$EX_USAGE" args "unknown option: $1 (see --help)" ;;
    esac
  done
}

# --- platform ---

# platform_detect: sets OS and ARCH; returns 0 only for linux x64, mac x64, mac aarch64, windows x64.
# UNAME_S and UNAME_M override uname for tests; main unsets them first.
platform_detect() {
  pd_s=${UNAME_S:-$(uname -s)}
  pd_m=${UNAME_M:-$(uname -m)}
  case "$pd_s" in
    Linux) OS=linux ;;
    Darwin) OS=mac ;;
    MINGW* | MSYS* | CYGWIN*) OS=windows ;;
    *) OS=$pd_s ;;
  esac
  case "$pd_m" in
    x86_64 | amd64) ARCH=x64 ;;
    arm64 | aarch64) ARCH=aarch64 ;;
    *) ARCH=$pd_m ;;
  esac
  case "$OS $ARCH" in
    "linux x64" | "mac x64" | "mac aarch64" | "windows x64") return 0 ;;
    *) return 1 ;;
  esac
}

# --- validation ---

# profile_name_valid NAME: agent-profile's naming rules
profile_name_valid() {
  pv_name=$1
  case "$pv_name" in
    '' | *'
'*) return 1 ;;
  esac
  printf '%s\n' "$pv_name" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]*$' || return 1
  case "$pv_name" in
    *.) return 1 ;;
  esac
  pv_lower=$(printf '%s' "$pv_name" | tr '[:upper:]' '[:lower:]')
  case "$pv_lower" in
    agents | profiles | status | list | create | delete | current | resolve | doctor | link | unlink | repositories | completions) return 1 ;;
  esac
  case "${pv_lower%%.*}" in
    con | prn | aux | nul | com[1-9] | lpt[1-9]) return 1 ;;
  esac
  return 0
}

# semver_from_output TEXT: prints the first X.Y.Z
semver_from_output() {
  printf '%s\n' "$1" | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1
}

# semver_part VERSION N: the Nth (1-3) numeric component's leading digits; a missing one counts as 0
semver_part() {
  sp_rest=$1
  sp_i=1
  while [ "$sp_i" -lt "$2" ]; do
    case "$sp_rest" in
      *.*) sp_rest=${sp_rest#*.} ;;
      *) sp_rest="" ;;
    esac
    sp_i=$((sp_i + 1))
  done
  sp_part=${sp_rest%%.*}
  sp_part=${sp_part%%[!0-9]*}
  echo "${sp_part:-0}"
}

# semver_compare A B: prints -1, 0 or 1, comparing the leading numeric X.Y.Z only
semver_compare() {
  sc_i=0
  while [ "$sc_i" -lt 3 ]; do
    sc_i=$((sc_i + 1))
    sc_x=$(semver_part "$1" "$sc_i")
    sc_y=$(semver_part "$2" "$sc_i")
    if [ "$sc_x" -lt "$sc_y" ]; then
      echo -1
      return 0
    fi
    if [ "$sc_x" -gt "$sc_y" ]; then
      echo 1
      return 0
    fi
  done
  echo 0
}

# node_version_ok VERSION: 0 when v22.x >= 22.23.4, v24.x >= 24.22.1 or >= 26.12.1
node_version_ok() {
  nv=${1#v}
  nv_major=${nv%%.*}
  nv_major=${nv_major%%[!0-9]*}
  case "$nv_major" in
    22) nv_floor=22.23.4 ;;
    24) nv_floor=24.22.1 ;;
    '' | *[!0-9]*) return 1 ;;
    *)
      if [ "$nv_major" -ge 26 ]; then
        nv_floor=26.12.1
        if [ "$nv_major" -gt 26 ]; then
          return 0
        fi
      else
        return 1
      fi
      ;;
  esac
  [ "$(semver_compare "$nv" "$nv_floor")" != -1 ]
}

# confirm PROMPT: 0 when OPT_YES; refuses without a terminal; else reads one line
confirm() {
  if [ "${OPT_YES:-0}" -eq 1 ]; then
    return 0
  fi
  if [ ! -t 0 ]; then
    die "$EX_USAGE" confirm "no terminal to ask '$1' on; re-run with --yes"
  fi
  printf '%s [y/N] ' "$1" >&2
  read -r cf_answer || return 1
  case "$cf_answer" in
    y | Y) return 0 ;;
    *) return 1 ;;
  esac
}

# --- main ---

# log_config: records the pins and effective options at DEBUG, the first lines of every log
log_config() {
  log DEBUG preflight "pins: ghidra=$PIN_GHIDRA_VERSION topdir=$PIN_GHIDRA_TOPDIR bytes=$PIN_GHIDRA_ZIP_BYTES unpacked_mb=$PIN_GHIDRA_UNPACKED_MB sha256=$PIN_GHIDRA_SHA256"
  log DEBUG preflight "pins: ghidra_url=$PIN_GHIDRA_URL"
  log DEBUG preflight "pins: jdk=$PIN_JDK_MAJOR unpacked_mb=$PIN_JDK_UNPACKED_MB fallback=$PIN_JDK_FALLBACK_RELEASE base=$PIN_JDK_FALLBACK_URL_BASE"
  log DEBUG preflight "pins: jdk_linux_x64=$PIN_JDK_FALLBACK_LINUX_X64 jdk_mac_x64=$PIN_JDK_FALLBACK_MAC_X64"
  log DEBUG preflight "pins: jdk_mac_aarch64=$PIN_JDK_FALLBACK_MAC_AARCH64 jdk_windows_x64=$PIN_JDK_FALLBACK_WINDOWS_X64"
  log DEBUG preflight "pins: repos=$PIN_AGENT_PROFILE_REPO,$PIN_CLAVITY_REPO rea=$PIN_REA_SPEC hosts=$PIN_ALLOWED_HOSTS"
  log DEBUG preflight "exit codes: $EX_OK ok, $EX_STEP step, $EX_USAGE usage, $EX_PLATFORM platform, $EX_PREREQ prereq, $EX_VERIFY verify"
  log DEBUG preflight "options: profile=$OPT_PROFILE folder=$(abbrev_home "$OPT_FOLDER") ghidra_dir=$OPT_GHIDRA_DIR java_home=$OPT_JAVA_HOME"
  log DEBUG preflight "options: tools_dir=$OPT_TOOLS_DIR bin_dir=$OPT_BIN_DIR hopper=$OPT_INSTALL_HOPPER yes=$OPT_YES dry_run=$OPT_DRY_RUN no_launch=$OPT_NO_LAUNCH check_upstream=$OPT_CHECK_UPSTREAM"
}

main() {
  unset UNAME_S UNAME_M
  parse_args "$@"
  CONSOLE_LEVEL=$OPT_CONSOLE_LEVEL
  LOG_FILE=$(log_open)
  log DEBUG preflight "script version $PIN_SCRIPT_VERSION sha256 n/a"
  log DEBUG preflight "$(uname -a)"
  log DEBUG preflight "invoked: $0 $*"
  log_config
  if ! profile_name_valid "$OPT_PROFILE"; then
    die "$EX_USAGE" preflight "invalid profile name: $OPT_PROFILE"
  fi
  platform_detect || die "$EX_PLATFORM" preflight "unsupported platform: $(uname -s) $(uname -m)"
  log INFO preflight "platform: $OS $ARCH"
}

if [ "${REA_SETUP_NO_MAIN:-}" != 1 ]; then
  main "$@"
fi
