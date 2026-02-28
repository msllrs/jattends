<img src="assets/icon.png" alt="Jattends icon" width="64">

A [Raycast](https://www.raycast.com/) extension for quickly switching between [Claude Code](https://docs.anthropic.com/en/docs/claude-code) sessions. Complements the [Jattends](https://github.com/msllrs/jattends) menubar app.

<img width="1872" height="1320" alt="Jattends Raycast extension screenshot" src="https://github.com/user-attachments/assets/0d7762f9-7aef-4548-8650-253f2b21b751" />

## Install

```bash
cd raycast-extension
npm install
npm run build
```

Then open Raycast, search "Import Extension", and select the `raycast-extension` folder. The extension persists across Raycast restarts.

For development, use `npm run dev` instead of `npm run build` to get auto-reload on file changes.

## How it works

The Claude Code hook (`~/.claude/hooks/jattends-hook.sh`) writes a JSON file per session to `~/.claude/jattends/sessions/`. The extension reads these files, groups them by status, and provides fuzzy search. Press Enter on a session to jump straight to the right terminal window.

## Features

- **Status groups** — sessions grouped by Waiting, Working, and Ready
- **Fuzzy search** — filter by project name, directory path, or session ID
- **Terminal focus** — press Enter to raise the exact window (via OSC 2 title marker + System Events)
- **Multi-terminal** — Ghostty, iTerm2, Terminal.app, kitty, Alacritty, WezTerm, and more
- **Auto-cleanup** — stale and dead sessions are removed automatically

## Requirements

- [Jattends](https://github.com/msllrs/jattends) menubar app installed (provides the Claude Code hook)
- [Raycast](https://www.raycast.com/)
- Accessibility permission for Raycast (System Settings → Privacy & Security → Accessibility)
