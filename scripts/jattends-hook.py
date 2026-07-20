#!/usr/bin/env python3
"""jattends-hook.py — Claude Code hook that writes session state to disk
for the Jattends menubar app to monitor.

Usage:
  As a hook:  echo '{"session_id":...}' | jattends-hook.py
  Scan mode:  jattends-hook.py --scan   (discover untracked claude processes)

Session files: ~/.claude/jattends/sessions/<sessionId>.json
Approval requests: ~/.claude/jattends/approvals/<requestId>.json
"""

import json
import os
import subprocess
import sys
import time
from datetime import datetime, timezone

BASE_DIR = os.path.expanduser("~/.claude/jattends")
SESSIONS_DIR = os.path.join(BASE_DIR, "sessions")
APPROVALS_DIR = os.path.join(BASE_DIR, "approvals")
CONFIG_PATH = os.path.join(BASE_DIR, "config.json")

TERMINALS = {"ghostty", "Terminal", "iTerm2", "kitty", "warp", "stable",
             "Alacritty", "WezTerm", "wezterm-gui", "Hyper", "Code", "Electron"}

# Friendly activity verbs for PostToolUse detail (VibeIsland-style).
TOOL_VERBS = {
    "Read": "Reading", "Glob": "Searching", "Grep": "Searching",
    "Edit": "Editing", "Write": "Writing", "NotebookEdit": "Editing",
    "Bash": "Running", "BashOutput": "Running", "KillShell": "Running",
    "WebFetch": "Fetching", "WebSearch": "Searching",
    "Task": "Delegating", "Agent": "Delegating", "TodoWrite": "Planning",
    "Skill": "Running skill",
}


def utcnow():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def load_config():
    try:
        with open(CONFIG_PATH) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def atomic_write(path, data):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f)
    os.replace(tmp, path)


def process_table():
    """One ps call -> {pid: (ppid, tty, comm_basename)}."""
    procs = {}
    out = subprocess.check_output(["ps", "-eo", "pid,ppid,tty,comm"], text=True)
    for line in out.splitlines()[1:]:
        parts = line.split(None, 3)
        if len(parts) >= 4:
            try:
                procs[int(parts[0])] = (int(parts[1]), parts[2], os.path.basename(parts[3]))
            except ValueError:
                continue
    return procs


def find_process_info(start_pid, procs):
    """Walk up the tree from start_pid: returns (claude_pid, tty, terminal_pid, terminal_app)."""
    claude_pid = None
    tty = None
    terminal_pid = None
    terminal_app = None
    pid = start_pid
    for _ in range(15):
        if pid is None or pid <= 1 or pid not in procs:
            break
        ppid, ptty, name = procs[pid]
        if name == "claude" and claude_pid is None:
            claude_pid = pid
            if ptty not in ("??", "-", ""):
                tty = "/dev/" + ptty
        if name in TERMINALS:
            terminal_pid = pid
            terminal_app = name
            break
        pid = ppid
    return claude_pid, tty, terminal_pid, terminal_app


def app_running(procs):
    # Test/debug override: JATTENDS_APP_RUNNING=0|1
    override = os.environ.get("JATTENDS_APP_RUNNING")
    if override in ("0", "1"):
        return override == "1"
    return any(name == "Jattends" for _, _, name in procs.values())


def tool_summary(tool_name, tool_input):
    """Short human-readable summary of a tool call, e.g. 'Running: npm test'."""
    verb = TOOL_VERBS.get(tool_name, tool_name)
    target = ""
    if isinstance(tool_input, dict):
        if "command" in tool_input:
            target = str(tool_input["command"]).split("\n")[0]
        elif "file_path" in tool_input:
            target = os.path.basename(str(tool_input["file_path"]))
        elif "pattern" in tool_input:
            target = str(tool_input["pattern"])
        elif "url" in tool_input:
            target = str(tool_input["url"])
        elif "query" in tool_input:
            target = str(tool_input["query"])
        elif "description" in tool_input:
            target = str(tool_input["description"])
    text = f"{verb}: {target}" if target else verb
    return text[:120]


