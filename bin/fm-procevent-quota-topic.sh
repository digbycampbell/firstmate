#!/usr/bin/env bash
# Live quota channel-topic adapter for the generic process-to-event runner: keep
# a Slack channel's topic showing how much provider quota is left.
#
# Usage:
#   fm-procevent-quota-topic.sh arm
#   fm-procevent-quota-topic.sh poll <home>
#   fm-procevent-quota-topic.sh render
#   fm-procevent-quota-topic.sh update
#   fm-procevent-quota-topic.sh handle <source-id> <sequence> <result-file>
#   fm-procevent-quota-topic.sh autohandle <source-id> <sequence> <result-file>
#   fm-procevent-quota-topic.sh classify <result-file>
#   fm-procevent-quota-topic.sh terminal <result-file>
#   fm-procevent-quota-topic.sh source-id
#   fm-procevent-quota-topic.sh retire
#
# `arm` registers one long-running child with bin/fm-procevent.sh, which owns
# supervision, one machine-wide owner per source, durable capture, publication,
# and restart; this adapter adds no daemon of its own. The child renders the
# topic on the configured interval and sets it only when the rendered string
# changed, so an unchanged quota picture makes no API call and no noise.
#
# This source is NEVER terminal, and a healthy run produces NO result: quota
# reporting is ambient, not an event. The only captured result is a fatal Slack
# error - a credential, scope, or membership problem no retry can fix - which
# becomes an `api-error` result so firstmate is woken with the reason.
# Threshold-crossing quota alerts are ordinary messages and are unchanged by
# this source; the topic is a status line, never an alert channel.
#
# CONFIGURATION - $FM_HOME/config/slack-quota-topic, one key per line:
#   channel=<channel id or name>  required; a name is resolved through
#                                 config/slack-channels, the same map
#                                 bin/fm-slack-post.sh uses
#   interval=<seconds>            optional, default 1200 (20 minutes)
#
# TOPIC FORMAT - one line, always naming every provider honestly:
#   Claude: session xx% week yy% // Codex: week yy% // Grok: credits xx% // Kimi: session xx% week yy%
# Percentages are percentRemaining. Codex publishes no session window at all, so
# it is rendered weekly-only rather than with an invented session figure. Grok
# publishes only a credits window, no session/weekly split, so it is rendered
# credits-only for the same reason. A provider that is absent, unauthenticated,
# or erroring renders its reason (`auth expired`, `unavailable`, `n/a`) and is
# never left blank or stale - an auth problem always wins over a cached figure
# quota-axi still carries from before the credential expired.
#
# QUOTA SOURCES. Claude, Codex, and Grok come from `quota-axi --json`. Kimi does NOT:
# quota-axi's Kimi source reads only the Kimi CLI's OAuth store and goes dark the
# moment that store expires, which is exactly when the number matters. Kimi is
# therefore read straight from the managed usage endpoint the Kimi CLI itself
# calls, `<base>/usages` under https://api.kimi.com/coding/v1, authenticated with
# `KIMI_API_QUOTA` from the home's gitignored `.env`. Its weekly figure is the
# top-level `usage` row and its session figure is the shortest limits window.
#
# TOKENS - `SLACK_BOT_TOKEN` and `KIMI_API_QUOTA` are read from the home's
# gitignored `.env` and handed to curl through `--config -` on stdin. Neither
# ever appears in argv, in a registration record, in a captured result, in the
# rendered topic, or in any diagnostic this adapter prints.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# shellcheck source=bin/fm-x-lib.sh
. "$SCRIPT_DIR/fm-x-lib.sh"

SLACK_API="${FM_SLACK_CAPTAIN_API:-https://slack.com/api}"
KIMI_API="${FM_KIMI_QUOTA_API:-https://api.kimi.com/coding/v1}"
CURL_MAX_TIME=${FM_QUOTA_TOPIC_MAX_TIME:-20}
QUOTA_AXI_TIMEOUT=${FM_QUOTA_TOPIC_QUOTA_TIMEOUT:-60}
MAX_LOOPS=${FM_QUOTA_TOPIC_MAX_LOOPS:-3}
DEFAULT_INTERVAL=1200
SCHEMA=fm-quota-topic.v1
NO_RESULT_EXIT=75

HOME_DIR=$FM_HOME
POLL_TMP=

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,54p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }

