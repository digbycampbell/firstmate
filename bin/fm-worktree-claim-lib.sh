#!/usr/bin/env bash
# Worktree-claim cross-check: one home's live tasks must never share a worktree.
#
# A task's `state/<id>.meta` holds `worktree=<path>` from spawn until teardown
# removes that metadata, so the set of live claims is exactly the set of
# `state/*.meta` files present. Two live tasks pointing at the same path is
# always a bug: whichever one is torn down (or freshened to origin) first
# destroys the other's work.
#
# The pool's own reservation is "a process is running in this tree", which is
# shorter than a firstmate task's life: a task whose agent has exited - paused
# awaiting a merge, stopped, or between relaunches - still owns its worktree and
# any unlanded work, but the pool sees an idle tree and can hand the same slot to
# the next spawn. Observed twice in one home, once under a RUNNING agent. This
# check is what makes that collision structurally impossible to act on, whatever
# produced it: a recycled slot, a rebuilt pool, or hand-edited metadata.
#
# Callers:
#   - bin/fm-spawn.sh refuses to launch onto a path another live task claims.
#   - bin/fm-teardown.sh refuses to reset/remove a path another live task claims.
# Both refuse loudly and name the colliding task rather than proceeding.

# fm_worktree_claim_real: <path> resolved physically, or the raw path when it
# cannot be resolved (a recorded worktree may already be gone).
fm_worktree_claim_real() {  # <path>
  local path=$1 real
  [ -n "$path" ] || return 1
  if real=$(CDPATH='' cd -- "$path" 2>/dev/null && pwd -P); then
    printf '%s\n' "$real"
  else
    printf '%s\n' "$path"
  fi
}

# fm_worktree_claim_owner: print the id of a LIVE task in <state-dir> - other
# than <self-id> - whose metadata records <path> as its worktree, and return 0.
# Return 1 when no other live task claims it. Ids are printed one per line, so a
# caller can report every colliding task rather than only the first.
fm_worktree_claim_owner() {  # <state-dir> <path> <self-id>
  local state=$1 path=$2 self=$3 want meta id claimed found=1
  [ -d "$state" ] || return 1
  want=$(fm_worktree_claim_real "$path") || return 1
  [ -n "$want" ] || return 1
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] || continue
    id=$(basename "$meta" .meta)
    [ "$id" != "$self" ] || continue
    claimed=$(fm_meta_get "$meta" worktree)
    [ -n "$claimed" ] || continue
    [ "$(fm_worktree_claim_real "$claimed")" = "$want" ] || continue
    printf '%s\n' "$id"
    found=0
  done
  return "$found"
}

# fm_worktree_claim_conflict_message: the shared refusal text naming the path and
# every colliding task. <owners> is fm_worktree_claim_owner's newline-separated
# output.
fm_worktree_claim_conflict_message() {  # <action> <path> <owners>
  local action=$1 path=$2 owners=$3 list
  list=$(printf '%s' "$owners" | tr '\n' ' ')
  list=${list% }
  printf 'error: worktree %s is already recorded as the live worktree of task(s): %s; refusing to %s it. Investigate the double allocation before continuing (do not tear down or reset a path another live task still holds).\n' \
    "$path" "$list" "$action"
}
