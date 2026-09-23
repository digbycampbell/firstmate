#!/usr/bin/env bash
# fm-board.sh - manage cards on a digio-nz GitHub Project (v2) board: the
# fleet's 11-stage house pipeline (Inbox -> Design (lavish) -> Plan -> Ready to
# build -> Building -> no-mistakes -> PR ready -> Preview -> UAT -> Approved ->
# Merged), replacing repeated hand-run `gh-axi project item-edit` calls.
#
# Usage:
#   fm-board.sh move <issue-number> <stage> [--repo <owner/name>] [--project <n>] [--owner <login>]
#   fm-board.sh status <issue-number> [--repo <owner/name>] [--project <n>] [--owner <login>]
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
#   --repo <owner/name>  the repository whose issue #N is being moved/read. When
#                     given, move/status resolve that one card DIRECTLY through
#                     the issue's `projectItems` connection - O(1) in board
#                     size, a handful of GraphQL points - and there is no
#                     cross-repo ambiguity because the repo is named. Prefer
#                     this on every automated call; a program that knows the
#                     issue number almost always knows its repo too.
#   --project <n>    the project (board) number. Default 2 (FC Dispatch).
#                     Products is 3, Business Operations is 1.
#   --owner <login>  the project's owner (an organization). Default digio-nz.
#
# GRAPHQL BUDGET. GitHub's GraphQL API has its own 5,000-points-per-hour budget,
# shared by every tool on the account. This tool's move/status therefore never
# list the whole board: discovery resolves the project id, the Status field id,
# and every column option id in ONE `organization.projectV2.field(name:"Status")`
# round trip, and item lookup uses the issue's own `projectItems` connection when
# --repo is given (single-digit points regardless of board size). Only
# sweep-stale, which by its nature must inspect every card, pages the board, and
# it fetches ONLY the fields it uses. When --repo is absent, move/status fall
# back to that same board page-scan to discover which repo the issue lives in
# (the expensive path, proportional to board size); pass --repo to avoid it.
# Set FM_BOARD_DEBUG=1 to print each path's measured GraphQL `cost` on stderr.
#
# DISCOVERY, NEVER HARDCODED. The project's node id, the Status field's id, and
# every Status column's option id are all resolved fresh on every invocation
# from live GraphQL, so a renamed or reordered board (this board was already
# renamed "shaping (lavish)" -> "Design (lavish)") never breaks this tool. The
# terminal column for sweep-stale is likewise whichever option is LAST in the
# Status field's live option order, not a hardcoded "Merged".
#
# FAIL-OPEN, ALWAYS. The board is a courtesy surface, never a gate. Once a
# subcommand's own arguments parse (a real usage mistake - missing/extra
# arguments, an unknown subcommand or flag - still prints usage and exits 2,
# matching every other bin/fm-*.sh script), every remaining path exits 0 with
# one clear diagnostic line on stderr: a missing/unreachable gh or gh-axi, an
# unresolvable project/field/item, an unrecognized stage, a malformed --repo, an
# issue number ambiguous across repositories on the board (only possible on the
# no-repo fallback), or a failed mutation. None of those can block the caller.
#
# TOOLS. GraphQL discovery, item lookup, the board page-scan, and the move
# mutation go through `gh api graphql` (gh-axi has no graphql subcommand, and
# gh's own --jq gives clean machine output without a separate jq dependency);
# sweep-stale still reads each repo's closed-issue list through `gh-axi issue
# list`. Every such call is bounded by FM_BOARD_TIMEOUT seconds (default 30) so
# a hung network call can never hang a caller either; a bound failure is just
# another fail-open diagnostic.
set -u

GH=gh
GH_AXI=gh-axi
TIMEOUT_SECS=${FM_BOARD_TIMEOUT:-30}
ISSUE_LIMIT=${FM_BOARD_ISSUE_LIMIT:-1000}
# Board page-scan safety bound: refuse to loop past this many 100-card pages.
MAX_PAGES=${FM_BOARD_MAX_PAGES:-50}

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
debug_cost() {  # <label> <cost>
  [ -n "${FM_BOARD_DEBUG:-}" ] || return 0
  printf 'fm-board: GraphQL cost (%s): %s\n' "$1" "$2" >&2
}

# Every gh / gh-axi call goes through here so the timeout bound applies
# uniformly. First argument is the binary, the rest its arguments.
run_bounded() {  # <binary> <args...>
  if [ -n "$TIMEOUT_BIN" ]; then
    "$TIMEOUT_BIN" "$TIMEOUT_SECS" "$@"
  else
    "$@"
  fi
}

