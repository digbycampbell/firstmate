#!/usr/bin/env bash
# Tests for bin/fm-board.sh: the tool that replaces hand-run
# `gh-axi project item-edit` calls for moving/reading fleet pipeline cards.
#
# fm-board resolves cards through `gh api graphql` (gh-axi has no graphql
# subcommand): a single discovery round trip for the project id, Status field
# id, and column option ids, then either the issue's own `projectItems`
# connection when --repo is given (O(1) in board size) or a minimal-field board
# page-scan when it is not. sweep-stale reads each repo's closed-issue list
# through `gh-axi issue list`, then moves stale cards with the same graphql
# mutation. The mocks below stand in for `gh` (graphql) and `gh-axi` and log
# every invocation so the tests can assert on the calls made.
#
# Matrix:
#   (a) status --repo reads the live stage through the projectItems lookup, and
#       makes NO board-wide item listing (the regression that motivated this)
#   (b) status/move with no --repo resolve the card via the board page-scan
#   (c) move resolves the target option id from the board's LIVE Status options
#       rather than any hardcoded id, case/whitespace-loosely
#   (d) move is a reported no-op (no mutation) when already in that stage
#   (e) sweep-stale moves a closed issue's card into the terminal (last) Status
#       column and reports it
#   (f) every path is fail-open: exit 0 with a diagnostic when gh is missing,
#       when the graphql call fails outright, on an unknown stage, on an
#       unresolvable issue number, on an issue number ambiguous across
#       repositories (no-repo scan), and on a malformed --repo
#   (g) usage mistakes (no subcommand, unknown subcommand, wrong arg count, a
#       non-numeric issue number, --repo on sweep-stale) still exit 2
#   (h) every graphql call is bounded by FM_BOARD_TIMEOUT
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BOARD="$ROOT/bin/fm-board.sh"
TMP_ROOT=$(fm_test_tmproot fm-board-tests)

# A fresh sandbox with its own fakebin. Echoes the case dir.
make_case() {
  local name=$1 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/fakebin"
  printf '%s\n' "$case_dir"
}

run_board() {
  local case_dir=$1; shift
  PATH="$case_dir/fakebin:$PATH" \
  FM_TEST_LOG="$case_dir/calls.log" \
    "$BOARD" "$@"
}

# The `gh` (graphql) mock. It answers post-`--jq` output directly (it replaces
# gh, so it emits the exact lines fm-board's --jq filter would have produced),
# branching on the query text: discovery, the projectItems find, the board
# page-scan, or the move mutation. A standard two-card board: issue 101 in
# Inbox and issue 102 in Building, both digio-nz/fcdispatch; terminal column is
# Merged. `variant` tweaks it: `std`, `ambiguous` (issue 55 on two repos in the
# scan), `fails` (every call errors), `hangs` (every call sleeps).
write_gh_mock() {
  local fakebin=$1 variant=${2:-std}
  cat > "$fakebin/gh" <<SH
#!/usr/bin/env bash
log="\${FM_TEST_LOG:-/dev/null}"
printf 'gh %s\n' "\$*" >> "\$log"
variant=$variant
SH
  cat >> "$fakebin/gh" <<'SH'
[ "$variant" != fails ] || { echo "error: simulated gh failure" >&2; exit 1; }
[ "$variant" != hangs ] || { sleep 60; exit 0; }
q=''; num=''; after=''
for a in "$@"; do
  case "$a" in
    query=*) q=$a ;;
    number=*) num=${a#number=} ;;
    after=*) after=${a#after=} ;;
  esac
done
tab=$'\t'
case "$q" in
  *updateProjectV2ItemFieldValue*)
    # mutation: fm-board discards stdout; success is exit 0.
    exit 0 ;;
  *projectItems*)
    case "$num" in
      101) printf 'item=ITEM-A%sPVT_TEST%sInbox\ncost=1\n' "$tab" "$tab" ;;
      102) printf 'item=ITEM-B%sPVT_TEST%sBuilding\ncost=1\n' "$tab" "$tab" ;;
      *)   printf 'cost=1\n' ;;
    esac
    exit 0 ;;
  *"items(first:100"*)
    # Single page; hasNext=false regardless of the (ignored) after cursor.
    printf 'page=false%s\n' "$tab"
    if [ "$variant" = ambiguous ]; then
      printf 'item=ITEM-X%sIssue%s55%sdigio-nz/fcdispatch%sInbox\n' "$tab" "$tab" "$tab" "$tab"
      printf 'item=ITEM-Y%sIssue%s55%sdigio-nz/otherrepo%sInbox\n' "$tab" "$tab" "$tab" "$tab"
    else
      printf 'item=ITEM-A%sIssue%s101%sdigio-nz/fcdispatch%sInbox\n' "$tab" "$tab" "$tab" "$tab"
      printf 'item=ITEM-B%sIssue%s102%sdigio-nz/fcdispatch%sBuilding\n' "$tab" "$tab" "$tab" "$tab"
    fi
    printf 'cost=1\n'
    exit 0 ;;
  *)
    # discovery: project id, Status field id, and the live options in order.
    printf 'project=PVT_TEST\nfield=PVTSSF_STATUS\n'
    printf 'option=Inbox%sopt-inbox\n' "$tab"
    printf 'option=Design (lavish)%sopt-design\n' "$tab"
    printf 'option=Plan%sopt-plan\n' "$tab"
    printf 'option=Building%sopt-building\n' "$tab"
    printf 'option=Merged%sopt-merged\n' "$tab"
    printf 'cost=1\n'
    exit 0 ;;
