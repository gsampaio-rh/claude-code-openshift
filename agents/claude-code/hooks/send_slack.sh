#!/bin/bash
# Hook script — sends Slack notifications on Stop and PostToolUseFailure events.
# Reads event JSON from stdin, extracts relevant info, posts to SLACK_NOTIFY_CHANNEL.
# Skips silently if SLACK_BOT_TOKEN or SLACK_NOTIFY_CHANNEL are not set.

[[ -z "${SLACK_BOT_TOKEN:-}" || -z "${SLACK_NOTIFY_CHANNEL:-}" ]] && exit 0

EVENT_JSON=$(cat)
EVENT_TYPE=$(echo "$EVENT_JSON" | python3.12 -c "import sys,json; print(json.load(sys.stdin).get('event',''))" 2>/dev/null || echo "")

case "$EVENT_TYPE" in
  Stop)
    MSG=":white_check_mark: Agent session finished."
    ;;
  PostToolUseFailure)
    TOOL=$(echo "$EVENT_JSON" | python3.12 -c "import sys,json; print(json.load(sys.stdin).get('tool_name','unknown'))" 2>/dev/null || echo "unknown")
    MSG=":warning: Tool \`${TOOL}\` failed."
    ;;
  *)
    exit 0
    ;;
esac

curl -s -X POST https://slack.com/api/chat.postMessage \
  -H "Authorization: Bearer ${SLACK_BOT_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"channel\":\"${SLACK_NOTIFY_CHANNEL}\",\"text\":\"${MSG}\"}" \
  > /dev/null 2>&1 || true
