#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
for scheme in HDXLVoiceProcessing HDXLVoiceProcessingAudio HDXLVoiceProcessingVisualization; do
    xcodebuild -scheme "$scheme" -destination 'generic/platform=iOS Simulator' \
        -derivedDataPath .build/xcode-ios CODE_SIGNING_ALLOWED=NO build
done
