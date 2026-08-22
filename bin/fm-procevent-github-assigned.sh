#!/usr/bin/env bash
# GitHub self-assignment adapter for the generic process-to-event runner.
#
# Usage:
#   fm-procevent-github-assigned.sh arm
#   fm-procevent-github-assigned.sh poll <home>
#   fm-procevent-github-assigned.sh list
#   fm-procevent-github-assigned.sh handle <source-id> <sequence> <result-file>
#   fm-procevent-github-assigned.sh autohandle <source-id> <sequence> <result-file>
#   fm-procevent-github-assigned.sh classify <result-file>
#   fm-procevent-github-assigned.sh terminal <result-file>
#   fm-procevent-github-assigned.sh source-id
#   fm-procevent-github-assigned.sh retire
#
# `arm` registers one bounded poll of GitHub with bin/fm-procevent.sh, which owns
# supervision, one machine-wide owner per source, durable capture, publication,
# and restart; this adapter adds no daemon of its own. The captain
# self-assigning a GitHub issue or a project-board draft is firstmate's
# prioritisation signal, and this listener's only job is to notice that signal
# and wake firstmate - it decides nothing about what to do with a
# self-assignment. Issue-triage logic, auto-pickup behaviour, and board-move
# side effects are deliberately out of scope for this listener.
#
# `list` is a manual, on-demand helper: it prints the configured login's
# currently assigned open issues and assigned board drafts, with no cursor side
# effects, for a human or agent to read directly.
#
# This source is NEVER terminal: the captain can always self-assign again, so
# the runner keeps it armed no matter what a result contained.
#
# CONFIGURATION - $FM_HOME/config/github-assigned, one key per line:
#   login=<github login>          optional, default digbycampbell
#   repo=<owner/repo>             repeatable; issues in each named repo are
#                                 watched regardless of board membership.
#                                 default digio-nz/fcdispatch when absent
#   project_owner=<org login>     optional, default digio-nz
#   project_number=<n>            optional, default 2
#   interval=<seconds>            optional poll interval for issues, default 300
#   board_interval=<seconds>      optional poll interval for the project board,
#                                 default 1800; see RATE-LIMIT below for why it
#                                 is slower than `interval`
# `login`, `project_owner`, and every repo owner are validated as GitHub login
# shapes (letters, digits, hyphens, <=39 chars); a repo entry is
# <owner>/<name>. project_owner is assumed to name an organization: the
# adapter reads the board through GraphQL's `organization(login:...)` field,
# so a personal (user-owned) project is not currently supported.
#
# AUTHENTICATION is gh-axi's own: no token lives in this adapter or in .env. A
# broken GitHub credential is already surfaced by firstmate's own session-start
# network check, so this adapter does not duplicate that reporting - it simply
# treats every GitHub call failure as transient and retries on the next poll
# interval, and to firstmate simply reports nothing until the underlying
# credential recovers.
#
# RATE-LIMIT-FRIENDLINESS is load-bearing, not a nice-to-have: GitHub's GraphQL
# quota (5,000/hour) is shared with every other GraphQL caller on the same
# token, including manual board operations, and has been observed fully
# exhausted by those. This adapter is deliberately built around that scarcity:
#   - Issues are read through `GET /repos/<owner>/<repo>/issues?assignee=<login>`,
#     one call per configured repo, which spends the generous 5,000/hour "core"
#     quota rather than the Search API's separate 30/minute budget. It is
#     scoped to exactly the login's assigned items in exactly the configured
#     repos, never a whole-repo or whole-board listing.
#   - The project board (GraphQL) is intake-only and lower priority than a real
#     issue, so it is polled on its own slower `board_interval` cadence
#     (default 1,800s) while issues keep the faster `interval` (default 300s).
#     A board-cadence miss costs latency on noticing a new draft, never
#     correctness: the next scheduled board poll still finds it.
#   - Before spending either quota, `quota_ok` reads the free `/rate_limit`
#     endpoint (checking it never itself counts against any limit) and skips
#     that surface's fetch for this cycle - fail-open, logged, retried next
#     cycle - when remaining capacity is below FM_GITHUB_ASSIGNED_MIN_CORE_QUOTA
#     or FM_GITHUB_ASSIGNED_MIN_GRAPHQL_QUOTA (default 100 and 50). A quota
#     check that itself fails never blocks the real fetch; it only stops being
#     an early warning, and the real call's own fail-open handling still
#     applies.
#   - An issues-quota shortage and a board-quota shortage are independent: a
#     board fetch skipped or failed this cycle never blocks noticing a newly
#     assigned real issue via the still-healthy core quota, which is exactly
#     the scenario that motivated this design (GraphQL exhausted by manual
#     board work while core quota remains untouched).
#
# CONDITIONAL REQUESTS (ETag / If-Modified-Since), which would make a
# no-change poll free against the rate limit, were evaluated and are NOT used
# here, for two independent reasons verified at implementation time rather
# than assumed: `gh-axi api` has no flag to surface response headers (no
# `--include`/`-i`), so an ETag can never be read back to resend; and sending
# `If-Modified-Since` with the current time against a live repo's issues
# listing still returned a normal 200 with a body, meaning GitHub does not
# honor conditional revalidation on this listing endpoint the way it does for
# single-resource GETs. Rather than wire up header plumbing that cannot work
# end to end, this adapter substitutes cheap-endpoint selection, split cadence,
# and proactive quota checking, all three of which are independently effective
# and verified above.
#
# TWO SURFACES, ONE UNION. Each poll reads the configured repos' open assigned
# issues via the REST endpoint above, and separately reads the configured
# project board's items assigned to the login via GraphQL, keeping only items
# typed Issue or DraftIssue (pull requests are never surfaced). The two results
# are combined into one set, deduplicated by canonical id, so an issue that is
# both in a watched repo and on the board is counted once. Both reads go
# through `gh-axi api`, the only gh-axi surface that returns machine-shaped
# output; every other gh-axi subcommand renders a TOON table meant for a human
# or agent to read, not to be parsed here.
#
# gh-axi's `api` command tries to JSON-parse the raw GitHub response and, on
# success, re-renders it as a TOON table - which is exactly what this adapter's
# --jq filters defeat, because they always emit multiple newline-joined
# strings rather than one parseable JSON document. That reliably drives gh-axi
# into its documented fallback envelope instead:
#   api_response:
#     body: "<jq output, JSON-string-escaped>"
#     truncated: false
# `--full` is passed on every call so that envelope is never truncated.
# envelope_body() below trusts nothing about this shape beyond checking those
# three lines are present; any other shape is treated as a fetch failure
# (fail-open), never parsed speculatively.
#
# CANONICAL IDENTITY. An assigned issue is identified as "issue:<owner>/<repo>#<number>",
# stable across relabeling, retitling, or reassignment-and-reassignment-again.
# A board draft is identified as "draft:<project item id>" (its PVTI_... id),
# the project item's own stable identity.
#
# READ-POSITION CONTINUITY, an EVER-GROWING known-id set rather than a single
# advancing timestamp: the stored cursor is every id this adapter has ever
# reported as newly assigned, and each poll's "new" set is this poll's full
# live assignment set minus that stored set. A captured result carries the
# cursor's content both before (cursor_from) and after (cursor_to) as content
# hashes, and advance_cursor refuses to move the cursor unless the currently
# stored content still matches cursor_from, exactly like the Slack captain
# adapter's from_ts/to_ts continuation check.
#
# LIMITATION, stated plainly: because the known set only grows, an item that is
# unassigned and later reassigned to the same login does not produce a second
# wake, since its id was already recorded as seen. Solving that would require
# advancing the cursor on every poll cycle - including a quiet one where
# nothing new appeared - which the generic runner's capture-only-on-result
# convention does not support without inventing a second notification path.
# This is an accepted v1 boundary, not a hidden one.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

