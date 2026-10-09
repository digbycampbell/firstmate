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
# A private file fetch from the stub file host serves FAKE_FILES/<last path
# segment> and prints the `-w` status line a real curl would: a .vtt as
# text/vtt, anything else as FAKE_FILE_TYPE. FAKE_FILE_FAIL makes it a
# transport failure.
case "$*" in
  *https://files.example.test/*)
    out=
    prev=
    for arg in "$@"; do
      [ "$prev" = -o ] && out=$arg
      prev=$arg
    done
    url=$prev
    name=${url##*/}
    [ -z "${FAKE_FILE_FAIL-}" ] || exit 7
    [ -n "$out" ] && [ -f "$FAKE_FILES/$name" ] || exit 22
    cat "$FAKE_FILES/$name" > "$out"
    case "$name" in
      *.vtt) printf '200 text/vtt' ;;
      *) printf '200 %s' "${FAKE_FILE_TYPE:-image/png}" ;;
    esac
    exit 0
    ;;
esac
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
export FAKE_FILES="$TMP_ROOT/files"
mkdir -p "$FAKE_FILES"
export FM_SLACK_CAPTAIN_FILES_HOST=https://files.example.test/
# Canned message timestamps are tiny epochs, so stored attachments would age
# out at once; the bound is exercised deliberately in its own case below.
export FM_SLACK_CAPTAIN_FILE_MAX_AGE=99999999999
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

# --- a configured peer bot is captured, always untrusted --------------------
# Only ids named in peer_bots= pass the bot_id filter. The bot's own user and
# every unlisted bot stay dropped, so a mirrored reply can never loop back.

PEER=U0PEERBOT1
PEER2=U0PEERBOT2
home=$(new_home peerbots)
printf 'peer_bots=%s,%s\n' "$PEER" "$PEER2" >> "$home/config/slack-captain"
slack_response "$(ok_body '[
  {"type":"message","user":"'"$CAPTAIN"'","ts":"420.000420","text":"owner says"},
  {"type":"message","bot_id":"B900","user":"'"$PEER"'","ts":"421.000421","text":"peer says"},
  {"type":"message","bot_id":"B901","user":"'"$BOT"'","ts":"422.000422","text":"own mirror"},
  {"type":"message","bot_id":"B902","user":"'"$STRANGER"'","ts":"423.000423","text":"unlisted bot"},
  {"type":"message","bot_id":"B903","ts":"424.000424","text":"botless user field"}
]')"
"$ADAPTER" poll "$home" "$CHANNEL" > "$TMP_ROOT/peer.out" 2>/dev/null   || fail "a poll seeing an owner and a peer bot message should succeed"
assert_grep 'count=2' "$TMP_ROOT/peer.out" "only the owner and the listed peer bot are captured"
assert_grep '"text":"owner says"' "$TMP_ROOT/peer.out" "the owner message is captured"
assert_grep '"text":"peer says"' "$TMP_ROOT/peer.out" "the peer bot message is captured"
assert_no_grep 'own mirror' "$TMP_ROOT/peer.out" "the bot's own post stays dropped even with peer_bots set"
assert_no_grep 'unlisted bot' "$TMP_ROOT/peer.out" "an unlisted bot stays dropped"
assert_no_grep 'botless user field' "$TMP_ROOT/peer.out" "a bot message with no user id stays dropped"
assert_grep '"user":"'"$PEER"'","trusted":false' "$TMP_ROOT/peer.out" \
  "a peer bot message is untrusted and names its bot user"
assert_grep '"user":"'"$CAPTAIN"'","trusted":true' "$TMP_ROOT/peer.out" "the owner stays trusted"
assert_grep 'untrusted=1' "$TMP_ROOT/peer.out" "the peer bot message is counted untrusted"
[ "$("$ADAPTER" classify "$TMP_ROOT/peer.out")" = untrusted-messages ] \
  || fail "a result carrying a peer bot message classifies as untrusted-messages"
pass "a listed peer bot is captured untrusted; own and unlisted bots stay dropped"

# A peer bot that is also the configured owner or the firstmate bot changes nothing.
home=$(new_home peerbotself)
printf 'peer_bots=%s,%s\n' "$BOT" "$CAPTAIN" >> "$home/config/slack-captain"
slack_response "$(ok_body '[
  {"type":"message","bot_id":"B901","user":"'"$BOT"'","ts":"430.000430","text":"own mirror"}
]')"
rc=0
"$ADAPTER" poll "$home" "$CHANNEL" > "$TMP_ROOT/peerself.out" 2>/dev/null || rc=$?
[ "$rc" -ne 0 ] || [ ! -s "$TMP_ROOT/peerself.out" ] \
  || fail "listing firstmate's own bot as a peer must not let its posts loop back"
