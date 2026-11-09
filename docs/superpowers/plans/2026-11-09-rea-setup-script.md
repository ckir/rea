# REA Setup Script Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Two single-file scripts, `setup.sh` (POSIX sh) and `setup.ps1` (Windows PowerShell 5.1), that take a stock machine to a running `clavity-ls` session with `morluto/rea` registered in an isolated `agent-profile` Claude profile, plus the `just`/`lefthook`/CI quality gates and a GitHub release process.

**Architecture:** Each script is one file (friends download one file), organised as pure helper functions (platform mapping, semver, validation, URL and archive safety, logging) and nine step functions (`preflight`, `prereq`, `tools-bin`, `jdk`, `ghidra`, `profile`, `rea-setup`, `rea-doctor`, `launch`) driven by `main`. A sourcing guard (`REA_SETUP_NO_MAIN=1`) lets the test suites load the functions without running `main`. Tests are plain `sh` files run under `dash` and `bash` (and `/bin/sh` on macOS) and Pester 5 files; failure injection uses a test-only Python fake release server; prerequisites are stubbed with fake executables on `PATH`.

**Tech Stack:** POSIX sh (curl, tar, unzip or bsdtar, `jar` fallback), Windows PowerShell 5.1 (.NET `HttpWebRequest`, `System.IO.Compression`, `tar.exe`), Node (JSON parsing on POSIX, already a `rea` prerequisite), `just`, `lefthook`, shellcheck, shfmt, PSScriptAnalyzer, Pester 5, typos, actionlint, addlicense, jq, Python 3 (tests only), GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-11-09-rea-setup-script-design.md` (sections are cited as "spec §N").

## Global Constraints

- `setup.sh` is POSIX `sh`: no bashisms, passes `shellcheck -s sh` and `shfmt -ln posix -i 2 -ci -d`; runs under `dash` and bash 3.2.
- `setup.ps1` is Windows PowerShell 5.1 compatible: `[CmdletBinding()]`, PSScriptAnalyzer `PSUseCompatibleSyntax` with `TargetVersions = @("5.1")`, no ternary, no `??`, no PowerShell 7 cmdlet parameters.
- Pins (spec §6), the only ones: Ghidra exactly `12.1.4`, zip `ghidra_12.1.4_PUBLIC_20260921.zip`, 569,649,598 bytes, SHA-256 `ddac49f903da9d5bac833e5cc79395098b9c33cfd3279be5f31bd00387d2d4db` (verified at planning against the downloaded zip and the release notes); JDK major 21 with fallback release `jdk-21.0.13+9`; everything else "latest".
- Node floors (from `rea` `install.sh`): 22.x >= 22.23.4, 24.x >= 24.22.1, or >= 26.12.1.
- Exit codes (spec §7): 0 ok, 1 step failed, 2 usage or non-interactive without `--yes`, 3 unsupported platform, 4 prerequisite, 5 verification failed. After `clavity-ls start` the script exits with Claude's own exit code.
- Host allow-list (spec §8, measured O14): `github.com`, `api.github.com`, `release-assets.githubusercontent.com`, `api.adoptium.net`, `registry.npmjs.org`, `raw.githubusercontent.com`. HTTPS only. Redirects resolved by the script, at most 5 hops. `GITHUB_TOKEN` only to `api.github.com`.
- Retries: 4 attempts, waits 2, 4, 8, 16 s, for connection errors and HTTP 5xx; 429 honours `Retry-After`; other 4xx never retried. Stalled transfer (under 1 KiB/s for 60 s) aborts.
- Log line format (spec §9): `<UTC ISO-8601>Z LEVEL [step] message`, LEVEL padded to five characters; file always DEBUG, console INFO by default; UTF-8 without BOM; log file `setup-<yyyymmddThhmmssZ>-<pid>.log`; newest 20 kept.
- Redaction (spec §9): never log the value of any variable whose name contains `TOKEN`, `KEY`, `SECRET` or `PASSWORD`; strip `Authorization` headers and URL userinfo/query strings; abbreviate the home directory as `~` (POSIX) or `%USERPROFILE%` (Windows).
- Anti-goals (spec §2): never write under `~/.claude` or `~/.claude.json`; never edit shell profiles or the registry; never strip macOS quarantine attributes; never leave an install directory that looks complete without `.install-complete`.
- Licence: every source file (scripts, tests, workflows, justfile, lefthook.yml) carries `header.txt` (PolyForm Noncommercial 1.0.0), checked by `addlicense`.
- Line citations: no comment in a script, test or workflow cites another file by line number (gate `line-citations`). Cite symbols or quoted phrases.
- Every commit passes `just check` (Task 1 defines it) before it is made.

## Review Focus

Inputs the spec implies but no step exercises by default. Each has a test added to the task named.

1. **Paths with spaces** (`C:\Users\John Smith`, `/Users/Jane Doe`) in the home directory, `--tools-dir`, `--folder` and `--bin-dir`: every path must be quoted when passed to curl, tar, unzip, `jar`, `clavity-ls`; expected: identical behaviour. Test in Task 6 and Task 13 (throwaway tools dir with a space).
2. **Interruption** (Ctrl-C or power loss) during download or extraction: the lock is released, the `*.tmp.<pid>` staging is removed on the next run, and the re-run installs cleanly. Test in Task 6 (`trap` behaviour and orphan cleanup).
3. **A JDK that is present but wrong** (`JAVA_HOME` pointing at a JRE, a JDK 17, or a 32-bit JDK): expected WARN and continue to install, never a crash or a silent reuse. Test in Task 9.
4. **An aborted earlier install** that left `<tools>/ghidra_12.1.4_PUBLIC` without `.install-complete`: expected "treated as absent" and replaced, including the rename over the existing directory. Test in Task 6 and Task 10.
5. **Node present but too old** (this machine's default is 24.21.0): expected exit 4 with the `fnm install 24` hint before any download starts. Test in Task 2 (version comparison) and Task 13 (end-to-end with a stub `node`).

---

## A. Measurements made for this plan (resolves spec §13)

| Item | Result (measured 2026-11-09 unless noted) | Consequence |
|---|---|---|
| O1 | `npx -y rea-agents@latest setup --client claude_code --yes` with `CLAUDE_CONFIG_DIR` set to a throwaway directory wrote `$CLAUDE_CONFIG_DIR/.claude.json` with `mcpServers.rea = {command: "npx", args: ["-y","rea-agents@6.8.0","mcp"], env: {GHIDRA_INSTALL_DIR, JAVA_HOME}}` and `skills/reverse-engineer-anything/`. `~/.claude.json` was not touched. Source: `GhidraDoctor.ts` publishes `registrationEnvironment` when the inspection status is `available`. | The MCP server gets its environment from the registration. The fallback in spec §8 ("claude mcp") is NOT needed. The registration pins the `rea` version that ran setup; a re-run of the script refreshes it. |
| O2 | Moot (O1). | No work. |
| O3 | JDK `jdk-21.0.13+9` unpacked: 346 MB; archive 208 MB. Ghidra unpacked 882 MB; zip 570 MB. | Free-space check: Ghidra needs 1,500 MB, the JDK 600 MB; `main` checks the sum over pending installs plus 200 MB once, after the plan phase and before the prompt (Task 13), so a run never starts a download it cannot finish; each install re-checks its own share just before downloading, as defence against another process filling the disk in between. |
| O4 | `checksum_link` (`...tar.gz.sha256.txt`) exists, HTTP 200, content `d7f5…d1c  OpenJDK21U-jdk_x64_linux_hotspot_21.0.13_9.tar.gz`, equal to the API `checksum`. | Cross-check stays. Sidecar parsing takes the first 64-hex token (aiprofiles uses `hash  name`, clavity `hash *name`). |
| O5 | `agent-profile-aarch64-apple-darwin.tar.gz` = one file `agent-profile`. `clavity-ls-win-x64-0.17.0.tar.gz` = one file `clavity-ls.exe` (79 MB). Both sidecars match. | Windows needs `tar.exe` for `clavity-ls` (spec already requires it). |
| O6 | `agent-profile claude doctor <n> --json` exits 5 exactly when `result` is `"fail"` (reproduced twice: root is a regular file; profile directory is a regular file). In both cases `create` then exits 4. Exit 0 with `status:"warn"` checks for an unreadable profile directory. `CLAUDE_CONFIG_DIR` is at `.checks[] | select(.id=="launch_environment") | .data.value`. `AGENT_PROFILE_HOME` overrides the root. `clavity-ls` treats 5 as warnings (`ProfileSetup.cs` `DoctorWarnings = 5`). | Design stands: 5 is WARN with the failing check ids logged; `create` decides. Tests use `AGENT_PROFILE_HOME`. |
| O8 | `rea doctor ... --json` top-level keys: `healthy`, `environment_healthy`, `checks[]`, `scope_checks[]{name,ok,code}`, `providerInspections[]{id,configured,available,providerVersion,registrationEnvironment,checks[]{name,ok,code}}`, `identity.cli_package_version`. Exit 1 when `healthy` is false (empty profile: `scope_checks` fail on `registration:claude_code` and `skill:identity`). Bad Ghidra dir: `installation` check code `executable_missing`, `providerVersion` null. Zip has no macOS decompiler, see O7 row. | The script reads only `healthy`, `scope_checks[].{name,ok}`, and for Ghidra `available`, `providerVersion`, `checks[].{name,ok,code}`. |
| O7 | NEW FACT: the Ghidra 12.1.4 zip contains native decompilers only for `linux_x86_64` and `win_x86_64`. `rea` expects `mac_x86_64` / `mac_arm_64` (`GhidraInstallation.ts`) and documents a manual build with Xcode Command Line Tools, `make` and `bison` (`docs/installation.md`, "Missing macOS native decompiler" and "macOS arm64 native decompiler"). | On macOS the script installs Ghidra, then `rea-doctor` reports `native_decompiler` failing. Plan decision (Task 12, flagged to the owner): WARN with the recipe pointer, do not fail, continue to launch. Quarantine behaviour and Temurin macOS layout remain for the macOS handoff. |
| O9 | Cause and `--attach --profile` verified earlier. The env file in both terminals is tested on Linux in Task 13 with stubs. | macOS real run via handoff (Task 15). |
| O10, O13 | Windows-only facts. | Windows handoff (Task 15). |
| O11 | Release process decided here: tag `v<semver>` pushed by the owner → `release.yml` runs `just check`, asserts the tag equals `SCRIPT_VERSION` in both scripts, publishes `setup.sh`, `setup.ps1`, `SHA256SUMS`. | Task 15. |
| O12 | `clavity-ls --version` prints `clavity-ls 0.17.0+c356375b`; `agent-profile --version` prints `agent-profile 0.1.1`. | `semver_from_output` takes the first `X.Y.Z` match and drops `+…`. |
| O14 | Every GitHub release download redirects to `release-assets.githubusercontent.com` (one hop from `/releases/download/`, two from `/releases/latest/download/`). Adoptium's binary endpoint: 307 to `github.com`, then 302 to `release-assets.githubusercontent.com`. | Allow-list fixed as in Global Constraints. |
| O15 | 134 entries carry an execute bit; 0 symlinks; 0 unsafe paths; top directory `ghidra_12.1.4_PUBLIC`; `application.version=12.1.4`. The owner's unzip-extracted install has exactly the same 134. | Exec-bit rule for the `jar` fallback (Linux only) in Task 6. |
| O16 | CI installs `just`, `shellcheck`, `shfmt`, `typos` through `taiki-e/install-action` (manifests exist for all four); `actionlint` and `addlicense` through `go install …@<version>` (Go module checksums). `jq` is preinstalled on all three runner images. | Task 1 `ci.yml`. |
| O17 | `windows-2025`: PowerShell 7.6.9, Windows PowerShell 5.1 (`powershell.exe`), Pester 3.4.0 and 5.9.0, PSScriptAnalyzer 1.25.0. `macos-15`: bash 3.2.57, PowerShell 7.6.4. `ubuntu-24.04`: dash 0.5.12, PowerShell 7.6.9. Local: Pester 6.2.0. | Tests use Pester 5 syntax; the recipe imports `Pester -MinimumVersion 5.0`; CI installs `Pester -RequiredVersion 5.9.0` where absent. |
| O18 | Decided: stub executables on `PATH` (`tests/fixtures/bin/`), no test seam in the scripts beyond the sourcing guard. Test-only URL/scheme overrides are shell variables reassigned after sourcing, never environment variables the product reads. | Tasks 4, 13. |
| O19 | PSScriptAnalyzer pinned to 1.25.0 (local and runner). Profile-based compatibility rules not used. | Task 1. |

Release-asset facts used below: `ckir/aiprofiles` latest `v0.1.2` has `agent-profile-{x86_64-unknown-linux-gnu,aarch64-unknown-linux-gnu,x86_64-apple-darwin,aarch64-apple-darwin}.tar.gz` and `agent-profile-x86_64-pc-windows-msvc.zip`, each with `.sha256`. `ckir/clavity` latest `clavity-v31` has `clavity-ls-{linux-x64,osx-arm64,osx-x64,win-x64}-0.17.0.tar.gz` with `.sha256`. The GitHub API `releases/latest` JSON has `tag_name` and `assets[].{name,browser_download_url,size}`.

## B. Decisions this plan makes (builder level; the spec leaves them open)

- One file per script. Helpers are functions inside it; tests source the file with `REA_SETUP_NO_MAIN=1`.
- JSON on POSIX is parsed with `node -e` (Node is a `rea` prerequisite checked in `prereq`; `jq` is not assumed on friends' machines). PowerShell uses `ConvertFrom-Json`.
- Steps 1 and 2 need no JSON; the `tools-bin` step runs after `prereq`, so `node` is available for the GitHub API response.
- Function naming: sh `snake_case`; ps1 `Verb-ReaNoun` as listed in each Interfaces block.
- Lock: `mkdir <tools>/.lock` (atomic on every platform) with an `owner` file `pid=<n> started=<UTC>`; stale when the pid is not alive; poll every 2 s up to 120 s.
- Rename over an existing incomplete directory: move the old one to `<name>.old.<pid>`, rename the staging in, then delete the old one (a failed delete on Windows is WARN).
- macOS native decompiler (O7): WARN, print the two `rea` recipe section titles and the `GHIDRA_INSTALL_DIR`, continue. DECIDED by the owner 2026-11-09 ("warn-and-continue is fine"). The Ghidra install still gets `.install-complete`, because the sentinel certifies that the archive upstream ships was downloaded, verified and extracted whole, and re-downloading it would not add the missing component; what the sentinel does not certify is usability by `rea`, which is the job of `rea-doctor`, and that step runs on EVERY run, so the limitation is reported every time (WARN line, `SUMMARY_rea_doctor=warn`, and a `ghidra: installed, not usable by rea until the native decompiler is built` line in the final summary), never only on the first run.
- Windows ARM64 and Linux ARM64: exit 3 (no `clavity-ls` build, no Ghidra native decompiler).
- `SCRIPT_VERSION` lives in the pins block of both scripts and must equal the release tag.
- Pins block format: between the lines `# --- pins begin ---` and `# --- pins end ---`; sh lines `PIN_<NAME>=<value>`; ps1 lines `$script:PIN_<NAME> = '<value>'`. The `drift` gate compares `<NAME>=<value>` sets.

