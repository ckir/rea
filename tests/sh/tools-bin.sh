#!/bin/sh
# Copyright (c) 2026 Costas Kirgoussios
#
# This software is licensed under the PolyForm Noncommercial License 1.0.0.
# You may obtain a copy of the License at:
# https://polyformproject.org/licenses/noncommercial/1.0.0/

# Tests for the setup.sh step tools-bin: the asset maps, the clavity-ls asset match, the verified single-file
# install, the installed-version reader and the install / update / skip decisions. The releases come from the
# fake server of tests/integration (python3, loopback only); a curl wrapper maps github.com and api.github.com
# onto it, so the product code runs unchanged. Every directory has a space in its name.
# shellcheck source=/dev/null
. "$(dirname "$0")/lib.sh"
cd "$ROOT" || exit 1

if ! command -v python3 >/dev/null 2>&1; then
  echo "tools-bin.sh: python3 is required" >&2
  exit 1
fi

T="$ROOT/tests/.tmp/toolsbin work $$"
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

# A PATH of its own: the coreutils the code runs, curl, tar, gzip and node, and nothing else, so a
# clavity-ls or agent-profile installed on this machine cannot shadow anything.
SYS=$T/sys
mkdir -p "$SYS"
for t in awk basename cat chmod cp curl cut date df dirname env expr find grep gzip head id kill ln ls mkdir mktemp mv node od ps pwd rm sed sha256sum shasum sleep sort stat tail tar tee tr uname wc; do
  p=$(command -v "$t" 2>/dev/null) || continue
  case "$p" in
    /*) ln -sf "$p" "$SYS/$t" ;;
  esac
done
CLEAN_PATH=$SYS

ALLOWED_SCHEMES="https http"
ALLOWED_HOSTS="github.com api.github.com 127.0.0.1"
RETRY_WAITS="0 0"
SLEEP=true
OS=linux
ARCH=x64
OPT_DRY_RUN=0
OPT_CHECK_UPSTREAM=0
TOOLS_DIR="$T/tools dir"
BIN_DIR="$T/bin dir"
LOG_FILE=$T/unit.log
CONSOLE_LEVEL=ERROR
export ALLOWED_SCHEMES ALLOWED_HOSTS RETRY_WAITS SLEEP OS ARCH OPT_DRY_RUN OPT_CHECK_UPSTREAM TOOLS_DIR BIN_DIR LOG_FILE CONSOLE_LEVEL
ORIG_PATH=$PATH

# curl_local ARG...: curl with github.com and api.github.com URLs sent to the fake server (BASE) instead
curl_local() {
  cx_n=$#
  while [ "$cx_n" -gt 0 ]; do
    cx_a=$1
    shift
    case "$cx_a" in
      https://github.com/* | https://api.github.com/*) cx_a="$BASE/${cx_a#https://}" ;;
    esac
    set -- "$@" "$cx_a"
    cx_n=$((cx_n - 1))
  done
  curl "$@"
}

# --- fake server scenarios ---

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

# mk_script FILE LINE: an executable script that prints LINE for --version
mk_script() {
  printf '#!/bin/sh\necho "%s"\n' "$2" >"$1"
  chmod +x "$1"
}

# pack DIR NAME FILE...: DIR/NAME is a tar.gz of the named files (taken from DIR/src)
pack() {
  pk_dir=$1
  pk_name=$2
  shift 2
  tar -czf "$pk_dir/$pk_name" -C "$pk_dir/src" "$@"
}

# release_json FILE VERSION: a release listing for every platform of clavity-ls at VERSION
release_json() {
  printf '{"tag_name":"clavity-v31","assets":[' >"$1"
  rj_sep=""
  for rj_rid in linux-x64 osx-arm64 osx-x64 win-x64; do
    printf '%s{"name":"clavity-ls-%s-%s.tar.gz"},{"name":"clavity-ls-%s-%s.tar.gz.sha256"}' "$rj_sep" "$rj_rid" "$2" "$rj_rid" "$2" >>"$1"
    rj_sep=,
  done
  printf ']}\n' >>"$1"
}

# mk_server NAME CLVER APIKIND [BADSIDECAR]: builds the archives, the checksum files and the scenario of one
# fake release server, starts it and sets BASE. APIKIND is json (all platforms at CLVER), two (two
# linux-x64 assets), fixture (tests/fixtures/github-release-clavity.json) or fail (the API answers 500 and
# the release page lists the assets). BADSIDECAR=ap gives agent-profile a checksum that does not match.
mk_server() {
  ms_name=$1
  ms_ver=$2
  ms_kind=$3
  ms_dir="$T/srv $ms_name"
  mkdir -p "$ms_dir/src" "$ms_dir/two"
  mk_script "$ms_dir/src/agent-profile" "agent-profile 0.1.2"
  mk_script "$ms_dir/src/clavity-ls" "clavity-ls $ms_ver+built"
  mk_script "$ms_dir/src/extra" "extra"
  pack "$ms_dir" ap.tgz agent-profile
  pack "$ms_dir" cl.tgz clavity-ls
  pack "$ms_dir" two.tgz clavity-ls extra
  ms_ap=agent-profile-x86_64-unknown-linux-gnu.tar.gz
  ms_cl=clavity-ls-linux-x64-$ms_ver.tar.gz
  printf '%s  %s\n' "$(sha256_file "$ms_dir/ap.tgz")" "$ms_ap" >"$ms_dir/ap.sha256"
  printf '%s *%s\n' "$(sha256_file "$ms_dir/cl.tgz")" "$ms_cl" >"$ms_dir/cl.sha256"
  printf '%s  two.tgz\n' "$(sha256_file "$ms_dir/two.tgz")" >"$ms_dir/two.sha256"
  if [ "${4:-}" = ap ]; then
    printf '%s  %s\n' 0000000000000000000000000000000000000000000000000000000000000000 "$ms_ap" >"$ms_dir/ap.sha256"
  fi
  release_json "$ms_dir/api.json" "$ms_ver"
  if [ "$ms_kind" = none ]; then
    printf '{"tag_name":"clavity-v31","assets":[{"name":"clavity-ls-win-x64-0.17.0.tar.gz"}]}\n' >"$ms_dir/api.json"
  fi
  if [ "$ms_kind" = two ]; then
    printf '{"tag_name":"clavity-v31","assets":[{"name":"clavity-ls-linux-x64-0.17.0.tar.gz"},{"name":"clavity-ls-linux-x64-0.18.0.tar.gz"}]}\n' >"$ms_dir/api.json"
  fi
  printf '<html><a href="/ckir/clavity/releases/download/clavity-v31/%s">a</a>\n<a href="/ckir/clavity/releases/download/clavity-v31/%s.sha256">s</a>\n<a href="/ckir/other/releases/download/clavity-v31/clavity-ls-linux-x64-9.9.9.tar.gz">x</a></html>\n' "$ms_cl" "$ms_cl" >"$ms_dir/page.html"
  scn_start "$ms_dir/scenario.json"
  scn_ent /github.com/ckir/aiprofiles/releases/latest '{"status":302,"location":"{base}/r/aiprofiles/releases/tag/v0.1.2"}'
  scn_ent /github.com/ckir/clavity/releases/latest '{"status":302,"location":"{base}/r/clavity/releases/tag/clavity-v31"}'
  scn_ent "/github.com/ckir/aiprofiles/releases/latest/download/$ms_ap" '{"status":302,"location":"{base}/dl/ap.tgz"}'
  scn_ent "/github.com/ckir/aiprofiles/releases/latest/download/$ms_ap.sha256" '{"status":302,"location":"{base}/dl/ap.sha256"}'
  scn_ent "/github.com/ckir/clavity/releases/download/clavity-v31/$ms_cl" '{"status":302,"location":"{base}/dl/cl.tgz"}'
  scn_ent "/github.com/ckir/clavity/releases/download/clavity-v31/$ms_cl.sha256" '{"status":302,"location":"{base}/dl/cl.sha256"}'
  for ms_f in ap.tgz ap.sha256 cl.tgz cl.sha256 two.tgz two.sha256; do
    scn_ent "/dl/$ms_f" "{\"status\":200,\"body_file\":\"$ms_f\"}"
  done
  case "$ms_kind" in
    fixture) scn_ent /api.github.com/repos/ckir/clavity/releases/latest "{\"status\":200,\"body_file\":\"$ROOT/tests/fixtures/github-release-clavity.json\"}" ;;
    fail) scn_ent /api.github.com/repos/ckir/clavity/releases/latest '{"status":500}' ;;
    *) scn_ent /api.github.com/repos/ckir/clavity/releases/latest '{"status":200,"body_file":"api.json"}' ;;
  esac
  scn_ent /github.com/ckir/clavity/releases/expanded_assets/clavity-v31 '{"status":200,"body_file":"page.html"}'
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
    echo "tools-bin.sh: the fake server did not start" >&2
    echo "tools-bin.sh: server.out: $(cat "$ms_dir/server.out" 2>&1)" >&2
    cat "$ms_dir/server.err" >&2
    exit 1
  fi
  BASE=http://127.0.0.1:$ms_port
}

# count_of PATH: the GET requests the fake server has seen for PATH
count_of() {
  curl -sS "$BASE/__count$1"
}

# run_tb LOG: runs step_tools_bin and then tools_lock_release in a subshell with the clean PATH (or PATHX), the
# curl wrapper and the traps; the log goes to $T/LOG.log and the state afterwards to $T/LOG.state; returns the
# step's exit status
run_tb() {
  rt_log=$T/$1.log
  : >"$rt_log"
  (
    PATH=${PATHX:-$CLEAN_PATH}
    LOG_FILE=$rt_log
    CURL=curl_local
    install_traps
    step_tools_bin
    if [ -d "$TOOLS_DIR/.lock" ]; then rt_held=held; else rt_held=free; fi
    printf 'lock-after-step=%s\npath=%s\nsummary=%s\n' "$rt_held" "$PATH" "$(summary_get tools_bin)" >"$T/$1.state"
    tools_lock_release
    if [ -d "$TOOLS_DIR/.lock" ]; then rt_held=held; else rt_held=free; fi
    printf 'lock-after-release=%s\n' "$rt_held" >>"$T/$1.state"
  ) >/dev/null 2>&1
}

logtext() {
  cat "$T/$1.log"
}

# fresh: empty bin and tools directories
fresh() {
  rm -rf "$BIN_DIR" "$TOOLS_DIR"
  mkdir -p "$BIN_DIR" "$TOOLS_DIR"
}

# listing DIR: the entries of DIR, one per line (a glob, so odd names are safe)
listing() {
  for li_f in "$1"/* "$1"/.[!.]*; do
    [ -e "$li_f" ] || [ -L "$li_f" ] || continue
    echo "${li_f##*/}"
  done
}