def truncate_prompt(prompt):
    first_line = str(prompt).strip().split("\n")[0]
    return first_line[:120] if first_line else None


# --- Scan mode: discover untracked claude processes ---

def scan():
    tracked_ttys = set()
    tracked_cwds = set()
    for name in os.listdir(SESSIONS_DIR):
        if not name.endswith(".json"):
            continue
        try:
            with open(os.path.join(SESSIONS_DIR, name)) as f:
                d = json.load(f)
        except (OSError, ValueError):
            continue
        if d.get("terminalTty"):
            tracked_ttys.add(d["terminalTty"])
        if d.get("cwd"):
            tracked_cwds.add(d["cwd"])

    procs = process_table()
    for pid, (_, ptty, name) in procs.items():
        if name != "claude":
            continue
        tty = "/dev/" + ptty if ptty not in ("??", "-", "") else None
        if tty and tty in tracked_ttys:
            continue
        try:
            out = subprocess.check_output(
                ["lsof", "-a", "-d", "cwd", "-p", str(pid), "-Fn"],
                text=True, stderr=subprocess.DEVNULL)
            cwd = next((l[1:] for l in out.splitlines() if l.startswith("n/")), None)
        except subprocess.CalledProcessError:
            cwd = None
        if not cwd or cwd in tracked_cwds:
            continue
        _, _, term_pid, term_app = find_process_info(pid, procs)
        session_id = f"discovered-{pid}"
        path = os.path.join(SESSIONS_DIR, session_id + ".json")
        if not os.path.exists(path):
            atomic_write(path, {
                "sessionId": session_id, "cwd": cwd, "status": "idle",
                "terminalApp": term_app or "unknown", "terminalPid": term_pid,
                "terminalTty": tty, "claudePid": pid, "updatedAt": utcnow(),
            })


# --- Approval flow (PermissionRequest) ---

def handle_permission_request(d, session, procs):
    """Write an approval request and poll for the app's decision.

    Returns a hook JSON output dict, or None to fall through to the
    normal terminal permission dialog.
    """
    config = load_config()
    if not config.get("inAppApprovals", True) or not app_running(procs):
        return None
    wait_seconds = float(config.get("approvalWaitSeconds", 45))
    if wait_seconds <= 0:
        return None

    os.makedirs(APPROVALS_DIR, exist_ok=True)
    request_id = f"{d['session_id']}-{d.get('prompt_id', '')}-{int(time.time() * 1000)}"
    request_path = os.path.join(APPROVALS_DIR, request_id + ".json")
    decision_path = os.path.join(APPROVALS_DIR, request_id + ".decision.json")
    atomic_write(request_path, {
        "requestId": request_id,
        "sessionId": d["session_id"],
        "cwd": d.get("cwd", ""),
        "toolName": d.get("tool_name", ""),
        "summary": tool_summary(d.get("tool_name", ""), d.get("tool_input")),
        "createdAt": utcnow(),
    })

    decision = None
    deadline = time.time() + wait_seconds
    try:
        while time.time() < deadline:
            if os.path.exists(decision_path):
                try:
                    with open(decision_path) as f:
                        decision = json.load(f)
                except (OSError, ValueError):
                    pass
                break
            time.sleep(0.25)
    finally:
        for p in (request_path, decision_path):
            try:
                os.remove(p)
            except FileNotFoundError:
                pass

    behavior = (decision or {}).get("behavior")
    if behavior not in ("allow", "deny"):
        return None  # timed out or user chose to answer in terminal
    out = {"behavior": behavior}
    if behavior == "deny":
        out["reason"] = decision.get("reason", "Denied from Jattends")
    return {"hookSpecificOutput": {"hookEventName": "PermissionRequest",
                                   "decision": out}}


# --- Normal hook mode ---

