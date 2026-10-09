#!/usr/bin/env bash
# fm-git-identity.sh - give firstmate-managed commits their own git identity and
# refuse, at commit time, any commit that would carry another one.
#
# The incident this exists for: a machine with no user.email configured at any
# level let git synthesize the captain's private address into crewmate commits.
# GitHub rejected the push hours later with GH007, after a full validation run
# had already been spent. So the load-bearing layer here is commit-time, not
# push-time. bin/fm-git-identity-lib.sh owns the identities and the allowlist,
# and explains why the rule is an allowlist rather than a denylist of one
# address.
#
# Commands:
#   apply-worktree <worktree> --hooks-dir <dir>
#       Arm one task worktree: set the crew identity (user.*, author.* and
#       committer.*) and the commit guard so they apply to THAT worktree only.
#       Refuses rather than half-arming.
#   disarm-worktree <worktree> --hooks-dir <dir>
#       Return a pooled worktree to unarmed: drop the per-worktree identity and
#       hooksPath, then remove the hooks directory. Run at teardown so a
#       recycled pool slot can never keep a hooksPath pointing at a directory
#       that no longer exists, which git would treat as "no hooks" and pass.
#   verify-worktree <worktree>
#       Assert the identity and the guard are actually in force for the
#       WORKTREE, from configuration alone. Non-zero and explicit when they are
#       not; never silently satisfied.
#   guard-commit <worktree>
#       The check itself: resolve the identity git would use for a commit made
#       by THIS process right now - configuration plus its GIT_AUTHOR_* and
#       GIT_COMMITTER_* environment - and refuse a non-allowlisted one. Used by
#       the installed hook and runnable by hand.
#   hook-pre-commit <worktree> [<chained-hooks-dir>]
#       Hook entry point: guard-commit, then delegate to the repo's own
#       pre-commit hook when one existed before firstmate took over hooksPath.
#   check-range <repo> <range>
#       Scan authors and committers of a commit range against the allowlist.
#   commit [git-commit-args...]
#       Firstmate's own direct commit, authored and committed as the firstmate
#       identity, guarded by the same allowlist.
#   allowlist
#       Print the permitted identities, one "<name><TAB><email>" per line.
#   -h, --help
#       Print this header.
#
# Mechanism (verified in docs/verification/git-identity.md): firstmate's pooled
# worktrees are LINKED worktrees sharing one .git directory, so `git config
# user.email` in a task worktree writes the SHARED clone config and would
# relabel the captain's own commits in that clone. Everything this script sets
# per worktree goes through git's worktree-config extension
# (extensions.worktreeConfig + `git config --worktree`), which is per-worktree
# for user.*, author.*, committer.* and core.hooksPath alike. All three
# identity scopes are armed because author.*/committer.* outrank user.*.
#
# Fail-closed: every prerequisite is checked and every failure exits non-zero
# with the concrete missing requirement. There is no path through this script
# that reports success without having verified the identity by reading it back.
#
# Destructive-operation rule: the only files this script ever removes are hook
# shims inside a hooks directory it owns. Ownership is proven structurally by
# HOOKS_MARKER, the path is rebuilt from a resolved directory plus a name
# matched against HOOK_NAME_RE, and the resolved parent must equal the resolved
# hooks directory. Any of those failing is a hard error, never a skipped remove.
set -uo pipefail

FM_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=bin/fm-git-identity-lib.sh
. "$FM_ROOT/bin/fm-git-identity-lib.sh"

# Present only in a hooks directory this script created. Nothing is removed from
# a directory without it, so a mistyped or inherited --hooks-dir cannot become a
# delete against a directory someone else owns.
HOOKS_MARKER='.fm-git-identity-hooks'
HOOK_NAME_RE='^[a-z][a-z0-9-]*$'

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0" >&2
}

die() {
  printf 'fm-git-identity: %s\n' "$*" >&2
  exit 1
}

