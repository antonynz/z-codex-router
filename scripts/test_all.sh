#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)

sh -n "$ROOT/install.sh"
sh -n "$ROOT/plugins/z-codex-router/scripts/routerctl.sh"
sh -n "$ROOT/scripts/test_routerctl.sh"
sh -n "$ROOT/scripts/test_install.sh"
sh -n "$ROOT/scripts/test_docs.sh"
sh -n "$ROOT/scripts/test_bootstrap.sh"
sh -n "$ROOT/scripts/test_user_commands.sh"
sh -n "$ROOT/scripts/test_docs_bootstrap.sh"
sh -n "$ROOT/scripts/test_policy.sh"
sh -n "$ROOT/scripts/verify_source.sh"
sh -n "$ROOT/scripts/package_release.sh"
sh -n "$ROOT/scripts/test_release.sh"

sh "$ROOT/scripts/test_routerctl.sh"
sh "$ROOT/scripts/test_docs.sh"
sh "$ROOT/scripts/test_bootstrap.sh"
sh "$ROOT/scripts/test_user_commands.sh"
sh "$ROOT/scripts/test_policy.sh"
sh "$ROOT/scripts/verify_source.sh"
sh "$ROOT/scripts/test_release.sh"
