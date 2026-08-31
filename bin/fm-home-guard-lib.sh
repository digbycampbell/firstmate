#!/usr/bin/env bash
# fm-home-guard-lib.sh - refuse, at the point of resolution, to operate on a
# firstmate home outside the behavior suite's sandbox.
#
# Completely inert unless FM_TEST_SANDBOX is set, which only
# bin/fm-test-sandbox-lib.sh does. Production runs never reach the check.
#
# Why the check lives here rather than in the runner: filesystem writes cannot
# be attributed to a process tree after the fact. A live firstmate home moves
# its own .wake-queue and watcher beats while the suite runs, so a before/after
# diff of that home blames the test for the fleet's heartbeat - measured, not
# assumed, on 2026-08-31. Refusing at the moment a script resolves its state
# directory is attributable by construction: the refusing process IS the writer,
# it names itself, and there is nothing to infer.
#
# Every bin/fm-*.sh that resolves `STATE` from FM_STATE_OVERRIDE/FM_HOME sources
# either fm-pr-lib.sh or fm-wake-lib.sh after that assignment, and both call
# this guard, so the check reaches all of them from one place. A new script that
# resolves a home and sources neither is outside the guard;
# tests/fm-test-sandbox.test.sh asserts that no such script exists.

# fm_home_guard_assert <state-dir>
# Dies when <state-dir> resolves outside the running test's sandbox.
fm_home_guard_assert() {
  local state=${1:-} sandbox=${FM_TEST_SANDBOX:-} own=${FM_TEST_OWN_ROOT:-} resolved parent
  [ -n "$sandbox" ] || return 0
  [ -n "$state" ] || return 0

  # Resolve without requiring the directory to exist yet: scripts routinely
  # mkdir their state dir after this point.
  #
  # Split the path with parameter expansion rather than `dirname`/`basename`.
  # This guard is sourced by libraries that real scripts load near the top of
  # their startup, so every external command it runs is a side effect imposed on
  # the whole fleet. tests/fm-pr-check-security.test.sh stubs `basename` as a
  # timing gate to prove a migration excludes an older watcher BEFORE it does any
  # other work; a `basename` call in here opened that gate early and made the
  # migration look racy when it was not. A guard must not perturb what it
  # watches, so it spawns no process.
  local dirpart basepart
  while [ "${state%/}" != "$state" ] && [ "$state" != / ]; do state=${state%/}; done
  basepart=${state##*/}
  if [ "$state" = "$basepart" ]; then
    dirpart=.
  else
    dirpart=${state%/*}
    [ -n "$dirpart" ] || dirpart=/
  fi
  parent=$(CDPATH='' cd -- "$dirpart" 2>/dev/null && pwd -P) || return 0
  [ "$parent" = / ] && parent=""
  resolved="$parent/$basepart"

  case "$resolved/" in
    "$sandbox"/*) return 0 ;;
  esac
  # The checkout the suite is running FROM is a home it owns, and with the FM_*
  # namespace cleared that is exactly what a firstmate script falls back to. The
  # boundary being enforced is "a home it does not own", so refusing the running
  # checkout would refuse the legitimate default and break every test that
  # exercises a real script's own default home.
  if [ -n "$own" ]; then
    case "$resolved/" in
      "$own"/*) return 0 ;;
    esac
  fi

  printf 'fm-home-guard: ISOLATION FAILURE - %s resolved its firstmate home to %s, which is outside the test sandbox %s.\n' \
    "${BASH_SOURCE[${#BASH_SOURCE[@]} - 1]:-a firstmate script}" "$resolved" "$sandbox" >&2
  printf 'fm-home-guard: a test must pass a fixture home it created. FM_STATE_OVERRIDE is read AHEAD of FM_HOME, so an ambient override silently wins over the FM_HOME a test passes explicitly.\n' >&2
  printf 'fm-home-guard: FM_HOME=%s FM_STATE_OVERRIDE=%s FM_ROOT_OVERRIDE=%s\n' \
    "${FM_HOME:-<unset>}" "${FM_STATE_OVERRIDE:-<unset>}" "${FM_ROOT_OVERRIDE:-<unset>}" >&2
  exit 99
}
