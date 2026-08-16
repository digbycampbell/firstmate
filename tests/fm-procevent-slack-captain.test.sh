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
export FM_SLACK_CAPTAIN_MAX_LOOPS=1
export FM_SLACK_CAPTAIN_INTERVAL=0
export FM_SLACK_CAPTAIN_MAX_TIME=5

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
# FAKE_SLACK_RESPONSE into whatever -o names.
set -u
printf '%s\n' "$*" >> "$FAKE_CURL_ARGV"
cat >> "$FAKE_CURL_STDIN"
out=
prev=
for arg in "$@"; do
  [ "$prev" = -o ] && out=$arg
  prev=$arg
done
[ -n "$out" ] || exit 1
cat "$FAKE_SLACK_RESPONSE" > "$out"
exit "${FAKE_CURL_EXIT:-0}"
SH
chmod +x "$FAKEBIN/curl"
export PATH="$FAKEBIN:$PATH"
export FAKE_CURL_ARGV="$TMP_ROOT/curl.argv"
export FAKE_CURL_STDIN="$TMP_ROOT/curl.stdin"
export FAKE_SLACK_RESPONSE="$TMP_ROOT/slack.json"
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
