#!/usr/bin/env bash
# jattends-hook.sh — Claude Code hook that writes session state to disk
# for the Jattends menubar app to monitor.
#
# Reads hook JSON from stdin. Writes/removes files in ~/.claude/jattends/sessions/

set -euo pipefail

SESSIONS_DIR="${HOME}/.claude/jattends/sessions"
mkdir -p "$SESSIONS_DIR"

# Read the full JSON payload from stdin
INPUT=$(cat)

SESSION_ID=$(echo "$INPUT" | /usr/bin/python3 -c "import sys,json; print(json.load(sys.stdin)['session_id'])")
EVENT=$(echo "$INPUT" | /usr/bin/python3 -c "import sys,json; print(json.load(sys.stdin)['hook_event_name'])")
CWD=$(echo "$INPUT" | /usr/bin/python3 -c "import sys,json; print(json.load(sys.stdin)['cwd'])")

SESSION_FILE="${SESSIONS_DIR}/${SESSION_ID}.json"

# Detect terminal application from environment
TERM_APP="${TERM_PROGRAM:-unknown}"

# Get the terminal's PID — walk up from our shell to find the terminal process
get_terminal_pid() {
    local pid=$$
    local max_depth=10
    local depth=0
    while [ "$pid" -ne 1 ] && [ "$depth" -lt "$max_depth" ]; do
        pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
        [ -z "$pid" ] && break
        local pname
        pname=$(ps -o comm= -p "$pid" 2>/dev/null | xargs basename 2>/dev/null || echo "")
        case "$pname" in
            ghostty|Terminal|iTerm2|kitty|warp|Alacritty|WezTerm|Hyper)
                echo "$pid"
                return
                ;;
        esac
        depth=$((depth + 1))
    done
    echo ""
}

TERMINAL_PID=$(get_terminal_pid)

# Get the TTY of the current shell for session deduplication and terminal activation
TERMINAL_TTY=$(tty 2>/dev/null || echo "")

write_session() {
    local status="$1"
    local now
    now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    /usr/bin/python3 -c "
import json, sys
data = {
    'sessionId': sys.argv[1],
    'cwd': sys.argv[2],
    'status': sys.argv[3],
    'terminalApp': sys.argv[4],
    'terminalPid': int(sys.argv[5]) if sys.argv[5] else None,
    'terminalTty': sys.argv[6] if sys.argv[6] else None,
    'updatedAt': sys.argv[7]
}
print(json.dumps(data))
" "$SESSION_ID" "$CWD" "$status" "$TERM_APP" "${TERMINAL_PID:-}" "${TERMINAL_TTY:-}" "$now" > "${SESSION_FILE}.tmp" \
    && mv -f "${SESSION_FILE}.tmp" "$SESSION_FILE"
}

case "$EVENT" in
    SessionStart)
        write_session "active"
        ;;
    UserPromptSubmit)
        # User responded — Claude is working again, no longer needs attention
        write_session "active"
        ;;
    PermissionRequest)
        # Tool permission — always needs attention
        write_session "waiting"
        ;;
    Notification)
        # Only mark as waiting if the message ends with '?' (asking a question)
        ENDS_WITH_QUESTION=$(echo "$INPUT" | /usr/bin/python3 -c "
import sys, json
msg = json.load(sys.stdin).get('last_assistant_message', '')
print('yes' if msg.rstrip().endswith('?') else 'no')
")
        if [ "$ENDS_WITH_QUESTION" = "yes" ]; then
            write_session "waiting"
        else
            write_session "active"
        fi
        ;;
    Stop)
        # Only notify if Claude's last message ends with '?' (asking a question)
        ENDS_WITH_QUESTION=$(echo "$INPUT" | /usr/bin/python3 -c "
import sys, json
msg = json.load(sys.stdin).get('last_assistant_message', '')
print('yes' if msg.rstrip().endswith('?') else 'no')
")
        if [ "$ENDS_WITH_QUESTION" = "yes" ]; then
            write_session "waiting"
        else
            write_session "active"
        fi
        ;;
    SessionEnd)
        # Clean up the session file
        rm -f "$SESSION_FILE"
        ;;
    *)
        # Unknown event — ignore
        ;;
esac
