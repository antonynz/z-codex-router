#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
ROUTER=$ROOT/plugins/z-codex-router/scripts/routerctl.sh
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/zcr-router-tests.XXXXXX")
PASSED=0

cleanup() {
  status=$?
  rm -rf -- "$TEST_ROOT"
  if [ "$status" -eq 0 ]; then
    printf 'PASS test_routerctl.sh (%s assertions)\n' "$PASSED"
  fi
  exit "$status"
}
trap cleanup 0
trap 'exit 130' HUP INT TERM

pass() {
  PASSED=$((PASSED + 1))
}

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_file_equal() {
  cmp "$1" "$2" || fail "files differ: $1 $2"
  pass
}

assert_contains() {
  pattern=$1
  file=$2
  grep -F "$pattern" "$file" >/dev/null || fail "missing '$pattern' in $file"
  pass
}

expect_fail() {
  expected=$1
  shift
  output=$TEST_ROOT/expect.out
  error=$TEST_ROOT/expect.err
  if "$@" >"$output" 2>"$error"; then
    fail "command unexpectedly succeeded: $*"
  fi
  assert_contains "$expected" "$error"
}

run_router() {
  home=$1
  shift
  sh "$ROUTER" --codex-home "$home" "$@"
}

tree_hash() {
  root=$1
  manifest=$TEST_ROOT/tree-hash.txt
  (
    CDPATH= cd -- "$root"
    find . -type f -print | LC_ALL=C sort |
      while IFS= read -r relative; do
        clean=${relative#./}
        if command -v sha256sum >/dev/null 2>&1; then
          hash=$(sha256sum "$clean" | awk '{print tolower($1)}')
        else
          hash=$(shasum -a 256 "$clean" | awk '{print tolower($1)}')
        fi
        printf '%s  %s\n' "$hash" "$clean"
      done
  ) >"$manifest"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$manifest" | awk '{print tolower($1)}'
  else
    shasum -a 256 "$manifest" | awk '{print tolower($1)}'
  fi
}

sha_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print tolower($1)}'
  else
    shasum -a 256 "$1" | awk '{print tolower($1)}'
  fi
}

# Fresh install, managed prefix, no-change, and idempotent uninstall.
home=$TEST_ROOT/basic
mkdir -p "$home"
run_router "$home" dry-run >"$TEST_ROOT/basic-dry"
assert_contains "code=OK_DRY_RUN" "$TEST_ROOT/basic-dry"
run_router "$home" install >"$TEST_ROOT/basic-install"
assert_contains "code=OK_ENABLED" "$TEST_ROOT/basic-install"
run_router "$home" install >"$TEST_ROOT/basic-repeat"
assert_contains "code=OK_NO_CHANGE" "$TEST_ROOT/basic-repeat"
run_router "$home" doctor --cwd "$home" >"$TEST_ROOT/basic-doctor"
assert_contains "managed_block_start=0" "$TEST_ROOT/basic-doctor"
assert_contains "code=OK_ENABLED" "$TEST_ROOT/basic-doctor"
run_router "$home" uninstall >"$TEST_ROOT/basic-uninstall"
assert_contains "code=OK_UNINSTALLED" "$TEST_ROOT/basic-uninstall"
run_router "$home" uninstall >"$TEST_ROOT/basic-uninstall-repeat"
assert_contains "changed=false" "$TEST_ROOT/basic-uninstall-repeat"

