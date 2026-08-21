#!/usr/bin/env bash
# Behavior tests for the Slack captain-channel process-event adapter.
#
# Slack itself is replaced by a fake `curl` on PATH that serves a canned
# conversations.history body, so nothing here touches the network. The fake also
# records its own argv and the config it received on stdin, which is how the
# token-confinement invariant is asserted rather than merely documented.
#
# Delivery is deliberately NOT asserted as lossless. What is asserted is the
# adapter's own contract: the read position advances only after a result is
# durably captured, a result that does not continue that position is refused
# rather than rebased, and the source is never terminal.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ADAPTER="$ROOT/bin/fm-procevent-slack-captain.sh"
TMP_ROOT=$(fm_test_tmproot fm-procevent-slack-captain)
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"
# Staging-directory hygiene is asserted by scanning TMPDIR, so TMPDIR is scoped
# to this run: an unrelated live poll on the machine must not decide the verdict.
export TMPDIR="$TMP_ROOT/tmp"
mkdir -p "$TMPDIR"
export FM_SLACK_CAPTAIN_MAX_LOOPS=1
export FM_SLACK_CAPTAIN_INTERVAL=0
export FM_SLACK_CAPTAIN_MAX_TIME=5
# The debounce hold is exercised deliberately below; every other case runs with
# no hold, so those cases assert capture shape rather than wall-clock patience
# and their canned responses stay call-for-call predictable.
export FM_SLACK_CAPTAIN_QUIET_WINDOW=0
export FM_SLACK_CAPTAIN_MAX_QUIET_WINDOWS=0
# Canned Slack timestamps are tiny epochs, so the age bound on tracked threads
# is widened here and exercised deliberately in its own case below.
export FM_SLACK_CAPTAIN_THREAD_MAX_AGE=99999999999

CHANNEL=C0TESTCHAN
BOT=U0BOTUSER
CAPTAIN=U0CAPTAIN
STRANGER=U0STRANGER
SID="slack-captain-$CHANNEL"

TRACKED_HOMES=()
slack_teardown() {
  local home
  for home in ${TRACKED_HOMES[@]+"${TRACKED_HOMES[@]}"}; do
    FM_HOME="$home" "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
  done
  fm_test_cleanup
}
trap slack_teardown EXIT

FAKEBIN=$(fm_fakebin "$TMP_ROOT")
cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
# Stand-in for the Slack call. Records argv and the stdin config, then serves
# FAKE_SLACK_RESPONSE into whatever -o names. When FAKE_SLACK_RESPONSE.<n>
# exists for the nth call it is served instead, which is how a paginated
# window is faked.
set -u
printf '%s\n' "$*" >> "$FAKE_CURL_ARGV"
cat >> "$FAKE_CURL_STDIN"
# Each endpoint counts its own calls, so a canned history sequence stays
# call-for-call predictable no matter how many thread reads happen beside it.
case "$*" in
  *conversations.replies*) counter="$FAKE_REPLIES_COUNT"; base="$FAKE_SLACK_REPLIES" ;;
  *) counter="$FAKE_CURL_COUNT"; base="$FAKE_SLACK_RESPONSE" ;;
esac
n=$(cat "$counter" 2>/dev/null || printf 0)
n=$((n + 1))
printf '%s\n' "$n" > "$counter"
out=
prev=
for arg in "$@"; do
  [ "$prev" = -o ] && out=$arg
  prev=$arg
done
[ -n "$out" ] || exit 1
body="$base"
[ ! -f "$base.$n" ] || body="$base.$n"
[ -f "$body" ] || body="$FAKE_SLACK_RESPONSE"
cat "$body" > "$out"
exit "${FAKE_CURL_EXIT:-0}"
SH
chmod +x "$FAKEBIN/curl"
export PATH="$FAKEBIN:$PATH"
export FAKE_CURL_ARGV="$TMP_ROOT/curl.argv"
export FAKE_CURL_STDIN="$TMP_ROOT/curl.stdin"
export FAKE_SLACK_RESPONSE="$TMP_ROOT/slack.json"
export FAKE_CURL_COUNT="$TMP_ROOT/curl.count"
export FAKE_REPLIES_COUNT="$TMP_ROOT/replies.count"
export FAKE_SLACK_REPLIES="$TMP_ROOT/slack-replies.json"
: > "$FAKE_CURL_ARGV"
: > "$FAKE_CURL_STDIN"

TOKEN='xoxb-fake-000-supersecret'

new_home() {  # <name> [--no-token]
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/config"
  {
    printf 'channel=%s\n' "$CHANNEL"
    printf 'bot_user=%s\n' "$BOT"
    printf 'allowed_user=%s\n' "$CAPTAIN"
  } > "$home/config/slack-captain"
  if [ "${2-}" != --no-token ]; then
    printf 'SLACK_BOT_TOKEN=%s\n' "$TOKEN" > "$home/.env"
    chmod 600 "$home/.env"
  fi
  TRACKED_HOMES+=("$home")
  printf '%s\n' "$home"
}

