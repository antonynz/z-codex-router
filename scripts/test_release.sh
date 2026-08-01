#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/zcr-release-tests.XXXXXX")
VERSION=$(sed -n 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
  "$ROOT/plugins/z-codex-router/release/manifest.json" | sed -n '1p')

cleanup() {
  status=$?
  rm -rf -- "$TEST_ROOT"
  exit "$status"
}
trap cleanup 0
trap 'exit 130' HUP INT TERM

sh "$ROOT/scripts/package_release.sh" --out "$TEST_ROOT/dist" >"$TEST_ROOT/package-output"
tar_asset=$TEST_ROOT/dist/z-codex-router-$VERSION.tar.gz
zip_asset=$TEST_ROOT/dist/z-codex-router-$VERSION.zip
[ -f "$tar_asset" ] && [ -f "$zip_asset" ] && [ -f "$TEST_ROOT/dist/SHA256SUMS" ]

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print tolower($1)}'
  else
    shasum -a 256 "$1" | awk '{print tolower($1)}'
  fi
}

grep -F "$(sha256 "$tar_asset")  $(basename "$tar_asset")" "$TEST_ROOT/dist/SHA256SUMS" >/dev/null
grep -F "$(sha256 "$zip_asset")  $(basename "$zip_asset")" "$TEST_ROOT/dist/SHA256SUMS" >/dev/null

mkdir -p "$TEST_ROOT/tar"
tar -xzf "$tar_asset" -C "$TEST_ROOT/tar"
mkdir -p "$TEST_ROOT/zip"
unzip -q "$zip_asset" -d "$TEST_ROOT/zip"

hash_tree() {
  root=$1
  output=$2
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
  ) >"$output"
}

hash_tree "$TEST_ROOT/tar/z-codex-router-$VERSION" "$TEST_ROOT/tar-tree"
hash_tree "$TEST_ROOT/zip/z-codex-router-$VERSION" "$TEST_ROOT/zip-tree"
cmp "$TEST_ROOT/tar-tree" "$TEST_ROOT/zip-tree"

tar_root=$TEST_ROOT/tar/z-codex-router-$VERSION
home=$TEST_ROOT/home
mkdir -p "$home"
sh -n "$tar_root/install.sh"
sh -n "$tar_root/zcr"
sh -n "$tar_root/plugins/z-codex-router/scripts/routerctl.sh"
sh "$tar_root/plugins/z-codex-router/scripts/routerctl.sh" \
  --source "$tar_root/plugins/z-codex-router" --codex-home "$home" dry-run \
  >"$TEST_ROOT/smoke"
grep -F 'code=OK_DRY_RUN' "$TEST_ROOT/smoke" >/dev/null
grep -F 'z-codex-router-entrypoint-v1' "$tar_root/zcr" >/dev/null
grep -F 'z-codex-router-entrypoint-v1' "$tar_root/zcr.ps1" >/dev/null
grep -F 'z-codex-router-entrypoint-v1' "$tar_root/zcr.cmd" >/dev/null

if command -v pwsh >/dev/null 2>&1; then
  pwsh -NoProfile -File "$tar_root/plugins/z-codex-router/scripts/routerctl.ps1" \
    --source "$tar_root/plugins/z-codex-router" --codex-home "$TEST_ROOT/ps-home" dry-run \
    >"$TEST_ROOT/ps-smoke"
  grep -F 'code=OK_DRY_RUN' "$TEST_ROOT/ps-smoke" >/dev/null
fi

printf 'PASS test_release.sh (tar/zip content parity and extracted smoke)\n'
