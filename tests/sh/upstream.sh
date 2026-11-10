#!/bin/sh
# Copyright (c) 2026 Costas Kirgoussios
#
# This software is licensed under the PolyForm Noncommercial License 1.0.0.
# You may obtain a copy of the License at:
# https://polyformproject.org/licenses/noncommercial/1.0.0/

# Tests for --check-upstream: rea_supported_ghidra and step_check_upstream against the fake server of
# tests/integration (python3, loopback only). A curl wrapper maps every allow-listed host onto it, so the product
# code runs unchanged. The rea source file is the real GhidraReleasePolicy.ts (tests/fixtures). Every run proves
# that no archive was requested and that nothing was written under the tools, bin and home directories.
# The fixture tests/fixtures/GhidraReleasePolicy.ts is src/ghidra/GhidraReleasePolicy.ts of github.com/morluto/rea
# at the tag rea-agents-6.8.0, unchanged.
# shellcheck source=/dev/null
. "$(dirname "$0")/lib.sh"
cd "$ROOT" || exit 1

if ! command -v python3 >/dev/null 2>&1; then
  echo "upstream.sh: python3 is required" >&2
  exit 1
fi

T="$ROOT/tests/.tmp/upstream work $$"
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
unset GITHUB_TOKEN

ALLOWED_SCHEMES="https http"
ALLOWED_HOSTS="github.com api.github.com api.adoptium.net registry.npmjs.org raw.githubusercontent.com release-assets.githubusercontent.com 127.0.0.1"
RETRY_WAITS="0 0"
SLEEP=true
OS=linux
ARCH=x64
OPT_DRY_RUN=0
OPT_CHECK_UPSTREAM=1
OPT_YES=1
TOOLS_DIR="$T/work/tools dir"
BIN_DIR="$T/work/bin dir"
HOME_DIR="$T/work/home dir"
TMP_DIR="$T/work/tmp dir"
LOG_FILE=$T/unit.log
CONSOLE_LEVEL=ERROR
CURL=curl_local
export CURL ALLOWED_SCHEMES ALLOWED_HOSTS RETRY_WAITS SLEEP OS ARCH OPT_DRY_RUN OPT_CHECK_UPSTREAM OPT_YES TOOLS_DIR BIN_DIR LOG_FILE CONSOLE_LEVEL
FIX=$ROOT/tests/fixtures
PIN_PATH=${PIN_GHIDRA_URL#https://}
REA_PATH=/raw.githubusercontent.com/morluto/rea/rea-agents-6.8.0/src/ghidra/GhidraReleasePolicy.ts
AP_ASSET=agent-profile-x86_64-unknown-linux-gnu.tar.gz
CL_ASSET=clavity-ls-linux-x64-0.17.0.tar.gz
JDK_ASSET=OpenJDK21U-jdk_x64_linux_hotspot_21.0.13_9.tar.gz

# curl_local ARG...: curl with every allow-listed host sent to the fake server (BASE) instead
curl_local() {
  cx_n=$#
  while [ "$cx_n" -gt 0 ]; do
    cx_a=$1
    shift
    case "$cx_a" in
      https://github.com/* | https://api.github.com/* | https://api.adoptium.net/* | https://registry.npmjs.org/* | https://raw.githubusercontent.com/* | https://release-assets.githubusercontent.com/*)
        cx_a="$BASE/${cx_a#https://}"
        ;;
    esac
    set -- "$@" "$cx_a"
    cx_n=$((cx_n - 1))
  done
  curl "$@"
}

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

HEX64=0000000000000000000000000000000000000000000000000000000000000000

# mk_up NAME [CASE]: builds the files and the scenario of a fake world in which every upstream expectation
# holds, except as CASE says, starts the server and sets BASE. CASES: policy-new (rea supports 12.2.0),
# policy-404, policy-noconst, npm-nover, len-bad (Content-Length one short), head405 (HEAD refused, the ranged
# GET answers the length), evil (the Ghidra redirect leaves the allow-list), ap-badsum, cl-two, jdk-diff, ap-gone (the latest-release page answers 410: unreachable upstream).
mk_up() {
  mu_name=$1
  mu_case=${2:-ok}
  mu_dir="$T/srv $mu_name"
  mkdir -p "$mu_dir"
  cp "$FIX/GhidraReleasePolicy.ts" "$mu_dir/policy.ts"
  sed 's/"12\.1\.4"/"12.2.0"/' "$FIX/GhidraReleasePolicy.ts" >"$mu_dir/policy-new.ts"
  grep -v 'SUPPORTED_GHIDRA_VERSION = ' "$FIX/GhidraReleasePolicy.ts" >"$mu_dir/policy-noconst.ts"
  printf '{"name":"rea-agents","version":"6.8.0"}\n' >"$mu_dir/npm.json"
  printf '{"name":"rea-agents"}\n' >"$mu_dir/npm-nover.json"
  printf '{"version":%s}\n' "${UP_NPM_RAW:-0}" >"$mu_dir/npm-raw.json"
  {
    printf 'export const MIN_SUPPORTED_GHIDRA_VERSION = "9.9";\n'
    cat "$FIX/GhidraReleasePolicy.ts"
  } >"$mu_dir/policy-min.ts"
  printf '%s  %s\n' "$HEX64" "$AP_ASSET" >"$mu_dir/ap.sha256"
  printf 'no checksum here\n' >"$mu_dir/ap-bad.sha256"
  printf '%s *%s\n' "$HEX64" "$CL_ASSET" >"$mu_dir/cl.sha256"
  printf '%s  x\n' "$HEX64" >"$mu_dir/jdk-diff.sha256"
  printf '{"tag_name":"clavity-v31","assets":[{"name":"%s"},{"name":"clavity-ls-linux-x64-0.18.0.tar.gz"}]}\n' "$CL_ASSET" >"$mu_dir/cl-two.json"
  printf 'x\n' >"$mu_dir/blob"
  mu_npm=npm.json
  mu_apsum=ap.sha256
  mu_cl="$FIX/github-release-clavity.json"
  mu_jdksum="$FIX/sidecar-temurin.sha256.txt"
  mu_gh='{"status":200,"body_file":"blob","content_length":569649598}'
  mu_aplatest='{"status":302,"location":"{base}/r/aiprofiles/releases/tag/v0.1.2"}'
  mu_ghhop='{"status":302,"location":"{base}/dl/ghidra.zip"}'
  mu_pol='{"status":200,"body_file":"policy.ts"}'
  case "$mu_case" in
    policy-new) mu_pol='{"status":200,"body_file":"policy-new.ts"}' ;;
    policy-404) mu_pol='{"status":404}' ;;
    policy-noconst) mu_pol='{"status":200,"body_file":"policy-noconst.ts"}' ;;
    npm-nover) mu_npm=npm-nover.json ;;
    npm-raw) mu_npm=npm-raw.json ;;
    policy-min) mu_pol='{"status":200,"body_file":"policy-min.ts"}' ;;
    tag-dots) mu_aplatest='{"status":302,"location":"{base}/r/aiprofiles/releases/tag/.."}' ;;
    len-bad) mu_gh='{"status":200,"body_file":"blob","content_length":569649597}' ;;
    head405) mu_gh='{"status":206,"head_status":405,"headers":{"Content-Range":"bytes 0-0/569649598"}}' ;;
    evil) mu_ghhop='{"status":302,"location":"https://evil.example/ghidra.zip"}' ;;
    ap-badsum) mu_apsum=ap-bad.sha256 ;;
    cl-two) mu_cl="$mu_dir/cl-two.json" ;;
    jdk-diff) mu_jdksum="$mu_dir/jdk-diff.sha256" ;;
    ap-gone) mu_aplatest='{"status":410}' ;;
    ok) ;;
  esac
  scn_start "$mu_dir/scenario.json"
  scn_ent /github.com/ckir/aiprofiles/releases/latest "$mu_aplatest"
  scn_ent "/github.com/ckir/aiprofiles/releases/latest/download/$AP_ASSET" '{"status":302,"location":"{base}/dl/ap.tgz"}'
  scn_ent "/github.com/ckir/aiprofiles/releases/latest/download/$AP_ASSET.sha256" '{"status":302,"location":"{base}/dl/ap.sha256"}'
  scn_ent /dl/ap.tgz '{"status":200,"body_file":"blob"}'
  scn_ent /dl/ap.sha256 "{\"status\":200,\"body_file\":\"$mu_apsum\"}"
  scn_ent /github.com/ckir/clavity/releases/latest '{"status":302,"location":"{base}/r/clavity/releases/tag/clavity-v31"}'
  scn_ent /api.github.com/repos/ckir/clavity/releases/latest "{\"status\":200,\"body_file\":\"$mu_cl\"}"
  scn_ent "/github.com/ckir/clavity/releases/download/clavity-v31/$CL_ASSET.sha256" '{"status":302,"location":"{base}/dl/cl.sha256"}'
  scn_ent /dl/cl.sha256 '{"status":200,"body_file":"cl.sha256"}'
  scn_ent "/api.adoptium.net/v3/assets/latest/21/hotspot?architecture=x64&image_type=jdk&os=linux&vendor=eclipse" "{\"status\":200,\"body_file\":\"$FIX/adoptium-linux-x64.json\"}"
  scn_ent "/github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.13%2B9/$JDK_ASSET.sha256.txt" "{\"status\":200,\"body_file\":\"$mu_jdksum\"}"
  scn_ent "/github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.13%2B9/$JDK_ASSET" '{"status":200,"body_file":"blob"}'
  scn_ent "/$PIN_PATH" "$mu_ghhop"
  scn_ent /dl/ghidra.zip "$mu_gh"
  scn_ent /registry.npmjs.org/rea-agents/latest "{\"status\":200,\"body_file\":\"$mu_npm\"}"
  scn_ent "$REA_PATH" "$mu_pol"
  scn_end
  python3 -I "$ROOT/tests/integration/fake_release_server.py" 0 "$mu_dir/scenario.json" >"$mu_dir/server.out" 2>"$mu_dir/server.err" &
  mu_pid=$!
  SRV_PIDS="$SRV_PIDS $mu_pid"
  mu_port=""
  mu_tries=0
  while [ -z "$mu_port" ] && [ "$mu_tries" -lt 100 ]; do
    mu_port=$(sed -n 's/^PORT //p' "$mu_dir/server.out" 2>/dev/null)
    [ -n "$mu_port" ] || sleep 0.1
    mu_tries=$((mu_tries + 1))
  done
  if [ -z "$mu_port" ]; then
    echo "upstream.sh: the fake server did not start" >&2
    echo "upstream.sh: server.out: $(cat "$mu_dir/server.out" 2>&1)" >&2
    cat "$mu_dir/server.err" >&2
    exit 1
  fi
  BASE=http://127.0.0.1:$mu_port
}

