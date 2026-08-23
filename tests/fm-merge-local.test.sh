#!/usr/bin/env bash
# Behavior tests for bin/fm-merge-local.sh branch resolution.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

MERGE_LOCAL="$ROOT/bin/fm-merge-local.sh"
TMP_ROOT=$(fm_test_tmproot fm-merge-local)

make_case() {
  local name=$1 case_dir repo
  case_dir="$TMP_ROOT/$name"
  repo="$case_dir/project"
  mkdir -p "$case_dir/state"
  fm_git_init_commit "$repo"
  git -C "$repo" branch -M main
  printf '%s\n' "$case_dir"
}

prepare_branch() {
  local repo=$1 branch=$2
  git -C "$repo" checkout -qb "$branch"
  printf '%s\n' change >> "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -qm change
  git -C "$repo" checkout -q main
}

run_merge() {
  local case_dir=$1 id=$2
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$case_dir" \
    "$MERGE_LOCAL" "$id"
}

test_issue_linked_branch() {
  local case_dir repo
  case_dir=$(make_case issue-linked)
  repo="$case_dir/project"
  prepare_branch "$repo" fm-issue-512
  fm_write_meta "$case_dir/state/issue-linked.meta" \
    "project=$repo" "kind=ship" "mode=local-only" "issue=512"

  run_merge "$case_dir" issue-linked >/dev/null \
    || fail "issue-linked: local merge should resolve fm-issue-512"
  [ "$(git -C "$repo" symbolic-ref --short HEAD)" = main ] \
    || fail "issue-linked: merge changed the project's checked-out branch"
  assert_contains "$(git -C "$repo" log --oneline -2)" change \
    "issue-linked: fm-issue-512 was not merged into main"
  pass "fm-merge-local resolves fm-issue-<number> for linked local-only tasks"
}

test_fallback_branch() {
  local case_dir repo
  case_dir=$(make_case fallback)
  repo="$case_dir/project"
  prepare_branch "$repo" fm/task-fallback-a1
  fm_write_meta "$case_dir/state/task-fallback-a1.meta" \
    "project=$repo" "kind=ship" "mode=local-only"

  run_merge "$case_dir" task-fallback-a1 >/dev/null \
    || fail "fallback: local merge should resolve fm/<task-id>"
  assert_contains "$(git -C "$repo" log --oneline -2)" change \
    "fallback: fm/<task-id> was not merged into main"
  pass "fm-merge-local preserves fm/<task-id> for issue-less tasks"
}

test_issue_linked_branch
test_fallback_branch
