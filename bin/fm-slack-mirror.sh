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
#   fm-slack-mirror.sh note-trigger <channel> <source-id> <sequence> <thread-ts|none>
#   fm-slack-mirror.sh note-reply-target <channel> <thread-ts|none>
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
# WHAT IS MIRRORED. The final assistant text of the finished turn: not tool
# output, not thinking, not the intermediate narration of earlier assistant
# entries. The payload's own `last_assistant_message` is preferred because it
# describes the turn that just ended and cannot race the transcript write, which
# is not guaranteed to have flushed the final entry by the time Stop fires. When
# a payload omits it, the transcript named by the payload is read instead:
# sidechain (subagent) entries are excluded, and the text must be newer than the
# turn's own opening captain message, so a turn that produced no reply of its
# own never re-posts an older one. The text is carried verbatim into the Slack
# request body by bin/fm-slack-post.sh, so URLs and markdown survive; only a
# body longer than `mirror_max_chars` is truncated, with a visible marker.
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
# that thread. The target is resolved in three layers, highest precedence first:
#
#   1. EXPLICIT OVERRIDE. Firstmate may record the thread it is answering with
#      `note-reply-target` before the turn ends; a fresh record wins over
#      everything below, binds exactly one turn (consumed on read), and a
#      recorded `none` forces the channel top level. It exists for a substantive
#      reply whose own turn is not opened by the triggering wake, so auto-detect
#      cannot see it.
#
#   2. AUTO-DETECT from the turn's trigger. A captain Slack message reaches
#      firstmate as a watcher wake naming the exact captured result
#      (`procevent:slack-captain-<channel>:<sequence>`), so with no explicit
#      record `stop` reads the turn's own opening message from the transcript and,
#      when it names such a capture, files the reply into the thread that capture
#      recorded. bin/fm-procevent-slack-captain.sh records that thread PER CAPTURE
#      as it commits, keyed by the same source id and sequence the wake carries
#      (`note-trigger`), so the routing binds to the message that actually opened
#      the turn rather than to whichever inbound was captured most recently. This
#      is what keeps interleaved captain messages - a reply to one thread while a
#      fresh message lands in another - from ever filing a reply into the wrong
#      thread, with no manual `note-reply-target` step. A turn whose trigger is
#      readable but names no such capture is NOT a Slack turn (a crew wake, a
#      terminal-typed line, an operational injection): it posts at the channel top
#      level and never guesses a thread.
#
#   3. NEWEST-INBOUND FALLBACK, last resort only. When the trigger cannot be read
#      at all - a payload-only turn whose transcript never named an opening
#      message - `stop` falls back to the older guess: the adapter records the
#      routing target of the newest captured captain message (`note-inbound`), and
#      while that record is newer than `mirror_thread_window` seconds the mirror
#      replies into that thread.
#
# Either way delivery goes through `bin/fm-slack-post.sh --thread`, which also
# keeps the thread registered for capture; otherwise it posts at the channel's
# top level. Every recorded target must be fresh within `mirror_thread_window`,
# which a normal turn always is; the bound only discards a target orphaned by a
# hung or crashed turn.
#
# HARNESS SCOPE OF AUTO-DETECT. Reading the turn's opening trigger from the
# transcript is a Claude-specific surface, exactly like the mirror itself;
# docs/turnend-guard.md owns what each harness exposes at the turn boundary. The
# correlation core - a captured sequence mapped to its thread - is
# harness-agnostic: a future harness extension supplies its own way to name the
# turn's trigger and reuses the same `note-trigger` store unchanged.
#
# CONFIGURATION - additional optional keys in $FM_HOME/config/slack-captain:
#   mirror=on|off                 default on once `channel=` is set
#   mirror_ack_max_chars=<n>      default 120, the single-line acknowledgement bound
#   mirror_thread_window=<s>      default 900, how long an inbound thread binds replies
#   mirror_turn_window=<s>        default 900, the assumed turn length when the
#                                 transcript cannot date this turn's start
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
#   mirror.reply-target   the thread firstmate recorded for this turn's reply,
#                         consumed by `stop`; a deterministic override of inbound
#   mirror.correlate      a bounded newest-first log mapping each captured result
#                         (source id and sequence) to its reply thread, so `stop`
#                         can route by the wake that opened the turn
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
REPLY_TARGET_SCHEMA=fm-slack-mirror-reply-target.v1
CORRELATE_SCHEMA=fm-slack-mirror-correlate.v1
# The bounded number of recent captures the correlation log retains. A capture
# maps one wake to one thread, so this only has to cover the captures whose reply
# turn might still be in flight; older entries are dropped newest-first.
CORRELATE_MAX=${FM_SLACK_MIRROR_CORRELATE_MAX:-128}

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-hook-host-lib.sh
. "$SCRIPT_DIR/fm-hook-host-lib.sh"

