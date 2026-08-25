#!/usr/bin/env bash
# Mirror a coding agent's final human-facing message of each turn into a Slack
# channel, so Slack carries the same conversation the human sees in the terminal
# instead of the subset the agent remembered to post by hand.
#
# This directory is the whole tool and is deliberately self-contained: the core
# below owns everything that is not harness-specific, adapters/ owns the
# per-harness turn-end payload shapes, and the host agent supplies its own
# policy and its own Slack poster through the environment contract below. It is
# shaped to be lifted into its own repository unchanged.
#
# Usage:
#   slack-mirror.sh turn-end [--harness <name>]   turn-end entry, payload on stdin
#   slack-mirror.sh note-post <channel>           record a deliberate outbound post
#   slack-mirror.sh note-inbound <channel> <message-ts> [thread-ts]
#   slack-mirror.sh note-trigger <channel> <source-id> <sequence> <thread-ts|none>
#   slack-mirror.sh note-reply-target <channel> <thread-ts|none>
#   slack-mirror.sh deliver <channel> <body-file> [--thread <ts>] [--worker-details <d>]
#   slack-mirror.sh adapters                      print the harness coverage table
#
# `deliver` is the detached delivery child `turn-end` starts; it is not a
# separate feature and removes the staging directory holding <body-file> when it
# returns.
#
# ENVIRONMENT CONTRACT - the host agent supplies these; nothing here reads a
# host's own layout or configuration files by name:
#   SLACK_MIRROR_STATE_DIR    required for every command; the directory holding
#                             this tool's own records (see STATE below)
#   SLACK_MIRROR_CONFIG_FILE  required; the `key=value` file holding `channel=`
#                             and the optional `mirror*` keys below
#   SLACK_MIRROR_POST_CMD     required for delivery; an executable invoked as
#                             `<cmd> <channel> --file <path> --origin mirror
#                             [--thread <ts>] [--worker-details <d>]`. It owns
#                             the Slack token contract entirely, so no secret
#                             reaches this tool's argv, a log line, or a record
#                             written here.
#   SLACK_MIRROR_HARNESS      optional; pins the adapter instead of asking each
#                             adapter whether it claims the payload
#
# NEVER A GATE. This is a courtesy channel. Every path exits 0, prints nothing
# to stdout, and returns before the network is touched: the decision is local
# file reads only, and the post itself is handed to a detached child unless
# SLACK_MIRROR_SYNC=1. A missing token, a Slack outage, a malformed payload, an
# unreadable transcript, or a bug here therefore cannot block, delay, or fail
# the agent's turn, and cannot alter the exit status of any other hook the host
# registers on the same turn boundary.
#
# OFF BY DEFAULT. With no `channel=` in the configuration file, nothing is
# mirrored at all.
#
# WHAT IS MIRRORED. The final assistant text of the finished turn: not tool
# output, not thinking, not the intermediate narration of earlier assistant
# entries. The selected adapter owns that extraction for its harness and returns
# it as text; the text is carried verbatim into the Slack request body by
# SLACK_MIRROR_POST_CMD, so URLs and markdown survive, and only a body longer
# than `mirror_max_chars` is truncated with a visible marker.
#
# SUPPRESSION. Supervising a fleet produces many pure-acknowledgement turns, and
# mirroring those verbatim would bury the reader. A reply is mirrored only when
# it is SUBSTANTIVE, which is a positive test rather than a blocklist of
# phrases: it spans more than one line, or is longer than `mirror_ack_max_chars`
# characters, or carries a link, a code span, a bullet or numbered item, or a
# `#<number>` reference. A single short prose line with none of those is an
# acknowledgement and is not mirrored. On top of that, two consecutive identical
# bodies are never both sent.
#
# NO DOUBLE POST. When the host posts deliberately, it records that here with
# `note-post`, and a turn whose own window already contains a deliberate post to
# the mirrored channel is not mirrored. The record is a durable timestamp
# compared against the turn's start, never a comparison of message text, so a
# deliberate post that says something different from the terminal reply still
# suppresses the mirror.
#
# THREAD CORRECTNESS. Slack does not render a channel message inside a thread
# view, so a reply to a message written in a thread must go back into that
# thread. The target is resolved in three layers, highest precedence first:
#
#   1. EXPLICIT OVERRIDE. The host may record the thread it is answering with
#      `note-reply-target` before the turn ends; a fresh record wins over
#      everything below, binds exactly one turn (consumed on read), and a
#      recorded `none` forces the channel top level. It exists for a substantive
#      reply whose own turn is not opened by the triggering event, so
#      auto-detect cannot see it.
#
#   2. AUTO-DETECT from the turn's trigger. When an inbound Slack message
#      reaches the agent as an event naming the exact captured result, the host
#      records that capture's thread with `note-trigger`, keyed by the same
#      source id and sequence the event carries. The adapter returns the text
#      that opened the turn, and when that text names such a capture the reply
#      is filed into the thread that capture recorded. This binds the routing to
#      the message that actually opened the turn rather than to whichever inbound
#      arrived most recently, so interleaved inbound messages - a reply to one
#      thread while a fresh message lands in another - never misfile. A turn
#      whose trigger is readable but names no such capture is not a Slack turn:
#      it posts at the channel top level and never guesses a thread.
#
#   3. NEWEST-INBOUND FALLBACK, last resort only. When the adapter cannot read
#      the trigger at all, the mirror falls back to the older guess: the host
#      records the routing target of the newest captured message
#      (`note-inbound`), and while that record is newer than
#      `mirror_thread_window` seconds the mirror replies into that thread.
#
# Every recorded target must be fresh within `mirror_thread_window`, which a
# normal turn always is; the bound only discards a target orphaned by a hung or
# crashed turn.
#
# HARNESS COVERAGE. `slack-mirror.sh adapters` prints the current table: one
# line per implemented adapter, which adapters/ owns, then the uncovered
# harnesses below. A harness whose turn boundary exposes no payload naming the
# finished turn's own final message cannot be mirrored, and is recorded as a gap
# here rather than given an adapter that guesses at one:
#
#   codex      A Stop payload of the same Claude-shaped snake_case kind exists
#              (`stop.command.input` in codex-cli 0.149.0 carries
#              `last_assistant_message` and `transcript_path`), so
#              adapters/claude.sh already reads it, but no host registers it yet
#              and it has not been proven end to end against a running Codex,
#              whose project hooks need per-hook trust before they load.
#   cursor     Its `stop` step is claimed by the host's own turn-boundary park
#              and its payload has not been shown to carry the finished turn's
#              final assistant message.
#   opencode   `session.idle` is a passive SDK callback with no payload naming
#   pi         the finished turn's own final message; the same is true of Pi's
#   pi-signed  `agent_settled`. Mirroring these needs an SDK-side extension that
#              supplies the text, not a shell adapter.
#   kimi       Its Stop payload carries only `hook_event_name`, `session_id`,
#              `cwd`, and `stop_hook_active`, so the reply is simply not there.
#
# CONFIGURATION - optional keys in SLACK_MIRROR_CONFIG_FILE beside `channel=`:
#   mirror=on|off                 default on once `channel=` is set
#   mirror_ack_max_chars=<n>      default 120, the single-line acknowledgement bound
#   mirror_thread_window=<s>      default 900, how long an inbound thread binds replies
#   mirror_turn_window=<s>        default 900, the assumed turn length when the
#                                 adapter cannot date this turn's start
#   mirror_max_chars=<n>          default 3500, the length above which a body is truncated
#   mirror_worker_details=on|off  default off; when on, each mirrored message is
#                                 stamped with the model and effort the adapter
#                                 reported, through SLACK_MIRROR_POST_CMD's own
#                                 `--worker-details` convention
# Each has a `SLACK_MIRROR_*` environment override for tests and specialized
# setups, and each of those also accepts the legacy `FM_SLACK_MIRROR_*` spelling
# for hosts that set it: SLACK_MIRROR (the on/off switch), _ACK_MAX_CHARS,
# _THREAD_WINDOW, _TURN_WINDOW, _MAX_CHARS, _WORKER_DETAILS, _CORRELATE_MAX,
# _SYNC.
#
# STATE, all under SLACK_MIRROR_STATE_DIR:
#   mirror.last-body      sha256 of the last mirrored body, for the repeat test
#   mirror.last-post      epoch of the last deliberate post to the channel
#   mirror.inbound        the newest captured inbound message and its thread, if any
#   mirror.reply-target   the thread the host recorded for this turn's reply,
#                         consumed by `turn-end`; a deterministic override of inbound
#   mirror.correlate      a bounded newest-first log mapping each captured result
#                         (source id and sequence) to its reply thread, so
#                         `turn-end` can route by the event that opened the turn
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADAPTER_DIR="$SCRIPT_DIR/adapters"
MIRROR_DIR="${SLACK_MIRROR_STATE_DIR:-}"
CONFIG_FILE="${SLACK_MIRROR_CONFIG_FILE:-}"
POST_CMD="${SLACK_MIRROR_POST_CMD:-}"
INBOUND_SCHEMA=fm-slack-mirror-inbound.v1
REPLY_TARGET_SCHEMA=fm-slack-mirror-reply-target.v1
CORRELATE_SCHEMA=fm-slack-mirror-correlate.v1

