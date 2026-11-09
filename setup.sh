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

# --- network ---

ALLOWED_SCHEMES=https
ALLOWED_HOSTS=$PIN_ALLOWED_HOSTS
RETRY_WAITS="2 4 8 16"
CURL="curl"

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
  hg_cfg=$(mktemp "${TMPDIR:-/tmp}/rea-setup-cfg.XXXXXX") || {
    rm -f "$hg_hdr"
    return 1
  }
  hg_err=$(mktemp "${TMPDIR:-/tmp}/rea-setup-err.XXXXXX") || {
    rm -f "$hg_hdr" "$hg_cfg"
    return 1
  }
  if [ -n "${GITHUB_TOKEN:-}" ] && [ "$(url_host "$hg_url")" = api.github.com ]; then
    printf 'header = "Authorization: Bearer %s"\n' "$GITHUB_TOKEN" >"$hg_cfg"
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
    if [ -n "$hg_ra" ] && [ "$hg_ra" -gt "$hg_wait" ]; then
      hg_wait=$hg_ra
    fi
    if [ "$hg_wait" -gt 120 ]; then
      hg_wait=120
    fi
    log DEBUG net "retrying in ${hg_wait}s"
    sleep "$hg_wait"
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
