#!/usr/bin/env bash
# Behavior tests for firstmate's thin Slack captain-channel wrapper.
#
# Slack logic now lives in agent-slack-mirror. This file pins the wrapper
# contract: path resolution, environment export, poll argv, handled
# acknowledgement, missing-package diagnostics, and the runner round-trip
# through `fm-procevent.sh start`. Package-owned poll, handle, attachment,
# reaction, and token-confinement cases live in that package's
# tests/slack-captain.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ADAPTER="$ROOT/bin/fm-procevent-slack-captain.sh"
TMP_ROOT=$(fm_test_tmproot fm-procevent-slack-captain)
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"
export TMPDIR="$TMP_ROOT/tmp"
mkdir -p "$TMPDIR"

CHANNEL=C0TESTCHAN
CAPTAIN=U0CAPTAIN
SID="slack-captain-$CHANNEL"
REAL_MIRROR_HOME="${SLACK_MIRROR_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/agent-slack-mirror}"
STUB="$TMP_ROOT/stub-package"
STUB_LOG="$TMP_ROOT/stub.log"

TRACKED_HOMES=()
slack_teardown() {
  local home
  for home in ${TRACKED_HOMES[@]+"${TRACKED_HOMES[@]}"}; do
    FM_HOME="$home" "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
  done
  fm_test_cleanup
}
trap slack_teardown EXIT

new_home() {  # <name> [--no-token]
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/config"
  {
    printf 'channel=%s\n' "$CHANNEL"
    printf 'allowed_user=%s\n' "$CAPTAIN"
  } > "$home/config/slack-captain"
  if [ "${2-}" != --no-token ]; then
    printf 'SLACK_BOT_TOKEN=xoxb-fake-000-supersecret\n' > "$home/.env"
    chmod 600 "$home/.env"
  fi
  TRACKED_HOMES+=("$home")
  printf '%s\n' "$home"
}

install_cmd() {
  printf 'git clone https://github.com/digbycampbell/agent-slack-mirror.git %q' "$1"
}

# A stub package that records argv and the SLACK_* contract, then implements
# the few commands the wrapper itself still owns.
write_stub_package() {
  mkdir -p "$STUB/bin"
  cat > "$STUB/slack-mirror.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$STUB/bin/slack-post.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$STUB/bin/slack-captain.sh" <<SH
#!/usr/bin/env bash
set -u
{
  printf 'cmd=%s\n' "\$*"
  env | grep '^SLACK_' | sort
} > "$STUB_LOG"
case "\${1-}" in
  source-id) printf 'slack-captain-%s\n' "$CHANNEL" ;;
  handle)
    printf 'applied: %s read-position=1\n' "\$2"
    exit 0
    ;;
  autohandle)
    if [ -n "\${STUB_AUTOHANDLE_REFUSE:-}" ]; then
      printf 'error: captured Slack messages do not continue the stored read position\n' >&2
      exit 1
    fi
    printf 'applied: %s read-position=1\n' "\$2"
    exit 1
    ;;
  classify) printf 'messages\n' ;;
  poll)
    # STUB_POLL_SCRIPT lists one outcome per poll: quiet, capture, or fail.
    if [ -n "\${STUB_POLL_SCRIPT:-}" ]; then
      n=\$(( \$(cat "\$STUB_POLL_COUNT" 2>/dev/null || echo 0) + 1 ))
      printf '%s\n' "\$n" > "\$STUB_POLL_COUNT"
      outcome=\$(printf '%s\n' \$STUB_POLL_SCRIPT | sed -n "\${n}p")
      case "\$outcome" in
        quiet) exit 75 ;;
        capture) ;;
        *) exit 1 ;;
      esac
    fi
    printf 'schema=fm-slack-captain.v1\nstatus=messages\nchannel=%s\nfrom_ts=0\nto_ts=1\ncount=1\nuntrusted=0\nreason=\n\n' "$CHANNEL"
    printf '{"ts":"1","user":"U0CAPTAIN","trusted":true,"text":"ahoy"}\n'
    exit 0
    ;;
  terminal) exit 1 ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$STUB/slack-mirror.sh" "$STUB/bin/slack-post.sh" "$STUB/bin/slack-captain.sh"
}

