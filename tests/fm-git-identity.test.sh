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
  [ -z "$TMP" ] || rm -rf "$TMP"
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
  [ "$(author_of "$d/wt")" = "digio crew <crew@digio.nz>" ] \
    || fail "worktree commit author is $(author_of "$d/wt"), expected the crew identity"
  [ "$(committer_of "$d/wt")" = "digio crew <crew@digio.nz>" ] \
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
  git -C "$d/wt" config --worktree --unset-all user.email
  git -C "$d/wt" config --worktree --unset-all user.name

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
    *apply-worktree*) : ;;
    *) fail "the refusal does not say how to fix it: $out" ;;
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
  [ "$(author_of "$d/parent")" = "firstmate <firstmate@digio.nz>" ] \
    || fail "a firstmate direct commit is authored as $(author_of "$d/parent")"
  [ "$(committer_of "$d/parent")" = "firstmate <firstmate@digio.nz>" ] \
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
