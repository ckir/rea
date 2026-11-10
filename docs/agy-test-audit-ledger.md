# AGY-TEST-AUDIT ledger

Newest row at the bottom. Escape every pipe inside a cell as \|. This is a record, not a proof.

| date | audited range | rounds | verdict | evidence |
|---|---|---|---|---|
| 2026-11-10 | b67c1da..ff25e23 (tests and gate scripts) | 1 | GAPS FOUND, both gaps folded | Brief .clavity/seams/setup-script-test-audit.md; agy reply cascade 45b3db33-866f-4f30-86f2-8cd21d00936c. Two gaps, both verified by measurement and closed in commit cc7bb945cd679d0fbc9901ef447d5bdd21462cf2: scripts/tests/check-suppressions.sh (new, wired into just suppressions) and the missing-option-value cases in tests/sh/core.sh. Each was shown red under a logic mutant (unreasoned-suppression exit disabled, baseline cap raised, baseline validation removed, need_value bound changed). Discarded below the floor: a standalone fixture for check-line-citations.sh; full --help text matching. just check exit 0 afterwards. Test-only change, so the capstone GREEN on ff25e23 stands. Windows paths unexercised on this host. |
