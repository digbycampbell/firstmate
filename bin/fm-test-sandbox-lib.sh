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
#      namespace cleared, a private TMPDIR, and a PATH whose first entry
#      refuses the real `treehouse` binary.
#
#      HOME is deliberately NOT overridden. The guarantee does not need it - it
#      rests on the FM_* clearing, the resolution-time home guard, and the
#      treehouse shim - and overriding it breaks the real-harness gated tests,
#      which legitimately read a tool's own state under the real HOME. Measured:
#      with a private HOME, tests/fm-afk-inject-herdr-e2e.test.sh cannot see the
#      running Herdr default session and fails its fleet-state tripwire. A test that needs treehouse
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

# fm_test_sandbox_shim <dir> <pool>: build the redirecting-PATH shim directory.
#
# The boundary being enforced is "never operate on a worktree pool this run does
# not own" - NOT "never run treehouse". Those are different, and the difference
# matters: bin/fm-spawn.sh sends a literal `treehouse get` into the spawned
# pane and waits 60s for its cwd to move into a worktree, so a shim that simply
# refused turned four real-harness spawn tests into 60s timeouts while proving
# nothing. Those tests were genuinely consuming LIVE pool leases, which is the
# 2026-08-31 pool incident, so they must keep exercising the real binary - just
# never against the real pool.
#
# So the shim redirects rather than refuses: it runs the real treehouse with
# TREEHOUSE_ROOT pointed at a pool inside this sandbox, and refuses loudly only
# when an explicit --root would escape that sandbox (an explicit --root beats
# TREEHOUSE_ROOT, so it is the one way left to reach the live pool).
#
# It is installed ONLY when a real treehouse exists, so that on a machine
# without one - standard CI - absence stays absence and every caller's
# not-found fallback behaves exactly as it does today.
fm_test_sandbox_shim() {
  local dir=$1 pool=$2 real
  mkdir -p "$dir" "$pool" || return 1
  real=$(PATH=${PATH#"$dir":} command -v treehouse 2>/dev/null) || real=""
  [ -n "$real" ] || return 0
  cat > "$dir/treehouse" <<SHIM || return 1
#!/usr/bin/env bash
# Installed by bin/fm-test-sandbox-lib.sh. See that file's header.
set -u
# Read at RUN time, never baked in: an install-time expansion is empty here,
# which would turn an allow-glob into "/*" and match every absolute path.
sandbox=\${FM_TEST_SANDBOX:-}
pool='$pool'
real='$real'

# Only an explicit --root can still escape, because it beats TREEHOUSE_ROOT.
want=""
expect_value=0
for arg in "\$@"; do
  if [ "\$expect_value" = 1 ]; then
    want=\$arg
    expect_value=0
    continue
  fi
  case "\$arg" in
    --root) expect_value=1 ;;
    --root=*) want=\${arg#--root=} ;;
  esac
done

if [ -n "\$want" ]; then
  resolved=\$(CDPATH='' cd -- "\$want" 2>/dev/null && pwd -P) || resolved=\$want
  allowed=0
  case "\$resolved/" in
    "\$pool"/*) allowed=1 ;;
  esac
  if [ -n "\$sandbox" ]; then
    case "\$resolved/" in
      "\$sandbox"/*) allowed=1 ;;
    esac
  fi
  if [ "\$allowed" != 1 ]; then
    printf 'fm-test-sandbox: refusing \`treehouse --root %s\` in %s: that pool is outside this test sandbox, and operating on a live worktree pool is how the 2026-08-31 run lost two leases. Drop --root to use the sandbox pool.\n' \
      "\$want" "\${FM_TEST_SCRIPT:-a test}" >&2
    exit 97
  fi
fi

export TREEHOUSE_ROOT="\$pool"
exec "\$real" "\$@"
SHIM
  chmod 0755 "$dir/treehouse" || return 1
}

# fm_test_sandbox_exec <sandbox-root> <script> : run <script> contained.
# Returns the script's exit status.
fm_test_sandbox_exec() {
  local root=$1 script=$2 shim="$1/shim" tmp="$1/tmp" pool="$1/pool"
  local -a clear=()
  local name
  mkdir -p "$tmp" "$pool" || return 1
  chmod 0700 "$tmp" || return 1
  fm_test_sandbox_shim "$shim" "$pool" || return 1
  while IFS= read -r name; do
    [ -n "$name" ] && clear+=(-u "$name")
  done < <(fm_test_sandbox_cleared_vars)
  env ${clear[@]+"${clear[@]}"} \
    TMPDIR="$tmp" TMP="$tmp" TREEHOUSE_ROOT="$pool" \
    PATH="$shim:$PATH" \
    FM_TEST_SANDBOX="$root" FM_TEST_SCRIPT="$script" \
    FM_TEST_OWN_ROOT="${FM_TEST_OWN_ROOT:-$ROOT}" \
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
#     is cleared, TMPDIR is private, and the real `treehouse` binary -
#     the only way a test reaches the live worktree pool, which it resolves from
#     the working directory - is refused by a shim.
#   * bin/fm-home-guard-lib.sh refuses at the moment a firstmate script resolves
#     a state directory outside FM_TEST_SANDBOX, and exits 99 naming the home,
#     the script, and the three variables that decide it. The refusing process
#     is the writer, so there is nothing to infer.
#
# fm_test_protected_roots stays because tests/fm-test-sandbox.test.sh uses it to
# prove the guard fires on a real primary checkout rather than a mock.
