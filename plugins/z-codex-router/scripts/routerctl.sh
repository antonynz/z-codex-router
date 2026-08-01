#!/usr/bin/env sh
set -eu

PROGRAM=routerctl
FORMAT=script-v1
PUBLIC_VERSION=1.1.0
BEGIN_MARKER='<!-- z-codex-router:begin'
END_MARKER='<!-- z-codex-router:end id=z-codex-router -->'
DEFAULT_BUDGET=32768
SOURCE_ROOT=
CODEX_HOME_ARG=
DOCTOR_CWD=
WORK_DIR=
LOCK_DIR=
LOCK_HELD=0

usage() {
  cat <<'EOF'
Z Codex Router pure-script control plane

Usage:
  routerctl.sh [--source PATH] [--codex-home PATH] dry-run
  routerctl.sh [--source PATH] [--codex-home PATH] install
  routerctl.sh [--source PATH] [--codex-home PATH] enable
  routerctl.sh [--source PATH] [--codex-home PATH] disable
  routerctl.sh [--source PATH] [--codex-home PATH] status [--cwd PATH]
  routerctl.sh [--source PATH] [--codex-home PATH] doctor [--cwd PATH]
  routerctl.sh [--source PATH] [--codex-home PATH] upgrade [--dry-run]
  routerctl.sh [--source PATH] [--codex-home PATH] recover
  routerctl.sh [--source PATH] [--codex-home PATH] rollback
  routerctl.sh [--source PATH] [--codex-home PATH] uninstall [--purge-profile]
  routerctl.sh [--source PATH] [--codex-home PATH] legacy-cleanup [--dry-run]
  routerctl.sh [--source PATH] [--codex-home PATH] profile show|init|validate|reset|backups
  routerctl.sh [--source PATH] [--codex-home PATH] profile set TIER MODEL EFFORT
  routerctl.sh [--source PATH] [--codex-home PATH] profile restore BACKUP
EOF
}

failure_guidance() {
  code=$1
  case "$code" in
    E_TRANSACTION_PENDING|E_TRANSACTION_DRIFT|E_TRANSACTION_INVALID)
      printf '%s\n' "state=recovery-required" "impact=lifecycle-state-may-be-incomplete" \
        "retry_safe=false" "next_command=zcr recover"
      ;;
    E_LOCKED)
      printf '%s\n' "state=operation-in-progress" "impact=no-write-by-this-command" \
        "retry_safe=true" "next_command=zcr status"
      ;;
    E_GLOBAL_OVERRIDE_ACTIVE)
      printf '%s\n' "state=shadowed" "impact=global-routing-not-modified" \
        "retry_safe=true" "next_command=zcr status"
      ;;
    E_MANAGED_BLOCK_DRIFT|E_PAYLOAD_INVALID|E_COMMIT_DRIFT|E_ROLLBACK_DRIFT)
      printf '%s\n' "state=review-required" "impact=protected-user-state-preserved" \
        "retry_safe=true" "next_command=zcr status"
      ;;
    E_PROFILE_*)
      printf '%s\n' "state=profile-needs-attention" "impact=profile-not-modified" \
        "retry_safe=true" "next_command=zcr profile show"
      ;;
    E_LEGACY_*)
      printf '%s\n' "state=legacy-cleanup-required" "impact=global-routing-not-modified" \
        "retry_safe=false" "next_command=zcr legacy-cleanup --dry-run"
      ;;
    E_NOT_INSTALLED|E_UPGRADE_REQUIRED)
      printf '%s\n' "state=not-enabled" "impact=global-routing-inactive" \
        "retry_safe=true" "next_command=zcr enable"
      ;;
    *)
      printf '%s\n' "state=failed" "impact=operation-not-completed" \
        "retry_safe=true" "next_command=zcr status"
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
  if [ "$LOCK_HELD" -eq 1 ] && [ -n "$LOCK_DIR" ] && [ -d "$LOCK_DIR" ]; then
    rm -f "$LOCK_DIR/pid"
    rmdir "$LOCK_DIR" 2>/dev/null || true
  fi
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

sha256_file() {
  file=$1
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print tolower($1)}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print tolower($1)}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "$file" | awk '{print tolower($NF)}'
  else
    fail E_PREREQUISITE "need sha256sum, shasum, or openssl"
  fi
}

hash_optional() {
  path=$1
  if [ -f "$path" ]; then
    sha256_file "$path"
  elif [ ! -e "$path" ]; then
    printf '%s\n' absent
  else
    fail E_PATH_INVALID "expected a regular file or an absent path: $path"
  fi
}

