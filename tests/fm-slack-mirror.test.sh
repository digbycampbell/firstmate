#!/usr/bin/env bash
# Behavior tests for the terminal-to-Slack mirror.
#
# The mirror is driven exactly as Claude drives it: a Stop payload on stdin
# naming a real transcript file. Slack is replaced by a fake `curl` on PATH that
# records the request body, so what would actually be posted is asserted rather
# than inferred, and nothing here touches the network. Delivery runs inline
# (FM_SLACK_MIRROR_SYNC=1) so each case is deterministic.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MIRROR="$ROOT/bin/fm-slack-mirror.sh"
POST="$ROOT/bin/fm-slack-post.sh"
TMP_ROOT=$(fm_test_tmproot fm-slack-mirror)
trap fm_test_cleanup EXIT
export TMPDIR="$TMP_ROOT/tmp"
mkdir -p "$TMPDIR"

CHANNEL=C0TESTCHAN
CAPTAIN=U0CAPTAIN
BOT=U0BOTUSER

FAKEBIN=$(fm_fakebin "$TMP_ROOT")
cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
# Stand-in for chat.postMessage: records the request body and serves a canned
# success into whatever -o names.
set -u
out=
prev=
for arg in "$@"; do
  [ "$prev" = -o ] && out=$arg
  case "$arg" in
    @*) [ "$prev" = --data-binary ] && cat "${arg#@}" >> "$FAKE_POST_BODY" ;;
  esac
  prev=$arg
done
cat >/dev/null
[ -n "$out" ] || exit 1
printf '{"ok":true,"ts":"500.000500"}\n' > "$out"
exit "${FAKE_CURL_EXIT:-0}"
SH
chmod +x "$FAKEBIN/curl"
export PATH="$FAKEBIN:$PATH"
export FAKE_POST_BODY="$TMP_ROOT/post.body.json"
export FM_SLACK_MIRROR_SYNC=1

# A home that satisfies the primary-scope predicate the hook shares with the
# turn-end guard: a plain checkout with AGENTS.md, bin/, and a state dir.
new_home() {  # <name> [--no-captain]
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/config" "$home/bin"
  printf '# firstmate\n' > "$home/AGENTS.md"
  git -C "$home" init -q
  printf 'SLACK_BOT_TOKEN=xoxb-fake-000-supersecret\n' > "$home/.env"
  chmod 600 "$home/.env"
  if [ "${2-}" != --no-captain ]; then
    {
      printf 'channel=%s\n' "$CHANNEL"
      printf 'bot_user=%s\n' "$BOT"
      printf 'allowed_user=%s\n' "$CAPTAIN"
    } > "$home/config/slack-captain"
  fi
  printf '%s\n' "$home"
}

# One transcript holding a captain prompt and firstmate's reply to it, in the
# shape Claude writes: JSONL entries with a timestamp, an isSidechain flag, and
# typed content blocks.
write_transcript() {  # <path> <user-text> <assistant-text> [--sidechain-reply]
  local path=$1 user=$2 reply=$3 mode=${4-}
  jq -n --arg text "$user" '{
      type: "user", isSidechain: false, timestamp: "2026-08-21T10:00:00.000Z",
      message: {role: "user", content: [{type: "text", text: $text}]}
    }' -c > "$path"
  jq -n -c '{
      type: "assistant", isSidechain: false, timestamp: "2026-08-21T10:00:01.000Z",
      message: {model: "claude-opus-5", content: [{type: "thinking", thinking: "private"}]},
      effort: "low"
    }' >> "$path"
  jq -n -c '{
      type: "assistant", isSidechain: false, timestamp: "2026-08-21T10:00:02.000Z",
      message: {model: "claude-opus-5", content: [{type: "tool_use", name: "Bash", input: {}}]},
      effort: "low"
    }' >> "$path"
  if [ "$mode" = --sidechain-reply ]; then
    jq -n --arg text "$reply" -c '{
        type: "assistant", isSidechain: true, timestamp: "2026-08-21T10:00:03.000Z",
        message: {model: "claude-sonnet-5", content: [{type: "text", text: $text}]},
        effort: "low"
      }' >> "$path"
    return 0
  fi
  jq -n --arg text "$reply" -c '{
      type: "assistant", isSidechain: false, timestamp: "2026-08-21T10:00:03.000Z",
      message: {model: "claude-opus-5", content: [{type: "text", text: $text}]},
      effort: "low"
    }' >> "$path"
}

# Fire the Stop hook exactly as Claude does and report its exit status.
run_stop() {  # <home> <transcript> [extra env assignments...]
  local home=$1 transcript=$2
  shift 2
  : > "$FAKE_POST_BODY"
  env FM_ROOT_OVERRIDE="$home" "$@" \
    "$MIRROR" stop <<EOF
{"hook_event_name":"Stop","session_id":"s-1","stop_hook_active":false,"transcript_path":"$transcript","cwd":"$home"}
EOF
}

# The realistic shape of a captain Slack message reaching firstmate: the turn is
# opened by a watcher wake naming the exact captured result, never by the
# captain's raw text. This is the surface auto-detect reads.
wake_trigger() {  # <source-id> <sequence>
  printf 'firstmate watcher wake - one supervision event needs a handling turn now.\ncheck: process-event result captured: procevent:%s:%s\ncheck: procevent slack-captain %s %s\n' \
    "$1" "$2" "$1" "$2"
}

# Fire the Stop hook with a payload-carried final message and no readable
# transcript, so the turn's trigger cannot be read at all: the last-resort
# newest-inbound fallback path.
run_stop_payload() {  # <home> <reply-text> [extra env assignments...]
  local home=$1 reply=$2
  shift 2
  : > "$FAKE_POST_BODY"
  env FM_ROOT_OVERRIDE="$home" "$@" "$MIRROR" stop <<EOF
{"hook_event_name":"Stop","transcript_path":"$home/absent.jsonl","cwd":"$home","last_assistant_message":$(jq -Rn --arg r "$reply" '$r')}
EOF
}

posted_text() { jq -r 'select(has("text")) | .text' "$FAKE_POST_BODY" 2>/dev/null; }
posted_thread() { jq -r '.thread_ts // ""' "$FAKE_POST_BODY" 2>/dev/null; }
posted_count() { jq -s 'length' "$FAKE_POST_BODY" 2>/dev/null; }

# --- a substantive reply reaches Slack with no hand-written post -------------