MAX_LOOPS=${FM_GITHUB_ASSIGNED_MAX_LOOPS:-12}
MAX_PAGES=${FM_GITHUB_ASSIGNED_MAX_PAGES:-10}
DEFAULT_INTERVAL=300
DEFAULT_BOARD_INTERVAL=1800
DEFAULT_LOGIN=digbycampbell
DEFAULT_REPO=digio-nz/fcdispatch
DEFAULT_PROJECT_OWNER=digio-nz
DEFAULT_PROJECT_NUMBER=2
SCHEMA=fm-github-assigned.v1
CURSOR_SCHEMA=fm-github-assigned-cursor.v1
NO_RESULT_EXIT=75
# Minimum remaining quota (see the RATE-LIMIT header note) below which a fetch
# is skipped for this cycle rather than spent.
QUOTA_MIN_CORE=${FM_GITHUB_ASSIGNED_MIN_CORE_QUOTA:-100}
QUOTA_MIN_GRAPHQL=${FM_GITHUB_ASSIGNED_MIN_GRAPHQL_QUOTA:-50}

HOME_DIR=$FM_HOME
POLL_TMP=

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,139p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }

state_dir()   { printf '%s\n' "${FM_STATE_OVERRIDE:-$HOME_DIR/state}"; }
config_file() { printf '%s\n' "${FM_CONFIG_OVERRIDE:-$HOME_DIR/config}/github-assigned"; }
cursor_dir()  { printf '%s\n' "$(state_dir)/github-assigned"; }
cursor_path() { printf '%s/%s.cursor\n' "$(cursor_dir)" "$1"; }

