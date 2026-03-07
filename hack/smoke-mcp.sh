#!/usr/bin/env bash
# MCP server smoke tests — verify ctx mcp serve responds to JSON-RPC requests.
# Builds ctx, creates a temp context directory, then pipes JSON-RPC requests
# to 'ctx mcp serve' and validates responses.
# Exit code 0 = all passed.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

echo "Running MCP server smoke tests..."

# Build
VERSION=$(tr -d '[:space:]' < VERSION)
echo "  Building ctx (v${VERSION})..."
CGO_ENABLED=0 go build \
  -ldflags="-s -w -X github.com/ActiveMemory/ctx/internal/bootstrap.version=${VERSION}" \
  -o ctx ./cmd/ctx

CTX="$REPO_ROOT/ctx"
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

# Create a context directory
cd "$WORKDIR"
CTX_SKIP_PATH_CHECK=1 "$CTX" init >/dev/null 2>&1

PASS=0
FAIL=0

run_mcp_test() {
  local name="$1"
  local request="$2"
  local expect="$3"

  printf "  Testing: %s" "$name"

  response=$(echo "$request" | "$CTX" mcp serve 2>/dev/null || true)

  if echo "$response" | grep -q "$expect"; then
    echo " OK"
    PASS=$((PASS + 1))
  else
    echo " FAIL"
    echo "    Expected pattern: $expect"
    echo "    Got: $response"
    FAIL=$((FAIL + 1))
  fi
}

# Test 1: Initialize — server should return its name
run_mcp_test "initialize" \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","clientInfo":{"name":"test","version":"1.0"}}}' \
  '"name":"ctx"'

# Test 2: Ping — should return a result (not an error)
run_mcp_test "ping" \
  '{"jsonrpc":"2.0","id":2,"method":"ping"}' \
  '"result"'

# Test 3: Resources list — should return resources array
run_mcp_test "resources/list" \
  '{"jsonrpc":"2.0","id":3,"method":"resources/list"}' \
  '"resources"'

# Test 4: Tools list — should return tools array
run_mcp_test "tools/list" \
  '{"jsonrpc":"2.0","id":4,"method":"tools/list"}' \
  '"tools"'

# Test 5: Unknown method — should return error
run_mcp_test "unknown method error" \
  '{"jsonrpc":"2.0","id":5,"method":"nonexistent/method"}' \
  '"error"'

# Test 6: Parse error — invalid JSON should return error
run_mcp_test "parse error" \
  'not json' \
  '"error"'

echo ""
if [ $FAIL -eq 0 ]; then
  echo "$PASS/$((PASS + FAIL)) MCP smoke tests passed"
  exit 0
else
  echo "FAILED: $FAIL/$((PASS + FAIL)) MCP smoke tests failed"
  exit 1
fi
