# rea

Portable bootstrap and launch scripts for `rea` (`morluto/rea`, an MCP server and CLI for reverse
engineering): `setup.sh` for Linux and macOS, `setup.ps1` for Windows.

## What it does

Each script takes a machine that has only the operating system, Claude Code, agy and a recent Node to a
running Claude Code session paired with a live agy peer, with `rea` registered in an isolated Claude Code
profile. It installs `agent-profile` and `clavity-ls` (always the latest release), a JDK (Temurin 21) and
Ghidra 12.1.4 when they are missing, creates the profile, runs `rea setup` and `rea doctor` against it, and
starts the session with `clavity-ls start`. Where `clavity-ls` cannot open an agy terminal itself (macOS, and
Linux without a display) it prints a two-terminal flow instead.

It needs no administrator rights on its default path, installs into your user directories, is safe to run
again (every step is skipped when its result is already in place), and writes a complete log of every run.
It does not install Node, Claude Code or agy, does not touch your shell profiles and does not uninstall
anything.

## Requirements

All platforms: Claude Code (native install) and agy on `PATH`, and Node with `npx`: 22.x at least 22.23.4,
24.x at least 24.22.1, or any version from 26.12.1.

| | Linux | macOS | Windows |
|---|---|---|---|
| Shell | `sh` | `sh` (bash 3.2 is fine) | Windows PowerShell 5.1 or later |
| Download and archives | `curl`, `tar`, and `unzip` or `bsdtar` (without both, the Ghidra zip is read with `jar` from the installed JDK) | `curl`, `tar`, and `unzip` or `bsdtar` | `tar.exe` (Windows 10 build 17063 or later; used for the `clavity-ls` `.tar.gz`) |
| Claude Code | `claude` | `claude` | a native `claude.exe`; a `.cmd` shim is refused |
| Other | `ps` from procps | | `wt` (Windows Terminal; install with `winget install Microsoft.WindowsTerminal`) |

Supported platforms: Linux x64, macOS x64 and arm64, Windows x64. Anything else exits with code 3.

## Download, verify, run

Each release carries `setup.sh`, `setup.ps1` and `SHA256SUMS`. Read the script before you run it: it
downloads and runs binaries and starts agy with permissions skipped. There is deliberately no pipe-to-shell
installer.

The checksum sits in the same release as the script, so it detects a corrupted or truncated download, not a
compromised release.

### Linux and macOS

```sh
curl -LO https://github.com/ckir/rea/releases/latest/download/setup.sh
curl -LO https://github.com/ckir/rea/releases/latest/download/setup.ps1
curl -LO https://github.com/ckir/rea/releases/latest/download/SHA256SUMS
grep ' setup.sh$' SHA256SUMS | shasum -a 256 -c -
sh setup.sh
```

The verify line must print `setup.sh: OK`. (`shasum` ships with macOS and with Linux's perl; stock macOS has
no `sha256sum`.)

### Windows

In Windows PowerShell:

```powershell
Invoke-WebRequest https://github.com/ckir/rea/releases/latest/download/setup.ps1 -OutFile setup.ps1
Invoke-WebRequest https://github.com/ckir/rea/releases/latest/download/SHA256SUMS -OutFile SHA256SUMS
(Get-FileHash setup.ps1).Hash
Select-String ' setup.ps1$' SHA256SUMS
powershell -NoProfile -ExecutionPolicy Bypass -File .\setup.ps1
```

The hash printed by `Get-FileHash` (upper case) must equal the one on the `SHA256SUMS` line (lower case);
compare them before the last command. The last command is the one documented way to run the script: a stock
Windows 11 execution policy of `Restricted` refuses `.\setup.ps1` outright, and a downloaded file also carries
the Mark of the Web. `-ExecutionPolicy Bypass` applies to that one process only. If you prefer to keep your
policy, run `Unblock-File .\setup.ps1` and then start it the way your policy allows. Neither way needs
administrator rights.

## Options

Flags are the same in both scripts: kebab-case in `setup.sh`, PascalCase parameters in `setup.ps1`.

