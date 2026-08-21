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
#   fm-procevent-slack-captain.sh track-thread <channel> <thread-ts>
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
#   quiet_window=<seconds>      optional, the debounce hold below (default 90)
# Ids are validated as uppercase alphanumerics. An absent `allowed_user` marks
# every message untrusted, because trust is granted only by configuration.
#
# TOKEN - `SLACK_BOT_TOKEN` in the home's gitignored `.env`. It is read inside
# the poll child and handed to curl through `--config -` on stdin, so it never
# appears in argv, in a registration record, in a captured result, or in any
# diagnostic this adapter prints. Nothing here echoes a response body.
#
# READ-POSITION CONTINUITY. The poll child never advances a stored cursor,
# because doing so before the runner has captured its output would lose messages
# on a crash. It reports `from_ts` and `to_ts` instead, and cursors advance
# only in `handle`/`autohandle`, strictly after the result is durably captured.
# A result that does not continue the stored cursor is refused loudly and the
# cursor is never silently rebased; the same refusal covers an unreadable or
# incompatible cursor file. Slack's own retention still bounds what any cursor
# can recover, so this is continuity within retention, never a no-loss claim.
#
# THREAD REPLIES. Channel history alone cannot see a reply the captain writes
# inside a thread, so this adapter also reads conversations.replies for every
# TRACKED thread. A thread becomes tracked when a message in a captured window
# carries a `thread_ts`, and when `track-thread` is called - which is how
# bin/fm-slack-post.sh registers the threads firstmate's own posts create or
# reply into. Each tracked thread keeps its own cursor under
# state/slack-captain/threads/<channel>/, advanced by exactly the same
# capture-first rule as the channel cursor, and the result names each thread's
# committed span in a repeated `thread=` header line. Every captured thread
# reply carries `thread_ts` in its payload object, so a reply can be bound back
# to the topic it answers. Trust classification is identical: only the
# configured captain is trusted. Tracked threads older than
# FM_SLACK_CAPTAIN_THREAD_MAX_AGE are no longer polled, and their records are
# pruned when a later result is handled.
#
# DEBOUNCE. A captain writing several messages in a row is one thought, not
# several wakes. The poll listens on a short interval, and when it first sees
# new traffic it does NOT capture: it holds a quiet window (`quiet_window`,
# default 90 seconds), recollects the whole span from the unmoved cursor, and
# repeats until a window adds nothing new or FM_SLACK_CAPTAIN_MAX_QUIET_WINDOWS
# holds have elapsed, so a continuous stream still flushes. That bound set to 0
# disables the hold and captures the first window immediately. Because every
# recollection reads from the same unmoved cursor, the hold cannot lose a
# message and a crash mid-hold loses only an uncaptured, unacknowledged window.
# A transient fetch failure or a fatal Slack error DURING a hold ends the hold
# and emits the burst already collected rather than discarding it; the fatal
# error is reported by the next poll, which re-hits it.
#
# A window holding more messages than one page fetches is paginated to
# exhaustion (bounded by FM_SLACK_CAPTAIN_MAX_PAGES) before a result is
# emitted, so `to_ts` never commits past a message the result did not capture.
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
INTERVAL=${FM_SLACK_CAPTAIN_INTERVAL:-20}
CURL_MAX_TIME=${FM_SLACK_CAPTAIN_MAX_TIME:-20}
PAGE_LIMIT=${FM_SLACK_CAPTAIN_PAGE_LIMIT:-200}
MAX_PAGES=${FM_SLACK_CAPTAIN_MAX_PAGES:-25}
MAX_QUIET_WINDOWS=${FM_SLACK_CAPTAIN_MAX_QUIET_WINDOWS:-3}
MAX_THREADS=${FM_SLACK_CAPTAIN_MAX_THREADS:-20}
THREAD_MAX_AGE=${FM_SLACK_CAPTAIN_THREAD_MAX_AGE:-604800}
DEFAULT_QUIET_WINDOW=90
SCHEMA=fm-slack-captain.v1
CURSOR_SCHEMA=fm-slack-captain-cursor.v1
THREAD_SCHEMA=fm-slack-captain-thread-cursor.v1
NO_TRAFFIC_EXIT=75

