#!/bin/sh
# Copyright (c) 2026 Costas Kirgoussios
#
# This software is licensed under the PolyForm Noncommercial License 1.0.0.
# You may obtain a copy of the License at:
# https://polyformproject.org/licenses/noncommercial/1.0.0/

# ONE DEFECT CLASS, ONE IDIOM: *a scan that produces nothing is read as clean*.
#
# Sourced, never run:
#   . "$root/scripts/lib/scan-guard.sh"
#
# THE CLASS, measured three times in this repository -- each time inside a guard written to catch a
# DIFFERENT defect, each time found by someone who was not looking for it:
#
#   scripts/gen-tool-table.sh       `jq -c '.[]' "$json" | while read ...`. jq was the LEFT-HAND SIDE of
#                                   a pipe, so its exit status was discarded -- POSIX sh has no
#                                   `pipefail` -- and malformed JSON produced a header-only table that
#                                   `--check` then compared clean against an equally empty regeneration.
#                                   Fixed in b140a18.
#   scripts/check-line-citations.sh `find ... -print0 | xargs -0 grep ... || true`. The same shape: a
#                                   missing root emptied the hit list, the reporting loop ran zero times,
#                                   and the gate certified a tree it had never read. Fixed in 068a18a.
#   sandbox/tests/probe-harness.sh  `for script in "$root"/sandbox/probes/*.sh`. POSIX sh has no
#                                   `nullglob`, so an unmatched glob passes through LITERALLY; grep was
#                                   handed a path that does not exist, exited 2, and `|| true` folded that
#                                   into the same empty result as "no match". The loop printed `ok`. It
#                                   guarded the worst defect found in its session -- twelve probe scripts
#                                   watching the harness's home instead of the agent's.
#
# It is not "someone forgot to check". A shell pipeline reports NOTHING-FOUND and BROKEN-SCAN as the same
# two things -- an empty stream, and a status nobody is in a position to look at -- while the guard above
# it is written to fail on what it FINDS. So a broken guard can only report clean, and it does so in the
# vocabulary of a passing gate.
#
# THE TWO QUESTIONS THIS FILE MAKES A CALLER ANSWER OUT LOUD:
#
#   1. WAS THERE ANYTHING TO SCAN?  `scan_expand` builds the input list and takes the answer as an
#      ARGUMENT: `must-find` (an empty list means the scan is broken -- always a failure) or
#      `may-be-empty` (the caller has a reason and says so). There is no default, and an unrecognised
#      policy word is refused, so the permissive answer cannot be given by omission or by a typo.
#      `scan_require` asks the same question of a list some other command produced, and
#      `scan_require_count` of a loop that filtered the list down to nothing after reading it.
#   2. DID THE SCANNER ITSELF FAIL?  `scan_grep` keeps grep's "no match" (status 1, a legitimate empty
#      result) apart from grep's hard errors (status 2 and up: a path that does not exist, a file that
#      cannot be read, a pattern that will not compile). `grep ... || true` folds the two together; this
#      hands the hard error back to the caller and says so on stderr.
#
# WHERE THIS LIVES, and why not sandbox/probes/text.sh -- the repository's existing shared shell helper,
# sourced by both sandbox/probes/common.sh and sandbox/transcript.sh. Three reasons, and the first is
# decisive: text.sh is sourced by common.sh, so everything in it ships into the container and is carried
# by every probe run, and none of this is probe code. Second, text.sh is scoped to one job -- turning
# captured, untrusted vendor text into something committable -- and a gate helper is not that job. Third,
# a repository gate (scripts/check-line-citations.sh) sourcing a file under sandbox/probes/ would point
# the dependency the wrong way round: the gates would depend on the probe harness. This is neither probe
# code nor any one gate's code, so it sits under scripts/lib/ and both sides source it.
#
# Nothing RUNS this file, so it needs no justfile recipe and no CI step to avoid being dead code:
# `just shellcheck` and the CI job of the same name already lint it where it is, both spelled
# `find sandbox scripts -name '*.sh' -exec shellcheck -s sh {} +`.
#
# Its own ACCEPTING AND REJECTING halves are tested in sandbox/tests/probe-harness.sh, for the reason
# written there beside the privilege-enumeration check: that suite already runs in `just check` and in CI
# and already makes assertions against source files outside itself, while a new test script would need the
# justfile and the CI workflow changed to be anything but dead code.

