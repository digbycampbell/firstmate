#!/usr/bin/env bash
# Single owner of the git identities firstmate-managed commits may carry, and of
# the allowlist every layer of the guard tests against.
#
# Why an allowlist and not a denylist of the one address that leaked: the
# incident's root cause was not "someone typed the captain's address", it was
# "no identity was configured, so git synthesized one". A denylist only covers
# the synthesized value this machine happened to produce; a different host,
# user, or clone synthesizes a different address and the guard passes an equally
# wrong commit. The allowlist names the two identities firstmate is allowed to
# author as, so every unconfigured-fallback case fails the same way.
#
# The captain's own identity is deliberately NOT on this list. It is correct for
# his own terminal work and must stay configured globally; it is simply not an
# identity firstmate's own tooling may create a commit with.
#
# Callers: bin/fm-git-identity.sh (CLI and hook), bin/fm-spawn.sh (worktree
# arming and the fail-closed launch assertion).

# Crewmates and scouts working in a task worktree.
FM_GIT_CREW_NAME='digio crew'
FM_GIT_CREW_EMAIL='crew@digio.nz'

# Firstmate itself, committing directly under one of its guarded exceptions.
FM_GIT_FIRSTMATE_NAME='firstmate'
FM_GIT_FIRSTMATE_EMAIL='firstmate@digio.nz'

# fm_git_identity_for_role: print "<name>\t<email>" for a role, or fail.
fm_git_identity_for_role() {  # <crew|firstmate>
  case "${1:-}" in
    crew) printf '%s\t%s\n' "$FM_GIT_CREW_NAME" "$FM_GIT_CREW_EMAIL" ;;
    firstmate) printf '%s\t%s\n' "$FM_GIT_FIRSTMATE_NAME" "$FM_GIT_FIRSTMATE_EMAIL" ;;
    *) return 1 ;;
  esac
}

# fm_git_identity_allowlist: every email a firstmate-managed commit may carry,
# one per line.
fm_git_identity_allowlist() {
  printf '%s\n' "$FM_GIT_CREW_EMAIL" "$FM_GIT_FIRSTMATE_EMAIL"
}

# fm_git_identity_allowed: 0 when <email> is a permitted firstmate identity.
# Empty is never allowed: an unset identity is exactly the state that produced
# the incident, so it must fail rather than defer to git's fallback.
fm_git_identity_allowed() {  # <email>
  local email=${1:-} allowed
  [ -n "$email" ] || return 1
  while IFS= read -r allowed; do
    [ "$email" = "$allowed" ] && return 0
  done < <(fm_git_identity_allowlist)
  return 1
}

# fm_git_identity_reject_message: the refusal text, printed by every layer so
# the same wrong identity reads the same way at commit time and at launch time.
# <what> names the offending subject, already including its role, so the caller
# can report author and committer in one block rather than repeating the whole
# explanation twice for what is almost always the same misconfiguration.
fm_git_identity_reject_message() {  # <what> [<what>...]
  local what
  for what in "$@"; do
    printf 'refusing: %s\n' "$what"
  done
  printf 'Only firstmate identities may author a firstmate-managed commit:\n'
  printf '  %s <%s>   (crewmates and scouts, set per task worktree)\n' \
    "$FM_GIT_CREW_NAME" "$FM_GIT_CREW_EMAIL"
  printf '  %s <%s>   (firstmate itself, via bin/fm-git-identity.sh commit)\n' \
    "$FM_GIT_FIRSTMATE_NAME" "$FM_GIT_FIRSTMATE_EMAIL"
  printf 'Fix: in a task worktree run\n'
  printf '  bin/fm-git-identity.sh apply-worktree <worktree> --hooks-dir <dir>\n'
  printf 'Do not set this with a plain "git config user.email" in a linked worktree:\n'
  printf 'that writes the SHARED clone config and would relabel the captain'"'"'s own commits.\n'
}