usage() { sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }

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

# A source id as the process-event runner names it: an opaque, path-safe token.
# Validated for charset only, never reconstructed here, so this recorder never
# owns bin/fm-procevent-slack-captain.sh's `slack-captain-<channel>` format.
valid_source_id() {
  case "${1-}" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  [ "${#1}" -le 64 ]
}

# Prepend one newest-first correlation line and keep only the newest CORRELATE_MAX,
# so the log stays bounded whatever the capture rate. Fail-soft: a write problem
# never disrupts the capture that triggered it.
correlate_write() {  # <source-id> <sequence> <thread-or-empty>
  local path line existing dir tmp
  path="$MIRROR_DIR/mirror.correlate"
  line=$(printf 'schema=%s epoch=%s source=%s seq=%s thread=%s' \
    "$CORRELATE_SCHEMA" "$(now_epoch)" "$1" "$2" "$3")
  dir=$(dirname "$path")
  (umask 077; mkdir -p "$dir") || return 1
  [ ! -L "$path" ] || return 1
  existing=
  [ ! -f "$path" ] || existing=$(head -n "$((CORRELATE_MAX - 1))" "$path" 2>/dev/null || true)
  tmp=$(umask 077; mktemp "$dir/.correlate.XXXXXX") || return 1
  {
    printf '%s\n' "$line"
    [ -z "$existing" ] || printf '%s\n' "$existing"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$path"
}

# Record where a reply to one captured result belongs, keyed by the source id and
# sequence the wake for that result carries, so `stop` can route the mirror by the
# message that actually opened the turn. `none` (or empty) binds the channel top
# level. Fail-soft like the other recorders: it must never disrupt a capture.
cmd_note_trigger() {  # <channel> <source-id> <sequence> <thread-ts-or-none>
  local channel=${1-} source=${2-} seq=${3-} thread=${4-} watched
  valid_slack_id "$channel" || return 0
  valid_source_id "$source" || return 0
  case "$seq" in ''|*[!0-9]*) return 0 ;; esac
  watched=$(captain_channel) || return 0
  [ "$watched" = "$channel" ] || return 0
  case "$thread" in
    none|top|'') thread= ;;
    *) valid_ts "$thread" || return 0 ;;
  esac
  correlate_write "$source" "$seq" "$thread" || return 0
}

# The thread firstmate is answering this turn, recorded before the turn ends so
# `stop` can route the mirror deterministically instead of guessing from the
# newest captured inbound. A valid ts targets that thread; `none` (or empty)
# forces the channel top level. An invalid ts is reported but writes no record,
# so `stop` falls back rather than silently forcing the top level. Fail-soft like
# the other recorders: it must never disrupt firstmate's turn.
cmd_note_reply_target() {  # <channel> <thread-ts-or-none>
  local channel=${1-} thread=${2-} watched
  valid_slack_id "$channel" || return 0
  watched=$(captain_channel) || return 0
  [ "$watched" = "$channel" ] || return 0
  case "$thread" in
    none|top|'') thread= ;;
    *) valid_ts "$thread" || {
         printf 'fm-slack-mirror: invalid thread timestamp for note-reply-target: %s\n' \
           "$thread" >&2
         return 0
       } ;;
  esac
  state_write "$MIRROR_DIR/mirror.reply-target" \
    "$(printf 'schema=%s epoch=%s thread=%s' \
        "$REPLY_TARGET_SCHEMA" "$(now_epoch)" "$thread")" || return 0
}

# --- stop hook ---------------------------------------------------------------