# The lifecycle names are explicit, status is actionable, and a disabled Router
# keeps the user's profile intact while allowing a no-TOML re-enable.
home=$TEST_ROOT/lifecycle
mkdir -p "$home"
run_router "$home" profile set B2 gpt-5.6-terra high >"$TEST_ROOT/lifecycle-profile"
assert_contains "tier=B2" "$TEST_ROOT/lifecycle-profile"
cp "$home/z-codex-router-profile.toml" "$TEST_ROOT/lifecycle-profile-original"
run_router "$home" enable >"$TEST_ROOT/lifecycle-enable"
assert_contains "code=OK_ENABLED" "$TEST_ROOT/lifecycle-enable"
run_router "$home" status >"$TEST_ROOT/lifecycle-status"
assert_contains "code=OK_STATUS" "$TEST_ROOT/lifecycle-status"
assert_contains "state=enabled" "$TEST_ROOT/lifecycle-status"
run_router "$home" disable >"$TEST_ROOT/lifecycle-disable"
assert_contains "code=OK_DISABLED" "$TEST_ROOT/lifecycle-disable"
assert_contains "next_command=zcr status" "$TEST_ROOT/lifecycle-disable"
assert_file_equal "$TEST_ROOT/lifecycle-profile-original" "$home/z-codex-router-profile.toml"
run_router "$home" enable >"$TEST_ROOT/lifecycle-reenable"
assert_contains "code=OK_ENABLED" "$TEST_ROOT/lifecycle-reenable"
run_router "$home" uninstall >"$TEST_ROOT/lifecycle-uninstall"
assert_contains "profile_preserved=true" "$TEST_ROOT/lifecycle-uninstall"
assert_file_equal "$TEST_ROOT/lifecycle-profile-original" "$home/z-codex-router-profile.toml"
run_router "$home" uninstall --purge-profile >"$TEST_ROOT/lifecycle-purge"
assert_contains "profile_purge_state=purged" "$TEST_ROOT/lifecycle-purge"
[ ! -e "$home/z-codex-router-profile.toml" ] || fail "purge profile left an override"
pass
profile_backup=$(sed -n 's/^profile_backup=//p' "$TEST_ROOT/lifecycle-purge")
[ -f "$profile_backup" ] && [ -f "$profile_backup.sha256" ] || fail "purge profile backup is missing"
pass
expect_fail E_PROFILE_OVERRIDE_INVALID run_router "$home" profile set BAD gpt-5.6-terra high
assert_contains "code=E_PROFILE_OVERRIDE_INVALID" "$TEST_ROOT/expect.err"
assert_contains "state=profile-needs-attention" "$TEST_ROOT/expect.err"
assert_contains "impact=profile-not-modified" "$TEST_ROOT/expect.err"
assert_contains "retry_safe=true" "$TEST_ROOT/expect.err"
assert_contains "next_command=zcr profile show" "$TEST_ROOT/expect.err"

# UTF-8 BOM, CRLF, multibyte user content, and post-install edits survive uninstall byte-for-byte.
home=$TEST_ROOT/bytes
mkdir -p "$home"
printf '\357\273\277用户原文\r\nsecond\r\n' >"$home/AGENTS.md"
cp "$home/AGENTS.md" "$TEST_ROOT/bytes-original"
run_router "$home" install >/dev/null
run_router "$home" doctor --cwd "$home" >"$TEST_ROOT/bytes-doctor"
assert_contains "managed_block_start=3" "$TEST_ROOT/bytes-doctor"
printf '安装后追加\r\n' >>"$home/AGENTS.md"
run_router "$home" uninstall >/dev/null
{
  cat "$TEST_ROOT/bytes-original"
  printf '安装后追加\r\n'
} >"$TEST_ROOT/bytes-expected"
assert_file_equal "$TEST_ROOT/bytes-expected" "$home/AGENTS.md"

# Non-empty global override blocks writes and remains unchanged.
home=$TEST_ROOT/override
mkdir -p "$home"
printf 'user override\n' >"$home/AGENTS.override.md"
cp "$home/AGENTS.override.md" "$TEST_ROOT/override-original"
expect_fail E_GLOBAL_OVERRIDE_ACTIVE run_router "$home" dry-run
assert_file_equal "$TEST_ROOT/override-original" "$home/AGENTS.override.md"
[ ! -e "$home/AGENTS.md" ] || fail "blocked install created AGENTS.md"
pass

