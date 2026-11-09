#!/bin/sh
# Copyright (c) 2026 Costas Kirgoussios
#
# This software is licensed under the PolyForm Noncommercial License 1.0.0.
# You may obtain a copy of the License at:
# https://polyformproject.org/licenses/noncommercial/1.0.0/

# Runs every tests/sh/*.sh except lib.sh and run.sh under each named shell, or under each of dash, bash
# and /bin/sh that exists when none is named. Prints one `ok <shell> <file>` per pair. Fails on a zero
# file count or a zero shell count (must-find).
#
# Usage: sh tests/sh/run.sh [SHELL...]
set -eu

here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

shells=""
if [ $# -gt 0 ]; then
  for s in "$@"; do
    shells="$shells $s"
  done
else
  for s in dash bash /bin/sh; do
    if command -v "$s" >/dev/null 2>&1; then
      shells="$shells $s"
    fi
  done
fi
if [ -z "$shells" ]; then
  echo "run.sh: no shell found to run the tests under" >&2
  exit 1
fi

files=""
for f in "$here"/*.sh; do
  [ -f "$f" ] || continue
  case "$(basename "$f")" in
    lib.sh | run.sh) continue ;;
  esac
  files="$files $f"
done
if [ -z "$files" ]; then
  echo "run.sh: no test files found in $here" >&2
  exit 1
fi

failed=0
for s in $shells; do
  for f in $files; do
    if "$s" "$f" >/dev/null; then
      echo "ok $s $(basename "$f")"
    else
      echo "FAIL $s $(basename "$f")" >&2
      "$s" "$f" >&2 || true
      failed=1
    fi
  done
done
exit "$failed"