# Run one `gh api graphql` query, bounded, on stdout. The query text is $1; the
# remaining arguments are passed through verbatim (typically -F var=value pairs
# and a --jq filter).
gh_graphql() {  # <query> <extra gh-api args...>
  local query=$1
  shift
  run_bounded "$GH" api graphql -f "query=$query" "$@" 2>/dev/null
}

normalize_stage() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -s '[:space:]' ' ' | sed -e 's/^ //' -e 's/ $//'
}

# --repo owner/name shape check, matching the fleet's own board tools: one
# slash, no whitespace, no empty half.
valid_repo() {
  case "${1-}" in
    ''|*[[:space:]]*|*/*/*) return 1 ;;
    */*) ;;
    *) return 1 ;;
  esac
  local owner=${1%%/*} name=${1#*/}
  [ -n "$owner" ] && [ -n "$name" ]
}

# --- board discovery (one GraphQL round trip) ------------------------------

# shellcheck disable=SC2016  # GraphQL $vars are literal query syntax, not shell expansions
DISCOVER_QUERY='query($owner:String!,$number:Int!){
  organization(login:$owner){
    projectV2(number:$number){
      id
      field(name:"Status"){ ... on ProjectV2SingleSelectField { id options { id name } } }
    }
  }
  rateLimit { cost }
}'

