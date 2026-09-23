#!/usr/bin/env bash
# Tests for bin/fm-pr-check.sh's optional board-move courtesy: when a task's
# meta carries issue= (persisted at spawn time by fm-spawn.sh's --issue
# flag), recording a PR also makes one fail-open
# `bin/fm-board.sh move <issue> "PR ready"` call, after the PR is already
# durably recorded and the merge poll already armed.
#
# These run the REAL fm-pr-check.sh and the REAL fm-board.sh together (FM_ROOT
# resolves to this repo) with `gh` mocked, so this is the actual wiring under
# test rather than a stand-in for it. fm-pr-check passes the PR's own repo to
# fm-board, so fm-board resolves the card directly through the issue's
# projectItems connection (no whole-board listing); the mock also answers
# fm-pr-check's own `gh pr view` head read with a miss so it is a no-op.
#
# Matrix:
#   (a) a task meta carrying issue=42 makes fm-pr-check.sh move that card to
#       "PR ready" via the projectItems lookup, with no board-wide listing
#   (b) a task meta with no issue= makes no board call at all, and
#       fm-pr-check.sh's own result is unaffected
#   (c) a failing board (graphql error) does not fail fm-pr-check.sh
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PR_CHECK="$ROOT/bin/fm-pr-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-check-board)

# gh mock: answers fm-pr-check's own `gh pr view` head read with a miss (exit 1,
# so no PR head is recorded), and answers fm-board's `gh api graphql` board
# calls for a minimal one-card board (project 2, owner digio-nz, a "Status"
# field with Inbox/PR ready options, one card for issue 42 in Inbox in
# digio-nz/fcdispatch). Logs every invocation. Args: fakebin fail-mode(0/1)
add_gh_mock() {
  local fakebin=$1 fail=$2
  cat > "$fakebin/gh" <<SH
#!/usr/bin/env bash
log="\${FM_TEST_GH_AXI_LOG:-/dev/null}"
printf 'gh %s\n' "\$*" >> "\$log"
fail=$fail
SH
  cat >> "$fakebin/gh" <<'SH'
case "$1 $2" in
  "pr view") exit 1 ;;
  "api graphql") ;;
  *) exit 0 ;;
esac
[ "$fail" != 1 ] || { echo "error: simulated gh failure" >&2; exit 1; }
q=''; num=''
for a in "$@"; do
  case "$a" in query=*) q=$a ;; number=*) num=${a#number=} ;; esac
done
tab=$'\t'
case "$q" in
  *updateProjectV2ItemFieldValue*) exit 0 ;;
  *projectItems*)
    case "$num" in
      42) printf 'item=ITEM-42%sPVT_TEST%sInbox\ncost=1\n' "$tab" "$tab" ;;
      *)  printf 'cost=1\n' ;;
    esac
    exit 0 ;;
  *)
    printf 'project=PVT_TEST\nfield=PVTSSF_STATUS\n'
    printf 'option=Inbox%sopt-inbox\n' "$tab"
    printf 'option=PR ready%sopt-prready\n' "$tab"
    printf 'cost=1\n'
    exit 0 ;;
esac
SH
  chmod +x "$fakebin/gh"
}

# A fresh sandbox: an FM_HOME with a task meta, and a fakebin with gh
# mocked. Echoes "case_dir|home_dir|fakebin_dir".
make_case() {
  local name=$1 id=$2 with_issue=$3 case_dir home fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  fakebin=$(fm_fakebin "$case_dir")
  mkdir -p "$home/state" "$home/data" "$home/config" "$case_dir/wt" "$case_dir/project"
  if [ "$with_issue" = 1 ]; then
    fm_write_meta "$home/state/$id.meta" \
      "window=firstmate:fm-$id" \
      "endpoint_task_id=$id" \
      "worktree=$case_dir/wt" \
      "project=$case_dir/project" \
      "kind=ship" \
      "mode=no-mistakes" \
      "issue=42"
  else
    fm_write_meta "$home/state/$id.meta" \
      "window=firstmate:fm-$id" \
      "endpoint_task_id=$id" \
      "worktree=$case_dir/wt" \
      "project=$case_dir/project" \
      "kind=ship" \
      "mode=no-mistakes"
  fi
  printf '%s\n' "$case_dir|$home|$fakebin"
}

