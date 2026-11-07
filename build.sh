#!/bin/zsh
# Builds Faders.app without Xcode (uses the Command Line Tools toolchain).
set -euo pipefail
cd "$(dirname "$0")"

export DEVELOPER_DIR=/Library/Developer/CommandLineTools
APP=build/Faders.app
ARCH=$(uname -m)
SDK=$DEVELOPER_DIR/SDKs/MacOSX26.sdk

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Resources/Info.plist "$APP/Contents/Info.plist"

swiftc -O -swift-version 5 -parse-as-library \
  -sdk "$SDK" -target "$ARCH-apple-macos14.4" \
  Sources/*.swift \
  -framework CoreAudio -framework AudioToolbox -framework AppKit -framework SwiftUI \
  -o "$APP/Contents/MacOS/Faders"

codesign --force --sign - "$APP"
echo "Built $PWD/$APP"