require_tools() {
  command -v gh-axi >/dev/null 2>&1 || die "gh-axi is not installed"
  command -v jq >/dev/null 2>&1 || die "jq is not installed"
  command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 \
    || die "neither sha256sum nor shasum is installed"
}

valid_login() {
  case "${1-}" in
    ''|*[!A-Za-z0-9-]*) return 1 ;;
  esac
  [ "${#1}" -le 39 ]
}

valid_repo() {
  local repo=${1-} owner name
  case "$repo" in
    ''|*/*/*) return 1 ;;
    */*) ;;
    *) return 1 ;;
  esac
  owner=${repo%%/*}
  name=${repo#*/}
  valid_login "$owner" || return 1
  case "$name" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  [ "${#name}" -le 100 ]
}

valid_project_number() {
  case "${1-}" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "${#1}" -le 10 ]
}

# A GraphQL pagination cursor is opaque, external, and reused verbatim in the
# next query text (not passed as a --field, so it must be safe to embed
# literally); this bounds its shape before that happens.
valid_gql_cursor() {
  case "${1-}" in
    ''|*[!A-Za-z0-9+/=_-]*) return 1 ;;
  esac
  [ "${#1}" -le 512 ]
}

config_get() {  # <key> - last matching line, like the other adapters' single-value keys
  local file
  file=$(config_file)
  [ -e "$file" ] || return 0
  [ -f "$file" ] && [ ! -L "$file" ] || die "github-assigned configuration is unsafe: $file"
  sed -n "s/^[[:space:]]*$1=//p" "$file" | tail -n1 | tr -d '[:space:]'
}

config_get_all() {  # <key> - every matching line, for the repeatable repo= key
  local file
  file=$(config_file)
  [ -e "$file" ] || return 0
  [ -f "$file" ] && [ ! -L "$file" ] || die "github-assigned configuration is unsafe: $file"
  sed -n "s/^[[:space:]]*$1=//p" "$file"
}

# Sets CFG_LOGIN, CFG_REPOS (array), CFG_PROJECT_OWNER, CFG_PROJECT_NUMBER,
# CFG_INTERVAL.
load_config() {
  local r
  CFG_LOGIN=$(config_get login)
  [ -n "$CFG_LOGIN" ] || CFG_LOGIN=$DEFAULT_LOGIN
  valid_login "$CFG_LOGIN" || die "config/github-assigned has an invalid login"

  CFG_REPOS=()
  while IFS= read -r r; do
    r=$(printf '%s' "$r" | tr -d '[:space:]')
    [ -n "$r" ] || continue
    CFG_REPOS+=("$r")
  done < <(config_get_all repo)
  [ "${#CFG_REPOS[@]}" -gt 0 ] || CFG_REPOS=("$DEFAULT_REPO")
  for r in "${CFG_REPOS[@]}"; do
    valid_repo "$r" || die "config/github-assigned has an invalid repo entry: $r"
  done

  CFG_PROJECT_OWNER=$(config_get project_owner)
  [ -n "$CFG_PROJECT_OWNER" ] || CFG_PROJECT_OWNER=$DEFAULT_PROJECT_OWNER
  valid_login "$CFG_PROJECT_OWNER" || die "config/github-assigned has an invalid project_owner"

  CFG_PROJECT_NUMBER=$(config_get project_number)
  [ -n "$CFG_PROJECT_NUMBER" ] || CFG_PROJECT_NUMBER=$DEFAULT_PROJECT_NUMBER
  valid_project_number "$CFG_PROJECT_NUMBER" || die "config/github-assigned has an invalid project_number"

  CFG_INTERVAL=${FM_GITHUB_ASSIGNED_INTERVAL-}
  if [ -z "$CFG_INTERVAL" ]; then
    CFG_INTERVAL=$(config_get interval)
    [ -n "$CFG_INTERVAL" ] || CFG_INTERVAL=$DEFAULT_INTERVAL
  fi
  case "$CFG_INTERVAL" in
    ''|*[!0-9]*) die "config/github-assigned has an invalid interval" ;;
  esac

  CFG_BOARD_INTERVAL=${FM_GITHUB_ASSIGNED_BOARD_INTERVAL-}
  if [ -z "$CFG_BOARD_INTERVAL" ]; then
    CFG_BOARD_INTERVAL=$(config_get board_interval)
    [ -n "$CFG_BOARD_INTERVAL" ] || CFG_BOARD_INTERVAL=$DEFAULT_BOARD_INTERVAL
  fi
  case "$CFG_BOARD_INTERVAL" in
    ''|*[!0-9]*) die "config/github-assigned has an invalid board_interval" ;;
  esac
}

cmd_source_id() {
  load_config
  printf 'github-assigned-%s\n' "$CFG_LOGIN"
}

