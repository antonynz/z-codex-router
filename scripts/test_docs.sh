#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
PASSED=0

assert_contains() {
  grep -F "$1" "$2" >/dev/null || {
    printf 'FAIL: missing %s in %s\n' "$1" "$2" >&2
    exit 1
  }
  PASSED=$((PASSED + 1))
}

[ -f "$ROOT/README.en.md" ] || { printf 'FAIL: README.en.md is missing\n' >&2; exit 1; }
[ -f "$ROOT/docs/manual-install.md" ] || { printf 'FAIL: manual-install.md is missing\n' >&2; exit 1; }
[ -f "$ROOT/docs/commands.md" ] || { printf 'FAIL: commands.md is missing\n' >&2; exit 1; }
[ -f "$ROOT/docs/troubleshooting.md" ] || { printf 'FAIL: troubleshooting.md is missing\n' >&2; exit 1; }
[ -f "$ROOT/docs/architecture.md" ] || { printf 'FAIL: architecture.md is missing\n' >&2; exit 1; }

assert_contains 'zcr-test:posix-install' "$ROOT/README.md"
assert_contains 'zcr-test:powershell-install' "$ROOT/README.md"
assert_contains ': "${CODEX_HOME:=$HOME/.codex}"' "$ROOT/README.md"
assert_contains 'Join-Path $env:USERPROFILE ".codex"' "$ROOT/README.md"
assert_contains 'zcr uninstall --purge-profile' "$ROOT/README.md"
assert_contains 'Windows PowerShell 5.1 / 7' "$ROOT/README.md"
assert_contains 'Lifecycle contract' "$ROOT/README.en.md"
assert_contains 'SHA256SUMS' "$ROOT/docs/manual-install.md"
assert_contains 'retry_safe' "$ROOT/docs/commands.md"
assert_contains 'next_command' "$ROOT/docs/troubleshooting.md"
assert_contains 'core/router.md' "$ROOT/docs/architecture.md"
assert_contains 'manual-install.md' "$ROOT/docs/index.md"

printf 'PASS test_docs.sh (%s assertions)\n' "$PASSED"
