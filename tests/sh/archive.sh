#!/bin/sh
# Copyright (c) 2026 Costas Kirgoussios
#
# This software is licensed under the PolyForm Noncommercial License 1.0.0.
# You may obtain a copy of the License at:
# https://polyformproject.org/licenses/noncommercial/1.0.0/

# Tests for the setup.sh files layer: locks, orphan cleanup, staging, archive listing, archive safety,
# extraction, the Ghidra execute-bit rule and JDK pruning. Fixtures are built by
# tests/integration/make_archives.py into a scratch directory whose name contains a space, so every
# path below is also a quoting test.
# shellcheck source=/dev/null
. "$(dirname "$0")/lib.sh"
cd "$ROOT" || exit 1
CONSOLE_LEVEL=WARN
export CONSOLE_LEVEL

FIX=$ROOT/tests/fixtures
T="$ROOT/tests/.tmp/archive work $$"
mkdir -p "$T" || exit 1
trap 'rm -rf "$T"; rmdir "$ROOT/tests/.tmp" 2>/dev/null' EXIT
python3 -I "$ROOT/tests/integration/make_archives.py" "$T" || exit 1

# t_skip REASON: a skip is always visible on stderr (run.sh discards stdout of a passing file)
t_skip() {
  printf 'skip: %s\n' "$1" >&2
}

# --- archive safety: tar ---
assert_status 0 "clean tar safe" archive_check_safe "$T/clean.tar.gz"
assert_status 1 "dotdot tar refused" archive_check_safe "$T/dotdot.tar.gz"
assert_status 1 "dotdot in the middle tar refused" archive_check_safe "$T/dotdot-mid.tar.gz"
assert_status 1 "absolute tar refused" archive_check_safe "$T/abs.tar.gz"
assert_status 1 "symlink out refused" archive_check_safe "$T/symlink.tar.gz"
assert_status 1 "relative symlink out refused" archive_check_safe "$T/symlink-rel.tar.gz"
assert_status 1 "deep relative symlink out refused" archive_check_safe "$T/symlink-deep.tar.gz"
# GNU tar lists (and extracts) a hardlink target with leading ../ and / removed, so these two are safe as
# listed; bsdtar shows the raw target, which the line checker tests below cover.
assert_status 0 "GNU-neutralised hardlink listing is safe" archive_check_safe "$T/hardlink-rel.tar.gz"
if tar --version 2>/dev/null | grep -q 'GNU tar'; then
  assert_match '^hrw-r--r-- h top/hl -> x$' "$(archive_list "$T/hardlink-rel.tar.gz")" "GNU tar strips ../ from a hardlink target"
else
  t_skip "tar is not GNU tar: the hardlink target neutralising test is skipped"
fi
assert_status 1 "entry below an earlier symlink refused" archive_check_safe "$T/symchain.tar.gz"
assert_status 1 "missing archive refused" archive_check_safe "$T/nope.tar.gz"
assert_match 'dotdot|\.\./evil' "$(archive_check_safe "$T/dotdot.tar.gz" 2>&1)" "names the offending entry"

# --- archive safety: zip ---
assert_status 0 "clean zip safe" archive_check_safe "$T/clean.zip"
assert_status 1 "dotdot zip refused" archive_check_safe "$T/dotdot.zip"
assert_status 1 "dotdot in the middle zip refused" archive_check_safe "$T/dotdot-mid.zip"
assert_status 1 "absolute zip refused" archive_check_safe "$T/abs.zip"
assert_status 1 "backslash dotdot zip refused" archive_check_safe "$T/backslash.zip"
assert_status 1 "drive letter zip refused" archive_check_safe "$T/drive.zip"
assert_status 1 "symlink out zip refused" archive_check_safe "$T/symlink.zip"

