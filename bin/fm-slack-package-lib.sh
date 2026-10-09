#!/usr/bin/env bash
# Firstmate's mapping from one home onto the agent-slack-mirror environment
# contract. Sourced by the Slack wrappers and by bootstrap; no side effects on
# source.
#
# The package never reads FM_HOME. Callers export this table, then exec the
# installed listener, poster, or mirror core. docs/firstmate-integration.md in
# the package is the contract this table satisfies.
#
# SLACK_MIRROR_HOME selects the checkout; it defaults to
# ${XDG_DATA_HOME:-$HOME/.local/share}/agent-slack-mirror.

# shellcheck shell=bash

fm_slack_package_home() {
  printf '%s\n' "${SLACK_MIRROR_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/agent-slack-mirror}"
}

fm_slack_package_install_cmd() {
  printf 'git clone https://github.com/digbycampbell/agent-slack-mirror.git %q' \
    "$(fm_slack_package_home)"
}

# 0 when the installed checkout has the mirror core, the listener, and the poster.
fm_slack_package_ready() {
  local home
  home=$(fm_slack_package_home)
  [ -f "$home/slack-mirror.sh" ] && [ -x "$home/slack-mirror.sh" ] || return 1
  [ -f "$home/bin/slack-captain.sh" ] && [ -x "$home/bin/slack-captain.sh" ] || return 1
  [ -f "$home/bin/slack-post.sh" ] && [ -x "$home/bin/slack-post.sh" ] || return 1
  return 0
}

fm_slack_package_die_missing() {
  printf 'error: agent-slack-mirror is not installed at %s; install: %s\n' \
    "$(fm_slack_package_home)" "$(fm_slack_package_install_cmd)" >&2
  exit 1
}

fm_slack_package_require() {
  fm_slack_package_ready || fm_slack_package_die_missing
}

# Export the package environment contract from this home. Callers must set
# FM_HOME first. FM_STATE_OVERRIDE and FM_CONFIG_OVERRIDE win the same way
# other firstmate scripts resolve those directories.
fm_slack_package_export_env() {
  local package state config
  package=$(fm_slack_package_home)
  state="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
  config="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
  export SLACK_CONFIG_FILE="$config/slack-captain"
  export SLACK_STATE_DIR="$state/slack-captain"
  export SLACK_TOKEN_FILE="$FM_HOME/.env"
  export SLACK_CHANNELS_FILE="$config/slack-channels"
  export SLACK_MIRROR_STATE_DIR="$state/slack-captain"
  export SLACK_MIRROR_CONFIG_FILE="$config/slack-captain"
  export SLACK_MIRROR_POST_CMD="$package/bin/slack-post.sh"
  export SLACK_MIRROR_CMD="$package/slack-mirror.sh"
  export SLACK_CAPTAIN_CMD="$package/bin/slack-captain.sh"
}