pass "the bot's own user can never be a peer bot"

# An invalid peer id is a configuration refusal, not a silent widening.
home=$(new_home peerbotbad)
printf 'peer_bots=%s,bad id!\n' "$PEER" >> "$home/config/slack-captain"
rc=0
"$ADAPTER" poll "$home" "$CHANNEL" > "$TMP_ROOT/peerbad.out" 2>"$TMP_ROOT/peerbad.err" || rc=$?
[ "$rc" -ne 0 ] || fail "an invalid peer_bots id must be refused"
assert_grep 'peer_bots' "$TMP_ROOT/peerbad.err" "the refusal names the offending key"
pass "an invalid peer_bots id is refused"

# The same filter covers thread replies.
home=$(new_home peerthread)
printf 'peer_bots=%s\n' "$PEER" >> "$home/config/slack-captain"
FM_HOME="$home" "$ADAPTER" track-thread "$CHANNEL" 440.000440 >/dev/null \
  || fail "registering a thread must succeed"
slack_response "$(ok_body '[]')"
cat > "$FAKE_SLACK_REPLIES" <<JSON
{"ok":true,"messages":[
  {"type":"message","user":"$BOT","ts":"440.000440","thread_ts":"440.000440","text":"root"},
  {"type":"message","bot_id":"B900","user":"$PEER","ts":"441.000441","thread_ts":"440.000440","text":"peer in thread"},
  {"type":"message","bot_id":"B902","user":"$STRANGER","ts":"442.000442","thread_ts":"440.000440","text":"unlisted in thread"}
]}
JSON
"$ADAPTER" poll "$home" "$CHANNEL" > "$TMP_ROOT/peerthread.out" 2>/dev/null \
  || fail "a peer bot reply in a tracked thread must produce a result"
assert_grep 'count=1' "$TMP_ROOT/peerthread.out" "only the peer bot thread reply is captured"
assert_grep '"text":"peer in thread"' "$TMP_ROOT/peerthread.out" "the peer bot thread reply is captured"
assert_no_grep 'unlisted in thread' "$TMP_ROOT/peerthread.out" "an unlisted bot in a thread stays dropped"
assert_grep '"trusted":false' "$TMP_ROOT/peerthread.out" "the peer bot thread reply is untrusted"
pass "a peer bot reply inside a tracked thread is captured untrusted"

# --- a peer bot never steals the mirror's reply target ----------------------
# The newest captured message names the reply thread. A peer bot posting after
# the owner must not redirect the reply, unless it is the only message.

mirror_inbound() { cat "$1/state/slack-captain/mirror.inbound" 2>/dev/null; }
home=$(new_home peertarget)
printf 'peer_bots=%s\n' "$PEER" >> "$home/config/slack-captain"
slack_response "$(ok_body '[
  {"type":"message","user":"'"$CAPTAIN"'","ts":"450.000450","text":"owner first"},
  {"type":"message","bot_id":"B900","user":"'"$PEER"'","ts":"451.000451","text":"peer later"}
]')"
"$ADAPTER" poll "$home" "$CHANNEL" > "$TMP_ROOT/peertarget.out" 2>/dev/null \
  || fail "poll for the reply-target case should succeed"
FM_HOME="$home" "$ADAPTER" autohandle "$SID" 7 "$TMP_ROOT/peertarget.out" >/dev/null 2>&1 || true
assert_grep 'ts=450.000450' <(mirror_inbound "$home") \
  "the owner's message, not the later peer bot message, is the reply target"

home=$(new_home peeronly)
printf 'peer_bots=%s\n' "$PEER" >> "$home/config/slack-captain"
slack_response "$(ok_body '[
  {"type":"message","bot_id":"B900","user":"'"$PEER"'","ts":"460.000460","text":"peer alone"}
]')"
"$ADAPTER" poll "$home" "$CHANNEL" > "$TMP_ROOT/peeronly.out" 2>/dev/null \
  || fail "poll for the peer-only case should succeed"