# --- the line checker on hand-written listings (formats a local tool may not produce) ---
chk() {
  printf '%s\n' "$1" | archive_check_lines
}
assert_status 1 "absolute hardlink target refused" chk '-rw-r--r-- h top/hl -> /etc/passwd'
assert_status 0 "inside hardlink target allowed" chk '-rw-r--r-- h top/hl -> top/lib/x'
assert_status 1 "hardlink dotdot target refused" chk '-rw-r--r-- h top/hl -> top/../../x'
assert_status 0 "inside symlink allowed" chk 'lrwxrwxrwx l a/b/link -> ../c'
assert_status 0 "symlink to the root itself allowed" chk 'lrwxrwxrwx l a/link -> ..'
assert_status 1 "symlink one level too far refused" chk 'lrwxrwxrwx l a/link -> ../..'
assert_status 1 "symlink with an inner dotdot refused" chk 'lrwxrwxrwx l a/link -> b/../../x'
assert_status 1 "symlink with a lexically harmless inner dotdot refused" chk 'lrwxrwxrwx l a/link -> b/../c'
assert_status 1 "windows absolute symlink refused" chk 'lrwxrwxrwx l a/link -> C:\Windows'
assert_status 1 "ambiguous symlink line refused" chk 'lrwxrwxrwx l a -> b -> /etc/passwd'
assert_status 0 "names with spaces and arrows in a regular file allowed" chk '-rw-r--r-- f dir with space/a -> b.txt'
assert_status 1 "dotdot component with spaces refused" chk '-rw-r--r-- f dir with space/../../x'
assert_status 0 "dots inside a name allowed" chk '-rw-r--r-- f a/..b/c..d/e...'
assert_status 0 "empty listing is not unsafe by itself" chk ''

# --- archive_list normalisation ---
ml=$(archive_list "$T/clean.tar.gz")
assert_match '^-rwxr-xr-x f top/bin/java$' "$(printf '%s\n' "$ml" | grep 'bin/java')" "tar regular entry"
assert_match '^drwxr-xr-x d top/dir with space/$' "$(printf '%s\n' "$ml" | grep 'dir with space/$')" "tar directory entry with spaces"
assert_match '^-rw-r--r-- f top/file with spaces.txt$' "$(printf '%s\n' "$ml" | grep 'file with')" "tar name with spaces"
assert_match '^lrw-r--r-- l top/bin/libjli.so -> \.\./lib/libjli.so$' "$(printf '%s\n' "$ml" | grep 'bin/libjli')" "tar symlink with target"
assert_match '^hrw-r--r-- h top/hard -> top/lib/libjli.so$' "$(printf '%s\n' "$ml" | grep 'top/hard')" "tar hardlink with target"
zl=$(archive_list "$T/exec.zip")
assert_match '^-rwxr-xr-x f ghidra_12.1.4_PUBLIC/ghidraRun$' "$(printf '%s\n' "$zl" | grep 'ghidraRun')" "zip regular entry via unzip"
assert_match '^drwxr-xr-x d ghidra_12.1.4_PUBLIC/$' "$(archive_list "$T/clean.zip" | head -n 1)" "zip directory entry"
assert_match 'dir with space/inner file.txt$' "$(archive_list "$T/clean.zip")" "zip name with spaces"
assert_match '^lrwxrwxrwx l passwd -> /etc/passwd$' "$(archive_list "$T/symlink.zip")" "zip symlink target read from the entry"
assert_eq 5 "$(printf '%s\n' "$zl" | wc -l | tr -d ' ')" "zip listing has one line per entry and no header or footer"
assert_status 1 "archive_list of a missing file fails" archive_list "$T/nope.zip"

# bsdtar and jar: skipped visibly when the tool is not installed
if command -v bsdtar >/dev/null 2>&1; then
  assert_eq "$(archive_list "$T/clean.tar.gz")" "$(ARCHIVE_TAR=bsdtar archive_list "$T/clean.tar.gz")" "bsdtar tar listing matches the default"
  assert_eq "$(archive_list "$T/exec.zip")" "$(ARCHIVE_ZIP_TOOL=bsdtar archive_list "$T/exec.zip")" "bsdtar zip listing matches unzip"
else
  t_skip "bsdtar not installed: bsdtar tar and zip listing tests skipped"
fi
if [ -x "${JAVA_HOME_SELECTED:-/nonexistent}/bin/jar" ] || command -v jar >/dev/null 2>&1; then
  jh=${JAVA_HOME_SELECTED:-}
  if [ -z "$jh" ] || [ ! -x "$jh/bin/jar" ]; then
    jh=$(CDPATH='' cd -- "$(dirname -- "$(command -v jar)")/.." && pwd)
  fi
  jl=$(JAVA_HOME_SELECTED=$jh ARCHIVE_ZIP_TOOL=jar archive_list "$T/clean.zip")
  assert_match '^\? \? ghidra_12.1.4_PUBLIC/ok.txt$' "$(printf '%s\n' "$jl" | grep 'ok.txt')" "jar listing: names only, unknown type"
  assert_status 1 "jar listing of a dotdot zip refused" env JAVA_HOME_SELECTED="$jh" ARCHIVE_ZIP_TOOL=jar sh -c ". ./setup.sh; archive_check_safe \"\$1\"" _ "$T/dotdot.zip"
  jx="$T/jar extract"
  JAVA_HOME_SELECTED=$jh ARCHIVE_ZIP_TOOL=jar archive_extract "$T/exec.zip" "$jx"
  assert_status 0 "jar extract: ghidraRun executable (rule applied)" test -x "$jx/ghidra_12.1.4_PUBLIC/ghidraRun"
  assert_status 0 "jar extract: analyzeHeadless executable (rule applied)" test -x "$jx/ghidra_12.1.4_PUBLIC/support/analyzeHeadless"
  assert_status 1 "jar extract: properties not executable" test -x "$jx/ghidra_12.1.4_PUBLIC/support/launch.properties"
