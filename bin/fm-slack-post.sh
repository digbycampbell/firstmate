#!/usr/bin/env bash
# Post one Slack message as firstmate's bot, and register the thread it creates
# so a captain reply inside that thread is still captured.
#
# Usage:
#   fm-slack-post.sh <channel> <text>...
#   fm-slack-post.sh <channel> --file <path>
#   fm-slack-post.sh <channel> ... --thread <ts>
#   fm-slack-post.sh <channel> ... --worker-details "<model> <effort>"
#   fm-slack-post.sh <channel> ... --origin manual|mirror
#
# <channel> is either a raw Slack channel id (uppercase alphanumerics) or a name
# defined in $FM_HOME/config/slack-channels, one `name=<channel id>` per line; a
# leading `#` is accepted and ignored. An unknown name is a refusal, never a
# guess, so a typo cannot post into the wrong channel.
#
# The message body is the remaining arguments joined with spaces, or the whole
# contents of `--file <path>` when that is given; exactly one of the two must be
# present. Text is never expanded by a shell: it is carried into the JSON request
# body by jq and posted from a private temporary file, so nothing in it can be
# re-split, interpolated, or executed.
#
# `--thread <ts>` posts the message as a reply inside that thread instead of at
# the channel's top level.
#
# `--worker-details "<model> <effort>"` appends firstmate's standing completion
# convention to the message. This flag is the single owner of that convention:
# the message gains a blank line and then `_worker: <model> <effort>_`, so a
# completion post always says which model and effort produced the work. The value
# is bounded and restricted to plain identifier characters.
#
# TOKEN - `SLACK_BOT_TOKEN` in the home's gitignored `.env`, read exactly as
# bin/fm-procevent-slack-captain.sh reads it and handed to curl through
# `--config -` on stdin. It never appears in argv, in a log line, in a printed
# diagnostic, or in the request body file. Nothing here echoes a response body.
#
# On success the posted message timestamp is printed on stdout and nothing else,
# so a caller can thread onto it. A Slack error is a loud nonzero refusal naming
# the Slack error code.
#
# ORIGIN. A successful post to the configured captain channel is recorded with
# bin/fm-slack-mirror.sh `note-post`, which is how the terminal mirror knows
# firstmate already spoke in this turn and must not mirror it a second time.
# `--origin mirror` marks the mirror's own delivery and skips that record, so
# the mirror cannot suppress itself on the following turn. The default is
# `manual`, so every ordinary hand-written post counts.
#
# THREAD REGISTRATION. When the target channel is the configured captain channel
# and this post is itself a reply (`--thread <ts>` was given), the replied-to
# thread is registered with bin/fm-procevent-slack-captain.sh `track-thread`,
# which is what makes a captain reply written inside that thread reach
# firstmate. A top-level post is not yet a thread and is not registered here: if
# it later grows replies, the adapter's own channel-window scan tracks it the
# first time a reply naming it is captured. A home with no captain-channel
# configuration simply skips this step.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# shellcheck source=bin/fm-x-lib.sh
. "$SCRIPT_DIR/fm-x-lib.sh"

SLACK_API="${FM_SLACK_CAPTAIN_API:-https://slack.com/api}"
CURL_MAX_TIME=${FM_SLACK_POST_MAX_TIME:-20}
MAX_BODY_BYTES=${FM_SLACK_POST_MAX_BYTES:-40000}

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,52p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }

config_dir()  { printf '%s\n' "${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"; }
env_file()    { printf '%s\n' "$FM_HOME/.env"; }

valid_slack_id() {
  case "${1-}" in
    ''|*[!A-Z0-9]*) return 1 ;;
  esac
  [ "${#1}" -le 32 ]
}

valid_ts() {
  case "${1-}" in
    ''|*[!0-9.]*|*.*.*) return 1 ;;
  esac
  return 0
}

# The same reader the captain adapter uses, refused rather than defaulted.
read_token() {
  local token file
  file=$(env_file)
  [ -f "$file" ] && [ ! -L "$file" ] || die "no .env in this home, so SLACK_BOT_TOKEN cannot be read"
  token=$(fmx_env_get SLACK_BOT_TOKEN "$file")
  [ -n "$token" ] || die "SLACK_BOT_TOKEN is not set in this home's .env"
  case "$token" in
    *[[:space:]]*) die "SLACK_BOT_TOKEN contains whitespace" ;;
  esac
  printf '%s\n' "$token"
}

# A name resolves only through the local channel map; an id passes through.
resolve_channel() {  # <channel>
  local name=${1#\#} file id
  if valid_slack_id "$name"; then
    printf '%s\n' "$name"
    return 0
  fi
  case "$name" in
    ''|*[!A-Za-z0-9_-]*) die "invalid channel name: $1" ;;
  esac
  file="$(config_dir)/slack-channels"
  [ -f "$file" ] && [ ! -L "$file" ] \
    || die "no config/slack-channels in this home, so the channel name '$name' cannot be resolved"
  id=$(sed -n "s/^[[:space:]]*$name=//p" "$file" | tail -n1 | tr -d '[:space:]')
  [ -n "$id" ] || die "config/slack-channels has no entry for '$name'"
  valid_slack_id "$id" || die "config/slack-channels maps '$name' to an invalid channel id"
  printf '%s\n' "$id"
}

