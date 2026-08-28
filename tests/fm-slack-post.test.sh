#!/usr/bin/env bash
# Behavior tests for the outbound Slack post helper.
#
# Slack is replaced by a fake `curl` on PATH that records its argv, the config
# it received on stdin, and the request body, so token confinement and the exact
# posted JSON are asserted rather than merely documented. Nothing here touches
# the network.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
POST="$ROOT/bin/fm-slack-post.sh"
TMP_ROOT=$(fm_test_tmproot fm-slack-post)
trap fm_test_cleanup EXIT
export TMPDIR="$TMP_ROOT/tmp"
mkdir -p "$TMPDIR"

CHANNEL=C0TESTCHAN
QUOTA=C0QUOTA
CAPTAIN=U0CAPTAIN
TOKEN='xoxb-fake-000-supersecret'

FAKEBIN=$(fm_fakebin "$TMP_ROOT")
cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
# Stand-in for chat.postMessage: records argv, the stdin config, and the request
# body, then serves FAKE_SLACK_RESPONSE into whatever -o names.
set -u
printf '%s\n' "$*" >> "$FAKE_CURL_ARGV"
cat >> "$FAKE_CURL_STDIN"
out=
prev=
for arg in "$@"; do
  [ "$prev" = -o ] && out=$arg
  case "$arg" in
    @*) [ "$prev" = --data-binary ] && cp "${arg#@}" "$FAKE_POST_BODY" ;;
  esac
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
export FAKE_POST_BODY="$TMP_ROOT/post.body.json"
export FAKE_SLACK_RESPONSE="$TMP_ROOT/slack.json"
: > "$FAKE_CURL_ARGV"
: > "$FAKE_CURL_STDIN"
printf '{"ok":true,"ts":"500.000500"}\n' > "$FAKE_SLACK_RESPONSE"

new_home() {  # <name> [--no-captain]
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/config"
  printf 'general=%s\nquota=%s\n' "$CHANNEL" "$QUOTA" > "$home/config/slack-channels"
  if [ "${2-}" != --no-captain ]; then
    {
      printf 'channel=%s\n' "$CHANNEL"
      printf 'allowed_user=%s\n' "$CAPTAIN"
    } > "$home/config/slack-captain"
  fi
  printf 'SLACK_BOT_TOKEN=%s\n' "$TOKEN" > "$home/.env"
  chmod 600 "$home/.env"
  printf '%s\n' "$home"
}

thread_cursor() { printf '%s/state/slack-captain/threads/%s/%s.cursor\n' "$1" "$2" "$3"; }
body_field() { jq -r "$1" "$FAKE_POST_BODY"; }

# --- a message is posted, and the posted timestamp comes back ---------------

home=$(new_home post)
# The literal command substitution below is the point: it must survive as data.
# shellcheck disable=SC2016
out=$(FM_HOME="$home" "$POST" general 'ready $(touch /tmp/fm-slack-post-pwned)' 2>"$TMP_ROOT/post.err") \
  || fail "posting a message should succeed: $(cat "$TMP_ROOT/post.err")"
[ "$out" = 500.000500 ] || fail "the posted timestamp should be printed alone, got: $out"
[ "$(body_field .channel)" = "$CHANNEL" ] || fail "a configured channel name must resolve to its id"
# shellcheck disable=SC2016 # The unexpanded literal is exactly what must round-trip.
[ "$(body_field .text)" = 'ready $(touch /tmp/fm-slack-post-pwned)' ] \
  || fail "message text must be carried as data"
assert_absent /tmp/fm-slack-post-pwned "message text must never be expanded by a shell"
[ "$(body_field 'has("thread_ts")')" = false ] || fail "a top-level post must carry no thread_ts"
assert_grep 'chat.postMessage' "$FAKE_CURL_ARGV" "the message is posted through chat.postMessage"
[ ! -s "$TMP_ROOT/post.err" ] || fail "a successful post must be silent: $(cat "$TMP_ROOT/post.err")"
pass "a message is posted to a named channel and its timestamp is returned"

# --- the token never reaches argv or the request body -----------------------

assert_no_grep "$TOKEN" "$FAKE_CURL_ARGV" "the token must never appear in curl argv"
assert_no_grep "$TOKEN" "$FAKE_POST_BODY" "the token must never appear in the request body"
assert_grep "Authorization: Bearer $TOKEN" "$FAKE_CURL_STDIN" "the token reaches curl only on stdin"
pass "the token is confined to curl's stdin"

# --- the post registers its thread for inbound capture ----------------------

assert_absent "$(thread_cursor "$home" "$CHANNEL" 500.000500)" \
  "a top-level post must not register a tracked thread of its own"
printf '{"ok":true,"ts":"501.000501"}\n' > "$FAKE_SLACK_RESPONSE"
FM_HOME="$home" "$POST" general --thread 400.000400 'in thread' >/dev/null \
  || fail "a threaded post should succeed"
[ "$(body_field .thread_ts)" = 400.000400 ] || fail "--thread must post into that thread"
assert_present "$(thread_cursor "$home" "$CHANNEL" 400.000400)" \
  "a threaded post registers the thread it replied into"
assert_absent "$(thread_cursor "$home" "$CHANNEL" 501.000501)" \
  "a reply's own timestamp is not a separate thread"
pass "a post registers the thread a captain reply would land in"

