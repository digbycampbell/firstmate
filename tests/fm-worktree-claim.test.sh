#!/usr/bin/env bash
# Regression tests for the worktree double-allocation guard
# (bin/fm-worktree-claim-lib.sh, wired into fm-spawn.sh and fm-teardown.sh).
#
# The pool's default reservation is "a process is running in this tree", which is
# shorter than a firstmate task's life. A task whose agent has exited - paused
# awaiting a merge, stopped, or between relaunches - still owns its worktree and
# whatever work it has not landed, but the pool sees an idle tree and can hand
# the same slot to the next spawn. Observed twice in one home: once onto a paused
# task's worktree, once UNDER A RUNNING AGENT.
#
# These tests pin the structural guard that makes the collision impossible to act
# on however it arises: before spawning onto a worktree, and before cleanup
# resets one, the path is cross-checked against every live task's recorded
# worktree in this home.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-worktree-claim)

# A fake tmux whose pane reports FM_FAKE_PANE_PATH as its cwd after `treehouse
# get`, so the fixture controls exactly which worktree the spawn resolves.
make_fakebin() {
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
  list-windows|has-session|new-session|new-window|kill-window|send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# make_case <name> builds a home, a project with one pooled worktree, and the
# fake terminal/pool that hands that worktree out.
make_case() {
  local name=$1 case_dir
  case_dir="$TMP_ROOT/$name"
  CASE_HOME="$case_dir/home"
  CASE_PROJECT="$case_dir/project"
  CASE_WT="$case_dir/pool-slot"
  CASE_FAKEBIN=$(make_fakebin "$case_dir/fake")
  mkdir -p "$CASE_HOME/data" "$CASE_HOME/projects" "$CASE_HOME/state" "$CASE_HOME/config"
  printf 'codex\n' > "$CASE_HOME/config/crew-harness"
  touch "$CASE_HOME/state/.last-watcher-beat"
  fm_git_worktree "$CASE_PROJECT" "$CASE_WT" "pool-$name"
}

seed_brief() {
  local id=$1
  mkdir -p "$CASE_HOME/data/$id"
  printf 'brief for %s\n' "$id" > "$CASE_HOME/data/$id/brief.md"
}

run_spawn() {
  local id=$1
  FM_ROOT_OVERRIDE='' FM_HOME="$CASE_HOME" \
    FM_STATE_OVERRIDE="$CASE_HOME/state" FM_DATA_OVERRIDE="$CASE_HOME/data" \
    FM_PROJECTS_OVERRIDE="$CASE_HOME/projects" FM_CONFIG_OVERRIDE="$CASE_HOME/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$CASE_WT" \
    PATH="$CASE_FAKEBIN:$PATH" \
    "$SPAWN" "$id" "$CASE_PROJECT" --mode no-mistakes --yolo off 2>&1
}

run_teardown() {
  local id=$1
  shift
  FM_ROOT_OVERRIDE='' FM_HOME="$CASE_HOME" \
    FM_STATE_OVERRIDE="$CASE_HOME/state" FM_DATA_OVERRIDE="$CASE_HOME/data" \
    FM_PROJECTS_OVERRIDE="$CASE_HOME/projects" FM_CONFIG_OVERRIDE="$CASE_HOME/config" \
    FM_TEARDOWN_GUARD_DONE=1 TMUX="fake,1,0" \
    PATH="$CASE_FAKEBIN:$PATH" \
    "$TEARDOWN" "$id" "$@" 2>&1
}

# The collision shape as observed: a live task's metadata still records the pool
# slot the pool is about to hand out again.
record_live_task() {
  local id=$1
  fm_write_meta "$CASE_HOME/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$CASE_WT" \
    "project=$CASE_PROJECT" \
    "harness=codex" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off"
}

test_spawn_refuses_a_slot_a_live_task_still_holds() {
  local out status
  make_case spawn-collision
  record_live_task paused-holder
  seed_brief newcomer

  out=$(run_spawn newcomer)
  status=$?

  expect_code 1 "$status" "spawn onto a live task's worktree should fail"
  assert_contains "$out" "paused-holder" "the refusal did not name the colliding task"
  assert_contains "$out" "$CASE_WT" "the refusal did not name the contested worktree"
  [ ! -f "$CASE_HOME/state/newcomer.meta" ] \
    || fail "spawn recorded metadata for a task it refused to launch"
  assert_grep "worktree=$CASE_WT" "$CASE_HOME/state/paused-holder.meta" \
    "the holder's recorded worktree was disturbed by the refused spawn"
  pass "spawn refuses a pool slot another live task still records as its worktree"
}

# Control: the same fixture with no colliding metadata must still spawn normally,
# so the guard cannot pass by refusing everything.
test_spawn_still_allocates_an_unclaimed_slot() {
  local out status
  make_case spawn-control
  seed_brief lone

  out=$(run_spawn lone)
  status=$?

  expect_code 0 "$status" "spawn onto an unclaimed worktree should succeed"
  assert_contains "$out" "spawned lone" "spawn did not report success"
  assert_grep "worktree=$CASE_WT" "$CASE_HOME/state/lone.meta" \
    "meta did not record the allocated worktree"
  pass "spawn still allocates a pool slot no live task claims"
}

# The 2026-08-21 de-fused-by-hand shape: the collision is noticed, the newcomer's
# metadata now records the contested path, and cleaning up the older task would
# reset the worktree out from under it.
test_teardown_refuses_a_worktree_another_live_task_records() {
  local out status
  make_case teardown-collision
  record_live_task first-owner
  record_live_task second-owner

  out=$(run_teardown first-owner)
  status=$?

  expect_code 1 "$status" "teardown of a contested worktree should fail"
  assert_contains "$out" "second-owner" "the refusal did not name the colliding task"
  assert_contains "$out" "$CASE_WT" "the refusal did not name the contested worktree"
  [ -f "$CASE_HOME/state/first-owner.meta" ] \
    || fail "teardown removed the task's metadata despite refusing"
  [ -d "$CASE_WT" ] || fail "teardown removed a worktree another live task records"
  pass "teardown refuses to reset a worktree another live task records"
}

# A collision is a bug to investigate, not work to discard, so the discard escape
# hatch must not open this door.
test_teardown_refusal_survives_force() {
  local out status
  make_case teardown-force
  record_live_task first-owner
  record_live_task second-owner

  out=$(run_teardown first-owner --force)
  status=$?

  expect_code 1 "$status" "--force teardown of a contested worktree should still fail"
  assert_contains "$out" "second-owner" "the forced refusal did not name the colliding task"
  [ -d "$CASE_WT" ] || fail "--force teardown removed a contested worktree"
  pass "the teardown collision refusal is not bypassed by --force"
}

test_spawn_refuses_a_slot_a_live_task_still_holds
test_spawn_still_allocates_an_unclaimed_slot
test_teardown_refuses_a_worktree_another_live_task_records
test_teardown_refusal_survives_force