# rc_of CMD...: the exit status of a command run in a subshell with the log silenced
rc_of() {
  rc_v=0
  (
    CURL=curl_local
    LOG_FILE=$T/unit.log
    "$@"
  ) >/dev/null 2>&1 || rc_v=$?
  echo "$rc_v"
}

# failmv/mv: the real mv, except that it fails when its last argument is $FAKE_MV_FAIL
mkdir -p "$T/failmv"
cat >"$T/failmv/mv" <<'MV'
#!/bin/sh
for l; do :; done
if [ "$l" = "$FAKE_MV_FAIL" ]; then exit 1; fi
exec "$FAKE_MV_REAL" "$@"
MV
FAKE_MV_REAL=$(command -v mv)
export FAKE_MV_REAL
chmod +x "$T/failmv/mv"

# --- platforms without a build: no network is touched ---
CURL=false
assert_status 1 "agent-profile linux aarch64" resolve_agent_profile linux aarch64
assert_status 1 "agent-profile windows aarch64" resolve_agent_profile windows aarch64
assert_status 1 "clavity-ls linux aarch64" resolve_clavity_ls linux aarch64
assert_status 1 "clavity-ls windows aarch64" resolve_clavity_ls windows aarch64

# --- the real release listing: one match for win-x64, none for osx-x64 ---
mk_server fixture 0.17.0 fixture
CURL=curl_local
resolve_clavity_ls windows x64
assert_eq clavity-ls-win-x64-0.17.0.tar.gz "$CL_ASSET" "fixture: the one win-x64 asset"
assert_eq 0.17.0 "$CL_VERSION" "fixture: version from the asset name"
assert_eq clavity-v31 "$CL_TAG" "fixture: tag"
assert_eq https://github.com/ckir/clavity/releases/download/clavity-v31/clavity-ls-win-x64-0.17.0.tar.gz "$CL_URL" "fixture: URL"
assert_eq "$CL_URL.sha256" "$CL_SIDECAR_URL" "fixture: sidecar URL"
resolve_clavity_ls linux x64
assert_eq clavity-ls-linux-x64-0.17.0.tar.gz "$CL_ASSET" "fixture: the one linux-x64 asset"
assert_eq 5 "$(rc_of resolve_clavity_ls mac x64)" "fixture: no osx-x64 asset is a verification failure"

