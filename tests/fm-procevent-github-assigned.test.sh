#!/usr/bin/env bash
# Behavior tests for the GitHub self-assignment process-event adapter.
#
# The external source is replaced on PATH with a fake `gh-axi` that records
# every invocation's argv and replies with gh-axi's real documented envelope
# shape (verified live against gh-axi 0.1.32 and the real digio-nz/fcdispatch
# repo and FC Dispatch board at implementation time: a multi-line jq result
# lands in `api_response: / body: "..." / truncated: false`, while a single
# short, special-character-free result like a quota reading is rendered bare).
# Nothing here touches the network.
#
# What is asserted is the adapter's own contract: a newly assigned issue or
# draft produces exactly one wake, re-polling with nothing new produces none
# (the cursor dedup proof), a fresh assignment made after that steady state is
# still detected, a stale cursor continuation is refused, low quota skips a
# fetch without blocking the other surface, every failure path is fail-open,
# and the full register/run/capture/publish/handle round trip works.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ADAPTER="$ROOT/bin/fm-procevent-github-assigned.sh"
TMP_ROOT=$(fm_test_tmproot fm-procevent-github-assigned)
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"
export TMPDIR="$TMP_ROOT/tmp"
mkdir -p "$TMPDIR"
export FM_GITHUB_ASSIGNED_MAX_LOOPS=1
export FM_GITHUB_ASSIGNED_MIN_CORE_QUOTA=100
export FM_GITHUB_ASSIGNED_MIN_GRAPHQL_QUOTA=50

LOGIN=digbycampbell
REPO=digio-nz/fcdispatch
SID="github-assigned-$LOGIN"

TRACKED_HOMES=()
gha_teardown() {
  local home
  for home in ${TRACKED_HOMES[@]+"${TRACKED_HOMES[@]}"}; do
    FM_HOME="$home" "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
  done
  fm_test_cleanup
}
trap gha_teardown EXIT

FAKEBIN=$(fm_fakebin "$TMP_ROOT")
cat > "$FAKEBIN/gh-axi" <<'SH'
#!/usr/bin/env bash
# Stand-in for gh-axi. Records argv, replies with gh-axi's real envelope shape.
set -u
printf '%s\n' "$*" >> "$FAKE_GH_AXI_ARGV"

emit_envelope() {  # <content>, JSON-string-quoted unless it is quota=<digits>
  case "$1" in
    quota=*) printf 'api_response:\n  body: %s\n  truncated: false\n' "$1" ;;
    *)
      printf 'api_response:\n  body: %s\n  truncated: false\n' \
        "$(printf '%s' "$1" | jq -Rs .)"
      ;;
  esac
}

[ "${FAKE_GH_AXI_FAIL:-0}" != 1 ] || { printf 'error: "forced failure"\ncode: UNKNOWN\n'; exit 1; }
[ "${1-}" = api ] || { printf 'fake gh-axi: unsupported command: %s\n' "$*" >&2; exit 1; }
shift

first=${1-}
shift
if [ "$first" = POST ]; then
  path="POST $1"
  shift
else
  path=$first
fi

field_value() {  # <argv...> <key> - last --field <key>=<value>, or empty
  local key=$1 prev='' a
  shift
  for a in "$@"; do
    if [ "$prev" = --field ]; then
      case "$a" in "$key="*) printf '%s\n' "${a#"$key"=}" ;; esac
    fi
    prev=$a
  done
}

