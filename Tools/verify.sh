#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcrun swift --version
bash Tools/format.sh --check
python3 Tools/verify-provenance.py
python3 -m unittest discover -s Tools/Tests -p 'test_*.py'
swift build
swift test
swift run --package-path Examples/CoreConsumer CoreConsumer
python3 Tools/verify-package-graph.py
bash Tools/verify-offline.sh
