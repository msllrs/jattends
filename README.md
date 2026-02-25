# Jattends

A macOS menubar app that monitors your [Claude Code](https://docs.anthropic.com/en/docs/claude-code) sessions and tells you when they need attention.

*From French "j'attends" — "I'm waiting."*

## How it works

Jattends sits in your menubar. Claude Code [hooks](https://docs.anthropic.com/en/docs/claude-code/hooks) write session state to disk whenever something changes — a notification fires, a tool needs approval, a turn finishes with a question, or a session starts/ends. Jattends watches the session directory and shows a badge when any session is waiting for you. Click a session to jump straight to the right terminal window.

## Requirements

- macOS 14+
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code)
- Swift 5.10+ (ships with Xcode 15.3+)

## Install

```bash
git clone https://github.com/msllrs/jattends.git
cd jattends
bash scripts/install.sh
```

The install script will:
1. Build the app from source
2. Copy `Jattends.app` to `/Applications`
3. Install the hook script to `~/.claude/hooks/`
4. Auto-configure Claude Code hooks in `~/.claude/settings.json`
5. Launch the app

Grant **Accessibility** permission when prompted — this lets Jattends raise the correct terminal window when you click a session.

## Manual setup

If you prefer to configure hooks yourself, build and install the app:

```bash
bash scripts/build.sh
cp -R .build/Jattends.app /Applications/
cp scripts/jattends-hook.sh ~/.claude/hooks/
chmod +x ~/.claude/hooks/jattends-hook.sh
mkdir -p ~/.claude/jattends/sessions
```

Then add the following to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "Notification": [{ "hooks": [{ "type": "command", "command": "~/.claude/hooks/jattends-hook.sh" }] }],
    "PermissionRequest": [{ "hooks": [{ "type": "command", "command": "~/.claude/hooks/jattends-hook.sh" }] }],
    "Stop": [{ "hooks": [{ "type": "command", "command": "~/.claude/hooks/jattends-hook.sh" }] }],
    "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "~/.claude/hooks/jattends-hook.sh" }] }],
    "SessionStart": [{ "hooks": [{ "type": "command", "command": "~/.claude/hooks/jattends-hook.sh" }] }],
    "SessionEnd": [{ "hooks": [{ "type": "command", "command": "~/.claude/hooks/jattends-hook.sh" }] }]
  }
}
```

## Architecture

```
scripts/jattends-hook.sh     Claude Code hook — writes session JSON to disk
  └─ ~/.claude/jattends/sessions/{session_id}.json

Sources/Jattends/
  JattendsApp.swift           App entry point, NSMenu-based menubar dropdown
  Models/
    SessionInfo.swift         Session data model (id, cwd, status, terminal info)
    SessionStatus.swift       Status enum: waiting / active / idle
  Services/
    SessionStore.swift        Reads session files, exposes observable state
    SessionDirectoryWatcher.swift   FSEvents watcher for the sessions directory
    TerminalActivator.swift   Activates the right terminal window via Accessibility API
  Views/
    MenuBarIcon.swift         SVG-based menubar icon (normal + badge variants)
```

## Supported terminals

Ghostty, Terminal.app, iTerm2, kitty, Warp, Alacritty, WezTerm, Hyper, VS Code (terminal)

## Uninstall

```bash
bash scripts/uninstall.sh
```

This removes the app, hook script, session data, and hook entries from your Claude Code settings.

## License

[MIT](LICENSE)