esac
SH
  chmod +x "$fakebin/gh"
}

# The `gh-axi` mock, only used by sweep-stale for the closed-issue list.
# `variant` is `std` (issue 102 closed) or `fails`.
write_ghaxi_mock() {
  local fakebin=$1 variant=${2:-std}
  cat > "$fakebin/gh-axi" <<SH
#!/usr/bin/env bash
log="\${FM_TEST_LOG:-/dev/null}"
printf 'gh-axi %s\n' "\$*" >> "\$log"
variant=$variant
SH
  cat >> "$fakebin/gh-axi" <<'SH'
[ "$variant" != fails ] || { echo "error: simulated gh-axi failure" >&2; exit 1; }
case "$1 $2" in
  "issue list")
    printf 'count: 1 of 1 total\nissues[1]{number,title,state,author,created}:\n  102,"Card two",closed,tester,1d ago\n'
    exit 0 ;;
esac
exit 9
SH
  chmod +x "$fakebin/gh-axi"
}

# --- (a) status --repo reads the live stage, WITHOUT any board listing ------
c=$(make_case status-repo)
write_gh_mock "$c/fakebin" std
out=$(run_board "$c" status 101 --repo digio-nz/fcdispatch); rc=$?
expect_code 0 "$rc" "status-repo: exit code"
printf '%s\n' "$out" | grep -qF "issue #101 (digio-nz/fcdispatch) is in stage 'Inbox'" \
  || fail "status-repo: did not report the live stage (got: $out)"
assert_grep "projectItems" "$c/calls.log" "status-repo: did not resolve via the projectItems connection"
assert_no_grep "items(first:100" "$c/calls.log" "status-repo: page-scanned the whole board despite --repo"
pass "fm-board status --repo reads the live stage via projectItems, with no board-wide listing"

# --- regression: move --repo also never lists the whole board --------------
c=$(make_case move-repo-nolist)
write_gh_mock "$c/fakebin" std
out=$(run_board "$c" move 101 building --repo digio-nz/fcdispatch); rc=$?
expect_code 0 "$rc" "move-repo-nolist: exit code"
printf '%s\n' "$out" | grep -qF "moved issue #101 (digio-nz/fcdispatch) from 'Inbox' to 'Building'" \
  || fail "move-repo-nolist: did not move the card (got: $out)"
assert_grep "projectItems" "$c/calls.log" "move-repo-nolist: did not resolve via projectItems"
assert_no_grep "items(first:100" "$c/calls.log" "move-repo-nolist: page-scanned the whole board despite --repo"
assert_grep "updateProjectV2ItemFieldValue" "$c/calls.log" "move-repo-nolist: no move mutation was issued"
assert_grep "option=opt-building" "$c/calls.log" "move-repo-nolist: mutation used the wrong option id"
pass "fm-board move --repo mutates via projectItems ids and never lists the whole board"

# --- (b) status/move with no --repo resolve via the board page-scan ---------
c=$(make_case status-scan)
write_gh_mock "$c/fakebin" std
out=$(run_board "$c" status 102); rc=$?
expect_code 0 "$rc" "status-scan: exit code"
printf '%s\n' "$out" | grep -qF "issue #102 (digio-nz/fcdispatch) is in stage 'Building'" \
  || fail "status-scan: did not report the scanned stage (got: $out)"