# The configured captain channel, or empty when this home watches none.
captain_channel() {
  local file id
  file="$(config_dir)/slack-captain"
  [ -f "$file" ] && [ ! -L "$file" ] || return 0
  id=$(sed -n 's/^[[:space:]]*channel=//p' "$file" | tail -n1 | tr -d '[:space:]')
  valid_slack_id "$id" || return 0
  printf '%s\n' "$id"
}

CHANNEL=
THREAD=
FILE=
DETAILS=
ORIGIN=manual
TEXT_ARGS=()

[ "$#" -gt 0 ] || usage
case "${1-}" in
  ''|-h|--help|help) usage ;;
esac
CHANNEL=$1
shift

while [ "$#" -gt 0 ]; do
  case "$1" in
    --file)   [ "$#" -ge 2 ] || die "--file needs a path"; FILE=$2; shift 2 ;;
    --thread) [ "$#" -ge 2 ] || die "--thread needs a timestamp"; THREAD=$2; shift 2 ;;
    --worker-details)
      [ "$#" -ge 2 ] || die "--worker-details needs a \"<model> <effort>\" value"
      DETAILS=$2; shift 2 ;;
    --origin)
      [ "$#" -ge 2 ] || die "--origin needs a value"
      case "$2" in
        manual|mirror) ORIGIN=$2 ;;
        *) die "--origin accepts only manual or mirror" ;;
      esac
      shift 2 ;;
    -h|--help) usage ;;
    --*) die "unknown option: $1" ;;
    *) TEXT_ARGS+=("$1"); shift ;;
  esac
done

command -v curl >/dev/null 2>&1 || die "curl is not installed"
command -v jq >/dev/null 2>&1 || die "jq is not installed"

channel=$(resolve_channel "$CHANNEL") || exit 1
[ -z "$THREAD" ] || valid_ts "$THREAD" || die "invalid thread timestamp: $THREAD"
case "$DETAILS" in
  '') ;;
  *[!A-Za-z0-9\ ._/-]*) die "--worker-details accepts only plain model and effort names" ;;
  *) [ "${#DETAILS}" -le 80 ] || die "--worker-details is too long" ;;
esac

if [ -n "$FILE" ]; then
  [ "${#TEXT_ARGS[@]}" -eq 0 ] || die "give message text or --file, not both"
  [ -f "$FILE" ] && [ ! -L "$FILE" ] || die "message file is unavailable or unsafe: $FILE"
  text=$(cat "$FILE")
else
  [ "${#TEXT_ARGS[@]}" -gt 0 ] || die "no message text; give text or --file"
  text="${TEXT_ARGS[*]}"
fi
[ -n "$text" ] || die "the message is empty"
[ "${#text}" -le "$MAX_BODY_BYTES" ] || die "the message is longer than $MAX_BODY_BYTES characters"
[ -z "$DETAILS" ] || text=$(printf '%s\n\n_worker: %s_' "$text" "$DETAILS")

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-slack-post.XXXXXX") || die "cannot create a staging directory"
trap 'rm -rf -- "$TMP"' EXIT
body="$TMP/body.json"
resp="$TMP/response.json"

jq -n --arg channel "$channel" --arg text "$text" --arg thread "$THREAD" '
  {channel: $channel, text: $text}
  + (if $thread == "" then {} else {thread_ts: $thread} end)
' > "$body" || die "cannot build the Slack request body"

token=$(read_token) || exit 1
printf 'header = "Authorization: Bearer %s"\n' "$token" \
  | curl -sS --config - --max-time "$CURL_MAX_TIME" \
      -H 'Content-Type: application/json; charset=utf-8' \
      --data-binary "@$body" \
      "$SLACK_API/chat.postMessage" -o "$resp" 2>/dev/null \
  || die "the Slack request failed"

jq -e . "$resp" >/dev/null 2>&1 || die "Slack returned an unreadable response"
if ! jq -e '.ok == true' "$resp" >/dev/null 2>&1; then
  err=$(jq -r '.error // "unknown"' "$resp" 2>/dev/null || printf 'unknown')
  case "$err" in
    ''|*[!A-Za-z0-9_-]*) err=unknown ;;
  esac
  die "Slack refused the message: $err"
fi

ts=$(jq -r '.ts // ""' "$resp")
valid_ts "$ts" || die "Slack accepted the message but returned no usable timestamp"

# Register the thread this post replies into, so a captain reply inside it is
# captured. A top-level post is not yet a thread, so it is not registered: doing
# so would consume a tracked-thread slot and an extra poll request for a thread
# that may never exist. A home that watches no captain channel needs nothing
# here, and a registration failure never invalidates a message Slack already
# accepted.
watched=$(captain_channel)
# The terminal mirror's duplicate test; a failure here never invalidates a
# message Slack already accepted.
if [ -n "$watched" ] && [ "$watched" = "$channel" ] && [ "$ORIGIN" = manual ]; then
  "$SCRIPT_DIR/fm-slack-mirror.sh" note-post "$channel" >/dev/null 2>&1 || true
fi
if [ -n "$watched" ] && [ "$watched" = "$channel" ] && [ -n "$THREAD" ]; then
  "$SCRIPT_DIR/fm-procevent-slack-captain.sh" track-thread "$channel" "$THREAD" >/dev/null 2>&1 \
    || printf 'fm-slack-post: could not register thread %s for capture\n' "$THREAD" >&2
fi

printf '%s\n' "$ts"
