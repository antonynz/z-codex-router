#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
INSTALLER=$ROOT/install.sh
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/zcr-install-tests.XXXXXX")
PASSED=0

cleanup() {
  status=$?
  rm -rf -- "$TEST_ROOT"
  if [ "$status" -eq 0 ]; then
    printf 'PASS test_install.sh (%s assertions)\n' "$PASSED"
  fi
  exit "$status"
}
trap cleanup 0
trap 'exit 130' HUP INT TERM

pass() { PASSED=$((PASSED + 1)); }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_contains() {
  grep -F "$1" "$2" >/dev/null || fail "missing '$1' in $2"
  pass
}

fake=$TEST_ROOT/fake-codex
cat >"$fake" <<'EOF'
#!/usr/bin/env sh
if [ -n "${FAKE_CODEX_LOG:-}" ]; then
  printf '%s\n' "$*" >>"$FAKE_CODEX_LOG"
fi
case "$*" in
  *--help*) exit 0 ;;
esac
if [ "$*" = "plugin marketplace list" ]; then
  printf '%-24s %s\n' MARKETPLACE ROOT
  if [ -n "${FAKE_MARKETPLACE_STATE:-}" ] && [ -f "$FAKE_MARKETPLACE_STATE" ]; then
    printf '%-24s %s\n' z-codex-router "$(cat "$FAKE_MARKETPLACE_STATE")"
  fi
  exit 0
fi
if [ "${FAKE_CODEX_FAIL:-0}" = 1 ] && [ "$1" = plugin ]; then
  exit 17
fi
if [ "$1 $2 $3" = "plugin marketplace add" ] && [ -n "${FAKE_MARKETPLACE_STATE:-}" ]; then
  if [ -f "$FAKE_MARKETPLACE_STATE" ] &&
    [ "$(cat "$FAKE_MARKETPLACE_STATE")" != "$4" ]; then
    exit 18
  fi
  printf '%s\n' "$4" >"$FAKE_MARKETPLACE_STATE"
fi
exit 0
EOF
chmod 700 "$fake"

# Local universal source install uses one cache build and enables Router.
home=$TEST_ROOT/home
log=$TEST_ROOT/codex.log
marketplace_state=$TEST_ROOT/marketplace-state
FAKE_CODEX_LOG=$log FAKE_MARKETPLACE_STATE=$marketplace_state \
  sh "$INSTALLER" --source "$ROOT" --codex-home "$home" \
  --codex-bin "$fake" --enable >"$TEST_ROOT/install-output"
