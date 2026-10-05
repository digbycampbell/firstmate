#!/usr/bin/env bash
# Single owner of how a ship task's branch is named and of the organisation
# Branch Naming rule a fleet-process project enforces at push.
# Sourced by bin/fm-dod-lib.sh, so bin/fm-brief.sh, bin/fm-spawn.sh, and
# bin/fm-promote.sh share one naming and one refusal.
#
# A ship branch takes exactly one of four shapes:
#   fm-issue-<n>[<suffix>]  --issue <n> [--issue-suffix <suffix>]: the task
#                           delivers GitHub issue <n>; the suffix is an optional
#                           retry marker such as `b` or `-r2`
#                           (fm-issue-1596b, fm-issue-1596-r2).
#   plan-issue-<p>          --issue <n> --plan-branch plan-issue-<p>: the task
#                           delivers Phase <n> of a one-branch Plan
#                           (digio-factory#55) as plain commits on the Plan's
#                           own branch, which it shares with every other Phase
#                           and does not create.
#   fm-chore-<slug>         --chore <slug>: admin work too small for an issue.
#   <prefix><task-id>       neither flag: the legacy shape, "fm/<task-id>" unless
#                           --branch-prefix overrides it.
# The `fm-` builder is firstmate's for every harness it runs.
#
# A project registered +fleet-process (bin/fm-project-mode.sh owns the token)
# sits under a GitHub organisation ruleset that refuses to create any branch the
# pattern below rejects, with no bypass, so a legacy "fm/<task-id>" ship there
# is refused at push. Every other project keeps whichever shape it is given.
# FM_ORG_BRANCH_PATTERN is that ruleset's pattern verbatim
# (digio-factory:github/rulesets/digio-nz/_org/branch-naming.json); it is POSIX
# ERE as written, so bash's =~ applies it unchanged.

FM_ORG_BRANCH_PATTERN='^(refs/heads/)?(([a-z0-9]+[-/])*(issue-[0-9]+[a-z]?|chore-[a-z0-9]+)(-[a-z0-9]+)*|process-deploy|dependabot/.+|revert-.+|gh-readonly-queue/.+)$'

# 0 when the organisation ruleset would let <branch> be created.
fm_ship_branch_org_allowed() {  # <branch>
  [[ $1 =~ $FM_ORG_BRANCH_PATTERN ]]
}

# 0 for a chore slug the ruleset accepts: lowercase words joined by single dashes.
fm_ship_chore_slug_valid() {  # <slug>
  [[ $1 =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]
}

# 0 for a one-branch Plan's branch name: plan-issue-<n>, n a positive integer.
fm_ship_plan_branch_valid() {  # <branch>
  [[ $1 =~ ^plan-issue-[1-9][0-9]*$ ]]
}

# 0 for a non-empty retry suffix the ruleset accepts after issue-<n>: an
# optional single letter, then any number of -<word> parts.
fm_ship_issue_suffix_valid() {  # <suffix>
  [ -n "$1" ] && [[ $1 =~ ^[a-z]?(-[a-z0-9]+)*$ ]]
}

# Validate one flag combination and print the ship branch it names. Arguments
# are the raw flag values, empty when the flag was not given; <prefix-set> is 1
# when --branch-prefix was passed explicitly; <plan-branch> is optional.
# Refusals name the flag to change.
fm_ship_branch_resolve() {  # <task-id> <issue> <issue-suffix> <chore> <prefix> <prefix-set> [<plan-branch>]
  local id=$1 issue=$2 suffix=$3 chore=$4 prefix=$5 prefix_set=$6 plan=${7:-} branch
  if [ -n "$issue" ]; then
    case "$issue" in
      *[!0-9]*|0*) echo "error: --issue must be a positive integer issue number (got '$issue')" >&2; return 1 ;;
    esac
  fi
  if [ -n "$issue" ] && [ -n "$chore" ]; then
    echo "error: --issue and --chore name different branches; a task delivers an issue or is a chore, not both" >&2
    return 1
  fi
  if [ -n "$suffix" ] && [ -z "$issue" ]; then
    echo "error: --issue-suffix applies only with --issue" >&2
    return 1
  fi
  if { [ -n "$issue" ] || [ -n "$chore" ]; } && [ "$prefix_set" = 1 ]; then
    echo "error: --issue and --chore name the ship branch themselves; drop --branch-prefix" >&2
    return 1
  fi
  if [ -n "$plan" ]; then
    if [ -z "$issue" ] || [ -n "$suffix" ]; then
      echo "error: --plan-branch needs --issue <n> naming the Phase, and no --issue-suffix: the Phase's commits go on the Plan's one shared branch" >&2
      return 1
    fi
    if ! fm_ship_plan_branch_valid "$plan"; then
      echo "error: --plan-branch must name a Plan's branch, plan-issue-<n> (got '$plan')" >&2
      return 1
    fi
    branch=$plan
  elif [ -n "$issue" ]; then
    if [ -n "$suffix" ] && ! fm_ship_issue_suffix_valid "$suffix"; then
      echo "error: --issue-suffix must be an optional letter then -<word> parts in lowercase letters and digits, such as b or -r2 (got '$suffix')" >&2
      return 1
    fi
    branch="fm-issue-$issue$suffix"
  elif [ -n "$chore" ]; then
    if ! fm_ship_chore_slug_valid "$chore"; then
      echo "error: --chore must be lowercase letters and digits in words joined by single dashes, such as bump-node (got '$chore')" >&2
      return 1
    fi
    branch="fm-chore-$chore"
  else
    branch="$prefix$id"
  fi
  if ! git check-ref-format --branch "$branch" >/dev/null 2>&1; then
    echo "error: --branch-prefix and task id must form a valid git branch (got '$branch')" >&2
    return 1
  fi
  printf '%s\n' "$branch"
}

# Refuse a ship branch a fleet-process project's ruleset would refuse at push,
# naming the two ways forward. <caller> prefixes the message.
fm_ship_branch_require_org_shape() {  # <caller> <project> <branch>
  local caller=$1 project=$2 branch=$3
  fm_ship_branch_org_allowed "$branch" && return 0
  echo "error: $caller: $project is registered +fleet-process, whose organisation ruleset refuses to create branch '$branch' at push; open a Task issue first and ship it with --issue <n>, or pass --chore <slug> for admin work too small for an issue" >&2
  return 1
}