write_stub_package
export SLACK_MIRROR_HOME="$STUB"

# --- a missing package names the exact install command ----------------------

missing="$TMP_ROOT/missing package"
err=$(SLACK_MIRROR_HOME="$missing" "$ADAPTER" source-id 2>&1) && rc=0 || rc=$?
[ "$rc" -ne 0 ] || fail "a missing package must be a refusal"
assert_contains "$err" "agent-slack-mirror is not installed at $missing" \
  "the refusal must name the missing checkout"
assert_contains "$err" "install: $(install_cmd "$missing")" \
  "the refusal must name the exact clone command"
pass "a missing package reports the exact install command"

# --- poll exports this home's contract and drops <home> from argv -----------

home=$(new_home poll-env)
wrong="$TMP_ROOT/wrong-home"
mkdir -p "$wrong/config" "$wrong/state"
: > "$STUB_LOG"
FM_HOME="$wrong" "$ADAPTER" poll "$home" "$CHANNEL" >/dev/null \
  || fail "poll through the stub should succeed"
assert_grep "cmd=poll $CHANNEL" "$STUB_LOG" "poll must drop the home argument"
assert_no_grep "cmd=poll $home" "$STUB_LOG" "poll must not forward the home argument"
assert_grep "SLACK_CONFIG_FILE=$home/config/slack-captain" "$STUB_LOG" \
  "poll must export this home's config file"
assert_grep "SLACK_STATE_DIR=$home/state/slack-captain" "$STUB_LOG" \
  "poll must export this home's state dir"
assert_grep "SLACK_TOKEN_FILE=$home/.env" "$STUB_LOG" \
  "poll must export this home's token file"
assert_no_grep "$wrong" "$STUB_LOG" "poll must not take paths from inherited FM_HOME"
pass "poll exports the named home's contract and drops that home from argv"

# --- handle records the runner acknowledgement; autohandle does not ---------

home=$(new_home handle-ack)
mkdir -p "$home/state/procevent-inbox"
result="$home/state/procevent-inbox/$SID.3.result"
printf 'schema=fm-slack-captain.v1\nstatus=messages\n\n' > "$result"
printf '%s\n' "$ADAPTER" > "$home/state/procevent-inbox/$SID.3.adapter"
out=$(FM_HOME="$home" "$ADAPTER" handle "$SID" 3 "$result" 2>&1) \
  || fail "handle through the stub should succeed: $out"
assert_contains "$out" "applied:" "handle must surface the package result"
assert_present "$home/state/procevent-inbox/$SID.3.handled" \
  "handle must record the runner acknowledgement"
pass "handle records fm-procevent handled after the package applies"

result4="$home/state/procevent-inbox/$SID.4.result"
printf 'schema=fm-slack-captain.v1\nstatus=messages\n\n' > "$result4"
printf '%s\n' "$ADAPTER" > "$home/state/procevent-inbox/$SID.4.adapter"
out=$(FM_HOME="$home" "$ADAPTER" autohandle "$SID" 4 "$result4" 2>&1) \
  || fail "autohandle must report an applied capture so the runner can poll again: $out"
assert_contains "$out" "applied:" "autohandle must surface the package result"
assert_absent "$home/state/procevent-inbox/$SID.4.handled" \
  "autohandle must not record the runner acknowledgement"
out=$(STUB_AUTOHANDLE_REFUSE=1 FM_HOME="$home" "$ADAPTER" autohandle "$SID" 4 "$result4" 2>&1) && rc=0 || rc=$?
[ "$rc" -ne 0 ] || fail "autohandle must keep the package's refusal: $out"
assert_absent "$home/state/procevent-inbox/$SID.4.handled" \
  "a refused autohandle must not record the runner acknowledgement"
pass "autohandle reports an applied capture, keeps a refusal, and never acknowledges"

# --- the runner keeps polling the channel without a supervision cycle -------
# A Slack poll used to release its claim after every quiet window and every
# capture, so the channel went unpolled until the next supervision cycle ran
# reconcile; with the watcher down, nothing polled Slack at all. The runner
# must poll again on its own after a quiet window and after an applied capture,
# and leave the capture announced and unacknowledged for firstmate.