case "$path" in
  /rate_limit)
    resource=core
    case "$*" in *graphql*) resource=graphql ;; esac
    [ "${FAKE_GH_AXI_FAIL_RATE_LIMIT:-0}" != 1 ] || { printf 'error: "forced failure"\n'; exit 1; }
    if [ "$resource" = graphql ]; then
      emit_envelope "quota=${FAKE_QUOTA_GRAPHQL:-5000}"
    else
      emit_envelope "quota=${FAKE_QUOTA_CORE:-5000}"
    fi
    ;;
  /repos/*/issues)
    [ "${FAKE_GH_AXI_FAIL_ISSUES:-0}" != 1 ] || { printf 'error: "forced failure"\n'; exit 1; }
    page=$(field_value page "$@")
    [ -n "$page" ] || page=1
    if [ "$page" = 1 ]; then
      emit_envelope "$(cat "$FAKE_ISSUES_BODY_FILE" 2>/dev/null || true)"
    else
      emit_envelope ""
    fi
    ;;
  "POST graphql")
    [ "${FAKE_GH_AXI_FAIL_PROJECT:-0}" != 1 ] || { printf 'error: "forced failure"\n'; exit 1; }
    after=$(field_value after "$@")
    if [ -z "$after" ]; then
      emit_envelope "$(cat "$FAKE_PROJECT_PAGE1_FILE" 2>/dev/null || true)"
    else
      emit_envelope "$(cat "$FAKE_PROJECT_PAGE2_FILE" 2>/dev/null || true)"
    fi
    ;;
  *)
    printf 'fake gh-axi: unsupported path: %s\n' "$path" >&2
    exit 1
    ;;
esac
SH
chmod +x "$FAKEBIN/gh-axi"
export PATH="$FAKEBIN:$PATH"
export FAKE_GH_AXI_ARGV="$TMP_ROOT/gh-axi.argv"
export FAKE_ISSUES_BODY_FILE="$TMP_ROOT/issues.body"
export FAKE_PROJECT_PAGE1_FILE="$TMP_ROOT/project.page1"
export FAKE_PROJECT_PAGE2_FILE="$TMP_ROOT/project.page2"
: > "$FAKE_GH_AXI_ARGV"
: > "$FAKE_ISSUES_BODY_FILE"
: > "$FAKE_PROJECT_PAGE1_FILE"

# No board items unless a case opts in: an always-present "no more pages" row.
no_board_items() {
  printf 'page\tfalse\t\n' > "$FAKE_PROJECT_PAGE1_FILE"
}
no_board_items

issue_row() {  # <number> <title>
  printf 'issue\tissue:%s#%s\t%s\t%s\thttps://github.com/%s/issues/%s\t%s\n' \
    "$REPO" "$1" "$1" "$REPO" "$REPO" "$1" "$2"
}

new_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/config"
  printf 'login=%s\nrepo=%s\nproject_owner=digio-nz\nproject_number=2\ninterval=1\nboard_interval=1\n' \
    "$LOGIN" "$REPO" > "$home/config/github-assigned"
  TRACKED_HOMES+=("$home")
  printf '%s\n' "$home"
}

cursor_file() { printf '%s/state/github-assigned/%s.cursor\n' "$1" "$LOGIN"; }

# --- classify is defensive about anything foreign ---------------------------

: > "$TMP_ROOT/empty.result"
[ "$("$ADAPTER" classify "$TMP_ROOT/empty.result")" = empty ] || fail "an empty result classifies as empty"
printf 'schema=something-else\nstatus=assigned\n\n' > "$TMP_ROOT/foreign.result"
[ "$("$ADAPTER" classify "$TMP_ROOT/foreign.result")" = unknown ] || fail "a foreign result classifies as unknown"
pass "classify refuses to be confused by an unfamiliar result"

# --- this source is never terminal ------------------------------------------

printf 'schema=fm-github-assigned.v1\nstatus=assigned\n\n' > "$TMP_ROOT/some.result"
"$ADAPTER" terminal "$TMP_ROOT/some.result" && fail "a github-assigned source must never be terminal"
pass "the source stays armed no matter what a result contained"

# --- a fresh assignment is captured, classified, and named ------------------

home=$(new_home fresh)
issue_row 488 "Readiness-of-engineer warning on the main grid" > "$FAKE_ISSUES_BODY_FILE"
: > "$FAKE_GH_AXI_ARGV"
out=$(FM_HOME="$home" "$ADAPTER" poll "$home") || fail "the first poll should capture the pre-existing assignment"
assert_contains "$out" 'status=assigned' "the result reports the assigned status"
assert_contains "$out" 'issue_count=1' "one issue is reported"
assert_contains "$out" 'draft_count=0' "no drafts are reported"
assert_contains "$out" 'issue:digio-nz/fcdispatch#488' "the snapshot names the assigned issue's canonical id"
printf '%s\n' "$out" > "$TMP_ROOT/fresh.result"
printf '%s\n' "$out" | grep -qF 'new	issue	issue:digio-nz/fcdispatch#488	488	digio-nz/fcdispatch' \
  || fail "the new-item row must name the issue's number, repo, and url"
[ "$("$ADAPTER" classify "$TMP_ROOT/fresh.result")" = assigned ] || fail "classify should report assigned"
pass "a fresh assignment is captured with a distinguishable issue row"

# --- dedup: re-polling with nothing new produces no result ------------------

FM_HOME="$home" "$ADAPTER" handle "no-op-not-registered" 1 "$TMP_ROOT/fresh.result" >/dev/null 2>&1
# handle above will fail because this result was never registered through the
# runner; what matters for this adapter's own contract is that advance_cursor
# itself committed the cursor before that unrelated failure - confirmed next.
assert_present "$(cursor_file "$home")" "the cursor is committed as soon as the result is applied"
rc=0
FM_HOME="$home" "$ADAPTER" poll "$home" > "$TMP_ROOT/second.out" 2>"$TMP_ROOT/second.err" || rc=$?
[ "$rc" -eq 75 ] || fail "re-polling with no new assignment must return the no-result exit code, got $rc"
[ ! -s "$TMP_ROOT/second.out" ] || fail "a steady-state poll must emit nothing: $(cat "$TMP_ROOT/second.out")"
pass "re-polling with no new assignment produces no result - the cursor dedup proof"

# --- a fresh assignment made after steady state is still detected ----------

{ cat "$FAKE_ISSUES_BODY_FILE"; issue_row 490 "Grid speed"; } > "$TMP_ROOT/issues2.body"
mv "$TMP_ROOT/issues2.body" "$FAKE_ISSUES_BODY_FILE"
out2=$(FM_HOME="$home" "$ADAPTER" poll "$home") || fail "a genuinely new assignment should be captured"
assert_contains "$out2" 'issue_count=1' "only the newly assigned issue is reported"
assert_contains "$out2" 'issue:digio-nz/fcdispatch#490' "the new issue's canonical id is present"
printf '%s\n' "$out2" | grep -qF 'new	issue	issue:digio-nz/fcdispatch#490' \
  || fail "the new row must name issue 490"
! printf '%s\n' "$out2" | grep -qF 'new	issue	issue:digio-nz/fcdispatch#488' \
  || fail "issue 488 was already known and must not be re-announced as new"
pass "a fresh assignment after steady state is detected without re-announcing the old one"

# --- a stale continuation is refused ----------------------------------------

home2=$(new_home stale)
issue_row 501 "Some issue" > "$FAKE_ISSUES_BODY_FILE"
stale_out=$(FM_HOME="$home2" "$ADAPTER" poll "$home2") || fail "priming poll failed"
printf '%s' "$stale_out" > "$TMP_ROOT/stale.result"
# Move the real cursor forward by a different, unrelated path so the captured
# result's cursor_from no longer matches the currently stored position.
mkdir -p "$(dirname "$(cursor_file "$home2")")"
printf 'schema=fm-github-assigned-cursor.v1\nissue:digio-nz/fcdispatch#999\n' > "$(cursor_file "$home2")"
if FM_HOME="$home2" "$ADAPTER" handle unused 1 "$TMP_ROOT/stale.result" >"$TMP_ROOT/stale.handle.out" 2>&1; then
  fail "handling a result whose cursor_from no longer matches stored state must be refused"
fi
assert_grep 'does not continue the stored read position' "$TMP_ROOT/stale.handle.out" \
  "the refusal names the continuation failure"
pass "a captured result that no longer continues the stored cursor is refused, never silently rebased"

# --- low quota skips a fetch without blocking the other surface -------------

home3=$(new_home quota)
issue_row 601 "Quota-safe issue" > "$FAKE_ISSUES_BODY_FILE"
: > "$FAKE_GH_AXI_ARGV"
export FAKE_QUOTA_GRAPHQL=1
out3=$(FM_HOME="$home3" "$ADAPTER" poll "$home3") || fail "an issue assignment should still be captured when only board quota is low"
assert_contains "$out3" 'issue:digio-nz/fcdispatch#601' "the issue is still detected"
assert_no_grep 'POST graphql' "$FAKE_GH_AXI_ARGV" "a low GraphQL quota must skip the board call entirely"
unset FAKE_QUOTA_GRAPHQL
pass "a low board quota never blocks noticing a newly assigned issue"

home4=$(new_home quota2)
issue_row 602 "Should not be fetched" > "$FAKE_ISSUES_BODY_FILE"
: > "$FAKE_GH_AXI_ARGV"
export FAKE_QUOTA_CORE=1
rc=0
FM_HOME="$home4" "$ADAPTER" poll "$home4" > "$TMP_ROOT/quota2.out" 2>"$TMP_ROOT/quota2.err" || rc=$?
[ "$rc" -eq 75 ] || fail "a low core quota should skip the cycle rather than fetch, got exit $rc"
assert_no_grep '/repos/' "$FAKE_GH_AXI_ARGV" "a low core quota must skip the issues call entirely"
assert_grep 'core API quota is low' "$TMP_ROOT/quota2.err" "the skip is logged"
unset FAKE_QUOTA_CORE
pass "a low core quota skips the issues fetch and logs why"

# --- every failure path is fail-open ----------------------------------------

home5=$(new_home failopen)
issue_row 701 "Irrelevant" > "$FAKE_ISSUES_BODY_FILE"
export FAKE_GH_AXI_FAIL=1
rc=0
FM_HOME="$home5" "$ADAPTER" poll "$home5" > "$TMP_ROOT/fail.out" 2>"$TMP_ROOT/fail.err" || rc=$?
[ "$rc" -eq 75 ] || fail "a forced GitHub failure must still exit cleanly with the no-result code, got $rc"
[ ! -s "$TMP_ROOT/fail.out" ] || fail "a failed poll must never emit a bogus result"
assert_grep 'gh-axi call failed' "$TMP_ROOT/fail.err" "the failure is diagnosed, not swallowed silently"
rc=0
FM_HOME="$home5" "$ADAPTER" list >"$TMP_ROOT/fail.list.out" 2>"$TMP_ROOT/fail.list.err" || rc=$?
[ "$rc" -ne 0 ] || fail "list must fail rather than report false emptiness when GitHub is unreachable"
assert_grep 'could not read' "$TMP_ROOT/fail.list.err" "list fails with a clean diagnostic, not a crash"
unset FAKE_GH_AXI_FAIL
pass "every GitHub failure path exits cleanly with a diagnostic and never wedges"

# --- list prints assigned issues and drafts on demand ------------------------

home6=$(new_home list)
issue_row 801 "Listed issue" > "$FAKE_ISSUES_BODY_FILE"
printf 'page\tfalse\t\nitem\tdraft\tdraft:PVTI_fake123\t\t\t\tListed draft\n' > "$FAKE_PROJECT_PAGE1_FILE"
list_out=$(FM_HOME="$home6" "$ADAPTER" list) || fail "list should succeed"
assert_contains "$list_out" 'count: 2 (1 issue, 1 draft)' "list summarizes both kinds"
assert_contains "$list_out" 'issue digio-nz/fcdispatch#801' "list names the issue"
assert_contains "$list_out" 'draft PVTI_fake123' "list names the draft"
no_board_items
pass "list prints the captain's currently assigned issues and drafts on demand"

# --- a board draft is distinguished from a promoted issue --------------------

home7=$(new_home draft)
: > "$FAKE_ISSUES_BODY_FILE"
printf 'page\tfalse\t\nitem\tdraft\tdraft:PVTI_zzz\t\t\t\tA fresh draft\n' > "$FAKE_PROJECT_PAGE1_FILE"
draft_out=$(FM_HOME="$home7" "$ADAPTER" poll "$home7") || fail "a new draft should be captured"
assert_contains "$draft_out" 'issue_count=0' "no issues in this capture"
assert_contains "$draft_out" 'draft_count=1' "one draft in this capture"
printf '%s\n' "$draft_out" | grep -qF 'new	draft	draft:PVTI_zzz' \
  || fail "the new row must flag this item as a draft, distinct from a promoted issue"
no_board_items
pass "a board draft is flagged distinctly from a promoted real issue"

# --- the board fetch follows GraphQL pagination across pages -----------------

home9=$(new_home paginate)
: > "$FAKE_ISSUES_BODY_FILE"
printf 'page\ttrue\tOPAQUECURSOR1\nitem\tdraft\tdraft:PVTI_page1\t\t\t\tPage one draft\n' > "$FAKE_PROJECT_PAGE1_FILE"
printf 'page\tfalse\t\nitem\tdraft\tdraft:PVTI_page2\t\t\t\tPage two draft\n' > "$FAKE_PROJECT_PAGE2_FILE"
: > "$FAKE_GH_AXI_ARGV"
page_out=$(FM_HOME="$home9" "$ADAPTER" poll "$home9") || fail "a board fetch spanning two pages should still capture both drafts"
assert_contains "$page_out" 'draft_count=2' "both pages' drafts are counted"
assert_contains "$page_out" 'draft:PVTI_page1' "the first page's draft is present"
assert_contains "$page_out" 'draft:PVTI_page2' "the second page's draft is present"
assert_grep 'after=OPAQUECURSOR1' "$FAKE_GH_AXI_ARGV" "the second page request carries the first page's cursor"
: > "$FAKE_PROJECT_PAGE1_FILE"
no_board_items
: > "$FAKE_PROJECT_PAGE2_FILE"
pass "a board fetch spanning multiple GraphQL pages aggregates every page's items"

# --- end-to-end: arm, run the source, capture, publish, handle --------------

home8=$(new_home roundtrip)
issue_row 901 "Roundtrip issue" > "$FAKE_ISSUES_BODY_FILE"
armed=$(FM_HOME="$home8" "$ADAPTER" arm 2>&1) || fail "arm failed: $armed"
assert_contains "$armed" "armed: $SID" "arm reports the registered source"
assert_present "$home8/state/procevent/$SID.source" "arm registers the source"
FM_HOME="$home8" "$ROOT/bin/fm-procevent.sh" start "$SID" > "$TMP_ROOT/start.out" 2>&1 \
  || fail "the runner failed: $(cat "$TMP_ROOT/start.out")"
result=$(printf '%s\n' "$home8/state/procevent-inbox/$SID".*.result | head -n 1)
[ -f "$result" ] || fail "the runner captured no result: $(cat "$TMP_ROOT/start.out")"
[ "$("$ADAPTER" classify "$result")" = assigned ] || fail "the captured result should classify as assigned"
assert_grep "procevent github-assigned $SID" "$home8/state/.wake-queue" "the capture publishes a wake"
assert_present "$home8/state/procevent/$SID.source" "the source stays armed after a capture"
seq=${result%.result}
seq=${seq##*.}
FM_HOME="$home8" "$ADAPTER" handle "$SID" "$seq" "$result" >/dev/null \
  || fail "handling the captured result failed"
assert_present "$home8/state/procevent-inbox/$SID.$seq.handled" "handling records the acknowledgement"
pass "register, run, capture, publish, classify, and acknowledge round-trip"