tree_hash() {
  root=$1
  [ -d "$root" ] || fail E_PATH_INVALID "tree is missing: $root"
  manifest="$WORK_DIR/tree-hash-$$.txt"
  (
    CDPATH= cd -- "$root"
    find . -type f -print | LC_ALL=C sort |
      while IFS= read -r relative; do
        clean=${relative#./}
        case "$clean" in
          *'
'*|*'	'*) fail E_PATH_INVALID "unsupported filename in managed tree" ;;
        esac
        printf '%s  %s\n' "$(sha256_file "$clean")" "$clean"
      done
  ) >"$manifest"
  [ -s "$manifest" ] || fail E_SOURCE_INVALID "managed tree is empty: $root"
  sha256_file "$manifest"
}

timestamp() {
  date -u +%Y%m%dT%H%M%SZ
}

atomic_copy() {
  source=$1
  destination=$2
  parent=$(dirname -- "$destination")
  base=$(basename -- "$destination")
  mkdir -p "$parent"
  temporary=$(mktemp "$parent/.$base.XXXXXX")
  cp "$source" "$temporary"
  mv -f "$temporary" "$destination"
}

atomic_from() {
  prepared=$1
  destination=$2
  parent=$(dirname -- "$destination")
  base=$(basename -- "$destination")
  mkdir -p "$parent"
  temporary=$(mktemp "$parent/.$base.XXXXXX")
  cp "$prepared" "$temporary"
  mv -f "$temporary" "$destination"
}

write_value() {
  path=$1
  value=$2
  printf '%s\n' "$value" >"$path"
}

read_value() {
  path=$1
  [ -f "$path" ] || fail E_STATE_INVALID "missing state file: $path"
  IFS= read -r value <"$path" || [ -n "${value:-}" ] ||
    fail E_STATE_INVALID "empty state file: $path"
  printf '%s\n' "$value"
}

resolve_paths() {
  script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
  if [ -z "$SOURCE_ROOT" ]; then
    SOURCE_ROOT=$(CDPATH= cd -- "$script_dir/.." && pwd -P)
  else
    [ -d "$SOURCE_ROOT" ] || fail E_SOURCE_INVALID "source does not exist: $SOURCE_ROOT"
    SOURCE_ROOT=$(CDPATH= cd -- "$SOURCE_ROOT" && pwd -P)
  fi

  if [ -z "$CODEX_HOME_ARG" ]; then
    if [ -n "${CODEX_HOME:-}" ]; then
      CODEX_HOME_ARG=$CODEX_HOME
    else
      [ -n "${HOME:-}" ] || fail E_CODEX_HOME_REQUIRED "set CODEX_HOME or HOME"
      CODEX_HOME_ARG=$HOME/.codex
    fi
  fi
  case "$CODEX_HOME_ARG" in
    /*) ;;
    *) fail E_CODEX_HOME_INVALID "Codex home must be absolute" ;;
  esac
  case "/$CODEX_HOME_ARG/" in
    *"/../"*) fail E_CODEX_HOME_INVALID "Codex home cannot contain .." ;;
  esac
  [ "$CODEX_HOME_ARG" != "/" ] ||
    fail E_CODEX_HOME_INVALID "filesystem root is unsafe"
  if [ -L "$CODEX_HOME_ARG" ]; then
    fail E_CODEX_HOME_INVALID "Codex home cannot be a symbolic link"
  fi
  mkdir -p "$CODEX_HOME_ARG"
  CODEX_HOME_ARG=$(CDPATH= cd -- "$CODEX_HOME_ARG" && pwd -P)
  [ "$CODEX_HOME_ARG" != "/" ] ||
    fail E_CODEX_HOME_INVALID "filesystem root is unsafe"

  ROUTER_ROOT=$CODEX_HOME_ARG/z-codex-router
  CURRENT_DIR=$ROUTER_ROOT/current
  VERSIONS_DIR=$ROUTER_ROOT/versions
  BACKUPS_DIR=$ROUTER_ROOT/backups
  TRANSACTION_DIR=$ROUTER_ROOT/transaction
  AGENTS_FILE=$CODEX_HOME_ARG/AGENTS.md
  GLOBAL_OVERRIDE=$CODEX_HOME_ARG/AGENTS.override.md
  PROFILE_FILE=$CODEX_HOME_ARG/z-codex-router-profile.toml
  PROFILE_BACKUPS=$CODEX_HOME_ARG/z-codex-router-profile-backups
  LOCK_DIR=$CODEX_HOME_ARG/.z-codex-router.lock
  WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/zcr.XXXXXX")
}

acquire_lock() {
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    LOCK_HELD=1
    write_value "$LOCK_DIR/pid" "$$"
  else
    fail E_LOCKED "another Z Codex Router operation is active"
  fi
}

release_lock() {
  if [ "$LOCK_HELD" -eq 1 ]; then
    rm -f "$LOCK_DIR/pid"
    rmdir "$LOCK_DIR" 2>/dev/null ||
      fail E_LOCKED "could not release operation lock"
    LOCK_HELD=0
  fi
}

ensure_no_links() {
  root=$1
  linked=$(find "$root" -type l -print -quit)
  [ -z "$linked" ] ||
    fail E_PATH_INVALID "symbolic links are not allowed in managed content: $linked"
}

validate_semver() {
  printf '%s\n' "$1" |
    LC_ALL=C grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$'
}

release_version() {
  manifest=$SOURCE_ROOT/release/manifest.json
  [ -f "$manifest" ] || fail E_SOURCE_INVALID "release manifest is missing"
  version=$(sed -n 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$manifest" |
    sed -n '1p')
  validate_semver "$version" ||
    fail E_SOURCE_INVALID "release manifest version is invalid"
  printf '%s\n' "$version"
}

plugin_version() {
  manifest=$SOURCE_ROOT/.codex-plugin/plugin.json
  [ -f "$manifest" ] || fail E_SOURCE_INVALID "plugin manifest is missing"
  version=$(sed -n 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$manifest" |
    sed -n '1p')
  validate_semver "$version" ||
    fail E_SOURCE_INVALID "plugin manifest version is invalid"
  printf '%s\n' "$version"
}

copy_payload() {
  destination=$1
  mkdir -p "$destination"
  for name in agents core profiles release scripts compatibility.json; do
    [ -e "$SOURCE_ROOT/$name" ] ||
      fail E_SOURCE_INVALID "required payload entry is missing: $name"
    cp -R "$SOURCE_ROOT/$name" "$destination/"
  done
}

source_payload_hash() {
  stage=$WORK_DIR/source-payload
  rm -rf -- "$stage"
  copy_payload "$stage"
  ensure_no_links "$stage"
  tree_hash "$stage"
}

profile_normalize() {
  file=$1
  kind=$2
  output=$3
  [ -f "$file" ] || fail E_PROFILE_OVERRIDE_INVALID "profile file is missing: $file"
  LC_ALL=C awk -v kind="$kind" '
    function trim(value) {
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      return value
    }
    BEGIN {
      section = ""
      schema = 0
      bad = 0
    }
    {
      line = $0
      sub(/\r$/, "", line)
      sub(/[[:space:]]*#.*/, "", line)
      line = trim(line)
      if (line == "") next
      if (line ~ /^\[[A-Za-z0-9_.-]+\]$/) {
        section = line
        if (kind == "override" && section != "[routing]") bad = 1
        next
      }
      if (section == "") {
        if (line ~ /^schema_version[[:space:]]*=[[:space:]]*1$/) {
          schema++
        } else if (kind == "override") {
          bad = 1
        }
        next
      }
      if (section != "[routing]") next
      split(line, pieces, "=")
      tier = trim(pieces[1])
      if (tier !~ /^(A0|A1|B0|B1|B2|C1|C2|C3)$/) {
        bad = 1
        next
      }
      if (seen[tier]++) {
        bad = 1
        next
      }
      rhs = line
      sub(/^[^=]+=[[:space:]]*/, "", rhs)
      if (rhs !~ /^[{][[:space:]]*model[[:space:]]*=[[:space:]]*"[A-Za-z0-9._-]+"[[:space:]]*,[[:space:]]*effort[[:space:]]*=[[:space:]]*"[A-Za-z0-9._-]+"[[:space:]]*[}][[:space:]]*$/) {
        bad = 1
        next
      }
      model = rhs
      sub(/^[{][[:space:]]*model[[:space:]]*=[[:space:]]*"/, "", model)
      sub(/".*$/, "", model)
      effort = rhs
      sub(/^.*effort[[:space:]]*=[[:space:]]*"/, "", effort)
      sub(/".*$/, "", effort)
      models[tier] = model
      efforts[tier] = effort
    }
    END {
      if (schema != 1) bad = 1
      order[1] = "A0"; order[2] = "A1"; order[3] = "B0"; order[4] = "B1"
      order[5] = "B2"; order[6] = "C1"; order[7] = "C2"; order[8] = "C3"
      for (i = 1; i <= 8; i++) {
        tier = order[i]
        if (!seen[tier]) bad = 1
        if (tier == "A0") {
          if (models[tier] != "current-qualified-root" || efforts[tier] != "runtime-qualified") bad = 1
        } else {
          if (models[tier] !~ /^[A-Za-z0-9][A-Za-z0-9._-]*$/) bad = 1
          if (efforts[tier] !~ /^(medium|high|xhigh|max)$/) bad = 1
        }
      }
      if (bad) exit 42
      for (i = 1; i <= 8; i++) {
        tier = order[i]
        print tier "|" models[tier] "|" efforts[tier]
      }
    }
  ' "$file" >"$output" ||
    fail E_PROFILE_OVERRIDE_INVALID "profile must contain one valid A0-C3 routing mapping"
}

canonical_profile_from_normalized() {
  normalized=$1
  destination=$2
  {
    printf '%s\n\n' 'schema_version = 1'
    printf '%s\n' '[routing]'
    while IFS='|' read -r tier model effort; do
      printf '%s = { model = "%s", effort = "%s" }\n' "$tier" "$model" "$effort"
    done <"$normalized"
  } >"$destination"
}

active_payload_root() {
  if [ -d "$CURRENT_DIR" ] && [ -f "$CURRENT_DIR/version" ]; then
    active_version=$(read_value "$CURRENT_DIR/version")
    root=$VERSIONS_DIR/$active_version
    [ -d "$root" ] || fail E_STATE_INVALID "active version payload is missing"
    printf '%s\n' "$root"
  else
    printf '%s\n' "$SOURCE_ROOT"
  fi
}

selected_stable_profile() {
  payload=$1
  portable=$payload/profiles/portable/default.toml
  [ -f "$portable" ] && [ ! -L "$portable" ] ||
    fail E_PROFILE_INVALID "portable default profile is missing"
  selected=$(sed -n 's/^[[:space:]]*stable_profile[[:space:]]*=[[:space:]]*"\([^"]*\)"[[:space:]]*$/\1/p' \
    "$portable")
  [ "$(printf '%s\n' "$selected" | sed '/^$/d' | wc -l | tr -d ' ')" -eq 1 ] ||
    fail E_PROFILE_INVALID "portable default must select exactly one stable profile"
  case "$selected" in
    stable/*.toml) ;;
    *) fail E_PROFILE_INVALID "stable profile selection must remain under profiles/stable" ;;
  esac
  profile=$payload/profiles/$selected
  [ -f "$profile" ] && [ ! -L "$profile" ] ||
    fail E_PROFILE_INVALID "selected stable profile is missing"
  printf '%s\n' "$profile"
}

validate_effective_profile() {
  normalized=$WORK_DIR/profile-normalized
  if [ -e "$PROFILE_FILE" ]; then
    [ -f "$PROFILE_FILE" ] && [ ! -L "$PROFILE_FILE" ] ||
      fail E_PROFILE_OVERRIDE_INVALID "user override must be a regular file"
    profile_normalize "$PROFILE_FILE" override "$normalized"
    EFFECTIVE_PROFILE_SOURCE=override
    EFFECTIVE_PROFILE_PATH=$PROFILE_FILE
  else
    payload=$(active_payload_root)
    default_profile=$(selected_stable_profile "$payload")
    profile_normalize "$default_profile" default "$normalized"
    EFFECTIVE_PROFILE_SOURCE=default
    EFFECTIVE_PROFILE_PATH=$default_profile
  fi
  EFFECTIVE_PROFILE_HASH=$(sha256_file "$normalized")
}

validate_source() {
  ensure_no_links "$SOURCE_ROOT"
  base_version=$(release_version)
  [ "$base_version" = "$PUBLIC_VERSION" ] ||
    fail E_SOURCE_INVALID "public source version must remain $PUBLIC_VERSION"
  local_version=$(plugin_version)
  case "$local_version" in
    "$base_version"|"$base_version"+codex.*) ;;
    *) fail E_SOURCE_INVALID "plugin version must be $base_version or a +codex cache build" ;;
  esac
  for required in \
    core/managed-block.md \
    core/router.md \
    core/policy.md \
    core/classification.md \
    core/modes/automation.md \
    core/modes/business-operations.md \
    core/modes/content.md \
    core/modes/design.md \
    core/modes/engineering.md \
    core/modes/general.md \
    core/modes/image.md \
    core/modes/product.md \
    core/modes/research.md \
    core/modes/testing.md \
    core/modes/video.md \
    agents/roles/analyst.toml \
    agents/roles/code_writer.toml \
    agents/roles/designer.toml \
    agents/roles/docs_writer.toml \
    agents/roles/media_creator.toml \
    agents/roles/reviewer.toml \
    agents/roles/runtime_validator.toml \
    profiles/portable/default.toml \
    profiles/candidate/example-next-model.toml \
    profiles/candidate/current-gpt-5.6-no-luna-compatibility-candidate.toml \
    profiles/schema.json \
    release/manifest.json \
    scripts/routerctl.sh \
    scripts/routerctl.ps1 \
    compatibility.json; do
    [ -f "$SOURCE_ROOT/$required" ] ||
      fail E_SOURCE_INVALID "required source file is missing: $required"
  done
  for skill in recover-router router-doctor setup-router uninstall-router upgrade-router; do
    [ -f "$SOURCE_ROOT/skills/$skill/SKILL.md" ] ||
      fail E_SOURCE_INVALID "required skill is missing: $skill"
  done
  source_stable_profile=$(selected_stable_profile "$SOURCE_ROOT")
  profile_normalize "$source_stable_profile" default \
    "$WORK_DIR/source-profile"
  candidate=$SOURCE_ROOT/profiles/candidate/example-next-model.toml
  [ "$(sed -n 's/^[[:space:]]*status[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$candidate" |
    sed -n '1p')" = disabled ] &&
    [ "$(sed -n 's/^[[:space:]]*enabled[[:space:]]*=[[:space:]]*\([^[:space:]#]*\).*/\1/p' "$candidate" |
      sed -n '1p')" = false ] ||
    fail E_SOURCE_INVALID "candidate profile must remain disabled"
  SOURCE_BASE_VERSION=$base_version
  SOURCE_VERSION=$local_version
  SOURCE_PAYLOAD_HASH=$(source_payload_hash)
}

marker_count() {
  file=$1
  [ -f "$file" ] || {
    printf '%s\n' 0
    return
  }
  LC_ALL=C awk -v marker="$BEGIN_MARKER" 'index($0, marker) { count++ } END { print count + 0 }' "$file"
}

has_bom() {
  file=$1
  [ -f "$file" ] || {
    printf '%s\n' 0
    return
  }
  prefix=$(dd if="$file" bs=1 count=3 2>/dev/null | od -An -tx1 | tr -d ' \n')
  if [ "$prefix" = efbbbf ]; then
    printf '%s\n' 3
  else
    printf '%s\n' 0
  fi
}

detect_eol() {
  file=$1
  if [ -f "$file" ] && LC_ALL=C grep "$(printf '\r')" "$file" >/dev/null 2>&1; then
    printf '%s\n' crlf
  else
    printf '%s\n' lf
  fi
}

eol_bytes() {
  if [ "$1" = crlf ]; then
    printf '\r\n'
  else
    printf '\n'
  fi
}

render_block() {
  version=$1
  payload_hash=$2
  eol=$3
  destination=$4
  sed \
    -e "s/@VERSION@/$version/g" \
    -e "s/@PAYLOAD_SHA256@/$payload_hash/g" \
    "$SOURCE_ROOT/core/managed-block.md" >"$WORK_DIR/block-lf"
  if [ "$eol" = crlf ]; then
    sed 's/$//' "$WORK_DIR/block-lf" >"$destination"
  else
    cp "$WORK_DIR/block-lf" "$destination"
  fi
}

validate_managed_block() {
  [ -d "$CURRENT_DIR" ] || fail E_NOT_INSTALLED "script router state is missing"
  [ "$(read_value "$CURRENT_DIR/format")" = "$FORMAT" ] ||
    fail E_STATE_INVALID "unsupported state format"
  [ -f "$AGENTS_FILE" ] || fail E_MANAGED_BLOCK_DRIFT "AGENTS.md is missing"
  [ "$(marker_count "$AGENTS_FILE")" -eq 1 ] ||
    fail E_MANAGED_BLOCK_DRIFT "managed block must appear exactly once"
  bom=$(read_value "$CURRENT_DIR/bom_bytes")
  block_bytes=$(read_value "$CURRENT_DIR/block_bytes")
  prefix_bytes=$(read_value "$CURRENT_DIR/prefix_bytes")
  case "$bom:$block_bytes:$prefix_bytes" in
    *[!0-9:]*|:*|*:) fail E_STATE_INVALID "invalid managed byte offsets" ;;
  esac
  total=$(wc -c <"$AGENTS_FILE" | tr -d ' ')
  [ "$prefix_bytes" -le "$total" ] ||
    fail E_MANAGED_BLOCK_DRIFT "managed prefix exceeds AGENTS.md"
  dd if="$AGENTS_FILE" of="$WORK_DIR/current-block" bs=1 skip="$bom" count="$block_bytes" 2>/dev/null
  actual_block_hash=$(sha256_file "$WORK_DIR/current-block")
  [ "$actual_block_hash" = "$(read_value "$CURRENT_DIR/block_sha256")" ] ||
    fail E_MANAGED_BLOCK_DRIFT "managed block bytes changed"
  dd if="$AGENTS_FILE" of="$WORK_DIR/current-prefix" bs=1 count="$prefix_bytes" 2>/dev/null
  actual_prefix_hash=$(sha256_file "$WORK_DIR/current-prefix")
  [ "$actual_prefix_hash" = "$(read_value "$CURRENT_DIR/prefix_sha256")" ] ||
    fail E_MANAGED_BLOCK_DRIFT "managed prefix or separator changed"
}

check_global_override() {
  if [ -f "$GLOBAL_OVERRIDE" ] && [ -s "$GLOBAL_OVERRIDE" ]; then
    fail E_GLOBAL_OVERRIDE_ACTIVE \
      "non-empty global AGENTS.override.md shadows the managed AGENTS.md; it was not modified"
  fi
  [ ! -e "$GLOBAL_OVERRIDE" ] || [ -f "$GLOBAL_OVERRIDE" ] ||
    fail E_GLOBAL_OVERRIDE_ACTIVE "global override path is not a regular file"
}

is_new_install() {
  [ -d "$CURRENT_DIR" ] &&
    [ -f "$CURRENT_DIR/format" ] &&
    [ "$(sed -n '1p' "$CURRENT_DIR/format")" = "$FORMAT" ]
}

legacy_present() {
  if [ -e "$ROUTER_ROOT/current.json" ] ||
    [ -e "$ROUTER_ROOT/transaction.json" ] ||
    [ -e "$ROUTER_ROOT/safe-auto.json" ] ||
    [ -e "$ROUTER_ROOT/safe-auto.transaction.json" ]; then
    return 0
  fi
  if [ "$(marker_count "$AGENTS_FILE")" -gt 0 ] && ! is_new_install; then
    return 0
  fi
  if [ -d "$ROUTER_ROOT" ] && ! is_new_install; then
    # A disabled script-v1 installation intentionally retains payload and
    # rollback backups so `zcr enable` can work without a manual source path.
    # Those known directories are not evidence of a legacy installation.
    entries=$(find "$ROUTER_ROOT" -mindepth 1 -maxdepth 1 \
      ! -name versions ! -name backups -print -quit)
    [ -n "$entries" ] && return 0
  fi
  return 1
}

ensure_fresh_boundary() {
  if legacy_present; then
    fail E_LEGACY_INSTALL_DETECTED \
      "legacy Rust/prebuilt state detected; run legacy-cleanup --dry-run, then legacy-cleanup, then install"
  fi
}

ensure_no_transaction() {
  [ ! -d "$TRANSACTION_DIR" ] ||
    fail E_TRANSACTION_PENDING "run recover before another lifecycle operation"
}

backup_state() {
  mkdir -p "$BACKUPS_DIR"
  backup=$BACKUPS_DIR/backup-$(timestamp)-$$
  mkdir "$backup"
  if [ -f "$AGENTS_FILE" ]; then
    write_value "$backup/agents.present" 1
    cp "$AGENTS_FILE" "$backup/AGENTS.md"
    write_value "$backup/agents.sha256" "$(sha256_file "$backup/AGENTS.md")"
  else
    write_value "$backup/agents.present" 0
    write_value "$backup/agents.sha256" absent
  fi
  if [ -d "$CURRENT_DIR" ]; then
    ensure_no_links "$CURRENT_DIR"
    write_value "$backup/current.present" 1
    cp -R "$CURRENT_DIR" "$backup/current"
    write_value "$backup/current.sha256" "$(tree_hash "$backup/current")"
  else
    write_value "$backup/current.present" 0
    write_value "$backup/current.sha256" absent
  fi
  printf '%s\n' "$backup"
}

validate_backup() {
  backup=$1
  [ -d "$BACKUPS_DIR" ] && [ -d "$backup" ] ||
    fail E_TRANSACTION_INVALID "managed backup is missing"
  backups_resolved=$(CDPATH= cd -- "$BACKUPS_DIR" && pwd -P)
  backup=$(CDPATH= cd -- "$backup" && pwd -P)
  case "$backup" in
    "$backups_resolved"/backup-*) ;;
    *) fail E_TRANSACTION_INVALID "backup escapes managed directory" ;;
  esac
  [ -d "$backup" ] && [ ! -L "$backup" ] ||
    fail E_TRANSACTION_INVALID "managed backup is missing"
  ensure_no_links "$backup"
  agents_present=$(read_value "$backup/agents.present")
  if [ "$agents_present" = 1 ]; then
    [ -f "$backup/AGENTS.md" ] ||
      fail E_TRANSACTION_INVALID "AGENTS.md backup is missing"
    backup_agents_hash=$(read_value "$backup/agents.sha256")
    [ "$(sha256_file "$backup/AGENTS.md")" = "$backup_agents_hash" ] ||
      fail E_TRANSACTION_INVALID "AGENTS.md backup hash changed"
  elif [ "$agents_present" = 0 ]; then
    backup_agents_hash=$(read_value "$backup/agents.sha256")
    [ "$backup_agents_hash" = absent ] && [ ! -e "$backup/AGENTS.md" ] ||
      fail E_TRANSACTION_INVALID "invalid absent AGENTS.md backup"
  else
    fail E_TRANSACTION_INVALID "invalid AGENTS.md backup state"
  fi
  current_present=$(read_value "$backup/current.present")
  if [ "$current_present" = 1 ]; then
    [ -d "$backup/current" ] ||
      fail E_TRANSACTION_INVALID "current state backup is missing"
    backup_current_hash=$(read_value "$backup/current.sha256")
    [ "$(tree_hash "$backup/current")" = "$backup_current_hash" ] ||
      fail E_TRANSACTION_INVALID "current state backup hash changed"
  elif [ "$current_present" = 0 ]; then
    backup_current_hash=$(read_value "$backup/current.sha256")
    [ "$backup_current_hash" = absent ] && [ ! -e "$backup/current" ] ||
      fail E_TRANSACTION_INVALID "invalid absent current state backup"
  else
    fail E_TRANSACTION_INVALID "invalid current backup state"
  fi
  VALIDATED_BACKUP=$backup
  BACKUP_AGENTS_HASH=$backup_agents_hash
  BACKUP_CURRENT_HASH=$backup_current_hash
}

