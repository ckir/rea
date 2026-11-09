#!/bin/sh
# Copyright (c) 2026 Costas Kirgoussios
#
# This software is licensed under the PolyForm Noncommercial License 1.0.0.
# You may obtain a copy of the License at:
# https://polyformproject.org/licenses/noncommercial/1.0.0/

# Tests for the setup.sh network layer that need no network: URL allow-list, checksums, JSON queries,
# the Adoptium parser, the retry loop (against a stub CURL) and the guarantee that a token never reaches
# the log. The loopback tests live in tests/integration/run.sh.
# shellcheck source=/dev/null
. "$(dirname "$0")/lib.sh"
cd "$ROOT" || exit 1
FIX=$ROOT/tests/fixtures
TMP=$(mktemp -d "${TMPDIR:-/tmp}/rea-net-test.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM

assert_status 0 "allowed" url_allowed https://github.com/x
assert_status 1 "http refused" url_allowed http://github.com/x
assert_status 1 "host refused" url_allowed https://evil.example/x
assert_status 1 "userinfo refused" url_allowed https://u@github.com/x
assert_status 1 "userinfo trick refused" url_allowed https://github.com@evil.example/x
assert_status 1 "backslash refused" url_allowed 'https://github.com\@evil.example/x'
assert_status 1 "no scheme refused" url_allowed github.com/x
assert_status 0 "uppercase host allowed" url_allowed HTTPS://GitHub.com/x
assert_status 0 "port allowed" url_allowed https://github.com:443/x
assert_status 1 "trailing-dot host refused" url_allowed https://github.com./x
assert_status 0 "upper-case host allowed" url_allowed https://GITHUB.com/x
assert_status 1 "suffix host refused" url_allowed https://github.com.evil.example/x
assert_eq api.github.com "$(url_host 'https://api.github.com/repos/a/b?x=1')" "url_host"
assert_eq github.com "$(url_host 'https://u:p@GitHub.com:8443/x')" "url_host strips userinfo, port and case"

assert_eq f8114d71dc4d54a342ed13bc2fbe4b87f755af1de1c4e7ffaa47262a2eb1ac3d "$(sidecar_sha256 "$FIX/sidecar-aiprofiles.sha256")" "sidecar two-space"
assert_eq c9de4fe583d8c301b90196f3ecb25568f09b7c7ad832ba917fd951df7b15da1c "$(sidecar_sha256 "$FIX/sidecar-clavity.sha256")" "sidecar asterisk"
assert_eq d7f5d5cf865a2902b70ff549b97586a7d3f234e016f041ab447ea740c7d66d1c "$(sidecar_sha256 "$FIX/sidecar-temurin.sha256.txt")" "sidecar temurin"
printf 'ABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCD\n' >"$TMP/upper"
assert_eq abcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd "$(sidecar_sha256 "$TMP/upper")" "sidecar uppercase is lowered"
printf 'not a checksum\n' >"$TMP/junk"
assert_status 1 "sidecar without hash" sidecar_sha256 "$TMP/junk"
printf abc >"$TMP/abc"
assert_eq ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad "$(sha256_file "$TMP/abc")" "sha256"

assert_eq "clavity-v31" "$(json_query "$FIX/github-release-clavity.json" 'd.tag_name')" "json scalar"
assert_eq "clavity-ls-win-x64-0.17.0.tar.gz" "$(json_query "$FIX/github-release-clavity.json" 'd.assets.map(a=>a.name).filter(n=>/^clavity-ls-win-x64-[0-9]+\.[0-9]+\.[0-9]+\.tar\.gz$/.test(n))')" "asset match"
assert_eq "" "$(json_query "$FIX/github-release-clavity.json" 'd.nothing')" "json undefined is empty"
assert_eq "" "$(json_query "$FIX/github-release-clavity.json" 'null')" "json null is empty"

assert_eq "jdk-21.0.13+9 207858352" "$(
  adoptium_parse "$FIX/adoptium-linux-x64.json"
  echo "$JDK_RELEASE $JDK_BYTES"
)" "adoptium parse"
assert_eq "d7f5d5cf865a2902b70ff549b97586a7d3f234e016f041ab447ea740c7d66d1c https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.13%2B9/OpenJDK21U-jdk_x64_linux_hotspot_21.0.13_9.tar.gz.sha256.txt" "$(
  adoptium_parse "$FIX/adoptium-linux-x64.json"
  echo "$JDK_SHA256 $JDK_SIDECAR_URL"
)" "adoptium parse sha and sidecar"
assert_match '^https://github\.com/adoptium/temurin21-binaries/releases/download/.*\.tar\.gz$' "$(
  adoptium_parse "$FIX/adoptium-linux-x64.json"
  echo "$JDK_URL"
)" "adoptium parse url"
assert_status 1 "bad tag" jdk_release_valid jdk-22.0.1+7
assert_status 0 "good tag" jdk_release_valid jdk-21.0.13+9
assert_status 0 "good tag, no patch" jdk_release_valid jdk-21+35
assert_status 1 "tag with suffix" jdk_release_valid 'jdk-21.0.13+9;x'

