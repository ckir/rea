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
TMP_FILES=""

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

# trim_ws_end TEXT / trim_ws TEXT: TEXT without its trailing (and leading) whitespace, CR and newlines included
trim_ws_end() {
  tw_s=$1
  tw_t=${tw_s##*[![:space:]]}
  printf '%s\n' "${tw_s%"$tw_t"}"
}

trim_ws() {
  tw_s=$(trim_ws_end "$1")
  tw_l=${tw_s%%[![:space:]]*}
  printf '%s\n' "${tw_s#"$tw_l"}"
}

# run_cmd STEP cmd...: logs the argument list, exit code and duration; stdout goes to the file named by
# RUN_STDOUT, stderr to the log (bounded to 4000 characters on failure) and its last 1000 bytes to
# RUN_STDERR_TAIL (redacted, cut at a line boundary). RUN_STDOUT is registered for cleanup. Returns the command's exit code.
run_cmd() {
  rc_step=$1
  shift
  RUN_STDOUT=$(mktemp "${TMPDIR:-/tmp}/rea-setup-out.XXXXXX") || return 1
  register_tmp "$RUN_STDOUT"
  rc_nl='
'
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
  # the tail is cut from the redacted end of stderr, so a secret name sliced by the cut cannot leak its value
  rc_win=$(tail -c 20000 "$rc_err")
  rc_win=$(trim_ws_end "$(redact "$rc_win")")
  RUN_STDERR_TAIL=$(trim_ws "$rc_win")
  rc_size=$(printf '%s' "$rc_win" | wc -c | tr -d ' ')
  if [ "$rc_size" -gt 1000 ]; then
    # the last 1000 bytes without their partial first line; one long line has no boundary: its last 1000 bytes
    rc_win=$(printf '%s' "$rc_win" | tail -c 1000)
    rc_rest=""
    case "$rc_win" in
      *"$rc_nl"*) rc_rest=$(trim_ws "${rc_win#*"$rc_nl"}") ;;
    esac
    if [ -n "$rc_rest" ]; then
      RUN_STDERR_TAIL=$rc_rest
    else
      RUN_STDERR_TAIL="...$rc_win"
    fi
  fi
  if [ "$rc" -ne 0 ]; then
    log DEBUG "$rc_step" "stderr: $(head -c 4000 "$rc_err")"
  fi
  rm -f "$rc_err"
  return "$rc"
}

# --- temporary files ---

# register_tmp PATH: remembers PATH (a file or a directory) for cleanup_tmp. One path per line, so a name
# containing a newline is not supported.
register_tmp() {
  TMP_FILES="${TMP_FILES}${TMP_FILES:+
}$1"
}

# cleanup_tmp: removes every registered path; safe to call again, and with an empty list. Later steps that
# create temporary files register them here, and the locks and staging directories are released by
# cleanup_install (called first); nothing adds its own traps.
cleanup_tmp() {
  cleanup_install
  ct_list=$TMP_FILES
  TMP_FILES=""
  [ -n "$ct_list" ] || return 0
  printf '%s\n' "$ct_list" | while IFS= read -r ct_path; do
    if [ -n "$ct_path" ]; then
      rm -rf -- "$ct_path"
    fi
  done
  return 0
}

# install_traps: cleanup on normal exit and on INT and TERM (exit codes 130 and 143)
install_traps() {
  trap cleanup_tmp EXIT
  trap 'cleanup_tmp; exit 130' INT
  trap 'cleanup_tmp; exit 143' TERM
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

# redact TEXT: hides secrets in a log message, line by line (POSIX ERE, sed under LC_ALL=C so that an invalid
# multibyte sequence cannot stop a match and leave the rest of the line in clear; names are matched case-insensitively
# with explicit letter classes, since there is no portable I flag). In this order:
#   URL userinfo and query; AUTHORIZATION=value to the end of the line; NAME = value (optional spaces around the
#   equals sign, quoted values consumed whole); "NAME": value in JSON form (strings with
#   escaped quotes, numbers, true, false, null); NAME: value to the end of the line (headers). NAME contains
#   TOKEN, KEY, SECRET or PASSWORD, and for the JSON and colon forms also AUTHORIZATION. setup.ps1 Hide-ReaSecret
#   does the same; tests/fixtures/redact-corpus.txt pins both. A JSON value that is an object or an array is
#   left alone.
redact() {
  rd_q="'"
  rd_bs=\\\\
  rd_names='[Tt][Oo][Kk][Ee][Nn]|[Kk][Ee][Yy]|[Ss][Ee][Cc][Rr][Ee][Tt]|[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]'
  rd_auth='[Aa][Uu][Tt][Hh][Oo][Rr][Ii][Zz][Aa][Tt][Ii][Oo][Nn]'
  rd_all="$rd_names|$rd_auth"
  rd_key="\"[A-Za-z0-9_.-]*($rd_all)[A-Za-z0-9_.-]*\"[ ]*:[ ]*"
  printf '%s\n' "$1" | LC_ALL=C sed -E \
    -e 's#(https?://)[^/@ ]*@#\1#g' \
    -e 's#(https?://[^ ?]*)\?[^ ]*#\1#g' \
    -e "s/([A-Za-z0-9_-]*($rd_auth)[A-Za-z0-9_-]*[ ]*=[ ]*).*/\\1<redacted>/" \
    -e "s/([A-Za-z0-9_]*($rd_names)[A-Za-z0-9_]*[ ]*=[ ]*)(\"[^\"]*\"[^ ]*|${rd_q}[^${rd_q}]*${rd_q}[^ ]*|[^ ]*)/\\1<redacted>/g" \
    -e "s/($rd_key)\"([^\"$rd_bs]|$rd_bs.)*\"?/\\1\"<redacted>\"/g" \
    -e "s/($rd_key)[A-Za-z0-9_.+-]+/\\1<redacted>/g" \
    -e "s/([A-Za-z0-9_-]*($rd_all)[A-Za-z0-9_-]*[ ]*:)[ ]*.*/\\1 <redacted>/"
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

# abs_path PATH: PATH made absolute against the current directory, without resolving symlinks; '' stays ''
abs_path() {
  case "$1" in
    '' | /*) printf '%s\n' "$1" ;;
    .) printf '%s\n' "$PWD" ;;
    ./*) abs_path "${1#./}" ;;
    *) printf '%s/%s\n' "$PWD" "$1" ;;
  esac
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
  # The paths are recorded in the profile, env.sh and the printed commands, which run elsewhere: make them absolute now
  OPT_FOLDER=$(abs_path "$OPT_FOLDER")
  OPT_GHIDRA_DIR=$(abs_path "$OPT_GHIDRA_DIR")
  OPT_JAVA_HOME=$(abs_path "$OPT_JAVA_HOME")
  OPT_TOOLS_DIR=$(abs_path "$OPT_TOOLS_DIR")
  OPT_BIN_DIR=$(abs_path "$OPT_BIN_DIR")
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

# --- network ---

ALLOWED_SCHEMES=https
ALLOWED_HOSTS=$PIN_ALLOWED_HOSTS
RETRY_WAITS="2 4 8 16"
CURL="curl"
SLEEP="sleep"

# url_scheme URL: the lower-cased scheme; fails when there is no scheme://
url_scheme() {
  case "$1" in
    *://*) printf '%s\n' "${1%%://*}" | tr '[:upper:]' '[:lower:]' ;;
    *) return 1 ;;
  esac
}

# url_authority URL: everything between scheme:// and the first / ? or #
url_authority() {
  ua_rest=${1#*://}
  printf '%s\n' "${ua_rest%%[/?#]*}"
}

# url_host URL: the lower-cased host, without any userinfo or port
url_host() {
  uh_auth=$(url_authority "$1")
  uh_auth=${uh_auth##*@}
  printf '%s\n' "${uh_auth%%:*}" | tr '[:upper:]' '[:lower:]'
}

# url_allowed URL: 0 when the scheme is in ALLOWED_SCHEMES, the host in ALLOWED_HOSTS and the authority
# carries no userinfo; whitespace and backslashes are refused outright
url_allowed() {
  case "$1" in
    *[[:space:]\\]*) return 1 ;;
  esac
  ual_scheme=$(url_scheme "$1") || return 1
  ual_ok=1
  for ual_s in $ALLOWED_SCHEMES; do
    if [ "$ual_s" = "$ual_scheme" ]; then
      ual_ok=0
    fi
  done
  [ "$ual_ok" -eq 0 ] || return 1
  case "$(url_authority "$1")" in
    *@*) return 1 ;;
  esac
  ual_host=$(url_host "$1")
  for ual_h in $ALLOWED_HOSTS; do
    if [ "$ual_h" = "$ual_host" ]; then
      return 0
    fi
  done
  return 1
}

# url_path_safe URL: 1 when the URL has a dot-dot path segment (plain or percent-encoded) or a backslash
url_path_safe() {
  case "$1" in
    */../* | */.. | */..\?* | *%2[eE]* | *\\*) return 1 ;;
  esac
  return 0
}

# net_proto: the value for curl --proto, https only unless ALLOWED_SCHEMES lists http (tests)
net_proto() {
  case " $ALLOWED_SCHEMES " in
    *" http "*) echo '=https,http' ;;
    *) echo '=https' ;;
  esac
}

# probe_retry URL [CURL_ARG...]: one metadata request (no body is written) with the retries http_get has: 5xx,
# 429 and curl exits 6 7 28 35 52 56 are retried after the pauses in RETRY_WAITS; anything else stops at once.
# Sets PR_RESP to "<http code> <redirect url>" ("000 " when curl failed). curl's exit code and the first line
# of its stderr go to the DEBUG log. -q is first so a ~/.curlrc (location, insecure...) cannot change the policy.
probe_retry() {
  pr_url=$1
  shift
  PR_RESP="000 "
  pr_err=$(mktemp "${TMPDIR:-/tmp}/rea-setup-err.XXXXXX") || return 1
  register_tmp "$pr_err"
  pr_total=0
  for pr_w in $RETRY_WAITS; do
    [ -n "$pr_w" ] && pr_total=$((pr_total + 1))
  done
  pr_attempt=0
  for pr_wait in $RETRY_WAITS; do
    pr_attempt=$((pr_attempt + 1))
    pr_rc=0
    PR_RESP=$("$CURL" -q -sS "$@" -o /dev/null -w '%{http_code} %{redirect_url}' --proto "$(net_proto)" --tlsv1.2 \
      --connect-timeout 20 --max-time 60 "$pr_url" 2>"$pr_err") || pr_rc=$?
    if [ "$pr_rc" -ne 0 ]; then
      PR_RESP="000 "
      log DEBUG net "curl exit $pr_rc for $pr_url (attempt $pr_attempt of $pr_total): $(head -n 1 "$pr_err" | head -c 300)"
    fi
    pr_retry=0
    if [ "$pr_rc" -eq 0 ]; then
      case "${PR_RESP%% *}" in
        5?? | 429) pr_retry=1 ;;
      esac
    else
      case "$pr_rc" in
        6 | 7 | 28 | 35 | 52 | 56) pr_retry=1 ;;
      esac
    fi
    [ "$pr_retry" -eq 1 ] || break
    [ "$pr_attempt" -lt "$pr_total" ] || break
    log DEBUG net "retrying in ${pr_wait}s"
    "$SLEEP" "$pr_wait"
  done
  rm -f "$pr_err"
  return 0
}

# resolve_redirects URL: prints the final URL after at most 5 redirects, using HEAD (no body is fetched).
# A hop answering 405 or 403 to HEAD is asked again with a one-byte ranged GET. Every hop must pass
# url_allowed and is retried like http_get retries. Returns 1 for a disallowed hop, 2 for more than 5
# redirects, 3 for any other failure.
resolve_redirects() {
  rr_url=$1
  rr_hops=0
  while :; do
    url_allowed "$rr_url" || {
      log ERROR net "redirect target not allowed: $rr_url"
      return 1
    }
    probe_retry "$rr_url" -I
    rr_resp=$PR_RESP
    case "$rr_resp" in
      403* | 405*)
        probe_retry "$rr_url" -r 0-0
        rr_resp=$PR_RESP
        ;;
    esac
    rr_code=${rr_resp%% *}
    rr_next=${rr_resp#* }
    log DEBUG net "HEAD $rr_url -> $rr_code"
    case "$rr_code" in
      2??)
        printf '%s\n' "$rr_url"
        return 0
        ;;
      3??)
        if [ -z "$rr_next" ]; then
          return 3
        fi
        rr_hops=$((rr_hops + 1))
        if [ "$rr_hops" -gt 5 ]; then
          log ERROR net "more than 5 redirects from $1"
          return 2
        fi
        rr_url=$rr_next
        ;;
      *) return 3 ;;
    esac
  done
}

# http_get URL DEST [EXTRA_CURL_ARGS...]: GET into DEST with retries. 2xx returns 0; 5xx, 429 and curl exits
# 6 7 28 35 52 56 are retried (RETRY_WAITS gives the pause before each retry, so it also sets the number of
# attempts; Retry-After raises the pause); any other failure returns 1 at once. GITHUB_TOKEN goes to
# api.github.com only, through a private curl config file so it is neither on a command line nor in the log.
http_get() {
  hg_url=$1
  hg_dest=$2
  shift 2
  url_allowed "$hg_url" || {
    log ERROR net "URL not allowed: $hg_url"
    return 1
  }
  hg_hdr=$(mktemp "${TMPDIR:-/tmp}/rea-setup-hdr.XXXXXX") || return 1
  register_tmp "$hg_hdr"
  hg_cfg=$(mktemp "${TMPDIR:-/tmp}/rea-setup-cfg.XXXXXX") || {
    rm -f "$hg_hdr"
    return 1
  }
  register_tmp "$hg_cfg"
  hg_err=$(mktemp "${TMPDIR:-/tmp}/rea-setup-err.XXXXXX") || {
    rm -f "$hg_hdr" "$hg_cfg"
    return 1
  }
  register_tmp "$hg_err"
  if [ -n "${GITHUB_TOKEN:-}" ] && [ "$(url_host "$hg_url")" = api.github.com ]; then
    case "$GITHUB_TOKEN" in
      *[!A-Za-z0-9_.-]*) log WARN net "GITHUB_TOKEN ignored: unexpected characters" ;;
      *) printf 'header = "Authorization: Bearer %s"\n' "$GITHUB_TOKEN" >"$hg_cfg" ;;
    esac
  fi
  hg_total=0
  for hg_w in $RETRY_WAITS; do
    [ -n "$hg_w" ] && hg_total=$((hg_total + 1))
  done
  hg_attempt=0
  hg_result=1
  for hg_wait in $RETRY_WAITS; do
    hg_attempt=$((hg_attempt + 1))
    hg_rc=0
    : >"$hg_hdr"
    hg_code=$("$CURL" -q -sS -K "$hg_cfg" --proto "$(net_proto)" --tlsv1.2 --speed-limit 1024 --speed-time 60 \
      --connect-timeout 20 -D "$hg_hdr" -o "$hg_dest" -w '%{http_code}' "$@" "$hg_url" 2>"$hg_err") || hg_rc=$?
    log DEBUG net "GET $hg_url -> ${hg_code:-000} (curl exit $hg_rc, attempt $hg_attempt of $hg_total)"
    if [ "$hg_rc" -ne 0 ]; then
      log DEBUG net "curl: $(head -c 500 "$hg_err")"
    fi
    hg_retry=0
    if [ "$hg_rc" -eq 0 ]; then
      case "$hg_code" in
        2??)
          hg_result=0
          break
          ;;
        5?? | 429) hg_retry=1 ;;
        *) break ;;
      esac
    else
      case "$hg_rc" in
        6 | 7 | 28 | 35 | 52 | 56) hg_retry=1 ;;
        *) break ;;
      esac
    fi
    [ "$hg_retry" -eq 1 ] || break
    [ "$hg_attempt" -lt "$hg_total" ] || break
    hg_ra=$(sed -n 's/^[Rr][Ee][Tt][Rr][Yy]-[Aa][Ff][Tt][Ee][Rr]:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$hg_hdr" | tail -n 1)
    if [ "${#hg_ra}" -gt 6 ]; then
      hg_ra=""
    fi
    if [ -n "$hg_ra" ] && [ "$hg_ra" -gt "$hg_wait" ] 2>/dev/null; then
      hg_wait=$hg_ra
    fi
    if [ "$hg_wait" -gt 120 ]; then
      hg_wait=120
    fi
    log DEBUG net "retrying in ${hg_wait}s"
    "$SLEEP" "$hg_wait"
  done
  rm -f "$hg_hdr" "$hg_cfg" "$hg_err"
  if [ "$hg_result" -ne 0 ]; then
    rm -f "$hg_dest"
    log ERROR net "GET failed: $hg_url"
  fi
  return "$hg_result"
}

# sha256_file FILE: prints the lower-case hex digest
sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d ' ' -f 1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | cut -d ' ' -f 1
  else
    log ERROR net "neither sha256sum nor shasum is available"
    return 1
  fi
}

# sidecar_sha256 FILE: prints the first 64-hex token of a .sha256 sidecar, lower-cased (sha256sum, shasum
# and PowerShell layouts); fails when there is none
sidecar_sha256() {
  ss_hash=$(sed -n -E 's/^[[:space:]]*([0-9A-Fa-f]{64})([^0-9A-Fa-f].*)?$/\1/p' "$1" | head -n 1 | tr '[:upper:]' '[:lower:]')
  [ -n "$ss_hash" ] || return 1
  printf '%s\n' "$ss_hash"
}

