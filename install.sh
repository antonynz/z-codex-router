#!/usr/bin/env sh
set -eu

REPOSITORY=antonynz/z-codex-router
PLUGIN_NAME=z-codex-router
MARKETPLACE_NAME=z-codex-router
VERSION=1.1.0
BASE_URL=
CODEX_HOME_ARG=${CODEX_HOME:-}
CODEX_BIN=${CODEX_BIN:-}
CODEX_BIN_SOURCE=
SOURCE_PACKAGE=
RELEASE_DIR=
ENABLE=0
LEGACY_MODE=
WORK_DIR=
DOWNLOADED_BYTES=0

usage() {
  cat <<'EOF'
Usage: install.sh [--enable] [--version 1.1.0] [--base-url HTTPS_URL]
                  [--codex-home PATH] [--codex-bin PATH] [--source PATH]
                  [--release-dir PATH]
       install.sh --legacy-cleanup-dry-run [same source/download options]
       install.sh --legacy-cleanup [same source/download options]

Installs the universal, script-only Z Codex Router source package.
Global routing changes only with --enable. Enabling persistently authorizes
route-only create_thread dispatch until uninstall. Legacy Rust installations
must be explicitly inspected and cleaned before a fresh script installation.

--release-dir verifies the same versioned archive and SHA256SUMS as a remote
release, but reads them from an already-downloaded release directory. It is
useful for offline installations and CI verification.
EOF
}

failure_guidance() {
  code=$1
  case "$code" in
    E_ROUTER_*)
      printf '%s\n' "state=router-needs-attention" "impact=global-routing-not-enabled" \
        "retry_safe=true" "next_command=zcr status"
      ;;
    E_CHECKSUM_*|E_ARCHIVE_*)
      printf '%s\n' "state=release-verification-failed" "impact=package-not-installed" \
        "retry_safe=true" "next_command=sh install.sh --release-dir /absolute/path/to/release"
      ;;
    E_ENTRYPOINT_CONFLICT)
      printf '%s\n' "state=entrypoint-conflict" "impact=existing-command-preserved" \
        "retry_safe=true" "next_command=sh install.sh --source ."
      ;;
    *)
      printf '%s\n' "state=failed" "impact=operation-not-completed" \
        "retry_safe=true" "next_command=sh install.sh --source ."
      ;;
  esac
}

fail() {
  code=$1
  shift
  printf '%s: %s\n' "$code" "$*" >&2
  printf '%s\n' "code=$code" >&2
  failure_guidance "$code" >&2
  exit 1
}

cleanup() {
  status=$?
  if [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ]; then
    rm -rf -- "$WORK_DIR"
  fi
  exit "$status"
}

trap cleanup 0
trap 'exit 130' HUP INT TERM

need_command() {
  command -v "$1" >/dev/null 2>&1 ||
    fail E_PREREQUISITE "missing command: $1"
}

codex_has_plugin_capability() {
  candidate=$1
  "$candidate" plugin marketplace add --help >/dev/null 2>&1 &&
    "$candidate" plugin add --help >/dev/null 2>&1
}

use_codex_candidate() {
  candidate=$1
  source=$2
  resolved=$(command -v "$candidate" 2>/dev/null || true)
  [ -n "$resolved" ] && [ -f "$resolved" ] && [ -x "$resolved" ] || return 1
  CODEX_CANDIDATES_FOUND=1
  codex_has_plugin_capability "$resolved" || return 1
  CODEX_BIN=$resolved
  CODEX_BIN_SOURCE=$source
  return 0
}

