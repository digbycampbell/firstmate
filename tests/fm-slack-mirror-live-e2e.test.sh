#!/usr/bin/env bash
# Opt-in live guard for the Slack mirror's per-harness turn-end adapters.
#
# The mirror's verdict comes from a vendor-emitted Stop payload, so a stub agent
# could only confirm the assumption already written into the stub. This runs the
# tracked registration against a REAL installed harness in an isolated clone,
# with Slack replaced by a fake `curl`, and fails naming the harness and version.
# An absent harness is reported explicitly rather than passed over silently.
#
#   FM_SLACK_MIRROR_LIVE_E2E=1 tests/fm-slack-mirror-live-e2e.test.sh
#
# `FM_SLACK_MIRROR_LIVE_GROK_BIN` names an exact grok binary; otherwise `grok`
# on PATH is used. Grok's project hooks need a trusted checkout, which `--trust`
# supplies. `.grok/hooks/fm-primary-slack-mirror.json` is the registration under
# test.
set -u

if [ "${FM_SLACK_MIRROR_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_SLACK_MIRROR_LIVE_E2E=1 to run the live Slack-mirror guard"
  exit 0
fi

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-slack-mirror-live)
trap fm_test_cleanup EXIT

CHANNEL=C0TESTCHAN
SOURCE_ID="slack-captain-$CHANNEL"
SEQUENCE=77
THREAD=300.000300

command -v jq >/dev/null 2>&1 || fail "test host must provide jq"

GROK_BIN=${FM_SLACK_MIRROR_LIVE_GROK_BIN:-$(command -v grok || true)}
[ -n "$GROK_BIN" ] && [ -x "$GROK_BIN" ] \
  || fail "grok is not installed, so this guard checked nothing; install it or name FM_SLACK_MIRROR_LIVE_GROK_BIN"
GROK_VERSION=$("$GROK_BIN" --version 2>&1 | head -n1)
AUTH=${FM_GROK_AUTH_FILE:-$HOME/.grok/auth.json}
[ -f "$AUTH" ] || fail "grok $GROK_VERSION has no usable credential at $AUTH"

# An isolated firstmate-shaped checkout: the harness must reach the tracked
# registration and the tracked mirror, not this working tree.
LAB="$TMP_ROOT/lab"
mkdir -p "$LAB/bin" "$LAB/grok-home"
git clone -q --no-hardlinks "$ROOT" "$LAB/project" || fail "could not clone the repo under test"
# Before the candidate is committed, the clone sees HEAD only; carry the working
# tree across so this guard always exercises the code under review.
git -C "$ROOT" diff --binary HEAD > "$LAB/candidate.patch" || fail "could not capture the candidate diff"
[ ! -s "$LAB/candidate.patch" ] \
  || git -C "$LAB/project" apply --whitespace=nowarn "$LAB/candidate.patch" \
  || fail "could not apply the candidate diff to the isolated clone"
# The repo's own ignore rules alone decide what is a candidate file here: a
# machine-local global ignore (`.grok/` is a common one) must not hide a tracked
# registration's not-yet-committed sibling from this guard.
while IFS= read -r path; do
  [ -n "$path" ] || continue
  mkdir -p "$LAB/project/$(dirname "$path")"
  cp -p "$ROOT/$path" "$LAB/project/$path"
done < <(git -C "$ROOT" -c core.excludesFile=/dev/null ls-files --others --exclude-standard)

mkdir -p "$LAB/project/state/slack-captain" "$LAB/project/config"
{
  printf 'channel=%s\n' "$CHANNEL"
  printf 'bot_user=U0BOTUSER\n'
  printf 'allowed_user=U0CAPTAIN\n'
} > "$LAB/project/config/slack-captain"
printf 'SLACK_BOT_TOKEN=xoxb-fake-000-supersecret\n' > "$LAB/project/.env"
chmod 600 "$LAB/project/.env"
ln -s "$AUTH" "$LAB/grok-home/auth.json"

cat > "$LAB/bin/curl" <<'SH'
#!/usr/bin/env bash
set -u
out=; prev=
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
SH
chmod +x "$LAB/bin/curl"
export FAKE_POST_BODY="$LAB/post.body.json"
: > "$FAKE_POST_BODY"

# The capture the reply answers, recorded exactly as the captain adapter records
# it as a result commits.
FM_ROOT_OVERRIDE="$LAB/project" "$LAB/project/bin/fm-slack-mirror.sh" \
  note-trigger "$CHANNEL" "$SOURCE_ID" "$SEQUENCE" "$THREAD" \
  || fail "could not record the capture this turn answers"

PROMPT="This is an isolated end-to-end test of a Slack mirror hook. Do not use any tools. Reply with exactly these two lines and nothing else:
Captain, the mirror is live: https://example.invalid/pr/99
check: procevent $SOURCE_ID $SEQUENCE"

( cd "$LAB/project" \
  && env PATH="$LAB/bin:$PATH" GROK_HOME="$LAB/grok-home" FAKE_POST_BODY="$FAKE_POST_BODY" \
    "$GROK_BIN" --trust --always-approve --reasoning-effort low --output-format json \
      -p "$PROMPT" > "$LAB/outer.json" 2> "$LAB/outer.err" ) \
  || fail "grok $GROK_VERSION did not finish the isolated turn"

# Delivery is deliberately detached so the turn never waits on Slack, so the
# post lands shortly AFTER grok returns; wait for it rather than racing it.
waited=0
while [ "$waited" -lt "${FM_SLACK_MIRROR_LIVE_WAIT:-30}" ]; do
  [ ! -s "$FAKE_POST_BODY" ] || break
  sleep 1
  waited=$((waited + 1))
done

posts=$(jq -s 'length' "$FAKE_POST_BODY" 2>/dev/null || printf 0)
[ "$posts" = 1 ] \
  || fail "grok $GROK_VERSION: expected exactly one mirrored post from one turn, saw $posts"
text=$(jq -r 'select(has("text")) | .text' "$FAKE_POST_BODY")
case "$text" in
  *'https://example.invalid/pr/99'*) ;;
  *) fail "grok $GROK_VERSION: the mirrored body lost the turn's own reply: $text" ;;
esac
thread=$(jq -r '.thread_ts // ""' "$FAKE_POST_BODY")
[ "$thread" = "$THREAD" ] \
  || fail "grok $GROK_VERSION: auto-detect did not thread the reply into the capture it answers ($thread)"
[ ! -s "$LAB/outer.err" ] || fail "grok $GROK_VERSION printed to stderr: $(cat "$LAB/outer.err")"

pass "grok ($GROK_VERSION) fired the tracked Stop registration once, mirrored the turn's own reply, and threaded it by the wake that opened the turn"
