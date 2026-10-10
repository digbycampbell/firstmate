#!/usr/bin/env bash
# End-to-end regression for the fleet process through the real spawn path.
#
# A project registered +fleet-process sits under an organisation Branch Naming
# ruleset that refuses fm/<task-id> branches. These tests scaffold the brief
# with bin/fm-brief.sh, launch it with bin/fm-spawn.sh on a fake terminal and a
# real pooled worktree, and read the task record the spawn publishes: a fleet
# project's issue ship records branch=fm-issue-<n>, issue=<n>, and
# process=fleet, while a plain project still records branch=fm/<task-id>.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-fleet-process)

make_case() {  # <name> <id> <registry-line>
  local name=$1 id=$2 registry=$3 case_dir home project origin pool fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  project="$case_dir/project"
  origin="$case_dir/origin.git"
  pool="$case_dir/pool"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  printf '%s\n' "$registry" > "$home/data/projects.md"
  touch "$home/state/.last-watcher-beat"
  git init --quiet -b main "$project"
  printf 'base\n' > "$project/README.md"
  git -C "$project" add README.md
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  git clone --quiet --bare "$project" "$origin"
  git -C "$project" remote add origin "file://$origin"
  git -C "$project" worktree add --quiet --detach "$pool" "$(git -C "$project" rev-parse HEAD)"
  printf '%s\n' "$home|$project|$pool|$fakebin"
}

read_case_record() {
  IFS='|' read -r HOME_DIR PROJECT_DIR POOL_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

# Scaffold a real brief and fill its two task subsections, as firstmate does.
scaffold_brief() {  # <id> <fm-brief args...>
  local id=$1 brief
  shift
  FM_HOME="$HOME_DIR" "$ROOT/bin/fm-brief.sh" "$id" project "$@" >/dev/null \
    || fail "fm-brief.sh could not scaffold $id"
  brief="$HOME_DIR/data/$id/brief.md"
  sed -i -e 's/{TASK}/Fix the thing./' -e 's/{FIRSTMATE_SPEC}/Ship it./' "$brief"
}

# assert_line <line> <file> <msg>: the file must hold exactly this whole line.
assert_line() {
  grep -qxF -- "$1" "$2" || fail "$3"
}

run_spawn() {  # <id> <fm-spawn args...>
  local id=$1
  shift
  fm_test_run_spawn "$HOME_DIR" "$POOL_DIR" "$FAKEBIN_DIR" "$id" "$PROJECT_DIR" "$@"
}

test_fleet_project_issue_ship_records_its_issue_branch() {
  local rec id out status meta brief
  id='fleet-issue-r1'
  rec=$(make_case fleet-issue "$id" '- project [no-mistakes +fleet-process] - fixture (added 2026-01-01)')
  read_case_record "$rec"
  scaffold_brief "$id" --mode no-mistakes --fleet-process --issue 42
  brief="$HOME_DIR/data/$id/brief.md"
  assert_line 'Delivery contract: mode=no-mistakes process=fleet' "$brief" \
    "the fleet brief does not record process=fleet on its contract line"
  assert_line 'Ship branch: fm-issue-42' "$brief" "the fleet brief does not name the issue branch"
  assert_grep 'work.ts branch 42 --builder fm --create' "$brief" \
    "the fleet brief does not create its branch with work.ts"
  out=$(run_spawn "$id" --mode no-mistakes --yolo off --issue 42)
  status=$?
  expect_code 0 "$status" "a fleet-process issue ship should launch"$'\n'"$out"
  meta="$HOME_DIR/state/$id.meta"
  assert_line 'branch=fm-issue-42' "$meta" "the spawn did not record the issue branch"
  assert_line 'issue=42' "$meta" "the spawn did not record the linked issue"
  assert_line 'process=fleet' "$meta" "the spawn did not record the fleet process"
  ! grep -q '^branch=fm/' "$meta" || fail "the spawn recorded an fm/<task-id> branch the ruleset refuses"
  pass "a fleet-process issue ship launches on fm-issue-<n> and records issue= and process=fleet"
}

test_fleet_project_refuses_an_fm_branch() {
  local rec id out status
  id='fleet-plain-r1'
  rec=$(make_case fleet-plain "$id" '- project [no-mistakes +fleet-process] - fixture (added 2026-01-01)')
  read_case_record "$rec"
  scaffold_brief "$id" --mode no-mistakes
  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "an fm/<task-id> ship launched on a fleet-process project"
  assert_contains "$out" "refuses to create branch 'fm/$id'" "the refusal did not name the refused branch"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "a refused fleet spawn published task metadata"
  pass "a fleet-process project refuses an fm/<task-id> ship before launch"
}

test_plain_project_keeps_the_fm_branch() {
  local rec id out status meta
  id='plain-ship-r1'
  rec=$(make_case plain "$id" '- project [no-mistakes] - fixture (added 2026-01-01)')
  read_case_record "$rec"
  scaffold_brief "$id" --mode no-mistakes
  assert_line "Delivery contract: mode=no-mistakes" "$HOME_DIR/data/$id/brief.md" \
    "a plain brief gained a process on its contract line"
  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "a plain ship should launch"$'\n'"$out"
  meta="$HOME_DIR/state/$id.meta"
  assert_line "branch=fm/$id" "$meta" "a plain ship did not keep its fm/<task-id> branch"
  ! grep -q '^process=' "$meta" || fail "a plain ship recorded a process"
  ! grep -q '^issue=' "$meta" || fail "a plain ship recorded a linked issue"
  pass "a plain project still ships on fm/<task-id> with no process recorded"
}

test_issue_branch_refuses_a_prefix() {
  local rec id out status
  id='plain-prefix-r1'
  rec=$(make_case plain-prefix "$id" '- project [no-mistakes] - fixture (added 2026-01-01)')
  read_case_record "$rec"
  scaffold_brief "$id" --mode no-mistakes --issue 7
  out=$(run_spawn "$id" --mode no-mistakes --yolo off --issue 7 --branch-prefix fix/)
  status=$?
  [ "$status" -ne 0 ] || fail "a spawn accepted --issue together with --branch-prefix"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "a refused prefix spawn published task metadata"
  pass "an issue-named ship refuses a branch prefix"
}

test_fleet_project_issue_ship_records_its_issue_branch
test_fleet_project_refuses_an_fm_branch
test_plain_project_keeps_the_fm_branch
test_issue_branch_refuses_a_prefix