else
  t_skip "jar not installed: jar listing and extraction tests skipped"
fi
assert_eq unzip "$(archive_tool_for "$T/exec.zip")" "zip tool prefers unzip"
assert_eq jar "$(ARCHIVE_ZIP_TOOL=jar archive_tool_for "$T/exec.zip")" "zip tool override"

# --- review fixes: fail closed on odd zip records and hidden tool failures ---
assert_status 1 "zip entry without type bits and a ../ name refused" archive_check_safe "$T/notype-evil.zip"
assert_status 0 "zip entry without type bits and a harmless name is treated as a regular file" archive_check_safe "$T/notype-ok.zip"
assert_match '^\?rw-------  *f ghidra_12.1.4_PUBLIC/ok.txt$|^\?rw------- f ' "$(archive_list "$T/notype-ok.zip")" "no-type-bit record listed as f"
assert_status 1 "entry count differing from the header refused" archive_check_safe "$T/mismatch.zip"
assert_status 1 "empty zip refused" archive_check_safe "$T/empty.zip"
assert_status 1 "non-zip file refused" archive_check_safe "$T/notzip.zip"
assert_status 1 "empty zip cannot be listed" archive_list "$T/empty.zip"
sl=$(archive_list "$T/spacel.zip")
assert_eq "-rw-r--r-- f dir/a l b" "$(printf '%s\n' "$sl" | head -n 1)" "a name holding ' l ' gets no bogus target"
assert_status 0 "zip with ' l ' in a name is safe" archive_check_safe "$T/spacel.zip"
if command -v bsdtar >/dev/null 2>&1; then
  for z in empty notzip; do
    assert_status 1 "bsdtar zip $z refused" env ARCHIVE_ZIP_TOOL=bsdtar sh -c ". ./setup.sh; archive_check_safe \"\$1\"" _ "$T/$z.zip"
  done
  assert_status 1 "bsdtar zip missing refused" env ARCHIVE_ZIP_TOOL=bsdtar sh -c ". ./setup.sh; archive_check_safe \"\$1\"" _ "$T/nope.zip"
else
  t_skip "bsdtar not installed: bsdtar missing, non-zip and empty zip tests skipped"
fi
if [ -n "${jh:-}" ]; then
  for z in empty notzip nope; do
    assert_status 1 "jar $z.zip refused" env JAVA_HOME_SELECTED="$jh" ARCHIVE_ZIP_TOOL=jar sh -c ". ./setup.sh; archive_check_safe \"\$1\"" _ "$T/$z.zip"
  done
  assert_status 0 "jar clean zip still safe" env JAVA_HOME_SELECTED="$jh" ARCHIVE_ZIP_TOOL=jar sh -c ". ./setup.sh; archive_check_safe \"\$1\"" _ "$T/clean.zip"
fi
assert_status 1 "empty tar refused" archive_check_safe "$T/empty.tar.gz"
# deterministic fixtures
sum1=$(cksum <"$T/clean.tar.gz")
python3 -I "$ROOT/tests/integration/make_archives.py" "$T/again" || exit 1
assert_eq "$sum1" "$(cksum <"$T/again/clean.tar.gz")" "tar.gz fixtures are reproducible"
# a SIGINT during archive_list leaves no temp file behind (private TMPDIR)
mkdir -p "$T/tmpd"
cat >"$T/killer.sh" <<'KILLER_EOF'
#!/bin/sh
kill -INT "$PPID"
sleep 1
exit 0
KILLER_EOF
chmod +x "$T/killer.sh"
trc=0
TMPDIR="$T/tmpd" ARCHIVE_TAR="$T/killer.sh" sh -c ". ./setup.sh; install_traps; archive_list \"\$1\"" _ "$T/clean.tar.gz" >/dev/null 2>&1 || trc=$?
assert_eq 130 "$trc" "INT during archive_list exits 130"
assert_eq "" "$(ls -A "$T/tmpd")" "no archive_list temp file left after INT"
TMPDIR="$T/tmpd" archive_list "$T/exec.zip" >/dev/null
TMPDIR="$T/tmpd" archive_list "$T/clean.tar.gz" >/dev/null
TMPDIR="$T/tmpd" archive_list "$T/empty.zip" >/dev/null 2>&1
assert_eq "" "$(ls -A "$T/tmpd")" "archive_list removes its temp files on every path"

