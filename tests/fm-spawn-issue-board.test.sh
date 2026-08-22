#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh's optional `--issue <n>` board-move hook
# (AGENTS.md section 7 / bin/fm-board.sh): a successful ship spawn carrying
# --issue makes one fail-open `bin/fm-board.sh move <n> Building` call as its
# very last step.
#
# These drive a real ship spawn to completion with a fake tmux pane and a real
# isolated git worktree (the same fixture shape as
# tests/fm-spawn-dispatch-profile.test.sh), and a fake `gh-axi` so the REAL
# bin/fm-board.sh runs end to end against a mock board instead of a mocked
# fm-board.sh - this is the actual wiring under test, not a stand-in for it.
#
# Matrix:
#   (a) --issue on a successful ship spawn calls gh-axi through fm-board.sh
#   (b) omitting --issue makes no gh-axi call at all
#   (c) a failing gh-axi (board failure) does not fail the spawn
#   (d) --issue is refused (exit 1, before any spawn side effect) on --scout,
#       --secondmate, and batch dispatch
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

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

# gh-axi mock answering a minimal one-card board (project 2, owner digio-nz,
# a single "Status" field with Inbox/Building options, one card for issue 42)
# and logging every invocation. Args: fakebin fail-mode(0/1)
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
    options: "Inbox:opt-inbox,Building:opt-building"
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
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
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

# --- (a) --issue on a successful spawn calls gh-axi through fm-board.sh -----
id=issue-yes-z1
rec=$(make_spawn_case issue-yes "$id")
read_case_record "$rec"
add_gh_axi_mock "$FAKEBIN_DIR" 0
gh_log="$CASE_DIR/gh-axi.log"
out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$gh_log" "$id" "$PROJ_DIR" --issue 42)
status=$?
expect_code 0 "$status" "issue-yes: spawn should succeed"
assert_contains "$out" "spawned $id harness=claude" "issue-yes: spawn did not report success"
[ -s "$gh_log" ] || fail "issue-yes: --issue did not trigger any gh-axi call"
assert_grep "project item-edit --id ITEM-42" "$gh_log" \
  "issue-yes: fm-board.sh did not move the discovered card"
assert_grep "single-select-option-id opt-building" "$gh_log" \
  "issue-yes: fm-board.sh did not target the Building option"
pass "fm-spawn --issue triggers a real fm-board.sh move to Building on a successful ship spawn"

# --- (b) omitting --issue makes no gh-axi call at all -----------------------
id=issue-no-z1
rec=$(make_spawn_case issue-no "$id")
read_case_record "$rec"
add_gh_axi_mock "$FAKEBIN_DIR" 0
gh_log="$CASE_DIR/gh-axi.log"
out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$gh_log" "$id" "$PROJ_DIR")
status=$?
expect_code 0 "$status" "issue-no: spawn should succeed"
assert_contains "$out" "spawned $id harness=claude" "issue-no: spawn did not report success"
[ ! -s "$gh_log" ] || fail "issue-no: omitting --issue still called gh-axi (got: $(cat "$gh_log"))"
pass "fm-spawn without --issue makes no board call at all"

# --- (c) a failing board (bad gh-axi) does not fail the spawn --------------
id=issue-fails-z1
rec=$(make_spawn_case issue-fails "$id")
read_case_record "$rec"
add_gh_axi_mock "$FAKEBIN_DIR" 1
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

exit 0
