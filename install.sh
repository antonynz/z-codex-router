#!/usr/bin/env sh
set -eu

REPOSITORY="antonynz/z-codex-router"
PLUGIN_NAME="z-codex-router"
MARKETPLACE_NAME="z-codex-router"
VERSION="latest"
BASE_URL="${ZCR_BASE_URL:-}"
ENABLE=0
CODEX_BIN="${CODEX_BIN:-codex}"
CODEX_HOME_ARG="${CODEX_HOME:-}"
RESOLVE_OS=""
RESOLVE_ARCH=""
WORK_DIR=""
SOURCE_ROOT=""
VERSION_ROOT=""
BACKUP_ROOT=""

usage() {
  cat <<'EOF'
Usage: install.sh [--enable] [--version VERSION] [--base-url HTTPS_URL]
                  [--codex-home PATH] [--codex-bin PATH]

Installs the matching prebuilt Z Codex Router plugin from GitHub Releases.
Global routing is changed only when --enable is present.
EOF
}

fail() {
  printf '%s\n' "$*" >&2
  exit 1
}

need_command() {
  command -v "$1" >/dev/null 2>&1 || fail "E_PREREQUISITE: missing command: $1"
}

resolve_platform() {
  raw_os=$1
  raw_arch=$2
  case "$raw_os" in
    Darwin|darwin|macOS|macos) platform=darwin ;;
    Linux|linux) platform=linux ;;
    Windows_NT|windows|Windows) platform=windows ;;
    *) fail "E_PLATFORM_UNSUPPORTED: $raw_os" ;;
  esac
  case "$raw_arch" in
    arm64|aarch64|ARM64|AARCH64) architecture=arm64 ;;
    x86_64|amd64|AMD64|X64|x64) architecture=amd64 ;;
    *) fail "E_ARCH_UNSUPPORTED: $raw_arch" ;;
  esac
  printf '%s-%s\n' "$platform" "$architecture"
}

valid_version() {
  printf '%s\n' "$1" |
    LC_ALL=C grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$'
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print tolower($1)}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print tolower($1)}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "$1" | awk '{print tolower($NF)}'
  else
    fail "E_PREREQUISITE: need sha256sum, shasum, or openssl"
  fi
}

download_https() {
  url=$1
  destination=$2
  case "$url" in
    https://*) ;;
    *) fail "E_URL_INSECURE: only HTTPS URLs are accepted" ;;
  esac
  curl --fail --silent --show-error --location \
    --proto '=https' --proto-redir '=https' --tlsv1.2 \
    --max-redirs 5 --output "$destination" "$url"
}

expected_checksum() {
  sums_file=$1
  asset_name=$2
  awk -v wanted="$asset_name" '
    {
      name = $2
      sub(/^\*/, "", name)
      if (name == wanted) {
        count += 1
        hash = tolower($1)
      }
    }
    END {
      if (count != 1 || hash !~ /^[0-9a-f]{64}$/) {
        exit 1
      }
      print hash
    }
  ' "$sums_file" || fail "E_CHECKSUM_ENTRY: expected one exact checksum for $asset_name"
}

verify_checksum() {
  file=$1
  expected=$2
  actual=$(sha256_file "$file")
  [ "$actual" = "$expected" ] ||
    fail "E_CHECKSUM_MISMATCH: $(basename "$file")"
}

