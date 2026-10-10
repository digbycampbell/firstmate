#!/usr/bin/env bash
# Firstmate-managed commits must carry a firstmate identity, and must not be
# able to carry the captain's.
#
# The regression this pins: a task worktree with no identity of its own let git
# synthesize the machine's personal address into a crewmate's commits, and
# nothing noticed until GitHub rejected the push with GH007 hours later. The
# three properties that make that structurally impossible are exercised here -
# per-worktree identity that does NOT leak into the shared clone config, a
# commit-time refusal, and a guard that fails closed when its own prerequisites
# are missing.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ID_BIN="$ROOT/bin/fm-git-identity.sh"

CAPTAIN_EMAIL='96467498+digbycampbell@users.noreply.github.com'
CAPTAIN_NAME='digbycampbell'

FAILED=0
TMP=""

# shellcheck disable=SC2329 # Registered by the EXIT trap below.
cleanup() {
  [ -n "$TMP" ] || return 0
  # The strip-hooks installer leaves its directory read-only on purpose.
  chmod -R u+w "$TMP" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

fail() {
  printf 'not ok - %s\n' "$1" >&2
  FAILED=1
}

pass() {
  printf 'ok - %s\n' "$1"
}

# A scratch parent clone configured exactly like the machine that produced the
# incident: the captain's own identity in the clone, plus one linked worktree
# standing in for a pooled task worktree.
make_fixture() {  # <dir>
  local dir=$1
  mkdir -p "$dir"
  git init -q "$dir/parent"
  git -C "$dir/parent" config user.email "$CAPTAIN_EMAIL"
  git -C "$dir/parent" config user.name "$CAPTAIN_NAME"
  git -C "$dir/parent" commit -q --allow-empty -m init
  git -C "$dir/parent" worktree add -q "$dir/wt" -b task >/dev/null 2>&1
}

commit_in() {  # <dir> <message>
  local dir=$1 msg=$2
  ( cd "$dir" && printf '%s\n' "$msg" >>"log.txt" && git add log.txt \
    && git commit -m "$msg" ) >/dev/null 2>&1
}

# Drop every identity key apply-worktree arms, leaving the worktree to fall back
# on whatever the machine's own configuration says.
strip_worktree_identity() {  # <worktree>
  local key
  for key in user.name user.email author.name author.email committer.name committer.email; do
    git -C "$1" config --worktree --unset-all "$key" 2>/dev/null || true
  done
}

# Reproduce dotfiles' path-routed identity: a global include whose file sets
# author.* and committer.*, which git ranks above user.* at every level.
install_global_author_override() {  # <dir>
  local file=$1/identity-override
  printf '[author]\n\tname = %s\n\temail = %s\n[committer]\n\tname = %s\n\temail = %s\n' \
    "$CAPTAIN_NAME" "$CAPTAIN_EMAIL" "$CAPTAIN_NAME" "$CAPTAIN_EMAIL" >"$file"
  git config --global include.path "$file"
}

remove_global_author_override() {
  git config --global --unset-all include.path 2>/dev/null || true
}

author_of() {  # <dir>
  git -C "$1" log -1 --format='%an <%ae>'
}

committer_of() {  # <dir>
  git -C "$1" log -1 --format='%cn <%ce>'
}

test_worktree_identity_does_not_leak_into_the_parent_clone() {
  local d="$TMP/isolation" before after
  make_fixture "$d"
  before=$(git -C "$d/parent" config --local --list | LC_ALL=C sort)

  "$ID_BIN" apply-worktree "$d/wt" --hooks-dir "$d/hooks" >/dev/null 2>&1 \
    || { fail "apply-worktree failed on a linked worktree"; return; }

  commit_in "$d/wt" "crew work" || { fail "could not commit in the armed worktree"; return; }
  [ "$(author_of "$d/wt")" = "Crewmate <crew@digio.nz>" ] \
    || fail "worktree commit author is $(author_of "$d/wt"), expected the crew identity"
  [ "$(committer_of "$d/wt")" = "Crewmate <crew@digio.nz>" ] \
    || fail "worktree commit committer is $(committer_of "$d/wt"), expected the crew identity"

  # The property that actually matters: the shared clone config the captain's
  # own commits read from is untouched apart from the mechanism switch.
  after=$(git -C "$d/parent" config --local --list | LC_ALL=C sort \
    | grep -v '^extensions\.worktreeconfig=' || true)
  before=$(printf '%s\n' "$before" | grep -v '^extensions\.worktreeconfig=' || true)
  [ "$before" = "$after" ] \
    || fail "arming a task worktree changed the parent clone's shared config"

  commit_in "$d/parent" "captain work" || { fail "could not commit in the parent clone"; return; }
  [ "$(author_of "$d/parent")" = "$CAPTAIN_NAME <$CAPTAIN_EMAIL>" ] \
    || fail "the captain's own commit in the parent clone became $(author_of "$d/parent")"

  pass "a task worktree's crew identity never reaches the parent clone or its commits"
}

test_commit_carrying_the_captain_identity_is_refused() {
  local d="$TMP/refuse" out before_count after_count
  make_fixture "$d"
  "$ID_BIN" apply-worktree "$d/wt" --hooks-dir "$d/hooks" >/dev/null 2>&1 \
    || { fail "apply-worktree failed"; return; }

  # Reproduce the incident state exactly: the worktree loses its own identity
  # and falls back to the machine's, which is the captain's private address.
  strip_worktree_identity "$d/wt"

  before_count=$(git -C "$d/wt" rev-list --count HEAD)
  out=$( ( cd "$d/wt" && printf 'x\n' >>log.txt && git add log.txt \
    && git commit -m "leaks the captain's address" ) 2>&1 )
  # shellcheck disable=SC2181 # the message is captured above, so the status is read separately
  if [ $? -eq 0 ]; then
    fail "a commit carrying the captain's address was accepted"
    return
  fi
  after_count=$(git -C "$d/wt" rev-list --count HEAD)
  [ "$before_count" = "$after_count" ] \
    || fail "the refused commit still landed on the branch"
  case $out in
    *"$CAPTAIN_EMAIL"*) : ;;
    *) fail "the refusal does not name the offending address: $out" ;;
  esac
  case $out in
    *'crew@digio.nz'*) : ;;
    *) fail "the refusal does not say which identity to use instead: $out" ;;
  esac
  case $out in
    *'noreply or personal address is never the fix'*) : ;;
    *) fail "the refusal does not rule out substituting a noreply address: $out" ;;
  esac
  case $out in
    *'apply-worktree <worktree> --hooks-dir <dir>'*)
      fail "the refusal still invites a hand-run apply-worktree with an arbitrary hooks dir: $out" ;;
  esac
  pass "a commit carrying the captain's address is refused at commit time, with a fix"
}