# Sets PROJECT_ID, STATUS_FIELD_ID, and the STAGE_PAIRS array (each element
# "Name:optionid") in the board's own live column order. Returns 1 on any
# lookup failure or when the board carries no single-select "Status" field.
STAGE_PAIRS=()
resolve_board_meta() {  # <project-number> <owner>
  local out line cost=
  PROJECT_ID=
  STATUS_FIELD_ID=
  STAGE_PAIRS=()
  out=$(gh_graphql "$DISCOVER_QUERY" -F "owner=$2" -F "number=$1" --jq '
    "project=" + (.data.organization.projectV2.id // ""),
    "field=" + (.data.organization.projectV2.field.id // ""),
    (.data.organization.projectV2.field.options[]? | "option=" + .name + "\t" + .id),
    "cost=" + ((.data.rateLimit.cost // "") | tostring)') || return 1
  while IFS= read -r line; do
    case "$line" in
      project=*) PROJECT_ID=${line#project=} ;;
      field=*) STATUS_FIELD_ID=${line#field=} ;;
      option=*) STAGE_PAIRS+=("$(printf '%s' "${line#option=}" | sed 's/\t/:/')") ;;
      cost=*) cost=${line#cost=} ;;
    esac
  done <<EOF
$out
EOF
  debug_cost "discovery" "${cost:-?}"
  [ -n "$PROJECT_ID" ] && [ -n "$STATUS_FIELD_ID" ] && [ "${#STAGE_PAIRS[@]}" -gt 0 ]
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

# --- item lookup -----------------------------------------------------------

# shellcheck disable=SC2016  # GraphQL $vars are literal query syntax, not shell expansions
FIND_ITEM_QUERY='query($owner:String!,$repo:String!,$number:Int!){
  repository(owner:$owner,name:$repo){
    issue(number:$number){
      projectItems(first:20){
        nodes {
          id
          project { id }
          fieldValueByName(name:"Status"){ ... on ProjectV2ItemFieldSingleSelectValue { name } }
        }
      }
    }
  }
  rateLimit { cost }
}'

# Directly resolve issue #N's card on this project through its own projectItems
# connection - O(1) in board size. Sets ITEM_ID, ITEM_REPO, ITEM_STATUS.
# Returns 0 on the matching card, 1 when the issue has no card on this project
# (or the issue does not exist), 3 when the lookup call itself failed.
# Requires PROJECT_ID (set by resolve_board_meta).
resolve_item_by_repo() {  # <repo-owner> <repo-name> <issue-number>
  local out line cost='' iid pid pname
  ITEM_ID=; ITEM_REPO="$1/$2"; ITEM_STATUS=
  out=$(gh_graphql "$FIND_ITEM_QUERY" -F "owner=$1" -F "repo=$2" -F "number=$3" --jq '
    (.data.repository.issue.projectItems.nodes[]? | "item=" + .id + "\t" + (.project.id // "") + "\t" + (.fieldValueByName.name // "")),
    "cost=" + ((.data.rateLimit.cost // "") | tostring)') || return 3
  while IFS= read -r line; do
    case "$line" in
      cost=*) cost=${line#cost=} ;;
      item=*)
        IFS=$'\t' read -r iid pid pname <<<"${line#item=}"
        if [ "$pid" = "$PROJECT_ID" ]; then
          ITEM_ID=$iid
          ITEM_STATUS=$pname
        fi
        ;;
    esac
  done <<EOF
$out
EOF
  debug_cost "item-by-repo" "${cost:-?}"
  [ -n "$ITEM_ID" ]
}

# shellcheck disable=SC2016  # GraphQL $vars are literal query syntax, not shell expansions
BOARD_SCAN_QUERY='query($owner:String!,$number:Int!,$after:String){
  organization(login:$owner){
    projectV2(number:$number){
      items(first:100, after:$after){
        pageInfo { hasNextPage endCursor }
        nodes {
          id
          content {
            __typename
            ... on Issue { number repository { nameWithOwner } }
            ... on PullRequest { number repository { nameWithOwner } }
          }
          fieldValueByName(name:"Status"){ ... on ProjectV2ItemFieldSingleSelectValue { name } }
        }
      }
    }
  }
  rateLimit { cost }
}'

# Page the whole board into $BOARD_ROWS_FILE, one TSV row per card:
# id, __typename, number, repository, status. Only the fields the callers use
# are requested. Accumulates and reports the summed GraphQL cost. Returns 1 if
# any page fetch fails. $BOARD_ROWS_FILE must be set to a writable path.
scan_board() {  # <project-number> <owner>
  local after='' page=0 out line cost total_cost=0 has_next end
  : > "$BOARD_ROWS_FILE"
  while :; do
    page=$((page + 1))
    if [ -n "$after" ]; then
      out=$(gh_graphql "$BOARD_SCAN_QUERY" -F "owner=$2" -F "number=$1" -F "after=$after" --jq '
        (.data.organization.projectV2.items.pageInfo | "page=" + (.hasNextPage|tostring) + "\t" + (.endCursor // "")),
        (.data.organization.projectV2.items.nodes[]? | "item=" + .id + "\t" + (.content.__typename // "") + "\t" + ((.content.number // "") | tostring) + "\t" + (.content.repository.nameWithOwner // "") + "\t" + (.fieldValueByName.name // "")),
        "cost=" + ((.data.rateLimit.cost // "") | tostring)') || return 1
    else
      out=$(gh_graphql "$BOARD_SCAN_QUERY" -F "owner=$2" -F "number=$1" --jq '
        (.data.organization.projectV2.items.pageInfo | "page=" + (.hasNextPage|tostring) + "\t" + (.endCursor // "")),
        (.data.organization.projectV2.items.nodes[]? | "item=" + .id + "\t" + (.content.__typename // "") + "\t" + ((.content.number // "") | tostring) + "\t" + (.content.repository.nameWithOwner // "") + "\t" + (.fieldValueByName.name // "")),
        "cost=" + ((.data.rateLimit.cost // "") | tostring)') || return 1
    fi
    has_next=false
    end=''
    while IFS= read -r line; do
      case "$line" in
        page=*) IFS=$'\t' read -r has_next end <<<"${line#page=}" ;;
        cost=*) cost=${line#cost=}; case "$cost" in ''|*[!0-9]*) ;; *) total_cost=$((total_cost + cost)) ;; esac ;;
        item=*) printf '%s\n' "${line#item=}" >> "$BOARD_ROWS_FILE" ;;
      esac
    done <<EOF
$out
EOF
    [ "$has_next" = true ] || break
    [ -n "$end" ] || break
    after=$end
    [ "$page" -lt "$MAX_PAGES" ] || { diag "board page-scan exceeded $MAX_PAGES pages on project $1; refusing to loop"; return 1; }
  done
  debug_cost "board-scan (${page} page(s))" "$total_cost"
  return 0
}

# No-repo fallback: discover the issue's card by scanning the board (which is
# already project-scoped, so no PROJECT_ID match is needed). Sets ITEM_ID,
# ITEM_REPO, ITEM_STATUS. Returns 0 on exactly one match, 1 when none match, 2
# when more than one repository's card shares the number, 3 when the scan failed.
resolve_item_by_scan() {  # <project-number> <owner> <issue-number>
  local match count
  scan_board "$1" "$2" || return 3
  # Column layout from scan_board: id, __typename, number, repository, status
  match=$(awk -F'\t' -v n="$3" '$2 == "Issue" && $3 == n' "$BOARD_ROWS_FILE")
  count=$(printf '%s\n' "$match" | grep -c . || true)
  case "$count" in
    0) return 1 ;;
    1) IFS=$'\t' read -r ITEM_ID _ _ ITEM_REPO ITEM_STATUS <<<"$match"; return 0 ;;
    *) return 2 ;;
  esac
}

# shellcheck disable=SC2016  # GraphQL $vars are literal query syntax, not shell expansions
MUTATE_QUERY='mutation($project:ID!,$item:ID!,$field:ID!,$option:String!){
  updateProjectV2ItemFieldValue(input:{projectId:$project,itemId:$item,fieldId:$field,value:{singleSelectOptionId:$option}}){ projectV2Item { id } }
}'

# Move one card to an option id. Returns nonzero on failure.
mutate_status() {  # <item-id> <option-id>
  gh_graphql "$MUTATE_QUERY" -F "project=$PROJECT_ID" -F "item=$1" \
    -F "field=$STATUS_FIELD_ID" -F "option=$2" >/dev/null
}

# --- staging for the board scan --------------------------------------------

BOARD_ROWS_FILE=
BOARD_TMP=
ensure_scan_staging() {
  [ -z "$BOARD_TMP" ] || return 0
  BOARD_TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-board.XXXXXX") || return 1
  trap 'rm -rf -- "$BOARD_TMP"' EXIT
  BOARD_ROWS_FILE="$BOARD_TMP/rows.tsv"
}

# --- commands --------------------------------------------------------------

# Resolve issue #N's card into ITEM_ID/ITEM_REPO/ITEM_STATUS, preferring the
# cheap --repo path. Emits the appropriate fail-open diagnostic and returns
# nonzero on any failure. $REPO_ARG is the caller's --repo (may be empty).
locate_item() {  # <issue-number> <project-number> <owner>
  local issue=$1 proj=$2 owner=$3
  if [ -n "$REPO_ARG" ]; then
    local ro=${REPO_ARG%%/*} rn=${REPO_ARG#*/}
    resolve_item_by_repo "$ro" "$rn" "$issue"
    case $? in
      0) return 0 ;;
      1) diag "issue #$issue was not found as a card on project $proj (repo $REPO_ARG, owner $owner)"; return 1 ;;
      *) diag "could not look up issue #$issue on project $proj (repo $REPO_ARG); GraphQL may be rate limited"; return 1 ;;
    esac
  fi
  ensure_scan_staging || { diag "could not create a scratch directory for the board scan"; return 1; }
  resolve_item_by_scan "$proj" "$owner" "$issue"
  case $? in
    0) return 0 ;;
    1) diag "issue #$issue was not found as a card on project $proj (owner $owner)"; return 1 ;;
    2) diag "issue #$issue matches cards in more than one repository on project $proj; pass --repo owner/name to resolve it"; return 1 ;;
    *) diag "could not list items on project $proj (owner $owner)"; return 1 ;;
  esac
}

cmd_move() {  # <issue-number> <stage> <project-number> <owner>
  local issue=$1 stage=$2 proj=$3 owner=$4 option_id target_name
  command -v "$GH" >/dev/null 2>&1 || { diag "$GH is not on PATH"; return 0; }
  resolve_board_meta "$proj" "$owner" || { diag "could not resolve project $proj or its Status field (owner $owner); GraphQL may be rate limited"; return 0; }
  option_id=$(stage_option_id "$stage") || {
    diag "stage '$stage' does not match any Status column on project $proj (have: $(stage_names_human))"
    return 0
  }
  locate_item "$issue" "$proj" "$owner" || return 0
  target_name=$(stage_name_for_option "$option_id")
  if [ "$(normalize_stage "$ITEM_STATUS")" = "$(normalize_stage "$target_name")" ]; then
    echo "issue #$issue ($ITEM_REPO) is already in stage '$ITEM_STATUS' on project $proj"
    return 0
  fi
  if mutate_status "$ITEM_ID" "$option_id"; then
    echo "moved issue #$issue ($ITEM_REPO) from '$ITEM_STATUS' to '$target_name' on project $proj"
  else
    diag "the move mutation failed for issue #$issue to '$target_name' on project $proj"
  fi
  return 0
}

cmd_status() {  # <issue-number> <project-number> <owner>
  local issue=$1 proj=$2 owner=$3
  command -v "$GH" >/dev/null 2>&1 || { diag "$GH is not on PATH"; return 0; }
  # --repo path needs PROJECT_ID to match the card; the scan path is
  # project-scoped and needs it only to keep the diagnostics consistent.
  resolve_board_meta "$proj" "$owner" || { diag "could not resolve project $proj (owner $owner); GraphQL may be rate limited"; return 0; }
  if locate_item "$issue" "$proj" "$owner"; then
    echo "issue #$issue ($ITEM_REPO) is in stage '$ITEM_STATUS' on project $proj"
  fi
  return 0
}

cmd_sweep_stale() {  # <project-number> <owner>
  local proj=$1 owner=$2 repos repo closed terminal_pair terminal_name terminal_id
  local moved=0 iid ityp inum irepo istatus
  command -v "$GH" >/dev/null 2>&1 || { diag "$GH is not on PATH"; return 0; }
  command -v "$GH_AXI" >/dev/null 2>&1 || { diag "$GH_AXI is not on PATH"; return 0; }
  resolve_board_meta "$proj" "$owner" || { diag "could not resolve project $proj or its Status field (owner $owner); GraphQL may be rate limited"; return 0; }
  terminal_pair=${STAGE_PAIRS[${#STAGE_PAIRS[@]} - 1]}
  terminal_name=${terminal_pair%:*}
  terminal_id=${terminal_pair##*:}

  ensure_scan_staging || { diag "could not create a scratch directory for the board scan"; return 0; }
  scan_board "$proj" "$owner" || { diag "could not list items on project $proj (owner $owner)"; return 0; }
  repos=$(awk -F'\t' -v term="$terminal_name" '$2 == "Issue" && $5 != term { print $4 }' "$BOARD_ROWS_FILE" | sort -u)

  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    closed=$(run_bounded "$GH_AXI" issue list -R "$repo" --state closed --limit "$ISSUE_LIMIT" 2>/dev/null \
      | grep -oE '^  [0-9]+,' | tr -d ' ,') || closed=
    [ -n "$closed" ] || continue
    while IFS=$'\t' read -r iid ityp inum irepo istatus; do
      [ "$ityp" = "Issue" ] || continue
      [ "$irepo" = "$repo" ] || continue
      [ "$istatus" != "$terminal_name" ] || continue
      printf '%s\n' "$closed" | grep -qxF "$inum" || continue
      if mutate_status "$iid" "$terminal_id"; then
        echo "moved issue #$inum ($irepo) from '$istatus' to '$terminal_name' (issue is closed)"
        moved=$((moved + 1))
      else
        diag "the move mutation failed for issue #$inum ($irepo) to '$terminal_name'"
      fi
    done < "$BOARD_ROWS_FILE"
  done <<<"$repos"

  [ "$moved" -gt 0 ] || echo "sweep-stale: no stale cards found on project $proj"
  return 0
}

# --- argument parsing -------------------------------------------------------

[ "$#" -ge 1 ] || { usage >&2; exit 2; }
case "${1-}" in -h|--help|help) usage; exit 0 ;; esac
SUB=$1
shift

PROJECT=2
OWNER=digio-nz
REPO_ARG=
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
    --repo)
      [ "$#" -ge 2 ] && [ -n "$2" ] || { echo "error: --repo requires a value" >&2; exit 2; }
      REPO_ARG=$2; shift 2 ;;
    --repo=*)
      REPO_ARG=${1#--repo=}
      [ -n "$REPO_ARG" ] || { echo "error: --repo requires a value" >&2; exit 2; }
      shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; while [ "$#" -gt 0 ]; do POS+=("$1"); shift; done ;;
    -*) echo "error: unknown flag: $1" >&2; exit 2 ;;
    *) POS+=("$1"); shift ;;
  esac
done
case "$PROJECT" in *[!0-9]*|'') echo "error: --project must be a positive integer" >&2; exit 2 ;; esac

# --repo shape failures are fail-open diagnostics, not usage errors: a malformed
# repo must never turn a courtesy call into a failure.
if [ -n "$REPO_ARG" ] && ! valid_repo "$REPO_ARG"; then
  diag "--repo '$REPO_ARG' is not a valid owner/name; ignoring it and resolving by board scan"
  REPO_ARG=
fi

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
    [ -z "$REPO_ARG" ] || { echo "error: --repo does not apply to sweep-stale (it inspects the whole board)" >&2; exit 2; }
    cmd_sweep_stale "$PROJECT" "$OWNER"
    ;;
  *)
    echo "error: unknown subcommand: $SUB" >&2
    usage >&2
    exit 2
    ;;
esac
exit 0