test_substantive_reply_is_mirrored() {
  local home out status
  home=$(new_home substantive)
  write_transcript "$home/t.jsonl" 'where is the fix?' \
    'Captain, the fix is up for review: https://github.com/x/y/pull/12 and checks are green.'
  out=$(run_stop "$home" "$home/t.jsonl" 2>&1)
  status=$?
  expect_code 0 "$status" "the mirror must never fail a turn"
  [ -z "$out" ] || fail "the mirror printed to the turn: $out"
  [ "$(posted_count)" = 1 ] || fail "a substantive reply was not mirrored"
  assert_contains "$(posted_text)" 'https://github.com/x/y/pull/12' \
    "the mirrored body lost the URL it carried"
  assert_contains "$(posted_text)" 'Captain, the fix is up for review' \
    "the mirrored body lost its text"
  [ "$(posted_thread)" = "" ] || fail "an unprompted reply must post at the channel top level"
  pass "a substantive terminal reply is mirrored verbatim with no hand-written post"
}

# --- acknowledgement turns stay out of the channel ---------------------------

test_acknowledgement_is_suppressed() {
  local home
  home=$(new_home ack)
  write_transcript "$home/t.jsonl" 'noted' 'Captain, shipshape.'
  run_stop "$home" "$home/t.jsonl" >/dev/null 2>&1
  [ "$(posted_count)" = 0 ] || fail "an acknowledgement-only turn was mirrored: $(posted_text)"

  # The rule is a positive substantive test, not a phrase blocklist: the same
  # short shape carrying a link is still real news.
  write_transcript "$home/t2.jsonl" 'noted' 'Captain, shipshape: https://example.invalid/pr/3'
  run_stop "$home" "$home/t2.jsonl" >/dev/null 2>&1
  [ "$(posted_count)" = 1 ] || fail "a short reply carrying a link must still be mirrored"

  # A multi-line reply is substantive however short each line is.
  write_transcript "$home/t3.jsonl" 'noted' "$(printf 'Captain, two things.\nThe second one.')"
  run_stop "$home" "$home/t3.jsonl" >/dev/null 2>&1
  [ "$(posted_count)" = 1 ] || fail "a multi-line reply must be mirrored"

  # The bound is configurable, not hard-coded: raising it past a long single
  # prose line makes that line an acknowledgement.
  write_transcript "$home/t4.jsonl" 'noted' \
    'Captain, the crew finished the sweep and everything came back clean with nothing left to decide.'
  run_stop "$home" "$home/t4.jsonl" FM_SLACK_MIRROR_ACK_MAX_CHARS=20 >/dev/null 2>&1
  [ "$(posted_count)" = 1 ] || fail "a line past the configured bound must be mirrored"
  run_stop "$home" "$home/t4.jsonl" FM_SLACK_MIRROR_ACK_MAX_CHARS=400 >/dev/null 2>&1
  [ "$(posted_count)" = 0 ] || fail "the acknowledgement bound is not configurable"
  pass "acknowledgement turns are suppressed by a configurable substantive test"
}

test_identical_bodies_are_never_repeated() {
  local home
  home=$(new_home repeat)
  write_transcript "$home/t.jsonl" 'status?' \
    'Captain, the review is still running: https://example.invalid/pr/9'
  run_stop "$home" "$home/t.jsonl" >/dev/null 2>&1
  [ "$(posted_count)" = 1 ] || fail "the first substantive reply was not mirrored"
  run_stop "$home" "$home/t.jsonl" >/dev/null 2>&1
  [ "$(posted_count)" = 0 ] || fail "the same body was mirrored twice in a row"

  # A different body is not blocked by the repeat test.
  write_transcript "$home/t2.jsonl" 'status?' \
    'Captain, the review finished: https://example.invalid/pr/9 checks green'
  run_stop "$home" "$home/t2.jsonl" >/dev/null 2>&1
  [ "$(posted_count)" = 1 ] || fail "a changed body must still be mirrored"
  pass "two consecutive identical bodies are never both sent"
}

# --- thread routing: auto-detect from the triggering wake --------------------

# With NO manual note-reply-target call, a reply to a captain Slack message
# threads into that message's own thread, resolved from the wake that opened the
# turn. This is the whole point: firstmate does nothing by hand.
test_auto_detect_threads_by_the_triggering_wake() {
  local home sid
  home=$(new_home autodetect)
  sid="slack-captain-$CHANNEL"

  # An in-thread capture (seq 41) and a top-level capture (seq 42) both recorded,
  # exactly as the adapter records them as each result commits.
  FM_ROOT_OVERRIDE="$home" "$MIRROR" note-trigger "$CHANNEL" "$sid" 41 300.000300 \
    >/dev/null 2>&1
  FM_ROOT_OVERRIDE="$home" "$MIRROR" note-trigger "$CHANNEL" "$sid" 42 none \
    >/dev/null 2>&1

  # A turn opened by the wake for the in-thread capture threads into that thread.
  write_transcript "$home/t.jsonl" "$(wake_trigger "$sid" 41)" \
    'Captain, answering in the thread: https://example.invalid/a'
  run_stop "$home" "$home/t.jsonl" >/dev/null 2>&1
  [ "$(posted_thread)" = 300.000300 ] \
    || fail "auto-detect did not thread the reply into the triggering message's thread ($(posted_thread))"

  # A turn opened by the wake for the top-level capture posts at the top level.
  write_transcript "$home/t2.jsonl" "$(wake_trigger "$sid" 42)" \
    'Captain, answering in the channel: https://example.invalid/b'
  run_stop "$home" "$home/t2.jsonl" >/dev/null 2>&1
  [ "$(posted_thread)" = "" ] \
    || fail "auto-detect threaded a reply to a top-level captain message ($(posted_thread))"
  pass "auto-detect routes the reply by the wake that opened the turn, with no manual step"
}

# The interleaved case the newest-inbound guess gets WRONG: the captain writes in
# thread A (seq 41), then a fresh message lands top-level (seq 42) so the newest
# inbound now points there; firstmate is still answering thread A. Auto-detect,
# keyed by the triggering wake, must still reach thread A.
test_auto_detect_beats_the_interleaved_newest_inbound() {
  local home sid
  home=$(new_home interleaved)
  sid="slack-captain-$CHANNEL"

  # The earlier capture answered by this turn.
  FM_ROOT_OVERRIDE="$home" "$MIRROR" note-trigger "$CHANNEL" "$sid" 41 222.000222 \
    >/dev/null 2>&1
  # A later, unrelated capture moves the newest-inbound guess to the top level -
  # the exact interleaving that misroutes a guess by newest inbound.
  FM_ROOT_OVERRIDE="$home" "$MIRROR" note-inbound "$CHANNEL" 900.000900 "" >/dev/null 2>&1
  FM_ROOT_OVERRIDE="$home" "$MIRROR" note-trigger "$CHANNEL" "$sid" 42 none >/dev/null 2>&1

  write_transcript "$home/t.jsonl" "$(wake_trigger "$sid" 41)" \
    'Captain, answering the earlier thread: https://example.invalid/a'
  run_stop "$home" "$home/t.jsonl" >/dev/null 2>&1
  [ "$(posted_thread)" = 222.000222 ] \
    || fail "the interleaved newest-inbound pulled the reply out of the thread it answered ($(posted_thread))"
  pass "auto-detect files the reply by the triggering wake, not the newest inbound"
}