# A response whose release name, link host or link path is outside the rules is refused.
sed 's/"release_name": "jdk-21.0.13+9"/"release_name": "jdk-22.0.1+7"/' "$FIX/adoptium-linux-x64.json" >"$TMP/bad-release.json"
assert_status 1 "adoptium bad release" adoptium_parse "$TMP/bad-release.json"
sed 's#"link": "https://github.com/adoptium/#"link": "https://github.com/evil/#' "$FIX/adoptium-linux-x64.json" >"$TMP/bad-path.json"
assert_status 1 "adoptium bad url path" adoptium_parse "$TMP/bad-path.json"
sed 's#"link": "https://github.com/#"link": "https://evil.example/#' "$FIX/adoptium-linux-x64.json" >"$TMP/bad-host.json"
assert_status 1 "adoptium bad url host" adoptium_parse "$TMP/bad-host.json"
printf '[]\n' >"$TMP/empty.json"
assert_status 1 "adoptium empty list" adoptium_parse "$TMP/empty.json"

# --- stub CURL: a function standing in for the curl binary ---
# Answers from the file named by STUB_PLAN (one "code[:exit[:retry-after]]" per call), writes the request count
# to STUB_COUNT, copies the -K config file (where the Authorization header goes) to STUB_CFG and the URL to
# STUB_URL. A call that exits non-zero writes no header file, like curl failing before any response.
# STUB_BODY, when set, is the file copied to the -o target.
stub_curl() {
  sc_n=$(cat "$STUB_COUNT" 2>/dev/null || echo 0)
  sc_n=$((sc_n + 1))
  echo "$sc_n" >"$STUB_COUNT"
  sc_out=""
  sc_hdr=""
  sc_cfg=""
  while [ $# -gt 1 ]; do
    case "$1" in
      -o)
        sc_out=$2
        shift
        ;;
      -D)
        sc_hdr=$2
        shift
        ;;
      -K)
        sc_cfg=$2
        shift
        ;;
    esac
    shift
  done
  echo "$1" >"$STUB_URL"
  if [ -n "$sc_cfg" ]; then cat "$sc_cfg" >"$STUB_CFG"; fi
  sc_line=$(sed -n "${sc_n}p" "$STUB_PLAN")
  sc_code="" sc_rc="" sc_ra=""
  IFS=: read -r sc_code sc_rc sc_ra <<EOF
$sc_line
EOF
  sc_rc=${sc_rc:-0}
  if [ "$sc_rc" -eq 0 ] && [ -n "$sc_hdr" ]; then
    {
      printf 'HTTP/1.1 %s\r\n' "$sc_code"
      if [ -n "$sc_ra" ]; then printf 'Retry-After: %s\r\n' "$sc_ra"; fi
      printf '\r\n'
    } >"$sc_hdr"
  fi
  if [ -n "$sc_out" ]; then
    if [ -n "${STUB_BODY:-}" ]; then cp "$STUB_BODY" "$sc_out"; else echo body >"$sc_out"; fi
  fi
  printf '%s' "$sc_code"
  return "$sc_rc"
}
# stub_sleep N: records the pause instead of taking it
stub_sleep() {
  echo "$1" >>"$STUB_SLEEPS"
}
STUB_COUNT=$TMP/stub.count
STUB_CFG=$TMP/stub.cfg
STUB_URL=$TMP/stub.url
STUB_PLAN=$TMP/stub.plan
STUB_SLEEPS=$TMP/stub.sleeps
SLEEP=stub_sleep
CURL=stub_curl
RETRY_WAITS="0 0 0 0"
LOG_FILE=$TMP/log
CONSOLE_LEVEL=ERROR
log DEBUG test "stub transport: curl=$CURL waits=$RETRY_WAITS console=$CONSOLE_LEVEL sleep=$SLEEP"

stub_reset() {
  rm -f "$STUB_COUNT" "$STUB_CFG" "$STUB_URL" "$STUB_SLEEPS" "$LOG_FILE"
  STUB_BODY=""
  printf '%s\n' "$@" >"$STUB_PLAN"
}

