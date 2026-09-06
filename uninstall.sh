#!/bin/bash
# uninstall.sh — stop and remove the ClipBridge background services.
set -uo pipefail
for label in com.sikai.clipbridge.prefetch com.sikai.clipbridge.watch; do
  launchctl bootout "gui/$UID/$label" 2>/dev/null && echo "stopped $label" || echo "$label was not running"
  rm -f "$HOME/Library/LaunchAgents/$label.plist"
done
for cmd in clip autopaste; do
  # Only remove the symlink if it is ours.
  [ -L "$HOME/.local/bin/$cmd" ] && case "$(readlink "$HOME/.local/bin/$cmd")" in
    */ClipBridge/bin/*) rm -f "$HOME/.local/bin/$cmd"; echo "unlinked $cmd" ;;
  esac
done
echo "Removed. Clipboard history is kept at ~/Library/Application Support/ClipBridge"
