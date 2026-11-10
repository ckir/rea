#!/bin/sh
# Copyright (c) 2026 Costas Kirgoussios
#
# This software is licensed under the PolyForm Noncommercial License 1.0.0.
# You may obtain a copy of the License at:
# https://polyformproject.org/licenses/noncommercial/1.0.0/

# Offline Markdown link check: every relative link in a *.md file must point at a file or directory that
# exists, and a `#fragment` into a Markdown file must match one of its headings (GitHub's slug rule). Links
# with a scheme (https:, mailto:) are not fetched here; the weekly canary checks those with lychee.
# Fenced code blocks and inline code spans are ignored.
#
# Usage: sh scripts/check-md-links.sh [ROOT]   (ROOT defaults to the repository root)
set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
. "$repo_root/scripts/lib/scan-guard.sh"
root=${1:-$repo_root}
root=$(CDPATH='' cd -- "$root" && pwd)

files=$(mktemp)
found=$(mktemp)
slugs=$(mktemp)
trap 'rm -f "$files" "$found" "$slugs"' EXIT

find "$root" \( -path "$root/.clavity" -o -path "$root/tests/.tmp" -o -path "$root/.git" -o -path "$root/.superpowers" -o -path "$root/docs/superpowers" \) -prune \
  -o -name '*.md' -type f -print >"$files"
scan_require "$files" "*.md files under $root" || exit 1

# awk_scan FILE: prints `L<TAB>line<TAB>target` per link and `H<TAB>slug` per heading, skipping code.
awk_scan() {
  awk '
    /^[ \t]*(```|~~~)/ { fence = !fence; next }
    fence { next }
    /^#{1,6}[ \t]+/ {
      h = $0
      sub(/^#+[ \t]+/, "", h)
      sub(/[ \t]+#+[ \t]*$/, "", h)
      h = tolower(h)
      gsub(/[^a-z0-9 _-]/, "", h)
      gsub(/ /, "-", h)
      print "H\t" h
    }
    {
      line = $0
      gsub(/`[^`]*`/, "", line)
      if (match(line, /^[ ]{0,3}\[[^]]+\]:[ \t]+[^ \t]+/)) {
        d = substr(line, RSTART, RLENGTH)
        sub(/^[ ]{0,3}\[[^]]+\]:[ \t]+/, "", d)
        print "L\t" NR "\t" d
      }
      while (match(line, /\]\([^)]*\)/)) {
        t = substr(line, RSTART + 2, RLENGTH - 3)
        line = substr(line, RSTART + RLENGTH)
        sub(/[ \t].*$/, "", t)
        gsub(/^<|>$/, "", t)
        if (t != "") print "L\t" NR "\t" t
      }
    }
  ' "$1"
}

broken=0
checked=0
while IFS= read -r md; do
  [ -n "$md" ] || continue
  rel=${md#"$root"/}
  dir=$(dirname -- "$md")
  if ! awk_scan "$md" >"$found"; then
    echo "check-md-links: could not read $rel, so this scan is broken, not clean." >&2
    exit 1
  fi
  while IFS="	" read -r kind a b; do
    [ "$kind" = L ] || continue
    target=$b
    case "$target" in
      [a-zA-Z]*:*) continue ;;
    esac
    checked=$((checked + 1))
    path=${target%%#*}
    frag=
    case "$target" in
      *'#'*) frag=${target#*#} ;;
    esac
    path=${path%%\?*}
    if [ -z "$path" ]; then
      dest=$md
    else
      case "$path" in
        /*) dest="$root$path" ;;
        *) dest="$dir/$path" ;;
      esac
      if [ ! -e "$dest" ]; then
        echo "check-md-links: $rel:$a broken link: $target (no such file or directory)" >&2
        broken=$((broken + 1))
        continue
      fi
    fi
    if [ -n "$frag" ] && [ -f "$dest" ]; then
      case "$dest" in
        *.md)
          if ! awk_scan "$dest" >"$slugs"; then
            echo "check-md-links: could not read ${dest#"$root"/}, so this scan is broken, not clean." >&2
            exit 1
          fi
          want=$(printf '%s' "$frag" | tr '[:upper:]' '[:lower:]')
          hit=0
          while IFS="	" read -r k s _; do
            if [ "$k" = H ] && [ "$s" = "$want" ]; then
              hit=1
              break
            fi
          done <"$slugs"
          if [ "$hit" -eq 0 ]; then
            echo "check-md-links: $rel:$a broken anchor: $target (no heading with that slug)" >&2
            broken=$((broken + 1))
          fi
          ;;
      esac
    fi
  done <"$found"
done <"$files"

echo "check-md-links: $checked relative link(s) checked"
[ "$broken" -eq 0 ] || exit 1
