#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh's optional `--issue <n>` board-move hook
# (AGENTS.md section 7 / bin/fm-board.sh): a successful ship spawn carrying
# --issue makes one fail-open `bin/fm-board.sh move <n> Building` call as its
# very last step.
#
# These drive a real ship spawn to completion with a fake tmux pane and a real
# isolated git worktree (the same fixture shape as
# tests/fm-spawn-dispatch-profile.test.sh), and a fake `gh` so the REAL
# bin/fm-board.sh runs end to end against a mock board instead of a mocked
# fm-board.sh - this is the actual wiring under test, not a stand-in for it.
# fm-board resolves cards through `gh api graphql`; the fixture worktree has no
# GitHub origin, so fm-spawn cannot derive a --repo and fm-board takes its
# board page-scan path (the mock answers both paths regardless).
#
# Matrix:
#   (a) --issue on a successful ship spawn moves the card through fm-board.sh
#   (b) omitting --issue makes no board call at all
#   (c) a failing board (graphql error) does not fail the spawn
#   (d) --issue is refused (exit 1, before any spawn side effect) on --scout,
#       --secondmate, and batch dispatch
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-issue-board)

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window|send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  cat > "$fakebin/timeout" <<'SH'
#!/usr/bin/env bash
shift
exec "$@"
SH
  chmod +x "$fakebin/timeout"
  printf '%s\n' "$fakebin"
}

# gh (graphql) mock answering a minimal one-card board (project 2, owner
# digio-nz, a "Status" field with Inbox/Building options, one card for issue 42
# in Inbox) and logging every invocation. It answers both fm-board lookup paths
# (projectItems and the board page-scan) and the move mutation. Any other gh use
# is a benign exit 0 so it never breaks the spawn. Args: fakebin fail-mode(0/1)
add_gh_mock() {
  local fakebin=$1 fail=$2
  cat > "$fakebin/gh" <<SH
#!/usr/bin/env bash
log="\${FM_TEST_GH_AXI_LOG:-/dev/null}"
printf 'gh %s\n' "\$*" >> "\$log"
fail=$fail
SH
  cat >> "$fakebin/gh" <<'SH'
[ "$1 $2" = "api graphql" ] || exit 0
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
  *"items(first:100"*)
    printf 'page=false%s\n' "$tab"
    printf 'item=ITEM-42%sIssue%s42%sdigio-nz/fcdispatch%sInbox\n' "$tab" "$tab" "$tab" "$tab"
    printf 'cost=1\n'
    exit 0 ;;
  *)
    printf 'project=PVT_TEST\nfield=PVTSSF_STATUS\n'
    printf 'option=Inbox%sopt-inbox\n' "$tab"
    printf 'option=Building%sopt-building\n' "$tab"
    printf 'cost=1\n'
    exit 0 ;;
esac
SH
  chmod +x "$fakebin/gh"
}

