#!/bin/sh
# Copyright (c) 2026 Costas Kirgoussios
#
# This software is licensed under the PolyForm Noncommercial License 1.0.0.
# You may obtain a copy of the License at:
# https://polyformproject.org/licenses/noncommercial/1.0.0/

# End-to-end runs of setup.sh (main, in a subshell) on Linux against a fake release server on 127.0.0.1: tiny
# stand-in archives under the real asset names (agent-profile and clavity-ls with one file each, a Temurin-shaped
# tar.gz, a Ghidra-shaped zip), the digest and size of the Ghidra pin reassigned after sourcing, a throwaway HOME,
# AGENT_PROFILE_HOME and XDG_DATA_HOME that all contain a space, and stubs on PATH for node, npx, claude and agy
# (the installed agent-profile and clavity-ls are the stubs of tests/fixtures/bin, packed into the archives).
# Scenarios: dry-run, declined, low-disk, order, old-node, install, idempotent, dry-run-after; each prints
# `ok <name>`. Usage: sh tests/integration/e2e.sh
# shellcheck source=/dev/null
. "$(dirname "$0")/../sh/lib.sh"
cd "$ROOT" || exit 1

TMP=$(mktemp -d "${TMPDIR:-/tmp}/rea e2e.XXXXXX") || exit 1
SRV_PID=""
cleanup() {
  if [ -n "$SRV_PID" ]; then
    kill "$SRV_PID" 2>/dev/null
    wait "$SRV_PID" 2>/dev/null
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT
trap 'exit 1' INT TERM

if ! command -v python3 >/dev/null 2>&1; then
  echo "e2e.sh: python3 is required" >&2
  exit 1
fi
REAL_NODE=$(command -v node) || {
  echo "e2e.sh: node is required (the script parses JSON with it)" >&2
  exit 1
}
BASE_PATH=$PATH
FIX=$ROOT/tests/fixtures

NO_PROXY=127.0.0.1,api.github.com
no_proxy=127.0.0.1,api.github.com
export NO_PROXY no_proxy
unset GITHUB_TOKEN CLAUDE_CONFIG_DIR GHIDRA_INSTALL_DIR JAVA_HOME STUB_CL_LOG STUB_CL_EXIT STUB_CL_STDERR
unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CODE_OAUTH_REFRESH_TOKEN ANTHROPIC_PROFILE
unset CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY

# --- the stand-in release assets ---
SRV=$TMP/srv
mkdir -p "$SRV/src ap" "$SRV/src cl" "$SRV/src jdk/jdk-21.0.13+9" || exit 1
cp "$FIX/bin/agent-profile" "$SRV/src ap/agent-profile"
cp "$FIX/bin/clavity-ls" "$SRV/src cl/clavity-ls"
cp -R "$FIX/fake-jdk/bin" "$SRV/src jdk/jdk-21.0.13+9/bin"
tar -czf "$SRV/ap.tgz" -C "$SRV/src ap" agent-profile
tar -czf "$SRV/cl.tgz" -C "$SRV/src cl" clavity-ls
tar -czf "$SRV/jdk.tgz" -C "$SRV/src jdk" jdk-21.0.13+9
cat >"$SRV/mkzip.py" <<'PYEOF'
import sys
import zipfile

top = "ghidra_12.1.4_PUBLIC"
files = [
    ("Ghidra/application.properties", "application.name=Ghidra\napplication.version=12.1.4\n", 0o644),
    ("ghidraRun", "#!/bin/sh\n", 0o755),
    ("support/analyzeHeadless", "#!/bin/sh\n", 0o755),
    ("Ghidra/Features/Decompiler/os/linux_x86_64/decompile", "ELF\n", 0o755),
]
with zipfile.ZipFile(sys.argv[1], "w", zipfile.ZIP_DEFLATED) as z:
    for name, text, mode in files:
        info = zipfile.ZipInfo(top + "/" + name)
        info.external_attr = (0o100000 | mode) << 16
        z.writestr(info, text)
PYEOF
python3 -I "$SRV/mkzip.py" "$SRV/ghidra.zip" || exit 1
AP_ASSET=agent-profile-x86_64-unknown-linux-gnu.tar.gz
CL_ASSET=clavity-ls-linux-x64-1.0.0.tar.gz
JDK_ASSET=OpenJDK21U-jdk_x64_linux_hotspot_21.0.13_9.tar.gz
printf '%s  %s\n' "$(sha256_file "$SRV/ap.tgz")" "$AP_ASSET" >"$SRV/ap.sha256"
printf '%s *%s\n' "$(sha256_file "$SRV/cl.tgz")" "$CL_ASSET" >"$SRV/cl.sha256"
JDK_SHA=$(sha256_file "$SRV/jdk.tgz")
JDK_SIZE=$(wc -c <"$SRV/jdk.tgz" | tr -d ' ')
printf '%s  %s\n' "$JDK_SHA" "$JDK_ASSET" >"$SRV/jdk.sha256"
sed -e "s/\"checksum\": \"[0-9a-f]*\"/\"checksum\": \"$JDK_SHA\"/" -e "s/\"size\": [0-9]*/\"size\": $JDK_SIZE/" "$FIX/adoptium-linux-x64.json" >"$SRV/adoptium.json"
GHIDRA_SHA=$(sha256_file "$SRV/ghidra.zip")
GHIDRA_SIZE=$(wc -c <"$SRV/ghidra.zip" | tr -d ' ')
printf '{"tag_name":"clavity-v31","assets":[{"name":"%s"},{"name":"%s.sha256"}]}\n' "$CL_ASSET" "$CL_ASSET" >"$SRV/clavity-api.json"

# scn_ent PATH SPEC: PATH answers SPEC to its first twenty requests
SCN=$SRV/scenario.json
SCN_SEP=""
printf '{' >"$SCN"
scn_ent() {
  se_list=""
  se_i=0
  while [ "$se_i" -lt 20 ]; do
    se_list="$se_list${se_list:+,}$2"
    se_i=$((se_i + 1))
  done
  printf '%s"%s": [%s]' "$SCN_SEP" "$1" "$se_list" >>"$SCN"
  SCN_SEP=,
}
JDK_REL=/github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.13%2B9
scn_ent /github.com/ckir/aiprofiles/releases/latest '{"status":302,"location":"{base}/r/aiprofiles/releases/tag/v1.0.0"}'
scn_ent /github.com/ckir/clavity/releases/latest '{"status":302,"location":"{base}/r/clavity/releases/tag/clavity-v31"}'
scn_ent "/github.com/ckir/aiprofiles/releases/latest/download/$AP_ASSET" '{"status":302,"location":"{base}/dl/ap.tgz"}'
scn_ent "/github.com/ckir/aiprofiles/releases/latest/download/$AP_ASSET.sha256" '{"status":302,"location":"{base}/dl/ap.sha256"}'
scn_ent "/github.com/ckir/clavity/releases/download/clavity-v31/$CL_ASSET" '{"status":302,"location":"{base}/dl/cl.tgz"}'
scn_ent "/github.com/ckir/clavity/releases/download/clavity-v31/$CL_ASSET.sha256" '{"status":302,"location":"{base}/dl/cl.sha256"}'
scn_ent /api.github.com/repos/ckir/clavity/releases/latest '{"status":200,"body_file":"clavity-api.json"}'
scn_ent "/api.adoptium.net/v3/assets/latest/21/hotspot?architecture=x64&image_type=jdk&os=linux&vendor=eclipse" '{"status":200,"body_file":"adoptium.json"}'
scn_ent "$JDK_REL/$JDK_ASSET" '{"status":302,"location":"{base}/dl/jdk.tgz"}'
scn_ent "$JDK_REL/$JDK_ASSET.sha256.txt" '{"status":302,"location":"{base}/dl/jdk.sha256"}'
scn_ent /github.com/NationalSecurityAgency/ghidra/releases/download/Ghidra_12.1.4_build/ghidra_12.1.4_PUBLIC_20260921.zip '{"status":302,"location":"{base}/dl/ghidra.zip"}'
for e2e_f in ap.tgz:ap.tgz ap.sha256:ap.sha256 cl.tgz:cl.tgz cl.sha256:cl.sha256 jdk.tgz:jdk.tgz jdk.sha256:jdk.sha256 ghidra.zip:ghidra.zip; do
  scn_ent "/dl/${e2e_f%%:*}" "{\"status\":200,\"body_file\":\"${e2e_f#*:}\"}"
done
printf '}\n' >>"$SCN"

python3 -I tests/integration/fake_release_server.py 0 "$SCN" >"$TMP/server.out" 2>"$TMP/server.err" &
SRV_PID=$!
PORT=""
tries=0
while [ -z "$PORT" ] && [ "$tries" -lt 100 ]; do
  PORT=$(sed -n 's/^PORT //p' "$TMP/server.out" 2>/dev/null)
  [ -n "$PORT" ] || sleep 0.1
  tries=$((tries + 1))
done
if [ -z "$PORT" ]; then
  echo "e2e.sh: the fake server did not start" >&2
  cat "$TMP/server.err" >&2
  exit 1
fi
SERVER=http://127.0.0.1:$PORT

# count_of PATH: the GET requests the fake server has seen for PATH
count_of() {
  curl -sS "$SERVER/__count$1"
}

# archives_fetched: the archive downloads so far, as one line
archives_fetched() {
  printf '%s %s %s %s' "$(count_of /dl/ap.tgz)" "$(count_of /dl/cl.tgz)" "$(count_of /dl/jdk.tgz)" "$(count_of /dl/ghidra.zip)"
}

# curl_local ARGS...: curl with the three hosts of the script pointed at the fake server; each call is traced
curl_local() {
  cx_n=$#
  printf 'CURL %s\n' "$*" >>"$TRACE"
  while [ "$cx_n" -gt 0 ]; do
    cx_a=$1
    shift
    case "$cx_a" in
      https://github.com/* | https://api.github.com/* | https://api.adoptium.net/*) cx_a="$SERVER/${cx_a#https://}" ;;
    esac
    set -- "$@" "$cx_a"
    cx_n=$((cx_n - 1))
  done
  curl "$@"
}

# --- the throwaway machine ---
STATE=$TMP/state
HOME_DIR="$STATE/home dir"
APH="$STATE/aph dir"
XDG="$STATE/xdg data"
TOOLS="$XDG/rea-tools"
BIN="$HOME_DIR/.local/bin"
SCRATCH="$STATE/tmp dir"
LOGS=$TMP/logs
FOLDER="$STATE/my folder"
STUBS=$TMP/stubs
mkdir -p "$HOME_DIR" "$APH" "$XDG" "$SCRATCH" "$FOLDER" "$STUBS" || exit 1
for e2e_s in npx claude agy; do
  ln -s "$FIX/bin/$e2e_s" "$STUBS/$e2e_s"
done
# node: --version is the stub's answer (this machine's node may be older than the floor); everything else is the real node
cat >"$STUBS/node" <<NODE
#!/bin/sh
case "\${1:-}" in
  --version | -v)
    printf '%s\\n' "\${STUB_node_VERSION:-v24.22.2}"
    exit 0
    ;;
