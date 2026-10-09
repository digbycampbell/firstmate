#!/usr/bin/env bash
# Firstmate's caller for the terminal-to-Slack mirror, so Slack carries the same
# conversation the captain sees in the terminal instead of the subset firstmate
# remembered to post by hand.
#
# Usage:
#   fm-slack-mirror.sh stop                       turn-end entry, payload on stdin
#   fm-slack-mirror.sh note-post <channel>        record a deliberate outbound post
#   fm-slack-mirror.sh note-inbound <channel> <message-ts> [thread-ts]
#   fm-slack-mirror.sh note-trigger <channel> <source-id> <sequence> <thread-ts|none>
#   fm-slack-mirror.sh note-reply-target <channel> <thread-ts|none>
#   fm-slack-mirror.sh deliver <channel> <body-file> [--thread <ts>] [--worker-details <d>]
#   fm-slack-mirror.sh adapters                   print the harness coverage table
#
# THIN CALLER. The separately installed agent-slack-mirror core and its header
# own every mirror contract: what is mirrored, the substantive-versus-
# acknowledgement rule, the no-double-post record, thread resolution and its
# three precedence layers, the never-a-gate guarantee, the configuration keys,
# and the state files. This file adds only what is firstmate's, and forwards
# everything else unchanged:
#
#   - it resolves this home's `config/slack-captain`, `state/slack-captain/`,
#     and the installed package poster as the tool's environment contract, so
#     the tool itself never learns firstmate's layout;
#   - it applies firstmate's own primary scope, so a crewmate or scout worktree
#     is inert exactly like the turn-end guard;
#   - it stands a Claude-shaped payload down when a foreign host delivered it,
#     through bin/fm-hook-host-lib.sh, because that host has its own coverage.
#
# HARNESS SCOPE. `stop` is registered on every primary harness whose turn end
# delivers a payload naming the finished turn's own final message:
# `.claude/settings.json` as a third Claude `Stop` hook, and
# `.grok/hooks/fm-primary-slack-mirror.json` as a Grok `Stop` hook. The adapter
# is selected from the payload itself, so one registration shape serves both and
# a harness that delivers no such payload is simply never registered;
# `fm-slack-mirror.sh adapters` prints the installed core's current coverage and
# every recorded gap. docs/turnend-guard.md owns what each harness exposes at the
# turn boundary.
#
# INSTALLATION. SLACK_MIRROR_HOME selects the agent-slack-mirror checkout or
# install directory. It defaults to
# `${XDG_DATA_HOME:-$HOME/.local/share}/agent-slack-mirror`; fm-bootstrap reports
# the exact clone command when that directory has no executable core, listener,
# or poster. Non-hook commands report the same clone command rather than
# failing obscurely; `stop` stays silent so a missing package cannot gate a turn.
#
# NEVER A GATE. This entry point exits 0 on every path, prints nothing to
# stdout, and hands delivery to a detached child, so it cannot change the exit
# status semantics of the turn-end guard or the watcher auto-arm, which are
# separate hook processes with their own stdin.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-hook-host-lib.sh
. "$SCRIPT_DIR/fm-hook-host-lib.sh"
# shellcheck source=bin/fm-slack-package-lib.sh
. "$SCRIPT_DIR/fm-slack-package-lib.sh"

usage() { sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }

fm_slack_package_export_env
MIRROR_HOME=$(fm_slack_package_home)
MIRROR="$MIRROR_HOME/slack-mirror.sh"

cmd_stop() {
  local payload
  payload=$(cat 2>/dev/null) || return 0
  [ -n "$payload" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  # A foreign host that also loads Claude-shaped settings has its own coverage.
  ! fm_hook_payload_is_foreign_host "$payload" || return 0

  fm_primary_scope_matches "$FM_ROOT" "$STATE" || return 0
  [ -x "$MIRROR" ] || return 0

  printf '%s' "$payload" | "$MIRROR" turn-end >/dev/null 2>&1 || true
  return 0
}

forward() {
  if ! fm_slack_package_ready; then
    printf 'error: agent-slack-mirror is not installed at %s; install: %s\n' \
      "$MIRROR_HOME" "$(fm_slack_package_install_cmd)" >&2
    return 0
  fi
  "$MIRROR" "$@" || true
  return 0
}

case "${1-}" in
  stop)         shift; [ "$#" -eq 0 ] || usage; cmd_stop ;;
  note-post)    shift; [ "$#" -eq 1 ] || usage; forward note-post "$@" ;;
  note-inbound) shift; [ "$#" -ge 2 ] && [ "$#" -le 3 ] || usage; forward note-inbound "$@" ;;
  note-trigger) shift; [ "$#" -eq 4 ] || usage; forward note-trigger "$@" ;;
  note-reply-target) shift; [ "$#" -eq 2 ] || usage; forward note-reply-target "$@" ;;
  deliver)      shift; [ "$#" -ge 2 ] || usage; forward deliver "$@" ;;
  adapters)     shift; [ "$#" -eq 0 ] || usage; forward adapters ;;
  ''|-h|--help|help) usage ;;
  *) usage ;;
esac
exit 0
