#!/usr/bin/env bash
set -euo pipefail

# Verify why-docs are in sync with embedded copies
FAIL=0
for pair in \
    "docs/index.md:internal/assets/why/manifesto.md" \
    "docs/home/about.md:internal/assets/why/about.md" \
    "docs/reference/design-invariants.md:internal/assets/why/design-invariants.md"; do
    SRC="${pair%%:*}"
    DST="${pair##*:}"
    if [ ! -f "$SRC" ] || [ ! -f "$DST" ]; then
        echo "SKIP: $SRC or $DST not found"
        continue
    fi
    if ! diff -q "$SRC" "$DST" >/dev/null 2>&1; then
        echo "DIFF: $SRC ≠ $DST"
        FAIL=1
    fi
done
if [ "$FAIL" -ne 0 ]; then
    echo "Why docs out of sync — run: make sync-why"
    exit 1
fi
echo "Why docs in sync"
