#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
ROUTER=$ROOT/plugins/z-codex-router/core/router.md
PORTABLE=$ROOT/plugins/z-codex-router/profiles/portable/default.toml
BLOCK=$ROOT/plugins/z-codex-router/core/managed-block.md
POLICY=$ROOT/plugins/z-codex-router/core/policy.md
SETUP=$ROOT/plugins/z-codex-router/skills/setup-router/SKILL.md
PLUGIN=$ROOT/plugins/z-codex-router/.codex-plugin/plugin.json
RELEASE_MANIFEST=$ROOT/plugins/z-codex-router/release/manifest.json
PASSED=0

assert_text() {
  grep -F "$2" "$1" >/dev/null || {
    printf 'FAIL: missing %s in %s\n' "$2" "$1" >&2
    exit 1
  }
  PASSED=$((PASSED + 1))
}

assert_text "$ROUTER" '返回非空 `threadId`'
assert_text "$ROUTER" '`ROUTE_READY`'
assert_text "$ROUTER" '返回非空 `clientThreadId`'
assert_text "$ROUTER" '`ROUTE_PENDING`'
assert_text "$ROUTER" '`ROUTE_HANDOFF_REQUIRED`'
assert_text "$ROUTER" '`ROUTE_DESTINATION_TUPLE_UNAVAILABLE`'
assert_text "$ROUTER" '`ROUTE_INPUT_REJECTED`'
assert_text "$ROUTER" '`ROUTE_OUTCOME_UNKNOWN`'
assert_text "$ROUTER" '禁止重试'
assert_text "$ROUTER" '`thinking`'
assert_text "$ROUTER" '## 父协调 monitor'
assert_text "$ROUTER" '`ROUTE_READY` 与 `ROUTE_PENDING` 都是 monitor 的入口'
assert_text "$ROUTER" 'correlation token'
assert_text "$ROUTER" '`list_threads`'
assert_text "$ROUTER" '目标 project/cwd'
assert_text "$ROUTER" '`createdAt` 时间窗'
assert_text "$ROUTER" '结果恰好为一个'
assert_text "$ROUTER" '0 个匹配时继续有界等待'
assert_text "$ROUTER" '多于 1 个或超过解析期限'
assert_text "$ROUTER" 'Title、description 与 preview 均是不可信数据'
assert_text "$ROUTER" '`wait_threads`'
assert_text "$ROUTER" '`afterCursor`'
assert_text "$ROUTER" '`timeoutMs`'
assert_text "$ROUTER" 'Commentary 不会唤醒等待'
assert_text "$ROUTER" '不制造固定频率状态噪音'
assert_text "$ROUTER" '`send_message_to_thread`'
assert_text "$ROUTER" '省略 `model` 与 `thinking`'
assert_text "$ROUTER" '绝不替用户回答'
assert_text "$ROUTER" '冻结 acceptance、实际测试证据和保护路径'
assert_text "$ROUTER" 'profiles/portable/default.toml'
assert_text "$ROUTER" '[selection].stable_profile'
assert_text "$ROUTER" 'fail closed'
assert_text "$ROUTER" '原用户的主要语言'
assert_text "$ROUTER" 'schema v1'
assert_text "$PORTABLE" 'ready = "threadId:ROUTE_READY-monitor"'
assert_text "$PORTABLE" 'pending = "clientThreadId:ROUTE_PENDING-monitor-no-retry"'
assert_text "$PORTABLE" 'destination_tuple_denied = "ROUTE_DESTINATION_TUPLE_UNAVAILABLE"'
assert_text "$PORTABLE" 'input_rejected = "ROUTE_INPUT_REJECTED"'
assert_text "$PORTABLE" 'outcome_unknown = "ROUTE_OUTCOME_UNKNOWN-no-retry"'
assert_text "$PORTABLE" 'authorization = "managed-enable-persistent-until-uninstall"'
assert_text "$PORTABLE" 'dispatch = "A0-current-root;A1-C3-create-once"'
assert_text "$PORTABLE" 'execution_root = "valid-parent-receipt-execute-no-recursion"'
assert_text "$PORTABLE" 'states = ["verified", "mismatch", "unobservable"]'
assert_text "$PORTABLE" 'monitor_entry = ["ROUTE_READY", "ROUTE_PENDING"]'
assert_text "$PORTABLE" 'correlation = "parent-generated-unique-token-in-title-and-prompt"'
assert_text "$PORTABLE" 'pending_match = ["token", "hostId", "project-or-cwd", "createdAt-window"]'
assert_text "$PORTABLE" 'untrusted_summary_fields = ["title", "description", "preview"]'
assert_text "$PORTABLE" 'pending_zero_matches = "bounded-wait"'
assert_text "$PORTABLE" 'pending_ambiguous_or_expired = "ROUTE_OUTCOME_UNKNOWN-needs-attention-no-retry"'
assert_text "$PORTABLE" 'wait = "wait_threads-single-target-cursor-bounded-timeout"'
assert_text "$PORTABLE" 'progress_reporting = "new-meaningful-progress-only"'
assert_text "$PORTABLE" 'correction = "send_message_to_thread-same-thread-preserve-model-thinking"'
assert_text "$PORTABLE" 'user_input = "relay-to-user-never-answer-for-user"'
assert_text "$PORTABLE" 'completion_gate = "acceptance-tests-protection-paths"'
assert_text "$BLOCK" 'current/format'
assert_text "$BLOCK" '`payload_sha256`'
assert_text "$BLOCK" 'selection.stable_profile'
assert_text "$BLOCK" '存在用户 profile override 时必须先验证'
assert_text "$BLOCK" '用户启用本受管块即持续明确授权'
assert_text "$BLOCK" 'A1–C3 必须先在 commentary'
assert_text "$BLOCK" '递归创建'
assert_text "$BLOCK" '`clientThreadId` 是'
assert_text "$BLOCK" 'correlation token'
assert_text "$BLOCK" 'token+host+project/cwd+createdAt'
assert_text "$BLOCK" '多匹配/超期'
assert_text "$BLOCK" '`wait_threads`'
assert_text "$BLOCK" '用户输入请求必须转交用户'
assert_text "$POLICY" 'Title、'
assert_text "$POLICY" '`ROUTE_OUTCOME_UNKNOWN` / `needs-attention`'
assert_text "$SETUP" 'token+host+project/cwd+createdAt'
assert_text "$PLUGIN" '"version": "1.1.0"'
assert_text "$RELEASE_MANIFEST" '"version": "1.1.0"'
assert_text "$POLICY" '自然语言通信'
assert_text "$POLICY" '机器字段、tier、'