test_environment_identity_cannot_bypass_the_guard() {
  local d="$TMP/env" out
  make_fixture "$d"
  "$ID_BIN" apply-worktree "$d/wt" --hooks-dir "$d/hooks" >/dev/null 2>&1 \
    || { fail "apply-worktree failed"; return; }
  # Config is correct here; the wrong identity arrives through the environment,
  # which a config-only check would pass.
  out=$( ( cd "$d/wt" && printf 'y\n' >>log.txt && git add log.txt \
    && GIT_AUTHOR_NAME=$CAPTAIN_NAME GIT_AUTHOR_EMAIL=$CAPTAIN_EMAIL \
       git commit -m "env override" ) 2>&1 )
  # shellcheck disable=SC2181 # the message is captured above, so the status is read separately
  if [ $? -eq 0 ]; then
    fail "an environment-supplied captain identity bypassed the guard"
    return
  fi
  case $out in
    *"$CAPTAIN_EMAIL"*) pass "an environment-supplied identity is checked, not just config" ;;
    *) fail "the refusal does not name the environment-supplied address: $out" ;;
  esac
  # The 2026-10-04 reviewer case: the override is the cause, so the refusal
  # must say so and name the identity the worktree would commit as without it.
  case $out in
    *'GIT_AUTHOR_*/GIT_COMMITTER_* override'*'configured as Crewmate <crew@digio.nz>'*)
      pass "an override refusal names the override as the cause and the worktree's own identity" ;;
    *) fail "the refusal does not name the override as the cause: $out" ;;
  esac
}