# The home the poll child works against. `poll` is executed by the runner, which
# does not necessarily export FM_HOME, so `arm` stores the home in argv and the
# child re-derives every path from it rather than from an inherited variable.
HOME_DIR=$FM_HOME
POLL_TMP=

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,86p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }

state_dir()   { printf '%s\n' "${FM_STATE_OVERRIDE:-$HOME_DIR/state}"; }
config_file() { printf '%s\n' "${FM_CONFIG_OVERRIDE:-$HOME_DIR/config}/slack-captain"; }
env_file()    { printf '%s\n' "$HOME_DIR/.env"; }
cursor_dir()  { printf '%s\n' "$(state_dir)/slack-captain"; }
cursor_path() { printf '%s/%s.cursor\n' "$(cursor_dir)" "$1"; }
thread_dir()  { printf '%s/threads/%s\n' "$(cursor_dir)" "$1"; }
thread_path() { printf '%s/%s.cursor\n' "$(thread_dir "$1")" "$2"; }

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

# Sets CFG_CHANNEL, CFG_BOT_USER, CFG_ALLOWED_USER, QUIET_WINDOW.
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
  # The environment override exists for tests and specialized setups; the
  # configured value is the captain-facing knob and the default is the floor.
  QUIET_WINDOW=${FM_SLACK_CAPTAIN_QUIET_WINDOW-}
  if [ -z "$QUIET_WINDOW" ]; then
    QUIET_WINDOW=$(config_get quiet_window)
    [ -n "$QUIET_WINDOW" ] || QUIET_WINDOW=$DEFAULT_QUIET_WINDOW
  fi
  case "$QUIET_WINDOW" in
    ''|*[!0-9]*) die "config/slack-captain has an invalid quiet_window" ;;
  esac
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

valid_ts() {
  case "${1-}" in
    ''|*[!0-9.]*|*.*.*) return 1 ;;
  esac
  return 0
}

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

# One private cursor record, written atomically. Used for the channel cursor and
# for every tracked thread cursor, which differ only in their schema and path.
write_cursor_file() {  # <path> <schema> <ts>
  local dir tmp
  dir=$(dirname "$1")
  (umask 077; mkdir -p "$dir") || return 1
  [ ! -L "$1" ] || return 1
  tmp=$(umask 077; mktemp "$dir/.cursor.XXXXXX") || return 1
  {
    printf 'schema=%s\n' "$2"
    printf 'ts=%s\n' "$3"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$1"
}

write_cursor() {  # <channel> <ts>
  write_cursor_file "$(cursor_path "$1")" "$CURSOR_SCHEMA" "$2"
}

# --- tracked threads --------------------------------------------------------

# Sets THREAD_TS_READ for one tracked thread. An absent record is not tracked.
read_thread_cursor() {  # <channel> <thread-ts>
  local path ts schema
  path=$(thread_path "$1" "$2")
  THREAD_TS_READ=
  [ -e "$path" ] || return 1
  [ -f "$path" ] && [ ! -L "$path" ] || die "slack captain thread cursor is unsafe: $path"
  schema=$(sed -n 's/^schema=//p' "$path" | head -n1)
  ts=$(sed -n 's/^ts=//p' "$path" | head -n1)
  [ "$schema" = "$THREAD_SCHEMA" ] \
    || die "slack captain thread cursor has an incompatible schema: $path"
  valid_ts "$ts" || die "slack captain thread cursor has an invalid read position: $path"
  THREAD_TS_READ=$ts
}

# Start tracking a thread. Creating the record is registration, not a read
# position: it starts AT the thread root, so every reply after the root is still
# captured before anything is ever marked read. Idempotent, and never moves an
# existing read position.
track_thread() {  # <channel> <thread-ts>
  local path
  valid_ts "$2" || return 1
  path=$(thread_path "$1" "$2")
  [ ! -e "$path" ] || return 0
  write_cursor_file "$path" "$THREAD_SCHEMA" "$2"
}

cmd_track_thread() {  # <channel> <thread-ts>
  local channel=${1-} ts=${2-}
  valid_slack_id "$channel" || die "invalid channel id"
  valid_ts "$ts" || die "invalid thread timestamp"
  track_thread "$channel" "$ts" || die "cannot record the tracked thread"
  printf 'tracked: %s %s\n' "$channel" "$ts"
}

# The tracked threads worth polling now: the most recent MAX_THREADS whose root
# is younger than THREAD_MAX_AGE. An old thread stops being polled rather than
# growing the per-poll request count without bound.
active_threads() {  # <channel>
  local dir now cutoff name ts
  dir=$(thread_dir "$1")
  [ -d "$dir" ] || return 0
  now=$(date +%s)
  cutoff=$((now - THREAD_MAX_AGE))
  for name in "$dir"/*.cursor; do
    [ -f "$name" ] || continue
    ts=${name##*/}
    ts=${ts%.cursor}
    valid_ts "$ts" || continue
    [ "${ts%%.*}" -ge "$cutoff" ] || continue
    printf '%s\n' "$ts"
  done | sort -n | tail -n "$MAX_THREADS"
}

