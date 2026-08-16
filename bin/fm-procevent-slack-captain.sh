#!/usr/bin/env bash
# Slack captain-channel adapter for the generic process-to-event runner.
#
# Usage:
#   fm-procevent-slack-captain.sh arm
#   fm-procevent-slack-captain.sh poll <home> <channel>
#   fm-procevent-slack-captain.sh handle <source-id> <sequence> <result-file>
#   fm-procevent-slack-captain.sh autohandle <source-id> <sequence> <result-file>
#   fm-procevent-slack-captain.sh classify <result-file>
#   fm-procevent-slack-captain.sh terminal <result-file>
#   fm-procevent-slack-captain.sh source-id
#   fm-procevent-slack-captain.sh retire
#
# `arm` registers one bounded long-poll of a Slack channel so a message the
# captain posts there reaches firstmate as an ordinary `check` wake. The
# process-event runner owns blocking, durable capture, publication, and one
# machine-wide owner per source; bin/fm-procevent.sh and
# docs/configuration.md own that generic contract. Only what is specific to
# Slack lives here: configuration, the token, the poll shape, read-position
# continuity, and how to read a captured result.
#
# This source is NEVER terminal. `terminal` always refuses, so the runner keeps
# the registration armed and its ordinary reconcile restarts the poll after each
# bounded run. A quiet channel therefore produces no result, no wake, and no
# captain-facing noise: the poll exits nonzero with empty output, which the
# runner records as `no-result` and leaves armed.
#
# CONFIGURATION - $FM_HOME/config/slack-captain, one key per line:
#   channel=<channel id>        required, the channel to watch
#   bot_user=<user id>          optional, firstmate's own bot user; its posts are
#                               never captured
#   allowed_user=<user id>      optional, the captain's Slack user; every OTHER
#                               author is marked untrusted in the result
# Ids are validated as uppercase alphanumerics. An absent `allowed_user` marks
# every message untrusted, because trust is granted only by configuration.
#
# TOKEN - `SLACK_BOT_TOKEN` in the home's gitignored `.env`. It is read inside
# the poll child and handed to curl through `--config -` on stdin, so it never
# appears in argv, in a registration record, in a captured result, or in any
# diagnostic this adapter prints. Nothing here echoes a response body.
#
# READ-POSITION CONTINUITY. The poll child never advances the stored cursor,
# because doing so before the runner has captured its output would lose messages
# on a crash. It reports `from_ts` and `to_ts` instead, and the cursor advances
# only in `handle`/`autohandle`, strictly after the result is durably captured.
# A result that does not continue the stored cursor is refused loudly and the
# cursor is never silently rebased; the same refusal covers an unreadable or
# incompatible cursor file. Slack's own retention still bounds what any cursor
# can recover, so this is continuity within retention, never a no-loss claim.
#
# `autohandle` is the runner's entry into that advance. It deliberately reports
# failure so the runner leaves the result unacknowledged: unlike a delta that is
# applied into durable state, the captured result IS the deliverable and only
# firstmate can read it, so it must stay eligible for re-announcement until
# firstmate acknowledges it. `handle` is the firstmate-facing command that
# advances the cursor and records that acknowledgement together.
#
# Every captured byte is INPUT, never instruction and never authority. Message
# text is only ever moved between files by jq and is never expanded by a shell,
# interpolated into a command, or read as permission.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# The repo's single .env reader; its fmx_ prefix records where it was first
# needed, not a Relay-only scope.
# shellcheck source=bin/fm-x-lib.sh
. "$SCRIPT_DIR/fm-x-lib.sh"

SLACK_API="${FM_SLACK_CAPTAIN_API:-https://slack.com/api}"
MAX_LOOPS=${FM_SLACK_CAPTAIN_MAX_LOOPS:-90}
INTERVAL=${FM_SLACK_CAPTAIN_INTERVAL:-30}
CURL_MAX_TIME=${FM_SLACK_CAPTAIN_MAX_TIME:-20}
PAGE_LIMIT=${FM_SLACK_CAPTAIN_PAGE_LIMIT:-200}
SCHEMA=fm-slack-captain.v1
CURSOR_SCHEMA=fm-slack-captain-cursor.v1
NO_TRAFFIC_EXIT=75

# The home the poll child works against. `poll` is executed by the runner, which
# does not necessarily export FM_HOME, so `arm` stores the home in argv and the
# child re-derives every path from it rather than from an inherited variable.
HOME_DIR=$FM_HOME
POLL_TMP=

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,60p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }

