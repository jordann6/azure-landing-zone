#!/usr/bin/env bash
# Assert the source image, isolation, encryption, patch mode and live OS baseline.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$SCRIPT_DIR/test-compute.py"