# The thread firstmate explicitly recorded for this turn's reply, CONSUMED on
# read so it binds to exactly one turn end and cannot misroute a later turn. Sets
# REPLY_TARGET_SET=1 and REPLY_TARGET_THREAD (empty means the channel top level)
# when a fresh, well-formed record existed; the record is removed either way.
# Returns nonzero when there was no usable record, so `stop` falls back to the
# newest-inbound guess. A record older than the window is an orphan from a hung
# turn and is discarded, not applied.
reply_target_consume() {  # <window-seconds>
  local path line schema epoch thread now
  path="$MIRROR_DIR/mirror.reply-target"
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  line=$(head -n1 "$path")
  rm -f -- "$path"
  schema=${line#*schema=}; schema=${schema%% *}
  [ "$schema" = "$REPLY_TARGET_SCHEMA" ] || return 1
  epoch=${line#*epoch=}; epoch=${epoch%% *}
  case "$epoch" in ''|*[!0-9]*) return 1 ;; esac
  now=$(now_epoch)
  [ "$((now - epoch))" -le "$1" ] || return 1
  thread=${line#*thread=}; thread=${thread%% *}
  [ -z "$thread" ] || valid_ts "$thread" || return 1
  REPLY_TARGET_SET=1
  REPLY_TARGET_THREAD=$thread
  return 0
}

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

# The AUTO-DETECT layer: resolve this turn's reply thread from the message that
# opened it. Sets TRIGGER_MODE and TRIGGER_THREAD:
#   thread   - the trigger names a captured Slack result; TRIGGER_THREAD is that
#              capture's recorded thread (empty means the channel top level).
#   toplevel - the trigger is readable but names no captured result, so this is
#              not a Slack turn; post at the top level and never guess a thread.
#   fallback - the trigger could not be read at all, so `stop` falls back to the
#              newest-inbound guess.
# The correlation log is scanned newest-first, so a turn whose trigger names more
# than one capture routes to the most recent. A stored source id and sequence are
# matched against the trigger text as a bounded reference; the recorded thread is
# never itself compiled into the match, so captured text can forge nothing here.
resolve_trigger() {
  local path line source seq thread re
  TRIGGER_MODE=fallback
  TRIGGER_THREAD=
  [ -n "${TURN_TEXT-}" ] || return 0
  TRIGGER_MODE=toplevel
  path="$MIRROR_DIR/mirror.correlate"
  [ -f "$path" ] && [ ! -L "$path" ] || return 0
  while IFS= read -r line; do
    case "$line" in "schema=$CORRELATE_SCHEMA "*) ;; *) continue ;; esac
    source=${line#*source=}; source=${source%% *}
    seq=${line#*seq=}; seq=${seq%% *}
    valid_source_id "$source" || continue
    case "$seq" in ''|*[!0-9]*) continue ;; esac
    re="(^|[^0-9A-Za-z])${source}[: ]${seq}([^0-9]|$)"
    if [[ $TURN_TEXT =~ $re ]]; then
      thread=${line#*thread=}; thread=${thread%% *}
      [ -z "$thread" ] || valid_ts "$thread" || continue
      TRIGGER_MODE=thread
      TRIGGER_THREAD=$thread
      return 0
    fi
  done < "$path"
  return 0
}

# The final assistant text of the finished turn. Sets FINAL_TEXT, FINAL_TS,
# FINAL_MODEL, FINAL_EFFORT, TURN_TS, and TURN_TEXT from the reversed transcript
# in $1. TURN_TS and TURN_TEXT describe the same message - the turn's newest
# opening user entry that carries text - and are set before any early return, so
# the trigger stays readable even when the turn produced no assistant text.
read_final_message() {  # <reversed-transcript>
  local meta
  FINAL_TEXT=; FINAL_TS=; FINAL_MODEL=; FINAL_EFFORT=; TURN_TS=; TURN_TEXT=
  TURN_TS=$(jq -r --slurp '
      map(select(.type == "user" and (.isSidechain != true)))
      | map(select(
          (.message.content | type) == "string"
          or ((.message.content | type) == "array"
              and (.message.content | any(.type == "text")))
        ))
      | (.[0].timestamp // "")
    ' "$1" 2>/dev/null) || return 1
  TURN_TEXT=$(jq -r --slurp '
      map(select(.type == "user" and (.isSidechain != true)))
      | map(select(
          (.message.content | type) == "string"
          or ((.message.content | type) == "array"
              and (.message.content | any(.type == "text")))
        ))
      | (.[0] // empty)
      | (if (.message.content | type) == "string" then .message.content
         else (.message.content | map(select(.type == "text") | .text // "") | join("\n")) end)
    ' "$1" 2>/dev/null) || TURN_TEXT=
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
  local payload payload_text transcript reversed tmpdir channel enabled
  local ack_max window max_chars details_flag
  local body turn_epoch post_epoch digest last_digest thread details
  local REPLY_TARGET_SET=0 REPLY_TARGET_THREAD=
  local TURN_TEXT='' TRIGGER_MODE=fallback TRIGGER_THREAD=''

  payload=$(cat 2>/dev/null) || return 0
  [ -n "$payload" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  # A foreign host that also loads Claude-shaped settings has its own coverage.
  ! fm_hook_payload_is_foreign_host "$payload" || return 0

  fm_primary_scope_matches "$FM_ROOT" "$STATE" || return 0
  channel=$(captain_channel) || return 0
  enabled=$(setting_flag "${FM_SLACK_MIRROR-}" mirror on)
  [ "$enabled" = on ] || return 0

  # Consumed unconditionally at turn end so a recorded target binds to exactly
  # this turn, whatever this turn ends up mirroring. Read before the substantive
  # and duplicate checks below, which return early on many turns.
  window=$(setting_int "${FM_SLACK_MIRROR_THREAD_WINDOW-}" mirror_thread_window 900)
  reply_target_consume "$window" || true

  FINAL_TEXT=; FINAL_TS=; FINAL_MODEL=; FINAL_EFFORT=; TURN_TS=; TURN_TEXT=
  transcript=$(printf '%s' "$payload" | jq -r '.transcript_path // ""' 2>/dev/null) || return 0
  if [ -n "$transcript" ] && [ -f "$transcript" ] && [ ! -L "$transcript" ]; then
    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/fm-slack-mirror.XXXXXX" 2>/dev/null) || return 0
    reversed="$tmpdir/reversed.jsonl"
    # Newest first, so each read stops at the first match instead of walking the
    # whole session.
    if tail -n "${FM_SLACK_MIRROR_SCAN_LINES:-400}" "$transcript" 2>/dev/null \
        | tac > "$reversed" 2>/dev/null; then
      read_final_message "$reversed" || true
    fi
    rm -rf -- "$tmpdir"
  fi

  # The payload's own account of the turn that just ended wins over the
  # transcript, which Stop can outrun.
  payload_text=$(printf '%s' "$payload" | jq -r '
      if (.last_assistant_message | type) == "string" then .last_assistant_message else "" end
    ' 2>/dev/null) || payload_text=
  if [ -n "$payload_text" ]; then
    body=$payload_text
    FINAL_EFFORT=$(printf '%s' "$payload" | jq -r '
        if (.effort.level | type) == "string" then .effort.level else "" end
      ' 2>/dev/null) || FINAL_EFFORT=
  else
    [ -n "$FINAL_TEXT" ] || return 0
    body=$FINAL_TEXT
    # A turn that ended without a reply of its own must never re-post an older
    # one. ISO-8601 UTC instants compare correctly as strings.
    [ -z "$TURN_TS" ] || [ "$FINAL_TS" ">" "$TURN_TS" ] || return 0
  fi

  ack_max=$(setting_int "${FM_SLACK_MIRROR_ACK_MAX_CHARS-}" mirror_ack_max_chars 120)
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
        ''|*[!0-9]*)
          # No dated turn start, so fall back to an assumed turn length rather
          # than losing the duplicate test entirely.
          turn_epoch=$(( $(now_epoch) - $(setting_int "${FM_SLACK_MIRROR_TURN_WINDOW-}" \
            mirror_turn_window 900) ))
          ;;
      esac
      [ "$post_epoch" -lt "$turn_epoch" ] || return 0
      ;;
  esac

  if [ "${#body}" -gt "$max_chars" ]; then
    body=$(printf '%s\n\n_[truncated by the terminal mirror]_' "${body:0:$max_chars}")
  fi

  digest=$(body_digest "$body") || return 0
  last_digest=$(state_read "$MIRROR_DIR/mirror.last-body" 2>/dev/null || true)
  [ "$digest" != "$last_digest" ] || return 0

  # Precedence: the explicit record firstmate wrote for this turn wins; else
  # auto-detect from the message that opened the turn; else, only when the trigger
  # could not be read at all, the newest-inbound guess. A readable non-Slack
  # trigger posts at the top level rather than guessing a thread.
  if [ "$REPLY_TARGET_SET" = 1 ]; then
    thread=$REPLY_TARGET_THREAD
  else
    resolve_trigger
    case "$TRIGGER_MODE" in
      thread)   thread=$TRIGGER_THREAD ;;
      toplevel) thread= ;;
      *)        thread=$(inbound_thread "$window") ;;
    esac
  fi

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
  note-trigger) shift; [ "$#" -eq 4 ] || usage; cmd_note_trigger "$@" ;;
  note-reply-target) shift; [ "$#" -eq 2 ] || usage; cmd_note_reply_target "$@" ;;
  deliver)      shift; [ "$#" -ge 2 ] || usage; cmd_deliver "$@" ;;
  ''|-h|--help|help) usage ;;
  *) usage ;;
esac
exit 0