# Large AGENTS content remains behind a readable prefix; a tiny effective budget fails closed.
home=$TEST_ROOT/budget
mkdir -p "$home"
awk 'BEGIN { for (i = 0; i < 5000; i++) print "用户内容-0123456789" }' >"$home/AGENTS.md"
cp "$home/AGENTS.md" "$TEST_ROOT/budget-original"
run_router "$home" install >/dev/null
run_router "$home" doctor --cwd "$home" >"$TEST_ROOT/budget-doctor"
block_end=$(sed -n 's/^managed_block_end=//p' "$TEST_ROOT/budget-doctor")
[ "$block_end" -lt 32768 ] || fail "managed prefix is outside the default budget"
pass
printf 'project_doc_max_bytes = 64\n' >"$home/config.toml"
expect_fail E_MANAGED_BLOCK_OUTSIDE_INSTRUCTION_BUDGET run_router "$home" doctor --cwd "$home"
rm "$home/config.toml"
run_router "$home" uninstall >/dev/null
assert_file_equal "$TEST_ROOT/budget-original" "$home/AGENTS.md"

# Project/nested instruction discovery is cwd-aware.
home=$TEST_ROOT/chain-home
project=$TEST_ROOT/project/a/b
mkdir -p "$home" "$project" "$TEST_ROOT/project/a/.codex"
printf 'root project\n' >"$TEST_ROOT/project/AGENTS.md"
printf 'nested project\n' >"$TEST_ROOT/project/a/AGENTS.override.md"
printf 'project_doc_max_bytes = 4096\n' >"$TEST_ROOT/project/a/.codex/config.toml"
run_router "$home" install >/dev/null
run_router "$home" doctor --cwd "$project" >"$TEST_ROOT/chain-doctor"
assert_contains "project_doc_max_bytes=4096" "$TEST_ROOT/chain-doctor"
assert_contains "project_instruction_count=2" "$TEST_ROOT/chain-doctor"

# Managed block drift and duplication fail closed without touching the file.
home=$TEST_ROOT/drift
mkdir -p "$home"
run_router "$home" install >/dev/null
printf '<!-- z-codex-router:begin duplicate -->\n' >>"$home/AGENTS.md"
cp "$home/AGENTS.md" "$TEST_ROOT/drifted"
expect_fail E_MANAGED_BLOCK_DRIFT run_router "$home" doctor
expect_fail E_MANAGED_BLOCK_DRIFT run_router "$home" uninstall
assert_file_equal "$TEST_ROOT/drifted" "$home/AGENTS.md"

# Profile init/set/validate/reset/restore is hash-managed and survives Router uninstall.
home=$TEST_ROOT/profile
mkdir -p "$home"
run_router "$home" profile init >"$TEST_ROOT/profile-init"
assert_contains "code=OK_PROFILE_INITIALIZED" "$TEST_ROOT/profile-init"
run_router "$home" profile set B0 gpt-5.6-luna high >"$TEST_ROOT/profile-set"
assert_contains "code=OK_PROFILE_SET" "$TEST_ROOT/profile-set"
run_router "$home" profile validate >"$TEST_ROOT/profile-validate"
assert_contains "B0|gpt-5.6-luna|high" "$TEST_ROOT/profile-validate"
cp "$home/z-codex-router-profile.toml" "$TEST_ROOT/profile-original"
run_router "$home" profile reset >"$TEST_ROOT/profile-reset"
backup=$(sed -n 's/^backup=//p' "$TEST_ROOT/profile-reset")
[ -f "$backup" ] || fail "profile reset backup is missing"
pass
run_router "$home" profile backups >"$TEST_ROOT/profile-backups"
assert_contains "code=OK_PROFILE_BACKUPS" "$TEST_ROOT/profile-backups"
assert_contains "next_command=zcr profile restore $backup" "$TEST_ROOT/profile-backups"
run_router "$home" profile restore "$backup" >"$TEST_ROOT/profile-restore"
assert_file_equal "$TEST_ROOT/profile-original" "$home/z-codex-router-profile.toml"
run_router "$home" install >/dev/null
run_router "$home" uninstall >/dev/null
assert_file_equal "$TEST_ROOT/profile-original" "$home/z-codex-router-profile.toml"
printf 'schema_version = 1\n[routing]\nA0 = { model = "wrong", effort = "wrong" }\n' \
  >"$home/z-codex-router-profile.toml"