| `setup.sh` | `setup.ps1` | Default | Meaning |
|---|---|---|---|
| `--profile NAME` | `-ProfileName NAME` | `rea` | Profile name, validated with `agent-profile`'s rules |
| `--folder PATH` | `-Folder PATH` | current directory | Folder handed to `clavity-ls start` |
| `--ghidra-dir PATH` | `-GhidraDir PATH` | env `GHIDRA_INSTALL_DIR` | Use this Ghidra (must be 12.1.x). Invalid by flag: exit 1. Invalid only from the environment: warning, the search continues |
| `--java-home PATH` | `-JavaHome PATH` | env `JAVA_HOME` | Use this JDK (21 or later, a full JDK). Same validity rules |
| `--tools-dir PATH` | `-ToolsDir PATH` | see below | Where the JDK and Ghidra are installed |
| `--bin-dir PATH` | `-BinDir PATH` | `~/.local/bin`; `%LOCALAPPDATA%\rea-tools\bin` | Where `agent-profile` and `clavity-ls` are installed |
| `--log-dir PATH` | `-LogDir PATH` | see below | Where the log files go |
| `--install-hopper` | `-InstallHopper` | off | Pass `--install-hopper` to `rea setup` (installs commercial demo software; may ask for root). Rejected on Windows with exit 2 |
| `--yes` | `-Yes` | off | Do not ask `Proceed? [y/N]`. Without a terminal and without this flag the script refuses (exit 2) |
| `--dry-run` | `-DryRun` | off | Plan only; see below |
| `--no-launch` | `-NoLaunch` | off | Do everything except `clavity-ls start`; prints the command |
| `--check-upstream` | `-CheckUpstream` | off | Read-only check that every pinned and resolved release, asset, URL and hash still matches; exit 5 if one breaks. Skips the Claude Code, agy and `wt` checks |
| `--verbose` | `-Verbose` | off | Console level DEBUG (the log file is always DEBUG) |
| `--quiet` | `-Quiet` | off | Console level WARN |
| `--help` | (use `Get-Help .\setup.ps1`) | | `setup.sh` prints its usage and exits 0 |

Exit codes: 0 success; 1 a step failed; 2 usage error, or non-interactive without `--yes`; 3 unsupported
platform or architecture; 4 a prerequisite you must install; 5 verification failed (checksum, version,
doctor). When the final `clavity-ls start` runs, the script exits with its exit code unchanged; the log line
`launch exited <n>` tells it apart from the script's own codes.

### Dry run

`--dry-run` / `-DryRun` changes nothing except its own log file: it still makes the read-only network
requests for metadata (release redirects, API calls), downloads no archive, installs nothing and never asks.
It prints what each step would do. On a fresh machine, where there is no profile, Ghidra or JDK yet, the
`rea setup --dry-run` call is skipped, so `rea`'s own plan is not shown; it is shown only when those already
exist.

## What gets installed where

| What | Linux and macOS | Windows |
|---|---|---|
| JDK and Ghidra | `$XDG_DATA_HOME/rea-tools`, else `~/.local/share/rea-tools` (each in a versioned subdirectory) | `%LOCALAPPDATA%\rea-tools` (must be a fixed NTFS volume) |
| `agent-profile`, `clavity-ls` | `~/.local/bin` | `%LOCALAPPDATA%\rea-tools\bin` |
| Claude Code profile | `~/.agent-profile/profiles/<name>` | `%USERPROFILE%\.agent-profile\profiles\<name>` |
| Logs (newest 20 kept) | `$XDG_STATE_HOME/rea-setup/logs`, else `~/.local/state/rea-setup/logs` | `%LOCALAPPDATA%\rea-setup\logs` |
| Environment file | `<tools dir>/env.sh` | `<tools dir>\env.ps1` |

Nothing is added to `PATH` permanently and nothing is written to shell profiles. `env.sh` / `env.ps1`
exports `GHIDRA_INSTALL_DIR` and `JAVA_HOME` and puts the bin directory first on `PATH`; it is rewritten on
every run, and you source it in a terminal that does not inherit the script's environment.

Measured on Linux, a cold run installed Temurin 21.0.13+9, Ghidra 12.1.4, `agent-profile` 0.1.2 and
`clavity-ls` 0.17.0 and took about 130 s on a fast connection. A second run took about 30 s, because
`rea setup` and `rea doctor` run through `npx` every time. The tools directory was about 1.2 GB (Ghidra
882 MB, JDK 346 MB); the download is about 778 MB.