run_check() {
  local home=$1 fakebin=$2 gh_log=$3
  shift 3
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_TEST_GH_AXI_LOG="$gh_log" \
    PATH="$fakebin:$PATH" \
    "$PR_CHECK" "$@" 2>&1
}

# --- (a) issue= on the task meta moves the card to "PR ready" -------------
id=pr-check-issue-yes
rec=$(make_case issue-yes "$id" 1)
IFS='|' read -r CASE_DIR HOME_DIR FAKEBIN_DIR <<EOF
$rec
EOF
add_gh_mock "$FAKEBIN_DIR" 0
gh_log="$CASE_DIR/gh-axi.log"
out=$(run_check "$HOME_DIR" "$FAKEBIN_DIR" "$gh_log" "$id" "https://github.com/digio-nz/fcdispatch/pull/99")
status=$?
expect_code 0 "$status" "issue-yes: fm-pr-check.sh should succeed"
assert_contains "$out" "armed: state/$id.check.sh" "issue-yes: fm-pr-check.sh did not report armed"
[ -s "$gh_log" ] || fail "issue-yes: issue= on meta did not trigger any board call"
assert_grep "projectItems" "$gh_log" \
  "issue-yes: fm-board.sh did not resolve the card via the projectItems connection"
assert_no_grep "items(first:100" "$gh_log" \
  "issue-yes: fm-board.sh page-scanned the whole board despite the repo being passed"
assert_grep "updateProjectV2ItemFieldValue" "$gh_log" \
  "issue-yes: fm-board.sh did not issue a move mutation"
assert_grep "option=opt-prready" "$gh_log" \
  "issue-yes: fm-board.sh did not target the PR ready option"
pass "fm-pr-check.sh moves the linked issue's card to PR ready via projectItems when meta carries issue="

# --- (b) no issue= on the task meta makes no board call at all -------------
id=pr-check-issue-no
rec=$(make_case issue-no "$id" 0)
IFS='|' read -r CASE_DIR HOME_DIR FAKEBIN_DIR <<EOF
$rec
EOF
add_gh_mock "$FAKEBIN_DIR" 0
gh_log="$CASE_DIR/gh-axi.log"
out=$(run_check "$HOME_DIR" "$FAKEBIN_DIR" "$gh_log" "$id" "https://github.com/digio-nz/fcdispatch/pull/99")
status=$?
expect_code 0 "$status" "issue-no: fm-pr-check.sh should succeed"
assert_contains "$out" "armed: state/$id.check.sh" "issue-no: fm-pr-check.sh did not report armed"
[ -f "$gh_log" ] || : > "$gh_log"
assert_no_grep "api graphql" "$gh_log" "issue-no: no issue= still made a board call"
pass "fm-pr-check.sh makes no board call at all when the task meta carries no issue="

# --- (c) a failing board does not fail fm-pr-check.sh ----------------------
id=pr-check-issue-fails
rec=$(make_case issue-fails "$id" 1)
IFS='|' read -r CASE_DIR HOME_DIR FAKEBIN_DIR <<EOF
$rec
EOF
add_gh_mock "$FAKEBIN_DIR" 1
gh_log="$CASE_DIR/gh-axi.log"
out=$(run_check "$HOME_DIR" "$FAKEBIN_DIR" "$gh_log" "$id" "https://github.com/digio-nz/fcdispatch/pull/99")
status=$?
expect_code 0 "$status" "issue-fails: a failing board must not fail fm-pr-check.sh"
assert_contains "$out" "armed: state/$id.check.sh" "issue-fails: fm-pr-check.sh did not report armed despite the board failure"
assert_grep "api graphql" "$gh_log" "issue-fails: the board move was never even attempted"
pass "fm-pr-check.sh's board move is strictly fail-open: a board/graphql failure never fails PR recording"

exit 0