# --- archive_extract ---
ex="$T/extract dest"
assert_status 0 "extract tar" archive_extract "$T/clean.tar.gz" "$ex"
assert_status 0 "extracted tar file with spaces" test -f "$ex/top/file with spaces.txt"
assert_status 0 "extracted tar keeps exec bit" test -x "$ex/top/bin/java"
ez="$T/extract zip"
assert_status 0 "extract zip" archive_extract "$T/exec.zip" "$ez"
assert_status 0 "unzip extract: ghidraRun executable" test -x "$ez/ghidra_12.1.4_PUBLIC/ghidraRun"
assert_status 0 "unzip extract: rule makes analyzeHeadless executable" test -x "$ez/ghidra_12.1.4_PUBLIC/support/analyzeHeadless"
assert_status 0 "unzip extract: rule makes decompile executable" test -x "$ez/ghidra_12.1.4_PUBLIC/Ghidra/Features/Decompiler/os/linux_x86_64/decompile"
assert_status 1 "unzip extract: plain.txt not executable" test -x "$ez/ghidra_12.1.4_PUBLIC/plain.txt"
assert_status 1 "extract of a missing archive fails" archive_extract "$T/nope.tar.gz" "$T/never"
assert_status 1 "no extraction directory is created for a missing archive" test -e "$T/never"

# --- locks ---
assert_status 0 "lock fresh" lock_acquire "$T/tools"
assert_file "$T/tools/.lock/owner" "owner file"
assert_match '^pid='"$$"' started=[0-9]{4}-' "$(cat "$T/tools/.lock/owner")" "owner file content"
lock_release "$T/tools"
assert_status 1 "lock released" test -d "$T/tools/.lock"
mkdir -p "$T/tools/.lock"
printf 'pid=999999 started=x\n' >"$T/tools/.lock/owner"
assert_status 0 "stale lock taken over" lock_acquire "$T/tools"
assert_match "^pid=$$ " "$(cat "$T/tools/.lock/owner")" "takeover rewrites the owner"
lock_release "$T/tools"
mkdir -p "$T/tools/.lock"
printf 'pid=%s started=x\n' "$$" >"$T/tools/.lock/owner"
assert_status 1 "live lock refused" sh -c ". ./setup.sh; LOCK_POLLS=1; lock_acquire \"\$1\"" _ "$T/tools"
assert_status 0 "live lock left in place by the refused process" test -f "$T/tools/.lock/owner"
rm -rf "$T/tools/.lock"
mkdir -p "$T/tools/.lock"
assert_status 0 "old ownerless lock taken over" sh -c ". ./setup.sh; touch -d \"2 hours ago\" \"\$1/.lock\" 2>/dev/null || touch -t 200001010000 \"\$1/.lock\"; lock_acquire \"\$1\" && lock_release \"\$1\"" _ "$T/tools"
# two processes race to take over one stale lock: never both inside, no .lock.stale.* left (the race itself is
# timing dependent, so a pass here shows the absence of overlap in these runs, not a proof)
cat >"$T/racer.sh" <<'RACER_EOF'
. ./setup.sh
LOCK_POLLS=1
while [ ! -e "$1/go" ]; do :; done
lock_acquire "$1/tools" 2>/dev/null || exit 0
if [ -e "$1/holder" ]; then
  echo "overlap $$" >>"$1/violations"
