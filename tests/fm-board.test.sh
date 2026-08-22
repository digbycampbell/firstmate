#!/usr/bin/env bash
# Tests for bin/fm-board.sh: the tool that replaces hand-run
# `gh-axi project item-edit` calls for moving/reading fleet pipeline cards.
#
# Matrix:
#   (a) status prints the card's live stage, discovered (not hardcoded) via
#       gh-axi project item-list block output
#   (b) status/move also parse gh-axi's OTHER real output shape: a compact
#       `items[N]{col,...}:` CSV table, which gh-axi renders whenever the
#       returned batch is field-homogeneous (observed live against the real
#       FC Dispatch board) - including a field with an embedded comma and an
#       escaped quote
#   (c) move resolves the target option id from the board's LIVE Status
#       options rather than any hardcoded id, case/whitespace-loosely
#   (d) move is a reported no-op when the card is already in that stage (no
#       gh-axi item-edit call)
#   (e) sweep-stale moves a closed issue's card into the terminal (last)
#       Status column and reports it
#   (f) every path is fail-open: exit 0 with a diagnostic when gh-axi is
#       missing, when gh-axi fails outright, on an unknown stage, on an
#       unresolvable issue number, and on an issue number ambiguous across
#       repositories on the same board
#   (g) usage mistakes (no subcommand, unknown subcommand, wrong arg count, a
#       non-numeric issue number) are the one exception and still exit 2
#   (h) every gh-axi call is bounded by FM_BOARD_TIMEOUT so a hung call can
#       never hang the caller
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
  FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
    "$BOARD" "$@"
}

# A gh-axi mock covering a small two-field, two-card board (block-format
# item-list), logging every invocation.
gh_axi_block_board() {
  cat <<'SH'
#!/usr/bin/env bash
log="${FM_TEST_GH_AXI_LOG:-/dev/null}"
printf '%s\n' "$*" >> "$log"
case "$1 $2" in
  "project view")
    printf 'project:\n  id: PVT_TEST\n'
    exit 0 ;;
  "project field-list")
    cat <<'EOF'
count: 1 of 1 total
fields[1]:
  - id: PVTSSF_STATUS
    name: Status
    type: ProjectV2SingleSelectField
    options: "Inbox:opt-inbox,Design (lavish):opt-design,Plan:opt-plan,Building:opt-building,Merged:opt-merged"
EOF
    exit 0 ;;
  "project item-list")
    limit=30
    prev=
    for a in "$@"; do
      [ "$prev" != --limit ] || limit=$a
      prev=$a
    done
    if [ "$limit" = 1 ]; then
      printf 'count: 1 of 2 total\nitems[1]{id,title,type,number,repository,status}:\n  ITEM-A,"Card one",Issue,101,digio-nz/fcdispatch,Inbox\n'
      exit 0
    fi
    cat <<'EOF'
count: 2 of 2 total
items[2]:
  - id: ITEM-A
    title: Card one
    type: Issue
    number: 101
    repository: digio-nz/fcdispatch
    status: Inbox
  - id: ITEM-B
    title: Card two
    type: Issue
    number: 102
    repository: digio-nz/fcdispatch
    status: Building
help[2]:
  Run `gh-axi project item-add 2 --url <issue-or-pr-url> --owner digio-nz` to add an item
EOF
    exit 0 ;;
  "project item-edit") exit 0 ;;
  "issue list")
    printf 'count: 1 of 1 total\nissues[1]{number,title,state,author,created}:\n  102,"Card two",closed,tester,1d ago\n'
    exit 0 ;;
esac
echo "unhandled: $*" >&2
exit 9
SH
}