resolve_codex_bin() {
  CODEX_CANDIDATES_FOUND=0
  if [ -n "$CODEX_BIN" ]; then
    resolved=$(command -v "$CODEX_BIN" 2>/dev/null || true)
    [ -n "$resolved" ] && [ -f "$resolved" ] && [ -x "$resolved" ] ||
      fail E_CODEX_MISSING "explicit Codex executable is not runnable: $CODEX_BIN"
    codex_has_plugin_capability "$resolved" ||
      fail E_CODEX_CAPABILITY "explicit Codex executable lacks plugin marketplace support"
    CODEX_BIN=$resolved
    CODEX_BIN_SOURCE=explicit
    return
  fi

  use_codex_candidate codex path && return
  if [ -n "${CODEX_CLI_PATH:-}" ]; then
    use_codex_candidate "$CODEX_CLI_PATH" desktop-runtime && return
  fi
  if [ -n "${XDG_BIN_HOME:-}" ]; then
    use_codex_candidate "$XDG_BIN_HOME/codex" user-local && return
  fi
  use_codex_candidate "$HOME/.local/bin/codex" user-local && return
  platform=$(uname -s 2>/dev/null || printf unknown)
  case "$platform" in
    Darwin)
      for candidate in \
        /Applications/ChatGPT.app/Contents/Resources/codex \
        "$HOME/Applications/ChatGPT.app/Contents/Resources/codex" \
        /Applications/Codex.app/Contents/Resources/codex \
        "$HOME/Applications/Codex.app/Contents/Resources/codex"; do
        use_codex_candidate "$candidate" desktop-app-bundled && return
      done
      ;;
    Linux)
      if [ -n "${APPDIR:-}" ]; then
        use_codex_candidate "$APPDIR/resources/codex" desktop-app-bundled && return
        use_codex_candidate "$APPDIR/usr/bin/codex" desktop-app-bundled && return
      fi
      ;;
  esac

  if [ "$CODEX_CANDIDATES_FOUND" -eq 1 ]; then
    fail E_CODEX_CAPABILITY \
      "Codex candidates were found but none support plugin marketplace commands; use --codex-bin"
  fi
  fail E_CODEX_MISSING \
    "Codex executable not found in PATH or supported desktop locations; install Codex CLI or use --codex-bin"
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print tolower($1)}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print tolower($1)}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "$1" | awk '{print tolower($NF)}'
  else
    fail E_PREREQUISITE "need sha256sum, shasum, or openssl"
  fi
}

valid_version() {
  printf '%s\n' "$1" |
    LC_ALL=C grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'
}

download_https() {
  url=$1
  destination=$2
  case "$url" in https://*) ;; *) fail E_URL_INSECURE "only HTTPS URLs are accepted" ;; esac
  curl --fail --silent --show-error --location \
    --proto '=https' --proto-redir '=https' --tlsv1.2 --max-redirs 5 \
    --output "$destination" "$url"
}

expected_checksum() {
  sums=$1
  asset=$2
  awk -v wanted="$asset" '
    {
      name = $2
      sub(/^\*/, "", name)
      if (name == wanted) {
        count++
        hash = tolower($1)
      }
    }
    END {
      if (count != 1 || hash !~ /^[0-9a-f]{64}$/) exit 1
      print hash
    }
  ' "$sums" || fail E_CHECKSUM_ENTRY "expected one checksum for $asset"
}

assert_no_compiled_files() {
  root=$1
  find "$root" -type f -print |
    while IFS= read -r file; do
      lower=$(printf '%s' "$file" | LC_ALL=C tr '[:upper:]' '[:lower:]')
      case "$lower" in
        *.o|*.obj|*.a|*.lib|*.so|*.dylib|*.dll|*.exe|*.pdb|*.wasm|*.class|*.jar)
          fail E_COMPILED_ARTIFACT "compiled artifact is forbidden: ${file#"$root"/}"
          ;;
      esac
      magic=$(dd if="$file" bs=1 count=4 2>/dev/null | od -An -tx1 | tr -d ' \n')
      case "$magic" in
        7f454c46|4d5a*|feedface|feedfacf|cefaedfe|cffaedfe|\
        cafebabe|bebafeca|cafebabf|bfbafeca|0061736d|213c6172|4243c0de|dec0170b)
          fail E_COMPILED_ARTIFACT "compiled executable is forbidden: ${file#"$root"/}"
          ;;
      esac
    done
}

