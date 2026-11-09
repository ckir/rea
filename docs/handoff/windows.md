# Handoff: run and verify setup.ps1 on Windows

For: an agent session started on the owner's Windows machine, after fetching branch `feat/setup-script` at
commit `a902737` (or the commit that contains this file). Written 2026-11-09 on a Linux box, which cannot run
Windows PowerShell 5.1, `wt`, NTFS volume checks, SmartScreen or `tar.exe`. Every Windows-specific behaviour
of `setup.ps1` is so far untested on a real machine; CI (`windows-latest`) has not run yet either.

## Ground rules in force

- Work on a branch (for example `handoff/windows-results`), never on `main`. Commit only when the owner asks;
  push only when the owner asks. Do not cut a release or tag.
- Do not change `setup.ps1` or `setup.sh` in this session. If something is wrong, report it with the log lines;
  a fix is a separate change with its own review gates.
- Measure before claiming. Quote raw output next to every figure. A timing needs an idle machine, two or more
  runs, and the range quoted (not a point); say what background load you did not control (Windows Update,
  Defender, indexing).
- Do not contact anyone and do not send the log anywhere: write results into a file and hand it to the owner.
- Read a log before passing it on: redaction is best effort (values over 20000 characters, nested JSON,
  cookie headers and unquoted values with spaces are not handled).

## Already done - do not redo

All code, shell tests (dash, bash), the Linux integration run, the drift check and the canary on Linux. Nothing
Windows-specific has been run.

## Traps

- Do not use `powershell -File .\setup.ps1` without `-ExecutionPolicy Bypass` for the first run: a stock
  `Restricted` policy refuses it, which is itself the thing item 3 checks.
- `-InstallHopper` is rejected on Windows (exit 2); do not try it.
- A real run installs about 1.2 GB under `%LOCALAPPDATA%\rea-tools` and downloads about 778 MB. Run
  `Remove-Item -Recurse` on it only when an item says so.
- `-Yes` skips the question but the disclosures are still printed.

## Items, in order (item 1 gates the rest)

Use Windows PowerShell 5.1 (`powershell.exe`) unless stated. Get the script from the repo checkout.

1. **Preconditions.** Record: `$PSVersionTable.PSVersion`, `node --version`, `where.exe claude`, `where.exe agy`,
   `where.exe wt`, `(Get-Command wt).Source`, `tar --version`,
   `Get-ExecutionPolicy -List`, and
   `(Get-ItemProperty HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem).LongPathsEnabled`
   (expected: absent or 0; if it is 1, say so, because item 6 then proves less).
   Expected: `claude` resolves to a `.exe`. If `where.exe claude` shows only a `.cmd`, the script must stop with
   exit 4: run `powershell -NoProfile -ExecutionPolicy Bypass -File .\setup.ps1 -Yes -NoLaunch; $LASTEXITCODE`
   and report the message.
2. **O13: `wt` is a working install, not a disabled App Execution Alias.** Run `wt --version` and open
   Settings > Apps > Advanced app settings > App execution aliases; note whether `wt.exe` is on. If it is off the
   script must report exit 4 at step `prereq` naming `wt`; if it is on and works the step must pass. Report
   which, with the log line.