stub_reset 200
assert_status 0 "stub 200" http_get https://github.com/a "$TMP/out"
assert_eq 1 "$(cat "$STUB_COUNT")" "one request on 200"
stub_reset 503 503 200
assert_status 0 "stub 503 503 200" http_get https://github.com/a "$TMP/out"
assert_eq 3 "$(cat "$STUB_COUNT")" "three requests"
stub_reset 000:28 000:6 200
assert_status 0 "stub curl exits 28 and 6 are retried" http_get https://github.com/a "$TMP/out"
stub_reset 000:60
assert_status 1 "stub curl exit 60 is not retried" http_get https://github.com/a "$TMP/out"
assert_eq 1 "$(cat "$STUB_COUNT")" "one request on curl exit 60"
stub_reset 404 200
assert_status 1 "stub 404" http_get https://github.com/a "$TMP/out"
assert_eq 1 "$(cat "$STUB_COUNT")" "one request on 404"
stub_reset 429 200
assert_status 0 "stub 429 retried" http_get https://github.com/a "$TMP/out"
stub_reset 500 500 500 500 200
assert_status 1 "stub gives up after four attempts" http_get https://github.com/a "$TMP/out"
assert_eq 4 "$(cat "$STUB_COUNT")" "four attempts"
stub_reset 200
assert_status 1 "disallowed host never reaches curl" http_get https://evil.example/a "$TMP/out"
assert_eq "" "$(cat "$STUB_COUNT" 2>/dev/null)" "no request for a disallowed host"
assert_status 1 "http refused by default" http_get http://github.com/a "$TMP/out"

# The token goes only to api.github.com, only in the curl config, and never into the log.
tok=ghp_UnitTestToken0123456789abcdefghijkl
stub_reset 200
GITHUB_TOKEN=$tok http_get https://api.github.com/repos/a/b/releases/latest "$TMP/out" 2>/dev/null
assert_match "Authorization: Bearer $tok" "$(cat "$STUB_CFG" 2>/dev/null)" "token sent to api.github.com"
assert_eq 0 "$(grep -c "$tok" "$LOG_FILE")" "token absent from the log"
assert_match 'releases/latest' "$(cat "$LOG_FILE")" "request is logged"
stub_reset 200
GITHUB_TOKEN=$tok http_get https://github.com/a/b "$TMP/out" 2>/dev/null
assert_eq "" "$(cat "$STUB_CFG" 2>/dev/null)" "token withheld from other hosts"
stub_reset 500 500 500 500
GITHUB_TOKEN=$tok http_get https://api.github.com/x "$TMP/out" 2>/dev/null
assert_eq 0 "$(grep -c "$tok" "$LOG_FILE")" "token absent from the log after failures"
stub_reset 200
GITHUB_TOKEN=$tok http_get 'https://api.github.com/x?access_token=Zq9' "$TMP/out" 2>/dev/null
assert_eq 0 "$(grep -c 'Zq9' "$LOG_FILE")" "query string absent from the log"

# --- Retry-After handling: the recorded pauses ---
sleeps() { tr '\n' ' ' <"$STUB_SLEEPS" 2>/dev/null | sed 's/ $//'; }
RETRY_WAITS="3 3"
stub_reset 503 200
http_get https://github.com/a "$TMP/out"
assert_eq "3" "$(sleeps)" "no Retry-After: base wait"
stub_reset 503::1 200
http_get https://github.com/a "$TMP/out"
assert_eq "3" "$(sleeps)" "Retry-After below the base wait: base wait"
stub_reset 503::10 200
http_get https://github.com/a "$TMP/out"
assert_eq "10" "$(sleeps)" "Retry-After above the base wait is honoured"
stub_reset 503::500 200
http_get https://github.com/a "$TMP/out"
assert_eq "120" "$(sleeps)" "Retry-After capped at 120"
stub_reset 503::99999999999999999999 200
assert_eq "" "$(http_get https://github.com/a "$TMP/out" 2>&1)" "overflowing Retry-After prints nothing"
stub_reset 503::99999999999999999999 200
http_get https://github.com/a "$TMP/out" 2>/dev/null
assert_eq "3" "$(sleeps)" "overflowing Retry-After: base wait"
stub_reset 503::abc 200
http_get https://github.com/a "$TMP/out" 2>/dev/null
assert_eq "3" "$(sleeps)" "non-numeric Retry-After: base wait"
RETRY_WAITS="0 0 0"
stub_reset 503::7 000:7 200
http_get https://github.com/a "$TMP/out"
assert_eq "7 0" "$(sleeps)" "a stale header file is not reused by the next attempt"
RETRY_WAITS="0 0 0 0"