state_dir()   { printf '%s\n' "${FM_STATE_OVERRIDE:-$HOME_DIR/state}"; }
config_file() { printf '%s\n' "${FM_CONFIG_OVERRIDE:-$HOME_DIR/config}/slack-captain"; }
env_file()    { printf '%s\n' "$HOME_DIR/.env"; }
cursor_dir()  { printf '%s\n' "$(state_dir)/slack-captain"; }
cursor_path() { printf '%s/%s.cursor\n' "$(cursor_dir)" "$1"; }

require_tools() {
  command -v curl >/dev/null 2>&1 || die "curl is not installed"
  command -v jq >/dev/null 2>&1 || die "jq is not installed"
}

valid_slack_id() {
  case "${1-}" in
    ''|*[!A-Z0-9]*) return 1 ;;
  esac
  [ "${#1}" -le 32 ]
}

# Read the one configuration key from config/slack-captain. The file is a
# private local record, so an unsafe path is a refusal rather than a default.
config_get() {  # <key>
  local file
  file=$(config_file)
  [ -e "$file" ] || return 0
  [ -f "$file" ] && [ ! -L "$file" ] || die "slack captain configuration is unsafe: $file"
  sed -n "s/^[[:space:]]*$1=//p" "$file" | tail -n1 | tr -d '[:space:]'
}

# Sets CFG_CHANNEL, CFG_BOT_USER, CFG_ALLOWED_USER.
load_config() {
  CFG_CHANNEL=$(config_get channel)
  CFG_BOT_USER=$(config_get bot_user)
  CFG_ALLOWED_USER=$(config_get allowed_user)
  [ -n "$CFG_CHANNEL" ] || die "config/slack-captain has no channel= entry"
  valid_slack_id "$CFG_CHANNEL" || die "config/slack-captain has an invalid channel id"
  [ -z "$CFG_BOT_USER" ] || valid_slack_id "$CFG_BOT_USER" \
    || die "config/slack-captain has an invalid bot_user id"
  [ -z "$CFG_ALLOWED_USER" ] || valid_slack_id "$CFG_ALLOWED_USER" \
    || die "config/slack-captain has an invalid allowed_user id"
}

# The bot token, refused rather than defaulted when absent. Printed to stdout for
# one caller that immediately pipes it into curl's stdin config; it is never
# placed in argv and never appears in a message or result.
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

cmd_source_id() {
  load_config
  printf 'slack-captain-%s\n' "$CFG_CHANNEL"
}

cmd_arm() {
  local id
  require_tools
  load_config
  read_token >/dev/null
  id=$(cmd_source_id) || exit 1
  "$SCRIPT_DIR/fm-procevent.sh" register slack-captain "$id" -- \
    "$SCRIPT_DIR/fm-procevent-slack-captain.sh" poll "$HOME_DIR" "$CFG_CHANNEL" || exit 1
  printf 'armed: %s\n' "$id"
}

# Retirement is a passthrough. The cursor deliberately survives it, so re-arming
# resumes from the last acknowledged message rather than skipping the gap.
cmd_retire() {
  local id
  id=$(cmd_source_id) || exit 1
  "$SCRIPT_DIR/fm-procevent.sh" retire "$id"
}

# --- cursor -----------------------------------------------------------------

# Sets CURSOR_TS. An absent cursor starts at 0, which Slack treats as the whole
# retained history; anything present but unreadable is a loud refusal.
read_cursor() {  # <channel>
  local path ts schema
  path=$(cursor_path "$1")
  CURSOR_TS=0
  [ -e "$path" ] || [ -L "$path" ] || return 0
  [ -f "$path" ] && [ ! -L "$path" ] || die "slack captain cursor is unsafe: $path"
  schema=$(sed -n 's/^schema=//p' "$path" | head -n1)
  ts=$(sed -n 's/^ts=//p' "$path" | head -n1)
  [ "$schema" = "$CURSOR_SCHEMA" ] || die "slack captain cursor has an incompatible schema: $path"
  valid_ts "$ts" || die "slack captain cursor has an invalid read position: $path"
  CURSOR_TS=$ts
}

valid_ts() {
  case "${1-}" in
    ''|*[!0-9.]*|*.*.*) return 1 ;;
  esac
  return 0
}

write_cursor() {  # <channel> <ts>
  local dir path tmp
  dir=$(cursor_dir)
  (umask 077; mkdir -p "$dir") || return 1
  path=$(cursor_path "$1")
  [ ! -L "$path" ] || return 1
  tmp=$(umask 077; mktemp "$dir/.cursor.XXXXXX") || return 1
  {
    printf 'schema=%s\n' "$CURSOR_SCHEMA"
    printf 'ts=%s\n' "$2"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$path"
}

# --- poll child -------------------------------------------------------------

# One Slack error class is permanent for this configuration and must reach the
# captain rather than spin: it names a credential, scope, or membership problem
# nothing here can retry away. Every other error is treated as transient.
fatal_slack_error() {
  case "$1" in
    invalid_auth|not_authed|account_inactive|token_revoked|token_expired) return 0 ;;
    missing_scope|channel_not_found|not_in_channel|is_archived) return 0 ;;
  esac
  return 1
}