slack_response() {  # <json>
  printf '%s\n' "$1" > "$FAKE_SLACK_RESPONSE"
}

ok_body() {  # <messages-json-array>
  printf '{"ok":true,"messages":%s}\n' "$1"
}

cursor_file() { printf '%s/state/slack-captain/%s.cursor\n' "$1" "$CHANNEL"; }
file_mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

# --- a captain message is captured, and the read position advances only on handle

home=$(new_home capture)
# The literal command substitution below is the point: it must survive as data.
# shellcheck disable=SC2016
slack_response "$(ok_body '[
  {"type":"message","user":"'"$CAPTAIN"'","ts":"200.000200","text":"second"},
  {"type":"message","user":"'"$CAPTAIN"'","ts":"100.000100","text":"first $(touch /tmp/fm-slack-pwned)"}
]')"

out="$TMP_ROOT/capture.result"
rc=0
"$ADAPTER" poll "$home" "$CHANNEL" > "$out" 2>"$TMP_ROOT/capture.err" || rc=$?
expect_code 0 "$rc" "a poll that sees messages succeeds"
assert_grep 'schema=fm-slack-captain.v1' "$out" "the result carries its schema"
assert_grep 'status=messages' "$out" "the result reports messages"
assert_grep 'from_ts=0' "$out" "a first poll starts from the whole retained history"
assert_grep 'to_ts=200.000200' "$out" "the result commits the newest timestamp"
assert_grep 'count=2' "$out" "both captain messages are carried"
assert_grep 'untrusted=0' "$out" "the captain's own messages are trusted"
[ "$(tail -n 2 "$out" | head -n 1 | jq -r .ts)" = 100.000100 ] \
  || fail "messages are not ordered oldest first"
# shellcheck disable=SC2016 # The unexpanded literal is exactly what must round-trip.
assert_grep 'first $(touch /tmp/fm-slack-pwned)' "$out" "message text is carried as data"
assert_absent /tmp/fm-slack-pwned "message text must never be expanded by a shell"
[ "$("$ADAPTER" classify "$out")" = messages ] || fail "classify should report messages"
[ ! -s "$TMP_ROOT/capture.err" ] \
  || fail "a successful poll must be silent: $(cat "$TMP_ROOT/capture.err")"
staged=$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'fm-slack-captain.*' 2>/dev/null | head -n 1)
[ -z "$staged" ] || fail "the poll left its staging directory behind: $staged"
pass "a captain message is captured as ordered, uninterpreted data"

assert_absent "$(cursor_file "$home")" "the poll child must not advance the read position itself"
FM_HOME="$home" "$ADAPTER" autohandle "$SID" 1 "$out" >/dev/null 2>&1 \
  && fail "autohandle must report failure so the runner leaves the result unacknowledged"
assert_grep 'ts=200.000200' "$(cursor_file "$home")" "applying the result advances the stored read position"
[ "$(file_mode "$(cursor_file "$home")")" = 600 ] || fail "the cursor must be private"
pass "the read position advances only after a result exists, and never acknowledges it"

# The advance is idempotent, and the next poll resumes from it.
FM_HOME="$home" "$ADAPTER" autohandle "$SID" 1 "$out" >/dev/null 2>&1 \
  && fail "autohandle must keep reporting failure on a repeat application"
assert_grep 'ts=200.000200' "$(cursor_file "$home")" "re-applying the same result is a no-op"
slack_response "$(ok_body '[]')"
rc=0
"$ADAPTER" poll "$home" "$CHANNEL" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "a quiet channel must not produce a result"
assert_grep "oldest=200.000200" "$FAKE_CURL_ARGV" "the next poll resumes from the stored read position"
pass "read-position continuity survives across polls and repeat application"

# --- the token never reaches argv or the result -----------------------------

assert_no_grep "$TOKEN" "$FAKE_CURL_ARGV" "the token must never appear in curl argv"
assert_no_grep "$TOKEN" "$out" "the token must never appear in a captured result"
assert_grep "Authorization: Bearer $TOKEN" "$FAKE_CURL_STDIN" "the token reaches curl only on stdin"
pass "the token is confined to the poll child's stdin"

# --- bot posts and subtyped events are never captured -----------------------

home=$(new_home botfilter)
slack_response "$(ok_body '[
  {"type":"message","user":"'"$BOT"'","ts":"300.000300","text":"firstmate reply"},
  {"type":"message","bot_id":"B123","ts":"301.000301","text":"other bot"},
  {"type":"message","user":"'"$CAPTAIN"'","subtype":"channel_join","ts":"302.000302","text":"joined"}
]')"
rc=0
"$ADAPTER" poll "$home" "$CHANNEL" > "$TMP_ROOT/bot.out" 2>/dev/null || rc=$?
[ "$rc" -ne 0 ] || fail "a channel with only bot and subtyped posts must produce no result"
[ ! -s "$TMP_ROOT/bot.out" ] || fail "bot and subtyped posts must not be captured"
pass "the bot's own posts and subtyped events never become results"

