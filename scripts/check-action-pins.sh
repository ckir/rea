#!/bin/sh
# Copyright (c) 2026 Costas Kirgoussios
#
# This software is licensed under the PolyForm Noncommercial License 1.0.0.
# You may obtain a copy of the License at:
# https://polyformproject.org/licenses/noncommercial/1.0.0/

# Fails when a `uses:` in a workflow is not pinned to a full commit SHA.
#
# THE RULE: every `uses:` under .github/workflows/ is `<owner>/<repo>[/<path>]@<40 lower-case hex> # <ref>`.
# A job-level `uses: ./...` (a local reusable workflow) is exempt: it is this repository's own code at the
# same commit. Everything else, including a `docker://` reference, is refused.
#
# WHY THE SHA MUST BE THE REF AND NOT THE COMMENT: a tag or a branch is a pointer that its owner can move
# after review, so `@v7 # 3d3c42e...` still runs whatever `v7` points at today and only LOOKS pinned. The
# anchored pattern below therefore requires the 40-hex string directly after the `@`, and the `# <ref>`
# comment only after it, so the human-readable version stays next to the immutable one.
#
# This is a SYNTACTIC check. It cannot tell a real commit from a mistyped one; resolving each SHA against
# its repository is a separate, manual step done when a pin is written or bumped.
#
# FAIL CLOSED ON SHAPE: the scan is not a YAML parser, so it does not enumerate the shapes a `uses` key can
# take; it flags every non-comment line where `uses` appears as a key token (after line start, whitespace,
# `{`, `,`, `[` or `-`, optionally quoted, optionally followed by blanks before the colon). Each such line
# must then be the canonical form: an unquoted `uses:` key with no space before the colon, one value per
# line, optionally after `-` and any blanks. Quoted keys, `uses :`, flow `{ uses: ... }` and `[ uses: ... ]`
# are refused outright, even with a full SHA, so a floating action cannot hide beside a pinned one.
#
# Two more spellings are refused for the same reason. The key match ignores case, and `canon` below does not,
# so `Uses:` and `USES:` fail (the runner matches keys exactly, so they would not run, but this gate does not
# vouch for them). A YAML explicit key (`? uses` with its `: value` on the next line) is the `uses` key to a
# parser yet has no colon on its own line, so every explicit-key indicator line is flagged.
# A double-quoted key can spell `uses` with an escape (a \u0075 for the u) that no match for the word can see, yet a
# parser reads it as the key. So any closed double-quoted token followed by a colon is flagged, wherever it sits on
# the line. Single-quoted scalars have no escapes, so a literal 'uses' is already caught by the key match.
#
# Usage: sh scripts/check-action-pins.sh [dir]   (default: <repo>/.github/workflows)
# Output: one `<file>:<line>: <text>` per violation and exit 1; otherwise `check-action-pins: <n> uses checked`.

set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
. "$repo_root/scripts/lib/scan-guard.sh"

dir=${1:-$repo_root/.github/workflows}
scan='(^|[[:space:]{,[-])["'"'"']?uses["'"'"']?[[:space:]]*:|^[[:space:]]*(-[[:space:]]+)*\?([[:space:]]|$)|"[^"]+"[[:space:]]*:'
canon='^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]+'
pin='^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(/[^@ ]+)?@[0-9a-f]{40} # [A-Za-z0-9_.-]+$'

files=$(mktemp)
hits=$(mktemp)
trap 'rm -f "$files" "$hits"' EXIT INT TERM

checked=0
violations=0

scan_expand "$files" must-find "workflow files under $dir" "$dir"/*.yml

while IFS= read -r file; do
  scan_grep -n -i -E "$scan" "$file" >"$hits"
  # Read from a file, never a pipe: a pipe runs the loop in a subshell and loses the counters.
  while IFS= read -r hit; do
    lineno=${hit%%:*}
    text=${hit#*:}
    case "$text" in
      [[:space:]]*#* | '#'*)
        trimmed=$(printf '%s\n' "$text" | sed -E 's/^[[:space:]]+//')
        case "$trimmed" in '#'*) continue ;; esac
        ;;
    esac
    checked=$((checked + 1))
    if ! printf '%s\n' "$text" | grep -qE "$canon"; then
      trimmed=$(printf '%s\n' "$text" | sed -E 's/^[[:space:]]+//')
      printf '%s:%s: %s\n' "$file" "$lineno" "$trimmed"
      violations=1
      continue
    fi
    value=$(printf '%s\n' "$text" | sed -E 's/^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]+//; s/[[:space:]]+$//')
    case "$value" in
      ./*) continue ;;
    esac
    if ! printf '%s\n' "$value" | grep -qE "$pin"; then
      trimmed=$(printf '%s\n' "$text" | sed -E 's/^[[:space:]]+//')
      printf '%s:%s: %s\n' "$file" "$lineno" "$trimmed"
      violations=1
    fi
  done <"$hits"
done <"$files"

scan_require_count "$checked" "uses: lines under $dir"

if [ "$violations" -ne 0 ]; then
  exit 1
fi
printf 'check-action-pins: %s uses checked\n' "$checked"