test_global_author_override_cannot_change_the_crew_identity() {
  local d="$TMP/global-author"
  make_fixture "$d"
  install_global_author_override "$d"
  "$ID_BIN" apply-worktree "$d/wt" --hooks-dir "$d/hooks" >/dev/null 2>&1 \
    || { fail "apply-worktree failed under a global author.* override"; remove_global_author_override; return; }
  commit_in "$d/wt" "crew work" \
    || { fail "could not commit in a worktree armed under a global author.* override"; remove_global_author_override; return; }
  remove_global_author_override
  [ "$(author_of "$d/wt")" = "Crewmate <crew@digio.nz>" ] \
    || { fail "a global author.* override won: the crew commit is authored as $(author_of "$d/wt")"; return; }
  [ "$(committer_of "$d/wt")" = "Crewmate <crew@digio.nz>" ] \
    || { fail "a global committer.* override won: the crew commit is committed as $(committer_of "$d/wt")"; return; }
  pass "a global author.*/committer.* override cannot change an armed worktree's commit identity"
}

test_guard_resolves_author_config_as_git_does() {
  local d="$TMP/author-config" out before_count after_count
  make_fixture "$d"
  "$ID_BIN" apply-worktree "$d/wt" --hooks-dir "$d/hooks" >/dev/null 2>&1 \
    || { fail "apply-worktree failed"; return; }
  # An allowlisted user.* that git does NOT use for the commit, because a
  # global author.*/committer.* outranks it. A guard reading user.* alone
  # passes this; the commit still lands as the captain.
  strip_worktree_identity "$d/wt"
  git -C "$d/wt" config --worktree user.name Crewmate
  git -C "$d/wt" config --worktree user.email crew@digio.nz
  install_global_author_override "$d"
  before_count=$(git -C "$d/wt" rev-list --count HEAD)
  out=$( ( cd "$d/wt" && printf 'z\n' >>log.txt && git add log.txt \
    && git commit -m "author config override" ) 2>&1 )
  # shellcheck disable=SC2181 # the message is captured above, so the status is read separately
  if [ $? -eq 0 ]; then
    remove_global_author_override
    fail "a commit whose author.* config resolves to the captain was accepted as $(author_of "$d/wt")"
    return
  fi
  "$ID_BIN" verify-worktree "$d/wt" >/dev/null 2>&1 \
    && fail "verify-worktree reports a worktree armed when author.* config would win"
  remove_global_author_override
  after_count=$(git -C "$d/wt" rev-list --count HEAD)
  [ "$before_count" = "$after_count" ] \
    || fail "the refused commit still landed on the branch"
  case $out in
    *"refusing: this commit's author would be $CAPTAIN_NAME <$CAPTAIN_EMAIL>"*)
      pass "the guard resolves author.*/committer.* config the way git does" ;;
    *) fail "the refusal does not name the author.* identity git would use: $out" ;;
  esac
}

test_rearming_into_a_new_guard_dir_does_not_chain_guards() {
  local d="$TMP/rechain" rc
  make_fixture "$d"
  "$ID_BIN" apply-worktree "$d/wt" --hooks-dir "$d/guard-one" >/dev/null 2>&1 \
    || { fail "first apply-worktree failed"; return; }
  # Arming again under a hooksPath that already names another firstmate guard
  # (a re-arm into a new dir, or an inherited hooksPath) once chained the new
  # guard into the old one, and two guards exec'd each other forever.
  "$ID_BIN" apply-worktree "$d/wt" --hooks-dir "$d/guard-two" >/dev/null 2>&1 \
    || { fail "second apply-worktree failed"; return; }
  # Back to the first dir: guard-one now chains to guard-two, which chains to
  # guard-one.
  "$ID_BIN" apply-worktree "$d/wt" --hooks-dir "$d/guard-one" >/dev/null 2>&1 \
    || { fail "third apply-worktree failed"; return; }
  ( cd "$d/wt" && printf 'z\n' >>log.txt && git add log.txt \
    && timeout 20 git commit -qm "after re-arm" ) >/dev/null 2>&1
  rc=$?
  [ "$rc" -ne 124 ] || { fail "a commit after re-arming looped between two guards until killed"; return; }
  [ "$rc" -eq 0 ] || { fail "a commit after re-arming failed (exit $rc)"; return; }
  pass "re-arming into a new guard dir never chains one guard into another"
}

