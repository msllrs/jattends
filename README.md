# Jattends

A menubar app that tells you when your [Claude Code](https://docs.anthropic.com/en/docs/claude-code) sessions need attention.

<img src="Resources/screenshot.png" alt="Jattends menubar dropdown" width="420">

*From French "j'attends" — "I'm waiting."*

## Install

```bash
git clone https://github.com/msllrs/jattends.git
cd jattends
bash scripts/install.sh
```

Grant **Accessibility** permission when prompted — this lets Jattends raise the correct terminal window when you click a session.

## How it works

Jattends uses Claude Code [hooks](https://docs.anthropic.com/en/docs/claude-code/hooks) to track session state. When something needs your attention — a tool approval, a question, a notification — a badge appears in your menubar. Click a session to jump straight to the right terminal window.

## Features

- **Menubar badge** — see at a glance when sessions are waiting
- **Terminal focus** — click a session to raise the exact window
- **Dismiss** — Option+click a session to dismiss it, or Option+click the header to clear all
- **Notifications** — native macOS notifications when a session starts waiting
- **Sound alerts** — play a system sound, with an option to repeat until dismissed
- **Global shortcut** — jump to the most recent waiting session from any app
- **Auto-clear** — automatically dismiss waiting sessions after a configurable timeout
- **Multi-terminal** — Ghostty, Terminal.app, iTerm2, kitty, Warp, Alacritty, WezTerm, Hyper, VS Code

Notifications, sound, shortcut, and auto-clear are off by default. Configure in Settings (menubar icon → Settings).

## Requirements

- macOS 14+
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code)
- Swift 5.10+ (Xcode 15.3+)

## Uninstall

```bash
bash scripts/uninstall.sh
```

## License

[MIT](LICENSE)