# Hook names firstmate shims through when it takes over a worktree's hooksPath.
# A repo that ships its own hooks (digio-planning sets core.hooksPath=.githooks;
# the dotfiles pre-push secret guard installs the same way) must keep them:
# taking over hooksPath without chaining would silently disarm another guard,
# which is the same fail-open failure this script exists to prevent.
CHAINED_HOOKS='applypatch-msg pre-applypatch post-applypatch pre-commit
prepare-commit-msg commit-msg post-commit pre-rebase post-checkout post-merge
pre-push pre-receive update post-receive post-update push-to-checkout
pre-auto-gc post-rewrite sendemail-validate p4-pre-submit post-index-change'

resolve_dir() {  # <path>
  local path=${1:-}
  [ -n "$path" ] || return 1
  CDPATH='' cd -- "$path" 2>/dev/null && pwd -P
}

require_worktree() {  # <path> -> prints resolved worktree top
  local path=$1 top
  top=$(git -C "$path" rev-parse --show-toplevel 2>/dev/null) \
    || die "'$path' is not inside a git worktree"
  resolve_dir "$top" || die "cannot resolve worktree root '$top'"
}

# hook_path: the ONLY way a hook path is constructed in this script. It refuses
# an empty or unresolvable directory, a name that is not a plain hook name, and
# any result whose parent is not the resolved hooks directory itself.
hook_path() {  # <hooks-real> <hook-name>
  local hooks=${1:-} name=${2:-} parent
  [ -n "$hooks" ] || die "internal: empty hooks directory"
  [ -d "$hooks" ] || die "internal: hooks directory '$hooks' does not exist"
  [ "$hooks" = "$(resolve_dir "$hooks")" ] || die "internal: hooks directory '$hooks' is not a resolved path"
  [ "$hooks" != / ] || die "internal: refusing to treat / as a hooks directory"
  [ -n "$name" ] || die "internal: empty hook name"
  [[ $name =~ $HOOK_NAME_RE ]] || die "internal: '$name' is not a plain hook name"
  parent=$(resolve_dir "$(dirname -- "$hooks/$name")") \
    || die "internal: cannot resolve the parent of '$hooks/$name'"
  [ "$parent" = "$hooks" ] || die "internal: '$hooks/$name' escapes the hooks directory"
  printf '%s\n' "$hooks/$name"
}

# remove_hook: the script's only destructive operation. Every constraint is
# checked here and a violated one is a hard error, so there is no path where a
# removal targets something outside a hooks directory this script owns.
remove_hook() {  # <hooks-real> <hook-name>
  local hooks=${1:-} name=${2:-} target
  [ -n "$hooks" ] || die "internal: empty hooks directory"
  [ -f "$hooks/$HOOKS_MARKER" ] \
    || die "refusing to remove anything from '$hooks': it is not a firstmate hooks directory (no $HOOKS_MARKER)"
  target=$(hook_path "$hooks" "$name") || exit 1
  [ ! -e "$target" ] && [ ! -L "$target" ] && return 0
  [ ! -d "$target" ] || die "refusing to remove '$target': it is a directory, not a hook file"
  rm -f -- "$target" || die "cannot remove the stale hook '$target'"
}

# Identity git would use for a commit made in <dir> right now, resolved by git
# itself (`git var`), so the precedence is git's own: GIT_AUTHOR_*/
# GIT_COMMITTER_* environment, then author.*/committer.* at any config level,
# then user.*. Reading user.* alone missed a global author.* include, which
# outranks a worktree's user.*. An identity git cannot resolve prints empty.
resolved_ident() {  # <dir> <AUTHOR|COMMITTER> -> "<name>\t<email>"
  local ident name email
  ident=$(git -C "$1" var "GIT_${2}_IDENT" 2>/dev/null) || ident=''
  ident=$(printf '%s' "$ident" | sed -E 's/ [0-9]+ [-+][0-9]{4}$//')
  case $ident in
    *' <'*'>') name=${ident% <*}; email=${ident##* <}; email=${email%>} ;;
    *) name=''; email='' ;;
  esac
  printf '%s\t%s\n' "$name" "$email"
}