# The pane override bin/fm-spawn.sh exports into every worker: git there reads
# core.hooksPath from GIT_CONFIG_* and finds the AI-trailer strip directory.
pane_hooks_env() {  # <strip-hooks-dir> -> env assignments for env(1)
  printf '%s\n' GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath "GIT_CONFIG_VALUE_0=$1"
}

# Commit in <dir> under the pane override, killed after 20 seconds so a hook
# loop reads as exit 124 rather than hanging the suite.
commit_in_pane() {  # <dir> <strip-hooks-dir> <message>
  local dir=$1 strip=$2 msg=$3 assignments
  mapfile -t assignments < <(pane_hooks_env "$strip")
  ( cd "$dir" && printf '%s\n' "$msg" >>log.txt && git add log.txt \
    && env "${assignments[@]}" timeout 20 git commit -qm "$msg" ) >/dev/null 2>&1
}

test_arming_inside_a_worker_pane_does_not_chain_the_strip_hooks() {
  local d="$TMP/pane-arm" assignments chained repo_hooks rc
  make_fixture "$d"
  repo_hooks="$d/repo-hooks"
  mkdir -p "$repo_hooks"
  printf '#!/bin/sh\necho REPO-PRE-COMMIT >>%q\n' "$d/ran" >"$repo_hooks/pre-commit"
  chmod +x "$repo_hooks/pre-commit"
  git -C "$d/parent" config core.hooksPath "$repo_hooks"
  "$ROOT/bin/fm-git-strip-ai-trailers.sh" install "$d/strip" "$d/wt" >/dev/null 2>&1 \
    || { fail "installing the AI-trailer strip hooks failed"; return; }
  mapfile -t assignments < <(pane_hooks_env "$d/strip")
  # Arming from a worker pane, whose environment names the strip directory as
  # core.hooksPath, once recorded that directory as the repo's own hooks. Its
  # wrappers dispatch back to the worktree's hooks, which are the guard, so the
  # guard and the strip hooks exec'd each other on every commit.
  env "${assignments[@]}" "$ID_BIN" apply-worktree "$d/wt" --hooks-dir "$d/hooks" >/dev/null 2>&1 \
    || { fail "apply-worktree failed under the worker pane's hooks override"; return; }
  chained=$(git -C "$d/wt" config --worktree --get firstmate.chainedHooksPath 2>/dev/null || true)
  [ "$chained" = "$(cd "$repo_hooks" && pwd -P)" ] \
    || { fail "apply-worktree chained '$chained' instead of the repo's own hooks '$repo_hooks'"; return; }
  commit_in_pane "$d/wt" "$d/strip" "from the pane"
  rc=$?
  [ "$rc" -ne 124 ] || { fail "a commit in an armed worker pane looped between the guard and the strip hooks until killed"; return; }
  [ "$rc" -eq 0 ] || { fail "a commit in an armed worker pane failed (exit $rc)"; return; }
  grep -q REPO-PRE-COMMIT "$d/ran" 2>/dev/null \
    || { fail "the repo's own pre-commit hook did not run in an armed worker pane"; return; }
  pass "arming inside a worker pane chains the repo's own hooks, not the pane override"
}

test_a_fleet_hooks_dir_is_never_chained() {
  local d="$TMP/fleet-chain" chained rc
  make_fixture "$d"
  "$ROOT/bin/fm-git-strip-ai-trailers.sh" install "$d/strip" "$d/wt" >/dev/null 2>&1 \
    || { fail "installing the AI-trailer strip hooks failed"; return; }
  # A clone whose own config names a fleet hooks directory: chaining it makes
  # the strip wrappers dispatch back into the guard that chained them.
  git -C "$d/parent" config core.hooksPath "$d/strip"
  "$ID_BIN" apply-worktree "$d/wt" --hooks-dir "$d/hooks" >/dev/null 2>&1 \
    || { fail "apply-worktree failed over a fleet hooks directory"; return; }
  chained=$(git -C "$d/wt" config --worktree --get firstmate.chainedHooksPath 2>/dev/null || true)
  [ -z "$chained" ] \
    || { fail "apply-worktree chained the fleet hooks directory '$chained'"; return; }
  commit_in_pane "$d/wt" "$d/strip" "over a fleet hooks dir"
  rc=$?
  [ "$rc" -ne 124 ] || { fail "a commit looped between the guard and a chained fleet hooks directory until killed"; return; }
  [ "$rc" -eq 0 ] || { fail "a commit over a fleet hooks directory failed (exit $rc)"; return; }
  pass "apply-worktree never chains a fleet hooks directory"
}

