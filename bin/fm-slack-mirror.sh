#!/usr/bin/env bash
# Mirror firstmate's final captain-facing message of each turn into the
# configured Slack captain channel, so Slack carries the same conversation the
# captain sees in the terminal instead of the subset firstmate remembered to
# post by hand.
#
# Usage:
#   fm-slack-mirror.sh stop                       Stop-hook entry, payload on stdin
#   fm-slack-mirror.sh note-post <channel>        record a deliberate outbound post
#   fm-slack-mirror.sh note-inbound <channel> <message-ts> [thread-ts]
#   fm-slack-mirror.sh deliver <channel> <body-file> [--thread <ts>] [--worker-details <d>]
#
# `deliver` is the detached delivery child `stop` starts; it is not a separate
# feature and removes the staging directory holding <body-file> when it returns.
#
# HARNESS SCOPE. `stop` needs a turn-end payload that names the transcript of
# the finished turn. Only the Claude primary integration delivers one, so this
# is registered as a third Claude `Stop` hook and every other primary harness is
# uncovered; docs/turnend-guard.md owns what each harness exposes at the turn
# boundary. A payload delivered by a foreign host that also loads Claude-shaped
# settings stands down through bin/fm-hook-host-lib.sh.
#
# NEVER A GATE. This hook is a courtesy channel. Every path exits 0, prints
# nothing to stdout, and returns before the network is touched: the decision is
# local file reads only, and the post itself is handed to a detached child
# unless FM_SLACK_MIRROR_SYNC=1. A missing token, a Slack outage, a malformed
# payload, an unreadable transcript, or a bug here therefore cannot block,
# delay, or fail the captain's turn, and cannot alter the exit status semantics
# of the turn-end guard or the watcher auto-arm, which are separate hook
# processes with their own stdin.
#
# OFF BY DEFAULT. A home with no `channel=` in config/slack-captain mirrors
# nothing, exactly like the rest of the Slack surface.
#
# WHAT IS MIRRORED. The final assistant text of the finished turn, taken from
# the transcript the payload names: not tool output, not thinking, not the
# intermediate narration of earlier assistant entries. Sidechain (subagent)
# entries are excluded, and the text must be newer than the turn's own opening
# captain message, so a turn that produced no reply of its own never re-posts an
# older one. The text is carried verbatim into the Slack request body by
# bin/fm-slack-post.sh, so URLs and markdown survive; only a body longer than
# `mirror_max_chars` is truncated, with a visible marker.
#
# SUPPRESSION. Supervising a fleet produces many pure-acknowledgement turns, and
# mirroring those verbatim would bury the captain. A reply is mirrored only when
# it is SUBSTANTIVE, which is a positive test rather than a blocklist of
# phrases: it spans more than one line, or is longer than `mirror_ack_max_chars`
# characters, or carries a link, a code span, a bullet or numbered item, or a
# `#<number>` reference. A single short prose line with none of those - the
# "Captain, shipshape." shape - is an acknowledgement and is not mirrored. On
# top of that, two consecutive identical bodies are never both sent.
#
# NO DOUBLE POST. When firstmate posts deliberately with bin/fm-slack-post.sh,
# that helper records the post here, and a turn whose own window already
# contains a deliberate post to the captain channel is not mirrored. The record
# is a durable timestamp compared against the turn's start, never a comparison
# of message text, so a deliberate post that says something different from the
# terminal reply still suppresses the mirror.
#
# THREAD CORRECTNESS. Slack does not render a channel message inside a thread
# view, so a reply to a captain message written in a thread must go back into
# that thread. bin/fm-procevent-slack-captain.sh records the routing target of
# the newest captured captain message here as it commits that capture, from the
# threads it already tracks rather than a parallel store. While that record is
# newer than `mirror_thread_window` seconds the mirror replies into the same
# thread through `bin/fm-slack-post.sh --thread`, which also keeps the thread
# registered for capture; otherwise it posts at the channel's top level.
#
# CONFIGURATION - additional optional keys in $FM_HOME/config/slack-captain:
#   mirror=on|off                 default on once `channel=` is set
#   mirror_ack_max_chars=<n>      default 120, the single-line acknowledgement bound
#   mirror_thread_window=<s>      default 900, how long an inbound thread binds replies
#   mirror_max_chars=<n>          default 3500, the length above which a body is truncated
#   mirror_worker_details=on|off  default off; see below
# Each has an `FM_SLACK_MIRROR_*` environment override for tests and specialized
# setups. `mirror_worker_details` is off by default because the standing
# `--worker-details` convention describes a completion or status post about a
# worker, and a mirrored line of firstmate's own conversation is neither; a home
# that wants every mirrored message stamped can turn it on.
#
# STATE, all under state/slack-captain/ beside the adapter's own cursors:
#   mirror.last-body      sha256 of the last mirrored body, for the repeat test
#   mirror.last-post      epoch of the last deliberate post to the captain channel
#   mirror.inbound        the newest captured captain message and its thread, if any
#
# TOKEN. This script never reads SLACK_BOT_TOKEN. Posting is delegated whole to
# bin/fm-slack-post.sh, which owns the token contract, so no secret reaches
# argv, a log line, or any state file written here.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
MIRROR_DIR="$STATE/slack-captain"
INBOUND_SCHEMA=fm-slack-mirror-inbound.v1

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-hook-host-lib.sh
. "$SCRIPT_DIR/fm-hook-host-lib.sh"

