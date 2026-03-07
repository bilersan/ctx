#!/usr/bin/env bash
set -euo pipefail

# Check Go source formatting
BAD=$(gofmt -l . 2>&1 | grep -v '^vendor/' || true)
if [ -n "$BAD" ]; then
    echo "Files need formatting:"
    echo "$BAD"
    exit 1
fi
echo "Format OK"