test_hooks_dir_inside_a_tracked_tree_is_refused() {
  local d="$TMP/stray" out
  make_fixture "$d"
  # The 2026-09-21 incident: a hooks dir under a repository's working tree that
  # the repository does not ignore left an untracked hooks/ behind there.
  out=$("$ID_BIN" apply-worktree "$d/wt" --hooks-dir "$d/parent/hooks" 2>&1)
  # shellcheck disable=SC2181 # the message is captured above, so the status is read separately
  if [ $? -eq 0 ]; then
    fail "apply-worktree accepted a hooks dir that dirties the parent repository"
    return
  fi
  [ ! -e "$d/parent/hooks" ] || fail "the refused hooks dir was still created"
  [ -z "$(git -C "$d/parent" status --porcelain)" ] \
    || fail "a refused apply-worktree left the parent repository dirty"
  case $out in
    *'not ignored there'*) : ;;
    *) fail "the refusal does not explain why: $out" ;;
  esac
  # Control: the same location is fine once the repository ignores it, which
  # is the shape bin/fm-spawn.sh uses (<home>/state/<id>.githooks).
  printf 'state/\n' > "$d/parent/.git/info/exclude"
  "$ID_BIN" apply-worktree "$d/wt" --hooks-dir "$d/parent/state/t.githooks" >/dev/null 2>&1 \
    || { fail "apply-worktree refused a hooks dir the repository ignores"; return; }
  [ -z "$(git -C "$d/parent" status --porcelain)" ] \
    || fail "an ignored hooks dir still dirtied the parent repository"
  pass "a hooks dir that would dirty a repository is refused; an ignored one is accepted"
}

test_guard_refuses_when_its_own_prerequisites_are_missing() {
  local d="$TMP/missing" out hooks
  make_fixture "$d"
  hooks="$d/hooks"
  "$ID_BIN" apply-worktree "$d/wt" --hooks-dir "$hooks" >/dev/null 2>&1 \
    || { fail "apply-worktree failed"; return; }

  # The guard executable disappears (an interrupted self-update, a half-synced
  # home). A guard that quietly passed here would be worse than none.
  sed -i.bak "s|^FM_ID=.*|FM_ID=$d/not-installed.sh|" "$hooks/pre-commit"
  rm -f "$hooks/pre-commit.bak"
  out=$( ( cd "$d/wt" && printf 'z\n' >>log.txt && git add log.txt \
    && git commit -m "guard missing" ) 2>&1 )
  # shellcheck disable=SC2181 # the message is captured above, so the status is read separately
  if [ $? -eq 0 ]; then
    fail "the commit was accepted while the identity guard was missing"
    return
  fi
  case $out in
    *refusing*) : ;;
    *) fail "a missing guard did not produce a refusal: $out" ;;
  esac
  pass "a missing guard executable refuses the commit rather than passing silently"
}

test_verify_refuses_an_unarmed_worktree() {
  local d="$TMP/unarmed" out
  make_fixture "$d"
  out=$("$ID_BIN" verify-worktree "$d/wt" 2>&1)
  # shellcheck disable=SC2181 # the message is captured above, so the status is read separately
  if [ $? -eq 0 ]; then
    fail "verify-worktree reported an unarmed worktree as armed"
    return
  fi
  case $out in
    *user.email*) pass "verify-worktree refuses an unarmed worktree and names what is missing" ;;
    *) fail "verify-worktree's refusal does not name the missing requirement: $out" ;;
  esac
}