restore_backup() {
  backup=$1
  validate_backup "$backup"
  backup=$VALIDATED_BACKUP
  agents_present=$(read_value "$backup/agents.present")
  current_present=$(read_value "$backup/current.present")
  if [ "$agents_present" = 1 ]; then
    atomic_copy "$backup/AGENTS.md" "$AGENTS_FILE"
  else
    rm -f "$AGENTS_FILE"
  fi
  rm -rf -- "$CURRENT_DIR"
  if [ "$current_present" = 1 ]; then
    cp -R "$backup/current" "$CURRENT_DIR"
  fi
}

begin_transaction() {
  action=$1
  backup=$2
  agents_before=$3
  agents_after=$4
  current_before=$5
  current_after=$6
  remove_version=$7
  version=$8
  temporary=$ROUTER_ROOT/.transaction-$$
  rm -rf -- "$temporary"
  mkdir -p "$temporary"
  write_value "$temporary/action" "$action"
  write_value "$temporary/backup" "$backup"
  write_value "$temporary/agents_before_sha256" "$agents_before"
  write_value "$temporary/agents_after_sha256" "$agents_after"
  write_value "$temporary/current_before_sha256" "$current_before"
  write_value "$temporary/current_intermediate_sha256" absent
  write_value "$temporary/current_after_sha256" "$current_after"
  write_value "$temporary/remove_version" "$remove_version"
  write_value "$temporary/version" "$version"
  write_value "$temporary/operation_id" "$$"
  mv "$temporary" "$TRANSACTION_DIR"
}