esac
exec "$REAL_NODE" "\$@"
NODE
chmod +x "$STUBS/node"
printf '{"checks":[{"id":"launch_environment","data":{"value":"%s/profiles/rea/claude"}}]}\n' "$APH" >"$TMP/doctor-ap.json"
printf '{"mcpServers":{"rea":{"command":"npx","args":["-y","rea-agents@6.8.0","mcp"]}}}\n' >"$TMP/cfg-ok.json"

# setv NAME VALUE: assigns through eval (the script reads these variables; shellcheck cannot see that)
setv() {
  eval "$1=\$2"
}

# snapshot: every path under the machine, sorted, one per line
snapshot() {
  find "$STATE" | sort
}

# run_setup NAME PRE ARGS...: main in a subshell on the throwaway machine; PRE (shell text, may be empty) runs
# before it. stdout goes to $TMP/NAME.out, stderr and the curl trace to $TMP/NAME.trace; RC is the exit code.
run_setup() {
  rs_name=$1
  rs_pre=$2
  shift 2
  : >"$TMP/$rs_name.trace"
  rm -f "$TMP/npx.log" "$TMP/npx.log.n" "$TMP/npx.log.env"
  (
    TRACE=$TMP/$rs_name.trace
    HOME=$HOME_DIR
    AGENT_PROFILE_HOME=$APH
    XDG_DATA_HOME=$XDG
    TMPDIR=$SCRATCH
    PATH="$STUBS:$BASE_PATH"
    STUB_AP_DOCTOR_FILE=$TMP/doctor-ap.json
    STUB_NPX_LOG=$TMP/npx.log
    STUB_NPX_CONFIG_2=$TMP/cfg-ok.json
    STUB_NPX_FILE_3=$FIX/rea-doctor-client-ok.json
    STUB_NPX_FILE_4=$FIX/rea-doctor-ghidra-ok.json
    export TRACE HOME AGENT_PROFILE_HOME XDG_DATA_HOME TMPDIR PATH STUB_AP_DOCTOR_FILE STUB_NPX_LOG STUB_NPX_CONFIG_2 STUB_NPX_FILE_3 STUB_NPX_FILE_4
    setv CURL curl_local
    setv ALLOWED_SCHEMES "https http"
    setv ALLOWED_HOSTS "$ALLOWED_HOSTS 127.0.0.1"
    setv RETRY_WAITS "0 0 0 0"
    setv PIN_GHIDRA_SHA256 "$GHIDRA_SHA"
    setv PIN_GHIDRA_ZIP_BYTES "$GHIDRA_SIZE"
    eval "$rs_pre"
    main --profile rea --folder "$FOLDER" --log-dir "$LOGS" --quiet "$@"
  ) >"$TMP/$rs_name.out" 2>>"$TMP/$rs_name.trace" </dev/null
  RC=$?
}

