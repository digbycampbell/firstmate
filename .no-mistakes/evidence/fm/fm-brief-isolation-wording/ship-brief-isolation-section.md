# Setup
You are in a disposable git worktree of some-proj, at a detached HEAD on a clean default branch.

**Verify isolation before anything else, by structure, not by any directory label a harness banner prints - that label names where the harness started, not which checkout this is.** Run `pwd -P` and `git rev-parse --show-toplevel`; both must resolve to the disposable task worktree you were launched in, such as a treehouse pool path or an Orca-managed worktree, sitting at a detached HEAD. Firstmate's own permanent clone is different in kind: it always sits on its default branch at an attached HEAD, never detached. In the common case it lives under a firstmate home's `projects/<repo>` directory; in a project-less self-repo domain there is no such clone and the firstmate home is itself that checkout, its own repository root on its default branch.
The path check is authoritative: `git rev-parse --git-dir` and `git rev-parse --git-common-dir` can help inspect the repo, but they do not prove you are outside firstmate's permanent clone.
If the top-level path sits under a firstmate home's `projects/<repo>` clone on its default branch, or is a firstmate home's own checkout on its default branch, or is otherwise not the detached-HEAD worktree you were launched in, STOP - do not branch or commit here - append `blocked: launched in firstmate's permanent clone, not an isolated worktree` to the status file and stop.

1. First action: create your branch: `git checkout -b fm/demo-ship`
