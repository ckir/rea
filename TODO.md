# TODO

Open items that are not part of any change in progress. Add one `- [ ]` line per item and tick or delete it when
it is done.

- [ ] `tests/sh/run.sh` runs its 12 test files one after another under each of dash, bash and `/bin/sh`, so a full
  run is slow (measured 2026-11-27 on a loaded machine: not finished after 10 minutes), and a file that fails is
  run a second time to print its output. Run the files in parallel, or let a single file or shell be named.
- [ ] Home-path abbreviation has no shared test corpus. `abbrev_home` (`setup.sh`) is tested only in
  `tests/sh/core.sh` and `Convert-ReaHomeText` (`setup.ps1`) only in `tests/pester/Core.Tests.ps1`, so the two
  can drift apart. The secret redaction already shares `tests/fixtures/redact-corpus.txt`; do the same here.
- [ ] Reported, unverified: in bash 3.2 POSIX mode (macOS `/bin/bash`) a variable assigned in front of a function
  call stays set after the call. It was seen leaking `ARCHIVE_ZIP_TOOL` on macOS, and it does not reproduce on
  bash 5.3 (checked 2026-11-27). Sites: `tests/sh/archive.sh` (`TMPDIR`, `CONSOLE_LEVEL`, `JAVA_HOME`) and
  `tests/sh/network.sh` (`GITHUB_TOKEN`). Confirm on a Mac, then run each such call in a subshell.