usage() { sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }

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

# One key from config/slack-captain, empty when absent or the file is unsafe.
config_get() {  # <key>
  local file="$CONFIG/slack-captain"
  [ -f "$file" ] && [ ! -L "$file" ] || return 0
  sed -n "s/^[[:space:]]*$1=//p" "$file" | tail -n1 | tr -d '[:space:]'
}

# A bounded setting: environment override, then configuration, then the default.
# Anything unusable falls back to the default rather than refusing, because this
# path must never become a reason a turn misbehaves.
setting_int() {  # <env-value> <config-key> <default>
  local value=${1-}
  [ -n "$value" ] || value=$(config_get "$2")
  case "$value" in
    ''|*[!0-9]*) value=$3 ;;
  esac
  printf '%s\n' "$value"
}

setting_flag() {  # <env-value> <config-key> <default-on-or-off>
  local value=${1-}
  [ -n "$value" ] || value=$(config_get "$2")
  case "$value" in
    on|1|true|yes) printf 'on\n' ;;
    off|0|false|no) printf 'off\n' ;;
    *) printf '%s\n' "$3" ;;
  esac
}

captain_channel() {
  local id
  id=$(config_get channel)
  valid_slack_id "$id" || return 1
  printf '%s\n' "$id"
}

state_write() {  # <path> <content>
  local dir tmp
  dir=$(dirname "$1")
  (umask 077; mkdir -p "$dir") || return 1
  [ ! -L "$1" ] || return 1
  tmp=$(umask 077; mktemp "$dir/.mirror.XXXXXX") || return 1
  printf '%s\n' "$2" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$1"
}

state_read() {  # <path>
  [ -f "$1" ] && [ ! -L "$1" ] || return 1
  head -n1 "$1"
}

now_epoch() { date +%s; }

# An ISO-8601 instant from the transcript, as epoch seconds. GNU and BSD date
# disagree on the flag, so both are tried and an unreadable value is a refusal.
iso_epoch() {  # <iso-8601>
  local value=${1-} plain out
  [ -n "$value" ] || return 1
  if out=$(date -u -d "$value" +%s 2>/dev/null) && [ -n "$out" ]; then
    printf '%s\n' "$out"
    return 0
  fi
  plain=${value%%.*}
  plain=${plain%Z}
  if out=$(date -u -j -f '%Y-%m-%dT%H:%M:%S' "$plain" +%s 2>/dev/null) && [ -n "$out" ]; then
    printf '%s\n' "$out"
    return 0
  fi
  return 1
}

body_digest() {  # <text>
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | cut -d' ' -f1
  else
    return 1
  fi
}

# The positive substantive test described in the header. A body that fails every
# limb is an acknowledgement.
is_substantive() {  # <text> <ack-max-chars>
  local text=${1-} limit=${2-} nl
  nl=$(printf 'x\nx')
  nl=${nl#x}
  nl=${nl%x}
  case "$text" in
    *"$nl"*) return 0 ;;
  esac
  [ "${#text}" -le "$limit" ] || return 0
  case "$text" in
    *http://*|*https://*|*'`'*) return 0 ;;
    *'#'[0-9]*) return 0 ;;
    '- '*|'* '*|[0-9]'. '*|[0-9][0-9]'. '*) return 0 ;;
  esac
  return 1
}

# --- recording ---------------------------------------------------------------

cmd_note_post() {  # <channel>
  local channel=${1-} watched
  valid_slack_id "$channel" || return 0
  watched=$(captain_channel) || return 0
  [ "$watched" = "$channel" ] || return 0
  state_write "$MIRROR_DIR/mirror.last-post" "$(now_epoch)" || return 0
}

cmd_note_inbound() {  # <channel> <message-ts> [thread-ts]
  local channel=${1-} msg=${2-} thread=${3-} watched
  valid_slack_id "$channel" || return 0
  valid_ts "$msg" || return 0
  [ -z "$thread" ] || valid_ts "$thread" || thread=
  watched=$(captain_channel) || return 0
  [ "$watched" = "$channel" ] || return 0
  state_write "$MIRROR_DIR/mirror.inbound" \
    "$(printf 'schema=%s epoch=%s ts=%s thread=%s' \
        "$INBOUND_SCHEMA" "$(now_epoch)" "$msg" "$thread")" || return 0
}