# A channel this home does not watch registers nothing.
printf '{"ok":true,"ts":"502.000502"}\n' > "$FAKE_SLACK_RESPONSE"
FM_HOME="$home" "$POST" quota 'topic-ish' >/dev/null || fail "posting to another channel should succeed"
assert_absent "$(thread_cursor "$home" "$QUOTA" 502.000502)" \
  "a channel that is not watched registers no thread"
pass "thread registration is limited to the watched captain channel"

# --- channel resolution refuses to guess ------------------------------------

err=$(FM_HOME="$home" "$POST" nosuch 'hello' 2>&1) && rc=0 || rc=$?
[ "$rc" -ne 0 ] || fail "an unknown channel name must be refused"
assert_contains "$err" "no entry for 'nosuch'" "the refusal must name the unresolved channel"
printf '{"ok":true,"ts":"503.000503"}\n' > "$FAKE_SLACK_RESPONSE"
FM_HOME="$home" "$POST" "$QUOTA" 'by id' >/dev/null || fail "a raw channel id should post"
[ "$(body_field .channel)" = "$QUOTA" ] || fail "a raw channel id must pass through"
FM_HOME="$home" "$POST" '#general' 'hashed' >/dev/null || fail "a leading # should be accepted"
[ "$(body_field .channel)" = "$CHANNEL" ] || fail "a #name must resolve like a name"
pass "a channel name resolves through the local map, and an unknown one is refused"

# --- message body sources ---------------------------------------------------

printf 'from a file\nsecond line\n' > "$TMP_ROOT/message.txt"
FM_HOME="$home" "$POST" general --file "$TMP_ROOT/message.txt" >/dev/null \
  || fail "--file should post the file contents"
[ "$(body_field .text)" = 'from a file
second line' ] || fail "--file must carry the whole file"
err=$(FM_HOME="$home" "$POST" general 'text' --file "$TMP_ROOT/message.txt" 2>&1) && rc=0 || rc=$?
[ "$rc" -ne 0 ] || fail "text and --file together must be refused"
assert_contains "$err" "not both" "the refusal must name the conflict"
err=$(FM_HOME="$home" "$POST" general 2>&1) && rc=0 || rc=$?
[ "$rc" -ne 0 ] || fail "an empty message must be refused"
pass "the message comes from arguments or --file, never ambiguously"

# --- the worker-details convention ------------------------------------------

FM_HOME="$home" "$POST" general 'work landed' --worker-details 'opus-5 high' >/dev/null \
  || fail "--worker-details should post"
[ "$(body_field .text)" = 'work landed

_worker: opus-5 high_' ] || fail "the completion convention must be appended verbatim"
err=$(FM_HOME="$home" "$POST" general 'x' --worker-details 'opus; rm -rf /' 2>&1) && rc=0 || rc=$?
[ "$rc" -ne 0 ] || fail "an unsafe worker-details value must be refused"
pass "--worker-details appends the standing completion convention"

# --- failures are loud ------------------------------------------------------

printf '{"ok":false,"error":"channel_not_found"}\n' > "$FAKE_SLACK_RESPONSE"
err=$(FM_HOME="$home" "$POST" general 'nowhere' 2>&1) && rc=0 || rc=$?
[ "$rc" -ne 0 ] || fail "a Slack error must be a refusal"
assert_contains "$err" "channel_not_found" "the refusal must name the Slack error"
printf '{"ok":true,"ts":"600.000600"}\n' > "$FAKE_SLACK_RESPONSE"
home=$(new_home notoken)
: > "$home/.env"
err=$(FM_HOME="$home" "$POST" general 'hello' 2>&1) && rc=0 || rc=$?
[ "$rc" -ne 0 ] || fail "posting without a token must be refused"
assert_contains "$err" "SLACK_BOT_TOKEN" "the refusal must name the missing credential"
pass "a Slack error and an absent token are both loud refusals"

# --- a stalled Slack cannot hang the caller ---------------------------------
#
# curl's --max-time is a single in-band guard; a curl wedged outside its own
# transfer accounting outlasts it. The hard wall-clock ceiling is the defense.
# The stand-in ignores --max-time and sleeps far past the ceiling, so a caller
# with no ceiling would block for the full sleep and report an unreadable
# response, never "timed out" - this asserts the ceiling fired instead.
HANGBIN="$TMP_ROOT/hangbin"
mkdir -p "$HANGBIN"
cat > "$HANGBIN/curl" <<SH
#!/usr/bin/env bash
printf 'started\n' >> "$TMP_ROOT/hang.log"
sleep 30
SH
chmod +x "$HANGBIN/curl"
: > "$TMP_ROOT/hang.log"
home=$(new_home hang)
start=$(date +%s)
err=$(PATH="$HANGBIN:$PATH" FM_HOME="$home" \
  FM_SLACK_POST_HARD_TIMEOUT=2 FM_SLACK_POST_MAX_TIME=1 \
  "$POST" general 'hi captain' 2>&1) && rc=0 || rc=$?
end=$(date +%s)
[ "$rc" -ne 0 ] || fail "a hung Slack must be a nonzero refusal"
assert_contains "$err" "timed out" "the hard-ceiling refusal must name the timeout, not a downstream parse error"
[ -s "$TMP_ROOT/hang.log" ] || fail "the ceiling fired before curl ran, so it proves nothing about a hang"
[ "$((end - start))" -lt 8 ] \
  || fail "the hard wall-clock ceiling did not stop a curl ignoring --max-time ($((end - start))s)"
pkill -f "$HANGBIN/curl" 2>/dev/null || true
pass "a curl that ignores --max-time is stopped by the hard wall-clock ceiling"
