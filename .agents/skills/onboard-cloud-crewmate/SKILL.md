---
name: onboard-cloud-crewmate
description: >-
  Turn one GitHub issue (or a plan and its phases) into a self-contained handoff prompt for an agent running alone in a cloud container, with a readiness verdict and a model recommendation.
  Use when the captain invokes /onboard-cloud-crewmate <issue>, asks for a cloud or container prompt for an issue, or asks whether an issue is ready to hand off.
user-invocable: true
metadata:
  internal: true
---

# onboard-cloud-crewmate

The container agent has no firstmate: no brief scaffold, no status file, no steering, no gates driven for it, nobody to answer a question.
Everything it needs must be in the prompt, and everything it cannot do alone must be said up front.
Firstmate stays read-only throughout: this skill dispatches nothing and edits no issue.

## 1. Read the contract

Read the issue in full with comments, its parent plan if it is a phase, and every sibling phase's ordering section.
Read the project's `AGENTS.md`, `docs/ci-mechanics.md`, and the header of each script the delivery needs.
Sweep for prior work: grep `main` for the issue's subject and check merged PR titles, so a built issue is reported as built rather than handed off again.
Done when you can state in one sentence what changes, where, and how it will be proven.

## 2. Judge readiness

Answer each, with evidence from the issue text and the code as it is on `main` today:

- Contract: does it name the behaviour, the owners (files), and acceptance criteria that can fail on a reachable broken state?
- Currency: do the named owners and line references still match `main`, or has later work moved them? Stale references are a note in the prompt, not a blocker; a missing owner is.
- Dependencies: does it wait on an unmerged PR, a sibling phase, a migration, a secret, or a decision the captain has not made?
- Product judgement: does any criterion need the captain's eye (visual polish, copy, an unspecified choice)? Name it; the container cannot ask.

Verdict is one of `ready`, `ready with notes` (list them; they go into the prompt), or `not ready` (say what is missing and who supplies it).
Check whether the target repo has GitHub stacked pull requests (public preview) enabled and say so in the verdict; the prompt's branch convention names the fallback when it is not.

## 3. Judge standalone fit

The container agent can carry a task alone when every gate it will meet is mechanical: tests, lint, Discipline, a PR it opens itself.
It cannot carry: a no-mistakes pipeline (the daemon is not in the container), an ask-user gate, a merge, a preview deploy for UAT, a cross-repo seam, or a decision the issue leaves open.
For each of those the prompt must say what the agent does instead: stop and report, or leave the step to the captain.
Done when the prompt's stop conditions are listed and none of them is "ask".

For a plan phase specifically: the first phase, and any phase whose predecessor has already merged, are fine for a container.
A phase whose predecessor is still an open PR is fine only with the branch and stacking convention in the template's Pull request section and a named base branch.
A phase that needs a decision the plan leaves open, a preview UAT, or a cross-repo release is not fit for a container; say so in the verdict.

## 4. Judge the environment

From the repo's scripts and CI, list what the container must provide: language runtime and version, submodules, database engine and version, browsers, the slot-lease tooling, and any secret that is genuinely required (usually none for a build-and-test task).
Name the heavy runs and their cost on this project's own box, so the captain sizes the container: the CI-shaped e2e suite is the usual one.
State the CI posture: by default the forge re-runs the full lanes on the PR, so the container runs only the focused specs covering the change plus the running-app check; ask for the full local suite only when the forge is skipping lanes for this task.

## 5. Recommend a model

Same rule as crew dispatch: the minimum strength you are confident finishes it, judged by shape.
A bounded single-surface change with clear criteria: a mid-tier model at medium effort.
Anything that must self-triage flakes, drive a long e2e run, resolve conflicts, or carry a multi-phase plan: the strongest tier at medium effort.
State the pick and the reason in one line; the captain may override.

## 6. Write the prompt

Fill [`references/prompt-template.md`](references/prompt-template.md) section by section; leave nothing as a placeholder.
Rules the template does not carry for you:

- The issue text is the contract. Quote its acceptance criteria by reference, never paraphrase them into something weaker.
- Put the readiness notes from step 2 under the issue-specific section, each as an instruction the agent can act on.
- Never write the word the project retires (`captain` in fcdispatch); say "the project owner".
- The branch and stacking convention lives only in the template's Pull request section; fill its bracket for a phase with the named predecessor branch, and do not restate the convention anywhere else in the prompt.
- Keep it in one code block the captain can paste whole.

Done when a reader with only the prompt and repo access could start work and knows exactly when to stop.

## 7. Report and record

Reply with the verdict, the prompt in its code block, the model line, and the container sizing.
File the issue as a held backlog item noting it is handed to a cloud container, so no firstmate dispatch duplicates it; when the container's PR appears, the ordinary PR-ready path takes over.