expect_fail E_PROFILE_OVERRIDE_INVALID run_router "$home" profile validate

# Removed safe-auto surface never modifies config.toml.
home=$TEST_ROOT/safe-auto
mkdir -p "$home"
printf 'user_key = "keep"\n' >"$home/config.toml"
cp "$home/config.toml" "$TEST_ROOT/config-original"
expect_fail E_USAGE run_router "$home" safe-auto enable
assert_file_equal "$TEST_ROOT/config-original" "$home/config.toml"

# A pending transaction with exact before/after hashes recovers to the backup.
home=$TEST_ROOT/recover
mkdir -p "$home"
run_router "$home" install >/dev/null
backup=$(find "$home/z-codex-router/backups" -mindepth 1 -maxdepth 1 -type d -name 'backup-*' |
  LC_ALL=C sort | tail -1)
transaction=$home/z-codex-router/transaction
mkdir "$transaction"
printf '%s\n' install >"$transaction/action"
printf '%s\n' "$backup" >"$transaction/backup"
printf '%s\n' absent >"$transaction/agents_before_sha256"
printf '%s\n' "$(sha_file "$home/AGENTS.md")" >"$transaction/agents_after_sha256"
printf '%s\n' absent >"$transaction/current_before_sha256"
printf '%s\n' "$(tree_hash "$home/z-codex-router/current")" >"$transaction/current_after_sha256"
printf '%s\n' absent >"$transaction/current_intermediate_sha256"
printf '%s\n' 1 >"$transaction/remove_version"
printf '%s\n' 1.1.0 >"$transaction/version"
printf '%s\n' 4242 >"$transaction/operation_id"
mv "$home/z-codex-router/current" "$home/z-codex-router/.current-previous-4242"
expect_fail E_TRANSACTION_PENDING run_router "$home" doctor
run_router "$home" recover >"$TEST_ROOT/recover-output"
assert_contains "code=OK_RECOVERED" "$TEST_ROOT/recover-output"
run_router "$home" doctor >"$TEST_ROOT/recover-doctor"
assert_contains "code=OK_NOT_ENABLED" "$TEST_ROOT/recover-doctor"

# Recover refuses unknown user drift and preserves it.
home=$TEST_ROOT/recover-drift
mkdir -p "$home"
run_router "$home" install >/dev/null
backup=$(find "$home/z-codex-router/backups" -mindepth 1 -maxdepth 1 -type d -name 'backup-*' |
  LC_ALL=C sort | tail -1)
transaction=$home/z-codex-router/transaction
mkdir "$transaction"
printf '%s\n' install >"$transaction/action"
printf '%s\n' "$backup" >"$transaction/backup"
printf '%s\n' absent >"$transaction/agents_before_sha256"
printf '%s\n' "$(sha_file "$home/AGENTS.md")" >"$transaction/agents_after_sha256"
printf '%s\n' absent >"$transaction/current_before_sha256"
printf '%s\n' "$(tree_hash "$home/z-codex-router/current")" >"$transaction/current_after_sha256"
printf '%s\n' absent >"$transaction/current_intermediate_sha256"
printf '%s\n' 0 >"$transaction/remove_version"
printf '%s\n' 1.1.0 >"$transaction/version"
printf '%s\n' 4343 >"$transaction/operation_id"
printf 'user drift\n' >>"$home/AGENTS.md"
cp "$home/AGENTS.md" "$TEST_ROOT/recover-drift-original"
expect_fail E_TRANSACTION_DRIFT run_router "$home" recover
assert_file_equal "$TEST_ROOT/recover-drift-original" "$home/AGENTS.md"
[ ! -e "$home/.z-codex-router.lock" ] || fail "failed recover left a stale operation lock"
pass

