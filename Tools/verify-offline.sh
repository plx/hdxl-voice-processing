#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
consumer_binary_dir="$(swift build --package-path Examples/CoreConsumer --show-bin-path)"
test -x "$consumer_binary_dir/CoreConsumer"
# This OS sandbox applies to execution only; build/resolve is a separate developer action.
/usr/bin/sandbox-exec -p '(version 1)(allow default)(deny network*)' \
    "$consumer_binary_dir/CoreConsumer"