# A turn NOT opened by a captain Slack message - a crew wake, a terminal-typed
# line, an operational injection - must post at the top level even while a fresh
# inbound thread exists: it must never guess a thread it does not actually answer.
test_non_slack_trigger_never_threads() {
  local home sid
  home=$(new_home nonslack)
  sid="slack-captain-$CHANNEL"

  # A fresh inbound thread AND a recorded capture both exist; neither is what
  # opened this turn.
  FM_ROOT_OVERRIDE="$home" "$MIRROR" note-inbound "$CHANNEL" 700.000700 555.000555 \
    >/dev/null 2>&1
  FM_ROOT_OVERRIDE="$home" "$MIRROR" note-trigger "$CHANNEL" "$sid" 41 555.000555 \
    >/dev/null 2>&1

  # The turn is opened by an unrelated crew wake naming no captain capture.
  write_transcript "$home/t.jsonl" \
    'firstmate watcher wake - stale: fm-some-crew endpoint stopped responding' \
    'Captain, the crew task stalled: https://example.invalid/x'
  run_stop "$home" "$home/t.jsonl" >/dev/null 2>&1
  [ "$(posted_thread)" = "" ] \
    || fail "a non-Slack-triggered turn misfiled into a thread ($(posted_thread))"
  pass "a readable non-Slack trigger posts at the top level and never guesses a thread"
}

# --- thread routing: the newest-inbound last-resort fallback -----------------

# When the trigger cannot be read at all - a payload-only turn whose transcript
# never named an opening message - the mirror falls back to the newest-inbound
# guess, the pre-existing behavior, and that binding still expires.
test_newest_inbound_is_the_last_resort_fallback() {
  local home
  home=$(new_home fallback)

  # A fresh in-thread inbound: an unreadable trigger falls back to it.
  FM_ROOT_OVERRIDE="$home" "$MIRROR" note-inbound "$CHANNEL" 400.000400 300.000300 \
    >/dev/null 2>&1
  run_stop_payload "$home" 'Captain, answering in the thread: https://example.invalid/a' \
    >/dev/null 2>&1
  [ "$(posted_thread)" = 300.000300 ] \
    || fail "an unreadable trigger did not fall back to the newest inbound thread ($(posted_thread))"

  # A top-level inbound binds the channel top level.
  rm -f "$home/state/slack-captain/mirror.last-body"
  FM_ROOT_OVERRIDE="$home" "$MIRROR" note-inbound "$CHANNEL" 500.000500 "" >/dev/null 2>&1
  run_stop_payload "$home" 'Captain, answering in the channel: https://example.invalid/b' \
    >/dev/null 2>&1
  [ "$(posted_thread)" = "" ] || fail "the fallback answered a top-level message inside a stale thread"

  # A binding older than the window expires rather than capturing later turns.
  rm -f "$home/state/slack-captain/mirror.last-body"
  FM_ROOT_OVERRIDE="$home" "$MIRROR" note-inbound "$CHANNEL" 600.000600 300.000300 \
    >/dev/null 2>&1
  sed -i "s/epoch=[0-9]*/epoch=$(( $(date +%s) - 4000 ))/" \
    "$home/state/slack-captain/mirror.inbound"
  run_stop_payload "$home" 'Captain, much later: https://example.invalid/c' \
    FM_SLACK_MIRROR_THREAD_WINDOW=900 >/dev/null 2>&1
  [ "$(posted_thread)" = "" ] || fail "an expired thread binding still captured a later turn"
  pass "the newest-inbound guess is the last resort for an unreadable trigger, and it expires"
}

# The deterministic record firstmate writes for the turn it is answering must
# beat the newest-inbound guess, so an interleaved captain message in another
# thread cannot pull the reply out of the thread it answers.
test_recorded_reply_target_is_deterministic() {
  local home
  home=$(new_home reply-target)

  # The newest captured inbound points at thread B, exactly the interleaving that
  # misroutes the guess; firstmate records that it is answering thread A.
  FM_ROOT_OVERRIDE="$home" "$MIRROR" note-inbound "$CHANNEL" 700.000700 222.000222 \
    >/dev/null 2>&1
  FM_ROOT_OVERRIDE="$home" "$MIRROR" note-reply-target "$CHANNEL" 111.000111 >/dev/null 2>&1
  write_transcript "$home/t.jsonl" 'answer thread A' \
    'Captain, answering thread A: https://example.invalid/a'
  run_stop "$home" "$home/t.jsonl" >/dev/null 2>&1
  [ "$(posted_thread)" = 111.000111 ] \
    || fail "the recorded reply target did not beat the newest-inbound guess ($(posted_thread))"

  # The record is consumed: the next turn, with no fresh record and an unreadable
  # trigger, falls back to the newest inbound (thread B).
  run_stop_payload "$home" 'Captain, a different reply: https://example.invalid/b' \
    >/dev/null 2>&1
  [ "$(posted_thread)" = 222.000222 ] \
    || fail "the reply target was not consumed after one turn ($(posted_thread))"
  [ ! -f "$home/state/slack-captain/mirror.reply-target" ] \
    || fail "the reply-target record survived the turn it was recorded for"

  # `none` forces the channel top level even while an inbound thread is fresh.
  FM_ROOT_OVERRIDE="$home" "$MIRROR" note-reply-target "$CHANNEL" none >/dev/null 2>&1
  write_transcript "$home/t3.jsonl" 'top level' 'Captain, at the top level: https://example.invalid/c'
  run_stop "$home" "$home/t3.jsonl" >/dev/null 2>&1
  [ "$(posted_thread)" = "" ] \
    || fail "a recorded 'none' did not force the channel top level ($(posted_thread))"

  # A record orphaned by a hung turn is older than the window: discard it and
  # fall back rather than routing a much later turn into it.
  FM_ROOT_OVERRIDE="$home" "$MIRROR" note-reply-target "$CHANNEL" 111.000111 >/dev/null 2>&1
  sed -i "s/epoch=[0-9]*/epoch=$(( $(date +%s) - 4000 ))/" \
    "$home/state/slack-captain/mirror.reply-target"
  FM_ROOT_OVERRIDE="$home" "$MIRROR" note-inbound "$CHANNEL" 800.000800 222.000222 \
    >/dev/null 2>&1
  run_stop_payload "$home" 'Captain, much later: https://example.invalid/d' \
    FM_SLACK_MIRROR_THREAD_WINDOW=900 >/dev/null 2>&1
  [ "$(posted_thread)" = 222.000222 ] \
    || fail "a stale reply target was applied instead of discarded ($(posted_thread))"
  pass "the recorded reply target is deterministic, consumed once, and expires"
}

