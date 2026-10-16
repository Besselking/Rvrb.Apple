#!/bin/bash
# Builds a Release copy of the Mac app, quits the running one (which keeps your DJ spot), installs the new one in its
# place and opens it again: Xcode's Archive > Copy App, in one go.
#
# usage: Scripts/install-mac.sh [folder to install in]
# Without a folder it replaces the running copy wherever it is (Copy App puts it in /Applications/Rvrb/), else the
# one in /Applications/Rvrb, else /Applications.
set -euo pipefail

cd "$(dirname "$0")/.."
derived="build/Install"

running_copy() {
    # Mac copies only (an iOS simulator app has no Contents/MacOS), and not Xcode's own builds.
    pgrep -fl '/Rvrb\.app/Contents/MacOS/Rvrb$' | grep -v -E '/(build|DerivedData)/' | head -1 \
        | sed -E 's|^[0-9]+ (.*)/Contents/MacOS/Rvrb$|\1|' || true
}

if [ $# -gt 0 ]; then
    installed="$1/Rvrb.app"
elif [ -n "$(running_copy)" ]; then
    installed="$(running_copy)"
elif [ -d /Applications/Rvrb/Rvrb.app ]; then
    installed="/Applications/Rvrb/Rvrb.app"
else
    installed="/Applications/Rvrb.app"
fi

echo "Building…"
xcodebuild -project Rvrb.xcodeproj -scheme Rvrb -configuration Release -destination 'generic/platform=macOS' \
    -derivedDataPath "$derived" -quiet build
built="$derived/Build/Products/Release/Rvrb.app"

# Quit through the app (not kill), so it can keep the DJ spot; wait until it has gone.
if pgrep -f "$installed/Contents/MacOS/Rvrb" > /dev/null; then
    echo "Quitting $installed…"
    osascript -e "tell application \"$installed\" to quit"
    while pgrep -f "$installed/Contents/MacOS/Rvrb" > /dev/null; do sleep 0.5; done
fi

echo "Installing $installed…"
mkdir -p "$(dirname "$installed")"
rm -rf "$installed"
ditto "$built" "$installed"
open "$installed"
