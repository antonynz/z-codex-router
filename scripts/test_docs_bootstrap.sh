#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/zcr-docs-tests.XXXXXX")
PASSED=0

cleanup() {
  status=$?
  rm -rf -- "$TEST_ROOT"
  if [ "$status" -eq 0 ]; then
    printf 'PASS test_docs_bootstrap.sh (%s assertions)\n' "$PASSED"
  fi
  exit "$status"
}
trap cleanup 0
trap 'exit 130' HUP INT TERM

assert_contains() {
  grep -F "$1" "$2" >/dev/null || {
    printf 'FAIL: missing %s in %s\n' "$1" "$2" >&2
    exit 1
  }
  PASSED=$((PASSED + 1))
}

assert_contains 'zcr-test:posix-install' "$ROOT/README.md"
assert_contains 'zcr-test:powershell-install' "$ROOT/README.md"
assert_contains 'README.en.md' "$ROOT/README.md"
assert_contains 'docs/commands.md' "$ROOT/README.md"
assert_contains 'docs/troubleshooting.md' "$ROOT/README.md"

fake_dir=$TEST_ROOT/bin
mkdir -p "$fake_dir" "$TEST_ROOT/home" "$TEST_ROOT/any-directory"
cp "$ROOT/scripts/test_support/fake-codex.sh" "$fake_dir/codex"
chmod 700 "$fake_dir/codex"

# Execute the fenced POSIX install block from README.md verbatim (apart from
# its documented surrounding environment, which supplies a disposable home and
# a local Codex executable).
(
  cd "$ROOT"
  export CODEX_HOME=$TEST_ROOT/home
  export PATH="$fake_dir:$PATH"
  awk '
    /zcr-test:posix-install/ { inside = 1; next }
    inside && /^```/ { exit }
    inside { print }
  ' README.md | sh
) >"$TEST_ROOT/readme-posix.out"
assert_contains 'code=OK_STATUS' "$TEST_ROOT/readme-posix.out"
assert_contains 'state=enabled' "$TEST_ROOT/readme-posix.out"

(
  cd "$TEST_ROOT/any-directory"
  export CODEX_HOME=$TEST_ROOT/home
  export PATH="$TEST_ROOT/home/bin:$PATH"
  zcr disable
  zcr status
  zcr enable
  zcr profile set B2 gpt-5.6-terra high
  zcr profile show
) >"$TEST_ROOT/user-commands.out"
assert_contains 'code=OK_DISABLED' "$TEST_ROOT/user-commands.out"
assert_contains 'code=OK_STATUS' "$TEST_ROOT/user-commands.out"
assert_contains 'state=disabled' "$TEST_ROOT/user-commands.out"
assert_contains 'code=OK_ENABLED' "$TEST_ROOT/user-commands.out"
assert_contains 'code=OK_PROFILE_SET' "$TEST_ROOT/user-commands.out"
assert_contains 'next_command=zcr profile set B2 gpt-5.6-terra high' "$TEST_ROOT/user-commands.out"
[ -d "$TEST_ROOT/home/z-codex-router-marketplaces" ] || {
  printf 'FAIL: disable removed the registered plugin cache\n' >&2
  exit 1
}
PASSED=$((PASSED + 1))