# newest_log: the log file of the latest run
newest_log() {
  nl_last=""
  for nl_f in "$LOGS"/setup-*.log; do
    [ -e "$nl_f" ] || continue
    nl_last=$nl_f
  done
  printf '%s\n' "$nl_last"
}

# leftovers: staging paths and private temporary files anywhere on the machine
leftovers() {
  find "$STATE" -name '*.tmp.*' -o -name '*.old.*' -o -name 'rea-setup-*' | head -n 3
}

scenario_start() {
  SC_LABEL=$1
  SC_FAILS=$T_FAIL
}

scenario_end() {
  if [ "$T_FAIL" -eq "$SC_FAILS" ]; then
    echo "ok $SC_LABEL"
  fi
}

EMPTY=$(snapshot)

# --- dry-run: plan only, the log is the only thing written ---
scenario_start dry-run
run_setup dry "" --dry-run
assert_eq 0 "$RC" "dry-run: exit 0"
assert_eq "$EMPTY" "$(snapshot)" "dry-run: nothing was written on the machine"
assert_eq "0 0 0 0" "$(archives_fetched)" "dry-run: no archive was requested"
assert_eq "" "$(leftovers)" "dry-run: no temporary file"
assert_eq "" "$(find "$STATE" -name 'env.*')" "dry-run: no env file"
assert_eq 1 "$(find "$LOGS" -name 'setup-*.log' | wc -l | tr -d ' ')" "dry-run: the log was written"
assert_match 'would install' "$(cat "$TMP/dry.trace")" "dry-run: the plan says would install"
assert_match 'Dry run: nothing was changed' "$(cat "$TMP/dry.out")" "dry-run: the summary says so on stdout"
assert_match 'would run: clavity-ls start' "$(cat "$(newest_log)")" "dry-run: the launch is a would"
scenario_end

