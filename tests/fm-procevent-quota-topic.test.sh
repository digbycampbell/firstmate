#!/usr/bin/env bash
# Behavior tests for the live quota channel-topic process-event adapter.
#
# Both external sources are replaced on PATH: a fake `quota-axi` serving a canned
# document, and a fake `curl` serving canned Kimi usage and Slack responses while
# recording its argv and the config it received on stdin. Nothing here touches
# the network.
#
# What is asserted is the adapter's own contract: every provider renders
# honestly, Codex is weekly-only, Kimi is read from its own endpoint rather than
# from quota-axi, the topic is written only when the rendered string changed, a
# refused write is not remembered as applied, both secrets stay out of argv, and
# a healthy run produces no result at all.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ADAPTER="$ROOT/bin/fm-procevent-quota-topic.sh"
TMP_ROOT=$(fm_test_tmproot fm-procevent-quota-topic)
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"
export TMPDIR="$TMP_ROOT/tmp"
mkdir -p "$TMPDIR"
export FM_QUOTA_TOPIC_MAX_LOOPS=1

CHANNEL=C0QUOTA
SID="quota-topic-$CHANNEL"
SLACK_TOKEN='xoxb-fake-000-supersecret'
KIMI_TOKEN='sk-kimi-fake-supersecret'

TRACKED_HOMES=()
quota_teardown() {
  local home
  for home in ${TRACKED_HOMES[@]+"${TRACKED_HOMES[@]}"}; do
    FM_HOME="$home" "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
  done
  fm_test_cleanup
}
trap quota_teardown EXIT

FAKEBIN=$(fm_fakebin "$TMP_ROOT")
cat > "$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
set -u
[ "${FAKE_QUOTA_AXI_MISSING:-0}" != 1 ] || exit 1
cat "$FAKE_QUOTA_AXI_JSON"
SH
cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
# Stand-in for the Kimi usage endpoint and the Slack topic call. Records argv
# and the stdin config, serves the canned body for whichever endpoint was asked
# for, and prints the canned HTTP status when -w asked for it.
set -u
printf '%s\n' "$*" >> "$FAKE_CURL_ARGV"
cat >> "$FAKE_CURL_STDIN"
out=
prev=
kind=slack
for arg in "$@"; do
  [ "$prev" = -o ] && out=$arg
  case "$arg" in
    *usages*) kind=kimi ;;
    @*) [ "$prev" = --data-binary ] && cp "${arg#@}" "$FAKE_POST_BODY" ;;
  esac
  prev=$arg
done
[ -n "$out" ] || exit 1
if [ "$kind" = kimi ]; then
  cat "$FAKE_KIMI_BODY" > "$out"
  case "$*" in *-w*) printf '%s' "${FAKE_KIMI_CODE:-200}" ;; esac
  exit "${FAKE_KIMI_EXIT:-0}"
fi
printf '%s\n' "$*" >> "$FAKE_TOPIC_CALLS"
cat "$FAKE_SLACK_RESPONSE" > "$out"
exit "${FAKE_CURL_EXIT:-0}"
SH
chmod +x "$FAKEBIN/curl" "$FAKEBIN/quota-axi"
export PATH="$FAKEBIN:$PATH"
export FAKE_CURL_ARGV="$TMP_ROOT/curl.argv"
export FAKE_CURL_STDIN="$TMP_ROOT/curl.stdin"
export FAKE_POST_BODY="$TMP_ROOT/post.body.json"
export FAKE_TOPIC_CALLS="$TMP_ROOT/topic.calls"
export FAKE_SLACK_RESPONSE="$TMP_ROOT/slack.json"
export FAKE_QUOTA_AXI_JSON="$TMP_ROOT/quota-axi.json"
export FAKE_KIMI_BODY="$TMP_ROOT/kimi.json"
: > "$FAKE_CURL_ARGV"
: > "$FAKE_CURL_STDIN"
: > "$FAKE_TOPIC_CALLS"
printf '{"ok":true}\n' > "$FAKE_SLACK_RESPONSE"