FM_HOME="$home" "$ADAPTER" autohandle "$SID" 8 "$TMP_ROOT/peeronly.out" >/dev/null 2>&1 || true
assert_grep 'ts=460.000460' <(mirror_inbound "$home") \
  "a peer bot message that is the only one in the turn is the reply target"
pass "a peer bot message is a reply target only when nothing else was captured"

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
# A span that starts after the stored position would skip what lies between.
sed 's/^from_ts=0$/from_ts=150.000150/' "$out" > "$TMP_ROOT/gap.result"
printf 'schema=%s\nts=%s\n' fm-slack-captain-cursor.v1 100.000100 > "$(cursor_file "$home")"
err=$(FM_HOME="$home" "$ADAPTER" handle "$SID" 1 "$TMP_ROOT/gap.result" 2>&1) && rc=0 || rc=$?
[ "$rc" -ne 0 ] || fail "a discontinuous result must be refused"
assert_contains "$err" "do not continue the stored read position" \
  "the refusal must name the continuity break"
assert_grep 'ts=100.000100' "$(cursor_file "$home")" "a refused result must not rebase the read position"
pass "a result that does not continue the stored position is refused loudly"

# --- an out-of-order capture the read position already covers ----------------
#
# The 2026-10-04 wedge: two debounce captures of one span (723: 0..100, 724:
# 0..200) arrived together and 724 was handled first. 723 ends inside what is
# already applied, so it is acknowledged as superseded, never refused forever.
# autohandle applies exactly what handle applies, minus the acknowledgement
# (which needs a registered source), and prints the same verdict line.
home=$(new_home outoforder)
sed 's/^to_ts=200.000200$/to_ts=100.000100/' "$out" > "$TMP_ROOT/older.result"
msg=$(FM_HOME="$home" "$ADAPTER" autohandle "$SID" 724 "$out" 2>&1)
assert_contains "$msg" "applied: $SID" "the newer, wider capture applies"
assert_grep 'ts=200.000200' "$(cursor_file "$home")" "the newer capture advances the read position"
msg=$(FM_HOME="$home" "$ADAPTER" autohandle "$SID" 723 "$TMP_ROOT/older.result" 2>&1)
assert_contains "$msg" "superseded: $SID" "an older capture the read position covers is superseded, not refused"
assert_grep 'ts=200.000200' "$(cursor_file "$home")" "a superseded capture never moves the read position back"
# The same pair in arrival order: the wider capture starts before the stored
# position and reaches past it, so it applies without skipping anything.
home=$(new_home inorder)
msg=$(FM_HOME="$home" "$ADAPTER" autohandle "$SID" 723 "$TMP_ROOT/older.result" 2>&1)
assert_contains "$msg" "applied: $SID" "the older capture applies first in arrival order"
msg=$(FM_HOME="$home" "$ADAPTER" autohandle "$SID" 724 "$out" 2>&1)
assert_contains "$msg" "applied: $SID" "a wider capture overlapping the stored position applies"
assert_grep 'ts=200.000200' "$(cursor_file "$home")" "the overlapping capture advances to its end"
pass "overlapping debounce captures apply in either order and the covered one is superseded"

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
sed "s/^thread=$ROOT_TS $ROOT_TS /thread=$ROOT_TS 900.000900 /" "$TMP_ROOT/thread.out" > "$TMP_ROOT/thread-gap.out"
err=$(FM_HOME="$home" "$ADAPTER" handle "$SID" 2 "$TMP_ROOT/thread-gap.out" 2>&1) && rc=0 || rc=$?
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

# --- attachments: images are fetched, clips carry their transcript ----------
# The canned files[] objects follow the shape conversations.history returns:
# an image carries url_private_download; a voice clip carries Slack's
# transcription object and, when its preview is cut short, a WebVTT track.

FILE_HOST=https://files.example.test
printf 'PNGDATA\n' > "$FAKE_FILES/shot.png"
printf 'WEBVTT\n\n1\n00:00:00.000 --> 00:00:02.000\nhello there\n\n2\n00:00:02.000 --> 00:00:04.000\nthe whole clip\n' \
  > "$FAKE_FILES/long.vtt"