effective_identity() {  # <dir> -> author line then committer line
  resolved_ident "$1" AUTHOR
  resolved_ident "$1" COMMITTER
}

# The same resolution with the caller's environment overrides removed: what the
# worktree's configuration alone would commit as.
configured_identity() {  # <dir> -> author line then committer line
  (
    unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
    effective_identity "$1"
  )
}

cmd_guard_commit() {  # <worktree>
  local dir=${1:-.} top line name email configured i=0
  local roles=(author committer)
  local -a bad=()
  top=$(require_worktree "$dir")
  while IFS= read -r line; do
    name=${line%%$'\t'*}
    email=${line#*$'\t'}
    if ! fm_git_identity_allowed "$email"; then
      bad+=("this commit's ${roles[$i]} would be ${name:-<unset>} <${email:-<unset>}>")
    fi
    i=$((i + 1))
  done < <(effective_identity "$top")
  if [ "${#bad[@]}" -gt 0 ]; then
    fm_git_identity_reject_message "${bad[@]}" >&2
    # Name the environment as the cause only when configuration alone would
    # have passed; git exports GIT_AUTHOR_* to every pre-commit hook, so the
    # variables being set says nothing on its own.
    configured=$(configured_identity "$top" | head -n 1)
    if [ -n "${GIT_AUTHOR_NAME:-}${GIT_AUTHOR_EMAIL:-}${GIT_COMMITTER_NAME:-}${GIT_COMMITTER_EMAIL:-}" ] \
      && fm_git_identity_allowed "${configured#*$'\t'}"; then
      printf 'This commit'"'"'s identity comes from a GIT_AUTHOR_*/GIT_COMMITTER_* override (git commit --author sets one too); this worktree is configured as %s <%s>.\n' \
        "${configured%%$'\t'*}" "${configured#*$'\t'}" >&2
    fi
    exit 1
  fi
  return 0
}

# A hooks directory firstmate generated: this script's guard (HOOKS_MARKER) or
# bin/fm-git-strip-ai-trailers.sh's per-pane strip hooks, whose commit-msg runs
# that script. Both dispatch back into the worktree's own hooks, which are the
# guard once a worktree is armed, so chaining either makes two hooks directories
# exec each other on every commit.
is_fleet_hooks_dir() {  # <dir>
  local dir=$1
  [ -f "$dir/$HOOKS_MARKER" ] && return 0
  [ -f "$dir/commit-msg" ] && grep -qF 'fm-git-strip-ai-trailers.sh' "$dir/commit-msg" 2>/dev/null
}

# The hooks path the repository's own config files name for <worktree>. The
# GIT_CONFIG_* environment is dropped first: bin/fm-spawn.sh exports
# core.hooksPath through it into every worker pane, and git -c carries it in
# GIT_CONFIG_PARAMETERS, so a lookup that honored either would read back the
# pane's strip hooks instead of the repository's own.
repo_hooks_path() {  # <worktree>
  (
    unset GIT_CONFIG GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS
    git -C "$1" config --get core.hooksPath 2>/dev/null || true
  )
}

cmd_hook_pre_commit() {  # <worktree> [<chained-hooks-dir>] [hook args...]
  local dir=${1:-.} chained=${2:-}
  cmd_guard_commit "$dir"
  # A fleet hooks directory is never a chain target (see cmd_apply_worktree); a
  # hook written before that rule must not loop either.
  if [ -n "$chained" ] && [ -x "$chained/pre-commit" ] && ! is_fleet_hooks_dir "$chained"; then
    exec "$chained/pre-commit" "${@:3}"
  fi
  return 0
}

# A hooks directory inside a repository's working tree that the repository does
# not ignore becomes untracked content there: one such stray hooks/ made a
# firstmate home read dirty, so its self-update skipped. bin/fm-spawn.sh passes
# <home>/state/<id>.githooks, which every firstmate home ignores.
require_hooks_dir_untracked() {  # <absolute-hooks-dir>
  local path=$1 probe top
  probe=$path
  while [ ! -d "$probe" ]; do
    probe=$(dirname -- "$probe")
  done
  top=$(git -C "$probe" rev-parse --show-toplevel 2>/dev/null) || return 0
  [ -n "$top" ] || return 0
  git -C "$top" check-ignore -q --no-index -- "$path" 2>/dev/null && return 0
  git -C "$top" check-ignore -q --no-index -- "$path/" 2>/dev/null && return 0
  die "--hooks-dir '$path' is inside the working tree of '$top' and not ignored there, so it would leave untracked files in that repository; pass a directory outside it, such as <firstmate-home>/state/<task>.githooks"
}

# Build the per-worktree hooks directory: firstmate's commit guard as
# pre-commit, plus a passthrough shim for every other hook the repo already had,
# so taking over hooksPath adds a guard instead of removing the repo's own.
write_hooks_dir() {  # <hooks-dir> <worktree> <chained-hooks-dir-or-empty>
  local hooks_arg=$1 wt=$2 chained=$3 hooks hook target
  [ -n "$hooks_arg" ] || die "apply-worktree needs a non-empty --hooks-dir"
  case $hooks_arg in
    /*) : ;;
    *) die "--hooks-dir must be an absolute path (got '$hooks_arg')" ;;
  esac
  if [ -e "$hooks_arg" ] && [ ! -d "$hooks_arg" ]; then
    die "--hooks-dir '$hooks_arg' exists and is not a directory"
  fi
  require_hooks_dir_untracked "$hooks_arg"
  mkdir -p -- "$hooks_arg" || die "cannot create hooks directory '$hooks_arg'"
  hooks=$(resolve_dir "$hooks_arg") || die "cannot resolve hooks directory '$hooks_arg'"
  [ "$hooks" != / ] || die "refusing to use / as a hooks directory"
  # Claim ownership before writing anything, so remove_hook's marker check can
  # never pass for a directory this script did not create or adopt.
  : >"$hooks/$HOOKS_MARKER" || die "cannot claim '$hooks' as a firstmate hooks directory"

  target=$(hook_path "$hooks" pre-commit) || exit 1
  # The literals below are the GENERATED hook's source text, so $FM_ID and "$@"
  # must survive into the file unexpanded.
  # shellcheck disable=SC2016
  {
    printf '#!/usr/bin/env bash\n'
    printf '# Generated by bin/fm-git-identity.sh apply-worktree. Do not edit.\n'
    printf 'set -uo pipefail\n'
    printf 'FM_ID=%q\n' "$FM_ROOT/bin/fm-git-identity.sh"
    printf 'if [ ! -x "$FM_ID" ]; then\n'
    printf '  echo "refusing this commit: firstmate'"'"'s identity guard ($FM_ID) is missing or not executable." >&2\n'
    printf '  echo "The guard cannot verify who this commit would be authored as, so it refuses rather than passes." >&2\n'
    printf '  exit 1\n'
    printf 'fi\n'
    printf 'exec "$FM_ID" hook-pre-commit %q %q "$@"\n' "$wt" "$chained"
  } >"$target" || die "cannot write '$target'"
  chmod 0700 -- "$target" || die "cannot make '$target' executable"

  for hook in $CHAINED_HOOKS; do
    [ "$hook" = pre-commit ] && continue
    remove_hook "$hooks" "$hook"
    if [ -n "$chained" ] && [ -x "$chained/$hook" ]; then
      target=$(hook_path "$hooks" "$hook") || exit 1
      {
        printf '#!/usr/bin/env bash\n'
        printf '# Generated passthrough to the repo hook firstmate'"'"'s hooksPath took over.\n'
        printf 'exec %q "$@"\n' "$chained/$hook"
      } >"$target" || die "cannot write '$target'"
      chmod 0700 -- "$target" || die "cannot make '$target' executable"
    fi
  done
  printf '%s\n' "$hooks"
}

# Enabling the worktree-config extension is safe only when the repo does not
# rely on core.bare/core.worktree in shared config: git treats those two as
# always-worktree-specific once the extension is on, so a repo carrying them
# would change meaning. Refuse instead of migrating someone else's config.
require_worktree_config_safe() {  # <worktree>
  local wt=$1 bare cw
  git -C "$wt" config --worktree --list >/dev/null 2>&1 \
    || git -C "$wt" config --local --list >/dev/null 2>&1 \
    || die "git in this environment does not support 'git config --worktree'"
  if [ "$(git -C "$wt" config --get extensions.worktreeConfig 2>/dev/null || true)" != true ]; then
    bare=$(git -C "$wt" config --local --get core.bare 2>/dev/null || true)
    cw=$(git -C "$wt" config --local --get core.worktree 2>/dev/null || true)
    [ "$bare" != true ] \
      || die "clone has core.bare=true in shared config; enabling the worktree-config extension would change its meaning. Migrate it by hand first"
    [ -z "$cw" ] \
      || die "clone has core.worktree='$cw' in shared config; enabling the worktree-config extension would change its meaning. Migrate it by hand first"
  fi
}

cmd_apply_worktree() {  # <worktree> --hooks-dir <dir>
  local dir='' hooks_arg='' wt hooks chained shared_before shared_after name email scope
  while [ $# -gt 0 ]; do
    case $1 in
      --hooks-dir) [ $# -ge 2 ] || die "--hooks-dir needs a value"; hooks_arg=$2; shift 2 ;;
      --hooks-dir=*) hooks_arg=${1#--hooks-dir=}; shift ;;
      -*) die "unknown option '$1'" ;;
      *) [ -z "$dir" ] || die "unexpected argument '$1'"; dir=$1; shift ;;
    esac
  done
  [ -n "$dir" ] || die "apply-worktree needs a worktree path"
  [ -n "$hooks_arg" ] || die "apply-worktree needs --hooks-dir <dir>"
  wt=$(require_worktree "$dir")
  require_worktree_config_safe "$wt"

  IFS=$'\t' read -r name email < <(fm_git_identity_for_role crew)

  # Shared-config fingerprint before and after: the property that must hold is
  # not "we intended to write per-worktree" but "the parent clone's own config
  # is byte-identical afterwards", so it is measured, not assumed.
  shared_before=$(git -C "$wt" config --local --list 2>/dev/null | LC_ALL=C sort || true)

  git -C "$wt" config extensions.worktreeConfig true \
    || die "cannot enable extensions.worktreeConfig on this clone"
  # author.* and committer.* outrank user.* at every config level, so arming
  # user.* alone loses to a global include that sets author.* (dotfiles routes
  # identities that way). The worktree level outranks global, so arming all
  # three makes this worktree's identity win whatever the machine routes.
  for scope in $FM_GIT_IDENTITY_SCOPES; do
    git -C "$wt" config --worktree "$scope.name" "$name" \
      || die "cannot set the per-worktree $scope.name"
    git -C "$wt" config --worktree "$scope.email" "$email" \
      || die "cannot set the per-worktree $scope.email"
  done

  chained=$(repo_hooks_path "$wt")
  if [ -n "$chained" ]; then
    case $chained in
      /*) : ;;
      *) chained=$wt/$chained ;;
    esac
    chained=$(resolve_dir "$chained" || true)
  fi
  # Never chain to a fleet hooks directory, ours or another task's: re-arming an
  # armed worktree, or arming where the config names another guard or a strip
  # directory, would otherwise make two hooks directories exec each other
  # forever. Chain to the repo hooks the worktree recorded instead.
  if [ -n "$chained" ] && is_fleet_hooks_dir "$chained"; then
    chained=$(git -C "$wt" config --worktree --get firstmate.chainedHooksPath 2>/dev/null || true)
    [ -z "$chained" ] || ! is_fleet_hooks_dir "$chained" || chained=''
  fi
  hooks=$(write_hooks_dir "$hooks_arg" "$wt" "$chained") || exit 1
  if [ -n "$chained" ]; then
    git -C "$wt" config --worktree firstmate.chainedHooksPath "$chained" \
      || die "cannot record the chained hooks path"
  else
    git -C "$wt" config --worktree --unset-all firstmate.chainedHooksPath 2>/dev/null || true
  fi
  git -C "$wt" config --worktree core.hooksPath "$hooks" \
    || die "cannot point this worktree's core.hooksPath at the guard"

  shared_after=$(git -C "$wt" config --local --list 2>/dev/null | LC_ALL=C sort || true)
  # extensions.worktreeConfig is the one shared key this may add; it enables the
  # per-worktree mechanism and carries no identity.
  shared_before=$(printf '%s\n' "$shared_before" | grep -v '^extensions\.worktreeconfig=' || true)
  shared_after=$(printf '%s\n' "$shared_after" | grep -v '^extensions\.worktreeconfig=' || true)
  [ "$shared_before" = "$shared_after" ] \
    || die "arming this worktree changed the parent clone's shared config; refusing to report success"

  cmd_verify_worktree "$wt"
}

# Teardown counterpart to apply-worktree. The git side is best-effort because
# the worktree may already be gone by the time teardown reaches this; the
# removal side keeps every ownership constraint remove_hook enforces.
cmd_disarm_worktree() {  # <worktree> --hooks-dir <dir>
  local dir='' hooks_arg='' hooks wt hook scope
  while [ $# -gt 0 ]; do
    case $1 in
      --hooks-dir) [ $# -ge 2 ] || die "--hooks-dir needs a value"; hooks_arg=$2; shift 2 ;;
      --hooks-dir=*) hooks_arg=${1#--hooks-dir=}; shift ;;
      -*) die "unknown option '$1'" ;;
      *) [ -z "$dir" ] || die "unexpected argument '$1'"; dir=$1; shift ;;
    esac
  done
  [ -n "$hooks_arg" ] || die "disarm-worktree needs --hooks-dir <dir>"
  if [ -n "$dir" ] && wt=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null); then
    git -C "$wt" config --worktree --unset-all core.hooksPath 2>/dev/null || true
    git -C "$wt" config --worktree --unset-all firstmate.chainedHooksPath 2>/dev/null || true
    for scope in $FM_GIT_IDENTITY_SCOPES; do
      git -C "$wt" config --worktree --unset-all "$scope.name" 2>/dev/null || true
      git -C "$wt" config --worktree --unset-all "$scope.email" 2>/dev/null || true
    done
  fi
  [ -d "$hooks_arg" ] || return 0
  hooks=$(resolve_dir "$hooks_arg") || die "cannot resolve hooks directory '$hooks_arg'"
  [ -f "$hooks/$HOOKS_MARKER" ] || die "refusing to remove '$hooks': it is not a firstmate hooks directory (no $HOOKS_MARKER)"
  for hook in $CHAINED_HOOKS; do
    remove_hook "$hooks" "$hook"
  done
  rm -f -- "$hooks/$HOOKS_MARKER" || die "cannot remove '$hooks/$HOOKS_MARKER'"
  rmdir -- "$hooks" 2>/dev/null || true
}

cmd_verify_worktree() {  # <worktree>
  local dir=${1:-.} wt hooks name email scope
  wt=$(require_worktree "$dir")
  for scope in $FM_GIT_IDENTITY_SCOPES; do
    email=$(git -C "$wt" config --worktree --get "$scope.email" 2>/dev/null || true)
    name=$(git -C "$wt" config --worktree --get "$scope.name" 2>/dev/null || true)
    [ -n "$email" ] \
      || die "this worktree has no per-worktree $scope.email; the machine's own identity routing could decide its commits. bin/fm-spawn.sh arms task worktrees with apply-worktree; a hand-run apply-worktree needs a --hooks-dir outside any repository's tracked tree"
    fm_git_identity_allowed "$email" || {
      fm_git_identity_reject_message \
        "commits in '$wt' would carry $scope ${name:-<unset>} <$email>" >&2
      exit 1
    }
  done
  hooks=$(git -C "$wt" config --worktree --get core.hooksPath 2>/dev/null || true)
  [ -n "$hooks" ] \
    || die "this worktree has no per-worktree core.hooksPath; the commit-time guard is not armed"
  [ -x "$hooks/pre-commit" ] \
    || die "the commit-time guard '$hooks/pre-commit' is missing or not executable"
  # Config-resolved identity only. verify-worktree answers "is this worktree
  # configured correctly", which is a property of the worktree; guard-commit
  # answers "is THIS commit correct", which is a property of the committing
  # process and rightly includes its GIT_AUTHOR_*/GIT_COMMITTER_* environment.
  # Conflating them would let the arming caller's own environment - a test
  # fixture identity, a CI runner's - decide whether a worktree is armed.
  env -u GIT_AUTHOR_NAME -u GIT_AUTHOR_EMAIL \
      -u GIT_COMMITTER_NAME -u GIT_COMMITTER_EMAIL \
      "$0" guard-commit "$wt" || exit 1
  printf 'fm-git-identity: %s is armed as %s <%s>, guard at %s\n' "$wt" "$name" "$email" "$hooks"
}

cmd_check_range() {  # <repo> <range>
  local repo=${1:-} range=${2:-} sha kind name email rc=0 seen=0 log
  local -a bad=()
  [ -n "$repo" ] && [ -n "$range" ] || die "check-range needs <repo> <range>"
  log=$(git -C "$repo" log --format=$'%H\tauthor\t%an\t%ae\n%H\tcommitter\t%cn\t%ce' "$range" 2>/dev/null) \
    || die "cannot read commit range '$range' in '$repo'"
  while IFS=$'\t' read -r sha kind name email; do
    [ -n "$sha" ] || continue
    seen=1
    if ! fm_git_identity_allowed "$email"; then
      bad+=("commit $sha $kind is ${name:-<unset>} <${email:-<unset>}>")
      rc=1
    fi
  done <<<"$log"
  [ "$seen" -eq 1 ] || die "commit range '$range' selected no commits; refusing to report a pass that checked nothing"
  if [ "$rc" -ne 0 ]; then
    fm_git_identity_reject_message "${bad[@]}" >&2
    exit 1
  fi
  printf 'fm-git-identity: every commit in %s carries a firstmate identity\n' "$range"
}

cmd_commit() {  # [git-commit-args...]
  local name email
  IFS=$'\t' read -r name email < <(fm_git_identity_for_role firstmate)
  export GIT_AUTHOR_NAME=$name GIT_AUTHOR_EMAIL=$email
  export GIT_COMMITTER_NAME=$name GIT_COMMITTER_EMAIL=$email
  cmd_guard_commit .
  exec git commit "$@"
}

cmd_allowlist() {
  fm_git_identity_for_role crew
  fm_git_identity_for_role firstmate
}

case ${1:-} in
  apply-worktree) shift; cmd_apply_worktree "$@" ;;
  disarm-worktree) shift; cmd_disarm_worktree "$@" ;;
  verify-worktree) shift; cmd_verify_worktree "${1:-.}" ;;
  guard-commit) shift; cmd_guard_commit "${1:-.}" ;;
  hook-pre-commit) shift; cmd_hook_pre_commit "$@" ;;
  check-range) shift; cmd_check_range "$@" ;;
  commit) shift; cmd_commit "$@" ;;
  allowlist) cmd_allowlist ;;
  -h|--help) usage ;;
  '') usage; exit 2 ;;
  *) die "unknown command '$1' (see --help)" ;;
esac