cmd_arm() {
  local id
  require_tools
  load_config
  id=$(cmd_source_id) || exit 1
  "$SCRIPT_DIR/fm-procevent.sh" register github-assigned "$id" -- \
    "$SCRIPT_DIR/fm-procevent-github-assigned.sh" poll "$HOME_DIR" || exit 1
  printf 'armed: %s\n' "$id"
}

cmd_retire() {
  local id
  id=$(cmd_source_id) || exit 1
  "$SCRIPT_DIR/fm-procevent.sh" retire "$id"
}

# --- cursor -------------------------------------------------------------

hash_of_file() {  # <file>
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# Stages the stored known-id set, sorted and deduplicated, into
# $prev_ids_sorted. An absent cursor is an empty set, matching the adapter's
# ever-growing model: nothing has ever been reported before.
read_cursor() {  # <login>
  local path schema
  path=$(cursor_path "$1")
  : > "$prev_ids_sorted"
  [ -e "$path" ] || return 0
  [ -f "$path" ] && [ ! -L "$path" ] || die "github-assigned cursor is unsafe: $path"
  schema=$(head -n1 "$path")
  [ "$schema" = "schema=$CURSOR_SCHEMA" ] \
    || die "github-assigned cursor has an incompatible schema: $path"
  tail -n +2 "$path" | sort -u > "$prev_ids_sorted"
}

write_cursor() {  # <login> <content-file, already sorted ids one per line>
  local path dir tmp
  path=$(cursor_path "$1")
  dir=$(dirname "$path")
  (umask 077; mkdir -p "$dir") || return 1
  [ ! -L "$path" ] || return 1
  tmp=$(umask 077; mktemp "$dir/.cursor.XXXXXX") || return 1
  { printf 'schema=%s\n' "$CURSOR_SCHEMA"; cat "$2"; } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$path"
}

# --- reading the gh-axi api envelope -----------------------------------

# Decode gh-axi's `api_response: / body: ... / truncated: false` envelope.
# Trusts nothing about the shape beyond those three fixed lines; anything else
# - including a successfully-JSON-parsed reply gh-axi rendered some other way,
# or a truncated body despite --full - is refused rather than guessed at.
#
# gh-axi's underlying `gh api --jq` call emits RAW (unquoted) jq output, not
# JSON-encoded text, verified directly against the real `gh` binary at
# implementation time. gh-axi then tries to JSON.parse that raw text: when the
# text happens to be valid JSON on its own (this adapter hits that only for a
# bare-digit quota reading), parsing succeeds and TOON re-renders it as a bare
# scalar with no envelope at all - which is why every filter in this adapter is
# deliberately built to never be valid JSON by itself (a multi-row TSV stream,
# or a "quota=<n>" prefix), so parsing reliably fails and this envelope always
# wraps it. Inside the envelope, TOON quotes the body value only when it
# contains characters that would otherwise be ambiguous (a tab, a newline, a
# leading/trailing quote); a value with none of those - such as "quota=5000" -
# is written bare. Both forms are handled below; anything else is refused.
envelope_body() {  # <raw-output-file>
  local l1 l2 l3 rest
  { IFS= read -r l1 <&3 || return 1
    IFS= read -r l2 <&3 || return 1
    IFS= read -r l3 <&3 || return 1
  } 3< "$1"
  [ "$l1" = 'api_response:' ] || return 1
  case "$l2" in '  body: '*) ;; *) return 1 ;; esac
  [ "$l3" = '  truncated: false' ] || return 1
  rest=${l2#'  body: '}
  case "$rest" in
    '"'*'"')
      jq -rn --argjson v "$rest" '$v' 2>/dev/null || return 1
      ;;
    *[!A-Za-z0-9=_./:-]*)
      return 1
      ;;
    *)
      printf '%s\n' "$rest"
      ;;
  esac
}

# Run `gh-axi api ... --full` and decode its envelope. Sets FETCHED (1 ok, 0 any
# failure - a nonzero exit, or an unrecognized output shape) and, on success,
# BODY_TEXT (may be empty). Every caller treats FETCHED=0 identically: log a
# diagnostic and let this poll cycle retry, never crash and never wedge.
gh_api_body() {  # <gh-axi api args...>
  local rc detail
  gh-axi api "$@" --full > "$resp_raw" 2> "$resp_err"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    FETCHED=0
    # gh-axi reports its own errors on stdout (verified at implementation
    # time), so both streams are shown; real stderr (a crash, a missing
    # binary) still surfaces even when gh-axi itself printed nothing there.
    detail=$(cat "$resp_raw" "$resp_err" 2>/dev/null | tr '\n' ' ')
    printf 'github-assigned: gh-axi call failed: %s\n' "$detail" >&2
    return 0
  fi
  if ! BODY_TEXT=$(envelope_body "$resp_raw"); then
    FETCHED=0
    printf 'github-assigned: unexpected gh-axi output shape; retrying\n' >&2
    return 0
  fi
  FETCHED=1
}