remove_transaction_residue() {
  operation_id=$1
  case "$operation_id" in
    ''|*[!0-9]*) fail E_TRANSACTION_INVALID "invalid operation identity" ;;
  esac
  for residue in \
    "$ROUTER_ROOT/.current-$operation_id" \
    "$ROUTER_ROOT/.current-previous-$operation_id" \
    "$VERSIONS_DIR/.stage-$operation_id" \
    "$ROUTER_ROOT/.transaction-$operation_id"; do
    if [ -e "$residue" ]; then
      [ -d "$residue" ] && [ ! -L "$residue" ] ||
        fail E_TRANSACTION_INVALID "unexpected transaction residue type"
      rm -rf -- "$residue"
    fi
  done
}

state_tree_hash_optional() {
  if [ -d "$CURRENT_DIR" ]; then
    tree_hash "$CURRENT_DIR"
  elif [ ! -e "$CURRENT_DIR" ]; then
    printf '%s\n' absent
  else
    fail E_STATE_INVALID "current state is not a directory"
  fi
}

prepare_agents() {
  mode=$1
  version=$2
  payload_hash=$3
  prepared=$4
  if [ "$mode" = new ]; then
    if [ -f "$AGENTS_FILE" ]; then
      AGENTS_EXISTED_BEFORE=1
      original=$AGENTS_FILE
    elif [ ! -e "$AGENTS_FILE" ]; then
      AGENTS_EXISTED_BEFORE=0
      original=$WORK_DIR/empty-agents
      : >"$original"
    else
      fail E_PATH_INVALID "AGENTS.md is not a regular file"
    fi
    BOM_BYTES=$(has_bom "$original")
    EOL_STYLE=$(detect_eol "$original")
    remainder=$WORK_DIR/agents-remainder
    dd if="$original" of="$remainder" bs=1 skip="$BOM_BYTES" 2>/dev/null
  else
    validate_managed_block
    AGENTS_EXISTED_BEFORE=$(read_value "$CURRENT_DIR/agents_existed_before")
    BOM_BYTES=$(read_value "$CURRENT_DIR/bom_bytes")
    EOL_STYLE=$(read_value "$CURRENT_DIR/eol")
    old_prefix=$(read_value "$CURRENT_DIR/prefix_bytes")
    remainder=$WORK_DIR/agents-remainder
    dd if="$AGENTS_FILE" of="$remainder" bs=1 skip="$old_prefix" 2>/dev/null
  fi

  block=$WORK_DIR/rendered-block
  render_block "$version" "$payload_hash" "$EOL_STYLE" "$block"
  BLOCK_BYTES=$(wc -c <"$block" | tr -d ' ')
  BLOCK_SHA256=$(sha256_file "$block")
  remainder_bytes=$(wc -c <"$remainder" | tr -d ' ')
  : >"$prepared"
  if [ "$BOM_BYTES" -eq 3 ]; then
    if [ "$mode" = new ]; then
      dd if="$original" bs=1 count=3 2>/dev/null >>"$prepared"
    else
      dd if="$AGENTS_FILE" bs=1 count=3 2>/dev/null >>"$prepared"
    fi
  fi
  cat "$block" >>"$prepared"
  separator_bytes=0
  if [ "$remainder_bytes" -gt 0 ]; then
    eol_bytes "$EOL_STYLE" >>"$prepared"
    if [ "$EOL_STYLE" = crlf ]; then separator_bytes=2; else separator_bytes=1; fi
  fi
  cat "$remainder" >>"$prepared"
  PREFIX_BYTES=$((BOM_BYTES + BLOCK_BYTES + separator_bytes))
  dd if="$prepared" of="$WORK_DIR/new-prefix" bs=1 count="$PREFIX_BYTES" 2>/dev/null
  PREFIX_SHA256=$(sha256_file "$WORK_DIR/new-prefix")
  AGENTS_COMMIT_SHA256=$(sha256_file "$prepared")
}

write_current_stage() {
  stage=$1
  version=$2
  payload_hash=$3
  mkdir -p "$stage"
  write_value "$stage/format" "$FORMAT"
  write_value "$stage/public_version" "$SOURCE_BASE_VERSION"
  write_value "$stage/version" "$version"
  write_value "$stage/payload_sha256" "$payload_hash"
  write_value "$stage/installed_at" "$(timestamp)"
  write_value "$stage/agents_existed_before" "$AGENTS_EXISTED_BEFORE"
  write_value "$stage/bom_bytes" "$BOM_BYTES"
  write_value "$stage/eol" "$EOL_STYLE"
  write_value "$stage/block_bytes" "$BLOCK_BYTES"
  write_value "$stage/block_sha256" "$BLOCK_SHA256"
  write_value "$stage/prefix_bytes" "$PREFIX_BYTES"
  write_value "$stage/prefix_sha256" "$PREFIX_SHA256"
  write_value "$stage/agents_commit_sha256" "$AGENTS_COMMIT_SHA256"
}

validate_active_payload() {
  version=$(read_value "$CURRENT_DIR/version")
  expected=$(read_value "$CURRENT_DIR/payload_sha256")
  payload=$VERSIONS_DIR/$version
  [ -d "$payload" ] && [ ! -L "$payload" ] ||
    fail E_PAYLOAD_INVALID "active payload directory is missing"
  ensure_no_links "$payload"
  actual=$(tree_hash "$payload")
  [ "$actual" = "$expected" ] ||
    fail E_PAYLOAD_INVALID "active payload hash changed"
}

install_or_upgrade() {
  action=$1
  dry_run=$2
  ensure_no_transaction
  check_global_override
  validate_effective_profile
  validate_source

  if is_new_install; then
    validate_managed_block
    validate_active_payload
    current_version=$(read_value "$CURRENT_DIR/version")
    current_hash=$(read_value "$CURRENT_DIR/payload_sha256")
    if [ "$current_version" = "$SOURCE_VERSION" ] &&
      [ "$current_hash" = "$SOURCE_PAYLOAD_HASH" ]; then
      if [ "$action" = enable ]; then
        result_code=OK_ENABLED
      else
        result_code=OK_NO_CHANGE
      fi
      printf '%s\n' "code=$result_code" "action=$action" "state=enabled" \
        "impact=global-routing-active" "retry_safe=true" "version=$current_version" \
        "changed=false" "profile_source=$EFFECTIVE_PROFILE_SOURCE" \
        "profile_hash=$EFFECTIVE_PROFILE_HASH" "next_command=zcr status"
      return
    fi
    [ "$action" = upgrade ] ||
      fail E_UPGRADE_REQUIRED "a different script payload is active; use upgrade"
    prepare_mode=upgrade
  else
    ensure_fresh_boundary
    [ "$action" != upgrade ] ||
      fail E_NOT_INSTALLED "no script installation exists; use install"
    prepare_mode=new
  fi

  prepared_agents=$WORK_DIR/AGENTS.after
  prepare_agents "$prepare_mode" "$SOURCE_VERSION" "$SOURCE_PAYLOAD_HASH" "$prepared_agents"
  prepared_from_agents_hash=$(hash_optional "$AGENTS_FILE")
  prepared_from_current_hash=$(state_tree_hash_optional)
  if [ "$dry_run" -eq 1 ]; then
    printf '%s\n' "code=OK_DRY_RUN" "action=$action" "state=planned" \
      "impact=global-routing-unchanged" "retry_safe=true" "version=$SOURCE_VERSION" \
      "payload_sha256=$SOURCE_PAYLOAD_HASH" "agents_prefix_bytes=$PREFIX_BYTES" \
      "profile_source=$EFFECTIVE_PROFILE_SOURCE" "profile_hash=$EFFECTIVE_PROFILE_HASH" \
      "changed=true" "next_command=zcr enable"
    return
  fi

  acquire_lock
  ensure_no_transaction
  [ "$(hash_optional "$AGENTS_FILE")" = "$prepared_from_agents_hash" ] &&
    [ "$(state_tree_hash_optional)" = "$prepared_from_current_hash" ] ||
    fail E_COMMIT_DRIFT "AGENTS.md or current state changed between preflight and commit"
  check_global_override
  mkdir -p "$ROUTER_ROOT" "$VERSIONS_DIR" "$BACKUPS_DIR"
  backup=$(backup_state)
  version_destination=$VERSIONS_DIR/$SOURCE_VERSION
  remove_version=0
  if [ -d "$version_destination" ]; then
    existing_hash=$(tree_hash "$version_destination")
    [ "$existing_hash" = "$SOURCE_PAYLOAD_HASH" ] ||
      fail E_PAYLOAD_CONFLICT "local version path already contains different bytes"
  elif [ -e "$version_destination" ]; then
    fail E_PAYLOAD_CONFLICT "local version path is not a directory"
  else
    version_stage=$VERSIONS_DIR/.stage-$$
    rm -rf -- "$version_stage"
    copy_payload "$version_stage"
    [ "$(tree_hash "$version_stage")" = "$SOURCE_PAYLOAD_HASH" ] ||
      fail E_SOURCE_INVALID "staged payload hash changed"
    mv "$version_stage" "$version_destination"
    remove_version=1
  fi

  current_stage=$ROUTER_ROOT/.current-$$
  rm -rf -- "$current_stage"
  write_current_stage "$current_stage" "$SOURCE_VERSION" "$SOURCE_PAYLOAD_HASH"
  agents_before_hash=$(hash_optional "$AGENTS_FILE")
  agents_after_hash=$(sha256_file "$prepared_agents")
  current_before_hash=$(state_tree_hash_optional)
  current_after_hash=$(tree_hash "$current_stage")
  begin_transaction "$action" "$backup" "$agents_before_hash" "$agents_after_hash" \
    "$current_before_hash" "$current_after_hash" "$remove_version" "$SOURCE_VERSION"

  atomic_from "$prepared_agents" "$AGENTS_FILE"
  old_current=$ROUTER_ROOT/.current-previous-$$
  if [ -d "$CURRENT_DIR" ]; then
    mv "$CURRENT_DIR" "$old_current"
  fi
  mv "$current_stage" "$CURRENT_DIR"
  rm -rf -- "$old_current"
  rm -rf -- "$TRANSACTION_DIR"
  release_lock
  printf '%s\n' "code=OK_ENABLED" "action=$action" "state=enabled" \
    "impact=global-routing-active" "retry_safe=true" "version=$SOURCE_VERSION" \
    "payload_sha256=$SOURCE_PAYLOAD_HASH" "backup=$backup" "changed=true" \
    "profile_source=$EFFECTIVE_PROFILE_SOURCE" "profile_hash=$EFFECTIVE_PROFILE_HASH" \
    "next_command=zcr status"
}

