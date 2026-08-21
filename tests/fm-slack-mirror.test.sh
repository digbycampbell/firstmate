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

# --- thread routing ----------------------------------------------------------

test_reply_lands_in_the_captain_thread() {
  local home
  home=$(new_home thread)
  # The captain adapter records the routing target as it commits a capture.
  FM_ROOT_OVERRIDE="$home" "$MIRROR" note-inbound "$CHANNEL" 400.000400 300.000300 \
    >/dev/null 2>&1
  write_transcript "$home/t.jsonl" 'inside a thread' \
    'Captain, answering in the thread: https://example.invalid/a'
  run_stop "$home" "$home/t.jsonl" >/dev/null 2>&1
  [ "$(posted_thread)" = 300.000300 ] \
    || fail "a reply to a threaded captain message did not land in that thread"

  # A top-level captain message binds the channel top level, not the old thread.
  FM_ROOT_OVERRIDE="$home" "$MIRROR" note-inbound "$CHANNEL" 500.000500 "" >/dev/null 2>&1
  write_transcript "$home/t2.jsonl" 'in the channel' \
    'Captain, answering in the channel: https://example.invalid/b'
  run_stop "$home" "$home/t2.jsonl" >/dev/null 2>&1
  [ "$(posted_thread)" = "" ] || fail "a top-level captain message was answered inside a stale thread"

  # A binding older than the window expires rather than capturing later turns.
  FM_ROOT_OVERRIDE="$home" "$MIRROR" note-inbound "$CHANNEL" 600.000600 300.000300 \
    >/dev/null 2>&1
  sed -i "s/epoch=[0-9]*/epoch=$(( $(date +%s) - 4000 ))/" \
    "$home/state/slack-captain/mirror.inbound"
  write_transcript "$home/t3.jsonl" 'later' 'Captain, much later: https://example.invalid/c'
  run_stop "$home" "$home/t3.jsonl" FM_SLACK_MIRROR_THREAD_WINDOW=900 >/dev/null 2>&1
  [ "$(posted_thread)" = "" ] || fail "an expired thread binding still captured a later turn"
  pass "a mirrored reply lands where the captain wrote, and the binding expires"
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
  pass "the captain adapter records the reply target from the threads it already tracks"
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

test_substantive_reply_is_mirrored
test_acknowledgement_is_suppressed
test_identical_bodies_are_never_repeated
test_reply_lands_in_the_captain_thread
test_adapter_records_the_reply_target
test_deliberate_post_suppresses_the_mirror
test_fail_open_paths
test_off_without_a_captain_channel
test_child_worktree_is_inert
test_only_the_final_message_of_the_turn
test_payload_message_wins_over_the_transcript
test_worker_details_are_configurable