# --- quota awareness ------------------------------------------------------

# Prints the remaining count for one /rate_limit resource, or nothing (and
# returns 1) if it cannot be read. Reading /rate_limit never itself counts
# against any quota. The filter prefixes a non-numeric marker so its raw
# output can never itself be mistaken for standalone valid JSON - see the
# envelope_body note on why that matters.
quota_remaining() {  # <resource: core|graphql>
  local filter
  filter=$(printf '"quota=\\(.resources.%s.remaining)"' "$1")
  gh_api_body /rate_limit --jq "$filter"
  [ "$FETCHED" = 1 ] || return 1
  case "$BODY_TEXT" in
    quota=*) ;;
    *) return 1 ;;
  esac
  BODY_TEXT=${BODY_TEXT#quota=}
  case "$BODY_TEXT" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "$BODY_TEXT"
}

# quota_ok <resource> <minimum>: 0 when safe to proceed, including when the
# check itself could not be read (best-effort only - the real call's own
# fail-open handling still governs), 1 when known-low and the caller should
# skip spending this quota for the current cycle.
quota_ok() {
  local remaining
  remaining=$(quota_remaining "$1") || return 0
  [ "$remaining" -ge "$2" ]
}

# --- fetching issues (REST, per repo) -------------------------------------

# The jq filter for one repo's assigned-issues listing. The repo name is
# embedded literally (gh-axi's --jq takes only a plain expression string, no
# variable binding), safe because valid_repo already restricted its charset to
# letters, digits, ., _, -, and / - nothing that can break out of a jq string
# literal.
issues_jq_filter() {  # <repo>
  printf '["count", (length | tostring)] | @tsv,
  (.[] | select(has("pull_request") | not) | [
    "issue", ("issue:%s#" + (.number | tostring)), (.number | tostring), "%s", .html_url, .title
  ] | @tsv)' "$1" "$1"
}

# Fetches every open issue assigned to the login across the configured repos
# into $issues_tmp, as "issue<TAB>id<TAB>number<TAB>repo<TAB>url<TAB>title" rows,
# one call per repo against the generous "core" rate limit (see the
# RATE-LIMIT header note for why this is not the Search API). Sets FETCHED.
fetch_issues() {
  local r page kind rest line raw_count
  : > "$issues_tmp"
  if ! quota_ok core "$QUOTA_MIN_CORE"; then
    FETCHED=0
    printf 'github-assigned: core API quota is low (below %s remaining); skipping this cycle\n' \
      "$QUOTA_MIN_CORE" >&2
    return 0
  fi
  for r in "${CFG_REPOS[@]}"; do
    page=1
    while :; do
      gh_api_body "/repos/$r/issues" --field assignee="$CFG_LOGIN" --field state=open \
        --field per_page=100 --field page="$page" --jq "$(issues_jq_filter "$r")"
      [ "$FETCHED" = 1 ] || return 0
      raw_count=0
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        kind=${line%%$'\t'*}
        rest=${line#*$'\t'}
        case "$kind" in
          count) raw_count=$rest ;;
          issue) printf '%s\n' "$line" >> "$issues_tmp" ;;
        esac
      done <<< "$BODY_TEXT"
      [ "$raw_count" -ge 100 ] || break
      page=$((page + 1))
      [ "$page" -le "$MAX_PAGES" ] \
        || die "assigned issues in $r past page $MAX_PAGES exceed the bounded page count; refusing to emit a partial capture"
    done
  done
  FETCHED=1
}

# --- fetching the project board (GraphQL) -------------------------------

project_items_query() {  # <after-cursor-or-empty>
  if [ -n "$1" ]; then
    # shellcheck disable=SC2016 # $after is a literal GraphQL variable reference, not a shell expansion
    printf 'query($after: String) { organization(login: "%s") { projectV2(number: %s) { items(first: 100, after: $after) { pageInfo { hasNextPage endCursor } nodes { id content { __typename ... on DraftIssue { title assignees(first: 20) { nodes { login } } } ... on Issue { number title url state repository { nameWithOwner } assignees(first: 20) { nodes { login } } } } } } } } }' \
      "$CFG_PROJECT_OWNER" "$CFG_PROJECT_NUMBER"
  else
    printf 'query { organization(login: "%s") { projectV2(number: %s) { items(first: 100) { pageInfo { hasNextPage endCursor } nodes { id content { __typename ... on DraftIssue { title assignees(first: 20) { nodes { login } } } ... on Issue { number title url state repository { nameWithOwner } assignees(first: 20) { nodes { login } } } } } } } } }' \
      "$CFG_PROJECT_OWNER" "$CFG_PROJECT_NUMBER"
  fi
}