# download_verified URL DEST SHA256: resolves redirects, downloads to DEST.tmp.$$, checks the digest
# (case-insensitive) and only then moves the file to DEST. Returns 1 on any failure, leaving nothing behind.
download_verified() {
  dv_final=$(resolve_redirects "$1") || {
    log ERROR net "cannot resolve $1"
    return 1
  }
  dv_tmp="$2.tmp.$$"
  register_tmp "$dv_tmp"
  http_get "$dv_final" "$dv_tmp" || {
    rm -f "$dv_tmp"
    return 1
  }
  dv_got=$(sha256_file "$dv_tmp") || {
    rm -f "$dv_tmp"
    return 1
  }
  dv_want=$(printf '%s' "$3" | tr '[:upper:]' '[:lower:]')
  if [ "$dv_got" != "$dv_want" ]; then
    log ERROR net "checksum mismatch for $1: expected $dv_want got $dv_got"
    rm -f "$dv_tmp"
    return 1
  fi
  mv -f "$dv_tmp" "$2"
}

# json_query FILE JS: applies the JavaScript expression JS (a literal from this script, never data) to the
# parsed JSON of FILE as `d` and prints the result; arrays one element per line, null and undefined as empty.
# The expression travels as an argument, so quoting cannot break the program. The last two arguments are
# read, so it does not matter whether this node keeps the -- in process.argv.
json_query() {
  node -e 'const a=process.argv.slice(-2);const d=JSON.parse(require("fs").readFileSync(a[0],"utf8"));let r=new Function("d","return ("+a[1]+")")(d);if(r===null||r===undefined)r="";if(Array.isArray(r))r=r.join("\n");process.stdout.write(String(r)+"\n")' -- "$1" "$2"
}

# github_latest_tag REPO: the tag of the latest release, from the redirect of /releases/latest
github_latest_tag() {
  gl_url="https://github.com/$1/releases/latest"
  url_allowed "$gl_url" || return 1
  probe_retry "$gl_url" -I
  gl_loc=${PR_RESP#* }
  log DEBUG net "latest release of $1 -> $gl_loc"
  case "$gl_loc" in
    */releases/tag/?*) gl_tag=${gl_loc##*/} ;;
    *) return 1 ;;
  esac
  # the tag is spliced into later URLs: letters, digits and . _ + - only, never a dot segment
  case "$gl_tag" in
    '' | .* | *[!A-Za-z0-9._+-]*) return 1 ;;
  esac
  printf '%s\n' "$gl_tag"
}

# github_release_assets REPO: the asset names of the latest release, one per line, from the API
github_release_assets() {
  gr_tmp=$(mktemp "${TMPDIR:-/tmp}/rea-setup-json.XXXXXX") || return 1
  if http_get "https://api.github.com/repos/$1/releases/latest" "$gr_tmp"; then
    gr_rc=0
    json_query "$gr_tmp" '(d.assets||[]).map(a=>a.name)' || gr_rc=1
  else
    gr_rc=1
  fi
  rm -f "$gr_tmp"
  return "$gr_rc"
}

# github_release_assets_scrape REPO TAG: the asset names of a release, from the HTML of its expanded_assets
# page; the fallback for when the API is rate-limited
github_release_assets_scrape() {
  gs_tmp=$(mktemp "${TMPDIR:-/tmp}/rea-setup-html.XXXXXX") || return 1
  if http_get "https://github.com/$1/releases/expanded_assets/$2" "$gs_tmp"; then
    grep -Eo '/[^"<> ]+/releases/download/[^"<> ]+' "$gs_tmp" | grep -F "/$1/releases/download/$2/" | sed 's#.*/##' | sort -u
    gs_rc=0
  else
    gs_rc=1
  fi
  rm -f "$gs_tmp"
  return "$gs_rc"
}

# jdk_release_valid TAG: 0 when TAG is a Temurin 21 release name such as jdk-21.0.13+9
jdk_release_valid() {
  printf '%s\n' "$1" | grep -Eq '^jdk-21(\.[0-9]+)*\+[0-9]+$'
}

# adoptium_parse FILE: reads the first asset of an Adoptium response and sets JDK_RELEASE, JDK_URL,
# JDK_SHA256, JDK_SIDECAR_URL and JDK_BYTES. Returns 1 unless the release name, the download link (host
# github.com, path /adoptium/temurin21-binaries/), the sidecar link and the checksum all pass.
adoptium_parse() {
  ap_vals=$(json_query "$1" '[d[0].release_name, d[0].binary.package.link, d[0].binary.package.checksum, d[0].binary.package.checksum_link, d[0].binary.package.size]') || return 1
  JDK_RELEASE=$(printf '%s\n' "$ap_vals" | sed -n 1p)
  JDK_URL=$(printf '%s\n' "$ap_vals" | sed -n 2p)
  JDK_SHA256=$(printf '%s\n' "$ap_vals" | sed -n 3p | tr '[:upper:]' '[:lower:]')
  JDK_SIDECAR_URL=$(printf '%s\n' "$ap_vals" | sed -n 4p)
  JDK_BYTES=$(printf '%s\n' "$ap_vals" | sed -n 5p)
  jdk_release_valid "$JDK_RELEASE" || {
    log ERROR net "unexpected JDK release name: $JDK_RELEASE"
    return 1
  }
  url_allowed "$JDK_URL" || return 1
  url_path_safe "$JDK_URL" || {
    log ERROR net "unexpected JDK download path: $JDK_URL"
    return 1
  }
  [ "$(url_host "$JDK_URL")" = github.com ] || return 1
  case "${JDK_URL#*://*/}" in
    adoptium/temurin21-binaries/?*) ;;
    *)
      log ERROR net "unexpected JDK download path: $JDK_URL"
      return 1
      ;;
  esac
  printf '%s\n' "$JDK_SHA256" | grep -Eq '^[0-9a-f]{64}$' || return 1
  printf '%s\n' "$JDK_BYTES" | grep -Eq '^[0-9]+$' || return 1
  if [ -n "$JDK_SIDECAR_URL" ]; then
    url_allowed "$JDK_SIDECAR_URL" || return 1
    url_path_safe "$JDK_SIDECAR_URL" || return 1
  fi
  return 0
}

# adoptium_resolve OS ARCH: asks the Adoptium API for the latest Temurin 21 JDK and parses it. Returns 2
# when the API cannot be reached (the caller uses the fallback pin) and 1 when the answer fails validation.
adoptium_resolve() {
  ar_tmp=$(mktemp "${TMPDIR:-/tmp}/rea-setup-json.XXXXXX") || return 2
  if ! http_get "https://api.adoptium.net/v3/assets/latest/21/hotspot?architecture=$2&image_type=jdk&os=$1&vendor=eclipse" "$ar_tmp"; then
    rm -f "$ar_tmp"
    return 2
  fi
  ar_rc=0
  adoptium_parse "$ar_tmp" || ar_rc=1
  rm -f "$ar_tmp"
  return "$ar_rc"
}

# --- files, locks, archives and staging ---

NL='
'
LOCK_HELD=""
STAGING_DIRS=""

# tools_dir_default / bin_dir_default: where the JDK and Ghidra go, and where the launchers go
tools_dir_default() {
  printf '%s\n' "${OPT_TOOLS_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/rea-tools}"
}

bin_dir_default() {
  printf '%s\n' "${OPT_BIN_DIR:-$HOME/.local/bin}"
}

# pid_alive PID: 0 when the process exists. kill -0 fails for another user's process, so ps -p decides then.
pid_alive() {
  case "$1" in
    '' | *[!0-9]*) return 1 ;;
  esac
  kill -0 "$1" 2>/dev/null && return 0
  ps -p "$1" >/dev/null 2>&1
}

# older_than_min PATH MINUTES: 0 when PATH's modification time is more than MINUTES minutes ago
older_than_min() {
  [ -n "$(find "$1" -maxdepth 0 -mmin "+$2" 2>/dev/null)" ]
}

# list_has LIST ITEM: 0 when the newline-separated LIST contains ITEM exactly
list_has() {
  case "$NL$1$NL" in
    *"$NL$2$NL"*) return 0 ;;
  esac
  return 1
}

# lock_owner_pid DIR: the pid recorded in DIR/.lock/owner, or nothing
lock_owner_pid() {
  sed -n 's/^pid=\([0-9][0-9]*\).*/\1/p' "$1/.lock/owner" 2>/dev/null | head -n 1
}

# lock_acquire DIR: takes DIR/.lock (mkdir is atomic) and records pid and start time in DIR/.lock/owner. A
# lock whose owner is dead (or that has no owner file and is over a minute old) is taken over with a WARN. A
# live owner is waited for, 2 s per poll, up to LOCK_POLLS polls (default 60), then the step fails. Taking the
# same lock twice in one process is a no-op. The release is lock_release, or cleanup_install on any exit.
lock_acquire() {
  la_dir=$1
  la_polls=0
  if list_has "$LOCK_HELD" "$la_dir"; then
    return 0
  fi
  mkdir -p -- "$la_dir" || die "$EX_STEP" tools-bin "cannot create directory: $la_dir"
  while :; do
    if mkdir -- "$la_dir/.lock" 2>/dev/null; then
      printf 'pid=%s started=%s\n' "$$" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$la_dir/.lock/owner" 2>/dev/null || true
      LOCK_HELD="${LOCK_HELD}${LOCK_HELD:+$NL}$la_dir"
      return 0
    fi
    [ -d "$la_dir/.lock" ] || die "$EX_STEP" tools-bin "cannot create lock: $la_dir/.lock"
    la_pid=$(lock_owner_pid "$la_dir")
    la_stale=0
    if [ -n "$la_pid" ]; then
      pid_alive "$la_pid" || la_stale=1
    elif older_than_min "$la_dir/.lock" 1; then
      la_stale=1
    fi
    if [ "$la_stale" -eq 1 ]; then
      # Move the lock aside (atomic) only while its owner is still the one judged dead; a failed move means
      # another process took it over first, so fall through to normal polling. Never rm the live name.
      la_aside="$la_dir/.lock.stale.$$"
      rm -rf -- "$la_aside"
      if [ "$(lock_owner_pid "$la_dir")" = "$la_pid" ] && mv -- "$la_dir/.lock" "$la_aside" 2>/dev/null; then
        if [ "$(sed -n 's/^pid=\([0-9][0-9]*\).*/\1/p' "$la_aside/owner" 2>/dev/null | head -n 1)" = "$la_pid" ]; then
          log WARN tools-bin "stale lock from pid ${la_pid:-unknown} taken over: $la_dir/.lock"
          rm -rf -- "$la_aside"
        elif [ ! -e "$la_dir/.lock" ]; then
          # We moved a lock that changed owner between the check and the move: put it back.
          mv -- "$la_aside" "$la_dir/.lock" 2>/dev/null || rm -rf -- "$la_aside"
        else
          rm -rf -- "$la_aside"
        fi
        continue
      fi
    fi
    la_polls=$((la_polls + 1))
    if [ "$la_polls" -ge "${LOCK_POLLS:-60}" ]; then
      die "$EX_STEP" tools-bin "lock held by pid ${la_pid:-unknown}: $la_dir/.lock"
    fi
    sleep 2
  done
}

# lock_release DIR: removes DIR/.lock when this process holds it; otherwise does nothing
lock_release() {
  list_has "$LOCK_HELD" "$1" || return 0
  rm -rf -- "$1/.lock"
  lr_rest=""
  while IFS= read -r lr_d; do
    if [ -n "$lr_d" ] && [ "$lr_d" != "$1" ]; then
      lr_rest="${lr_rest}${lr_rest:+$NL}$lr_d"
    fi
  done <<EOF
$LOCK_HELD
EOF
  LOCK_HELD=$lr_rest
  return 0
}

