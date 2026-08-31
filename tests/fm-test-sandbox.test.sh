#!/usr/bin/env bash
# Behavior tests for the behavior suite's own containment boundary
# (bin/fm-test-sandbox-lib.sh, wired into both paths of bin/fm-test-run.sh).
#
# The guarantee under test is that no test can write into a firstmate home or
# worktree pool it does not own. That guarantee is worthless if the guard can
# only ever pass, so every case here is built around a deliberate violation and
# a near-identical clean control: the leak cases must fail, the control cases
# must pass, and each pair differs by exactly the one thing being asserted.
#
# The protected roots are not mocked or injected. The suite builds a real
# primary checkout plus a real linked git worktree, runs the real runner from
# the worktree, and lets discovery find the primary the same way it finds the
# live firstmate home on this machine. There is no override that could point
# the guard somewhere harmless.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-test-sandbox)

# shellcheck source=bin/fm-test-sandbox-lib.sh
. "$ROOT/bin/fm-test-sandbox-lib.sh"

# --- a real primary checkout with a real linked worktree --------------------

PRIMARY="$TMP_ROOT/primary"
WT="$TMP_ROOT/wt"

build_world() {
  mkdir -p "$PRIMARY"
  cp -R "$ROOT/bin" "$PRIMARY/bin"
  cp "$ROOT/AGENTS.md" "$PRIMARY/AGENTS.md"
  git -C "$PRIMARY" init -q
  git -C "$PRIMARY" config user.email fm-test@example.invalid
  git -C "$PRIMARY" config user.name 'fm test'
  git -C "$PRIMARY" add -A
  git -C "$PRIMARY" commit -qm 'fixture'
  git -C "$PRIMARY" worktree add -q -f "$WT" HEAD
  # A firstmate home's mutable directories. Discovery requires state/ to exist.
  mkdir -p "$PRIMARY/state" "$PRIMARY/data" "$PRIMARY/config"
}
build_world

# run_fixture <name> <body>: write a fixture test script and run it through the
# real runner from the linked worktree. Echoes "<exit>" and leaves output in
# $TMP_ROOT/<name>.out.
run_fixture() {
  local name=$1 body=$2 script rc
  script="$TMP_ROOT/$name.test.sh"
  printf '#!/usr/bin/env bash\n%s\n' "$body" > "$script"
  ( cd "$WT" && bash "$WT/bin/fm-test-run.sh" "$script" ) > "$TMP_ROOT/$name.out" 2>&1
  rc=$?
  printf '%s\n' "$rc"
}

# --- discovery --------------------------------------------------------------

roots=$(fm_test_protected_roots "$WT")
case "$roots" in
  *"$PRIMARY"*) pass "discovery finds the primary checkout that owns the worktree's git-common-dir" ;;
  *) fail "discovery missed the primary checkout; got: ${roots:-<empty>}" ;;
esac
case "$roots" in
  *"$WT"*) fail "discovery protected the worktree the suite legitimately runs in" ;;
  *) pass "discovery excludes the disposable worktree the suite runs in" ;;
esac

# --- refusal at the source --------------------------------------------------
#
# This is the enforced guarantee. A firstmate script that resolves a home
# outside the sandbox exits 99 naming the home, so a leak is attributable to
# the process that would have written it.