# --- a message with a file attachment is still captured ---------------------

home=$(new_home filesubtype)
slack_response "$(ok_body '[
  {"type":"message","user":"'"$CAPTAIN"'","subtype":"file_share","ts":"310.000310","text":"see attached"},
  {"type":"message","user":"'"$CAPTAIN"'","subtype":"channel_join","ts":"311.000311","text":"joined"}
]')"
"$ADAPTER" poll "$home" "$CHANNEL" > "$TMP_ROOT/filesubtype.out" 2>/dev/null \
  || fail "a file_share message from the captain should be captured"
assert_grep 'count=1' "$TMP_ROOT/filesubtype.out" "only the file_share message is captured"
assert_grep '"text":"see attached"' "$TMP_ROOT/filesubtype.out" \
  "a message with a file attachment is not silently dropped"
assert_grep 'to_ts=311.000311' "$TMP_ROOT/filesubtype.out" \
  "the read position advances past the trailing subtyped message too"
pass "a captain message posted with a file attachment is captured"

# --- an author other than the configured captain is marked untrusted --------

home=$(new_home untrusted)
slack_response "$(ok_body '[
  {"type":"message","user":"'"$CAPTAIN"'","ts":"400.000400","text":"mine"},
  {"type":"message","user":"'"$STRANGER"'","ts":"401.000401","text":"theirs"}
]')"
"$ADAPTER" poll "$home" "$CHANNEL" > "$TMP_ROOT/untrusted.out" 2>/dev/null \
  || fail "a poll that sees messages should succeed"
assert_grep 'untrusted=1' "$TMP_ROOT/untrusted.out" "a non-captain author is counted untrusted"
assert_grep '"trusted":false' "$TMP_ROOT/untrusted.out" "the untrusted message is marked in place"
[ "$("$ADAPTER" classify "$TMP_ROOT/untrusted.out")" = untrusted-messages ] \
  || fail "classify must distinguish a result containing untrusted authors"
pass "messages from any other author are marked and classified untrusted"

# An absent allowed_user grants trust to nobody.
sed -i.bak '/^allowed_user=/d' "$home/config/slack-captain"
"$ADAPTER" poll "$home" "$CHANNEL" > "$TMP_ROOT/noallow.out" 2>/dev/null \
  || fail "a poll should still succeed with no configured captain"
assert_grep 'untrusted=2' "$TMP_ROOT/noallow.out" "trust is granted only by configuration"
pass "no configured captain means no trusted author"

# --- a window larger than one page is fetched to exhaustion ------------------

home=$(new_home pagination)
printf 0 > "$FAKE_CURL_COUNT"
cat > "$FAKE_SLACK_RESPONSE.1" <<JSON
{"ok":true,"has_more":true,"messages":[
  {"type":"message","user":"$CAPTAIN","ts":"602.000602","text":"third"},
  {"type":"message","user":"$CAPTAIN","ts":"601.000601","text":"second"}
]}
JSON
cat > "$FAKE_SLACK_RESPONSE.2" <<JSON
{"ok":true,"has_more":false,"messages":[
  {"type":"message","user":"$CAPTAIN","ts":"600.000600","text":"first"}
]}
JSON
"$ADAPTER" poll "$home" "$CHANNEL" > "$TMP_ROOT/paged.out" 2>/dev/null \
  || fail "a poll over a paginated window should succeed"
assert_grep 'count=3' "$TMP_ROOT/paged.out" "every message in the window is captured before a result is emitted"
assert_grep 'to_ts=602.000602' "$TMP_ROOT/paged.out" "the committed end position is the newest captured message"

# --- the read position advances past trailing bot-only traffic --------------
# A channel where firstmate posts often and the captain rarely does must not
# re-walk the same bot-only tail forever: the position commits to the newest
# ts FETCHED, not merely the newest ts that survived the captain-only filter.

home=$(new_home botheavy)
slack_response "$(ok_body '[
  {"type":"message","user":"'"$CAPTAIN"'","ts":"700.000700","text":"one word"},
  {"type":"message","user":"'"$BOT"'","ts":"701.000701","text":"done"},
  {"type":"message","user":"'"$BOT"'","ts":"702.000702","text":"done again"}
]')"
"$ADAPTER" poll "$home" "$CHANNEL" > "$TMP_ROOT/botheavy.out" 2>/dev/null \
  || fail "a window with trailing bot-only traffic should still succeed"
