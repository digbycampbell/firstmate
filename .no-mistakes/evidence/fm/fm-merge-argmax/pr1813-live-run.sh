#!/usr/bin/env bash
# usage: run.sh <W> <root> <label> <url> [extra args]
W=$1 ROOT=$2 LABEL=$3 URL=$4; shift 4
LAB=$(mktemp -d /tmp/fm-lab.XXXXXX); bash "$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null 2>&1 || bash bin/fm-lab-home.sh create "$LAB" >/dev/null
git init -q "$LAB/wt"
git -C "$LAB/wt" -c user.name=t -c user.email=t@x.invalid commit -q --allow-empty -m init
git -C "$LAB/wt" update-ref refs/remotes/origin/main HEAD
printf '%s\n' "window=fm-task-x1" "worktree=$LAB/wt" "project=$LAB/projects/p" "kind=ship" "mode=no-mistakes" > "$LAB/state/task-x1.meta"
: > "$W/gh.log"
( cd "$ROOT" && env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
   PATH="$W/bin:$PATH" FM_HOME="$LAB" bash bin/fm-pr-merge.sh task-x1 "$URL" --attended-override "$@" ) > "$W/$LABEL.out" 2>&1
echo "exit=$?" >> "$W/$LABEL.out"
cp "$W/gh.log" "$W/$LABEL.gh.log"
rm -rf -- "$LAB"