# cleanup_install: called by cleanup_tmp (the one trap mechanism). Removes the staging directories this
# process made, and what it left beside them (*.tmp.$$ and *.old.$$ in every directory it holds a lock on:
# a staging_new inside $(...) runs in a subshell and cannot add itself to STAGING_DIRS, but its name always
# ends in this process's $$), then releases the locks.
cleanup_install() {
  ci_stage=$STAGING_DIRS
  ci_locks=$LOCK_HELD
  STAGING_DIRS=""
  LOCK_HELD=""
  if [ -n "$ci_stage" ]; then
    printf '%s\n' "$ci_stage" | while IFS= read -r ci_path; do
      if [ -n "$ci_path" ]; then
        rm -rf -- "$ci_path"
      fi
    done
  fi
  if [ -n "$ci_locks" ]; then
    printf '%s\n' "$ci_locks" | while IFS= read -r ci_dir; do
      if [ -n "$ci_dir" ]; then
        for ci_path in "$ci_dir"/*.tmp."$$" "$ci_dir"/*.old."$$" "$ci_dir"/.lock.stale."$$"; do
          if [ -e "$ci_path" ] || [ -L "$ci_path" ]; then
            rm -rf -- "$ci_path"
          fi
        done
        rm -rf -- "$ci_dir/.lock"
      fi
    done
  fi
  return 0
}

# cleanup_orphans DIR: removes DIR/<name>.tmp.PID and DIR/<name>.old.PID (also the Windows script's leftovers)
# whose process is gone or whose modification time is over 24 hours old; logs each. Only the names this script
# creates are considered (agent-profile*, clavity-ls*, jdk-<digit>*, ghidra.work, ghidra_<digit>*, env.*): the
# bin dir is shared with other tools and the tools dir may hold a user's own files.
cleanup_orphans() {
  co_dir=$1
  for co_pat in 'agent-profile*' 'clavity-ls*' 'jdk-[0-9]*' 'ghidra.work' 'ghidra_[0-9]*' 'env.*'; do
    for co_path in "$co_dir"/$co_pat.tmp.* "$co_dir"/$co_pat.old.*; do
      if [ ! -e "$co_path" ] && [ ! -L "$co_path" ]; then
        continue
      fi
      co_pid=${co_path##*.}
      case "$co_pid" in
        '' | *[!0-9]*) continue ;;
      esac
      if ! pid_alive "$co_pid"; then
        co_why="pid $co_pid is not running"
      elif older_than_min "$co_path" 1440; then
        co_why="older than 24 hours"
      else
        continue
      fi
      log INFO cleanup "removing orphan ($co_why): $co_path"
      rm -rf -- "$co_path" || log WARN cleanup "could not remove orphan: $co_path"
    done
  done
  return 0
}

# disk_free_mb PATH: free megabytes on the filesystem holding PATH (the nearest existing parent when PATH
# does not exist yet)
disk_free_mb() {
  df_path=$1
  while [ ! -d "$df_path" ]; do
    case "$df_path" in
      */*) df_path=${df_path%/*} ;;
      *) df_path=. ;;
    esac
    [ -n "$df_path" ] || df_path=/
  done
  df -Pm "$df_path" | awk 'NR == 2 { print $4 }'
}

# require_free_mb PATH MB: dies EX_STEP with the shortfall when PATH has less than MB megabytes free
require_free_mb() {
  rf_have=$(disk_free_mb "$1")
  case "$rf_have" in
    '' | *[!0-9]*) die "$EX_STEP" disk "cannot determine the free space at: $1" ;;
  esac
  if [ "$rf_have" -lt "$2" ]; then
    die "$EX_STEP" disk "not enough free space at $1: need $2 MB, have $rf_have MB (short by $(($2 - rf_have)) MB)"
  fi
  return 0
}

# archive_tool_for ZIP: prints unzip, bsdtar or jar (the first available); ARCHIVE_ZIP_TOOL forces one (tests)
archive_tool_for() {
  if [ -n "${ARCHIVE_ZIP_TOOL:-}" ]; then
    printf '%s\n' "$ARCHIVE_ZIP_TOOL"
    return 0
  fi
  if command -v unzip >/dev/null 2>&1; then
    echo unzip
  elif command -v bsdtar >/dev/null 2>&1; then
    echo bsdtar
  elif [ -x "${JAVA_HOME_SELECTED:-/nonexistent}/bin/jar" ]; then
    echo jar
  else
    return 1
  fi
}

# archive_tarlike_normalise: stdin is `tar -tvf` output (GNU or bsdtar), stdout is `MODE TYPE PATH [-> TARGET]`
# lines. Exit 1 on a line it cannot parse, so a name holding a newline cannot slip through.
archive_tarlike_normalise() {
  awk '
    function skip(line, n,   i) {
      for (i = 0; i < n; i++) { sub(/^[ \t]*[^ \t]+/, "", line) }
      sub(/^[ \t]+/, "", line)
      return line
    }
    function cnt(s, t,   n, i) {
      n = 0
      while ((i = index(s, t)) > 0) { n++; s = substr(s, i + length(t)) }
      return n
    }
    {
      if ($1 !~ /^[-dlhcbps][-rwxsStTlL.+@]+$/) { bad = 1; exit }
      mode = $1
      if ($4 ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) { rest = skip($0, 5) } else { rest = skip($0, 8) }
      t = substr(mode, 1, 1)
      if (t == "-") { t = "f" }
      if (t == "h" || t == "l") {
        sep = (t == "h" && cnt(rest, " link to ") > 0) ? " link to " : " -> "
        if (cnt(rest, sep) != 1) { bad = 1; exit }
        i = index(rest, sep)
        rest = substr(rest, 1, i - 1) " -> " substr(rest, i + length(sep))
      }
      print mode " " t " " rest
    }
    END { if (bad) { exit 1 } }
  '
}

# archive_list FILE: prints one `MODE TYPE PATH [-> TARGET]` line per entry. TYPE is f, d, l (symlink), h
# (hardlink, TARGET is a member path) or ? (unknown: jar lists names only, MODE is then ?). Tar archives use
# `tar -tvf` (GNU or bsdtar; stdout only), zips use `unzip -Z`, else `bsdtar -tvf`, else `jar tf`. Every tool
# writes to a temp file first so its exit status is not hidden by a pipeline. Fails when the archive cannot be
# listed, a record cannot be parsed, or the listing is empty (an archive with no entries is not an install
# archive).
archive_list() {
  al_file=$1
  al_raw=$(mktemp "${TMPDIR:-/tmp}/rea-setup-al.XXXXXX") || return 1
  register_tmp "$al_raw"
  register_tmp "$al_raw.t"
  register_tmp "$al_raw.z"
  register_tmp "$al_raw.n"
  al_rc=0
  case "$al_file" in
    *.zip | *.ZIP)
      al_tool=$(archive_tool_for "$al_file") || al_tool=""
      case "$al_tool" in
        unzip) archive_list_unzip "$al_file" "$al_raw" || al_rc=1 ;;
        bsdtar)
          bsdtar -tvf "$al_file" >"$al_raw.t" 2>/dev/null || al_rc=1
          if [ "$al_rc" -eq 0 ]; then
            archive_tarlike_normalise <"$al_raw.t" >"$al_raw" || al_rc=1
          fi
          ;;
        jar)
          "$JAVA_HOME_SELECTED/bin/jar" tf "$al_file" >"$al_raw.t" 2>/dev/null || al_rc=1
          if [ "$al_rc" -eq 0 ]; then
            sed -e 's/^/? ? /' <"$al_raw.t" >"$al_raw" || al_rc=1
          fi
          ;;
        *) al_rc=1 ;;
      esac
      ;;
    *)
      "${ARCHIVE_TAR:-tar}" -tvf "$al_file" >"$al_raw.t" 2>/dev/null || al_rc=1
      if [ "$al_rc" -eq 0 ]; then
        archive_tarlike_normalise <"$al_raw.t" >"$al_raw" || al_rc=1
      fi
      ;;
  esac
  if [ "$al_rc" -eq 0 ] && [ ! -s "$al_raw" ]; then
    al_rc=1
  fi
  if [ "$al_rc" -eq 0 ]; then
    cat "$al_raw"
  fi
  rm -f "$al_raw" "$al_raw.t" "$al_raw.z" "$al_raw.n"
  return "$al_rc"
}

# archive_list_unzip ZIP OUT: normalised listing via unzip -Z. Every line must be the header, the footer or a
# parsable record, and the number of records must equal the `number of entries` in the header; anything else
# fails. A record with no file-type bit (mode ?rw-------) is listed as a regular file, so its path is still
# checked. unzip does not show a symlink's target, so it is read from the entry itself.
archive_list_unzip() {
  unzip -Z "$1" 2>/dev/null >"$2.z" || return 1
  awk '
    function skip(line, n,   i) {
      for (i = 0; i < n; i++) { sub(/^[ \t]*[^ \t]+/, "", line) }
      sub(/^[ \t]+/, "", line)
      return line
    }
    /^Archive:/ { next }
    /^Zip file size:/ {
      if (match($0, /number of entries: [0-9]+/) == 0) { bad = 1; exit }
      want = substr($0, RSTART + 19, RLENGTH - 19) + 0
      have_header = 1
      next
    }
    /^[0-9]+ files?, / { next }
    {
      if ($1 !~ /^[-dlcbps?][-rwxsStTa?]+$/ || NF < 9) { bad = 1; exit }
      t = substr($1, 1, 1)
      if (t == "-" || t == "?") { t = "f" }
      print $1 " " t " " skip($0, 8)
      n++
    }
    END { if (bad || !have_header || n != want) { exit 1 } }
  ' "$2.z" >"$2.n" || return 1
  : >"$2"
  while IFS= read -r alu_line; do
    alu_rest=${alu_line#* }
    case "$alu_rest" in
      l\ *)
        alu_name=${alu_rest#l }
        alu_pat=$(printf '%s' "$alu_name" | sed -e 's/[][\\*?]/\\&/g')
        alu_target=$(unzip -p "$1" "$alu_pat" 2>/dev/null | head -c 4096 | tr '\n' '/')
        printf '%s -> %s\n' "$alu_line" "$alu_target" >>"$2"
        ;;
      *) printf '%s\n' "$alu_line" >>"$2" ;;
    esac
  done <"$2.n"
  return 0
}

# archive_check_lines: reads normalised listing lines on stdin; exit 1, naming the first offending entry on
# stderr via log, when any path is absolute (leading / or a drive letter), has a .. component (a backslash
# counts as a separator), traverses a symlink made earlier or later in the same archive, or is a link whose
# target leaves the archive root (a symlink target is resolved from the link's directory; a .. after a normal
# component is refused outright, since it cannot be resolved without the filesystem).
archive_check_lines() {
  acl_out=$(awk '
    function norm(p) { gsub(/\\/, "/", p); return p }
    function absolute(p) { return (p ~ /^\// || p ~ /^[A-Za-z]:/) }
    function dotdot(p,   n, a, i) {
      n = split(p, a, "/")
      for (i = 1; i <= n; i++) { if (a[i] == "..") { return 1 } }
      return 0
    }
    function canon(p,   n, a, i, r) {
      n = split(p, a, "/")
      r = ""
      for (i = 1; i <= n; i++) { if (a[i] != "" && a[i] != ".") { r = r (r == "" ? "" : "/") a[i] } }
      return r
    }
    function escapes(dir, tgt,   n, a, i, depth, seen) {
      if (absolute(tgt)) { return 1 }
      depth = 0
      n = split(dir, a, "/")
      for (i = 1; i <= n; i++) { if (a[i] != "" && a[i] != ".") { depth++ } }
      seen = 0
      n = split(tgt, a, "/")
      for (i = 1; i <= n; i++) {
        if (a[i] == "" || a[i] == ".") { continue }
        if (a[i] == "..") {
          if (seen) { return 1 }
          depth--
          if (depth < 0) { return 1 }
        } else { seen = 1 }
      }
      return 0
    }
    {
      line = $0
      m = match(line, /^[^ ]+ [^ ]+ /)
      if (m == 0) { next }
      type[NR] = substr(line, RSTART + length($1) + 1, 1)
      rest = substr(line, RLENGTH + 1)
      tgt[NR] = ""
      if (type[NR] == "l" || type[NR] == "h") {
        i = index(rest, " -> ")
        if (i == 0) { path[NR] = rest; amb[NR] = 1 } else {
          tgt[NR] = substr(rest, i + 4)
          rest = substr(rest, 1, i - 1)
          if (index(tgt[NR], " -> ") > 0) { amb[NR] = 1 }
        }
      }
      path[NR] = norm(rest)
      tgt[NR] = norm(tgt[NR])
      if (type[NR] == "l") { sym[canon(path[NR])] = 1 }
      last = NR
    }
    END {
      for (k = 1; k <= last; k++) {
        if (!(k in path)) { continue }
        p = path[k]
        why = ""
        if (absolute(p)) { why = "absolute path" }
        else if (dotdot(p)) { why = "parent-directory component" }
        else if (amb[k]) { why = "ambiguous link entry" }
        else if (type[k] == "l") {
          d = p
          if (sub(/\/[^\/]*\/?$/, "", d) == 0) { d = "" }
          if (escapes(d, tgt[k])) { why = "symlink target leaves the archive: " tgt[k] }
        } else if (type[k] == "h") {
          if (escapes("", tgt[k])) { why = "hardlink target leaves the archive: " tgt[k] }
        }
        if (why == "") {
          n = split(canon(p), a, "/")
          pre = ""
          for (i = 1; i < n; i++) {
            pre = pre (i == 1 ? "" : "/") a[i]
            if (pre in sym) { why = "path below a symlink (" pre ")"; break }
          }
        }
        if (why != "") { print p " (" why ")"; exit 1 }
      }
    }
  ') && return 0
  log ERROR archive "unsafe archive entry: $acl_out"
  return 1
}

# archive_check_safe FILE: 0 when every entry stays inside the archive root; 1 (logged, first offending entry
# named) otherwise, and also when the archive cannot be listed
archive_check_safe() {
  acs_list=$(mktemp "${TMPDIR:-/tmp}/rea-setup-cs.XXXXXX") || return 1
  register_tmp "$acs_list"
  if ! archive_list "$1" >"$acs_list"; then
    rm -f "$acs_list"
    log ERROR archive "cannot list archive: $1"
    return 1
  fi
  acs_rc=0
  archive_check_lines <"$acs_list" || acs_rc=1
  rm -f "$acs_list"
  return "$acs_rc"
}

# PRECONDITION: the caller has run archive_check_safe on this same, already verified file; nothing here
# re-checks the entries.
# archive_extract FILE DEST: tar.gz with tar; zip with unzip, else bsdtar, else jar run inside DEST. A zip
# that holds the Ghidra top directory then gets ghidra_set_exec_bits (jar and some bsdtar builds drop the
# execute bits).
archive_extract() {
  ae_file=$1
  ae_dest=$2
  [ -f "$ae_file" ] || return 1
  mkdir -p -- "$ae_dest" || return 1
  case "$ae_file" in
    *.zip | *.ZIP)
      ae_tool=$(archive_tool_for "$ae_file") || return 1
      case "$ae_tool" in
        unzip) unzip -q "$ae_file" -d "$ae_dest" || return 1 ;;
        bsdtar) bsdtar -xf "$ae_file" -C "$ae_dest" || return 1 ;;
        jar)
          case "$ae_file" in
            /*) ae_abs=$ae_file ;;
            *) ae_abs=$PWD/$ae_file ;;
          esac
          (cd "$ae_dest" && "$JAVA_HOME_SELECTED/bin/jar" xf "$ae_abs") || return 1
          ;;
        *) return 1 ;;
      esac
      if [ -d "$ae_dest/$PIN_GHIDRA_TOPDIR" ]; then
        ghidra_set_exec_bits "$ae_dest/$PIN_GHIDRA_TOPDIR"
      fi
      ;;
    *)
      "${ARCHIVE_TAR:-tar}" -xzf "$ae_file" -C "$ae_dest" --no-same-owner || return 1
      ;;
  esac
  return 0
}

# ghidra_set_exec_bits ROOT: the zip format keeps the execute bit, but jar and some tools drop it. Sets it on
# ghidraRun, the files directly under support/ and server/ (not *.bat *.properties *.txt *.html *.cmd), every
# *.sh, every file under an os/linux_x86_64/ directory, the debugger launchers under
# Ghidra/Debug/*/data/debugger-launchers/, Ghidra/Debug/Debugger-isf/support/runISFServer,
# support/gradle/gradlew and support/GhidraGo/ghidraGo. Symlinks are never followed (find -type f).
ghidra_set_exec_bits() {
  [ -d "$1" ] || return 1
  (
    cd "$1" || exit 1
    [ -f ghidraRun ] && chmod +x ghidraRun
    for gx_d in support server; do
      [ -d "$gx_d" ] || continue
      find "$gx_d" -maxdepth 1 -type f ! -name '*.bat' ! -name '*.properties' ! -name '*.txt' ! -name '*.html' ! -name '*.cmd' -exec chmod +x {} +
    done
    find . -type f -name '*.sh' -exec chmod +x {} +
    find . -type f -path '*/os/linux_x86_64/*' -exec chmod +x {} +
    if [ -d Ghidra/Debug ]; then
      find Ghidra/Debug -type f -path 'Ghidra/Debug/*/data/debugger-launchers/*' -exec chmod +x {} +
    fi
    for gx_f in Ghidra/Debug/Debugger-isf/support/runISFServer support/gradle/gradlew support/GhidraGo/ghidraGo; do
      [ -f "$gx_f" ] && chmod +x "$gx_f"
    done
    exit 0
  )
}

# staging_new DIR NAME: creates DIR/NAME.tmp.$$, prints its path and adds it to STAGING_DIRS (newline-
# separated: a path may contain a space). Called inside $(...) the addition is lost with the subshell;
# cleanup_install still removes it when DIR is locked by this process.
staging_new() {
  sn_path="$1/$2.tmp.$$"
  rm -rf -- "$sn_path"
  mkdir -p -- "$sn_path" || return 1
  STAGING_DIRS="${STAGING_DIRS}${STAGING_DIRS:+$NL}$sn_path"
  printf '%s\n' "$sn_path"
}

# install_commit STAGING FINAL: marks STAGING complete, swaps it in for FINAL (an existing FINAL, complete
# or not, is moved aside to FINAL.old.$$ first and removed after; failing to remove it only warns)
install_commit() {
  ic_stage=$1
  ic_final=$2
  ic_old="$ic_final.old.$$"
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$PIN_SCRIPT_VERSION" >"$ic_stage/.install-complete" || return 1
  rm -rf -- "$ic_old"
  if [ -e "$ic_final" ] || [ -L "$ic_final" ]; then
    mv -- "$ic_final" "$ic_old" || return 1
  fi
  if ! mv -- "$ic_stage" "$ic_final"; then
    if [ -e "$ic_old" ]; then
      mv -- "$ic_old" "$ic_final"
    fi
    return 1
  fi
  if [ -e "$ic_old" ] || [ -L "$ic_old" ]; then
    rm -rf -- "$ic_old" || log WARN install "could not remove the previous install: $ic_old"
  fi
  return 0
}

# install_valid DIR FILE...: 0 when DIR/.install-complete and every listed file under DIR exist
install_valid() {
  iv_dir=$1
  shift
  [ -f "$iv_dir/.install-complete" ] || return 1
  for iv_f in "$@"; do
    [ -e "$iv_dir/$iv_f" ] || return 1
  done
  return 0
}

# jdk_build RELEASE: the build number after the + (0 when absent), digits only
jdk_build() {
  case "$1" in
    *+*) jb=${1#*+} ;;
    *) jb=0 ;;
  esac
  jb=${jb%%[!0-9]*}
  echo "${jb:-0}"
}