fi
echo "$$" >"$1/holder"
sleep 0.2
[ "$(cat "$1/holder" 2>/dev/null)" = "$$" ] || echo "stolen $$" >>"$1/violations"
rm -f "$1/holder"
echo "$$" >>"$1/winners"
lock_release "$1/tools"
RACER_EOF
race_i=0
race_bad=0
while [ "$race_i" -lt 20 ]; do
  race_i=$((race_i + 1))
  rd="$T/race $race_i"
  mkdir -p "$rd/tools/.lock"
  printf 'pid=999999 started=x\n' >"$rd/tools/.lock/owner"
  sh "$T/racer.sh" "$rd" &
  rp1=$!
  sh "$T/racer.sh" "$rd" &
  rp2=$!
  : >"$rd/go"
  wait "$rp1" "$rp2"
  [ ! -e "$rd/violations" ] || race_bad=$((race_bad + 1))
  [ -e "$rd/winners" ] || race_bad=$((race_bad + 1))
  [ -z "$(find "$rd" -name '.lock.stale.*' | head -n 1)" ] || race_bad=$((race_bad + 1))
  [ ! -d "$rd/tools/.lock" ] || race_bad=$((race_bad + 1))
done
assert_eq 0 "$race_bad" "20 takeover races: no overlap, a winner each time, no stale leftovers, lock released"
# a takeover must not delete a lock whose owner changed after the staleness decision
mkdir -p "$T/chg/.lock"
printf 'pid=999999 started=x\n' >"$T/chg/.lock/owner"
assert_status 0 "stale takeover leaves no .lock.stale" sh -c ". ./setup.sh; lock_acquire \"\$1\" && lock_release \"\$1\" && test -z \"\$(find \"\$1\" -name '.lock.stale.*')\"" _ "$T/chg"
mkdir -p "$T/tools dir with space"
assert_status 0 "lock in path with space" lock_acquire "$T/tools dir with space"
lock_release "$T/tools dir with space"
assert_status 1 "lock in path with space released" test -d "$T/tools dir with space/.lock"
assert_status 0 "lock is reentrant in one process" sh -c ". ./setup.sh; lock_acquire \"\$1\" && lock_acquire \"\$1\" && lock_release \"\$1\" && test ! -d \"\$1/.lock\"" _ "$T/tools"
assert_status 0 "lock creates a missing directory" sh -c ". ./setup.sh; lock_acquire \"\$1/new/deep\" && test -d \"\$1/new/deep/.lock\"" _ "$T"
rm -rf "$T/new"

# trap test: INT while holding a lock and a staging directory leaves neither behind (via install_traps)
mkdir -p "$T/trap dir"
trc=0
sh -c ". ./setup.sh; install_traps; lock_acquire \"\$1\"; s=\$(staging_new \"\$1\" z); test -d \"\$s\" || exit 9; kill -INT \$\$; sleep 5" _ "$T/trap dir" || trc=$?
assert_eq 130 "$trc" "INT exits 130 through install_traps"
assert_status 1 "lock released by the INT trap" test -d "$T/trap dir/.lock"
assert_eq "" "$(find "$T/trap dir" -name 'z.tmp.*' | head -n 1)" "staging removed by the INT trap"
trc=0
sh -c ". ./setup.sh; install_traps; lock_acquire \"\$1\"; s=\$(staging_new \"\$1\" z); kill -TERM \$\$; sleep 5" _ "$T/trap dir" || trc=$?
assert_eq 143 "$trc" "TERM exits 143 through install_traps"
assert_status 1 "lock released by the TERM trap" test -d "$T/trap dir/.lock"
assert_eq "" "$(find "$T/trap dir" -name 'z.tmp.*' | head -n 1)" "staging removed by the TERM trap"
sh -c ". ./setup.sh; install_traps; lock_acquire \"\$1\"; STAGE=\$(staging_new \"\$1\" y); exit 0" _ "$T/trap dir"
assert_status 1 "lock released on normal exit" test -d "$T/trap dir/.lock"
assert_eq "" "$(find "$T/trap dir" -name 'y.tmp.*' | head -n 1)" "staging removed on normal exit"
sh -c ". ./setup.sh; install_traps; staging_new \"\$1\" w >/dev/null; staging_new \"\$1\" \"v v\" >/dev/null; exit 0" _ "$T/trap dir"
assert_eq "" "$(find "$T/trap dir" -name '*.tmp.*' | head -n 1)" "staging made in the main shell removed on exit (names with spaces)"

