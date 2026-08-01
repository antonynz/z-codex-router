#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
OUT=$ROOT/dist

read_manifest_version() {
  manifest=$1
  sed -n 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$manifest" |
    sed -n '1p'
}

VERSION=$(read_manifest_version "$ROOT/plugins/z-codex-router/release/manifest.json")
printf '%s\n' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || {
  printf 'E_RELEASE_VERSION: release manifest has an invalid version\n' >&2
  exit 1
}

usage() {
  printf 'Usage: package_release.sh [--out PATH]\n'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --out)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      OUT=$2
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

case "$OUT" in /*) ;; *) OUT=$(pwd -P)/$OUT ;; esac
WORK=$(mktemp -d "${TMPDIR:-/tmp}/zcr-package.XXXXXX")
cleanup() {
  status=$?
  rm -rf -- "$WORK"
  exit "$status"
}
trap cleanup 0
trap 'exit 130' HUP INT TERM

stage=$WORK/z-codex-router-$VERSION
mkdir -p "$stage"
for entry in \
  .agents \
  .gitattributes \
  .github \
  .gitignore \
  AGENT_INSTALL.md \
  CHANGELOG.md \
  CONTRIBUTING.md \
  LICENSE \
  README.md \
  README.en.md \
  RELEASE_NOTES.md \
  SECURITY.md \
  docs \
  install.ps1 \
  install.sh \
  zcr \
  zcr.ps1 \
  zcr.cmd \
  plugins \
  scripts \
  submission; do
  [ -e "$ROOT/$entry" ] || continue
  cp -R "$ROOT/$entry" "$stage/"
done

find "$stage" -name '.DS_Store' -type f -delete
find "$stage" -type d -empty -delete

release_version=$(sed -n 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
  "$stage/plugins/z-codex-router/release/manifest.json" | sed -n '1p')
plugin_version=$(sed -n 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
  "$stage/plugins/z-codex-router/.codex-plugin/plugin.json" | sed -n '1p')
[ "$release_version" = "$VERSION" ] && [ "$plugin_version" = "$VERSION" ] || {
  printf 'E_RELEASE_VERSION: package manifest version drift (expected %s)\n' "$VERSION" >&2
  exit 1
}
install_sh_version=$(sed -n 's/^VERSION=\([0-9][0-9.]*\)$/\1/p' "$stage/install.sh" | sed -n '1p')
install_ps_version=$(sed -n 's/^[[:space:]]*\[string\]\$Version[[:space:]]*=[[:space:]]*"\([0-9.]*\)".*/\1/p' "$stage/install.ps1" | sed -n '1p')
router_sh_version=$(sed -n 's/^PUBLIC_VERSION=\([0-9][0-9.]*\)$/\1/p' \
  "$stage/plugins/z-codex-router/scripts/routerctl.sh" | sed -n '1p')
router_ps_version=$(sed -n 's/^[[:space:]]*\$script:PublicVersion[[:space:]]*=[[:space:]]*"\([0-9.]*\)".*/\1/p' \
  "$stage/plugins/z-codex-router/scripts/routerctl.ps1" | sed -n '1p')
[ "$install_sh_version" = "$VERSION" ] && [ "$install_ps_version" = "$VERSION" ] && \
  [ "$router_sh_version" = "$VERSION" ] && [ "$router_ps_version" = "$VERSION" ] || {
  printf 'E_RELEASE_VERSION: installer or controller version drift (expected %s)\n' "$VERSION" >&2
  exit 1
}

sh "$ROOT/scripts/verify_source.sh"
mkdir -p "$OUT"
tar_asset=$OUT/z-codex-router-$VERSION.tar.gz
zip_asset=$OUT/z-codex-router-$VERSION.zip
rm -f "$tar_asset" "$zip_asset" "$OUT/SHA256SUMS"

(
  CDPATH= cd -- "$WORK"
  COPYFILE_DISABLE=1 tar -czf "$tar_asset" "z-codex-router-$VERSION"
  zip -X -q -r "$zip_asset" "z-codex-router-$VERSION"
)

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print tolower($1)}'
  else
    shasum -a 256 "$1" | awk '{print tolower($1)}'
  fi
}

{
  printf '%s  %s\n' "$(sha256 "$tar_asset")" "$(basename "$tar_asset")"
  printf '%s  %s\n' "$(sha256 "$zip_asset")" "$(basename "$zip_asset")"
} >"$OUT/SHA256SUMS"

printf '%s\n' "ZCR_TAR=$tar_asset" "ZCR_ZIP=$zip_asset" "ZCR_SUMS=$OUT/SHA256SUMS"