state_dir()   { printf '%s\n' "${FM_STATE_OVERRIDE:-$HOME_DIR/state}"; }
config_dir()  { printf '%s\n' "${FM_CONFIG_OVERRIDE:-$HOME_DIR/config}"; }
env_file()    { printf '%s\n' "$HOME_DIR/.env"; }
topic_path()  { printf '%s/slack-quota-topic/%s.topic\n' "$(state_dir)" "$1"; }

valid_slack_id() {
  case "${1-}" in
    ''|*[!A-Z0-9]*) return 1 ;;
  esac
  [ "${#1}" -le 32 ]
}

config_get() {  # <file> <key>
  local file
  file="$(config_dir)/$1"
  [ -e "$file" ] || return 0
  [ -f "$file" ] && [ ! -L "$file" ] || die "slack quota topic configuration is unsafe: $file"
  sed -n "s/^[[:space:]]*$2=//p" "$file" | tail -n1 | tr -d '[:space:]'
}

# Sets CFG_CHANNEL and CFG_INTERVAL. A name is resolved through the shared
# channel map; an unknown name is a refusal, never a guess.
load_config() {
  local raw id
  raw=$(config_get slack-quota-topic channel)
  [ -n "$raw" ] || die "config/slack-quota-topic has no channel= entry"
  raw=${raw#\#}
  if valid_slack_id "$raw"; then
    CFG_CHANNEL=$raw
  else
    case "$raw" in
      ''|*[!A-Za-z0-9_-]*) die "config/slack-quota-topic has an invalid channel" ;;
    esac
    id=$(config_get slack-channels "$raw")
    [ -n "$id" ] || die "config/slack-channels has no entry for '$raw'"
    valid_slack_id "$id" || die "config/slack-channels maps '$raw' to an invalid channel id"
    CFG_CHANNEL=$id
  fi
  CFG_INTERVAL=$(config_get slack-quota-topic interval)
  [ -n "$CFG_INTERVAL" ] || CFG_INTERVAL=$DEFAULT_INTERVAL
  case "$CFG_INTERVAL" in
    ''|*[!0-9]*|0) die "config/slack-quota-topic has an invalid interval" ;;
  esac
}

# One secret from the home's .env, printed for one caller that immediately pipes
# it into curl's stdin config. Absence is a distinguishable nonzero, because an
# absent Kimi key renders honestly rather than stopping the whole topic.
read_secret() {  # <key>
  local token file
  file=$(env_file)
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  token=$(fmx_env_get "$1" "$file")
  [ -n "$token" ] || return 1
  case "$token" in
    *[[:space:]]*) return 1 ;;
  esac
  printf '%s\n' "$token"
}

# --- rendering --------------------------------------------------------------

# Percent as a bounded integer, or empty when the input is not usable.
as_percent() {  # <value>
  local v=${1-}
  case "$v" in
    ''|null|*[!0-9]*) printf '' ; return 0 ;;
  esac
  [ "$v" -le 100 ] || { printf ''; return 0; }
  printf '%s' "$v"
}

