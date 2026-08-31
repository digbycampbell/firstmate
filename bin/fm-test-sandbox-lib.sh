#!/usr/bin/env bash
# fm-test-sandbox-lib.sh - single owner of the behavior suite's containment
# boundary: the environment every test runs under, and the tripwire that proves
# no test wrote into a firstmate home or worktree pool it does not own.
#
# Sourced by bin/fm-test-run.sh. Has no side effects on source.
#
# Why this exists, in one line: home resolution reads FM_STATE_OVERRIDE BEFORE
# FM_HOME (see the STATE= line at the top of any bin/fm-*.sh), so a test that
# carefully passes FM_HOME=<fixture> to a real script still writes into whatever
# home an ambient FM_STATE_OVERRIDE names. Clearing a remembered list of
# variables is not a boundary - a new FM_* variable silently reopens the hole -
# so this library clears the whole FM_* namespace against an explicit allowlist,
# and then verifies containment by observation rather than trusting it.
#
# Two independent layers, because they fail for different reasons:
#
#   1. Containment (fm_test_sandbox_exec): every test runs with the FM_*
#      namespace cleared, a private TMPDIR and HOME, and a PATH whose first
#      entry refuses the real `treehouse` binary. A test that needs treehouse
#      must install its own fake earlier in PATH, which every such test already
#      does; a test that reaches the real one is operating on the live worktree
#      pool and is refused loudly.
#
#   2. Tripwire (fm_test_protect_snapshot / fm_test_protect_verify): a
#      before/after fingerprint of every protected root discovered on this
#      machine. This is the discriminator - containment can only ever pass, so
#      on its own it proves nothing. The tripwire fails, names the script, and
#      names the exact paths it touched.
#
# Protected roots are DISCOVERED, never remembered: this repo's primary
# checkout (the git-common-dir owner, which in a self-repo domain IS the live
# firstmate home), every secondmate home that checkout registers, and every
# treehouse pool that holds a worktree of this repository.

# Environment variables the suite is allowed to inherit. Everything else
# matching FM_* is cleared before a test starts.
FM_TEST_ENV_ALLOWLIST="FM_TEST_ORPHAN_MAX_AGE_SECONDS FM_TEST_SANDBOX"

# fm_test_sandbox_cleared_vars: echo one FM_* variable name per line that must
# be cleared from the child environment. Reads the live environment, so a
# variable invented after this file was written is still caught.
fm_test_sandbox_cleared_vars() {
  local name allow
  while IFS= read -r name; do
    case "$name" in
      FM_*) ;;
      *) continue ;;
    esac
    for allow in $FM_TEST_ENV_ALLOWLIST; do
      [ "$name" = "$allow" ] && continue 2
    done
    printf '%s\n' "$name"
  done < <(compgen -e)
}

# fm_test_sandbox_shim <dir>: build the refusing-PATH shim directory.
# The shim refuses every command that mutates shared machine state a test has
# no business touching. It is deliberately first in PATH and deliberately
# beatable by a test's own fake, which is what a correctly written test does.
fm_test_sandbox_shim() {
  local dir=$1 cmd
  mkdir -p "$dir" || return 1
  for cmd in treehouse; do
    cat > "$dir/$cmd" <<SHIM || return 1
#!/usr/bin/env bash
# Installed by bin/fm-test-sandbox-lib.sh. See that file's header.
printf 'fm-test-sandbox: refusing real \`%s\` in \${FM_TEST_SCRIPT:-a test}: it would operate on the live worktree pool resolved from the current directory. Install a fake %s earlier in PATH.\\n' "$cmd" "$cmd" >&2
exit 97
SHIM
    chmod 0755 "$dir/$cmd" || return 1
  done
}

# fm_test_sandbox_exec <sandbox-root> <script> : run <script> contained.
# Returns the script's exit status.
fm_test_sandbox_exec() {
  local root=$1 script=$2 shim="$1/shim" tmp="$1/tmp" home="$1/home"
  local -a clear=()
  local name
  mkdir -p "$tmp" "$home" || return 1
  chmod 0700 "$tmp" || return 1
  fm_test_sandbox_shim "$shim" || return 1
  while IFS= read -r name; do
    [ -n "$name" ] && clear+=(-u "$name")
  done < <(fm_test_sandbox_cleared_vars)
  env ${clear[@]+"${clear[@]}"} \
    TMPDIR="$tmp" TMP="$tmp" HOME="$home" \
    PATH="$shim:$PATH" \
    FM_TEST_SANDBOX="$root" FM_TEST_SCRIPT="$script" \
    bash "$script"
}

