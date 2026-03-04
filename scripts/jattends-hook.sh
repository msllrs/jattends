#!/usr/bin/env bash
# jattends-hook.sh — Claude Code hook that writes session state to disk
# for the Jattends menubar app to monitor.
#
# Usage:
#   As a hook:  echo '{"session_id":...}' | jattends-hook.sh
#   Scan mode:  jattends-hook.sh --scan   (discover untracked claude processes)

set -euo pipefail

SESSIONS_DIR="${HOME}/.claude/jattends/sessions"
mkdir -p "$SESSIONS_DIR"

# --- Shared helpers ---

# Walk up the process tree to find the terminal process PID
find_terminal_pid() {
    local pid="$1"
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

# Detect terminal app name from process tree
find_terminal_app() {
    local pid="$1"
    local max_depth=10
    local depth=0
    while [ "$pid" -ne 1 ] && [ "$depth" -lt "$max_depth" ]; do
        pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
        [ -z "$pid" ] && break
        local pname
        pname=$(ps -o comm= -p "$pid" 2>/dev/null | xargs basename 2>/dev/null || echo "")
        case "$pname" in
            ghostty|Terminal|iTerm2|kitty|warp|Alacritty|WezTerm|Hyper)
                echo "$pname"
                return
                ;;
        esac
        depth=$((depth + 1))
    done
    echo "unknown"
}

write_session_file() {
    local session_id="$1" cwd="$2" status="$3" term_app="$4" term_pid="$5" term_tty="$6"
    local session_file="${SESSIONS_DIR}/${session_id}.json"
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
" "$session_id" "$cwd" "$status" "$term_app" "${term_pid:-}" "${term_tty:-}" "$now" > "${session_file}.tmp" \
    && mv -f "${session_file}.tmp" "$session_file"
}

# --- Scan mode: discover untracked claude processes ---

if [ "${1:-}" = "--scan" ]; then
    # Collect TTYs and cwds already tracked by existing session files
    tracked_ttys=""
    tracked_cwds=""
    for f in "$SESSIONS_DIR"/*.json; do
        [ -f "$f" ] || continue
        info=$(/usr/bin/python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
print(d.get('terminalTty',''), d.get('cwd',''))
" "$f" 2>/dev/null || echo "")
        tty_val=$(echo "$info" | awk '{print $1}')
        cwd_val=$(echo "$info" | cut -d' ' -f2-)
        [ -n "$tty_val" ] && [ "$tty_val" != "None" ] && [ "$tty_val" != "not a tty" ] && tracked_ttys="$tracked_ttys|$tty_val"
        [ -n "$cwd_val" ] && tracked_cwds="$tracked_cwds|$cwd_val"
    done

    # Find running claude processes
    ps -eo pid,tty,comm 2>/dev/null | while read -r cpid ctty ccomm; do
        [ "$ccomm" = "claude" ] || continue
        # Normalize TTY (ps shows "ttys006", we need "/dev/ttys006")
        local_tty=""
        if [ "$ctty" != "??" ] && [ "$ctty" != "-" ]; then
            local_tty="/dev/$ctty"
        fi

        # Skip if this TTY is already tracked by any session file
        if [ -n "$local_tty" ]; then
            case "$tracked_ttys" in
                *"|$local_tty"*) continue ;;
            esac
        fi

        # Get cwd via lsof
        local_cwd=$(lsof -a -d cwd -p "$cpid" -Fn 2>/dev/null | grep "^n/" | head -1 | cut -c2- || echo "")
        [ -z "$local_cwd" ] && continue

        # Skip if this cwd is already tracked by any session file
        case "$tracked_cwds" in
            *"|$local_cwd"*) continue ;;
        esac

        # Find terminal info by walking the process tree
        local_term_pid=$(find_terminal_pid "$cpid")
        local_term_app=$(find_terminal_app "$cpid")

        # Generate a deterministic session ID from PID (prefixed to avoid collision with real IDs)
        local_session_id="discovered-${cpid}"

        # Only create if no file exists yet for this discovered session
        if [ ! -f "${SESSIONS_DIR}/${local_session_id}.json" ]; then
            write_session_file "$local_session_id" "$local_cwd" "idle" "$local_term_app" "${local_term_pid:-}" "${local_tty:-}"
        fi
    done

    exit 0
fi

# --- Normal hook mode: read event from stdin ---

INPUT=$(cat)

SESSION_ID=$(echo "$INPUT" | /usr/bin/python3 -c "import sys,json; print(json.load(sys.stdin)['session_id'])")
EVENT=$(echo "$INPUT" | /usr/bin/python3 -c "import sys,json; print(json.load(sys.stdin)['hook_event_name'])")
CWD=$(echo "$INPUT" | /usr/bin/python3 -c "import sys,json; print(json.load(sys.stdin)['cwd'])")

SESSION_FILE="${SESSIONS_DIR}/${SESSION_ID}.json"

TERM_APP="${TERM_PROGRAM:-unknown}"
TERMINAL_PID=$(find_terminal_pid $$)
TERMINAL_TTY=$(tty 2>/dev/null || echo "")

write_session() {
    write_session_file "$SESSION_ID" "$CWD" "$1" "$TERM_APP" "${TERMINAL_PID:-}" "${TERMINAL_TTY:-}"
}

case "$EVENT" in
    SessionStart)
        write_session "active"
        ;;
    UserPromptSubmit)
        write_session "active"
        ;;
    PermissionRequest)
        write_session "waiting"
        ;;
    Notification)
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
        # Claude finished its turn — idle unless asking a question
        ENDS_WITH_QUESTION=$(echo "$INPUT" | /usr/bin/python3 -c "
import sys, json
msg = json.load(sys.stdin).get('last_assistant_message', '')
print('yes' if msg.rstrip().endswith('?') else 'no')
")
        if [ "$ENDS_WITH_QUESTION" = "yes" ]; then
            write_session "waiting"
        else
            write_session "idle"
        fi
        ;;
    SessionEnd)
        rm -f "$SESSION_FILE"
        ;;
    *)
        ;;
esac