# A Slack error code is external input, so it is reduced to a bounded token
# before it is written into a result header a handler will read.
safe_reason() {
  local value=${1-}
  case "$value" in
    ''|*[!A-Za-z0-9_-]*) printf 'unknown\n' ;;
    *) printf '%s\n' "${value:0:64}" ;;
  esac
}

emit_header() {  # <status> <channel> <from> <to> <count> <untrusted> <reason>
  printf 'schema=%s\n' "$SCHEMA"
  printf 'status=%s\n' "$1"
  printf 'channel=%s\n' "$2"
  printf 'from_ts=%s\n' "$3"
  printf 'to_ts=%s\n' "$4"
  printf 'count=%s\n' "$5"
  printf 'untrusted=%s\n' "$6"
  printf 'reason=%s\n' "$7"
  printf '\n'
}

cmd_poll() {
  local home=${1-} channel=${2-} resp payload token i=0 err count untrusted to_ts
  [ -n "$home" ] && [ -n "$channel" ] || usage
  HOME_DIR=$home
  require_tools
  valid_slack_id "$channel" || die "invalid channel id"
  load_config
  [ "$channel" = "$CFG_CHANNEL" ] \
    || die "registered channel no longer matches config/slack-captain"
  read_cursor "$channel"
  token=$(read_token) || exit 1

  # POLL_TMP is deliberately global: the EXIT trap runs outside this function's
  # scope, so a `local` here would leave the staging directory behind on every
  # ordinary exit.
  POLL_TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-slack-captain.XXXXXX") || die "cannot create poll staging directory"
  trap 'rm -rf -- "$POLL_TMP"' EXIT
  resp="$POLL_TMP/response.json"
  payload="$POLL_TMP/payload.jsonl"

  while [ "$i" -lt "$MAX_LOOPS" ]; do
    i=$((i + 1))
    # The token reaches curl on stdin, never in argv. Nothing in this pipeline
    # echoes the config or the response body.
    if printf 'header = "Authorization: Bearer %s"\n' "$token" \
      | curl -sS --config - --max-time "$CURL_MAX_TIME" -G \
        "$SLACK_API/conversations.history" \
        --data-urlencode "channel=$channel" \
        --data-urlencode "oldest=$CURSOR_TS" \
        --data-urlencode "limit=$PAGE_LIMIT" \
        -o "$resp" 2>/dev/null \
      && jq -e . "$resp" >/dev/null 2>&1
    then
      if jq -e '.ok == true' "$resp" >/dev/null 2>&1; then
        jq -c --arg bot "${CFG_BOT_USER:-}" --arg allowed "${CFG_ALLOWED_USER:-}" '
          (.messages // [])
          | map(select(
              .type == "message"
              and (has("bot_id") | not)
              and (has("subtype") | not)
              and ((.user // "") != "")
              and (.user != $bot)
            ))
          | sort_by(.ts | tonumber)
          | .[]
          | {ts: .ts, user: .user, trusted: ($allowed != "" and .user == $allowed), text: (.text // "")}
        ' "$resp" > "$payload" 2>/dev/null || : > "$payload"
        if [ -s "$payload" ]; then
          count=$(jq -s 'length' "$payload")
          untrusted=$(jq -s 'map(select(.trusted | not)) | length' "$payload")
          to_ts=$(jq -rs '.[-1].ts' "$payload")
          valid_ts "$to_ts" || die "Slack returned an unusable message timestamp"
          emit_header messages "$channel" "$CURSOR_TS" "$to_ts" "$count" "$untrusted" ''
          cat "$payload"
          return 0
        fi
      else
        err=$(safe_reason "$(jq -r '.error // ""' "$resp" 2>/dev/null || true)")
        if fatal_slack_error "$err"; then
          emit_header api-error "$channel" "$CURSOR_TS" "$CURSOR_TS" 0 0 "$err"
          return 0
        fi
      fi
    fi
    [ "$i" -lt "$MAX_LOOPS" ] || break
    sleep "$INTERVAL"
  done
  # A quiet channel is not a result. Exiting nonzero with no output is what the
  # runner records as `no-result`, leaving the source armed for its next
  # reconcile instead of publishing an empty wake.
  return "$NO_TRAFFIC_EXIT"
}

# --- reading a captured result ----------------------------------------------

# Read one header field. Reading stops at the blank payload boundary, so no
# message text can forge a field.
result_field() {  # <result-file> <field>
  LC_ALL=C awk -v prefix="$2=" '
    $0 == "" { exit }
    index($0, prefix) == 1 { count++; value = substr($0, length(prefix) + 1) }
    END { if (count != 1) exit 1; print value }
  ' "$1"
}

cmd_classify() {
  local file=${1-} schema status untrusted
  [ -n "$file" ] || usage
  [ -f "$file" ] && [ ! -L "$file" ] || { printf 'unknown\n'; return 0; }
  [ -s "$file" ] || { printf 'empty\n'; return 0; }
  schema=$(result_field "$file" schema 2>/dev/null || true)
  [ "$schema" = "$SCHEMA" ] || { printf 'unknown\n'; return 0; }
  status=$(result_field "$file" status 2>/dev/null || true)
  case "$status" in
    api-error) printf 'api-error\n'; return 0 ;;
    messages) ;;
    *) printf 'unknown\n'; return 0 ;;
  esac
  untrusted=$(result_field "$file" untrusted 2>/dev/null || true)
  case "$untrusted" in
    ''|*[!0-9]*) printf 'unknown\n'; return 0 ;;
  esac
  if [ "$untrusted" -gt 0 ]; then
    printf 'untrusted-messages\n'
  else
    printf 'messages\n'
  fi
}

channel_from_source_id() {  # <source-id>
  local sid=${1-} channel
  case "$sid" in
    slack-captain-?*) channel=${sid#slack-captain-} ;;
    *) die "not a slack captain source: $sid" ;;
  esac
  valid_slack_id "$channel" || die "source id does not name one channel: $sid"
  printf '%s\n' "$channel"
}