# Recover rejects a modified backup before changing live user files.
home=$TEST_ROOT/recover-backup-drift
mkdir -p "$home"
printf 'original user bytes\n' >"$home/AGENTS.md"
run_router "$home" install >"$TEST_ROOT/recover-backup-install"
backup=$(sed -n 's/^backup=//p' "$TEST_ROOT/recover-backup-install")
transaction=$home/z-codex-router/transaction
mkdir "$transaction"
printf '%s\n' install >"$transaction/action"
printf '%s\n' "$backup" >"$transaction/backup"
cp "$backup/agents.sha256" "$transaction/agents_before_sha256"
printf '%s\n' "$(sha_file "$home/AGENTS.md")" >"$transaction/agents_after_sha256"
cp "$backup/current.sha256" "$transaction/current_before_sha256"
printf '%s\n' absent >"$transaction/current_intermediate_sha256"
printf '%s\n' "$(tree_hash "$home/z-codex-router/current")" >"$transaction/current_after_sha256"
printf '%s\n' 0 >"$transaction/remove_version"
printf '%s\n' 1.1.0 >"$transaction/version"
printf '%s\n' 4444 >"$transaction/operation_id"
printf 'tampered backup\n' >>"$backup/AGENTS.md"
cp "$home/AGENTS.md" "$TEST_ROOT/recover-backup-live"
expect_fail E_TRANSACTION_INVALID run_router "$home" recover
assert_file_equal "$TEST_ROOT/recover-backup-live" "$home/AGENTS.md"
[ ! -e "$home/.z-codex-router.lock" ] || fail "backup validation failure left a stale lock"
pass

# Rollback to the pre-install state and rollback drift protection.
home=$TEST_ROOT/rollback
mkdir -p "$home"
printf 'before\n' >"$home/AGENTS.md"
cp "$home/AGENTS.md" "$TEST_ROOT/rollback-original"
run_router "$home" install >/dev/null
run_router "$home" rollback >"$TEST_ROOT/rollback-output"
assert_contains "code=OK_ROLLED_BACK" "$TEST_ROOT/rollback-output"
assert_file_equal "$TEST_ROOT/rollback-original" "$home/AGENTS.md"

home=$TEST_ROOT/rollback-drift
mkdir -p "$home"
run_router "$home" install >/dev/null
printf 'new user text\n' >>"$home/AGENTS.md"
cp "$home/AGENTS.md" "$TEST_ROOT/rollback-drift-original"
expect_fail E_ROLLBACK_DRIFT run_router "$home" rollback
assert_file_equal "$TEST_ROOT/rollback-drift-original" "$home/AGENTS.md"

# Explicit legacy cleanup checks identity, backs up config, preserves user AGENTS bytes, then permits fresh install.
home=$TEST_ROOT/legacy
mkdir -p "$home/z-codex-router"
legacy_hash=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
printf 'legacy user\n\n' >"$home/AGENTS.md"
printf '<!-- z-codex-router:begin id=z-codex-router version=1.0.3 sha256=%s protocol=1 agents_existed_before=true separator=one-newline -->\n' \
  "$legacy_hash" >>"$home/AGENTS.md"
printf '# old managed\n%s' '<!-- z-codex-router:end id=z-codex-router -->' >>"$home/AGENTS.md"
printf '{\n  "version": "1.0.3",\n  "payload_sha256": "%s"\n}\n' "$legacy_hash" \
  >"$home/z-codex-router/current.json"
