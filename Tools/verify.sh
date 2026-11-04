#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 Tools/ci.py debug