assert_grep "items(first:100" "$c/calls.log" "status-scan: no --repo should page-scan the board"
pass "fm-board status with no --repo resolves the card through the board page-scan"

# --- (c) move resolves the option id live, case/whitespace-loosely ----------
c=$(make_case move-loose-stage)
write_gh_mock "$c/fakebin" std
out=$(run_board "$c" move 101 "  design (LAVISH)  " --repo digio-nz/fcdispatch)
printf '%s\n' "$out" | grep -qF "moved issue #101 (digio-nz/fcdispatch) from 'Inbox' to 'Design (lavish)'" \
  || fail "move-loose-stage: loose stage match failed (got: $out)"
assert_grep "option=opt-design" "$c/calls.log" "move-loose-stage: mutation used the wrong option id"
pass "fm-board move matches a stage name case/whitespace-loosely against the live board"

# --- (d) move is a no-op, with no mutation, when already in stage -----------
c=$(make_case move-noop)
write_gh_mock "$c/fakebin" std
out=$(run_board "$c" move 101 inbox --repo digio-nz/fcdispatch)
printf '%s\n' "$out" | grep -qF "issue #101 (digio-nz/fcdispatch) is already in stage 'Inbox'" \
  || fail "move-noop: did not report the no-op (got: $out)"
assert_no_grep "updateProjectV2ItemFieldValue" "$c/calls.log" "move-noop: mutated an already-correct stage"
pass "fm-board move is a reported no-op with no mutation when the card is already in that stage"

# --- (e) sweep-stale moves a closed issue's card to the terminal column -----
c=$(make_case sweep-stale)
write_gh_mock "$c/fakebin" std
write_ghaxi_mock "$c/fakebin" std
out=$(run_board "$c" sweep-stale)
printf '%s\n' "$out" | grep -qF "moved issue #102 (digio-nz/fcdispatch) from 'Building' to 'Merged'" \
  || fail "sweep-stale: did not move the closed-but-not-merged card (got: $out)"
assert_grep "items(first:100" "$c/calls.log" "sweep-stale: did not page-scan the board"
assert_grep "updateProjectV2ItemFieldValue" "$c/calls.log" "sweep-stale: no move mutation was issued"
assert_grep "option=opt-merged" "$c/calls.log" "sweep-stale: mutation did not target the terminal option"
pass "fm-board sweep-stale moves a closed issue's stray card into the terminal Status column"

c=$(make_case sweep-stale-clean)
write_gh_mock "$c/fakebin" std
write_ghaxi_mock "$c/fakebin" fails
out=$(run_board "$c" sweep-stale)
printf '%s\n' "$out" | grep -qF "no stale cards found" \
  || fail "sweep-stale-clean: did not report a clean board (got: $out)"
pass "fm-board sweep-stale reports a clean board when no closed issue has a stray card"

# --- (f) fail-open on every non-usage failure -------------------------------
c=$(make_case no-gh)
# A PATH with only bash, so `command -v gh` fails while the script can still run.
mkdir -p "$c/onlybash"
ln -sf "$(command -v bash)" "$c/onlybash/bash"
out=$(PATH="$c/onlybash" FM_TEST_LOG="$c/calls.log" "$BOARD" status 101 --repo digio-nz/fcdispatch 2>&1); rc=$?
expect_code 0 "$rc" "no-gh: exit code"
printf '%s\n' "$out" | grep -qF "gh is not on PATH" || fail "no-gh: missing diagnostic (got: $out)"
pass "fm-board fails open (exit 0) when gh is not on PATH"

c=$(make_case gh-fails)
write_gh_mock "$c/fakebin" fails
write_ghaxi_mock "$c/fakebin" std
for args in "status 101 --repo digio-nz/fcdispatch" "move 101 plan --repo digio-nz/fcdispatch" "status 101" "sweep-stale"; do
  # shellcheck disable=SC2086
  out=$(run_board "$c" $args 2>&1); rc=$?
  expect_code 0 "$rc" "gh-fails ($args): exit code"
  [ -n "$out" ] || fail "gh-fails ($args): no diagnostic printed"