# The exact 2026-08-31 mechanism: the test passes a fixture home explicitly,
# but FM_STATE_OVERRIDE is read AHEAD of FM_HOME, so an ambient override wins
# and the real script operates on the live home instead.
rc=$(run_fixture ambient-override "fixture=\$TMPDIR/fixture-home
mkdir -p \"\$fixture/state\"
out=\$(FM_HOME=\"\$fixture\" '$WT/bin/fm-procevent.sh' list 2>&1)
grc=\$?
[ \"\$grc\" = 99 ] && { echo \"not ok - a correctly passed fixture home was refused: \$out\"; exit 1; }
echo 'ok - the fixture home is accepted'
# Now the incident: an ambient override pointing at a home this test does not own.
out=\$(FM_STATE_OVERRIDE='$PRIMARY/state' FM_HOME=\"\$fixture\" '$WT/bin/fm-procevent.sh' list 2>&1)
grc=\$?
[ \"\$grc\" = 99 ] || { echo \"not ok - an ambient FM_STATE_OVERRIDE onto a foreign home was not refused (exit \$grc): \$out\"; exit 1; }
case \"\$out\" in *'ISOLATION FAILURE'*) ;; *) echo \"not ok - the refusal did not identify itself: \$out\"; exit 1 ;; esac
case \"\$out\" in *'$PRIMARY/state'*) ;; *) echo \"not ok - the refusal did not name the home: \$out\"; exit 1 ;; esac
echo 'ok - the foreign home is refused'")
[ "$rc" = "0" ] || {
  cat "$TMP_ROOT/ambient-override.out" >&2
  fail "the 2026-08-31 mechanism was not refused: FM_STATE_OVERRIDE still beats an explicitly passed FM_HOME"
}
pass "a script steered onto a foreign home by ambient FM_STATE_OVERRIDE is refused at resolution, naming the home"

# Every script that resolves a firstmate home from FM_STATE_OVERRIDE/FM_HOME
# must carry the guard, or the boundary is only as good as whichever scripts
# someone remembered. Each one is RUN against a home it does not own; nothing
# here reads a script's source to decide.
#
# Two acceptable outcomes, because a script whose no-argument path is a usage
# message or an inert no-op exits before it resolves anything: it must either
# refuse, or leave the foreign home untouched. Proceeding into a home the test
# does not own is the failure.
FOREIGN="$TMP_ROOT/foreign"
SANDBOX="$TMP_ROOT/sandbox"
mkdir -p "$FOREIGN/state" "$SANDBOX"

probe_script() {  # <script-path> -> echoes "refused" | "untouched" | "wrote"
  local f=$1 before after out
  before=$(find "$FOREIGN" | LC_ALL=C sort)
  out=$(FM_TEST_SANDBOX="$SANDBOX" FM_STATE_OVERRIDE="$FOREIGN/state" FM_HOME="$FOREIGN" \
    timeout 20 bash "$f" </dev/null 2>&1)
  case "$out" in
    *'fm-home-guard: ISOLATION FAILURE'*) printf 'refused\n'; return ;;
  esac
  after=$(find "$FOREIGN" | LC_ALL=C sort)
  if [ "$before" = "$after" ]; then printf 'untouched\n'; else printf 'wrote\n'; fi
}

home_resolving_scripts() {
  grep -l 'STATE="${FM_STATE_OVERRIDE' "$ROOT"/bin/fm-*.sh
}

scripts=$(home_resolving_scripts)
[ -n "$scripts" ] || fail "found no home-resolving scripts to probe; the selection is broken"
[ "$(printf '%s\n' "$scripts" | wc -l)" -ge 20 ] \
  || fail "only $(printf '%s\n' "$scripts" | wc -l) home-resolving scripts found; the selection is too narrow to be meaningful"

wrote=""
refused_count=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  case "$(probe_script "$f")" in
    refused) refused_count=$((refused_count + 1)) ;;
    wrote) wrote="$wrote $(basename "$f")" ;;
  esac
done <<< "$scripts"

[ -z "$wrote" ] || fail "these scripts wrote into a firstmate home the test does not own:$wrote"
pass "no bin/fm-*.sh that resolves a home can write into one outside the sandbox"

# The count matters: if every script merely exited early, the case above would
# pass while proving nothing.
[ "$refused_count" -ge 20 ] \
  || fail "only $refused_count home-resolving scripts actually refused; the rest exited early, so this proves nothing"
pass "$refused_count home-resolving scripts refuse a foreign home outright"

# The scripts that actually leaked on 2026-08-31 must refuse outright, not
# merely happen to exit early: the writers of the phantom task records, the
# registered process-event sources and the armed watch specs.
for probe in fm-spawn.sh fm-procevent.sh fm-procevent-when.sh fm-send.sh fm-teardown.sh fm-home-seed.sh; do
  [ "$(probe_script "$ROOT/bin/$probe")" = refused ] \
    || fail "$probe did not refuse a firstmate home outside the sandbox"
done
pass "every script implicated in the 2026-08-31 leak refuses a foreign home outright"

# The control. Without it the case above proves only that the guard refuses
# everything, which would be indistinguishable from a broken suite.
rc=$(run_fixture guard-control "fixture=\$TMPDIR/own-home
mkdir -p \"\$fixture/state\"
out=\$(FM_HOME=\"\$fixture\" '$WT/bin/fm-procevent.sh' list 2>&1)
grc=\$?
case \"\$out\" in *'ISOLATION FAILURE'*) echo \"not ok - a home the test owns was refused: \$out\"; exit 1 ;; esac
[ \"\$grc\" != 99 ] || { echo 'not ok - a home the test owns exited 99'; exit 1; }
echo 'ok - a home the test owns is accepted'")
[ "$rc" = "0" ] || {
  cat "$TMP_ROOT/guard-control.out" >&2
  fail "a fixture home inside the sandbox was refused; the guard is not discriminating"
}
pass "a fixture home the test created inside its own sandbox is still accepted"

# The guard must be completely inert in production, or it would refuse the
# captain's own fleet. Same command, no sandbox marker.
out=$(FM_STATE_OVERRIDE="$PRIMARY/state" FM_HOME="$PRIMARY" bash "$WT/bin/fm-procevent.sh" --help 2>&1)
case "$out" in
  *'ISOLATION FAILURE'*) fail "the guard fired outside the test suite: $out" ;;
esac
pass "the guard is inert when FM_TEST_SANDBOX is unset, so production runs are untouched"

# --- the worktree pool ------------------------------------------------------
#
# `treehouse` resolves its pool from the working directory, so a test that
# reaches the real binary operates on the live pool that holds this repo's
# worktrees - which on 2026-08-31 lost two leases and handed an occupied slot
# out three times. Prevented, not detected: there is no way to attribute a pool
# mutation after the fact either.

rc=$(run_fixture treehouse-real 'out=$(treehouse list 2>&1); trc=$?
[ "$trc" = "97" ] || { echo "not ok - real treehouse was not refused (exit $trc)"; exit 1; }
case "$out" in *"refusing real"*) ;; *) echo "not ok - refusal did not explain itself: $out"; exit 1 ;; esac
echo "ok - real treehouse refused"')
[ "$rc" = "0" ] || {
  cat "$TMP_ROOT/treehouse-real.out" >&2
  fail "the real treehouse binary was reachable from a test"
}
pass "a test reaching the real treehouse binary is refused loudly"

# A test that installs its own fake still wins, which is what every test that
# legitimately exercises the pool already does.
rc=$(run_fixture treehouse-fake 'fb=$TMPDIR/fakebin; mkdir -p "$fb"
printf "#!/usr/bin/env bash\necho faked\n" > "$fb/treehouse"; chmod +x "$fb/treehouse"
out=$(PATH="$fb:$PATH" treehouse list 2>&1)
[ "$out" = "faked" ] || { echo "not ok - a test fake did not win over the shim: $out"; exit 1; }
echo "ok - test fake wins"')
[ "$rc" = "0" ] || {
  cat "$TMP_ROOT/treehouse-fake.out" >&2
  fail "a test's own treehouse fake did not take precedence over the refusing shim"
}
pass "a test's own fake still takes precedence over the refusing shim"

# --- the environment hole that caused the incident --------------------------

ENVPROBE='vars=$(tr "\0" "\n" < /proc/$$/environ | grep -c "^FM_STATE_OVERRIDE=" || true)
[ "$vars" = "0" ] || { echo "not ok - FM_STATE_OVERRIDE reached the test process"; exit 1; }
[ -z "${FM_HOME:-}" ] || { echo "not ok - FM_HOME reached the test process"; exit 1; }
[ -n "${FM_TEST_SANDBOX:-}" ] || { echo "not ok - the sandbox marker is absent"; exit 1; }
case "$TMPDIR" in "$FM_TEST_SANDBOX"/*) ;; *) echo "not ok - TMPDIR is outside the sandbox"; exit 1 ;; esac
echo "ok - environment is contained"'

rc=$(FM_HOME=/home/nonexistent-fixture \
     FM_STATE_OVERRIDE=/home/nonexistent-fixture/state \
     run_fixture envclear "$ENVPROBE")
[ "$rc" = "0" ] || {
  cat "$TMP_ROOT/envclear.out" >&2
  fail "an ambient FM_HOME/FM_STATE_OVERRIDE reached the test process"
}
pass "ambient FM_* variables never reach a test, proven through /proc/<pid>/environ"

# The whole namespace is cleared, not a remembered list: a variable this
# library has never heard of must be cleared too, or the boundary decays with
# every new FM_* variable added to the codebase.
rc=$(FM_SOME_FUTURE_VARIABLE=1 run_fixture futurevar \
  '[ -z "${FM_SOME_FUTURE_VARIABLE:-}" ] || { echo "not ok - unknown FM_* variable survived"; exit 1; }
echo "ok - unknown FM_* variable cleared"')
[ "$rc" = "0" ] || {
  cat "$TMP_ROOT/futurevar.out" >&2
  fail "an FM_* variable not on any remembered unset list reached the test process"
}
pass "an FM_* variable the library has never heard of is still cleared"

# An allowlisted variable must survive, or the clearing is indiscriminate
# rather than targeted.
rc=$(FM_TEST_ORPHAN_MAX_AGE_SECONDS=1234 run_fixture allowlist \
  '[ "${FM_TEST_ORPHAN_MAX_AGE_SECONDS:-}" = "1234" ] || { echo "not ok - allowlisted variable was cleared"; exit 1; }
echo "ok - allowlisted variable survived"')
[ "$rc" = "0" ] || {
  cat "$TMP_ROOT/allowlist.out" >&2
  fail "an allowlisted variable was cleared along with the rest of the namespace"
}
pass "an explicitly allowlisted FM_TEST_* variable still reaches the test"

git -C "$PRIMARY" worktree remove --force "$WT" >/dev/null 2>&1 || true