# --- the asset maps ---
mk_server maps 0.17.0 json
resolve_agent_profile linux x64
assert_eq agent-profile-x86_64-unknown-linux-gnu.tar.gz "$AP_ASSET" "agent-profile linux x64"
assert_eq v0.1.2 "$AP_TAG" "agent-profile tag"
assert_eq 0.1.2 "$AP_VERSION" "agent-profile version"
assert_eq https://github.com/ckir/aiprofiles/releases/latest/download/agent-profile-x86_64-unknown-linux-gnu.tar.gz "$AP_URL" "agent-profile URL"
assert_eq "$AP_URL.sha256" "$AP_SIDECAR_URL" "agent-profile sidecar URL"
resolve_agent_profile mac x64
assert_eq agent-profile-x86_64-apple-darwin.tar.gz "$AP_ASSET" "agent-profile mac x64"
resolve_agent_profile mac aarch64
assert_eq agent-profile-aarch64-apple-darwin.tar.gz "$AP_ASSET" "agent-profile mac aarch64"
resolve_agent_profile windows x64
assert_eq agent-profile-x86_64-pc-windows-msvc.zip "$AP_ASSET" "agent-profile windows x64"
resolve_clavity_ls linux x64
assert_eq clavity-ls-linux-x64-0.17.0.tar.gz "$CL_ASSET" "clavity-ls linux x64"
resolve_clavity_ls mac aarch64
assert_eq clavity-ls-osx-arm64-0.17.0.tar.gz "$CL_ASSET" "clavity-ls mac aarch64"
resolve_clavity_ls mac x64
assert_eq clavity-ls-osx-x64-0.17.0.tar.gz "$CL_ASSET" "clavity-ls mac x64"
resolve_clavity_ls windows x64
assert_eq clavity-ls-win-x64-0.17.0.tar.gz "$CL_ASSET" "clavity-ls windows x64"

