#!/usr/bin/env bash
# Linux smoke tests for ctx CLI — equivalent of hack/smoke-windows.ps1.
# Builds ctx, creates a temp directory, and runs core commands.
# Exit code 0 = all passed.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

echo "Running Linux smoke tests..."

# Build
VERSION=$(tr -d '[:space:]' < VERSION)
echo "  Building ctx (v${VERSION})..."
CGO_ENABLED=0 go build \
  -ldflags="-s -w -X github.com/ActiveMemory/ctx/internal/bootstrap.version=${VERSION}" \
  -o ctx ./cmd/ctx

CTX="$REPO_ROOT/ctx"
TMPDIR=$(mktemp -d)
cd "$TMPDIR"

PASS=0
FAIL=0

run_test() {
  local name="$1"; shift
  printf "  Testing: %s" "$name"
  if "$@" >/dev/null 2>&1; then
    echo " OK"
    PASS=$((PASS + 1))
  else
    # drift exits non-zero by design
    if [[ "$name" == *drift* ]]; then
      echo " OK (drift exits non-zero)"
      PASS=$((PASS + 1))
    else
      echo " FAIL"
      FAIL=$((FAIL + 1))
    fi
  fi
}

run_test "ctx --help"              "$CTX" --help
CTX_SKIP_PATH_CHECK=1 run_test "ctx init" "$CTX" init
run_test "ctx status"              "$CTX" status
run_test "ctx agent"               "$CTX" agent
run_test "ctx drift"               "$CTX" drift
run_test "ctx add task smoke-test" "$CTX" add task "smoke test task"
run_test "ctx recall list"         "$CTX" recall list
run_test "ctx why manifesto"       "$CTX" why manifesto

# Cleanup
cd /
rm -rf "$TMPDIR"

echo ""
if [ $FAIL -eq 0 ]; then
  echo "$PASS/$((PASS + FAIL)) smoke tests passed"
  exit 0
else
  echo "FAILED: $FAIL/$((PASS + FAIL)) smoke tests failed"
  exit 1
fi
