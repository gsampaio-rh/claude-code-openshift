#!/usr/bin/env bash
# Legacy alias — use 02-validate-model.sh instead
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/02-validate-model.sh" "$@"