# --- install_single_binary ---
IA=$BASE/dl
fresh
DEST="$BIN_DIR/clavity-ls"
rc=0
(
  CURL=curl_local
  LOG_FILE=$T/isb1.log
  install_traps
  install_single_binary clavity-ls "$IA/cl.tgz" "$IA/cl.sha256" clavity-ls "$DEST"
) >/dev/null 2>&1 || rc=$?
assert_eq 0 "$rc" "install_single_binary: one file archive"
assert_file "$DEST" "install_single_binary: file in place"
assert_status 0 "install_single_binary: executable" test -x "$DEST"
assert_eq "clavity-ls 0.17.0+built" "$("$DEST" --version)" "install_single_binary: the extracted file"
assert_eq "clavity-ls" "$(listing "$BIN_DIR")" "install_single_binary: nothing else left in the bin dir"

fresh
rc=0
(
  CURL=curl_local
  LOG_FILE=$T/isb2.log
  install_traps
  install_single_binary clavity-ls "$IA/two.tgz" "$IA/two.sha256" clavity-ls "$DEST"
) >/dev/null 2>&1 || rc=$?
assert_eq 5 "$rc" "install_single_binary: a second entry is refused with 5"
assert_eq "" "$(listing "$BIN_DIR")" "install_single_binary: refused archive leaves the bin dir empty"
assert_match 'exactly one file' "$(cat "$T/isb2.log")" "install_single_binary: the refusal is logged"

