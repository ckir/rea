#!/bin/sh
# Copyright (c) 2026 Costas Kirgoussios
#
# This software is licensed under the PolyForm Noncommercial License 1.0.0.
# You may obtain a copy of the License at:
# https://polyformproject.org/licenses/noncommercial/1.0.0/

# Generates the "## Tools" table in CONTRIBUTING.md from .claude/recommended-tools.json, so the
# two lists (the doc a human reads, the JSON a hook reads) cannot drift apart the way they already had:
# `just` had no doc row despite gating everything, and Sandboxie-Plus — the sandbox that enforces
# "coding agents are never installed on the host" — was missing from the doc entirely.
#
# Usage:
#   sh scripts/gen-tool-table.sh          # rewrite CONTRIBUTING.md in place
#   sh scripts/gen-tool-table.sh --check  # verify CONTRIBUTING.md is up to date; no writes
set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
# The repository's one answer to "a scan that produces nothing is read as clean" -- the class this
# generator was the FIRST measured instance of. The refusal below used to be spelled out by hand here.
. "$repo_root/scripts/lib/scan-guard.sh"
json="$repo_root/.claude/recommended-tools.json"
doc="$repo_root/CONTRIBUTING.md"
begin_marker='<!-- tools:begin — generated from .claude/recommended-tools.json by scripts/gen-tool-table.sh; do not edit by hand -->'
end_marker='<!-- tools:end -->'

check=0
case "${1:-}" in
  --check) check=1 ;;
  "") ;;
  *)
    echo "usage: $0 [--check]" >&2
    exit 2
    ;;
esac

command -v jq >/dev/null 2>&1 || {
  echo "gen-tool-table.sh: jq is required" >&2
  exit 1
}

[ -r "$json" ] || {
  echo "gen-tool-table.sh: cannot read $json" >&2
  exit 1
}
[ -r "$doc" ] || {
  echo "gen-tool-table.sh: cannot read $doc" >&2
  exit 1
}

# Escapes a literal pipe so it cannot be mistaken for a table column separator.
escape_pipe() {
  printf '%s' "$1" | sed 's/|/\\|/g'
}

table_file=$(mktemp)
entries=$(mktemp)
trap 'rm -f "$table_file" "$entries" "${new_doc:-}"' EXIT

# jq is pulled out of the pipeline and into its own statement so `set -e` can see its exit status —
# as the right-hand side of a pipe, a stream-level jq failure (e.g. truncated JSON) was silently
# discarded and the while loop below just ran zero times, producing a header-only table that
# --check would then compare clean against an equally-empty regeneration.
# A filter that legitimately selects nothing is the other half of the same class: the JSON parses, jq
# exits 0, and the table is silently wiped in write mode and compared clean against nothing in --check.
# Refusing an empty entry list is the shared `must-find` policy, spelled the same way in every gate.
jq -c '.[]' "$json" >"$entries"
scan_require "$entries" "entries in $json" || exit 1

{
  printf '%s\n' "$begin_marker"
  # shellcheck disable=SC2016 # literal backticks in the markdown header, not command substitution
  printf '| Tool | Config | `just` recipe | Gates |\n'
  printf '|---|---|---|---|\n'
  while IFS= read -r entry; do
    name=$(printf '%s' "$entry" | jq -r '.name // empty')
    config=$(printf '%s' "$entry" | jq -r '.config // "—"')
    just_recipe=$(printf '%s' "$entry" | jq -r '.just // "—"')
    gates=$(printf '%s' "$entry" | jq -r '.gates // "—"')

    name=$(escape_pipe "$name")
    config=$(escape_pipe "$config")
    just_recipe=$(escape_pipe "$just_recipe")
    gates=$(escape_pipe "$gates")

    # shellcheck disable=SC2016 # literal backtick around $name is markdown code-span syntax, not expansion
    printf '| `%s` | %s | %s | %s |\n' "$name" "$config" "$just_recipe" "$gates"
  done <"$entries"
  printf '%s\n' "$end_marker"
} >"$table_file"

# Splice table_file between the markers in the doc. awk keeps everything outside the markers
# byte-for-byte and drops whatever was between them before (regenerated content, not hand-written).
new_doc=$(mktemp)
awk -v table_file="$table_file" '
  BEGIN { in_block = 0; printed = 0 }
  /^<!-- tools:begin/ {
    in_block = 1
    while ((getline line < table_file) > 0) print line
    close(table_file)
    printed = 1
    next
  }
  /^<!-- tools:end/ {
    in_block = 0
    next
  }
  in_block { next }
  { print }
  END {
    if (!printed) {
      print "gen-tool-table.sh: no tools:begin/tools:end markers found in CONTRIBUTING.md" > "/dev/stderr"
      exit 1
    }
  }
' "$doc" >"$new_doc"

if [ "$check" -eq 1 ]; then
  # Compare with CRLF stripped on both sides: core.autocrlf=true (this repo's config) checks docs/
  # out as CRLF even though the git object — and this script's own output — is LF, and that alone
  # must never register as drift.
  old_normalized=$(mktemp)
  new_normalized=$(mktemp)
  tr -d '\r' <"$doc" >"$old_normalized"
  tr -d '\r' <"$new_doc" >"$new_normalized"
  if diff -u "$old_normalized" "$new_normalized" >/dev/null 2>&1; then
    rm -f "$old_normalized" "$new_normalized"
    exit 0
  else
    echo "CONTRIBUTING.md is out of date with .claude/recommended-tools.json." >&2
    echo "Run: just tools-doc" >&2
    diff -u "$old_normalized" "$new_normalized" >&2 || true
    rm -f "$old_normalized" "$new_normalized"
    exit 1
  fi
else
  cp "$new_doc" "$doc"
fi
