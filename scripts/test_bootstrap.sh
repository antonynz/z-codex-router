#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
# test_install.sh performs both a checkout install and a checksum-verified
# release-directory install, which is the portable bootstrap contract.
exec sh "$ROOT/scripts/test_install.sh"