# A gh-axi mock whose item-list is homogeneous at every --limit, so gh-axi
# renders the compact CSV table shape even for the full fetch - the shape
# item_rows_from_list's table branch must handle, including a quoted field
# with an embedded comma and an escaped internal quote.
gh_axi_table_board() {
  cat <<'SH'
#!/usr/bin/env bash
log="${FM_TEST_GH_AXI_LOG:-/dev/null}"
printf '%s\n' "$*" >> "$log"
case "$1 $2" in
  "project view")
    printf 'project:\n  id: PVT_TEST\n'
    exit 0 ;;
  "project field-list")
    cat <<'EOF'
count: 1 of 1 total
fields[1]:
  - id: PVTSSF_STATUS
    name: Status
    type: ProjectV2SingleSelectField
    options: "Inbox:opt-inbox,Merged:opt-merged"
EOF
    exit 0 ;;
  "project item-list")
    cat <<'EOF'
count: 1 of 1 total
items[1]{id,title,type,number,repository,status}:
  ITEM-C,"A title, with a comma and a ""quoted"" word",Issue,201,digio-nz/fcdispatch,Inbox
help[2]:
  Run `gh-axi project item-add 2 --url <issue-or-pr-url> --owner digio-nz` to add an item
EOF
    exit 0 ;;
  "project item-edit") exit 0 ;;
esac
echo "unhandled: $*" >&2
exit 9
SH
}

# A gh-axi mock reporting two cards sharing the same issue number across two
# different repositories on the same board (the deliberate ambiguous case).
gh_axi_ambiguous_board() {
  cat <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "project view") printf 'project:\n  id: PVT_TEST\n'; exit 0 ;;
  "project field-list")
    cat <<'EOF'
count: 1 of 1 total
fields[1]:
  - id: PVTSSF_STATUS
    name: Status
    type: ProjectV2SingleSelectField
    options: "Inbox:opt-inbox,Merged:opt-merged"
EOF
    exit 0 ;;
  "project item-list")
    cat <<'EOF'
count: 2 of 2 total
items[2]:
  - id: ITEM-A
    type: Issue
    number: 55
    repository: digio-nz/fcdispatch
    status: Inbox
  - id: ITEM-B
    type: Issue
    number: 55
    repository: digio-nz/otherrepo
    status: Inbox
EOF
    exit 0 ;;
esac
exit 9
SH
}

# A gh-axi mock that always fails, simulating an auth/network/lookup failure.
gh_axi_always_fails() {
  cat <<'SH'
#!/usr/bin/env bash
echo "error: simulated gh-axi failure" >&2
exit 1
SH
}

# A gh-axi mock that hangs forever, to prove the timeout bound.
gh_axi_hangs() {
  cat <<'SH'
#!/usr/bin/env bash
sleep 60
SH
}

# --- (a) status reads the live stage from block-format item-list -----------
c=$(make_case status-block)
gh_axi_block_board > "$c/fakebin/gh-axi"; chmod +x "$c/fakebin/gh-axi"
out=$(run_board "$c" status 101); rc=$?
expect_code 0 "$rc" "status-block: exit code"
printf '%s\n' "$out" | grep -qF "issue #101 (digio-nz/fcdispatch) is in stage 'Inbox'" \
  || fail "status-block: did not report the live stage (got: $out)"
pass "fm-board status reads the live stage from block-format item-list"

# --- (b) status/move parse the compact CSV table shape too -----------------
c=$(make_case status-table)
gh_axi_table_board > "$c/fakebin/gh-axi"; chmod +x "$c/fakebin/gh-axi"
out=$(run_board "$c" status 201)
printf '%s\n' "$out" | grep -qF "issue #201 (digio-nz/fcdispatch) is in stage 'Inbox'" \
  || fail "status-table: did not parse the CSV table shape (got: $out)"
pass "fm-board status parses gh-axi's compact CSV table output shape"

c=$(make_case move-table)
gh_axi_table_board > "$c/fakebin/gh-axi"; chmod +x "$c/fakebin/gh-axi"
out=$(run_board "$c" move 201 merged)
printf '%s\n' "$out" | grep -qF "moved issue #201 (digio-nz/fcdispatch) from 'Inbox' to 'Merged'" \
  || fail "move-table: did not move the CSV-table-parsed card (got: $out)"