test_adapter_records_the_reply_target() {
  local home result out
  home=$(new_home adapter)
  mkdir -p "$home/state/slack-captain/threads/$CHANNEL"
  printf 'schema=fm-slack-captain-thread-cursor.v1\nts=%s\n' 300.000300 \
    > "$home/state/slack-captain/threads/$CHANNEL/300.000300.cursor"
  printf 'schema=fm-slack-captain-cursor.v1\nts=%s\n' 0 \
    > "$home/state/slack-captain/$CHANNEL.cursor"
  result="$home/result"
  {
    printf 'schema=fm-slack-captain.v1\nstatus=messages\nchannel=%s\n' "$CHANNEL"
    printf 'from_ts=0\nto_ts=400.000400\ncount=1\nuntrusted=0\nreason=\n'
    printf 'thread=300.000300 300.000300 350.000350 1\n'
    printf '\n'
    printf '{"ts":"350.000350","user":"%s","trusted":true,"text":"hello","thread_ts":"300.000300"}\n' "$CAPTAIN"
  } > "$result"
  out=$(FM_ROOT_OVERRIDE="$home" "$ROOT/bin/fm-procevent-slack-captain.sh" \
    autohandle "slack-captain-$CHANNEL" 1 "$result" 2>&1 || true)
  assert_contains "$out" 'applied:' "the adapter did not commit the capture: $out"
  assert_contains "$(cat "$home/state/slack-captain/mirror.inbound")" 'thread=300.000300' \
    "committing a capture did not record where a reply belongs"
  # The same commit records the keyed correlation the wake for this result carries.
  assert_contains "$(cat "$home/state/slack-captain/mirror.correlate")" \
    "source=slack-captain-$CHANNEL seq=1 thread=300.000300" \
    "committing a capture did not record the wake-keyed reply target"

  # End to end: a turn opened by the wake for this exact result threads correctly
  # off only what the adapter recorded, with no manual note-reply-target step.
  write_transcript "$home/t.jsonl" "$(wake_trigger "slack-captain-$CHANNEL" 1)" \
    'Captain, answering the captured thread: https://example.invalid/z'
  run_stop "$home" "$home/t.jsonl" >/dev/null 2>&1
  [ "$(posted_thread)" = 300.000300 ] \
    || fail "auto-detect did not route off the adapter's own recorded capture ($(posted_thread))"
  pass "the captain adapter records the reply target, and the mirror auto-detects off it"
}

# --- a deliberate post is never mirrored again -------------------------------

test_deliberate_post_suppresses_the_mirror() {
  local home
  home=$(new_home deliberate)
  # Firstmate posts by hand during the turn; the helper records it.
  FM_ROOT_OVERRIDE="$home" "$POST" "$CHANNEL" \
    'Captain, the fix is up: https://example.invalid/pr/1' >/dev/null 2>&1 \
    || fail "the hand-written post failed"
  [ -f "$home/state/slack-captain/mirror.last-post" ] \
    || fail "a deliberate post to the captain channel was not recorded"

  # The terminal text differs from what was posted, so only a durable record can
  # catch this.
  write_transcript "$home/t.jsonl" 'ship it' \
    'Captain, posted to Slack already; the fix is up for review with green checks.'
  run_stop "$home" "$home/t.jsonl" >/dev/null 2>&1
  [ "$(posted_count)" = 0 ] || fail "a turn that already posted was mirrored again: $(posted_text)"

  # The mirror's own delivery must not suppress the next turn.
  rm -f "$home/state/slack-captain/mirror.last-post"
  write_transcript "$home/t2.jsonl" 'next' 'Captain, next: https://example.invalid/pr/2'
  run_stop "$home" "$home/t2.jsonl" >/dev/null 2>&1
  [ "$(posted_count)" = 1 ] || fail "the mirror's first delivery did not go out"
  [ ! -f "$home/state/slack-captain/mirror.last-post" ] \
    || fail "the mirror recorded its own delivery as a deliberate post"
  pass "a turn where firstmate already posted produces no duplicate"
}

# --- fail open and silent ----------------------------------------------------

test_fail_open_paths() {
  local home out status
  home=$(new_home failopen)
  write_transcript "$home/t.jsonl" 'status?' 'Captain, real news: https://example.invalid/pr/4'

  rm -f "$home/.env"
  out=$(run_stop "$home" "$home/t.jsonl" 2>&1); status=$?
  expect_code 0 "$status" "a missing token must not fail the turn"
  [ -z "$out" ] || fail "a missing token was reported into the turn: $out"

  printf 'SLACK_BOT_TOKEN=xoxb-fake-000-supersecret\n' > "$home/.env"
  rm -f "$home/state/slack-captain/mirror.last-body"
  out=$(run_stop "$home" "$home/t.jsonl" FAKE_CURL_EXIT=7 2>&1); status=$?
  expect_code 0 "$status" "an unreachable Slack must not fail the turn"
  [ -z "$out" ] || fail "a Slack failure was reported into the turn: $out"

  out=$(printf 'not json at all' | env FM_ROOT_OVERRIDE="$home" "$MIRROR" stop 2>&1); status=$?
  expect_code 0 "$status" "a malformed payload must not fail the turn"
  [ -z "$out" ] || fail "a malformed payload was reported into the turn: $out"

  out=$(printf '' | env FM_ROOT_OVERRIDE="$home" "$MIRROR" stop 2>&1); status=$?
  expect_code 0 "$status" "an empty payload must not fail the turn"
  [ -z "$out" ] || fail "an empty payload was reported into the turn: $out"

  out=$(run_stop "$home" "$home/missing.jsonl" 2>&1); status=$?
  expect_code 0 "$status" "an unreadable transcript must not fail the turn"
  [ -z "$out" ] || fail "an unreadable transcript was reported into the turn: $out"
  pass "every failure path exits 0 and stays silent to the captain"
}