# --- stop hook ---------------------------------------------------------------

# The reply target for this turn: the thread of the newest captured captain
# message while that capture is still recent, or empty for the channel top
# level. Reads only the record the adapter writes as it commits a capture.
inbound_thread() {  # <window-seconds>
  local line schema epoch thread now
  line=$(state_read "$MIRROR_DIR/mirror.inbound") || return 0
  schema=${line#*schema=}; schema=${schema%% *}
  [ "$schema" = "$INBOUND_SCHEMA" ] || return 0
  epoch=${line#*epoch=}; epoch=${epoch%% *}
  thread=${line#*thread=}; thread=${thread%% *}
  case "$epoch" in ''|*[!0-9]*) return 0 ;; esac
  valid_ts "$thread" || return 0
  now=$(now_epoch)
  [ "$((now - epoch))" -le "$1" ] || return 0
  printf '%s\n' "$thread"
}

# The final assistant text of the finished turn. Sets FINAL_TEXT, FINAL_TS,
# FINAL_MODEL, FINAL_EFFORT, and TURN_TS from the reversed transcript in $1.
read_final_message() {  # <reversed-transcript>
  local meta
  FINAL_TEXT=; FINAL_TS=; FINAL_MODEL=; FINAL_EFFORT=; TURN_TS=
  TURN_TS=$(jq -r --slurp '
      map(select(.type == "user" and (.isSidechain != true)))
      | map(select(
          (.message.content | type) == "string"
          or ((.message.content | type) == "array"
              and (.message.content | any(.type == "text")))
        ))
      | (.[0].timestamp // "")
    ' "$1" 2>/dev/null) || return 1
  meta=$(jq -r --slurp '
      map(select(.type == "assistant" and (.isSidechain != true)))
      | map(select(((.message.content // []) | type) == "array"))
      | map(select((.message.content | map(select(.type == "text") | .text // "")
                    | join("")) != ""))
      | (.[0] // empty)
      | "\(.timestamp // "") \(.message.model // "") \(.effort // "")"
    ' "$1" 2>/dev/null) || return 1
  [ -n "$meta" ] || return 1
  read -r FINAL_TS FINAL_MODEL FINAL_EFFORT <<EOF
$meta
EOF
  FINAL_TEXT=$(jq -r --slurp '
      map(select(.type == "assistant" and (.isSidechain != true)))
      | map(select(((.message.content // []) | type) == "array"))
      | map(select((.message.content | map(select(.type == "text") | .text // "")
                    | join("")) != ""))
      | (.[0] // empty)
      | (.message.content | map(select(.type == "text") | .text // "") | join("\n"))
    ' "$1" 2>/dev/null) || return 1
  [ -n "$FINAL_TEXT" ] || return 1
  return 0
}

cmd_stop() {
  local payload transcript reversed tmpdir channel enabled
  local ack_max window max_chars details_flag
  local body turn_epoch post_epoch digest last_digest thread details

  payload=$(cat 2>/dev/null) || return 0
  [ -n "$payload" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  # A foreign host that also loads Claude-shaped settings has its own coverage.
  ! fm_hook_payload_is_foreign_host "$payload" || return 0

  fm_primary_scope_matches "$FM_ROOT" "$STATE" || return 0
  channel=$(captain_channel) || return 0
  enabled=$(setting_flag "${FM_SLACK_MIRROR-}" mirror on)
  [ "$enabled" = on ] || return 0

  transcript=$(printf '%s' "$payload" | jq -r '.transcript_path // ""' 2>/dev/null) || return 0
  [ -n "$transcript" ] && [ -f "$transcript" ] && [ ! -L "$transcript" ] || return 0

  tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/fm-slack-mirror.XXXXXX" 2>/dev/null) || return 0
  reversed="$tmpdir/reversed.jsonl"
  # Newest first, so each read stops at the first match instead of walking the
  # whole session.
  if ! tail -n "${FM_SLACK_MIRROR_SCAN_LINES:-400}" "$transcript" 2>/dev/null \
      | tac > "$reversed" 2>/dev/null; then
    rm -rf -- "$tmpdir"
    return 0
  fi
  if ! read_final_message "$reversed"; then
    rm -rf -- "$tmpdir"
    return 0
  fi
  rm -rf -- "$tmpdir"
  body=$FINAL_TEXT

  # A turn that ended without a reply of its own must never re-post an older
  # one. ISO-8601 UTC instants compare correctly as strings.
  [ -z "$TURN_TS" ] || [ "$FINAL_TS" ">" "$TURN_TS" ] || return 0

  ack_max=$(setting_int "${FM_SLACK_MIRROR_ACK_MAX_CHARS-}" mirror_ack_max_chars 120)
  window=$(setting_int "${FM_SLACK_MIRROR_THREAD_WINDOW-}" mirror_thread_window 900)
  max_chars=$(setting_int "${FM_SLACK_MIRROR_MAX_CHARS-}" mirror_max_chars 3500)
  details_flag=$(setting_flag "${FM_SLACK_MIRROR_WORKER_DETAILS-}" mirror_worker_details off)

  is_substantive "$body" "$ack_max" || return 0

  # A deliberate post inside this turn's own window is the message; mirroring it
  # again would double-post.
  post_epoch=$(state_read "$MIRROR_DIR/mirror.last-post" 2>/dev/null || true)
  case "$post_epoch" in
    ''|*[!0-9]*) ;;
    *)
      turn_epoch=$(iso_epoch "$TURN_TS" 2>/dev/null || true)
      case "$turn_epoch" in
        ''|*[!0-9]*) ;;
        *) [ "$post_epoch" -lt "$turn_epoch" ] || return 0 ;;
      esac
      ;;
  esac

  if [ "${#body}" -gt "$max_chars" ]; then
    body=$(printf '%s\n\n_[truncated by the terminal mirror]_' "${body:0:$max_chars}")
  fi

  digest=$(body_digest "$body") || return 0
  last_digest=$(state_read "$MIRROR_DIR/mirror.last-body" 2>/dev/null || true)
  [ "$digest" != "$last_digest" ] || return 0

  thread=$(inbound_thread "$window")

  details=
  if [ "$details_flag" = on ] && [ -n "$FINAL_MODEL" ]; then
    details=$FINAL_MODEL
    [ -z "$FINAL_EFFORT" ] || details="$FINAL_MODEL $FINAL_EFFORT"
  fi

  # Recorded before the post is attempted: the repeat test is a courtesy, and a
  # failure this hook deliberately never learns about must not leave the next
  # identical turn eligible to retry into a channel that may already have it.
  state_write "$MIRROR_DIR/mirror.last-body" "$digest" || return 0

  send "$channel" "$body" "$thread" "$details"
  return 0
}

# Stage the body and hand it to the delivery child. Detached by default, so the
# turn ends without waiting for Slack at all; FM_SLACK_MIRROR_SYNC=1 delivers
# inline for tests.
send() {  # <channel> <body> <thread-or-empty> <details-or-empty>
  local channel=$1 body=$2 thread=$3 details=$4 dir file args
  dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-slack-mirror-send.XXXXXX" 2>/dev/null) || return 0
  file="$dir/body.txt"
  printf '%s\n' "$body" > "$file" 2>/dev/null || { rm -rf -- "$dir"; return 0; }

  args=( "$SCRIPT_DIR/fm-slack-mirror.sh" deliver "$channel" "$file" )
  [ -z "$thread" ] || args+=( --thread "$thread" )
  [ -z "$details" ] || args+=( --worker-details "$details" )

  if [ "${FM_SLACK_MIRROR_SYNC-}" = 1 ]; then
    "${args[@]}" >/dev/null 2>&1 || true
    return 0
  fi
  # setsid puts delivery in its own session, so Claude reaping this hook's
  # process group cannot truncate a post already in flight, and nothing here
  # waits on it.
  if command -v setsid >/dev/null 2>&1; then
    setsid "${args[@]}" </dev/null >/dev/null 2>&1 &
  else
    "${args[@]}" </dev/null >/dev/null 2>&1 &
  fi
  disown 2>/dev/null || true
  return 0
}

# The delivery child. `--origin mirror` is what keeps this post out of the
# deliberate-post record, so the mirror can never suppress itself next turn.
cmd_deliver() {  # <channel> <body-file> [--thread <ts>] [--worker-details <d>]
  local channel=${1-} file=${2-} dir
  shift 2 2>/dev/null || return 0
  [ -n "$channel" ] && [ -f "$file" ] && [ ! -L "$file" ] || return 0
  dir=$(dirname "$file")
  "$SCRIPT_DIR/fm-slack-post.sh" "$channel" --file "$file" --origin mirror "$@" \
    >/dev/null 2>&1 || true
  case "$dir" in
    */fm-slack-mirror-send.*) rm -rf -- "$dir" ;;
  esac
  return 0
}

case "${1-}" in
  stop)         shift; [ "$#" -eq 0 ] || usage; cmd_stop ;;
  note-post)    shift; [ "$#" -eq 1 ] || usage; cmd_note_post "$@" ;;
  note-inbound) shift; [ "$#" -ge 2 ] && [ "$#" -le 3 ] || usage; cmd_note_inbound "$@" ;;
  deliver)      shift; [ "$#" -ge 2 ] || usage; cmd_deliver "$@" ;;
  ''|-h|--help|help) usage ;;
  *) usage ;;
esac
exit 0