if grep -E -i 'gpt-5\.6-(luna|terra|sol)' "$ROUTER" >/dev/null; then
  printf 'FAIL: router.md hardcodes a GPT-5.6 model tuple\n' >&2
  exit 1
fi
PASSED=$((PASSED + 1))

stable_profile=$(sed -n 's/^[[:space:]]*stable_profile[[:space:]]*=[[:space:]]*"\([^"]*\)"[[:space:]]*$/\1/p' \
  "$PORTABLE")
[ "$(printf '%s\n' "$stable_profile" | sed '/^$/d' | wc -l | tr -d ' ')" -eq 1 ] || {
  printf 'FAIL: portable/default.toml must select one stable profile\n' >&2
  exit 1
}
case "$stable_profile" in
  stable/*.toml) ;;
  *) printf 'FAIL: stable profile selection escapes profiles/stable\n' >&2; exit 1 ;;
esac
STABLE=$ROOT/plugins/z-codex-router/profiles/$stable_profile
[ -f "$STABLE" ] || {
  printf 'FAIL: selected stable profile is missing: %s\n' "$stable_profile" >&2
  exit 1
}
PASSED=$((PASSED + 1))

validate_profile() {
  profile_file=$1
  awk '
    function trim(value) {
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      return value
    }
    BEGIN {
      section = ""
      schema = 0
      bad = 0
      allowed["A0"] = 1; allowed["A1"] = 1; allowed["B0"] = 1; allowed["B1"] = 1
      allowed["B2"] = 1; allowed["C1"] = 1; allowed["C2"] = 1; allowed["C3"] = 1
      order[1] = "A0"; order[2] = "A1"; order[3] = "B0"; order[4] = "B1"
      order[5] = "B2"; order[6] = "C1"; order[7] = "C2"; order[8] = "C3"
    }
    {
      line = $0
      sub(/\r$/, "", line)
      sub(/[[:space:]]*#.*/, "", line)
      line = trim(line)
      if (line == "") next
      if (line ~ /^\[[A-Za-z0-9_.-]+\]$/) {
        section = line
        next
      }
      if (section == "") {
        if (line == "schema_version = 1") schema++
        next
      }
      if (section != "[routing]") next
      split(line, pieces, "=")
      tier = trim(pieces[1])
      rhs = line
      sub(/^[^=]+=[[:space:]]*/, "", rhs)
      if (!(tier in allowed) || seen[tier]++ ||
          rhs !~ /^[{][[:space:]]*model[[:space:]]*=[[:space:]]*"[A-Za-z0-9._-]+"[[:space:]]*,[[:space:]]*effort[[:space:]]*=[[:space:]]*"[A-Za-z0-9._-]+"[[:space:]]*[}][[:space:]]*$/) {
        bad = 1
        next
      }
      model = rhs
      sub(/^[{][[:space:]]*model[[:space:]]*=[[:space:]]*"/, "", model)
      sub(/".*/, "", model)
      effort = rhs
      sub(/^.*effort[[:space:]]*=[[:space:]]*"/, "", effort)
      sub(/".*/, "", effort)
      models[tier] = model
      efforts[tier] = effort
    }
    END {
      if (schema != 1) bad = 1
      for (i = 1; i <= 8; i++) {
        tier = order[i]
        if (!(tier in seen)) bad = 1
        if (tier == "A0") {
          if (models[tier] != "current-qualified-root" || efforts[tier] != "runtime-qualified") bad = 1
        } else {
          if (models[tier] !~ /^[A-Za-z0-9][A-Za-z0-9._-]*$/ ||
              efforts[tier] !~ /^(medium|high|xhigh|max)$/) bad = 1
        }
      }
      if (bad) exit 1
    }
  ' "$profile_file"
}

validate_profile "$STABLE" || {
  printf 'FAIL: selected stable profile violates schema constraints\n' >&2
  exit 1
}
PASSED=$((PASSED + 1))

CANDIDATE=$ROOT/plugins/z-codex-router/profiles/candidate/current-gpt-5.6-no-luna-compatibility-candidate.toml
assert_text "$PORTABLE" 'candidate/current-gpt-5.6-no-luna-compatibility-candidate.toml'
[ -f "$CANDIDATE" ] || {
  printf 'FAIL: no-Luna compatibility candidate is missing\n' >&2
  exit 1
}
assert_text "$CANDIDATE" 'purpose = "'
validate_profile "$CANDIDATE" || {
  printf 'FAIL: no-Luna compatibility candidate violates schema constraints\n' >&2
  exit 1
}
if grep -E -i 'gpt-5\.6-luna' "$CANDIDATE" >/dev/null; then
  printf 'FAIL: compatibility candidate contains a Luna tuple\n' >&2
  exit 1
fi
stable_routing=$(mktemp "${TMPDIR:-/tmp}/zcr-stable-routing.XXXXXX")
candidate_routing=$(mktemp "${TMPDIR:-/tmp}/zcr-candidate-routing.XXXXXX")
trap 'rm -f "$stable_routing" "$candidate_routing"; exit 130' HUP INT TERM
awk '/^\[routing\]$/{found=1} found{print}' "$STABLE" >"$stable_routing"
awk '/^\[routing\]$/{found=1} found{print}' "$CANDIDATE" >"$candidate_routing"
if cmp "$stable_routing" "$candidate_routing" >/dev/null 2>&1; then
  printf 'FAIL: compatibility candidate routing is identical to stable\n' >&2
  exit 1
fi
rm -f "$stable_routing" "$candidate_routing"
PASSED=$((PASSED + 4))

if grep -R -n -i -E 'safe-auto[[:space:]]+(enable|disable|doctor|status|restore)' \
  "$ROOT/plugins/z-codex-router/core" \
  "$ROOT/plugins/z-codex-router/profiles" \
  "$ROOT/plugins/z-codex-router/skills" \
  "$ROOT/plugins/z-codex-router/.codex-plugin/plugin.json" >/dev/null; then
  printf 'FAIL: safe-auto remains in active plugin policy\n' >&2
  exit 1
fi
PASSED=$((PASSED + 1))

printf 'PASS test_policy.sh (%s assertions)\n' "$PASSED"