usage() { sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }

# An environment override under either spelling: the tool's own name first, then
# the legacy host-prefixed one, so a host that already exports the old name keeps
# working after extraction.
env_override() {  # <suffix-or-empty>
  local suffix=${1-} own legacy
  if [ -z "$suffix" ]; then
    own=SLACK_MIRROR; legacy=FM_SLACK_MIRROR
  else
    own="SLACK_MIRROR$suffix"; legacy="FM_SLACK_MIRROR$suffix"
  fi
  if [ -n "${!own-}" ]; then
    printf '%s\n' "${!own}"
  else
    printf '%s\n' "${!legacy-}"
  fi
}

# The bounded number of recent captures the correlation log retains. A capture
# maps one event to one thread, so this only has to cover the captures whose
# reply turn might still be in flight; older entries are dropped newest-first.
CORRELATE_MAX=$(env_override _CORRELATE_MAX)
case "$CORRELATE_MAX" in
  ''|*[!0-9]*) CORRELATE_MAX=128 ;;
esac

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

# One key from the host's configuration file, empty when absent or unsafe.
config_get() {  # <key>
  [ -n "$CONFIG_FILE" ] || return 0
  [ -f "$CONFIG_FILE" ] && [ ! -L "$CONFIG_FILE" ] || return 0
  sed -n "s/^[[:space:]]*$1=//p" "$CONFIG_FILE" | tail -n1 | tr -d '[:space:]'
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

mirrored_channel() {
  local id
  id=$(config_get channel)
  valid_slack_id "$id" || return 1
  printf '%s\n' "$id"
}

state_write() {  # <path> <content>
  local dir tmp
  [ -n "$MIRROR_DIR" ] || return 1
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
  watched=$(mirrored_channel) || return 0
  [ "$watched" = "$channel" ] || return 0
  state_write "$MIRROR_DIR/mirror.last-post" "$(now_epoch)" || return 0
}

cmd_note_inbound() {  # <channel> <message-ts> [thread-ts]
  local channel=${1-} msg=${2-} thread=${3-} watched
  valid_slack_id "$channel" || return 0
  valid_ts "$msg" || return 0
  [ -z "$thread" ] || valid_ts "$thread" || thread=
  watched=$(mirrored_channel) || return 0
  [ "$watched" = "$channel" ] || return 0
  state_write "$MIRROR_DIR/mirror.inbound" \
    "$(printf 'schema=%s epoch=%s ts=%s thread=%s' \
        "$INBOUND_SCHEMA" "$(now_epoch)" "$msg" "$thread")" || return 0
}

# A source id as the host's event runner names it: an opaque, path-safe token.
# Validated for charset only, never reconstructed here, so this recorder never
# owns the host's own source-id format.
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
# sequence the event for that result carries, so `turn-end` can route the mirror
# by the message that actually opened the turn. `none` (or empty) binds the
# channel top level. Fail-soft like the other recorders.
cmd_note_trigger() {  # <channel> <source-id> <sequence> <thread-ts-or-none>
  local channel=${1-} source=${2-} seq=${3-} thread=${4-} watched
  valid_slack_id "$channel" || return 0
  valid_source_id "$source" || return 0
  case "$seq" in ''|*[!0-9]*) return 0 ;; esac
  watched=$(mirrored_channel) || return 0
  [ "$watched" = "$channel" ] || return 0
  case "$thread" in
    none|top|'') thread= ;;
    *) valid_ts "$thread" || return 0 ;;
  esac
  correlate_write "$source" "$seq" "$thread" || return 0
}

