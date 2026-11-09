# Handoff: run and verify setup.sh on macOS

For: an agent session started on the owner's macOS machine, after fetching branch `feat/setup-script` at
commit `a902737` (or the commit that contains this file). Written 2026-11-09 on a Linux box, which has no
Gatekeeper, no BSD `sed`, no bsdtar listing, no bash 3.2 and no `Contents/Home` JDK layout. Nothing macOS-specific
has been run; CI (`macos-latest`) has not run yet either.

## Ground rules in force

- Work on a branch (for example `handoff/macos-results`), never on `main`. Commit only when the owner asks;
  push only when the owner asks. Do not cut a release or tag.
- Do not change `setup.sh` in this session. Report problems with the log lines; a fix is a separate change.
- Do NOT strip quarantine or any other attribute (`xattr -d`, `xattr -c`, `spctl --add`). The script never
  does; observe and report what macOS does.
- Measure before claiming; quote raw output. Timings: idle machine, two or more runs, range quoted, say what
  you did not control (Spotlight, Time Machine, updates).
- Do not contact anyone and do not send logs anywhere; write the results into a file for the owner.
- Read a log before passing it on: redaction is best effort.

## Already done - do not redo

All code, the dash and bash tests on Linux, the Linux integration run. The `archive_list` parsers were only
tested against GNU tar and `unzip -Z` here.

## Traps

- Stock macOS has no `sha256sum`; the verify line uses `shasum -a 256 -c -`.
- `/bin/sh` on macOS is bash 3.2 in POSIX mode; run with `sh setup.sh` exactly, not `bash setup.sh`.
- macOS has no `DISPLAY`, so the launch step prints the two-terminal flow and exits 0: that is expected.
- Real run installs about 1.2 GB under `~/.local/share/rea-tools`.
- Official Ghidra has no macOS native decompiler: a WARN on every run is expected, and so is `rea doctor`
  reporting `native_decompiler` missing.

## Items, in order (item 1 gates the rest)

1. **Preconditions.** Record `sw_vers`, `uname -m`, `sh --version` (or `bash --version`), `node --version`,
   `command -v claude agy curl tar unzip bsdtar shasum`, `tar --version`.
2. **Verify line, then a real run, as the README says.**
   ```sh
   grep ' setup.sh$' SHA256SUMS | shasum -a 256 -c -     # expect: setup.sh: OK (skip if you run from the checkout)
   sh setup.sh --yes
   echo $?
   ```
   Expected: exit 0; steps `preflight`, `prereq`, `tools-bin`, `jdk`, `ghidra`, `profile`, `rea-setup`,
   `rea-doctor` end `ok` (or `warn` for ghidra); the WARN line
   `the official 12.1.4 archive has no macOS native decompiler` at step `ghidra`; the launch step logs
   `no terminal can be opened from here: two-terminal instructions printed` and the stdout ends with the
   Terminal 1 / Terminal 2 commands. Second run: every step `skip (already valid)` or reuse, exit 0, about 30 s.
3. **O7: quarantine of curl-downloaded binaries.** After item 2, run
   `xattr -l ~/.local/bin/agent-profile ~/.local/bin/clavity-ls` and
   `~/.local/bin/agent-profile --version; ~/.local/bin/clavity-ls --version`. Report whether
   `com.apple.quarantine` is present and whether macOS blocked either binary (a Gatekeeper dialog, `killed`,
   `cannot be opened`). Do not clear anything. If a binary was blocked, quote the exact script log lines of step
   `tools-bin` (the script has no special handling for it).
4. **Temurin layout.** `ls -d ~/.local/share/rea-tools/jdk-*/` and
   `ls ~/.local/share/rea-tools/jdk-*/Contents/Home/bin | head`; the summary and `env.sh` must show `JAVA_HOME`
   ending in `/Contents/Home`. Run `. ~/.local/share/rea-tools/env.sh; "$JAVA_HOME/bin/java" -version` and quote
   the output (expected: 21).
5. **Two-terminal flow.** Open two new terminals. In both: `. ~/.local/share/rea-tools/env.sh`. Terminal 1:
   `clavity-ls agy "<folder>"`; terminal 2: `clavity-ls start "<folder>" --attach --profile rea` (exactly the
   commands the script printed, do not use the attach hint `clavity-ls agy` prints). Report whether Claude starts
   on the `rea` profile (`/status` or `echo $CLAUDE_CONFIG_DIR` must show `~/.agent-profile/profiles/rea`),
   whether `/mcp` lists `rea`, and anything that failed.
6. **bash 3.2 and bsdtar listing format.** If `bsdtar` is present (macOS `tar` is bsdtar), the script's
   `archive_list` has parsed real archives during item 2. Check the log's DEBUG lines of step `archive` (or
   `tools-bin` / `ghidra`) for rejections of safe archives. Then capture the raw listings to a file for the owner:
   `tar -tvzf <any .tar.gz from the staging dir or a fresh download of the Temurin macOS archive>` (first 15
   lines) and `unzip -Z` of the Ghidra zip if `unzip` exists (first 15 lines). Report any run where the script
   said the archive was not safe.
   To test the parser directly:
   `REA_SETUP_NO_MAIN=1 . ./setup.sh; tar -tvzf <file> | archive_tarlike_normalise | head`
   (expected lines `MODE TYPE PATH [-> TARGET]`, TYPE one of f d l h).
7. **BSD sed behaviour of `redact`.** From the checkout:
   ```sh
   REA_SETUP_NO_MAIN=1 . ./setup.sh
   n=0; bad=0
   while IFS= read -r line; do
     n=$((n+1)); in=${line%%"	"*}; want=${line#*"	"}
     got=$(redact "$in")
     [ "$got" = "$want" ] || { bad=$((bad+1)); printf 'DIFF line %s\n in:   %s\n want: %s\n got:  %s\n' "$n" "$in" "$want" "$got"; }
   done < tests/fixtures/redact-corpus.txt
   echo "lines=$n differences=$bad"
   ```
   Expected: `differences=0` and `lines` at least 39. Report every DIFF verbatim. As a bonus, if `node` exists:
   `sh tests/sh/run.sh sh bash` and report which test files fail and the first failing assertion of each
   (do not fix).
8. **`ps -o pid= -p $$`.** In `sh`, run `ps -o pid= -p $$` and `echo $$`; the numbers must match. Report the
   output (the script's lock records its owner this way).
9. **Native decompiler (only if the owner wants it verified).** Ask the owner first. If yes, follow `rea`'s
   `docs/installation.md`, sections "Missing macOS native decompiler" (x64) or "macOS arm64 native decompiler"
   (arm64), then re-run `sh setup.sh --yes --no-launch` and report whether `rea doctor` still reports
   `native_decompiler` missing. If no, report "not exercised".

## Not for this session

Windows items (see `docs/handoff/windows.md`), any change to the scripts, `--install-hopper`, releasing.

## How to finish and report back

Write `docs/handoff/macos-results.md` on your branch: per item, the command, the raw output, pass/fail against
the expectation above. Include from the newest files in `~/.local/state/rea-setup/logs`:

- the whole log of the first and second run of item 2,
- every `disk_free_mb` DEBUG line, and the measured delta
  `du -sk ~/.local/share/rea-tools` before and after the first run (Linux figure: about 1.2 GB, Ghidra 882 MB,
  JDK 346 MB),
- timings of both runs (two samples each if you can, range quoted, uncontrolled load stated),
- `sw_vers`, `uname -m`.

Leave OPEN anything not finished and list the items you did not reach.