# the wrong expected name is refused too
fresh
rc=0
(
  CURL=curl_local
  LOG_FILE=$T/isb3.log
  install_traps
  install_single_binary clavity-ls "$IA/cl.tgz" "$IA/cl.sha256" other-name "$BIN_DIR/other-name"
) >/dev/null 2>&1 || rc=$?
assert_eq 5 "$rc" "install_single_binary: an unexpected file name is refused with 5"
assert_eq "" "$(listing "$BIN_DIR")" "install_single_binary: unexpected name leaves the bin dir empty"

# Windows, file in use: the move fails, the installed copy stays, the staged file goes
fresh
printf 'old\n' >"$DEST"
rc=0
(
  CURL=curl_local
  LOG_FILE=$T/isb4.log
  OS=windows
  export CURL LOG_FILE OS
  install_traps
  PATH=$T/failmv:$CLEAN_PATH
  FAKE_MV_FAIL=$DEST
  export FAKE_MV_FAIL
  install_single_binary clavity-ls "$IA/cl.tgz" "$IA/cl.sha256" clavity-ls "$DEST"
) >/dev/null 2>&1 || rc=$?
assert_eq 2 "$rc" "install_single_binary: Windows in-use returns 2"
assert_eq old "$(cat "$DEST")" "install_single_binary: the installed copy is kept"
assert_eq "clavity-ls" "$(listing "$BIN_DIR")" "install_single_binary: the staged file is removed"
assert_match 'WARN.*close running sessions to update clavity-ls' "$(cat "$T/isb4.log")" "install_single_binary: the warning is logged"

# the same failure off Windows is an error
rc=0
(
  CURL=curl_local
  LOG_FILE=$T/isb5.log
  export CURL LOG_FILE
  install_traps
  PATH=$T/failmv:$CLEAN_PATH
  FAKE_MV_FAIL=$DEST
  export FAKE_MV_FAIL
  install_single_binary clavity-ls "$IA/cl.tgz" "$IA/cl.sha256" clavity-ls "$DEST"
) >/dev/null 2>&1 || rc=$?
assert_eq 1 "$rc" "install_single_binary: a failed move off Windows dies with 1"
assert_eq old "$(cat "$DEST")" "install_single_binary: the installed copy survives a failed move"

# --- installed_version ---
fresh
assert_eq "" "$(installed_version clavity-ls)" "installed_version: empty bin dir prints nothing"
assert_status 0 "installed_version: empty bin dir returns 0" installed_version clavity-ls
mk_script "$BIN_DIR/clavity-ls" "clavity-ls 0.17.0+abc"
assert_eq 0.17.0 "$(installed_version clavity-ls)" "installed_version: build metadata ignored"
printf '#!/bin/sh\nexit 1\n' >"$BIN_DIR/clavity-ls"
assert_eq "" "$(installed_version clavity-ls)" "installed_version: a failing stub prints nothing"
assert_status 0 "installed_version: a failing stub returns 0" installed_version clavity-ls
printf '#!/bin/sh\necho "no version here"\n' >"$BIN_DIR/clavity-ls"
assert_eq "" "$(installed_version clavity-ls)" "installed_version: output without X.Y.Z prints nothing"
printf '#!/bin/sh\necho "clavity-ls 9.9.9"\n' >"$BIN_DIR/clavity-ls"
chmod -x "$BIN_DIR/clavity-ls"
assert_eq "" "$(installed_version clavity-ls)" "installed_version: a non-executable file prints nothing"
rm -f "$BIN_DIR/clavity-ls"
mkdir -p "$T/elsewhere"
mk_script "$T/elsewhere/clavity-ls" "clavity-ls 3.3.3"
assert_eq "" "$(PATH="$T/elsewhere:$ORIG_PATH" installed_version clavity-ls)" "installed_version: PATH is not consulted"

