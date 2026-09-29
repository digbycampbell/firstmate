#!/usr/bin/env bash
# tests/fm-herdr-presentation-lock.test.sh - fm_backend_herdr_presentation_order_lock_wait
# (bin/backends/herdr.sh) serialization and refusal behavior. Split out of
# tests/fm-backend-herdr.test.sh: these three cases each source herdr.sh (which
# lazily sources bin/fm-wake-lib.sh) in their own subshell, and keeping them
# appended to that already-large file tripled ShellCheck's peak memory for the
# whole partition. No assertion here changed in the split.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/herdr-test-safety.sh
. "$(dirname "${BASH_SOURCE[0]}")/herdr-test-safety.sh"

# These cases script a canned fake CLI; a Herdr pane identity leaked in from the
# developer's own terminal would make the adapter resolve a launcher that this
# fake never models.
herdr_forget_inherited_pane

TMP_ROOT=$(fm_test_tmproot fm-herdr-presentation-lock-tests)

# --- presentation-order serialization ---------------------------------------
#
# The guard asserts that one spawn at a time projects into a named session, NOT
# that the section completes inside a wall-clock budget. Each case drives a REAL
# lock through fm_lock_try_acquire with a real holder process, and each verifies
# the holder is genuinely holding before it asserts anything: a fixture whose
# holder quietly died would let the waiter acquire instantly and pass both cases
# vacuously, which is exactly how the first draft of these tests fooled itself.

# Start a real holder for <secs>. Sets PRES_HOLDER_PID. Must NOT run inside a
# command substitution: the holder would be a child of a subshell that exits.
presentation_lock_start_holder() {  # <lock> <secs>
  local lock=$1 secs=$2 ready waited=0
  ready="$TMP_ROOT/pres-ready.$RANDOM"
  bash -c '
    . "$0/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$1" || exit 1
    : > "$3"
    sleep "$2"
    fm_lock_release "$1"
  ' "$ROOT" "$lock" "$secs" "$ready" &
  # shellcheck disable=SC2031 # The assignment is in this function's own body,
  # not a subshell; the caller reads it directly after the call, and the
  # liveness assertion below would fail loudly if the pid were ever lost.
  PRES_HOLDER_PID=$!
  while [ ! -e "$ready" ] && [ "$waited" -lt 200 ]; do
    sleep 0.05
    waited=$((waited + 1))
  done
  [ -e "$ready" ] || fail "fixture holder never took the presentation lock"
  # Discriminator guard: prove the section is actually occupied by a live
  # process, so a later acquire means serialization and not an empty lock.
  [ -e "$lock" ] || fail "fixture holder reported ready but the lock is absent"
  kill -0 "$(cat "$lock/pid" 2>/dev/null)" 2>/dev/null \
    || fail "fixture holder is not alive, so the wait would prove nothing"
}

test_presentation_lock_serializes_behind_a_slow_holder() {
  local lock="$TMP_ROOT/pres-slow.lock" began elapsed rc
  presentation_lock_start_holder "$lock" 15
  began=$(date +%s)
  ( . "$ROOT/bin/backends/herdr.sh"
    FM_BACKEND_HERDR_ROOT="$ROOT" \
      fm_backend_herdr_presentation_order_lock_wait "$lock" )
  rc=$?
  elapsed=$(( $(date +%s) - began ))
  wait "$PRES_HOLDER_PID" 2>/dev/null || true
  [ "$rc" -eq 0 ] \
    || fail "a concurrent resume must serialize behind a slow holder, got rc=$rc"
  # 15s is deliberately past the retired budget. That budget was nominally
  # 50 x 0.1s = 5s but measured ~7.3s of wall clock, because each
  # fm_lock_try_acquire costs ~0.047s on top of its sleep - and it shrinks as
  # the machine loads, which is why it failed intermittently. Asserting the WAIT
  # actually happened is what makes this fail on the old implementation instead
  # of passing on an empty lock.
  [ "$elapsed" -ge 12 ] \
    || fail "the waiter returned after ${elapsed}s, so it never serialized behind the holder"
  pass "presentation lock: serializes behind a holder slower than the retired 5s budget"
}

test_presentation_lock_still_refuses_a_stuck_holder() {
  local lock="$TMP_ROOT/pres-stuck.lock" rc out
  presentation_lock_start_holder "$lock" 120
  # The deadlock backstop is what keeps this a guard rather than an open wait.
  set +e
  out=$( . "$ROOT/bin/backends/herdr.sh"
    FM_BACKEND_HERDR_ROOT="$ROOT" FM_HERDR_PRESENTATION_LOCK_WAIT_SECS=2 \
      fm_backend_herdr_presentation_order_lock_wait "$lock"
    printf 'rc=%s refusal=%s' "$?" "$FM_HERDR_PRESENTATION_LOCK_REFUSAL" )
  rc=$?
  set -e
  kill "$PRES_HOLDER_PID" 2>/dev/null || true
  wait "$PRES_HOLDER_PID" 2>/dev/null || true
  case "$out" in
    "rc=1 refusal=pid "*"still held it after 2s") ;;
    *) fail "a stuck holder must be refused and named, got '$out'" ;;
  esac
  pass "presentation lock: still refuses a holder that never finishes, naming it"
}

test_presentation_lock_explicit_cap_overrides_a_large_wait_secs() {
  local lock="$TMP_ROOT/pres-capped.lock" rc out began elapsed
  presentation_lock_start_holder "$lock" 120
  began=$(date +%s)
  set +e
  out=$( . "$ROOT/bin/backends/herdr.sh"
    FM_BACKEND_HERDR_ROOT="$ROOT" FM_HERDR_PRESENTATION_LOCK_WAIT_SECS=300 \
      fm_backend_herdr_presentation_order_lock_wait "$lock" 2
    printf 'rc=%s refusal=%s' "$?" "$FM_HERDR_PRESENTATION_LOCK_REFUSAL" )
  rc=$?
  set -e
  elapsed=$(( $(date +%s) - began ))
  kill "$PRES_HOLDER_PID" 2>/dev/null || true
  wait "$PRES_HOLDER_PID" 2>/dev/null || true
  case "$out" in
    "rc=1 refusal=pid "*"still held it after 2s") ;;
    *) fail "an explicit small cap must refuse and name the holder even under a large FM_HERDR_PRESENTATION_LOCK_WAIT_SECS, got '$out'" ;;
  esac
  [ "$elapsed" -lt 10 ] \
    || fail "the explicit cap did not bound the wait; returned after ${elapsed}s"
  pass "presentation lock: an explicit cap refuses within itself even when FM_HERDR_PRESENTATION_LOCK_WAIT_SECS is large"
}

test_presentation_lock_serializes_behind_a_slow_holder
test_presentation_lock_still_refuses_a_stuck_holder
test_presentation_lock_explicit_cap_overrides_a_large_wait_secs
