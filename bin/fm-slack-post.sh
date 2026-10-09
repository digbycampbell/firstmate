#!/usr/bin/env bash
# Post one Slack message as firstmate's bot: firstmate's thin caller over the
# installed agent-slack-mirror poster.
#
# Usage:
#   fm-slack-post.sh <channel> <text>...
#   fm-slack-post.sh <channel> --file <path>
#   fm-slack-post.sh <channel> ... --thread <ts>
#   fm-slack-post.sh <channel> ... --worker-details "<model> <effort>"
#   fm-slack-post.sh <channel> ... --origin manual|mirror
#
# THIN CALLER. The installed agent-slack-mirror `bin/slack-post.sh` header owns
# the post itself: channel-map resolution, token confinement, the quote bar,
# `--worker-details`, thread registration, and the replied reaction. This file
# resolves this home's `config/slack-captain`, `config/slack-channels`, `.env`,
# and the installed package as the tool's environment contract, then execs the
# package with the same flags.
#
# INSTALLATION. SLACK_MIRROR_HOME selects the agent-slack-mirror checkout.
# A missing core, listener, or poster is a loud refusal naming the exact clone
# command; fm-bootstrap reports the same gap at session start.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# shellcheck source=bin/fm-slack-package-lib.sh
. "$SCRIPT_DIR/fm-slack-package-lib.sh"

usage() { awk 'NR > 1 && !/^#/ { exit } NR > 1' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }

case "${1-}" in
  ''|-h|--help|help) usage ;;
esac

fm_slack_package_export_env
fm_slack_package_require
exec "$(fm_slack_package_home)/bin/slack-post.sh" "$@"
