#!/usr/bin/env bash
# The inherited-config re-read nudge must not manufacture a decision.
#
# The nudge tells a secondmate that inherited config changed. It asks for
# nothing back - the mate re-reads its own config at session start regardless -
# yet every marked from-firstmate send armed a parent pending-reply expectation.
# An expectation that nothing will ever satisfy decays into
#   blocked [key=pending-reply-<id>]: pending-reply-missed: ...
# and, because `pending-reply-` is a reserved decision-key namespace, no answer
# can close it (see tests/fm-send-resolve-key.test.sh). Seven of these piled up
# in a single day, every one noise.
#
# Two layers were wrong and both are covered here:
#   1. Expectation creation. A request that asks for no report must arm no
#      expectation. --no-reply-expected is that declaration.
#   2. Delivery judgement. fm-send exit 3 means "typed into the live endpoint,
#      Enter sent, read-back inconclusive" - the ordinary result when the mate
#      is mid-turn. The nudge counted it as a failure, so a landed nudge
#      produced a retry and a CONFIG_REREAD diagnostic.
#
# The bar the tests hold: a routine nudge produces no open decision, while a
# request that genuinely awaits a report still arms its expectation and still
# escalates. Assertions run through the real fm-send executable and the real
# OPEN DECISIONS consumer, never against source text.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-marker-lib.sh"

SEND="$ROOT/bin/fm-send.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-config-reread-no-decision)

# Stub tmux. FM_FAKE_TMUX_VERDICT=pending renders a composer that still holds
# text, which is how fm-send reaches its exit-3 delivered-unconfirmed verdict -
# the mid-turn mate case that drove the whole defect.
make_stubs() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    if [ "$literal" = 1 ]; then
      printf '%s' "${1:-}" >> "$FM_SEND_LOG"
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf "3\n"; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane)
    # Preceding output rows matter: a bordered composer flush against the top
    # of the screen is geometrically ambiguous and classifies as
    # pending-unproven rather than the proven `pending` this case needs.
    if [ "${FM_FAKE_TMUX_VERDICT:-empty}" = pending ]; then
      printf 'earlier output\nmore output\n╭────────────────────────────╮\n│ CONFIG_REREAD: still here  │\n╰────────────────────────────╯\n'
    else
      printf 'earlier output\nmore output\n╭────────────────────────────╮\n│                            │\n╰────────────────────────────╯\n'
    fi
    exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fb/sleep"
  chmod +x "$fb/sleep"
  printf '%s\n' "$fb"
}

setup_secondmate_home() {  # <name> <task-id> -> echoes home dir
  local home="$TMP_ROOT/$1-$RANDOM" id=$2
  mkdir -p "$home/state"
  fm_write_secondmate_meta "$home/state/$id.meta" "$home" "sess:fm-$id"
  printf '%s\n' "$home"
}

run_send() {  # <fakebin> <home> <send-log> <args...>
  local fb=$1 home=$2 log=$3; shift 3
  : > "$log"
  env PATH="$fb:$PATH" \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" "$@" 2>/dev/null
}

# assert_expectation_count <home> <expected> <msg>
assert_expectation_count() {
  local actual
  actual=$(pending_reply_count "$1")
  [ "$actual" = "$2" ] || fail "$3: expected $2 pending-reply record(s), found $actual"
}

pending_reply_count() {  # <home>
  local d="$1/state/pending-replies"
  [ -d "$d" ] || { printf '0\n'; return 0; }
  find "$d" -type f 2>/dev/null | wc -l | tr -d ' '
}

# --- 1. a no-reply-expected send arms no expectation, but is still marked -----

test_no_reply_expected_arms_no_expectation() {
  local dir fb log home rc sent
  dir="$TMP_ROOT/no-reply"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_secondmate_home no-reply sm1)

  run_send "$fb" "$home" "$log" sm1 --no-reply-expected "CONFIG_REREAD: /tmp/x"; rc=$?
  expect_code 0 "$rc" "a no-reply-expected nudge should be delivered normally"

  sent=$(cat "$log")
  assert_contains "$sent" "CONFIG_REREAD: /tmp/x" "the nudge text should reach the mate"
  # Still MARKED: the mate must recognise an operational instruction from
  # firstmate. Suppressing the expectation must not silently demote the
  # message to ordinary chat.
  case "$sent" in
    "$FM_FROMFIRST_MARK"*) ;;
    *) fail "the nudge lost its from-firstmate marker: $(printf '%q' "$sent")" ;;
  esac
  # ...but carries no correlation id, because nothing correlates back.
  printf '%s' "$sent" | grep -qE 'corr=[0-9a-f]{16}' \
    && fail "a no-reply-expected nudge still embedded a correlation id: $sent"

  assert_expectation_count "$home" 0 \
    "a no-reply-expected nudge must arm no pending-reply expectation"
  pass "fm-send --no-reply-expected: marked, delivered, and arms no expectation"
}

