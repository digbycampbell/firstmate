#!/usr/bin/env bash
# Slack captain-channel adapter: firstmate's thin caller over the installed
# agent-slack-mirror listener.
#
# Usage:
#   fm-procevent-slack-captain.sh arm
#   fm-procevent-slack-captain.sh poll <home> <channel>
#   fm-procevent-slack-captain.sh handle <source-id> <sequence> <result-file>
#   fm-procevent-slack-captain.sh autohandle <source-id> <sequence> <result-file>
#   fm-procevent-slack-captain.sh classify <result-file>
#   fm-procevent-slack-captain.sh terminal <result-file>
#   fm-procevent-slack-captain.sh relisten
#   fm-procevent-slack-captain.sh track-thread <channel> <thread-ts>
#   fm-procevent-slack-captain.sh mark-replied <channel> <thread-ts|none>
#   fm-procevent-slack-captain.sh source-id
#   fm-procevent-slack-captain.sh retire
#
# `arm` registers one bounded long-poll of a Slack channel so a message the
# captain posts there reaches firstmate as an ordinary `check` wake. The
# process-event runner owns blocking, durable capture, publication, and one
# machine-wide owner per source; bin/fm-procevent.sh and
# docs/configuration.md own that generic contract.
#
# THIN CALLER. The installed agent-slack-mirror `bin/slack-captain.sh` header
# owns Slack behaviour: configuration keys, the token, poll shape, read-position
# continuity, thread tracking, debounce, reactions, attachments, and captured
# message shape. This file keeps the built-in adapter name and the argv the
# runner already registers, and adds only what is firstmate's:
#
#   - it resolves this home's `config/slack-captain`, `state/slack-captain/`,
#     `.env`, and the installed package as the tool's environment contract, so
#     the package never learns firstmate's layout;
#   - `arm` and `retire` stay here, because the package does not call the
#     runner: `arm` registers `poll <home> <channel>` on this wrapper so a
#     later runner child can re-derive the home;
#   - `poll <home> <channel>` drops `<home>` from argv after exporting that
#     home's contract, then execs the package;
#   - `handle` runs the package then records `fm-procevent.sh handled`, because
#     the package applies read positions only;
#   - `autohandle` runs the package, which advances the read positions and
#     then exits nonzero on purpose. It exits 0 only when the package applied
#     a messages capture and the read position now covers it, so the runner
#     may poll again; any refusal keeps the package's nonzero exit. Neither
#     exit records `fm-procevent.sh handled`, so the result stays announced
#     until firstmate handles it;
#   - `relisten` exits 0, so the runner keeps its claim and polls again after
#     a quiet poll (the package's exit 75) and after an applied capture;
#   - `poll` reports a failed poll that produced no output as the package's
#     quiet exit 75, so the runner relistens, unless the previous poll also
#     failed with no output, tracked by a marker file under this home's
#     state/slack-captain/ directory that any successful or quiet poll clears.
#     A poll that fails with output keeps that failure's exit status.
#
# This source is NEVER terminal. `terminal` always refuses, so the runner keeps
# the registration armed. The runner normally relistens; two consecutive
# failed polls with no output, or a capture the package could not apply,
# release the claim, and the ordinary reconcile restarts the poll on the next
# supervision cycle. Relistening keeps the channel polled while no supervision
# cycle runs, until the runner's owner lease ends (bin/fm-procevent.sh).
#
# INSTALLATION. SLACK_MIRROR_HOME selects the agent-slack-mirror checkout.
# A missing core, listener, or poster is a loud refusal naming the exact clone
# command; fm-bootstrap reports the same gap at session start.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# shellcheck source=bin/fm-env-lib.sh
. "$SCRIPT_DIR/fm-env-lib.sh"
# shellcheck source=bin/fm-slack-package-lib.sh
. "$SCRIPT_DIR/fm-slack-package-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { awk 'NR > 1 && !/^#/ { exit } NR > 1' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }

package_captain() {
  printf '%s/bin/slack-captain.sh\n' "$(fm_slack_package_home)"
}

prepare() {
  fm_slack_package_export_env
  fm_slack_package_require
}

forward() {
  prepare
  exec "$(package_captain)" "$@"
}

cmd_source_id() {
  prepare
  "$(package_captain)" source-id
}

