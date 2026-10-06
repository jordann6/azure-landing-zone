#!/usr/bin/env bash
# Fail closed: an API or parsing error must never be reported as clean teardown.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$SCRIPT_DIR/verify-teardown.py"