assert_grep 'to_ts=702.000702' "$TMP_ROOT/botheavy.out" \
  "the position advances past bot traffic fetched after the last captured message"
FM_HOME="$home" "$ADAPTER" autohandle "$SID" 1 "$TMP_ROOT/botheavy.out" >/dev/null 2>&1 || true
slack_response "$(ok_body '[]')"
"$ADAPTER" poll "$home" "$CHANNEL" >/dev/null 2>&1 || true
assert_grep 'oldest=702.000702' "$FAKE_CURL_ARGV" \
  "the next poll does not re-walk the bot-only tail already fetched"
pass "the channel read position advances to the newest fetched timestamp, not just the newest captured one"
assert_grep '"text":"first"' "$TMP_ROOT/paged.out" "the older page's message is in the payload, so to_ts skips nothing"
[ "$(tail -n 3 "$TMP_ROOT/paged.out" | head -n 1 | jq -r .ts)" = 600.000600 ] \
  || fail "a paginated payload must stay ordered oldest first"
assert_grep 'latest=601.000601' "$FAKE_CURL_ARGV" "the next page walks back from the oldest fetched timestamp"
rm -f "$FAKE_SLACK_RESPONSE.1" "$FAKE_SLACK_RESPONSE.2"
pass "a burst past the page limit is paginated, never silently truncated"

# --- a broken read position is loud, never silently rebased ------------------

home=$(new_home cursorbreak)
mkdir -p "$home/state/slack-captain"
printf 'schema=%s\nts=%s\n' fm-slack-captain-cursor.v1 999.000999 > "$(cursor_file "$home")"
err=$(FM_HOME="$home" "$ADAPTER" handle "$SID" 1 "$out" 2>&1) && rc=0 || rc=$?
[ "$rc" -ne 0 ] || fail "a discontinuous result must be refused"
assert_contains "$err" "do not continue the stored read position" \
  "the refusal must name the continuity break"
assert_grep 'ts=999.000999' "$(cursor_file "$home")" "a refused result must not rebase the read position"
pass "a result that does not continue the stored position is refused loudly"

printf 'schema=%s\nts=%s\n' fm-slack-cursor.v0 100.000100 > "$(cursor_file "$home")"
err=$("$ADAPTER" poll "$home" "$CHANNEL" 2>&1) && rc=0 || rc=$?
[ "$rc" -ne 0 ] || fail "an unreadable read position must stop the poll"
assert_contains "$err" "incompatible schema" "the refusal must name the unreadable cursor"
assert_grep 'ts=100.000100' "$(cursor_file "$home")" "an unreadable cursor must not be rewritten"
pass "an incompatible stored read position stops the poll instead of restarting from zero"

# --- an absent token is a refusal, never a silent no-op ---------------------

home=$(new_home notoken --no-token)
err=$(FM_HOME="$home" "$ADAPTER" arm 2>&1) && rc=0 || rc=$?
[ "$rc" -ne 0 ] || fail "arming without a token must be refused"
assert_contains "$err" "SLACK_BOT_TOKEN" "the refusal must name the missing credential"
err=$("$ADAPTER" poll "$home" "$CHANNEL" 2>&1) && rc=0 || rc=$?
[ "$rc" -ne 0 ] || fail "polling without a token must be refused"
assert_contains "$err" "SLACK_BOT_TOKEN" "the poll refusal must name the missing credential"
pass "an absent token is refused rather than silently skipped"

# --- a fatal Slack error is surfaced, a transient one is not ----------------

home=$(new_home apierror)
slack_response '{"ok":false,"error":"invalid_auth"}'
"$ADAPTER" poll "$home" "$CHANNEL" > "$TMP_ROOT/apierror.out" 2>/dev/null \
  || fail "a fatal Slack error should produce a result rather than exit nonzero"
assert_grep 'status=api-error' "$TMP_ROOT/apierror.out" "a credential failure becomes a result"
assert_grep 'reason=invalid_auth' "$TMP_ROOT/apierror.out" "the result names the Slack error"
[ "$("$ADAPTER" classify "$TMP_ROOT/apierror.out")" = api-error ] || fail "classify should report api-error"
slack_response '{"ok":false,"error":"ratelimited"}'
rc=0
"$ADAPTER" poll "$home" "$CHANNEL" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "a transient Slack error must not become a result"
pass "a fatal Slack error is surfaced and a transient one is retried"

# handle acknowledges an api-error result without moving the read position.
# The acknowledgement is recorded against the runner's inbox copy, so the
# captured result is staged there the way the runner captures it.
mkdir -p "$home/state/procevent-inbox"
cp "$TMP_ROOT/apierror.out" "$home/state/procevent-inbox/$SID.7.result"
printf '%s\n' "$ADAPTER" > "$home/state/procevent-inbox/$SID.7.adapter"
FM_HOME="$home" "$ADAPTER" handle "$SID" 7 "$home/state/procevent-inbox/$SID.7.result" >/dev/null 2>&1 \
  || fail "handling an api-error result must record the acknowledgement"