# count_of PATH: the GET requests the fake server has seen for PATH
count_of() {
  curl -sS "$BASE/__count$1"
}

# count_prefix PREFIX: the GET requests the fake server has seen for any path starting with PREFIX
count_prefix() {
  curl -sS "$BASE/__countprefix$1"
}

# run_cu NAME CMD...: runs CMD in a subshell with the curl wrapper; stdout to $T/NAME.out, stderr and the log
# to $T/NAME.err and $T/NAME.log; prints the exit status
run_cu() {
  ru_n=$1
  shift
  ru_rc=0
  : >"$T/$ru_n.log"
  (
    LOG_FILE=$T/$ru_n.log
    install_traps
    "$@"
  ) >"$T/$ru_n.out" 2>"$T/$ru_n.err" || ru_rc=$?
  echo "$ru_rc"
}

# tree_of DIR: every entry under DIR, one per line (nothing when DIR is absent)
tree_of() {
  if [ -e "$1" ]; then
    find "$1" -print
  fi
}

# --- rea_supported_ghidra ---
mk_up supported ok
rc=$(run_cu sup1 rea_supported_ghidra)
assert_eq 0 "$rc" "rea_supported_ghidra: 6.8.0 supports the pinned 12.1.4"
assert_match '^ok rea_supported_ghidra: rea-agents 6\.8\.0 supports Ghidra 12\.1\.4$' "$(cat "$T/sup1.out")" "rea_supported_ghidra: ok line"

