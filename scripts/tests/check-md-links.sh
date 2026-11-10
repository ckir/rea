#!/bin/sh
# Copyright (c) 2026 Costas Kirgoussios
#
# This software is licensed under the PolyForm Noncommercial License 1.0.0.
# You may obtain a copy of the License at:
# https://polyformproject.org/licenses/noncommercial/1.0.0/

# Tests for scripts/check-md-links.sh, the offline Markdown link gate. Each case is its own tree under a
# temporary directory; the gate takes that tree as its ROOT argument. A broken link must be named with its
# file and line, and a tree with no Markdown at all must fail rather than report clean.

set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
failures=0
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

check() {
  if [ "$2" = "$3" ]; then
    echo "ok   - $1"
  else
    echo "FAIL - $1: expected '$3', got '$2'"
    failures=$((failures + 1))
  fi
}

has() {
  case "$2" in
    *"$3"*) echo "ok   - $1" ;;
    *)
      echo "FAIL - $1: output lacks '$3': $2"
      failures=$((failures + 1))
      ;;
  esac
}

lacks() {
  case "$2" in
    *"$3"*)
      echo "FAIL - $1: output has '$3': $2"
      failures=$((failures + 1))
      ;;
    *) echo "ok   - $1" ;;
  esac
}

# run <dir>: sets out and status.
run() {
  set +e
  out=$(sh "$root/scripts/check-md-links.sh" "$1" 2>&1)
  status=$?
  set -e
}

# tree <name>: a fresh directory. Sets dir.
tree() {
  dir="$tmp/$1"
  mkdir -p "$dir"
}

# good links of every kind pass: file, directory, anchor in another file, anchor in the same file, query, absolute, reference style
tree good
mkdir -p "$dir/docs/sub"
printf '# Guide\n\n## Step One: install (fast)\n\ntext\n' >"$dir/docs/guide.md"
printf 'x\n' >"$dir/docs/data.txt"
{
  printf '# Top\n\n'
  printf '[file](docs/data.txt) [dir](docs/sub) [anchor](docs/guide.md#step-one-install-fast)\n'
  printf '[self](#top) [query](docs/data.txt?raw=1) [abs](/docs/guide.md) [ref][r]\n\n'
  printf '[r]: docs/data.txt "title"\n'
} >"$dir/README.md"
run "$dir"
check "valid relative links pass" "$status" 0
has "the checked count is printed" "$out" "7 relative link(s) checked"

# a missing file is named with its file and line
tree missing
printf '# T\n\nsee [gone](docs/nope.md) here\n' >"$dir/README.md"
run "$dir"
check "a missing target fails" "$status" 1
has "the file and line are named" "$out" "README.md:3 broken link: docs/nope.md"

# a missing anchor in an existing Markdown file fails
tree anchor
printf '# Guide\n' >"$dir/g.md"
printf '[x](g.md#not-there)\n' >"$dir/README.md"
run "$dir"
check "a missing anchor fails" "$status" 1
has "the anchor is named" "$out" "broken anchor: g.md#not-there"

# an anchor into a non-Markdown file is not checked (line anchors on source files are common)
tree srcanchor
printf 'x\n' >"$dir/s.sh"
printf '[x](s.sh#L10)\n' >"$dir/README.md"
run "$dir"
check "an anchor into a source file passes" "$status" 0

# links inside fenced code and inline code are not links
tree code
bt='`'
{
  printf '# T\n\n%s%s%s\n[x](missing-in-fence.md)\n%s%s%s\n\n' "$bt" "$bt" "$bt" "$bt" "$bt" "$bt"
  printf 'inline %s[y](missing-inline.md)%s text\n' "$bt" "$bt"
} >"$dir/README.md"
run "$dir"
check "links in code are ignored" "$status" 0
lacks "no code link is reported" "$out" "missing-"

# links with a scheme are left to the external checker
tree external
printf '[w](https://example.invalid/x) [m](mailto:a@example.invalid)\n' >"$dir/README.md"
run "$dir"
check "external links are not fetched or flagged" "$status" 0
has "none counted as relative" "$out" "0 relative link(s) checked"

# a heading with the same slug in a different file does not satisfy the anchor
tree otherfile
printf '# Alpha\n' >"$dir/a.md"
printf '# Beta\n' >"$dir/b.md"
printf '[x](a.md#beta)\n' >"$dir/README.md"
run "$dir"
check "an anchor is looked up in the target file only" "$status" 1

# a tree with no Markdown must fail, not pass
tree empty
run "$dir"
check "a tree with no Markdown fails" "$status" 1

if [ "$failures" -ne 0 ]; then
  echo "$failures failure(s)"
  exit 1
fi
echo "all check-md-links tests passed"