# Drop tracked-thread records far past the age at which they stopped being
# polled. Called only from the acknowledgement path, never from the poll child.
prune_threads() {  # <channel>
  local dir now cutoff name ts
  dir=$(thread_dir "$1")
  [ -d "$dir" ] || return 0
  now=$(date +%s)
  cutoff=$((now - THREAD_MAX_AGE * 4))
  for name in "$dir"/*.cursor; do
    [ -f "$name" ] || continue
    ts=${name##*/}
    ts=${ts%.cursor}
    valid_ts "$ts" || continue
    [ "${ts%%.*}" -lt "$cutoff" ] && rm -f -- "$name"
  done
  return 0
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

emit_header() {  # <status> <channel> <from> <to> <count> <untrusted> <reason> [thread-lines-file]
  printf 'schema=%s\n' "$SCHEMA"
  printf 'status=%s\n' "$1"
  printf 'channel=%s\n' "$2"
  printf 'from_ts=%s\n' "$3"
  printf 'to_ts=%s\n' "$4"
  printf 'count=%s\n' "$5"
  printf 'untrusted=%s\n' "$6"
  printf 'reason=%s\n' "$7"
  [ -z "${8-}" ] || [ ! -s "$8" ] || cat "$8"
  printf '\n'
}

# One conversations.history page. The token reaches curl on stdin, never in
# argv. Nothing in this pipeline echoes the config or the response body.
fetch_page() {  # <channel> <latest-or-empty>
  local args
  args=( -sS --config - --max-time "$CURL_MAX_TIME" -G
    "$SLACK_API/conversations.history"
    --data-urlencode "channel=$1"
    --data-urlencode "oldest=$CURSOR_TS"
    --data-urlencode "limit=$PAGE_LIMIT"
    -o "$resp" )
  [ -z "$2" ] || args+=( --data-urlencode "latest=$2" )
  printf 'header = "Authorization: Bearer %s"\n' "$token" \
    | curl "${args[@]}" 2>/dev/null
}

# One conversations.replies page, from a thread's own read position. The first
# page is bounded by `oldest`; later pages follow Slack's own cursor, and the
# payload is filtered by timestamp regardless, so a cursor page can never
# reintroduce something already read.
fetch_replies_page() {  # <channel> <thread-ts> <oldest> <next-cursor-or-empty>
  local args
  args=( -sS --config - --max-time "$CURL_MAX_TIME" -G
    "$SLACK_API/conversations.replies"
    --data-urlencode "channel=$1"
    --data-urlencode "ts=$2"
    --data-urlencode "limit=$PAGE_LIMIT"
    -o "$resp" )
  if [ -n "$4" ]; then
    args+=( --data-urlencode "cursor=$4" )
  else
    args+=( --data-urlencode "oldest=$3" )
  fi
  printf 'header = "Authorization: Bearer %s"\n' "$token" \
    | curl "${args[@]}" 2>/dev/null
}