assert_eq 1 "$(count_prefix /raw.githubusercontent.com/)" "rea_supported_ghidra: the prefix counter sees the one raw request of a good answer"

mk_up policy-min policy-min
rc=$(run_cu supmin rea_supported_ghidra)
assert_eq 0 "$rc" "rea_supported_ghidra: MIN_SUPPORTED_GHIDRA_VERSION is not the constant; the SUPPORTED one wins"
assert_match 'supports Ghidra 12\.1\.4$' "$(cat "$T/supmin.out")" "rea_supported_ghidra: the word boundary picks 12.1.4"

# a hostile registry answer is refused before any rea-agents-... request
hn=0
for hv in '"1.2.3\nx"' '"x\n1.2.3"' '"../../x\n1.2.3"' '"1.2.3/../../x"' '"1.2"' '"1.2.3.4"' '"v1.2.3"' '" 1.2.3"' '"1.2.3 "' '"1..3"' '""' '123' '1.5' '"1.2.3\u0000"' '"\n1.2.3"' '"1.2.3\n"'; do
  hn=$((hn + 1))
  UP_NPM_RAW=$hv
  mk_up "hostile$hn" npm-raw
  rc=$(run_cu "hostile$hn" step_check_upstream)
  assert_eq 5 "$rc" "hostile registry version $hv: exit 5"
  assert_match '^FAIL rea_supported_ghidra' "$(cat "$T/hostile$hn.out")" "hostile registry version $hv: the expectation fails"
  assert_eq 0 "$(count_prefix /raw.githubusercontent.com/)" "hostile registry version $hv: no request to a rea-agents raw path"