grep -qxF 'project item-edit --id ITEM-C --project-id PVT_TEST --field-id PVTSSF_STATUS --single-select-option-id opt-merged' \
  "$c/gh-axi.log" || fail "move-table: item-edit was not called with the discovered ids"
pass "fm-board move resolves ids and moves a card parsed from the CSV table shape"

# --- (c) move resolves the option id live, case/whitespace-loosely ---------
c=$(make_case move-loose-stage)
gh_axi_block_board > "$c/fakebin/gh-axi"; chmod +x "$c/fakebin/gh-axi"
out=$(run_board "$c" move 101 "  design (LAVISH)  ")
printf '%s\n' "$out" | grep -qF "moved issue #101 (digio-nz/fcdispatch) from 'Inbox' to 'Design (lavish)'" \
  || fail "move-loose-stage: loose stage match failed (got: $out)"
grep -qxF 'project item-edit --id ITEM-A --project-id PVT_TEST --field-id PVTSSF_STATUS --single-select-option-id opt-design' \
  "$c/gh-axi.log" || fail "move-loose-stage: item-edit used the wrong option id"
pass "fm-board move matches a stage name case/whitespace-loosely against the live board"

# --- (d) move is a no-op, with no item-edit call, when already in stage ----
c=$(make_case move-noop)
gh_axi_block_board > "$c/fakebin/gh-axi"; chmod +x "$c/fakebin/gh-axi"
out=$(run_board "$c" move 101 inbox)
printf '%s\n' "$out" | grep -qF "issue #101 (digio-nz/fcdispatch) is already in stage 'Inbox'" \
  || fail "move-noop: did not report the no-op (got: $out)"
assert_no_grep "item-edit" "$c/gh-axi.log" "move-noop: item-edit was called for an already-correct stage"
pass "fm-board move is a reported no-op with no item-edit call when the card is already in that stage"

# --- (e) sweep-stale moves a closed issue's card to the terminal column ----
c=$(make_case sweep-stale)
gh_axi_block_board > "$c/fakebin/gh-axi"; chmod +x "$c/fakebin/gh-axi"
out=$(run_board "$c" sweep-stale)
printf '%s\n' "$out" | grep -qF "moved issue #102 (digio-nz/fcdispatch) from 'Building' to 'Merged'" \
  || fail "sweep-stale: did not move the closed-but-not-merged card (got: $out)"
grep -qxF 'project item-edit --id ITEM-B --project-id PVT_TEST --field-id PVTSSF_STATUS --single-select-option-id opt-merged' \
  "$c/gh-axi.log" || fail "sweep-stale: item-edit was not called for the stale card"
pass "fm-board sweep-stale moves a closed issue's stray card into the terminal Status column"

c=$(make_case sweep-stale-clean)
gh_axi_table_board > "$c/fakebin/gh-axi"; chmod +x "$c/fakebin/gh-axi"
out=$(run_board "$c" sweep-stale)
printf '%s\n' "$out" | grep -qF "no stale cards found" \
  || fail "sweep-stale-clean: did not report a clean board (got: $out)"
pass "fm-board sweep-stale reports a clean board when nothing is stale"

# --- (f) fail-open on every non-usage failure -------------------------------
c=$(make_case no-gh-axi)
out=$(PATH="/usr/bin:/bin" run_board "$c" status 101 2>&1); rc=$?
expect_code 0 "$rc" "no-gh-axi: exit code"
printf '%s\n' "$out" | grep -qF "gh-axi is not on PATH" || fail "no-gh-axi: missing diagnostic"
pass "fm-board fails open (exit 0) when gh-axi is not on PATH"