def handle_event():
    d = json.load(sys.stdin)
    event = d.get("hook_event_name", "")
    session_id = d.get("session_id", "")
    if not session_id:
        return
    session_file = os.path.join(SESSIONS_DIR, session_id + ".json")

    if event == "SessionEnd":
        try:
            os.remove(session_file)
        except FileNotFoundError:
            pass
        return

    # Load existing session record so per-event updates preserve context.
    session = {}
    try:
        with open(session_file) as f:
            session = json.load(f)
    except (OSError, ValueError):
        pass

    # Reuse process info from the existing record when possible — the tree
    # walk costs a full ps scan and the answer never changes mid-session.
    procs = None
    if not session.get("claudePid") or not session.get("terminalTty"):
        procs = process_table()
        claude_pid, tty, term_pid, term_app = find_process_info(os.getpid(), procs)
        session["claudePid"] = claude_pid or session.get("claudePid")
        session["terminalTty"] = tty or session.get("terminalTty")
        session["terminalPid"] = term_pid or session.get("terminalPid")
        session["terminalApp"] = (term_app or session.get("terminalApp")
                                  or os.environ.get("TERM_PROGRAM") or "unknown")

    status = None
    detail = session.get("statusDetail")
    hook_output = None

    if event == "SessionStart":
        # source=compact means an auto-compact restart mid-turn: still working
        status = "working" if d.get("source") == "compact" else "idle"
        detail = None
    elif event == "UserPromptSubmit":
        status = "working"
        detail = None
        prompt = truncate_prompt(d.get("prompt", ""))
        if prompt:
            session["lastPrompt"] = prompt
    elif event == "PostToolUse":
        status = "working"
        detail = tool_summary(d.get("tool_name", ""), d.get("tool_input"))
    elif event == "PermissionRequest":
        status = "approval"
        detail = tool_summary(d.get("tool_name", ""), d.get("tool_input"))
        if procs is None:
            procs = process_table()
    elif event == "Notification":
        ntype = d.get("notification_type") or d.get("matcher") or ""
        msg = d.get("message", "") or ""
        if ntype == "permission_prompt" or "permission" in msg.lower():
            status = "approval"
            detail = msg[:120] or detail
        elif ntype in ("idle_prompt", "agent_needs_input", "elicitation_dialog") \
                or "waiting for your input" in msg.lower():
            status = "waiting"
            detail = msg[:120] or detail
        else:
            return  # auth_success etc. — nothing to record
    elif event == "Stop":
        msg = (d.get("last_assistant_message") or "").rstrip()
        if msg.endswith("?"):
            status = "waiting"
            detail = msg.split("\n")[-1].strip()[:120]
        else:
            status = "idle"
            detail = None
    elif event == "StopFailure":
        status = "error"
        detail = (d.get("matcher") or d.get("error_type")
                  or d.get("message") or "API error")[:120]
    elif event == "PreCompact":
        status = "compacting"
        detail = None
    elif event == "PostCompact":
        status = "working"
        detail = None
    else:
        return

    session.update({
        "sessionId": session_id,
        "cwd": d.get("cwd", session.get("cwd", "")),
        "status": status,
        "statusDetail": detail,
        "permissionMode": d.get("permission_mode", session.get("permissionMode")),
        "transcriptPath": d.get("transcript_path", session.get("transcriptPath")),
        "updatedAt": utcnow(),
    })
    atomic_write(session_file, session)

    # PermissionRequest optionally blocks awaiting an in-app decision.
    if event == "PermissionRequest":
        hook_output = handle_permission_request(d, session, procs)
        if hook_output:
            # Reflect that the approval was handled so the badge clears fast.
            session["status"] = "working"
            session["statusDetail"] = None
            session["updatedAt"] = utcnow()
            atomic_write(session_file, session)
            print(json.dumps(hook_output))


def main():
    os.makedirs(SESSIONS_DIR, exist_ok=True)
    if len(sys.argv) > 1 and sys.argv[1] == "--scan":
        scan()
    else:
        handle_event()


if __name__ == "__main__":
    try:
        main()
    except Exception:
        # Never break Claude Code on a monitoring failure.
        sys.exit(0)