3. **A real run exactly as the README says, on a stock `Restricted` policy.**
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\setup.ps1 -Yes -NoLaunch
   $LASTEXITCODE
   ```
   Expected: exit 0; the console prints the log path first; steps `preflight`, `prereq`, `tools-bin`, `jdk`,
   `ghidra`, `profile`, `rea-setup`, `rea-doctor` each end `ok`; a summary on stdout; `env.ps1` written. Take
   timings from the log timestamps (state the load you did not control). Then run it a second time with
   the same command: expect every step `skip (already valid)` or reuse, exit 0, and about 30 s (npx).
   Also: in a window where `Get-ExecutionPolicy` is `Restricted`, run `.\setup.ps1` plainly and report the
   refusal text (it documents why the README uses Bypass).
4. **Launch.** `powershell -NoProfile -ExecutionPolicy Bypass -File .\setup.ps1 -Yes` (no `-NoLaunch`). Expect
   `clavity-ls start` to open Windows Terminal with agy and Claude Code on the `rea` profile. In Claude Code
   run `/mcp` and confirm `rea` is listed. Close the session normally, then check the exit code and the log line
   `launch exited <n>`. Then start again and press Ctrl-C in the launching window: report what the console does,
   the exit code, and the `launch exited` line.
5. **O10: fixed NTFS rule.** The default tools dir is under `%LOCALAPPDATA%`. Confirm item 3 did not stop at
   step `disk`. Then, only if you have one, run with `-ToolsDir` on a removable or network drive and expect exit 1
   with `the install location must be on a fixed NTFS volume`. Report `(Get-Volume).FileSystem` and DriveType of
   the `%LOCALAPPDATA%` volume. Also confirm `rea doctor --provider ghidra` (inside the run) did not complain
   about the volume.
6. **Longest Ghidra path versus MAX_PATH.** The longest entry in the Ghidra zip is 149 characters below the
   extraction directory; the script refuses when the result would pass 240. With `LongPathsEnabled` unset,
   run with a deliberately long tools dir:
   `-ToolsDir C:\<a directory name padded so the full path is 70 characters> -Yes -NoLaunch -DryRun` is not
   enough (a dry run extracts nothing); use a real run on a spare directory and expect exit 5 with
   `the longest path to extract would be`. Then a 64-character tools dir must succeed. Delete the spare
   directory afterwards. Report the lengths you used.
7. **SmartScreen and antivirus.** After item 3, run `Get-ChildItem $env:LOCALAPPDATA\rea-tools\bin | Get-Item |
   Select Name,Length` and `Get-MpThreatDetection` (if Defender). Report: whether `agent-profile.exe` and
   `clavity-ls.exe` exist at the expected sizes, whether either was quarantined or deleted (the script's next
   `--version` call would then fail), whether SmartScreen prompted when `clavity-ls.exe` first ran, and any
   third-party antivirus you could see. Do not add exclusions.
8. **In-use `.exe` update path.** With a `clavity-ls` session running (item 4), run the script again. If a newer
   release of either tool exists, expect the WARN `close running sessions to update <name>` and a summary line
   `kept <version> (in use)`, exit 0. If no newer release exists, say so: the path is then unexercised. To force
   it, copy an older `clavity-ls.exe` over the installed one only if the owner agrees; otherwise report as not
   exercised.
9. **Pester under Windows PowerShell 5.1 (O17).**
   ```powershell
   Get-Module -ListAvailable Pester | Select Name,Version,Path
   powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Import-Module Pester -MinimumVersion 5.0; Invoke-Pester -Path tests/pester -CI"
   ```
   Expected: Pester 5.x resolves ahead of the built-in 3.4.0 (if only 3.4.0 exists, install 5.9.0 for the
   current user and say so); all tests pass; report the totals and any failure with its message.
10. **Odd tools directories.** Real run with `-ToolsDir "C:\rea tools"` (a space) and, separately, a directory
    whose name holds a typographic apostrophe (U+2019), for example `C:\rea` + [char]0x2019 + `s tools`. Both are
    expected to succeed, with `env.ps1` correctly quoted: dot-source it in a new window and check
    `$env:GHIDRA_INSTALL_DIR`, `$env:JAVA_HOME`, `Get-Command clavity-ls`. Report any failure verbatim.
11. **Not-executable rule for `Get-ReaInstalledVersion`.** Rename the installed `agent-profile.exe` to
    `agent-profile.exe.bak`, copy any text file to `agent-profile.exe`, run the script: it must treat the tool as
    not installed (empty version) and reinstall, not crash. Restore afterwards. Report the log lines of step
    `tools-bin`.
12. **`Start-Process` / `npx.cmd` resolution.** Item 3 already exercised it; additionally, report from the log
    how `npx` was resolved (the DEBUG lines of step `rea-setup` naming the command) and that `rea setup` and
    `rea doctor` JSON appear in the log.

## Not for this session

macOS items (see `docs/handoff/macos.md`), any change to the scripts, `-InstallHopper`, releasing.

## How to finish and report back

Write `docs/handoff/windows-results.md` on your branch with: per item, the command, the raw output (trimmed
only of secrets), pass/fail against the expectation above, and anything surprising. Attach the contents
needed from the newest files in `%LOCALAPPDATA%\rea-setup\logs`:

- the whole log of the item 3 first run and of the second run (they are DEBUG logs, home paths are abbreviated),
- every `disk_free_mb` DEBUG line (they appear before each install, for example
  `disk_free_mb <n> MB at <dir> before the download`); also run
  `(Get-ChildItem $env:LOCALAPPDATA\rea-tools -Recurse -Force | Measure-Object Length -Sum).Sum / 1MB` before
  and after the first run to give the measured on-disk delta (the Linux figure is about 1.2 GB, Ghidra 882 MB,
  JDK 346 MB),
- timings of the first and second runs (two runs each if you can, range quoted, load uncontrolled stated),
- `$PSVersionTable`, Windows build (`[Environment]::OSVersion`), and the antivirus products found.

Before handing over, run nothing else in the repo; do not edit the scripts. Leave OPEN anything not finished
and list which items you did not reach. The owner reads the file and decides what changes.