parse_budget_file() {
  file=$1
  [ -f "$file" ] || return 0
  LC_ALL=C awk '
    {
      line = $0
      sub(/[[:space:]]*#.*/, "", line)
      if (line ~ /^[[:space:]]*project_doc_max_bytes[[:space:]]*=[[:space:]]*[0-9]+[[:space:]]*$/) {
        count++
        sub(/^[^=]+=[[:space:]]*/, "", line)
        sub(/[[:space:]]*$/, "", line)
        value = line
      }
    }
    END {
      if (count > 1) exit 43
      if (count == 1) print value
    }
  ' "$file" || fail E_CONFIG_INVALID "duplicate project_doc_max_bytes in $file"
}

collect_directory_chain() {
  start=$1
  output=$2
  : >"$output"
  directory=$start
  while :; do
    printf '%s\n' "$directory" >>"$output"
    [ "$directory" = "/" ] && break
    parent=$(dirname -- "$directory")
    [ "$parent" != "$directory" ] || break
    directory=$parent
  done
  awk '{ lines[NR] = $0 } END { for (i = NR; i >= 1; i--) print lines[i] }' "$output" \
    >"$output.ordered"
  mv "$output.ordered" "$output"
}

doctor_command() {
  requested_action=${1:-doctor}
  ensure_no_transaction
  if legacy_present; then
    fail E_LEGACY_INSTALL_DETECTED \
      "legacy state requires explicit legacy-cleanup before a fresh script install"
  fi
  if ! is_new_install; then
    if [ "$requested_action" = status ]; then
      result_code=OK_STATUS
      result_action=status
      result_state=disabled
      result_impact=global-routing-inactive
      next_command='zcr enable'
    else
      result_code=OK_NOT_ENABLED
      result_action=doctor
      result_state=disabled
      result_impact=global-routing-inactive
      next_command='zcr enable'
    fi
    printf '%s\n' "code=$result_code" "action=$result_action" "state=$result_state" \
      "impact=$result_impact" "retry_safe=true" "changed=false" \
      "global_override=$([ -s "$GLOBAL_OVERRIDE" ] 2>/dev/null && printf active || printf absent)" \
      "next_command=$next_command"
    return
  fi
  check_global_override
  validate_managed_block
  validate_active_payload
  validate_effective_profile

  if [ -n "$DOCTOR_CWD" ]; then
    [ -d "$DOCTOR_CWD" ] || fail E_CWD_INVALID "doctor cwd does not exist"
    resolved_cwd=$(CDPATH= cd -- "$DOCTOR_CWD" && pwd -P)
  else
    resolved_cwd=$(pwd -P)
  fi
  budget=$DEFAULT_BUDGET
  configured=$(parse_budget_file "$CODEX_HOME_ARG/config.toml")
  [ -z "$configured" ] || budget=$configured
  chain=$WORK_DIR/directory-chain
  collect_directory_chain "$resolved_cwd" "$chain"
  instruction_chain=$WORK_DIR/instruction-chain
  : >"$instruction_chain"
  while IFS= read -r directory; do
    project_config=$directory/.codex/config.toml
    configured=$(parse_budget_file "$project_config")
    [ -z "$configured" ] || budget=$configured
    if [ -s "$directory/AGENTS.override.md" ]; then
      printf 'override:%s\n' "$directory/AGENTS.override.md" >>"$instruction_chain"
    elif [ -f "$directory/AGENTS.md" ]; then
      printf 'agents:%s\n' "$directory/AGENTS.md" >>"$instruction_chain"
    fi
  done <"$chain"
  case "$budget" in
    ''|*[!0-9]*) fail E_CONFIG_INVALID "project_doc_max_bytes must be a positive integer" ;;
  esac
  [ "$budget" -gt 0 ] ||
    fail E_CONFIG_INVALID "project_doc_max_bytes must be positive"
  bom=$(read_value "$CURRENT_DIR/bom_bytes")
  block_bytes=$(read_value "$CURRENT_DIR/block_bytes")
  block_start=$bom
  block_end=$((bom + block_bytes))
  chain_count=$(wc -l <"$instruction_chain" | tr -d ' ')
  if [ "$block_end" -gt "$budget" ]; then
    fail E_MANAGED_BLOCK_OUTSIDE_INSTRUCTION_BUDGET \
      "managed block ends at byte $block_end, beyond effective budget $budget"
  fi
  if [ "$requested_action" = status ]; then
    result_code=OK_STATUS
    result_action=status
    next_command='zcr doctor'
  else
    result_code=OK_ENABLED
    result_action=doctor
    next_command='zcr status'
  fi
  printf '%s\n' "code=$result_code" "action=$result_action" "state=enabled" \
    "impact=global-routing-active" "retry_safe=true" "version=$(read_value "$CURRENT_DIR/version")" \
    "payload_sha256=$(read_value "$CURRENT_DIR/payload_sha256")" \
    "instruction_source=$AGENTS_FILE" "managed_block_start=$block_start" \
    "managed_block_end=$block_end" "project_doc_max_bytes=$budget" \
    "instruction_cwd=$resolved_cwd" "project_instruction_count=$chain_count" \
    "profile_source=$EFFECTIVE_PROFILE_SOURCE" "profile_path=$EFFECTIVE_PROFILE_PATH" \
    "profile_hash=$EFFECTIVE_PROFILE_HASH" "changed=false" "next_command=$next_command"
}

status_command() {
  # Status is deliberately non-mutating and turns the common recovery and
  # shadowing states into actionable records instead of opaque failures.
  if [ -d "$TRANSACTION_DIR" ]; then
    printf '%s\n' "code=OK_STATUS" "action=status" "state=recovery-required" \
      "impact=lifecycle-state-may-be-incomplete" "retry_safe=false" "changed=false" \
      "next_command=zcr recover"
    return
  fi
  if legacy_present; then
    printf '%s\n' "code=OK_STATUS" "action=status" "state=legacy-cleanup-required" \
      "impact=global-routing-not-modified" "retry_safe=false" "changed=false" \
      "next_command=zcr legacy-cleanup --dry-run"
    return
  fi
  if [ -e "$GLOBAL_OVERRIDE" ] && { [ ! -f "$GLOBAL_OVERRIDE" ] || [ -s "$GLOBAL_OVERRIDE" ]; }; then
    printf '%s\n' "code=OK_STATUS" "action=status" "state=shadowed" \
      "impact=managed-routing-not-effective" "retry_safe=true" "changed=false" \
      "next_command=zcr disable"
    return
  fi
  doctor_command status
}

