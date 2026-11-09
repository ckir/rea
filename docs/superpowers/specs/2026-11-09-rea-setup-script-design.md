# REA setup and launch script: design

Status: DRAFT for owner approval (2026-11-09). Nothing is built. This is a design, not a line-level plan:
the scripts do not exist yet, so no line numbers or "existing code" are cited for them. The line-level plan
is written after this design is approved (see "Next step").

## 1. Intent and why

The owner wants to run `morluto/rea` (an MCP server and CLI for reverse engineering) inside an isolated
Claude Code profile, started by `clavity-ls` (which pairs Claude Code with a live agy peer), and to hand
the same tool to friends. Friends have stock machines. So the tool must take a box from "nothing but the
OS, Claude Code, agy and a recent Node" to a running paired session, with one setup command (the launch itself is one command only where `clavity-ls` can open an agy terminal, see step 9), on Windows, Linux
and macOS, and must be safe to run again.

Why a script and not a README: seven manual steps across four tools, each with a platform-specific
download and a version rule that is easy to get wrong (for example `rea` accepts only Ghidra 12.1.x while
upstream's latest is 12.2). A script removes that guesswork and leaves a log when something goes wrong.

## 2. Goals, non-goals, anti-goals

Goals
- G1. One command per OS family: `setup.sh` (Linux, macOS) and `setup.ps1` (Windows, Windows PowerShell 5.1
  or later). Same behaviour, same flags, same log format. `setup.sh` is POSIX `sh` (it must run under dash and
  under macOS's bash 3.2; no bashisms; checked with `shellcheck -s sh`).
- G2. Bootstrap from nothing: install `agent-profile` and `clavity-ls`, a JDK and Ghidra when missing.
- G3. "Always latest" for everything `rea` does not constrain (owner decision), with exactly the pins in section 6.
- G4. Idempotent: a second run with everything valid changes nothing and says so.
- G5. No admin or root rights for the default path.
- G6. A readable console and a complete log file for every run (section 9).
- G7. Reuse anything already valid on the machine (the owner has Ghidra 12.1.4 and a JDK 21).
- G8. The quality gates are defined once, as `just` recipes (section 12b), and run both locally (`just check`,
  `lefthook` on pre-push) and in CI: the static gates on Ubuntu, and the OS-dependent tests (`just test`) on
  Linux, macOS and Windows.

Non-goals (v1)
- Installing Claude Code, agy or Node. They are checked and reported.
- Persisting PATH changes or editing shell profiles/registry. The script changes PATH only for its own process.
- Hopper beyond passing `--install-hopper` through to `rea setup` (Linux and macOS only; rea offers no Windows install).
- Uninstalling. The README lists what to delete.
- Linux ARM64 (no native Ghidra decompiler upstream; `clavity-ls` has no Linux ARM64 build either).
- Updating itself, or a GUI.

Anti-goals (would make it a failure even if it technically runs)
- Touching the user's default Claude profile (`~/.claude`, `~/.claude.json`). Every `claude`, `rea` and
  `agent-profile` call that could write runs with an explicit `CLAUDE_CONFIG_DIR` for the named profile.
- Leaving a half-extracted install that later looks complete.
- Launching agy with permission prompts skipped without telling the user first (section 10).
- Logging secrets.

## 3. Decisions ledger

| # | Decision | Who |
|---|---|---|
| D1 | Two native scripts, `setup.sh` + `setup.ps1`, not Python/PowerShell 7/Node (stock Windows and macOS lack Python; pwsh 7 is not default on Windows) | Owner, after an agy-first consult |
| D2 | Always fetch the latest, except where `rea` cannot accept it | Owner |
| D3 | Script installs Ghidra and a JDK when missing (not verify-only) | Owner |
| D4 | Add logging | Owner |
| D5 | Ghidra pinned to exactly 12.1.4 with an embedded SHA-256 | Negotiated with agy, owner asked for the negotiation |
| D6 | JDK: latest Temurin 21.x resolved at run time, checksum cross-checked, embedded 21.0.13+9 fallback only if the Adoptium API is unreachable, with a warning | Negotiated; fallback wording is my edit |
| D7 | One shared per-user tools directory outside `~/.agent-profile` | Negotiated with agy |
| D8 | Everything marked "my call" below | Me, for the owner to correct |
| D10 | "One command" holds for setup everywhere, but for launching only on Windows and Linux with a display; macOS and headless Linux get the two-terminal flow, because `clavity-ls` 0.17.0 cannot open an agy terminal there (step 9). CONFIRMED by the owner 2026-11-09 (option 1, accept the two-terminal flow; fixing `clavity-ls` upstream stays a possible later improvement) | Owner, forced by the `clavity-ls` source |
| D11 | Add `just`, `lefthook`, quality gates and CI (GitHub Actions on Ubuntu, macOS, Windows), following the conventions of the owner's `aiprofiles` repository (section 12b) | Owner (the CI part chosen from two options) |
| D12 | A weekly canary workflow and a read-only `--check-upstream` mode to catch upstream drift early | Me, for the owner to veto |
| D13 | `shfmt` is a hard quality gate: `fmt-check` is in `check`, runs on pre-push and in CI | Owner |
| D14 | Licence: PolyForm Noncommercial 1.0.0, with the `header.txt` used in `aiprofiles` ("Copyright (c) 2026 Costas Kirgoussios ... PolyForm Noncommercial License 1.0.0"). Consequence the owner has been told: friends may not use the scripts commercially, for example at work | Owner |
| D9 | `rea` stays on "latest" (`npx -y rea-agents@latest`) while Ghidra is pinned to 12.1.4. The accepted consequence (section 6): the script breaks, loudly and early, on the day `rea` stops accepting 12.1.x, and the fix is a one-line edit of the pin block. The weekly canary is what catches this early | Owner |

## 4. Approaches considered

Language (decided D1): Python (rejected: absent on stock Windows/macOS), PowerShell 7 (rejected: not default
on Windows), Node `.mjs` (rejected: Node may be missing or too old before the script can run; this machine has
24.21.0 while `rea` needs 24.22.1+), one shared Node core behind thin native launchers (rejected for the same
reason), documentation only (rejected: the owner wants automation). Chosen: two native scripts.

Toolchain install (decided D3, D5-D7): system package managers (rejected: need admin, differ per platform,
Ghidra packaging unconfirmed), containers (rejected: heavy, not asked for), verify-and-explain only (the owner
declined it). Chosen: per-user portable install into a shared directory.

## 5. Constraints (verified unless marked)

From `rea` (tag `rea-agents-6.8.0`):
- Node 22.x >= 22.23.4, 24.x >= 24.22.1, or >= 26.12.1 (`install.sh`).
- Ghidra: accepts the 12.1.x line, verified build 12.1.4 (`src/ghidra/GhidraReleasePolicy.ts:2`). Upstream's latest, 12.2, is "unsupported". A 64-bit full JDK of at least 21 (this Ghidra declares min 21, no max); the JDK must match the host architecture (no emulated x64 JDK on Apple silicon); on macOS `JAVA_HOME` must be the `Contents/Home` directory.
- `rea setup` follows `CLAUDE_CONFIG_DIR`: registration in `$CLAUDE_CONFIG_DIR/.claude.json`, skill in `$CLAUDE_CONFIG_DIR/skills` (`src/application/SupportedClients.ts`: directory resolution at lines 167-171, the `.claude.json` and `skills` names at lines 509-514). It never installs Ghidra, Java or Python.
- Linux needs a procps-compatible `ps`. Windows Ghidra is "experimental P0" and needs fixed local NTFS volumes. No Hopper install on Windows.
- `rea` reads `GHIDRA_INSTALL_DIR` and `JAVA_HOME` from the process environment (`src/config/parseConfig.ts:116-117`).

From `agent-profile` (v0.1.2 source, installed 0.1.1):
- Profile root `~/.agent-profile`; profile config dir `~/.agent-profile/profiles/<name>/claude`.
- `claude create <name>` is idempotent. `doctor <name> --json` works before the profile exists and still reports the `CLAUDE_CONFIG_DIR` value (measured).
- Exit codes: 0 ok, 1 I/O, 2 usage, 3 agent not installed, 4 profile/config problem, 5 a doctor check failed, 6 unsupported executable (`error.rs`, `cli.rs:1186`).
- Profile names: start with an ASCII letter or digit; then letters, digits, `.`, `_`, `-`; not one of 13 reserved words; not a Windows device name; no trailing dot on Windows; case-insensitive uniqueness (`name.rs`).
- Windows: `claude` must be a native `.exe`; an npm `.cmd` shim is refused (exit 6).
- All of its platform evidence comes from a Linux container (README), so Windows and macOS behaviour is unmeasured by its author.

From `clavity-ls` (0.17.0; local source one chore commit past `clavity-v31`):
- `start --profile <name>` requires `agent-profile` and `claude` on PATH, runs `agent-profile claude create`, takes a per-profile lock, installs the `clavity` and `superpowers` plugins into the profile at user scope, then launches Claude with `CLAUDE_CONFIG_DIR` set (`ProfileSetup.cs`). It applies its extra variables on top of the inherited environment (`RealStartEffects.cs:56-65`).
- It always launches agy with `--dangerously-skip-permissions` (`StartFlow.cs:149` and `:349` set `SkipPermissions = true`; `Launcher.cs:44` documents it as a recorded owner decision of the clavity project). It does not pass `CLAUDE_CONFIG_DIR` to agy; agy shares `~/.gemini/antigravity-cli/` with the user's normal setup.
- Windows `start` needs Windows Terminal (`wt`) and `pwsh` or `powershell`. Linux/macOS open a terminal via a ladder; `CLAVITY_TERMINAL` overrides it.
- Its profile-name check is looser than `agent-profile`'s, so the script uses `agent-profile`'s rules.

From GitHub and Adoptium (measured 2026-11-09):
- `agent-profile` assets have unversioned names, so `.../releases/latest/download/<asset>` works. `clavity-ls` assets embed the version (`clavity-ls-linux-x64-0.17.0.tar.gz`), so the unversioned name returns 404 and the version must be discovered.
- GitHub returned repeated 504 errors for release downloads during testing, so retries are mandatory.
- Ghidra 12.1.4: `ghidra_12.1.4_PUBLIC_20260921.zip`, 569,649,598 bytes, SHA-256 printed in the release notes (`ddac49f9...d2d4db`; the script embeds the full value, computed by the author at build time). The unpacked directory on the owner's machine is 882 MB.
- Temurin 21: Adoptium's assets API returned `jdk-21.0.13+9`, 207,858,352 bytes, with `checksum`, `checksum_link` and `signature_link` fields.
- Total download is about 778 MB for Ghidra plus the JDK.

## 6. Version policy (the only pins)

| Component | Policy | Source of truth |
|---|---|---|
| `agent-profile` | latest | `https://github.com/ckir/aiprofiles/releases/latest/download/<asset>` plus `.sha256`; tag from the `releases/latest` redirect |
| `clavity-ls` | latest | tag from the `releases/latest` redirect of `ckir/clavity`; asset name from the GitHub releases API (uses `GITHUB_TOKEN` if set), falling back to scraping `/releases/expanded_assets/<tag>`; match `^clavity-ls-<rid>-(<semver>)\.tar\.gz$`; plus `.sha256` |
| `rea` | latest, via `npx -y rea-agents@latest` | npm |
| JDK | latest Temurin 21.x (pin: major 21) | Adoptium assets API; embedded 21.0.13+9 URL and hash used only if the API is unreachable after retries, with a "possibly outdated JDK" warning |
| Ghidra | exact 12.1.4 (pin: exact build) | embedded URL and SHA-256 |

The pins live in one clearly marked block at the top of each script. A test asserts the two blocks carry
identical values (drift guard). When `rea` moves to Ghidra 12.2, `rea doctor --provider ghidra` reports the
install unsupported and the script's pin block needs a one-line update (the script prints this hint).

Coupling to be aware of (decided by the owner, D9: `rea` stays on latest): "latest `rea`" plus "exact Ghidra 12.1.4" guarantees the script
breaks on the day a `rea` release stops accepting 12.1.x, until the pin block is edited. The script detects
that case (the `rea doctor --provider ghidra` result) and says exactly what to change, but it cannot avoid
it. Alternatives: pin `rea` to a tested version (breaks "always latest" for `rea`), or accept the break and
the one-line fix. Recommended: accept it, because the failure is loud, early and has a one-line remedy.

Ghidra hash procedure: the author downloads the 570 MB zip once, computes its SHA-256, and compares it with the
value in the release notes. If they disagree, stop and ask the owner before embedding anything.

An already-installed tool is replaced only by a newer one; the script never downgrades.

## 7. Interface

Flags are kebab-case in `setup.sh` (`--dry-run`) and the same names as PascalCase parameters in `setup.ps1`
(`-DryRun`, `-Yes`, `-ProfileName`), with identical meaning. `setup.ps1` uses `[CmdletBinding()]`, so
`--verbose` is PowerShell's built-in `-Verbose`. The README carries the mapping table.

| Flag | Default | Meaning |
|---|---|---|
| `--profile NAME` | `rea` | Profile name, validated with `agent-profile`'s rules |
| `--folder PATH` | current directory | Folder handed to `clavity-ls start` |
| `--ghidra-dir PATH` / `--java-home PATH` | env `GHIDRA_INSTALL_DIR` / `JAVA_HOME` | Use this install. An invalid path given by the FLAG is a failure (exit 1, no silent fallback). A stale value that came only from the environment variable is a warning and the search continues (see "Validity and precedence") |
| `--tools-dir PATH` | shared dir, section 8 | Where the JDK and Ghidra are installed |
| `--bin-dir PATH` | `~/.local/bin` (POSIX), `%LOCALAPPDATA%\rea-tools\bin` (Windows) | Where `agent-profile` and `clavity-ls` are installed |
| `--install-hopper` | off | Pass to `rea setup`; Linux/macOS only; rejected on Windows. May need root (apt/dnf/pacman) |
| `--yes` | off | Do not prompt. Without a terminal and without `--yes`, refuse (exit 2) |
| `--dry-run` | off | Plan only (section 11) |
| `--no-launch` | off | Do everything except `clavity-ls start` |
| `--check-upstream` | off | Read-only drift check (section 12b): resolve every release, asset, URL and expected hash without downloading archives or checking Claude Code/agy; exit 5 if any expectation breaks |
| `--verbose` / `--quiet` | INFO | Console level DEBUG / WARN. The log file is always DEBUG |
| `--log-dir PATH` | state dir, section 9 | Log location |

Environment read: `GITHUB_TOKEN` (API rate limit only; never logged), `GHIDRA_INSTALL_DIR`, `JAVA_HOME`,
`XDG_DATA_HOME`/`XDG_STATE_HOME`, `LOCALAPPDATA`, `CLAVITY_TERMINAL` (passed through untouched).

Exit codes (script's own; my call): 0 success; 1 a step failed; 2 usage error or non-interactive without
`--yes`; 3 unsupported platform or architecture; 4 a prerequisite the user must install (Claude Code, agy,
Node, `wt`, a native `claude.exe`); 5 verification failed (checksum, signature, version, doctor). When the
final `clavity-ls start` runs, the script exits with its exit code unchanged (Claude Code's own), and the
log records that. `clavity-ls start` blocks until the Claude session ends (`RealStartEffects.cs` waits for
the process and returns its exit code), so the final summary (section 9) is printed BEFORE it runs and the
log line `launch exited <n>` is written after. A Claude exit code of 1-5 is indistinguishable by number from
the script's own; that log line disambiguates (accepted trade-off, my call).

## 8. Behaviour, step by step

Every step is skipped when its postcondition already holds. Step ids are used in the log.

1. `preflight`: detect OS and architecture; refuse unsupported combinations (exit 3). Validate the profile name. Check a downloader and archive tools exist (curl and tar; on Windows `tar.exe`, which ships with Windows 10 build 17063 and later, is needed for the `.tar.gz` of `clavity-ls`). A missing required tool is exit 4 with an install hint. For Ghidra's zip on POSIX, `unzip` or `bsdtar` is preferred; if both are absent (GNU tar cannot read zip), the zip is listed and extracted with `jar` from the already-validated JDK (step 4 runs before step 5). Measured 2026-11-09 with JDK 21.0.12: `jar tf` lists entries including a `../` path; `jar xf` skipped that entry here (not guaranteed for other JDK builds, so the script still checks the listing itself); and `jar xf` does NOT preserve Unix execute bits, so the script then sets them from a list derived at planning from the zip's own mode bits (O15).
2. `prereq`: check `node` (floor above, early, with an `fnm install 24`-style hint), `npx`, `claude` (and on Windows that it is a native `.exe`, not a `.cmd` shim), `agy`, `wt` plus a PowerShell on Windows, a procps `ps` on Linux. Failures exit 4 with the exact fix.
3. `tools-bin`: install or update `agent-profile` then `clavity-ls` into the bin dir: resolve latest (section 6), compare with the installed version (parse the semver from `--version`, ignore build metadata), download to `<file>.tmp.<pid>` with retries, verify SHA-256 against the sidecar, extract only the expected single file (`agent-profile[.exe]` / `clavity-ls[.exe]`), set the execute bit on POSIX, move into place. Prepend the bin dir to this process's PATH. Linux ARM64 for `clavity-ls`: exit 3. Installs here take the same lock as the tools dir. On Windows a running `.exe` cannot be replaced: if the move fails because the file is in use, skip the update with a warning ("close running sessions to update") and continue with the installed version; there is no compatibility floor (always latest). On POSIX the new file is renamed over the old one.
4. `jdk`: reuse a valid `--java-home`/`JAVA_HOME`, or a valid install in the tools dir; else install (below).
5. `ghidra`: reuse a valid `--ghidra-dir`/`GHIDRA_INSTALL_DIR` of the 12.1.x line, or a valid install in the tools dir; else install 12.1.4 (below).
6. `profile`: run `agent-profile claude doctor <name> --json` to read `CLAUDE_CONFIG_DIR` (works before creation), refuse an empty value or the default `~/.claude`; then `agent-profile claude create <name>`; a doctor exit of 5 alone is logged as WARN with the failing checks and is not fatal (as `clavity-ls` does), because `clavity-ls` and `aiprofiles` disagree on its meaning (O6); it is fatal only if the `CLAUDE_CONFIG_DIR` value is missing or the directory does not exist after `create`.
7. `rea-setup`: with `CLAUDE_CONFIG_DIR`, `GHIDRA_INSTALL_DIR`, `JAVA_HOME` set for the child only: run `npx -y rea-agents@latest setup --client claude_code --dry-run`, log the plan, then `... setup --client claude_code --yes` (adds `--install-hopper` if asked).
8. `rea-doctor`: same environment: `npx -y rea-agents@latest doctor --client claude_code --skill --json` and `doctor --provider ghidra --json`. A non-zero exit is a failure (exit 5). The raw JSON goes to the log; the script reads only fields confirmed against a real run during planning.
9. `launch`: print the disclosures (section 10). What happens next depends on what `clavity-ls` 0.17.0 can do (verified in its source: its terminal ladder lists only Linux terminals such as mate-terminal, gnome-terminal, konsole and xfce4-terminal, has no macOS terminal support, and returns an empty ladder when neither `DISPLAY` nor `WAYLAND_DISPLAY` is set, before it even looks at `CLAVITY_TERMINAL`: `PosixAgyTab.cs` `Candidates`; its own roadmap says macOS `open -a Terminal` is "untested and explicitly out of the first cut", `ROADMAP.md:3894`; on failure `start` prints a fallback message and returns 1, `StartFlow.cs:383-387`):
   - Windows, and Linux with a display: run `clavity-ls start <folder> --profile <name>` with the same environment (one command).
   - macOS, and Linux with neither `DISPLAY` nor `WAYLAND_DISPLAY`: do not call `start` (it would fail). Setup is complete, so the script exits 0 with the launch deferred, and prints the two-terminal flow: in terminal 1, `clavity-ls agy <folder>`; in terminal 2, `clavity-ls start <folder> --attach --profile <name>`. Neither new terminal inherits this script's environment (including the bin dir on `PATH`, so `clavity-ls` would not even be found), so the script writes a sourceable file `<tools-dir>/env.sh` (Windows: `env.ps1`) that exports `GHIDRA_INSTALL_DIR`, `JAVA_HOME` and the bin dir on `PATH`, and the printed instructions tell the user to source it in BOTH terminals first. The printed commands must be used exactly as written: the attach hint that `clavity-ls agy` prints itself omits `--profile` (`PosixAgyTab.cs:208-212`), and running that one would start Claude on the user's default profile, which the anti-goals forbid, so the instructions say this in so many words. Verified: `start --attach --profile <name>` does run the profile setup (`StartFlow.cs:306-315`). Nothing is added to shell profiles.
   - If `start` is attempted and still fails to open a terminal, print the same two-terminal instructions.

JDK install: resolve the Temurin 21 asset for the OS/arch from the Adoptium assets API (query values measured
2026-11-09: `os` is `linux`, `mac` or `windows`, and `macos` returns 404; `architecture` is `x64` or `aarch64`,
and `arm64` returns 404, so map `uname -m` `arm64` to `aarch64`; take the response's `binary.package`, a
`.tar.gz` on Linux and macOS and a `.zip` on Windows, and never `binary.installer`, which is an `.msi` or `.pkg`
that needs administrator rights and would break goal G5); validate the release tag with `^jdk-21(\.[0-9]+)*\+[0-9]+$`; require the download host to be `github.com` under `adoptium/temurin21-binaries`; download to a staging directory; verify SHA-256 against the API's `checksum` and, when reachable, the sidecar at `checksum_link` (mismatch fails with exit 5; an unreachable sidecar warns and continues); extract; verify `bin/java` and `bin/javac` exist and `java -version` reports 21; on macOS `JAVA_HOME` is `.../Contents/Home`. Installed into `<tools>/jdk-<release>/`.

Ghidra install: download the embedded URL, verify the embedded SHA-256, extract with every entry path checked to stay inside the staging directory (reject `..` and absolute paths), require the top directory `ghidra_12.1.4_PUBLIC` and `application.version=12.1.4` in `Ghidra/application.properties`, make launch scripts and the native decompiler executable on POSIX. Installed into `<tools>/ghidra_12.1.4_PUBLIC/`. The authoritative acceptance test is `rea doctor --provider ghidra`, not the script's own checks.

Archive safety (every extraction): extract into the staging directory only; refuse absolute entry names and
any `..` component; refuse symlinks and hard links whose target resolves outside the staging directory
(tar/bsdtar defaults differ, so the script checks the listing first, and does not preserve owners:
`--no-same-owner`); for zip on Windows PowerShell 5.1 check every entry path before extracting (do not rely on
`ExtractToDirectory` alone). Any violation deletes the staging directory and fails with exit 5. Measured with GNU tar on Linux: `tar -tvz` prints a `Removing leading` warning on stderr while listing, so the check must parse stdout only, and a symlink appears as `name -> target` on its line (hardlink listings were not tried, and bsdtar's listing format on macOS is UNVERIFIED).

Validity and precedence (my call). A JDK is valid when `bin/java` and `bin/javac` exist (a full JDK, not a
JRE), `java -version` reports a major version of at least 21 (any vendor, any later major: this Ghidra declares
no maximum), it is 64-bit and matches the host architecture. A Ghidra is valid when
`Ghidra/application.properties` reports `application.version` in the 12.1.x line, and the final authority is
`rea doctor --provider ghidra`. A tools-dir install is valid only if its `.install-complete` file exists AND
the essential files above exist (the file alone proves nothing). Precedence for each of JDK and Ghidra:
explicit flag (invalid: fail) > environment variable (invalid: WARN and continue) > a valid install already in
the tools dir > install. The script never searches the system for other installs.

Shared tools directory (my call on exact paths): `${XDG_DATA_HOME:-~/.local/share}/rea-tools` (Linux, macOS) and
`%LOCALAPPDATA%\rea-tools` (Windows; it must be a fixed NTFS volume, checked). Each install goes to
`<name>.tmp.<pid>` inside the tools dir (the same volume, so the rename is atomic; never in `%TEMP%`), the
`.install-complete` file is written INSIDE the staging directory after verification, and the rename into place
is the single commit point. An install directory without that file is treated as absent and replaced. At
start the script removes `*.tmp.<pid>` leftovers, in the tools dir AND the bin dir, whose process no longer
exists (or older than 24 hours); a skipped update (a running Windows `.exe`) deletes its own staged file at once. Versioned subdirectories mean an upgrade never overwrites a directory
a running session may hold open (Windows file locks). Concurrent runs serialise on a lock in the tools dir
(wait up to 120 s, then fail with exit 1 naming the lock). The lock is held for the install and update steps
(3 to 5) only and is released before step 6, so a long-running `clavity-ls start` (which blocks until the
Claude session ends) never holds it. The lock records its owner's pid and start time; a
lock whose owner no longer exists is stale and is taken over with a WARN. Old JDK directories are pruned to the
newest two after a successful install (never while holding an in-use directory: a failed delete on Windows is
a WARN, not an error). Free disk space is checked before downloading
(threshold set at planning from measurement; the unpacked JDK size is not yet measured).

Environment handling: `GHIDRA_INSTALL_DIR` and `JAVA_HOME` are set only in the environment of the commands
that need them and of `clavity-ls start`. Nothing is written to shell profiles. If O1/O2 show these values do
not reach the MCP server that way, the fallback is to set them on the `rea` MCP server's own `env` inside the
profile's config, through the supported `claude mcp` mechanism run with the profile's `CLAUDE_CONFIG_DIR`
(profile-scoped only; never shell profiles, never the default profile). The exact command is chosen after
O1/O2 and reported to the owner. Warn (do not fail) if any of
`ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN`, `CLAUDE_CODE_OAUTH_REFRESH_TOKEN`,
`ANTHROPIC_PROFILE`, `CLAUDE_CODE_USE_BEDROCK`, `CLAUDE_CODE_USE_VERTEX`, `CLAUDE_CODE_USE_FOUNDRY` is set,
because they override the profile's credential isolation (`aiprofiles` adapter notes).

Network policy: HTTPS only, TLS 1.2 or later (set explicitly in Windows PowerShell 5.1). Only these hosts are
contacted: `github.com`, `api.github.com`, the host(s) GitHub's release download redirect lands on (to be
measured at planning, O14), `api.adoptium.net`, and the npm registry through `npx`; anything else is refused.
`GITHUB_TOKEN` is sent only to `api.github.com` and is never forwarded on a redirect to another host.
Redirects are resolved by the script, not by the downloader: automatic redirect-following is turned off, each
`Location` is read, must be `https` and on the allow-list, and at most 5 hops are followed; the archive is then
downloaded from the final URL. (Standard `curl -L` and `Invoke-WebRequest` follow redirects without any host
check, so the allow-list cannot be enforced any other way.) Four attempts with
waits of 2, 4, 8 and 16 seconds for connection errors and HTTP 5xx; no retry for 4xx other than 429 (honour
`Retry-After` if present). Large archives abort on a stalled transfer rather than a fixed total timeout. Partial
downloads restart from zero in v1 (builder may add resume).

## 9. Logging

Two sinks, same line format in both scripts:

`2026-11-09T14:03:22Z INFO  [ghidra] installed 12.1.4 to /home/u/.local/share/rea-tools/ghidra_12.1.4_PUBLIC (5m02s)`

Fields: UTC ISO-8601 timestamp, level (`ERROR WARN INFO DEBUG`), step id in brackets, message.

- Console: to stderr, at INFO by default (`--verbose` DEBUG, `--quiet` WARN). Each step prints one start line and one result line (`ok`, `skip (already valid)`, `warn`, `FAIL`), with download progress only when stderr is a terminal. stdout is reserved for the final summary. Colour only on a terminal and not when `NO_COLOR` is set.
- File: always DEBUG. One file per run, `setup-<UTC yyyymmddThhmmssZ>-<pid>.log`, in `${XDG_STATE_HOME:-~/.local/state}/rea-setup/logs` (POSIX) or `%LOCALAPPDATA%\rea-setup\logs` (Windows), overridable with `--log-dir`. The newest 20 files are kept. The first console line of a run prints the log path; every failure message ends with `details: <log path>`.
- Contents: script version and a hash of the script, OS/arch/shell versions, parsed arguments (not environment dumps), every resolved version and URL, each external command as an argument list with its exit code and duration, bounded (4,000 characters each) stdout and stderr of failed commands, expected and actual SHA-256 values, skip reasons, the `rea` setup plan, the raw `rea doctor` JSON, and the final exit code.
- Redaction: never write `GITHUB_TOKEN` or any variable whose name contains `TOKEN`, `KEY`, `SECRET` or `PASSWORD`; strip `Authorization` headers and URL userinfo/query strings; log only the names of credential-override variables found, never their values. Paths under the home directory are written
  abbreviated (`~` or `%USERPROFILE%`) so a log a friend sends to the owner does not carry a user name.
- Final summary (stdout, printed before the launch): the profile name and its config directory, the installed
  or reused version and path of each of `agent-profile`, `clavity-ls`, the JDK and Ghidra, whether each was
  installed, updated, reused or skipped, the `rea` doctor result, the log file path, and the command to
  launch again (the script itself is idempotent, so re-running it is the way).
- Encoding: UTF-8 without a byte-order mark in both scripts. Windows PowerShell 5.1's default encodings would add one, so the log writer uses .NET file APIs directly (builder's note, not a free choice).
- A failed log write (disk full, read-only) downgrades to a console warning and never aborts the setup.

## 10. Disclosures and security posture

Printed before the first download (unless `--yes`, which still prints them, then continues):
- What will be downloaded and its total size (about 778 MB for Ghidra and the JDK), and where it goes.
- That `clavity-ls start` always runs agy with `--dangerously-skip-permissions`, and that agy is not isolated by the profile (it shares `~/.gemini/antigravity-cli/`).
- That `--install-hopper` may ask for administrator rights and installs commercial demo software.
- That `npx -y rea-agents@latest` downloads and runs the newest published npm package with the user's rights.

Prompt (my call): after the disclosures and the plan, one question, `Proceed? [y/N]`. Declining exits 0 with
"nothing changed". `--yes` skips the question (the disclosures are still printed); `--dry-run` never asks. No
other prompts exist; anything ambiguous is a flag, not a question.

macOS quarantine (O7): the script never strips `com.apple.quarantine` or any other protection attribute by
itself. Whether macOS blocks a curl-downloaded binary is unmeasured (O7); a special message and exit 4 for a
blocked binary are NOT implemented until the macOS handoff measures it. Until then a blocked binary surfaces
as an ordinary step failure and the README tells the user.

Distribution (O11): friends get the scripts from a GitHub release, with a `.sha256` file beside them, and the
README shows how to verify before running. That checksum sits in the same release as the script, so it detects
a corrupted or truncated download, not a compromised release; the README says so. There is deliberately no
pipe-to-shell installer: the scripts download and run binaries and start agy with permissions skipped, so a
person should read what they are about to run.

Honest limits to state in the README and the output: the `.sha256` files for `agent-profile` and `clavity-ls`
sit in the same release as the archive, so they detect corruption, not a compromised release; "always latest"
widens that exposure. Ghidra's check is stronger (the hash is embedded by the script author); the JDK check
spans two origins (Adoptium's API and GitHub). Optional hardening (verifying Adoptium's `.sig`) is out of scope
for v1 because `gpg` is not present by default on Windows and macOS.

## 11. Dry run

`--dry-run` makes no changes: it may perform read-only network requests for metadata (release redirects, API
calls), writes only its own log file, downloads no archives, runs no mutating command, and uses
`rea setup --dry-run` and `agent-profile ... --dry-run` where they exist. It prints every step with what it
would do, including the resolved versions and sizes, and exits 0 if the plan is sound.

## 12. Testing strategy (not a plan)

- Pure functions in both scripts (platform and asset mapping, semver compare, profile-name validation, tag regex, redaction, pin-block equality) tested with plain shell tests and Pester.
- A local fake release server (test-only; may use Python since tests are not shipped) for failure injection: 504 sequences, 429 with `Retry-After`, truncated download, wrong checksum, API unreachable (JDK fallback), missing sidecar.
- `--dry-run` end to end on this Linux machine; a real run on a throwaway `CLAUDE_CONFIG_DIR`/profile and a throwaway tools dir.
- Windows and macOS: real runs on the owner's other boxes, driven through the platform-handoff process, because this machine is Linux only.
- Static analysis: `shellcheck`, PSScriptAnalyzer; both declared in `.claude/recommended-tools.json`.

## 12b. Developer tooling and quality gates

Added at the owner's request (D11). The conventions are copied from the owner's `aiprofiles` repository
(`justfile`, `lefthook.yml`, `.github/workflows/ci.yml`): a `just` recipe is the single definition of a check;
`lefthook` only ever calls recipes (the comment in `aiprofiles`' `lefthook.yml` says why: so hook and CI cannot drift). One deliberate difference: `aiprofiles`' CI jobs repeat the commands instead of running `just check`, and a comment in its own `ci.yml` records that two lists had already drifted once. Here CI calls the recipes too, so there is exactly one list; slow checks run on pre-push,
not pre-commit, so commits stay fast; `default` runs `just check`.

Files this adds to the repository: `justfile`, `lefthook.yml`, `.github/workflows/ci.yml`,
`.github/workflows/canary.yml`, `.claude/recommended-tools.json`, `scripts/` (helper checks), `tests/`,
`header.txt` and `LICENSE` (the PolyForm Noncommercial 1.0.0 text, copied from the owner's `aiprofiles`; D14), `CONTRIBUTING.md` (how to run the gates, one page).

Recipes (names are the contract; the commands behind them are the builder's):

| Recipe | What it gates | In `check`? |
|---|---|---|
| `setup` | `lefthook install`, then `tools-check` | no |
| `tools-check` | every required tool is present, with the install hint for each that is not | yes |
| `shellcheck` | `shellcheck -s sh` over every shell file found with `find` (a bare glob would pass an unmatched pattern through literally), excluding `.clavity/` | yes |
| `psanalyze` | PSScriptAnalyzer over every `*.ps1`, failing on Warning and above, with the `PSUseCompatibleSyntax` rule set to `TargetVersions = @("5.1")` (measured with PSScriptAnalyzer 1.25.0: it reports a PowerShell 7 ternary expression as an Error; `PSUseCompatibleCommands`, `PSUseCompatibleCmdlets` and `PSUseCompatibleTypes` also exist but need compatibility profiles and were not tried) | yes |
| `typos` | spelling, as in the owner's other repositories | yes |
| `tools-doc-check` | the tool table in `CONTRIBUTING.md` is generated from `.claude/recommended-tools.json` and must match it (the pattern in `aiprofiles`, `scripts/gen-tool-table.sh --check`, added there after the two lists drifted by hand) | yes |
| `line-citations` | no comment in a script or test cites another file by line number (it rots on the next edit; the same gate exists in `aiprofiles`). This does not apply to design documents | yes |
| `suppressions` | every `# shellcheck disable` and every PSScriptAnalyzer suppression carries a written reason, and the total is compared with a committed baseline (`scripts/suppressions.baseline`): a higher count fails unless the baseline is raised in the same change, so every increase is a visible line in the diff | yes |
| `drift` | the pin blocks of `setup.sh` and `setup.ps1` are identical; the embedded Ghidra SHA-256 is 64 hex digits; embedded URLs use only allow-listed hosts | yes |
| `test` | unit tests: plain-shell tests under `tests/sh/` run with `dash` and `bash`, and Pester tests under `tests/pester/` | yes |
| `test-integration` | a local fake release server (test-only Python) for failure injection: 504 sequences, 429 with `Retry-After`, truncated download, wrong checksum, API unreachable, missing sidecar, a zip with a `..` entry | no (CI and by hand; slower) |
| `action-pins` | every `uses:` in workflows is pinned to a 40-hex commit SHA with a `# <ref>` comment (reuse `aiprofiles`' `scripts/check-action-pins.sh`; same owner) | yes |
| `actionlint` | workflow syntax | yes |
| `license-check` | `addlicense -check -f header.txt`, over scripts, tests, workflows, ignoring `.clavity/**` and other generated or scratch output as `aiprofiles` does | yes (licence chosen, D14) |
| `fmt-check` | `shfmt` in diff mode, POSIX dialect, over every shell file found with `find`; any difference is a non-zero exit. A hard gate (D13) | yes |
| `fmt` | rewrites shell files with the same `shfmt` settings (the writer; not part of `check`). PowerShell formatting (`Invoke-Formatter`) stays advisory, because only `shfmt` was made a gate | no |
| `check` | the recipes marked "yes", in that order of cost: cheap ones first | n/a |

`lefthook.yml`: `pre-push`, parallel, one command per recipe in the "yes" column (the same list as `check`),
each a plain `just <recipe>`. No `pre-commit` hook (my call, following `aiprofiles`). CI is the backstop: a
bypassed hook is caught there. Nothing in the hooks or CI downloads the real toolchain.

CI (`.github/workflows/ci.yml`; triggers: push to `main`, pull requests):
- Job `gates` on Ubuntu: install the declared tools, run `just check`.
- Job `matrix` on `ubuntu-latest`, `macos-latest` and `windows-latest`: run `just test` (and `test-integration`
  on Ubuntu). On Windows the Pester tests are run under Windows PowerShell 5.1 explicitly (`powershell.exe`),
  not only `pwsh`; on macOS the shell tests run under the system `/bin/sh`. This is the only way to exercise
  Windows PowerShell 5.1 and macOS bash 3.2 without owning the machines. UNVERIFIED until a run: that those
  runners ship those shells, and which Pester major version is available on them (O17).
- Security: `permissions: contents: read` at the top, least privilege per job, no secrets, no
  `pull_request_target`, third-party actions pinned by SHA, a `concurrency` group that cancels superseded runs,
  and a `timeout-minutes` on every job. These rules apply equally to `canary.yml` (an explicit `permissions: contents: read`, nothing broader). The tools the `gates` job installs are pinned: exact versions recorded in one file, and any downloaded binary verified against a checksum recorded beside its version. `.github/CODEOWNERS` names the owner for `justfile`, `lefthook.yml`, `.github/` and `scripts/`, so a pull request that weakens a gate needs the owner's review; enforcing that needs branch protection with required code-owner review, which is a repository setting outside the files (an owner action, not verified here).

Canary (`.github/workflows/canary.yml`, weekly and manual; my call D12): because the script follows "always
latest", upstream drift is the main risk (an asset renamed, `rea` moving to Ghidra 12.2, Adoptium changing its
API). The canary runs a new read-only mode on all three OSes, `--check-upstream`: it resolves every release,
asset name, URL and expected hash exactly as a real run would, downloads no archive, ignores the Claude Code/agy
prerequisites (a CI runner has neither), compares the Ghidra line the script installs with the one the latest published `rea` accepts (it reads the latest version from the npm registry, then `SUPPORTED_GHIDRA_VERSION` in `src/ghidra/GhidraReleasePolicy.ts` at that release's git tag on `raw.githubusercontent.com`; measured 2026-11-09: latest is 6.8.0 and the constant reads "12.1.4"; if that file ever moves, the canary fails loudly, which is the intended behaviour), and exits 5 if any expectation breaks. `registry.npmjs.org` and `raw.githubusercontent.com` join the host allow-list (O14). A failing canary tells the owner
before a friend finds out. It uses `GITHUB_TOKEN` only for `api.github.com`.

Anti-weakening rules (the written quality bar): a gate may not be removed from `check`, a threshold may not be
lowered, a test may not be skipped or deleted, and a suppression may not be added without a reason, except in a
change whose description says so. There is deliberately NO numeric coverage threshold in v1: shell and
PowerShell coverage tools are not declared tools here, and a made-up number would be the kind of bar this
section exists to prevent. Revisit when Pester code coverage is in use.

Declared tools (`.claude/recommended-tools.json`, each with `why` and `install`): `just`, `lefthook`,
`shellcheck`, `pwsh`, the PowerShell modules `PSScriptAnalyzer` and `Pester`, `typos`, `actionlint`,
`addlicense`, `jq` (used by `tools-doc-check`; `aiprofiles` forgot to declare it, so it is declared here), `shfmt` (a hard gate, D13). Measured on this machine 2026-11-09: present are `just`, `lefthook`,
`shellcheck`, `pwsh` with Pester 6.2.0, PSScriptAnalyzer 1.25.0 (installed for the current user on 2026-11-09 at the owner's request), `typos`, `actionlint`, `addlicense`, `jq`, `shfmt` 3.12.0 (snap, installed 2026-11-09 at the owner's request). Missing: `bats`, which is not needed because the shell tests are plain `sh`.

## 13. Open items and where each is resolved

| # | Unverified or undecided | Resolved by |
|---|---|---|
| O1 | Does `rea setup` record `GHIDRA_INSTALL_DIR`/`JAVA_HOME` in the registration. Source says it records a provider environment (`SetupHost.ts:221-227` builds it from doctor inspections, the host and the explicit setup environment; `SetupTypes.ts:22` calls it "non-secret provider variables propagated into managed registrations"); the exact variable names are not traced | A dry run and a real run in a throwaway `CLAUDE_CONFIG_DIR`, during planning |
| O2 | Does Claude Code pass its environment to the stdio MCP server | Same experiment (look at what `rea` sees) |
| O3 | Unpacked JDK size; the free-space threshold | Measure during planning |
| O4 | Does Temurin's `.sha256.txt` sidecar exist at `checksum_link` (GitHub returned 504s) | Retry during planning; if absent, drop the cross-check from the design |
| O5 | Contents of `agent-profile` macOS arm64 and `clavity-ls` win-x64 archives (downloads failed) | Download and list during planning |
| O6 | Meaning of `agent-profile doctor` exit 5 versus `clavity-ls` treating 5 as fine | Reproduce a failing doctor in a scratch root during planning |
| O7 | macOS: archive quarantine behaviour for curl-downloaded binaries; Ghidra native decompiler directory names; Temurin macOS archive layout | macOS test run via handoff |
| O8 | JSON fields of `rea setup`/`doctor` output the script may rely on | Capture real output during planning; use only those fields |
| O9 | Headless Linux and macOS launch: RESOLVED for the cause (source cited in step 9: no display means an empty terminal ladder, and no macOS terminal code); VERIFIED: `start --attach --profile` runs the profile setup (`StartFlow.cs:306-315`); still UNVERIFIED: that the sourced env file is enough in both terminals | Test during planning on Linux; macOS via handoff |
| O10 | Whether installing under `%LOCALAPPDATA%` satisfies `rea`'s NTFS fixed-volume rule | Windows test run via handoff |
| O11 | DISTRIBUTION DECIDED by the owner 2026-11-09: a GitHub release on `ckir/rea` carrying `setup.sh`, `setup.ps1` and a `.sha256` file, documented as download, verify, run; no pipe-to-shell one-liner. LICENCE DECIDED by the owner 2026-11-09: PolyForm Noncommercial 1.0.0, same as the owner's other repositories (D14). The release process itself (who cuts it, tag naming, how the checksum is produced and published, whether a `release.yml` workflow does it) is left to planning | Owner (licence), Plan (release process) |
| O12 | Exact `clavity-ls --version` output format, needed for the version comparison (`agent-profile --version` prints `agent-profile 0.1.1`, measured) | Capture during planning |
| O13 | Windows: whether `wt` is a working install or a disabled App Execution Alias (`clavity-ls` itself distinguishes these); the hint to print is `winget install Microsoft.WindowsTerminal` (from `Launcher.cs`) | Windows test run via handoff |
| O14 | Which host(s) GitHub release downloads redirect to, for the host allow-list (plus `registry.npmjs.org` and `raw.githubusercontent.com` for the canary) | Measure during planning |
| O15 | Which Ghidra files need the execute bit (derive the list from the zip's own mode bits, needed for the `jar` fallback) | Read the zip metadata during planning |
| O16 | RESOLVED by the owner (D13): `shfmt` is a hard gate. Installed here 2026-11-09 from Canonical's snap (shfmt 3.12.0, `/snap/bin/shfmt`). MEASURED: `shfmt -ln posix -i 2 -ci -d <file>` exits 0 for a formatted file and 1, printing a diff, for a badly formatted one; the snap cannot read files under `/tmp`, so tests use paths under the home directory or pipe through stdin; `-ln posix` does NOT reject `[[ ]]` (it parses it as a command word), so `shellcheck -s sh` stays the portability guard. Still open: PowerShell formatting stays advisory; the install route on CI runners (a package, or a release binary pinned by checksum) | Plan |
| O17 | Which Pester major version the Windows and macOS runners provide, and that Windows PowerShell 5.1 can run the tests; the recipe pins what it needs | First CI run, during planning |
| O18 | How `test-integration` and any non-dry-run CI job satisfy the Claude Code/agy prerequisites (stubs on PATH versus a test-only seam in the scripts, which would be a smell); `--check-upstream` avoids the question for the canary | Plan |
| O19 | PSScriptAnalyzer 5.1 compatibility settings: RESOLVED for the syntax rule (`PSUseCompatibleSyntax`, `TargetVersions = @("5.1")`, measured with PSScriptAnalyzer 1.25.0, installed 2026-11-09). Still open: whether to also use the profile-based compatibility rules, and which PSScriptAnalyzer version CI installs (pin it) | Plan |

## 14. What is left to the builder

Exact flag spellings per shell (`--yes` versus `-Yes`), function decomposition, the download progress
display, resume support, the lock implementation, temporary file naming beyond `.tmp.<pid>`, the free-space
threshold, and the README text. Windows PowerShell 5.1 notes for the builder: set
`$ProgressPreference = 'SilentlyContinue'` for large downloads (the progress bar slows `Invoke-WebRequest`
drastically), and `Invoke-WebRequest` has no stalled-transfer abort, so a stream-based download is likely
needed. Any change to a decision in section 3, a pin in section 6, an exit code in
section 7, or the redaction rules in section 9 comes back to the owner.

## Review log and stand-downs

Reviews so far (every finding resolved to exactly one disposition; findings were verified by reading the
cited source or by running a command before being folded):
- Builder check (a fresh reader of this document): 11 questions; answered in the document, settled as marked "my call", or left to the owner (D9 and O11, both since decided).
- agy-first consults: language (decision D1), toolchain install and its negotiation (D5-D7).
- Adversarial panel with the live agy peer, round 1 (10 seats): 5 findings, all FOLDED (lock held across launch, redirect allow-list enforcement, orphaned staging files in the bin dir, Adoptium `os`/`architecture` values, Adoptium package versus installer).
- Panel round 2 (three first-run walkers): 2 findings FOLDED (no unzip on minimal Linux; headless launch exits 1), which led me to verify that `clavity-ls` has no macOS terminal support (D10).
- Panel round 3 (citation audit and a step-9 walk): 3 findings FOLDED (a wrong line range, the PATH in the first terminal, the attach hint that omits `--profile`).
- Panel round 4 (section 12b only: a fold auditor, a CI attacker, a gate gamer): 5 findings FOLDED after verification (goal G8 contradicted the Ubuntu-only gates job; the canary could not detect `rea` moving to Ghidra 12.2 until it was given a source check at the latest release tag; `jq` was an undeclared dependency of `tools-doc-check`; `canary.yml` lacked explicit permissions, CI tool installs were unpinned and nothing guarded the gate files, hence CODEOWNERS; the `suppressions` gate had no ceiling, hence a committed baseline). One of my own errors was caught before the round: `aiprofiles`' CI repeats commands rather than running `just check`.
- Panel round 5 (whole document; a contradiction sweeper, a scope auditor and a shell-feasibility prober): `PANEL VERDICT: CLEAN`, 0 findings. Not taken on trust: I recounted the census myself (8 goals, 14 decisions, 19 open items, 12 flag rows; agy counted 13 decisions because it read the file before D14 was added), found one stale phrase of my own in this log (fixed), and re-ran four of its probes: a redirect resolved without following it (302 to the tag page), a `mkdir` lock under `dash` (fresh, live owner refused, dead owner taken over), a `tar -tvz` pre-scan that flags `../` entries, absolute entries and a symlink to `/etc/passwd`, and the SHA-256 of `abc`. All reproduced. What the round did not cover: macOS `bsdtar` and bash 3.2, and Windows PowerShell 5.1 (UNVERIFIED until the first CI run or a handoff run).
- REJECTED after measurement (agy claims, not folded): a Ghidra unpacked size of 1.4 GB (measured 882 MB); an install path inside `~/.agent-profile/<profile>/tools` (the real layout is `profiles/<name>/claude`); a constant named `VERIFIED_GHIDRA_BUILD` (the real name is `SUPPORTED_GHIDRA_VERSION`); "macOS Terminal.app launcher integration" in `clavity-ls` (no such code; `ROADMAP.md:3894`).
- UNVERIFIED-ACCEPTED: native `tar.exe` before Windows 10 build 17063 was not verified; the design simply requires it and exits 4 with a hint when it is absent.
- DISCARDED-BELOW-FLOOR: none.

## 15. Next step

On owner approval: a reviewer reads this as a builder, questions are settled, then `superpowers:writing-plans`
produces the plan against the real repository state (the plan first resolves, by measurement, every open item in section 13 that is not the owner's).
