#!/usr/bin/env bash
# Behavior tests for firstmate's thin Slack poster wrapper.
#
# Quote-bar, token confinement, channel-map, and stall-ceiling cases live in
# agent-slack-mirror's tests/slack-post.test.sh. This file pins the wrapper
# contract: environment export, missing-package diagnostics, and a smoke post
# through the installed package.
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
REAL_MIRROR_HOME="${SLACK_MIRROR_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/agent-slack-mirror}"
STUB="$TMP_ROOT/stub-package"
STUB_LOG="$TMP_ROOT/stub.log"

install_cmd() {
  printf 'git clone https://github.com/digbycampbell/agent-slack-mirror.git %q' "$1"
}

new_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/config"
  printf 'general=%s\nquota=%s\n' "$CHANNEL" "$QUOTA" > "$home/config/slack-channels"
  printf 'channel=%s\n' "$CHANNEL" > "$home/config/slack-captain"
  printf 'SLACK_BOT_TOKEN=xoxb-fake-000-supersecret\n' > "$home/.env"
  chmod 600 "$home/.env"
  printf '%s\n' "$home"
}

mkdir -p "$STUB/bin"
cat > "$STUB/slack-mirror.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$STUB/bin/slack-captain.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$STUB/bin/slack-post.sh" <<SH
#!/usr/bin/env bash
set -u
{
  printf 'cmd=%s\n' "\$*"
  env | grep '^SLACK_' | sort
} > "$STUB_LOG"
printf '500.000500\n'
exit 0
SH
chmod +x "$STUB/slack-mirror.sh" "$STUB/bin/slack-captain.sh" "$STUB/bin/slack-post.sh"

# --- a missing package names the exact install command ----------------------

missing="$TMP_ROOT/missing package"
err=$(SLACK_MIRROR_HOME="$missing" "$POST" general hello 2>&1) && rc=0 || rc=$?
[ "$rc" -ne 0 ] || fail "a missing package must be a refusal"
assert_contains "$err" "agent-slack-mirror is not installed at $missing" \
  "the refusal must name the missing checkout"
assert_contains "$err" "install: $(install_cmd "$missing")" \
  "the refusal must name the exact clone command"
pass "a missing package reports the exact install command"

# --- the wrapper exports this home's contract and forwards argv -------------

home=$(new_home export)
out=$(SLACK_MIRROR_HOME="$STUB" FM_HOME="$home" "$POST" general 'hello there' --thread 400.000400) \
  || fail "posting through the stub should succeed"
[ "$out" = 500.000500 ] || fail "the wrapper must surface the package timestamp: $out"
assert_grep "cmd=general hello there --thread 400.000400" "$STUB_LOG" \
  "the wrapper must forward the original argv"
assert_grep "SLACK_CONFIG_FILE=$home/config/slack-captain" "$STUB_LOG" \
  "the wrapper must export this home's captain config"
assert_grep "SLACK_CHANNELS_FILE=$home/config/slack-channels" "$STUB_LOG" \
  "the wrapper must export this home's channel map"
assert_grep "SLACK_TOKEN_FILE=$home/.env" "$STUB_LOG" \
  "the wrapper must export this home's token file"
assert_grep "SLACK_CAPTAIN_CMD=$STUB/bin/slack-captain.sh" "$STUB_LOG" \
  "the wrapper must point the poster at the package listener"
pass "the wrapper exports the home contract and forwards argv"

# --- smoke: a post through the installed package ----------------------------

if [ ! -x "$REAL_MIRROR_HOME/bin/slack-post.sh" ]; then
  if [ -n "${CI:-}" ] || [ -n "${GITHUB_ACTIONS:-}" ]; then
    fail "agent-slack-mirror is not installed at $REAL_MIRROR_HOME; install: $(install_cmd "$REAL_MIRROR_HOME")"
  fi
  echo "skip: installed poster missing at $REAL_MIRROR_HOME; install: $(install_cmd "$REAL_MIRROR_HOME")"
  exit 0
fi

FAKEBIN=$(fm_fakebin "$TMP_ROOT")
cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
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
exit 0
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

home=$(new_home smoke)
# shellcheck disable=SC2016
out=$(SLACK_MIRROR_HOME="$REAL_MIRROR_HOME" FM_HOME="$home" "$POST" general \
  'ready $(touch /tmp/fm-slack-post-pwned)' 2>"$TMP_ROOT/post.err") \
  || fail "posting through the installed package should succeed: $(cat "$TMP_ROOT/post.err")"
[ "$out" = 500.000500 ] || fail "the posted timestamp should come back: $out"
assert_absent /tmp/fm-slack-post-pwned "message text must never be expanded by a shell"
assert_no_grep 'xoxb-fake-000-supersecret' "$FAKE_CURL_ARGV" "the token must never appear in curl argv"
assert_grep 'Authorization: Bearer xoxb-fake-000-supersecret' "$FAKE_CURL_STDIN" \
  "the token reaches curl only on stdin"
pass "a message posts through the installed package and returns its timestamp"
