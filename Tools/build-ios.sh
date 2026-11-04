#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
case "${1:-simulator}" in
    simulator) destination='generic/platform=iOS Simulator'; derived=.build/xcode-ios ;;
    device) destination='generic/platform=iOS'; derived=.build/xcode-device ;;
    *) echo 'Usage: bash Tools/build-ios.sh [simulator|device]' >&2; exit 2 ;;
esac
for scheme in HDXLVoiceProcessing HDXLVoiceProcessingAudio HDXLVoiceProcessingVisualization; do
    xcodebuild -scheme "$scheme" -configuration Debug -destination "$destination" \
        -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO build
done
repository_dir="$PWD"
cd Examples/CoreConsumer
xcodebuild -scheme CoreConsumer -configuration Debug -destination "$destination" \
    -derivedDataPath "$repository_dir/$derived-consumer" CODE_SIGNING_ALLOWED=NO build