done

# a tag that is a dot segment is not spliced into a URL
mk_up tagdots tag-dots
rc=$(run_cu tagdots step_check_upstream)
assert_eq 5 "$rc" "release tag ..: exit 5"
assert_match '^FAIL agent-profile' "$(cat "$T/tagdots.out")" "release tag ..: agent-profile fails"

mk_up policy-new policy-new
rc=$(run_cu sup2 rea_supported_ghidra)
assert_eq 5 "$rc" "rea_supported_ghidra: a newer Ghidra is a verification failure"
assert_match 'rea 6\.8\.0 now supports Ghidra 12\.2\.0; update PIN_GHIDRA_\*' "$(cat "$T/sup2.err")" "rea_supported_ghidra: the PIN_GHIDRA_* hint"

mk_up policy-404 policy-404
rc=$(run_cu sup3 rea_supported_ghidra)
assert_eq 5 "$rc" "rea_supported_ghidra: a 404 is a verification failure"
assert_match 'raw\.githubusercontent\.com/morluto/rea/rea-agents-6\.8\.0/src/ghidra/GhidraReleasePolicy\.ts' "$(cat "$T/sup3.err")" "rea_supported_ghidra: the 404 names the URL"

mk_up policy-noconst policy-noconst
rc=$(run_cu sup4 rea_supported_ghidra)
assert_eq 5 "$rc" "rea_supported_ghidra: no constant is a verification failure"
assert_match 'SUPPORTED_GHIDRA_VERSION' "$(cat "$T/sup4.err")" "rea_supported_ghidra: the missing constant is named"
assert_match 'GhidraReleasePolicy\.ts' "$(cat "$T/sup4.err")" "rea_supported_ghidra: the missing constant names the URL"