quota_axi_doc() {  # <claude-json> <codex-json> <grok-json>
  printf '{"providers":[%s,%s,%s]}\n' "$1" "$2" "$3" > "$FAKE_QUOTA_AXI_JSON"
}
CLAUDE_OK='{"provider":"claude","state":{"status":"fresh"},"windows":[
  {"id":"five_hour","kind":"session","percentRemaining":81},
  {"id":"seven_day","kind":"weekly","percentRemaining":93},
  {"id":"model:fable","kind":"model","percentRemaining":93}]}'
CODEX_OK='{"provider":"codex","state":{"status":"fresh"},"windows":[
  {"id":"weekly","kind":"weekly","percentRemaining":40}]}'
CLAUDE_EXPIRED='{"provider":"claude","state":{"status":"auth_required"},"windows":[]}'
GROK_OK='{"provider":"grok","state":{"status":"fresh"},"windows":[
  {"id":"credits","kind":"credits","percentRemaining":42},
  {"id":"product:grok_build","kind":"credits","percentRemaining":42}]}'
# An observed shape: quota-axi keeps serving grok's last-known credits figure
# even once its token has expired, so this fixture pins the case that matters -
# an auth problem must win over a cached percentage rather than render it stale.
# The second credits-kind window also pins that the selector takes the `credits`
# id rather than whichever credits window happens to come first.
GROK_EXPIRED='{"provider":"grok","state":{"status":"stale","stale":true,
  "authStatus":"expired_refreshable","reason":"credentials_expired"},"windows":[
  {"id":"credits","kind":"credits","percentRemaining":15},
  {"id":"product:grok_build","kind":"credits","percentRemaining":15}]}'

kimi_ok() {
  cat > "$FAKE_KIMI_BODY" <<'JSON'
{"usage":{"limit":"100","used":"35","remaining":"65"},
 "limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},
            "detail":{"limit":"100","remaining":"90"}}]}
JSON
}

new_home() {  # <name> [--no-kimi]
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/config"
  printf 'quota=%s\n' "$CHANNEL" > "$home/config/slack-channels"
  printf 'channel=quota\ninterval=1200\n' > "$home/config/slack-quota-topic"
  {
    printf 'SLACK_BOT_TOKEN=%s\n' "$SLACK_TOKEN"
    [ "${2-}" = --no-kimi ] || printf 'KIMI_API_QUOTA=%s\n' "$KIMI_TOKEN"
  } > "$home/.env"
  chmod 600 "$home/.env"
  TRACKED_HOMES+=("$home")
  printf '%s\n' "$home"
}

topic_file() { printf '%s/state/slack-quota-topic/%s.topic\n' "$1" "$CHANNEL"; }
file_mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

# --- the topic renders every provider from its own source -------------------

home=$(new_home render)
quota_axi_doc "$CLAUDE_OK" "$CODEX_OK" "$GROK_OK"
kimi_ok
out=$(FM_HOME="$home" "$ADAPTER" render) || fail "render failed"
[ "$out" = 'Claude: session 81% week 93% // Codex: week 40% // Grok: credits 42% // Kimi: session 90% week 65%' ] \
  || fail "unexpected topic: $out"
assert_contains "$out" 'Codex: week' "Codex renders weekly-only, because it publishes no session window"
case "$out" in
  *'Codex: week 40% //'*) ;;
  *) fail "Codex must carry no invented session figure: $out" ;;
esac
assert_contains "$out" 'Grok: credits 42%' "Grok renders credits-only, because it publishes no session/weekly split"
assert_grep 'usages' "$FAKE_CURL_ARGV" "Kimi is read from its own usage endpoint"
pass "the topic renders Claude, Codex, Grok, and Kimi from their authoritative sources"

# --- neither secret ever reaches argv ---------------------------------------

assert_no_grep "$KIMI_TOKEN" "$FAKE_CURL_ARGV" "the Kimi key must never appear in curl argv"
assert_no_grep "$SLACK_TOKEN" "$FAKE_CURL_ARGV" "the Slack token must never appear in curl argv"
assert_grep "Authorization: Bearer $KIMI_TOKEN" "$FAKE_CURL_STDIN" "the Kimi key reaches curl only on stdin"
pass "both secrets are confined to curl's stdin"

# --- a missing or broken provider renders honestly, never blank -------------