# The thread the host is answering this turn, recorded before the turn ends so
# `turn-end` can route the mirror deterministically instead of guessing from the
# newest captured inbound. A valid ts targets that thread; `none` (or empty)
# forces the channel top level. An invalid ts is reported but writes no record,
# so `turn-end` falls back rather than silently forcing the top level.
cmd_note_reply_target() {  # <channel> <thread-ts-or-none>
  local channel=${1-} thread=${2-} watched
  valid_slack_id "$channel" || return 0
  watched=$(mirrored_channel) || return 0
  [ "$watched" = "$channel" ] || return 0
  case "$thread" in
    none|top|'') thread= ;;
    *) valid_ts "$thread" || {
         printf 'slack-mirror: invalid thread timestamp for note-reply-target: %s\n' \
           "$thread" >&2
         return 0
       } ;;
  esac
  state_write "$MIRROR_DIR/mirror.reply-target" \
    "$(printf 'schema=%s epoch=%s thread=%s' \
        "$REPLY_TARGET_SCHEMA" "$(now_epoch)" "$thread")" || return 0
}

# --- turn end ----------------------------------------------------------------

# The thread the host explicitly recorded for this turn's reply, CONSUMED on
# read so it binds to exactly one turn end and cannot misroute a later turn. Sets
# REPLY_TARGET_SET=1 and REPLY_TARGET_THREAD (empty means the channel top level)
# when a fresh, well-formed record existed; the record is removed either way.
# Returns nonzero when there was no usable record, so `turn-end` falls back to
# the newest-inbound guess. A record older than the window is an orphan from a
# hung turn and is discarded, not applied.
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