mk_up npm-nover npm-nover
rc=$(run_cu sup5 rea_supported_ghidra)
assert_eq 5 "$rc" "rea_supported_ghidra: registry JSON without a version is a verification failure"
assert_match 'registry\.npmjs\.org/rea-agents/latest' "$(cat "$T/sup5.err")" "rea_supported_ghidra: the registry URL is named"

# --- step_check_upstream: everything holds ---
mk_up all ok
rm -rf "$T/work"
mkdir -p "$HOME_DIR" "$TMP_DIR"
before=$(tree_of "$T/work")
rc=$(TMPDIR=$TMP_DIR HOME=$HOME_DIR run_cu all step_check_upstream)
after=$(tree_of "$T/work")
assert_eq 0 "$rc" "step_check_upstream: all expectations hold"
out=$(cat "$T/all.out")
assert_eq 5 "$(printf '%s\n' "$out" | grep -c '^ok ')" "step_check_upstream: five ok lines"
assert_eq 0 "$(printf '%s\n' "$out" | grep -c '^FAIL')" "step_check_upstream: no FAIL line"
assert_match '^ok agent-profile: v0\.1\.2 agent-profile-x86_64-unknown-linux-gnu\.tar\.gz' "$out" "step_check_upstream: agent-profile line"
assert_match "^ok clavity-ls: clavity-v31 $CL_ASSET" "$out" "step_check_upstream: clavity-ls line"
assert_match '^ok adoptium: jdk-21\.0\.13\+9 ' "$out" "step_check_upstream: adoptium line"
assert_match '^ok ghidra: 569649598 bytes' "$out" "step_check_upstream: ghidra line"
assert_match '^ok rea_supported_ghidra: rea-agents 6\.8\.0 supports Ghidra 12\.1\.4$' "$out" "step_check_upstream: rea line"
assert_eq "$before" "$after" "step_check_upstream: nothing written under the work tree (tools, bin, home, tmp)"
assert_eq "" "$(tree_of "$TOOLS_DIR")" "step_check_upstream: no tools dir"
assert_eq "" "$(tree_of "$BIN_DIR")" "step_check_upstream: no bin dir"
assert_eq "" "$(ls -A "$TMP_DIR")" "step_check_upstream: no temporary file left"
for p in "/github.com/ckir/aiprofiles/releases/latest/download/$AP_ASSET" /dl/ap.tgz "/github.com/ckir/clavity/releases/download/clavity-v31/$CL_ASSET" \
  "/github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.13%2B9/$JDK_ASSET" "/$PIN_PATH" /dl/ghidra.zip; do
  assert_eq 0 "$(count_of "$p")" "step_check_upstream: no GET of the archive $p"
done