# --- a stalled Slack never blocks the turn -----------------------------------
#
# The mirror's whole safety promise is "never a gate": a slow or unreachable
# Slack must not delay the turn. Delivery is detached, so the turn-end hook
# returns at once however long the post takes; and even a caller that runs
# delivery inline (SYNC=1, the shape a test or a foreign host might use) is now
# backstopped by fm-slack-post's hard wall-clock ceiling. Both are proven here
# against a curl that hangs far past any bound, not the instant fake above.
test_a_stalled_slack_never_blocks_the_turn() {
  local home hangbin start end waited
  home=$(new_home stalled)
  write_transcript "$home/t.jsonl" 'status?' \
    'Captain, real news that must reach Slack: https://example.invalid/pr/99'

  hangbin="$TMP_ROOT/stalled-curl"
  mkdir -p "$hangbin"
  cat > "$hangbin/curl" <<SH
#!/usr/bin/env bash
printf 'started\n' >> "$home/curl.hang.log"
sleep 30
SH
  chmod +x "$hangbin/curl"
  : > "$home/curl.hang.log"

  # Detached (production) path: the hook must return at once, not wait on curl.
  start=$(date +%s)
  env PATH="$hangbin:$PATH" FM_ROOT_OVERRIDE="$home" FM_SLACK_MIRROR_SYNC= \
    "$MIRROR" stop >/dev/null 2>&1 <<EOF
{"hook_event_name":"Stop","session_id":"s","stop_hook_active":false,"transcript_path":"$home/t.jsonl","cwd":"$home"}
EOF
  end=$(date +%s)
  [ "$((end - start))" -lt 8 ] \
    || fail "the detached turn-end path waited on a hung Slack ($((end - start))s)"
  # And the detachment did not swallow the delivery: the child really ran curl.
  waited=0
  while [ ! -s "$home/curl.hang.log" ] && [ "$waited" -lt 100 ]; do
    sleep 0.1; waited=$((waited + 1))
  done
  [ -s "$home/curl.hang.log" ] \
    || fail "the detached path returned fast because it skipped delivery, not because it detached"
  pkill -f "$hangbin/curl" 2>/dev/null || true

  # Inline path: with no detachment, the hard ceiling in fm-slack-post is the
  # only thing standing between a hung curl and a blocked turn. It must bound it.
  rm -f "$home/state/slack-captain/mirror.last-body" "$home/curl.hang.log"
  start=$(date +%s)
  env PATH="$hangbin:$PATH" FM_ROOT_OVERRIDE="$home" FM_SLACK_MIRROR_SYNC=1 \
    FM_SLACK_POST_HARD_TIMEOUT=2 FM_SLACK_POST_MAX_TIME=1 \
    "$MIRROR" stop >/dev/null 2>&1 <<EOF
{"hook_event_name":"Stop","session_id":"s","stop_hook_active":false,"transcript_path":"$home/t.jsonl","cwd":"$home"}
EOF
  end=$(date +%s)
  [ -s "$home/curl.hang.log" ] \
    || fail "the inline path never reached curl, so the ceiling assertion is vacuous"
  [ "$((end - start))" -lt 8 ] \
    || fail "the inline delivery hung on curl instead of hitting the hard ceiling ($((end - start))s)"
  pkill -f "$hangbin/curl" 2>/dev/null || true
  pass "a stalled Slack blocks neither the detached turn-end path nor the inline backstop"
}

# --- scope -------------------------------------------------------------------

test_off_without_a_captain_channel() {
  local home
  home=$(new_home unconfigured --no-captain)
  write_transcript "$home/t.jsonl" 'status?' 'Captain, real news: https://example.invalid/pr/5'
  run_stop "$home" "$home/t.jsonl" >/dev/null 2>&1
  [ "$(posted_count)" = 0 ] || fail "a home with no captain channel mirrored anyway"

  # And an explicit off switch stops a configured home.
  home=$(new_home switched-off)
  printf 'mirror=off\n' >> "$home/config/slack-captain"
  write_transcript "$home/t.jsonl" 'status?' 'Captain, real news: https://example.invalid/pr/6'
  run_stop "$home" "$home/t.jsonl" >/dev/null 2>&1
  [ "$(posted_count)" = 0 ] || fail "mirror=off did not stop the mirror"
  pass "the mirror is off without a captain channel and can be switched off"
}

test_child_worktree_is_inert() {
  local repo work
  repo="$TMP_ROOT/childrepo"
  work="$TMP_ROOT/childwork"
  fm_git_worktree "$repo" "$work" fm/task
  mkdir -p "$work/state" "$work/config" "$work/bin"
  printf '# firstmate\n' > "$work/AGENTS.md"
  printf 'channel=%s\n' "$CHANNEL" > "$work/config/slack-captain"
  printf 'SLACK_BOT_TOKEN=xoxb-fake-000-supersecret\n' > "$work/.env"
  write_transcript "$work/t.jsonl" 'status?' 'Captain, real news: https://example.invalid/pr/7'
  run_stop "$work" "$work/t.jsonl" >/dev/null 2>&1
  [ "$(posted_count)" = 0 ] || fail "a crewmate worktree mirrored into the captain channel"
  pass "a crewmate or scout worktree is inert, exactly like the turn-end guard"
}

test_only_the_final_message_of_the_turn() {
  local home
  home=$(new_home final)
  # A subagent's own reply is not firstmate's captain-facing message.
  write_transcript "$home/t.jsonl" 'status?' \
    'Worker here with a long report: https://example.invalid/pr/8' --sidechain-reply
  run_stop "$home" "$home/t.jsonl" >/dev/null 2>&1
  [ "$(posted_count)" = 0 ] || fail "a subagent message was mirrored as firstmate's reply"

  # A turn whose only text predates the turn's opening message is not this
  # turn's reply and must not be re-posted.
  write_transcript "$home/t2.jsonl" 'status?' 'Captain, real news: https://example.invalid/pr/8'
  jq -n -c '{
      type: "user", isSidechain: false, timestamp: "2026-08-21T11:00:00.000Z",
      message: {role: "user", content: [{type: "text", text: "and again"}]}
    }' >> "$home/t2.jsonl"
  run_stop "$home" "$home/t2.jsonl" >/dev/null 2>&1
  [ "$(posted_count)" = 0 ] || fail "an older reply was re-posted for a turn that produced none"
  pass "only the finished turn's own final assistant text is mirrored"
}