quota_axi_doc "$CLAUDE_EXPIRED" "$CODEX_OK" "$GROK_EXPIRED"
out=$(FM_HOME="$home" "$ADAPTER" render) || fail "render failed"
assert_contains "$out" 'Claude: auth expired' "an unauthenticated provider says so"
assert_contains "$out" 'Grok: auth expired' "an expired grok token says so"
case "$out" in
  *'Grok: credits'*) fail "grok must never render a cached figure once its token has expired: $out" ;;
  *) ;;
esac
export FAKE_KIMI_CODE=401
out=$(FM_HOME="$home" "$ADAPTER" render) || fail "render failed"
assert_contains "$out" 'Kimi: auth expired' "a rejected Kimi key renders as expired"
export FAKE_KIMI_CODE=404
out=$(FM_HOME="$home" "$ADAPTER" render) || fail "render failed"
assert_contains "$out" 'Kimi: n/a' "an unavailable Kimi endpoint renders as n/a"
export FAKE_KIMI_CODE=500
out=$(FM_HOME="$home" "$ADAPTER" render) || fail "render failed"
assert_contains "$out" 'Kimi: unavailable' "a failing Kimi endpoint renders as unavailable"
unset FAKE_KIMI_CODE
nokimi=$(new_home nokimi --no-kimi)
out=$(FM_HOME="$nokimi" "$ADAPTER" render) || fail "render failed"
assert_contains "$out" 'Kimi: n/a' "an absent Kimi key renders as n/a rather than blank"
export FAKE_QUOTA_AXI_MISSING=1
out=$(FM_HOME="$home" "$ADAPTER" render) || fail "render failed"
unset FAKE_QUOTA_AXI_MISSING
assert_contains "$out" 'Claude: unavailable' "an unreadable quota source is reported, not skipped"
assert_contains "$out" 'Codex: unavailable' "every provider keeps its place in the line"
pass "an absent or erroring provider renders its reason and is never blank"

# --- the topic is written only when the rendered string changed -------------

home=$(new_home apply)
quota_axi_doc "$CLAUDE_OK" "$CODEX_OK" "$GROK_OK"
kimi_ok
: > "$FAKE_TOPIC_CALLS"
out=$(FM_HOME="$home" "$ADAPTER" update) || fail "the first update should set the topic"
assert_contains "$out" 'set: Claude: session 81%' "the first update reports what it set"
[ "$(wc -l < "$FAKE_TOPIC_CALLS")" -eq 1 ] || fail "the first update should make one Slack call"
assert_grep 'conversations.setTopic' "$FAKE_TOPIC_CALLS" "the topic is set through conversations.setTopic"
[ "$(jq -r .topic "$FAKE_POST_BODY")" = 'Claude: session 81% week 93% // Codex: week 40% // Grok: credits 42% // Kimi: session 90% week 65%' ] \
  || fail "the posted topic must be the rendered line"
[ "$(file_mode "$(topic_file "$home")")" = 600 ] || fail "the applied-topic record must be private"

out=$(FM_HOME="$home" "$ADAPTER" update) || fail "a repeat update should succeed"
assert_contains "$out" 'unchanged:' "an unchanged quota picture reports no change"
[ "$(wc -l < "$FAKE_TOPIC_CALLS")" -eq 1 ] || fail "an unchanged topic must make no Slack call"

quota_axi_doc "${CLAUDE_OK/81/72}" "$CODEX_OK" "$GROK_OK"
out=$(FM_HOME="$home" "$ADAPTER" update) || fail "a changed update should set the topic"
assert_contains "$out" 'set: Claude: session 72%' "a changed figure is written"
[ "$(wc -l < "$FAKE_TOPIC_CALLS")" -eq 2 ] || fail "a changed topic makes exactly one more Slack call"
pass "the topic is written only when the rendered line changed"

# --- a refused write is retried, never remembered as applied ----------------

home=$(new_home refused)
quota_axi_doc "$CLAUDE_OK" "$CODEX_OK" "$GROK_OK"
kimi_ok
printf '{"ok":false,"error":"ratelimited"}\n' > "$FAKE_SLACK_RESPONSE"
: > "$FAKE_TOPIC_CALLS"
FM_HOME="$home" "$ADAPTER" update >/dev/null 2>&1 && fail "a refused write must report failure"
assert_absent "$(topic_file "$home")" "a refused write must not be recorded as applied"
printf '{"ok":true}\n' > "$FAKE_SLACK_RESPONSE"
FM_HOME="$home" "$ADAPTER" update >/dev/null || fail "the retry should succeed"
assert_present "$(topic_file "$home")" "the accepted write is recorded"
pass "a transient Slack refusal is retried rather than remembered"

