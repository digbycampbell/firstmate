#!/usr/bin/env bash
# Turn-end adapter for Grok Stop payloads.
#
# Usage (the adapter contract every file in this directory implements):
#   grok.sh claims     payload on stdin; exit 0 when this adapter owns it
#   grok.sh extract    payload on stdin; one JSON turn record on stdout
#   grok.sh describe   one coverage line for `slack-mirror.sh adapters`
#
# adapters/claude.sh documents the turn record's fields; this file documents only
# what is Grok-specific.
#
# PAYLOAD, verified against grok 1.0.5 (5115b46bc9) by dumping a real Stop hook's
# own stdin. It is camel-case and NOT Claude-shaped:
#   hookEventName "stop", sessionId, cwd, workspaceRoot, timestamp,
#   transcriptPath, promptId, permissionMode, reason, stopHookActive,
#   lastAssistantMessage, backgroundTasks, sessionCrons
# `reason` is `end_turn` for a finished turn and `shutdown` for the extra Stop
# that fires as the session exits; the shutdown payload carries neither
# `lastAssistantMessage` nor `promptId`, so only `end_turn` is mirrored and the
# session teardown never re-posts the last reply.
#
# TRANSCRIPT. `transcriptPath` names the session's `updates.jsonl`, a log of
# JSON-RPC session updates, not a Claude-shaped message transcript. The final
# reply is `lastAssistantMessage`; when it is absent the same text is rebuilt
# from the `agent_message_chunk` updates whose `_meta.promptId` matches this
# payload's `promptId`, so a turn that produced no reply of its own contributes
# nothing rather than re-posting an older one. The trigger is the newest
# `user_message_chunk` group, keyed by its `_meta.promptIndex`, which is where a
# watcher wake naming a captured Slack result lands on this harness.
set -u

SCAN_LINES=${SLACK_MIRROR_SCAN_LINES:-${FM_SLACK_MIRROR_SCAN_LINES:-800}}

cmd_claims() {
  local payload
  command -v jq >/dev/null 2>&1 || return 1
  payload=$(cat 2>/dev/null) || return 1
  [ -n "$payload" ] || return 1
  printf '%s' "$payload" | jq -e '
      (type == "object")
      and ((.hookEventName | type) == "string")
      and ((.hookEventName | ascii_downcase) == "stop")
    ' >/dev/null 2>&1
}

cmd_extract() {
  local payload transcript prompt_id reason body trigger turn_ms turn_epoch model tail_file tmpdir

  command -v jq >/dev/null 2>&1 || return 0
  payload=$(cat 2>/dev/null) || return 0
  [ -n "$payload" ] || return 0

  reason=$(printf '%s' "$payload" | jq -r '
      if (.reason | type) == "string" then .reason else "" end' 2>/dev/null) || return 0
  case "$reason" in
    ''|end_turn) ;;
    *) return 0 ;;
  esac

  prompt_id=$(printf '%s' "$payload" | jq -r '
      if (.promptId | type) == "string" then .promptId else "" end' 2>/dev/null) || prompt_id=
  body=$(printf '%s' "$payload" | jq -r '
      if (.lastAssistantMessage | type) == "string" then .lastAssistantMessage else "" end
    ' 2>/dev/null) || body=
  transcript=$(printf '%s' "$payload" | jq -r '
      if (.transcriptPath | type) == "string" then .transcriptPath else "" end' 2>/dev/null) || transcript=

  trigger=; turn_ms=; model=
  if [ -n "$transcript" ] && [ -f "$transcript" ] && [ ! -L "$transcript" ]; then
    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/slack-mirror-grok.XXXXXX" 2>/dev/null) || return 0
    tail_file="$tmpdir/tail.jsonl"
    if tail -n "$SCAN_LINES" "$transcript" > "$tail_file" 2>/dev/null; then
      # The turn's opening message: every chunk of the newest prompt, in order.
      trigger=$(jq -r --slurp '
          [ .[] | select((.params.update.sessionUpdate? // "") == "user_message_chunk") ]
          | (if length == 0 then empty
             else (map(.params.update._meta.promptIndex // -1) | max) as $newest
                  | map(select((.params.update._meta.promptIndex // -1) == $newest))
                  | map(.params.update.content.text // "") | join("")
             end)
        ' "$tail_file" 2>/dev/null) || trigger=
      turn_ms=$(jq -r --slurp --arg id "$prompt_id" '
          [ .[] | select((.params.update.sessionUpdate? // "") == "agent_message_chunk")
                | select($id == "" or (.params._meta.promptId // "") == $id)
                | (.params._meta.turnStartMs // empty) ]
          | (if length == 0 then "" else (max | floor | tostring) end)
        ' "$tail_file" 2>/dev/null) || turn_ms=
      model=$(jq -r --slurp --arg id "$prompt_id" '
          [ .[] | select((.params.update.sessionUpdate? // "") == "turn_completed")
                | select($id == "" or (.params.update.prompt_id // "") == $id)
                | (.params.update.usage.modelUsage // {} | keys_unsorted[0] // empty) ]
          | (.[-1] // "")
        ' "$tail_file" 2>/dev/null) || model=
      if [ -z "$body" ] && [ -n "$prompt_id" ]; then
        body=$(jq -r --slurp --arg id "$prompt_id" '
            [ .[] | select((.params.update.sessionUpdate? // "") == "agent_message_chunk")
                  | select((.params._meta.promptId // "") == $id)
                  | (.params.update.content.text // "") ]
            | join("")
          ' "$tail_file" 2>/dev/null) || body=
      fi
    fi
    rm -rf -- "$tmpdir"
  fi

  turn_epoch=
  case "$turn_ms" in
    ''|*[!0-9]*) ;;
    *) turn_epoch=$(( turn_ms / 1000 )) ;;
  esac

  # Grok reports no reasoning effort at the turn boundary, so the optional
  # worker-details stamp carries the model alone.
  jq -n --arg harness grok --arg final "$body" --arg trigger "$trigger" \
    --arg epoch "$turn_epoch" --arg model "$model" \
    '{harness: $harness, final_text: $final, trigger_text: $trigger,
      turn_epoch: $epoch, model: $model, effort: ""}'
}

# `claims` is a predicate, so its status must survive to the caller; every other
# path stays silent and successful.
case "${1-}" in
  claims)   cmd_claims; exit $? ;;
  extract)  cmd_extract ;;
  describe) printf 'grok: covered - Stop payload carries lastAssistantMessage and an updates.jsonl transcript naming the turn trigger (verified against grok 1.0.5)\n' ;;
  *) printf 'usage: %s claims|extract|describe\n' "${0##*/}" >&2; exit 2 ;;
esac
exit 0