# Fetches every open Issue or DraftIssue board item assigned to the login into
# $project_tmp, in the same row shape fetch_issues produces. Sets FETCHED.
project_jq_filter() {
  printf '(.data.organization.projectV2.items.pageInfo | ["page", (.hasNextPage | tostring), (.endCursor // "")] | @tsv),
    (.data.organization.projectV2.items.nodes[]
     | select(.content.assignees.nodes // [] | map(.login) | index("%s") != null)
     | if .content.__typename == "DraftIssue" then
         ["item", "draft", ("draft:" + .id), "", "", "", .content.title]
       elif .content.__typename == "Issue" and .content.state == "OPEN" then
         ["item", "issue",
           ("issue:" + .content.repository.nameWithOwner + "#" + (.content.number | tostring)),
           (.content.number | tostring), .content.repository.nameWithOwner, .content.url, .content.title]
       else empty end
     | @tsv)' "$CFG_LOGIN"
}

fetch_project() {
  local after='' page=1 kind rest has_next line
  local -a extra_fields
  : > "$project_tmp"
  if ! quota_ok graphql "$QUOTA_MIN_GRAPHQL"; then
    FETCHED=0
    printf 'github-assigned: GraphQL API quota is low (below %s remaining); skipping the board poll this cycle\n' \
      "$QUOTA_MIN_GRAPHQL" >&2
    return 0
  fi
  while :; do
    extra_fields=()
    [ -z "$after" ] || extra_fields=(--field "after=$after")
    gh_api_body POST graphql --field query="$(project_items_query "$after")" \
      "${extra_fields[@]}" --jq "$(project_jq_filter)"
    [ "$FETCHED" = 1 ] || return 0
    has_next=false
    after=''
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      kind=${line%%$'\t'*}
      rest=${line#*$'\t'}
      case "$kind" in
        page)
          has_next=${rest%%$'\t'*}
          after=${rest#*$'\t'}
          ;;
        item)
          printf '%s\n' "$rest" >> "$project_tmp"
          ;;
      esac
    done <<< "$BODY_TEXT"
    [ "$has_next" = true ] || return 0
    valid_gql_cursor "$after" || die "GitHub returned an unusable project pagination cursor"
    page=$((page + 1))
    [ "$page" -le "$MAX_PAGES" ] \
      || die "the project board past page $MAX_PAGES exceeds the bounded page count; refusing to emit a partial capture"
  done
}

# --- combining, diffing, and emitting -----------------------------------

# Combines $issues_tmp and $project_tmp into a deduplicated, sorted snapshot,
# diffs it against <login>'s stored known-id set, and sets NEW_COUNT,
# NEW_ISSUE_COUNT, NEW_DRAFT_COUNT, FROM_HASH, TO_HASH. Writes the new rows to
# $new_rows_file and the next cursor content (the union of the stored set and
# this snapshot) to $union_ids.
build_snapshot() {  # <login>
  read_cursor "$1"
  cat "$issues_tmp" "$project_tmp" > "$combined_tmp"
  awk -F'\t' '!seen[$2]++' "$combined_tmp" | sort -t $'\t' -k2,2 > "$snapshot_rows"
  cut -f2 "$snapshot_rows" | sort -u > "$current_ids"
  comm -23 "$current_ids" "$prev_ids_sorted" > "$new_ids"
  cat "$current_ids" "$prev_ids_sorted" | sort -u > "$union_ids"
  NEW_COUNT=$(wc -l < "$new_ids" | tr -d ' ')
  awk -F'\t' 'NR==FNR { want[$1] = 1; next } ($2 in want)' "$new_ids" "$snapshot_rows" > "$new_rows_file"
  NEW_ISSUE_COUNT=$(awk -F'\t' '$1 == "issue"' "$new_rows_file" | wc -l | tr -d ' ')
  NEW_DRAFT_COUNT=$(awk -F'\t' '$1 == "draft"' "$new_rows_file" | wc -l | tr -d ' ')
  FROM_HASH=$(hash_of_file "$prev_ids_sorted")
  TO_HASH=$(hash_of_file "$union_ids")
}

emit_result() {
  printf 'schema=%s\n' "$SCHEMA"
  printf 'status=assigned\n'
  printf 'login=%s\n' "$CFG_LOGIN"
  printf 'count=%s\n' "$NEW_COUNT"
  printf 'issue_count=%s\n' "$NEW_ISSUE_COUNT"
  printf 'draft_count=%s\n' "$NEW_DRAFT_COUNT"
  printf 'cursor_from=%s\n' "$FROM_HASH"
  printf 'cursor_to=%s\n' "$TO_HASH"
  printf '\n'
  cat "$union_ids"
  printf '\n'
  while IFS=$'\t' read -r type id number repo url title; do
    printf 'new\t%s\t%s\t%s\t%s\t%s\t%s\n' "$type" "$id" "$number" "$repo" "$url" "$title"
  done < "$new_rows_file"
}

# poll_once <do-board: 0|1>. Issues are always (re)fetched; the board is only
# fetched when the caller's slower cadence says it is due (see cmd_poll). A
# board fetch that is skipped or that itself fails never blocks noticing a
# newly assigned issue - $project_tmp is simply empty for this cycle, and
# BOARD_FETCHED tells the caller whether to reschedule the next board poll.
poll_once() {
  local do_board=$1
  BOARD_FETCHED=0
  fetch_issues
  [ "$FETCHED" = 1 ] || return 1
  if [ "$do_board" = 1 ]; then
    fetch_project
    BOARD_FETCHED=$FETCHED
  fi
  [ "$BOARD_FETCHED" = 1 ] || : > "$project_tmp"
  build_snapshot "$CFG_LOGIN"
  [ "$NEW_COUNT" -gt 0 ] || return 1
  emit_result
  return 0
}

staging() {
  POLL_TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-github-assigned.XXXXXX") || die "cannot create a staging directory"
  trap 'rm -rf -- "$POLL_TMP"' EXIT
  resp_raw="$POLL_TMP/resp.raw"
  resp_err="$POLL_TMP/resp.err"
  issues_tmp="$POLL_TMP/issues.tsv"
  project_tmp="$POLL_TMP/project.tsv"
  combined_tmp="$POLL_TMP/combined.tsv"
  snapshot_rows="$POLL_TMP/snapshot.tsv"
  current_ids="$POLL_TMP/current.ids"
  prev_ids_sorted="$POLL_TMP/prev.sorted.ids"
  new_ids="$POLL_TMP/new.ids"
  union_ids="$POLL_TMP/union.ids"
  new_rows_file="$POLL_TMP/new.rows.tsv"
  snapshot_block_file="$POLL_TMP/snapshot-block.ids"
}

# The board's due-for-poll state is only tracked in memory for this bounded
# child's own lifetime, never persisted: once anything is captured this
# process exits anyway, and the next spawned child simply polls the board on
# its own first cycle. That is a soft pacing hint, not a correctness
# requirement - see the RATE-LIMIT header note.
cmd_poll() {  # <home>
  local home=${1-} i=0 next_board_due=0 now do_board
  [ -n "$home" ] || usage
  HOME_DIR=$home
  require_tools
  load_config
  staging
  while [ "$i" -lt "$MAX_LOOPS" ]; do
    i=$((i + 1))
    now=$(date +%s)
    do_board=0
    [ "$now" -lt "$next_board_due" ] || do_board=1
    poll_once "$do_board" && return 0
    if [ "$do_board" = 1 ] && [ "$BOARD_FETCHED" = 1 ]; then
      next_board_due=$((now + CFG_BOARD_INTERVAL))
    fi
    [ "$i" -lt "$MAX_LOOPS" ] || break
    sleep "$CFG_INTERVAL"
  done
  # Nothing newly assigned this run: no result, no wake, and the runner's
  # ordinary reconcile starts the next bounded run.
  return "$NO_RESULT_EXIT"
}

# --- list: manual on-demand helper --------------------------------------

cmd_list() {
  require_tools
  load_config
  staging
  fetch_issues
  [ "$FETCHED" = 1 ] || die "could not read assigned issues from GitHub"
  fetch_project
  [ "$FETCHED" = 1 ] || die "could not read the assigned project board items from GitHub"
  cat "$issues_tmp" "$project_tmp" > "$combined_tmp"
  awk -F'\t' '!seen[$2]++' "$combined_tmp" | sort -t $'\t' -k2,2 > "$snapshot_rows"
  local total issues drafts
  total=$(wc -l < "$snapshot_rows" | tr -d ' ')
  issues=$(awk -F'\t' '$1 == "issue"' "$snapshot_rows" | wc -l | tr -d ' ')
  drafts=$(awk -F'\t' '$1 == "draft"' "$snapshot_rows" | wc -l | tr -d ' ')
  printf 'count: %s (%s issue, %s draft) assigned to %s\n' "$total" "$issues" "$drafts" "$CFG_LOGIN"
  while IFS=$'\t' read -r type id number repo url title; do
    case "$type" in
      issue) printf 'issue %s#%s "%s" %s\n' "$repo" "$number" "$title" "$url" ;;
      draft) printf 'draft %s "%s"\n' "${id#draft:}" "$title" ;;
    esac
  done < "$snapshot_rows"
}

