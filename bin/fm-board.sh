#!/usr/bin/env bash
# fm-board.sh - manage cards on a digio-nz GitHub Project (v2) board: the
# fleet's 11-stage house pipeline (Inbox -> Design (lavish) -> Plan -> Ready to
# build -> Building -> no-mistakes -> PR ready -> Preview -> UAT -> Approved ->
# Merged), replacing repeated hand-run `gh-axi project item-edit` calls.
#
# Usage:
#   fm-board.sh move <issue-number> <stage> [--project <n>] [--owner <login>]
#   fm-board.sh status <issue-number> [--project <n>] [--owner <login>]
#   fm-board.sh sweep-stale [--project <n>] [--owner <login>]
#
#   move          Move the card for <issue-number> to <stage>. <stage> matches
#                 case- and whitespace-loosely against the board's live Status
#                 column names (so "plan" matches "Plan", "design (lavish)"
#                 matches "Design (lavish)"). A card already in that stage is
#                 left untouched and reported as a no-op.
#   status        Print the card's current stage.
#   sweep-stale   Move every card whose issue is already closed but whose card
#                 still sits outside the terminal (last) Status column - e.g. a
#                 merged PR whose card was never dragged to Merged - into that
#                 terminal column, and report what moved.
#
#   --project <n>    the project (board) number. Default 2 (FC Dispatch).
#                     Products is 3, Business Operations is 1.
#   --owner <login>  the project's owner. Default digio-nz.
#
# DISCOVERY, NEVER HARDCODED. The project's node id, the Status field's id,
# every Status column's option id, and each issue's item id are all resolved
# fresh on every invocation from `gh-axi project view|field-list|item-list`, so
# a renamed or reordered board (this board was already renamed
# "shaping (lavish)" -> "Design (lavish)") never breaks this tool. The
# terminal column for sweep-stale is likewise whichever option is LAST in the
# Status field's live option order, not a hardcoded "Merged".
#
# FAIL-OPEN, ALWAYS. The board is a courtesy surface, never a gate. Once a
# subcommand's own arguments parse (a real usage mistake - missing/extra
# arguments, an unknown subcommand or flag - still prints usage and exits 2,
# matching every other bin/fm-*.sh script), every remaining path exits 0 with
# one clear diagnostic line on stderr: a missing/unreachable gh-axi, an
# unresolvable project/field/item, an unrecognized stage, an ambiguous issue
# number spanning more than one repository on the same board, or a failed
# gh-axi item-edit call. None of those can block or fail the caller.
#
# Every gh-axi call is bounded by FM_BOARD_TIMEOUT seconds (default 30) so a
# hung network call can never hang a caller either; a bound failure is just
# another fail-open diagnostic.
set -u

GH=gh-axi
TIMEOUT_SECS=${FM_BOARD_TIMEOUT:-30}
# ITEM_LIMIT is only the fallback used when the live item count cannot be read
# (fetch_item_list_raw normally sizes its real fetch to the board's own live
# total instead of this guess, to avoid over-requesting GraphQL budget).
ITEM_LIMIT=${FM_BOARD_ITEM_LIMIT:-300}
ISSUE_LIMIT=${FM_BOARD_ISSUE_LIMIT:-1000}
FIELD_LIMIT=${FM_BOARD_FIELD_LIMIT:-100}

TIMEOUT_BIN=
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_BIN=timeout
elif command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_BIN=gtimeout
fi

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

diag() { printf 'fm-board: %s\n' "$*" >&2; }

# Every gh-axi call goes through here so the timeout bound and the missing-tool
# check apply uniformly.
run_gh() {
  if [ -n "$TIMEOUT_BIN" ]; then
    "$TIMEOUT_BIN" "$TIMEOUT_SECS" "$GH" "$@"
  else
    "$GH" "$@"
  fi
}

normalize_stage() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -s '[:space:]' ' ' | sed -e 's/^ //' -e 's/ $//'
}