# jdk_newer A B: 0 when directory name A (jdk-21.0.13+9) is a newer release than B: the X.Y.Z first, then
# the build number
jdk_newer() {
  jn_a=${1#jdk-}
  jn_b=${2#jdk-}
  jn_c=$(semver_compare "${jn_a%%+*}" "${jn_b%%+*}")
  [ "$jn_c" = 1 ] && return 0
  [ "$jn_c" = -1 ] && return 1
  [ "$(jdk_build "$jn_a")" -gt "$(jdk_build "$jn_b")" ]
}

# prune_jdks TOOLS: keeps the two newest jdk-<digit>* directories that hold .install-complete (nothing else
# is ever touched) by release, and whichever one holds JAVA_HOME or
# JAVA_HOME_SELECTED; removes the rest (a failed removal only warns). Staging and .old directories are
# ignored.
prune_jdks() {
  pj_tools=$1
  pj_all=""
  for pj_d in "$pj_tools"/jdk-[0-9]*; do
    [ -d "$pj_d" ] || continue
    pj_n=${pj_d##*/}
    case "$pj_n" in
      *.tmp.* | *.old.*) continue ;;
    esac
    # Only what an install of this script made: the sentinel. A JDK's own release file is not proof, a
    # hand-extracted Temurin has one too.
    if [ ! -f "$pj_d/.install-complete" ]; then
      continue
    fi
    pj_all="${pj_all}${pj_all:+$NL}$pj_n"
  done
  [ -n "$pj_all" ] || return 0
  while IFS= read -r pj_n; do
    pj_newer=0
    while IFS= read -r pj_m; do
      if [ "$pj_m" != "$pj_n" ] && jdk_newer "$pj_m" "$pj_n"; then
        pj_newer=$((pj_newer + 1))
      fi
    done <<EOF
$pj_all
EOF
    [ "$pj_newer" -ge 2 ] || continue
    pj_keep=0
    for pj_h in "${JAVA_HOME:-}" "${JAVA_HOME_SELECTED:-}"; do
      case "$pj_h" in
        "$pj_tools/$pj_n" | "$pj_tools/$pj_n"/*) pj_keep=1 ;;
      esac
    done
    if [ "$pj_keep" -eq 1 ]; then
      log INFO jdk "keeping the JDK in use: $pj_tools/$pj_n"
      continue
    fi
    log INFO jdk "removing old JDK: $pj_tools/$pj_n"
    rm -rf -- "${pj_tools:?}/${pj_n:?}" || log WARN jdk "could not remove: $pj_tools/$pj_n"
  done <<EOF
$pj_all
EOF
  return 0
}

# --- steps ---

CRED_OVERRIDE_VARS="ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CODE_OAUTH_REFRESH_TOKEN ANTHROPIC_PROFILE CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY"
HINT_NODE="install Node 24: fnm install 24 (https://github.com/Schniz/fnm) or https://nodejs.org"
HINT_CLAUDE_CMD="agent-profile refuses npm .cmd shims; install Claude Code's native installer"

# step_preflight: platform, profile name, downloader and archive tools, the two install directories and
# their orphan cleanup. Sets OS, ARCH, TOOLS_DIR, BIN_DIR, ZIP_TOOL and SUMMARY_preflight.
step_preflight() {
  platform_detect || die "$EX_PLATFORM" preflight "unsupported platform: $OS $ARCH (no agent-profile, clavity-ls or Ghidra native build)"
  log INFO preflight "platform: $OS $ARCH"
  if ! profile_name_valid "$OPT_PROFILE"; then
    die "$EX_USAGE" preflight "invalid profile name: $OPT_PROFILE"
  fi
  if ! command -v curl >/dev/null 2>&1; then
    die "$EX_PREREQ" preflight "curl not found; install curl (apt install curl, dnf install curl, or brew install curl) and re-run"
  fi
  if ! command -v tar >/dev/null 2>&1; then
    die "$EX_PREREQ" preflight "tar not found; install tar (apt install tar, dnf install tar, or brew install gnu-tar) and re-run"
  fi
  # The zip of Ghidra is read with unzip or bsdtar; without either, jar from the JDK is the reader, which
  # is safe because step jdk runs before step ghidra.
  if ZIP_TOOL=$(archive_tool_for ""); then
    log DEBUG preflight "zip tool: $ZIP_TOOL"
  else
    ZIP_TOOL=jar
    log INFO preflight "neither unzip nor bsdtar found; the Ghidra zip will be read with jar from the JDK"
  fi
  TOOLS_DIR=$(tools_dir_default)
  BIN_DIR=$(bin_dir_default)
  log DEBUG preflight "tools dir: $(abbrev_home "$TOOLS_DIR"); bin dir: $(abbrev_home "$BIN_DIR")"
  if [ "${OPT_DRY_RUN:-0}" -eq 1 ] || [ "${OPT_CHECK_UPSTREAM:-0}" -eq 1 ]; then
    log DEBUG preflight "read-only run: orphan cleanup skipped"
  else
    cleanup_orphans "$TOOLS_DIR"
    cleanup_orphans "$BIN_DIR"
  fi
  summary_set preflight ok
  log INFO preflight "ok"
  return 0
}

# summary_set ID VALUE / summary_get ID: set and read SUMMARY_<id> through eval, because a plain assignment of
# SUMMARY_<id> trips shellcheck SC2034 (never read in this file) and lint suppressions are banned
summary_set() {
  eval "SUMMARY_$1=\$2"
}

summary_get() {
  eval "printf '%s\\n' \"\${SUMMARY_$1:-}\""
}

# prereq_tool NAME HINT: dies EX_PREREQ naming NAME when it is not on PATH
prereq_tool() {
  command -v "$1" >/dev/null 2>&1 || die "$EX_PREREQ" prereq "$1 not found; $2"
}

# prereq_node: node must exist and satisfy node_version_ok
prereq_node() {
  prereq_tool node "$HINT_NODE"
  node_rc=0
  node_out=$(node --version 2>/dev/null) || node_rc=$?
  if [ "$node_rc" -ne 0 ]; then
    die "$EX_PREREQ" prereq "node --version failed (exit $node_rc); $HINT_NODE"
  fi
  node_ver=$(semver_from_output "$node_out")
  if [ -z "$node_ver" ] || ! node_version_ok "$node_ver"; then
    die "$EX_PREREQ" prereq "node $node_out is not supported (needs 22.x >= 22.23.4, 24.x >= 24.22.1 or >= 26.12.1); $HINT_NODE"
  fi
  log DEBUG prereq "node $node_ver"
}

# prereq_claude: claude must exist; on Windows it must resolve to a native .exe
prereq_claude() {
  prereq_tool claude "install Claude Code (https://docs.claude.com/en/docs/claude-code/setup)"
  if [ "$OS" = windows ]; then
    pc_path=$(command -v claude)
    case "$pc_path" in
      *.exe | *.EXE) ;;
      *) die "$EX_PREREQ" prereq "claude resolves to $pc_path; $HINT_CLAUDE_CMD" ;;
    esac
  fi
}

# prereq_credentials: warns, by name only, about each variable that overrides the profile's isolation;
# returns 1 when it warned
prereq_credentials() {
  pcr_found=""
  for pcr_name in $CRED_OVERRIDE_VARS; do
    eval "pcr_val=\${$pcr_name:-}"
    if [ -n "$pcr_val" ]; then
      pcr_found="$pcr_found $pcr_name"
    fi
  done
  if [ -n "$pcr_found" ]; then
    log WARN prereq "set in this environment, these override the profile's credential isolation (names only):$pcr_found"
    return 1
  fi
  return 0
}

# step_prereq: node, npx, claude, agy, a procps ps on Linux, and (Windows) wt and a PowerShell. With
# --check-upstream, claude, agy and wt are skipped. Sets SUMMARY_prereq.
step_prereq() {
  prereq_node
  prereq_tool npx "it ships with Node; $HINT_NODE"
  if [ "${OPT_CHECK_UPSTREAM:-0}" -eq 1 ]; then
    log INFO prereq "skip claude, agy and wt (--check-upstream)"
  else
    prereq_claude
    prereq_tool agy "install the Antigravity CLI (agy) and put it on PATH"
    if [ "$OS" = windows ]; then
      prereq_tool wt "install Windows Terminal (https://aka.ms/terminal)"
    fi
  fi
  if [ "$OS" = windows ]; then
    command -v pwsh >/dev/null 2>&1 || command -v powershell >/dev/null 2>&1 ||
      die "$EX_PREREQ" prereq "pwsh or powershell not found; install PowerShell (https://aka.ms/powershell)"
  fi
  if [ "$OS" = linux ]; then
    sp_pid=$(ps -o pid= -p "$$" 2>/dev/null) || sp_pid=""
    case "$sp_pid" in
      '' | *[!0-9' ']*) die "$EX_PREREQ" prereq "a procps ps is required (ps -o pid= -p PID failed); install procps (apt install procps)" ;;
    esac
  fi
  if prereq_credentials; then
    summary_set prereq ok
    log INFO prereq "ok"
  else
    summary_set prereq warn
  fi
  return 0
}

# --- step tools-bin ---

# bin_exe_name NAME: the file name of a managed tool in BIN_DIR (.exe on Windows)
bin_exe_name() {
  if [ "${OS:-}" = windows ]; then
    printf '%s.exe\n' "$1"
  else
    printf '%s\n' "$1"
  fi
}

# resolve_agent_profile OS ARCH: sets AP_TAG, AP_VERSION, AP_ASSET, AP_URL and AP_SIDECAR_URL for the latest
# aiprofiles release; returns 1 (before any network request) for a platform with no build, and dies on a
# release that cannot be resolved
resolve_agent_profile() {
  case "$1 $2" in
    "linux x64") AP_ASSET=agent-profile-x86_64-unknown-linux-gnu.tar.gz ;;
    "mac x64") AP_ASSET=agent-profile-x86_64-apple-darwin.tar.gz ;;
    "mac aarch64") AP_ASSET=agent-profile-aarch64-apple-darwin.tar.gz ;;
    "windows x64") AP_ASSET=agent-profile-x86_64-pc-windows-msvc.zip ;;
    *) return 1 ;;
  esac
  AP_TAG=$(github_latest_tag "$PIN_AGENT_PROFILE_REPO") ||
    die "$EX_STEP" tools-bin "cannot determine the latest release of $PIN_AGENT_PROFILE_REPO"
  AP_VERSION=$(semver_from_output "$AP_TAG")
  [ -n "$AP_VERSION" ] || die "$EX_VERIFY" tools-bin "release tag of $PIN_AGENT_PROFILE_REPO has no X.Y.Z version: $AP_TAG"
  AP_URL="https://github.com/$PIN_AGENT_PROFILE_REPO/releases/latest/download/$AP_ASSET"
  AP_SIDECAR_URL="$AP_URL.sha256"
  log DEBUG tools-bin "agent-profile latest: tag $AP_TAG, asset $AP_ASSET"
  return 0
}

# resolve_clavity_ls OS ARCH: sets CL_TAG, CL_VERSION, CL_ASSET, CL_URL and CL_SIDECAR_URL for the latest
# clavity release, the asset being the one tar.gz for this platform among the release's assets (read from the
# API, else from the release page); returns 1 for a platform with no build; dies EX_VERIFY unless exactly one
# asset matches
resolve_clavity_ls() {
  case "$1 $2" in
    "linux x64") rcl_rid=linux-x64 ;;
    "mac aarch64") rcl_rid=osx-arm64 ;;
    "mac x64") rcl_rid=osx-x64 ;;
    "windows x64") rcl_rid=win-x64 ;;
    *) return 1 ;;
  esac
  CL_TAG=$(github_latest_tag "$PIN_CLAVITY_REPO") ||
    die "$EX_STEP" tools-bin "cannot determine the latest release of $PIN_CLAVITY_REPO"
  if ! rcl_names=$(github_release_assets "$PIN_CLAVITY_REPO"); then
    log WARN tools-bin "the GitHub API did not answer; reading the release page of $CL_TAG instead"
    rcl_names=$(github_release_assets_scrape "$PIN_CLAVITY_REPO" "$CL_TAG") ||
      die "$EX_STEP" tools-bin "cannot list the assets of $PIN_CLAVITY_REPO $CL_TAG"
  fi
  rcl_match=$(printf '%s\n' "$rcl_names" | grep -E "^clavity-ls-$rcl_rid-[0-9]+\\.[0-9]+\\.[0-9]+\\.tar\\.gz\$")
  rcl_count=$(printf '%s\n' "$rcl_match" | grep -c .)
  if [ "$rcl_count" -ne 1 ]; then
    die "$EX_VERIFY" tools-bin "expected exactly one clavity-ls asset for $rcl_rid in $CL_TAG, found $rcl_count"
  fi
  CL_ASSET=$rcl_match
  CL_VERSION=$(semver_from_output "$CL_ASSET")
  CL_URL="https://github.com/$PIN_CLAVITY_REPO/releases/download/$CL_TAG/$CL_ASSET"
  CL_SIDECAR_URL="$CL_URL.sha256"
  log DEBUG tools-bin "clavity-ls latest: tag $CL_TAG, asset $CL_ASSET"
  return 0
}

# install_single_binary NAME URL SIDECAR_URL EXPECTED_FILE DEST_PATH: downloads URL, checks it against the
# SHA-256 in the sidecar, refuses an unsafe archive, extracts it into a staging directory beside DEST_PATH,
# requires that the one entry is the regular file EXPECTED_FILE, and renames it over DEST_PATH. Returns 0 when
# installed and 2 when the move failed on Windows (a running program holds DEST_PATH): the installed copy is
# kept and the staged one removed. Every other failure dies, EX_VERIFY for anything the download, the checksum
# or the archive got wrong.
install_single_binary() {
  isb_name=$1
  isb_url=$2
  isb_sidecar_url=$3
  isb_expected=$4
  isb_dest=$5
  isb_dir=$(dirname -- "$isb_dest")
  mkdir -p -- "$isb_dir" || die "$EX_STEP" tools-bin "cannot create directory: $isb_dir"
  isb_stage=$(staging_new "$isb_dir" "$isb_name") || die "$EX_STEP" tools-bin "cannot create a staging directory in $isb_dir"
  register_tmp "$isb_stage"
  isb_final=$(resolve_redirects "$isb_sidecar_url") || die "$EX_VERIFY" tools-bin "cannot resolve the checksum of $isb_name: $isb_sidecar_url"
  http_get "$isb_final" "$isb_stage/sidecar" || die "$EX_VERIFY" tools-bin "cannot download the checksum of $isb_name: $isb_sidecar_url"
  isb_hash=$(sidecar_sha256 "$isb_stage/sidecar") || die "$EX_VERIFY" tools-bin "the checksum file of $isb_name holds no SHA-256: $isb_sidecar_url"
  isb_archive="$isb_stage/${isb_url##*/}"
  log DEBUG tools-bin "disk_free_mb $(disk_free_mb "$isb_dir") MB at $isb_dir before the download of $isb_name"
  download_verified "$isb_url" "$isb_archive" "$isb_hash" || die "$EX_VERIFY" tools-bin "cannot download and verify $isb_name from $isb_url"
  archive_check_safe "$isb_archive" || die "$EX_VERIFY" tools-bin "the archive of $isb_name is not safe to extract"
  archive_extract "$isb_archive" "$isb_stage/x" || die "$EX_VERIFY" tools-bin "cannot extract the archive of $isb_name"
  isb_count=0
  isb_found=""
  for isb_e in "$isb_stage"/x/* "$isb_stage"/x/.[!.]* "$isb_stage"/x/..?*; do
    if [ -e "$isb_e" ] || [ -L "$isb_e" ]; then
      isb_count=$((isb_count + 1))
      isb_found=$isb_e
    fi
  done
  if [ "$isb_count" -ne 1 ] || [ "${isb_found##*/}" != "$isb_expected" ] || [ -L "$isb_found" ] || [ ! -f "$isb_found" ]; then
    die "$EX_VERIFY" tools-bin "the archive of $isb_name must hold exactly one file, $isb_expected (found $isb_count entries)"
  fi
  chmod +x -- "$isb_found" || die "$EX_STEP" tools-bin "cannot make $isb_expected executable"
  if mv -f -- "$isb_found" "$isb_dest"; then
    rm -rf -- "$isb_stage"
    log DEBUG tools-bin "disk_free_mb $(disk_free_mb "$isb_dir") MB at $isb_dir after installing $isb_name"
    return 0
  fi
  if [ "${OS:-}" = windows ] && [ -e "$isb_dest" ]; then
    log WARN tools-bin "close running sessions to update $isb_name"
    rm -rf -- "$isb_stage"
    return 2
  fi
  die "$EX_STEP" tools-bin "cannot move $isb_expected into place: $isb_dest"
}

# installed_version NAME: prints the X.Y.Z that BIN_DIR's copy of NAME reports for --version, or nothing at
# all (status 0 either way) when that file is absent, not executable, exits non-zero or prints no X.Y.Z.
# PATH is not consulted.
installed_version() {
  iv_bin="$BIN_DIR/$(bin_exe_name "$1")"
  if [ ! -f "$iv_bin" ] || [ ! -x "$iv_bin" ]; then
    return 0
  fi
  iv_out=$("$iv_bin" --version 2>/dev/null) || return 0
  semver_from_output "$iv_out"
  return 0
}

# tools_bin_one NAME LATEST URL SIDECAR_URL: decides install, update or skip for one tool and carries it out
# (a dry or read-only run only reports); appends the outcome to TOOLS_BIN_SUMMARY
tools_bin_one() {
  tbo_name=$1
  tbo_latest=$2
  tbo_exe=$(bin_exe_name "$tbo_name")
  tbo_dest="$BIN_DIR/$tbo_exe"
  tbo_have=$(installed_version "$tbo_name")
  if [ -z "$tbo_have" ]; then
    tbo_decision=install
    log DEBUG tools-bin "no $tbo_name in $(abbrev_home "$BIN_DIR")"
  elif [ "$(semver_compare "$tbo_have" "$tbo_latest")" = -1 ]; then
    tbo_decision=update
  else
    tbo_decision="skip (already latest)"
  fi
  log INFO tools-bin "$tbo_name: $tbo_decision (installed: ${tbo_have:-none}, latest: $tbo_latest)"
  tbo_path=$(command -v "$tbo_name" 2>/dev/null) || tbo_path=""
  if [ -n "$tbo_path" ] && [ "$tbo_path" != "$tbo_dest" ]; then
    log WARN tools-bin "another $tbo_name at $tbo_path precedes the one this script manages"
  fi
  tbo_result=$tbo_decision
  case "$tbo_decision" in
    install | update)
      TOOLS_BIN_ACTED=1
      if [ "${OPT_DRY_RUN:-0}" -eq 1 ] || [ "${OPT_CHECK_UPSTREAM:-0}" -eq 1 ]; then
        log INFO tools-bin "$tbo_name: read-only run, nothing installed"
        tbo_result="$tbo_decision (not done: read-only run)"
      else
        tbo_rc=0
        install_single_binary "$tbo_name" "$3" "$4" "$tbo_exe" "$tbo_dest" || tbo_rc=$?
        if [ "$tbo_rc" -eq 2 ]; then
          tbo_result="kept ${tbo_have:-none} (in use)"
        else
          log INFO tools-bin "$tbo_name $tbo_latest installed in $(abbrev_home "$BIN_DIR")"
        fi
      fi
      ;;
  esac
  TOOLS_BIN_SUMMARY="${TOOLS_BIN_SUMMARY}${TOOLS_BIN_SUMMARY:+$NL}$tbo_name $tbo_latest: $tbo_result"
}

# step_tools_bin: agent-profile then clavity-ls, each installed or updated to the latest release in BIN_DIR.
# Takes the lock on TOOLS_DIR (kept until tools_lock_release) and puts BIN_DIR first on PATH. Sets
# SUMMARY_tools_bin.
step_tools_bin() {
  TOOLS_BIN_SUMMARY=""
  TOOLS_BIN_ACTED=0
  if [ "${OPT_DRY_RUN:-0}" -eq 1 ] || [ "${OPT_CHECK_UPSTREAM:-0}" -eq 1 ]; then
    log DEBUG tools-bin "read-only run: no lock taken"
  else
    lock_acquire "$TOOLS_DIR"
    mkdir -p -- "$BIN_DIR" || die "$EX_STEP" tools-bin "cannot create directory: $BIN_DIR"
  fi
  if [ "${TB_PLANNED:-0}" -ne 1 ]; then
    resolve_agent_profile "$OS" "$ARCH" || die "$EX_PLATFORM" tools-bin "no agent-profile build for $OS $ARCH"
  fi
  tools_bin_one agent-profile "$AP_VERSION" "$AP_URL" "$AP_SIDECAR_URL"
  if [ "${TB_PLANNED:-0}" -ne 1 ]; then
    resolve_clavity_ls "$OS" "$ARCH" || die "$EX_PLATFORM" tools-bin "no clavity-ls build for $OS $ARCH"
  fi
  tools_bin_one clavity-ls "$CL_VERSION" "$CL_URL" "$CL_SIDECAR_URL"
  PATH="$BIN_DIR:$PATH"
  export PATH
  summary_set tools_bin "$TOOLS_BIN_SUMMARY"
  if [ "$TOOLS_BIN_ACTED" -eq 1 ]; then
    log INFO tools-bin "ok"
  else
    log INFO tools-bin "skip (already valid)"
  fi
  return 0
}

# tools_lock_release: lets go of the lock step_tools_bin took on TOOLS_DIR. It belongs after the last step that
# writes to the tools directory, so main calls it where the steps end and the step that follows moves the call.
tools_lock_release() {
  lock_release "$TOOLS_DIR"
}

# --- step jdk ---

# jdk_exe NAME: the file name of a JDK program on this OS (java.exe on Windows)
jdk_exe() {
  if [ "${OS:-}" = windows ]; then
    printf '%s.exe\n' "$1"
  else
    printf '%s\n' "$1"
  fi
}