# --- reading a captured result -------------------------------------------

result_field() {  # <result-file> <field>
  LC_ALL=C awk -v prefix="$2=" '
    $0 == "" { exit }
    index($0, prefix) == 1 { count++; value = substr($0, length(prefix) + 1) }
    END { if (count != 1) exit 1; print value }
  ' "$1"
}

# The next-cursor content block: everything between the first blank line (the
# header boundary) and the second (where the untrusted "new" rows begin). Never
# reads past that second boundary, so a fetched title can never be mistaken for
# cursor content.
payload_snapshot_block() {  # <result-file>
  awk '
    stage == 0 { if ($0 == "") { stage = 1 }; next }
    stage == 1 { if ($0 == "") { exit }; print }
  ' "$1"
}

cmd_classify() {
  local file=${1-} schema status
  [ -n "$file" ] || usage
  [ -f "$file" ] && [ ! -L "$file" ] || { printf 'unknown\n'; return 0; }
  [ -s "$file" ] || { printf 'empty\n'; return 0; }
  schema=$(result_field "$file" schema 2>/dev/null || true)
  [ "$schema" = "$SCHEMA" ] || { printf 'unknown\n'; return 0; }
  status=$(result_field "$file" status 2>/dev/null || true)
  case "$status" in
    assigned) printf 'assigned\n' ;;
    *) printf 'unknown\n' ;;
  esac
}