# scan_empty_failure <label>: the one diagnostic, so every caller refuses in the same words.
scan_empty_failure() {
  printf 'scan: found nothing to scan: %s\n' "$1" >&2
  printf 'scan: an empty scan is not a clean result, it is an unread one. Check that the path exists\n' >&2
  printf 'scan: and that the pattern still matches something before reading a pass off it.\n' >&2
  return 1
}

# scan_expand <dest> <policy> <label> <path>...
#
# Writes the paths that EXIST, one per line, to <dest>, and answers question 1 under <policy>:
#   must-find     an empty list is a broken scan. Returns non-zero.
#   may-be-empty  the caller has stated a reason for tolerating nothing. Returns zero.
# Anything else is refused outright, so a misspelt policy cannot read as the permissive one.
#
# The paths are normally a glob the CALLER expanded, which is the whole reason the literal word is
# filtered rather than trusted: POSIX sh has no `nullglob`, so an unmatched glob arrives here as its own
# pattern text. That word names nothing, so it is dropped here instead of being handed to a scanner that
# would fail on it in a way `|| true` then erases.
scan_expand() {
  scan_dest=$1
  scan_policy=$2
  scan_label=$3
  shift 3

  case "$scan_policy" in
    must-find | may-be-empty) ;;
    *)
      printf 'scan_expand: unknown empty-policy %s; use must-find or may-be-empty (%s)\n' \
        "$scan_policy" "$scan_label" >&2
      return 2
      ;;
  esac

  : >"$scan_dest"
  for scan_path in "$@"; do
    if [ -e "$scan_path" ]; then
      printf '%s\n' "$scan_path" >>"$scan_dest"
    fi
  done

  if [ "$scan_policy" = may-be-empty ]; then
    return 0
  fi
  scan_require "$scan_dest" "$scan_label"
}

# scan_require <file> <label>: question 1, for a list a COMMAND produced rather than a glob --
# `jq -c '.[]' > entries`, `find ... -print > files`. Returns non-zero, having said why, when it is empty.
scan_require() {
  if [ -s "$1" ]; then
    return 0
  fi
  scan_empty_failure "$2"
}

# scan_require_count <count> <label>: question 1 again, for the case a non-empty list does not answer.
#
# A loop that SKIPS entries can read a full list and still inspect nothing -- sandbox/probes/*.sh matches
# common.sh and text.sh, which every probe-script loop skips by name, so moving the twelve agent scripts
# aside leaves a list that is not empty and a scan that saw no probe. The count is what the caller
# actually read, so this is the question asked at the far end of the filter.
scan_require_count() {
  if [ "$1" -gt 0 ]; then
    return 0
  fi
  scan_empty_failure "$2"
}

# scan_grep <grep-arg>...: question 2. grep whose HARD ERRORS do not arrive looking like "no match".
#
# grep exits 0 for a match, 1 for no match, and 2 or more for an error -- a path that does not exist, a
# file it cannot read, a pattern it cannot compile. `grep ... || true` erases that distinction and the
# caller then reads "nothing found" off an empty stream. This returns 0 for 0 and for 1, leaving the
# caller to decide what an empty result means where it has the context to decide it, and passes anything
# above 1 back as a failure with the status and the arguments on stderr.
#
# stdout is grep's own, so a caller captures or redirects around this exactly as it would around a bare
# grep -- `$(scan_grep ...)`, `scan_grep ... >> "$hits"`.
scan_grep() {
  if grep "$@"; then
    scan_status=0
  else
    scan_status=$?
  fi
  if [ "$scan_status" -le 1 ]; then
    return 0
  fi
  printf 'scan: grep exited %s: that is a broken scan, not a clean one\n' "$scan_status" >&2
  printf 'scan:   grep %s\n' "$*" >&2
  return "$scan_status"
}