## C. File structure

```
setup.sh                         POSIX script (one file)
setup.ps1                        Windows PowerShell 5.1 script (one file)
justfile                         recipes (spec §12b); `check` is the gate
lefthook.yml                     pre-push: one `just <recipe>` per gate
header.txt, LICENSE              PolyForm Noncommercial 1.0.0 (copied from aiprofiles)
README.md                        download-verify-run, flag table, uninstall list, honest limits
CONTRIBUTING.md                  how to run the gates; generated `## Tools` table
_typos.toml                      typos config
.claude/recommended-tools.json   declared tools (spec §12b list)
.github/workflows/ci.yml         gates (ubuntu) + matrix test (ubuntu, macos, windows)
.github/workflows/canary.yml     weekly `--check-upstream` on three OSes
.github/workflows/release.yml    tag v* -> release with SHA256SUMS
.github/CODEOWNERS
scripts/lib/scan-guard.sh        copied from aiprofiles (must-find policy)
scripts/check-action-pins.sh     copied from aiprofiles; scripts/tests/check-action-pins.sh too
scripts/check-line-citations.sh  adapted: roots scripts/ tests/ .github/ and the two setup scripts; *.sh *.ps1 *.yml
scripts/gen-tool-table.sh        adapted: writes CONTRIBUTING.md
scripts/check-suppressions.sh    + scripts/suppressions.baseline
scripts/check-drift.sh           pins-block equality, 64-hex SHA, allow-listed hosts
scripts/tools-check.sh           presence of every declared tool, with hints
scripts/psanalyze.ps1            PSScriptAnalyzer with the 5.1 settings; fails on Warning+
scripts/ci-tools.lock            pinned versions of CI-installed tools
tests/sh/lib.sh, run.sh          assertions and runner (per shell)
tests/sh/<area>.sh               unit tests (core, network, archive, tools-bin, jdk, ghidra, profile, rea, launch, upstream)
tests/pester/<Area>.Tests.ps1    the same areas
tests/fixtures/bin/              stub executables: node npx claude agy agent-profile clavity-ls wt
tests/fixtures/                  ghidra-12.1.4-exec.list, sample JSON from O1/O6/O8, sample sidecars
tests/integration/fake_release_server.py   failure-injection server (stdlib only)
tests/integration/run.sh         sh integration (fake server + stubs); run-win.ps1 for the PS layers
```

## D. Shared conventions

- `log LEVEL STEP MSG` (ps1 `Write-ReaLog -Level -Step -Message`): console to stderr when LEVEL >= console level; file always. Colours only when stderr is a terminal and `NO_COLOR` is unset.
- `die CODE STEP MSG` logs ERROR with `details: <log path>` and exits CODE (after `lock_release` if held).
- `run_cmd STEP cmd args…` runs an external command, logs the argument list, exit code and duration, captures stdout to a temp file and stderr to the log (bounded 4,000 chars on failure); returns the exit code.
- Step functions are named `step_<id>` and return 0 after logging `ok`, `skip (already valid)` or `warn`; they call `die` on failure. `main` runs them in spec §8 order and records each outcome in `SUMMARY_<id>` for the final summary.
- Test files: `tests/sh/<area>.sh` begin with `. "$(dirname "$0")/lib.sh"` which sets `ROOT`, exports `REA_SETUP_NO_MAIN=1`, sources `$ROOT/setup.sh` and provides `assert_eq EXPECTED ACTUAL LABEL`, `assert_status CODE LABEL cmd…`, `assert_match REGEX TEXT LABEL`, `assert_file FILE LABEL`, `t_done` (prints `ok N` or `FAIL N` and exits 0/1). Pester files: `BeforeAll { $env:REA_SETUP_NO_MAIN = '1'; . "$PSScriptRoot/../../setup.ps1" }`.

---

### Task 1: Repository scaffolding, licence and quality gates

**Files:**
- Create: `justfile`, `lefthook.yml`, `header.txt`, `LICENSE`, `_typos.toml`, `CONTRIBUTING.md`, `README.md` (replace the 10-byte stub), `.claude/recommended-tools.json`, `.github/CODEOWNERS`, `.github/workflows/ci.yml`, `scripts/lib/scan-guard.sh`, `scripts/check-action-pins.sh`, `scripts/tests/check-action-pins.sh`, `scripts/check-line-citations.sh`, `scripts/gen-tool-table.sh`, `scripts/check-suppressions.sh`, `scripts/suppressions.baseline`, `scripts/tools-check.sh`, `scripts/psanalyze.ps1`, `scripts/ci-tools.lock`, `tests/sh/lib.sh`, `tests/sh/run.sh`, `tests/sh/harness.sh`, `tests/pester/Harness.Tests.ps1`
- Modify: `.gitignore` (append `*.log`, `tests/.tmp/`)

**Interfaces:**
- Produces: the recipes `setup`, `tools-check`, `shellcheck`, `psanalyze`, `typos`, `line-citations`, `tools-doc-check`, `suppressions`, `action-pins`, `actionlint`, `license-check`, `fmt-check`, `fmt`, `test`, `test-integration`, `check` (the `drift` recipe is added in Task 3). `check` = `tools-check typos license-check line-citations action-pins actionlint fmt-check shellcheck psanalyze suppressions tools-doc-check test`.
- Produces: `tests/sh/lib.sh` functions named in section D; `tests/sh/run.sh [SHELL…]` runs every `tests/sh/*.sh` except `lib.sh` and `run.sh` itself (it would otherwise execute itself recursively) under each named shell, or under every one of `dash`, `bash`, `/bin/sh` that exists when none is named; fails on a zero file count or a zero shell count (must-find), prints one `ok <shell> <file>` line per pair.

- [ ] **Step 1: Copy `header.txt`, `LICENSE`, `scripts/lib/scan-guard.sh`, `scripts/check-action-pins.sh`, `scripts/tests/check-action-pins.sh` byte-for-byte from `/home/user/Development/Rust/aiprofiles`** (same owner, same licence). Copy `_typos.toml` and reduce it to the header, `[files] extend-exclude = ["docs/superpowers/"]`, the `[0-9a-fA-F]{32,}` ignore and `[default.extend-words]` with `ckir`, `aiprofiles`, `agy`, `clavity`, `rea`, `Temurin`, `Adoptium`, `Ghidra`, `shfmt`, `psanalyze`.

- [ ] **Step 2: Write `scripts/check-line-citations.sh`** from the aiprofiles original with TWO `find` statements writing to the same list (each its own statement, as the original's comment demands): directories `find "$repo_root/scripts" "$repo_root/tests" "$repo_root/.github" \( -name '*.sh' -o -name '*.ps1' -o -name '*.yml' \) -type f -print > "$files"` and root-level files `find "$repo_root" -maxdepth 1 -type f \( -name '*.sh' -o -name '*.ps1' -o -name justfile -o -name lefthook.yml \) -print >> "$files"`. Never name `setup.sh` or `setup.ps1` as a `find` root: they do not exist until Tasks 2 and 3, and `find` exits 1 on a missing root (measured), which under `set -eu` would fail `just check` at Step 12. `scan_require` on the combined list; the comment pattern gains `ps1` in its extension list. Keep the `line-cite-ok` escape hatch.

- [ ] **Step 3: Write `scripts/gen-tool-table.sh`** from the original with `doc="$repo_root/CONTRIBUTING.md"` and the error text naming `CONTRIBUTING.md`. Write `CONTRIBUTING.md` with: the one-time `just setup`, the gate list, the anti-weakening rules (spec §12b verbatim), and the `<!-- tools:begin … -->` / `<!-- tools:end -->` markers.

- [ ] **Step 4: Write `.claude/recommended-tools.json`** with one entry per declared tool: `just`, `lefthook`, `shellcheck`, `shfmt`, `pwsh`, `PSScriptAnalyzer` (PowerShell module; `file_exists` on `~/.local/share/powershell/Modules/PSScriptAnalyzer` and the Windows `Documents\PowerShell\Modules` path), `Pester` (same shape), `typos`, `actionlint`, `addlicense`, `jq`, `python3` (tests only), `dash` (Linux, tests). Each has `name`, `why`, `install` (Linux, macOS, Windows), `in_path` or `file_exists`, `config`, `just`, `gates`. Run `sh scripts/gen-tool-table.sh` to fill the table.

- [ ] **Step 5: Write `scripts/tools-check.sh`**: reads the JSON with `jq`, checks `in_path`/`file_exists`, prints `missing: <name>  install: <hint>` per gap, exits 1 if any; `scan_require` on the entry list.

- [ ] **Step 6: Write `scripts/check-suppressions.sh` and `scripts/suppressions.baseline`** (`0`): counts `# shellcheck disable=` lines in every `*.sh` found by the same pruned `find` as the `shellcheck` recipe (this covers `setup.sh` once it exists), and `[Diagnostics.CodeAnalysis.SuppressMessageAttribute` plus `# PSScriptAnalyzer` suppression comments in `*.ps1`; every match must carry a `#`-comment reason on the same line (sh: text after a second `#`; ps1: the `Justification` argument or trailing comment); prints the count; exits 1 if any lacks a reason or the count exceeds the baseline. Note the copied aiprofiles scripts carry two `# shellcheck disable=SC2016 # …` lines, so the baseline is `2`.

- [ ] **Step 7: Write `scripts/psanalyze.ps1`**: `Import-Module PSScriptAnalyzer -RequiredVersion 1.25.0`; settings hashtable `@{ Rules = @{ PSUseCompatibleSyntax = @{ Enable = $true; TargetVersions = @('5.1') } }; Severity = @('Error','Warning'); IncludeDefaultRules = $true }`; builds the file list as `Get-ChildItem -Path scripts, tests -Recurse -File -Filter *.ps1` plus `Get-ChildItem -Path $root -File -Filter *.ps1` (root level, non-recursive, so an absent `setup.ps1` is tolerated in Task 1 and analysed from Task 3 on), then runs `Invoke-ScriptAnalyzer -Path <each file> -Settings $settings`; prints findings; `exit 1` if any. Must-find on the file list (zero files → `exit 1`).

- [ ] **Step 8: Write `tests/sh/lib.sh`, `tests/sh/run.sh` and `tests/sh/harness.sh`**. `harness.sh` tests the harness itself: `assert_eq a a` passes, `assert_eq a b` is counted as a failure (run in a subshell and check `t_done` exits 1), `assert_status 3 … sh -c 'exit 3'` passes. `lib.sh` tolerates a missing `setup.sh` only when `TEST_NO_SOURCE=1` (set by `harness.sh`), so later tests fail loudly if the script is absent. Write `tests/pester/Harness.Tests.ps1` with one `It 'runs under Pester 5 or newer'` asserting `(Get-Module Pester).Version.Major -ge 5`; `BeforeAll` skips sourcing when `$env:TEST_NO_SOURCE -eq '1'`.

- [ ] **Step 9: Write `justfile`** (header comment from `header.txt`). Recipes and exact commands:
```
default: (just check)
setup:            lefthook install && just tools-check
tools-check:      sh scripts/tools-check.sh
shellcheck:       find . \( -path ./.clavity -o -path ./tests/.tmp \) -prune -o -name '*.sh' -type f -print0 | xargs -0 shellcheck -s sh
fmt-check:        find . \( -path ./.clavity -o -path ./tests/.tmp \) -prune -o -name '*.sh' -type f -print0 | xargs -0 shfmt -ln posix -i 2 -ci -d
fmt:              same with -w instead of -d
psanalyze:        pwsh -NoProfile -File scripts/psanalyze.ps1
typos:            typos
line-citations:   sh scripts/check-line-citations.sh
tools-doc:        sh scripts/gen-tool-table.sh
tools-doc-check:  sh scripts/gen-tool-table.sh --check
suppressions:     sh scripts/check-suppressions.sh
action-pins:      sh scripts/check-action-pins.sh && sh scripts/tests/check-action-pins.sh
actionlint:       actionlint
license-check:    addlicense -check -f header.txt -ignore '.clavity/**' -ignore 'docs/**' -ignore 'tests/fixtures/**' -ignore 'scripts/suppressions.baseline' -ignore 'scripts/ci-tools.lock' .
test:
    sh tests/sh/run.sh
    pwsh -NoProfile -Command "if (@(Get-ChildItem -Path tests/pester -Filter *.Tests.ps1 -File).Count -eq 0) { exit 1 }; Import-Module Pester -MinimumVersion 5.0; Invoke-Pester -Path tests/pester -CI"
test-integration: sh tests/integration/run.sh
check: tools-check typos license-check line-citations action-pins actionlint fmt-check shellcheck psanalyze suppressions tools-doc-check test
```
`tests/sh/run.sh [SHELL…]` with no argument runs every test file under each of `dash`, `bash` and `/bin/sh` that exists on the machine (`command -v`), so Linux covers dash and bash, macOS bash 3.2 as `/bin/sh` and bash, Windows Git Bash `bash`; it fails when no shell is found. `test` must fail on zero test files: the sh runner's must-find, and for Pester the pwsh command first counts `tests/pester/*.Tests.ps1` with `Get-ChildItem` and exits 1 on zero (not `find`: on a Windows runner `find` can resolve to `System32\find.exe`, the text-search tool, so the guard lives inside `pwsh`) (Pester 5 itself exits 0 when it finds no tests).

- [ ] **Step 10: Write `lefthook.yml`**: header, `pre-push: parallel: true`, one command per recipe in `check` (same list, same order), each `run: just <recipe>`. No pre-commit.

- [ ] **Step 11: Write `scripts/ci-tools.lock`** (`name=version` lines: `just=1.58.0`, `shellcheck=0.10.0`, `shfmt=3.12.0`, `typos=1.51.1`, `actionlint=1.7.12`, `addlicense=1.2.0`, `pester=5.9.0`, `psscriptanalyzer=1.25.0`) and `.github/workflows/ci.yml`: `on: push: branches: [main]; pull_request:`; `permissions: contents: read`; `concurrency: group: ci-${{ github.ref }} cancel-in-progress: true`; job `gates` (`ubuntu-latest`, `timeout-minutes: 20`): `actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1`, `taiki-e/install-action@68a389c788b2cd04016ce8c80ee23b80d2ab3d68 # v2.88.1` with `tool: just@<v>,shellcheck@<v>,shfmt@<v>,typos@<v>` read from the lock, `go install github.com/rhysd/actionlint/cmd/actionlint@v1.7.12`, `go install github.com/google/addlicense@v1.2.0`, `pwsh -c "Install-Module PSScriptAnalyzer -RequiredVersion 1.25.0 -Force; Install-Module Pester -RequiredVersion 5.9.0 -Force"`, then `just check`; job `matrix` (`strategy.matrix.os: [ubuntu-latest, macos-latest, windows-latest]`, `timeout-minutes: 30`): checkout, install `just` the same way, install Pester 5.9.0 where `Get-Module -ListAvailable Pester` has no 5.x, `just test`; on Windows an extra step `powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Import-Module Pester -MinimumVersion 5.0; Invoke-Pester -Path tests/pester -CI"` (Windows PowerShell 5.1; `-ExecutionPolicy Bypass` because the tests dot-source `setup.ps1`, a script file subject to the policy); on Ubuntu `just test-integration` (added in Task 4, keep the step from Task 4 on). Write `.github/CODEOWNERS`: `justfile lefthook.yml .github/ scripts/ @ckir`.

- [ ] **Step 12: Run the gate**

Run: `just check`
Expected: every recipe passes; `tests/sh/run.sh` prints `ok harness.sh` for dash and bash; Pester prints `Tests Passed: 1`.

- [ ] **Step 13: Commit**

```bash
git add -A && git commit -m "chore: scaffolding, licence and quality gates (just, lefthook, CI)"
```

---

### Task 2: `setup.sh` core: pins, logging, arguments, platform, validation

**Files:**
- Create: `setup.sh`, `tests/sh/core.sh`, `tests/fixtures/sample-doctor-agent-profile.json` (the O6 "after create" JSON, home path replaced by `/home/u`)

**Interfaces (sh; ps1 equivalents in Task 3):**
- Pins block (section B) with: `PIN_SCRIPT_VERSION=0.1.0`, `PIN_GHIDRA_VERSION=12.1.4`, `PIN_GHIDRA_TOPDIR=ghidra_12.1.4_PUBLIC`, `PIN_GHIDRA_URL=https://github.com/NationalSecurityAgency/ghidra/releases/download/Ghidra_12.1.4_build/ghidra_12.1.4_PUBLIC_20260921.zip`, `PIN_GHIDRA_SHA256=ddac49f903da9d5bac833e5cc79395098b9c33cfd3279be5f31bd00387d2d4db`, `PIN_GHIDRA_ZIP_BYTES=569649598`, `PIN_GHIDRA_UNPACKED_MB=882`, `PIN_JDK_MAJOR=21`, `PIN_JDK_UNPACKED_MB=346`, `PIN_JDK_FALLBACK_RELEASE=jdk-21.0.13+9`, `PIN_JDK_FALLBACK_LINUX_X64=OpenJDK21U-jdk_x64_linux_hotspot_21.0.13_9.tar.gz:d7f5d5cf865a2902b70ff549b97586a7d3f234e016f041ab447ea740c7d66d1c`, `PIN_JDK_FALLBACK_MAC_X64=OpenJDK21U-jdk_x64_mac_hotspot_21.0.13_9.tar.gz:9aa1d1c17ae5467a022679e7e0af5c00797d94ac462ed1a46f4db07a8a34a6dd`, `PIN_JDK_FALLBACK_MAC_AARCH64=OpenJDK21U-jdk_aarch64_mac_hotspot_21.0.13_9.tar.gz:bf036b35b071bfb2f54f2c0af8ee8d88afa95ee6eb3dce02c0f94cfc2524d04a`, `PIN_JDK_FALLBACK_WINDOWS_X64=OpenJDK21U-jdk_x64_windows_hotspot_21.0.13_9.zip:a4dbaa05fca4bd89d84584e58c459bd732efebb1722af80ab13c6516832004f9`, `PIN_JDK_FALLBACK_URL_BASE=https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.13%2B9/`, `PIN_AGENT_PROFILE_REPO=ckir/aiprofiles`, `PIN_CLAVITY_REPO=ckir/clavity`, `PIN_REA_SPEC=rea-agents@latest`, `PIN_ALLOWED_HOSTS=github.com api.github.com release-assets.githubusercontent.com api.adoptium.net registry.npmjs.org raw.githubusercontent.com`.
- `EX_OK=0 EX_STEP=1 EX_USAGE=2 EX_PLATFORM=3 EX_PREREQ=4 EX_VERIFY=5`.
- `log_format LEVEL STEP MSG [TIMESTAMP]` (stdout, the one line; the timestamp argument exists for tests), `log LEVEL STEP MSG`, `die CODE STEP MSG`, `run_cmd STEP cmd…`, `log_open` (creates the log dir and file, prunes to 20, prints the path), `redact TEXT` (stdout), `abbrev_home PATH` (stdout).
- `parse_args "$@"` sets `OPT_PROFILE` (default `rea`), `OPT_FOLDER` (default `$PWD`), `OPT_GHIDRA_DIR`, `OPT_JAVA_HOME`, `OPT_TOOLS_DIR`, `OPT_BIN_DIR`, `OPT_INSTALL_HOPPER`, `OPT_YES`, `OPT_DRY_RUN`, `OPT_NO_LAUNCH`, `OPT_CHECK_UPSTREAM`, `OPT_CONSOLE_LEVEL`, `OPT_LOG_DIR`; unknown flag or missing value → `die $EX_USAGE`; `--help` prints usage and exits 0.
- `platform_detect` sets `OS` (`linux`|`mac`|`windows`), `ARCH` (`x64`|`aarch64`) and returns 0 only for the four supported pairs `linux x64`, `mac x64`, `mac aarch64`, `windows x64` (the pairs for which `agent-profile`, `clavity-ls` and a Ghidra native decompiler all exist); every other pair, including `linux aarch64` and `windows aarch64`, returns 1 and the caller exits 3 naming the pair. Maps `uname -s` `Linux`/`Darwin`, `uname -m` `x86_64`/`amd64`→`x64`, `arm64`/`aarch64`→`aarch64`.
- `profile_name_valid NAME`: first char `[A-Za-z0-9]`, rest `[A-Za-z0-9._-]`, not (case-insensitive) one of `agents profiles status list create delete current resolve doctor link unlink repositories completions`, not a Windows device name (`CON PRN AUX NUL COM1-9 LPT1-9`, case-insensitive, also with any extension), no trailing dot.
- `semver_from_output TEXT` prints the first `X.Y.Z`; `semver_compare A B` prints `-1`, `0` or `1`; `node_version_ok VERSION` (0 when `v22.x>=22.23.4`, `v24.x>=24.22.1`, `>=26.12.1`).
- `confirm PROMPT`: returns 0 when `OPT_YES`; with no tty and no `OPT_YES` → `die $EX_USAGE`; else reads one line, `y`/`Y` → 0.
- Sourcing guard as the last lines; `main` runs `parse_args`, `log_open`, `platform_detect`, then the steps that exist so far.

- [ ] **Step 1: Write the failing tests `tests/sh/core.sh`**

```sh
assert_eq "2026-01-02T03:04:05Z INFO  [ghidra] hello" "$(LOG_FILE=/dev/null log_format INFO ghidra hello 2026-01-02T03:04:05Z)" "log format"
assert_match '^ERROR \[x\]' "$(CONSOLE_LEVEL=INFO LOG_FILE=/dev/null log ERROR x boom 2>&1 | cut -d' ' -f2-)" "console shows ERROR"
assert_eq "" "$(CONSOLE_LEVEL=WARN LOG_FILE=/dev/null log INFO x hidden 2>&1)" "quiet hides INFO"
assert_eq "GITHUB_TOKEN=<redacted> KEY=<redacted>" "$(redact 'GITHUB_TOKEN=abc KEY=def')" "redact names"
assert_eq "https://h/p" "$(redact 'https://u:p@h/p?x=1')" "redact userinfo and query"
assert_eq "~/x" "$(HOME=/home/u abbrev_home /home/u/x)" "abbrev home"
assert_status 2 "unknown flag" sh -c '. ./setup.sh; parse_args --bogus'
assert_status 0 "profile ok" profile_name_valid rea-1.x
for bad in doctor Doctor CON con.txt -x '' 'a b' 'ok.'; do assert_status 1 "reject $bad" profile_name_valid "$bad"; done
assert_eq 0.17.0 "$(semver_from_output 'clavity-ls 0.17.0+c356375b')" "semver from clavity-ls"
assert_eq 0.1.1 "$(semver_from_output 'agent-profile 0.1.1')" "semver from agent-profile"
assert_eq -1 "$(semver_compare 0.1.1 0.1.2)" "compare lt"; assert_eq 1 "$(semver_compare 0.17.0 0.9.9)" "compare gt"
assert_status 1 "node 24.21.0 too old" node_version_ok v24.21.0
assert_status 0 "node 24.22.2 ok" node_version_ok v24.22.2
assert_status 0 "node 26.12.1 ok" node_version_ok v26.12.1
assert_status 1 "node 23 unsupported" node_version_ok v23.5.0
assert_status 2 "non-interactive without --yes" sh -c '. ./setup.sh; OPT_YES=0; confirm "Proceed?" </dev/null'
assert_eq "linux x64" "$(UNAME_S=Linux UNAME_M=x86_64 platform_detect; echo "$OS $ARCH")" "platform linux"
assert_eq "mac aarch64" "$(UNAME_S=Darwin UNAME_M=arm64 platform_detect; echo "$OS $ARCH")" "platform mac arm"
assert_status 1 "linux arm64 unsupported" sh -c '. ./setup.sh; UNAME_S=Linux UNAME_M=aarch64 platform_detect'
```
(`platform_detect` reads `UNAME_S`/`UNAME_M` when set, else `uname`; `main` runs `unset UNAME_S UNAME_M` as its first statement so a value inherited from the user's environment can never spoof detection; the knob exists only for tests, which call `platform_detect` directly after sourcing. Add `assert_eq "$(uname -s | tr A-Z a-z | sed 's/darwin/mac/')" …` style check: with `UNAME_S=Darwin` exported in the environment, `sh setup.sh --dry-run --yes` on this Linux box still logs `platform: linux`.)

- [ ] **Step 2: Run to verify failure**

Run: `sh tests/sh/run.sh`
Expected: `FAIL core.sh` (setup.sh missing or functions undefined).

- [ ] **Step 3: Implement `setup.sh`** with the header, the pins block, constants, the functions above, usage text (the flag table of spec §7), and `main` calling `parse_args`, `log_open`, `platform_detect || die $EX_PLATFORM preflight "unsupported platform: $(uname -s) $(uname -m)"`. `log_open` writes to `${OPT_LOG_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/rea-setup/logs}`; the first DEBUG lines record `PIN_SCRIPT_VERSION`, `sha256_file "$0"` (sha256 helper comes in Task 4; log `n/a` until then), `uname -a`, `$0 "$@"` after `redact`. Failed log writes print one console warning and set `LOG_FILE=/dev/null`.

- [ ] **Step 4: Run tests and gates**

Run: `sh tests/sh/run.sh && just shellcheck fmt-check`
Expected: `ok dash core.sh` and `ok bash core.sh`; shellcheck and shfmt silent.

- [ ] **Step 5: Commit**

```bash
git add setup.sh tests/sh/core.sh tests/fixtures && git commit -m "feat(sh): core of setup.sh: pins, logging, arguments, platform, validation"
```

---

### Task 3: `setup.ps1` core and the `drift` gate

**Files:**
- Create: `setup.ps1`, `tests/pester/Core.Tests.ps1`, `scripts/check-drift.sh`
- Modify: `justfile` (add `drift` to `check`, after `suppressions`), `lefthook.yml` (add `drift`)

**Interfaces:**
- ps1 names: `Write-ReaLog`, `Stop-Rea -Code -Step -Message` (die), `Invoke-ReaCommand` (run_cmd), `Open-ReaLog`, `Hide-ReaSecret` (redact), `Get-ReaShortPath` (abbrev_home, `%USERPROFILE%`), `Get-ReaPlatform` (returns `@{Os='windows'; Arch='x64'|'aarch64'}` from `[System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture`), `Test-ReaProfileName`, `Get-ReaSemver`, `Compare-ReaSemver`, `Test-ReaNodeVersion`, `Read-ReaConfirm`, `Invoke-Main`.
- `param()` block: `[string]$ProfileName='rea'`, `[string]$Folder=(Get-Location).Path`, `$GhidraDir`, `$JavaHome`, `$ToolsDir`, `$BinDir`, `[switch]$InstallHopper`, `[switch]$Yes`, `[switch]$DryRun`, `[switch]$NoLaunch`, `[switch]$CheckUpstream`, `[switch]$Quiet`, `$LogDir`; `-Verbose` is the CmdletBinding one. `-InstallHopper` → `Stop-Rea 2` ("not available on Windows").
- Log writer uses `[System.IO.File]::AppendAllText($path, $line, (New-Object System.Text.UTF8Encoding $false))`. `[Net.ServicePointManager]::SecurityProtocol` gets `Tls12` added at start.
- `scripts/check-drift.sh`: extracts `PIN_<NAME>=<value>` from `setup.sh` between the markers and `\$script:PIN_<NAME> = '<value>'` from `setup.ps1`, strips one pair of surrounding single or double quotes from each extracted value (`PIN_ALLOWED_HOSTS` holds spaces and is quoted in `setup.sh`), sorts, `diff`; asserts `PIN_GHIDRA_SHA256` is 64 lower-case hex; asserts every `https://<host>/` in any `PIN_*` value is in `PIN_ALLOWED_HOSTS`; must-find on both pin lists.

- [ ] **Step 1: Write the failing tests** `tests/pester/Core.Tests.ps1`, mirroring Task 2 Step 1 assertions (`Should -Be`), plus `It 'rejects -InstallHopper on Windows'` and `It 'writes UTF-8 without BOM'` (write one line through `Write-ReaLog` to a temp file; first three bytes are not `EF BB BF`).

- [ ] **Step 2: Run to verify failure**

Run: `pwsh -NoProfile -Command "Import-Module Pester -MinimumVersion 5.0; Invoke-Pester -Path tests/pester -CI"`
Expected: failures in `Core.Tests.ps1` (file not found).

- [ ] **Step 3: Implement `setup.ps1`** (header, `[CmdletBinding()] param(...)`, `$ErrorActionPreference = 'Stop'` (the POSIX `set -eu` counterpart; non-terminating cmdlet errors must not cascade), pins block, functions, guard `if ($env:REA_SETUP_NO_MAIN -ne '1') { exit (Invoke-Main) }`). Write `scripts/check-drift.sh` and add the `drift` recipe (`sh scripts/check-drift.sh`) to `check` and to `lefthook.yml`.

- [ ] **Step 4: Run tests and gates**

Run: `just test && just psanalyze drift`
Expected: Pester `Tests Passed: N, Failed: 0`; psanalyze prints no findings; drift prints `drift: 23 pins identical`.

- [ ] **Step 5: Commit**

```bash
git add setup.ps1 tests/pester/Core.Tests.ps1 scripts/check-drift.sh justfile lefthook.yml && git commit -m "feat(ps1): core of setup.ps1 and the pins drift gate"
```

---

### Task 4: Network layer, `setup.sh`

**Files:**
- Create: `tests/sh/network.sh`, `tests/integration/fake_release_server.py`, `tests/integration/run.sh`, `tests/fixtures/sidecar-aiprofiles.sha256`, `tests/fixtures/sidecar-clavity.sha256`, `tests/fixtures/sidecar-temurin.sha256.txt`, `tests/fixtures/adoptium-linux-x64.json` (the measured API response), `tests/fixtures/github-release-clavity.json` (the measured API response, trimmed to `tag_name` and four `assets`)
- Modify: `setup.sh`, `justfile` (`test-integration`), `.github/workflows/ci.yml` (run `just test-integration` on Ubuntu in `matrix`)

**Interfaces:**
- Shell variables (reassignable after sourcing, not environment): `ALLOWED_SCHEMES=https`, `ALLOWED_HOSTS=$PIN_ALLOWED_HOSTS`, `RETRY_WAITS="2 4 8 16"`, `CURL="curl"`.
- `url_host URL` (stdout), `url_allowed URL` (0/1: scheme in `ALLOWED_SCHEMES`, host in `ALLOWED_HOSTS`, no userinfo).
- `resolve_redirects URL` prints the final URL after at most 5 hops using `curl -sS -I -o /dev/null -w '%{http_code} %{redirect_url}'` (HEAD, no `-L`, so a 570 MB body is never fetched just to find its URL); a hop answering 405 or 403 to HEAD is retried with `-r 0-0` instead of `-I`; each hop must pass `url_allowed`; returns 1 on a disallowed hop, 2 on more than 5 hops, 3 on a non-2xx/3xx.
- `http_get URL DEST [EXTRA_CURL_ARGS…]`: the retry loop (status via `-w '%{http_code}'`, headers to a temp file for `Retry-After`, `--speed-limit 1024 --speed-time 60`, `--tlsv1.2`, `--proto =https` unless `ALLOWED_SCHEMES` contains `http`); 2xx → 0; 5xx/429/curl exit 6,7,28,35,52,56 → retry; other 4xx → 1 at once; `GITHUB_TOKEN` added as `Authorization: Bearer` only when `url_host` is `api.github.com`.
- `download_verified URL DEST SHA256`: `resolve_redirects`, `http_get` into `DEST.tmp.$$`, `sha256_file`, compare (case-insensitive), mismatch → remove file, return 1; ok → `mv` to `DEST`.
- `sha256_file FILE` (`sha256sum` or `shasum -a 256`), `sidecar_sha256 FILE` (first 64-hex token).
- `github_latest_tag REPO` (Location of `https://github.com/REPO/releases/latest`, last path segment), `github_release_assets REPO` (API JSON via `http_get`, names via `json_query`), `github_release_assets_scrape REPO TAG` (regex over `https://github.com/REPO/releases/expanded_assets/TAG`).
- `json_query FILE JS` runs `node -e '<fixed program>' -- FILE JS` where the fixed program reads `process.argv[2]` as the file, builds `new Function("d", "return (" + process.argv[3] + ")")`, applies it to the parsed JSON and writes the result (arrays joined by newline, `null`/`undefined` as empty). The JS text is always a literal from the script, never data, and is passed as an argument so quoting cannot break it.
- `jdk_release_valid TAG` (0 when `TAG` matches `^jdk-21(\.[0-9]+)*\+[0-9]+$`); `adoptium_parse FILE` (the file-reading half of the next function, testable offline); `adoptium_resolve OS ARCH` sets `JDK_RELEASE`, `JDK_URL`, `JDK_SHA256`, `JDK_SIDECAR_URL`, `JDK_BYTES` from `https://api.adoptium.net/v3/assets/latest/21/hotspot?architecture=ARCH&image_type=jdk&os=OS&vendor=eclipse` (`.[0].release_name`, `.binary.package.{link,checksum,checksum_link,size}`); validates `JDK_RELEASE` with `^jdk-21(\.[0-9]+)*\+[0-9]+$` and `JDK_URL` host `github.com` path prefix `/adoptium/temurin21-binaries/`; returns 2 when the API is unreachable (caller uses the fallback pin), 1 on a validation failure.
- Fake server `fake_release_server.py PORT SCENARIO.json`: stdlib `http.server`; the scenario maps a path to a list of responses consumed in order, each `{"status":504}` or `{"status":429,"headers":{"Retry-After":"1"}}` or `{"status":200,"body_file":"…","truncate":N}` or `{"status":302,"location":"…"}`; a `/__count/<path>` endpoint returns how many requests hit a path. Started by `tests/integration/run.sh`, which sets `ALLOWED_SCHEMES="https http"`, `ALLOWED_HOSTS="127.0.0.1"`, `RETRY_WAITS="0 0 0 0"` after sourcing.

- [ ] **Step 1: Write the failing unit tests `tests/sh/network.sh`**

```sh
assert_status 0 "allowed" url_allowed https://github.com/x
assert_status 1 "http refused" url_allowed http://github.com/x
assert_status 1 "host refused" url_allowed https://evil.example/x
assert_status 1 "userinfo refused" url_allowed https://u@github.com/x
assert_eq f8114d71dc4d54a342ed13bc2fbe4b87f755af1de1c4e7ffaa47262a2eb1ac3d "$(sidecar_sha256 "$FIX/sidecar-aiprofiles.sha256")" "sidecar two-space"
assert_eq c9de4fe583d8c301b90196f3ecb25568f09b7c7ad832ba917fd951df7b15da1c "$(sidecar_sha256 "$FIX/sidecar-clavity.sha256")" "sidecar asterisk"
printf abc > "$TMP/abc"; assert_eq ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad "$(sha256_file "$TMP/abc")" "sha256"
assert_eq "clavity-v31" "$(json_query "$FIX/github-release-clavity.json" 'd.tag_name')" "json scalar"
assert_eq "clavity-ls-win-x64-0.17.0.tar.gz" "$(json_query "$FIX/github-release-clavity.json" 'd.assets.map(a=>a.name).filter(n=>/^clavity-ls-win-x64-[0-9]+\.[0-9]+\.[0-9]+\.tar\.gz$/.test(n))')" "asset match"
assert_eq "jdk-21.0.13+9 207858352" "$(adoptium_parse "$FIX/adoptium-linux-x64.json"; echo "$JDK_RELEASE $JDK_BYTES")" "adoptium parse"
assert_status 1 "bad tag" jdk_release_valid jdk-22.0.1+7
assert_status 0 "good tag" jdk_release_valid jdk-21.0.13+9
```
(`adoptium_parse FILE` is the file-reading half of `adoptium_resolve`, so it is testable offline.)

- [ ] **Step 2: Write the failing integration test `tests/integration/run.sh`** with scenarios: (a) `504,504,200` → download succeeds and `/__count` is 3; (b) `504 ×4` → `http_get` returns 1 after 4 attempts; (c) `429 Retry-After: 1` then `200` → succeeds, elapsed >= 1 s; (d) truncated body → `download_verified` returns 1 and no `DEST` exists, `DEST.tmp.*` removed; (e) a 302 to `https://evil.example/` → `resolve_redirects` returns 1; (f) six chained 302 hops → returns 2; (g) a 404 → 1 with exactly one request.

- [ ] **Step 3: Run to verify failure**

Run: `sh tests/sh/run.sh dash; sh tests/integration/run.sh`
Expected: `FAIL network.sh`; integration aborts on undefined functions.

- [ ] **Step 4: Implement the functions in `setup.sh`** and the fake server. Add `test-integration` to the justfile (`sh tests/integration/run.sh`; runs `python3 -I`), and the Ubuntu-only step in `ci.yml`.

- [ ] **Step 5: Run tests and gates**

Run: `just test test-integration shellcheck fmt-check`
Expected: `ok network.sh` under dash and bash; integration prints `ok` for scenarios a–g.

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "feat(sh): network layer with redirect allow-list, retries and checksum verification"
```

---

### Task 5: Network layer, `setup.ps1`

**Files:**
- Create: `tests/pester/Network.Tests.ps1`, `tests/integration/run-win.ps1`
- Modify: `setup.ps1`

**Interfaces:** `Test-ReaUrlAllowed`, `Resolve-ReaRedirects` (`[System.Net.HttpWebRequest]` with `AllowAutoRedirect = $false`, `Method = 'HEAD'` then `GET` fallback when HEAD is 405), `Invoke-ReaHttpGet -Url -Destination` (stream copy with a 64 KiB buffer, `ReadWriteTimeout = 60000`, stall detection: fewer than 1,024 bytes in any 60 s window aborts; `$ProgressPreference = 'SilentlyContinue'`), `Get-ReaDownload -Url -Destination -Sha256` (download_verified), `Get-ReaFileSha256` (`Get-FileHash -Algorithm SHA256`), `Get-ReaSidecarSha256`, `Get-ReaGitHubLatestTag`, `Get-ReaGitHubReleaseAssets` (`ConvertFrom-Json`), `Get-ReaGitHubReleaseAssetsScrape`, `Resolve-ReaAdoptium -Os -Arch` (and `ConvertFrom-ReaAdoptium -Path` for offline tests). Script-scope overrides `$script:AllowedSchemes`, `$script:AllowedHosts`, `$script:RetryWaits`.

- [ ] **Step 1: Write the failing tests** `Network.Tests.ps1` mirroring Task 4 Step 1, and `run-win.ps1` mirroring scenarios a–g (it starts the same Python fake server; `pwsh` on Linux CI runs it too, so the scenarios are exercised on every OS; `python3` is on all three runner images).

- [ ] **Step 2: Run to verify failure**

Run: `pwsh -NoProfile -Command "Import-Module Pester -MinimumVersion 5.0; Invoke-Pester -Path tests/pester -CI"`
Expected: `Network.Tests.ps1` fails.

- [ ] **Step 3: Implement** the functions in `setup.ps1`. Add `pwsh -NoProfile -File tests/integration/run-win.ps1` to the `test-integration` recipe.

- [ ] **Step 4: Run tests and gates**

Run: `just test test-integration psanalyze drift`
Expected: all pass; psanalyze reports no PowerShell 7 syntax.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(ps1): network layer with redirect allow-list, retries and checksum verification"
```

---

### Task 6: Files, locks, archives and staging, `setup.sh`

**Files:**
- Create: `tests/sh/archive.sh`, `tests/fixtures/ghidra-12.1.4-exec.list` (the 134 measured paths, one per line, without the top directory), `tests/integration/make_archives.py` (builds tar and zip fixtures: clean, `../` entry, absolute entry, symlink to `/etc/passwd`, a zip with an execute-bit entry)
- Modify: `setup.sh`

**Interfaces:**
- `tools_dir_default` prints `${OPT_TOOLS_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/rea-tools}`; `bin_dir_default` prints `${OPT_BIN_DIR:-$HOME/.local/bin}`; `state_dir` as in Task 2.
- `lock_acquire DIR` (`mkdir "$DIR/.lock"`; writes `$DIR/.lock/owner` with `pid=$$ started=<UTC>`; on failure reads the owner pid, `kill -0` → alive: wait 2 s, up to `LOCK_POLLS` polls (default 60), then `die $EX_STEP tools-bin "lock held by pid N: $DIR/.lock"`; dead → WARN `stale lock from pid N taken over`, `rm -rf` and retry); `lock_release DIR`; `LOCK_HELD` variable; `trap 'cleanup' EXIT INT TERM` runs `lock_release` and removes `STAGING_DIRS` (space-separated list the install functions append to).
- `cleanup_orphans DIR` removes `DIR/*.tmp.<pid>` and `DIR/*.old.<pid>` whose pid is dead or whose mtime is older than 24 h; logs each.
- `disk_free_mb PATH` (`df -Pm`), `require_free_mb PATH MB` (die `$EX_STEP` with the shortfall).
- `archive_list FILE` prints entry lines `MODE TYPE PATH [-> TARGET]` normalised across `tar -tvf` (GNU and bsdtar: parse stdout only), `unzip -Z1`/`zipinfo`, `bsdtar -tvf` for zip, and `jar tf` (names only, type unknown); `archive_check_safe FILE` returns 1 and names the first offending entry when any path is absolute, contains a `..` component, or is a symlink/hardlink whose target resolves outside the archive root; `archive_extract FILE DEST` (tar: `tar -xzf FILE -C DEST --no-same-owner`, bsdtar accepts the same; zip: `unzip -q FILE -d DEST`, else `bsdtar -xf FILE -C DEST`, else `"$JAVA_HOME_SELECTED/bin/jar" xf` (ps1 never uses `jar`; `JAVA_HOME_SELECTED` because the plain `JAVA_HOME` environment variable may be unset) run from inside `DEST` followed by `ghidra_set_exec_bits DEST/<top>`); `archive_tool_for ZIP` prints `unzip`, `bsdtar` or `jar`.
- `ghidra_set_exec_bits ROOT`: `chmod +x` on `ROOT/ghidraRun`, every regular file directly under `ROOT/support` and `ROOT/server` except `*.bat *.properties *.txt *.html *.cmd`, every `*.sh` under ROOT, every file under any `os/linux_x86_64/` directory, every file under `Ghidra/Debug/*/data/debugger-launchers/`, `Ghidra/Debug/Debugger-isf/support/runISFServer`, `support/gradle/gradlew`, `support/GhidraGo/ghidraGo`.
- `staging_new DIR NAME` prints `DIR/NAME.tmp.$$` (created; appended to `STAGING_DIRS`); `install_commit STAGING FINAL`: writes `STAGING/.install-complete` (UTC timestamp and `PIN_SCRIPT_VERSION`), moves an existing `FINAL` to `FINAL.old.$$`, `mv STAGING FINAL`, `rm -rf FINAL.old.$$` (failure → WARN).
- `install_valid DIR FILE…` 0 when `DIR/.install-complete` and every listed file exist.
- `prune_jdks TOOLS` keeps the newest two `jdk-*` directories by `semver_compare` on the release string (`jdk-21.0.13+9` → compare `21.0.13` then build `9`), never the one in `JAVA_HOME`.

- [ ] **Step 1: Write the failing tests `tests/sh/archive.sh`** (fixtures built into `tests/.tmp/` by `tests/integration/make_archives.py`, which THIS step creates first (Python `tarfile`/`zipfile`; the symlink fixture uses `tarfile.TarInfo` with `type = SYMTYPE`) and which `archive.sh` runs in its setup as `python3 "$ROOT/tests/integration/make_archives.py" "$T"`):

```sh
assert_status 0 "clean tar safe" archive_check_safe "$T/clean.tar.gz"
assert_status 1 "dotdot tar refused" archive_check_safe "$T/dotdot.tar.gz"
assert_status 1 "absolute tar refused" archive_check_safe "$T/abs.tar.gz"
assert_status 1 "symlink out refused" archive_check_safe "$T/symlink.tar.gz"
assert_status 1 "dotdot zip refused" archive_check_safe "$T/dotdot.zip"
assert_status 0 "clean zip safe" archive_check_safe "$T/clean.zip"
assert_status 0 "lock fresh" lock_acquire "$T/tools"; assert_file "$T/tools/.lock/owner" "owner file"; lock_release "$T/tools"
mkdir -p "$T/tools/.lock"; printf 'pid=999999 started=x\n' > "$T/tools/.lock/owner"
assert_status 0 "stale lock taken over" lock_acquire "$T/tools"; lock_release "$T/tools"
mkdir -p "$T/tools/.lock"; printf 'pid=%s started=x\n' "$$" > "$T/tools/.lock/owner"
assert_status 1 "live lock refused" sh -c '. ./setup.sh; LOCK_POLLS=1; lock_acquire "$1"' _ "$T/tools"
mkdir -p "$T/tools/x.tmp.999999" "$T/tools/y.tmp.$$"; cleanup_orphans "$T/tools"
assert_status 1 "dead-pid staging removed" test -d "$T/tools/x.tmp.999999"; assert_status 0 "live staging kept" test -d "$T/tools/y.tmp.$$"
s=$(staging_new "$T/tools" ghidra_12.1.4_PUBLIC); mkdir -p "$T/tools/ghidra_12.1.4_PUBLIC"; touch "$s/marker"
install_commit "$s" "$T/tools/ghidra_12.1.4_PUBLIC"; assert_file "$T/tools/ghidra_12.1.4_PUBLIC/.install-complete" "sentinel"; assert_file "$T/tools/ghidra_12.1.4_PUBLIC/marker" "replaced incomplete dir"
assert_status 1 "no sentinel invalid" install_valid "$T/tools/nosentinel" x
mkdir -p "$T/g/support" "$T/g/Ghidra/Features/Decompiler/os/linux_x86_64"; touch "$T/g/ghidraRun" "$T/g/support/analyzeHeadless" "$T/g/support/launch.properties" "$T/g/Ghidra/Features/Decompiler/os/linux_x86_64/decompile"
ghidra_set_exec_bits "$T/g"; assert_status 0 "exec analyzeHeadless" test -x "$T/g/support/analyzeHeadless"; assert_status 0 "exec decompile" test -x "$T/g/Ghidra/Features/Decompiler/os/linux_x86_64/decompile"; assert_status 1 "properties not exec" test -x "$T/g/support/launch.properties"
# rule coverage against the measured list: every line matching the required categories is covered
required=$(grep -E '^(ghidraRun|support/[^/]+|server/[^/]+|.*\.sh|.*/os/linux_x86_64/.*|Ghidra/Debug/[^/]+/data/debugger-launchers/.*)$' "$FIX/ghidra-12.1.4-exec.list" | grep -v -E '\.(bat|properties|txt|html|cmd)$')
# recreate the required paths as empty files under $T/rule, apply the rule, assert every one is executable
mkdir -p "$T/tools dir with space"; assert_status 0 "lock in path with space" lock_acquire "$T/tools dir with space"; lock_release "$T/tools dir with space"
```
Plus a trap test: `sh -c '. ./setup.sh; lock_acquire "$1"; s=$(staging_new "$1" z); kill -INT $$' _ "$T/tools"` then assert `.lock` and `z.tmp.*` are gone.

- [ ] **Step 2: Run to verify failure**

Run: `sh tests/sh/run.sh dash`
Expected: `FAIL archive.sh`.

- [ ] **Step 3: Implement** the functions in `setup.sh` (the fixture builder already exists from Step 1).

- [ ] **Step 4: Run tests and gates**

Run: `just test shellcheck fmt-check`
Expected: `ok archive.sh` under dash and bash.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(sh): locks, staging, archive safety and extraction"
```