# gh-axi renders a project list as one indented YAML-ish block per row when
# the returned rows carry heterogeneous fields (e.g. a mix of DraftIssue and
# real Issue cards), and as a compact `name[N]{col,col,...}:` CSV table when
# the returned rows are homogeneous - which can happen even with no --query,
# whenever a --limit cuts the batch down to one item or one type. Both shapes
# are real and must both be parsed; relying on only one silently drops rows.
#
# Parse `gh-axi project item-list` output (either shape) on stdin into TSV
# rows: id, number, repository, status, type. DraftIssue rows carry an empty
# number and repository, which naturally excludes them from every
# issue-number match.
item_rows_from_list() {
  awk '
    NR == 1 { next }
    NR == 2 && /^items\[[0-9]+\]\{/ {
      mode = "table"
      header = $0
      sub(/^items\[[0-9]+\]\{/, "", header)
      sub(/\}:$/, "", header)
      ncols = split(header, cols, ",")
      for (i = 1; i <= ncols; i++) colidx[cols[i]] = i
      next
    }
    NR == 2 { mode = "block"; next }
    mode == "table" {
      if ($0 ~ /^help\[/) exit
      line = $0
      sub(/^ +/, "", line)
      n = csv_split(line, f)
      rid = colidx["id"] ? f[colidx["id"]] : ""
      if (rid == "") next
      printf "%s\t%s\t%s\t%s\t%s\n", rid, \
        (colidx["number"] ? f[colidx["number"]] : ""), \
        (colidx["repository"] ? f[colidx["repository"]] : ""), \
        (colidx["status"] ? f[colidx["status"]] : ""), \
        (colidx["type"] ? f[colidx["type"]] : "")
      next
    }
    mode == "block" && /^  - id: / {
      if (id != "") printf "%s\t%s\t%s\t%s\t%s\n", id, number, repo, status, type
      id = $0; sub(/^  - id: /, "", id)
      number = ""; repo = ""; status = ""; type = ""
      next
    }
    mode == "block" && /^    number: / { number = $0; sub(/^    number: /, "", number) }
    mode == "block" && /^    repository: / { repo = $0; sub(/^    repository: /, "", repo) }
    mode == "block" && /^    status: / { status = $0; sub(/^    status: /, "", status) }
    mode == "block" && /^    type: / { type = $0; sub(/^    type: /, "", type) }
    END { if (mode == "block" && id != "") printf "%s\t%s\t%s\t%s\t%s\n", id, number, repo, status, type }
    function csv_split(line, out,    i, c, field, n, inq) {
      n = 0; field = ""; inq = 0
      for (i = 1; i <= length(line); i++) {
        c = substr(line, i, 1)
        if (inq) {
          if (c == "\"") {
            if (substr(line, i + 1, 1) == "\"") { field = field "\""; i++ }
            else inq = 0
          } else field = field c
        } else {
          if (c == "\"") inq = 1
          else if (c == ",") { out[++n] = field; field = "" }
          else field = field c
        }
      }
      out[++n] = field
      return n
    }
  '
}

# Same dual-shape handling as item_rows_from_list, for `gh-axi project
# field-list` output: TSV rows of id, name, options (the raw
# "Name:optionid,Name:optionid,..." string, or empty for a field with no
# single-select options).
field_rows_from_list() {
  awk '
    NR == 1 { next }
    NR == 2 && /^fields\[[0-9]+\]\{/ {
      mode = "table"
      header = $0
      sub(/^fields\[[0-9]+\]\{/, "", header)
      sub(/\}:$/, "", header)
      ncols = split(header, cols, ",")
      for (i = 1; i <= ncols; i++) colidx[cols[i]] = i
      next
    }
    NR == 2 { mode = "block"; next }
    mode == "table" {
      if ($0 ~ /^help\[/) exit
      line = $0
      sub(/^ +/, "", line)
      n = csv_split(line, f)
      rid = colidx["id"] ? f[colidx["id"]] : ""
      if (rid == "") next
      printf "%s\t%s\t%s\n", rid, \
        (colidx["name"] ? f[colidx["name"]] : ""), \
        (colidx["options"] ? f[colidx["options"]] : "")
      next
    }
    mode == "block" && /^  - id: / {
      if (id != "") printf "%s\t%s\t%s\n", id, name, opts
      id = $0; sub(/^  - id: /, "", id)
      name = ""; opts = ""
      next
    }
    mode == "block" && /^    name: / { name = $0; sub(/^    name: /, "", name) }
    mode == "block" && /^    options: / { opts = $0; sub(/^    options: /, "", opts); gsub(/^"|"$/, "", opts) }
    END { if (mode == "block" && id != "") printf "%s\t%s\t%s\n", id, name, opts }
    function csv_split(line, out,    i, c, field, n, inq) {
      n = 0; field = ""; inq = 0
      for (i = 1; i <= length(line); i++) {
        c = substr(line, i, 1)
        if (inq) {
          if (c == "\"") {
            if (substr(line, i + 1, 1) == "\"") { field = field "\""; i++ }
            else inq = 0
          } else field = field c
        } else {
          if (c == "\"") inq = 1
          else if (c == ",") { out[++n] = field; field = "" }
          else field = field c
        }
      }
      out[++n] = field
      return n
    }
  '
}

# Fetch the FULL item list in one right-sized call: a cheap --limit 1 probe
# reads the live "count: X of Y total" header, then the real fetch asks for
# exactly Y. A single guessed large --limit (e.g. 2000) costs GraphQL budget
# proportional to the LIMIT requested, not to the board's real size, and can
# get preemptively rate-limited on a board with a fraction of that many
# cards; sizing the real call to the live total avoids that entirely and
# scales automatically as the board grows. Prints the raw item-list output on
# stdout; returns 1 when even the probe call fails.
fetch_item_list_raw() {  # <project-number> <owner>
  local probe total
  probe=$(run_gh project item-list "$1" --owner "$2" --limit 1 2>/dev/null) || return 1
  total=$(printf '%s\n' "$probe" | sed -n 's/^count: [0-9]* of \([0-9]*\) total$/\1/p' | head -n1)
  case "$total" in
    ''|*[!0-9]*) run_gh project item-list "$1" --owner "$2" --limit "$ITEM_LIMIT" 2>/dev/null ;;
    0) printf '%s\n' "$probe" ;;
    *) run_gh project item-list "$1" --owner "$2" --limit "$total" 2>/dev/null ;;
  esac
}

# Sets PROJECT_ID. Returns 1 on any lookup failure.
resolve_project() {  # <project-number> <owner>
  local out
  out=$(run_gh project view "$1" --owner "$2" 2>/dev/null) || return 1
  PROJECT_ID=$(printf '%s\n' "$out" | sed -n 's/^  id: //p' | head -n1)
  [ -n "$PROJECT_ID" ] || return 1
}

# Sets STATUS_FIELD_ID and the global STAGE_PAIRS array (each element
# "Name:optionid"), in the board's own live column order. Returns 1 when the
# board carries no single-select "Status" field.
resolve_status_field() {  # <project-number> <owner>
  local out row options
  out=$(run_gh project field-list "$1" --owner "$2" --limit "$FIELD_LIMIT" 2>/dev/null) || return 1
  row=$(printf '%s\n' "$out" | field_rows_from_list | awk -F'\t' '$2 == "Status" && $3 != "" { print; exit }')
  [ -n "$row" ] || return 1
  IFS=$'\t' read -r STATUS_FIELD_ID _ options <<<"$row"
  [ -n "$STATUS_FIELD_ID" ] && [ -n "$options" ] || return 1
  IFS=',' read -r -a STAGE_PAIRS <<<"$options"
  [ "${#STAGE_PAIRS[@]}" -gt 0 ] || return 1
}

stage_option_id() {  # <requested-stage>
  local want norm pair
  want=$(normalize_stage "$1")
  for pair in "${STAGE_PAIRS[@]}"; do
    norm=$(normalize_stage "${pair%:*}")
    if [ "$norm" = "$want" ]; then
      printf '%s' "${pair##*:}"
      return 0
    fi
  done
  return 1
}

stage_name_for_option() {  # <option-id>
  local pair
  for pair in "${STAGE_PAIRS[@]}"; do
    if [ "${pair##*:}" = "$1" ]; then
      printf '%s' "${pair%:*}"
      return 0
    fi
  done
  return 1
}

stage_names_human() {
  local pair out=""
  for pair in "${STAGE_PAIRS[@]}"; do
    out="$out${out:+, }${pair%:*}"
  done
  printf '%s' "$out"
}

# Sets ITEM_ID, ITEM_NUMBER, ITEM_REPO, ITEM_STATUS for the one card on this
# project whose issue number matches. Returns 0 on exactly one match, 1 when
# none match, 2 when more than one repository's card matches the same number,
# 3 when the item list itself could not be fetched.
resolve_item() {  # <project-number> <owner> <issue-number>
  local out rows match count
  out=$(fetch_item_list_raw "$1" "$2") || return 3
  rows=$(printf '%s\n' "$out" | item_rows_from_list)
  match=$(printf '%s\n' "$rows" | awk -F'\t' -v n="$3" '$2 == n')
  count=$(printf '%s\n' "$match" | grep -c . || true)
  case "$count" in
    0) return 1 ;;
    1) IFS=$'\t' read -r ITEM_ID _ ITEM_REPO ITEM_STATUS _ <<<"$match"; return 0 ;;
    *) return 2 ;;
  esac
}