# --- step_check_upstream: one expectation fails, the others are still printed ---
for uc in policy-new:rea_supported_ghidra:5 len-bad:ghidra:5 evil:ghidra:5 ap-badsum:agent-profile:5 cl-two:clavity-ls:5 jdk-diff:adoptium:5 ap-gone:agent-profile:5 policy-404:rea_supported_ghidra:5 policy-noconst:rea_supported_ghidra:5 npm-nover:rea_supported_ghidra:5; do
  uc_case=${uc%%:*}
  uc_rest=${uc#*:}
  uc_name=${uc_rest%%:*}
  uc_rc=${uc_rest#*:}
  mk_up "f-$uc_case" "$uc_case"
  rc=$(run_cu "f-$uc_case" step_check_upstream)
  out=$(cat "$T/f-$uc_case.out")
  assert_eq "$uc_rc" "$rc" "step_check_upstream $uc_case: exit status"
  assert_eq 1 "$(printf '%s\n' "$out" | grep -c '^FAIL ')" "step_check_upstream $uc_case: one FAIL line"
  assert_match "^FAIL $uc_name" "$out" "step_check_upstream $uc_case: FAIL names $uc_name"
  assert_eq 4 "$(printf '%s\n' "$out" | grep -c '^ok ')" "step_check_upstream $uc_case: the other four are still checked"
done
mk_up f-len len-bad
rc=$(run_cu f-len step_check_upstream)
assert_match '569649597.*569649598|569649598.*569649597' "$(cat "$T/f-len.err")" "Content-Length mismatch: both numbers are named"
mk_up f-evil evil
rc=$(run_cu f-evil step_check_upstream)
assert_match 'evil\.example' "$(cat "$T/f-evil.err")" "off-list redirect: the host is named"

# --- HEAD refused: the ranged GET answers the length ---
mk_up h405 head405
rc=$(run_cu h405 step_check_upstream)
assert_eq 0 "$rc" "step_check_upstream: HEAD answered 405, Content-Range gives the length"
assert_match '^ok ghidra: 569649598 bytes' "$(cat "$T/h405.out")" "step_check_upstream: head405 ghidra line"

# --- main with --check-upstream: preflight, prereq, check, and nothing else ---
# stubs.sh: every step main would run, each recording its name in $T/calls
cat >"$T/stubs.sh" <<'STUBS'
: >"$T/calls"
step_preflight() { echo preflight >>"$T/calls"; }
step_prereq() { echo prereq >>"$T/calls"; }
step_check_upstream() { echo check >>"$T/calls" && exit "${STUB_CHECK_RC:-0}"; }
tools_bin_plan() { echo plan >>"$T/calls"; }
jdk_plan() { echo plan >>"$T/calls"; }
ghidra_plan() { echo plan >>"$T/calls"; }
plan_confirm() { echo plan_confirm >>"$T/calls"; }
confirm() { echo confirm >>"$T/calls"; }
lock_acquire() { echo lock >>"$T/calls"; }
step_tools_bin() { echo tools-bin >>"$T/calls"; }
step_jdk() { echo jdk >>"$T/calls"; }
step_ghidra() { echo ghidra >>"$T/calls"; }
step_profile() { echo profile >>"$T/calls"; }
step_rea_setup() { echo rea-setup >>"$T/calls"; }
step_rea_doctor() { echo rea-doctor >>"$T/calls"; }
write_env_files() { echo env >>"$T/calls"; }
print_summary() { echo summary >>"$T/calls"; }
step_launch() { echo launch >>"$T/calls"; }
STUBS
mk_main_calls() {
  : >"$T/calls"
  # shellcheck source=/dev/null
  . "$T/stubs.sh"
}
mrc=0
(
  XDG_STATE_HOME="$T/state"
  export XDG_STATE_HOME
  mk_main_calls
  main --check-upstream --yes
) >/dev/null 2>&1 || mrc=$?
assert_eq 0 "$mrc" "main --check-upstream: exit 0 when the check passes"
assert_eq "preflight,prereq,check" "$(tr '\n' ',' <"$T/calls" | sed 's/,$//')" "main --check-upstream: only preflight, prereq and the check run (no confirm, no lock)"
mrc=0
(
  XDG_STATE_HOME="$T/state"
  export XDG_STATE_HOME
  mk_main_calls
  STUB_CHECK_RC=5
  export STUB_CHECK_RC
  main --check-upstream
) >/dev/null 2>&1 || mrc=$?
assert_eq 5 "$mrc" "main --check-upstream: a failing check ends the run with 5, even without --yes"
assert_eq "preflight,prereq,check" "$(tr '\n' ',' <"$T/calls" | sed 's/,$//')" "main --check-upstream without --yes: still no confirm"

t_done