validate_archive() {
  archive=$1
  list=$WORK_DIR/archive.list
  verbose=$WORK_DIR/archive.verbose
  tar -tzf "$archive" >"$list" ||
    fail E_ARCHIVE_INVALID "cannot list source archive"
  [ -s "$list" ] || fail E_ARCHIVE_INVALID "source archive is empty"
  while IFS= read -r entry; do
    case "$entry" in
      ""|/*|*\\*|*'	'*|*" "*) fail E_ARCHIVE_PATH "unsafe archive entry: $entry" ;;
    esac
    printf '%s\n' "$entry" | LC_ALL=C grep -Eq '^[A-Za-z0-9._/+@-]+$' ||
      fail E_ARCHIVE_PATH "unsupported archive entry"
    case "/$entry/" in *"/../"*) fail E_ARCHIVE_PATH "path traversal entry: $entry" ;; esac
  done <"$list"
  duplicate=$(LC_ALL=C sort "$list" | uniq -d | sed -n '1p')
  [ -z "$duplicate" ] || fail E_ARCHIVE_PATH "duplicate archive entry: $duplicate"
  tar -tvzf "$archive" >"$verbose" ||
    fail E_ARCHIVE_INVALID "cannot inspect archive entry types"
  while IFS= read -r detail; do
    type=$(printf '%s' "$detail" | cut -c 1)
    case "$type" in -|d) ;; *) fail E_ARCHIVE_TYPE "links and special files are forbidden" ;; esac
  done <"$verbose"
}

find_package_root() {
  extracted=$1
  if [ -f "$extracted/plugins/z-codex-router/.codex-plugin/plugin.json" ]; then
    printf '%s\n' "$extracted"
    return
  fi
  candidate=
  count=0
  for directory in "$extracted"/*; do
    [ -d "$directory" ] || continue
    if [ -f "$directory/plugins/z-codex-router/.codex-plugin/plugin.json" ]; then
      candidate=$directory
      count=$((count + 1))
    fi
  done
  [ "$count" -eq 1 ] || fail E_ARCHIVE_LAYOUT "archive must contain exactly one package root"
  printf '%s\n' "$candidate"
}

manifest_version() {
  file=$1
  version=$(sed -n 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$file" |
    sed -n '1p')
  valid_version "$version" || fail E_RELEASE_VERSION "source manifest version is invalid"
  printf '%s\n' "$version"
}

copy_marketplace_source() {
  package=$1
  destination=$2
  [ -f "$package/.agents/plugins/marketplace.json" ] ||
    fail E_SOURCE_INVALID "marketplace manifest is missing"
  [ -d "$package/plugins/z-codex-router" ] ||
    fail E_SOURCE_INVALID "plugin source is missing"
  mkdir -p "$destination"
  cp -R "$package/.agents" "$destination/"
  cp -R "$package/plugins" "$destination/"
}

entrypoint_is_managed() {
  path=$1
  [ -f "$path" ] && [ ! -L "$path" ] &&
    grep -F 'z-codex-router-entrypoint-v1' "$path" >/dev/null 2>&1
}

preflight_entrypoints() {
  for name in zcr zcr.ps1 zcr.cmd; do
    [ -f "$PACKAGE_ROOT/$name" ] ||
      fail E_SOURCE_INVALID "stable entry point is missing: $name"
    destination=$CODEX_HOME_ARG/bin/$name
    if [ -e "$destination" ] && ! entrypoint_is_managed "$destination"; then
      fail E_ENTRYPOINT_CONFLICT "refusing to overwrite an unmanaged entry point: $destination"
    fi
  done
}

atomic_install_file() {
  source=$1
  destination=$2
  parent=$(dirname -- "$destination")
  base=$(basename -- "$destination")
  mkdir -p "$parent"
  temporary=$(mktemp "$parent/.$base.XXXXXX")
  cp "$source" "$temporary"
  mv -f "$temporary" "$destination"
}

install_entrypoints() {
  entrypoint_dir=$CODEX_HOME_ARG/bin
  for name in zcr zcr.ps1 zcr.cmd; do
    atomic_install_file "$PACKAGE_ROOT/$name" "$entrypoint_dir/$name"
  done
  chmod 755 "$entrypoint_dir/zcr"
  pointer_dir=$CODEX_HOME_ARG/z-codex-router-entrypoint
  mkdir -p "$pointer_dir"
  pointer=$pointer_dir/source
  temporary=$(mktemp "$pointer_dir/.source.XXXXXX")
  printf '%s\n' "$CACHE_ROOT/plugins/z-codex-router" >"$temporary"
  mv -f "$temporary" "$pointer"
}

rewrite_cache_version() {
  manifest=$1
  cache_version=$2
  temporary=$manifest.tmp-$$
  if ! awk -v version="$cache_version" '
    !done && $0 ~ /^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"[^"]*"[[:space:]]*,[[:space:]]*$/ {
      print "  \"version\": \"" version "\","
      done = 1
      next
    }
    { print }
    END { if (!done) exit 42 }
  ' "$manifest" >"$temporary"; then
    rm -f "$temporary"
    fail E_SOURCE_INVALID "could not apply local cache build metadata"
  fi
  mv "$temporary" "$manifest"
}

run_routerctl() {
  launcher=$1
  shift
  CODEX_HOME="$CODEX_HOME_ARG" sh "$launcher" --codex-home "$CODEX_HOME_ARG" "$@"
}

run_codex() {
  CODEX_HOME="$CODEX_HOME_ARG" "$CODEX_BIN" "$@"
}

registered_marketplace_root() {
  output=$WORK_DIR/marketplaces.txt
  run_codex plugin marketplace list >"$output" ||
    fail E_CODEX_REGISTRATION "could not inspect configured marketplaces"
  awk -v name="$MARKETPLACE_NAME" '
    $1 == name {
      sub(/^[^[:space:]]+[[:space:]]+/, "")
      print
      exit
    }
  ' "$output"
}

restore_marketplace_cache() {
  [ "${CACHE_REPLACED:-0}" -eq 1 ] || return 0
  [ -d "$CACHE_PREVIOUS" ] && [ ! -L "$CACHE_PREVIOUS" ] || return 1
  failed=$CACHE_PARENT/.failed-$cache_token
  mv "$CACHE_ROOT" "$failed" || return 1
  mv "$CACHE_PREVIOUS" "$CACHE_ROOT" || return 1
  run_codex plugin add "$PLUGIN_NAME@$MARKETPLACE_NAME" --json >/dev/null 2>&1 || return 1
  rm -rf -- "$failed"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --enable) ENABLE=1; shift ;;
    --version)
      [ "$#" -ge 2 ] || fail E_USAGE "--version needs a value"
      VERSION=$2
      shift 2
      ;;
    --base-url)
      [ "$#" -ge 2 ] || fail E_USAGE "--base-url needs a value"
      BASE_URL=$2
      shift 2
      ;;
    --codex-home)
      [ "$#" -ge 2 ] || fail E_USAGE "--codex-home needs a value"
      CODEX_HOME_ARG=$2
      shift 2
      ;;
    --codex-bin)
      [ "$#" -ge 2 ] || fail E_USAGE "--codex-bin needs a value"
      CODEX_BIN=$2
      shift 2
      ;;
    --source)
      [ "$#" -ge 2 ] || fail E_USAGE "--source needs a path"
      SOURCE_PACKAGE=$2
      shift 2
      ;;
    --release-dir)
      [ "$#" -ge 2 ] || fail E_USAGE "--release-dir needs a path"
      RELEASE_DIR=$2
      shift 2
      ;;
    --legacy-cleanup-dry-run)
      [ -z "$LEGACY_MODE" ] || fail E_USAGE "choose one legacy cleanup mode"
      LEGACY_MODE=dry-run
      shift
      ;;
    --legacy-cleanup)
      [ -z "$LEGACY_MODE" ] || fail E_USAGE "choose one legacy cleanup mode"
      LEGACY_MODE=clean
      shift
      ;;
    -h|--help) usage; exit 0 ;;
    *) fail E_USAGE "unknown option: $1" ;;
  esac
done

valid_version "$VERSION" ||
  fail E_VERSION_INVALID "expected a stable semantic version without leading v"
[ -z "$SOURCE_PACKAGE" ] || [ -z "$RELEASE_DIR" ] ||
  fail E_USAGE "--source and --release-dir cannot be used together"
if [ -z "$BASE_URL" ]; then
  BASE_URL=https://github.com/$REPOSITORY/releases/download/v$VERSION
fi
BASE_URL=${BASE_URL%/}
case "$BASE_URL" in https://*) ;; *) fail E_URL_INSECURE "--base-url must use HTTPS" ;; esac

need_command awk
need_command sed
need_command grep
need_command find
need_command sort
need_command uniq
need_command tar
need_command dd
need_command od
need_command tr
need_command wc
need_command mktemp
need_command cp
need_command mv
need_command cut
need_command chmod
need_command dirname
need_command basename

if [ -z "$CODEX_HOME_ARG" ]; then
  [ -n "${HOME:-}" ] || fail E_CODEX_HOME_REQUIRED "set CODEX_HOME or HOME"
  CODEX_HOME_ARG=$HOME/.codex
fi
case "$CODEX_HOME_ARG" in /*) ;; *) fail E_CODEX_HOME_INVALID "Codex home must be absolute" ;; esac
[ "$CODEX_HOME_ARG" != "/" ] || fail E_CODEX_HOME_INVALID "filesystem root is unsafe"
[ ! -L "$CODEX_HOME_ARG" ] || fail E_CODEX_HOME_INVALID "Codex home cannot be a link"
mkdir -p "$CODEX_HOME_ARG"
CODEX_HOME_ARG=$(CDPATH= cd -- "$CODEX_HOME_ARG" && pwd -P)
WORK_DIR=$(mktemp -d "$CODEX_HOME_ARG/.zcr-bootstrap.XXXXXX")

if [ -n "$SOURCE_PACKAGE" ]; then
  [ -d "$SOURCE_PACKAGE" ] || fail E_SOURCE_INVALID "local source path does not exist"
  PACKAGE_ROOT=$(CDPATH= cd -- "$SOURCE_PACKAGE" && pwd -P)
elif [ -n "$RELEASE_DIR" ]; then
  [ -d "$RELEASE_DIR" ] || fail E_RELEASE_DIRECTORY_INVALID "release directory does not exist"
  RELEASE_DIR=$(CDPATH= cd -- "$RELEASE_DIR" && pwd -P)
  asset=z-codex-router-$VERSION.tar.gz
  sums=$RELEASE_DIR/SHA256SUMS
  archive=$RELEASE_DIR/$asset
  [ -f "$sums" ] || fail E_CHECKSUM_ENTRY "release directory is missing SHA256SUMS"
  [ -f "$archive" ] || fail E_ARCHIVE_INVALID "release directory is missing $asset"
  expected=$(expected_checksum "$sums" "$asset")
  [ "$(sha256_file "$archive")" = "$expected" ] ||
    fail E_CHECKSUM_MISMATCH "$asset"
  validate_archive "$archive"
  extracted=$WORK_DIR/extracted
  mkdir "$extracted"
  tar -xzf "$archive" -C "$extracted" ||
    fail E_ARCHIVE_INVALID "source extraction failed"
  [ -z "$(find "$extracted" -type l -print -quit)" ] ||
    fail E_ARCHIVE_TYPE "extracted links are forbidden"
  PACKAGE_ROOT=$(find_package_root "$extracted")
else
  need_command curl
  asset=z-codex-router-$VERSION.tar.gz
  sums=$WORK_DIR/SHA256SUMS
  archive=$WORK_DIR/$asset
  download_https "$BASE_URL/SHA256SUMS" "$sums"
  DOWNLOADED_BYTES=$(wc -c <"$sums" | tr -d ' ')
  expected=$(expected_checksum "$sums" "$asset")
  download_https "$BASE_URL/$asset" "$archive"
  DOWNLOADED_BYTES=$((DOWNLOADED_BYTES + $(wc -c <"$archive" | tr -d ' ')))
  [ "$(sha256_file "$archive")" = "$expected" ] ||
    fail E_CHECKSUM_MISMATCH "$asset"
  validate_archive "$archive"
  extracted=$WORK_DIR/extracted
  mkdir "$extracted"
  tar -xzf "$archive" -C "$extracted" ||
    fail E_ARCHIVE_INVALID "source extraction failed"
  [ -z "$(find "$extracted" -type l -print -quit)" ] ||
    fail E_ARCHIVE_TYPE "extracted links are forbidden"
  PACKAGE_ROOT=$(find_package_root "$extracted")
fi

assert_no_compiled_files "$PACKAGE_ROOT"
for required in \
  .agents/plugins/marketplace.json \
  plugins/z-codex-router/.codex-plugin/plugin.json \
  plugins/z-codex-router/release/manifest.json \
  plugins/z-codex-router/core/router.md \
  plugins/z-codex-router/scripts/routerctl.sh \
  plugins/z-codex-router/scripts/routerctl.ps1; do
  [ -f "$PACKAGE_ROOT/$required" ] ||
    fail E_SOURCE_INVALID "required source file is missing: $required"
done
RELEASE_VERSION=$(manifest_version "$PACKAGE_ROOT/plugins/z-codex-router/release/manifest.json")
PLUGIN_VERSION=$(manifest_version "$PACKAGE_ROOT/plugins/z-codex-router/.codex-plugin/plugin.json")
[ "$RELEASE_VERSION" = "$VERSION" ] ||
  fail E_RELEASE_VERSION "requested $VERSION but source contains $RELEASE_VERSION"
[ "$PLUGIN_VERSION" = "$RELEASE_VERSION" ] ||
  fail E_RELEASE_VERSION "plugin and release manifest versions differ"
SOURCE_LAUNCHER=$PACKAGE_ROOT/plugins/z-codex-router/scripts/routerctl.sh
sh -n "$SOURCE_LAUNCHER" || fail E_SOURCE_INVALID "POSIX control plane has a syntax error"
preflight_entrypoints

if [ "$LEGACY_MODE" = dry-run ]; then
  run_routerctl "$SOURCE_LAUNCHER" --source "$PACKAGE_ROOT/plugins/z-codex-router" \
    legacy-cleanup --dry-run
  exit 0
elif [ "$LEGACY_MODE" = clean ]; then
  run_routerctl "$SOURCE_LAUNCHER" --source "$PACKAGE_ROOT/plugins/z-codex-router" legacy-cleanup
  exit 0
fi

if [ -f "$CODEX_HOME_ARG/z-codex-router/current/format" ]; then
  PREFLIGHT_ACTION=upgrade
  if ! run_routerctl "$SOURCE_LAUNCHER" --source "$PACKAGE_ROOT/plugins/z-codex-router" \
    upgrade --dry-run; then
    fail E_ROUTER_PREFLIGHT "script upgrade preflight failed; user files were not changed"
  fi
else
  PREFLIGHT_ACTION=install
  if ! run_routerctl "$SOURCE_LAUNCHER" --source "$PACKAGE_ROOT/plugins/z-codex-router" dry-run; then
    printf '%s\n' \
      "NEXT_1=install.sh --legacy-cleanup-dry-run" \
      "NEXT_2=install.sh --legacy-cleanup" \
      "NEXT_3=install.sh --enable" >&2
    fail E_ROUTER_PREFLIGHT "fresh-install preflight failed; user files were not changed"
  fi
fi

resolve_codex_bin

cache_token=$(date -u +%Y%m%dT%H%M%SZ)-$$
CACHE_VERSION=$VERSION+codex.$cache_token
CACHE_PARENT=$CODEX_HOME_ARG/z-codex-router-marketplaces
mkdir -p "$CACHE_PARENT"
existing_marketplace_root=$(registered_marketplace_root)
if [ -n "$existing_marketplace_root" ]; then
  case "$existing_marketplace_root" in
    "$CACHE_PARENT"/*) ;;
    *) fail E_MARKETPLACE_CONFLICT "existing z-codex-router marketplace is outside the managed cache" ;;
  esac
  [ -d "$existing_marketplace_root" ] && [ ! -L "$existing_marketplace_root" ] ||
    fail E_MARKETPLACE_CONFLICT "existing managed marketplace root is invalid"
  CACHE_ROOT=$existing_marketplace_root
  CACHE_REPLACED=1
  CACHE_PREVIOUS=$CACHE_PARENT/.previous-$cache_token
  [ ! -e "$CACHE_PREVIOUS" ] || fail E_CACHE_CONFLICT "marketplace rollback path already exists"
else
  CACHE_ROOT=$CACHE_PARENT/$CACHE_VERSION
  CACHE_REPLACED=0
  CACHE_PREVIOUS=
  [ ! -e "$CACHE_ROOT" ] || fail E_CACHE_CONFLICT "local cache path already exists"
fi
cache_stage=$CACHE_PARENT/.stage-$cache_token
copy_marketplace_source "$PACKAGE_ROOT" "$cache_stage"
rewrite_cache_version "$cache_stage/plugins/z-codex-router/.codex-plugin/plugin.json" "$CACHE_VERSION"
if [ "$CACHE_REPLACED" -eq 1 ]; then
  mv "$CACHE_ROOT" "$CACHE_PREVIOUS"
fi
mv "$cache_stage" "$CACHE_ROOT"
CACHE_LAUNCHER=$CACHE_ROOT/plugins/z-codex-router/scripts/routerctl.sh

if ! run_codex plugin marketplace add "$CACHE_ROOT" --json; then
  restore_marketplace_cache ||
    fail E_CODEX_REGISTRATION_ROLLBACK "marketplace registration failed and the previous source could not be restored"
  fail E_CODEX_REGISTRATION "marketplace registration failed; Router user files were not changed"
fi
if ! run_codex plugin add "$PLUGIN_NAME@$MARKETPLACE_NAME" --json; then
  restore_marketplace_cache ||
    fail E_CODEX_REGISTRATION_ROLLBACK "plugin registration failed and the previous plugin could not be restored"
  fail E_CODEX_REGISTRATION "plugin installation failed; Router user files were not changed"
fi
if [ "$CACHE_REPLACED" -eq 1 ]; then
  rm -rf -- "$CACHE_PREVIOUS"
fi
install_entrypoints

if [ "$ENABLE" -eq 1 ]; then
  if [ "$PREFLIGHT_ACTION" = upgrade ]; then
    run_routerctl "$CACHE_LAUNCHER" upgrade
  else
    run_routerctl "$CACHE_LAUNCHER" install
  fi
  if ! run_routerctl "$CACHE_LAUNCHER" doctor; then
    if run_routerctl "$CACHE_LAUNCHER" rollback; then
      fail E_ROUTER_VALIDATION "Doctor failed after write; Router state was rolled back"
    fi
    fail E_ROUTER_ROLLBACK_REQUIRED \
      "Doctor failed after write and rollback did not complete; use the Recover Router skill"
  fi
fi

printf '%s\n' "ZCR_VERSION=$VERSION" "ZCR_CACHE_VERSION=$CACHE_VERSION" \
  "ZCR_SOURCE=$CACHE_ROOT" "ZCR_DOWNLOADED_BYTES=$DOWNLOADED_BYTES" \
  "ZCR_ROUTER_ACTION=$PREFLIGHT_ACTION" \
  "ZCR_ENABLED=$([ "$ENABLE" -eq 1 ] && printf true || printf false)" \
  "ZCR_CODEX_BIN=$CODEX_BIN" "ZCR_CODEX_SOURCE=$CODEX_BIN_SOURCE" \
  "ZCR_ENTRYPOINT_POSIX=$CODEX_HOME_ARG/bin/zcr" \
  "ZCR_ENTRYPOINT_POWERSHELL=$CODEX_HOME_ARG/bin/zcr.ps1" \
  "ZCR_ENTRYPOINT_CMD=$CODEX_HOME_ARG/bin/zcr.cmd" \
  "ZCR_ROUTE_CREATE_AUTHORIZATION=$([ "$ENABLE" -eq 1 ] && printf persistent-until-uninstall || printf inactive)" \
  "ZCR_NEXT_COMMAND=zcr status"
