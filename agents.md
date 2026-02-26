# Jattends — Agent Notes

Reference for AI agents working on this codebase.

## Architecture

Jattends is a macOS menu bar app (LSUIElement) built with Swift 5.10+ / SwiftUI, targeting macOS 14+. It monitors Claude Code sessions and alerts users when sessions need attention.

### Data flow

1. **Claude Code hooks** (`scripts/jattends-hook.sh`) write JSON session files to `~/.claude/jattends/sessions/`
2. **SessionDirectoryWatcher** (FSEvents, 300ms coalesce) detects changes → triggers `SessionStore.reload()`
3. **SessionStore** parses JSON, filters stale sessions (>24h), sorts by status, tracks newly-waiting sessions
4. **AppDelegate** polls `SessionStore` every 0.5s to update the menu bar icon and trigger notifications/sound
5. **Menu** is built dynamically in `menuNeedsUpdate` — shows waiting sessions, Settings, Quit
6. **TerminalActivator** uses Accessibility API → AppleScript → PID fallback to focus terminal windows

### Key services

| Service | Purpose |
|---------|---------|
| `SessionStore` | Core state — loads sessions, exposes `waitingSessions`, `consumeNewlyWaiting()` |
| `NotificationManager` | macOS notifications via `UNUserNotificationCenter`, sound alerts with optional repeat |
| `HotkeyManager` | Global + local keyboard shortcut via `NSEvent` monitors |
| `TerminalActivator` | Multi-strategy window activation (AX, AppleScript, PID) for 10+ terminals |
| `SessionDirectoryWatcher` | FSEvents-based directory watcher |

### Views

| View | Purpose |
|------|---------|
| `MenuBarIcon` | SVG-based menu bar icons (normal + badge variants) |
| `PreferencesView` | Settings window — notifications, sound, keyboard shortcut |

## Build & install

```bash
bash scripts/build.sh           # Build to .build/Jattends.app
bash scripts/install.sh         # Build + install to /Applications + configure hooks
bash scripts/install.sh --reset-accessibility  # Also reset Accessibility TCC
```

## Dev workflow notes

- **Ad-hoc signing**: each build gets a new code identity, so macOS Accessibility grants don't persist across rebuilds. `install.sh` skips `tccutil reset` on reinstall to avoid constant re-granting. Use `--reset-accessibility` if needed.
- **Accessibility prompt**: deferred to first session click (not app launch) and only shown once per launch to avoid annoyance during dev.
- **Settings window**: managed directly via `NSWindow` + `NSHostingView` rather than SwiftUI `Settings` scene, which doesn't work reliably in LSUIElement apps.
- **Newly-waiting tracking**: `SessionStore.consumeNewlyWaiting()` returns and clears the list to prevent the 0.5s timer from re-triggering notifications on every tick.

## Dev vs public deploy

| Concern | Dev (iterating locally) | Public (end user installs once) |
|---------|------------------------|--------------------------------|
| Install command | `bash scripts/install.sh` | `bash scripts/install.sh` |
| Accessibility TCC reset | Skipped (signature changes each build, would prompt every time) | Auto-resets on first install (no existing app in `/Applications`) |
| Accessibility prompt | Once per launch, on first session click | Once per launch, on first session click |
| Force reset | `bash scripts/install.sh --reset-accessibility` | Not needed |
| Code signing | Ad-hoc (`codesign -s -`), identity changes each build | Same ad-hoc — but user only installs once so grant persists |
| App restart | `install.sh` auto-quits and relaunches | Same |

**Key gotcha**: ad-hoc signing gives the app a new code identity on every build. macOS ties Accessibility grants to code identity, so dev rebuilds invalidate the grant. This is why the install script skips `tccutil reset` on reinstall and why `TerminalActivator` only prompts once per launch. End users who install once don't hit this issue.

## UserDefaults keys

| Key | Type | Default | Purpose |
|-----|------|---------|---------|
| `notificationsEnabled` | Bool | `false` | Enable macOS notifications |
| `soundEnabled` | Bool | `false` | Enable sound alerts |
| `alertSoundName` | String | `"Glass"` | Which system sound to play |
| `soundRepeat` | Bool | `false` | Repeat sound until dismissed |
| `hotkeyEnabled` | Bool | `false` | Enable global keyboard shortcut |
| `hotkeyKeyCode` | Int | `38` (J) | Key code for shortcut |
| `hotkeyModifiers` | Int | Cmd+Shift | Modifier flags for shortcut |

## Session JSON format

Written by `jattends-hook.sh` to `~/.claude/jattends/sessions/{sessionId}.json`:

```json
{
  "sessionId": "abc-123",
  "cwd": "/Users/you/project",
  "status": "waiting",
  "terminalApp": "ghostty",
  "terminalPid": 12345,
  "updatedAt": "2026-02-26T00:00:00Z"
}
```

Status values: `waiting` (needs attention), `active` (Claude working), `idle`.

## Hook event logic

| Event | Status | Condition |
|-------|--------|-----------|
| `SessionStart` | `active` | Always |
| `UserPromptSubmit` | `active` | Always — user responded, Claude is working |
| `PermissionRequest` | `waiting` | Always — tool approval genuinely needs input |
| `Notification` | `waiting` / `active` | Only `waiting` if `last_assistant_message` ends with `?` |
| `Stop` | `waiting` / `active` | Only `waiting` if `last_assistant_message` ends with `?` |
| `SessionEnd` | *(deleted)* | Session file removed |

**Key design decision**: `Notification` and `Stop` use the `?` check to avoid false "waiting" signals when the user is actively in the session. Without this, every Claude response triggers a notification even though the user is already looking at it.
