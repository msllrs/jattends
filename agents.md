# Jattends — Agent Notes

Reference for AI agents working on this codebase.

## Architecture

Jattends is a macOS menu bar app (LSUIElement) built with Swift / SwiftUI, targeting macOS 14+. It monitors Claude Code sessions, alerts users when sessions need attention, and can answer permission requests from the menu bar.

### Data flow

1. **Claude Code hooks** (`scripts/jattends-hook.py`, pure Python) write JSON session files to `~/.claude/jattends/sessions/`
2. **SessionDirectoryWatcher** (FSEvents, 100ms coalesce) detects changes → triggers `SessionStore.reload()`
3. **SessionStore** parses JSON, cleans up dead/stale/duplicate sessions, sorts by status, tracks newly-attention-needing sessions, and fires `onReload` for event-driven UI updates
4. **AppDelegate** updates icon/notifications from `onReload`; a 10s timer runs `--scan` + force reload as a safety net (missed FSEvents, dead PIDs)
5. **Menu** is built dynamically in `menuNeedsUpdate` — pending approvals, then attention/working/ready session groups with activity detail, Settings, Quit
6. **TerminalActivator** raises the exact window: OSC 2 title marker → AX (AXDocument/AXTitle) → AppleScript → PID fallback
7. **ApprovalStore** watches `~/.claude/jattends/approvals/` for permission requests written by the hook and writes decision files back

### Dismissal ("hide until next activity")

Dismissing a session (Option-click a row, or Clear All) is non-destructive: the app writes tombstone files to `~/.claude/jattends/dismissed/` (`session-<id>` and `pid-<claudePid>`) and deletes the session file. Scan mode skips tombstoned PIDs so the 10s scanner won't resurrect the row; any real hook event clears the tombstones and the session reappears. Tombstones expire after 24h or when the process dies.

### In-app approvals

On `PermissionRequest`, the hook (if the app is running and `config.json` allows) writes `approvals/<requestId>.json` and polls up to `approvalWaitSeconds` (default 45) for `<requestId>.decision.json`. The app surfaces the request as a time-sensitive notification (Approve/Deny actions) and a menu section. A decision is forwarded to Claude Code as `hookSpecificOutput.decision` (`behavior: allow|deny`); on timeout the hook exits silently and the normal terminal prompt appears. The app mirrors approval preferences into `~/.claude/jattends/config.json` via `HookConfig.sync()`.

### Key services

| Service | Purpose |
|---------|---------|
| `SessionStore` | Core state — loads sessions, dedup/cleanup, exposes `waitingSessions`/`workingSessions`/`idleSessions`, `consumeNewlyWaiting()` |
| `ApprovalStore` | Pending permission requests; writes decision files for the blocked hook |
| `HookConfig` | Mirrors approval prefs to `~/.claude/jattends/config.json` for the hook |
| `NotificationManager` | macOS notifications (attention + approval categories with actions), sound alerts with optional repeat |
| `HotkeyManager` | Global + local keyboard shortcut via `NSEvent` monitors |
| `TerminalActivator` | Multi-strategy window activation (OSC 2 marker, AX, AppleScript, PID) |
| `SessionDirectoryWatcher` | FSEvents-based directory watcher (used for both sessions and approvals dirs) |

### Views

| View | Purpose |
|------|---------|
| `MenuBarIcon` | SVG-based menu bar icons (normal + badge variants) |
| `PreferencesView` | Settings window — application (background sessions, auto-clear), approvals, notifications, sound, keyboard shortcut |

## Build, install & test

```bash
bash scripts/build.sh           # Build to .build/Jattends.app
bash scripts/install.sh         # Build + install to /Applications + configure hooks
bash scripts/install.sh --reset-accessibility  # Also reset Accessibility TCC

python3 Tests/test_hook.py      # Hook tests (stdlib unittest, ~1 min)
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test  # Swift tests
```

`swift test` needs the full Xcode toolchain for XCTest; plain CommandLineTools can only `swift build`.

## Dev workflow notes

- **Ad-hoc signing**: each build gets a new code identity, so macOS Accessibility grants don't persist across rebuilds. `install.sh` skips `tccutil reset` on reinstall to avoid constant re-granting. Use `--reset-accessibility` if needed.
- **Accessibility prompt**: deferred to first session click (not app launch) and only shown once per launch to avoid annoyance during dev.
- **Settings window**: managed directly via `NSWindow` + `NSHostingView` rather than SwiftUI `Settings` scene, which doesn't work reliably in LSUIElement apps.
- **Newly-waiting tracking**: `SessionStore.consumeNewlyWaiting()` returns and clears the list so notifications fire exactly once per transition.
- **Hook testability**: `JATTENDS_APP_RUNNING=0|1` overrides the app-running check (the real app on the dev machine would otherwise leak into tests).

## Dev vs public deploy

