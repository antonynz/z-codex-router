#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
exec sh "$ROOT/scripts/test_docs_bootstrap.sh"
