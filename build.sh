#!/bin/sh
# Builds NotchGolf.app — a 9-hole mini-golf game that lives in your MacBook's notch.
set -e
cd "$(dirname "$0")"

mkdir -p NotchGolf.app/Contents/MacOS NotchGolf.app/Contents/Resources

swiftc -O -swift-version 5 main.swift \
    -o NotchGolf.app/Contents/MacOS/NotchGolf \
    -framework AppKit -framework Carbon -framework AVFoundation -framework QuartzCore

cp Info.plist NotchGolf.app/Contents/Info.plist

sh makeicon.sh >/dev/null 2>&1 || true
if [ -f AppIcon.icns ]; then
    cp AppIcon.icns NotchGolf.app/Contents/Resources/AppIcon.icns
fi

codesign --force --sign - NotchGolf.app 2>/dev/null || true

echo "Built NotchGolf.app — open it and play."