# jdk_valid DIR: 0 when DIR is a full 64-bit JDK of at least PIN_JDK_MAJOR for this host's architecture;
# otherwise prints the reason on stdout and returns 1. The only programs it runs are DIR's java, with
# -version and -XshowSettings:properties -version. DIR is the JDK home (on macOS .../Contents/Home).
jdk_valid() {
  jv_dir=$1
  jv_java="$jv_dir/bin/$(jdk_exe java)"
  jv_javac="$jv_dir/bin/$(jdk_exe javac)"
  if [ ! -f "$jv_java" ] || [ ! -x "$jv_java" ]; then
    echo "no executable bin/$(jdk_exe java) in $jv_dir"
    return 1
  fi
  if [ ! -f "$jv_javac" ]; then
    echo "no bin/$(jdk_exe javac) in $jv_dir (a JRE, not a JDK)"
    return 1
  fi
  jv_out=$("$jv_java" -version 2>&1) || {
    echo "java -version failed in $jv_dir"
    return 1
  }
  jv_out=$(printf '%s\n' "$jv_out" | tr -d '\r')
  jv_ver=$(printf '%s\n' "$jv_out" | sed -n -E 's/^.*version "([0-9]+)(\.([0-9]+))?.*$/\1 \3/p' | head -n 1)
  jv_major=${jv_ver%% *}
  case "$jv_major" in
    '' | *[!0-9]*)
      echo "cannot read the version from: $(printf '%s\n' "$jv_out" | head -n 1)"
      return 1
      ;;
  esac
  if [ "$jv_major" -eq 1 ]; then
    jv_major=${jv_ver#* }
    case "$jv_major" in
      '' | *[!0-9]*) jv_major=1 ;;
    esac
  fi
  if [ "$jv_major" -lt "$PIN_JDK_MAJOR" ]; then
    echo "major $jv_major < $PIN_JDK_MAJOR"
    return 1
  fi
  if ! printf '%s\n' "$jv_out" | grep -q '64-Bit'; then
    echo "not a 64-bit JDK (the banner has no 64-Bit)"
    return 1
  fi
  jv_set=$("$jv_java" -XshowSettings:properties -version 2>&1) || {
    echo "java -XshowSettings:properties failed in $jv_dir"
    return 1
  }
  jv_arch=$(printf '%s\n' "$jv_set" | tr -d '\r' | sed -n -E 's/^[[:space:]]*os\.arch[[:space:]]*=[[:space:]]*([^[:space:]]+).*$/\1/p' | head -n 1)
  case "$jv_arch" in
    amd64 | x86_64) jv_arch=x64 ;;
    aarch64 | arm64) jv_arch=aarch64 ;;
    '')
      echo "cannot read os.arch from $jv_dir"
      return 1
      ;;
  esac
  if [ "$jv_arch" != "$ARCH" ]; then
    echo "architecture $jv_arch does not match this host ($ARCH)"
    return 1
  fi
  return 0
}

# jdk_home_candidate DIR: the JAVA_HOME of an install at DIR: DIR/Contents/Home on macOS when it exists
jdk_home_candidate() {
  if [ "${OS:-}" = mac ] && [ -d "$1/Contents/Home" ]; then
    printf '%s\n' "$1/Contents/Home"
  else
    printf '%s\n' "$1"
  fi
}

# jdk_fallback OS ARCH: sets JDK_RELEASE, JDK_URL, JDK_SHA256, JDK_SIDECAR_URL and JDK_BYTES from the embedded
# pin of that platform; returns 1 when there is none
jdk_fallback() {
  case "$1-$2" in
    linux-x64) jf_pin=$PIN_JDK_FALLBACK_LINUX_X64 ;;
    mac-x64) jf_pin=$PIN_JDK_FALLBACK_MAC_X64 ;;
    mac-aarch64) jf_pin=$PIN_JDK_FALLBACK_MAC_AARCH64 ;;
    windows-x64) jf_pin=$PIN_JDK_FALLBACK_WINDOWS_X64 ;;
    *) return 1 ;;
  esac
  JDK_RELEASE=$PIN_JDK_FALLBACK_RELEASE
  JDK_URL="$PIN_JDK_FALLBACK_URL_BASE${jf_pin%%:*}"
  JDK_SHA256=${jf_pin#*:}
  JDK_SIDECAR_URL="$JDK_URL.sha256.txt"
  JDK_BYTES=""
  return 0
}

# jdk_resolve: sets JDK_RELEASE, JDK_URL, JDK_SHA256, JDK_SIDECAR_URL and JDK_BYTES for OS and ARCH: the
# Adoptium answer, or the embedded pin (with a WARN) when the API cannot be reached
jdk_resolve() {
  jr_rc=0
  adoptium_resolve "$OS" "$ARCH" || jr_rc=$?
  case "$jr_rc" in
    0) return 0 ;;
    2)
      jdk_fallback "$OS" "$ARCH" || die "$EX_PLATFORM" jdk "no JDK build for $OS $ARCH"
      log WARN jdk "Adoptium API unreachable; installing the embedded fallback $PIN_JDK_FALLBACK_RELEASE, possibly outdated"
      ;;
    *) die "$EX_VERIFY" jdk "the Adoptium answer for $OS $ARCH failed validation" ;;
  esac
}

# jdk_fail STAGE MSG [CODE]: removes STAGE (and the archive in it) and dies, EX_VERIFY unless CODE is given
jdk_fail() {
  rm -rf -- "$1"
  die "${3:-$EX_VERIFY}" jdk "$2"
}

# jdk_install: installs the latest Temurin JDK (or the embedded fallback) into TOOLS_DIR/jdk-<release> and
# sets JAVA_HOME_SELECTED; a read-only run only logs what it would fetch. The work happens in a staging
# directory beside the final one; the archive lives there as .download.$$ and goes right after the extract.
jdk_install() {
  require_free_mb "$TOOLS_DIR" 600
  if [ "${JDK_PLANNED:-0}" -ne 1 ]; then
    jdk_resolve
  fi
  log INFO jdk "resolved $JDK_RELEASE: $JDK_URL (${JDK_BYTES:-unknown} bytes)"
  if [ "${OPT_DRY_RUN:-0}" -eq 1 ] || [ "${OPT_CHECK_UPSTREAM:-0}" -eq 1 ]; then
    log INFO jdk "read-only run, nothing installed"
    summary_set jdk "$JDK_RELEASE (not installed: read-only run)"
    return 0
  fi
  mkdir -p -- "$TOOLS_DIR" || die "$EX_STEP" jdk "cannot create directory: $TOOLS_DIR"
  ji_final="$TOOLS_DIR/$JDK_RELEASE"
  ji_work=$(staging_new "$TOOLS_DIR" "$JDK_RELEASE.work") || die "$EX_STEP" jdk "cannot create a staging directory in $TOOLS_DIR"
  register_tmp "$ji_work"
  case "$JDK_URL" in
    *.zip) ji_ext=.zip ;;
    *) ji_ext=.tar.gz ;;
  esac
  ji_archive="$ji_work/.download.$$$ji_ext"
  if [ -n "$JDK_SIDECAR_URL" ]; then
    ji_sc=$(resolve_redirects "$JDK_SIDECAR_URL") || ji_sc=""
    if [ -n "$ji_sc" ] && http_get "$ji_sc" "$ji_work/sidecar"; then
      ji_hash=$(sidecar_sha256 "$ji_work/sidecar") || jdk_fail "$ji_work" "the checksum file of $JDK_RELEASE holds no SHA-256: $JDK_SIDECAR_URL"
      [ "$ji_hash" = "$JDK_SHA256" ] || jdk_fail "$ji_work" "checksum mismatch for $JDK_RELEASE: the API says $JDK_SHA256, the sidecar says $ji_hash"
    else
      log WARN jdk "the checksum sidecar of $JDK_RELEASE is unreachable; relying on the SHA-256 from the release listing"
    fi
  fi
  log DEBUG jdk "disk_free_mb $(disk_free_mb "$TOOLS_DIR") MB at $TOOLS_DIR before the download"
  download_verified "$JDK_URL" "$ji_archive" "$JDK_SHA256" || jdk_fail "$ji_work" "cannot download and verify $JDK_RELEASE from $JDK_URL"
  archive_check_safe "$ji_archive" || jdk_fail "$ji_work" "the archive of $JDK_RELEASE is not safe to extract"
  archive_extract "$ji_archive" "$ji_work/x" || jdk_fail "$ji_work" "cannot extract the archive of $JDK_RELEASE"
  rm -f "$ji_archive"
  ji_count=0
  ji_found=""
  for ji_e in "$ji_work"/x/* "$ji_work"/x/.[!.]* "$ji_work"/x/..?*; do
    if [ -e "$ji_e" ] || [ -L "$ji_e" ]; then
      ji_count=$((ji_count + 1))
      ji_found=$ji_e
    fi
  done
  if [ "$ji_count" -ne 1 ] || [ "${ji_found##*/}" != "$JDK_RELEASE" ] || [ -L "$ji_found" ] || [ ! -d "$ji_found" ]; then
    jdk_fail "$ji_work" "the archive of $JDK_RELEASE must hold exactly one top directory, $JDK_RELEASE (found $ji_count entries)"
  fi
  ji_stage=$(staging_new "$TOOLS_DIR" "$JDK_RELEASE") || jdk_fail "$ji_work" "cannot create a staging directory in $TOOLS_DIR" "$EX_STEP"
  register_tmp "$ji_stage"
  rmdir "$ji_stage" || jdk_fail "$ji_work" "cannot prepare the staging directory $ji_stage" "$EX_STEP"
  mv -- "$ji_found" "$ji_stage" || jdk_fail "$ji_work" "cannot move the extracted JDK into $ji_stage" "$EX_STEP"
  rm -rf -- "$ji_work"
  ji_home=$(jdk_home_candidate "$ji_stage")
  ji_why=$(jdk_valid "$ji_home") || jdk_fail "$ji_stage" "the downloaded $JDK_RELEASE is not a usable JDK: $ji_why"
  install_commit "$ji_stage" "$ji_final" || jdk_fail "$ji_stage" "cannot move $JDK_RELEASE into place: $ji_final" "$EX_STEP"
  JAVA_HOME_SELECTED=$(jdk_home_candidate "$ji_final")
  log DEBUG jdk "disk_free_mb $(disk_free_mb "$TOOLS_DIR") MB at $TOOLS_DIR after the install"
  log INFO jdk "installed $JDK_RELEASE in $(abbrev_home "$ji_final")"
  prune_jdks "$TOOLS_DIR"
  summary_set jdk "$JDK_RELEASE installed: $JAVA_HOME_SELECTED"
  return 0
}

# jdk_choose: sets JAVA_HOME_SELECTED and SUMMARY_jdk and returns 0 when a JDK can be reused, 1 when one has to
# be installed (JDK_REUSED says which). Precedence: --java-home (invalid: dies EX_STEP), the JAVA_HOME
# environment variable (invalid: WARN and go on), the newest valid install in TOOLS_DIR. Resolves and checks;
# downloads and writes nothing.
jdk_choose() {
  JAVA_HOME_SELECTED=""
  JDK_REUSED=1
  if [ -n "${OPT_JAVA_HOME:-}" ]; then
    js_home=$(jdk_home_candidate "$OPT_JAVA_HOME")
    js_why=$(jdk_valid "$js_home") || die "$EX_STEP" jdk "--java-home $OPT_JAVA_HOME is not a usable JDK: $js_why"
    JAVA_HOME_SELECTED=$js_home
    log INFO jdk "using --java-home: $(abbrev_home "$js_home")"
    summary_set jdk "reused --java-home: $JAVA_HOME_SELECTED"
    return 0
  fi
  if [ -n "${JAVA_HOME:-}" ]; then
    js_home=$(jdk_home_candidate "$JAVA_HOME")
    if js_why=$(jdk_valid "$js_home"); then
      JAVA_HOME_SELECTED=$js_home
      log INFO jdk "using JAVA_HOME: $(abbrev_home "$js_home")"
      summary_set jdk "reused JAVA_HOME: $JAVA_HOME_SELECTED"
      return 0
    fi
    log WARN jdk "JAVA_HOME $JAVA_HOME is not a usable JDK ($js_why); ignoring it"
  fi
  js_best=""
  for js_d in "$TOOLS_DIR"/jdk-[0-9]*; do
    [ -d "$js_d" ] || continue
    js_n=${js_d##*/}
    case "$js_n" in
      *.tmp.* | *.old.*) continue ;;
    esac
    install_valid "$js_d" || {
      log DEBUG jdk "ignoring $js_n: no .install-complete"
      continue
    }
    js_why=$(jdk_valid "$(jdk_home_candidate "$js_d")") || {
      log WARN jdk "ignoring the install $js_n: $js_why"
      continue
    }
    if [ -z "$js_best" ] || jdk_newer "$js_n" "$js_best"; then
      js_best=$js_n
    fi
  done
  if [ -n "$js_best" ]; then
    JAVA_HOME_SELECTED=$(jdk_home_candidate "$TOOLS_DIR/$js_best")
    log INFO jdk "reusing $js_best in $(abbrev_home "$TOOLS_DIR")"
    summary_set jdk "reused $js_best: $JAVA_HOME_SELECTED"
    return 0
  fi
  JDK_REUSED=0
  return 1
}

# jdk_select: jdk_choose, then jdk_install when there is nothing to reuse
jdk_select() {
  jdk_choose || jdk_install
}

# step_jdk: picks or installs the JDK that Ghidra and rea run with. Runs under the lock step_tools_bin took.
# Sets JAVA_HOME_SELECTED and SUMMARY_jdk. After jdk_plan it follows the plan (the choice was made there).
step_jdk() {
  case "${PLAN_jdk:-}" in
    reuse) ;;
    install) jdk_choose || jdk_install ;; # re-checked under the lock: another run may have installed it meanwhile
    *) jdk_select ;;
  esac
  if [ "${JDK_REUSED:-0}" -eq 1 ]; then
    log INFO jdk "skip (already valid)"
  else
    log INFO jdk "ok"
  fi
  return 0
}

# --- step ghidra ---

# ghidra_version DIR: the application.version of DIR/Ghidra/application.properties (tolerant of CRLF, blanks
# and other properties); empty when the file or the property is absent
ghidra_version() {
  gv_file="$1/Ghidra/application.properties"
  [ -f "$gv_file" ] || return 0
  tr -d '\r' <"$gv_file" | sed -n -E 's/^[[:space:]]*application\.version[[:space:]]*=[[:space:]]*([^[:space:]]*)[[:space:]]*$/\1/p' | head -n 1
}

# ghidra_valid DIR: 0 when DIR holds a Ghidra of the 12.1 line (12.1 or 12.1.N); otherwise 1 with the reason
# on stdout
ghidra_valid() {
  gl_ver=$(ghidra_version "$1")
  if [ -z "$gl_ver" ]; then
    echo "no application.version in Ghidra/application.properties"
    return 1
  fi
  if printf '%s\n' "$gl_ver" | grep -Eq '^12\.1(\.[0-9]+)?$'; then
    return 0
  fi
  echo "version $gl_ver is not in the 12.1 line"
  return 1
}

# ghidra_fail STAGE MSG [CODE]: removes STAGE (and the archive in it) and dies, EX_VERIFY unless CODE is given
ghidra_fail() {
  rm -rf -- "$1"
  die "${3:-$EX_VERIFY}" ghidra "$2"
}

# ghidra_install: installs the pinned Ghidra into TOOLS_DIR/PIN_GHIDRA_TOPDIR and sets GHIDRA_DIR_SELECTED; a
# read-only run only logs what it would fetch. The work happens in a staging directory beside the final one
# (a short name, for the Windows path limit); the archive lives there as .download.$$.zip and goes right after
# the extract. The digest is the one embedded in this script, never one fetched.
ghidra_install() {
  gi_final="$TOOLS_DIR/$PIN_GHIDRA_TOPDIR"
  require_free_mb "$TOOLS_DIR" 1500
  log INFO ghidra "will install Ghidra $PIN_GHIDRA_VERSION from $PIN_GHIDRA_URL ($PIN_GHIDRA_ZIP_BYTES bytes) into $(abbrev_home "$gi_final")"
  GHIDRA_OFFICIAL=1
  if [ "${OPT_DRY_RUN:-0}" -eq 1 ] || [ "${OPT_CHECK_UPSTREAM:-0}" -eq 1 ]; then
    log INFO ghidra "read-only run, nothing installed"
    summary_set ghidra "$PIN_GHIDRA_VERSION (not installed: read-only run)"
    return 0
  fi
  mkdir -p -- "$TOOLS_DIR" || die "$EX_STEP" ghidra "cannot create directory: $TOOLS_DIR"
  gi_work=$(staging_new "$TOOLS_DIR" ghidra.work) || die "$EX_STEP" ghidra "cannot create a staging directory in $TOOLS_DIR"
  register_tmp "$gi_work"
  gi_archive="$gi_work/.download.$$.zip"
  log DEBUG ghidra "disk_free_mb $(disk_free_mb "$TOOLS_DIR") MB at $TOOLS_DIR before the download"
  download_verified "$PIN_GHIDRA_URL" "$gi_archive" "$PIN_GHIDRA_SHA256" || ghidra_fail "$gi_work" "cannot download and verify Ghidra $PIN_GHIDRA_VERSION from $PIN_GHIDRA_URL"
  gi_size=$(wc -c <"$gi_archive" | tr -d ' ')
  [ "$gi_size" = "$PIN_GHIDRA_ZIP_BYTES" ] || ghidra_fail "$gi_work" "the Ghidra archive is $gi_size bytes, expected $PIN_GHIDRA_ZIP_BYTES"
  archive_check_safe "$gi_archive" || ghidra_fail "$gi_work" "the Ghidra archive is not safe to extract"
  archive_extract "$gi_archive" "$gi_work/x" || ghidra_fail "$gi_work" "cannot extract the Ghidra archive"
  rm -f "$gi_archive"
  gi_count=0
  gi_found=""
  for gi_e in "$gi_work"/x/* "$gi_work"/x/.[!.]* "$gi_work"/x/..?*; do
    if [ -e "$gi_e" ] || [ -L "$gi_e" ]; then
      gi_count=$((gi_count + 1))
      gi_found=$gi_e
    fi
  done
  if [ "$gi_count" -ne 1 ] || [ "${gi_found##*/}" != "$PIN_GHIDRA_TOPDIR" ] || [ -L "$gi_found" ] || [ ! -d "$gi_found" ]; then
    ghidra_fail "$gi_work" "the Ghidra archive must hold exactly one top directory, $PIN_GHIDRA_TOPDIR (found $gi_count entries)"
  fi
  gi_stage=$(staging_new "$TOOLS_DIR" "$PIN_GHIDRA_TOPDIR") || ghidra_fail "$gi_work" "cannot create a staging directory in $TOOLS_DIR" "$EX_STEP"
  register_tmp "$gi_stage"
  rmdir "$gi_stage" || ghidra_fail "$gi_work" "cannot prepare the staging directory $gi_stage" "$EX_STEP"
  mv -- "$gi_found" "$gi_stage" || ghidra_fail "$gi_work" "cannot move the extracted Ghidra into $gi_stage" "$EX_STEP"
  rm -rf -- "$gi_work"
  gi_ver=$(ghidra_version "$gi_stage")
  [ "$gi_ver" = "$PIN_GHIDRA_VERSION" ] || ghidra_fail "$gi_stage" "the downloaded Ghidra reports version '$gi_ver', expected $PIN_GHIDRA_VERSION"
  install_commit "$gi_stage" "$gi_final" || ghidra_fail "$gi_stage" "cannot move Ghidra into place: $gi_final" "$EX_STEP"
  GHIDRA_DIR_SELECTED=$gi_final
  log DEBUG ghidra "disk_free_mb $(disk_free_mb "$TOOLS_DIR") MB at $TOOLS_DIR after the install"
  log INFO ghidra "installed Ghidra $PIN_GHIDRA_VERSION in $(abbrev_home "$gi_final")"
  summary_set ghidra "$PIN_GHIDRA_VERSION installed: $GHIDRA_DIR_SELECTED"
  return 0
}