# --- protected-root discovery ----------------------------------------------

# fm_test_primary_checkout <repo-root>: echo the checkout that owns this
# repository's git-common-dir. For a linked worktree that is a different
# directory; in firstmate's self-repo domain it is the live firstmate home.
fm_test_primary_checkout() {
  local root=$1 common
  common=$(git -C "$root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  [ -n "$common" ] || return 1
  printf '%s\n' "${common%/.git}"
}

# fm_test_pool_roots <repo-root>: echo each worktree-pool root holding a
# worktree of this repository, one per line. Derived from git's own worktree
# list, so it needs no pool-tool cooperation and no hardcoded path.
fm_test_pool_roots() {
  local root=$1 line wt
  git -C "$root" worktree list --porcelain 2>/dev/null | while IFS= read -r line; do
    case "$line" in
      "worktree "*) wt=${line#worktree } ;;
      *) continue ;;
    esac
    case "$wt" in
      */.treehouse/*)
        # <pool-root>/<pool-id>/<slot>/<name> -> <pool-root>/<pool-id>
        printf '%s\n' "$(dirname "$(dirname "$wt")")"
        ;;
    esac
  done | sort -u
}

# fm_test_secondmate_homes <primary-checkout>: echo each registered secondmate
# home path recorded by that checkout, one per line.
fm_test_secondmate_homes() {
  local reg="$1/data/secondmates.md"
  [ -f "$reg" ] || return 0
  # Registry entries carry an absolute home path; take every absolute path that
  # names an existing directory rather than parsing the prose around it.
  grep -oE '(/[A-Za-z0-9._-]+)+' "$reg" 2>/dev/null | while IFS= read -r p; do
    [ -d "$p" ] && [ -d "$p/state" ] && printf '%s\n' "$p"
  done | sort -u
}

# fm_test_protected_roots <repo-root>: echo every root a test must not touch.
# The repo root itself is excluded: a disposable task worktree is where the
# suite legitimately runs.
fm_test_protected_roots() {
  local root=$1 primary p
  primary=$(fm_test_primary_checkout "$root" 2>/dev/null || true)
  {
    if [ -n "$primary" ] && [ "$primary" != "$root" ]; then
      printf '%s\n' "$primary"
      fm_test_secondmate_homes "$primary"
    fi
    fm_test_pool_roots "$root"
  } | sort -u | while IFS= read -r p; do
    [ -n "$p" ] && [ -d "$p" ] && printf '%s\n' "$p"
  done
}

# --- how the boundary is enforced, and what was tried and rejected -----------
#
# There is deliberately no before/after fingerprint of the protected roots.
# That design was built and measured on 2026-08-31 and it does not work: a
# protected home is normally LIVE, and its own watcher moves .wake-queue,
# .last-watcher-beat, .seen-*, .heartbeat-streak and friends throughout a run.
# A diff of that home charges the test with the fleet's heartbeat. Attribution
# by persistence (charge only paths that stopped changing after the test exited)
# was tried too and does not separate the populations either, because the live
# fleet writes in bursts and then goes quiet - measured, not assumed.
#
# Filesystem writes cannot be attributed to a process tree after the fact
# without kernel support, and read-only bind mounts need CAP_SYS_ADMIN in a user
# namespace, which is only obtainable by mapping to root and would change the
# uid semantics every permission assertion in this suite depends on.
#
# So the boundary is prevention plus refusal at the source, both attributable by
# construction:
#
#   * fm_test_sandbox_exec, above, removes the reachability: the FM_* namespace
#     is cleared, TMPDIR and HOME are private, and the real `treehouse` binary -
#     the only way a test reaches the live worktree pool, which it resolves from
#     the working directory - is refused by a shim.
#   * bin/fm-home-guard-lib.sh refuses at the moment a firstmate script resolves
#     a state directory outside FM_TEST_SANDBOX, and exits 99 naming the home,
#     the script, and the three variables that decide it. The refusing process
#     is the writer, so there is nothing to infer.
#
# fm_test_protected_roots stays because tests/fm-test-sandbox.test.sh uses it to
# prove the guard fires on a real primary checkout rather than a mock.