validate_archive() {
  archive=$1
  platform_token=$2
  architecture_token=$3
  list_file=$4
  verbose_file=$5

  tar -tzf "$archive" >"$list_file" ||
    fail "E_ARCHIVE_INVALID: cannot list archive"
  [ -s "$list_file" ] || fail "E_ARCHIVE_INVALID: archive is empty"

  while IFS= read -r entry; do
    case "$entry" in
      ""|/*|*\\*|*'	'*|*" "*) fail "E_ARCHIVE_PATH: unsafe entry: $entry" ;;
    esac
    printf '%s\n' "$entry" |
      LC_ALL=C grep -Eq '^[A-Za-z0-9._/-]+$' ||
      fail "E_ARCHIVE_PATH: unsupported entry name"
    case "/$entry/" in
      *"/../"*) fail "E_ARCHIVE_PATH: traversal entry: $entry" ;;
    esac
  done <"$list_file"

  duplicate=$(LC_ALL=C sort "$list_file" | uniq -d | sed -n '1p')
  [ -z "$duplicate" ] || fail "E_ARCHIVE_PATH: duplicate entry: $duplicate"

  tar -tvzf "$archive" >"$verbose_file" ||
    fail "E_ARCHIVE_INVALID: cannot inspect archive types"
  while IFS= read -r detail; do
    type=$(printf '%s' "$detail" | cut -c 1)
    case "$type" in
      -|d) ;;
      *) fail "E_ARCHIVE_TYPE: links and special files are rejected" ;;
    esac
  done <"$verbose_file"

  grep -Fx '.agents/plugins/marketplace.json' "$list_file" >/dev/null ||
    fail "E_ARCHIVE_LAYOUT: marketplace manifest is missing"
  grep -Fx 'plugins/z-codex-router/.codex-plugin/plugin.json' "$list_file" >/dev/null ||
    fail "E_ARCHIVE_LAYOUT: plugin manifest is missing"
  grep -Fx 'plugins/z-codex-router/release/manifest.json' "$list_file" >/dev/null ||
    fail "E_ARCHIVE_LAYOUT: release manifest is missing"
  grep -Fx "plugins/z-codex-router/bin/routerctl-$platform_token-$architecture_token" "$list_file" >/dev/null ||
    fail "E_ARCHIVE_LAYOUT: matching routerctl binary is missing"
}

same_tree() {
  left=$1
  right=$2
  [ -z "$(find "$right" -type l -print -quit)" ] &&
    diff -qr "$left" "$right" >/dev/null 2>&1 &&
    [ -x "$right/plugins/z-codex-router/scripts/routerctl.sh" ] &&
    [ -x "$right/plugins/z-codex-router/bin/routerctl-$PLATFORM-$ARCHITECTURE" ]
}

ensure_managed_directory() {
  directory=$1
  if [ -L "$directory" ]; then
    fail "E_PATH_INVALID: managed directories cannot be symbolic links"
  fi
  mkdir -p "$directory"
  resolved_directory=$(CDPATH= cd -- "$directory" && pwd -P)
  case "$resolved_directory/" in
    "$CODEX_HOME_ARG/"*) ;;
    *) fail "E_PATH_INVALID: managed directory escapes CODEX_HOME" ;;
  esac
}

run_codex() {
  CODEX_HOME="$CODEX_HOME_ARG" "$CODEX_BIN" "$@"
}

run_routerctl() {
  launcher="$SOURCE_ROOT/plugins/z-codex-router/scripts/routerctl.sh"
  CODEX_HOME="$CODEX_HOME_ARG" "$launcher" --codex-home "$CODEX_HOME_ARG" "$@"
}

cleanup() {
  status=$?
  if [ "$status" -ne 0 ] && [ -n "$BACKUP_ROOT" ] && [ -d "$BACKUP_ROOT" ]; then
    failed_root="${SOURCE_ROOT}.failed-$$"
    if [ -d "$SOURCE_ROOT" ]; then
      mv "$SOURCE_ROOT" "$failed_root" 2>/dev/null || true
    fi
    mv "$BACKUP_ROOT" "$SOURCE_ROOT" 2>/dev/null || true
  fi
  if [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ]; then
    rm -rf -- "$WORK_DIR"
  fi
  exit "$status"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --enable) ENABLE=1; shift ;;
    --version)
      [ "$#" -ge 2 ] || fail "E_USAGE: --version needs a value"
      VERSION=$2
      shift 2
      ;;
    --base-url)
      [ "$#" -ge 2 ] || fail "E_USAGE: --base-url needs a value"
      BASE_URL=$2
      shift 2
      ;;
    --codex-home)
      [ "$#" -ge 2 ] || fail "E_USAGE: --codex-home needs a value"
      CODEX_HOME_ARG=$2
      shift 2
      ;;
    --codex-bin)
      [ "$#" -ge 2 ] || fail "E_USAGE: --codex-bin needs a value"
      CODEX_BIN=$2
      shift 2
      ;;
    --resolve-platform)
      [ "$#" -ge 3 ] || fail "E_USAGE: --resolve-platform needs OS and ARCH"
      RESOLVE_OS=$2
      RESOLVE_ARCH=$3
      shift 3
      ;;
    -h|--help) usage; exit 0 ;;
    *) fail "E_USAGE: unknown argument: $1" ;;
  esac
done

if [ -n "$RESOLVE_OS" ]; then
  resolve_platform "$RESOLVE_OS" "$RESOLVE_ARCH"
  exit 0
fi

[ "$VERSION" = "latest" ] || valid_version "$VERSION" ||
  fail "E_VERSION_INVALID: expected a semantic version without a leading v"

if [ -z "$BASE_URL" ]; then
  if [ "$VERSION" = "latest" ]; then
    BASE_URL="https://github.com/$REPOSITORY/releases/latest/download"
  else
    BASE_URL="https://github.com/$REPOSITORY/releases/download/v$VERSION"
  fi
fi
BASE_URL=${BASE_URL%/}
case "$BASE_URL" in
  https://*) ;;
  *) fail "E_URL_INSECURE: --base-url must use HTTPS" ;;
esac

need_command uname
need_command curl
need_command tar
need_command awk
need_command grep
need_command sed
need_command sort
need_command uniq
need_command diff
need_command find
need_command cp
need_command cut
need_command tr
need_command mktemp
need_command wc

platform_pair=$(resolve_platform "$(uname -s)" "$(uname -m)")
PLATFORM=${platform_pair%-*}
ARCHITECTURE=${platform_pair#*-}
[ "$PLATFORM" != "windows" ] ||
  fail "E_PLATFORM_UNSUPPORTED: use install.ps1 on Windows"

command -v "$CODEX_BIN" >/dev/null 2>&1 ||
  fail "E_CODEX_MISSING: install the Codex CLI first"
"$CODEX_BIN" plugin marketplace add --help >/dev/null 2>&1 ||
  fail "E_CODEX_CAPABILITY: marketplace add is unavailable"
"$CODEX_BIN" plugin add --help >/dev/null 2>&1 ||
  fail "E_CODEX_CAPABILITY: plugin add is unavailable"

if [ -z "$CODEX_HOME_ARG" ]; then
  [ -n "${HOME:-}" ] || fail "E_CODEX_HOME_REQUIRED: set HOME or CODEX_HOME"
  CODEX_HOME_ARG="$HOME/.codex"
fi
case "$CODEX_HOME_ARG" in
  /*) ;;
  *) fail "E_CODEX_HOME_INVALID: use an absolute path" ;;
esac
case "/$CODEX_HOME_ARG/" in
  *"/../"*) fail "E_CODEX_HOME_INVALID: paths containing .. are rejected" ;;
esac
[ "$CODEX_HOME_ARG" != "/" ] || fail "E_CODEX_HOME_INVALID: root is unsafe"

umask 077
mkdir -p "$CODEX_HOME_ARG"
CODEX_HOME_ARG=$(CDPATH= cd -- "$CODEX_HOME_ARG" && pwd -P)
[ "$CODEX_HOME_ARG" != "/" ] || fail "E_CODEX_HOME_INVALID: root is unsafe"
if [ -n "${HOME:-}" ] && [ -d "$HOME" ]; then
  RESOLVED_USER_HOME=$(CDPATH= cd -- "$HOME" && pwd -P)
  [ "$RESOLVED_USER_HOME" != "$CODEX_HOME_ARG" ] ||
    fail "E_CODEX_HOME_INVALID: the user home itself is unsafe"
fi
WORK_DIR=$(mktemp -d "$CODEX_HOME_ARG/.zcr-install.XXXXXX")
trap cleanup 0
trap 'exit 130' HUP INT TERM

ASSET="z-codex-router-$PLATFORM-$ARCHITECTURE.tar.gz"
SUMS_FILE="$WORK_DIR/SHA256SUMS"
download_https "$BASE_URL/SHA256SUMS" "$SUMS_FILE"
DOWNLOADED_BYTES=$(wc -c <"$SUMS_FILE" | tr -d ' ')
EXPECTED=$(expected_checksum "$SUMS_FILE" "$ASSET")

CACHE_DIR="$CODEX_HOME_ARG/z-codex-router-downloads"
CACHE_ARCHIVE="$CACHE_DIR/$ASSET"
ensure_managed_directory "$CACHE_DIR"
[ ! -L "$CACHE_ARCHIVE" ] ||
  fail "E_PATH_INVALID: cached archive cannot be a symbolic link"
CACHE_HIT=false
if [ -f "$CACHE_ARCHIVE" ] &&
  [ "$(sha256_file "$CACHE_ARCHIVE")" = "$EXPECTED" ]; then
  CACHE_HIT=true
else
  ARCHIVE_DOWNLOAD="$WORK_DIR/$ASSET"
  download_https "$BASE_URL/$ASSET" "$ARCHIVE_DOWNLOAD"
  DOWNLOADED_BYTES=$((DOWNLOADED_BYTES + $(wc -c <"$ARCHIVE_DOWNLOAD" | tr -d ' ')))
  verify_checksum "$ARCHIVE_DOWNLOAD" "$EXPECTED"
  mv -f "$ARCHIVE_DOWNLOAD" "$CACHE_ARCHIVE"
fi
verify_checksum "$CACHE_ARCHIVE" "$EXPECTED"

LIST_FILE="$WORK_DIR/archive.list"
VERBOSE_FILE="$WORK_DIR/archive.verbose"
validate_archive "$CACHE_ARCHIVE" "$PLATFORM" "$ARCHITECTURE" "$LIST_FILE" "$VERBOSE_FILE"

STAGE_ROOT="$WORK_DIR/source"
mkdir -p "$STAGE_ROOT"
tar -xzf "$CACHE_ARCHIVE" -C "$STAGE_ROOT" ||
  fail "E_ARCHIVE_INVALID: extraction failed"
[ -z "$(find "$STAGE_ROOT" -type l -print -quit)" ] ||
  fail "E_ARCHIVE_TYPE: extracted links are rejected"

MANIFEST="$STAGE_ROOT/plugins/z-codex-router/release/manifest.json"
RESOLVED_VERSION=$(sed -n 's/^[[:space:]]*"version":[[:space:]]*"\([^"]*\)".*/\1/p' "$MANIFEST" | sed -n '1p')
valid_version "$RESOLVED_VERSION" ||
  fail "E_RELEASE_VERSION: release manifest version is invalid"
if [ "$VERSION" != "latest" ] && [ "$RESOLVED_VERSION" != "$VERSION" ]; then
  fail "E_RELEASE_VERSION: requested $VERSION but archive contains $RESOLVED_VERSION"
fi

VERSION_PARENT="$CODEX_HOME_ARG/z-codex-router-marketplace-versions/$RESOLVED_VERSION"
VERSION_ROOT="$VERSION_PARENT/$PLATFORM-$ARCHITECTURE"
ensure_managed_directory "$VERSION_PARENT"
VERSION_REUSED=false
VERSION_BACKUP=""
if [ -d "$VERSION_ROOT" ] && same_tree "$STAGE_ROOT" "$VERSION_ROOT"; then
  VERSION_REUSED=true
else
  if [ -e "$VERSION_ROOT" ] && [ ! -d "$VERSION_ROOT" ]; then
    fail "E_SOURCE_CONFLICT: persistent version path is not a directory"
  fi
  if [ -d "$VERSION_ROOT" ]; then
    VERSION_BACKUP="$VERSION_PARENT/.previous-$PLATFORM-$ARCHITECTURE-$(date -u +%Y%m%dT%H%M%SZ)-$$"
    mv "$VERSION_ROOT" "$VERSION_BACKUP"
  fi
  mv "$STAGE_ROOT" "$VERSION_ROOT"
fi

SOURCE_PARENT="$CODEX_HOME_ARG/z-codex-router-marketplaces"
SOURCE_ROOT="$SOURCE_PARENT/$PLATFORM-$ARCHITECTURE"
ensure_managed_directory "$SOURCE_PARENT"
SOURCE_REUSED=false
if [ -d "$SOURCE_ROOT" ] && same_tree "$VERSION_ROOT" "$SOURCE_ROOT"; then
  SOURCE_REUSED=true
else
  if [ -e "$SOURCE_ROOT" ] && [ ! -d "$SOURCE_ROOT" ]; then
    fail "E_SOURCE_CONFLICT: persistent marketplace path is not a directory"
  fi
  ACTIVE_STAGE="$WORK_DIR/active-source"
  cp -R "$VERSION_ROOT" "$ACTIVE_STAGE"
  if [ -d "$SOURCE_ROOT" ]; then
    BACKUP_ROOT="$SOURCE_PARENT/.previous-$PLATFORM-$ARCHITECTURE-$(date -u +%Y%m%dT%H%M%SZ)-$$"
    mv "$SOURCE_ROOT" "$BACKUP_ROOT"
  fi
  mv "$ACTIVE_STAGE" "$SOURCE_ROOT"
fi

run_codex plugin marketplace add "$SOURCE_ROOT" --json
run_codex plugin add "$PLUGIN_NAME@$MARKETPLACE_NAME" --json

if [ -f "$CODEX_HOME_ARG/z-codex-router/current.json" ]; then
  ROUTER_ACTION=upgrade
else
  ROUTER_ACTION=install
fi
if [ "$ROUTER_ACTION" = "upgrade" ]; then
  run_routerctl upgrade --dry-run
  if [ "$ENABLE" -eq 1 ]; then
    run_routerctl upgrade
  fi
else
  run_routerctl dry-run
  if [ "$ENABLE" -eq 1 ]; then
    run_routerctl install
  fi
fi
if [ "$ENABLE" -eq 1 ]; then
  run_routerctl doctor
fi

printf 'ZCR_VERSION=%s\n' "$RESOLVED_VERSION"
printf 'ZCR_PLATFORM=%s-%s\n' "$PLATFORM" "$ARCHITECTURE"
printf 'ZCR_SOURCE=%s\n' "$SOURCE_ROOT"
printf 'ZCR_VERSION_SOURCE=%s\n' "$VERSION_ROOT"
printf 'ZCR_CACHE_HIT=%s\n' "$CACHE_HIT"
printf 'ZCR_VERSION_REUSED=%s\n' "$VERSION_REUSED"
printf 'ZCR_SOURCE_REUSED=%s\n' "$SOURCE_REUSED"
printf 'ZCR_DOWNLOADED_BYTES=%s\n' "$DOWNLOADED_BYTES"
printf 'ZCR_ROUTER_ACTION=%s\n' "$ROUTER_ACTION"
printf 'ZCR_ENABLED=%s\n' "$([ "$ENABLE" -eq 1 ] && printf true || printf false)"
if [ -n "$BACKUP_ROOT" ]; then
  printf 'ZCR_PREVIOUS_SOURCE=%s\n' "$BACKUP_ROOT"
fi
if [ -n "$VERSION_BACKUP" ]; then
  printf 'ZCR_PREVIOUS_VERSION_SOURCE=%s\n' "$VERSION_BACKUP"
fi