# ghidra_choose: sets GHIDRA_DIR_SELECTED and SUMMARY_ghidra and returns 0 when a Ghidra can be reused, 1 when
# one has to be installed (GHIDRA_REUSED says which). Precedence: --ghidra-dir (invalid: dies EX_STEP), the
# GHIDRA_INSTALL_DIR environment variable (invalid: WARN and go on), the install in TOOLS_DIR (valid and
# marked complete; one without the mark is treated as absent and replaced). GHIDRA_OFFICIAL is 1 when the
# Ghidra is the official archive (reused from TOOLS_DIR; ghidra_install sets it for a new one). Resolves and
# checks; downloads and writes nothing.
ghidra_choose() {
  GHIDRA_DIR_SELECTED=""
  GHIDRA_OFFICIAL=0
  GHIDRA_REUSED=1
  if [ -n "${OPT_GHIDRA_DIR:-}" ]; then
    gs_why=$(ghidra_valid "$OPT_GHIDRA_DIR") || die "$EX_STEP" ghidra "--ghidra-dir $OPT_GHIDRA_DIR is not a usable Ghidra: $gs_why"
    GHIDRA_DIR_SELECTED=$OPT_GHIDRA_DIR
    log INFO ghidra "using --ghidra-dir: $(abbrev_home "$OPT_GHIDRA_DIR")"
    summary_set ghidra "reused --ghidra-dir: $GHIDRA_DIR_SELECTED"
    return 0
  fi
  if [ -n "${GHIDRA_INSTALL_DIR:-}" ]; then
    if gs_why=$(ghidra_valid "$GHIDRA_INSTALL_DIR"); then
      GHIDRA_DIR_SELECTED=$GHIDRA_INSTALL_DIR
      log INFO ghidra "using GHIDRA_INSTALL_DIR: $(abbrev_home "$GHIDRA_INSTALL_DIR")"
      summary_set ghidra "reused GHIDRA_INSTALL_DIR: $GHIDRA_DIR_SELECTED"
      return 0
    fi
    case "$(ghidra_version "$GHIDRA_INSTALL_DIR")" in
      12.2 | 12.2.*)
        log DEBUG ghidra "GHIDRA_INSTALL_DIR $GHIDRA_INSTALL_DIR is a 12.2 install"
        log WARN ghidra "12.2 is not accepted by rea 6.8.0; installing 12.1.4 alongside"
        ;;
      *) log WARN ghidra "GHIDRA_INSTALL_DIR $GHIDRA_INSTALL_DIR is not a usable Ghidra ($gs_why); ignoring it" ;;
    esac
  fi
  gs_dir="$TOOLS_DIR/$PIN_GHIDRA_TOPDIR"
  if [ -d "$gs_dir" ]; then
    if ! install_valid "$gs_dir" Ghidra/application.properties; then
      log DEBUG ghidra "ignoring $PIN_GHIDRA_TOPDIR: no .install-complete or no application.properties"
    elif gs_why=$(ghidra_valid "$gs_dir"); then
      GHIDRA_DIR_SELECTED=$gs_dir
      GHIDRA_OFFICIAL=1
      log INFO ghidra "reusing $PIN_GHIDRA_TOPDIR in $(abbrev_home "$TOOLS_DIR")"
      summary_set ghidra "reused $PIN_GHIDRA_TOPDIR: $GHIDRA_DIR_SELECTED"
      return 0
    else
      log WARN ghidra "ignoring the install $PIN_GHIDRA_TOPDIR: $gs_why"
    fi
  fi
  GHIDRA_REUSED=0
  return 1
}

# ghidra_select: ghidra_choose, then ghidra_install when there is nothing to reuse
ghidra_select() {
  ghidra_choose || ghidra_install
}

# step_ghidra: picks or installs the Ghidra that rea runs with. Runs under the lock step_tools_bin took. Sets
# GHIDRA_DIR_SELECTED and SUMMARY_ghidra. On macOS the official archive has no native decompiler: a WARN and
# a warn summary, never a failure.
step_ghidra() {
  case "${PLAN_ghidra:-}" in
    reuse) ;;
    install) ghidra_choose || ghidra_install ;; # re-checked under the lock: another run may have installed it meanwhile
    *) ghidra_select ;;
  esac
  log DEBUG ghidra "selected: $GHIDRA_DIR_SELECTED"
  if [ "$OS" = mac ] && [ "$GHIDRA_OFFICIAL" -eq 1 ]; then
    log WARN ghidra 'the official 12.1.4 archive has no macOS native decompiler; rea doctor will report native_decompiler missing until it is built (rea docs/installation.md, "Missing macOS native decompiler" / "macOS arm64 native decompiler")'
    summary_set ghidra "warn: $(summary_get ghidra); no macOS native decompiler in the official archive"
  fi
  if [ "${GHIDRA_REUSED:-0}" -eq 1 ]; then
    log INFO ghidra "skip (already valid)"
  else
    log INFO ghidra "ok"
  fi
  return 0
}

# --- step profile ---

