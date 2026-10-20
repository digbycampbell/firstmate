#!/usr/bin/env bash
# Drives bin/fm-pr-merge.sh (PR_MERGE may point at a base copy) against a disposable
# fake-gh fixture whose check-runs payload exceeds the kernel per-argument limit.
. "$(dirname "$0")/driver-lib.sh"
[ -n "${PR_MERGE_OVERRIDE:-}" ] && PR_MERGE=$PR_MERGE_OVERRIDE
set +e
HEAD_SHA=a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1
setup() { # name runs_jq_expr
  local c; c=$(make_case "$1"); add_gh_mocks "$c" "$HEAD_SHA" >/dev/null
  write_github_required "$c" "classic:ci"
  jq '.protection.required_status_checks.checks[0].app_id = 15368' "$c/github-branch.json" > "$c/u.json"; mv "$c/u.json" "$c/github-branch.json"
  jq -n --arg head "$HEAD_SHA" "$2" > "$c/github-runs.json"
  echo "$c"
}
report() { # label case
  printf '== %s\n   payload bytes: %s\n   exit: %s\n   merged (gh pr merge called): %s\n   stderr:\n' "$1" "$(wc -c < "$2/github-runs.json")" "$RC" "$(grep -q 'pr merge' "$2/gh.log" && echo yes || echo no)"
  sed 's/^/     /' "$2/stderr"
}
# S1: fcdispatch shape - 100 check runs, ~3.5 KB each (~350 KB), all green, required 'ci' from app 15368.
c=$(setup fcdispatch '{check_runs: ([{name:"ci",app:{id:15368,slug:"github-actions",description:("d"*1500)},head_sha:$head,output:{summary:("s"*2000)}}] + [range(1;100)|{name:"job-\(.)",app:{id:15368,slug:"github-actions",description:("d"*1500)},head_sha:$head,output:{summary:("s"*2000)}}])}')
run_required_case "$c" 1813 --attended-override -- --admin; report "S1 fcdispatch-shaped 100 runs ~350KB" "$c"
# S2: duplicate-heavy - 6000 re-runs of the same names (review-1 concern: projected producers still > 128 KiB)
c=$(setup reruns '{check_runs: ([{name:"ci",app:{id:15368},head_sha:$head}] + [range(0;6000)|{name:"matrix-job-with-a-long-descriptive-name-\(. % 50)-\("z"*40)",app:{id:15368},head_sha:$head}])}')
run_required_case "$c" 1814 --attended-override -- --admin; report "S2 6000 duplicate re-runs" "$c"
# S3 adversarial: large payload but required 'ci' only produced by the wrong app (42) -> must refuse
c=$(setup wrongapp '{check_runs: ([{name:"ci",app:{id:42},head_sha:$head}] + [range(0;6000)|{name:"job-\(.)-\("z"*60)",app:{id:15368},head_sha:$head,output:{summary:("s"*300)}}])}')
run_required_case "$c" 1815 --attended-override -- --admin; report "S3 adversarial wrong producer app in large payload" "$c"