# --- GITHUB_TOKEN must be plain token characters ---
for badtok in 'abc"def' 'abc def' 'abc
header = "X-Evil: 1"' 'abc\def' "abc\$def"; do
  stub_reset 200
  GITHUB_TOKEN=$badtok http_get https://api.github.com/x "$TMP/out" 2>/dev/null
  assert_eq "" "$(cat "$STUB_CFG" 2>/dev/null)" "unsafe token is not sent"
  assert_match 'GITHUB_TOKEN ignored: unexpected characters' "$(cat "$LOG_FILE")" "unsafe token warned about"
  assert_eq 0 "$(grep -c 'Evil' "$LOG_FILE")" "unsafe token value not logged"
done
stub_reset 200
GITHUB_TOKEN=github_pat_11AA-bb.cc_DD http_get https://api.github.com/x "$TMP/out"
assert_match 'Bearer github_pat_11AA-bb.cc_DD' "$(cat "$STUB_CFG")" "fine-grained token shape is sent"

# --- adoptium_parse refuses a dot-dot path segment ---
sed 's#temurin21-binaries/releases/download/jdk-21.0.13%2B9/OpenJDK21U-jdk_x64_linux_hotspot_21.0.13_9.tar.gz",#temurin21-binaries/../../evil/releases/x.tar.gz",#' "$FIX/adoptium-linux-x64.json" >"$TMP/dotdot.json"
assert_status 1 "adoptium dot-dot in link" adoptium_parse "$TMP/dotdot.json"
sed 's#temurin21-binaries/releases/download/jdk-21.0.13%2B9/OpenJDK21U-jdk_x64_linux_hotspot_21.0.13_9.tar.gz",#temurin21-binaries/%2e%2e/evil/x.tar.gz",#' "$FIX/adoptium-linux-x64.json" >"$TMP/dotdot2.json"
assert_status 1 "adoptium encoded dot-dot in link" adoptium_parse "$TMP/dotdot2.json"
sed 's#temurin21-binaries/releases/download/jdk-21.0.13%2B9/OpenJDK21U-jdk_x64_linux_hotspot_21.0.13_9.tar.gz.sha256.txt#temurin21-binaries/../x.sha256.txt#' "$FIX/adoptium-linux-x64.json" >"$TMP/dotdot3.json"
assert_status 1 "adoptium dot-dot in sidecar link" adoptium_parse "$TMP/dotdot3.json"

# --- GitHub parsing halves, offline ---
stub_tag_curl() { printf '%s' "$STUB_LOCATION"; }
CURL=stub_tag_curl
STUB_LOCATION=https://github.com/ckir/clavity/releases/tag/clavity-v31
assert_eq clavity-v31 "$(github_latest_tag ckir/clavity)" "latest tag from redirect"
STUB_LOCATION=https://github.com/ckir/clavity/releases
assert_status 1 "no tag in redirect" github_latest_tag ckir/clavity
STUB_LOCATION=""
assert_status 1 "no redirect" github_latest_tag ckir/clavity
CURL=stub_curl
stub_reset 200
STUB_BODY=$FIX/github-release-clavity.json
assert_eq "clavity-ls-linux-x64-0.17.0.tar.gz
clavity-ls-linux-x64-0.17.0.tar.gz.sha256
clavity-ls-win-x64-0.17.0.tar.gz
clavity-ls-win-x64-0.17.0.tar.gz.sha256" "$(github_release_assets ckir/clavity)" "release assets from the API fixture"
assert_match 'repos/ckir/clavity/releases/latest$' "$(cat "$STUB_URL")" "API URL"
cat >"$TMP/expanded.html" <<'HTML'
<a href="/ckir/clavity/releases/download/clavity-v31/clavity-ls-win-x64-0.17.0.tar.gz" rel="nofollow">x</a>
<a href="/ckir/clavity/releases/download/clavity-v31/clavity-ls-win-x64-0.17.0.tar.gz.sha256" rel="nofollow">y</a>
<a href="/ckir/clavity/releases/download/clavity-v30/old.tar.gz">z</a>
<a href="/other/repo/releases/download/clavity-v31/foreign.tar.gz">w</a>
HTML
stub_reset 200
STUB_BODY=$TMP/expanded.html
assert_eq "clavity-ls-win-x64-0.17.0.tar.gz
clavity-ls-win-x64-0.17.0.tar.gz.sha256" "$(github_release_assets_scrape ckir/clavity clavity-v31)" "scraped assets: this repo and tag only"
stub_reset 404
assert_status 1 "assets API failure" github_release_assets ckir/clavity