recover_command() {
  [ -d "$TRANSACTION_DIR" ] ||
    fail E_NO_TRANSACTION "no pending transaction exists"
  acquire_lock
  backup=$(read_value "$TRANSACTION_DIR/backup")
  agents_before=$(read_value "$TRANSACTION_DIR/agents_before_sha256")
  agents_after=$(read_value "$TRANSACTION_DIR/agents_after_sha256")
  current_before=$(read_value "$TRANSACTION_DIR/current_before_sha256")
  current_intermediate=$(read_value "$TRANSACTION_DIR/current_intermediate_sha256")
  current_after=$(read_value "$TRANSACTION_DIR/current_after_sha256")
  operation_id=$(read_value "$TRANSACTION_DIR/operation_id")
  [ "$current_intermediate" = absent ] ||
    fail E_TRANSACTION_INVALID "unsupported current-state intermediate"
  validate_backup "$backup"
  [ "$BACKUP_AGENTS_HASH" = "$agents_before" ] &&
    [ "$BACKUP_CURRENT_HASH" = "$current_before" ] ||
    fail E_TRANSACTION_INVALID "transaction before hashes do not match its backup"
  actual_agents=$(hash_optional "$AGENTS_FILE")
  actual_current=$(state_tree_hash_optional)
  if [ "$actual_agents" != "$agents_before" ] && [ "$actual_agents" != "$agents_after" ]; then
    fail E_TRANSACTION_DRIFT "AGENTS.md changed outside the pending transaction"
  fi
  if [ "$actual_current" != "$current_before" ] &&
    [ "$actual_current" != "$current_intermediate" ] &&
    [ "$actual_current" != "$current_after" ]; then
    fail E_TRANSACTION_DRIFT "current state changed outside the pending transaction"
  fi
  restore_backup "$backup"
  remove_version=$(read_value "$TRANSACTION_DIR/remove_version")
  version=$(read_value "$TRANSACTION_DIR/version")
  if [ "$remove_version" = 1 ] && [ -n "$version" ]; then
    case "$version" in
      *[!0-9A-Za-z.+-]*) fail E_TRANSACTION_INVALID "invalid staged version identity" ;;
    esac
    rm -rf -- "$VERSIONS_DIR/$version"
  fi
  remove_transaction_residue "$operation_id"
  rm -rf -- "$TRANSACTION_DIR"
  if [ ! -d "$CURRENT_DIR" ] && [ "$(marker_count "$AGENTS_FILE")" -eq 0 ]; then
    rm -rf -- "$ROUTER_ROOT"
  fi
  release_lock
  printf '%s\n' "code=OK_RECOVERED" "action=recover" "backup=$backup" "changed=true"
}

rollback_command() {
  ensure_no_transaction
  is_new_install || fail E_NOT_INSTALLED "no script installation exists"
  validate_managed_block
  validate_active_payload
  expected_agents=$(read_value "$CURRENT_DIR/agents_commit_sha256")
  actual_agents=$(sha256_file "$AGENTS_FILE")
  [ "$actual_agents" = "$expected_agents" ] ||
    fail E_ROLLBACK_DRIFT "AGENTS.md changed since the completed lifecycle operation"
  prepared_from_current_hash=$(state_tree_hash_optional)
  latest=$(find "$BACKUPS_DIR" -mindepth 1 -maxdepth 1 -type d -name 'backup-*' -print |
    LC_ALL=C sort | tail -1)
  [ -n "$latest" ] || fail E_NO_BACKUP "no managed rollback backup exists"
  acquire_lock
  before_agents=$(hash_optional "$AGENTS_FILE")
  before_current=$(state_tree_hash_optional)
  [ "$before_agents" = "$expected_agents" ] &&
    [ "$before_current" = "$prepared_from_current_hash" ] ||
    fail E_COMMIT_DRIFT "AGENTS.md or current state changed between preflight and rollback"
  validate_backup "$latest"
  after_agents=$BACKUP_AGENTS_HASH
  after_current=$BACKUP_CURRENT_HASH
  safety_backup=$(backup_state)
  begin_transaction rollback "$safety_backup" "$before_agents" "$after_agents" \
    "$before_current" "$after_current" 0 "-"
  restore_backup "$latest"
  rm -rf -- "$TRANSACTION_DIR"
  if [ ! -d "$CURRENT_DIR" ] && [ "$(marker_count "$AGENTS_FILE")" -eq 0 ]; then
    rm -rf -- "$ROUTER_ROOT"
  fi
  release_lock
  printf '%s\n' "code=OK_ROLLED_BACK" "action=rollback" "backup=$latest" "changed=true" \
    "next_step=start-a-new-task"
}

prepare_uninstall_agents() {
  validate_managed_block
  prefix=$(read_value "$CURRENT_DIR/prefix_bytes")
  bom=$(read_value "$CURRENT_DIR/bom_bytes")
  prepared=$1
  : >"$prepared"
  if [ "$bom" -eq 3 ]; then
    dd if="$AGENTS_FILE" bs=1 count=3 2>/dev/null >>"$prepared"
  fi
  dd if="$AGENTS_FILE" bs=1 skip="$prefix" 2>/dev/null >>"$prepared"
}

purge_profile_if_requested() {
  purge=$1
  PROFILE_PURGE_STATE=preserved
  PROFILE_PURGE_BACKUP=absent
  if [ "$purge" -ne 1 ]; then
    return 0
  fi
  if [ ! -e "$PROFILE_FILE" ]; then
    PROFILE_PURGE_STATE=absent
    return
  fi
  [ -f "$PROFILE_FILE" ] && [ ! -L "$PROFILE_FILE" ] ||
    fail E_PROFILE_OVERRIDE_INVALID "user override must be a regular file before it can be purged"
  profile_before_hash=$(sha256_file "$PROFILE_FILE")
  acquire_lock
  [ "$(sha256_file "$PROFILE_FILE")" = "$profile_before_hash" ] ||
    fail E_PROFILE_OVERRIDE_DRIFT "override changed before purge commit"
  mkdir -p "$PROFILE_BACKUPS"
  backup=$PROFILE_BACKUPS/backup-$(timestamp)-$$.toml
  cp "$PROFILE_FILE" "$backup"
  write_value "$backup.sha256" "$(sha256_file "$backup")"
  [ "$(sha256_file "$backup")" = "$profile_before_hash" ] ||
    fail E_PROFILE_OVERRIDE_DRIFT "profile backup changed during purge"
  rm -f "$PROFILE_FILE"
  release_lock
  PROFILE_PURGE_STATE=purged
  PROFILE_PURGE_BACKUP=$backup
}

remove_managed_state() {
  action=$1
  remove_root=$2
  purge_profile=$3
  ensure_no_transaction
  if legacy_present && ! is_new_install; then
    fail E_LEGACY_INSTALL_DETECTED "use legacy-cleanup for the old Rust installation"
  fi
  changed=false
  backup=absent
  if is_new_install; then
    validate_managed_block
    validate_active_payload
    # A corrupted profile must never prevent a user from disabling routing.
    prepared=$WORK_DIR/AGENTS.$action
    prepare_uninstall_agents "$prepared"
    existed=$(read_value "$CURRENT_DIR/agents_existed_before")
    prepared_from_agents_hash=$(hash_optional "$AGENTS_FILE")
    prepared_from_current_hash=$(state_tree_hash_optional)
    acquire_lock
    [ "$(hash_optional "$AGENTS_FILE")" = "$prepared_from_agents_hash" ] &&
      [ "$(state_tree_hash_optional)" = "$prepared_from_current_hash" ] ||
      fail E_COMMIT_DRIFT "AGENTS.md or current state changed between preflight and commit"
    backup=$(backup_state)
    agents_before=$(hash_optional "$AGENTS_FILE")
    if [ "$existed" = 0 ] && [ ! -s "$prepared" ]; then
      agents_after=absent
    else
      agents_after=$(sha256_file "$prepared")
    fi
    current_before=$(state_tree_hash_optional)
    begin_transaction "$action" "$backup" "$agents_before" "$agents_after" \
      "$current_before" absent 0 "-"
    if [ "$agents_after" = absent ]; then
      rm -f "$AGENTS_FILE"
    else
      atomic_from "$prepared" "$AGENTS_FILE"
    fi
    rm -rf -- "$CURRENT_DIR"
    rm -rf -- "$TRANSACTION_DIR"
    release_lock
    changed=true
  fi
  if [ "$remove_root" -eq 1 ] && [ -d "$ROUTER_ROOT" ]; then
    # Entry points and plugin cache live outside this directory, so uninstall
    # can stay discoverable while removing all managed Router payload state.
    rm -rf -- "$ROUTER_ROOT"
  fi
  purge_profile_if_requested "$purge_profile"
  if [ "$action" = disable ]; then
    result_code=OK_DISABLED
    result_impact=global-routing-disabled
    next_command='zcr status'
  else
    result_code=OK_UNINSTALLED
    result_impact=managed-payload-removed
    next_command='zcr enable'
  fi
  printf '%s\n' "code=$result_code" "action=$action" "state=disabled" \
    "impact=$result_impact" "retry_safe=true" "changed=$changed" "backup=$backup" \
    "profile_preserved=$([ "$PROFILE_PURGE_STATE" = preserved ] && printf true || printf false)" \
    "profile_purge_state=$PROFILE_PURGE_STATE" "profile_backup=$PROFILE_PURGE_BACKUP" \
    "next_command=$next_command"
}

disable_command() {
  remove_managed_state disable 0 0
}

uninstall_command() {
  purge=0
  [ "$#" -le 1 ] || fail E_USAGE "uninstall accepts only --purge-profile"
  if [ "$#" -eq 1 ]; then
    [ "$1" = --purge-profile ] || fail E_USAGE "uninstall accepts only --purge-profile"
    purge=1
  fi
  remove_managed_state uninstall 1 "$purge"
}