attachments_body() {
  ok_body '[
  {"type":"message","user":"'"$CAPTAIN"'","ts":"900.000900","text":"look at this","files":[
    {"id":"F0IMAGE1","name":"../../../../escape me.png","title":"shot","mimetype":"image/png",
     "filetype":"png","size":8,"mode":"hosted","media_display_type":"unknown",
     "url_private":"'"$FILE_HOST"'/files-pri/T1-F0IMAGE1/shot.png",
     "url_private_download":"'"$FILE_HOST"'/files-pri/T1-F0IMAGE1/download/shot.png"},
    {"id":"../F0EVIL","name":"evil.png","mimetype":"image/png","filetype":"png","size":8,
     "url_private_download":"'"$FILE_HOST"'/files-pri/T1-EVIL/download/shot.png"},
    {"id":"F0ELSEWHERE","name":"far.png","mimetype":"image/png","filetype":"png","size":8,
     "url_private_download":"https://attacker.example.test/steal/shot.png"}
  ]},
  {"type":"message","user":"'"$CAPTAIN"'","ts":"901.000901","text":"","files":[
    {"id":"F0AUDIO1","name":"audio_message.webm","mimetype":"audio/webm","filetype":"webm",
     "subtype":"slack_audio","media_display_type":"audio","size":5000,
     "url_private_download":"'"$FILE_HOST"'/files-pri/T1-F0AUDIO1/download/clip.webm",
     "transcription":{"status":"complete","locale":"en-US",
       "preview":{"content":"short voice note","has_more":false}}},
    {"id":"F0AUDIO2","name":"audio_message.webm","mimetype":"audio/webm","filetype":"webm",
     "subtype":"slack_audio","media_display_type":"audio","size":9000,
     "vtt":"'"$FILE_HOST"'/files-tmb/T1-F0AUDIO2/long.vtt",
     "transcription":{"status":"complete","locale":"en-US",
       "preview":{"content":"hello","has_more":true}}},
    {"id":"F0AUDIO3","name":"audio_message.webm","mimetype":"audio/webm","filetype":"webm",
     "subtype":"slack_audio","media_display_type":"audio","size":9000,
     "transcription":{"status":"processing"}},
    {"id":"F0VIDEO1","name":"clip.mp4","mimetype":"video/mp4","filetype":"mp4",
     "subtype":"slack_video","media_display_type":"video","size":90000,
     "url_private_download":"'"$FILE_HOST"'/files-pri/T1-F0VIDEO1/download/clip.mp4"}
  ]}
]'
}

home=$(new_home attachments)
: > "$FAKE_CURL_ARGV"
slack_response "$(attachments_body)"
out="$TMP_ROOT/attachments.result"
"$ADAPTER" poll "$home" "$CHANNEL" > "$out" 2>"$TMP_ROOT/attachments.err" \
  || fail "a poll that sees attachments should succeed: $(cat "$TMP_ROOT/attachments.err")"
store="$home/state/slack-captain/files/$CHANNEL"
image="$store/900.000900/F0IMAGE1.png"
msg() { LC_ALL=C awk 'body { print } $0 == "" { body = 1 }' "$out" | jq -c --arg ts "$1" 'select(.ts == $ts)'; }
file_of() { msg "$1" | jq -c --arg id "$2" '.files[] | select(.id == $id)'; }

assert_grep 'count=2' "$out" "both messages are captured, including one with no text"
[ "$(file_of 900.000900 F0IMAGE1 | jq -c '{id, name, mimetype, size, kind}')" \
  = '{"id":"F0IMAGE1","name":"../../../../escape me.png","mimetype":"image/png","size":8,"kind":"image"}' ] \
  || fail "the image's identity is not projected: $(file_of 900.000900 F0IMAGE1)"
pass "each attached file keeps its id, name, mimetype, size, and kind"

[ "$(cat "$image" 2>/dev/null)" = PNGDATA ] || fail "the image bytes were not stored under its id"
[ "$(file_of 900.000900 F0IMAGE1 | jq -r '.download + " " + .path')" = "saved $image" ] \
  || fail "the stored path is not recorded next to the file entry"
[ "$(file_mode "$image")" = 600 ] || fail "a stored image must be private"
[ "$(file_mode "$store/900.000900")" = 700 ] || fail "the per-message directory must be private"
[ "$(file_mode "$home/state/slack-captain/files")" = 700 ] || fail "the attachment store must be private"
assert_grep "file=900.000900 F0IMAGE1 image saved $image" "$out" \
  "the stored image is named in the result header"
assert_grep "Authorization: Bearer $TOKEN" "$FAKE_CURL_STDIN" "the file fetch carries the token on stdin"
assert_no_grep "$TOKEN" "$FAKE_CURL_ARGV" "the token never reaches a file fetch's argv"
pass "an image is downloaded into the private store and its path recorded"

