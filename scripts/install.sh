#!/usr/bin/env bash
# install.sh — Build, install Jattends.app, and configure Claude Code hooks
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Sync version from VERSION file into Info.plist and Raycast package.json
VERSION=$(tr -d '[:space:]' < "$PROJECT_DIR/VERSION")
/usr/bin/python3 -c "
import plistlib, sys
path = sys.argv[1] + '/Resources/Info.plist'
with open(path, 'rb') as f:
    plist = plistlib.load(f)
plist['CFBundleShortVersionString'] = sys.argv[2]
# Bump build number from current value
plist['CFBundleVersion'] = str(int(plist.get('CFBundleVersion', '0')) + 1)
with open(path, 'wb') as f:
    plistlib.dump(plist, f)
" "$PROJECT_DIR" "$VERSION"

/usr/bin/python3 -c "
import json, sys
path = sys.argv[1] + '/raycast-extension/package.json'
with open(path) as f:
    pkg = json.load(f)
pkg['version'] = sys.argv[2]
with open(path, 'w') as f:
    json.dump(pkg, f, indent=2)
    f.write('\n')
" "$PROJECT_DIR" "$VERSION"

echo "Version: $VERSION"

# Build first
bash "$SCRIPT_DIR/build.sh"

APP_SRC="${PROJECT_DIR}/.build/Jattends.app"
APP_DST="/Applications/Jattends.app"
HOOK_SRC="${SCRIPT_DIR}/jattends-hook.py"
HOOK_DST="${HOME}/.claude/hooks/jattends-hook.py"
OLD_HOOK_DST="${HOME}/.claude/hooks/jattends-hook.sh"
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
rm -f "$OLD_HOOK_DST"
echo "Installed: $HOOK_DST"

# Create sessions and approvals directories
mkdir -p "${HOME}/.claude/jattends/sessions" "${HOME}/.claude/jattends/approvals"

# Configure hooks in settings.json
echo ""
echo "Configuring Claude Code hooks..."
/usr/bin/python3 << 'PYTHON'
import json, os, sys

settings_path = os.path.expanduser("~/.claude/settings.json")
hook_cmd = "~/.claude/hooks/jattends-hook.py"

# Load existing settings or start fresh
if os.path.exists(settings_path):
    with open(settings_path) as f:
        settings = json.load(f)
else:
    settings = {}

hooks = settings.setdefault("hooks", {})

# Per-event timeouts: everything is a fast local write except
# PermissionRequest, which may block awaiting an in-app decision.
hook_events = {
    "SessionStart": 10,
    "SessionEnd": 10,
    "UserPromptSubmit": 10,
    "PostToolUse": 10,
    "Notification": 10,
    "Stop": 10,
    "StopFailure": 10,
    "PreCompact": 10,
    "PostCompact": 10,
    "SubagentStart": 10,
    "SubagentStop": 10,
    "PermissionRequest": 90,
}

def is_jattends(h):
    return "jattends-hook" in h.get("command", "")

changed = False
# Drop registrations for events we no longer use (and old .sh entries)
for event in list(hooks.keys()):
    matchers = hooks[event]
    for matcher in matchers:
        entries = matcher.get("hooks", [])
        stale = [h for h in entries if is_jattends(h) and (
            event not in hook_events
            or h.get("command") != hook_cmd
            or h.get("timeout") != hook_events[event])]
        if stale:
            matcher["hooks"] = [h for h in entries if h not in stale]
            changed = True
    pruned = [m for m in matchers if m.get("hooks") or m.get("matcher")]
    if pruned != matchers:
        hooks[event] = pruned
        changed = True
    if not hooks[event]:
        del hooks[event]
        changed = True

for event, timeout in hook_events.items():
    matchers = hooks.setdefault(event, [])
    already = any(is_jattends(h) for m in matchers for h in m.get("hooks", []))
    if not already:
        matchers.append({"hooks": [{"type": "command", "command": hook_cmd,
                                    "timeout": timeout}]})
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