legacy_offsets() {
  file=$1
  total=$(wc -c <"$file" | tr -d ' ')
  LC_ALL=C awk -v begin="$BEGIN_MARKER" -v ending="$END_MARKER" -v total="$total" '
    BEGIN { offset = 0; start = -1; finish = -1; begins = 0; ends = 0 }
    {
      bytes = length($0) + 1
      if (index($0, begin) == 1) {
        begins++
        if (start < 0) start = offset
      }
      if (index($0, ending) == 1) {
        ends++
        finish = offset + bytes
        if (finish > total) finish = total
      }
      offset += bytes
    }
    END {
      if (begins != 1 || ends != 1 || start < 0 || finish <= start) exit 44
      print start "|" finish
    }
  ' "$file" || fail E_LEGACY_BLOCK_DRIFT "legacy managed block markers are not unique and complete"
}

legacy_identity() {
  [ -f "$ROUTER_ROOT/current.json" ] ||
    fail E_LEGACY_STATE_INVALID "legacy current.json is required for hash-identified cleanup"
  legacy_version=$(sed -n 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    "$ROUTER_ROOT/current.json" | sed -n '1p')
  legacy_hash=$(sed -n 's/^[[:space:]]*"payload_sha256"[[:space:]]*:[[:space:]]*"\([0-9a-fA-F]*\)".*/\1/p' \
    "$ROUTER_ROOT/current.json" | sed -n '1p' | tr 'A-F' 'a-f')
  validate_semver "$legacy_version" ||
    fail E_LEGACY_STATE_INVALID "legacy state version is invalid"
  printf '%s\n' "$legacy_hash" | LC_ALL=C grep -Eq '^[0-9a-f]{64}$' ||
    fail E_LEGACY_STATE_INVALID "legacy state payload hash is invalid"
  begin_line=$(LC_ALL=C awk -v marker="$BEGIN_MARKER" 'index($0, marker) == 1 { print; exit }' "$AGENTS_FILE")
  case "$begin_line" in
    *" version=$legacy_version "*) ;;
    *) fail E_LEGACY_BLOCK_DRIFT "legacy block identity does not match current.json" ;;
  esac
  case "$begin_line" in
    *" sha256=$legacy_hash "*) ;;
    *) fail E_LEGACY_BLOCK_DRIFT "legacy block identity does not match current.json" ;;
  esac
  case "$begin_line" in
    *" protocol=1"*) ;;
    *) fail E_LEGACY_BLOCK_DRIFT "legacy block identity does not match current.json" ;;
  esac
  LEGACY_VERSION=$legacy_version
  LEGACY_HASH=$legacy_hash
  LEGACY_BEGIN_LINE=$begin_line
}

legacy_cleanup_command() {
  dry_run=$1
  legacy_present ||
    {
      printf '%s\n' "code=OK_NO_LEGACY_INSTALL" "action=legacy-cleanup" "changed=false"
      return
    }
  [ ! -e "$ROUTER_ROOT/transaction.json" ] ||
    fail E_LEGACY_TRANSACTION_PENDING "use the legacy controller recover command before cleanup"
  [ ! -e "$ROUTER_ROOT/safe-auto.transaction.json" ] ||
    fail E_LEGACY_SAFE_AUTO_STATE "restore the legacy safe-auto transaction before cleanup"
  [ ! -e "$ROUTER_ROOT/safe-auto.json" ] ||
    fail E_LEGACY_SAFE_AUTO_STATE "run the legacy safe-auto restore command before cleanup"
  [ -f "$AGENTS_FILE" ] ||
    fail E_LEGACY_BLOCK_DRIFT "legacy state exists but AGENTS.md is missing"
  legacy_identity
  offsets=$(legacy_offsets "$AGENTS_FILE")
  start=${offsets%|*}
  finish=${offsets#*|}
  ensure_no_links "$ROUTER_ROOT"
  legacy_agents_hash=$(sha256_file "$AGENTS_FILE")
  legacy_router_hash=$(tree_hash "$ROUTER_ROOT")
  if [ "$dry_run" -eq 1 ]; then
    printf '%s\n' "code=OK_LEGACY_CLEANUP_DRY_RUN" "action=legacy-cleanup" \
      "legacy_version=$LEGACY_VERSION" "legacy_payload_sha256=$LEGACY_HASH" \
      "managed_block_start=$start" "managed_block_end=$finish" \
      "changed=false" "next_step=run-legacy-cleanup-then-fresh-install"
    return
  fi

  acquire_lock
  [ "$(sha256_file "$AGENTS_FILE")" = "$legacy_agents_hash" ] &&
    [ "$(tree_hash "$ROUTER_ROOT")" = "$legacy_router_hash" ] ||
    fail E_COMMIT_DRIFT "legacy AGENTS.md or Router state changed before cleanup"
  backup_root=$CODEX_HOME_ARG/z-codex-router-legacy-backups/backup-$(timestamp)-$$
  mkdir -p "$backup_root"
  cp "$AGENTS_FILE" "$backup_root/AGENTS.md"
  if [ -f "$CODEX_HOME_ARG/config.toml" ]; then
    cp "$CODEX_HOME_ARG/config.toml" "$backup_root/config.toml"
  fi
  cp -R "$ROUTER_ROOT" "$backup_root/router-state"
  write_value "$backup_root/agents.sha256" "$(sha256_file "$backup_root/AGENTS.md")"
  write_value "$backup_root/legacy.version" "$LEGACY_VERSION"
  write_value "$backup_root/legacy.payload_sha256" "$LEGACY_HASH"

  separator=empty
  case "$LEGACY_BEGIN_LINE" in
    *" separator=two-newlines "*) separator=two ;;
    *" separator=one-newline "*) separator=one ;;
  esac
  adjusted_start=$start
  if [ "$start" -gt 3 ]; then
    if [ "$separator" = two ] && [ "$start" -ge 2 ]; then
      adjusted_start=$((start - 2))
    elif [ "$separator" = one ] && [ "$start" -ge 1 ]; then
      adjusted_start=$((start - 1))
    fi
  fi
  prepared=$WORK_DIR/AGENTS.legacy-clean
  : >"$prepared"
  dd if="$AGENTS_FILE" bs=1 count="$adjusted_start" 2>/dev/null >>"$prepared"
  total=$(wc -c <"$AGENTS_FILE" | tr -d ' ')
  adjusted_finish=$finish
  if [ "$start" -le 3 ] && [ "$finish" -lt "$total" ]; then
    if [ "$separator" = two ]; then
      adjusted_finish=$((finish + 2))
    elif [ "$separator" = one ]; then
      adjusted_finish=$((finish + 1))
    fi
    [ "$adjusted_finish" -le "$total" ] || adjusted_finish=$total
  fi
  dd if="$AGENTS_FILE" bs=1 skip="$adjusted_finish" 2>/dev/null >>"$prepared"
  if [ ! -s "$prepared" ]; then
    rm -f "$AGENTS_FILE"
  else
    atomic_from "$prepared" "$AGENTS_FILE"
  fi
  rm -rf -- "$ROUTER_ROOT"
  release_lock
  printf '%s\n' "code=OK_LEGACY_CLEANED" "action=legacy-cleanup" \
    "legacy_version=$LEGACY_VERSION" "backup=$backup_root" "changed=true" \
    "next_step=run-fresh-install"
}