assert_present "$home/state/procevent-inbox/$SID.7.handled" "acknowledging an api-error is recorded"
assert_absent "$(cursor_file "$home")" "acknowledging an api-error must not move the read position"
pass "an api-error result is acknowledgeable through handle"

# --- classify is defensive about anything else ------------------------------

: > "$TMP_ROOT/empty.result"
[ "$("$ADAPTER" classify "$TMP_ROOT/empty.result")" = empty ] || fail "an empty result classifies as empty"
printf 'schema=something-else\nstatus=messages\n\n' > "$TMP_ROOT/foreign.result"
[ "$("$ADAPTER" classify "$TMP_ROOT/foreign.result")" = unknown ] || fail "a foreign result classifies as unknown"
# Payload text must never be able to forge a header field.
{
  printf 'schema=fm-slack-captain.v1\nstatus=messages\nuntrusted=1\n\n'
  printf 'untrusted=0\n'
} > "$TMP_ROOT/forge.result"
[ "$("$ADAPTER" classify "$TMP_ROOT/forge.result")" = untrusted-messages ] \
  || fail "payload text must not override a header field"
pass "classify refuses to be confused by an unfamiliar or forged result"

# --- the source is never terminal -------------------------------------------

"$ADAPTER" terminal "$out" && fail "a Slack captain source must never be terminal"
"$ADAPTER" terminal "$TMP_ROOT/apierror.out" && fail "even an error result must keep the source armed"
pass "the adapter never reports a terminal verdict"

# --- end-to-end: arm, run the source, capture, publish, classify ------------

home=$(new_home roundtrip)
slack_response "$(ok_body '[{"type":"message","user":"'"$CAPTAIN"'","ts":"500.000500","text":"ahoy"}]')"
armed=$(FM_HOME="$home" "$ADAPTER" arm 2>&1) || fail "arm failed: $armed"
assert_contains "$armed" "armed: $SID" "arm reports the registered source"
assert_present "$home/state/procevent/$SID.source" "arm registers the source"
FM_HOME="$home" "$ROOT/bin/fm-procevent.sh" start "$SID" > "$TMP_ROOT/start.out" 2>&1 \
  || fail "the runner failed: $(cat "$TMP_ROOT/start.out")"
result=$(printf '%s\n' "$home/state/procevent-inbox/$SID".*.result | head -n 1)
[ -f "$result" ] || fail "the runner captured no result: $(cat "$TMP_ROOT/start.out")"
[ "$(file_mode "$result")" = 600 ] || fail "a captured result must be private"
[ "$("$ADAPTER" classify "$result")" = messages ] || fail "the captured result should classify as messages"
assert_grep "procevent slack-captain $SID" "$home/state/.wake-queue" "the capture publishes a wake"
assert_present "$home/state/procevent/$SID.source" "the source stays armed after a capture"
assert_no_grep "$TOKEN" "$result" "a captured result must never carry the token"
seq=${result%.result}
seq=${seq##*.}
FM_HOME="$home" "$ADAPTER" handle "$SID" "$seq" "$result" >/dev/null \
  || fail "handling the captured result failed"
assert_grep 'ts=500.000500' "$(cursor_file "$home")" "handling advances the read position"
assert_present "$home/state/procevent-inbox/$SID.$seq.handled" "handling records the acknowledgement"
pass "register, poll, capture, publish, classify, and acknowledge round-trip"

# --- a captain reply inside a thread is captured, with its own read position --

# The thread firstmate itself started: the channel never shows the reply, so
# only conversations.replies can see it. This is the case that once left nine
# captain decisions unread.
home=$(new_home threadreply)
ROOT_TS=700.000700
REPLY_TS=701.000701
FM_HOME="$home" "$ADAPTER" track-thread "$CHANNEL" "$ROOT_TS" >/dev/null \
  || fail "registering a thread firstmate posted into must succeed"
thread_cursor() { printf '%s/state/slack-captain/threads/%s/%s.cursor\n' "$1" "$CHANNEL" "$2"; }
assert_grep "ts=$ROOT_TS" "$(thread_cursor "$home" "$ROOT_TS")" \
  "a newly tracked thread starts reading at its own root"

slack_response "$(ok_body '[]')"
printf '%s\n' '{"ok":true,"messages":[
  {"type":"message","user":"'"$BOT"'","ts":"'"$ROOT_TS"'","thread_ts":"'"$ROOT_TS"'","text":"decisions"},
  {"type":"message","user":"'"$CAPTAIN"'","ts":"'"$REPLY_TS"'","thread_ts":"'"$ROOT_TS"'","text":"option b"}
]}' > "$FAKE_SLACK_REPLIES"
"$ADAPTER" poll "$home" "$CHANNEL" > "$TMP_ROOT/thread.out" 2>/dev/null \
  || fail "a thread reply with a quiet channel must still produce a result"