# The real Claude Stop payload carries the finished turn's own final assistant
# message, and Stop can fire before the transcript's last entry is flushed.
test_payload_message_wins_over_the_transcript() {
  local home out status
  home=$(new_home payload)
  write_transcript "$home/t.jsonl" 'status?' 'Captain, the stale transcript line.'

  # A transcript that has not caught up yet must not cost the captain the reply.
  : > "$FAKE_POST_BODY"
  out=$(env FM_ROOT_OVERRIDE="$home" "$MIRROR" stop 2>&1 <<EOF
{"hook_event_name":"Stop","transcript_path":"$home/t.jsonl","cwd":"$home","last_assistant_message":"Captain, the real reply of this turn: https://example.invalid/pr/11","effort":{"level":"high"}}
EOF
  ); status=$?
  expect_code 0 "$status" "a payload-carried message must not fail the turn"
  [ -z "$out" ] || fail "the payload path printed to the turn: $out"
  assert_contains "$(posted_text)" 'the real reply of this turn' \
    "the payload's own account of the turn did not win over the transcript"

  # The payload's effort still feeds the standing convention when it is on.
  rm -f "$home/state/slack-captain/mirror.last-body"
  : > "$FAKE_POST_BODY"
  env FM_ROOT_OVERRIDE="$home" FM_SLACK_MIRROR_WORKER_DETAILS=on "$MIRROR" stop >/dev/null 2>&1 <<EOF
{"hook_event_name":"Stop","transcript_path":"$home/t.jsonl","cwd":"$home","last_assistant_message":"Captain, the real reply of this turn: https://example.invalid/pr/11","effort":{"level":"high"}}
EOF
  assert_contains "$(posted_text)" '_worker: claude-opus-5 high_' \
    "the payload effort and transcript model did not reach the completion convention"

  # A payload-carried acknowledgement is suppressed by the same rule.
  rm -f "$home/state/slack-captain/mirror.last-body"
  : > "$FAKE_POST_BODY"
  env FM_ROOT_OVERRIDE="$home" "$MIRROR" stop >/dev/null 2>&1 <<EOF
{"hook_event_name":"Stop","transcript_path":"$home/t.jsonl","cwd":"$home","last_assistant_message":"Captain, shipshape."}
EOF
  [ "$(posted_count)" = 0 ] || fail "a payload-carried acknowledgement was mirrored"
  pass "the payload's own final message wins over a transcript Stop can outrun"
}

test_worker_details_are_configurable() {
  local home
  home=$(new_home details)
  write_transcript "$home/t.jsonl" 'status?' 'Captain, real news: https://example.invalid/pr/10'
  run_stop "$home" "$home/t.jsonl" >/dev/null 2>&1
  case "$(posted_text)" in
    *_worker:*) fail "the mirror stamped worker details while they are off by default" ;;
  esac
  rm -f "$home/state/slack-captain/mirror.last-body"
  run_stop "$home" "$home/t.jsonl" FM_SLACK_MIRROR_WORKER_DETAILS=on >/dev/null 2>&1
  assert_contains "$(posted_text)" '_worker: claude-opus-5 low_' \
    "the standing completion convention was not applied when switched on"
  pass "worker details follow the standing convention and are configurable"
}

# --- Grok ---------------------------------------------------------------------
#
# The Grok Stop payload is camel-case and NOT Claude-shaped, and its transcript
# is a JSON-RPC session-update log, so both are built here from the real shapes
# dumped out of a running grok 1.0.5 Stop hook.

GROK_PROMPT=2110aa12-286a-4884-9954-197520b5dba8

# One Grok session `updates.jsonl`: the captain (or a wake) opening the turn as a
# user_message_chunk, then the agent's own reply chunks keyed by promptId.
write_grok_transcript() {  # <path> <user-text> <reply-text> [prompt-id] [prompt-index]
  local path=$1 user=$2 reply=$3 prompt=${4:-$GROK_PROMPT} index=${5:-7}
  jq -n -c --arg text "$user" --argjson index "$index" '{
      timestamp: 1787663968, method: "session/update",
      params: {sessionId: "s-grok",
        update: {sessionUpdate: "user_message_chunk",
          content: {type: "text", text: $text},
          _meta: {modelId: "grok-4.6", promptIndex: $index}},
        _meta: {eventId: "s-grok-3", agentTimestampMs: 1787663968681}}
    }' > "$path"
  jq -n -c --arg text "$reply" --arg prompt "$prompt" '{
      timestamp: 1787663971, method: "session/update",
      params: {sessionId: "s-grok",
        update: {sessionUpdate: "agent_message_chunk",
          content: {type: "text", text: $text}},
        _meta: {promptId: $prompt, turnStartMs: 1787663968684,
                agentTimestampMs: 1787663971082}}
    }' >> "$path"
  jq -n -c --arg prompt "$prompt" '{
      timestamp: 1787663971, method: "_x.ai/session/update",
      params: {sessionId: "s-grok",
        update: {sessionUpdate: "turn_completed", prompt_id: $prompt,
          stop_reason: "end_turn",
          usage: {modelUsage: {"grok-4.6-build": {outputTokens: 26}}}},
        _meta: {eventId: "s-grok-25"}}
    }' >> "$path"
}

# Fire the mirror exactly as Grok fires it: the verified end_turn Stop payload.
run_grok_stop() {  # <home> <transcript> <last-assistant-message> [extra env...]
  local home=$1 transcript=$2 last=$3
  shift 3
  : > "$FAKE_POST_BODY"
  env FM_ROOT_OVERRIDE="$home" "$@" "$MIRROR" stop <<EOF
{"hookEventName":"stop","sessionId":"s-grok","cwd":"$home","workspaceRoot":"$home/","timestamp":"2026-08-25T13:19:31.141061028+00:00","transcriptPath":"$transcript","promptId":"$GROK_PROMPT","permissionMode":"bypassPermissions","reason":"end_turn","stopHookActive":false,"lastAssistantMessage":$(jq -Rn --arg r "$last" '$r'),"backgroundTasks":[],"sessionCrons":[]}
EOF
}

# The second Stop grok fires as the session exits: no promptId, no
# lastAssistantMessage, and reason=shutdown.
run_grok_shutdown() {  # <home> <transcript>
  local home=$1 transcript=$2
  : > "$FAKE_POST_BODY"
  env FM_ROOT_OVERRIDE="$home" "$MIRROR" stop <<EOF
{"hookEventName":"stop","sessionId":"s-grok","cwd":"$home","workspaceRoot":"$home/","timestamp":"2026-08-25T13:19:31.213905391+00:00","transcriptPath":"$transcript","permissionMode":"bypassPermissions","reason":"shutdown","stopHookActive":false}
EOF
}

test_grok_turn_is_mirrored() {
  local home out status
  home=$(new_home grok)
  write_grok_transcript "$home/updates.jsonl" 'where is the fix?' \
    'Captain, the fix is up: https://example.invalid/pr/21'
  out=$(run_grok_stop "$home" "$home/updates.jsonl" \
    'Captain, the fix is up: https://example.invalid/pr/21' 2>&1)
  status=$?
  expect_code 0 "$status" "the mirror must never fail a Grok turn"
  [ -z "$out" ] || fail "the Grok path printed to the turn: $out"
  [ "$(posted_count)" = 1 ] || fail "a substantive Grok reply was not mirrored"
  assert_contains "$(posted_text)" 'https://example.invalid/pr/21' \
    "the mirrored Grok body lost the URL it carried"

  # The same acknowledgement rule applies on this harness.
  rm -f "$home/state/slack-captain/mirror.last-body"
  run_grok_stop "$home" "$home/updates.jsonl" 'Captain, shipshape.' >/dev/null 2>&1
  [ "$(posted_count)" = 0 ] || fail "a Grok acknowledgement turn was mirrored"

  # Worker details come from the transcript's own model record.
  rm -f "$home/state/slack-captain/mirror.last-body"
  run_grok_stop "$home" "$home/updates.jsonl" \
    'Captain, details on: https://example.invalid/pr/22' FM_SLACK_MIRROR_WORKER_DETAILS=on \
    >/dev/null 2>&1
  assert_contains "$(posted_text)" '_worker: grok-4.6-build_' \
    "the Grok model did not reach the completion convention"
  pass "a substantive Grok reply is mirrored the same way Claude's is"
}