test_taking_over_hooks_path_keeps_the_repo_own_hooks() {
  local d="$TMP/chain" out
  make_fixture "$d"
  mkdir -p "$d/parent/.githooks"
  printf '#!/bin/sh\necho REPO-PRE-COMMIT >&2\n' >"$d/parent/.githooks/pre-commit"
  printf '#!/bin/sh\necho REPO-PRE-PUSH >&2\n' >"$d/parent/.githooks/pre-push"
  chmod +x "$d/parent/.githooks/pre-commit" "$d/parent/.githooks/pre-push"
  git -C "$d/parent" config core.hooksPath .githooks
  git -C "$d/parent" add .githooks >/dev/null 2>&1
  git -C "$d/parent" -c core.hooksPath=/dev/null commit -q -m hooks
  git -C "$d/wt" merge -q --ff-only master >/dev/null 2>&1 \
    || git -C "$d/wt" reset -q --hard master

  "$ID_BIN" apply-worktree "$d/wt" --hooks-dir "$d/hooks" >/dev/null 2>&1 \
    || { fail "apply-worktree failed over an existing hooksPath"; return; }

  out=$( ( cd "$d/wt" && printf 'c\n' >>log.txt && git add log.txt \
    && git commit -m "chained" ) 2>&1 )
  case $out in
    *REPO-PRE-COMMIT*) : ;;
    *) fail "the repo's own pre-commit hook stopped running once firstmate took over hooksPath: $out" ;;
  esac
  [ -x "$d/hooks/pre-push" ] \
    || fail "the repo's pre-push hook was not carried over; another guard would be silently disarmed"
  pass "taking over hooksPath adds the identity guard without disarming the repo's own hooks"
}

test_disarm_returns_the_worktree_to_unarmed() {
  local d="$TMP/disarm"
  make_fixture "$d"
  "$ID_BIN" apply-worktree "$d/wt" --hooks-dir "$d/hooks" >/dev/null 2>&1 \
    || { fail "apply-worktree failed"; return; }
  "$ID_BIN" disarm-worktree "$d/wt" --hooks-dir "$d/hooks" >/dev/null 2>&1 \
    || { fail "disarm-worktree failed"; return; }
  [ ! -d "$d/hooks" ] || fail "disarm-worktree left the hooks directory behind"
  [ -z "$(git -C "$d/wt" config --worktree --get core.hooksPath 2>/dev/null || true)" ] \
    || fail "disarm-worktree left core.hooksPath pointing at a deleted directory"
  [ -z "$(git -C "$d/wt" config --worktree --get-regexp '^(user|author|committer)\.' 2>/dev/null || true)" ] \
    || fail "disarm-worktree left a per-worktree identity behind"
  "$ID_BIN" verify-worktree "$d/wt" >/dev/null 2>&1 \
    && fail "verify-worktree still reports a disarmed worktree as armed"
  pass "disarm leaves no hooksPath pointing at a directory git would treat as no hooks"
}

test_removal_refuses_a_directory_it_does_not_own() {
  local d="$TMP/own" out
  make_fixture "$d"
  mkdir -p "$d/not-ours"
  printf 'keep me\n' >"$d/not-ours/pre-commit"
  out=$("$ID_BIN" disarm-worktree "$d/wt" --hooks-dir "$d/not-ours" 2>&1)
  # shellcheck disable=SC2181 # the message is captured above, so the status is read separately
  if [ $? -eq 0 ]; then
    fail "disarm-worktree operated on a directory firstmate does not own"
  fi
  [ -f "$d/not-ours/pre-commit" ] \
    || fail "disarm-worktree deleted a file in a directory firstmate does not own"
  case $out in
    *refusing*) pass "removal refuses a hooks directory firstmate does not own, deleting nothing" ;;
    *) fail "removal did not refuse an unowned directory explicitly: $out" ;;
  esac
}

test_check_range_refuses_a_vacuous_pass() {
  local d="$TMP/range" out
  make_fixture "$d"
  out=$("$ID_BIN" check-range "$d/parent" "HEAD..HEAD" 2>&1)
  # shellcheck disable=SC2181 # the message is captured above, so the status is read separately
  if [ $? -eq 0 ]; then
    fail "check-range reported a pass for a range containing no commits"
    return
  fi
  case $out in
    *"no commits"*) pass "check-range refuses to report a pass that checked nothing" ;;
    *) fail "check-range's empty-range refusal is not explicit: $out" ;;
  esac
}