cmd_move() {  # <issue-number> <stage> <project-number> <owner>
  local issue=$1 stage=$2 proj=$3 owner=$4 option_id target_name
  command -v "$GH" >/dev/null 2>&1 || { diag "$GH is not on PATH"; return 0; }
  resolve_project "$proj" "$owner" || { diag "could not resolve project $proj (owner $owner)"; return 0; }
  resolve_status_field "$proj" "$owner" || { diag "could not resolve the Status field on project $proj (owner $owner)"; return 0; }
  option_id=$(stage_option_id "$stage") || {
    diag "stage '$stage' does not match any Status column on project $proj (have: $(stage_names_human))"
    return 0
  }
  resolve_item "$proj" "$owner" "$issue"
  case $? in
    0) ;;
    1) diag "issue #$issue was not found as a card on project $proj (owner $owner)"; return 0 ;;
    2) diag "issue #$issue matches cards in more than one repository on project $proj; this tool does not disambiguate by repository yet"; return 0 ;;
    *) diag "could not list items on project $proj (owner $owner)"; return 0 ;;
  esac
  target_name=$(stage_name_for_option "$option_id")
  if [ "$(normalize_stage "$ITEM_STATUS")" = "$(normalize_stage "$target_name")" ]; then
    echo "issue #$issue ($ITEM_REPO) is already in stage '$ITEM_STATUS' on project $proj"
    return 0
  fi
  if run_gh project item-edit --id "$ITEM_ID" --project-id "$PROJECT_ID" --field-id "$STATUS_FIELD_ID" \
      --single-select-option-id "$option_id" >/dev/null 2>&1; then
    echo "moved issue #$issue ($ITEM_REPO) from '$ITEM_STATUS' to '$target_name' on project $proj"
  else
    diag "gh-axi project item-edit failed moving issue #$issue to '$target_name' on project $proj"
  fi
  return 0
}

