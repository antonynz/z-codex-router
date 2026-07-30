#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
CHECK_HISTORY=0
if [ "${1:-}" = --history ]; then
  CHECK_HISTORY=1
  shift
fi
[ "$#" -eq 0 ] || {
  printf 'Usage: verify_source.sh [--history]\n' >&2
  exit 2
}

fail() {
  printf 'FAIL verify_source.sh: %s\n' "$*" >&2
  exit 1
}

magic_of_file() {
  dd if="$1" bs=1 count=4 2>/dev/null | od -An -tx1 | tr -d ' \n'
}

is_compiled_magic() {
  case "$1" in
    7f454c46|4d5a*|feedface|feedfacf|cefaedfe|cffaedfe|\
    cafebabe|bebafeca|cafebabf|bfbafeca|0061736d|213c6172|4243c0de|dec0170b) return 0 ;;
    *) return 1 ;;
  esac
}

for forbidden in \
  "$ROOT/Cargo.toml" \
  "$ROOT/Cargo.lock" \
  "$ROOT/src" \
  "$ROOT/plugins/z-codex-router/bin"; do
  [ ! -e "$forbidden" ] || fail "forbidden Rust/binary path remains: ${forbidden#"$ROOT"/}"
done

python_file=$(find "$ROOT" \
  -path "$ROOT/.git" -prune -o \
  -type f \( -name '*.py' -o -name '*.pyc' \) -print -quit)
[ -z "$python_file" ] || fail "Python implementation/test file remains: ${python_file#"$ROOT"/}"

rust_file=$(find "$ROOT" \
  -path "$ROOT/.git" -prune -o \
  -type f -name '*.rs' -print -quit)
[ -z "$rust_file" ] || fail "Rust source remains: ${rust_file#"$ROOT"/}"

compiled_path=$(find "$ROOT" \
  -path "$ROOT/.git" -prune -o \
  -type f \( -iname '*.o' -o -iname '*.obj' -o -iname '*.a' -o -iname '*.lib' -o \
  -iname '*.so' -o -iname '*.dylib' -o -iname '*.dll' -o -iname '*.exe' -o \
  -iname '*.pdb' -o -iname '*.wasm' -o -iname '*.class' -o -iname '*.jar' \) \
  -print -quit)
[ -z "$compiled_path" ] ||
  fail "compiled artifact path remains: ${compiled_path#"$ROOT"/}"

current_list=$(mktemp "${TMPDIR:-/tmp}/zcr-current-files.XXXXXX")
history_list=$(mktemp "${TMPDIR:-/tmp}/zcr-history-objects.XXXXXX")
blob_file=$(mktemp "${TMPDIR:-/tmp}/zcr-blob.XXXXXX")
cleanup() {
  status=$?
  rm -f "$current_list" "$history_list" "$blob_file"
  exit "$status"
}
trap cleanup 0
trap 'exit 130' HUP INT TERM

find "$ROOT" -path "$ROOT/.git" -prune -o -type f -print >"$current_list"
while IFS= read -r file; do
  magic=$(magic_of_file "$file")
  if is_compiled_magic "$magic"; then
    fail "compiled executable in current tree: ${file#"$ROOT"/}"
  fi
done <"$current_list"

for image in \
  "$ROOT/docs/images/z-codex-router-architecture-zh.png" \
  "$ROOT/docs/images/z-codex-router-architecture-en.png"; do
  [ -f "$image" ] || fail "required PNG is missing: ${image#"$ROOT"/}"
  [ "$(magic_of_file "$image")" = 89504e47 ] ||
    fail "required image is not PNG: ${image#"$ROOT"/}"
done

if grep -R -n -i -E 'safe-auto[[:space:]]+(enable|disable|doctor|status|restore)' \
  "$ROOT/plugins/z-codex-router" 2>/dev/null |
  grep -v -i -E 'legacy|removed' >/dev/null 2>&1; then
  fail "removed safe-auto command remains in active plugin content"
fi

if [ "$CHECK_HISTORY" -eq 1 ]; then
  (
    CDPATH= cd -- "$ROOT"
    git rev-list --objects --all
  ) >"$history_list"
  while IFS=' ' read -r object path; do
    [ -n "$object" ] || continue
    type=$(git -C "$ROOT" cat-file -t "$object")
    [ "$type" = blob ] || continue
    lower_path=$(printf '%s' "${path:-}" | LC_ALL=C tr '[:upper:]' '[:lower:]')
    case "$lower_path" in
      *.o|*.obj|*.a|*.lib|*.so|*.dylib|*.dll|*.exe|*.pdb|*.wasm|*.class|*.jar)
        fail "compiled artifact path is reachable: $object ${path:-unknown-path}"
        ;;
    esac
    git -C "$ROOT" cat-file blob "$object" >"$blob_file"
    magic=$(magic_of_file "$blob_file")
    if is_compiled_magic "$magic"; then
      fail "compiled executable blob is reachable: $object ${path:-unknown-path}"
    fi
  done <"$history_list"
fi

printf 'PASS verify_source.sh (history=%s, PNG retained)\n' "$CHECK_HISTORY"