# --- step_tools_bin ---
# empty bin dir: both installed, BIN_DIR first on PATH, lock held until release
fresh
rc=0
run_tb s-install || rc=$?
assert_eq 0 "$rc" "step: empty bin dir succeeds"
assert_match 'tools-bin.* agent-profile: install \(installed: none, latest: 0\.1\.2\)' "$(logtext s-install)" "step: agent-profile decision is install"
assert_match 'tools-bin.* clavity-ls: install \(installed: none, latest: 0\.17\.0\)' "$(logtext s-install)" "step: clavity-ls decision is install"
assert_match 'DEBUG.*no agent-profile in ' "$(logtext s-install)" "step: DEBUG says no agent-profile in the bin dir"
assert_eq 0.1.2 "$(installed_version agent-profile)" "step: agent-profile installed"
assert_eq 0.17.0 "$(installed_version clavity-ls)" "step: clavity-ls installed"
assert_eq "agent-profile
clavity-ls" "$(listing "$BIN_DIR")" "step: only the two binaries are in the bin dir"
assert_match "^path=$BIN_DIR:" "$(cat "$T/s-install.state")" "step: BIN_DIR is first on PATH"
assert_match '^lock-after-step=held$' "$(cat "$T/s-install.state")" "step: the tools lock is still held after the step"
assert_match '^lock-after-release=free$' "$(cat "$T/s-install.state")" "step: tools_lock_release frees it"
assert_eq "" "$(listing "$TOOLS_DIR")" "step: nothing left in the tools dir"
assert_match '^summary=agent-profile 0\.1\.2: install' "$(cat "$T/s-install.state")" "step: SUMMARY_tools_bin is set"

# both current: skip, and the files are not touched
rc=0
run_tb s-skip || rc=$?
assert_eq 0 "$rc" "step: second run succeeds"
assert_match 'agent-profile: skip \(already latest\) \(installed: 0\.1\.2' "$(logtext s-skip)" "step: agent-profile skip"
assert_match 'clavity-ls: skip \(already latest\) \(installed: 0\.17\.0' "$(logtext s-skip)" "step: clavity-ls skip"
if grep -q 'WARN' "$T/s-skip.log"; then
  t_fail "step: a clean PATH logs no WARN"
else
  t_ok
fi

# a newer binary than the latest release is never downgraded
mk_script "$BIN_DIR/clavity-ls" "clavity-ls 0.99.0"
rc=0
run_tb s-newer || rc=$?
assert_eq 0 "$rc" "step: newer-than-latest run succeeds"
assert_match 'clavity-ls: skip \(already latest\) \(installed: 0\.99\.0' "$(logtext s-newer)" "step: no downgrade"
assert_eq 0.99.0 "$(installed_version clavity-ls)" "step: the newer copy is untouched"

# older installed: update
mk_script "$BIN_DIR/clavity-ls" "clavity-ls 0.16.0"
rc=0
run_tb s-older || rc=$?
assert_eq 0 "$rc" "step: update run succeeds"
assert_match 'clavity-ls: update \(installed: 0\.16\.0, latest: 0\.17\.0\)' "$(logtext s-older)" "step: older copy is updated"
assert_eq 0.17.0 "$(installed_version clavity-ls)" "step: the updated copy runs"

# a copy earlier on PATH: WARN, and the BIN_DIR copy is the one compared
mkdir -p "$T/shadow"
mk_script "$T/shadow/clavity-ls" "clavity-ls 0.1.0"
PATHX="$T/shadow:$CLEAN_PATH"
rc=0
run_tb s-shadow || rc=$?
unset PATHX
assert_eq 0 "$rc" "step: shadowed run succeeds"
assert_match "WARN.*another clavity-ls at .*/shadow/clavity-ls precedes the one this script manages" "$(logtext s-shadow)" "step: shadowing is warned about"
assert_match 'clavity-ls: skip \(already latest\) \(installed: 0\.17\.0' "$(logtext s-shadow)" "step: the BIN_DIR copy is compared, not the PATH one"