cmd_status() {  # <issue-number> <project-number> <owner>
  local issue=$1 proj=$2 owner=$3
  command -v "$GH" >/dev/null 2>&1 || { diag "$GH is not on PATH"; return 0; }
  resolve_item "$proj" "$owner" "$issue"
  case $? in
    0) echo "issue #$issue ($ITEM_REPO) is in stage '$ITEM_STATUS' on project $proj" ;;
    1) diag "issue #$issue was not found as a card on project $proj (owner $owner)" ;;
    2) diag "issue #$issue matches cards in more than one repository on project $proj; this tool does not disambiguate by repository yet" ;;
    *) diag "could not list items on project $proj (owner $owner)" ;;
  esac
  return 0
}

cmd_sweep_stale() {  # <project-number> <owner>
  local proj=$1 owner=$2 out rows repos repo closed terminal_pair terminal_name terminal_id
  local moved=0 iid inum irepo istatus itype
  command -v "$GH" >/dev/null 2>&1 || { diag "$GH is not on PATH"; return 0; }
  resolve_project "$proj" "$owner" || { diag "could not resolve project $proj (owner $owner)"; return 0; }
  resolve_status_field "$proj" "$owner" || { diag "could not resolve the Status field on project $proj (owner $owner)"; return 0; }
  terminal_pair=${STAGE_PAIRS[${#STAGE_PAIRS[@]} - 1]}
  terminal_name=${terminal_pair%:*}
  terminal_id=${terminal_pair##*:}

  out=$(fetch_item_list_raw "$proj" "$owner") || {
    diag "could not list items on project $proj (owner $owner)"
    return 0
  }
  rows=$(printf '%s\n' "$out" | item_rows_from_list)
  repos=$(printf '%s\n' "$rows" | awk -F'\t' -v term="$terminal_name" '$5 == "Issue" && $4 != term { print $3 }' | sort -u)

  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    closed=$(run_gh issue list -R "$repo" --state closed --limit "$ISSUE_LIMIT" 2>/dev/null \
      | grep -oE '^  [0-9]+,' | tr -d ' ,') || closed=
    [ -n "$closed" ] || continue
    while IFS=$'\t' read -r iid inum irepo istatus itype; do
      [ "$itype" = "Issue" ] || continue
      [ "$irepo" = "$repo" ] || continue
      [ "$istatus" != "$terminal_name" ] || continue
      printf '%s\n' "$closed" | grep -qxF "$inum" || continue
      if run_gh project item-edit --id "$iid" --project-id "$PROJECT_ID" --field-id "$STATUS_FIELD_ID" \
          --single-select-option-id "$terminal_id" >/dev/null 2>&1; then
        echo "moved issue #$inum ($irepo) from '$istatus' to '$terminal_name' (issue is closed)"
        moved=$((moved + 1))
      else
        diag "gh-axi project item-edit failed moving issue #$inum ($irepo) to '$terminal_name'"
      fi
    done <<<"$rows"
  done <<<"$repos"

  [ "$moved" -gt 0 ] || echo "sweep-stale: no stale cards found on project $proj"
  return 0
}

[ "$#" -ge 1 ] || { usage >&2; exit 2; }
case "${1-}" in -h|--help|help) usage; exit 0 ;; esac
SUB=$1
shift

PROJECT=2
OWNER=digio-nz
POS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --project)
      [ "$#" -ge 2 ] && [ -n "$2" ] || { echo "error: --project requires a value" >&2; exit 2; }
      PROJECT=$2; shift 2 ;;
    --project=*)
      PROJECT=${1#--project=}
      [ -n "$PROJECT" ] || { echo "error: --project requires a value" >&2; exit 2; }
      shift ;;
    --owner)
      [ "$#" -ge 2 ] && [ -n "$2" ] || { echo "error: --owner requires a value" >&2; exit 2; }
      OWNER=$2; shift 2 ;;
    --owner=*)
      OWNER=${1#--owner=}
      [ -n "$OWNER" ] || { echo "error: --owner requires a value" >&2; exit 2; }
      shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; while [ "$#" -gt 0 ]; do POS+=("$1"); shift; done ;;
    -*) echo "error: unknown flag: $1" >&2; exit 2 ;;
    *) POS+=("$1"); shift ;;
  esac