# Fetch the whole channel window past the cursor into $raw.
# Sets FETCHED (1 ok) and FATAL (a fatal Slack error code, or empty).
fetch_window() {  # <channel>
  local page=0 latest='' more err
  : > "$raw"
  FETCHED=1
  FATAL=
  while :; do
    page=$((page + 1))
    if ! fetch_page "$1" "$latest" || ! jq -e . "$resp" >/dev/null 2>&1; then
      FETCHED=0
      return 0
    fi
    if ! jq -e '.ok == true' "$resp" >/dev/null 2>&1; then
      err=$(safe_reason "$(jq -r '.error // ""' "$resp" 2>/dev/null || true)")
      fatal_slack_error "$err" && FATAL=$err
      FETCHED=0
      return 0
    fi
    if ! jq -c '.messages[]?' "$resp" >> "$raw" 2>/dev/null; then
      printf 'slack-captain: could not read the messages in a Slack page; retrying\n' >&2
      FETCHED=0
      return 0
    fi
    more=$(jq -r '.has_more == true' "$resp" 2>/dev/null || true)
    [ "$more" = true ] || return 0
    [ "$page" -lt "$MAX_PAGES" ] \
      || die "the Slack window past the read position exceeds $MAX_PAGES pages; refusing to emit a partial capture"
    latest=$(jq -r '[.messages[].ts] | min_by(tonumber)' "$resp" 2>/dev/null || true)
    valid_ts "$latest" || die "Slack returned an unusable message timestamp"
  done
}

# Fetch every new reply in one tracked thread into $traw.
# Sets FETCHED (1 ok) and FATAL, exactly like fetch_window.
fetch_thread() {  # <channel> <thread-ts> <oldest>
  local page=0 next='' more err
  : > "$traw"
  FETCHED=1
  FATAL=
  while :; do
    page=$((page + 1))
    if ! fetch_replies_page "$1" "$2" "$3" "$next" || ! jq -e . "$resp" >/dev/null 2>&1; then
      FETCHED=0
      return 0
    fi
    if ! jq -e '.ok == true' "$resp" >/dev/null 2>&1; then
      err=$(safe_reason "$(jq -r '.error // ""' "$resp" 2>/dev/null || true)")
      fatal_slack_error "$err" && FATAL=$err
      FETCHED=0
      return 0
    fi
    if ! jq -c --arg oldest "$3" --arg root "$2" '
        .messages[]? | select((.ts | tonumber) > ($oldest | tonumber)) | select(.ts != $root)
      ' "$resp" >> "$traw" 2>/dev/null; then
      printf 'slack-captain: could not read the replies in a Slack thread page; retrying\n' >&2
      FETCHED=0
      return 0
    fi
    more=$(jq -r '.has_more == true' "$resp" 2>/dev/null || true)
    [ "$more" = true ] || return 0
    [ "$page" -lt "$MAX_PAGES" ] \
      || die "a Slack thread past its read position exceeds $MAX_PAGES pages; refusing to emit a partial capture"
    next=$(jq -r '.response_metadata.next_cursor // ""' "$resp" 2>/dev/null || true)
    [ -n "$next" ] || return 0
  done
}