# --- declined: the user answers n ---
scenario_start declined
run_setup declined "eval 'confirm() { printf \"%s [y/N] \" \"\$1\" >&2; return 1; }'"
assert_eq 0 "$RC" "declined: exit 0"
assert_eq "nothing changed" "$(cat "$TMP/declined.out")" "declined: stdout is nothing changed"
assert_eq "$EMPTY" "$(snapshot)" "declined: nothing was written on the machine"
assert_eq "0 0 0 0" "$(archives_fetched)" "declined: no archive was requested"
assert_match 'Proceed\? \[y/N\]' "$(cat "$TMP/declined.trace")" "declined: the question was asked"
scenario_end

# --- low-disk: one check for the sum, before any download ---
scenario_start low-disk
run_setup low "eval 'df() { printf \"Filesystem 1048576-blocks Used Available Capacity Mounted\\nx 9999 1 1000 1%% /\\n\"; }'" --yes
assert_eq 1 "$RC" "low-disk: exit 1"
assert_match 'need 2300 MB, have 1000 MB \(short by 1300 MB\)' "$(cat "$TMP/low.trace")" "low-disk: the sum of Ghidra, the JDK and the margin"
assert_eq "0 0 0 0" "$(archives_fetched)" "low-disk: no archive was requested"
assert_eq "$EMPTY" "$(snapshot)" "low-disk: nothing was written on the machine"
assert_eq 0 "$(grep -c 'Before anything is changed' "$TMP/low.trace")" "low-disk: no disclosures before the failure"
scenario_end

