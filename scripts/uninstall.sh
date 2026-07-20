#!/usr/bin/env bash
# uninstall.sh — Remove Jattends app, hooks, and session data
set -euo pipefail

APP="/Applications/Jattends.app"
HOOKS=("${HOME}/.claude/hooks/jattends-hook.py" "${HOME}/.claude/hooks/jattends-hook.sh")
SESSIONS="${HOME}/.claude/jattends"
SETTINGS="${HOME}/.claude/settings.json"

echo "Uninstalling Jattends..."

# Quit the app if running
pkill -x Jattends 2>/dev/null || true

# Remove app
if [ -d "$APP" ]; then
    rm -rf "$APP"
    echo "Removed: $APP"
fi

# Remove hook scripts (current and legacy)
for hook in "${HOOKS[@]}"; do
    if [ -f "$hook" ]; then
        rm -f "$hook"
        echo "Removed: $hook"
    fi
done

# Remove session data
if [ -d "$SESSIONS" ]; then
    rm -rf "$SESSIONS"
    echo "Removed: $SESSIONS"
fi

# Remove hook entries from settings.json
if [ -f "$SETTINGS" ]; then
    echo "Removing hooks from $SETTINGS..."
    /usr/bin/python3 << 'PYTHON'
import json, os

settings_path = os.path.expanduser("~/.claude/settings.json")

if not os.path.exists(settings_path):
    exit(0)

with open(settings_path) as f:
    settings = json.load(f)

hooks = settings.get("hooks", {})
changed = False

for event in list(hooks.keys()):
    matchers = hooks[event]
    filtered = []
    for matcher in matchers:
        # Remove matchers that only contain our hook (any jattends-hook variant)
        hook_list = matcher.get("hooks", [])
        remaining = [h for h in hook_list if "jattends-hook" not in h.get("command", "")]
        if remaining:
            matcher["hooks"] = remaining
            filtered.append(matcher)
        elif hook_list:
            changed = True
    if filtered:
        hooks[event] = filtered
    elif hooks[event] != filtered:
        del hooks[event]
        changed = True

if changed:
    with open(settings_path, "w") as f:
        json.dump(settings, f, indent=2)
        f.write("\n")
    print("Hooks removed from " + settings_path)
else:
    print("No Jattends hooks found in settings.")
PYTHON
fi

echo ""
echo "Jattends has been uninstalled."