assert_grep 'count=1' "$TMP_ROOT/thread.out" "the thread reply is captured"
assert_grep 'untrusted=0' "$TMP_ROOT/thread.out" "the captain's thread reply is trusted"
assert_grep "\"thread_ts\":\"$ROOT_TS\"" "$TMP_ROOT/thread.out" \
  "a captured thread reply names the thread it answers"
assert_grep "thread=$ROOT_TS $ROOT_TS $REPLY_TS 1" "$TMP_ROOT/thread.out" \
  "the result names the thread's committed span"
assert_grep "to_ts=0" "$TMP_ROOT/thread.out" \
  "a quiet channel's own read position is not moved by a thread reply"
[ "$("$ADAPTER" classify "$TMP_ROOT/thread.out")" = messages ] \
  || fail "a thread-only result classifies as messages"
assert_grep "ts=$ROOT_TS" "$(thread_cursor "$home" "$ROOT_TS")" \
  "the poll child must not advance a thread read position itself"
pass "a captain reply inside a thread is captured with its thread reference"

FM_HOME="$home" "$ADAPTER" autohandle "$SID" 1 "$TMP_ROOT/thread.out" >/dev/null 2>&1 \
  && fail "autohandle must still report failure so the result stays unacknowledged"
assert_grep "ts=$REPLY_TS" "$(thread_cursor "$home" "$ROOT_TS")" \
  "applying the result advances that thread's read position"
FM_HOME="$home" "$ADAPTER" autohandle "$SID" 1 "$TMP_ROOT/thread.out" >/dev/null 2>&1
assert_grep "ts=$REPLY_TS" "$(thread_cursor "$home" "$ROOT_TS")" \
  "re-applying the same thread span is a no-op"
: > "$FAKE_REPLIES_COUNT"
printf '%s\n' '{"ok":true,"messages":[]}' > "$FAKE_SLACK_REPLIES"
rc=0
"$ADAPTER" poll "$home" "$CHANNEL" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "a thread with no new replies must not produce a result"
assert_grep "oldest=$REPLY_TS" "$FAKE_CURL_ARGV" \
  "the next thread read resumes from the stored thread read position"
assert_grep 'conversations.replies' "$FAKE_CURL_ARGV" "the thread is read through conversations.replies"
pass "thread read-position continuity survives across polls and repeat application"

# A thread span that does not continue the stored position is refused, exactly
# like the channel position, and nothing is rebased.
printf 'schema=%s\nts=%s\n' fm-slack-captain-thread-cursor.v1 888.000888 \
  > "$(thread_cursor "$home" "$ROOT_TS")"
err=$(FM_HOME="$home" "$ADAPTER" handle "$SID" 2 "$TMP_ROOT/thread.out" 2>&1) && rc=0 || rc=$?
[ "$rc" -ne 0 ] || fail "a discontinuous thread span must be refused"
assert_contains "$err" "do not continue the stored read position for thread" \
  "the refusal must name the thread continuity break"
assert_grep "ts=888.000888" "$(thread_cursor "$home" "$ROOT_TS")" \
  "a refused thread span must not rebase the thread read position"
pass "a thread span that does not continue the stored position is refused loudly"

# --- a thread seen in channel history becomes tracked automatically ----------

home=$(new_home threaddiscovery)
: > "$FAKE_REPLIES_COUNT"
DISCOVER_ROOT=800.000800
slack_response "$(ok_body '[
  {"type":"message","user":"'"$CAPTAIN"'","ts":"'"$DISCOVER_ROOT"'","thread_ts":"'"$DISCOVER_ROOT"'","text":"topic"}
]')"
printf '%s\n' '{"ok":true,"messages":[]}' > "$FAKE_SLACK_REPLIES"
"$ADAPTER" poll "$home" "$CHANNEL" > "$TMP_ROOT/discover.out" 2>/dev/null \
  || fail "a poll seeing a thread root should still capture the root message"
assert_present "$(thread_cursor "$home" "$DISCOVER_ROOT")" \
  "a thread seen in the channel window becomes tracked"
pass "a thread rooted in the captured window is tracked without any manual step"

# An untrusted author is marked identically inside a thread.
home=$(new_home threadtrust)
: > "$FAKE_REPLIES_COUNT"
FM_HOME="$home" "$ADAPTER" track-thread "$CHANNEL" 900.000900 >/dev/null
slack_response "$(ok_body '[]')"
printf '%s\n' '{"ok":true,"messages":[
  {"type":"message","user":"'"$STRANGER"'","ts":"901.000901","thread_ts":"900.000900","text":"theirs"}
]}' > "$FAKE_SLACK_REPLIES"
"$ADAPTER" poll "$home" "$CHANNEL" > "$TMP_ROOT/threadtrust.out" 2>/dev/null \
  || fail "an untrusted thread reply should still be captured"