# --- old-node: exit 4 before any request ---
scenario_start old-node
run_setup oldnode "STUB_node_VERSION=v24.21.0; export STUB_node_VERSION" --yes --no-launch
assert_eq 4 "$RC" "old-node: exit 4"
assert_match 'fnm install 24' "$(cat "$TMP/oldnode.trace")" "old-node: the hint"
assert_eq 0 "$(grep -c '^CURL ' "$TMP/oldnode.trace")" "old-node: no request was made"
assert_eq "0 0 0 0" "$(archives_fetched)" "old-node: no archive was requested"
assert_eq "$EMPTY" "$(snapshot)" "old-node: nothing was written on the machine"
scenario_end

# --- install: the whole run ---
scenario_start install
run_setup install "" --yes --no-launch
assert_eq 0 "$RC" "install: exit 0"
assert_file "$TOOLS/jdk-21.0.13+9/.install-complete" "install: the JDK is installed and marked"
assert_file "$TOOLS/ghidra_12.1.4_PUBLIC/.install-complete" "install: Ghidra is installed and marked"
assert_file "$TOOLS/ghidra_12.1.4_PUBLIC/Ghidra/application.properties" "install: Ghidra has its files"
assert_file "$BIN/agent-profile" "install: agent-profile is in the bin dir"
assert_file "$BIN/clavity-ls" "install: clavity-ls is in the bin dir"
assert_file "$TOOLS/env.sh" "install: env.sh exists"
assert_eq "1 1 1 1" "$(archives_fetched)" "install: each archive was fetched once"
assert_eq "" "$(leftovers)" "install: no temporary file is left"
assert_eq 0 "$(find "$HOME_DIR" -name '.claude.json' | wc -l | tr -d ' ')" "install: no .claude.json anywhere under HOME"
assert_eq "" "$(ls "$HOME_DIR/.claude" 2>/dev/null)" "install: no ~/.claude"
assert_file "$APH/profiles/rea/claude/.claude.json" "install: rea is registered in the profile"
assert_match 'launch skipped \(--no-launch\); run: clavity-ls start ".*my folder" --profile rea' "$(cat "$TMP/install.out")" "install: the launch command on stdout"
assert_match 'Setup summary' "$(cat "$TMP/install.out")" "install: the summary is on stdout"
assert_match "env file: +$TOOLS/env.sh" "$(cat "$TMP/install.out")" "install: the summary names the env file"
assert_match "ghidra: +12\\.1\\.4 installed: $TOOLS/ghidra_12\\.1\\.4_PUBLIC" "$(cat "$TMP/install.out")" "install: the summary names the Ghidra version and path"
cat >"$TMP/source.sh" <<'SRC'
. "$1"
printf '%s\n%s\n%s' "$GHIDRA_INSTALL_DIR" "$JAVA_HOME" "${PATH%%:*}"
SRC
sourced=$(env -i PATH=/usr/bin:/bin sh "$TMP/source.sh" "$TOOLS/env.sh")
assert_eq "$TOOLS/ghidra_12.1.4_PUBLIC
$TOOLS/jdk-21.0.13+9
$BIN" "$sourced" "install: env.sh sets the three values (spaces)"
assert_eq 4 "$(cat "$TMP/npx.log.n")" "install: rea was called four times (setup dry, setup, two doctors)"
assert_match 'setup --client claude_code --dry-run' "$(sed -n 1p "$TMP/npx.log")" "install: rea setup --dry-run first"
assert_match 'setup --client claude_code --yes' "$(sed -n 2p "$TMP/npx.log")" "install: then the real setup"
assert_match "GHIDRA_INSTALL_DIR=$TOOLS/ghidra_12.1.4_PUBLIC" "$(cat "$TMP/npx.log.env")" "install: rea got the Ghidra directory"
inst_log=$(cat "$(newest_log)")
assert_eq 1 "$(printf '%s\n' "$inst_log" | grep -c 'disk_free_mb .*before the download of agent-profile')" "install: free space logged before the agent-profile download"
assert_eq 8 "$(printf '%s\n' "$inst_log" | grep -c 'DEBUG .*disk_free_mb')" "install: free space logged before and after each of the four installs"
assert_eq 4 "$(printf '%s\n' "$inst_log" | grep -c 'DEBUG .*disk_free_mb .*after ')" "install: ... four after the install"
scenario_end