c=$(make_case gh-axi-fails)
gh_axi_always_fails > "$c/fakebin/gh-axi"; chmod +x "$c/fakebin/gh-axi"
for args in "status 101" "move 101 plan" "sweep-stale"; do
  # shellcheck disable=SC2086
  out=$(run_board "$c" $args 2>&1); rc=$?
  expect_code 0 "$rc" "gh-axi-fails ($args): exit code"
  [ -n "$out" ] || fail "gh-axi-fails ($args): no diagnostic printed"
done
pass "fm-board fails open (exit 0, with a diagnostic) on every subcommand when gh-axi itself fails"

c=$(make_case unknown-stage)
gh_axi_block_board > "$c/fakebin/gh-axi"; chmod +x "$c/fakebin/gh-axi"
out=$(run_board "$c" move 101 "not-a-real-stage" 2>&1); rc=$?
expect_code 0 "$rc" "unknown-stage: exit code"
printf '%s\n' "$out" | grep -qF "does not match any Status column" || fail "unknown-stage: missing diagnostic"
assert_no_grep "item-edit" "$c/gh-axi.log" "unknown-stage: item-edit was called for an unrecognized stage"
pass "fm-board fails open on an unrecognized stage name"

c=$(make_case not-found)
gh_axi_block_board > "$c/fakebin/gh-axi"; chmod +x "$c/fakebin/gh-axi"
out=$(run_board "$c" status 999999 2>&1); rc=$?
expect_code 0 "$rc" "not-found: exit code"
printf '%s\n' "$out" | grep -qF "was not found as a card" || fail "not-found: missing diagnostic"
pass "fm-board fails open when the issue number is not on the board"

c=$(make_case ambiguous)
gh_axi_ambiguous_board > "$c/fakebin/gh-axi"; chmod +x "$c/fakebin/gh-axi"
out=$(run_board "$c" move 55 merged 2>&1); rc=$?
expect_code 0 "$rc" "ambiguous: exit code"
printf '%s\n' "$out" | grep -qF "more than one repository" || fail "ambiguous: missing diagnostic"
pass "fm-board fails open when an issue number is ambiguous across repositories on one board"

# --- (g) usage mistakes still exit 2 ----------------------------------------
c=$(make_case usage-errors)
run_board "$c" >/dev/null 2>&1; expect_code 2 "$?" "usage-errors: no subcommand"
run_board "$c" bogus-subcommand >/dev/null 2>&1; expect_code 2 "$?" "usage-errors: unknown subcommand"
run_board "$c" move 101 >/dev/null 2>&1; expect_code 2 "$?" "usage-errors: move missing stage arg"
run_board "$c" status 101 extra >/dev/null 2>&1; expect_code 2 "$?" "usage-errors: status extra arg"
run_board "$c" move notanumber plan >/dev/null 2>&1; expect_code 2 "$?" "usage-errors: non-numeric issue"
run_board "$c" sweep-stale extra >/dev/null 2>&1; expect_code 2 "$?" "usage-errors: sweep-stale extra arg"
pass "fm-board usage mistakes still exit 2 with usage text, unlike every other failure"

# --- (h) a hung gh-axi call is bounded, not left to hang the caller --------
c=$(make_case timeout-bound)
gh_axi_hangs > "$c/fakebin/gh-axi"; chmod +x "$c/fakebin/gh-axi"
start=$(date +%s)
out=$(FM_BOARD_TIMEOUT=2 run_board "$c" status 101 2>&1); rc=$?
elapsed=$(( $(date +%s) - start ))
expect_code 0 "$rc" "timeout-bound: exit code"
[ "$elapsed" -lt 10 ] || fail "timeout-bound: gh-axi call was not bounded (took ${elapsed}s)"
printf '%s\n' "$out" | grep -qF "could not list items" || fail "timeout-bound: missing diagnostic"
pass "fm-board bounds a hung gh-axi call by FM_BOARD_TIMEOUT instead of hanging the caller"

exit 0
