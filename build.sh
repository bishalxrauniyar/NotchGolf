#!/bin/sh
# Builds NotchGolf.app — a 9-hole mini-golf game that lives in your MacBook's notch.
set -e
cd "$(dirname "$0")"

mkdir -p NotchGolf.app/Contents/MacOS NotchGolf.app/Contents/Resources

# Universal binary: build each slice, then lipo them together (works on Apple Silicon + Intel)
swiftc -O -swift-version 5 -target arm64-apple-macos14.0 main.swift \
    -o /tmp/notchgolf-arm64 \
    -framework AppKit -framework Carbon -framework AVFoundation -framework QuartzCore
swiftc -O -swift-version 5 -target x86_64-apple-macos14.0 main.swift \
    -o /tmp/notchgolf-x86_64 \
    -framework AppKit -framework Carbon -framework AVFoundation -framework QuartzCore
lipo -create /tmp/notchgolf-arm64 /tmp/notchgolf-x86_64 \
    -o NotchGolf.app/Contents/MacOS/NotchGolf

cp Info.plist NotchGolf.app/Contents/Info.plist

sh makeicon.sh >/dev/null 2>&1 || true
if [ -f AppIcon.icns ]; then
    cp AppIcon.icns NotchGolf.app/Contents/Resources/AppIcon.icns
fi

codesign --force --sign - NotchGolf.app 2>/dev/null || true

echo "Built NotchGolf.app — open it and play."