[ -z "$(find "$TMP_ROOT" -name 'escape me.png' 2>/dev/null)" ] \
  || fail "a file name chose a path on disk"
[ -z "$(find "$home" -path '*F0EVIL*' 2>/dev/null)" ] || fail "an invalid file id chose a path on disk"
[ "$(file_of 900.000900 ../F0EVIL | jq -r '.download + " " + .download_error')" = 'failed invalid-id' ] \
  || fail "an invalid file id must be recorded as a failure, not fetched"
[ "$(file_of 900.000900 F0ELSEWHERE | jq -r '.download + " " + .download_error')" = 'failed untrusted-url' ] \
  || fail "a file URL off Slack's file host must not be fetched"
assert_no_grep 'attacker.example.test' "$FAKE_CURL_ARGV" "the token is never sent to another host"
assert_grep 'file=900.000900 invalid image failed invalid-id' "$out" \
  "an invalid id never reaches the header verbatim"
pass "file names and ids never pick a path, and the token goes only to Slack's file host"

[ "$(file_of 901.000901 F0AUDIO1 | jq -c '{kind, transcript, transcript_truncated, download}')" \
  = '{"kind":"audio","transcript":"short voice note","transcript_truncated":false,"download":"skipped"}' ] \
  || fail "a voice clip's transcript is not carried: $(file_of 901.000901 F0AUDIO1)"
[ "$(file_of 901.000901 F0AUDIO2 | jq -c '{transcript, transcript_truncated}')" \
  = '{"transcript":"hello there the whole clip","transcript_truncated":false}' ] \
  || fail "a truncated preview is not completed from the clip's WebVTT track: $(file_of 901.000901 F0AUDIO2)"
[ "$(file_of 901.000901 F0AUDIO3 | jq -c '{transcript, transcript_status}')" \
  = '{"transcript":null,"transcript_status":"processing"}' ] \
  || fail "a clip with no finished transcript must say so"
[ "$(file_of 901.000901 F0VIDEO1 | jq -c '{kind, download}')" = '{"kind":"video","download":"skipped"}' ] \
  || fail "a video clip is identified but not fetched"
assert_no_grep 'clip.webm\|clip.mp4' "$FAKE_CURL_ARGV" "clip bytes are never downloaded"
assert_grep 'file=901.000901 F0AUDIO1 audio skipped transcript-in-message' "$out" \
  "the header points at a clip's transcript"
assert_grep 'file=901.000901 F0AUDIO3 audio skipped no-transcript' "$out" \
  "the header says when a clip has no transcript"
assert_no_grep '"_url"\|"_vtt"\|"_ext"' "$out" "internal fetch fields never reach the result"
pass "a voice clip carries Slack's transcript; video is identified only"

handled=$(FM_HOME="$home" "$ADAPTER" autohandle "$SID" 1 "$out" 2>&1) || true
assert_grep "attachment: 900.000900 F0IMAGE1 image saved $image" <(printf '%s\n' "$handled") \
  "handling a result lists the stored image"
pass "applying a result surfaces each attachment"

# --- a failed download never loses the message -------------------------------

home=$(new_home attachfail)
slack_response "$(attachments_body)"
out="$TMP_ROOT/attachfail.result"
FAKE_FILE_FAIL=1 "$ADAPTER" poll "$home" "$CHANNEL" > "$out" 2>/dev/null \
  || fail "a failed file fetch must not fail the capture"
assert_grep 'count=2' "$out" "both messages survive a failed file fetch"
assert_grep '"text":"look at this"' "$out" "the text survives a failed file fetch"
[ "$(file_of 900.000900 F0IMAGE1 | jq -r '.download + " " + .download_error')" = 'failed fetch-failed' ] \
  || fail "the failure is recorded next to the file entry"
[ "$(file_of 901.000901 F0AUDIO2 | jq -c '{transcript, transcript_truncated}')" \
  = '{"transcript":"hello","transcript_truncated":true}' ] \
  || fail "a failed WebVTT fetch must keep Slack's preview"
assert_grep 'file=900.000900 F0IMAGE1 image failed fetch-failed' "$out" "the header records the failure"
[ -z "$(find "$home/state/slack-captain/files" -type f 2>/dev/null)" ] \
  || fail "a failed fetch must leave no partial file"
pass "a failed download still captures the message and records the failure"

