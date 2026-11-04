#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
version=1.7.12
expected=aba9ced2dee8d27fecca3dc7feb1a7f9a52caefa1eb46f3271ea66b6e0e6953f
if [[ "$(uname -s)-$(uname -m)" != Darwin-arm64 ]]; then
    echo 'Pinned workflow validator currently supports macOS arm64 only.' >&2
    exit 2
fi
validator_dir="$(mktemp -d "${TMPDIR:-/tmp}/hdxl-actionlint.XXXXXX")"
trap 'rm -rf "$validator_dir"' EXIT
curl --fail --location --silent --show-error --retry 3 \
    "https://github.com/rhysd/actionlint/releases/download/v$version/actionlint_${version}_darwin_arm64.tar.gz" \
    --output "$validator_dir/actionlint.tar.gz"
echo "$expected  $validator_dir/actionlint.tar.gz" | shasum -a 256 -c -
tar -xzf "$validator_dir/actionlint.tar.gz" -C "$validator_dir" actionlint
"$validator_dir/actionlint" -color -shellcheck='' .github/workflows/*.yml