# --- temp-file registry ---
TMP_FILES=""
mkdir "$TMP/reg" "$TMP/reg/dir with space"
: >"$TMP/reg/plain"
: >"$TMP/reg/with space.tmp.1"
: >"$TMP/reg/dir with space/inner"
register_tmp "$TMP/reg/plain"
register_tmp "$TMP/reg/with space.tmp.1"
register_tmp "$TMP/reg/dir with space"
register_tmp "$TMP/reg/never-created"
: >"$TMP/reg/keep"
cleanup_tmp
assert_eq "keep" "$(ls "$TMP/reg")" "cleanup_tmp removes registered paths, including a name with a space, and nothing else"
assert_status 0 "cleanup_tmp is idempotent" cleanup_tmp
assert_eq "" "$TMP_FILES" "registry emptied"
cleanup_tmp
assert_status 0 "empty registry is fine" cleanup_tmp

# http_get registers its private files (the token-bearing config among them)
TMPDIR=$TMP/priv
mkdir "$TMPDIR"
stub_reset 200
http_get https://github.com/a "$TMP/out"
assert_match 'rea-setup-cfg\.' "$TMP_FILES" "http_get registers its curl config"
cleanup_tmp
assert_eq "" "$(ls "$TMPDIR")" "nothing left in TMPDIR"
# --- metadata probes: retried like http_get, and -q always first so a ~/.curlrc cannot change the policy ---
# probe_stub answers "code[:exit[:location]]" per call from STUB_PLAN, counts calls, and records the first argument
probe_stub() {
  ps_n=$(cat "$STUB_COUNT" 2>/dev/null || echo 0)
  ps_n=$((ps_n + 1))
  echo "$ps_n" >"$STUB_COUNT"
  echo "$1" >>"$TMP/first-args"
  ps_line=$(sed -n "${ps_n}p" "$STUB_PLAN")
  ps_code="" ps_rc="" ps_loc=""
  IFS=: read -r ps_code ps_rc ps_loc <<EOF
$ps_line
EOF
  ps_rc=${ps_rc:-0}
  if [ -n "$ps_loc" ]; then ps_loc="https:$ps_loc"; fi
  printf '%s %s' "$ps_code" "$ps_loc"
  return "$ps_rc"
}
CURL=probe_stub
: >"$TMP/first-args"
stub_reset 504 503 200
assert_eq "https://github.com/a" "$(resolve_redirects https://github.com/a)" "resolve_redirects retries 504 and 503"
assert_eq 3 "$(cat "$STUB_COUNT")" "three probes"
stub_reset 000:28 302:0://github.com/b 000:7 200
assert_eq "https://github.com/b" "$(resolve_redirects https://github.com/a)" "transient curl exits are retried on each hop"
stub_reset 404 200
assert_status 3 "404 on a hop is not retried" resolve_redirects https://github.com/a
assert_eq 1 "$(cat "$STUB_COUNT")" "one probe on 404"
stub_reset 000:60 200
assert_status 3 "curl exit 60 is not retried" resolve_redirects https://github.com/a
assert_eq 1 "$(cat "$STUB_COUNT")" "one probe on curl exit 60"
stub_reset 504 504 504 504 200
assert_status 3 "gives up after four attempts" resolve_redirects https://github.com/a
assert_eq 4 "$(cat "$STUB_COUNT")" "four probes"
stub_reset 405 504 200
assert_eq "https://github.com/a" "$(resolve_redirects https://github.com/a)" "the ranged fallback is retried too"
stub_reset 504 302:0://github.com/ckir/clavity/releases/tag/clavity-v31
assert_eq clavity-v31 "$(github_latest_tag ckir/clavity)" "latest tag survives a 504"
stub_reset 504 504 504 504
assert_status 1 "latest tag fails after four 504s" github_latest_tag ckir/clavity
assert_eq 4 "$(cat "$STUB_COUNT")" "four tag probes"
# every curl call starts with -q
: >"$TMP/first-args"
stub_reset 200
http_get https://github.com/a "$TMP/out" || true
stub_reset 200
resolve_redirects https://github.com/a >/dev/null || true
stub_reset 302:0://github.com/ckir/clavity/releases/tag/v1
github_latest_tag ckir/clavity >/dev/null || true
stub_reset 200
cu_headers https://github.com/a -I >/dev/null || true
assert_eq "-q -q -q -q" "$(tr '\n' ' ' <"$TMP/first-args" | sed 's/ $//')" "-q is the first curl argument of every call"
CURL=stub_curl

t_done