# --- order: the disclosures and the plan come before the first archive request ---
scenario_start order
first_dl=$(grep -n '^CURL .*releases/\(latest/\)\{0,1\}download/' "$TMP/install.trace" | head -n 1 | cut -d: -f1)
disc=$(grep -n 'Before anything is changed' "$TMP/install.trace" | head -n 1 | cut -d: -f1)
plan=$(grep -n '^Plan:' "$TMP/install.trace" | head -n 1 | cut -d: -f1)
agy_line=$(grep -n 'always runs agy with --dangerously-skip-permissions' "$TMP/install.trace" | head -n 1 | cut -d: -f1)
assert_match '^[0-9]+$' "$first_dl" "order: there was a first download request"
assert_match '^[0-9]+$' "$disc" "order: the disclosures were printed"
if [ -n "$first_dl" ] && [ -n "$disc" ] && [ -n "$plan" ] && [ -n "$agy_line" ]; then
  assert_eq 1 "$([ "$disc" -lt "$first_dl" ] && [ "$agy_line" -lt "$first_dl" ] && [ "$plan" -lt "$first_dl" ] && echo 1 || echo 0)" "order: disclosures and plan come before the first download request"
else
  t_fail "order: disclosures, plan or first download not found in the trace"
fi
assert_eq 1 "$(grep -c 'Download: .* MB in total' "$TMP/install.trace")" "order: the disclosures carry the computed total"
scenario_end