home=$(new_home attachhtml)
slack_response "$(attachments_body)"
out="$TMP_ROOT/attachhtml.result"
FAKE_FILE_TYPE='text/html; charset=utf-8' "$ADAPTER" poll "$home" "$CHANNEL" > "$out" 2>/dev/null \
  || fail "an HTML file response must not fail the capture"
[ "$(file_of 900.000900 F0IMAGE1 | jq -r '.download_error')" = bad-response ] \
  || fail "Slack's HTML sign-in page must not be stored as the image"
pass "an HTML sign-in page is refused as a download"

home=$(new_home attachbig)
slack_response "$(attachments_body)"
out="$TMP_ROOT/attachbig.result"
: > "$FAKE_CURL_ARGV"
FM_SLACK_CAPTAIN_FILE_MAX_BYTES=4 "$ADAPTER" poll "$home" "$CHANNEL" > "$out" 2>/dev/null \
  || fail "an oversized file must not fail the capture"
[ "$(file_of 900.000900 F0IMAGE1 | jq -r '.download + " " + .download_error')" = 'skipped too-large' ] \
  || fail "a file over the size cap must be skipped"
assert_no_grep 'T1-F0IMAGE1' "$FAKE_CURL_ARGV" "an oversized file is never requested"
pass "a file over the size cap is skipped"

# --- stored attachments expire ----------------------------------------------

home=$(new_home attachprune)
slack_response "$(attachments_body)"
out="$TMP_ROOT/attachprune.result"
"$ADAPTER" poll "$home" "$CHANNEL" > "$out" 2>/dev/null || fail "poll for the expiry case should succeed"
store="$home/state/slack-captain/files/$CHANNEL"
[ -d "$store/900.000900" ] || fail "the expiry case needs a stored attachment"
FM_HOME="$home" "$ADAPTER" autohandle "$SID" 1 "$out" >/dev/null 2>&1 || true
[ -d "$store/900.000900" ] || fail "a stored attachment inside the age bound must be kept"
FM_HOME="$home" FM_SLACK_CAPTAIN_FILE_MAX_AGE=60 "$ADAPTER" autohandle "$SID" 1 "$out" >/dev/null 2>&1 || true
[ ! -e "$store/900.000900" ] || fail "a stored attachment past the age bound must be removed"
pass "stored attachments are removed once past their age bound"

# --- poll_interval is configurable, the environment still wins ---------------

SLEEPBIN="$TMP_ROOT/sleepbin"
mkdir -p "$SLEEPBIN"
cat > "$SLEEPBIN/sleep" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_SLEEP_LOG"
SH
chmod +x "$SLEEPBIN/sleep"
export FAKE_SLEEP_LOG="$TMP_ROOT/sleep.log"
home=$(new_home pollinterval)
printf 'poll_interval=7\n' >> "$home/config/slack-captain"
slack_response "$(ok_body '[]')"
: > "$FAKE_SLEEP_LOG"
(unset FM_SLACK_CAPTAIN_INTERVAL; PATH="$SLEEPBIN:$PATH" FM_SLACK_CAPTAIN_MAX_LOOPS=2 \
  "$ADAPTER" poll "$home" "$CHANNEL" >/dev/null 2>&1) || true
[ "$(cat "$FAKE_SLEEP_LOG")" = 7 ] || fail "poll_interval must set the listening interval: $(cat "$FAKE_SLEEP_LOG")"
: > "$FAKE_SLEEP_LOG"
(PATH="$SLEEPBIN:$PATH" FM_SLACK_CAPTAIN_INTERVAL=3 FM_SLACK_CAPTAIN_MAX_LOOPS=2 \
  "$ADAPTER" poll "$home" "$CHANNEL" >/dev/null 2>&1) || true
[ "$(cat "$FAKE_SLEEP_LOG")" = 3 ] || fail "the environment override must win over poll_interval"
printf 'poll_interval=soon\n' >> "$home/config/slack-captain"
rc=0
(unset FM_SLACK_CAPTAIN_INTERVAL; "$ADAPTER" poll "$home" "$CHANNEL" >/dev/null 2>"$TMP_ROOT/interval.err") || rc=$?
[ "$rc" -ne 0 ] || fail "an invalid poll_interval must be refused"
assert_grep 'poll_interval' "$TMP_ROOT/interval.err" "the refusal names poll_interval"
pass "poll_interval sets the listening interval and the environment still overrides it"