assert_contains "ZCR_VERSION=1.0.0" "$TEST_ROOT/install-output"
assert_contains "ZCR_ENABLED=true" "$TEST_ROOT/install-output"
assert_contains "ZCR_ROUTE_CREATE_AUTHORIZATION=persistent-until-uninstall" "$TEST_ROOT/install-output"
assert_contains "ZCR_CODEX_SOURCE=explicit" "$TEST_ROOT/install-output"
assert_contains "+codex." "$TEST_ROOT/install-output"
assert_contains "用户启用本受管块即持续明确授权" "$home/AGENTS.md"
assert_contains "A1–C3 必须先在 commentary" "$home/AGENTS.md"
assert_contains "plugin marketplace add" "$log"
assert_contains "plugin add z-codex-router@z-codex-router" "$log"
sh "$home"/z-codex-router-marketplaces/*/plugins/z-codex-router/scripts/routerctl.sh \
  --codex-home "$home" doctor >"$TEST_ROOT/doctor-output"
assert_contains "code=OK_ENABLED" "$TEST_ROOT/doctor-output"

# Reinstalling 1.0.0 refreshes the already registered managed marketplace in place.
FAKE_CODEX_LOG=$log FAKE_MARKETPLACE_STATE=$marketplace_state \
  sh "$INSTALLER" --source "$ROOT" --codex-home "$home" \
  --codex-bin "$fake" --enable >"$TEST_ROOT/reinstall-output"
assert_contains "ZCR_ROUTER_ACTION=upgrade" "$TEST_ROOT/reinstall-output"
assert_contains "ZCR_SOURCE=$(cat "$marketplace_state")" "$TEST_ROOT/reinstall-output"

# Without a PATH CLI, Linux/macOS user-local discovery can supply a capable Codex executable.
home=$TEST_ROOT/discovery-home
discovery_user=$TEST_ROOT/discovery-user
mkdir -p "$home" "$discovery_user/.local/bin" "$discovery_user/path-bin"
cp "$fake" "$discovery_user/.local/bin/codex"
printf '#!/usr/bin/env sh\nexit 2\n' >"$discovery_user/path-bin/codex"
chmod 700 "$discovery_user/path-bin/codex"
PATH=$discovery_user/path-bin:/usr/bin:/bin HOME=$discovery_user sh "$INSTALLER" --source "$ROOT" \
  --codex-home "$home" >"$TEST_ROOT/discovery-output"
assert_contains "ZCR_CODEX_SOURCE=user-local" "$TEST_ROOT/discovery-output"
assert_contains "ZCR_ENABLED=false" "$TEST_ROOT/discovery-output"

# Registration failure occurs after read-only preflight and preserves Router user files.
home=$TEST_ROOT/registration-failure
mkdir -p "$home"
printf 'user agents\n' >"$home/AGENTS.md"
cp "$home/AGENTS.md" "$TEST_ROOT/registration-agents"
if FAKE_CODEX_FAIL=1 sh "$INSTALLER" --source "$ROOT" --codex-home "$home" \
  --codex-bin "$fake" --enable >"$TEST_ROOT/failure-output" 2>"$TEST_ROOT/failure-error"; then
  fail "registration failure unexpectedly succeeded"
fi
assert_contains "E_CODEX_REGISTRATION" "$TEST_ROOT/failure-error"
cmp "$TEST_ROOT/registration-agents" "$home/AGENTS.md" ||
  fail "registration failure changed AGENTS.md"
pass
[ ! -e "$home/z-codex-router/current" ] || fail "registration failure enabled Router"
pass

# A post-write Doctor failure rolls Router user files back to their exact pre-install bytes.
home=$TEST_ROOT/doctor-failure
mkdir -p "$home"
printf 'user agents before Doctor\n' >"$home/AGENTS.md"
printf 'project_doc_max_bytes = 64\n' >"$home/config.toml"
cp "$home/AGENTS.md" "$TEST_ROOT/doctor-failure-agents"
if sh "$INSTALLER" --source "$ROOT" --codex-home "$home" \
  --codex-bin "$fake" --enable >"$TEST_ROOT/doctor-failure-output" \
  2>"$TEST_ROOT/doctor-failure-error"; then
  fail "post-write Doctor failure unexpectedly succeeded"
fi
assert_contains "E_ROUTER_VALIDATION" "$TEST_ROOT/doctor-failure-error"
cmp "$TEST_ROOT/doctor-failure-agents" "$home/AGENTS.md" ||
  fail "Doctor failure rollback changed user AGENTS.md"
pass
[ ! -e "$home/z-codex-router/current" ] || fail "Doctor failure left Router enabled"
pass

# Global override and legacy state fail before Codex registration.
home=$TEST_ROOT/override
mkdir -p "$home"
printf 'override\n' >"$home/AGENTS.override.md"
: >"$TEST_ROOT/override-log"
if FAKE_CODEX_LOG=$TEST_ROOT/override-log sh "$INSTALLER" --source "$ROOT" \
  --codex-home "$home" --codex-bin "$fake" --enable >/dev/null 2>"$TEST_ROOT/override-error"; then
  fail "override preflight unexpectedly succeeded"
fi
assert_contains "E_ROUTER_PREFLIGHT" "$TEST_ROOT/override-error"
[ ! -s "$TEST_ROOT/override-log" ] || fail "Codex was called after blocked preflight"
pass

home=$TEST_ROOT/legacy
mkdir -p "$home/z-codex-router"
printf '{}\n' >"$home/z-codex-router/current.json"
: >"$TEST_ROOT/legacy-log"
if FAKE_CODEX_LOG=$TEST_ROOT/legacy-log sh "$INSTALLER" --source "$ROOT" \
  --codex-home "$home" --codex-bin "$fake" --enable >/dev/null 2>"$TEST_ROOT/legacy-error"; then
  fail "legacy preflight unexpectedly succeeded"
fi
assert_contains "NEXT_1=install.sh --legacy-cleanup-dry-run" "$TEST_ROOT/legacy-error"
[ ! -s "$TEST_ROOT/legacy-log" ] || fail "Codex was called after legacy preflight"
pass