Every run prints these disclosures before the first download: the download size and destination; that
`clavity-ls start` always runs agy with `--dangerously-skip-permissions` and agy is not isolated by the profile
(it shares `~/.gemini/antigravity-cli/`); that `--install-hopper` may ask for administrator rights; and that
`npx -y rea-agents@latest` downloads and runs the newest published npm package with your rights.

## macOS and headless Linux: two terminals

`clavity-ls` cannot open an agy terminal on macOS, or on Linux with neither `DISPLAY` nor `WAYLAND_DISPLAY`.
There the script finishes setup, exits 0 without launching, and prints this flow:

```sh
# terminal 1
. "<tools dir>/env.sh"
clavity-ls agy "<folder>"

# terminal 2
. "<tools dir>/env.sh"
clavity-ls start "<folder>" --attach --profile <name>
```

Source `env.sh` in BOTH terminals (a new terminal does not inherit the script's environment, so it would not
even find `clavity-ls`). Use the commands exactly as printed: the attach hint that `clavity-ls agy` prints
itself omits `--profile`, and following it would start Claude on your default profile.

## macOS: no native decompiler

Ghidra's official archive has no macOS native decompiler. The script cannot build one (it never builds native
components), so it installs Ghidra, logs a WARN on every run, and continues; `rea doctor` then reports the
native decompiler missing and `rea` cannot decompile until you build it. `rea`'s own documentation
(`docs/installation.md`) describes how, in the sections "Missing macOS native decompiler" and "macOS arm64
native decompiler". The script never strips `com.apple.quarantine` or any other protection attribute. Whether
macOS blocks the downloaded `agent-profile` and `clavity-ls` binaries is not yet known (see `docs/handoff/`);
if it does, the script has no special message for it, and you have to clear the block yourself.

## Windows: path length

Ghidra's longest entry is 149 characters long below the extraction directory. The script refuses to extract
when the result would pass 240 characters (Windows' limit is 260 unless `LongPathsEnabled` is set), so keep a
`-ToolsDir` at most 64 characters long. The default `%LOCALAPPDATA%\rea-tools` is well under that.

## Limits

- Not yet tested on a real Windows or macOS machine; see `docs/handoff/`. The Windows PowerShell 5.1 code is
  unverified until the first CI run on `windows-latest`.
- Integrity: the `.sha256` sidecars of `agent-profile` and `clavity-ls` sit in the same release as the
  archive, so they detect corruption, not a compromised release, and "always latest" widens that exposure.
  Ghidra's check is stronger (the hash is embedded in the script). The JDK check spans two origins (the
  Adoptium API and GitHub). Adoptium's signature is not verified.
- The install lock records its owner; a lock whose owner has gone away is taken over with a warning, and
  there is a small race window between two runs taking it over at the same moment.
- `java -version` is run without a timeout.
- Log redaction is best effort. It does not handle values longer than 20000 characters, nested JSON objects
  or arrays, cookie headers, or unquoted values containing spaces. Home-directory paths are abbreviated.
  Read a log before sending it to someone.
- Only these hosts are contacted: `github.com`, `api.github.com`, `release-assets.githubusercontent.com`,
  `api.adoptium.net`, `registry.npmjs.org` (through `npx`) and `raw.githubusercontent.com`; HTTPS only.
  `GITHUB_TOKEN`, if set, is used for `api.github.com` only, to avoid the rate limit.

## Uninstall

There is no uninstall command. To remove everything the script installed, delete:

- the tools directory (`~/.local/share/rea-tools`, or `%LOCALAPPDATA%\rea-tools` on Windows),
- `agent-profile` and `clavity-ls` from the bin directory (`~/.local/bin`; on Windows they sit inside the
  tools directory above),
- the profile directory `~/.agent-profile/profiles/<name>`,
- the logs under the state directory (`~/.local/state/rea-setup`, `%LOCALAPPDATA%\rea-setup` on Windows).

## Development

`just setup` installs the pre-push hook and lists any missing tool; `just check` runs every gate and takes
minutes. A weekly canary workflow runs `--check-upstream` on all three systems. See `CONTRIBUTING.md` for the
gates, the release procedure and how to update the Ghidra pin.

## Licence

Licensed under the PolyForm Noncommercial License 1.0.0 (see `LICENSE`).
