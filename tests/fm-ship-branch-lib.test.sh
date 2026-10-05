#!/usr/bin/env bash
# Behavior tests for bin/fm-ship-branch-lib.sh: how a ship branch is named from
# --issue, --issue-suffix, --chore, and --branch-prefix, and which names the
# organisation Branch Naming ruleset of a +fleet-process project lets be created.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-ship-branch-lib.sh
. "$ROOT/bin/fm-ship-branch-lib.sh"

# The accepted and refused names are the ones the captain listed for the
# ruleset, plus the legacy firstmate shape it now refuses.
test_org_pattern_matches_the_agreed_names() {
  local name
  for name in fm-issue-1596 fm-issue-1596-r2 fm-issue-1596b fm-chore-bump-node \
    issue-12 claude/fm-issue-1302-9u07i7 process-deploy dependabot/npm/x revert-7-fm-issue-1 \
    gh-readonly-queue/main/pr-1-abc; do
    fm_ship_branch_org_allowed "$name" || fail "the ruleset pattern refused the accepted name $name"
  done
  for name in fm/fm-fleet-branch-rules fm/issue fm-issue-x fm-chore- fm-chore-Bump fix/thing main-work; do
    if fm_ship_branch_org_allowed "$name"; then
      fail "the ruleset pattern accepted the refused name $name"
    fi
  done
  pass "the organisation pattern accepts the agreed branch names and refuses fm/<task-id>"
}

test_resolver_names_each_shape() {
  local out
  out=$(fm_ship_branch_resolve t1 1596 '' '' fm/ 0) || fail "an issue branch did not resolve"
  [ "$out" = fm-issue-1596 ] || fail "an issue resolved to $out"
  out=$(fm_ship_branch_resolve t1 1596 -r2 '' fm/ 0) || fail "a suffixed issue branch did not resolve"
  [ "$out" = fm-issue-1596-r2 ] || fail "a suffixed issue resolved to $out"
  out=$(fm_ship_branch_resolve t1 1596 b '' fm/ 0) || fail "a lettered retry did not resolve"
  [ "$out" = fm-issue-1596b ] || fail "a lettered retry resolved to $out"
  out=$(fm_ship_branch_resolve t1 '' '' bump-node fm/ 0) || fail "a chore branch did not resolve"
  [ "$out" = fm-chore-bump-node ] || fail "a chore resolved to $out"
  out=$(fm_ship_branch_resolve t1 '' '' '' fm/ 0) || fail "a legacy branch did not resolve"
  [ "$out" = fm/t1 ] || fail "a legacy ship resolved to $out"
  out=$(fm_ship_branch_resolve t1 '' '' '' fix/ 1) || fail "a prefixed branch did not resolve"
  [ "$out" = fix/t1 ] || fail "a prefixed ship resolved to $out"
  out=$(fm_ship_branch_resolve t1 61 '' '' fm/ 0 plan-issue-57) || fail "a one-branch Phase did not resolve"
  [ "$out" = plan-issue-57 ] || fail "a one-branch Phase resolved to $out"
  fm_ship_branch_org_allowed "$out" || fail "the ruleset pattern refused a Plan's branch"
  pass "the resolver names issue, retry, chore, Plan, and prefixed ship branches"
}

test_resolver_refuses_contradictions_and_bad_names() {
  local out
  out=$(fm_ship_branch_resolve t1 7 '' tidy fm/ 0 2>&1) && fail "an issue and a chore were accepted together"
  assert_contains "$out" "not both" "the issue-and-chore refusal did not say why"
  out=$(fm_ship_branch_resolve t1 '' -r2 '' fm/ 0 2>&1) && fail "a suffix without an issue was accepted"
  assert_contains "$out" "--issue-suffix applies only with --issue" "the orphan suffix refusal did not name the flag"
  out=$(fm_ship_branch_resolve t1 '' '' tidy fix/ 1 2>&1) && fail "a chore with a prefix was accepted"
  assert_contains "$out" "drop --branch-prefix" "the chore-and-prefix refusal did not name the fix"
  out=$(fm_ship_branch_resolve t1 '' '' Bump_Node fm/ 0 2>&1) && fail "a chore slug the ruleset refuses was accepted"
  assert_contains "$out" "--chore must be lowercase" "the bad-slug refusal did not describe a valid slug"
  out=$(fm_ship_branch_resolve t1 7 _r2 '' fm/ 0 2>&1) && fail "a suffix the ruleset refuses was accepted"
  assert_contains "$out" "--issue-suffix must be" "the bad-suffix refusal did not describe a valid suffix"
  out=$(fm_ship_branch_resolve t1 0 '' '' fm/ 0 2>&1) && fail "issue 0 was accepted"
  out=$(fm_ship_branch_resolve t1 12x '' '' fm/ 0 2>&1) && fail "a non-numeric issue was accepted"
  assert_contains "$out" "positive integer" "the bad-issue refusal did not describe a valid issue"
  out=$(fm_ship_branch_resolve t1 '' '' '' fm/ 0 plan-issue-57 2>&1) && fail "a Plan branch without its Phase was accepted"
  assert_contains "$out" "--plan-branch needs --issue <n>" "the Phase-less refusal did not name the flag"
  out=$(fm_ship_branch_resolve t1 61 -r2 '' fm/ 0 plan-issue-57 2>&1) && fail "a Plan branch with a retry suffix was accepted"
  out=$(fm_ship_branch_resolve t1 61 '' '' fm/ 0 feature-57 2>&1) && fail "a non-Plan branch was accepted as a Plan's"
  assert_contains "$out" "plan-issue-<n>" "the bad Plan branch refusal did not describe a valid one"
  out=$(fm_ship_branch_resolve t1 61 '' '' fix/ 1 plan-issue-57 2>&1) && fail "a Plan branch with a prefix was accepted"
  pass "the resolver refuses contradictory flags and names the ruleset would refuse"
}

test_require_org_shape_names_the_way_forward() {
  local out
  fm_ship_branch_require_org_shape fm-spawn.sh fcdispatch fm-issue-9 || fail "an issue branch was refused"
  out=$(fm_ship_branch_require_org_shape fm-spawn.sh fcdispatch fm/t1 2>&1) \
    && fail "a legacy fm/ branch was accepted on a fleet-process project"
  assert_contains "$out" "fcdispatch is registered +fleet-process" "the refusal did not name the project binding"
  assert_contains "$out" "open a Task issue first" "the refusal did not name the Task-issue path"
  assert_contains "$out" "--chore <slug>" "the refusal did not name the chore path"
  pass "a fleet-process refusal names the Task-issue and chore paths"
}

test_org_pattern_matches_the_agreed_names
test_resolver_names_each_shape
test_resolver_refuses_contradictions_and_bad_names
test_require_org_shape_names_the_way_forward

echo "all fm-ship-branch-lib tests passed"