# Render Claude, Codex, and Grok from one quota-axi document. Prints one line
# per provider as "<provider> <session> <week> <credits> <reason>", where "-"
# stands for a figure or reason the document does not carry, so no field can go
# missing and shift the ones after it. An auth problem is decided from
# state.status/authStatus alone, never from figure presence, because quota-axi
# keeps serving a provider's last-known percentRemaining even after its
# credential expires (grok's live case: state.stale=true with real windows).
quota_axi_rows() {  # <json-file>
  jq -r '
    def pct(w): (w | if . == null then "-" else ((.percentRemaining // "-") | tostring) end);
    ["claude", "codex", "grok"][] as $p
    | (.providers // [] | map(select(.provider == $p)) | first) as $prov
    | if $prov == null then "\($p) - - - unavailable"
      else
        ($prov.windows // []) as $w
        | (pct($w | map(select(.kind == "session")) | first)) as $session
        | (pct($w | map(select(.kind == "weekly")) | first)) as $week
        | (pct($w | map(select(.kind == "credits" and .id == "credits")) | first)) as $credits
        | ($prov.state.status // "") as $status
        | ($prov.state.authStatus // "") as $authStatus
        | "\($p) \($session) \($week) \($credits) " +
          (if ($status == "auth_required") or ($authStatus | test("^expired")) then "auth-expired"
           elif ($status == "error") then "unavailable"
           elif ($session == "-" and $week == "-" and $credits == "-") then "unavailable"
           else "-" end)
      end
  ' "$1" 2>/dev/null
}

# Kimi, read directly from the managed usage endpoint. Sets KIMI_SESSION,
# KIMI_WEEK, and KIMI_REASON.
read_kimi() {
  local token resp code
  KIMI_SESSION='' KIMI_WEEK='' KIMI_REASON=''
  token=$(read_secret KIMI_API_QUOTA) || { KIMI_REASON='n/a'; return 0; }
  resp="$POLL_TMP/kimi.json"
  code=$(printf 'header = "Authorization: Bearer %s"\nheader = "Accept: application/json"\n' "$token" \
    | curl -sS --config - --max-time "$CURL_MAX_TIME" "$KIMI_API/usages" \
        -o "$resp" -w '%{http_code}' 2>/dev/null) || { KIMI_REASON=unavailable; return 0; }
  case "$code" in
    200) ;;
    401|403) KIMI_REASON='auth expired'; return 0 ;;
    404) KIMI_REASON='n/a'; return 0 ;;
    *) KIMI_REASON=unavailable; return 0 ;;
  esac
  jq -e . "$resp" >/dev/null 2>&1 || { KIMI_REASON=unavailable; return 0; }
  # The weekly figure is the top-level usage row; the session figure is the
  # shortest limits window the endpoint reports.
  KIMI_WEEK=$(as_percent "$(jq -r '
    (.usage // {}) as $u
    | if (($u.limit // "0") | tonumber) > 0
      then ((($u.remaining // "0") | tonumber) * 100 / (($u.limit) | tonumber) | round)
      else "" end
  ' "$resp" 2>/dev/null)")
  KIMI_SESSION=$(as_percent "$(jq -r '
    ((.limits // [])
      | map(select(.detail != null and ((.detail.limit // "0") | tonumber) > 0))
      | sort_by(
          (.window.duration // 0 | tonumber)
          * (if (.window.timeUnit // "") == "TIME_UNIT_MINUTE" then 60
             elif (.window.timeUnit // "") == "TIME_UNIT_HOUR" then 3600
             elif (.window.timeUnit // "") == "TIME_UNIT_DAY" then 86400
             else 1 end))
      | first) as $l
    | if $l == null then ""
      else (((($l.detail.remaining // "0") | tonumber) * 100 / (($l.detail.limit) | tonumber)) | round)
      end
  ' "$resp" 2>/dev/null)")
  [ -n "$KIMI_WEEK" ] || [ -n "$KIMI_SESSION" ] || KIMI_REASON='n/a'
}

# "<label>: session xx% week yy%", or the honest reason when every figure is missing.
render_provider() {  # <label> <session> <week> <credits> <reason>
  local out=
  if [ -n "$2" ]; then out="session $2%"; fi
  if [ -n "$3" ]; then out="${out:+$out }week $3%"; fi
  if [ -n "$4" ]; then out="${out:+$out }credits $4%"; fi
  [ -n "$out" ] || out=${5:-n/a}
  printf '%s: %s' "$1" "$out"
}

cmd_render() {
  local axi="$POLL_TMP/quota-axi.json" provider session week credits reason
  local claude='' codex='' grok='' kimi=''
  if command -v quota-axi >/dev/null 2>&1 \
     && timeout "$QUOTA_AXI_TIMEOUT" quota-axi --json > "$axi" 2>/dev/null \
     && jq -e . "$axi" >/dev/null 2>&1; then
    while read -r provider session week credits reason; do
      [ "$reason" != - ] || reason=''
      reason=${reason//-/ }
      # A named reason always wins over any cached figure quota-axi still
      # carries from before the credential problem, so a stale percentage
      # never slips out disguised as a current one.
      if [ -n "$reason" ]; then
        session='' week='' credits=''
      else
        session=$(as_percent "$session") week=$(as_percent "$week") credits=$(as_percent "$credits")
      fi
      case "$provider" in
        claude) claude=$(render_provider Claude "$session" "$week" '' "$reason") ;;
        # Codex has no session window at all, so only its weekly figure is real.
        codex)  codex=$(render_provider Codex '' "$week" '' "$reason") ;;
        # Grok has no session/weekly split at all, only a credits window.
        grok)   grok=$(render_provider Grok '' '' "$credits" "$reason") ;;
      esac
    done < <(quota_axi_rows "$axi")
  fi
  [ -n "$claude" ] || claude='Claude: unavailable'
  [ -n "$codex" ] || codex='Codex: unavailable'
  [ -n "$grok" ] || grok='Grok: unavailable'
  read_kimi
  kimi=$(render_provider Kimi "$KIMI_SESSION" "$KIMI_WEEK" '' "$KIMI_REASON")
  printf '%s // %s // %s // %s\n' "$claude" "$codex" "$grok" "$kimi"
}

# --- applying the topic -----------------------------------------------------

read_last_topic() {  # <channel>
  local path
  path=$(topic_path "$1")
  [ -f "$path" ] && [ ! -L "$path" ] || return 0
  head -n 1 "$path"
}

write_last_topic() {  # <channel> <topic>
  local path dir tmp
  path=$(topic_path "$1")
  dir=$(dirname "$path")
  (umask 077; mkdir -p "$dir") || return 1
  [ ! -L "$path" ] || return 1
  tmp=$(umask 077; mktemp "$dir/.topic.XXXXXX") || return 1
  printf '%s\n' "$2" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$path"
}

fatal_slack_error() {
  case "$1" in
    invalid_auth|not_authed|account_inactive|token_revoked|token_expired) return 0 ;;
    missing_scope|channel_not_found|not_in_channel|is_archived) return 0 ;;
  esac
  return 1
}

safe_reason() {
  local value=${1-}
  case "$value" in
    ''|*[!A-Za-z0-9_-]*) printf 'unknown\n' ;;
    *) printf '%s\n' "${value:0:64}" ;;
  esac
}

# Set the channel topic. Sets SET_STATE to set|unchanged|transient|<fatal-error>.
set_topic() {  # <channel> <topic>
  local token body resp err
  SET_STATE=transient
  if [ "$2" = "$(read_last_topic "$1")" ]; then
    SET_STATE=unchanged
    return 0
  fi
  token=$(read_secret SLACK_BOT_TOKEN) || die "SLACK_BOT_TOKEN is not set in this home's .env"
  body="$POLL_TMP/topic.json"
  resp="$POLL_TMP/topic-response.json"
  jq -n --arg channel "$1" --arg topic "$2" '{channel: $channel, topic: $topic}' > "$body" \
    || die "cannot build the Slack request body"
  printf 'header = "Authorization: Bearer %s"\n' "$token" \
    | curl -sS --config - --max-time "$CURL_MAX_TIME" \
        -H 'Content-Type: application/json; charset=utf-8' \
        --data-binary "@$body" \
        "$SLACK_API/conversations.setTopic" -o "$resp" 2>/dev/null \
    || return 0
  jq -e . "$resp" >/dev/null 2>&1 || return 0
  if ! jq -e '.ok == true' "$resp" >/dev/null 2>&1; then
    err=$(safe_reason "$(jq -r '.error // ""' "$resp" 2>/dev/null || true)")
    fatal_slack_error "$err" && SET_STATE=$err
    return 0
  fi
  # The record of what Slack accepted is written only after Slack accepted it,
  # so a failed call is retried rather than remembered as applied.
  write_last_topic "$1" "$2" || die "cannot record the applied channel topic"
  SET_STATE='set'
}

staging() {
  POLL_TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-quota-topic.XXXXXX") || die "cannot create a staging directory"
  trap 'rm -rf -- "$POLL_TMP"' EXIT
}

cmd_update() {
  local topic
  load_config
  staging
  topic=$(cmd_render)
  set_topic "$CFG_CHANNEL" "$topic"
  case "$SET_STATE" in
    set)       printf 'set: %s\n' "$topic" ;;
    unchanged) printf 'unchanged: %s\n' "$topic" ;;
    transient) printf 'not-set: %s\n' "$topic"; return 1 ;;
    *)         die "Slack refused the channel topic: $SET_STATE" ;;
  esac
}

emit_header() {  # <status> <channel> <reason>
  printf 'schema=%s\n' "$SCHEMA"
  printf 'status=%s\n' "$1"
  printf 'channel=%s\n' "$2"
  printf 'reason=%s\n' "$3"
  printf '\n'
}

cmd_poll() {  # <home>
  local home=${1-} i=0 topic
  [ -n "$home" ] || usage
  HOME_DIR=$home
  command -v curl >/dev/null 2>&1 || die "curl is not installed"
  command -v jq >/dev/null 2>&1 || die "jq is not installed"
  load_config
  staging
  while [ "$i" -lt "$MAX_LOOPS" ]; do
    i=$((i + 1))
    topic=$(cmd_render)
    set_topic "$CFG_CHANNEL" "$topic"
    case "$SET_STATE" in
      set|unchanged|transient) ;;
      *)
        emit_header api-error "$CFG_CHANNEL" "$SET_STATE"
        return 0
        ;;
    esac
    [ "$i" -lt "$MAX_LOOPS" ] || break
    sleep "$CFG_INTERVAL"
  done
  # An ambient status line that is up to date is not an event: no result, no
  # wake, and the runner's ordinary reconcile starts the next run.
  return "$NO_RESULT_EXIT"
}

# --- runner seams -----------------------------------------------------------

result_field() {  # <result-file> <field>
  LC_ALL=C awk -v prefix="$2=" '
    $0 == "" { exit }
    index($0, prefix) == 1 { count++; value = substr($0, length(prefix) + 1) }
    END { if (count != 1) exit 1; print value }
  ' "$1"
}

cmd_classify() {
  local file=${1-} schema status
  [ -n "$file" ] || usage
  [ -f "$file" ] && [ ! -L "$file" ] || { printf 'unknown\n'; return 0; }
  [ -s "$file" ] || { printf 'empty\n'; return 0; }
  schema=$(result_field "$file" schema 2>/dev/null || true)
  [ "$schema" = "$SCHEMA" ] || { printf 'unknown\n'; return 0; }
  status=$(result_field "$file" status 2>/dev/null || true)
  case "$status" in
    api-error) printf 'api-error\n' ;;
    *) printf 'unknown\n' ;;
  esac
}

cmd_source_id() {
  load_config
  printf 'quota-topic-%s\n' "$CFG_CHANNEL"
}

cmd_arm() {
  local id
  command -v curl >/dev/null 2>&1 || die "curl is not installed"
  command -v jq >/dev/null 2>&1 || die "jq is not installed"
  load_config
  read_secret SLACK_BOT_TOKEN >/dev/null || die "SLACK_BOT_TOKEN is not set in this home's .env"
  id=$(cmd_source_id) || exit 1
  "$SCRIPT_DIR/fm-procevent.sh" register quota-topic "$id" -- \
    "$SCRIPT_DIR/fm-procevent-quota-topic.sh" poll "$HOME_DIR" || exit 1
  printf 'armed: %s\n' "$id"
}

cmd_retire() {
  local id
  id=$(cmd_source_id) || exit 1
  "$SCRIPT_DIR/fm-procevent.sh" retire "$id"
}

# The only capturable result is a fatal Slack error, which carries nothing to
# apply. `handle` records the acknowledgement; `autohandle` deliberately reports
# failure so the result stays eligible for re-announcement until firstmate reads
# it, exactly as the captain-channel adapter does.
cmd_handle() {
  local sid=${1-} seq=${2-} file=${3-}
  case "$seq" in ''|*[!0-9]*) die "sequence must be a nonnegative integer" ;; esac
  [ -f "$file" ] && [ ! -L "$file" ] || die "result file is unavailable or unsafe: $file"
  [ "$(cmd_classify "$file")" = api-error ] \
    || die "captured quota-topic result needs firstmate's attention: $(cmd_classify "$file")"
  "$SCRIPT_DIR/fm-procevent.sh" handled "$sid" "$seq" || return 1
  printf 'applied: %s\n' "$sid"
}

case "${1-}" in
  arm)        shift; [ "$#" -eq 0 ] || usage; cmd_arm ;;
  poll)       shift; [ "$#" -eq 1 ] || usage; cmd_poll "$@" ;;
  render)     shift; [ "$#" -eq 0 ] || usage; staging; cmd_render ;;
  update)     shift; [ "$#" -eq 0 ] || usage; cmd_update ;;
  handle)     shift; [ "$#" -eq 3 ] || usage; cmd_handle "$@" ;;
  autohandle) shift; [ "$#" -eq 3 ] || usage; exit 1 ;;
  classify)   shift; [ "$#" -eq 1 ] || usage; cmd_classify "$@" ;;
  # The quota picture always has a next reading, so the source never ends.
  terminal)   shift; [ "$#" -eq 1 ] || usage; exit 1 ;;
  source-id)  shift; [ "$#" -eq 0 ] || usage; cmd_source_id ;;
  retire)     shift; [ "$#" -eq 0 ] || usage; cmd_retire ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