# The extra Stop that fires as a Grok session exits carries no message of its
# own; it must never re-post the turn that already went out.
test_grok_shutdown_stop_is_not_mirrored() {
  local home
  home=$(new_home grok-shutdown)
  write_grok_transcript "$home/updates.jsonl" 'status?' \
    'Captain, the sweep finished: https://example.invalid/pr/23'
  run_grok_shutdown "$home" "$home/updates.jsonl" >/dev/null 2>&1
  [ "$(posted_count)" = 0 ] || fail "the shutdown Stop mirrored a turn: $(posted_text)"
  [ ! -f "$home/state/slack-captain/mirror.last-body" ] \
    || fail "the shutdown Stop consumed the repeat record"

  # And the real end_turn payload for that same turn still goes out.
  run_grok_stop "$home" "$home/updates.jsonl" \
    'Captain, the sweep finished: https://example.invalid/pr/23' >/dev/null 2>&1
  [ "$(posted_count)" = 1 ] || fail "the end_turn Stop did not mirror after a shutdown Stop"
  pass "only Grok's end_turn Stop is mirrored, so session teardown never re-posts"
}

# Auto-detect is harness-agnostic: the Grok adapter supplies the turn's opening
# message from its own transcript shape and the shared correlation store routes
# the reply, with no manual note-reply-target step.
test_grok_auto_detect_threads_by_the_triggering_wake() {
  local home sid
  home=$(new_home grok-autodetect)
  sid="slack-captain-$CHANNEL"
  FM_ROOT_OVERRIDE="$home" "$MIRROR" note-trigger "$CHANNEL" "$sid" 41 300.000300 >/dev/null 2>&1
  FM_ROOT_OVERRIDE="$home" "$MIRROR" note-trigger "$CHANNEL" "$sid" 42 none >/dev/null 2>&1
  # A fresh newest-inbound pointing elsewhere: auto-detect must beat it.
  FM_ROOT_OVERRIDE="$home" "$MIRROR" note-inbound "$CHANNEL" 900.000900 888.000888 >/dev/null 2>&1

  write_grok_transcript "$home/a.jsonl" "$(wake_trigger "$sid" 41)" \
    'Captain, answering in the thread: https://example.invalid/a'
  run_grok_stop "$home" "$home/a.jsonl" \
    'Captain, answering in the thread: https://example.invalid/a' >/dev/null 2>&1
  [ "$(posted_thread)" = 300.000300 ] \
    || fail "Grok auto-detect did not thread by the wake that opened the turn ($(posted_thread))"

  write_grok_transcript "$home/b.jsonl" "$(wake_trigger "$sid" 42)" \
    'Captain, answering in the channel: https://example.invalid/b'
  run_grok_stop "$home" "$home/b.jsonl" \
    'Captain, answering in the channel: https://example.invalid/b' >/dev/null 2>&1
  [ "$(posted_thread)" = "" ] \
    || fail "Grok auto-detect threaded a reply to a top-level message ($(posted_thread))"

  # A turn opened by something that is not a captain Slack message posts at the
  # top level even while a fresh inbound thread exists.
  write_grok_transcript "$home/c.jsonl" \
    'firstmate watcher wake - stale: a worker stopped responding' \
    'Captain, the worker stalled: https://example.invalid/c'
  run_grok_stop "$home" "$home/c.jsonl" \
    'Captain, the worker stalled: https://example.invalid/c' >/dev/null 2>&1
  [ "$(posted_thread)" = "" ] \
    || fail "a non-Slack Grok turn misfiled into a thread ($(posted_thread))"
  pass "Grok auto-detect routes by the triggering wake off the same correlation store"
}

# With no lastAssistantMessage the reply is rebuilt from the transcript, and only
# from the chunks belonging to the turn that just ended.
test_grok_transcript_fallback_is_bound_to_this_turn() {
  local home
  home=$(new_home grok-transcript)
  write_grok_transcript "$home/t.jsonl" 'status?' \
    'Captain, rebuilt from the transcript: https://example.invalid/pr/24'
  : > "$FAKE_POST_BODY"
  env FM_ROOT_OVERRIDE="$home" "$MIRROR" stop >/dev/null 2>&1 <<EOF
{"hookEventName":"stop","cwd":"$home","transcriptPath":"$home/t.jsonl","promptId":"$GROK_PROMPT","reason":"end_turn","stopHookActive":false}
EOF
  assert_contains "$(posted_text)" 'rebuilt from the transcript' \
    "the Grok transcript fallback did not recover the turn's reply"

  # A turn whose own promptId produced no reply must not re-post the older one.
  # The repeat record is cleared first, so this asserts the prompt binding rather
  # than passing vacuously on the consecutive-repeat test.
  rm -f "$home/state/slack-captain/mirror.last-body"
  : > "$FAKE_POST_BODY"
  env FM_ROOT_OVERRIDE="$home" "$MIRROR" stop >/dev/null 2>&1 <<EOF
{"hookEventName":"stop","cwd":"$home","transcriptPath":"$home/t.jsonl","promptId":"a-different-prompt-id","reason":"end_turn","stopHookActive":false}
EOF
  [ "$(posted_count)" = 0 ] \
    || fail "a Grok turn with no reply of its own re-posted an older one: $(posted_text)"
  pass "the Grok transcript fallback is bound to the finished turn's own prompt"
}

