#!/bin/bash
# Assemble a standalone Claudepit.app you can hand to someone else.
#
# Why the resource bundles land at the .app root rather than Contents/Resources:
# SwiftPM generates `Bundle.module` accessors that look *only* at
#   Bundle.main.bundleURL/<Name>.bundle
# and otherwise fall back to an absolute path inside the build tree of the machine
# that compiled it — then `fatalError`. For an .app, Bundle.main.bundleURL is the
# .app directory itself, so that is where the bundles have to go for the app to
# find its own resources on someone else's Mac.
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG=${CONFIG:-release}
APP="${1:-build/Claudepit.app}"
VERSION=${VERSION:-0.1.0}

echo "==> Building ($CONFIG)"
swift build -c "$CONFIG" --product ClaudepitApp

BIN=".build/$CONFIG/ClaudepitApp"
[ -x "$BIN" ] || { echo "no binary at $BIN"; exit 1; }

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ClaudepitApp"

# Resource bundles must sit next to Contents/, see note above.
for b in .build/"$CONFIG"/*.bundle; do
  [ -e "$b" ] || continue
  cp -R "$b" "$APP/$(basename "$b")"
done

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Claudepit</string>
    <key>CFBundleDisplayName</key><string>Claudepit</string>
    <key>CFBundleIdentifier</key><string>dev.claudepit.app</string>
    <key>CFBundleExecutable</key><string>ClaudepitApp</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
</dict>
</plist>
PLIST

# Sign the executable, not the whole bundle: sealing the bundle fails with
# "unsealed contents present in the bundle root" because the resource bundles have
# to live there (see note above). Ad-hoc is enough for informal sharing; a notarized
# build would need the resource lookup reworked so Contents/Resources can be used.
echo "==> Signing executable (ad-hoc)"
codesign --force --sign - "$APP/Contents/MacOS/ClaudepitApp"

echo "==> Zipping"
ZIP="${APP%.app}.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo
echo "App: $APP  ($(du -sh "$APP" | cut -f1))"
echo "Zip: $ZIP  ($(du -sh "$ZIP" | cut -f1))"
echo
echo "Recipient runs this once, because the app is not notarized:"
echo "  xattr -dr com.apple.quarantine /Applications/Claudepit.app"
