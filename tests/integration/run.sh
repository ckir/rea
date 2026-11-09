#!/bin/sh
# Copyright (c) 2026 Costas Kirgoussios
#
# This software is licensed under the PolyForm Noncommercial License 1.0.0.
# You may obtain a copy of the License at:
# https://polyformproject.org/licenses/noncommercial/1.0.0/

# Integration tests for the setup.sh network layer against a fake release server on 127.0.0.1 only.
# Starts tests/integration/fake_release_server.py on a free port, runs scenarios a-j and prints one
# `ok <scenario>` line each. The server is killed on exit. Usage: sh tests/integration/run.sh
# shellcheck source=/dev/null
. "$(dirname "$0")/../sh/lib.sh"
cd "$ROOT" || exit 1

TMP=$(mktemp -d "${TMPDIR:-/tmp}/rea-net-it.XXXXXX") || exit 1
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
  echo "run.sh: python3 is required" >&2
  exit 1
fi

# The fake server and curl both stay on loopback; ignore any proxy configured for this machine.
NO_PROXY=127.0.0.1,api.github.com
no_proxy=127.0.0.1,api.github.com
export NO_PROXY no_proxy

# Payloads: 4096 bytes of text; its checksum is the oracle for the download scenarios.
i=0
while [ "$i" -lt 64 ]; do
  printf '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ+/\n'
  i=$((i + 1))
done >"$TMP/payload.bin"
PAYLOAD_SHA=$(sha256_file "$TMP/payload.bin")

cat >"$TMP/scenario.json" <<JSON
{
  "/a": [{"status": 504}, {"status": 504}, {"status": 200, "body_file": "payload.bin"}],
  "/b": [{"status": 504}, {"status": 504}, {"status": 504}, {"status": 504}, {"status": 200, "body_file": "payload.bin"}],
  "/c": [{"status": 429, "headers": {"Retry-After": "1"}}, {"status": 200, "body_file": "payload.bin"}],
  "/d": [{"status": 200, "body_file": "payload.bin", "truncate": 1000}],
  "/e": [{"status": 302, "location": "https://evil.example/"}],
  "/f0": [{"status": 302, "location": "{base}/f1"}],
  "/f1": [{"status": 302, "location": "{base}/f2"}],
  "/f2": [{"status": 302, "location": "{base}/f3"}],
  "/f3": [{"status": 302, "location": "{base}/f4"}],
  "/f4": [{"status": 302, "location": "{base}/f5"}],
  "/f5": [{"status": 302, "location": "{base}/f6"}],
  "/f6": [{"status": 200, "body_file": "payload.bin"}],
  "/g": [{"status": 404}, {"status": 200, "body_file": "payload.bin"}],
  "/h": [{"status": 200, "head_status": 405, "body_file": "payload.bin"}],
  "/i0": [{"status": 302, "location": "{base}/i1"}],
  "/i1": [{"status": 302, "location": "{base}/i2"}],
  "/i2": [{"status": 200, "body_file": "payload.bin"}],
  "/k0": [{"status": 302, "location": "{base}/k1"}],
  "/k1": [{"status": 302, "location": "{base}/k2"}],
  "/k2": [{"status": 302, "location": "{base}/k3"}],
  "/k3": [{"status": 302, "location": "{base}/k4"}],
  "/k4": [{"status": 302, "location": "{base}/k5"}],
  "/k5": [{"status": 200, "body_file": "payload.bin"}],
  "/slow": [{"status": 200, "body_file": "payload.bin", "hang_after": 100}, {"status": 200, "body_file": "payload.bin", "hang_after": 100}],
  "/j": [{"status": 200, "body_file": "payload.bin"}, {"status": 200, "body_file": "payload.bin"}]
}
JSON

python3 -I tests/integration/fake_release_server.py 0 "$TMP/scenario.json" >"$TMP/server.out" 2>"$TMP/server.err" &
SRV_PID=$!
PORT=""
tries=0
while [ -z "$PORT" ] && [ "$tries" -lt 100 ]; do
  PORT=$(sed -n 's/^PORT //p' "$TMP/server.out" 2>/dev/null)
  [ -n "$PORT" ] || sleep 0.1
  tries=$((tries + 1))
done
if [ -z "$PORT" ]; then
  echo "run.sh: the fake server did not start" >&2
  cat "$TMP/server.err" >&2
  exit 1
fi
BASE=http://127.0.0.1:$PORT

