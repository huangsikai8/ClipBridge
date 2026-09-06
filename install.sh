#!/bin/bash
# install.sh — build, sign and load (or reload) the ClipBridge services.
# Safe to re-run; that is the normal way to pick up a change in src/.
set -uo pipefail

# Resolve the repo from this script rather than a fixed path, so the clone
# can live anywhere.
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="$HOME/Library/LaunchAgents"
STATE="$HOME/Library/Application Support/ClipBridge"
mkdir -p "$DEST" "$STATE"

command -v swiftc >/dev/null 2>&1 || {
  echo "swiftc not found — install the Xcode command line tools:"
  echo "  xcode-select --install"
  exit 1
}

# The prefetch daemon lives inside an .app bundle: auto-paste needs
# Accessibility, and macOS grants that to bundles, not to bare executables.
APP="$SRC/ClipBridgeAgent.app"
APPBIN="$APP/Contents/MacOS/clip-prefetch"
mkdir -p "$APP/Contents/MacOS"

if [[ ! -x "$APPBIN" || "$SRC/src/ClipPrefetch.swift" -nt "$APPBIN" ]]; then
  echo "Building the agent..."
  swiftc -O "$SRC/src/ClipPrefetch.swift" -o "$APPBIN" || exit 1

  # The signing identity must be STABLE across rebuilds. Ad-hoc signing (-)
  # produces no stable designated requirement, so macOS grants Accessibility
  # and then silently drops it minutes later. Any self-signed certificate in
  # the login keychain avoids that; which one does not matter.
  IDENTITY="${CLIPBRIDGE_SIGN_IDENTITY:-}"
  if [ -z "$IDENTITY" ]; then
    IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
               | sed -n 's/.*"\(.*\)"$/\1/p' | head -1)
  fi

  if [ -n "$IDENTITY" ]; then
    if codesign --force --deep --sign "$IDENTITY" \
         --identifier com.sikaihuang.clipbridge "$APP" 2>/dev/null; then
      echo "  signed ($IDENTITY)"
    else
      echo "  WARNING: signing with '$IDENTITY' failed"
    fi
  else
    codesign --force --deep --sign - "$APP" 2>/dev/null
    echo "  WARNING: no codesigning certificate found, signed ad-hoc."
    echo "  Auto-paste will lose its Accessibility grant a few minutes after"
    echo "  you give it. To fix, make a self-signed certificate once:"
    echo "    Keychain Access -> Certificate Assistant -> Create a Certificate"
    echo "    name it anything, type 'Code Signing', then re-run install.sh."
  fi
fi

cp -f "$APPBIN" "$SRC/bin/clip-prefetch" 2>/dev/null   # keep the plain copy in step

# launchd does not expand $HOME or relative paths, so the absolute paths are
# substituted into the templates here instead of being committed.
for label in com.sikai.clipbridge.prefetch com.sikai.clipbridge.watch; do
  sed -e "s|__CLIPBRIDGE_DIR__|$SRC|g" -e "s|__HOME__|$HOME|g" \
      "$SRC/launchagents/$label.plist.template" > "$DEST/$label.plist" || exit 1
  launchctl bootout "gui/$UID/$label" 2>/dev/null
  # Bootout is asynchronous; bootstrapping immediately can race it.
  sleep 1
  err=$(launchctl bootstrap "gui/$UID" "$DEST/$label.plist" 2>&1)
  if [ -z "$err" ]; then
    echo "loaded  $label"
  else
    # Hiding this is how the prefetch service stayed down unnoticed.
    echo "FAILED to load $label: $err"
  fi
done

# Put the two commands worth remembering on PATH.
mkdir -p "$HOME/.local/bin"
ln -sf "$SRC/bin/clip" "$HOME/.local/bin/clip"
ln -sf "$SRC/bin/autopaste" "$HOME/.local/bin/autopaste"

echo
echo "Running services:"
launchctl list | grep clipbridge || echo "  (none — check $STATE/*.err)"

# Confirm they are actually alive, not merely registered.
pgrep -f "clip-prefetch" >/dev/null \
  && echo "running clip-prefetch" || echo "NOT RUNNING clip-prefetch"
echo "periodic clipwatch (runs every 60s)"

case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) echo; echo "Add ~/.local/bin to PATH to use 'clip' and 'autopaste' by name." ;;
esac