# --- 2. the discriminator: an ordinary marked request STILL arms one ----------
#
# Without this the test above is satisfied by any change that breaks
# expectations wholesale, including deleting the feature. Same home shape, same
# transport, one flag of difference.
test_ordinary_secondmate_request_still_arms_expectation() {
  local dir fb log home rc sent
  dir="$TMP_ROOT/ordinary"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_secondmate_home ordinary sm2)

  run_send "$fb" "$home" "$log" sm2 "report back on the migration"; rc=$?
  expect_code 0 "$rc" "an ordinary marked request should be delivered"

  sent=$(cat "$log")
  printf '%s' "$sent" | grep -qE 'corr=[0-9a-f]{16}' \
    || fail "an ordinary marked request lost its correlation id: $sent"
  assert_expectation_count "$home" 1 \
    "a request that awaits a report must still arm exactly one expectation"
  pass "fm-send: a request that awaits a report still arms its expectation"
}

# --- 3. the flag is refused where it would contradict itself -----------------

test_no_reply_expected_refuses_with_resolve_key() {
  local dir fb log home rc err
  dir="$TMP_ROOT/contradiction"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"; err="$dir/err.log"
  home=$(setup_secondmate_home contradiction sm3)
  printf 'needs-decision [key=shape]: which shape\n' > "$home/state/sm3.status"

  : > "$log"
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
    FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" sm3 --resolve-key shape --no-reply-expected "pick A" >/dev/null 2>"$err"; rc=$?

  [ "$rc" -ne 0 ] || fail "--no-reply-expected with --resolve-key should refuse"
  assert_contains "$(cat "$err")" "cannot accompany --resolve-key" \
    "the refusal should name the contradiction"
  [ ! -s "$log" ] || fail "a refused contradictory send still delivered text: $(cat "$log")"
  pass "fm-send --no-reply-expected: refuses alongside --resolve-key"
}

# --- 4. end to end: a routine nudge leaves no open decision -------------------
#
# Drives the real nudge path in bin/fm-config-inherit-lib.sh against a mid-turn
# mate (the exit-3 case), then asks the real OPEN DECISIONS consumer whether
# anything was left behind. Before the fix this left both a CONFIG_REREAD retry
# report and, once the expectation aged, an unclosable blocked decision.
test_routine_nudge_leaves_no_open_decision() {
  local dir fb log home rc out instruction
  dir="$TMP_ROOT/e2e"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_secondmate_home e2e sm4)

  instruction="$home/state/.fm-inherited-config-reread.1"
  printf 'these inherited files changed\n' > "$instruction"
  printf '%s\n' "$instruction" > "$instruction.pending"

  # shellcheck source=/dev/null
  out=$(
    set +u
    . "$ROOT/bin/fm-config-inherit-lib.sh"
    export PATH="$fb:$PATH" FM_SEND_LOG="$log" FM_SEND_SETTLE=0
    export FM_HOME="$home" FM_ROOT_OVERRIDE="$home"
    # A mate mid-turn: text lands, submit read-back is inconclusive (exit 3).
    export FM_FAKE_TMUX_VERDICT=pending
    fm_config_reread_send_pointer sm4 "$instruction" 2>&1
  ) && rc=0 || rc=$?

  expect_code 0 "$rc" \
    "a nudge delivered to a mid-turn mate is delivered, not failed (fm-send exit 3)"
  printf '%s' "$out" | grep -F 'send failed' >/dev/null \
    && fail "a delivered nudge was reported as a send failure: $out"
  [ ! -f "$instruction.pending" ] \
    || fail "a delivered nudge left a retry pointer behind, so it would be re-sent"
  assert_expectation_count "$home" 0 \
    "the routine nudge must arm no expectation to decay into a decision"

  out=$(FM_STATE_OVERRIDE="$home/state" "$DRAIN" 2>/dev/null)
  if printf '%s' "$out" | grep -F 'OPEN DECISIONS' >/dev/null; then
    fail "a routine config re-read produced an open decision: $out"
  fi
  pass "config re-read nudge: a routine nudge to a mid-turn mate leaves no open decision"
}

test_no_reply_expected_arms_no_expectation
test_ordinary_secondmate_request_still_arms_expectation
test_no_reply_expected_refuses_with_resolve_key
test_routine_nudge_leaves_no_open_decision
