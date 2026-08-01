#!/usr/bin/env sh
# Deterministic local Codex stub for executable documentation tests.
case "$*" in
  *--help*) exit 0 ;;
esac
if [ "$1 $2 $3" = "plugin marketplace list" ]; then
  printf '%-24s %s\n' MARKETPLACE ROOT
fi
exit 0