assert_grep 'untrusted=1' "$TMP_ROOT/threadtrust.out" "a non-captain thread author is counted untrusted"
[ "$("$ADAPTER" classify "$TMP_ROOT/threadtrust.out")" = untrusted-messages ] \
  || fail "a thread reply from another author classifies as untrusted"
pass "trust classification is identical inside a thread"

# --- the debounce window collects a burst into one result -------------------

# Each history call serves one more message than the last, so a hold that did
# not recollect would capture only the first.
home=$(new_home debounce)
: > "$FAKE_CURL_COUNT"
: > "$FAKE_REPLIES_COUNT"
for n in 1 2 3; do
  msgs=''
  for m in $(seq 1 "$n"); do
    [ -z "$msgs" ] || msgs="$msgs,"
    msgs="$msgs{\"type\":\"message\",\"user\":\"$CAPTAIN\",\"ts\":\"10$m.00010$m\",\"text\":\"burst $m\"}"
  done
  printf '{"ok":true,"messages":[%s]}\n' "$msgs" > "$FAKE_SLACK_RESPONSE.$n"
done
# The fourth read adds nothing: that quiet window is what ends the hold.
cp "$FAKE_SLACK_RESPONSE.3" "$FAKE_SLACK_RESPONSE.4"
cp "$FAKE_SLACK_RESPONSE.3" "$FAKE_SLACK_RESPONSE"
FM_SLACK_CAPTAIN_QUIET_WINDOW=0 FM_SLACK_CAPTAIN_MAX_QUIET_WINDOWS=3 \
  "$ADAPTER" poll "$home" "$CHANNEL" > "$TMP_ROOT/debounce.out" 2>/dev/null \
  || fail "a debounced burst should produce one result"
assert_grep 'count=3' "$TMP_ROOT/debounce.out" "the whole burst is captured as one result"
assert_grep 'to_ts=103.000103' "$TMP_ROOT/debounce.out" "the result commits the newest message of the burst"
[ "$(cat "$FAKE_CURL_COUNT")" = 4 ] \
  || fail "the hold should end on the first quiet window, not keep polling: $(cat "$FAKE_CURL_COUNT") reads"
assert_absent "$(cursor_file "$home")" "a held burst still marks nothing read before it is captured"
pass "a burst of captain messages is held open and captured as one result"

# A continuous stream still flushes: the hold is bounded, never open-ended.
home=$(new_home debouncebound)
: > "$FAKE_CURL_COUNT"
: > "$FAKE_REPLIES_COUNT"
rm -f "$FAKE_SLACK_RESPONSE".[0-9]*
for n in $(seq 1 12); do
  msgs=''
  for m in $(seq 1 "$n"); do
    [ -z "$msgs" ] || msgs="$msgs,"
    msgs="$msgs{\"type\":\"message\",\"user\":\"$CAPTAIN\",\"ts\":\"20$m.00020$m\",\"text\":\"stream $m\"}"
  done
  printf '{"ok":true,"messages":[%s]}\n' "$msgs" > "$FAKE_SLACK_RESPONSE.$n"
done
FM_SLACK_CAPTAIN_QUIET_WINDOW=0 FM_SLACK_CAPTAIN_MAX_QUIET_WINDOWS=3 \
  "$ADAPTER" poll "$home" "$CHANNEL" > "$TMP_ROOT/stream.out" 2>/dev/null \
  || fail "a continuous stream must still produce a result"
[ "$(cat "$FAKE_CURL_COUNT")" = 4 ] \
  || fail "the bounded hold should read exactly once plus its three windows: $(cat "$FAKE_CURL_COUNT")"
assert_grep 'count=4' "$TMP_ROOT/stream.out" "a bounded hold flushes everything collected so far"
rm -f "$FAKE_SLACK_RESPONSE".[0-9]*
pass "a continuous stream flushes after the bounded number of hold windows"

# The hold is real elapsed time, not an instant loop: with a one-second window
# the poll waits before capturing, and still captures the late message.
home=$(new_home debouncetiming)
: > "$FAKE_CURL_COUNT"
: > "$FAKE_REPLIES_COUNT"
printf '{"ok":true,"messages":[{"type":"message","user":"%s","ts":"301.000301","text":"first"}]}\n' \
  "$CAPTAIN" > "$FAKE_SLACK_RESPONSE.1"
printf '{"ok":true,"messages":[{"type":"message","user":"%s","ts":"302.000302","text":"late"},{"type":"message","user":"%s","ts":"301.000301","text":"first"}]}\n' \
  "$CAPTAIN" "$CAPTAIN" > "$FAKE_SLACK_RESPONSE.2"