# --- idempotent: a second run installs and downloads nothing, and rewrites env.sh ---
scenario_start idempotent
printf 'stale\n' >"$TOOLS/env.sh"
run_setup again "" --yes --no-launch
assert_eq 0 "$RC" "idempotent: exit 0"
assert_eq "1 1 1 1" "$(archives_fetched)" "idempotent: nothing was downloaded again"
again_log=$(cat "$(newest_log)")
assert_match '\[jdk\] skip \(already valid\)' "$again_log" "idempotent: jdk"
assert_match '\[ghidra\] skip \(already valid\)' "$again_log" "idempotent: ghidra"
assert_match '\[tools-bin\] skip \(already valid\)' "$again_log" "idempotent: tools-bin"
assert_match '\[profile\] skip \(already exists\)' "$again_log" "idempotent: profile"
assert_match 'GHIDRA_INSTALL_DIR=' "$(cat "$TOOLS/env.sh")" "idempotent: env.sh was overwritten"
assert_eq "" "$(leftovers)" "idempotent: no temporary file is left"
assert_eq 0 "$(find "$HOME_DIR" -name '.claude.json' | wc -l | tr -d ' ')" "idempotent: no .claude.json under HOME"
assert_match 'would reuse' "$(cat "$TMP/again.trace")" "idempotent: the plan says would reuse"
assert_eq 1 "$(grep -c 'Download: nothing for Ghidra and the JDK' "$TMP/again.trace")" "idempotent: the disclosures say there is nothing to download"
scenario_end

# --- launch: the real launch path, with the installed clavity-ls stub, not --no-launch ---
scenario_start launch
rm -f "$TMP/cl.rec"
run_setup launch "DISPLAY=:0; WAYLAND_DISPLAY=; STUB_CL_LOG=\"$TMP/cl.rec\"; export DISPLAY WAYLAND_DISPLAY STUB_CL_LOG" --yes
assert_eq 0 "$RC" "launch: exit 0 (the stub's code)"
assert_eq "arg: start
arg: $FOLDER
arg: --profile
arg: rea" "$(grep '^arg: ' "$TMP/cl.rec")" "launch: the stub saw start <folder> --profile rea"
assert_eq "env GHIDRA_INSTALL_DIR=$TOOLS/ghidra_12.1.4_PUBLIC" "$(grep '^env GHIDRA_INSTALL_DIR=' "$TMP/cl.rec")" "launch: the child has GHIDRA_INSTALL_DIR"
assert_eq "env JAVA_HOME=$TOOLS/jdk-21.0.13+9" "$(grep '^env JAVA_HOME=' "$TMP/cl.rec")" "launch: the child has JAVA_HOME"
assert_eq "path-head: $BIN" "$(grep '^path-head: ' "$TMP/cl.rec")" "launch: the bin dir heads the child's PATH"
assert_eq 0 "$(grep -c CLAUDE_CONFIG_DIR "$TMP/cl.rec")" "launch: no CLAUDE_CONFIG_DIR (--profile sets it)"
assert_match 'launch exited 0' "$(cat "$(newest_log)")" "launch: the exit is logged"
assert_eq "" "$(leftovers)" "launch: no temporary file is left"
scenario_end

# --- dry-run after the install: rea setup --dry-run runs, nothing is written, env.sh stays ---
scenario_start dry-run-after
printf 'stale\n' >"$TOOLS/env.sh"
before=$(snapshot)
run_setup dry2 "" --dry-run
assert_eq 0 "$RC" "dry-run-after: exit 0"
assert_eq "$before" "$(snapshot)" "dry-run-after: the machine is unchanged"
assert_eq "stale" "$(cat "$TOOLS/env.sh")" "dry-run-after: env.sh was not written"
assert_eq "1 1 1 1" "$(archives_fetched)" "dry-run-after: nothing was downloaded"
assert_eq 1 "$(cat "$TMP/npx.log.n")" "dry-run-after: rea was called once"
assert_match 'setup --client claude_code --dry-run' "$(cat "$TMP/npx.log")" "dry-run-after: rea setup --dry-run ran"
assert_eq 0 "$(grep -c -- '--yes' "$TMP/npx.log")" "dry-run-after: no real setup"
scenario_end

t_done