done
case "$PROJECT" in *[!0-9]*|'') echo "error: --project must be a positive integer" >&2; exit 2 ;; esac

validate_issue_number() {  # <raw-arg>  -> prints the numeric issue number
  local n=${1#\#}
  case "$n" in
    ''|*[!0-9]*) echo "error: <issue-number> must be numeric, got '$1'" >&2; exit 2 ;;
  esac
  printf '%s' "$n"
}

case "$SUB" in
  move)
    [ "${#POS[@]}" -eq 2 ] || { usage >&2; exit 2; }
    ISSUE=$(validate_issue_number "${POS[0]}") || exit 2
    cmd_move "$ISSUE" "${POS[1]}" "$PROJECT" "$OWNER"
    ;;
  status)
    [ "${#POS[@]}" -eq 1 ] || { usage >&2; exit 2; }
    ISSUE=$(validate_issue_number "${POS[0]}") || exit 2
    cmd_status "$ISSUE" "$PROJECT" "$OWNER"
    ;;
  sweep-stale)
    [ "${#POS[@]}" -eq 0 ] || { usage >&2; exit 2; }
    cmd_sweep_stale "$PROJECT" "$OWNER"
    ;;
  *)
    echo "error: unknown subcommand: $SUB" >&2
    usage >&2
    exit 2
    ;;
esac
exit 0