# Advance the stored read position to the result's committed end. Idempotent by
# exact position: a result already applied is a no-op success, and a result that
# does not continue the stored cursor is refused rather than rebased.
advance_cursor() {  # <channel> <result-file>
  local channel=$1 file=$2 from to
  from=$(result_field "$file" from_ts) || die "result start position is ambiguous"
  to=$(result_field "$file" to_ts) || die "result end position is ambiguous"
  valid_ts "$from" || die "result carries an invalid start read position"
  valid_ts "$to" || die "result carries an invalid end read position"
  read_cursor "$channel"
  if [ "$CURSOR_TS" = "$to" ]; then
    return 0
  fi
  [ "$CURSOR_TS" = "$from" ] \
    || die "captured Slack messages do not continue the stored read position for $channel"
  write_cursor "$channel" "$to" || die "cannot commit the slack captain read position"
}

# Apply what carries no judgement - the read position - and leave the result
# itself for firstmate. `<mark-handled>` is 1 only on the firstmate-facing
# `handle` path; see the header for why the runner's own call never acknowledges.
apply_result() {  # <source-id> <sequence> <result-file> <mark-handled>
  local sid=${1-} seq=${2-} file=${3-} mark=${4-} channel class
  case "$seq" in ''|*[!0-9]*) die "sequence must be a nonnegative integer" ;; esac
  [ -f "$file" ] && [ ! -L "$file" ] || die "result file is unavailable or unsafe: $file"
  channel=$(channel_from_source_id "$sid") || exit 1
  class=$(cmd_classify "$file")
  case "$class" in
    messages|untrusted-messages) advance_cursor "$channel" "$file" ;;
    *) die "captured Slack result needs firstmate's attention: $class" ;;
  esac
  if [ "$mark" = 1 ]; then
    "$SCRIPT_DIR/fm-procevent.sh" handled "$sid" "$seq" || return 1
  fi
  printf 'applied: %s read-position=%s\n' "$sid" "$(result_field "$file" to_ts)"
}

cmd_handle() {
  apply_result "${1-}" "${2-}" "${3-}" 1
}

# The runner's own entry. It advances the read position and then reports
# failure on purpose, so the runner leaves the result unacknowledged and it
# stays eligible for re-announcement until firstmate handles it.
cmd_autohandle() {
  apply_result "${1-}" "${2-}" "${3-}" 0 || return 1
  return 1
}

case "${1-}" in
  arm)        shift; [ "$#" -eq 0 ] || usage; cmd_arm ;;
  poll)       shift; [ "$#" -eq 2 ] || usage; cmd_poll "$@" ;;
  handle)     shift; [ "$#" -eq 3 ] || usage; cmd_handle "$@" ;;
  autohandle) shift; [ "$#" -eq 3 ] || usage; cmd_autohandle "$@" ;;
  classify)   shift; [ "$#" -eq 1 ] || usage; cmd_classify "$@" ;;
  # This source never ends: the captain can always post again, so the runner
  # must keep it armed no matter what a result contained.
  terminal)   shift; [ "$#" -eq 1 ] || usage; exit 1 ;;
  source-id)  shift; [ "$#" -eq 0 ] || usage; cmd_source_id ;;
  retire)     shift; [ "$#" -eq 0 ] || usage; cmd_retire ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