# --- orphan cleanup ---
mkdir -p "$T/tools/x.tmp.999999" "$T/tools/y.tmp.$$" "$T/tools/w.old.999999" "$T/tools/old live.tmp.$$" "$T/tools/keep.tmp.abc" "$T/tools/other.dir"
touch -d "3 days ago" "$T/tools/old live.tmp.$$" 2>/dev/null || touch -t 200001010000 "$T/tools/old live.tmp.$$"
cleanup_orphans "$T/tools"
assert_status 1 "dead-pid staging removed" test -d "$T/tools/x.tmp.999999"
assert_status 1 "dead-pid .old removed (Windows leftovers)" test -d "$T/tools/w.old.999999"
assert_status 0 "live young staging kept" test -d "$T/tools/y.tmp.$$"
assert_status 1 "live but older than 24 h removed" test -d "$T/tools/old live.tmp.$$"
assert_status 0 "non-numeric suffix kept" test -d "$T/tools/keep.tmp.abc"
assert_status 0 "unrelated dir kept" test -d "$T/tools/other.dir"
assert_status 0 "cleanup of an empty or missing dir is fine" cleanup_orphans "$T/nothing here"
rm -rf "$T/tools/y.tmp.$$" "$T/tools/keep.tmp.abc" "$T/tools/other.dir"

# --- staging and install_commit ---
s=$(staging_new "$T/tools" ghidra_12.1.4_PUBLIC)
assert_eq "$T/tools/ghidra_12.1.4_PUBLIC.tmp.$$" "$s" "staging path"
assert_status 0 "staging directory created" test -d "$s"
mkdir -p "$T/tools/ghidra_12.1.4_PUBLIC"
touch "$T/tools/ghidra_12.1.4_PUBLIC/incomplete-leftover"
touch "$s/marker"
install_commit "$s" "$T/tools/ghidra_12.1.4_PUBLIC"
assert_file "$T/tools/ghidra_12.1.4_PUBLIC/.install-complete" "sentinel"
assert_file "$T/tools/ghidra_12.1.4_PUBLIC/marker" "replaced incomplete dir"
assert_status 1 "old content gone" test -e "$T/tools/ghidra_12.1.4_PUBLIC/incomplete-leftover"
assert_status 1 "staging gone after commit" test -e "$s"
assert_status 1 "no .old left behind" test -e "$T/tools/ghidra_12.1.4_PUBLIC.old.$$"
assert_match "^[0-9]{4}-.*$PIN_SCRIPT_VERSION" "$(cat "$T/tools/ghidra_12.1.4_PUBLIC/.install-complete")" "sentinel holds timestamp and version"
assert_status 0 "install_valid with sentinel and file" install_valid "$T/tools/ghidra_12.1.4_PUBLIC" marker
assert_status 1 "install_valid with a missing file" install_valid "$T/tools/ghidra_12.1.4_PUBLIC" marker nope
assert_status 1 "no sentinel invalid" install_valid "$T/tools/nosentinel" x
mkdir -p "$T/tools/nosent2"
touch "$T/tools/nosent2/x"
assert_status 1 "dir without sentinel invalid" install_valid "$T/tools/nosent2" x
# a fresh install (no FINAL yet)
s=$(staging_new "$T/tools dir with space" "new thing")
touch "$s/f"
install_commit "$s" "$T/tools dir with space/new thing"
assert_status 0 "fresh install with spaces" install_valid "$T/tools dir with space/new thing" f
# failure of the final rm -rf only warns (an unwritable subdirectory makes the removal of the old install fail)
wlog="$T/warn.log"
if [ "$(id -u)" -eq 0 ]; then
  t_skip "running as root: the rm failure test is skipped (root can remove anything)"
else
  s=$(staging_new "$T/tools" warn)
  mkdir -p "$T/tools/warnfinal/locked"
  touch "$T/tools/warnfinal/locked/f"
  chmod 555 "$T/tools/warnfinal/locked"
  wrc=0
  CONSOLE_LEVEL=DEBUG LOG_FILE="$wlog" install_commit "$s" "$T/tools/warnfinal" 2>/dev/null || wrc=$?
  chmod 755 "$T/tools/warnfinal.old.$$/locked"
  assert_eq 0 "$wrc" "rm failure does not fail install_commit"
  assert_match 'WARN +\[install\]' "$(cat "$wlog")" "rm failure logs a WARN"
  assert_status 0 "install still committed" install_valid "$T/tools/warnfinal"
  rm -rf "$T/tools/warnfinal.old.$$"
fi

# --- disk space ---
assert_match '^[0-9]+$' "$(disk_free_mb "$T")" "disk_free_mb is a number"
assert_match '^[0-9]+$' "$(disk_free_mb "$T/does/not/exist/yet")" "disk_free_mb of a missing path uses its parent"
assert_status 0 "require_free_mb 1" sh -c ". ./setup.sh; require_free_mb \"\$1\" 1" _ "$T"
assert_status 1 "require_free_mb huge" sh -c ". ./setup.sh; require_free_mb \"\$1\" 999999999999" _ "$T"
assert_match 'short by' "$(sh -c ". ./setup.sh; require_free_mb \"\$1\" 999999999999" _ "$T" 2>&1)" "shortfall named"