# --- a healthy run is silent; a fatal Slack error becomes one result --------

home=$(new_home poll)
quota_axi_doc "$CLAUDE_OK" "$CODEX_OK" "$GROK_OK"
kimi_ok
rc=0
FM_HOME="$home" "$ADAPTER" poll "$home" > "$TMP_ROOT/poll.out" 2>/dev/null || rc=$?
[ "$rc" -ne 0 ] || fail "an up-to-date topic must not produce a result"
[ ! -s "$TMP_ROOT/poll.out" ] || fail "a healthy run must emit nothing: $(cat "$TMP_ROOT/poll.out")"
staged=$(find "$TMPDIR" -maxdepth 1 -name 'fm-quota-topic.*' 2>/dev/null | head -n 1)
[ -z "$staged" ] || fail "the poll left its staging directory behind: $staged"
pass "a healthy quota run is ambient: no result, no wake"

home=$(new_home pollerror)
printf '{"ok":false,"error":"not_in_channel"}\n' > "$FAKE_SLACK_RESPONSE"
FM_HOME="$home" "$ADAPTER" poll "$home" > "$TMP_ROOT/pollerr.out" 2>/dev/null \
  || fail "a fatal Slack error should produce a result rather than exit nonzero"
assert_grep 'status=api-error' "$TMP_ROOT/pollerr.out" "a membership failure becomes a result"
assert_grep 'reason=not_in_channel' "$TMP_ROOT/pollerr.out" "the result names the Slack error"
[ "$("$ADAPTER" classify "$TMP_ROOT/pollerr.out")" = api-error ] || fail "classify should report api-error"
assert_no_grep "$SLACK_TOKEN" "$TMP_ROOT/pollerr.out" "a captured result must never carry a token"
"$ADAPTER" terminal "$TMP_ROOT/pollerr.out" && fail "a quota topic source must never be terminal"
pass "a fatal Slack error is captured as a result and the source stays armed"

# --- classify is defensive about anything else ------------------------------

: > "$TMP_ROOT/empty.result"
[ "$("$ADAPTER" classify "$TMP_ROOT/empty.result")" = empty ] || fail "an empty result classifies as empty"
printf 'schema=something-else\nstatus=api-error\n\n' > "$TMP_ROOT/foreign.result"
[ "$("$ADAPTER" classify "$TMP_ROOT/foreign.result")" = unknown ] || fail "a foreign result classifies as unknown"
pass "classify refuses to be confused by an unfamiliar result"

# --- end-to-end: arm, run the source, capture, publish ----------------------

home=$(new_home roundtrip)
printf '{"ok":false,"error":"invalid_auth"}\n' > "$FAKE_SLACK_RESPONSE"
armed=$(FM_HOME="$home" "$ADAPTER" arm 2>&1) || fail "arm failed: $armed"
assert_contains "$armed" "armed: $SID" "arm reports the registered source"
assert_present "$home/state/procevent/$SID.source" "arm registers the source"
FM_HOME="$home" "$ROOT/bin/fm-procevent.sh" start "$SID" > "$TMP_ROOT/start.out" 2>&1 \
  || fail "the runner failed: $(cat "$TMP_ROOT/start.out")"
result=$(printf '%s\n' "$home/state/procevent-inbox/$SID".*.result | head -n 1)
[ -f "$result" ] || fail "the runner captured no result: $(cat "$TMP_ROOT/start.out")"
[ "$("$ADAPTER" classify "$result")" = api-error ] || fail "the captured result should classify as api-error"
assert_grep "procevent quota-topic $SID" "$home/state/.wake-queue" "the capture publishes a wake"
assert_present "$home/state/procevent/$SID.source" "the source stays armed after a capture"
seq=${result%.result}
seq=${seq##*.}
FM_HOME="$home" "$ADAPTER" handle "$SID" "$seq" "$result" >/dev/null \
  || fail "handling the captured result failed"
assert_present "$home/state/procevent-inbox/$SID.$seq.handled" "handling records the acknowledgement"
pass "register, run, capture, publish, classify, and acknowledge round-trip"