| Concern | Dev (iterating locally) | Public (end user installs once) |
|---------|------------------------|--------------------------------|
| Install command | `bash scripts/install.sh` | `bash scripts/install.sh` |
| Accessibility TCC reset | Skipped (signature changes each build, would prompt every time) | Auto-resets on first install (no existing app in `/Applications`) |
| Force reset | `bash scripts/install.sh --reset-accessibility` | Not needed |
| Code signing | Ad-hoc (`codesign -s -`), identity changes each build | Same ad-hoc — but user only installs once so grant persists |
| App restart | `install.sh` auto-quits and relaunches | Same |

**Key gotcha**: ad-hoc signing gives the app a new code identity on every build. macOS ties Accessibility grants to code identity, so dev rebuilds invalidate the grant.

## UserDefaults keys

| Key | Type | Default | Purpose |
|-----|------|---------|---------|
| `inAppApprovals` | Bool | `true` | Answer permission requests from Jattends |
| `approvalWaitSeconds` | Double | `45` | How long the hook waits for a decision |
| `notificationsEnabled` | Bool | `false` | Master switch for all notifications |
| `notifyAttention` | Bool | `true` | Sub-toggle: session needs attention (waiting/question/error) |
| `notifyApprovals` | Bool | `true` | Sub-toggle: approval requests with Approve/Deny actions |
| `soundEnabled` | Bool | `false` | Enable sound alerts |
| `alertSoundName` | String | `"Glass"` | Which system sound to play |
| `soundRepeat` | Bool | `false` | Repeat sound until dismissed |
| `autoClearMinutes` | Int | `0` | Auto-dismiss attention sessions after N minutes |
| `backgroundSessions` | String | `"all"` | Background section visibility: `all` / `active` (working or compacting only) / `hidden`. Attention rows always surface |
| `hotkeyEnabled` | Bool | `false` | Enable global keyboard shortcut |
| `hotkeyKeyCode` | Int | `38` (J) | Key code for shortcut |
| `hotkeyModifiers` | Int | Cmd+Shift | Modifier flags for shortcut |

## Session JSON contract

**This is the single source of truth for the file format.** Written by `jattends-hook.py` to `~/.claude/jattends/sessions/{sessionId}.json`; read by both the Swift app and the Raycast extension (`raycast-extension/src/switch-session.tsx`). Any change here must be reflected in both readers.

```json
{
  "sessionId": "abc-123",
  "cwd": "/Users/you/project",
  "status": "working",
  "statusDetail": "Running: npm test",
  "lastPrompt": "fix the login bug",
  "permissionMode": "default",
  "transcriptPath": "~/.claude/projects/.../abc-123.jsonl",
  "terminalApp": "ghostty",
  "terminalPid": 12345,
  "terminalTty": "/dev/ttys000",
  "claudePid": 12346,
  "kind": "bg",
  "updatedAt": "2026-07-20T00:00:00Z"
}
```

Status values, in sort/priority order: `approval`, `waiting`, `error`, `working`, `compacting`, `idle`. Legacy files may contain `active` (readers normalize it to `working`). All fields except `sessionId`, `cwd`, `status`, `updatedAt` are optional.

`kind` is `"bg"` for sessions run by Claude Code's background-task daemon (the task-list/agents feature) and `"interactive"` for terminal sessions; absent means unknown (treat as interactive). The hook copies it from Claude Code's own per-process record (see "Claude Code session records" below).

`viewer: true` marks a terminal claude currently connected to a background-task daemon's `control.sock` — it's displaying the task list or an attached task, so its window is already reachable via the named task rows. `--scan` stamps and clears it every cycle (lsof unix-socket probe; `JATTENDS_VIEWER_PIDS` env overrides for tests).

