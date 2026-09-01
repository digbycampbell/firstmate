#!/usr/bin/env bash
# Single owner of a ship task's mode-specific "Definition of done" block.
# Sourced by bin/fm-brief.sh, which renders it into a generated ship brief, and by
# bin/fm-promote.sh, which renders it into the ship instructions a promoted scout
# receives. Both paths must hand the worker the same contract: a promoted
# no-mistakes worker that never received the ask-user escalation rule or the
# `--yes` ban is the exact delivery hole this single owner exists to close.
# fm_dod_block <no-mistakes|direct-PR|local-only> <task-id> [<branch-name>] prints
# the block on stdout with no trailing blank line. The caller validates the mode; an
# unknown mode is refused rather than silently rendered as the pipeline contract.
# <branch-name> defaults to fm/<task-id>; bin/fm-brief.sh passes the issue-derived
# name when a ship task is linked to an issue, so the contract names the branch the
# worker was actually told to create.
# Every mode also carries the standing verification clause below, in the same words:
# a passing suite is not evidence the behavior is right. It sits directly after the
# fixed contract line so the principle precedes the mode-specific mechanics, and so
# bin/fm-spawn.sh still reads that line unchanged. Every obligation is
# applicability-scoped ("Where ..."), including the real-application one: a tooling,
# documentation, or configuration change with no user-facing surface has no running
# application to exercise, and an unconditional demand would make the clause a
# completion gate that lies for that whole category.
# The block opens with the fixed machine-readable "Delivery contract: mode=<mode>"
# line that bin/fm-spawn.sh checks a ship brief against.
# Every heredoc here stays outside a command substitution: `VAR=$(cat <<EOF ...)`
# breaks parsing of the whole file on Bash 3.2 (tests/fm-brief.test.sh).

IFS= read -r -d '' FM_DOD_VERIFY <<'FM_DOD_VERIFY_EOF' || true
Where the change has a user-facing surface, exercise it in the real running application before calling this done, not only in tests, and say what you exercised.
A passing unit or integration suite is not evidence the behavior is right.
Where the change could plausibly be timing-sensitive, exercise it under realistic latency rather than only on a fast local machine, and say what you used; this is a prompt to think about timing, not a hard gate on every trivial change.
Where you are fixing a defect, reproduce it before the fix and prove it gone after, stating the method.
For UI work, check a realistic desktop width and a narrow one, and be picky about alignment and fit.
FM_DOD_VERIFY_EOF
FM_DOD_VERIFY=${FM_DOD_VERIFY%$'\n'}

fm_dod_block() {  # <mode> <task-id> [<branch-name>]
  local mode=$1 branch=${3:-fm/$2}
  case "$mode" in
    direct-PR)
      cat <<EOF
# Definition of done
Delivery contract: mode=direct-PR
$FM_DOD_VERIFY

This task ships **direct-PR**: you raise the PR yourself, without the no-mistakes pipeline.
The task is complete only when committed on your branch.
When it is implemented and committed, push your branch and open a PR with \`gh-axi\`, then append \`done: PR {url}\` to the status file and stop.
Do NOT run /no-mistakes. The configured merge authority decides whether to merge the PR; firstmate relays the outcome.
EOF
      ;;
    local-only)
      cat <<EOF
# Definition of done
Delivery contract: mode=local-only
$FM_DOD_VERIFY

This task ships **local-only**: no remote, no PR, no pipeline.
The task is complete only when committed on your branch \`$branch\`. Do NOT push, do NOT open a PR, do NOT merge.
Keep your branch a clean fast-forward onto the current default branch - if \`main\` has advanced, rebase onto it so the eventual merge stays a fast-forward.
When it is implemented and committed, append \`done: ready in branch $branch\` to the status file and stop.
The configured merge authority approves the ready branch, then firstmate merges it into local \`main\` through the guarded fast-forward path.
EOF
      ;;
    no-mistakes)
      cat <<EOF
# Definition of done
Delivery contract: mode=no-mistakes
$FM_DOD_VERIFY

The task is complete only when committed on your branch.
When you believe it is complete, append \`done: {summary}\` to the status file and stop.
Firstmate will then instruct you to run /no-mistakes to validate and ship a PR.

You drive no-mistakes by responding to its gates, not by implementing fixes.
Follow the guidance no-mistakes itself provides for the mechanics: it loads when you invoke /no-mistakes, and \`no-mistakes axi run --help\` plus the \`help\` lines in each \`axi\` response are authoritative and version-matched to the installed binary.
When starting no-mistakes, make \`--intent\` preserve all relevant content from this brief's \`# Task\` section plus every later accepted Firstmate requirement, clarification, constraint, exclusion, and supersession, carrying only each requirement's current accepted form; retain direct requirements instead of substituting a diff summary, and exclude generic operational, status, delivery, and other scaffold boilerplate unless it is task-specific.
Do not hand-edit, commit, or fix findings yourself while a run is active - the pipeline applies every fix.

Two firstmate-specific rules layer on top of that guidance:
- ask-user findings are never yours to answer: escalate to firstmate (rule 6) and stop.
  Firstmate applies \`ask-user-authority\` and obtains any required captain decision.
  When the decision comes back, feed it to the gate with \`no-mistakes axi respond\` and let the pipeline apply it - do not route the question to "the user" or implement the fix yourself.
- NEVER pass \`--yes\` (or \`-y\`) to \`no-mistakes axi run\` or \`no-mistakes axi respond\`. It is banned fleet-wide.
  It auto-resolves every gate including ask-user findings with no escalation, and answering your own ask-user finding is a hard rule violation.

After /no-mistakes reports CI green (the CI-ready return point - do not wait for it to keep monitoring in the background until merge), append \`done: PR {url} checks green\` and stop. You are finished.
EOF
      ;;
    *)
      echo "error: fm_dod_block: unknown delivery mode '$mode'" >&2
      return 1 ;;
  esac
}
