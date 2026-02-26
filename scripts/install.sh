#!/usr/bin/env bash
# install.sh — Build, install Jattends.app, and configure Claude Code hooks
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Build first
bash "$SCRIPT_DIR/build.sh"

APP_SRC="${PROJECT_DIR}/.build/Jattends.app"
APP_DST="/Applications/Jattends.app"
HOOK_SRC="${SCRIPT_DIR}/jattends-hook.sh"
HOOK_DST="${HOME}/.claude/hooks/jattends-hook.sh"
SETTINGS_FILE="${HOME}/.claude/settings.json"

# Track whether this is a fresh install
FRESH_INSTALL=false
[[ ! -d "$APP_DST" ]] && FRESH_INSTALL=true

# Quit running instance if any
if pgrep -xq Jattends; then
    echo "Quitting running Jattends..."
    killall Jattends 2>/dev/null || true
    sleep 0.5
fi

# Install app
echo ""
echo "Installing to /Applications..."
rm -rf "$APP_DST"
cp -R "$APP_SRC" "$APP_DST"
echo "Installed: $APP_DST"

# Reset Accessibility trust on first install or when explicitly requested.
# Skipped on reinstall (dev workflow) since ad-hoc signing changes identity each build.
if [[ "$FRESH_INSTALL" == "true" ]] || [[ " $* " == *" --reset-accessibility "* ]]; then
    tccutil reset Accessibility com.jattends.app 2>/dev/null || true
fi

# Install hook script
echo ""
echo "Installing hook script..."
mkdir -p "$(dirname "$HOOK_DST")"
cp "$HOOK_SRC" "$HOOK_DST"
chmod +x "$HOOK_DST"
echo "Installed: $HOOK_DST"

# Create sessions directory
mkdir -p "${HOME}/.claude/jattends/sessions"

# Configure hooks in settings.json
echo ""
echo "Configuring Claude Code hooks..."
/usr/bin/python3 << 'PYTHON'
import json, os, sys

settings_path = os.path.expanduser("~/.claude/settings.json")
hook_cmd = "~/.claude/hooks/jattends-hook.sh"

# Load existing settings or start fresh
if os.path.exists(settings_path):
    with open(settings_path) as f:
        settings = json.load(f)
else:
    settings = {}

hooks = settings.setdefault("hooks", {})

# Hook events to register (all synchronous — the script is fast enough
# and synchronous hooks don't produce "Async hook completed" messages)
hook_events = [
    "Notification",
    "PermissionRequest",
    "Stop",
    "UserPromptSubmit",
    "SessionStart",
    "SessionEnd",
]

changed = False
for event in hook_events:
    matchers = hooks.setdefault(event, [])

    # Check if our hook command is already present in any matcher
    already_present = False
    for matcher in matchers:
        for h in matcher.get("hooks", []):
            if h.get("command") == hook_cmd:
                already_present = True
                break
        if already_present:
            break

    if not already_present:
        matchers.append({"hooks": [{"type": "command", "command": hook_cmd}]})
        changed = True

if changed:
    os.makedirs(os.path.dirname(settings_path), exist_ok=True)
    with open(settings_path, "w") as f:
        json.dump(settings, f, indent=2)
        f.write("\n")
    print("Hooks configured in " + settings_path)
else:
    print("Hooks already configured — no changes needed.")
PYTHON

# Launch the app
echo ""
echo "========================================"
echo " Installation complete!"
echo "========================================"
echo ""
echo "Launching Jattends..."
open /Applications/Jattends.app
echo ""
echo "Grant Accessibility permission when prompted (for terminal window activation)."
echo ""
