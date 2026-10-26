#!/usr/bin/env python3
"""jattends-hook.py — Claude Code hook that writes session state to disk
for the Jattends menubar app to monitor.

Usage:
  As a hook:   echo '{"session_id":...}' | jattends-hook.py
  Scan mode:   jattends-hook.py --scan   (discover untracked claude processes)
  Statusline:  echo "$input" | jattends-hook.py --statusline
               (bridge from a statusLine command: captures session_name)

Session files: ~/.claude/jattends/sessions/<sessionId>.json
Approval requests: ~/.claude/jattends/approvals/<requestId>.json
Session labels: ~/.claude/jattends/labels/<sessionId>  (plain text)
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
DISMISSED_DIR = os.path.join(BASE_DIR, "dismissed")
SUBAGENTS_DIR = os.path.join(BASE_DIR, "subagents")
LABELS_DIR = os.path.join(BASE_DIR, "labels")
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


def is_claude_proc(name):
    """Terminal sessions run as `claude`; the agents feature runs sessions
    under `claude.exe` daemons and `claude bg-pty-host`/`bg-spare` ptys."""
    return name in ("claude", "claude.exe") or name.startswith("claude ")


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
        if is_claude_proc(name) and claude_pid is None:
            claude_pid = pid
            if ptty not in ("??", "-", ""):
                tty = "/dev/" + ptty
        if name in TERMINALS:
            terminal_pid = pid
            terminal_app = name
            break
        pid = ppid
    return claude_pid, tty, terminal_pid, terminal_app


def stamp_rex(session):
    """Record the Rex block/session hosting this claude. Rex is a multiplexer:
    claude's parent is the rex server daemon, not a GUI app, so the exported
    IDs are the only way to focus the exact pane later."""
    for env, key in (("REX_BLOCK", "rexBlock"), ("REX_SESSION", "rexSession"),
                     ("REX_BIN_DIR", "rexBinDir")):
        value = os.environ.get(env)
        if value:
            session[key] = value


def tty_for_pid(pid):
    """The pty a process is attached to, via its open stdio fds — agent
    sessions run on daemon-created ptys that ps won't report as a
    controlling tty, but escape sequences written to them still reach the
    window displaying the session."""
    try:
        out = subprocess.check_output(
            ["lsof", "-a", "-d", "0,1,2", "-p", str(pid), "-Fn"],
            text=True, stderr=subprocess.DEVNULL)
    except (subprocess.CalledProcessError, OSError):
        return None
    for line in out.splitlines():
        if line.startswith("n/dev/ttys"):
            return line[1:]
    return None


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


# --- Session labels ---
# One plain-text file per session (labels/<session_id>) holding its display
# name: the auto-generated topic title or /rename name from Claude Code.
# Written by the statusline bridge (--statusline) on every refresh and by
# SessionStart's session_title; the app prefers it over the cwd basename.
# A sidecar file (not a field in the session JSON) so the statusline never
# races the hook's read-modify-write of the session file.

def safe_filename(name):
    return "".join(c if c.isalnum() or c in "-_." else "_" for c in str(name))


def label_path(session_id):
    return os.path.join(LABELS_DIR, safe_filename(session_id))


def read_label(session_id):
    try:
        with open(label_path(session_id)) as f:
            return f.read().strip() or None
    except OSError:
        return None


def write_label(session_id, name):
    name = " ".join(str(name).split())[:120]
    if not name or name == read_label(session_id):
        return
    os.makedirs(LABELS_DIR, exist_ok=True)
    path = label_path(session_id)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        f.write(name)
    os.replace(tmp, path)


def remove_label(session_id):
    try:
        os.remove(label_path(session_id))
    except FileNotFoundError:
        pass


def prune_labels():
    """Drop labels whose session file is gone — but only after an hour,
    since the statusline can label a session the hooks aren't tracking
    (yet), and the label must survive until its session file appears."""
    if not os.path.isdir(LABELS_DIR):
        return
    now = time.time()
    for name in os.listdir(LABELS_DIR):
        if os.path.exists(os.path.join(SESSIONS_DIR, name + ".json")):
            continue
        path = os.path.join(LABELS_DIR, name)
        try:
            if now - os.path.getmtime(path) > 3600:
                os.remove(path)
        except OSError:
            continue


def first_prompt_from_transcript(path):
    """First real user message from a transcript, for a row's detail line.
    Bounded read: agent sessions can have huge transcripts."""
    if not path:
        return None
    try:
        with open(path) as f:
            for _ in range(50):
                line = f.readline(500_000)
                if not line:
                    break
                try:
                    entry = json.loads(line)
                except ValueError:
                    continue
                if entry.get("type") != "user" or entry.get("isMeta"):
                    continue
                content = (entry.get("message") or {}).get("content")
                if isinstance(content, list):
                    content = next(
                        (b.get("text") for b in content
                         if isinstance(b, dict) and b.get("type") == "text"),
                        None)
                if isinstance(content, str) and content.strip() \
                        and not content.lstrip().startswith("<"):
                    return truncate_prompt(content)
    except OSError:
        pass
    return None


# --- Claude Code session records ---
# Claude Code (v2.1.218+) keeps its own per-process session records at
# ~/.claude/sessions/<pid>.json — a different directory from our
# SESSIONS_DIR above. Each looks like {"pid": ..., "sessionId": ...,
# "kind": "bg"|"interactive", "name": ..., "status": "busy"|"idle"}.
# They're the only source for a session's kind, for real busy/idle state
# on the statusline path (bridge sessions have no hook events), and for
# background task titles. Strictly optional enrichment: the directory
# doesn't exist on older Claude Code versions, so every failure is None
# and must never break the hook.

CLAUDE_SESSIONS_DIR = os.path.expanduser("~/.claude/sessions")


def claude_session_record(session_id, claude_pid=None):
    """Claude Code's own record for this session, or None.

    Pid-first: records are named after the claude process pid, so a known
    claudePid is a direct hit. Falls back to scanning the directory — the
    pid can be unknown (statusline path) or stale (respawned session)."""
    def load(path):
        try:
            with open(path) as f:
                rec = json.load(f)
        except (OSError, ValueError):
            return None
        if isinstance(rec, dict) and rec.get("sessionId") == session_id:
            return rec
        return None

    if claude_pid:
        rec = load(os.path.join(CLAUDE_SESSIONS_DIR, f"{claude_pid}.json"))
        if rec:
            return rec
    try:
        names = os.listdir(CLAUDE_SESSIONS_DIR)
    except OSError:
        return None
    for name in names:
        if name.endswith(".json"):
            rec = load(os.path.join(CLAUDE_SESSIONS_DIR, name))
            if rec:
                return rec
    return None


def bg_task_title(rec):
    """Usable display title from a background-task record, or None.
    Interactive records carry slugs like "lovable-7b" (their real titles
    arrive via session_name), and unnamed bg tasks carry the session id's
    first 8 chars as a placeholder name — neither is a title."""
    if not rec or rec.get("kind") != "bg":
        return None
    name = rec.get("name")
    if not name or name == str(rec.get("sessionId") or "")[:8]:
        return None
    return name


# Bridge-registered sessions rewrite at most this often — statusline
# refreshes can arrive several times a second while Claude streams.
STATUSLINE_WRITE_INTERVAL = 5


def register_statusline_session(d, rec=None):
    """Track sessions hooks never see (the agents feature runs sessions
    under a background pty daemon whose hook events don't fire) from their
    statusline refreshes. Hook-written records are left alone; a session is
    marked trackedBy=statusline and shows working while refreshes keep
    arriving (readers already downgrade quiet "working" to idle/ready).

    rec is Claude Code's own session record (claude_session_record), looked
    up once by the caller. It supplies what the statusline payload can't:
    the session kind, and the real busy/idle state — bridge sessions have
    no hook events, so without it every quiet session reads as working.
    """
    session_id = d["session_id"]
    session_file = os.path.join(SESSIONS_DIR, session_id + ".json")

    session = {}
    try:
        with open(session_file) as f:
            session = json.load(f)
    except (OSError, ValueError):
        pass
    if session and session.get("trackedBy") != "statusline":
        return  # hook-owned — never race the hook's writes
    if session:
        try:
            if time.time() - os.path.getmtime(session_file) < STATUSLINE_WRITE_INTERVAL:
                return
        except OSError:
            pass
    else:
        # Respect "hide until next activity" — the bridge refresh loop
        # isn't activity, so don't resurrect a dismissed session.
        if os.path.exists(os.path.join(DISMISSED_DIR, f"session-{session_id}")):
            return

    if not session.get("claudePid"):
        procs = process_table()
        claude_pid, tty, term_pid, term_app = find_process_info(os.getpid(), procs)
        if not session and claude_pid and is_dismissed(claude_pid):
            return
        session["claudePid"] = claude_pid
        session["terminalTty"] = tty
        session["terminalPid"] = term_pid
        session["terminalApp"] = term_app or "unknown"
        stamp_rex(session)
    # Daemon ptys don't show as a controlling tty in ps — recover them from
    # the claude process's open fds so title-marker activation still works.
    if session.get("claudePid") and not session.get("terminalTty"):
        session["terminalTty"] = tty_for_pid(session["claudePid"])

    if not session.get("lastPrompt"):
        prompt = first_prompt_from_transcript(d.get("transcript_path"))
        if prompt:
            session["lastPrompt"] = prompt

    if rec and rec.get("kind"):
        session["kind"] = rec["kind"]

    session.update({
        "sessionId": session_id,
        "cwd": d.get("cwd", session.get("cwd", "")),
        # Only an explicit "idle" from the record downgrades — busy,
        # missing record, or an unknown value all stay "working".
        "status": "idle" if rec and rec.get("status") == "idle" else "working",
        "trackedBy": "statusline",
        "transcriptPath": d.get("transcript_path", session.get("transcriptPath")),
        "updatedAt": utcnow(),
    })
    atomic_write(session_file, session)


def handle_statusline():
    """Statusline bridge: capture session_name from the statusLine JSON.

    Claude Code re-runs the statusLine command on every refresh with the
    session's current name (custom or auto-generated topic title), which
    hooks never see mid-session — this is the only live source for it.
    Also registers sessions the hooks aren't tracking (see above).
    """
    d = json.load(sys.stdin)
    session_id = d.get("session_id")
    if not session_id:
        return
    # One record lookup serves both the label and the registration below.
    rec = claude_session_record(session_id)
    name = d.get("session_name")
    if name:
        write_label(session_id, name)
    elif read_label(session_id) is None:
        # No label yet — seed one, but never overwrite: daemon-hosted
        # refreshes arrive without session_name, and letting a fallback
        # clobber the real topic title would lose it. Precedence for the
        # seed: a named bg task's title (from Claude Code's own session
        # record — no hook or statusline field ever carries it), then
        # agent.name. "claude" is the catch-all agent type, not a title —
        # skip it so the app's project-name fallback shows instead.
        title = bg_task_title(rec)
        agent_name = (d.get("agent") or {}).get("name")
        if title:
            write_label(session_id, title)
        elif agent_name and agent_name != "claude":
            write_label(session_id, agent_name)
    register_statusline_session(d, rec)


# --- Subagent markers ---
# One file per running subagent (subagents/<session_id>/<agent_id>): parallel
# starts never race a shared counter, and the count is just a readdir.

def subagent_marker_dir(session_id):
    return os.path.join(SUBAGENTS_DIR, session_id)


def count_subagents(session_id):
    try:
        return len(os.listdir(subagent_marker_dir(session_id)))
    except FileNotFoundError:
        return 0


def track_subagent(event, session_id, agent_id):
    """Touch/remove the marker for one subagent; returns the running count."""
    marker_dir = subagent_marker_dir(session_id)
    safe_id = "".join(c if c.isalnum() or c in "-_." else "_" for c in str(agent_id))
    path = os.path.join(marker_dir, safe_id)
    if event == "SubagentStart":
        os.makedirs(marker_dir, exist_ok=True)
        open(path, "w").close()
    else:
        try:
            os.remove(path)
        except FileNotFoundError:
            pass
    return count_subagents(session_id)


def clear_subagents(session_id):
    marker_dir = subagent_marker_dir(session_id)
    try:
        for name in os.listdir(marker_dir):
            try:
                os.remove(os.path.join(marker_dir, name))
            except FileNotFoundError:
                pass
        os.rmdir(marker_dir)
    except (FileNotFoundError, OSError):
        pass


def prune_subagents():
    """Drop marker dirs for sessions that no longer exist, and markers
    older than 12h (a crashed subagent never fires SubagentStop)."""
    if not os.path.isdir(SUBAGENTS_DIR):
        return
    now = time.time()
    for session_id in os.listdir(SUBAGENTS_DIR):
        if not os.path.exists(os.path.join(SESSIONS_DIR, session_id + ".json")):
            clear_subagents(session_id)
            continue
        marker_dir = subagent_marker_dir(session_id)
        for name in os.listdir(marker_dir):
            path = os.path.join(marker_dir, name)
            try:
                if now - os.path.getmtime(path) > 43200:
                    os.remove(path)
            except OSError:
                continue


# --- Dismissal tombstones ---
# The app writes these when the user dismisses a session ("hide until next
# activity"). Scan mode won't resurrect a tombstoned process; any real hook
# event clears the tombstone so the session reappears.

def is_dismissed(pid):
    return os.path.exists(os.path.join(DISMISSED_DIR, f"pid-{pid}"))


def clear_tombstones(session_id, claude_pid):
    names = [f"session-{session_id}"]
    if claude_pid:
        names.append(f"pid-{claude_pid}")
    for name in names:
        try:
            os.remove(os.path.join(DISMISSED_DIR, name))
        except FileNotFoundError:
            pass


def prune_tombstones(procs):
    """Drop tombstones for dead processes and anything older than 24h."""
    if not os.path.isdir(DISMISSED_DIR):
        return
    now = time.time()
    for name in os.listdir(DISMISSED_DIR):
        path = os.path.join(DISMISSED_DIR, name)
        expired = False
        try:
            expired = now - os.path.getmtime(path) > 86400
        except OSError:
            continue
        if name.startswith("pid-"):
            try:
                expired = expired or int(name[4:]) not in procs
            except ValueError:
                expired = True
        if expired:
            try:
                os.remove(path)
            except FileNotFoundError:
                pass


# --- Scan mode: discover untracked claude processes ---

def viewer_claude_pids():
    """Pids of claude processes connected to a background-task daemon's
    control socket (cc-daemon.*/control.sock).

    Such a terminal is a "viewer": it's displaying the task list or an
    attached task, both already represented by named task rows — scan
    stamps them so readers can hide the bare host row. Test/debug
    override: JATTENDS_VIEWER_PIDS (comma-separated pids; empty = none),
    like JATTENDS_APP_RUNNING.

    lsof's unix-socket entries join via kernel addresses: the d field is
    the socket's own address and the n field is either the bound sock
    path (server side) or "->0xPEER" (a connected client end). A pid is a
    viewer if any of its peer addresses resolves to a control.sock path.
    Addresses are normalized (drop 0x and leading zeros) — peer refs can
    render with different zero-padding than device fields. Any lsof
    failure degrades to an empty set; scan must never break on this.
    """
    override = os.environ.get("JATTENDS_VIEWER_PIDS")
    if override is not None:
        pids = set()
        for part in override.split(","):
            try:
                pids.add(int(part))
            except ValueError:
                continue  # skip junk; the seam is best-effort too
        return pids

    def norm(addr):
        addr = addr.lower()
        if addr.startswith("0x"):
            addr = addr[2:]
        return addr.lstrip("0")

    try:
        out = subprocess.check_output(["lsof", "-U", "-Fpcdn"], text=True,
                                      stderr=subprocess.DEVNULL)
    except (subprocess.CalledProcessError, OSError):
        return set()
    pid = None
    dev = None
    control_addrs = set()   # socket addrs bound to a control.sock path
    peer_addrs = {}         # pid -> addrs of the sockets it's connected to
    for line in out.splitlines():
        if not line:
            continue
        tag, val = line[0], line[1:]
        if tag == "p":
            try:
                pid = int(val)
            except ValueError:
                pid = None
            dev = None
        elif tag == "d":
            dev = val
        elif tag == "n":
            if val.startswith("->0x"):
                if pid is not None:
                    peer_addrs.setdefault(pid, set()).add(norm(val[2:]))
            elif dev and "cc-daemon" in val and val.endswith("/control.sock"):
                control_addrs.add(norm(dev))
            dev = None
    return {p for p, addrs in peer_addrs.items() if addrs & control_addrs}


def reconcile_viewer(session, viewers):
    """Stamp/clear the session's viewer flag; True when it changed."""
    if session.get("claudePid") in viewers:
        if not session.get("viewer"):
            session["viewer"] = True
            return True
    elif "viewer" in session:
        del session["viewer"]
        return True
    return False


def reconcile_session(path, session, viewers):
    """Heal dormant session records against Claude Code's own.

    Statusline-tracked: idle daemon sessions stop re-rendering their
    statusline, so a bridge record can be stuck at its last written status
    forever — no refresh ever arrives to update it. The periodic scan
    reconciles status/kind (same mapping as the bridge) and seeds the
    label the same way. Writes only on an actual change: churning mtimes
    every 10s would defeat the readers' staleness logic.

    Hook-owned: hook events stay the status authority, but a dormant
    session (e.g. a finished bg task whose last event already fired) may
    never get its kind stamped — backfill just the kind, and only once
    the file has been quiet for a minute so racing a live hook's
    read-modify-write is effectively impossible. updatedAt stays put:
    this is a classification fix, not activity, and bumping it would
    un-stale a dormant session in the readers' sort.

    Both flavors also reconcile the viewer flag (see viewer_claude_pids)
    under the same ownership rules; a record changing kind and viewer at
    once is still a single write.
    """
    session_id = session.get("sessionId")
    if not session_id:
        return

    if session.get("trackedBy") != "statusline":
        try:
            if time.time() - os.path.getmtime(path) < 60:
                return  # possibly live — never race a hook's write
        except OSError:
            return
        changed = reconcile_viewer(session, viewers)
        if "kind" not in session:
            rec = claude_session_record(session_id, session.get("claudePid"))
            if rec and rec.get("kind"):
                session["kind"] = rec["kind"]
                changed = True
        if changed:
            atomic_write(path, session)
        return

    changed = reconcile_viewer(session, viewers)
    rec = claude_session_record(session_id, session.get("claudePid"))
    if rec:
        title = bg_task_title(rec)
        if title and read_label(session_id) is None:
            write_label(session_id, title)
        status = "idle" if rec.get("status") == "idle" else "working"
        kind = rec.get("kind") or session.get("kind")
        if status != session.get("status") or kind != session.get("kind"):
            session["status"] = status
            if kind:
                session["kind"] = kind
            session["updatedAt"] = utcnow()
            changed = True
    if changed:
        atomic_write(path, session)


def scan():
    tracked_ttys = set()
    tracked_cwds = set()
    viewers = None  # lazy: the lsof probe only pays off once a session
                    # actually has a claudePid to match against
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
        if viewers is None and d.get("claudePid"):
            viewers = viewer_claude_pids()
        reconcile_session(os.path.join(SESSIONS_DIR, name), d, viewers or set())

    procs = process_table()
    prune_tombstones(procs)
    prune_subagents()
    prune_labels()
    for pid, (_, ptty, name) in procs.items():
        if name != "claude":
            continue
        if is_dismissed(pid):
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
        "sessionName": read_label(d["session_id"]),
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
        claude_pid = None
        try:
            with open(session_file) as f:
                claude_pid = json.load(f).get("claudePid")
        except (OSError, ValueError):
            pass
        clear_tombstones(session_id, claude_pid)
        clear_subagents(session_id)
        remove_label(session_id)
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
    # A real hook event means hooks work for this session — take ownership
    # from the statusline bridge, which then stops writing the record.
    session.pop("trackedBy", None)

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
        # Daemon ptys don't show as a controlling tty in ps — recover them
        # from the claude process's open fds (title-marker activation).
        if session["claudePid"] and not session["terminalTty"]:
            session["terminalTty"] = tty_for_pid(session["claudePid"])

    stamp_rex(session)

    # Any real hook event is activity — undo a "hide until next activity"
    clear_tombstones(session_id, session.get("claudePid"))

    # Stamp the session kind (interactive vs bg task) from Claude Code's
    # own record, once. Only kind: hook events are the status authority
    # here, the record merely classifies the session. No record found?
    # Leave kind unset and retry on the next event.
    if "kind" not in session:
        rec = claude_session_record(session_id, session.get("claudePid"))
        if rec and rec.get("kind"):
            session["kind"] = rec["kind"]

    status = None
    detail = session.get("statusDetail")
    hook_output = None

    if event == "SessionStart":
        # source=compact means an auto-compact restart mid-turn: still working
        status = "working" if d.get("source") == "compact" else "idle"
        detail = None
        # Resumed/renamed sessions carry their title here; fresh ones get
        # theirs later via the statusline bridge.
        if d.get("session_title"):
            write_label(session_id, d["session_title"])
    elif event == "UserPromptSubmit":
        status = "working"
        detail = None
        session["turnStartedAt"] = utcnow()
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
        elif ntype == "idle_prompt" or "waiting for your input" in msg.lower():
            # Sitting at the prompt is a ready state, not a request for
            # attention — treat it exactly like a plain Stop.
            status = "idle"
            detail = None
        elif ntype == "agent_needs_input":
            # Broadcast about a *background* session, sent to every
            # instance with the task-list view open — it says nothing
            # about this session, and the payload doesn't identify the
            # task. The background task's own hooks report its status.
            return
        elif ntype == "elicitation_dialog":
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
    elif event in ("SubagentStart", "SubagentStop"):
        agent_id = d.get("agent_id")
        if not agent_id:
            return  # can't pair start/stop without an id; don't drift
        track_subagent(event, session_id, agent_id)
        status = "working"
    else:
        return

    session.update({
        "sessionId": session_id,
        "cwd": d.get("cwd", session.get("cwd", "")),
        "status": status,
        "statusDetail": detail,
        "permissionMode": d.get("permission_mode", session.get("permissionMode")),
        "transcriptPath": d.get("transcript_path", session.get("transcriptPath")),
        "subagentCount": count_subagents(session_id),
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
    elif len(sys.argv) > 1 and sys.argv[1] == "--statusline":
        handle_statusline()
    else:
        handle_event()


if __name__ == "__main__":
    try:
        main()
    except Exception:
        # Never break Claude Code on a monitoring failure.
        sys.exit(0)