# profile_phys PATH: PATH with the symlinks of its longest existing part resolved (the rest is kept as given);
# PATH itself when nothing of it can be resolved
profile_phys() {
  pp_path=${1%/}
  pp_rest=""
  while [ -n "$pp_path" ] && [ ! -d "$pp_path" ]; do
    pp_rest="/${pp_path##*/}$pp_rest"
    pp_next=${pp_path%/*}
    if [ "$pp_next" = "$pp_path" ]; then
      printf '%s\n' "$1"
      return 0
    fi
    pp_path=$pp_next
  done
  [ -n "$pp_path" ] || pp_path=/
  pp_phys=$(cd -P -- "$pp_path" 2>/dev/null && pwd -P) || {
    printf '%s\n' "$1"
    return 0
  }
  printf '%s%s\n' "${pp_phys%/}" "$pp_rest"
}

# profile_within DIR ROOT: 0 when DIR is ROOT or lies under it; case-insensitive on Windows
profile_within() {
  pw_dir=${1%/}
  pw_root=${2%/}
  if [ "${OS:-}" = windows ]; then
    pw_dir=$(printf '%s' "$pw_dir" | tr '[:upper:]' '[:lower:]')
    pw_root=$(printf '%s' "$pw_root" | tr '[:upper:]' '[:lower:]')
  fi
  case "$pw_dir" in
    "$pw_root" | "$pw_root"/*) return 0 ;;
  esac
  return 1
}

# profile_dir_shared DIR: 0 when DIR is empty, or is $HOME/.claude or inside it, as given or with symlinks
# resolved; the setup must never write there, whatever agent-profile reports
profile_dir_shared() {
  [ -n "$1" ] || return 0
  [ -n "${HOME:-}" ] || return 1
  ps_real=$(profile_phys "$1")
  ps_home_real=$(profile_phys "$HOME/.claude")
  for ps_root in "$HOME/.claude" "$ps_home_real"; do
    for ps_cand in "$1" "$ps_real"; do
      if profile_within "$ps_cand" "$ps_root"; then
        return 0
      fi
    done
  done
  return 1
}

# profile_config_dir NAME: runs `agent-profile claude doctor NAME --json` and prints the CLAUDE_CONFIG_DIR it
# reports. Exit 5 means a check failed: a WARN naming the failing checks, and create decides. Any other
# non-zero exit, output that is not JSON, or a directory that is not specific to the profile dies EX_STEP.
profile_config_dir() {
  pcd_rc=0
  run_cmd profile agent-profile claude doctor "$1" --json || pcd_rc=$?
  pcd_json=$RUN_STDOUT
  case "$pcd_rc" in
    0 | 5) ;;
    *)
      rm -f "$pcd_json"
      die "$EX_STEP" profile "agent-profile claude doctor exited $pcd_rc"
      ;;
  esac
  pcd_dir=""
  pcd_json_rc=0
  pcd_dir=$(json_query "$pcd_json" '((d.checks||[]).find(c=>c.id==="launch_environment")||{}).data?.value ?? ""' 2>/dev/null) || pcd_json_rc=$?
  pcd_fail=""
  if [ "$pcd_rc" -eq 5 ] && [ "$pcd_json_rc" -eq 0 ]; then
    pcd_fail=$(json_query "$pcd_json" '(d.checks||[]).filter(c=>c.status==="fail").map(c=>c.id)' 2>/dev/null) || pcd_fail=""
  fi
  rm -f "$pcd_json"
  if [ "$pcd_json_rc" -ne 0 ]; then
    die "$EX_STEP" profile "agent-profile claude doctor printed output that is not JSON"
  fi
  if [ "$pcd_rc" -eq 5 ]; then
    log WARN profile "agent-profile doctor reports failing checks ($(printf '%s' "$pcd_fail" | tr '\n' ' ')); create decides"
  fi
  if profile_dir_shared "$pcd_dir"; then
    die "$EX_STEP" profile "agent-profile did not report a profile-specific CLAUDE_CONFIG_DIR"
  fi
  printf '%s\n' "$pcd_dir"
}

# profile_create NAME: runs `agent-profile claude create NAME`; prints "exists" when the profile was already
# there and "created" otherwise. A failure dies EX_STEP with the end of the output, bounded to 4000 characters
# (log redacts secrets).
profile_create() {
  pcr_out=$(mktemp "${TMPDIR:-/tmp}/rea-setup-out.XXXXXX") || die "$EX_STEP" profile "cannot create a temporary file"
  pcr_err=$(mktemp "${TMPDIR:-/tmp}/rea-setup-err.XXXXXX") || {
    rm -f "$pcr_out"
    die "$EX_STEP" profile "cannot create a temporary file"
  }
  log DEBUG profile "run: agent-profile claude create $1"
  pcr_rc=0
  agent-profile claude create "$1" >"$pcr_out" 2>"$pcr_err" || pcr_rc=$?
  log DEBUG profile "exit $pcr_rc"
  pcr_text=$(cat "$pcr_out" "$pcr_err")
  rm -f "$pcr_out" "$pcr_err"
  if [ "$pcr_rc" -ne 0 ]; then
    pcr_tail=$(printf '%s' "$pcr_text" | tail -c 4000)
    die "$EX_STEP" profile "agent-profile claude create exited $pcr_rc: $pcr_tail"
  fi
  case "$pcr_text" in
    *"already exists"*) echo exists ;;
    *) echo created ;;
  esac
}

# step_profile: finds the profile's CLAUDE_CONFIG_DIR with agent-profile doctor, creates the profile when it is
# not there yet and requires the directory to exist. Sets CLAUDE_CONFIG_DIR_SELECTED and SUMMARY_profile. A
# dry run only runs doctor (read-only); --check-upstream skips the step. It never touches ~/.claude or
# ~/.claude.json.
step_profile() {
  if [ "${OPT_CHECK_UPSTREAM:-0}" -eq 1 ]; then
    log INFO profile "skip (--check-upstream)"
    summary_set profile "skipped: --check-upstream"
    return 0
  fi
  if ! command -v agent-profile >/dev/null 2>&1; then
    if [ "${OPT_DRY_RUN:-0}" -eq 1 ]; then
      log INFO profile "agent-profile is not installed (read-only run); would run doctor and create"
      summary_set profile "not checked: agent-profile is not installed (read-only run)"
      return 0
    fi
    die "$EX_STEP" profile "agent-profile not found on PATH after the tools-bin step"
  fi
  sp_dir=$(profile_config_dir "$OPT_PROFILE") || exit "$?"
  if [ "${OPT_DRY_RUN:-0}" -eq 1 ]; then
    CLAUDE_CONFIG_DIR_SELECTED=$sp_dir
    export CLAUDE_CONFIG_DIR_SELECTED
    log INFO profile "would use $(abbrev_home "$sp_dir") (read-only run, nothing created)"
    summary_set profile "would use $sp_dir (not created: read-only run)"
    return 0
  fi
  sp_made=$(profile_create "$OPT_PROFILE") || exit "$?"
  [ -d "$sp_dir" ] || die "$EX_STEP" profile "the profile directory does not exist after create: $sp_dir"
  CLAUDE_CONFIG_DIR_SELECTED=$sp_dir
  export CLAUDE_CONFIG_DIR_SELECTED
  if [ "$sp_made" = exists ]; then
    log INFO profile "skip (already exists): $(abbrev_home "$sp_dir")"
    summary_set profile "reused $OPT_PROFILE: $sp_dir"
  else
    log INFO profile "created $OPT_PROFILE: $(abbrev_home "$sp_dir")"
    summary_set profile "created $OPT_PROFILE: $sp_dir"
  fi
  log INFO profile "ok"
  return 0
}

# --- steps rea-setup and rea-doctor ---

HINT_REA_GHIDRA_LINE='rea 6.8.0 accepts Ghidra 12.1.x; if rea now requires another line, update the pins block (PIN_GHIDRA_*)'
NOTE_MAC_DECOMPILER='build it as rea docs/installation.md describes (sections "Missing macOS native decompiler" and "macOS arm64 native decompiler")'

# rea_env_ready STEP: the three directories rea needs are known and the profile directory is not the shared
# ~/.claude; dies EX_STEP otherwise (defence in depth: the setup must never write in the shared profile).
rea_env_ready() {
  [ -n "${CLAUDE_CONFIG_DIR_SELECTED:-}" ] || die "$EX_STEP" "$1" "no profile directory was selected (CLAUDE_CONFIG_DIR_SELECTED is empty)"
  if profile_dir_shared "$CLAUDE_CONFIG_DIR_SELECTED"; then
    die "$EX_STEP" "$1" "refusing to run rea with the shared Claude directory: $CLAUDE_CONFIG_DIR_SELECTED"
  fi
  [ -n "${GHIDRA_DIR_SELECTED:-}" ] || die "$EX_STEP" "$1" "no Ghidra directory was selected (GHIDRA_DIR_SELECTED is empty)"
  [ -n "${JAVA_HOME_SELECTED:-}" ] || die "$EX_STEP" "$1" "no JDK was selected (JAVA_HOME_SELECTED is empty)"
  return 0
}

# rea_env_run STEP ARGS...: runs `npx -y $PIN_REA_SPEC ARGS...` through run_cmd with CLAUDE_CONFIG_DIR,
# GHIDRA_INSTALL_DIR and JAVA_HOME set for that child only. Returns its exit code; stdout is in RUN_STDOUT.
rea_env_run() {
  re_step=$1
  shift
  run_cmd "$re_step" env "CLAUDE_CONFIG_DIR=$CLAUDE_CONFIG_DIR_SELECTED" "GHIDRA_INSTALL_DIR=$GHIDRA_DIR_SELECTED" \
    "JAVA_HOME=$JAVA_HOME_SELECTED" npx -y "$PIN_REA_SPEC" "$@"
}

# rea_json_object FILE: succeeds when FILE holds a JSON object
rea_json_object() {
  [ "$(json_query "$1" '(d!==null&&typeof d==="object"&&!Array.isArray(d))' 2>/dev/null)" = true ]
}

# rea_doctor_healthy FILE: succeeds when the doctor answer in FILE has healthy true; anything else (false,
# missing, not JSON) fails
rea_doctor_healthy() {
  [ "$(json_query "$1" 'd.healthy===true' 2>/dev/null)" = true ]
}

# rea_doctor_failing FILE: the names of the scope_checks whose ok is not true, one per line
rea_doctor_failing() {
  json_query "$1" '(d.scope_checks||[]).filter(c=>c&&c.ok!==true).map(c=>c.name)' 2>/dev/null
}

# rea_ghidra_status FILE: prints `available providerVersion failing-check-names` for the ghidra provider of a
# doctor answer: available is true or false, the version is - when there is none, the names are comma separated
# and absent when nothing fails. A missing ghidra provider reads as unavailable with the check name
# ghidra_provider_missing.
rea_ghidra_status() {
  json_query "$1" '(()=>{const p=(d.providerInspections||[]).find(x=>x&&x.id==="ghidra");if(!p)return "false - ghidra_provider_missing";const f=(p.checks||[]).filter(c=>c&&c.ok!==true).map(c=>c.name).join(",");return String(p.available===true)+" "+(p.providerVersion||"-")+(f?" "+f:"")})()'
}

# rea_log_json STEP LABEL FILE: the raw doctor answer in FILE to the log (DEBUG: the file, not the console at
# INFO), bounded to 200000 characters with a marker; log redacts secrets and abbreviates the home directory.
rea_log_json() {
  lj_text=$(head -c 200000 "$3")
  lj_size=$(wc -c <"$3" | tr -d ' ')
  if [ "$lj_size" -gt 200000 ]; then
    lj_text="$lj_text [output truncated at 200000 characters]"
  fi
  log DEBUG "$1" "$2 output: $lj_text"
}

# rea_doctor_run STEP ARGS...: rea doctor ARGS... through rea_env_run. Exit 0 and 1 are both read (1 is how rea
# reports an unhealthy answer, and its JSON names what failed); any other exit code, and an answer that is not
# a JSON object, die EX_VERIFY with the end of stderr. The raw answer goes to the log. RD_JSON holds the answer
# file (registered for cleanup) and RD_RC the exit code; the caller decides the verdict from both.
rea_doctor_run() {
  rr_step=$1
  shift
  RD_RC=0
  rea_env_run "$rr_step" doctor "$@" || RD_RC=$?
  RD_JSON=$RUN_STDOUT
  rea_log_json "$rr_step" "rea doctor $*" "$RD_JSON"
  case "$RD_RC" in
    0 | 1) ;;
    *) die "$EX_VERIFY" "$rr_step" "rea doctor $* exited $RD_RC: $RUN_STDERR_TAIL" ;;
  esac
  rea_json_object "$RD_JSON" || die "$EX_VERIFY" "$rr_step" "rea doctor $* printed output that is not a JSON object (exit $RD_RC): $RUN_STDERR_TAIL"
  return 0
}

# step_rea_setup: registers rea in the profile with `rea setup`. A dry run of rea first (stdout at DEBUG), then
# the real setup unless --dry-run; --install-hopper is passed on when asked. The profile's .claude.json must then
# hold mcpServers.rea. It never touches ~/.claude.json: CLAUDE_CONFIG_DIR points rea at the profile.
step_rea_setup() {
  if [ "${OPT_CHECK_UPSTREAM:-0}" -eq 1 ]; then
    log INFO rea-setup "skip (--check-upstream)"
    summary_set rea_setup "skipped: --check-upstream"
    return 0
  fi
  if [ "${OPT_DRY_RUN:-0}" -eq 1 ] && { [ -z "${CLAUDE_CONFIG_DIR_SELECTED:-}" ] || [ -z "${GHIDRA_DIR_SELECTED:-}" ] || [ -z "${JAVA_HOME_SELECTED:-}" ]; }; then
    log INFO rea-setup "skip (read-only run: no profile, Ghidra or JDK was selected, so rea has no environment to run in)"
    summary_set rea_setup "skipped: read-only run"
    return 0
  fi
  rea_env_ready rea-setup
  rs_rc=0
  rea_env_run rea-setup setup --client claude_code --dry-run || rs_rc=$?
  log DEBUG rea-setup "rea setup dry-run output: $(head -c 4000 "$RUN_STDOUT")"
  rm -f "$RUN_STDOUT"
  [ "$rs_rc" -eq 0 ] || die "$EX_STEP" rea-setup "rea setup --dry-run exited $rs_rc: $RUN_STDERR_TAIL"
  if [ "${OPT_DRY_RUN:-0}" -eq 1 ]; then
    log INFO rea-setup "skip (read-only run): rea setup would register rea in $(abbrev_home "$CLAUDE_CONFIG_DIR_SELECTED")"
    summary_set rea_setup "not run: read-only run"
    return 0
  fi
  if [ "${OPT_INSTALL_HOPPER:-0}" -eq 1 ]; then
    rea_env_run rea-setup setup --client claude_code --yes --install-hopper || rs_rc=$?
  else
    rea_env_run rea-setup setup --client claude_code --yes || rs_rc=$?
  fi
  rm -f "$RUN_STDOUT"
  [ "$rs_rc" -eq 0 ] || die "$EX_STEP" rea-setup "rea setup exited $rs_rc: $RUN_STDERR_TAIL"
  rs_cfg=$CLAUDE_CONFIG_DIR_SELECTED/.claude.json
  [ -f "$rs_cfg" ] || die "$EX_STEP" rea-setup "rea setup left no .claude.json in $CLAUDE_CONFIG_DIR_SELECTED"
  rs_reg=$(json_query "$rs_cfg" '(d&&d.mcpServers&&d.mcpServers.rea&&typeof d.mcpServers.rea==="object")?"yes":"no"' 2>/dev/null) || rs_reg=unreadable
  [ "$rs_reg" = yes ] || die "$EX_STEP" rea-setup "$rs_cfg has no mcpServers.rea after rea setup ($rs_reg)"
  summary_set rea_setup "registered rea in $CLAUDE_CONFIG_DIR_SELECTED"
  log INFO rea-setup "ok"
  return 0
}

# step_rea_doctor: rea doctor for the client scope (healthy, else EX_VERIFY naming the failing scope_checks),
# then for the ghidra provider. A Ghidra that is not available is EX_VERIFY, except on macOS when only
# native_decompiler fails: that is a WARN with the recipe pointer and SUMMARY_rea_doctor=warn (the official
# archive has no macOS native decompiler), reported on every run. Skipped by --dry-run and --check-upstream.
step_rea_doctor() {
  if [ "${OPT_CHECK_UPSTREAM:-0}" -eq 1 ]; then
    log INFO rea-doctor "skip (--check-upstream)"
    summary_set rea_doctor "skipped: --check-upstream"
    return 0
  fi
  if [ "${OPT_DRY_RUN:-0}" -eq 1 ]; then
    log INFO rea-doctor "skip (--dry-run): nothing was registered to check"
    summary_set rea_doctor "skipped: --dry-run"
    return 0
  fi
  rea_env_ready rea-doctor
  rea_doctor_run rea-doctor --client claude_code --skill --json
  rd_file=$RD_JSON
  rd_healthy=0
  rea_doctor_healthy "$rd_file" && rd_healthy=1
  if [ "$rd_healthy" -eq 0 ]; then
    rd_names=$(rea_doctor_failing "$rd_file" | tr '\n' ' ')
    die "$EX_VERIFY" rea-doctor "rea doctor reports the Claude Code setup unhealthy (exit $RD_RC); failing checks: ${rd_names:-none listed (healthy is not true)}"
  fi
  if [ "$RD_RC" -ne 0 ]; then
    die "$EX_VERIFY" rea-doctor "rea doctor exited $RD_RC but its JSON says healthy is true: the exit code and the JSON disagree"
  fi
  rea_doctor_run rea-doctor --provider ghidra --json
  rd_file=$RD_JSON
  rd_status=$(rea_ghidra_status "$rd_file") || rd_status=""
  rd_avail=${rd_status%% *}
  rd_rest=${rd_status#* }
  rd_ver=${rd_rest%% *}
  rd_names=""
  case "$rd_rest" in
    *" "*) rd_names=${rd_rest#* } ;;
  esac
  log DEBUG rea-doctor "ghidra provider: available=$rd_avail version=$rd_ver failing=${rd_names:-none} exit=$RD_RC"
  if [ "$rd_avail" = true ]; then
    if [ "$RD_RC" -ne 0 ]; then
      die "$EX_VERIFY" rea-doctor "rea doctor exited $RD_RC but its JSON says the Ghidra provider is available: the exit code and the JSON disagree"
    fi
    summary_set rea_doctor "ok: ghidra $rd_ver"
    log INFO rea-doctor "ok"
    return 0
  fi
  if [ "$OS" = mac ] && [ "$rd_names" = native_decompiler ]; then
    log WARN rea-doctor "rea reports the native decompiler of $GHIDRA_DIR_SELECTED missing; $NOTE_MAC_DECOMPILER. rea cannot decompile until then; continuing"
    summary_set rea_doctor "warn: ghidra installed but not usable by rea until the native decompiler is built ($GHIDRA_DIR_SELECTED)"
    return 0
  fi
  case ",$rd_names," in
    *,version,*) die "$EX_VERIFY" rea-doctor "rea reports the Ghidra provider unavailable; failing checks: $rd_names. $HINT_REA_GHIDRA_LINE" ;;
  esac
  die "$EX_VERIFY" rea-doctor "rea reports the Ghidra provider unavailable; failing checks: ${rd_names:-none listed}"
}

# --- plan phase: resolution and validity checks only, no download and no write ---

PLAN_tools_bin=""
PLAN_jdk=""
PLAN_ghidra=""
PLAN_tools_bin_text=""
PLAN_jdk_text=""
PLAN_ghidra_text=""
PLAN_jdk_bytes=0
PLAN_ghidra_bytes=0
# the size of the Temurin 21 archive (208 MiB, measured) when the release listing gave none
JDK_DOWNLOAD_ESTIMATE_BYTES=218103808

# mb_of BYTES: BYTES in megabytes (MiB), one decimal
mb_of() {
  awk -v b="$1" 'BEGIN { printf "%.1f", b / 1048576 }'
}

# tools_bin_decide NAME LATEST: prints install, update or reuse for one managed tool
tools_bin_decide() {
  td_have=$(installed_version "$1")
  if [ -z "$td_have" ]; then
    echo install
  elif [ "$(semver_compare "$td_have" "$2")" = -1 ]; then
    echo update
  else
    echo reuse
  fi
}

# tools_bin_plan: resolves the latest agent-profile and clavity-ls (the answers are kept for step_tools_bin) and
# sets PLAN_tools_bin to install (one is missing), update (one is behind) or reuse. Skipped by --check-upstream.
tools_bin_plan() {
  if [ "${OPT_CHECK_UPSTREAM:-0}" -eq 1 ]; then
    return 0
  fi
  resolve_agent_profile "$OS" "$ARCH" || die "$EX_PLATFORM" tools-bin "no agent-profile build for $OS $ARCH"
  resolve_clavity_ls "$OS" "$ARCH" || die "$EX_PLATFORM" tools-bin "no clavity-ls build for $OS $ARCH"
  TB_PLANNED=1
  tp_ap=$(tools_bin_decide agent-profile "$AP_VERSION")
  tp_cl=$(tools_bin_decide clavity-ls "$CL_VERSION")
  PLAN_tools_bin=reuse
  case "$tp_ap $tp_cl" in
    *install*) PLAN_tools_bin=install ;;
    *update*) PLAN_tools_bin=update ;;
  esac
  PLAN_tools_bin_text="agent-profile $AP_VERSION ($tp_ap), clavity-ls $CL_VERSION ($tp_cl) in $BIN_DIR"
  log INFO plan "tools-bin: $PLAN_tools_bin ($PLAN_tools_bin_text)"
}

# jdk_plan: sets PLAN_jdk to reuse (jdk_choose picked one) or install (the release is resolved; the answer is
# kept for jdk_install) and PLAN_jdk_bytes to the download size
jdk_plan() {
  if [ "${OPT_CHECK_UPSTREAM:-0}" -eq 1 ]; then
    return 0
  fi
  if jdk_choose; then
    PLAN_jdk=reuse
    PLAN_jdk_bytes=0
    PLAN_jdk_text=$JAVA_HOME_SELECTED
  else
    jdk_resolve
    JDK_PLANNED=1
    PLAN_jdk=install
    PLAN_jdk_bytes=${JDK_BYTES:-$JDK_DOWNLOAD_ESTIMATE_BYTES}
    PLAN_jdk_text="$JDK_RELEASE into $TOOLS_DIR"
  fi
  log INFO plan "jdk: $PLAN_jdk ($PLAN_jdk_text)"
}

# ghidra_plan: sets PLAN_ghidra to reuse (ghidra_choose picked one) or install, and PLAN_ghidra_bytes
ghidra_plan() {
  if [ "${OPT_CHECK_UPSTREAM:-0}" -eq 1 ]; then
    return 0
  fi
  if ghidra_choose; then
    PLAN_ghidra=reuse
    PLAN_ghidra_bytes=0
    PLAN_ghidra_text=$GHIDRA_DIR_SELECTED
  else
    PLAN_ghidra=install
    PLAN_ghidra_bytes=$PIN_GHIDRA_ZIP_BYTES
    PLAN_ghidra_text="Ghidra $PIN_GHIDRA_VERSION into $TOOLS_DIR/$PIN_GHIDRA_TOPDIR"
  fi
  log INFO plan "ghidra: $PLAN_ghidra ($PLAN_ghidra_text)"
}

# plan_needed_mb: the free space the pending installs need: 1500 for Ghidra, 600 for the JDK, 200 for the rest
plan_needed_mb() {
  need_mb=200
  if [ "$PLAN_ghidra" = install ]; then
    need_mb=$((need_mb + 1500))
  fi
  if [ "$PLAN_jdk" = install ]; then
    need_mb=$((need_mb + 600))
  fi
  echo "$need_mb"
}

# print_disclosures: the four things the user is told before anything is downloaded (spec section 10)
print_disclosures() {
  pd_bytes=$((PLAN_ghidra_bytes + PLAN_jdk_bytes))
  printf 'Before anything is changed, please note:\n'
  if [ "$pd_bytes" -gt 0 ]; then
    printf '  1. Download: %s MB in total (Ghidra %s MB, JDK %s MB), unpacked under %s; agent-profile and clavity-ls go to %s when they are new or outdated.\n' \
      "$(mb_of "$pd_bytes")" "$(mb_of "$PLAN_ghidra_bytes")" "$(mb_of "$PLAN_jdk_bytes")" "$TOOLS_DIR" "$BIN_DIR"
  else
    printf '  1. Download: nothing for Ghidra and the JDK (both are already there); agent-profile and clavity-ls go to %s when they are new or outdated.\n' "$BIN_DIR"
  fi
  printf '  2. clavity-ls start always runs agy with --dangerously-skip-permissions, and agy is not isolated by the profile (it shares ~/.gemini/antigravity-cli/).\n'
  printf '  3. --install-hopper may ask for administrator rights and installs commercial demo software.\n'
  printf '  4. npx -y rea-agents@latest downloads and runs the newest published npm package with your rights.\n'
}

# plan_line STEP TEXT: one line of the plan
plan_line() {
  printf '  %-10s %s\n' "$1:" "$2"
}

# plan_phrase PLAN TEXT: would install, would update, would reuse or skip, then TEXT
plan_phrase() {
  case "$1" in
    install | update | reuse) printf 'would %s %s\n' "$1" "$2" ;;
    *) printf 'skip %s\n' "$2" ;;
  esac
}

# plan_summary: one line per step
plan_summary() {
  printf 'Plan:\n'
  plan_line tools-bin "$(plan_phrase "$PLAN_tools_bin" "$PLAN_tools_bin_text")"
  plan_line jdk "$(plan_phrase "$PLAN_jdk" "$PLAN_jdk_text ($(mb_of "$PLAN_jdk_bytes") MB)")"
  plan_line ghidra "$(plan_phrase "$PLAN_ghidra" "$PLAN_ghidra_text ($(mb_of "$PLAN_ghidra_bytes") MB)")"
  plan_line profile "would create or reuse the agent-profile profile $OPT_PROFILE"
  plan_line rea-setup "would register rea in that profile"
  plan_line rea-doctor "would check the registration and Ghidra"
  if [ "$OPT_NO_LAUNCH" -eq 1 ]; then
    plan_line launch "skip (--no-launch)"
  else
    plan_line launch "would start clavity-ls on $OPT_FOLDER"
  fi
}

# plan_confirm: the free-space check for every pending install at once, the disclosures, the plan and the
# question. Declining prints `nothing changed` on stdout and exits 0. Skipped by --check-upstream; --dry-run
# prints and never asks.
plan_confirm() {
  if [ "${OPT_CHECK_UPSTREAM:-0}" -eq 1 ]; then
    return 0
  fi
  NEEDED_MB=$(plan_needed_mb)
  log DEBUG plan "free space needed: $NEEDED_MB MB"
  require_free_mb "$TOOLS_DIR" "$NEEDED_MB"
  print_disclosures >&2
  plan_summary >&2
  if [ "${OPT_DRY_RUN:-0}" -eq 1 ]; then
    log INFO plan "dry run: nothing will be changed"
    return 0
  fi
  if ! confirm "Proceed?"; then
    log INFO plan "declined"
    printf 'nothing changed\n'
    exit "$EX_OK"
  fi
  return 0
}

# --- env file, summary and launch ---

# shell_quote TEXT: TEXT in single quotes, each embedded ' written as '\'' (safe for any POSIX shell)
shell_quote() {
  sq_body=$(printf '%s' "$1" | sed "s/'/'\\\\''/g")
  printf "'%s'\\n" "$sq_body"
}

# write_env_files TOOLS_DIR: writes TOOLS_DIR/env.sh, which exports GHIDRA_INSTALL_DIR and JAVA_HOME and puts BIN_DIR
# first on PATH, for a terminal that does not inherit this script's environment. Written to a temporary file and
# renamed, mode 0644 (it holds no secret), over the old one on every run. A dry run writes nothing.
write_env_files() {
  ENV_FILE=""
  if [ "${OPT_CHECK_UPSTREAM:-0}" -eq 1 ]; then
    return 0
  fi
  we_file="$1/env.sh"
  if [ "${OPT_DRY_RUN:-0}" -eq 1 ]; then
    log INFO env "would write $we_file"
    return 0
  fi
  [ -n "${GHIDRA_DIR_SELECTED:-}" ] && [ -n "${JAVA_HOME_SELECTED:-}" ] ||
    die "$EX_STEP" env "cannot write $we_file: no Ghidra or JDK was selected"
  mkdir -p -- "$1" || die "$EX_STEP" env "cannot create directory: $1"
  we_tmp="$we_file.tmp.$$"
  register_tmp "$we_tmp"
  {
    printf '# Written by setup.sh on every run. Source it in a terminal that does not inherit its environment.\n'
    printf 'export GHIDRA_INSTALL_DIR=%s\n' "$(shell_quote "$GHIDRA_DIR_SELECTED")"
    printf 'export JAVA_HOME=%s\n' "$(shell_quote "$JAVA_HOME_SELECTED")"
    printf "export PATH=%s\":\$PATH\"\n" "$(shell_quote "$BIN_DIR")"
  } >"$we_tmp" || die "$EX_STEP" env "cannot write $we_tmp"
  chmod 644 "$we_tmp" || die "$EX_STEP" env "cannot set the mode of $we_tmp"
  mv -f -- "$we_tmp" "$we_file" || die "$EX_STEP" env "cannot move $we_tmp into place: $we_file"
  ENV_FILE=$we_file
  log INFO env "wrote $(abbrev_home "$we_file")"
}

# print_summary: what was installed, reused or skipped, where, and what to do next; on stdout, before the launch
print_summary() {
  if [ "${OPT_CHECK_UPSTREAM:-0}" -eq 1 ]; then
    return 0
  fi
  if [ "${OPT_DRY_RUN:-0}" -eq 1 ]; then
    printf 'Dry run: nothing was changed. Plan result:\n'
  else
    printf 'Setup summary:\n'
  fi
  printf '  profile:     %s\n' "$(summary_get profile)"
  printf '  tools-bin:   in %s\n' "$BIN_DIR"
  summary_get tools_bin | while IFS= read -r ps_line; do
    printf '               %s\n' "$ps_line"
  done
  printf '  jdk:         %s\n' "$(summary_get jdk)"
  printf '  ghidra:      %s\n' "$(summary_get ghidra)"
  printf '  rea setup:   %s\n' "$(summary_get rea_setup)"
  printf '  rea doctor:  %s\n' "$(summary_get rea_doctor)"
  printf '  log file:    %s\n' "$LOG_FILE"
  if [ -n "${ENV_FILE:-}" ]; then
    printf '  env file:    %s\n' "$ENV_FILE"
  else
    printf '  env file:    not written\n'
  fi
  printf 'Next:\n'
  printf '  clavity-ls start "%s" --profile %s\n' "$OPT_FOLDER" "$OPT_PROFILE"
  printf '  (to launch again, run this script again: it skips everything that is already in place)\n'
}

# launch_now: the clock of step_launch, in whole seconds (LAUNCH_CLOCK and LAUNCH_SHORT_SECS are test seams)
launch_now() {
  date +%s
}

LAUNCH_CLOCK=launch_now
LAUNCH_SHORT_SECS=10

# launch_instructions [soft]: the two-terminal flow, for a machine where clavity-ls cannot open a terminal itself;
# soft is for a start that failed quickly, where the message above may or may not be about a terminal
launch_instructions() {
  if [ "${1:-}" = soft ]; then
    printf 'If the message above says clavity-ls could not open a terminal, use two terminals:\n'
  else
    printf 'Setup is complete. clavity-ls cannot open a terminal here, so start it from two terminals.\n'
  fi
  printf 'Terminal 1:\n'
  printf '  . "%s/env.sh"\n' "$TOOLS_DIR"
  printf '  clavity-ls agy "%s"\n' "$OPT_FOLDER"
  printf 'Terminal 2:\n'
  printf '  . "%s/env.sh"\n' "$TOOLS_DIR"
  printf '  clavity-ls start "%s" --attach --profile %s\n' "$OPT_FOLDER" "$OPT_PROFILE"
  printf 'Use these commands exactly as written: the attach hint that clavity-ls agy prints omits --profile, and must not be used, because it would start Claude on your default profile.\n'
}

# step_launch: always the last step, and it exits with clavity-ls start's own exit code. --no-launch prints the
# command; macOS and a Linux without DISPLAY and WAYLAND_DISPLAY get the two-terminal flow (start would fail
# there); otherwise clavity-ls start runs with all stdio inherited and GHIDRA_INSTALL_DIR, JAVA_HOME and PATH in
# its environment only, and when it exits 1 in under LAUNCH_SHORT_SECS seconds the two-terminal flow is printed
# too, as a hint (the exit code stays the child's).
step_launch() {
  if [ "${OPT_CHECK_UPSTREAM:-0}" -eq 1 ]; then
    return 0
  fi
  if [ "${OPT_DRY_RUN:-0}" -eq 1 ]; then
    log INFO launch "would run: clavity-ls start \"$OPT_FOLDER\" --profile $OPT_PROFILE"
    exit "$EX_OK"
  fi
  if [ "${OPT_NO_LAUNCH:-0}" -eq 1 ]; then
    log INFO launch "skip (--no-launch)"
    printf 'launch skipped (--no-launch); run: clavity-ls start "%s" --profile %s\n' "$OPT_FOLDER" "$OPT_PROFILE"
    exit "$EX_OK"
  fi
  if [ "$OS" = mac ] || { [ "$OS" = linux ] && [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; }; then
    log INFO launch "no terminal can be opened from here: two-terminal instructions printed"
    launch_instructions
    exit "$EX_OK"
  fi
  log INFO launch "running clavity-ls start \"$OPT_FOLDER\" --profile $OPT_PROFILE"
  # No pipe, no copy and no substitution around the child: it has this script's stdin, stdout and stderr, so a
  # terminal window it opens (which keeps them open) cannot hold this script back once the child has exited.
  # Ctrl-C reaches the child too (same process group); this script waits for it and then reports its code
  trap ':' INT
  sl_t0=$("$LAUNCH_CLOCK")
  env "GHIDRA_INSTALL_DIR=$GHIDRA_DIR_SELECTED" "JAVA_HOME=$JAVA_HOME_SELECTED" "PATH=$BIN_DIR:$PATH" \
    clavity-ls start "$OPT_FOLDER" --profile "$OPT_PROFILE"
  sl_rc=$?
  sl_t1=$("$LAUNCH_CLOCK")
  log INFO launch "launch exited $sl_rc"
  # exit 1 within LAUNCH_SHORT_SECS is how start fails to open a terminal (stderr is not read: see above)
  if [ "$sl_rc" -eq 1 ] && [ $((sl_t1 - sl_t0)) -lt "$LAUNCH_SHORT_SECS" ]; then
    launch_instructions soft
  fi
  exit "$sl_rc"
}

# --- step check-upstream ---

# cu_sidecar URL: prints the SHA-256 held by the sidecar file at URL (redirects resolved, the small file
# fetched into a temporary file that is removed); fails when it cannot be fetched or holds no 64-hex token
cu_sidecar() {
  cs_final=$(resolve_redirects "$1") || return 1
  cs_tmp=$(mktemp "${TMPDIR:-/tmp}/rea-setup-sc.XXXXXX") || return 1
  register_tmp "$cs_tmp"
  cs_hash=""
  if http_get "$cs_final" "$cs_tmp"; then
    cs_hash=$(sidecar_sha256 "$cs_tmp") || cs_hash=""
  fi
  rm -f "$cs_tmp"
  [ -n "$cs_hash" ] || return 1
  printf '%s\n' "$cs_hash"
}

# cu_headers URL [CURL_ARG...]: the response headers of one request, lower-cased, CR removed. -I is a HEAD; a
# ranged GET passes -r 0-0 -D - -o /dev/null instead. --max-filesize makes curl refuse a body it was told is
# large, so a server that ignores the range still sends nothing.
cu_headers() {
  ch_url=$1
  shift
  "$CURL" -q -sS --proto "$(net_proto)" --tlsv1.2 --connect-timeout 20 --max-time 60 "$@" "$ch_url" 2>/dev/null |
    tr -d '\r' | tr '[:upper:]' '[:lower:]'
}

# cu_content_length URL: prints the size in bytes of the file at URL without fetching it: the Content-Length of
# a HEAD or, when the HEAD is refused (403, 405), the total of the Content-Range of a one-byte GET; 5xx and a
# failed connection are retried like http_get does. Fails when no size can be read.
cu_content_length() {
  cc_url=$1
  cc_try=0
  for cc_w in $RETRY_WAITS; do
    cc_try=$((cc_try + 1))
    cc_hdr=$(cu_headers "$cc_url" -I) || cc_hdr=""
    cc_code=$(printf '%s\n' "$cc_hdr" | sed -n '1s/^http[^ ]* \([0-9][0-9]*\).*/\1/p')
    case "$cc_code" in
      403 | 405)
        cc_hdr=$(cu_headers "$cc_url" -r 0-0 -D - -o /dev/null --max-filesize 1000) || cc_hdr=""
        cc_code=$(printf '%s\n' "$cc_hdr" | sed -n '1s/^http[^ ]* \([0-9][0-9]*\).*/\1/p')
        ;;
    esac
    log DEBUG check-upstream "size of $cc_url -> ${cc_code:-000}"
    case "$cc_code" in
      200)
        printf '%s\n' "$cc_hdr" | sed -n 's/^content-length:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | tail -n 1
        return 0
        ;;
      206)
        printf '%s\n' "$cc_hdr" | sed -n 's/^content-range:[[:space:]]*bytes[[:space:]]*[0-9]*-[0-9]*\/\([0-9][0-9]*\).*/\1/p' | tail -n 1
        return 0
        ;;
      5?? | '') ;;
      *) return 1 ;;
    esac
    [ "$cc_try" -lt "$(printf '%s\n' "$RETRY_WAITS" | wc -w | tr -d ' ')" ] || return 1
    "$SLEEP" "$cc_w"
  done
  return 1
}

