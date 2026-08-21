#!/usr/bin/env bash
# A real fm-spawn.sh run must leave the task worktree committing as the crew
# identity, guarded, and must leave the project clone's own config untouched.
#
# tests/fm-git-identity.test.sh pins the identity contract itself. This pins the
# lifecycle wiring: that spawn actually arms it before an agent can commit, that
# it refuses to launch when it cannot, and that arming a LINKED worktree does not
# reach the shared clone config the captain's own commits read from.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-git-identity)

CAPTAIN_EMAIL='96467498+digbycampbell@users.noreply.github.com'
CAPTAIN_NAME='digbycampbell'

# Pin the machine-global identity to the captain's, so the fallback a worktree
# lands on when it loses its own is the same everywhere this runs - on the
# captain's machine and on CI, where git would otherwise synthesize a different
# address (or none) and make the refusal assertions meaningless.
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="$TMP_ROOT/gitconfig-global"
: >"$GIT_CONFIG_GLOBAL"
git config --global user.email "$CAPTAIN_EMAIL"
git config --global user.name "$CAPTAIN_NAME"
git config --global init.defaultBranch master

make_fakebin() {  # <dir> -> fake tmux/treehouse that reports the worktree pane
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
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# A home plus a project clone carrying the captain's own identity, with one
# linked worktree standing in for a pooled task worktree.
make_case() {  # <name> <id>
  local name=$1 id=$2 case_dir
  case_dir="$TMP_ROOT/$name"
  HOME_DIR="$case_dir/home"
  PROJ_DIR="$case_dir/project"
  WT_DIR="$case_dir/wt"
  FAKEBIN_DIR=$(make_fakebin "$case_dir/fake")
  mkdir -p "$HOME_DIR/data" "$HOME_DIR/projects" "$HOME_DIR/state" "$HOME_DIR/config"
  printf 'codex\n' > "$HOME_DIR/config/crew-harness"
  fm_git_worktree "$PROJ_DIR" "$WT_DIR" "wt-$name"
  git -C "$PROJ_DIR" config user.email "$CAPTAIN_EMAIL"
  git -C "$PROJ_DIR" config user.name "$CAPTAIN_NAME"
  mkdir -p "$HOME_DIR/data/$id"
  printf 'brief for %s\n' "$id" > "$HOME_DIR/data/$id/brief.md"
  touch "$HOME_DIR/state/.last-watcher-beat"
}

run_spawn() {  # <id> [extra PATH prefix]
  local id=$1
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$WT_DIR" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
}

test_spawn_arms_the_crew_identity_without_touching_the_clone() {
  local id out status before after author committer
  id=spawn-identity-armed-z1
  make_case armed "$id"
  before=$(git -C "$PROJ_DIR" config --local --list | LC_ALL=C sort \
    | grep -v '^extensions\.worktreeconfig=' || true)

  out=$(run_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed: $out"
  assert_contains "$out" "spawned $id" "spawn did not report success"

  # The real property: a commit made the way a crewmate makes one.
  ( cd "$WT_DIR" && printf 'work\n' > work.txt && git add work.txt \
    && git commit -qm "crew work" ) >/dev/null 2>&1 \
    || fail "could not commit in the spawned worktree"
  author=$(git -C "$WT_DIR" log -1 --format='%an <%ae>')
  committer=$(git -C "$WT_DIR" log -1 --format='%cn <%ce>')
  [ "$author" = "digio crew <crew@digio.nz>" ] \
    || fail "a commit in the spawned worktree is authored as $author"
  [ "$committer" = "digio crew <crew@digio.nz>" ] \
    || fail "a commit in the spawned worktree is committed as $committer"

  after=$(git -C "$PROJ_DIR" config --local --list | LC_ALL=C sort \
    | grep -v '^extensions\.worktreeconfig=' || true)
  [ "$before" = "$after" ] \
    || fail "spawning changed the project clone's shared config"
  [ "$(git -C "$PROJ_DIR" config --local --get user.email)" = "$CAPTAIN_EMAIL" ] \
    || fail "spawning changed the project clone's configured identity"
  pass "a real spawn arms the crew identity in the task worktree and leaves the clone alone"
}

test_spawned_worktree_refuses_a_captain_identity_commit() {
  local id out status
  id=spawn-identity-refuses-z2
  make_case refuses "$id"
  out=$(run_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed: $out"

  # Reproduce the incident: the worktree loses its own identity and falls back
  # to the machine's, which here is the captain's private address.
  git -C "$WT_DIR" config --worktree --unset-all user.email
  git -C "$WT_DIR" config --worktree --unset-all user.name
  out=$( ( cd "$WT_DIR" && printf 'leak\n' > leak.txt && git add leak.txt \
    && git commit -m "leak" ) 2>&1 )
  # shellcheck disable=SC2181 # the message is captured above, so the status is read separately
  if [ $? -eq 0 ]; then
    fail "a spawned worktree accepted a commit carrying the captain's address"
  fi
  assert_contains "$out" "$CAPTAIN_EMAIL" "the refusal does not name the offending address"
  pass "a spawned worktree refuses a commit carrying the captain's address"
}

test_spawn_refuses_when_the_identity_cannot_be_armed() {
  local id out status
  id=spawn-identity-unarmable-z3
  make_case unarmable "$id"
  # A clone that carries core.worktree in shared config cannot take the
  # worktree-config extension without changing meaning, so arming must refuse -
  # and spawn must refuse with it rather than launch an unguarded agent.
  git -C "$PROJ_DIR" config core.worktree "$WT_DIR"

  out=$(run_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn launched an agent it could not arm the identity guard for"
  assert_contains "$out" "core.worktree" "spawn's refusal does not name the blocking configuration"
  assert_contains "$out" "refusing to launch" "spawn's refusal does not say it declined to launch"
  pass "spawn refuses to launch when the identity guard cannot be armed"
}

test_spawn_arms_the_crew_identity_without_touching_the_clone
test_spawned_worktree_refuses_a_captain_identity_commit
test_spawn_refuses_when_the_identity_cannot_be_armed

echo "# all fm-spawn-git-identity tests passed"
