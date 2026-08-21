# Git identity verification

Audience: maintainer verification.

This record supports the current guarantee that a firstmate-managed commit carries a firstmate identity, and that arming a task worktree cannot relabel the captain's own commits in the same clone.
`bin/fm-git-identity.sh`'s header owns the commands and the mechanism; `bin/fm-git-identity-lib.sh` owns the identities and the allowlist.
`tests/fm-git-identity.test.sh` is the portable regression that keeps these properties enforced.

## Identities

| Role | Identity |
| --- | --- |
| Crewmates and scouts, per task worktree | `digio crew <crew@digio.nz>` |
| Firstmate's own direct commits | `firstmate <firstmate@digio.nz>` |

Neither address belongs to a GitHub account, which is deliberate: an unlinked address renders as a plain name rather than attributing agent work to a person.
Verified against a pre-existing example on 2026-08-21: `digio-nz/digio-os` commit `a253621`, authored `crewmate@digio.nz`, returns `author: null` from the GitHub commits API.

The captain's own `digbycampbell <96467498+digbycampbell@users.noreply.github.com>` is deliberately absent from the allowlist.
It stays configured globally for his own terminal work; it is simply not an identity firstmate's tooling may create a commit with.

## Per-worktree configuration applies in a pooled linked worktree

Checked 2026-08-21 with git 2.53.0 on Linux 6.18.33.2 (WSL2).

Firstmate's pooled task worktrees are linked worktrees: the worktree's `.git` is a file pointing at `<clone>/.git/worktrees/<name>`, so a plain `git config user.email` there writes the clone's shared config.
Observed in a live treehouse pool worktree of this repo:

```console
$ cat .git
gitdir: /home/digby/devs/firstmate/.git/worktrees/firstmate5
$ git rev-parse --git-dir --git-common-dir
/home/digby/devs/firstmate/.git/worktrees/firstmate5
/home/digby/devs/firstmate/.git
```

Git's worktree-config extension is per-worktree for `user.*` and for `core.hooksPath` alike, so both can be set without touching the shared config:

```console
$ git config extensions.worktreeConfig true
$ git config --worktree user.email crew@digio.nz
$ git commit --allow-empty -m x
$ git log -1 --format='%an <%ae>'
Crew <crew@digio.nz>
$ git -C ../parent log -1 --format='%an <%ae>'      # after its own commit
Parent <parent@example.com>
$ git -C ../parent config --local user.email
parent@example.com
$ git config --worktree core.hooksPath /tmp/wtx/hooks   # hook fires in the worktree only
```

`extensions.worktreeConfig` itself is the one key that lands in shared config.
It enables the mechanism and carries no identity.
Git treats `core.bare` and `core.worktree` as always-worktree-specific once the extension is on, so `apply-worktree` refuses a clone that carries either in shared config rather than migrating someone else's configuration.

## End-to-end exercise

Run 2026-08-21 against a scratch clone configured exactly like the machine that produced the incident: the captain's identity in the clone, one linked worktree, and a repo that already sets `core.hooksPath=.githooks`.

```console
$ bin/fm-git-identity.sh apply-worktree /tmp/idt/wt1 --hooks-dir /tmp/idt/hooks-task1
fm-git-identity: /tmp/idt/wt1 is armed as digio crew <crew@digio.nz>, guard at /tmp/idt/hooks-task1
$ git -C /tmp/idt/wt1 commit -m 'crew commit'
REPO-PRE-COMMIT RAN
$ git -C /tmp/idt/wt1 log -1 --format='%an <%ae> | %cn <%ce>'
digio crew <crew@digio.nz> | digio crew <crew@digio.nz>
$ git -C /tmp/idt/parent log -1 --format='%an <%ae>'
digbycampbell <96467498+digbycampbell@users.noreply.github.com>
```

The parent clone's `[user]` block was byte-identical before and after; the only added shared key was `extensions.worktreeConfig = true`.
The repo's own `pre-commit` still ran and its `pre-push` was carried into the generated hooks directory, so taking over `hooksPath` adds the identity guard without disarming an existing one.

Refusal, with the worktree identity removed to reproduce the incident state:

```console
$ git -C /tmp/idt/wt1 commit -m 'should be refused'
refusing: this commit's author would be digbycampbell <96467498+digbycampbell@users.noreply.github.com>
refusing: this commit's committer would be digbycampbell <96467498+digbycampbell@users.noreply.github.com>
Only firstmate identities may author a firstmate-managed commit:
  digio crew <crew@digio.nz>   (crewmates and scouts, set per task worktree)
  firstmate <firstmate@digio.nz>   (firstmate itself, via bin/fm-git-identity.sh commit)
...
$ echo $?
1
```

Missing prerequisite, with the guard executable made unreachable:

```console
$ git -C /tmp/idt/wt1 commit -m 'guard gone'
refusing this commit: firstmate's identity guard (/tmp/idt/definitely-not-here.sh) is missing or not executable.
The guard cannot verify who this commit would be authored as, so it refuses rather than passes.
$ echo $?
1
```

Firstmate's own direct commit in the same clone:

```console
$ bin/fm-git-identity.sh commit -m 'firstmate direct'
$ git log -1 --format='%an <%ae> | %cn <%ce>'
firstmate <firstmate@digio.nz> | firstmate <firstmate@digio.nz>
$ git config --local user.email
96467498+digbycampbell@users.noreply.github.com
```

## Layering against the dotfiles pre-push guard

`digio-nz/.dotfiles` ships a shared `githooks/pre-push` secret guard, installed per repo and opt-in.
It is complementary, not a duplicate: it runs at push time on repository content, while this guard runs at commit time on commit metadata.
Push time is specifically the wrong place for the identity check, because the incident's commits existed for hours before anyone pushed them and the rejection only arrived after a validation run had been spent.
The generated hooks directory chains every hook the repo already had, so a repo that has opted into the dotfiles guard keeps it while a firstmate task worktree is armed.
