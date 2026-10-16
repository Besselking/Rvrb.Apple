#!/bin/bash
# Builds a Release copy of the Mac app, quits the running one (which keeps your DJ spot), installs the new one and
# opens it again: Xcode's Archive > Copy App, in one go.
#
# usage: Scripts/install-mac.sh [destination folder, default /Applications]
set -euo pipefail

cd "$(dirname "$0")/.."
destination="${1:-/Applications}"
installed="$destination/Rvrb.app"
derived="build/Install"

echo "Building…"
xcodebuild -project Rvrb.xcodeproj -scheme Rvrb -configuration Release -destination 'generic/platform=macOS' \
    -derivedDataPath "$derived" -quiet build
built="$derived/Build/Products/Release/Rvrb.app"

# Quit through the app (not kill), so it can keep the DJ spot; wait until it has gone.
if pgrep -f "$installed/Contents/MacOS/Rvrb" > /dev/null; then
    echo "Quitting the running app…"
    osascript -e 'tell application id "is.bes.Rvrb" to quit'
    while pgrep -f "$installed/Contents/MacOS/Rvrb" > /dev/null; do sleep 0.5; done
fi

echo "Installing in $destination…"
rm -rf "$installed"
ditto "$built" "$installed"
open "$installed"
