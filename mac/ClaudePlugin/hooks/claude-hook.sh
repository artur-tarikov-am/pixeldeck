#!/bin/sh
# Claude Code hook: forwards the event to the hub without the prompt or tool output.
jq -c '{
  event: .hook_event_name,
  session: .session_id,
  cwd: .cwd,
  notification: .notification_type,
  tool: .tool_name,
  question: .tool_input.questions[0].question?,
  orca: (env.ORCA_AGENT_SESSION_ID // env.ORCA_PANE_KEY)
}' | curl -s -m 1 -X POST --data-binary @- http://127.0.0.1:7777/claude-events >/dev/null 2>&1
exit 0