# This source is never terminal: the captain can always self-assign again.
cmd_terminal() {
  [ -n "${1-}" ] || usage
  return 1
}

# Advance the stored known-id set to the result's committed union, refusing a
# result that does not continue the stored position - exactly like the Slack
# captain adapter's read-position check, but by content hash rather than by
# timestamp order, since the known set is an unordered id set.
advance_cursor() {  # <result-file>
  local file=$1 login from to current_hash
  login=$(result_field "$file" login) || die "result carries no login"
  from=$(result_field "$file" cursor_from) || die "result start read position is ambiguous"
  to=$(result_field "$file" cursor_to) || die "result end read position is ambiguous"
  read_cursor "$login"
  current_hash=$(hash_of_file "$prev_ids_sorted")
  if [ "$current_hash" = "$to" ]; then
    return 0
  fi
  [ "$current_hash" = "$from" ] \
    || die "captured GitHub assignment result does not continue the stored read position for $login"
  payload_snapshot_block "$file" > "$snapshot_block_file"
  [ "$(hash_of_file "$snapshot_block_file")" = "$to" ] \
    || die "captured GitHub assignment result is internally inconsistent"
  write_cursor "$login" "$snapshot_block_file" || die "cannot commit the github-assigned read position"
}

apply_result() {  # <source-id> <sequence> <result-file> <mark-handled>
  local sid=${1-} seq=${2-} file=${3-} mark=${4-} class
  case "$seq" in ''|*[!0-9]*) die "sequence must be a nonnegative integer" ;; esac
  [ -f "$file" ] && [ ! -L "$file" ] || die "result file is unavailable or unsafe: $file"
  staging
  class=$(cmd_classify "$file")
  case "$class" in
    assigned) advance_cursor "$file" ;;
    *) die "captured GitHub assignment result needs firstmate's attention: $class" ;;
  esac
  if [ "$mark" = 1 ]; then
    "$SCRIPT_DIR/fm-procevent.sh" handled "$sid" "$seq" || return 1
  fi
  printf 'applied: %s\n' "$sid"
}

cmd_handle() {
  apply_result "${1-}" "${2-}" "${3-}" 1
}

# The runner's own entry: advance the read position immediately (idempotent),
# then deliberately report failure so the result stays unacknowledged and
# eligible for re-announcement until firstmate calls `handle`, exactly like the
# Slack captain and quota-topic adapters.
cmd_autohandle() {
  apply_result "${1-}" "${2-}" "${3-}" 0 || return 1
  return 1
}

case "${1-}" in
  arm)        shift; [ "$#" -eq 0 ] || usage; cmd_arm ;;
  poll)       shift; [ "$#" -eq 1 ] || usage; cmd_poll "$@" ;;
  list)       shift; [ "$#" -eq 0 ] || usage; cmd_list ;;
  handle)     shift; [ "$#" -eq 3 ] || usage; cmd_handle "$@" ;;
  autohandle) shift; [ "$#" -eq 3 ] || usage; cmd_autohandle "$@" ;;
  classify)   shift; [ "$#" -eq 1 ] || usage; cmd_classify "$@" ;;
  terminal)   shift; [ "$#" -eq 1 ] || usage; cmd_terminal "$@" ;;
  source-id)  shift; [ "$#" -eq 0 ] || usage; cmd_source_id ;;
  retire)     shift; [ "$#" -eq 0 ] || usage; cmd_retire ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
