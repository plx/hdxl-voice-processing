#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
case "${1:---check}" in
    --check) operation=(lint --strict) ;;
    --write) operation=(format --in-place) ;;
    *) echo "usage: $0 [--check|--write]" >&2; exit 2 ;;
esac
git ls-files --cached --others --exclude-standard -z -- '*.swift' |
    xargs -0 xcrun swift-format "${operation[@]}" --configuration .swift-format