home=$(new_home relisten)
FM_HOME="$home" "$ADAPTER" arm >/dev/null || fail "arm for the relisten case failed"
rm -f "$TMP_ROOT/poll-count"
STUB_POLL_SCRIPT="quiet capture quiet fail fail" STUB_POLL_COUNT="$TMP_ROOT/poll-count" \
  FM_HOME="$home" "$ROOT/bin/fm-procevent.sh" start "$SID" \
  > "$TMP_ROOT/relisten.out" 2>&1 || true
[ "$(cat "$TMP_ROOT/poll-count" 2>/dev/null)" = 5 ] \
  || fail "the runner stopped polling after $(cat "$TMP_ROOT/poll-count" 2>/dev/null) poll(s) instead of polling again: $(cat "$TMP_ROOT/relisten.out")"
relisten_result=$(printf '%s\n' "$home/state/procevent-inbox/$SID".*.result | head -n 1)
[ -f "$relisten_result" ] || fail "the relistening runner captured no result: $(cat "$TMP_ROOT/relisten.out")"
assert_grep "procevent slack-captain $SID" "$home/state/.wake-queue" "the relistened capture publishes a wake"
relisten_seq=${relisten_result%.result}
relisten_seq=${relisten_seq##*.}
assert_absent "$home/state/procevent-inbox/$SID.$relisten_seq.handled" \
  "polling again must leave the capture unacknowledged for firstmate"
pass "the runner polls the channel again after a quiet window, an applied capture, and a single failed poll"

# --- a single failed poll keeps the claim, but two in a row release it ------
# A poll that fails with no output used to release the claim on the very
# first failure, leaving the source for the next reconcile. The sequence
# above already shows one failed poll (position 4) followed by another poll
# in the same runner (position 5); that next poll fails again, and the two
# consecutive failures end the runner at exactly 5 polls, so a broken setup
# cannot turn into a tight loop.
assert_contains "$(cat "$TMP_ROOT/relisten.out")" "no-result: $SID" \
  "two consecutive failed polls must release the claim"
pass "two consecutive failed polls release the claim"

# --- two channels under one home track failed polls independently ----------

home=$(new_home channel-scope)
CHAN_A=C0CHANAAA
CHAN_B=C0CHANBBB
rc=0
STUB_POLL_SCRIPT="fail" STUB_POLL_COUNT="$TMP_ROOT/scope-a1" \
  FM_HOME="$home" "$ADAPTER" poll "$home" "$CHAN_A" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 75 ] || fail "channel A's first failed poll must relisten (exit 75), got $rc"
rc=0
STUB_POLL_SCRIPT="fail" STUB_POLL_COUNT="$TMP_ROOT/scope-b1" \
  FM_HOME="$home" "$ADAPTER" poll "$home" "$CHAN_B" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 75 ] \
  || fail "channel B's first failed poll must relisten (exit 75) despite channel A's marker, got $rc"
rc=0
STUB_POLL_SCRIPT="fail" STUB_POLL_COUNT="$TMP_ROOT/scope-a2" \
  FM_HOME="$home" "$ADAPTER" poll "$home" "$CHAN_A" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 1 ] || fail "channel A's second consecutive failure must release the claim, got $rc"
rc=0
STUB_POLL_SCRIPT="fail" STUB_POLL_COUNT="$TMP_ROOT/scope-b2" \
  FM_HOME="$home" "$ADAPTER" poll "$home" "$CHAN_B" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 1 ] || fail "channel B's second consecutive failure must release the claim, got $rc"
pass "two channels under one home track failed polls independently"

# --- arm registers this wrapper's poll with the home and channel ------------

home=$(new_home arm)
armed=$(FM_HOME="$home" "$ADAPTER" arm 2>&1) || fail "arm failed: $armed"
assert_contains "$armed" "armed: $SID" "arm reports the registered source"
src="$home/state/procevent/$SID.source"
assert_present "$src" "arm registers the source"
assert_grep "fm-procevent-slack-captain.sh" "$src" \
  "arm must register this wrapper, not the package, as the poll argv"