make_spawn_case() {
  local name=$1 case_dir home proj wt fakebin id=$2
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf '%s\n' claude > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  fm_test_spawn_brief "$home" "$id"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

read_case_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

run_spawn() {
  local home=$1 wt=$2 fakebin=$3 gh_log=$4
  shift 4
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    CLAUDE_CONFIG_DIR='' FM_TEST_GH_AXI_LOG="$gh_log" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

run_ship_spawn() {
  run_spawn "$@" --mode no-mistakes --yolo off
}

# --- (a) --issue on a successful spawn moves the card through fm-board.sh ---
id=issue-yes-z1
rec=$(make_spawn_case issue-yes "$id")
read_case_record "$rec"
add_gh_mock "$FAKEBIN_DIR" 0
gh_log="$CASE_DIR/gh-axi.log"
out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$gh_log" "$id" "$PROJ_DIR" --issue 42)
status=$?
expect_code 0 "$status" "issue-yes: spawn should succeed"
assert_contains "$out" "spawned $id harness=claude" "issue-yes: spawn did not report success"
[ -s "$gh_log" ] || fail "issue-yes: --issue did not trigger any board call"
assert_grep "updateProjectV2ItemFieldValue" "$gh_log" \
  "issue-yes: fm-board.sh did not issue a move mutation"
assert_grep "option=opt-building" "$gh_log" \
  "issue-yes: fm-board.sh did not target the Building option"
pass "fm-spawn --issue triggers a real fm-board.sh move to Building on a successful ship spawn"

assert_grep "issue=42" "$HOME_DIR/state/$id.meta" \
  "issue-yes: --issue was not persisted onto the task meta"
pass "fm-spawn --issue persists issue=<n> onto state/<id>.meta"

# --- (b) omitting --issue makes no gh-axi call at all, and no meta line ----
id=issue-no-z1
rec=$(make_spawn_case issue-no "$id")
read_case_record "$rec"
add_gh_mock "$FAKEBIN_DIR" 0
gh_log="$CASE_DIR/gh-axi.log"
out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$gh_log" "$id" "$PROJ_DIR")
status=$?
expect_code 0 "$status" "issue-no: spawn should succeed"
assert_contains "$out" "spawned $id harness=claude" "issue-no: spawn did not report success"
[ -f "$gh_log" ] || : > "$gh_log"
assert_no_grep "api graphql" "$gh_log" "issue-no: omitting --issue still made a board call"
assert_no_grep "issue=" "$HOME_DIR/state/$id.meta" \
  "issue-no: omitting --issue still wrote an issue= line onto the task meta"
pass "fm-spawn without --issue makes no board call and persists no issue= line"

# --- (c) a failing board (bad gh-axi) does not fail the spawn --------------
id=issue-fails-z1
rec=$(make_spawn_case issue-fails "$id")
read_case_record "$rec"
add_gh_mock "$FAKEBIN_DIR" 1
gh_log="$CASE_DIR/gh-axi.log"
out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$gh_log" "$id" "$PROJ_DIR" --issue 42)
status=$?
expect_code 0 "$status" "issue-fails: a failing board must not fail the spawn"
assert_contains "$out" "spawned $id harness=claude" "issue-fails: spawn did not report success despite the board failure"
[ -s "$gh_log" ] || fail "issue-fails: gh-axi was never even attempted"
pass "fm-spawn --issue is strictly fail-open: a board/gh-axi failure never fails the spawn"

# --- (d) --issue is refused on --scout, --secondmate, and batch ------------
id=issue-scout-z1
rec=$(make_spawn_case issue-scout "$id")
read_case_record "$rec"
out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" /dev/null "$id" "$PROJ_DIR" --scout --issue 42)
status=$?
[ "$status" -ne 0 ] || fail "issue-scout: --issue with --scout should be refused"
assert_contains "$out" "--issue applies only to ship spawns" "issue-scout: wrong/missing refusal message"
pass "fm-spawn refuses --issue on a --scout spawn"

id2=issue-secondmate-z1
out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" /dev/null "$id2" --secondmate --issue 42)
status=$?
[ "$status" -ne 0 ] || fail "issue-secondmate: --issue with --secondmate should be refused"
assert_contains "$out" "--issue applies only to ship spawns" "issue-secondmate: wrong/missing refusal message"
pass "fm-spawn refuses --issue on a --secondmate spawn"

out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" /dev/null \
  "batch-a-z1=$PROJ_DIR" "batch-b-z2=$PROJ_DIR" --issue 42)
status=$?
[ "$status" -ne 0 ] || fail "issue-batch: --issue with batch dispatch should be refused"
assert_contains "$out" "batch dispatch (id=repo pairs) does not support it" "issue-batch: wrong/missing refusal message"
pass "fm-spawn refuses --issue on batch dispatch"

id3=issue-relaunch-z1
out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" /dev/null "$id3" --relaunch --issue 42)
status=$?
[ "$status" -ne 0 ] || fail "issue-relaunch: --issue with --relaunch should be refused"
assert_contains "$out" "--issue applies only to a fresh ship spawn" "issue-relaunch: wrong/missing refusal message"
pass "fm-spawn refuses --issue on --relaunch"

exit 0