# The one filter that decides what is a capturable captain message, applied
# identically to channel history and to thread replies.
select_messages() {  # <input-jsonl> <output-jsonl> <thread-ts-or-empty>
  jq -cs --arg bot "${CFG_BOT_USER:-}" --arg allowed "${CFG_ALLOWED_USER:-}" \
     --arg thread "$3" '
    map(select(
        .type == "message"
        and (has("bot_id") | not)
        and (has("subtype") | not)
        and ((.user // "") != "")
        and (.user != $bot)
      ))
    | sort_by(.ts | tonumber)
    | .[]
    | {ts: .ts, user: .user, trusted: ($allowed != "" and .user == $allowed), text: (.text // "")}
      + (if $thread == "" then {} else {thread_ts: $thread} end)
  ' "$1" > "$2" 2>/dev/null
}

# Collect one whole capture candidate from the UNMOVED cursor: the channel
# window plus every tracked thread's new replies. Writes the combined payload to
# $payload and the per-thread header lines to $threadlines, and sets
# CHANNEL_TO_TS. Sets FETCHED/FATAL from whichever call failed first.
collect_window() {  # <channel>
  local ts oldest tpayload
  CHANNEL_TO_TS=$CURSOR_TS
  : > "$payload"
  : > "$threadlines"
  fetch_window "$1"
  if [ "$FETCHED" != 1 ]; then
    return 0
  fi
  if [ -s "$raw" ]; then
    # Every thread seen in the window becomes tracked, including one rooted at a
    # message this adapter itself never captures, such as firstmate's own post.
    while IFS= read -r ts; do
      valid_ts "$ts" || continue
      track_thread "$1" "$ts" || true
    done < <(jq -r 'select((.thread_ts // "") != "") | .thread_ts' "$raw" 2>/dev/null | sort -u)
    if ! select_messages "$raw" "$payload" ''; then
      printf 'slack-captain: could not extract messages from a fetched Slack window; retrying\n' >&2
      : > "$payload"
    fi
    if [ -s "$payload" ]; then
      CHANNEL_TO_TS=$(jq -rs '.[-1].ts' "$payload")
      valid_ts "$CHANNEL_TO_TS" || die "Slack returned an unusable message timestamp"
    fi
  fi
  tpayload="$POLL_TMP/thread.payload.jsonl"
  while IFS= read -r ts; do
    [ -n "$ts" ] || continue
    read_thread_cursor "$1" "$ts" || continue
    oldest=$THREAD_TS_READ
    fetch_thread "$1" "$ts" "$oldest"
    if [ "$FETCHED" != 1 ]; then
      return 0
    fi
    [ -s "$traw" ] || continue
    if ! select_messages "$traw" "$tpayload" "$ts"; then
      printf 'slack-captain: could not extract replies from a fetched Slack thread; retrying\n' >&2
      continue
    fi
    [ -s "$tpayload" ] || continue
    cat "$tpayload" >> "$payload"
    printf 'thread=%s %s %s %s\n' "$ts" "$oldest" \
      "$(jq -rs '.[-1].ts' "$tpayload")" "$(jq -s 'length' "$tpayload")" >> "$threadlines"
  done < <(active_threads "$1")
  return 0
}

cmd_poll() {
  local home=${1-} channel=${2-} resp raw traw payload threadlines token i=0
  local count untrusted held prev
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
  raw="$POLL_TMP/messages.raw.jsonl"
  traw="$POLL_TMP/replies.raw.jsonl"
  payload="$POLL_TMP/payload.jsonl"
  threadlines="$POLL_TMP/threads.header"

  while [ "$i" -lt "$MAX_LOOPS" ]; do
    i=$((i + 1))
    collect_window "$channel"
    if [ -n "$FATAL" ]; then
      emit_header api-error "$channel" "$CURSOR_TS" "$CURSOR_TS" 0 0 "$FATAL"
      return 0
    fi
    if [ -s "$payload" ]; then
      # Debounce: hold the burst open until a quiet window adds nothing, or the
      # bounded number of holds is spent. Every recollection reads from the same
      # unmoved cursor, so the held span is a superset, never a replacement.
      prev=$(jq -s 'length' "$payload")
      held=0
      while [ "$held" -lt "$MAX_QUIET_WINDOWS" ]; do
        held=$((held + 1))
        sleep "$QUIET_WINDOW"
        cp "$payload" "$POLL_TMP/held.payload.jsonl"
        cp "$threadlines" "$POLL_TMP/held.threads.header"
        collect_window "$channel"
        if [ "$FETCHED" != 1 ] || [ ! -s "$payload" ]; then
          # A failed or degraded recollection never shrinks a burst already
          # collected: keep it and stop holding.
          cp "$POLL_TMP/held.payload.jsonl" "$payload"
          cp "$POLL_TMP/held.threads.header" "$threadlines"
          CHANNEL_TO_TS=$(jq -rs 'map(select(has("thread_ts") | not)) | if length == 0 then "" else .[-1].ts end' "$payload")
          [ -n "$CHANNEL_TO_TS" ] || CHANNEL_TO_TS=$CURSOR_TS
          break
        fi
        count=$(jq -s 'length' "$payload")
        [ "$count" -gt "$prev" ] || break
        prev=$count
      done
      # The payload is assembled per source, so order it once at the end.
      jq -cs 'sort_by(.ts | tonumber) | .[]' "$payload" > "$POLL_TMP/sorted.jsonl" 2>/dev/null \
        && mv -f "$POLL_TMP/sorted.jsonl" "$payload"
      count=$(jq -s 'length' "$payload")
      untrusted=$(jq -s 'map(select(.trusted | not)) | length' "$payload")
      emit_header messages "$channel" "$CURSOR_TS" "$CHANNEL_TO_TS" \
        "$count" "$untrusted" '' "$threadlines"
      cat "$payload"
      return 0
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

# Read every repeated `thread=` header line. Same boundary rule as
# result_field, so payload text can never forge a thread span.
result_threads() {  # <result-file>
  LC_ALL=C awk '
    $0 == "" { exit }
    index($0, "thread=") == 1 { print substr($0, 8) }
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

# The same rule, per tracked thread: a thread span is applied only when it
# continues that thread's stored position, and is a no-op when already applied.
advance_thread_cursors() {  # <channel> <result-file>
  local channel=$1 file=$2 thread from to
  while IFS=' ' read -r thread from to _count; do
    [ -n "$thread" ] || continue
    valid_ts "$thread" || die "result carries an invalid thread reference"
    valid_ts "$from" || die "result carries an invalid thread start read position"
    valid_ts "$to" || die "result carries an invalid thread end read position"
    read_thread_cursor "$channel" "$thread" \
      || die "captured Slack thread replies name a thread this home does not track: $thread"
    [ "$THREAD_TS_READ" = "$to" ] && continue
    [ "$THREAD_TS_READ" = "$from" ] \
      || die "captured Slack thread replies do not continue the stored read position for thread $thread"
    write_cursor_file "$(thread_path "$channel" "$thread")" "$THREAD_SCHEMA" "$to" \
      || die "cannot commit the slack captain read position for thread $thread"
  done < <(result_threads "$file")
}

# Apply what carries no judgement - the read positions - and leave the result
# itself for firstmate. `<mark-handled>` is 1 only on the firstmate-facing
# `handle` path; see the header for why the runner's own call never acknowledges.
apply_result() {  # <source-id> <sequence> <result-file> <mark-handled>
  local sid=${1-} seq=${2-} file=${3-} mark=${4-} channel class
  case "$seq" in ''|*[!0-9]*) die "sequence must be a nonnegative integer" ;; esac
  [ -f "$file" ] && [ ! -L "$file" ] || die "result file is unavailable or unsafe: $file"
  channel=$(channel_from_source_id "$sid") || exit 1
  class=$(cmd_classify "$file")
  case "$class" in
    messages|untrusted-messages)
      advance_thread_cursors "$channel" "$file"
      advance_cursor "$channel" "$file"
      prune_threads "$channel"
      ;;
    api-error) ;;
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
  track-thread) shift; [ "$#" -eq 2 ] || usage; cmd_track_thread "$@" ;;
  # This source never ends: the captain can always post again, so the runner
  # must keep it armed no matter what a result contained.
  terminal)   shift; [ "$#" -eq 1 ] || usage; exit 1 ;;
  source-id)  shift; [ "$#" -eq 0 ] || usage; cmd_source_id ;;
  retire)     shift; [ "$#" -eq 0 ] || usage; cmd_retire ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