# --- defaults ---
assert_eq "/x/data/rea-tools" "$(OPT_TOOLS_DIR='' XDG_DATA_HOME=/x/data tools_dir_default)" "tools dir from XDG"
assert_eq "/h/.local/share/rea-tools" "$(OPT_TOOLS_DIR='' XDG_DATA_HOME='' HOME=/h tools_dir_default)" "tools dir from HOME"
assert_eq "/o t" "$(OPT_TOOLS_DIR='/o t' tools_dir_default)" "tools dir option wins"
assert_eq "/h/.local/bin" "$(OPT_BIN_DIR='' HOME=/h bin_dir_default)" "bin dir default"
assert_eq "/b" "$(OPT_BIN_DIR=/b bin_dir_default)" "bin dir option wins"

# --- ghidra_set_exec_bits ---
mkdir -p "$T/g/support" "$T/g/Ghidra/Features/Decompiler/os/linux_x86_64"
touch "$T/g/ghidraRun" "$T/g/support/analyzeHeadless" "$T/g/support/launch.properties" "$T/g/Ghidra/Features/Decompiler/os/linux_x86_64/decompile"
ghidra_set_exec_bits "$T/g"
assert_status 0 "exec analyzeHeadless" test -x "$T/g/support/analyzeHeadless"
assert_status 0 "exec decompile" test -x "$T/g/Ghidra/Features/Decompiler/os/linux_x86_64/decompile"
assert_status 1 "properties not exec" test -x "$T/g/support/launch.properties"

# rule coverage against the measured list (134 paths from the real 12.1.4 zip, top directory removed).
# The rule is meant to cover the launchers and native binaries Ghidra needs; the zip also carries
# execute bits on data files (BSim xml, jars, sources, class-room exercise binaries) that nothing runs.
# Recreate every measured path as an empty file, apply the rule, and demand: the needed set is exactly
# executable, the rest is exactly untouched. Both counts are pinned so a change to the list or the rule shows.
assert_eq 134 "$(wc -l <"$FIX/ghidra-12.1.4-exec.list" | tr -d ' ')" "measured list has 134 paths"
rc_root="$T/rule root"
rm -rf "$rc_root"
mkdir -p "$rc_root"
while IFS= read -r p; do
  mkdir -p "$rc_root/$(dirname -- "$p")"
  : >"$rc_root/$p"
done <"$FIX/ghidra-12.1.4-exec.list"
# negatives the rule must not touch, in the directories it does touch
for n in support/launch.properties support/x.bat support/readme.txt support/index.html support/x.cmd server/x.properties server/x.bat; do
  : >"$rc_root/$n"
done
mkdir -p "$rc_root/support/sub" "$rc_root/Ghidra/Debug/Debugger-gdb/data" "$rc_root/Ghidra/Features/X/data"
: >"$rc_root/support/sub/deep.dat"
: >"$rc_root/Ghidra/Debug/Debugger-gdb/data/not-a-launcher.txt"
: >"$rc_root/Ghidra/Features/X/data/os-neutral.bin"
ghidra_set_exec_bits "$rc_root"
required=$(grep -E '^(ghidraRun|support/[^/]+|server/[^/]+|.*\.sh|.*/?os/linux_x86_64/.*|Ghidra/Debug/[^/]+/data/debugger-launchers/.*|Ghidra/Debug/Debugger-isf/support/runISFServer|support/gradle/gradlew|support/GhidraGo/ghidraGo)$' "$FIX/ghidra-12.1.4-exec.list" | grep -v -E '\.(bat|properties|txt|html|cmd)$')
assert_eq 51 "$(printf '%s\n' "$required" | wc -l | tr -d ' ')" "rule covers 51 of the 134 measured paths"
missing=""
while IFS= read -r p; do
  [ -x "$rc_root/$p" ] || missing="$missing $p"
done <<EOF
$required
EOF
assert_eq "" "$missing" "every required path is executable"
uncovered=$(
  grep -v -x -F -f - "$FIX/ghidra-12.1.4-exec.list" <<EOF
$required
EOF
)
assert_eq 83 "$(printf '%s\n' "$uncovered" | wc -l | tr -d ' ')" "83 measured paths are deliberately not covered"
extra=""
while IFS= read -r p; do
  [ -x "$rc_root/$p" ] && extra="$extra $p"