# The reply target for this turn: the thread of the newest captured inbound
# message while that capture is still recent, or empty for the channel top
# level. Reads only the record the host writes as it commits a capture.
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
# opened it, as the adapter reported it. Sets TRIGGER_MODE and TRIGGER_THREAD:
#   thread   - the trigger names a captured Slack result; TRIGGER_THREAD is that
#              capture's recorded thread (empty means the channel top level).
#   toplevel - the trigger is readable but names no captured result, so this is
#              not a Slack turn; post at the top level and never guess a thread.
#   fallback - the trigger could not be read at all, so `turn-end` falls back to
#              the newest-inbound guess.
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

# Every adapter file, in a stable order.
adapter_files() {
  local file
  for file in "$ADAPTER_DIR"/*.sh; do
    [ -f "$file" ] && [ ! -L "$file" ] || continue
    printf '%s\n' "$file"
  done
}

# The adapter for this payload: the pinned one when the host names a harness,
# otherwise the first adapter that claims the payload. No adapter claiming it is
# an ordinary silent no-op, because a host may register the same entry point on a
# harness this tool does not cover yet.
select_adapter() {  # <payload-file>
  local file
  if [ -n "${SLACK_MIRROR_HARNESS:-}" ]; then
    case "$SLACK_MIRROR_HARNESS" in
      ''|*[!a-z0-9-]*) return 1 ;;
    esac
    file="$ADAPTER_DIR/$SLACK_MIRROR_HARNESS.sh"
    [ -f "$file" ] && [ -x "$file" ] || return 1
    printf '%s\n' "$file"
    return 0
  fi
  while IFS= read -r file; do
    [ -x "$file" ] || continue
    if "$file" claims < "$1" >/dev/null 2>&1; then
      printf '%s\n' "$file"
      return 0
    fi
  done < <(adapter_files)
  return 1
}

# The coverage table: every implemented adapter's own line, then the uncovered
# harnesses this file's header records, so one command answers "can it mirror
# this harness yet" without reading the source.
cmd_adapters() {
  local file
  while IFS= read -r file; do
    [ -x "$file" ] || continue
    "$file" describe 2>/dev/null || true
  done < <(adapter_files)
  printf '\nuncovered harnesses:\n'
  sed -n '/^# HARNESS COVERAGE\./,/^# CONFIGURATION/p' "${BASH_SOURCE[0]}" \
    | sed -n '/^#   /p' | sed 's/^# \{0,1\}//'
  return 0
}

cmd_turn_end() {
  local payload_file tmpdir adapter record
  local channel enabled ack_max window max_chars details_flag
  local body turn_epoch post_epoch digest last_digest thread details
  local REPLY_TARGET_SET=0 REPLY_TARGET_THREAD=
  local TURN_TEXT='' TRIGGER_MODE=fallback TRIGGER_THREAD=''
  local model effort

  command -v jq >/dev/null 2>&1 || return 0
  [ -n "$MIRROR_DIR" ] && [ -n "$CONFIG_FILE" ] || return 0

  channel=$(mirrored_channel) || return 0
  enabled=$(setting_flag "$(env_override '')" mirror on)
  [ "$enabled" = on ] || return 0

  tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/slack-mirror-turn.XXXXXX" 2>/dev/null) || return 0
  payload_file="$tmpdir/payload.json"
  cat > "$payload_file" 2>/dev/null || { rm -rf -- "$tmpdir"; return 0; }
  if [ ! -s "$payload_file" ]; then
    rm -rf -- "$tmpdir"
    return 0
  fi

  # Consumed unconditionally at turn end so a recorded target binds to exactly
  # this turn, whatever this turn ends up mirroring. Read before the substantive
  # and duplicate checks below, which return early on many turns.
  window=$(setting_int "$(env_override _THREAD_WINDOW)" mirror_thread_window 900)
  reply_target_consume "$window" || true

  adapter=$(select_adapter "$payload_file") || { rm -rf -- "$tmpdir"; return 0; }
  record=$("$adapter" extract < "$payload_file" 2>/dev/null) || record=
  rm -rf -- "$tmpdir"
  [ -n "$record" ] || return 0

  body=$(printf '%s' "$record" | jq -r '
      if (.final_text | type) == "string" then .final_text else "" end' 2>/dev/null) || return 0
  [ -n "$body" ] || return 0
  TURN_TEXT=$(printf '%s' "$record" | jq -r '
      if (.trigger_text | type) == "string" then .trigger_text else "" end' 2>/dev/null) || TURN_TEXT=
  turn_epoch=$(printf '%s' "$record" | jq -r '
      if (.turn_epoch | type) == "number" then (.turn_epoch | floor | tostring)
      elif (.turn_epoch | type) == "string" then .turn_epoch else "" end' 2>/dev/null) || turn_epoch=
  model=$(printf '%s' "$record" | jq -r '
      if (.model | type) == "string" then .model else "" end' 2>/dev/null) || model=
  effort=$(printf '%s' "$record" | jq -r '
      if (.effort | type) == "string" then .effort else "" end' 2>/dev/null) || effort=

  ack_max=$(setting_int "$(env_override _ACK_MAX_CHARS)" mirror_ack_max_chars 120)
  max_chars=$(setting_int "$(env_override _MAX_CHARS)" mirror_max_chars 3500)
  details_flag=$(setting_flag "$(env_override _WORKER_DETAILS)" mirror_worker_details off)

  is_substantive "$body" "$ack_max" || return 0

  # A deliberate post inside this turn's own window is the message; mirroring it
  # again would double-post.
  post_epoch=$(state_read "$MIRROR_DIR/mirror.last-post" 2>/dev/null || true)
  case "$post_epoch" in
    ''|*[!0-9]*) ;;
    *)
      case "$turn_epoch" in
        ''|*[!0-9]*)
          # No dated turn start, so fall back to an assumed turn length rather
          # than losing the duplicate test entirely.
          turn_epoch=$(( $(now_epoch) - $(setting_int "$(env_override _TURN_WINDOW)" \
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

  # Precedence: the explicit record the host wrote for this turn wins; else
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
  if [ "$details_flag" = on ] && [ -n "$model" ]; then
    details=$model
    [ -z "$effort" ] || details="$model $effort"
  fi

  # Recorded before the post is attempted: the repeat test is a courtesy, and a
  # failure this tool deliberately never learns about must not leave the next
  # identical turn eligible to retry into a channel that may already have it.
  state_write "$MIRROR_DIR/mirror.last-body" "$digest" || return 0

  send "$channel" "$body" "$thread" "$details"
  return 0
}

# Stage the body and hand it to the delivery child. Detached by default, so the
# turn ends without waiting for Slack at all; SLACK_MIRROR_SYNC=1 delivers
# inline for tests.
send() {  # <channel> <body> <thread-or-empty> <details-or-empty>
  local channel=$1 body=$2 thread=$3 details=$4 dir file args
  dir=$(mktemp -d "${TMPDIR:-/tmp}/slack-mirror-send.XXXXXX" 2>/dev/null) || return 0
  file="$dir/body.txt"
  printf '%s\n' "$body" > "$file" 2>/dev/null || { rm -rf -- "$dir"; return 0; }

  args=( "$SCRIPT_DIR/slack-mirror.sh" deliver "$channel" "$file" )
  [ -z "$thread" ] || args+=( --thread "$thread" )
  [ -z "$details" ] || args+=( --worker-details "$details" )

  if [ "$(env_override _SYNC)" = 1 ]; then
    "${args[@]}" >/dev/null 2>&1 || true
    return 0
  fi
  # setsid puts delivery in its own session, so a harness reaping this hook's
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
  [ -n "$POST_CMD" ] && [ -x "$POST_CMD" ] || return 0
  dir=$(dirname "$file")
  "$POST_CMD" "$channel" --file "$file" --origin mirror "$@" >/dev/null 2>&1 || true
  case "$dir" in
    */slack-mirror-send.*) rm -rf -- "$dir" ;;
  esac
  return 0
}

case "${1-}" in
  turn-end)
    shift
    if [ "${1-}" = --harness ]; then
      [ "$#" -eq 2 ] || usage
      SLACK_MIRROR_HARNESS=$2
      export SLACK_MIRROR_HARNESS
      shift 2
    fi
    [ "$#" -eq 0 ] || usage
    cmd_turn_end
    ;;
  note-post)    shift; [ "$#" -eq 1 ] || usage; cmd_note_post "$@" ;;
  note-inbound) shift; [ "$#" -ge 2 ] && [ "$#" -le 3 ] || usage; cmd_note_inbound "$@" ;;
  note-trigger) shift; [ "$#" -eq 4 ] || usage; cmd_note_trigger "$@" ;;
  note-reply-target) shift; [ "$#" -eq 2 ] || usage; cmd_note_reply_target "$@" ;;
  deliver)      shift; [ "$#" -ge 2 ] || usage; cmd_deliver "$@" ;;
  adapters)     shift; [ "$#" -eq 0 ] || usage; cmd_adapters ;;
  ''|-h|--help|help) usage ;;
  *) usage ;;
esac
exit 0
