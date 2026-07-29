#!/usr/bin/env sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PLUGIN_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

case "$(uname -s)" in
  Darwin) OS=darwin ;;
  Linux) OS=linux ;;
  *) echo "E_PLATFORM_UNSUPPORTED: use the PowerShell launcher on Windows" >&2; exit 64 ;;
esac
case "$(uname -m)" in
  arm64|aarch64) ARCH=arm64 ;;
  x86_64|amd64) ARCH=amd64 ;;
  *) echo "E_ARCH_UNSUPPORTED" >&2; exit 64 ;;
esac

BINARY="$PLUGIN_ROOT/bin/routerctl-$OS-$ARCH"
if [ ! -x "$BINARY" ]; then
  echo "E_BINARY_MISSING: this plugin release lacks routerctl-$OS-$ARCH" >&2
  exit 69
fi
exec "$BINARY" --source "$PLUGIN_ROOT" "$@"