done <<EOF
$uncovered
EOF
assert_eq "" "$extra" "uncovered data files stay non-executable"
over=$(cd "$rc_root" && find . -type f -perm -u+x | sed 's#^\./##' | LC_ALL=C sort)
assert_eq "$(printf '%s\n' "$required" | LC_ALL=C sort)" "$over" "the executable set is exactly the required set"
# the uncovered set contains only the known families
assert_eq "" "$(printf '%s\n' "$uncovered" | grep -v -E '^(Ghidra/Features/|Ghidra/Framework/|Ghidra/Processors/|docs/)')" "uncovered paths are only data families"

# --- prune_jdks ---
pj="$T/jdk tools"
mkjdk() {
  for mj_n in "$@"; do
    mkdir -p "$pj/$mj_n"
    : >"$pj/$mj_n/.install-complete"
  done
}
mkjdk jdk-21.0.13+9 jdk-21.0.9+10 jdk-21.0.13+10 jdk-17.0.1+1
mkdir -p "$pj/jdk-21.0.13+9" "$pj/jdk-21.0.9+10" "$pj/jdk-21.0.13+10" "$pj/jdk-17.0.1+1" "$pj/not-a-jdk" "$pj/jdk-21.0.13+9.tmp.1" "$pj/ghidra_12.1.4_PUBLIC"
mkdir -p "$pj/jdk-notes" "$pj/jdk-21-scratch" "$pj/jdk-0.0.1-user/sub"
touch "$pj/jdk-notes/keep.txt" "$pj/jdk-0.0.1-user/sub/f"
mkdir -p "$pj/jdk-mac-old/Contents/Home" "$pj/jdk-1.8.0+1/Contents/Home"
: >"$pj/jdk-1.8.0+1/Contents/Home/release"
JAVA_HOME="" JAVA_HOME_SELECTED="" prune_jdks "$pj"
assert_status 0 "jdk-notes (user directory) untouched" test -f "$pj/jdk-notes/keep.txt"
assert_status 0 "jdk-21-scratch (no marker) untouched" test -d "$pj/jdk-21-scratch"
assert_status 0 "jdk-0.0.1-user (no marker) untouched" test -d "$pj/jdk-0.0.1-user/sub"
assert_status 0 "jdk-mac-old (not a version name) untouched" test -d "$pj/jdk-mac-old"
assert_status 1 "old mac-layout jdk with a release file pruned" test -d "$pj/jdk-1.8.0+1"
assert_status 0 "newest jdk kept" test -d "$pj/jdk-21.0.13+10"
assert_status 0 "second newest jdk kept" test -d "$pj/jdk-21.0.13+9"
assert_status 1 "21.0.9+10 pruned (older release)" test -d "$pj/jdk-21.0.9+10"
assert_status 1 "17.0.1+1 pruned" test -d "$pj/jdk-17.0.1+1"
assert_status 0 "non-jdk dirs untouched" test -d "$pj/not-a-jdk"
assert_status 0 "ghidra untouched" test -d "$pj/ghidra_12.1.4_PUBLIC"
assert_status 0 "staging-named jdk untouched" test -d "$pj/jdk-21.0.13+9.tmp.1"
mkjdk jdk-21.0.9+10
mkdir -p "$pj/jdk-21.0.9+10/Contents/Home"
mkjdk jdk-21.0.20+1
JAVA_HOME="$pj/jdk-21.0.9+10/Contents/Home" prune_jdks "$pj"
assert_status 0 "JAVA_HOME's jdk never pruned (even below it)" test -d "$pj/jdk-21.0.9+10"
assert_status 0 "newest kept" test -d "$pj/jdk-21.0.20+1"
assert_status 0 "second newest kept" test -d "$pj/jdk-21.0.13+10"
assert_status 1 "third newest pruned" test -d "$pj/jdk-21.0.13+9"
JAVA_HOME="" JAVA_HOME_SELECTED="$pj/jdk-21.0.9+10" prune_jdks "$pj"
assert_status 0 "JAVA_HOME_SELECTED's jdk never pruned" test -d "$pj/jdk-21.0.9+10"
JAVA_HOME="" JAVA_HOME_SELECTED="" prune_jdks "$pj"
assert_status 1 "unprotected old jdk pruned" test -d "$pj/jdk-21.0.9+10"
assert_status 0 "prune of a missing dir is fine" prune_jdks "$T/no such tools"

t_done