printf 'user_config = true\n' >"$home/config.toml"
cp "$home/config.toml" "$TEST_ROOT/legacy-config"
printf 'legacy user\n' >"$TEST_ROOT/legacy-agents-expected"
expect_fail E_LEGACY_INSTALL_DETECTED run_router "$home" dry-run
run_router "$home" legacy-cleanup --dry-run >"$TEST_ROOT/legacy-dry"
assert_contains "code=OK_LEGACY_CLEANUP_DRY_RUN" "$TEST_ROOT/legacy-dry"
run_router "$home" legacy-cleanup >"$TEST_ROOT/legacy-clean"
assert_contains "code=OK_LEGACY_CLEANED" "$TEST_ROOT/legacy-clean"
assert_file_equal "$TEST_ROOT/legacy-config" "$home/config.toml"
assert_file_equal "$TEST_ROOT/legacy-agents-expected" "$home/AGENTS.md"
run_router "$home" install >/dev/null
run_router "$home" doctor >"$TEST_ROOT/legacy-fresh"
assert_contains "code=OK_ENABLED" "$TEST_ROOT/legacy-fresh"

# Legacy safe-auto and legacy transaction states are never guessed or deleted.
home=$TEST_ROOT/legacy-safe
mkdir -p "$home/z-codex-router"
printf '{}\n' >"$home/z-codex-router/safe-auto.json"
expect_fail E_LEGACY_SAFE_AUTO_STATE run_router "$home" legacy-cleanup
[ -f "$home/z-codex-router/safe-auto.json" ] || fail "legacy safe-auto state was deleted"
pass

home=$TEST_ROOT/legacy-transaction
mkdir -p "$home/z-codex-router"
printf '{}\n' >"$home/z-codex-router/transaction.json"
expect_fail E_LEGACY_TRANSACTION_PENDING run_router "$home" legacy-cleanup
[ -f "$home/z-codex-router/transaction.json" ] || fail "legacy transaction was deleted"
pass

# Source validation requires every mode/role/skill and a disabled candidate profile.
home=$TEST_ROOT/source-boundary
source_invalid=$TEST_ROOT/source-invalid
mkdir -p "$home" "$source_invalid"
cp -R "$ROOT/plugins/z-codex-router" "$source_invalid/"
sed 's/^enabled = false$/enabled = true/' \
  "$source_invalid/z-codex-router/profiles/candidate/example-next-model.toml" \
  >"$source_invalid/candidate.toml"
mv "$source_invalid/candidate.toml" \
  "$source_invalid/z-codex-router/profiles/candidate/example-next-model.toml"
expect_fail E_SOURCE_INVALID sh \
  "$source_invalid/z-codex-router/scripts/routerctl.sh" \
  --source "$source_invalid/z-codex-router" --codex-home "$home" dry-run

# Same public version may upgrade through an explicit local cache build identity.
home=$TEST_ROOT/cache-build
source_copy=$TEST_ROOT/source-copy
mkdir -p "$home" "$source_copy"
cp -R "$ROOT/plugins/z-codex-router" "$source_copy/"
run_router "$home" profile set B2 gpt-5.6-terra high >/dev/null
cp "$home/z-codex-router-profile.toml" "$TEST_ROOT/cache-profile-original"
run_router "$home" install >/dev/null
awk '
  !done && $0 ~ /^[[:space:]]*"version"[[:space:]]*:/ {
    print "  \"version\": \"1.1.0+codex.test-build\","
    done = 1
    next
  }
  { print }
' "$source_copy/z-codex-router/.codex-plugin/plugin.json" >"$source_copy/plugin.json"
mv "$source_copy/plugin.json" "$source_copy/z-codex-router/.codex-plugin/plugin.json"
sh "$source_copy/z-codex-router/scripts/routerctl.sh" --source "$source_copy/z-codex-router" \
  --codex-home "$home" upgrade >"$TEST_ROOT/cache-upgrade"
assert_contains "version=1.1.0+codex.test-build" "$TEST_ROOT/cache-upgrade"
assert_file_equal "$TEST_ROOT/cache-profile-original" "$home/z-codex-router-profile.toml"
run_router "$home" doctor >"$TEST_ROOT/cache-doctor"
assert_contains "version=1.1.0+codex.test-build" "$TEST_ROOT/cache-doctor"