Reader conventions both implementations follow:
- Delete files that are stale (>24h), whose `terminalPid`/`claudePid` are dead, or (no `claudePid`) whose cwd has no live claude process
- Dedupe by `claudePid`, keeping higher-priority status then most recent
- Show `working`/`compacting` sessions older than 5 minutes as `idle`
- Read `~/.claude/jattends/labels/{sessionId}` (plain text, see below) and title the session with it when present, keeping the cwd basename visible in the detail/subtitle
- Group ANONYMOUS background sessions — `kind: "bg"` AND no label — into their own "Background" section, except attention states (`approval`/`waiting`/`error`), which surface with the other attention rows regardless. A NAMED background task is first-class and renders in the normal status groups: whether a task is currently open in a terminal window is not observable (statusline renders daemon-side, job state doesn't track attachment, socket traffic is multiplexed), and the name exists precisely when a human engaged with the task
- Hide bare viewer terminals from the idle/Ready group: `viewer: true` AND idle AND no `lastPrompt` AND no label. Any prompt history, label, or non-idle status keeps the row visible

## Claude Code session records

Claude Code (verified on v2.1.218) maintains its own per-process records at `~/.claude/sessions/<pid>.json` — undocumented internals the hook treats as an optional enrichment source, never a requirement:

```json
{"pid": 4844, "sessionId": "abc-123", "kind": "bg", "name": "pr review #46498", "status": "idle", "cwd": "..."}
```

- `kind`: `interactive` | `bg` → copied to the session file's `kind`
- `status`: `busy` | `idle` → the bridge maps `idle` → `idle`, anything else (busy/missing/unknown) → `working`
- `name`: for `bg` sessions this is the task title, except unnamed tasks carry the session id's first 8 chars (skipped); for `interactive` sessions it's a slug like `lovable-7b` (never used)

Lookup is by `<claudePid>.json` when the pid is known (validated against `sessionId`), else a scan of the directory for a matching `sessionId`. A missing directory or record degrades to pre-existing behavior. Related: `~/.claude/jobs/<short-id>/state.json` holds per-task state (`state: "done"`, `intent`, worktree) — currently unused, a candidate for a completed-task signal.

## Session labels

`~/.claude/jattends/labels/{sessionId}` holds the session's Claude Code display name (auto-generated topic title, `/rename` name, background task title, or `--agent` name) as plain text — this is what distinguishes parallel sessions sharing one cwd. It's a sidecar file rather than a session-JSON field so its writer never races the hook's read-modify-write of the session file.

Writers: the statusline bridge (`jattends-hook.py --statusline`, fed the statusLine payload by the user's statusline command — the only live source of `session_name`) and `SessionStart`'s optional `session_title`. `SessionEnd` removes the label; `--scan` prunes labels without a session file. Approval requests snapshot it as `sessionName`.

Label precedence in the bridge: `session_name` from the payload always wins; when it's absent and no label exists yet, the bg task title from the Claude Code session record is used, then the payload's `agent.name` (skipping the catch-all `"claude"`).

Statusline bridge hookup (one line in the user's statusline script; must run in the FOREGROUND — Claude Code reaps the statusline's process group on exit, so a backgrounded child dies before Python starts):

```bash
echo "$input" | ~/.claude/hooks/jattends-hook.py --statusline >/dev/null 2>&1 || true
```

## Statusline-tracked sessions

The agents feature runs sessions under a background pty daemon (`claude.exe`, `claude bg-pty-host`/`bg-spare` processes) whose hook events never fire — but their statusline does. The bridge therefore also registers any session without a hook-written record: it writes a session file with `trackedBy: "statusline"`, `updatedAt: now` (throttled to one rewrite per 5s), plus `claudePid`/terminal info from the process-tree walk and `lastPrompt` from the transcript's first real user message (bounded read). `status` comes from the Claude Code session record's busy/idle when one matches (see above), else `"working"` while refreshes keep arriving.

Ownership rules: the bridge never touches a record without the `trackedBy` marker; any real hook event pops the marker and takes over. Status semantics for bridge sessions are coarse — "working while refreshes keep arriving" — and the readers' existing 5-minute quiet timeout downgrades them to ready. Dismissal tombstones are respected (the refresh loop doesn't count as activity). Readers match claude processes as `claude`, `claude.exe`, or `claude *` (pty hosts).

## Hook event → status mapping

| Event | Status | Notes |
|-------|--------|-------|
| `SessionStart` | `idle` (`working` if `source=compact`) | Session open, waiting for first prompt; writes `session_title` to the label file if present |
| `UserPromptSubmit` | `working` | Captures `lastPrompt` (first line, 120 chars) |
| `PostToolUse` | `working` | Detail: "Running: npm test", "Editing: Store.swift", ... |
| `PermissionRequest` | `approval` | May block for an in-app decision (see above) |
| `Notification` (`permission_prompt`) | `approval` | |
| `Notification` (`idle_prompt`) | `idle` | Sitting at the prompt — treated like a plain `Stop` |
| `Notification` (`agent_needs_input`, `elicitation_dialog`) | `waiting` | |
| `Notification` (other) | *(ignored)* | auth_success etc. |
| `Stop` | `idle`; `waiting` if message ends with `?` | The `?` check is a fallback for questions Claude asks without a Notification |
| `StopFailure` | `error` | Detail carries the error type (rate_limit, ...) |
| `PreCompact` / `PostCompact` | `compacting` / `working` | |
| `SubagentStart` / `SubagentStop` | `working` | Marker file per running subagent in `~/.claude/jattends/subagents/<session>/<agent_id>`; count written to the session file as `subagentCount`. Skipped if no `agent_id`. SessionEnd clears markers; scan prunes orphaned/12h-stale ones |
| `SessionEnd` | *(deleted)* | Session file, subagent markers, and label removed |

Registered in `~/.claude/settings.json` by `install.sh` with a 10s timeout per event (90s for `PermissionRequest`).
