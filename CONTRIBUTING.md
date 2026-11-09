# Contributing

## One-time setup

```sh
just setup
```

This runs `lefthook install` (activating the `pre-push` hook) and then `just tools-check`, which lists any
missing tool together with its install hint.

## The gates

`just check` runs every gate, cheapest first (it takes minutes: about nine under load, the Pester and shell
suites dominate):

| Recipe | What it checks |
|---|---|
| `just tools-check` | every declared tool is installed (`.claude/recommended-tools.json`) |
| `just typos` | spelling in source and prose |
| `just license-check` | every source file carries `header.txt` |
| `just line-citations` | no comment cites another file by line number |
| `just action-pins` | every workflow `uses:` is pinned to a commit SHA |
| `just actionlint` | workflow syntax |
| `just fmt-check` | shell formatting (`just fmt` rewrites) |
| `just shellcheck` | every shell file as POSIX `sh` |
| `just psanalyze` | PSScriptAnalyzer over `*.ps1`, Windows PowerShell 5.1 syntax |
| `just suppressions` | every lint suppression carries a reason; the count stays within the committed baseline |
| `just drift` | the pins in `setup.sh` and `setup.ps1` are identical and each obeys its rule (`PIN_SCRIPT_VERSION` is `X.Y.Z`) |
| `just tools-doc-check` | the `## Tools` table below matches the JSON |
| `just test` | `just test-sh` (shell tests under dash, bash and `/bin/sh`), then `just test-pester`. CI runs only `test-pester` on Windows: Git Bash reports a MINGW uname, which `setup.sh` maps to the unsupported `windows` platform |

The `pre-push` hook and CI call the same recipes, so there is exactly one list. `just test-integration`
(a local fake release server, Linux; plus `tests/integration/run-win.ps1`) is not part of `check`; CI runs it
on Ubuntu.

## Test layout

- `tests/sh/*.sh`: shell unit tests for `setup.sh`, run by `tests/sh/run.sh` under each shell found.
- `tests/pester/*.Tests.ps1`: the same behaviours for `setup.ps1` (Pester 5; also run under Windows
  PowerShell 5.1 in CI).
- `tests/integration/`: a loopback fake release server and end-to-end runs (`just test-integration`).
- `tests/fixtures/`: recorded API replies, fake archives' inputs and the shared redaction corpus
  (`redact-corpus.txt`, run through both `redact` implementations).
- `scripts/tests/`: tests for the repository's own gate scripts (`check-drift.sh`, `check-action-pins.sh`).

## The canary

`.github/workflows/canary.yml` runs weekly (and on demand) `sh setup.sh --check-upstream --yes` on Linux and
macOS and `setup.ps1 -CheckUpstream -Yes` on Windows. It downloads no archive and writes nothing but its own log; it prints
one ok or FAIL line per expectation (latest releases, asset names, URLs, the embedded Ghidra archive size) and exits 5
when one breaks.

When it fails because of Ghidra (`rea` accepts only the 12.1.x line, so a newer 12.1.y may be fine and a 12.2
is not): read the FAIL line, then edit the Ghidra pins in BOTH `setup.sh` and `setup.ps1`
(`PIN_GHIDRA_VERSION`, `PIN_GHIDRA_TOPDIR`, `PIN_GHIDRA_URL`, `PIN_GHIDRA_SHA256`, `PIN_GHIDRA_ZIP_BYTES`,
`PIN_GHIDRA_UNPACKED_MB`) with the values of the new release asset, the hash from NSA's published checksum
(never from the file you downloaded alone), run `just drift`, run `sh setup.sh --check-upstream --yes`, then
`just check`. Release a new script version afterwards (below).

## Releasing

Only the owner pushes; no script or agent pushes a tag.

1. Bump `PIN_SCRIPT_VERSION` to the new `X.Y.Z` in BOTH `setup.sh` and `setup.ps1` (`just drift` fails when
   they differ or the value is not `X.Y.Z`).
2. `just check`.
3. Commit.
4. Tag `vX.Y.Z` and push the tag.
5. `.github/workflows/release.yml` runs on the tag: it runs `just check`, fails unless both
   `PIN_SCRIPT_VERSION` values equal the tag without its `v`, writes `SHA256SUMS` for `setup.sh` and
   `setup.ps1`, and creates the GitHub release with `setup.sh`, `setup.ps1` and `SHA256SUMS`
   (`--verify-tag`). The README tells users how to download, verify and run them.

## Anti-weakening rules

A gate may not be removed from `check`, a threshold may not be lowered, a test may not be skipped or deleted,
and a suppression may not be added without a reason, except in a change whose description says so. There is
deliberately NO numeric coverage threshold in v1: shell and PowerShell coverage tools are not declared tools
here, and a made-up number would be the kind of bar this section exists to prevent. Revisit when Pester code
coverage is in use.

## Tools

<!-- tools:begin — generated from .claude/recommended-tools.json by scripts/gen-tool-table.sh; do not edit by hand -->
| Tool | Config | `just` recipe | Gates |
|---|---|---|---|
| `just` | `justfile` | — | everything: the local gate (`just check`: tools-check, typos, license-check, line-citations, action-pins, actionlint, fmt-check, shellcheck, psanalyze, suppressions, drift, tools-doc-check, test), the pre-push hook, CI and the release workflow all route through the recipes it defines |
| `lefthook` | `lefthook.yml` | `setup` | local pre-push |
| `shellcheck` | — | `shellcheck` | `just check`; CI gates and release jobs |
| `shfmt` | — | `fmt-check`, `fmt` | `just check`; CI gates and release jobs |
| `pwsh` | — | `psanalyze`, `test` | `just check`; CI gates, release and matrix jobs |
| `PSScriptAnalyzer` | `scripts/psanalyze.ps1` | `psanalyze` | `just check`; CI gates and release jobs |
| `Pester` | `tests/pester/` | `test` | `just check`; CI gates, release and matrix jobs |
| `typos` | `_typos.toml` | `typos` | `just check`; CI gates and release jobs |
| `actionlint` | — | `actionlint` | `just check`; CI gates and release jobs |
| `addlicense` | `header.txt` | `license-check` | `just check`; CI gates and release jobs |
| `jq` | — | `tools-check`, `tools-doc-check` | `just check`; CI gates and release jobs |
| `python3` | `tests/integration/` | `test-integration` | CI matrix job (Ubuntu) |
| `dash` | — | `test` | `just check`; CI gates and release jobs |
<!-- tools:end -->