cp "$FAKE_SLACK_RESPONSE.2" "$FAKE_SLACK_RESPONSE.3"
cp "$FAKE_SLACK_RESPONSE.2" "$FAKE_SLACK_RESPONSE"
started=$(date +%s)
FM_SLACK_CAPTAIN_QUIET_WINDOW=1 FM_SLACK_CAPTAIN_MAX_QUIET_WINDOWS=3 \
  "$ADAPTER" poll "$home" "$CHANNEL" > "$TMP_ROOT/timing.out" 2>/dev/null \
  || fail "a timed hold should still produce a result"
elapsed=$(( $(date +%s) - started ))
[ "$elapsed" -ge 1 ] || fail "the hold did not actually wait: ${elapsed}s"
assert_grep 'count=2' "$TMP_ROOT/timing.out" "a message that arrived during the hold is in the same result"
rm -f "$FAKE_SLACK_RESPONSE".[0-9]*
pass "the quiet window is a real wait that collects late messages"

# --- a thread the home does not track is refused, never invented ------------

home=$(new_home threadunknown)
: > "$FAKE_REPLIES_COUNT"
{
  printf 'schema=fm-slack-captain.v1\nstatus=messages\nchannel=%s\n' "$CHANNEL"
  printf 'from_ts=0\nto_ts=0\ncount=1\nuntrusted=0\nreason=\n'
  printf 'thread=950.000950 950.000950 951.000951 1\n\n'
  printf '{"ts":"951.000951","user":"%s","trusted":true,"text":"x","thread_ts":"950.000950"}\n' "$CAPTAIN"
} > "$TMP_ROOT/unknownthread.result"
err=$(FM_HOME="$home" "$ADAPTER" handle "$SID" 3 "$TMP_ROOT/unknownthread.result" 2>&1) && rc=0 || rc=$?
[ "$rc" -ne 0 ] || fail "a thread span for an untracked thread must be refused"
assert_contains "$err" "does not track" "the refusal must name the untracked thread"
assert_absent "$(thread_cursor "$home" 950.000950)" "a refused thread span must not create a read position"
pass "a result naming a thread this home does not track is refused"

# --- a thread past the age bound stops being read ---------------------------

home=$(new_home threadage)
: > "$FAKE_REPLIES_COUNT"
: > "$FAKE_CURL_ARGV"
FM_HOME="$home" "$ADAPTER" track-thread "$CHANNEL" 100.000100 >/dev/null
slack_response "$(ok_body '[]')"
printf '%s\n' '{"ok":true,"messages":[
  {"type":"message","user":"'"$CAPTAIN"'","ts":"101.000101","thread_ts":"100.000100","text":"ancient"}
]}' > "$FAKE_SLACK_REPLIES"
rc=0
FM_SLACK_CAPTAIN_THREAD_MAX_AGE=60 "$ADAPTER" poll "$home" "$CHANNEL" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "a thread past the age bound must not be read at all"
assert_no_grep 'conversations.replies' "$FAKE_CURL_ARGV" \
  "an aged-out thread must cost no request"
pass "a tracked thread past the age bound stops being polled"

# --- retention is keyed on last activity, not the thread's root age ---------

home=$(new_home threadactivity)
: > "$FAKE_REPLIES_COUNT"
: > "$FAKE_CURL_ARGV"
FM_HOME="$home" "$ADAPTER" track-thread "$CHANNEL" 800.000800 >/dev/null
recent="$(date +%s).000001"
{
  printf 'schema=fm-slack-captain.v1\nstatus=messages\nchannel=%s\n' "$CHANNEL"
  printf 'from_ts=0\nto_ts=0\ncount=1\nuntrusted=0\nreason=\n'
  printf 'thread=800.000800 800.000800 %s 1\n\n' "$recent"
  printf '{"ts":"%s","user":"%s","trusted":true,"text":"still going","thread_ts":"800.000800"}\n' \
    "$recent" "$CAPTAIN"
} > "$TMP_ROOT/activethread.result"
FM_HOME="$home" "$ADAPTER" autohandle "$SID" 4 "$TMP_ROOT/activethread.result" >/dev/null 2>&1
[ -e "$(thread_cursor "$home" 800.000800)" ] \
  || fail "applying a fresh reply to an old-rooted thread should advance its position"
slack_response "$(ok_body '[]')"
printf '%s\n' '{"ok":true,"messages":[]}' > "$FAKE_SLACK_REPLIES"
rc=0
FM_SLACK_CAPTAIN_THREAD_MAX_AGE=60 "$ADAPTER" poll "$home" "$CHANNEL" >/dev/null 2>&1 || rc=$?
assert_grep 'conversations.replies' "$FAKE_CURL_ARGV" \
  "a thread rooted long ago but replied to just now must still be polled"
pass "thread retention is keyed on last activity, not the root's age"
