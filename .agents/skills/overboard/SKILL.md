---
name: overboard
description: >-
  Clean up a finished worker whose worktree, branch, or backend endpoint still occupies the machine.
  Use when the captain invokes /overboard with a task id, asks to remove a finished worker's leftovers, or asks to find stale finished workers.
user-invocable: true
metadata:
  internal: true
---

# overboard

Use this procedure only for a finished worker whose delivery is already safe at the forge.
It routes cleanup through the existing state, teardown, forge, and backend owners.
Every ambiguous read leaves the worker's pane, worktree, branch, and task records intact for inspection.

## Find candidates

When the captain supplies a task id, inspect only that task in its recorded home.
When the captain asks for stale finished workers, use `bin/fm-fleet-view.sh --json` to find task metadata whose current state or backlog record is done while its endpoint or worktree remains present.
Repeat the search inside a registered secondmate's own home when that home owns the task.
Treat the fleet view as a candidate list, then run the complete proof below for every candidate.
Do not sweep a shared endpoint namespace or claim an endpoint from its label alone.

## Prove completion

1. Read the complete `state/<id>.status` log and require a terminal `done:` event for this task.
   The status proof is complete only when the event names the delivered PR or pushed branch without an unresolved later failure or hold.
2. Run `bin/fm-crew-state.sh <id>` and require `done`.
   A working, parked, blocked, paused, failed, or unknown result stops cleanup with every trace preserved.
3. Read the task metadata and capture its home, project, worktree, backend, exact endpoint, and recorded PR before teardown can retire those records.
   Read the current branch and remote from that exact worktree and project.
   Missing, duplicate, or contradictory identity fields stop cleanup.
4. For PR work, run `gh-axi pr view <recorded-pr>` from the recorded project and require the forge's `merged` field to be affirmative.
   Pane output, a resume banner, local Git history, a closed PR, and green checks are not merge evidence.
5. For work without a PR, fetch the recorded remote, prove the task branch's exact HEAD exists on that remote, and require the task's structured backlog record to be in Done.
   This alternate proof permits guarded teardown, but it never permits remote-branch deletion.

The completion proof is satisfied only when the status evidence, current-state read, task identity, and one forge path all agree.
Any ambiguity ends the procedure with a report naming the missing proof.

## Return the worktree

Run `bin/fm-teardown.sh <id>` from the task's recorded home without `--force`.
This command owns the complete landed-work test, process cleanup, local branch cleanup, endpoint cleanup, durable-record retirement, and pool-slot return.
A refusal is the result of this attempt, so preserve its output and stop without bypassing or reproducing its checks.
The worktree step is complete only when teardown confirms the recorded worktree was returned or was already absent safely.

## Tidy the remote branch

Delete the captured remote branch only when the same recorded PR still reads merged at the forge after teardown.
Require the PR head branch to match the captured branch before deletion.
Use the captured explicit remote and branch names, and verify the exact remote ref is absent afterward.
Keep any branch with unmerged commits, a missing PR, a non-merged PR, a head mismatch, or an unreadable forge response.

## Close residual occupancy

Teardown normally removes the endpoint, so inspect the captured exact endpoint only when it remains afterward.
Source `bin/fm-backend.sh` and use `fm_backend_agent_state <backend> <endpoint>` as the recovery-grade ownership check.
Only `dead` or `missing` proves that no live agent owns the endpoint.
An `alive`, `ambiguous`, `unreadable`, or `unverified` result keeps the endpoint open and becomes the reported result.

For Herdr, use `fm_backend_kill herdr <endpoint>`, which dispatches to `fm_backend_herdr_kill` in `bin/backends/herdr.sh`.
That helper owns the presentation lock, exact-pane close, focus restoration, and focus-safety refusals.
Honor every refusal and never replace it with a raw `herdr pane close` command.
For tmux, use `fm_backend_kill tmux <endpoint>`, which validates the exact target before `tmux kill-window`.
Run the recovery-grade ownership check again after the close and require `missing` before calling the endpoint removed.

Residual endpoint closure also requires the captured forge proof to remain valid at the close boundary.
If that proof cannot be refreshed, keep the endpoint open.

## Report

Report one line for each trace, including traces that were already absent or deliberately retained.

- Report the pane as `pane: removed|absent|retained - <agent-state and exact endpoint evidence>`.
- Report the worktree as `worktree: returned|absent|retained - <fm-teardown result>`.
- Report the branch as `branch: deleted|absent|retained - <remote ref and merged-PR evidence>`.

## Worked example from 2026-08-28

The fcd-ci secondmate finished `fcd-nightly-full-suite-dead` and delivered its PR, but its Herdr pane stayed open after the Claude agent exited.
The pane showed Claude's resume banner above a bare shell parked in the task worktree, which made it a candidate rather than proof that cleanup was safe.
The overboard pass had to confirm the task's `done:` event, refresh the PR's merged field with `gh-axi`, return the worktree through `bin/fm-teardown.sh`, and classify the exact recorded Herdr pane as agent-free before closing any residual pane.
Nobody needed to own the bare shell, but the proof had to own every destructive step.