profile_command() {
  operation=$1
  shift
  case "$operation" in
    show|validate)
      validate_effective_profile
      b2=$(awk -F'|' '$1 == "B2" { print $2 " " $3; exit }' "$WORK_DIR/profile-normalized")
      set -- $b2
      printf '%s\n' "code=OK_PROFILE" "action=profile-$operation" \
        "profile_source=$EFFECTIVE_PROFILE_SOURCE" "profile_path=$EFFECTIVE_PROFILE_PATH" \
        "profile_hash=$EFFECTIVE_PROFILE_HASH" "state=profile-ready" \
        "impact=profile-effective" "retry_safe=true" "changed=false" \
        "next_command=zcr profile set B2 $1 $2"
      cat "$WORK_DIR/profile-normalized"
      ;;
    init)
      [ ! -e "$PROFILE_FILE" ] ||
        fail E_PROFILE_OVERRIDE_EXISTS "user override already exists"
      validate_effective_profile
      acquire_lock
      [ ! -e "$PROFILE_FILE" ] ||
        fail E_PROFILE_OVERRIDE_EXISTS "user override appeared before commit"
      canonical=$WORK_DIR/profile.toml
      canonical_profile_from_normalized "$WORK_DIR/profile-normalized" "$canonical"
      atomic_from "$canonical" "$PROFILE_FILE"
      release_lock
      profile_normalize "$PROFILE_FILE" override "$WORK_DIR/profile-created"
      printf '%s\n' "code=OK_PROFILE_INITIALIZED" "action=profile-init" \
        "profile_path=$PROFILE_FILE" "profile_hash=$(sha256_file "$WORK_DIR/profile-created")" \
        "state=profile-customized" "impact=profile-override-created" "retry_safe=true" \
        "changed=true" "next_command=zcr profile show"
      ;;
    set)
      [ "$#" -eq 3 ] || fail E_USAGE "profile set needs TIER MODEL EFFORT"
      tier=$1
      model=$2
      effort=$3
      requested_tier=$tier
      requested_model=$model
      requested_effort=$effort
      case "$tier" in A0|A1|B0|B1|B2|C1|C2|C3) ;; *) fail E_PROFILE_OVERRIDE_INVALID "unknown tier" ;; esac
      if [ "$tier" = A0 ]; then
        [ "$model" = current-qualified-root ] && [ "$effort" = runtime-qualified ] ||
          fail E_PROFILE_OVERRIDE_INVALID "A0 semantics are fixed"
      else
        printf '%s\n' "$model" | LC_ALL=C grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]*$' ||
          fail E_PROFILE_OVERRIDE_INVALID "invalid model token"
        case "$effort" in medium|high|xhigh|max) ;; *) fail E_PROFILE_OVERRIDE_INVALID "invalid effort" ;; esac
      fi
      validate_effective_profile
      profile_before_hash=$(hash_optional "$PROFILE_FILE")
      updated=$WORK_DIR/profile-updated-normalized
      awk -F'|' -v wanted="$tier" -v model="$model" -v effort="$effort" '
        $1 == wanted { print wanted "|" model "|" effort; next }
        { print }
      ' "$WORK_DIR/profile-normalized" >"$updated"
      canonical=$WORK_DIR/profile-updated.toml
      canonical_profile_from_normalized "$updated" "$canonical"
      profile_normalize "$canonical" override "$WORK_DIR/profile-updated-checked"
      acquire_lock
      [ "$(hash_optional "$PROFILE_FILE")" = "$profile_before_hash" ] ||
        fail E_PROFILE_OVERRIDE_DRIFT "override changed before profile set commit"
      atomic_from "$canonical" "$PROFILE_FILE"
      release_lock
      printf '%s\n' "code=OK_PROFILE_SET" "action=profile-set" "tier=$requested_tier" \
        "model=$requested_model" "effort=$requested_effort" \
        "profile_path=$PROFILE_FILE" \
        "profile_hash=$(sha256_file "$WORK_DIR/profile-updated-checked")" \
        "state=profile-customized" "impact=profile-override-updated" "retry_safe=true" \
        "changed=true" "next_command=zcr profile show"
      ;;
    reset)
      [ -f "$PROFILE_FILE" ] && [ ! -L "$PROFILE_FILE" ] ||
        fail E_PROFILE_OVERRIDE_MISSING "user override does not exist"
      profile_normalize "$PROFILE_FILE" override "$WORK_DIR/profile-reset-checked"
      profile_before_hash=$(sha256_file "$PROFILE_FILE")
      acquire_lock
      [ "$(sha256_file "$PROFILE_FILE")" = "$profile_before_hash" ] ||
        fail E_PROFILE_OVERRIDE_DRIFT "override changed before reset commit"
      mkdir -p "$PROFILE_BACKUPS"
      backup=$PROFILE_BACKUPS/backup-$(timestamp)-$$.toml
      cp "$PROFILE_FILE" "$backup"
      write_value "$backup.sha256" "$(sha256_file "$backup")"
      [ "$(sha256_file "$PROFILE_FILE")" = "$(sha256_file "$backup")" ] ||
        fail E_PROFILE_OVERRIDE_DRIFT "override changed while reset backup was created"
      rm "$PROFILE_FILE"
      release_lock
      printf '%s\n' "code=OK_PROFILE_RESET" "action=profile-reset" "backup=$backup" \
        "state=profile-defaulted" "impact=profile-override-backed-up" "retry_safe=true" \
        "changed=true" "next_command=zcr profile restore $backup"
      ;;
    restore)
      [ "$#" -eq 1 ] || fail E_USAGE "profile restore needs BACKUP"
      requested=$1
      [ ! -e "$PROFILE_FILE" ] ||
        fail E_PROFILE_OVERRIDE_EXISTS "refusing to overwrite an existing user override"
      [ -d "$PROFILE_BACKUPS" ] && [ -f "$requested" ] ||
        fail E_PROFILE_BACKUP_INVALID "backup or managed backup directory is missing"
      profile_backups_resolved=$(CDPATH= cd -- "$PROFILE_BACKUPS" && pwd -P)
      requested_parent=$(CDPATH= cd -- "$(dirname -- "$requested")" && pwd -P)
      requested=$requested_parent/$(basename -- "$requested")
      case "$requested" in
        "$profile_backups_resolved"/backup-*.toml) ;;
        *) fail E_PROFILE_BACKUP_INVALID "backup must be inside the managed backup directory" ;;
      esac
      [ -f "$requested" ] && [ ! -L "$requested" ] && [ -f "$requested.sha256" ] ||
        fail E_PROFILE_BACKUP_INVALID "backup or checksum metadata is missing"
      expected=$(read_value "$requested.sha256")
      [ "$(sha256_file "$requested")" = "$expected" ] ||
        fail E_PROFILE_BACKUP_INVALID "backup hash changed"
      profile_normalize "$requested" override "$WORK_DIR/profile-restore-checked"
      acquire_lock
      [ ! -e "$PROFILE_FILE" ] ||
        fail E_PROFILE_OVERRIDE_EXISTS "user override appeared before restore commit"
      atomic_copy "$requested" "$PROFILE_FILE"
      release_lock
      printf '%s\n' "code=OK_PROFILE_RESTORED" "action=profile-restore" \
        "profile_path=$PROFILE_FILE" \
        "profile_hash=$(sha256_file "$WORK_DIR/profile-restore-checked")" \
        "state=profile-customized" "impact=profile-backup-restored" "retry_safe=true" \
        "changed=true" "next_command=zcr status"
      ;;
    backups)
      [ "$#" -eq 0 ] || fail E_USAGE "profile backups takes no arguments"
      if [ ! -d "$PROFILE_BACKUPS" ]; then
        printf '%s\n' "code=OK_PROFILE_BACKUPS" "action=profile-backups" \
          "state=profile-ready" "impact=no-profile-backups" "retry_safe=true" \
          "backup_count=0" "changed=false" "next_command=zcr profile init"
        return
      fi
      find "$PROFILE_BACKUPS" -mindepth 1 -maxdepth 1 -type f -name 'backup-*.toml' -print |
        LC_ALL=C sort >"$WORK_DIR/profile-backups"
      backup_count=$(wc -l <"$WORK_DIR/profile-backups" | tr -d ' ')
      if [ "$backup_count" -eq 0 ]; then
        printf '%s\n' "code=OK_PROFILE_BACKUPS" "action=profile-backups" \
          "state=profile-ready" "impact=no-profile-backups" "retry_safe=true" \
          "backup_count=0" "changed=false" "next_command=zcr profile init"
      else
        first_backup=$(sed -n '1p' "$WORK_DIR/profile-backups")
        printf '%s\n' "code=OK_PROFILE_BACKUPS" "action=profile-backups" \
          "state=profile-ready" "impact=managed-profile-backups-available" "retry_safe=true" \
          "backup_count=$backup_count" "changed=false" \
          "next_command=zcr profile restore $first_backup"
        while IFS= read -r profile_backup; do
          printf '%s\n' "backup=$profile_backup"
        done <"$WORK_DIR/profile-backups"
      fi
      ;;
    *) fail E_USAGE "unknown profile command: $operation" ;;
  esac
}

need_command awk
need_command sed
need_command grep
need_command find
need_command sort
need_command dd
need_command od
need_command tr
need_command wc
need_command mktemp
need_command cp
need_command mv
need_command rm
need_command dirname
need_command basename
need_command date
need_command tail

while [ "$#" -gt 0 ]; do
  case "$1" in
    --source)
      [ "$#" -ge 2 ] || fail E_USAGE "--source needs a path"
      SOURCE_ROOT=$2
      shift 2
      ;;
    --codex-home)
      [ "$#" -ge 2 ] || fail E_USAGE "--codex-home needs a path"
      CODEX_HOME_ARG=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      fail E_USAGE "unknown global option: $1"
      ;;
    *)
      break
      ;;
  esac
done

[ "$#" -ge 1 ] || {
  usage >&2
  exit 2
}
COMMAND=$1
shift
resolve_paths

case "$COMMAND" in
  dry-run)
    [ "$#" -eq 0 ] || fail E_USAGE "dry-run takes no arguments"
    install_or_upgrade install 1
    ;;
  install)
    [ "$#" -eq 0 ] || fail E_USAGE "install takes no arguments"
    install_or_upgrade install 0
    ;;
  enable)
    [ "$#" -eq 0 ] || fail E_USAGE "enable takes no arguments"
    install_or_upgrade enable 0
    ;;
  disable)
    [ "$#" -eq 0 ] || fail E_USAGE "disable takes no arguments"
    disable_command
    ;;
  status)
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --cwd)
          [ "$#" -ge 2 ] || fail E_USAGE "--cwd needs a path"
          DOCTOR_CWD=$2
          shift 2
          ;;
        *) fail E_USAGE "unknown status option: $1" ;;
      esac
    done
    status_command
    ;;
  doctor)
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --cwd)
          [ "$#" -ge 2 ] || fail E_USAGE "--cwd needs a path"
          DOCTOR_CWD=$2
          shift 2
          ;;
        *) fail E_USAGE "unknown doctor option: $1" ;;
      esac
    done
    doctor_command
    ;;
  upgrade)
    dry=0
    if [ "$#" -gt 0 ]; then
      [ "$1" = --dry-run ] && [ "$#" -eq 1 ] ||
        fail E_USAGE "upgrade accepts only --dry-run"
      dry=1
    fi
    install_or_upgrade upgrade "$dry"
    ;;
  recover)
    [ "$#" -eq 0 ] || fail E_USAGE "recover takes no arguments"
    recover_command
    ;;
  rollback)
    [ "$#" -eq 0 ] || fail E_USAGE "rollback takes no arguments"
    rollback_command
    ;;
  uninstall)
    uninstall_command "$@"
    ;;
  legacy-cleanup)
    dry=0
    if [ "$#" -gt 0 ]; then
      [ "$1" = --dry-run ] && [ "$#" -eq 1 ] ||
        fail E_USAGE "legacy-cleanup accepts only --dry-run"
      dry=1
    fi
    legacy_cleanup_command "$dry"
    ;;
  profile)
    [ "$#" -ge 1 ] || fail E_USAGE "profile needs a subcommand"
    operation=$1
    shift
    profile_command "$operation" "$@"
    ;;
  *)
    fail E_USAGE "unknown command: $COMMAND"
    ;;
esac