assert_grep "$home" "$src" "arm must store the home in the registered poll argv"
assert_grep "$CHANNEL" "$src" "arm must store the channel in the registered poll argv"
pass "arm registers wrapper poll <home> <channel>"

# --- end-to-end against the installed package and the runner ----------------

if [ ! -x "$REAL_MIRROR_HOME/bin/slack-captain.sh" ]; then
  if [ -n "${CI:-}" ] || [ -n "${GITHUB_ACTIONS:-}" ]; then
    fail "agent-slack-mirror is not installed at $REAL_MIRROR_HOME; install: $(install_cmd "$REAL_MIRROR_HOME")"
  fi
  echo "skip: installed listener missing at $REAL_MIRROR_HOME; install: $(install_cmd "$REAL_MIRROR_HOME")"
  exit 0
fi

FAKEBIN=$(fm_fakebin "$TMP_ROOT")
cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
set -u
out=
prev=
for arg in "$@"; do
  [ "$prev" = -o ] && out=$arg
  prev=$arg
done
[ -n "$out" ] || exit 1
cat "$FAKE_SLACK_RESPONSE" > "$out"
exit 0
SH
chmod +x "$FAKEBIN/curl"
export PATH="$FAKEBIN:$PATH"
export FAKE_SLACK_RESPONSE="$TMP_ROOT/slack.json"
export FM_SLACK_CAPTAIN_MAX_LOOPS=1
export FM_SLACK_CAPTAIN_INTERVAL=0
export FM_SLACK_CAPTAIN_QUIET_WINDOW=0
export FM_SLACK_CAPTAIN_MAX_QUIET_WINDOWS=0
printf '{"ok":true,"messages":[{"type":"message","user":"%s","ts":"500.000500","text":"ahoy"}]}\n' \
  "$CAPTAIN" > "$FAKE_SLACK_RESPONSE"

home=$(new_home roundtrip)
armed=$(SLACK_MIRROR_HOME="$REAL_MIRROR_HOME" FM_HOME="$home" "$ADAPTER" arm 2>&1) \
  || fail "arm against the installed package failed: $armed"
assert_contains "$armed" "armed: $SID" "arm reports the registered source"
# The runner relistens after the capture, so retire the source to end it.
SLACK_MIRROR_HOME="$REAL_MIRROR_HOME" FM_HOME="$home" "$ROOT/bin/fm-procevent.sh" start "$SID" \
  > "$TMP_ROOT/start.out" 2>&1 &
start_pid=$!
for _ in $(seq 1 300); do
  [ -e "$home/state/.wake-queue" ] && break
  kill -0 "$start_pid" 2>/dev/null || break
  sleep 0.1
done
FM_HOME="$home" "$ROOT/bin/fm-procevent.sh" retire "$SID" >/dev/null 2>&1 || true
# Retirement stops the runner, so its exit status says nothing about the capture.
wait "$start_pid" 2>/dev/null || true
result=$(printf '%s\n' "$home/state/procevent-inbox/$SID".*.result | head -n 1)
[ -f "$result" ] || fail "the runner captured no result: $(cat "$TMP_ROOT/start.out")"
[ "$(SLACK_MIRROR_HOME="$REAL_MIRROR_HOME" "$ADAPTER" classify "$result")" = messages ] \
  || fail "the captured result should classify as messages"
assert_grep "procevent slack-captain $SID" "$home/state/.wake-queue" "the capture publishes a wake"
seq=${result%.result}
seq=${seq##*.}
SLACK_MIRROR_HOME="$REAL_MIRROR_HOME" FM_HOME="$home" "$ADAPTER" handle "$SID" "$seq" "$result" >/dev/null \
  || fail "handling the captured result failed"
assert_present "$home/state/procevent-inbox/$SID.$seq.handled" "handling records the acknowledgement"
assert_grep 'ts=500.000500' "$home/state/slack-captain/$CHANNEL.cursor" \
  "handling advances the read position"
pass "register, poll, capture, publish, classify, and acknowledge round-trip"