cmd_arm() {
  local id channel token envf
  prepare
  command -v curl >/dev/null 2>&1 || die "curl is not installed"
  command -v jq >/dev/null 2>&1 || die "jq is not installed"
  envf="$FM_HOME/.env"
  [ -f "$envf" ] && [ ! -L "$envf" ] || die "no .env in this home, so SLACK_BOT_TOKEN cannot be read"
  token=$(fmx_env_get SLACK_BOT_TOKEN "$envf")
  [ -n "$token" ] || die "SLACK_BOT_TOKEN is not set in this home's .env"
  case "$token" in
    *[[:space:]]*) die "SLACK_BOT_TOKEN contains whitespace" ;;
  esac
  id=$(cmd_source_id) || exit 1
  channel=${id#slack-captain-}
  "$SCRIPT_DIR/fm-procevent.sh" register slack-captain "$id" -- \
    "$SCRIPT_DIR/fm-procevent-slack-captain.sh" poll "$FM_HOME" "$channel" || exit 1
  printf 'armed: %s\n' "$id"
}

# Retirement is a passthrough. The cursor deliberately survives it, so re-arming
# resumes from the last acknowledged message rather than skipping the gap.
cmd_retire() {
  local id
  id=$(cmd_source_id) || exit 1
  "$SCRIPT_DIR/fm-procevent.sh" retire "$id"
}

cmd_poll() {
  local home=${1-} channel=${2-} marker_dir marker staged rc
  [ -n "$home" ] && [ -n "$channel" ] || usage
  FM_HOME=$home
  prepare
  marker_dir="${FM_STATE_OVERRIDE:-$FM_HOME/state}/slack-captain"
  marker="$marker_dir/.last-poll-failed"
  staged=$(mktemp "${TMPDIR:-/tmp}/fm-slack-poll.XXXXXX") || die "cannot stage the poll output"
  "$(package_captain)" poll "$channel" > "$staged"
  rc=$?
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 75 ] && [ ! -s "$staged" ]; then
    rm -f -- "$staged"
    mkdir -p "$marker_dir" 2>/dev/null || true
    if [ -e "$marker" ]; then
      rm -f -- "$marker"
      exit "$rc"
    fi
    : > "$marker" 2>/dev/null || true
    exit 75
  fi
  rm -f -- "$marker"
  cat -- "$staged"
  rm -f -- "$staged"
  exit "$rc"
}

cmd_handle() {
  local sid=${1-} seq=${2-} file=${3-}
  prepare
  "$(package_captain)" handle "$sid" "$seq" "$file" || exit $?
  "$SCRIPT_DIR/fm-procevent.sh" handled "$sid" "$seq" || exit 1
}

cmd_autohandle() {
  local sid=$1 seq=$2 file=$3 out rc=0 class
  prepare
  out=$("$(package_captain)" autohandle "$sid" "$seq" "$file") || rc=$?
  [ -z "$out" ] || printf '%s\n' "$out"
  class=$("$(package_captain)" classify "$file" 2>/dev/null) || class=
  case "$class:$(printf '%s\n' "$out" | head -n 1)" in
    messages:"applied: $sid "*|messages:"superseded: $sid "*) exit 0 ;;
    untrusted-messages:"applied: $sid "*|untrusted-messages:"superseded: $sid "*) exit 0 ;;
  esac
  [ "$rc" -ne 0 ] || rc=1
  exit "$rc"
}

case "${1-}" in
  arm)        shift; [ "$#" -eq 0 ] || usage; cmd_arm ;;
  poll)       shift; [ "$#" -eq 2 ] || usage; cmd_poll "$@" ;;
  handle)     shift; [ "$#" -eq 3 ] || usage; cmd_handle "$@" ;;
  autohandle) shift; [ "$#" -eq 3 ] || usage; cmd_autohandle "$@" ;;
  relisten)   shift; [ "$#" -eq 0 ] || usage; exit 0 ;;
  classify)   shift; [ "$#" -eq 1 ] || usage; forward classify "$@" ;;
  track-thread) shift; [ "$#" -eq 2 ] || usage; forward track-thread "$@" ;;
  mark-replied) shift; [ "$#" -eq 2 ] || usage; forward mark-replied "$@" ;;
  terminal)   shift; [ "$#" -eq 1 ] || usage; forward terminal "$@" ;;
  source-id)  shift; [ "$#" -eq 0 ] || usage; cmd_source_id ;;
  retire)     shift; [ "$#" -eq 0 ] || usage; cmd_retire ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