# rea_supported_ghidra: the Ghidra version the latest rea-agents release says it supports, read from
# SUPPORTED_GHIDRA_VERSION in the source of its tag; dies EX_VERIFY when that is not PIN_GHIDRA_VERSION, or when
# the registry answer, the file or the constant is missing. Prints the ok line.
rea_supported_ghidra() {
  rg_tmp=$(mktemp "${TMPDIR:-/tmp}/rea-setup-rea.XXXXXX") || die "$EX_STEP" check-upstream "cannot create a temporary file"
  register_tmp "$rg_tmp"
  rg_npm=https://registry.npmjs.org/rea-agents/latest
  http_get "$rg_npm" "$rg_tmp" || die "$EX_VERIFY" check-upstream "cannot read the latest rea-agents release from $rg_npm"
  # The JavaScript test is anchored to the whole string (no multi-line match, a string and not a number), and the
  # case below repeats it without trusting the tool: only digits and exactly two dots, none leading, trailing or
  # doubled, can reach the URL.
  rg_ver=$(json_query "$rg_tmp" 'typeof d.version==="string"&&/^[0-9]+\.[0-9]+\.[0-9]+$/.test(d.version)?d.version:""' 2>/dev/null) || rg_ver=""
  case "$rg_ver" in
    '' | *[!0-9.]* | .* | *. | *..* | *.*.*.*) rg_ver="" ;;
    *.*.*) ;;
    *) rg_ver="" ;;
  esac
  if [ -z "$rg_ver" ]; then
    die "$EX_VERIFY" check-upstream "no X.Y.Z version in the answer of $rg_npm"
  fi
  rg_src="https://raw.githubusercontent.com/morluto/rea/rea-agents-$rg_ver/src/ghidra/GhidraReleasePolicy.ts"
  http_get "$rg_src" "$rg_tmp" || die "$EX_VERIFY" check-upstream "cannot read $rg_src"
  rg_ghidra=$(sed -n -E 's/^(.*[^A-Za-z0-9_])?SUPPORTED_GHIDRA_VERSION[[:space:]]*=[[:space:]]*"([0-9.]+)".*$/\2/p' "$rg_tmp" | head -n 1)
  rm -f "$rg_tmp"
  [ -n "$rg_ghidra" ] || die "$EX_VERIFY" check-upstream "no SUPPORTED_GHIDRA_VERSION constant in $rg_src"
  if [ "$rg_ghidra" != "$PIN_GHIDRA_VERSION" ]; then
    die "$EX_VERIFY" check-upstream "rea $rg_ver now supports Ghidra $rg_ghidra; update PIN_GHIDRA_*"
  fi
  printf 'ok rea_supported_ghidra: rea-agents %s supports Ghidra %s\n' "$rg_ver" "$rg_ghidra"
}

# cu_agent_profile: the latest aiprofiles release has the asset for this host and a 64-hex sidecar
cu_agent_profile() {
  resolve_agent_profile "$OS" "$ARCH" || die "$EX_PLATFORM" check-upstream "no agent-profile build for $OS $ARCH"
  resolve_redirects "$AP_URL" >/dev/null || die "$EX_VERIFY" check-upstream "the agent-profile asset is missing: $AP_URL"
  cu_hash=$(cu_sidecar "$AP_SIDECAR_URL") || die "$EX_VERIFY" check-upstream "no SHA-256 in the sidecar $AP_SIDECAR_URL"
  printf 'ok agent-profile: %s %s sha256 %s\n' "$AP_TAG" "$AP_ASSET" "$cu_hash"
}

# cu_clavity_ls: the latest clavity release has exactly one asset for this host and a 64-hex sidecar
cu_clavity_ls() {
  resolve_clavity_ls "$OS" "$ARCH" || die "$EX_PLATFORM" check-upstream "no clavity-ls build for $OS $ARCH"
  cu_hash=$(cu_sidecar "$CL_SIDECAR_URL") || die "$EX_VERIFY" check-upstream "no SHA-256 in the sidecar $CL_SIDECAR_URL"
  printf 'ok clavity-ls: %s %s sha256 %s\n' "$CL_TAG" "$CL_ASSET" "$cu_hash"
}

# cu_adoptium: the Adoptium API answers a Temurin 21 release for this host and its .sha256.txt sidecar equals
# the checksum of the API
cu_adoptium() {
  cu_rc=0
  adoptium_resolve "$OS" "$ARCH" || cu_rc=$?
  case "$cu_rc" in
    0) ;;
    2) die "$EX_VERIFY" check-upstream "the Adoptium API did not answer for $OS $ARCH" ;;
    *) die "$EX_VERIFY" check-upstream "the Adoptium answer for $OS $ARCH failed validation" ;;
  esac
  cu_sc=${JDK_SIDECAR_URL:-$JDK_URL.sha256.txt}
  cu_hash=$(cu_sidecar "$cu_sc") || die "$EX_VERIFY" check-upstream "no SHA-256 in the sidecar $cu_sc"
  if [ "$cu_hash" != "$JDK_SHA256" ]; then
    die "$EX_VERIFY" check-upstream "the sidecar $cu_sc says $cu_hash but the Adoptium API says $JDK_SHA256"
  fi
  printf 'ok adoptium: %s sha256 %s\n' "$JDK_RELEASE" "$cu_hash"
}

# cu_ghidra: PIN_GHIDRA_URL redirects to an allow-listed host and the file there has PIN_GHIDRA_ZIP_BYTES bytes
cu_ghidra() {
  cu_final=$(resolve_redirects "$PIN_GHIDRA_URL") || die "$EX_VERIFY" check-upstream "cannot resolve PIN_GHIDRA_URL $PIN_GHIDRA_URL"
  cu_len=$(cu_content_length "$cu_final") || die "$EX_VERIFY" check-upstream "cannot read the size of $cu_final"
  if [ "$cu_len" != "$PIN_GHIDRA_ZIP_BYTES" ]; then
    die "$EX_VERIFY" check-upstream "Ghidra $PIN_GHIDRA_VERSION is $cu_len bytes upstream but PIN_GHIDRA_ZIP_BYTES is $PIN_GHIDRA_ZIP_BYTES; update PIN_GHIDRA_*"
  fi
  printf 'ok ghidra: %s bytes at %s\n' "$cu_len" "$(url_host "$cu_final")"
}

# cu_run NAME FUNCTION: runs one expectation in a subshell (die exits only that), printing FAIL NAME when it
# fails. Whatever the cause (a broken expectation, an unreachable or unreadable upstream), a failure is a
# verification failure: CU_FIRST becomes EX_VERIFY, the exit status of the run (spec: exit 5 if any expectation breaks).
cu_run() {
  cr_rc=0
  (
    install_traps
    "$2"
  ) || cr_rc=$?
  if [ "$cr_rc" -ne 0 ]; then
    printf 'FAIL %s\n' "$1"
    CU_FIRST=$EX_VERIFY
  fi
}

# step_check_upstream: replaces the install steps with --check-upstream. Checks that what the pins assume still
# holds upstream, one `ok` or `FAIL` line per expectation on stdout, all of them even after a failure; exits
# with EX_VERIFY when any fails. Fetches no archive and writes nothing but the log.
step_check_upstream() {
  CU_FIRST=0
  cu_run agent-profile cu_agent_profile
  cu_run clavity-ls cu_clavity_ls
  cu_run adoptium cu_adoptium
  cu_run ghidra cu_ghidra
  cu_run rea_supported_ghidra rea_supported_ghidra
  if [ "$CU_FIRST" -ne 0 ]; then
    die "$CU_FIRST" check-upstream "upstream no longer matches the pins in this script"
  fi
  summary_set check_upstream ok
  log INFO check-upstream "ok"
  return 0
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
  # test seams must not be reachable from the caller's environment
  unset UNAME_S UNAME_M ARCHIVE_TAR ARCHIVE_ZIP_TOOL LOCK_POLLS REA_SETUP_NO_MAIN
  unset CLAUDE_CONFIG_DIR_SELECTED GHIDRA_DIR_SELECTED JAVA_HOME_SELECTED
  install_traps
  parse_args "$@"
  CONSOLE_LEVEL=$OPT_CONSOLE_LEVEL
  LOG_FILE=$(log_open)
  if [ "$LOG_FILE" != /dev/null ]; then
    log INFO preflight "log file: $(abbrev_home "$LOG_FILE")"
  fi
  main_sha=n/a
  if [ -f "$0" ] && { command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1; }; then
    main_sha=$(sha256_file "$0") || main_sha=n/a
  fi
  log DEBUG preflight "script version $PIN_SCRIPT_VERSION sha256 $main_sha"
  log DEBUG preflight "$(uname -a)"
  log DEBUG preflight "invoked: $0 $*"
  log_config
  step_preflight
  step_prereq
  if [ "$OPT_CHECK_UPSTREAM" -eq 1 ]; then
    step_check_upstream
    exit "$EX_OK"
  fi
  tools_bin_plan
  jdk_plan
  ghidra_plan
  plan_confirm
  step_tools_bin
  step_jdk
  step_ghidra
  tools_lock_release
  step_profile
  step_rea_setup
  step_rea_doctor
  write_env_files "$TOOLS_DIR"
  print_summary
  step_launch
}

if [ "${REA_SETUP_NO_MAIN:-}" != 1 ]; then
  main "$@"
fi
