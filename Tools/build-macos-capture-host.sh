#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
package=Examples/MacOSCaptureHost
destination=.build/macos-capture-host/MacOSCaptureHost.app
swift build --package-path "$package" --configuration release
binary_dir=$(swift build --package-path "$package" --configuration release --show-bin-path)
mkdir -p "$destination/Contents/MacOS"
cp "$binary_dir/MacOSCaptureHost" "$destination/Contents/MacOS/MacOSCaptureHost"
cp "$package/Info.plist" "$destination/Contents/Info.plist"
plutil -lint "$destination/Contents/Info.plist" "$package/Development.entitlements"
# Default: ad-hoc local development identity. Supply an existing identity explicitly
# for stable TCC identity; no credentials, provisioning, or distribution setup here.
codesign --force --sign "${CAPTURE_HOST_SIGN_IDENTITY:--}" --timestamp=none --options runtime \
    --entitlements "$package/Development.entitlements" "$destination"
codesign --verify --strict "$destination"
codesign --display --entitlements - --xml "$destination"
echo "Built and signed $destination (not launched; no microphone access)."