ALLOWED_SCHEMES="https http"
ALLOWED_HOSTS="127.0.0.1"
RETRY_WAITS="0 0 0 0"
SLEEP=rec_sleep
LOG_FILE=$TMP/log
CONSOLE_LEVEL=ERROR
log DEBUG test "server $BASE schemes=$ALLOWED_SCHEMES hosts=$ALLOWED_HOSTS waits=$RETRY_WAITS sleep=$SLEEP console=$CONSOLE_LEVEL log=$LOG_FILE"

# rec_sleep N: records the pause (what http_get decided to wait) instead of taking it
rec_sleep() {
  echo "$1" >>"$TMP/sleeps"
}

# others DIR NAME: lists what is in DIR besides NAME (a glob, so odd file names are safe)
others() {
  for oth_f in "$1"/*; do
    [ -e "$oth_f" ] || continue
    [ "${oth_f##*/}" = "$2" ] || echo "${oth_f##*/}"
  done
}

count_of() {
  curl -sS "$BASE/__count$1"
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

http_get_rc() {
  http_get "$@" >/dev/null 2>&1
  echo $?
}

# (a) 504, 504, 200: the download succeeds on the third request
scenario_start "a retry then success"
assert_status 0 "a: http_get" http_get "$BASE/a" "$TMP/a.out"
assert_eq 3 "$(count_of /a)" "a: three requests"
assert_eq "$PAYLOAD_SHA" "$(sha256_file "$TMP/a.out")" "a: body intact"
scenario_end

# (b) four 504s: http_get gives up after four attempts
scenario_start "b gives up after four attempts"
assert_eq 1 "$(http_get_rc "$BASE/b" "$TMP/b.out")" "b: returns 1"
assert_eq 4 "$(count_of /b)" "b: four requests"
scenario_end

# (c) 429 with Retry-After: 1 then 200: the pause is the server's value (recorded, not slept)
scenario_start "c Retry-After honoured"
: >"$TMP/sleeps"
assert_status 0 "c: http_get" http_get "$BASE/c" "$TMP/c.out"
assert_eq "1" "$(cat "$TMP/sleeps")" "c: one pause of 1 second"
assert_eq 2 "$(count_of /c)" "c: two requests"
scenario_end

# (d) truncated body: download_verified fails and leaves nothing behind
scenario_start "d truncated body leaves nothing"
mkdir "$TMP/dd"
assert_eq 1 "$(
  download_verified "$BASE/d" "$TMP/dd/file" "$PAYLOAD_SHA" >/dev/null 2>&1
  echo $?
)" "d: returns 1"
assert_eq "" "$(others "$TMP/dd" '')" "d: no DEST and no DEST.tmp.*"
scenario_end

# (e) redirect to a disallowed host
scenario_start "e redirect to a disallowed host"
assert_eq 1 "$(
  resolve_redirects "$BASE/e" >/dev/null 2>&1
  echo $?
)" "e: returns 1"
scenario_end

# (f) six chained redirects: too many hops
scenario_start "f six redirects"
assert_eq 2 "$(
  resolve_redirects "$BASE/f0" >/dev/null 2>&1
  echo $?
)" "f: returns 2"
scenario_end

# (g) 404: one request, no retry
scenario_start "g 404 is not retried"
assert_eq 1 "$(http_get_rc "$BASE/g" "$TMP/g.out")" "g: returns 1"
assert_eq 1 "$(count_of /g)" "g: exactly one request"
scenario_end

# (h) HEAD answered 405: retried as a one-byte ranged GET
scenario_start "h HEAD 405 falls back to a ranged GET"
assert_eq "$BASE/h" "$(resolve_redirects "$BASE/h" 2>/dev/null)" "h: final URL"
scenario_end

# (i) a chain within the limit resolves to its end, without fetching the body
scenario_start "i three-hop chain resolves"
assert_eq "$BASE/i2" "$(resolve_redirects "$BASE/i0" 2>/dev/null)" "i: final URL"
assert_eq 0 "$(count_of /i2)" "i: the final body was never fetched"
scenario_end

# (k) exactly five redirects is allowed (six, in scenario f, is not)
scenario_start "k five redirects resolve"
assert_eq "$BASE/k5" "$(resolve_redirects "$BASE/k0" 2>/dev/null)" "k: final URL after 5 hops"
scenario_end

