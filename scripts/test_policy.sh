#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
ROUTER=$ROOT/plugins/z-codex-router/core/router.md
PORTABLE=$ROOT/plugins/z-codex-router/profiles/portable/default.toml
BLOCK=$ROOT/plugins/z-codex-router/core/managed-block.md
PLUGIN=$ROOT/plugins/z-codex-router/.codex-plugin/plugin.json
PASSED=0

assert_text() {
  grep -F "$2" "$1" >/dev/null || {
    printf 'FAIL: missing %s in %s\n' "$2" "$1" >&2
    exit 1
  }
  PASSED=$((PASSED + 1))
}

assert_text "$ROUTER" '返回非空 `threadId`'
assert_text "$ROUTER" '`ROUTE_READY`'
assert_text "$ROUTER" '返回非空 `clientThreadId`'
assert_text "$ROUTER" '`ROUTE_PENDING`'
assert_text "$ROUTER" '`ROUTE_HANDOFF_REQUIRED`'
assert_text "$ROUTER" '`ROUTE_DESTINATION_TUPLE_UNAVAILABLE`'
assert_text "$ROUTER" '`ROUTE_INPUT_REJECTED`'
assert_text "$ROUTER" '`ROUTE_OUTCOME_UNKNOWN`'
assert_text "$ROUTER" '禁止重试'
assert_text "$ROUTER" '`thinking`'
assert_text "$PORTABLE" 'pending = "clientThreadId:ROUTE_PENDING-no-retry"'
assert_text "$PORTABLE" 'destination_tuple_denied = "ROUTE_DESTINATION_TUPLE_UNAVAILABLE"'
assert_text "$PORTABLE" 'input_rejected = "ROUTE_INPUT_REJECTED"'
assert_text "$PORTABLE" 'outcome_unknown = "ROUTE_OUTCOME_UNKNOWN-no-retry"'
assert_text "$PORTABLE" 'authorization = "managed-enable-persistent-until-uninstall"'
assert_text "$PORTABLE" 'dispatch = "A0-current-root;A1-C3-create-once"'
assert_text "$PORTABLE" 'execution_root = "valid-parent-receipt-execute-no-recursion"'
assert_text "$PORTABLE" 'states = ["verified", "mismatch", "unobservable"]'
assert_text "$BLOCK" 'current/format'
assert_text "$BLOCK" '`payload_sha256`'
assert_text "$BLOCK" '存在用户 profile override 时必须先验证'
assert_text "$BLOCK" '用户启用本受管块即持续明确授权'
assert_text "$BLOCK" 'A1–C3 必须先在 commentary'
assert_text "$BLOCK" '递归创建'
assert_text "$BLOCK" '`clientThreadId` 是'
assert_text "$PLUGIN" '"version": "1.0.0"'

if grep -R -n -i -E 'safe-auto[[:space:]]+(enable|disable|doctor|status|restore)' \
  "$ROOT/plugins/z-codex-router/core" \
  "$ROOT/plugins/z-codex-router/profiles" \
  "$ROOT/plugins/z-codex-router/skills" \
  "$ROOT/plugins/z-codex-router/.codex-plugin/plugin.json" >/dev/null; then
  printf 'FAIL: safe-auto remains in active plugin policy\n' >&2
  exit 1
fi
PASSED=$((PASSED + 1))

printf 'PASS test_policy.sh (%s assertions)\n' "$PASSED"