# Codex's Stop payload is the same snake_case shape Claude emits, read by the
# same adapter; its rollout transcript is not Claude-shaped, so the trigger is
# unreadable and the reply posts by the fallback rather than guessing a thread.
test_codex_shaped_payload_is_mirrored() {
  local home out status
  home=$(new_home codex)
  printf '{"record_type":"turn_context","turn_id":"t-1"}\n' > "$home/rollout.jsonl"
  : > "$FAKE_POST_BODY"
  out=$(env FM_ROOT_OVERRIDE="$home" "$MIRROR" stop 2>&1 <<EOF
{"hook_event_name":"Stop","session_id":"s-9","turn_id":"t-1","model":"gpt-5.3-codex","stop_hook_active":false,"transcript_path":"$home/rollout.jsonl","cwd":"$home","last_assistant_message":"Captain, the fix is up: https://example.invalid/pr/31"}
EOF
)
  status=$?
  expect_code 0 "$status" "the mirror must never fail a Codex turn"
  [ -z "$out" ] || fail "the Codex path printed to the turn: $out"
  [ "$(posted_count)" = 1 ] || fail "a substantive Codex reply was not mirrored"
  assert_contains "$(posted_text)" 'https://example.invalid/pr/31' \
    "the mirrored Codex body lost the URL it carried"
  [ "$(posted_thread)" = "" ] \
    || fail "a Codex turn with no readable trigger guessed a thread ($(posted_thread))"
  pass "a Codex-shaped Stop payload is mirrored through the shared adapter"
}

# The Codex registration is the only thing that makes the mirror fire on that
# harness, so it is exercised as a command string rather than trusted: the
# tracked entry must reach the mirror from a Firstmate-shaped root, and must
# stay inert in a root whose own hooks file does not carry the registration.
test_codex_registration_reaches_the_mirror() {
  local hook cmd root
  hook="$ROOT/.codex/hooks.json"
  [ -f "$hook" ] || fail "the tracked Codex hooks registration is missing"
  cmd=$(jq -r '[.hooks.Stop[]?.hooks[]?.command | select(contains("fm-slack-mirror.sh"))][0] // empty' "$hook")
  [ -n "$cmd" ] || fail "no Codex Stop registration names the Slack mirror"

  root="$TMP_ROOT/codex-registration"
  mkdir -p "$root/bin" "$root/.codex"
  printf '# firstmate\n' > "$root/AGENTS.md"
  cp "$hook" "$root/.codex/hooks.json"
  # shellcheck disable=SC2016 # the expansions belong to the generated stub.
  printf '#!/usr/bin/env bash\nprintf "%%s:" "$1" >> %q\ncat >> %q\n' \
    "$root/invoked" "$root/invoked" > "$root/bin/fm-slack-mirror.sh"
  chmod +x "$root/bin/fm-slack-mirror.sh"

  rm -f "$root/invoked"
  (cd "$root" && printf '{"hook_event_name":"Stop"}' | bash -c "$cmd") \
    >/dev/null 2>&1
  [ "$(cat "$root/invoked" 2>/dev/null)" = 'stop:{"hook_event_name":"Stop"}' ] \
    || fail "the Codex registration did not hand the payload to the mirror's stop entry"

  # A root whose hooks file lacks the registration fails the self-check and
  # stays inert, exactly like the other tracked Codex entries.
  printf '{"hooks":{}}\n' > "$root/.codex/hooks.json"
  rm -f "$root/invoked"
  (cd "$root" && printf '{"hook_event_name":"Stop"}' | bash -c "$cmd") \
    >/dev/null 2>&1
  [ ! -e "$root/invoked" ] \
    || fail "the Codex registration ran from a root that does not register it"
  pass "the tracked Codex Stop registration reaches the mirror and self-checks its root"
}

test_adapter_coverage_is_reported() {
  local out
  out=$(FM_ROOT_OVERRIDE="$TMP_ROOT" "$MIRROR" adapters 2>&1)
  assert_contains "$out" 'claude: covered' "the coverage table lost the Claude adapter"
  assert_contains "$out" 'grok: covered' "the coverage table lost the Grok adapter"
  assert_contains "$out" 'uncovered harnesses:' "the coverage table lost its documented gaps"
  assert_contains "$out" 'kimi' "the coverage table lost an uncovered harness"
  pass "the tool reports which harnesses it covers and which remain gaps"
}

# The Grok registration is the only thing that makes the mirror fire on that
# harness, so it is exercised as a command string rather than trusted: the
# tracked entry must reach the mirror under a real grok hook environment, and
# must stay inert with no workspace root to anchor on.
test_grok_registration_reaches_the_mirror() {
  local hook cmd dir
  hook="$ROOT/.grok/hooks/fm-primary-slack-mirror.json"
  [ -f "$hook" ] || fail "the tracked Grok Slack-mirror registration is missing"
  cmd=$(jq -r '.hooks.Stop[0].hooks[0].command // empty' "$hook")
  [ -n "$cmd" ] || fail "the Grok registration has no Stop command"

  dir="$TMP_ROOT/grok-registration/bin"
  mkdir -p "$dir"
  # shellcheck disable=SC2016 # $1 belongs to the generated stub, not this shell.
  printf '#!/usr/bin/env bash\nprintf "%%s" "$1" >> %q\n' "$dir/../invoked" \
    > "$dir/fm-slack-mirror.sh"
  chmod +x "$dir/fm-slack-mirror.sh"

  rm -f "$dir/../invoked"
  env GROK_WORKSPACE_ROOT="$dir/.." GROK_HOOK_EVENT=stop bash -c "$cmd" \
    </dev/null >/dev/null 2>&1
  [ "$(cat "$dir/../invoked" 2>/dev/null)" = stop ] \
    || fail "the Grok registration did not reach the mirror's stop entry"

  rm -f "$dir/../invoked"
  env -u GROK_WORKSPACE_ROOT bash -c "$cmd" </dev/null >/dev/null 2>&1
  [ ! -e "$dir/../invoked" ] \
    || fail "the Grok registration ran with no workspace root to anchor on"
  pass "the tracked Grok Stop registration reaches the mirror and is inert unanchored"
}

test_substantive_reply_is_mirrored
test_acknowledgement_is_suppressed
test_identical_bodies_are_never_repeated
test_auto_detect_threads_by_the_triggering_wake
test_auto_detect_beats_the_interleaved_newest_inbound
test_non_slack_trigger_never_threads
test_newest_inbound_is_the_last_resort_fallback
test_recorded_reply_target_is_deterministic
test_adapter_records_the_reply_target
test_deliberate_post_suppresses_the_mirror
test_a_stalled_slack_never_blocks_the_turn
test_fail_open_paths
test_off_without_a_captain_channel
test_child_worktree_is_inert
test_only_the_final_message_of_the_turn
test_payload_message_wins_over_the_transcript
test_worker_details_are_configurable
test_grok_turn_is_mirrored
test_grok_shutdown_stop_is_not_mirrored
test_grok_auto_detect_threads_by_the_triggering_wake
test_grok_transcript_fallback_is_bound_to_this_turn
test_codex_shaped_payload_is_mirrored
test_codex_registration_reaches_the_mirror
test_adapter_coverage_is_reported
test_grok_registration_reaches_the_mirror
