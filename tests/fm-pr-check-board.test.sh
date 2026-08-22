#!/usr/bin/env bash
# Tests for bin/fm-pr-check.sh's optional board-move courtesy: when a task's
# meta carries issue= (persisted at spawn time by fm-spawn.sh's --issue
# flag), recording a PR also makes one fail-open
# `bin/fm-board.sh move <issue> "PR ready"` call, after the PR is already
# durably recorded and the merge poll already armed.
#
# These run the REAL fm-pr-check.sh and the REAL fm-board.sh together (FM_ROOT
# resolves to this repo) with only `gh-axi` mocked, so this is the actual
# wiring under test rather than a stand-in for it.
#
# Matrix:
#   (a) a task meta carrying issue=42 makes fm-pr-check.sh move that card to
#       "PR ready"
#   (b) a task meta with no issue= makes no board call at all, and
#       fm-pr-check.sh's own result is unaffected
#   (c) a failing board (bad gh-axi) does not fail fm-pr-check.sh
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PR_CHECK="$ROOT/bin/fm-pr-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-check-board)

# gh-axi mock answering a minimal one-card board (project 2, owner digio-nz,
# one "Status" field with Inbox/PR ready options, one card for issue 42) and
# logging every invocation. Args: fakebin fail-mode(0/1)
add_gh_axi_mock() {
  local fakebin=$1 fail=$2
  cat > "$fakebin/gh-axi" <<SH
#!/usr/bin/env bash
log="\${FM_TEST_GH_AXI_LOG:-/dev/null}"
printf '%s\n' "\$*" >> "\$log"
if [ "$fail" = 1 ]; then
  echo "error: simulated gh-axi failure" >&2
  exit 1
fi
case "\$1 \$2" in
  "project view") printf 'project:\n  id: PVT_TEST\n'; exit 0 ;;
  "project field-list")
    cat <<'EOF'
count: 1 of 1 total
fields[1]:
  - id: PVTSSF_STATUS
    name: Status
    type: ProjectV2SingleSelectField
    options: "Inbox:opt-inbox,PR ready:opt-prready"
EOF
    exit 0 ;;
  "project item-list")
    cat <<'EOF'
count: 1 of 1 total
items[1]{id,title,type,number,repository,status}:
  ITEM-42,"Test card",Issue,42,digio-nz/fcdispatch,Inbox
help[2]:
  Run \`gh-axi project item-add 2 --url <issue-or-pr-url> --owner digio-nz\` to add an item
EOF
    exit 0 ;;
  "project item-edit") exit 0 ;;
esac
exit 9
SH
  chmod +x "$fakebin/gh-axi"
}

# A fresh sandbox: an FM_HOME with a task meta, and a fakebin with gh-axi
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
add_gh_axi_mock "$FAKEBIN_DIR" 0
gh_log="$CASE_DIR/gh-axi.log"
out=$(run_check "$HOME_DIR" "$FAKEBIN_DIR" "$gh_log" "$id" "https://github.com/digio-nz/fcdispatch/pull/99")
status=$?
expect_code 0 "$status" "issue-yes: fm-pr-check.sh should succeed"
assert_contains "$out" "armed: state/$id.check.sh" "issue-yes: fm-pr-check.sh did not report armed"
[ -s "$gh_log" ] || fail "issue-yes: issue= on meta did not trigger any gh-axi call"
assert_grep "project item-edit --id ITEM-42" "$gh_log" \
  "issue-yes: fm-board.sh did not move the discovered card"
assert_grep "single-select-option-id opt-prready" "$gh_log" \
  "issue-yes: fm-board.sh did not target the PR ready option"
pass "fm-pr-check.sh moves the linked issue's card to PR ready when meta carries issue="

# --- (b) no issue= on the task meta makes no board call at all -------------
id=pr-check-issue-no
rec=$(make_case issue-no "$id" 0)
IFS='|' read -r CASE_DIR HOME_DIR FAKEBIN_DIR <<EOF
$rec
EOF
add_gh_axi_mock "$FAKEBIN_DIR" 0
gh_log="$CASE_DIR/gh-axi.log"
out=$(run_check "$HOME_DIR" "$FAKEBIN_DIR" "$gh_log" "$id" "https://github.com/digio-nz/fcdispatch/pull/99")
status=$?
expect_code 0 "$status" "issue-no: fm-pr-check.sh should succeed"
assert_contains "$out" "armed: state/$id.check.sh" "issue-no: fm-pr-check.sh did not report armed"
[ ! -s "$gh_log" ] || fail "issue-no: no issue= still called gh-axi (got: $(cat "$gh_log"))"
pass "fm-pr-check.sh makes no board call at all when the task meta carries no issue="

# --- (c) a failing board does not fail fm-pr-check.sh ----------------------
id=pr-check-issue-fails
rec=$(make_case issue-fails "$id" 1)
IFS='|' read -r CASE_DIR HOME_DIR FAKEBIN_DIR <<EOF
$rec
EOF
add_gh_axi_mock "$FAKEBIN_DIR" 1
gh_log="$CASE_DIR/gh-axi.log"
out=$(run_check "$HOME_DIR" "$FAKEBIN_DIR" "$gh_log" "$id" "https://github.com/digio-nz/fcdispatch/pull/99")
status=$?
expect_code 0 "$status" "issue-fails: a failing board must not fail fm-pr-check.sh"
assert_contains "$out" "armed: state/$id.check.sh" "issue-fails: fm-pr-check.sh did not report armed despite the board failure"
[ -s "$gh_log" ] || fail "issue-fails: gh-axi was never even attempted"
pass "fm-pr-check.sh's board move is strictly fail-open: a board/gh-axi failure never fails PR recording"

exit 0
