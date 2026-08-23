#!/usr/bin/env bash
# Merge a task's PR after recording pr= and any available pr_head= through
# bin/fm-pr-check.sh, so teardown can verify landed work after squash merges.
# The full canonical GitHub PR URL is parsed by bin/fm-pr-lib.sh and the derived
# owner/repository and PR number are passed to gh-axi as separate arguments.
#
# Merge method defaults to --squash when the caller passes none of --squash,
# --merge, --rebase, or --method after the optional -- separator. Extra args
# must not include --repo or -R because the repository comes only from the URL.
# Usage: fm-pr-merge.sh <task-id> <pr-url> [-- <extra gh-axi pr merge args>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

if [ "$#" -lt 2 ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
# bin/fm-pr-lib.sh parses GitLab merge request URLs so the watcher can follow
# them, but this path still addresses only GitHub by owner/repository. The
# provider check holds that refusal exactly as it was until merge parity lands.
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL" \
  || [ "$FM_PR_PROVIDER" != github ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
URL=$FM_PR_URL
PR_OWNER=$FM_PR_OWNER
PR_REPO=$FM_PR_REPO
PR_NUMBER=$FM_PR_NUMBER
shift 2
[ "${1:-}" = "--" ] && shift

caller_has_merge_method() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --squash|--merge|--rebase|--method|--method=*) return 0 ;;
    esac
  done
  return 1
}

caller_has_auto() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --auto) return 0 ;;
    esac
  done
  return 1
}

# Read-only PR queries use gh directly, consistent with fm-pr-check.sh's
# pr_head lookup. The merge mutation itself uses gh-axi.
fm_pr_base_branch() {
  gh pr view "$URL" --json baseRefName -q .baseRefName 2>/dev/null
}

# A merge-queue branch requires --auto so the PR is enqueued rather than merged
# immediately. gh pr merge --squash alone returns success on such branches
# without enqueueing or merging, so firstmate would falsely report a merge.
fm_pr_urlencode() {
  local s=$1 c i out=
  for ((i = 0; i < ${#s}; i++)); do
    c=${s:i:1}
    case "$c" in
      [a-zA-Z0-9._~-]) out+="$c" ;;
      *) out+=$(printf '%%%02X' "'$c") ;;
    esac
  done
  printf '%s' "$out"
}

fm_pr_branch_has_merge_queue() {
  local base rules
  base=$(fm_pr_base_branch) || return 1
  [ -n "$base" ] || return 1
  rules=$(gh api "repos/$PR_OWNER/$PR_REPO/rules/branches/$(fm_pr_urlencode "$base")" \
    --jq '.[] | select(.type == "merge_queue")' 2>/dev/null) || return 1
  [ -n "$rules" ]
}

fm_pr_verify_landed() {
  local state
  command -v gh >/dev/null 2>&1 || return 0
  state=$(gh pr view "$URL" --json merged,autoMerge \
    -q '.merged or (.autoMerge.enabled // false)' 2>/dev/null) || return 1
  [ "$state" = "true" ]
}

reject_repo_overrides() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --repo|--repo=*|-R|-R?*)
        echo "error: extra merge arguments must not override the repository" >&2
        return 1
        ;;
    esac
  done
}

reject_repo_overrides "$@" || exit 1

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi

"$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"
grep -qxF "pr=$URL" "$META" || {
  echo "error: PR metadata recording failed" >&2
  exit 1
}

merge_args=()
# On merge-queue branches, --auto is required to enqueue the PR. Do not add it
# when the caller already passed --auto, to avoid duplicate flags.
if command -v gh >/dev/null 2>&1 && fm_pr_branch_has_merge_queue && ! caller_has_auto "$@"; then
  merge_args+=(--auto)
fi
if ! caller_has_merge_method "$@"; then
  merge_args+=(--squash)
fi

gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" "${merge_args[@]+"${merge_args[@]}"}" "$@" || {
  rc=$?
  echo "error: PR merge command failed" >&2
  exit "$rc"
}

if ! fm_pr_verify_landed; then
  echo "error: PR merge reported success but the PR is neither merged nor enqueued" >&2
  exit 1
fi