done
pass "fm-board fails open (exit 0, with a diagnostic) on every subcommand when the graphql call fails"

c=$(make_case unknown-stage)
write_gh_mock "$c/fakebin" std
out=$(run_board "$c" move 101 "not-a-real-stage" --repo digio-nz/fcdispatch 2>&1); rc=$?
expect_code 0 "$rc" "unknown-stage: exit code"
printf '%s\n' "$out" | grep -qF "does not match any Status column" || fail "unknown-stage: missing diagnostic"
assert_no_grep "updateProjectV2ItemFieldValue" "$c/calls.log" "unknown-stage: mutated for an unrecognized stage"
pass "fm-board fails open on an unrecognized stage name"

c=$(make_case not-found)
write_gh_mock "$c/fakebin" std
out=$(run_board "$c" status 999999 --repo digio-nz/fcdispatch 2>&1); rc=$?
expect_code 0 "$rc" "not-found: exit code"
printf '%s\n' "$out" | grep -qF "was not found as a card" || fail "not-found: missing diagnostic"
pass "fm-board fails open when the issue number is not on the board"

c=$(make_case ambiguous)
write_gh_mock "$c/fakebin" ambiguous
out=$(run_board "$c" move 55 merged 2>&1); rc=$?
expect_code 0 "$rc" "ambiguous: exit code"
printf '%s\n' "$out" | grep -qF "more than one repository" || fail "ambiguous: missing diagnostic"
printf '%s\n' "$out" | grep -qF "pass --repo" || fail "ambiguous: did not point at --repo as the fix"
pass "fm-board fails open, pointing at --repo, when an issue number is ambiguous across repositories"

c=$(make_case bad-repo)
write_gh_mock "$c/fakebin" std
out=$(run_board "$c" status 101 --repo not/a/valid/repo 2>&1); rc=$?
expect_code 0 "$rc" "bad-repo: exit code"
printf '%s\n' "$out" | grep -qF "is not a valid owner/name" || fail "bad-repo: missing diagnostic (got: $out)"
# A malformed --repo is ignored and the call falls back to the board scan.
printf '%s\n' "$out" | grep -qF "issue #101 (digio-nz/fcdispatch) is in stage 'Inbox'" \
  || fail "bad-repo: did not fall back to the board scan (got: $out)"
assert_grep "items(first:100" "$c/calls.log" "bad-repo: did not fall back to the board scan"
pass "fm-board treats a malformed --repo as a fail-open diagnostic and falls back to the board scan"

# --- (g) usage mistakes still exit 2 ----------------------------------------
c=$(make_case usage-errors)
run_board "$c" >/dev/null 2>&1; expect_code 2 "$?" "usage-errors: no subcommand"
run_board "$c" bogus-subcommand >/dev/null 2>&1; expect_code 2 "$?" "usage-errors: unknown subcommand"
run_board "$c" move 101 >/dev/null 2>&1; expect_code 2 "$?" "usage-errors: move missing stage arg"
run_board "$c" status 101 extra >/dev/null 2>&1; expect_code 2 "$?" "usage-errors: status extra arg"
run_board "$c" move notanumber plan >/dev/null 2>&1; expect_code 2 "$?" "usage-errors: non-numeric issue"
run_board "$c" sweep-stale extra >/dev/null 2>&1; expect_code 2 "$?" "usage-errors: sweep-stale extra arg"
run_board "$c" sweep-stale --repo digio-nz/fcdispatch >/dev/null 2>&1; expect_code 2 "$?" "usage-errors: --repo on sweep-stale"
pass "fm-board usage mistakes still exit 2 with usage text, unlike every other failure"

# --- (h) a hung graphql call is bounded, not left to hang the caller --------
c=$(make_case timeout-bound)
write_gh_mock "$c/fakebin" hangs
start=$(date +%s)
out=$(FM_BOARD_TIMEOUT=2 run_board "$c" status 101 --repo digio-nz/fcdispatch 2>&1); rc=$?
elapsed=$(( $(date +%s) - start ))
expect_code 0 "$rc" "timeout-bound: exit code"
[ "$elapsed" -lt 10 ] || fail "timeout-bound: graphql call was not bounded (took ${elapsed}s)"
[ -n "$out" ] || fail "timeout-bound: missing diagnostic"
pass "fm-board bounds a hung graphql call by FM_BOARD_TIMEOUT instead of hanging the caller"

exit 0