# dry run: nothing installed, no lock
fresh
OPT_DRY_RUN=1
rc=0
run_tb s-dry || rc=$?
OPT_DRY_RUN=0
assert_eq 0 "$rc" "step: dry run succeeds"
assert_eq "" "$(listing "$BIN_DIR")" "step: dry run installs nothing"
assert_match 'clavity-ls: install \(installed: none' "$(logtext s-dry)" "step: dry run still reports the decision"
assert_match 'lock-after-step=free' "$(cat "$T/s-dry.state")" "step: dry run takes no lock"

# --- a newer release: update ---
mk_server new 0.18.0 json
fresh
mk_script "$BIN_DIR/agent-profile" "agent-profile 0.1.2"
mk_script "$BIN_DIR/clavity-ls" "clavity-ls 0.17.0+abc"
rc=0
run_tb s-new || rc=$?
assert_eq 0 "$rc" "newer release: run succeeds"
assert_match 'agent-profile: skip \(already latest\)' "$(logtext s-new)" "newer release: agent-profile skip"
assert_match 'clavity-ls: update \(installed: 0\.17\.0, latest: 0\.18\.0\)' "$(logtext s-new)" "newer release: clavity-ls update"
assert_eq 0.18.0 "$(installed_version clavity-ls)" "newer release: clavity-ls replaced"

# --- API unreachable: the release page is scraped ---
mk_server scrape 0.17.0 fail
fresh
rc=0
run_tb s-scrape || rc=$?
assert_eq 0 "$rc" "scrape: run succeeds"
assert_match 'WARN.*GitHub API did not answer' "$(logtext s-scrape)" "scrape: the fallback is logged"
assert_eq 2 "$(count_of /api.github.com/repos/ckir/clavity/releases/latest)" "scrape: the API was asked (2 attempts) and failed"
assert_eq 1 "$(count_of /github.com/ckir/clavity/releases/expanded_assets/clavity-v31)" "scrape: the release page was read once"
assert_eq 0.17.0 "$(installed_version clavity-ls)" "scrape: clavity-ls installed from the scraped asset"

# --- two matching assets: refused ---
mk_server two 0.17.0 two
fresh
rc=0
run_tb s-two || rc=$?
assert_eq 5 "$rc" "two matches: exit 5"
assert_match 'found 2' "$(logtext s-two)" "two matches: the count is logged"
assert_eq "agent-profile" "$(listing "$BIN_DIR")" "two matches: only agent-profile (resolved before) is in the bin dir"

# --- zero matching assets: refused ---
mk_server zero 0.17.0 none
fresh
rc=0
run_tb s-zero || rc=$?
assert_eq 5 "$rc" "zero matches: exit 5"
assert_match 'found 0' "$(logtext s-zero)" "zero matches: the count is logged"

# --- sidecar mismatch: nothing installed ---
mk_server bad 0.17.0 json ap
fresh
rc=0
run_tb s-bad || rc=$?
assert_eq 5 "$rc" "sidecar mismatch: exit 5"
assert_match 'checksum mismatch' "$(logtext s-bad)" "sidecar mismatch: logged"
assert_eq "" "$(listing "$BIN_DIR")" "sidecar mismatch: the bin dir is untouched"
assert_eq "" "$(listing "$TOOLS_DIR")" "sidecar mismatch: the lock is released"

# --- unsupported platform ---
ARCH=aarch64
fresh
rc=0
run_tb s-arm || rc=$?
ARCH=x64
assert_eq 3 "$rc" "linux aarch64: exit 3"
assert_eq "" "$(listing "$BIN_DIR")" "linux aarch64: nothing installed"

t_done