test_check_range_flags_a_published_captain_identity() {
  local d="$TMP/scan" out
  make_fixture "$d"
  git -C "$d/parent" commit -q --allow-empty -m "captain authored"
  out=$("$ID_BIN" check-range "$d/parent" "HEAD~1..HEAD" 2>&1)
  # shellcheck disable=SC2181 # the message is captured above, so the status is read separately
  if [ $? -eq 0 ]; then
    fail "check-range passed a commit carrying the captain's address"
    return
  fi
  case $out in
    *"$CAPTAIN_EMAIL"*) pass "check-range names a commit carrying a non-firstmate identity" ;;
    *) fail "check-range did not name the offending identity: $out" ;;
  esac
}

test_firstmate_direct_commit_uses_the_firstmate_identity() {
  local d="$TMP/direct"
  make_fixture "$d"
  ( cd "$d/parent" && printf 'f\n' >>log.txt && git add log.txt \
    && "$ID_BIN" commit -q -m "firstmate direct" ) >/dev/null 2>&1 \
    || { fail "fm-git-identity.sh commit failed"; return; }
  [ "$(author_of "$d/parent")" = "Firstmate <firstmate@digio.nz>" ] \
    || fail "a firstmate direct commit is authored as $(author_of "$d/parent")"
  [ "$(committer_of "$d/parent")" = "Firstmate <firstmate@digio.nz>" ] \
    || fail "a firstmate direct commit is committed as $(committer_of "$d/parent")"
  # The clone the captain also commits in keeps its own identity.
  [ "$(git -C "$d/parent" config --local --get user.email)" = "$CAPTAIN_EMAIL" ] \
    || fail "a firstmate direct commit changed the clone's configured identity"
  pass "firstmate's own direct commit uses the firstmate identity without changing the clone"
}

test_allowlist_excludes_the_captain() {
  local out
  out=$("$ID_BIN" allowlist 2>&1) || { fail "allowlist failed"; return; }
  case $out in
    *"$CAPTAIN_EMAIL"*) fail "the captain's own address is on the firstmate allowlist" ;;
    *) : ;;
  esac
  case $out in
    *crew@digio.nz*firstmate@digio.nz*) pass "the allowlist is exactly the two firstmate identities" ;;
    *) fail "the allowlist does not name both firstmate identities: $out" ;;
  esac
}

if ! command -v git >/dev/null 2>&1; then
  echo "skip: git not found"
  exit 0
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-git-identity.XXXXXX")
export GIT_CONFIG_NOSYSTEM=1
export HOME="$TMP/home"
mkdir -p "$HOME"
export GIT_CONFIG_GLOBAL="$TMP/home/.gitconfig"
: >"$GIT_CONFIG_GLOBAL"
# Every fixture starts from a machine with NO configured identity, which is the
# exact state that let git synthesize the captain's address in the incident.
git config --global init.defaultBranch master
git config --global --unset-all user.email 2>/dev/null || true
git config --global --unset-all user.name 2>/dev/null || true

test_worktree_identity_does_not_leak_into_the_parent_clone
test_commit_carrying_the_captain_identity_is_refused
test_environment_identity_cannot_bypass_the_guard
test_global_author_override_cannot_change_the_crew_identity
test_guard_resolves_author_config_as_git_does
test_hooks_dir_inside_a_tracked_tree_is_refused
test_rearming_into_a_new_guard_dir_does_not_chain_guards
test_arming_inside_a_worker_pane_does_not_chain_the_strip_hooks
test_a_fleet_hooks_dir_is_never_chained
test_guard_refuses_when_its_own_prerequisites_are_missing
test_verify_refuses_an_unarmed_worktree
test_taking_over_hooks_path_keeps_the_repo_own_hooks
test_disarm_returns_the_worktree_to_unarmed
test_removal_refuses_a_directory_it_does_not_own
test_check_range_refuses_a_vacuous_pass
test_check_range_flags_a_published_captain_identity
test_firstmate_direct_commit_uses_the_firstmate_identity
test_allowlist_excludes_the_captain

exit "$FAILED"
