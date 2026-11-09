# Copyright (c) 2026 Costas Kirgoussios
#
# This software is licensed under the PolyForm Noncommercial License 1.0.0.
# You may obtain a copy of the License at:
# https://polyformproject.org/licenses/noncommercial/1.0.0/

# Justfile for rea setup scripts

# Default: run the local gate
default:
    just check

# One-time per clone: activate the pre-push hook, then verify the declared tools
setup:
    lefthook install && just tools-check

# Every declared tool is present, with an install hint for each that is not
tools-check:
    sh scripts/tools-check.sh

# Every shell file, as POSIX sh; find rather than a glob so an unmatched pattern is not passed literally
shellcheck:
    find . \( -path ./.clavity -o -path ./tests/.tmp \) -prune -o -name '*.sh' -type f -print0 | xargs -0 shellcheck -s sh

# shfmt in diff mode, POSIX dialect; any difference is a non-zero exit
fmt-check:
    find . \( -path ./.clavity -o -path ./tests/.tmp \) -prune -o -name '*.sh' -type f -print0 | xargs -0 shfmt -ln posix -i 2 -ci -d

# Rewrite shell files with the same shfmt settings
fmt:
    find . \( -path ./.clavity -o -path ./tests/.tmp \) -prune -o -name '*.sh' -type f -print0 | xargs -0 shfmt -ln posix -i 2 -ci -w

# PSScriptAnalyzer over every *.ps1 (Windows PowerShell 5.1 syntax)
psanalyze:
    pwsh -NoProfile -File scripts/psanalyze.ps1

# Spell check
typos:
    typos

# No comment cites another file by line number
line-citations:
    sh scripts/check-line-citations.sh

# Regenerate the tool table in CONTRIBUTING.md
tools-doc:
    sh scripts/gen-tool-table.sh

# The tool table in CONTRIBUTING.md matches .claude/recommended-tools.json
tools-doc-check:
    sh scripts/gen-tool-table.sh --check

# Every lint suppression carries a reason and the count stays within the committed baseline
suppressions:
    sh scripts/check-suppressions.sh

# The pins in setup.sh and setup.ps1 are identical and each obeys its own rule
drift:
    sh scripts/check-drift.sh && sh scripts/tests/check-drift.sh

# Every workflow `uses:` is pinned to a commit SHA
action-pins:
    sh scripts/check-action-pins.sh && sh scripts/tests/check-action-pins.sh

# Workflow syntax
actionlint:
    actionlint

# Every source file carries header.txt
license-check:
    addlicense -check -f header.txt -ignore '.clavity/**' -ignore 'docs/**' -ignore 'tests/fixtures/**' -ignore 'scripts/suppressions.baseline' -ignore 'scripts/ci-tools.lock' -ignore 'testResults.xml' .

# Unit tests: shell tests under dash and bash, then Pester (zero test files is a failure)
test: test-sh test-pester

# The shell tests, under each of dash, bash and /bin/sh that exists
test-sh:
    sh tests/sh/run.sh

# The Pester tests (zero test files is a failure)
test-pester:
    pwsh -NoProfile -Command "if (@(Get-ChildItem -Path tests/pester -Filter *.Tests.ps1 -File).Count -eq 0) { exit 1 }; Import-Module Pester -MinimumVersion 5.0; Invoke-Pester -Path tests/pester -CI"

# Integration tests against a local fake release server (not part of check)
test-integration:
    sh tests/integration/run.sh
    sh tests/integration/e2e.sh
    pwsh -NoProfile -File tests/integration/run-win.ps1

# The local gate, cheapest first
check: tools-check typos license-check line-citations action-pins actionlint fmt-check shellcheck psanalyze suppressions drift tools-doc-check test