# (j) download_verified: right checksum installs the file (upper case accepted), wrong one removes it
scenario_start "j checksum verification"
mkdir "$TMP/jj"
UPPER_SHA=$(printf '%s' "$PAYLOAD_SHA" | tr 'a-f' 'A-F')
assert_status 0 "j: matching checksum" download_verified "$BASE/j" "$TMP/jj/ok" "$UPPER_SHA"
assert_file "$TMP/jj/ok" "j: file installed"
assert_eq "$PAYLOAD_SHA" "$(sha256_file "$TMP/jj/ok")" "j: content"
assert_eq "" "$(others "$TMP/jj" ok)" "j: no temporary left"
assert_status 1 "j: wrong checksum" download_verified "$BASE/j" "$TMP/jj/bad" "0000000000000000000000000000000000000000000000000000000000000000"
assert_eq "" "$(others "$TMP/jj" ok)" "j: wrong checksum leaves nothing"
scenario_end

# (l) SIGTERM during a transfer leaves nothing behind, token-bearing curl config included.
# The child sources setup.sh, installs the traps and starts the transfer against a response that stalls after
# 100 bytes; api.github.com is mapped to the fake server with --resolve so the token is really written.
mkdir "$TMP/priv" "$TMP/sig1" "$TMP/sig2"
cat >"$TMP/child.sh" <<'CHILD'
. "$1/setup.sh"
ALLOWED_SCHEMES="https http"
ALLOWED_HOSTS="127.0.0.1 api.github.com"
RETRY_WAITS="0 0 0 0"
LOG_FILE=/dev/null
install_traps
case "$2" in
  http_get) register_tmp "$4/out" && GITHUB_TOKEN=ghp_SigtermTestToken0123 http_get "http://api.github.com:$3/slow" "$4/out" --resolve "api.github.com:$3:127.0.0.1" ;;
  download) download_verified "http://127.0.0.1:$3/slow" "$4/file" 0000000000000000000000000000000000000000000000000000000000000000 ;;
esac
exit 0
CHILD

# sigterm_case MODE DESTDIR PATTERN: runs the child, waits for PATTERN (a file curl writes once the transfer is running), SIGTERMs
sigterm_case() {
  TMPDIR=$TMP/priv sh "$TMP/child.sh" "$ROOT" "$1" "$PORT" "$2" >/dev/null 2>&1 &
  sg_pid=$!
  sg_tries=0
  sg_seen=""
  while [ -z "$sg_seen" ] && [ "$sg_tries" -lt 100 ]; do
    for sg_f in $3; do
      [ -e "$sg_f" ] && sg_seen=$sg_f
    done
    [ -n "$sg_seen" ] || sleep 0.1
    sg_tries=$((sg_tries + 1))
  done
  SG_SEEN=$sg_seen
  SG_PRIV=$(others "$TMP/priv" '')
  # Like a terminal's Ctrl-C reaching the whole group: the shell first (its trap waits for the transfer),
  # then the transfer processes under it.
  sg_kids=""
  for sg_k in $(pgrep -P "$sg_pid"); do
    sg_kids="$sg_kids $sg_k $(pgrep -P "$sg_k")"
  done
  kill -TERM "$sg_pid" 2>/dev/null
  for sg_k in $sg_kids; do kill -TERM "$sg_k" 2>/dev/null; done
  SG_RC=0
  wait "$sg_pid" || SG_RC=$?
}

scenario_start "l SIGTERM during http_get with a token"
sigterm_case http_get "$TMP/sig1" "$TMP/sig1/out"
assert_match 'rea-setup-cfg' "$SG_PRIV" "l: the token-bearing config existed while the transfer ran"
assert_eq 143 "$SG_RC" "l: the child exited 143"
assert_eq "" "$(others "$TMP/priv" '')" "l: nothing left in TMPDIR"
assert_eq "" "$(others "$TMP/sig1" '')" "l: nothing left at the destination"
scenario_end

scenario_start "m SIGTERM during download_verified"
sigterm_case download "$TMP/sig2" "$TMP/sig2/file.tmp.*"
assert_match 'file\.tmp\.' "$SG_SEEN" "m: the partial download existed while the transfer ran"
assert_eq 143 "$SG_RC" "m: the child exited 143"
assert_eq "" "$(others "$TMP/priv" '')" "m: nothing left in TMPDIR"
assert_eq "" "$(others "$TMP/sig2" '')" "m: no DEST and no DEST.tmp.*"
scenario_end

t_done