---

### Task 7: Files, locks, archives and staging, `setup.ps1`

**Files:**
- Create: `tests/pester/Archive.Tests.ps1`
- Modify: `setup.ps1`

**Interfaces:** `Get-ReaToolsDir` (`$ToolsDir` or `$env:LOCALAPPDATA\rea-tools`), `Get-ReaBinDir` (`$env:LOCALAPPDATA\rea-tools\bin`), `Test-ReaFixedNtfs -Path` (`[System.IO.DriveInfo]` `DriveType -eq 'Fixed'` and `DriveFormat -eq 'NTFS'`; failure → `Stop-Rea 1`), `Lock-ReaDir`/`Unlock-ReaDir` (`New-Item -ItemType Directory` is atomic; liveness via `Get-Process -Id -ErrorAction SilentlyContinue`), `Remove-ReaOrphans`, `Get-ReaFreeMb`, `Get-ReaArchiveEntries -Path` (tar.gz via `tar.exe -tvzf`; zip via `[System.IO.Compression.ZipFile]::OpenRead` entries, `FullName`, external attributes), `Test-ReaArchiveSafe` (refuses `FullName` starting with `/` or `\`, containing a drive letter `X:`, or a `..` segment; tar symlink lines `->`), `Expand-ReaArchive -Path -Destination` (zip: iterate entries; an entry whose `FullName` ends in `/` or `\` is a directory: `New-Item -ItemType Directory -Force` it and continue, never `ExtractToFile`; for a file entry create the parent directory first, then `ExtractToFile` with `$false` overwrite after re-checking each target path starts with the destination; tar.gz: `tar.exe -xzf -C`), `New-ReaStaging`, `Complete-ReaInstall` (sentinel, swap, delete old; failure WARN), `Test-ReaInstallValid`, `Remove-ReaOldJdks`. Zip extraction from PowerShell 5.1 requires `Add-Type -AssemblyName System.IO.Compression.FileSystem`.

- [ ] **Step 1: Write the failing tests** `Archive.Tests.ps1` mirroring Task 6 (fixtures from `make_archives.py`, plus a zip entry named `C:\evil.txt` and one named `..\evil.txt` built with `zipfile` on any OS); stale/live lock using `$PID` and `999999`; `Complete-ReaInstall` replacing an incomplete directory; a path with a space.

- [ ] **Step 2: Run to verify failure**

Run: Pester as before. Expected: `Archive.Tests.ps1` fails.

- [ ] **Step 3: Implement** in `setup.ps1`.

- [ ] **Step 4: Run tests and gates**

Run: `just test psanalyze drift`
Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(ps1): locks, staging, archive safety and extraction"
```

---

### Task 8: Steps `preflight` and `prereq` (both scripts)

**Files:**
- Create: `tests/sh/prereq.sh`, `tests/pester/Prereq.Tests.ps1`, `tests/fixtures/bin/{node,npx,claude,agy,agent-profile,clavity-ls,wt}` (sh stubs that answer `--version`/`-V` with configurable text from `STUB_<NAME>_VERSION`, exit `STUB_<NAME>_EXIT`), `tests/fixtures/bin-win/` (`.cmd` stubs for `node`, `npx`, `agy`, `agent-profile`, `clavity-ls`, `wt`; `claude.exe` is a zero-byte file named for the extension check only)
- Modify: `setup.sh`, `setup.ps1`

**Interfaces:**
- `step_preflight`: `platform_detect` (exit 3), `profile_name_valid "$OPT_PROFILE"` (exit 2), `command -v curl tar` (exit 4 with hints), `archive_tool_for` records `ZIP_TOOL` (`unzip`|`bsdtar`|`jar`; `jar` only allowed because step `jdk` precedes `ghidra`), Windows: `tar.exe` and `Test-ReaFixedNtfs` on the tools dir, writes `TOOLS_DIR BIN_DIR`, `cleanup_orphans` on both.
- `step_prereq`: `node` (`node_version_ok` else exit 4: `install Node 24: fnm install 24 (https://github.com/Schniz/fnm) or https://nodejs.org`), `npx`, `claude` (Windows: resolved path must end in `.exe`; a `.cmd` → exit 4 `agent-profile refuses npm .cmd shims; install Claude Code's native installer`), `agy`, Windows `wt` and `powershell`/`pwsh`, Linux `ps` from procps (`ps -o pid= -p $$` works), credential-override WARN for the eight variable names in spec §8 (names only). `--check-upstream` skips `claude`, `agy`, `wt`.
- `main` now runs `step_preflight` and `step_prereq`.

- [ ] **Step 1: Write the failing tests** `tests/sh/prereq.sh` and `Prereq.Tests.ps1`: `step_prereq` with `PATH=tests/fixtures/bin:$PATH` and `STUB_node_VERSION=v24.21.0` → exit 4 with the fnm hint in the log; with `v24.22.2` → ok; with the `agy` stub removed → exit 4 naming `agy`; `--check-upstream` mode with `claude` removed from the stub dir → ok; `step_preflight` with `UNAME_S=Linux UNAME_M=aarch64` → exit 3; `--profile doctor` → exit 2; `ZIP_TOOL` resolves to `unzip` when present, `jar` when `unzip` and `bsdtar` are hidden from `PATH`. Pester: the `.exe` check with `bin-win/claude.exe` and a `claude.cmd` sibling (reject when `.cmd` resolves first); `windows aarch64` → exit 3 (`Get-ReaPlatform` reports the pair unsupported, message `unsupported platform: windows aarch64 (no agent-profile, clavity-ls or Ghidra native build)`).

- [ ] **Step 2: Run to verify failure.** Expected: `FAIL prereq.sh`, Pester `Prereq` fails.

- [ ] **Step 3: Implement** in both scripts.

- [ ] **Step 4: Run tests and gates.** Run: `just check`. Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: preflight and prerequisite steps with stubbed prerequisites in tests"
```

---

### Task 8b: Step `tools-bin` (both scripts)

**Files:**
- Create: `tests/sh/tools-bin.sh`, `tests/pester/ToolsBin.Tests.ps1`
- Modify: `setup.sh`, `setup.ps1`

**Interfaces:**
- `resolve_agent_profile OS ARCH` sets `AP_TAG`, `AP_VERSION`, `AP_ASSET`, `AP_URL` (`https://github.com/ckir/aiprofiles/releases/latest/download/<asset>`), `AP_SIDECAR_URL`; asset by map: `linux x64 → agent-profile-x86_64-unknown-linux-gnu.tar.gz`, `mac x64 → agent-profile-x86_64-apple-darwin.tar.gz`, `mac aarch64 → agent-profile-aarch64-apple-darwin.tar.gz`, `windows x64 → agent-profile-x86_64-pc-windows-msvc.zip`.
- `resolve_clavity_ls OS ARCH` sets `CL_TAG`, `CL_VERSION`, `CL_ASSET`, `CL_URL`, `CL_SIDECAR_URL`; rid map `linux x64 → linux-x64`, `mac aarch64 → osx-arm64`, `mac x64 → osx-x64`, `windows x64 → win-x64`; asset regex `^clavity-ls-<rid>-([0-9]+\.[0-9]+\.[0-9]+)\.tar\.gz$` over `github_release_assets`, falling back to `github_release_assets_scrape`; zero or two or more matches → `die $EX_VERIFY`.
- `install_single_binary NAME URL SIDECAR_URL EXPECTED_FILE DEST_PATH`: `download_verified` with the sidecar's hash, `archive_check_safe`, extract into a bin-dir staging, require exactly the one expected entry, `chmod +x`, `mv` over `DEST_PATH` (Windows: on a failed move with "in use", WARN `close running sessions to update <name>` and keep the installed one; remove the staged file).
- `installed_version NAME` (ps1: `Get-ReaInstalledVersion -Name`): prints `semver_from_output "$("$BIN_DIR/NAME" --version 2>/dev/null)"` for the copy in `BIN_DIR` (Windows: `BIN_DIR\NAME.exe`); prints the empty string, with status 0, when that file is absent or not executable, when `--version` exits non-zero, or when its output has no `X.Y.Z` (so `semver_compare` is never handed an empty argument).
- `step_tools_bin`: lock, for each of `agent-profile` then `clavity-ls`: `installed=$(installed_version <name>)`; empty → `install` (DEBUG `no <name> in BIN_DIR`); otherwise `semver_compare installed latest`; `-1` → `update`, else `skip (already latest)`; never downgrade. The check reads `BIN_DIR`, not whatever `PATH` resolves first; when `command -v <name>` resolves elsewhere, WARN `another <name> at <path> precedes the one this script manages`; prepend `BIN_DIR` to `PATH`; `SUMMARY_tools_bin` lines; lock stays held until after step `ghidra` (released in `main` after step 5).

- [ ] **Step 1: Write the failing tests**: asset maps for the four supported platforms (`resolve_agent_profile`/`resolve_clavity_ls` print the measured asset names from section A) and return 1 for `linux aarch64` and `windows aarch64`; the clavity regex against `github-release-clavity.json` (exactly one match for `win-x64`, zero for `linux-arm64` → verify failure); `install_single_binary` against a fixture tar with one file and against one with two files (refused); `installed_version` with an empty `BIN_DIR` prints nothing and exits 0, with a stub that exits 1 prints nothing, with a stub printing `clavity-ls 0.17.0+abc` prints `0.17.0`; `step_tools_bin` with an empty `BIN_DIR` → `install` (stub download served by the fixture tar); with the `clavity-ls` stub in `BIN_DIR` answering `0.17.0+abc` and a fixture release JSON naming `0.17.0` → `skip (already latest)`, naming `0.18.0` → `update`; with an older stub earlier on `PATH` → the WARN about shadowing is logged and the `BIN_DIR` version is the one compared.

- [ ] **Step 2: Run to verify failure.** Expected: `FAIL tools-bin.sh`, Pester `ToolsBin` fails.

- [ ] **Step 3: Implement** in both scripts; `main` now runs `step_tools_bin` after `step_prereq`.

- [ ] **Step 4: Run tests and gates.** Run: `just check`. Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: tools-bin step (agent-profile, clavity-ls latest, verified install)"
```

---

### Task 9: Step `jdk` (both scripts)

**Files:**
- Create: `tests/sh/jdk.sh`, `tests/pester/Jdk.Tests.ps1`, `tests/fixtures/fake-jdk/` (a `bin/java` stub printing a configurable `-version` to stderr, `bin/javac`)
- Modify: `setup.sh`, `setup.ps1`

**Interfaces:**
- `jdk_valid DIR` returns 0 when `DIR/bin/java` and `DIR/bin/javac` exist (Windows `.exe`), `java -version` reports major >= `PIN_JDK_MAJOR` (parse `version "X` or `openjdk version "X`), the banner contains `64-Bit`, and the architecture matches the host (`java -XshowSettings:properties -version 2>&1 | grep os.arch` → `amd64`/`x86_64` for x64, `aarch64` for aarch64); prints the reason on failure.
- `jdk_home_candidate DIR` prints `DIR/Contents/Home` on macOS when that exists, else `DIR`.
- `jdk_select`: precedence from spec §8: `OPT_JAVA_HOME` invalid → `die $EX_STEP`; `JAVA_HOME` env invalid → WARN; newest valid `TOOLS_DIR/jdk-*` with `.install-complete`; else `jdk_install`. Sets `JAVA_HOME_SELECTED` and `SUMMARY_jdk`.
- `jdk_install`: `require_free_mb TOOLS_DIR 600`; `adoptium_resolve OS ARCH`; on return 2 use the fallback pin for `OS_ARCH` (`PIN_JDK_FALLBACK_*`, URL `PIN_JDK_FALLBACK_URL_BASE<name>`) with WARN `Adoptium API unreachable; installing the embedded fallback jdk-21.0.13+9, possibly outdated`; `download_verified` against the API checksum; fetch the sidecar: unreachable → WARN, mismatch → `die $EX_VERIFY`; `archive_check_safe`; extract into staging; the top directory must be exactly one entry (`jdk-<release>`, on macOS with `Contents/Home` inside); `jdk_valid` on the staged home; `install_commit`; `prune_jdks`. The downloaded archive is removed with `rm -f` right after a successful extract and also on failure (the step's cleanup), so the 208 MB file never lingers in `TOOLS_DIR`; the download destination is a `.download.$$` file inside the step's staging directory. `--dry-run` logs the resolved release, URL and size and stops.

- [ ] **Step 1: Write the failing tests**: `jdk_valid` on the fake JDK with banners `openjdk version "21.0.13" … 64-Bit`, `"17.0.2"` (reject, reason `major 17 < 21`), `"21" … 32-Bit` (reject), JRE (no `javac`, reject); `jdk_home_candidate` with and without `Contents/Home` (`OS=mac`); `jdk_select` precedence: `OPT_JAVA_HOME` pointing at the JRE → exit 1; `JAVA_HOME` env at the JRE and a valid tools-dir JDK → WARN and the tools-dir one selected; fallback selection returns the right `PIN_JDK_FALLBACK_*` for each of the four platforms. Review Focus 3 is covered by the JRE and JDK 17 cases.

- [ ] **Step 2: Run to verify failure.** Expected: `FAIL jdk.sh`, Pester `Jdk` fails.

- [ ] **Step 3: Implement** in both scripts; `main` runs `step_jdk`.

- [ ] **Step 4: Run tests and gates.** Run: `just check`. Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: jdk step (reuse, Adoptium latest 21, embedded fallback)"
```

---

### Task 10: Step `ghidra` (both scripts)

**Files:**
- Create: `tests/sh/ghidra.sh`, `tests/pester/Ghidra.Tests.ps1`, `tests/fixtures/fake-ghidra/Ghidra/application.properties` (`application.version=12.1.4`) and a `12.2.0` variant
- Modify: `setup.sh`, `setup.ps1`

**Interfaces:**
- `ghidra_version DIR` prints `application.version` from `DIR/Ghidra/application.properties` (empty when absent); `ghidra_valid DIR` 0 when the version matches `^12\.1(\.[0-9]+)?$`.
- `ghidra_select`: `OPT_GHIDRA_DIR` invalid → `die $EX_STEP`; `GHIDRA_INSTALL_DIR` env invalid → WARN (a 12.2 install: WARN `12.2 is not accepted by rea 6.8.0; installing 12.1.4 alongside`); `TOOLS_DIR/PIN_GHIDRA_TOPDIR` valid with sentinel; else `ghidra_install`. Sets `GHIDRA_DIR_SELECTED`, `SUMMARY_ghidra`.
- `ghidra_install`: `require_free_mb TOOLS_DIR 1500`; `download_verified PIN_GHIDRA_URL … PIN_GHIDRA_SHA256`; size must equal `PIN_GHIDRA_ZIP_BYTES`; `archive_check_safe`; extract with `ZIP_TOOL` into staging; require the single top directory `PIN_GHIDRA_TOPDIR` and `ghidra_version` = `PIN_GHIDRA_VERSION`; `ghidra_set_exec_bits` when `ZIP_TOOL` is `jar` (POSIX); `install_commit`. The 570 MB zip is downloaded into the staging directory and removed right after extraction (and on failure), never left in `TOOLS_DIR`; the ps1 steps do the same with `Remove-Item`. On macOS log WARN `the official 12.1.4 archive has no macOS native decompiler; rea doctor will report native_decompiler missing until it is built (rea docs/installation.md, "Missing macOS native decompiler" / "macOS arm64 native decompiler")`.
- The dry run logs the URL, size and target.

- [ ] **Step 1: Write the failing tests**: `ghidra_version` on both fixtures; `ghidra_valid` accepts `12.1.4` and `12.1.9`, rejects `12.2.0` and `11.3.1`; `ghidra_select` precedence (flag invalid → exit 1; env 12.2 → WARN logged and install path taken; tools-dir without sentinel → treated absent, Review Focus 4); `--dry-run` performs no download (fake server `/__count` is 0 for the zip path when `ALLOWED_HOSTS` points at it).

- [ ] **Step 2: Run to verify failure.** Expected: fails.

- [ ] **Step 3: Implement** in both scripts; `main` runs `step_ghidra` then `lock_release`.

- [ ] **Step 4: Run tests and gates.** Run: `just check`. Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: ghidra step (exact 12.1.4, embedded SHA-256, archive safety)"
```

---

### Task 11: Step `profile` (both scripts)

**Files:**
- Create: `tests/sh/profile.sh`, `tests/pester/Profile.Tests.ps1`, `tests/fixtures/sample-doctor-agent-profile-fail.json` (the O6 variant B JSON, paths replaced)
- Modify: `setup.sh`, `setup.ps1`, `tests/fixtures/bin/agent-profile` (stub answers `claude doctor <n> --json` with `STUB_AP_DOCTOR_FILE` and exits `STUB_AP_DOCTOR_EXIT`; `claude create <n>` exits `STUB_AP_CREATE_EXIT` and creates `AGENT_PROFILE_HOME/profiles/<n>/claude`)

**Interfaces:**
- `profile_config_dir NAME` runs `agent-profile claude doctor NAME --json`; exit 0 or 5 accepted (5 → WARN listing `.checks[] | select(.status=="fail") | .id`); other → `die $EX_STEP`; prints `json_query … '((d.checks||[]).find(c=>c.id==="launch_environment")||{}).data?.value ?? ""'` (null-safe: a missing check yields an empty string, not a Node `TypeError`); empty, or equal to `$HOME/.claude`, → `die $EX_STEP profile "agent-profile did not report a profile-specific CLAUDE_CONFIG_DIR"`.
- `step_profile`: `profile_config_dir`, then `agent-profile claude create NAME` (exit 0 required; the message `already exists` → `skip`), then require the directory to exist; sets `CLAUDE_CONFIG_DIR_SELECTED`, `SUMMARY_profile`. Dry run: doctor only, log the directory.

- [ ] **Step 1: Write the failing tests**: with the stub and the "after create" fixture → directory parsed equals the fixture value; with the fail fixture and exit 5 → WARN logged containing `profile_path`, create still attempted; with exit 4 from doctor → exit 1; with a doctor JSON whose value is `$HOME/.claude` → exit 1; with `AGENT_PROFILE_HOME` set to a scratch dir and the REAL `agent-profile` (when on PATH; skipped otherwise with a printed `skip`) → the directory exists after the step (this is the O6 experiment as a test).

- [ ] **Step 2: Run to verify failure.** Expected: fails.

- [ ] **Step 3: Implement** in both scripts; `main` runs `step_profile`.

- [ ] **Step 4: Run tests and gates.** Run: `just check`. Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: profile step (agent-profile doctor and create, profile-scoped CLAUDE_CONFIG_DIR)"
```

---

### Task 12: Steps `rea-setup` and `rea-doctor` (both scripts)

**Files:**
- Create: `tests/sh/rea.sh`, `tests/pester/Rea.Tests.ps1`, `tests/fixtures/rea-doctor-client-ok.json`, `tests/fixtures/rea-doctor-client-empty.json`, `tests/fixtures/rea-doctor-ghidra-ok.json`, `tests/fixtures/rea-doctor-ghidra-bad.json`, `tests/fixtures/rea-doctor-ghidra-mac-nodecomp.json` (the ok fixture with `native_decompiler` `ok:false`, `code:"executable_missing"`, `available:false`)
- Modify: `setup.sh`, `setup.ps1`, `tests/fixtures/bin/npx` (stub: records its argument list to `STUB_NPX_LOG`, prints `STUB_NPX_FILE_<n>` for the n-th call, exits `STUB_NPX_EXIT_<n>`)

**Interfaces:**
- `rea_env_run STEP ARGS…` runs `npx -y "$PIN_REA_SPEC" ARGS…` through `run_cmd` with `CLAUDE_CONFIG_DIR=$CLAUDE_CONFIG_DIR_SELECTED GHIDRA_INSTALL_DIR=$GHIDRA_DIR_SELECTED JAVA_HOME=$JAVA_HOME_SELECTED` set for the child only (`env VAR=… npx …`; ps1: set `$env:` then restore in `finally`).
- `step_rea_setup`: `setup --client claude_code --dry-run` (log stdout at DEBUG), then unless `OPT_DRY_RUN`: `setup --client claude_code --yes` plus `--install-hopper` when asked; non-zero → `die $EX_STEP`.
- `step_rea_doctor`: `doctor --client claude_code --skill --json` → file; `rea_doctor_healthy FILE` (`d.healthy===true`); failing → `die $EX_VERIFY rea-doctor "<names of scope_checks with ok false>"`. Then `doctor --provider ghidra --json` → `rea_ghidra_status FILE` prints `available providerVersion failing-check-names`; `available` true → ok; only `native_decompiler` failing and `OS=mac` → WARN with the recipe pointer (section B decision) and `SUMMARY_rea_doctor=warn`; any other failure → `die $EX_VERIFY` with the hint `rea 6.8.0 accepts Ghidra 12.1.x; if rea now requires another line, update the pins block (PIN_GHIDRA_*)` when the `version` check fails, else the failing names. Skipped under `--dry-run`.

- [ ] **Step 1: Write the failing tests**: `rea_doctor_healthy` on the ok and empty fixtures; `rea_ghidra_status` on ok (`true 12.1.4`), bad (`installation`, `java` named), mac-nodecomp (`OS=mac` → step returns 0 and WARN logged; `OS=linux` → exit 5); the npx stub log shows exactly `-y rea-agents@latest setup --client claude_code --dry-run` then `… --yes` (and `--install-hopper` appended when `OPT_INSTALL_HOPPER=1`); the child environment contains the three variables (stub writes `env | grep -E '^(CLAUDE_CONFIG_DIR|GHIDRA_INSTALL_DIR|JAVA_HOME)='` to the log) and the parent shell's `CLAUDE_CONFIG_DIR` is unchanged afterwards.

- [ ] **Step 2: Run to verify failure.** Expected: fails.

- [ ] **Step 3: Implement** in both scripts; `main` runs both steps.

- [ ] **Step 4: Run tests and gates.** Run: `just check`. Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: rea setup and doctor steps with profile-scoped environment"
```

---

### Task 13: Disclosures, prompt, summary, env files, `launch`, dry run, end-to-end on Linux

**Files:**
- Create: `tests/sh/launch.sh`, `tests/pester/Launch.Tests.ps1`, `tests/integration/e2e.sh` (full `--dry-run` and full `--no-launch` run with stubs on PATH, the fake server serving tiny stand-in archives under the pinned names with matching hashes injected by reassigning `PIN_GHIDRA_SHA256`/`PIN_GHIDRA_ZIP_BYTES` after sourcing, a throwaway `HOME`, `AGENT_PROFILE_HOME`, `XDG_DATA_HOME` containing a space)
- Modify: `setup.sh`, `setup.ps1`, `justfile` (`test-integration` runs `e2e.sh`), `tests/fixtures/bin/clavity-ls` (stub records arguments and env, exits `STUB_CL_EXIT`)

**Interfaces:**
- `print_disclosures` (spec §10 four items, with the computed total download size from the pending installs), `plan_summary` (one line per step: `would install`, `would reuse`, `skip`), `confirm "Proceed? [y/N]"` (declined → print `nothing changed`, exit 0). Order in `main`: steps 1–2, then `tools_bin_plan`, `jdk_plan`, `ghidra_plan` (each sets `PLAN_<id>` to `install`, `update`, `reuse` or `skip` plus the download size, doing only the resolution and validity checks of its step), then ONE free-space check `require_free_mb "$TOOLS_DIR" $((NEEDED_MB))` where `NEEDED_MB` = 1500 if `PLAN_ghidra` is `install` + 600 if `PLAN_jdk` is `install` + 200 (exit 1 with the shortfall before anything is downloaded), disclosures, plan, prompt, then execute. Each install step logs `disk_free_mb TOOLS_DIR` at DEBUG immediately before its download and after `install_commit`, so a real run records the measured on-disk delta per platform (the 882 MB / 346 MB figures in section A were measured on ext4 only; the handoffs read these lines back).
- `write_env_files TOOLS_DIR`: `env.sh` with `export GHIDRA_INSTALL_DIR=… JAVA_HOME=… PATH="<bin>:$PATH"` (values single-quoted, embedded `'` escaped) and `env.ps1` on Windows (`$env:…`). Overwritten every run.
- `print_summary` to stdout (spec §9 list) BEFORE launch.
- `step_launch`: `OPT_NO_LAUNCH` → print `launch skipped (--no-launch); run: clavity-ls start "<folder>" --profile <name>` and exit 0. Headless Linux (`DISPLAY` and `WAYLAND_DISPLAY` both empty) or macOS → print the two-terminal instructions verbatim (spec §8 step 9: `. "<tools>/env.sh"` in both; terminal 1 `clavity-ls agy "<folder>"`; terminal 2 `clavity-ls start "<folder>" --attach --profile <name>`; the sentence that the hint `clavity-ls agy` prints omits `--profile` and must not be used), exit 0. Otherwise run `clavity-ls start "$OPT_FOLDER" --profile "$OPT_PROFILE"` with the three variables and `PATH`; log `launch exited <n>`; if `n` is 1 and stderr contains `terminal` → print the two-terminal instructions; exit `n`.
- Dry run (spec §11): every step logs `would …`, `rea setup --dry-run` runs, nothing is written except the log and `env.*` is NOT written.

- [ ] **Step 1: Write the failing tests**: `write_env_files` output sources cleanly under dash and sets the three values (path with a space and a `'`); `step_launch` with `OPT_NO_LAUNCH=1` prints the command and exits 0 without calling the stub; headless (`DISPLAY= WAYLAND_DISPLAY=`) prints both terminal commands including `--attach --profile`; with `DISPLAY=:0` the stub is called with `start <folder> --profile rea` and the env contains `GHIDRA_INSTALL_DIR`; stub exit 7 → script exit 7 and log `launch exited 7`; `confirm` declined → stdout `nothing changed`, exit 0. `e2e.sh`: `--dry-run` exits 0, makes no `*.tmp.*`, no `env.sh`, no archive requests; `--yes --no-launch` exits 0, tools dir holds `jdk-…/.install-complete` and `ghidra_12.1.4_PUBLIC/.install-complete`, `env.sh` exists, a second run logs `skip (already valid)` for jdk, ghidra, tools-bin and profile and downloads nothing; `STUB_node_VERSION=v24.21.0` → exit 4 before any request (Review Focus 5). Pester mirrors the unit tests; `e2e` for PowerShell runs the dry-run path only (prereq stubs cannot be `.exe` on CI; the Windows real run is the handoff).

- [ ] **Step 2: Run to verify failure.** Expected: fails.

- [ ] **Step 3: Implement** in both scripts.

- [ ] **Step 4: Run tests, integration and gates.** Run: `just check test-integration`. Expected: pass; `e2e.sh` prints `ok dry-run`, `ok install`, `ok idempotent`, `ok old-node`.

- [ ] **Step 5: Real run on this machine** with `XDG_DATA_HOME=$HOME/rea-e2e-tmp` (with a space in a subdirectory), `AGENT_PROFILE_HOME=$HOME/rea-e2e-tmp/aph`, `--profile reatest --yes --no-launch`, Node 24.22.2 via `fnm use`, real network (about 780 MB; do not pre-seed the tools dir from the planning downloads: the real download is the test). Expected: exit 0; `rea doctor --provider ghidra --json` in the log shows `available: true`; `~/.claude.json` mtime unchanged; a second run changes nothing. Record both durations in the commit message body. Delete the throwaway directories afterwards.

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "feat: disclosures, summary, env files and launch; end-to-end on Linux"
```

---

### Task 14: `--check-upstream` and the canary workflow

**Files:**
- Create: `tests/sh/upstream.sh`, `tests/pester/Upstream.Tests.ps1`, `.github/workflows/canary.yml`
- Modify: `setup.sh`, `setup.ps1`

**Interfaces:**
- `step_check_upstream` (replaces steps 3–9 when `OPT_CHECK_UPSTREAM`): `resolve_agent_profile`, `resolve_clavity_ls` (names, tags, sidecar fetch and 64-hex check), `adoptium_resolve` (release regex, host, sidecar equals API checksum), a `HEAD`-style `resolve_redirects` of `PIN_GHIDRA_URL` (final host allow-listed; `Content-Length` equals `PIN_GHIDRA_ZIP_BYTES` via `curl -sI` on the final URL), `rea_supported_ghidra`: latest version from `https://registry.npmjs.org/rea-agents/latest` (`d.version`), then `https://raw.githubusercontent.com/morluto/rea/rea-agents-<v>/src/ghidra/GhidraReleasePolicy.ts`, regex `SUPPORTED_GHIDRA_VERSION\s*=\s*"([0-9.]+)"`; must equal `PIN_GHIDRA_VERSION` (else `die $EX_VERIFY check-upstream "rea <v> now supports Ghidra <x>; update PIN_GHIDRA_*"`); a missing file or constant → `die $EX_VERIFY` naming the URL. Prints one line per expectation; exit 0 when all hold.
- `canary.yml`: `on: schedule: - cron: '17 6 * * 1'` and `workflow_dispatch`; `permissions: contents: read`; matrix of the three OSes; `timeout-minutes: 15`; runs `sh setup.sh --check-upstream --yes` (POSIX) and `powershell.exe -NoProfile -ExecutionPolicy Bypass -File setup.ps1 -CheckUpstream -Yes` on Windows; `GITHUB_TOKEN` passed as `env: GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}` (the script sends it only to `api.github.com`).

- [ ] **Step 1: Write the failing tests**: `rea_supported_ghidra` against fixture files served by the fake server (the real `GhidraReleasePolicy.ts` text with `"12.1.4"` → ok; with `"12.2.0"` → exit 5 and the `PIN_GHIDRA_*` hint; a 404 → exit 5 naming the URL); `step_check_upstream` with every endpoint stubbed by the fake server → exit 0 and no archive request; the Content-Length mismatch case → exit 5.

- [ ] **Step 2: Run to verify failure.** Expected: fails.

- [ ] **Step 3: Implement** in both scripts and write `canary.yml` (pins identical to `ci.yml`).

- [ ] **Step 4: Run tests and gates; one real `--check-upstream` run.** Run: `just check && sh setup.sh --check-upstream --yes`. Expected: pass; the real run prints `ok` for every expectation (today: rea 6.8.0 → 12.1.4).

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: --check-upstream drift check and weekly canary workflow"
```

---

### Task 15: Release process, README, handoffs

**Files:**
- Create: `.github/workflows/release.yml`, `docs/handoff/windows.md`, `docs/handoff/macos.md`
- Modify: `README.md`, `CONTRIBUTING.md`, `.claude/recommended-tools.json` (final `gates` text), `scripts/check-drift.sh` (also assert both `PIN_SCRIPT_VERSION` values match `^[0-9]+\.[0-9]+\.[0-9]+$`)

**Interfaces:**
- `release.yml`: `on: push: tags: ['v*']`; job `release` (`ubuntu-latest`, `permissions: contents: write`, `timeout-minutes: 20`): checkout, install tools as `ci.yml` does, `just check`, assert `PIN_SCRIPT_VERSION` in `setup.sh` equals `${GITHUB_REF_NAME#v}` (fail otherwise), `sha256sum setup.sh setup.ps1 > SHA256SUMS`, `gh release create "$GITHUB_REF_NAME" setup.sh setup.ps1 SHA256SUMS --verify-tag --title "$GITHUB_REF_NAME" --notes "See README: download, verify, run."` with `GH_TOKEN: ${{ github.token }}`.
- README sections: what it does (spec §1, two paragraphs), requirements per OS (Claude Code, agy, Node floors, `wt`, `tar.exe`), download-verify-run for each OS (`curl -LO`, `grep ' setup.sh$' SHA256SUMS | shasum -a 256 -c -` (stock macOS has no `sha256sum`; `shasum` ships with macOS and Linux perl), `sh setup.sh`; Windows: `Invoke-WebRequest` for the two files, `(Get-FileHash setup.ps1).Hash` compared with the line in `SHA256SUMS`, then `powershell -NoProfile -ExecutionPolicy Bypass -File .\setup.ps1` as the ONE documented run command, because a stock Windows 11 execution policy of `Restricted` refuses `.\setup.ps1` outright and a downloaded file also carries the Mark of the Web; `Unblock-File .\setup.ps1` is named as the alternative for users who prefer to keep their policy, and neither needs admin), the flag table with the `--flag`/`-Parameter` mapping, what gets installed where, the two-terminal flow for macOS and headless Linux, the macOS native-decompiler limitation with the `rea` docs section titles, honest limits (spec §10), uninstall list (tools dir, bin dir binaries, `~/.agent-profile/profiles/<name>`, state dir logs), licence line.

- [ ] **Step 1: Write `release.yml`, the README, finish CONTRIBUTING.md (release procedure: bump `PIN_SCRIPT_VERSION` in both scripts, `just check`, tag, push).** Extend `check-drift.sh` and its assertion.

- [ ] **Step 2: Run the gates.** Run: `just check`. Expected: pass; `actionlint` and `action-pins` accept the three workflows.

- [ ] **Step 3: Write the handoff files** with the `clavity:platform-handoff` skill: Windows (O10 NTFS rule under `%LOCALAPPDATA%`, longest extracted Ghidra path length versus the 260-character MAX_PATH with `LongPathsEnabled` unset, SmartScreen or antivirus quarantine of the downloaded `agent-profile.exe` and `clavity-ls.exe`, O13 `wt` alias, a real run started exactly as the README says on a stock `Restricted` policy (`powershell -NoProfile -ExecutionPolicy Bypass -File .\setup.ps1 -Yes -NoLaunch`) then a launch, the in-use `.exe` update path, Pester under `powershell.exe`); macOS (O7 quarantine of curl-downloaded binaries, Temurin `Contents/Home` layout, the two-terminal flow, bash 3.2 and bsdtar listing format, the native decompiler build if the owner wants it verified). Each names the exact commands, the expected log lines and what to send back.

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "docs: README, release workflow and platform handoffs"
```

- [ ] **Step 5: Capstone.** Before declaring the implementation complete, run `clavity:agy-capstone` on the committed range (`b67c1da..HEAD`), fold verified findings with tests, re-run until GREEN, then `clavity:agy-test-audit`.

---

## Review log

- Solo panel round 1 (six seats): 9 findings, all folded before escalation (redirect resolution by HEAD, JSON expression passed as an argument, `find` pruning of `tests/.tmp`, named plan functions, four undeclared names, the installed-version check reading `BIN_DIR`, `*.old.<pid>` cleanup, Pester zero-test guard, Windows ARM64 test).
- agy panel round 1 (seven seats): 6 findings. FOLDED after verification against the plan text and the runner images: `test` recipe called `dash` unconditionally (macOS and Windows runners have no dash); free-space checks were per step only (now one combined check before the prompt, per-step re-checks kept); `profile_config_dir` JSON lookup could throw a Node `TypeError` (now null-safe); `UNAME_S`/`UNAME_M` could spoof detection from the environment (now unset in `main`); `check-line-citations.sh` roots omitted `justfile` and `lefthook.yml`. Also folded from its open-question answers: Task 8 split into Task 8 (`preflight`, `prereq`) and Task 8b (`tools-bin`). PARTLY REJECTED: "do not write `.install-complete` on macOS without a native decompiler, or build it" contradicts the owner's decision of the same day (warn-and-continue) and the spec's non-goal of building native components; the sound half (report the limitation on every run, not only the first) is folded in section B. Its uncheckable item (Pester 5.9.0 resolution ahead of the built-in 3.4.0 under `powershell.exe`) is already O17's "first CI run".
- agy panel round 2 (six seats, new: Fold Auditor, First-Run Walker): 4 findings, all FOLDED after verification. (1) HIGH: the round-1 fold of `check-line-citations.sh` named `setup.sh`/`setup.ps1` as `find` roots, which do not exist in Task 1; measured `find` exits 1 on a missing root, so `just check` at Task 1 Step 12 would have failed under `set -eu` (now: directory roots plus a `-maxdepth 1` root-level scan; `psanalyze.ps1` builds its list the same tolerant way). (2) MED: README gave no way to run a downloaded `setup.ps1` on a stock Windows execution policy (now: `powershell -NoProfile -ExecutionPolicy Bypass -File` is the documented command, `Unblock-File` the alternative; CI and canary Windows steps carry the same flag). (3) MED: the `test` recipe text omitted the Pester zero-test guard its prose described (now in the recipe). (4) MED: `step_tools_bin` ran `$BIN_DIR/<name> --version` with no handling of an absent binary (now `installed_version` returns empty with status 0 and the step treats empty as `install`, with tests). From its open questions, folded as LOW: DEBUG lines with `disk_free_mb` before and after each install so the handoffs record real on-disk deltas. Its O17 item was already in the ledger.
- agy panel round 3 (seats Dependency Cynic, Activation Auditor, Protocol Pedant, Gate Sequencer + cores): 5 findings, all FOLDED after verification. (1) HIGH, claim partly false and fix changed: agy said `just` runs recipes in `cmd.exe` on Windows; `just` defaults to `sh`, so that mechanism is wrong, but the `find ... | wc -l` guard could still resolve to `System32\find.exe`, so the guard moved into the `pwsh` command (`Get-ChildItem` count). (2) HIGH: `Expand-ReaArchive` called `ExtractToFile` on directory entries and without parent directories (now: directory entries created, parents created first). (3) MED: `tests/sh/run.sh` globbed itself (now excludes `lib.sh` and `run.sh`). (4) MED: `make_archives.py` was created after the tests that need its fixtures (now created in Step 1, run from `archive.sh` setup). (5) LOW: `check-drift.sh` strips surrounding quotes from pin values; README verification line uses `shasum -a 256 -c` because stock macOS lacks `sha256sum`. Uncovered classes it named (SmartScreen/AV quarantine, Windows MAX_PATH) go to the handoff checklist, not the plan.
- agy panel round 4 (seats Boundary Smuggler, Resource Vampire, Order Inverter + cores; final allowed round): 3 findings, all FOLDED after verification. (1) MED: archive extraction fallback used `$JAVA_HOME/bin/jar` although the step sets `JAVA_HOME_SELECTED` (now the latter). (2) MED: the 570 MB Ghidra zip and 208 MB JDK archive were never deleted (now downloaded into staging and removed after extract and on failure). (3) LOW: `setup.ps1` sets `$ErrorActionPreference = 'Stop'`. Round cap reached with MED folds not re-reviewed by a further round; both MED folds are one-line and mechanical.

## Self-review notes

- Spec coverage: §2 goals G1–G8 → Tasks 1–3 (G1, G8), 8–10 (G2, G3, G7), 13 (G4, G5), 2 and 9 (G6); non-goals respected (no Node/Claude install, no PATH persistence, no uninstall code). §6 pins → Task 2 block + Task 3 drift. §7 flags and exit codes → Tasks 2, 3, 8, 13. §8 steps 1–9 → Tasks 8–13; archive safety → 6, 7; validity and precedence → 9, 10; shared tools dir, lock, orphans, prune, free space → 6, 7; env handling → 12, 13; network policy → 4, 5. §9 logging → 2, 3. §10 disclosures, prompt, distribution → 13, 15. §11 dry run → 13. §12/12b → 1, 4, 5. §13 → section A and Task 15 handoffs.
- One spec statement is NOT implemented because measurement made it unnecessary: the `claude mcp` fallback for the MCP environment (O1 shows `rea setup` records it). One new fact changes macOS behaviour (O7, native decompiler) and is flagged for the owner.
- Names used across tasks: `OS`, `ARCH`, `TOOLS_DIR`, `BIN_DIR`, `ZIP_TOOL`, `JAVA_HOME_SELECTED`, `GHIDRA_DIR_SELECTED`, `CLAUDE_CONFIG_DIR_SELECTED`, `SUMMARY_<id>`, `PLAN_<id>`, `STAGING_DIRS`, `LOCK_HELD`, `ALLOWED_SCHEMES`, `ALLOWED_HOSTS`, `RETRY_WAITS`, `LOCK_POLLS` are defined in the task that introduces them and used unchanged afterwards.
