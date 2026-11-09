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

# resolve_redirects URL: prints the final URL after at most 5 redirects, using HEAD (no body is fetched).
# A hop answering 405 or 403 to HEAD is asked again with a one-byte ranged GET. Every hop must pass
# url_allowed. Returns 1 for a disallowed hop, 2 for more than 5 redirects, 3 for any other failure.
resolve_redirects() {
  rr_url=$1
  rr_hops=0
  while :; do
    url_allowed "$rr_url" || {
      log ERROR net "redirect target not allowed: $rr_url"
      return 1
    }
    rr_resp=$("$CURL" -sS -I -o /dev/null -w '%{http_code} %{redirect_url}' --proto "$(net_proto)" --tlsv1.2 \
      --connect-timeout 20 --max-time 60 "$rr_url" 2>/dev/null) || rr_resp="000 "
    case "$rr_resp" in
      403* | 405*)
        rr_resp=$("$CURL" -sS -r 0-0 -o /dev/null -w '%{http_code} %{redirect_url}' --proto "$(net_proto)" --tlsv1.2 \
          --connect-timeout 20 --max-time 60 "$rr_url" 2>/dev/null) || rr_resp="000 "
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
    hg_code=$("$CURL" -sS -K "$hg_cfg" --proto "$(net_proto)" --tlsv1.2 --speed-limit 1024 --speed-time 60 \
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
  gl_loc=$("$CURL" -sS -I -o /dev/null -w '%{redirect_url}' --proto "$(net_proto)" --tlsv1.2 \
    --connect-timeout 20 --max-time 60 "$gl_url" 2>/dev/null) || return 1
  log DEBUG net "latest release of $1 -> $gl_loc"
  case "$gl_loc" in
    */releases/tag/?*) printf '%s\n' "${gl_loc##*/}" ;;
    *) return 1 ;;
  esac
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

# cleanup_orphans DIR: removes DIR/*.tmp.PID and DIR/*.old.PID (also the Windows script's leftovers) whose
# process is gone or whose modification time is over 24 hours old; logs each
cleanup_orphans() {
  co_dir=$1
  for co_path in "$co_dir"/*.tmp.* "$co_dir"/*.old.*; do
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

# prune_jdks TOOLS: keeps the two newest jdk-<digit>* directories that hold .install-complete or a release
# file (nothing else is ever touched) by release, and whichever one holds JAVA_HOME or
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
    # Only what an install made: the sentinel, or a JDK's own release file (also in the macOS layout)
    if [ ! -f "$pj_d/.install-complete" ] && [ ! -f "$pj_d/release" ] && [ ! -f "$pj_d/Contents/Home/release" ]; then
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

# summary_set ID VALUE / summary_get ID: the per-step outcome behind SUMMARY_<id> for the final summary
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
  install_traps
  parse_args "$@"
  CONSOLE_LEVEL=$OPT_CONSOLE_LEVEL
  LOG_FILE=$(log_open)
  log DEBUG preflight "script version $PIN_SCRIPT_VERSION sha256 n/a"
  log DEBUG preflight "$(uname -a)"
  log DEBUG preflight "invoked: $0 $*"
  log_config
  step_preflight
  step_prereq
}

if [ "${REA_SETUP_NO_MAIN:-}" != 1 ]; then
  main "$@"
fi
