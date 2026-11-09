# Contributing

## One-time setup

```sh
just setup
```

This runs `lefthook install` (activating the `pre-push` hook) and then `just tools-check`, which lists any
missing tool together with its install hint.

## The gates

`just check` runs every gate, cheapest first: `tools-check`, `typos`, `license-check`, `line-citations`,
`action-pins`, `actionlint`, `fmt-check`, `shellcheck`, `psanalyze`, `suppressions`, `tools-doc-check`,
`test`. The `pre-push` hook and CI call the same recipes, so there is exactly one list. `just test-integration`
(a local fake release server) is not part of `check`; CI runs it on Ubuntu.

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
| `just` | `justfile` | — | everything: local gate, pre-push hook and CI all route through the recipes it defines |
| `lefthook` | `lefthook.yml` | `setup` | local pre-push |
| `shellcheck` | — | `shellcheck` | `just check`; CI gates job |
| `shfmt` | — | `fmt-check`, `fmt` | `just check`; CI gates job |
| `pwsh` | — | `psanalyze`, `test` | `just check`; CI gates and matrix jobs |
| `PSScriptAnalyzer` | `scripts/psanalyze.ps1` | `psanalyze` | `just check`; CI gates job |
| `Pester` | `tests/pester/` | `test` | `just check`; CI gates and matrix jobs |
| `typos` | `_typos.toml` | `typos` | `just check`; CI gates job |
| `actionlint` | — | `actionlint` | `just check`; CI gates job |
| `addlicense` | `header.txt` | `license-check` | `just check`; CI gates job |
| `jq` | — | `tools-check`, `tools-doc-check` | `just check`; CI gates job |
| `python3` | `tests/integration/` | `test-integration` | CI matrix job (Ubuntu) |
| `dash` | — | `test` | `just check`; CI |
<!-- tools:end -->
