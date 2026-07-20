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

# Walk the process tree to find claude PID, terminal PID, and terminal app name.
# Uses a single `ps` call to get the full process table, then walks in-memory.
# Output: three lines — claude_pid, terminal_pid, terminal_app
find_process_info() {
    local start_pid="$1"
    /usr/bin/python3 -c "
import subprocess, os, sys

start = int(sys.argv[1])
terminals = {'ghostty','Terminal','iTerm2','kitty','warp','Alacritty','WezTerm','Hyper'}

# Single ps call to get all processes
procs = {}
for line in subprocess.check_output(['ps', '-eo', 'pid,ppid,comm'], text=True).splitlines()[1:]:
    parts = line.split(None, 2)
    if len(parts) >= 3:
        procs[int(parts[0])] = (int(parts[1]), os.path.basename(parts[2]))

claude_pid = ''
terminal_pid = ''
terminal_app = 'unknown'

pid = start
for _ in range(15):
    if pid <= 1 or pid not in procs:
        break
    ppid, name = procs[pid]
    if name == 'claude' and not claude_pid:
        claude_pid = str(pid)
    if name in terminals:
        terminal_pid = str(pid)
        terminal_app = name
        break
    pid = ppid

print(claude_pid)
print(terminal_pid)
print(terminal_app)
" "$start_pid"
}

# Legacy wrappers for scan mode (which walks from a claude PID, not $$)
find_terminal_pid() {
    local info
    info=$(find_process_info "$1")
    echo "$info" | sed -n '2p'
}

find_terminal_app() {
    local info
    info=$(find_process_info "$1")
    echo "$info" | sed -n '3p'
}

write_session_file() {
    local session_id="$1" cwd="$2" status="$3" term_app="$4" term_pid="$5" term_tty="$6" claude_pid="$7"
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
    'claudePid': int(sys.argv[7]) if sys.argv[7] else None,
    'updatedAt': sys.argv[8]
}
print(json.dumps(data))
" "$session_id" "$cwd" "$status" "$term_app" "${term_pid:-}" "${term_tty:-}" "${claude_pid:-}" "$now" > "${session_file}.tmp" \
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
            write_session_file "$local_session_id" "$local_cwd" "idle" "$local_term_app" "${local_term_pid:-}" "${local_tty:-}" "$cpid"
        fi
    done

    exit 0
fi

# --- Normal hook mode: read event from stdin, resolve status, write in one shot ---

# Get claude PID, terminal PID, and terminal app in one process tree walk
PROC_INFO=$(find_process_info $$)
CLAUDE_PID=$(echo "$PROC_INFO" | sed -n '1p')
TERMINAL_PID=$(echo "$PROC_INFO" | sed -n '2p')
TERM_APP_DETECTED=$(echo "$PROC_INFO" | sed -n '3p')
TERM_APP="${TERM_APP_DETECTED:-${TERM_PROGRAM:-unknown}}"
TERMINAL_TTY=$(tty 2>/dev/null || echo "")

# Single python3 call: parse input, determine status, write session file (or delete)
/usr/bin/python3 -c "
import json, sys, os, datetime

d = json.load(sys.stdin)
event = d['hook_event_name']
session_id = d['session_id']
cwd = d['cwd']
sessions_dir = sys.argv[1]
session_file = os.path.join(sessions_dir, session_id + '.json')

if event == 'SessionEnd':
    try: os.remove(session_file)
    except FileNotFoundError: pass
    sys.exit(0)

# Determine status
status_map = {
    'SessionStart': 'active',
    'UserPromptSubmit': 'active',
    'PermissionRequest': 'waiting',
}

if event in status_map:
    status = status_map[event]
elif event in ('Notification', 'Stop'):
    msg = d.get('last_assistant_message', '')
    asks_question = msg.rstrip().endswith('?')
    if asks_question:
        status = 'waiting'
    elif event == 'Stop':
        status = 'idle'
    else:
        status = 'active'
else:
    sys.exit(0)

data = {
    'sessionId': session_id,
    'cwd': cwd,
    'status': status,
    'terminalApp': sys.argv[2],
    'terminalPid': int(sys.argv[3]) if sys.argv[3] else None,
    'terminalTty': sys.argv[4] if sys.argv[4] else None,
    'claudePid': int(sys.argv[5]) if sys.argv[5] else None,
    'updatedAt': datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
}

tmp = session_file + '.tmp'
with open(tmp, 'w') as f:
    json.dump(data, f)
os.replace(tmp, session_file)
" "$SESSIONS_DIR" "$TERM_APP" "${TERMINAL_PID:-}" "${TERMINAL_TTY:-}" "${CLAUDE_PID:-}"
