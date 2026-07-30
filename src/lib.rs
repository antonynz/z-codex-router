use directories::BaseDirs;
use semver::Version;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use std::env;
use std::fs;
use std::io::Write;
use std::path::{Component, Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};
use tempfile::NamedTempFile;
use thiserror::Error;
use toml_edit::{DocumentMut, Item, Table};
use walkdir::WalkDir;

const ROUTER_ID: &str = "z-codex-router";
const PROTOCOL: u8 = 1;
const TIER_NAMES: [&str; 8] = ["A0", "A1", "B0", "B1", "B2", "C1", "C2", "C3"];
const USER_PROFILE_FILE: &str = "z-codex-router-profile.toml";
const USER_PROFILE_BACKUP_DIRECTORY: &str = "z-codex-router-profile-backups";

#[derive(Debug, Error)]
pub enum RouterError {
    #[error("{message}")]
    Coded { code: &'static str, message: String },
    #[error("I/O 错误：{0}")]
    Io(#[from] std::io::Error),
    #[error("JSON 错误：{0}")]
    Json(#[from] serde_json::Error),
}

impl RouterError {
    fn coded(code: &'static str, message: impl Into<String>) -> Self {
        Self::Coded {
            code,
            message: message.into(),
        }
    }

    pub fn code(&self) -> &'static str {
        match self {
            Self::Coded { code, .. } => code,
            Self::Io(_) => "E_IO",
            Self::Json(_) => "E_DATA",
        }
    }

    pub fn exit_code(&self) -> i32 {
        match self.code() {
            "E_NOT_INSTALLED" => 3,
            "E_MANAGED_BLOCK_DRIFT" => 4,
            "E_PERMISSION" => 5,
            "E_SOURCE_INVALID" | "E_SOURCE_CHECKSUM" | "E_PROFILE_INCOMPATIBLE" => 6,
            _ => 2,
        }
    }
}

pub type Result<T> = std::result::Result<T, RouterError>;

#[derive(Clone, Debug)]
pub enum Command {
    DryRun,
    Install,
    Doctor,
    Upgrade {
        dry_run: bool,
    },
    Recover,
    Rollback,
    Uninstall,
    ProfileShow,
    ProfileInit,
    ProfileValidate,
    ProfileReset,
    ProfileRestore {
        backup: PathBuf,
    },
    ProfileSet {
        tier: String,
        model: String,
        effort: String,
    },
    SafeAutoEnable,
    SafeAutoRestore,
    SafeAutoStatus,
    SafeAutoDoctor,
}

#[derive(Clone, Debug)]
pub struct Options {
    pub source: Option<PathBuf>,
    pub codex_home: Option<PathBuf>,
    pub command: Command,
}

#[derive(Debug, Serialize)]
pub struct Outcome {
    pub ok: bool,
    pub action: String,
    pub code: String,
    pub version: Option<String>,
    pub changed: bool,
    pub backup: Option<String>,
    pub details: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub profile: Option<ProfileReport>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct Route {
    pub model: String,
    pub effort: String,
}

#[derive(Clone, Debug, Serialize)]
pub struct ProfileReport {
    pub source: String,
    pub path: String,
    pub mapping_sha256: String,
    pub routing: BTreeMap<String, Route>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ReleaseManifest {
    schema_version: u8,
    version: String,
    channel: String,
    payload_sha256: String,
}

#[derive(Debug, Deserialize)]
struct PluginManifest {
    version: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
struct State {
    version: String,
    payload_sha256: String,
    installed_at_unix_ns: u128,
    #[serde(default)]
    agents_existed_before: bool,
    #[serde(default)]
    managed_separator: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
struct Backup {
    agents: Option<String>,
    current: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
struct ProfileBackup {
    protocol: u8,
    override_sha256: String,
}

#[derive(Debug, Serialize, Deserialize)]
struct Journal {
    protocol: u8,
    operation: String,
    backup: String,
    #[serde(default)]
    expected_agents_sha256: Option<String>,
    #[serde(default)]
    expected_current_sha256: Option<String>,
    #[serde(default)]
    created_version: Option<String>,
    #[serde(default)]
    created_payload_sha256: Option<String>,
    #[serde(default)]
    replaced_version_backup: Option<String>,
    #[serde(default)]
    replaced_version: Option<String>,
}

const SAFE_AUTO_KEYS: [&str; 3] = ["sandbox_mode", "approval_policy", "approvals_reviewer"];
const SAFE_AUTO_VALUES: [&str; 3] = ["workspace-write", "on-request", "auto_review"];

#[derive(Clone, Debug, Serialize, Deserialize)]
struct SafeAutoState {
    protocol: u8,
    config_existed_before: bool,
    original: BTreeMap<String, Option<String>>,
    managed: BTreeMap<String, String>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
struct SafeAutoJournal {
    protocol: u8,
    operation: String,
    before_hash: String,
    after_hash: String,
    state: SafeAutoState,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum SafeAutoStatus {
    Active,
    Drift,
    Absent,
}

#[derive(Debug)]
struct SourceRelease {
    root: PathBuf,
    manifest: ReleaseManifest,
}

pub fn execute(options: Options) -> Result<Outcome> {
    let home = resolve_home(options.codex_home)?;
    match options.command {
        Command::Doctor => doctor(&home),
        Command::Recover => recover(&home),
        Command::Rollback => rollback(&home),
        Command::Uninstall => uninstall(&home),
        Command::ProfileShow => profile_show(&home),
        Command::ProfileInit => profile_init(&home),
        Command::ProfileValidate => profile_validate(&home),
        Command::ProfileReset => profile_reset(&home),
        Command::ProfileRestore { backup } => profile_restore(&home, &backup),
        Command::ProfileSet {
            tier,
            model,
            effort,
        } => profile_set(&home, &tier, &model, &effort),
        Command::DryRun => install(&home, load_source(options.source)?, true, false),
        Command::Install => install(&home, load_source(options.source)?, false, false),
        Command::Upgrade { dry_run } => install(&home, load_source(options.source)?, dry_run, true),
        Command::SafeAutoEnable => safe_auto_enable(&home),
        Command::SafeAutoRestore => safe_auto_restore(&home),
        Command::SafeAutoStatus => safe_auto_status(&home),
        Command::SafeAutoDoctor => safe_auto_doctor(&home),
    }
}

fn resolve_home(explicit: Option<PathBuf>) -> Result<PathBuf> {
    let home = explicit
        .or_else(|| env::var_os("CODEX_HOME").map(PathBuf::from))
        .or_else(|| BaseDirs::new().map(|dirs| dirs.home_dir().join(".codex")))
        .ok_or_else(|| {
            RouterError::coded(
                "E_CODEX_HOME_REQUIRED",
                "无法解析 Codex home；请设置 CODEX_HOME 或传入 --codex-home",
            )
        })?;
    let resolved = resolve_path_safely(&home)?;
    if is_dangerous_home(&resolved) {
        return Err(RouterError::coded(
            "E_CODEX_HOME_DANGEROUS",
            format!("拒绝不安全的 CODEX_HOME {}", resolved.display()),
        ));
    }
    Ok(resolved)
}

fn resolve_path_safely(path: &Path) -> Result<PathBuf> {
    if path
        .components()
        .any(|component| component == Component::ParentDir)
    {
        return Err(RouterError::coded(
            "E_PATH_INVALID",
            "不接受包含 '..' 的路径",
        ));
    }
    let absolute = if path.is_absolute() {
        path.to_path_buf()
    } else {
        env::current_dir()?.join(path)
    };
    let mut suffix = Vec::new();
    let mut ancestor = absolute.as_path();
    while !ancestor.exists() {
        let name = ancestor
            .file_name()
            .ok_or_else(|| RouterError::coded("E_PATH_INVALID", "路径没有已存在的父目录"))?;
        suffix.push(name.to_os_string());
        ancestor = ancestor
            .parent()
            .ok_or_else(|| RouterError::coded("E_PATH_INVALID", "路径没有已存在的父目录"))?;
    }
    let mut resolved = fs::canonicalize(ancestor)
        .map_err(|error| RouterError::coded("E_PATH_INVALID", error.to_string()))?;
    for name in suffix.iter().rev() {
        resolved.push(name);
    }
    Ok(resolved)
}

fn is_dangerous_home(path: &Path) -> bool {
    if path.parent().is_none() || path == Path::new("/") {
        return true;
    }
    BaseDirs::new()
        .is_some_and(|dirs| fs::canonicalize(dirs.home_dir()).is_ok_and(|home| path == home))
}

fn load_source(source: Option<PathBuf>) -> Result<SourceRelease> {
    let root = source
        .ok_or_else(|| RouterError::coded("E_SOURCE_REQUIRED", "此操作需要 plugin source"))?;
    let root = resolve_path_safely(&root)?;
    let manifest_path = root.join("release/manifest.json");
    let bytes = fs::read(&manifest_path)
        .map_err(|_| RouterError::coded("E_SOURCE_INVALID", "缺少 release/manifest.json"))?;
    let manifest: ReleaseManifest = serde_json::from_slice(&bytes)?;
    if manifest.schema_version != 1
        || manifest.channel != "stable"
        || Version::parse(&manifest.version).is_err()
    {
        return Err(RouterError::coded(
            "E_SOURCE_INVALID",
            "Release manifest 必须使用 schema 1、stable channel 与语义化版本",
        ));
    }
    validate_source_plugin_identity(&root, &manifest)?;
    validate_current_payload(&root)?;
    let actual = payload_hash(&root)?;
    if actual != manifest.payload_sha256 {
        return Err(RouterError::coded(
            "E_SOURCE_CHECKSUM",
            "Release payload checksum 与 manifest 不一致",
        ));
    }
    Ok(SourceRelease { root, manifest })
}

fn validate_source_plugin_identity(root: &Path, release: &ReleaseManifest) -> Result<()> {
    let plugin: PluginManifest = serde_json::from_slice(
        &fs::read(root.join(".codex-plugin/plugin.json")).map_err(|_| {
            RouterError::coded(
                "E_SOURCE_INVALID",
                "plugin source 缺少 .codex-plugin/plugin.json 身份证据",
            )
        })?,
    )
    .map_err(|_| RouterError::coded("E_SOURCE_INVALID", "plugin source 身份证据无效"))?;
    if !source_plugin_version_matches_release(&plugin.version, &release.version) {
        return Err(RouterError::coded(
            "E_SOURCE_INVALID",
            "plugin manifest 与 Release manifest 的 source version 不一致",
        ));
    }
    Ok(())
}

fn source_plugin_version_matches_release(plugin_version: &str, release_version: &str) -> bool {
    if plugin_version == release_version {
        return true;
    }
    let Ok(plugin) = Version::parse(plugin_version) else {
        return false;
    };
    let Ok(release) = Version::parse(release_version) else {
        return false;
    };
    plugin.major == release.major
        && plugin.minor == release.minor
        && plugin.patch == release.patch
        && plugin.pre == release.pre
        && plugin.build.as_str().starts_with("codex.")
}

fn validate_current_payload(root: &Path) -> Result<()> {
    validate_required_payload_files(root, "E_PROFILE_INCOMPATIBLE")?;
    validate_profiles(root)?;
    validate_current_compatibility(root)
}

fn validate_required_payload_files(root: &Path, code: &'static str) -> Result<()> {
    for relative in required_payload_paths() {
        if !root.join(relative).is_file() {
            return Err(RouterError::coded(
                code,
                format!("缺少必需的 payload 文件：{relative}"),
            ));
        }
    }
    Ok(())
}

fn validate_current_compatibility(root: &Path) -> Result<()> {
    let compatibility: serde_json::Value =
        serde_json::from_slice(&fs::read(root.join("compatibility.json"))?)?;
    let config_contract = &compatibility["installer"]["configToml"];
    if config_contract["ordinaryInstallAndRoutingEnable"] != "untouched"
        || config_contract["safeAutoApproval"] != "explicit-opt-in-three-keys"
    {
        return Err(RouterError::coded(
            "E_PROFILE_INCOMPATIBLE",
            "compatibility metadata 未描述 Safe Auto config 边界",
        ));
    }
    let profile_override = &compatibility["installer"]["profileOverride"];
    if profile_override["path"] != USER_PROFILE_FILE
        || profile_override["precedence"]
            != "explicit-user-session-cli>validated-user-override>shipped-default"
        || profile_override["invalid"] != "fail-closed"
        || profile_override["runtimeAllowlist"] != "create-thread-intersection-fail-closed"
        || profile_override["reset"] != "backup-and-remove"
        || profile_override["restore"] != "managed-backup-only-validate-atomic"
    {
        return Err(RouterError::coded(
            "E_PROFILE_INCOMPATIBLE",
            "compatibility metadata 未描述持久 profile override 边界",
        ));
    }
    let independent_root_authorization =
        &compatibility["installer"]["independentRootAuthorization"];
    if independent_root_authorization["source"]
        != "explicit-install-enable-or-upgrade-managed-block"
        || independent_root_authorization["scope"] != "one-per-task-exact-route"
        || independent_root_authorization["repeatConfirmation"]
            != "not-required-when-host-accepts-durable-request"
        || independent_root_authorization["policyConflict"] != "route-handoff-required"
    {
        return Err(RouterError::coded(
            "E_PROFILE_INCOMPATIBLE",
            "compatibility metadata 未描述独立根授权边界",
        ));
    }
    validate_platform_compatibility(&compatibility, "E_PROFILE_INCOMPATIBLE")
}

fn validate_platform_compatibility(
    compatibility: &serde_json::Value,
    code: &'static str,
) -> Result<()> {
    let supported = compatibility["runtime"]["platforms"]
        .as_array()
        .is_some_and(|items| {
            items
                .iter()
                .any(|item| item.as_str() == Some(profile_platform()))
        });
    if !supported {
        return Err(RouterError::coded(code, "当前 platform 未声明为兼容"));
    }
    let supported_architecture = compatibility["runtime"]["architectures"]
        .as_array()
        .is_some_and(|items| {
            items
                .iter()
                .any(|item| item.as_str() == Some(profile_architecture()))
        });
    if !supported_architecture {
        return Err(RouterError::coded(code, "当前 architecture 未声明为兼容"));
    }
    Ok(())
}

fn required_payload_paths() -> [&'static str; 26] {
    [
        "core/router.md",
        "core/classification.md",
        "core/policy.md",
        "profiles/schema.json",
        "profiles/portable/default.toml",
        "profiles/stable/current-gpt-5.6-reference.toml",
        "profiles/candidate/example-next-model.toml",
        "agents/README.md",
        "core/modes/automation.md",
        "core/modes/business-operations.md",
        "core/modes/content.md",
        "core/modes/design.md",
        "core/modes/engineering.md",
        "core/modes/general.md",
        "core/modes/image.md",
        "core/modes/product.md",
        "core/modes/research.md",
        "core/modes/testing.md",
        "core/modes/video.md",
        "agents/roles/code_writer.toml",
        "agents/roles/docs_writer.toml",
        "agents/roles/runtime_validator.toml",
        "agents/roles/analyst.toml",
        "agents/roles/designer.toml",
        "agents/roles/media_creator.toml",
        "agents/roles/reviewer.toml",
    ]
}

fn validate_profiles(root: &Path) -> Result<()> {
    validate_modern_profiles(root)
}

fn validate_modern_profiles(root: &Path) -> Result<()> {
    let schema: serde_json::Value =
        serde_json::from_slice(&fs::read(root.join("profiles/schema.json"))?)?;
    let schema_required = schema["required"].as_array().is_some_and(|items| {
        ["schema_version", "metadata", "compatibility", "routing"]
            .iter()
            .all(|key| items.iter().any(|item| item.as_str() == Some(key)))
    });
    if !schema_required || schema["properties"]["schema_version"]["const"] != 1 {
        return Err(RouterError::coded(
            "E_PROFILE_INCOMPATIBLE",
            "profile schema 无效",
        ));
    }
    let portable = parse_profile(&root.join("profiles/portable/default.toml"))?;
    let stable = parse_profile(&root.join("profiles/stable/current-gpt-5.6-reference.toml"))?;
    let candidate = parse_profile(&root.join("profiles/candidate/example-next-model.toml"))?;
    for profile in [&portable, &stable, &candidate] {
        if profile.get("schema_version").and_then(Item::as_integer) != Some(1) {
            return Err(RouterError::coded(
                "E_PROFILE_INCOMPATIBLE",
                "profile schema_version 必须等于 1",
            ));
        }
    }

    let preflight = profile_table(&portable, "preflight")?;
    if preflight
        .get("require_explicit_runtime_metadata")
        .and_then(Item::as_bool)
        != Some(false)
        || preflight
            .get("require_exact_route_match")
            .and_then(Item::as_bool)
            != Some(true)
        || preflight
            .get("require_platform_capability")
            .and_then(Item::as_bool)
            != Some(true)
        || preflight
            .get("runtime_observability")
            .and_then(Item::as_str)
            != Some("three-state")
    {
        return Err(RouterError::coded(
            "E_PROFILE_INCOMPATIBLE",
            "portable profile 未声明三态 runtime preflight",
        ));
    }
    if preflight.get("on_unknown").and_then(Item::as_str) != Some("receipt-aware")
        || [
            "on_missing_profile",
            "on_incompatible_profile",
            "on_disabled_candidate",
        ]
        .iter()
        .any(|key| preflight.get(key).and_then(Item::as_str) != Some("fail-closed"))
    {
        return Err(RouterError::coded(
            "E_PROFILE_INCOMPATIBLE",
            "portable profile 对无效 policy 输入未 fail closed",
        ));
    }

    let receipt = profile_table(&portable, "receipt")?;
    if receipt.get("protocol").and_then(Item::as_integer) != Some(1)
        || receipt.get("classification_owner").and_then(Item::as_str) != Some("parent")
        || receipt.get("creation_tool").and_then(Item::as_str) != Some("create_thread")
        || receipt
            .get("max_automatic_root_creations")
            .and_then(Item::as_integer)
            != Some(1)
        || receipt.get("thread_id_source").and_then(Item::as_str)
            != Some("create_thread-return-only")
        || receipt.get("child_reclassification").and_then(Item::as_str) != Some("forbidden")
        || receipt.get("stage_reclassification").and_then(Item::as_str)
            != Some("parent-only-same-thread")
        || receipt.get("invalid_or_forged").and_then(Item::as_str) != Some("reject")
    {
        return Err(RouterError::coded(
            "E_PROFILE_INCOMPATIBLE",
            "portable profile 的 receipt policy 无效",
        ));
    }
    let observability = profile_table(&portable, "observability")?;
    for (key, expected) in [
        ("observable_exact", "verified"),
        ("observable_mismatch", "mismatch-fail-closed"),
        ("unobservable_non_c3", "requested-accepted-unverified"),
        (
            "unobservable_c3",
            "block-until-explicit-one-time-route-exception",
        ),
    ] {
        if observability.get(key).and_then(Item::as_str) != Some(expected) {
            return Err(RouterError::coded(
                "E_PROFILE_INCOMPATIBLE",
                "portable profile 的 observability policy 无效",
            ));
        }
    }
    let states = observability
        .get("states")
        .and_then(Item::as_array)
        .is_some_and(|items| {
            ["observable", "unobservable"]
                .iter()
                .all(|expected| items.iter().any(|item| item.as_str() == Some(*expected)))
        });
    if !states {
        return Err(RouterError::coded(
            "E_PROFILE_INCOMPATIBLE",
            "portable profile 的 observability states 不完整",
        ));
    }
    let selection = profile_table(&portable, "selection")?;
    if selection.get("stable_profile").and_then(Item::as_str)
        != Some("stable/current-gpt-5.6-reference.toml")
        || selection
            .get("allow_candidate_as_default")
            .and_then(Item::as_bool)
            != Some(false)
        || selection.get("silent_fallback").and_then(Item::as_bool) != Some(false)
        || !selection
            .get("candidate_profiles")
            .and_then(Item::as_array)
            .is_some_and(|items| {
                items
                    .iter()
                    .any(|item| item.as_str() == Some("candidate/example-next-model.toml"))
            })
    {
        return Err(RouterError::coded(
            "E_PROFILE_INCOMPATIBLE",
            "portable profile selection 无效",
        ));
    }
    let override_policy = profile_table(&portable, "profile_override")?;
    let precedence = override_policy
        .get("precedence")
        .and_then(Item::as_array)
        .is_some_and(|items| {
            items.iter().map(|item| item.as_str()).eq([
                Some("explicit-user-session-cli"),
                Some("validated-user-override"),
                Some("shipped-default"),
            ])
        });
    if override_policy.get("user_path").and_then(Item::as_str) != Some(USER_PROFILE_FILE)
        || !precedence
        || override_policy.get("invalid").and_then(Item::as_str) != Some("fail-closed")
        || override_policy
            .get("runtime_allowlist")
            .and_then(Item::as_str)
            != Some("create-thread-intersection-fail-closed")
        || override_policy.get("restore").and_then(Item::as_str)
            != Some("managed-backup-only-validate-atomic")
    {
        return Err(RouterError::coded(
            "E_PROFILE_INCOMPATIBLE",
            "portable profile 未声明持久 override 边界",
        ));
    }
    let authorization = profile_table(&portable, "independent_root_authorization")?;
    if authorization.get("source").and_then(Item::as_str)
        != Some("explicit-install-enable-or-upgrade-managed-block")
        || authorization.get("scope").and_then(Item::as_str) != Some("one-per-task-exact-route")
        || authorization
            .get("repeat_confirmation")
            .and_then(Item::as_str)
            != Some("not-required-when-host-accepts-durable-request")
        || authorization.get("policy_conflict").and_then(Item::as_str)
            != Some("route-handoff-required")
    {
        return Err(RouterError::coded(
            "E_PROFILE_INCOMPATIBLE",
            "portable profile 未声明独立根授权边界",
        ));
    }

    let stable_metadata = profile_table(&stable, "metadata")?;
    if stable_metadata.get("status").and_then(Item::as_str) != Some("reference") {
        return Err(RouterError::coded(
            "E_PROFILE_INCOMPATIBLE",
            "stable reference profile 状态无效",
        ));
    }
    require_routing(&stable, &["A0", "A1", "B0", "B1", "B2", "C1", "C2", "C3"])?;

    let candidate_metadata = profile_table(&candidate, "metadata")?;
    if candidate_metadata.get("status").and_then(Item::as_str) != Some("disabled")
        || candidate_metadata.get("enabled").and_then(Item::as_bool) != Some(false)
        || candidate_metadata
            .get("evaluation_state")
            .and_then(Item::as_str)
            != Some("unevaluated")
    {
        return Err(RouterError::coded(
            "E_PROFILE_INCOMPATIBLE",
            "candidate profile 必须保持 disabled 且 unevaluated",
        ));
    }
    require_routing(&candidate, &["B2", "C1"])?;
    Ok(())
}

fn parse_profile(path: &Path) -> Result<DocumentMut> {
    fs::read_to_string(path)?
        .parse::<DocumentMut>()
        .map_err(|error| RouterError::coded("E_PROFILE_INCOMPATIBLE", error.to_string()))
}

fn profile_table<'a>(profile: &'a DocumentMut, name: &str) -> Result<&'a Table> {
    profile.get(name).and_then(Item::as_table).ok_or_else(|| {
        RouterError::coded(
            "E_PROFILE_INCOMPATIBLE",
            format!("缺少 profile table {name}"),
        )
    })
}

fn require_routing(profile: &DocumentMut, tiers: &[&str]) -> Result<()> {
    let routing = profile_table(profile, "routing")?;
    for tier in tiers {
        let entry = routing.get(tier).and_then(Item::as_inline_table);
        let valid = entry.is_some_and(|table| {
            table.get("model").and_then(|item| item.as_str()).is_some()
                && table.get("effort").and_then(|item| item.as_str()).is_some()
        });
        if !valid {
            return Err(RouterError::coded(
                "E_PROFILE_INCOMPATIBLE",
                format!("profile routing entry {tier} 不完整"),
            ));
        }
    }
    Ok(())
}

fn payload_roots() -> [&'static str; 4] {
    ["core", "profiles", "agents", "compatibility.json"]
}

fn profile_platform() -> &'static str {
    match env::consts::OS {
        "macos" => "darwin",
        other => other,
    }
}

fn profile_architecture() -> &'static str {
    match env::consts::ARCH {
        "aarch64" | "arm64" => "arm64",
        "x86_64" | "amd64" => "amd64",
        other => other,
    }
}

fn payload_hash(root: &Path) -> Result<String> {
    let mut files = BTreeSet::new();
    for relative in payload_roots() {
        let target = root.join(relative);
        if target.is_file() {
            files.insert(target);
        } else if target.is_dir() {
            for entry in WalkDir::new(target) {
                let entry = entry
                    .map_err(|error| RouterError::coded("E_SOURCE_INVALID", error.to_string()))?;
                if entry.file_type().is_file() {
                    files.insert(entry.into_path());
                }
            }
        }
    }
    let mut hasher = Sha256::new();
    for file in files {
        let relative = file
            .strip_prefix(root)
            .map_err(|_| RouterError::coded("E_SOURCE_INVALID", "payload 路径越出 source root"))?;
        hasher.update(relative.to_string_lossy().replace('\\', "/").as_bytes());
        hasher.update([0]);
        hasher.update(fs::read(file)?);
        hasher.update([0]);
    }
    Ok(format!("{:x}", hasher.finalize()))
}

fn validate_installed_version_root(root: &Path, state: &State) -> Result<()> {
    Version::parse(&state.version)
        .map_err(|_| RouterError::coded("E_STATE_INVALID", "已安装版本不是语义化版本"))?;
    let installed: State = serde_json::from_slice(
        &fs::read(root.join("install.json"))
            .map_err(|_| RouterError::coded("E_PAYLOAD_DRIFT", "已安装版本缺少 state 证据"))?,
    )
    .map_err(|_| RouterError::coded("E_PAYLOAD_DRIFT", "已安装版本的 state 证据无效"))?;
    if installed.version != state.version || installed.payload_sha256 != state.payload_sha256 {
        return Err(RouterError::coded(
            "E_PAYLOAD_DRIFT",
            "current.json 与已安装版本的 state 证据不一致",
        ));
    }
    let manifest: ReleaseManifest =
        serde_json::from_slice(&fs::read(root.join("release/manifest.json")).map_err(|_| {
            RouterError::coded("E_PAYLOAD_DRIFT", "已安装版本缺少 Release manifest 证据")
        })?)
        .map_err(|_| RouterError::coded("E_PAYLOAD_DRIFT", "已安装 Release manifest 证据无效"))?;
    if manifest.schema_version != 1
        || manifest.channel != "stable"
        || manifest.version != state.version
        || manifest.payload_sha256 != state.payload_sha256
    {
        return Err(RouterError::coded(
            "E_PAYLOAD_DRIFT",
            "已安装 Release manifest 与活动 state 不一致",
        ));
    }
    validate_optional_installed_plugin_identity(root, state)?;
    validate_current_payload(root)?;
    if payload_hash(root)? != state.payload_sha256 {
        return Err(RouterError::coded(
            "E_PAYLOAD_DRIFT",
            "已安装版本的 payload hash 与其精确 state 证据不一致",
        ));
    }
    Ok(())
}

fn validate_optional_installed_plugin_identity(root: &Path, state: &State) -> Result<()> {
    let path = root.join(".codex-plugin/plugin.json");
    let metadata = match fs::symlink_metadata(&path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(error.into()),
    };
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return Err(RouterError::coded(
            "E_PAYLOAD_DRIFT",
            "已安装 plugin 的身份证据不是普通文件",
        ));
    }
    let plugin: PluginManifest = serde_json::from_slice(&fs::read(&path)?)
        .map_err(|_| RouterError::coded("E_PAYLOAD_DRIFT", "已安装 plugin 的身份证据无效"))?;
    if plugin.version != state.version {
        return Err(RouterError::coded(
            "E_PAYLOAD_DRIFT",
            "已安装 plugin 的身份证据与活动 state 不一致",
        ));
    }
    Ok(())
}

fn install(
    home: &Path,
    source: SourceRelease,
    dry_run: bool,
    allow_upgrade: bool,
) -> Result<Outcome> {
    ensure_no_pending_transaction(home)?;
    // An override lives outside the immutable payload precisely so upgrades preserve its
    // bytes.  That does not permit an invalid override to be silently carried forward: every
    // install/upgrade preflight validates it before changing the active router state.
    validate_user_profile_if_present(home)?;
    let existing_state = read_state(home)?;
    let agents_before = read_optional(&agents_path(home))?;
    let mut next_state = State {
        version: source.manifest.version.clone(),
        payload_sha256: source.manifest.payload_sha256.clone(),
        installed_at_unix_ns: now_ns(),
        agents_existed_before: agents_before.is_some(),
        managed_separator: managed_separator(agents_before.as_deref()),
    };
    let mut refresh_same_version = false;

    if let Some(current) = existing_state.as_ref() {
        next_state.agents_existed_before = current.agents_existed_before;
        next_state.managed_separator = current.managed_separator.clone();
        let current_version = Version::parse(&current.version)
            .map_err(|_| RouterError::coded("E_STATE_INVALID", "已安装版本不是语义化版本"))?;
        let next_version = Version::parse(&next_state.version)
            .map_err(|_| RouterError::coded("E_SOURCE_INVALID", "source version 不是语义化版本"))?;
        if current.version == next_state.version
            && current.payload_sha256 == next_state.payload_sha256
        {
            ensure_managed_matches(agents_before.as_deref(), current)?;
            validate_active_installation(home, current)?;
            return Ok(outcome(
                if allow_upgrade { "upgrade" } else { "install" },
                "OK_NO_CHANGE",
                Some(current.version.clone()),
                false,
                None,
                vec!["相同版本和受管内容已安装".into()],
            ));
        } else if !allow_upgrade {
            return Err(RouterError::coded(
                "E_UPGRADE_REQUIRED",
                "已安装不同的 router 版本；请使用 upgrade",
            ));
        } else if current.version == next_state.version {
            // A local same-version refresh is allowed only after the active installation is
            // byte-for-byte intact.  Identity-only replacement would overwrite a real user
            // edit to the managed block, so it is deliberately not a migration escape hatch.
            ensure_managed_matches(agents_before.as_deref(), current)?;
            validate_active_installation(home, current)?;
            refresh_same_version = true;
        } else {
            ensure_managed_matches(agents_before.as_deref(), current)?;
            validate_active_installation(home, current)?;
            if next_version <= current_version {
                return Err(RouterError::coded(
                    "E_VERSION_NOT_NEWER",
                    "source stable Release 不比已安装版本新",
                ));
            }
        }
    } else if agents_before
        .as_deref()
        .is_some_and(|text| text.contains(managed_begin()))
    {
        return Err(RouterError::coded(
            "E_MANAGED_BLOCK_CONFLICT",
            "AGENTS.md 包含未跟踪的 router 受管 block",
        ));
    }

    let agents_after = match existing_state.as_ref() {
        Some(previous) => replace_managed(
            agents_before.as_deref().unwrap_or_default(),
            previous,
            &next_state,
        )?,
        None => append_managed(agents_before.as_deref(), &next_state),
    };
    if dry_run {
        return Ok(outcome(
            if allow_upgrade { "upgrade" } else { "dry-run" },
            "OK_DRY_RUN",
            Some(next_state.version),
            false,
            None,
            vec![
                format!("将把不可变版本安装到 {}", versions_path(home).display()),
                format!("将原子更新 {}", current_path(home).display()),
                "将追加或精确替换一个带 hash 的 AGENTS.md block；不修改 config.toml".into(),
            ],
        ));
    }

    fs::create_dir_all(router_path(home))?;
    let backup = Backup {
        agents: agents_before,
        current: read_optional(&current_path(home))?,
    };
    let backup_path = create_backup(home, &backup)?;
    let replaced_version_backup = if refresh_same_version {
        Some(create_version_backup(home, &next_state.version)?)
    } else {
        None
    };
    let next_current = String::from_utf8(serde_json::to_vec_pretty(&next_state)?)
        .map_err(|_| RouterError::coded("E_DATA", "router state 无法编码为 UTF-8"))?;
    let version_existed_before = versions_path(home).join(&next_state.version).exists();
    if let Err(error) = write_journal_with_replaced_version(
        home,
        if allow_upgrade { "upgrade" } else { "install" },
        &backup_path,
        Some(&agents_after),
        Some(&next_current),
        (!version_existed_before && !refresh_same_version).then_some(&next_state),
        replaced_version_backup.as_deref(),
        refresh_same_version.then_some(next_state.version.as_str()),
    ) {
        if let Some(version_backup) = replaced_version_backup.as_deref() {
            let _ = fs::remove_dir_all(version_backup);
        }
        return Err(error);
    }
    let result = (|| {
        create_immutable_version(home, &source, &next_state, refresh_same_version)?;
        atomic_write(&agents_path(home), agents_after.as_bytes())?;
        atomic_write(&current_path(home), next_current.as_bytes())?;
        Ok(())
    })();
    if let Err(error) = result {
        let _ = restore_backup_contents(home, &backup);
        if let Some(version_backup) = replaced_version_backup.as_deref() {
            let _ = restore_version_backup(home, version_backup, &next_state.version);
        } else if !version_existed_before {
            let _ = remove_abandoned_version(home, &next_state);
        }
        let _ = fs::remove_file(journal_path(home));
        return Err(error);
    }
    if let Some(version_backup) = replaced_version_backup.as_deref() {
        let _ = fs::remove_dir_all(version_backup);
    }
    let _ = fs::remove_file(journal_path(home));
    Ok(outcome(
        if allow_upgrade { "upgrade" } else { "install" },
        "OK",
        Some(next_state.version),
        true,
        Some(backup_path.display().to_string()),
        vec!["继续选用 stable profile；未提升 disabled candidate".into()],
    ))
}

fn doctor(home: &Path) -> Result<Outcome> {
    ensure_no_pending_transaction(home)?;
    ensure_no_safe_auto_transaction(home)?;
    let agents = read_optional(&agents_path(home))?;
    let Some(state) = read_state(home)? else {
        match evaluate_safe_auto(home)? {
            SafeAutoStatus::Active => {
                return Err(RouterError::coded(
                    "E_SAFE_AUTO_ACTIVE",
                    "未安装 router，但 Safe Auto 审批 policy 仍为 active；清理前请运行 `safe-auto restore`",
                ))
            }
            SafeAutoStatus::Drift => {
                return Err(RouterError::coded(
                    "E_SAFE_AUTO_DRIFT",
                    "Safe Auto state 存在，但受管键已改变",
                ))
            }
            SafeAutoStatus::Absent => {}
        }
        if agents
            .as_deref()
            .is_some_and(|text| text.contains(managed_begin()))
        {
            return Err(RouterError::coded(
                "E_MANAGED_BLOCK_CONFLICT",
                "AGENTS.md 存在 router 受管 block，但 router state 缺失",
            ));
        }
        if router_path(home).exists() {
            return Err(RouterError::coded(
                "E_STALE_MANAGED_ASSETS",
                "router 受管资产仍存在，但没有 current state；请运行 uninstall skill 清理",
            ));
        }
        return Ok(outcome(
            "doctor",
            "OK_NOT_ENABLED",
            None,
            false,
            None,
            vec![
                "未启用受管 routing state；plugin registration 不在 routerctl 的检查范围内".into(),
            ],
        ));
    };
    validate_active_installation(home, &state)?;
    ensure_managed_matches(agents.as_deref(), &state)?;
    let profile = effective_profile_report(home, &state)?;
    let safe_detail = match evaluate_safe_auto(home)? {
        SafeAutoStatus::Active => "safe-auto=active",
        SafeAutoStatus::Absent => "safe-auto=absent",
        SafeAutoStatus::Drift => {
            return Err(RouterError::coded(
                "E_SAFE_AUTO_DRIFT",
                "启用后 Safe Auto 受管键发生变化；请运行 safe-auto status，并在解决用户改动后再 restore",
            ))
        }
    };
    Ok(with_profile(
        outcome(
        "doctor",
        "OK_ENABLED",
        Some(state.version),
        false,
        None,
        vec![format!("受管 block、payload hash、profile policy 与 runtime platform 均有效；{safe_detail}")],
    ),
        profile,
    ))
}

fn profile_show(home: &Path) -> Result<Outcome> {
    let state = active_state(home)?;
    let profile = effective_profile_report(home, &state)?;
    Ok(with_profile(
        outcome(
            "profile-show",
            if profile.source == "default" {
                "OK_DEFAULT"
            } else {
                "OK_USER_OVERRIDE"
            },
            Some(state.version),
            false,
            None,
            vec!["仅报告有效 tier mapping、source、path 与 mapping hash".into()],
        ),
        profile,
    ))
}

fn profile_validate(home: &Path) -> Result<Outcome> {
    let state = active_state(home)?;
    let profile = effective_profile_report(home, &state)?;
    Ok(with_profile(
        outcome(
            "profile-validate",
            if profile.source == "default" {
                "OK_DEFAULT"
            } else {
                "OK_USER_OVERRIDE"
            },
            Some(state.version),
            false,
            None,
            vec!["有效 routing mapping 的语法和语义均有效；handoff 时 runtime allowlist 交集仍 fail closed".into()],
        ),
        profile,
    ))
}

fn profile_init(home: &Path) -> Result<Outcome> {
    let state = active_state(home)?;
    let (_, default_mapping) = active_default_mapping(home, &state)?;
    if read_user_profile(home)?.is_some() {
        return Err(RouterError::coded(
            "E_PROFILE_OVERRIDE_EXISTS",
            format!(
                "{} 已存在 user override；请运行 `profile validate`、`profile set` 或显式 `profile reset`",
                user_profile_path(home).display()
            ),
        ));
    }
    let rendered = render_user_profile(&default_mapping);
    write_user_profile_if_unchanged(home, None, &rendered)?;
    let profile = effective_profile_report(home, &state)?;
    Ok(with_profile(
        outcome(
            "profile-init",
            "OK",
            Some(state.version),
            true,
            None,
            vec!["已根据随附的活动默认值创建完整、可编辑的 user override".into()],
        ),
        profile,
    ))
}

fn profile_set(home: &Path, tier: &str, model: &str, effort: &str) -> Result<Outcome> {
    if !TIER_NAMES.contains(&tier) {
        return Err(RouterError::coded(
            "E_PROFILE_OVERRIDE_INVALID",
            format!(
                "未知 tier {tier}；应为以下值之一：{}",
                TIER_NAMES.join(", ")
            ),
        ));
    }
    let state = active_state(home)?;
    let (_, default_mapping) = active_default_mapping(home, &state)?;
    let previous = read_user_profile(home)?;
    let mut mapping = match previous.as_deref() {
        Some(contents) => parse_user_profile_mapping(contents)?,
        None => default_mapping,
    };
    mapping.insert(
        tier.into(),
        Route {
            model: model.into(),
            effort: effort.into(),
        },
    );
    validate_routing_mapping(&mapping, "E_PROFILE_OVERRIDE_INVALID")?;
    let rendered = render_user_profile(&mapping);
    write_user_profile_if_unchanged(home, previous.as_deref(), &rendered)?;
    let profile = effective_profile_report(home, &state)?;
    Ok(with_profile(
        outcome(
            "profile-set",
            "OK",
            Some(state.version),
            true,
            None,
            vec![format!(
                "已更新 {tier} 并写入完整、经过验证的 user override"
            )],
        ),
        profile,
    ))
}

fn profile_reset(home: &Path) -> Result<Outcome> {
    let state = active_state(home)?;
    let Some(previous) = read_user_profile(home)? else {
        let profile = effective_profile_report(home, &state)?;
        return Ok(with_profile(
            outcome(
                "profile-reset",
                "OK_NO_CHANGE",
                Some(state.version),
                false,
                None,
                vec!["不存在 user override；随附默认值保持 active".into()],
            ),
            profile,
        ));
    };
    let backups = user_profile_backup_path(home)?;
    write_profile_backup(&backups, &previous)?;
    if read_user_profile(home)?.as_deref() != Some(previous.as_str()) {
        return Err(RouterError::coded(
            "E_PROFILE_OVERRIDE_DRIFT",
            "准备 reset 时 user override 已改变；已保留 backup，未移除 override",
        ));
    }
    fs::remove_file(user_profile_path(home))?;
    let profile = effective_profile_report(home, &state)?;
    Ok(with_profile(
        outcome(
            "profile-reset",
            "OK",
            Some(state.version),
            true,
            Some(backups.display().to_string()),
            vec!["已备份并移除 user override；随附默认值重新 active".into()],
        ),
        profile,
    ))
}

fn profile_restore(home: &Path, requested_backup: &Path) -> Result<Outcome> {
    let state = active_state(home)?;
    let backup = validated_user_profile_backup_path(home, requested_backup)?;
    let metadata_path = profile_backup_metadata_path(&backup)?;
    let metadata_file = fs::symlink_metadata(&metadata_path).map_err(|_| {
        RouterError::coded(
            "E_PROFILE_OVERRIDE_BACKUP_INVALID",
            "profile backup 缺少受管完整性 metadata",
        )
    })?;
    if metadata_file.file_type().is_symlink() || !metadata_file.is_file() {
        return Err(RouterError::coded(
            "E_PROFILE_OVERRIDE_BACKUP_INVALID",
            "profile backup 完整性 metadata 必须是受管普通文件",
        ));
    }
    let metadata: ProfileBackup =
        serde_json::from_slice(&fs::read(&metadata_path).map_err(|_| {
            RouterError::coded(
                "E_PROFILE_OVERRIDE_BACKUP_INVALID",
                "profile backup 缺少受管完整性 metadata",
            )
        })?)
        .map_err(|_| {
            RouterError::coded(
                "E_PROFILE_OVERRIDE_BACKUP_INVALID",
                "profile backup 完整性 metadata 无效",
            )
        })?;
    let contents = fs::read_to_string(&backup).map_err(|_| {
        RouterError::coded(
            "E_PROFILE_OVERRIDE_BACKUP_INVALID",
            "profile backup 不是有效的 UTF-8 TOML",
        )
    })?;
    if metadata.protocol != PROTOCOL
        || metadata.override_sha256 != bytes_sha256(contents.as_bytes())
    {
        return Err(RouterError::coded(
            "E_PROFILE_OVERRIDE_BACKUP_DRIFT",
            "profile backup bytes 与其受管完整性 metadata 不一致",
        ));
    }
    if let Err(error) = parse_user_profile_mapping(&contents) {
        return Err(RouterError::coded(
            "E_PROFILE_OVERRIDE_BACKUP_INVALID",
            format!("profile backup 不包含有效 override：{error}"),
        ));
    }
    if read_user_profile(home)?.is_some() {
        return Err(RouterError::coded(
            "E_PROFILE_OVERRIDE_DRIFT",
            "user override 已存在；profile restore 拒绝覆盖",
        ));
    }
    write_user_profile_if_unchanged(home, None, &contents)?;
    let profile = effective_profile_report(home, &state)?;
    Ok(with_profile(
        outcome(
            "profile-restore",
            "OK",
            Some(state.version),
            true,
            Some(backup.display().to_string()),
            vec!["已验证并原子恢复受管 profile backup，未覆盖现有 user override".into()],
        ),
        profile,
    ))
}

fn active_state(home: &Path) -> Result<State> {
    let state = read_state(home)?.ok_or_else(|| {
        RouterError::coded(
            "E_NOT_INSTALLED",
            "routing 未启用；请先安装，再管理有效 profile",
        )
    })?;
    validate_active_installation(home, &state)?;
    Ok(state)
}

fn active_default_mapping(
    home: &Path,
    state: &State,
) -> Result<(PathBuf, BTreeMap<String, Route>)> {
    let path = versions_path(home)
        .join(&state.version)
        .join("profiles/stable/current-gpt-5.6-reference.toml");
    let contents = fs::read_to_string(&path)
        .map_err(|_| RouterError::coded("E_PROFILE_INCOMPATIBLE", "缺少活动默认 tier mapping"))?;
    let mapping = parse_routing_mapping(&contents, "E_PROFILE_INCOMPATIBLE")?;
    Ok((path, mapping))
}

fn effective_profile_report(home: &Path, state: &State) -> Result<ProfileReport> {
    let (default_path, default_mapping) = active_default_mapping(home, state)?;
    let (source, path, routing) = match read_user_profile(home)? {
        Some(contents) => (
            "user override".into(),
            user_profile_path(home),
            parse_user_profile_mapping(&contents)?,
        ),
        None => ("default".into(), default_path, default_mapping),
    };
    Ok(ProfileReport {
        source,
        path: path.display().to_string(),
        mapping_sha256: routing_hash(&routing),
        routing,
    })
}

fn parse_user_profile_mapping(contents: &str) -> Result<BTreeMap<String, Route>> {
    let document = contents.parse::<DocumentMut>().map_err(|error| {
        RouterError::coded(
            "E_PROFILE_OVERRIDE_INVALID",
            format!("user override TOML 无效：{error}；请修复或运行 `profile reset`"),
        )
    })?;
    if document.get("schema_version").and_then(Item::as_integer) != Some(1) {
        return Err(RouterError::coded(
            "E_PROFILE_OVERRIDE_INVALID",
            "user override schema_version 必须等于 1；请修复或运行 `profile reset`",
        ));
    }
    routing_mapping_from_document(&document, "E_PROFILE_OVERRIDE_INVALID")
}

fn parse_routing_mapping(contents: &str, code: &'static str) -> Result<BTreeMap<String, Route>> {
    let document = contents
        .parse::<DocumentMut>()
        .map_err(|error| RouterError::coded(code, format!("tier mapping TOML 无效：{error}")))?;
    routing_mapping_from_document(&document, code)
}

fn routing_mapping_from_document(
    document: &DocumentMut,
    code: &'static str,
) -> Result<BTreeMap<String, Route>> {
    let routing = document
        .get("routing")
        .and_then(Item::as_table)
        .ok_or_else(|| RouterError::coded(code, "缺少 tier mapping 的 [routing] table"))?;
    for (tier, _) in routing.iter() {
        if !TIER_NAMES.contains(&tier) {
            return Err(RouterError::coded(
                code,
                format!("tier mapping 包含未知 tier {tier}"),
            ));
        }
    }
    let mut mapping = BTreeMap::new();
    for tier in TIER_NAMES {
        let entry = routing
            .get(tier)
            .and_then(Item::as_inline_table)
            .ok_or_else(|| RouterError::coded(code, format!("tier mapping 缺少 {tier}")))?;
        if entry.len() != 2 {
            return Err(RouterError::coded(
                code,
                format!("tier mapping {tier} 只能包含 model 和 effort"),
            ));
        }
        let model = entry
            .get("model")
            .and_then(|item| item.as_str())
            .ok_or_else(|| RouterError::coded(code, format!("tier mapping {tier} 缺少 model")))?;
        let effort = entry
            .get("effort")
            .and_then(|item| item.as_str())
            .ok_or_else(|| RouterError::coded(code, format!("tier mapping {tier} 缺少 effort")))?;
        mapping.insert(
            tier.into(),
            Route {
                model: model.into(),
                effort: effort.into(),
            },
        );
    }
    validate_routing_mapping(&mapping, code)?;
    Ok(mapping)
}

fn validate_routing_mapping(mapping: &BTreeMap<String, Route>, code: &'static str) -> Result<()> {
    if mapping.len() != TIER_NAMES.len()
        || TIER_NAMES.iter().any(|tier| !mapping.contains_key(*tier))
    {
        return Err(RouterError::coded(
            code,
            "tier mapping 必须恰好包含每个 tier 一次",
        ));
    }
    for tier in TIER_NAMES {
        let route = mapping.get(tier).expect("validated tier mapping entry");
        if route.model.trim().is_empty() || route.model.chars().any(char::is_whitespace) {
            return Err(RouterError::coded(
                code,
                format!("tier mapping {tier} 的 model 必须是非空 token"),
            ));
        }
        if route.effort.trim().is_empty() {
            return Err(RouterError::coded(
                code,
                format!("tier mapping {tier} 的 effort 不能为空"),
            ));
        }
        if tier == "A0" {
            if route.model != "current-qualified-root" || route.effort != "runtime-qualified" {
                return Err(RouterError::coded(
                    code,
                    "A0 必须保持 current-qualified-root/runtime-qualified，且不得创建 routed root",
                ));
            }
        } else if route.model == "current-qualified-root"
            || !matches!(route.effort.as_str(), "medium" | "high" | "xhigh" | "max")
        {
            return Err(RouterError::coded(
                code,
                format!(
                    "tier mapping {tier} 必须使用 future-compatible model token，以及 medium/high/xhigh/max 之一"
                ),
            ));
        }
    }
    Ok(())
}

fn render_user_profile(mapping: &BTreeMap<String, Route>) -> String {
    let mut output = String::from(
        "# 持久 Z Codex Router user override。\n# 显式 user/session/CLI 选择仍然优先。\n# handoff 时与 runtime create_thread allowlist 求交集，并 fail closed。\nschema_version = 1\n\n[metadata]\nname = \"user-tier-override\"\npurpose = \"不可变 Release payload 之外的持久本地 tier-to-model override。\"\n\n[routing]\n",
    );
    for tier in TIER_NAMES {
        let route = mapping.get(tier).expect("complete routing map");
        output.push_str(&format!(
            "{tier} = {{ model = \"{}\", effort = \"{}\" }}\n",
            route.model, route.effort
        ));
    }
    output
}

fn routing_hash(mapping: &BTreeMap<String, Route>) -> String {
    let mut hasher = Sha256::new();
    for (tier, route) in mapping {
        hasher.update(tier.as_bytes());
        hasher.update([0]);
        hasher.update(route.model.as_bytes());
        hasher.update([0]);
        hasher.update(route.effort.as_bytes());
        hasher.update([0]);
    }
    format!("{:x}", hasher.finalize())
}

fn user_profile_path(home: &Path) -> PathBuf {
    home.join(USER_PROFILE_FILE)
}

fn read_user_profile(home: &Path) -> Result<Option<String>> {
    let path = user_profile_path(home);
    match fs::symlink_metadata(&path) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error.into()),
        Ok(metadata) if metadata.file_type().is_symlink() || !metadata.is_file() => {
            Err(RouterError::coded(
                "E_PROFILE_OVERRIDE_INVALID",
                "user override 路径必须是普通文件，不能是 link 或目录",
            ))
        }
        Ok(_) => fs::read_to_string(&path).map(Some).map_err(Into::into),
    }
}

fn validate_user_profile_if_present(home: &Path) -> Result<()> {
    if let Some(contents) = read_user_profile(home)? {
        parse_user_profile_mapping(&contents)?;
    }
    Ok(())
}

fn write_user_profile_if_unchanged(
    home: &Path,
    expected_before: Option<&str>,
    contents: &str,
) -> Result<()> {
    if read_user_profile(home)?.as_deref() != expected_before {
        return Err(RouterError::coded(
            "E_PROFILE_OVERRIDE_DRIFT",
            "准备写入时 user override 已改变；拒绝覆盖",
        ));
    }
    atomic_write(&user_profile_path(home), contents.as_bytes())
}

fn user_profile_backup_directory(home: &Path) -> Result<PathBuf> {
    let directory = home.join(USER_PROFILE_BACKUP_DIRECTORY);
    if directory.exists() {
        let metadata = fs::symlink_metadata(&directory)?;
        if !metadata.is_dir() || metadata.file_type().is_symlink() {
            return Err(RouterError::coded(
                "E_PROFILE_OVERRIDE_INVALID",
                "user override backup 目录必须是普通目录",
            ));
        }
    } else {
        fs::create_dir_all(&directory)?;
    }
    Ok(directory)
}

fn user_profile_backup_path(home: &Path) -> Result<PathBuf> {
    Ok(user_profile_backup_directory(home)?.join(format!("backup-{}.toml", now_ns())))
}

fn profile_backup_metadata_path(backup: &Path) -> Result<PathBuf> {
    let name = backup
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or_else(|| {
            RouterError::coded(
                "E_PROFILE_OVERRIDE_BACKUP_INVALID",
                "profile backup 路径没有有效文件名",
            )
        })?;
    Ok(backup.with_file_name(format!("{name}.json")))
}

fn write_profile_backup(path: &Path, contents: &str) -> Result<()> {
    atomic_write(path, contents.as_bytes())?;
    let metadata = ProfileBackup {
        protocol: PROTOCOL,
        override_sha256: bytes_sha256(contents.as_bytes()),
    };
    atomic_write(
        &profile_backup_metadata_path(path)?,
        serde_json::to_vec_pretty(&metadata)?.as_slice(),
    )
}

fn validated_user_profile_backup_path(home: &Path, requested: &Path) -> Result<PathBuf> {
    if requested
        .components()
        .any(|component| component == Component::ParentDir)
    {
        return Err(RouterError::coded(
            "E_PROFILE_OVERRIDE_BACKUP_INVALID",
            "profile restore backup 路径不能包含 '..'",
        ));
    }
    let directory = user_profile_backup_directory(home)?;
    let directory_canonical = fs::canonicalize(&directory).map_err(|_| {
        RouterError::coded(
            "E_PROFILE_OVERRIDE_BACKUP_INVALID",
            "无法解析 profile backup 目录",
        )
    })?;
    let candidate = if requested.is_absolute() {
        requested.to_path_buf()
    } else {
        directory.join(requested)
    };
    let metadata = fs::symlink_metadata(&candidate).map_err(|_| {
        RouterError::coded(
            "E_PROFILE_OVERRIDE_BACKUP_INVALID",
            "profile restore backup 不存在",
        )
    })?;
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return Err(RouterError::coded(
            "E_PROFILE_OVERRIDE_BACKUP_INVALID",
            "profile restore backup 必须是受管普通文件",
        ));
    }
    let canonical = fs::canonicalize(&candidate).map_err(|_| {
        RouterError::coded(
            "E_PROFILE_OVERRIDE_BACKUP_INVALID",
            "无法解析 profile restore backup",
        )
    })?;
    let valid_name = canonical
        .file_name()
        .and_then(|name| name.to_str())
        .is_some_and(|name| name.starts_with("backup-") && name.ends_with(".toml"));
    if canonical.parent() != Some(directory_canonical.as_path()) || !valid_name {
        return Err(RouterError::coded(
            "E_PROFILE_OVERRIDE_BACKUP_INVALID",
            "profile restore backup 越出受管 backup 目录",
        ));
    }
    Ok(canonical)
}

fn bytes_sha256(contents: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(contents);
    format!("{:x}", hasher.finalize())
}

fn with_profile(mut outcome: Outcome, profile: ProfileReport) -> Outcome {
    outcome.profile = Some(profile);
    outcome
}

fn recover(home: &Path) -> Result<Outcome> {
    if safe_auto_journal_path(home).exists() && !journal_path(home).exists() {
        return safe_auto_recover(home);
    }
    let (journal, backup, backup_path) = pending_transaction(home)?;
    let expected_agents = journal.expected_agents_sha256.as_deref().ok_or_else(|| {
        RouterError::coded(
            "E_TRANSACTION_PENDING",
            "待处理事务缺少安全恢复检查；不要手工覆盖文件",
        )
    })?;
    let expected_current = journal.expected_current_sha256.as_deref().ok_or_else(|| {
        RouterError::coded(
            "E_TRANSACTION_PENDING",
            "待处理事务缺少安全恢复检查；不要手工覆盖文件",
        )
    })?;
    let agents_now = read_optional(&agents_path(home))?;
    let current_now = read_optional(&current_path(home))?;
    if !matches_transaction_value(
        agents_now.as_deref(),
        backup.agents.as_deref(),
        expected_agents,
    ) || !matches_transaction_value(
        current_now.as_deref(),
        backup.current.as_deref(),
        expected_current,
    ) {
        return Err(RouterError::coded(
            "E_TRANSACTION_PENDING",
            "待处理事务不再匹配 before/after 值；请保留文件并解决冲突",
        ));
    }
    if let (Some(version), Some(payload_sha256)) = (
        journal.created_version.as_deref(),
        journal.created_payload_sha256.as_deref(),
    ) {
        remove_abandoned_version_by_identity(home, version, payload_sha256)?;
    }
    if let Some(version_backup) = journal.replaced_version_backup.as_deref() {
        let backup = validated_version_backup_path(home, Path::new(version_backup))?;
        let version = journal.replaced_version.clone().ok_or_else(|| {
            RouterError::coded(
                "E_TRANSACTION_PENDING",
                "被替换版本的 backup 没有可恢复的版本身份",
            )
        })?;
        restore_version_backup(home, &backup, &version)?;
    }
    restore_backup_contents(home, &backup)?;
    fs::remove_file(journal_path(home))?;
    let restored = read_state(home)?.map(|item| item.version);
    Ok(outcome(
        "recover",
        "OK_RECOVERED",
        restored,
        true,
        Some(backup_path.display().to_string()),
        vec!["精确检查 before/after 后，已恢复原事务状态".into()],
    ))
}

fn rollback(home: &Path) -> Result<Outcome> {
    if journal_path(home).exists() {
        return recover(home);
    }
    let current = read_state(home)?
        .ok_or_else(|| RouterError::coded("E_NOT_INSTALLED", "router state 缺失"))?;
    let agents_before = read_optional(&agents_path(home))?;
    ensure_managed_matches(agents_before.as_deref(), &current)?;
    validate_active_installation(home, &current)?;
    let rollback_backup_path = latest_backup(home)?;
    let rollback_backup: Backup = serde_json::from_slice(&fs::read(&rollback_backup_path)?)?;
    let target = match rollback_backup.current.as_deref() {
        Some(text) => Some(serde_json::from_str::<State>(text).map_err(|_| {
            RouterError::coded("E_STATE_INVALID", "rollback backup 的 current pointer 无效")
        })?),
        None => None,
    };
    if let Some(target) = target.as_ref() {
        validate_active_installation(home, target)?;
    }
    let agents_after = match target.as_ref() {
        Some(target) => replace_managed(
            agents_before.as_deref().unwrap_or_default(),
            &current,
            target,
        )?,
        None => remove_managed(agents_before.as_deref().unwrap_or_default(), &current)?,
    };
    let next_current = rollback_backup.current.clone();
    let backup = Backup {
        agents: agents_before,
        current: read_optional(&current_path(home))?,
    };
    let backup_path = create_backup(home, &backup)?;
    write_journal(
        home,
        "rollback",
        &backup_path,
        Some(&agents_after),
        next_current.as_deref(),
        None,
    )?;
    let result = (|| {
        if !current.agents_existed_before && agents_after.is_empty() {
            fs::remove_file(agents_path(home))?;
        } else {
            atomic_write(&agents_path(home), agents_after.as_bytes())?;
        }
        restore_optional(&current_path(home), next_current.as_deref())?;
        Ok(())
    })();
    if let Err(error) = result {
        let _ = restore_backup_contents(home, &backup);
        let _ = fs::remove_file(journal_path(home));
        return Err(error);
    }
    fs::remove_file(journal_path(home))?;
    let restored = target.map(|state| state.version);
    Ok(outcome(
        "rollback",
        "OK",
        restored,
        true,
        Some(rollback_backup_path.display().to_string()),
        vec!["仅替换精确受管 block 与 current pointer；已保留用户管理的 AGENTS.md 内容".into()],
    ))
}

fn uninstall(home: &Path) -> Result<Outcome> {
    ensure_no_pending_transaction(home)?;
    if safe_auto_state_path(home).exists() || safe_auto_journal_path(home).exists() {
        return Err(RouterError::coded(
            "E_SAFE_AUTO_ACTIVE",
            "Safe Auto 审批 policy 仍受管理；uninstall 前请运行 `safe-auto restore`",
        ));
    }
    let Some(state) = read_state(home)? else {
        let agents = read_optional(&agents_path(home))?;
        if agents
            .as_deref()
            .is_some_and(|text| text.contains(managed_begin()))
        {
            return Err(RouterError::coded(
                "E_MANAGED_BLOCK_CONFLICT",
                "AGENTS.md 存在 router 受管 block，但 router state 缺失",
            ));
        }
        let changed = cleanup_managed_assets(home)?;
        return Ok(outcome(
            "uninstall",
            if changed { "OK" } else { "OK_NO_CHANGE" },
            None,
            changed,
            None,
            vec!["全局 routing 已停用；没有改变用户管理的 AGENTS.md 内容".into()],
        ));
    };
    let agents = read_optional(&agents_path(home))?;
    ensure_managed_matches(agents.as_deref(), &state)?;
    validate_active_installation(home, &state)?;
    let agents_after = remove_managed(agents.as_deref().unwrap_or_default(), &state)?;
    let backup = Backup {
        agents,
        current: read_optional(&current_path(home))?,
    };
    let backup_path = create_backup(home, &backup)?;
    write_journal(
        home,
        "uninstall",
        &backup_path,
        Some(&agents_after),
        None,
        None,
    )?;
    let result = (|| {
        if !state.agents_existed_before && agents_after.is_empty() {
            fs::remove_file(agents_path(home))?;
        } else {
            atomic_write(&agents_path(home), agents_after.as_bytes())?;
        }
        fs::remove_file(current_path(home))?;
        if read_optional(&agents_path(home))?
            != if state.agents_existed_before || !agents_after.is_empty() {
                Some(agents_after.clone())
            } else {
                None
            }
        {
            return Err(RouterError::coded(
                "E_IO",
                "uninstall 期间 AGENTS.md 发生变化；未把用户内容视为已验证",
            ));
        }
        fs::remove_file(journal_path(home))?;
        cleanup_managed_assets(home)?;
        Ok(())
    })();
    if let Err(error) = result {
        let _ = restore_backup_contents(home, &backup);
        let restored_backup = create_backup(home, &backup).ok();
        if let Some(restored_backup) = restored_backup {
            let _ = write_journal(
                home,
                "uninstall",
                &restored_backup,
                Some(&agents_after),
                None,
                None,
            );
        }
        return Err(error);
    }
    Ok(outcome(
        "uninstall",
        "OK",
        Some(state.version),
        true,
        None,
        vec!["仅撤销匹配的受管 block 与 state，验证用户内容，并清理 router 受管资产".into()],
    ))
}

fn safe_auto_enable(home: &Path) -> Result<Outcome> {
    ensure_no_pending_transaction(home)?;
    ensure_no_safe_auto_transaction(home)?;
    let current = read_optional(&config_path(home))?;
    let document = parse_config(current.as_deref())?;
    if let Some(state) = read_safe_auto_state(home)? {
        ensure_safe_auto_active(&document, &state)?;
        return Ok(outcome(
            "safe-auto-enable",
            "OK_NO_CHANGE",
            None,
            false,
            Some(safe_auto_state_path(home).display().to_string()),
            vec!["Safe Auto 审批 policy 已 active 且未改变".into()],
        ));
    }
    let original = snapshot_safe_auto_values(&document)?;
    let mut next = document;
    for (key, value) in SAFE_AUTO_KEYS.iter().zip(SAFE_AUTO_VALUES) {
        next[*key] = toml_edit::value(value);
    }
    let after = next.to_string();
    let state = SafeAutoState {
        protocol: PROTOCOL,
        config_existed_before: current.is_some(),
        original,
        managed: managed_safe_auto_values(),
    };
    let journal = SafeAutoJournal {
        protocol: PROTOCOL,
        operation: "enable".into(),
        before_hash: optional_hash(current.as_deref()),
        after_hash: optional_hash(Some(&after)),
        state: state.clone(),
    };
    if read_optional(&config_path(home))? != current {
        return Err(RouterError::coded(
            "E_SAFE_AUTO_DRIFT",
            "准备启用 Safe Auto 时 config.toml 已改变；拒绝覆盖",
        ));
    }
    atomic_write(
        &safe_auto_journal_path(home),
        serde_json::to_vec_pretty(&journal)?.as_slice(),
    )?;
    let write_result: Result<()> = (|| {
        atomic_write(&config_path(home), after.as_bytes())?;
        atomic_write(
            &safe_auto_state_path(home),
            serde_json::to_vec_pretty(&state)?.as_slice(),
        )?;
        Ok(())
    })();
    write_result?;
    fs::remove_file(safe_auto_journal_path(home))?;
    Ok(outcome(
        "safe-auto-enable",
        "OK",
        None,
        true,
        Some(safe_auto_state_path(home).display().to_string()),
        vec![
            "仅写入 sandbox_mode、approval_policy 与 approvals_reviewer".into(),
            "sandbox 保持 workspace-write；auto-review 只替换符合条件的 reviewer".into(),
            "Computer Use、凭证以及高风险或外部不可逆动作仍需用户授权".into(),
        ],
    ))
}

fn safe_auto_restore(home: &Path) -> Result<Outcome> {
    ensure_no_pending_transaction(home)?;
    ensure_no_safe_auto_transaction(home)?;
    let Some(state) = read_safe_auto_state(home)? else {
        return Ok(outcome(
            "safe-auto-restore",
            "OK_NO_CHANGE",
            None,
            false,
            None,
            vec!["Safe Auto 审批 policy 为 absent；未改变配置".into()],
        ));
    };
    let current = read_optional(&config_path(home))?;
    let document = parse_config(current.as_deref())?;
    ensure_safe_auto_active(&document, &state)?;
    let restored = restore_safe_auto_document(document, &state)?;
    let restored_text = restored.map(|document| document.to_string());
    let journal = SafeAutoJournal {
        protocol: PROTOCOL,
        operation: "restore".into(),
        before_hash: optional_hash(current.as_deref()),
        after_hash: optional_hash(restored_text.as_deref()),
        state: state.clone(),
    };
    if read_optional(&config_path(home))? != current {
        return Err(RouterError::coded(
            "E_SAFE_AUTO_DRIFT",
            "准备 Safe Auto restore 时 config.toml 已改变；拒绝覆盖",
        ));
    }
    atomic_write(
        &safe_auto_journal_path(home),
        serde_json::to_vec_pretty(&journal)?.as_slice(),
    )?;
    restore_optional(&config_path(home), restored_text.as_deref())?;
    fs::remove_file(safe_auto_state_path(home))?;
    fs::remove_file(safe_auto_journal_path(home))?;
    Ok(outcome(
        "safe-auto-restore",
        "OK",
        None,
        true,
        None,
        vec![
            "仅恢复三个受管键，并保留无关 config 内容".into(),
            "router uninstall 仍是独立操作；卸载 routing 前请先 restore Safe Auto".into(),
        ],
    ))
}

fn safe_auto_status(home: &Path) -> Result<Outcome> {
    if safe_auto_journal_path(home).exists() {
        return Err(RouterError::coded(
            "E_SAFE_AUTO_TRANSACTION_PENDING",
            "Safe Auto 存在中断事务；执行其他操作前请运行 `recover`",
        ));
    }
    let status = evaluate_safe_auto(home)?;
    let (code, detail) = match status {
        SafeAutoStatus::Active => ("SAFE_AUTO_ACTIVE", "Safe Auto 审批 policy 为 active"),
        SafeAutoStatus::Drift => (
            "SAFE_AUTO_DRIFT",
            "Safe Auto state 存在，但一个或多个受管键已改变",
        ),
        SafeAutoStatus::Absent => (
            "SAFE_AUTO_ABSENT",
            "Safe Auto 审批 policy 未受管理；未改变配置",
        ),
    };
    Ok(outcome(
        "safe-auto-status",
        code,
        None,
        false,
        read_safe_auto_state(home)?.map(|_| safe_auto_state_path(home).display().to_string()),
        vec![detail.into()],
    ))
}

fn safe_auto_doctor(home: &Path) -> Result<Outcome> {
    ensure_no_pending_transaction(home)?;
    ensure_no_safe_auto_transaction(home)?;
    match evaluate_safe_auto(home)? {
        SafeAutoStatus::Active => Ok(outcome(
            "safe-auto-doctor",
            "OK_ACTIVE",
            None,
            false,
            Some(safe_auto_state_path(home).display().to_string()),
            vec!["受管三键 policy 存在且未改变".into()],
        )),
        SafeAutoStatus::Absent => Ok(outcome(
            "safe-auto-doctor",
            "OK_ABSENT",
            None,
            false,
            None,
            vec!["Safe Auto 未启用；没有受管权限配置".into()],
        )),
        SafeAutoStatus::Drift => Err(RouterError::coded(
            "E_SAFE_AUTO_DRIFT",
            "启用后 Safe Auto 受管键已改变；为避免覆盖用户改动，restore 已阻止",
        )),
    }
}

fn safe_auto_recover(home: &Path) -> Result<Outcome> {
    let journal = read_safe_auto_journal(home)?;
    let current = read_optional(&config_path(home))?;
    let current_hash = optional_hash(current.as_deref());
    if current_hash != journal.before_hash && current_hash != journal.after_hash {
        return Err(RouterError::coded(
            "E_SAFE_AUTO_TRANSACTION_PENDING",
            "config.toml 在中断的 Safe Auto 事务之外发生变化；请保留并解决冲突",
        ));
    }
    if current_hash == journal.before_hash {
        if journal.operation == "restore" && !safe_auto_state_path(home).exists() {
            atomic_write(
                &safe_auto_state_path(home),
                serde_json::to_vec_pretty(&journal.state)?.as_slice(),
            )?;
        }
        fs::remove_file(safe_auto_journal_path(home))?;
        return Ok(outcome(
            "safe-auto-recover",
            "OK_RECOVERED",
            None,
            true,
            None,
            vec!["中断的 Safe Auto 写入尚未改变 config.toml".into()],
        ));
    }
    if journal.operation == "enable" {
        let document = parse_config(current.as_deref())?;
        ensure_safe_auto_active(&document, &journal.state)?;
        atomic_write(
            &safe_auto_state_path(home),
            serde_json::to_vec_pretty(&journal.state)?.as_slice(),
        )?;
    } else {
        let document = parse_config(current.as_deref())?;
        let restored = restore_safe_auto_document(document, &journal.state)?;
        let restored_text = restored.map(|document| document.to_string());
        if optional_hash(restored_text.as_deref()) != journal.after_hash {
            return Err(RouterError::coded(
                "E_SAFE_AUTO_TRANSACTION_PENDING",
                "Safe Auto 恢复后的 config 与 journal 不一致；请保留 config.toml",
            ));
        }
        // When current_hash == after_hash the config write already completed.  Do not
        // rewrite it: only finish the state/journal cleanup.  This preserves any
        // unrelated user content and covers an interruption between either cleanup step.
        if current_hash != journal.after_hash {
            restore_optional(&config_path(home), restored_text.as_deref())?;
        }
        if safe_auto_state_path(home).exists() {
            fs::remove_file(safe_auto_state_path(home))?;
        }
    }
    fs::remove_file(safe_auto_journal_path(home))?;
    Ok(outcome(
        "safe-auto-recover",
        "OK_RECOVERED",
        None,
        true,
        None,
        vec!["精确检查 hash 后，已完成中断的 Safe Auto 事务".into()],
    ))
}

fn ensure_no_safe_auto_transaction(home: &Path) -> Result<()> {
    if safe_auto_journal_path(home).exists() {
        return Err(RouterError::coded(
            "E_SAFE_AUTO_TRANSACTION_PENDING",
            "先前的 Safe Auto 事务要求在执行其他操作前运行 `recover`",
        ));
    }
    Ok(())
}

fn evaluate_safe_auto(home: &Path) -> Result<SafeAutoStatus> {
    let Some(state) = read_safe_auto_state(home)? else {
        return Ok(SafeAutoStatus::Absent);
    };
    let current = read_optional(&config_path(home))?;
    let document = parse_config(current.as_deref())?;
    if config_matches_managed(&document, &state) {
        Ok(SafeAutoStatus::Active)
    } else {
        Ok(SafeAutoStatus::Drift)
    }
}

fn ensure_safe_auto_active(document: &DocumentMut, state: &SafeAutoState) -> Result<()> {
    if state.protocol != PROTOCOL || !config_matches_managed(document, state) {
        return Err(RouterError::coded(
            "E_SAFE_AUTO_DRIFT",
            "Safe Auto 受管键缺失或已改变；拒绝覆盖用户配置",
        ));
    }
    Ok(())
}

fn config_matches_managed(document: &DocumentMut, state: &SafeAutoState) -> bool {
    SAFE_AUTO_KEYS.iter().all(|key| {
        document
            .get(key)
            .and_then(Item::as_value)
            .map(|value| {
                value
                    .as_str()
                    .map_or_else(|| value.to_string(), ToOwned::to_owned)
            })
            .is_some_and(|value| state.managed.get(*key) == Some(&value))
    })
}

fn snapshot_safe_auto_values(document: &DocumentMut) -> Result<BTreeMap<String, Option<String>>> {
    let mut original = BTreeMap::new();
    for key in SAFE_AUTO_KEYS {
        if let Some(item) = document.get(key) {
            if item.as_value().is_none() {
                return Err(RouterError::coded(
                    "E_CONFIG_INVALID",
                    format!("受管 config 键 {key} 必须是 TOML 标量值"),
                ));
            }
            original.insert(key.into(), Some(item.to_string().trim().into()));
        } else {
            original.insert(key.into(), None);
        }
    }
    Ok(original)
}

fn restore_safe_auto_document(
    mut document: DocumentMut,
    state: &SafeAutoState,
) -> Result<Option<DocumentMut>> {
    for key in SAFE_AUTO_KEYS {
        match state.original.get(key).and_then(Option::as_deref) {
            Some(representation) => {
                let mini = format!("{key} = {representation}\n");
                let parsed = mini.parse::<DocumentMut>().map_err(|error| {
                    RouterError::coded(
                        "E_SAFE_AUTO_STATE_INVALID",
                        format!("无法恢复原始 {key}：{error}"),
                    )
                })?;
                let item = parsed.get(key).cloned().ok_or_else(|| {
                    RouterError::coded(
                        "E_SAFE_AUTO_STATE_INVALID",
                        format!("Safe Auto state 缺少可恢复的 {key} 值"),
                    )
                })?;
                document[key] = item;
            }
            None => {
                document.remove(key);
            }
        }
    }
    if !state.config_existed_before && document.to_string().trim().is_empty() {
        Ok(None)
    } else {
        Ok(Some(document))
    }
}

fn managed_safe_auto_values() -> BTreeMap<String, String> {
    SAFE_AUTO_KEYS
        .into_iter()
        .zip(SAFE_AUTO_VALUES)
        .map(|(key, value)| (key.into(), value.into()))
        .collect()
}

fn parse_config(contents: Option<&str>) -> Result<DocumentMut> {
    contents
        .unwrap_or_default()
        .parse::<DocumentMut>()
        .map_err(|error| {
            RouterError::coded("E_CONFIG_INVALID", format!("config.toml 无效：{error}"))
        })
}

fn read_safe_auto_state(home: &Path) -> Result<Option<SafeAutoState>> {
    let Some(text) = read_optional(&safe_auto_state_path(home))? else {
        return Ok(None);
    };
    let state: SafeAutoState = serde_json::from_str(&text)
        .map_err(|_| RouterError::coded("E_SAFE_AUTO_STATE_INVALID", "Safe Auto state 无效"))?;
    if state.protocol != PROTOCOL
        || SAFE_AUTO_KEYS
            .iter()
            .any(|key| !state.original.contains_key(*key) || !state.managed.contains_key(*key))
        || state.managed != managed_safe_auto_values()
    {
        return Err(RouterError::coded(
            "E_SAFE_AUTO_STATE_INVALID",
            "Safe Auto state 未描述受支持的三键 policy",
        ));
    }
    Ok(Some(state))
}

fn read_safe_auto_journal(home: &Path) -> Result<SafeAutoJournal> {
    let text = read_optional(&safe_auto_journal_path(home))?
        .ok_or_else(|| RouterError::coded("E_NOT_INSTALLED", "不存在中断的 Safe Auto 事务"))?;
    let journal: SafeAutoJournal = serde_json::from_str(&text).map_err(|_| {
        RouterError::coded(
            "E_SAFE_AUTO_TRANSACTION_PENDING",
            "Safe Auto 事务 journal 无效",
        )
    })?;
    if journal.protocol != PROTOCOL || !matches!(journal.operation.as_str(), "enable" | "restore") {
        return Err(RouterError::coded(
            "E_SAFE_AUTO_TRANSACTION_PENDING",
            "不支持该 Safe Auto 事务 journal",
        ));
    }
    Ok(journal)
}

fn append_managed(existing: Option<&str>, state: &State) -> String {
    let block = managed_block(state);
    match existing {
        None | Some("") => block,
        Some(text) => format!("{text}{}{block}", state.managed_separator),
    }
}

fn managed_separator(existing: Option<&str>) -> String {
    match existing {
        None | Some("") => String::new(),
        Some(text) if text.ends_with('\n') => "\n".into(),
        Some(_) => "\n\n".into(),
    }
}

fn remove_managed(existing: &str, state: &State) -> Result<String> {
    let block = managed_block(state);
    let index = existing.find(&block).ok_or_else(|| {
        RouterError::coded(
            "E_MANAGED_BLOCK_DRIFT",
            "受管 AGENTS.md block 并非逐字节完整",
        )
    })?;
    let mut result = String::with_capacity(existing.len() - block.len());
    let before = &existing[..index];
    if !state.managed_separator.is_empty() && before.ends_with(&state.managed_separator) {
        result.push_str(&before[..before.len() - state.managed_separator.len()]);
    } else {
        result.push_str(before);
    }
    result.push_str(&existing[index + block.len()..]);
    Ok(result)
}

fn replace_managed(existing: &str, previous: &State, next: &State) -> Result<String> {
    let old = managed_block(previous);
    let index = existing.find(&old).ok_or_else(|| {
        RouterError::coded(
            "E_MANAGED_BLOCK_DRIFT",
            "受管 AGENTS.md block 并非逐字节完整",
        )
    })?;
    if existing.matches(managed_begin()).count() != 1 {
        return Err(RouterError::coded(
            "E_MANAGED_BLOCK_DRIFT",
            "AGENTS.md 包含多个受管 block",
        ));
    }
    let mut replaced =
        String::with_capacity(existing.len() - old.len() + managed_block(next).len());
    replaced.push_str(&existing[..index]);
    replaced.push_str(&managed_block(next));
    replaced.push_str(&existing[index + old.len()..]);
    Ok(replaced)
}

fn ensure_managed_matches(existing: Option<&str>, state: &State) -> Result<()> {
    let text =
        existing.ok_or_else(|| RouterError::coded("E_MANAGED_BLOCK_DRIFT", "缺少 AGENTS.md"))?;
    let exact = managed_block(state);
    if text.contains(&exact) && text.matches(managed_begin()).count() == 1 {
        return Ok(());
    }
    if text.contains(managed_begin()) {
        return Err(RouterError::coded(
            "E_MANAGED_BLOCK_DRIFT",
            "受管 AGENTS.md block 已改变",
        ));
    }
    Err(RouterError::coded(
        "E_MANAGED_BLOCK_DRIFT",
        "受管 AGENTS.md block 缺失",
    ))
}

fn managed_begin() -> &'static str {
    "<!-- z-codex-router:begin"
}

fn managed_block(state: &State) -> String {
    modern_managed_block(state)
}

const GLOBAL_ROUTING_POLICY: &str = r#"## 全局路由

- 对每个新的独立任务，先读取一次 `$CODEX_HOME/routing/router.md`（未设置时 `$CODEX_HOME` 为 `~/.codex`），再读取一个主 mode；确有跨领域需要时最多加一个辅助 mode，按最终交付责任选择主 mode，并指定最终交付负责人。Product 用于需求、研究、优先级、指标、实验、发布和复盘；Business Operations 用于运营、商务、预算、品牌、合同/报价材料和外部沟通。这些是人工路由说明，不会自动注入上下文。
- 同一任务的后续轮次复用已确认的 tier、范围和已读上下文；仅在目标、影响面或验收标准发生实质变化时重新路由。focused tests 通常是 Engineering 的验收证据，不因测试而无限叠加 mode。
- `routing/router.md` 是 tier 到模型和 reasoning effort 的唯一事实来源。用户、会话和 CLI 的显式选择优先；当前轮不可热切换主模型或 effort，运行时工具的 allowlist、角色锁和权限是最终约束。
- A1 及以上路线对可见运行时字段要求实际 model/effort 与目标 tuple 精确一致；可见不一致是 mismatch 并 fail closed，更高 effort 不自动兼容。字段缺失或接口不可用明确记为 `runtime_observability=unobservable`：A1/B0/B1/B2/C1/C2 在父 receipt 已确认工具接受目标 tuple 且无 reroute/failure 证据时可按 requested/accepted 继续但不声称 actual verified；C3 在不可逆动作前需一次当前 task/scope/action 的 route exception。创建能力不可用时仍停止并报告 route exception，未经用户明确授权不得由当前根会话代做。
- 本条是用户对符合上述路由条件时创建新/后台独立模型根会话的持久明确授权。创建前的 commentary 是信息披露，不是批准请求；工具 schema 与运行时权限优先，工具不接受授权、参数不支持或调用失败时报告 route exception，不伪造或绕过。工具明确接受授权时不得要求用户重复确认。若 `create_thread` 未直接暴露，先通过 `tool_search` 定向发现；只有工具发现后仍不可用或调用失败，才报告 route exception。创建 sub-agent 仍须满足 router 的委派条件。
- 创建任何独立模型根会话（单代理）或 sub-agent 前，必须在 commentary 明确告知执行拓扑、准确模型、reasoning effort 和任务范围；sub-agent 还要说明角色、文件所有权、验收标准或失败升级依据。禁止静默创建；若运行时客观上无法事前提示，必须在创建后的第一条 commentary 立即披露。默认不委派；并发、写入、GUI 和完整构建边界均遵守 router。所有角色使用 router 的结构化回报合同。
- 因模型/effort 不匹配的同一任务最多自动创建一次独立根任务；执行根可见 mismatch 时报告 route exception，不递归创建或静默降级；unobservable 按父 receipt 三态规则处理，不能写成 mismatch。用户/会话/CLI 显式组合优先，但仍须精确匹配。
- 线程 ID 由创建方从 `create_thread` 返回值记录并在最终回复披露；执行任务禁止从 request metadata 提取或输出 thread/session 信息。只要本任务创建过独立根会话或 sub-agent，最终回复必须再次列出执行拓扑、实际模型和 reasoning effort、线程/agent ID、sub-agent 数量、任务结果，以及原会话是否发送过收敛或纠偏指令；不得只依赖可能被客户端折叠的 commentary 或笼统的“任务已创建”卡片。
- 质量记录至少包含 `predicted_tier`、`final_tier`、`reroute_reason`、`first_success`、`user_correction`、`route_exception`、`retry` 和 `coordination_cost`（创建/等待/汇总成本）；每个主要任务桶保留至少 20 个真实样本作为观察下限，不因样本不足改动模型映射。
- agent 代表能力与权限边界，不按职业一一新增；不得替代审批人、法务、财务、业务签字人或对外承诺主体。对外发送、签署、支付、采购、账户/权限变更、公开发布和生产变更等外部不可逆动作，必须由具备权限的人明确确认并实际执行；草案、计划或自动化不能自动获得该授权。"#;

fn modern_managed_block(state: &State) -> String {
    let boundary = if !state.agents_existed_before && state.managed_separator.is_empty() {
        String::new()
    } else {
        format!(
            " agents_existed_before={} separator={}",
            state.agents_existed_before,
            managed_separator_label(&state.managed_separator)
        )
    };
    format!(
        "<!-- z-codex-router:begin id={ROUTER_ID} version={} sha256={} protocol={PROTOCOL}{boundary} -->\n# Z Codex Router（受管）\n先解析 Codex home：显式 `CODEX_HOME` 优先，否则使用 `~/.codex`；禁止相对于仓库或 worktree 解析。读取 `<codex_home>/z-codex-router/current.json`，再读取 `z-codex-router/versions/<current.version>/core/router.md` 与 `z-codex-router/versions/<current.version>/profiles/portable/default.toml`。在下方完整全局路由合同中，`$CODEX_HOME/routing/router.md` 与 `routing/router.md` 均指向这里解析出的版本化 `core/router.md`，无需单独的未版本化文件。\n\n{GLOBAL_ROUTING_POLICY}\n<!-- z-codex-router:end id={ROUTER_ID} -->",
        state.version, state.payload_sha256
    )
}

fn managed_separator_label(separator: &str) -> &'static str {
    match separator {
        "" => "empty",
        "\n" => "one-newline",
        "\n\n" => "two-newlines",
        _ => "invalid",
    }
}

fn create_immutable_version(
    home: &Path,
    source: &SourceRelease,
    state: &State,
    replace_existing: bool,
) -> Result<()> {
    let versions = versions_path(home);
    fs::create_dir_all(&versions)?;
    let destination = versions.join(&state.version);
    if destination.exists() {
        let actual = payload_hash(&destination)?;
        if actual == state.payload_sha256 {
            return Ok(());
        }
        if !replace_existing {
            return Err(RouterError::coded(
                "E_IMMUTABLE_VERSION_CONFLICT",
                "现有 version 目录包含不同 payload",
            ));
        }
        fs::remove_dir_all(&destination)?;
    }
    let staging = versions.join(format!(".staging-{}-{}", state.version, now_ns()));
    fs::create_dir_all(&staging)?;
    let result = (|| {
        for relative in payload_roots() {
            copy_path(&source.root.join(relative), &staging.join(relative))?;
        }
        copy_path(
            &source.root.join("release/manifest.json"),
            &staging.join("release/manifest.json"),
        )?;
        atomic_write(
            &staging.join("install.json"),
            serde_json::to_vec_pretty(state)?.as_slice(),
        )?;
        if payload_hash(&staging)? != state.payload_sha256 {
            return Err(RouterError::coded(
                "E_SOURCE_CHECKSUM",
                "staging 中的不可变 payload hash 与 source 不一致",
            ));
        }
        fs::rename(&staging, &destination)?;
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_dir_all(&staging);
    }
    result
}

fn copy_path(source: &Path, destination: &Path) -> Result<()> {
    if source.is_file() {
        if let Some(parent) = destination.parent() {
            fs::create_dir_all(parent)?;
        }
        fs::copy(source, destination)?;
        return Ok(());
    }
    for entry in WalkDir::new(source) {
        let entry =
            entry.map_err(|error| RouterError::coded("E_SOURCE_INVALID", error.to_string()))?;
        let relative = entry
            .path()
            .strip_prefix(source)
            .map_err(|_| RouterError::coded("E_SOURCE_INVALID", "无法复制 payload"))?;
        let target = destination.join(relative);
        if entry.file_type().is_dir() {
            fs::create_dir_all(target)?;
        } else if entry.file_type().is_file() {
            if let Some(parent) = target.parent() {
                fs::create_dir_all(parent)?;
            }
            fs::copy(entry.path(), target)?;
        }
    }
    Ok(())
}

fn create_backup(home: &Path, backup: &Backup) -> Result<PathBuf> {
    let backups = router_path(home).join("backups");
    fs::create_dir_all(&backups)?;
    let path = backups.join(format!("backup-{}.json", now_ns()));
    atomic_write(&path, serde_json::to_vec_pretty(backup)?.as_slice())?;
    Ok(path)
}

fn create_version_backup(home: &Path, version: &str) -> Result<PathBuf> {
    let source = versions_path(home).join(version);
    if !source.is_dir() {
        return Err(RouterError::coded("E_STATE_INVALID", "缺少已安装版本目录"));
    }
    let backups = router_path(home).join("backups/versions");
    fs::create_dir_all(&backups)?;
    let destination = backups.join(format!("backup-{}-{}", now_ns(), version));
    copy_path(&source, &destination)?;
    Ok(destination)
}

fn restore_version_backup(home: &Path, backup: &Path, version: &str) -> Result<()> {
    let destination = versions_path(home).join(version);
    if destination.exists() {
        fs::remove_dir_all(&destination)?;
    }
    fs::rename(backup, destination)?;
    Ok(())
}

fn write_journal(
    home: &Path,
    operation: &str,
    backup: &Path,
    expected_agents: Option<&str>,
    expected_current: Option<&str>,
    created_state: Option<&State>,
) -> Result<()> {
    write_journal_with_replaced_version(
        home,
        operation,
        backup,
        expected_agents,
        expected_current,
        created_state,
        None,
        None,
    )
}

// The journal fields mirror the on-disk transaction contract; keeping them explicit
// makes each call site auditable and avoids an unvalidated options map.
#[allow(clippy::too_many_arguments)]
fn write_journal_with_replaced_version(
    home: &Path,
    operation: &str,
    backup: &Path,
    expected_agents: Option<&str>,
    expected_current: Option<&str>,
    created_state: Option<&State>,
    replaced_version_backup: Option<&Path>,
    replaced_version: Option<&str>,
) -> Result<()> {
    let journal = Journal {
        protocol: PROTOCOL,
        operation: operation.into(),
        backup: backup.display().to_string(),
        expected_agents_sha256: Some(optional_hash(expected_agents)),
        expected_current_sha256: Some(optional_hash(expected_current)),
        created_version: created_state.map(|state| state.version.clone()),
        created_payload_sha256: created_state.map(|state| state.payload_sha256.clone()),
        replaced_version_backup: replaced_version_backup.map(|path| path.display().to_string()),
        replaced_version: replaced_version.map(str::to_owned),
    };
    atomic_write(
        &journal_path(home),
        serde_json::to_vec_pretty(&journal)?.as_slice(),
    )
}

fn optional_hash(contents: Option<&str>) -> String {
    let mut hasher = Sha256::new();
    match contents {
        Some(text) => {
            hasher.update(b"present\0");
            hasher.update(text.as_bytes());
        }
        None => hasher.update(b"absent\0"),
    }
    format!("{:x}", hasher.finalize())
}

fn matches_transaction_value(
    actual: Option<&str>,
    before: Option<&str>,
    expected_after: &str,
) -> bool {
    let actual_hash = optional_hash(actual);
    actual_hash == optional_hash(before) || actual_hash == expected_after
}

fn latest_backup(home: &Path) -> Result<PathBuf> {
    let backups = router_path(home).join("backups");
    let mut choices = fs::read_dir(backups)?
        .filter_map(std::result::Result::ok)
        .map(|item| item.path())
        .filter(|path| {
            path.file_name()
                .is_some_and(|name| name.to_string_lossy().starts_with("backup-"))
        })
        .collect::<Vec<_>>();
    choices.sort();
    choices
        .pop()
        .ok_or_else(|| RouterError::coded("E_NO_BACKUP", "没有可用的 router backup"))
}

fn validated_backup_path(home: &Path, candidate: &Path) -> Result<PathBuf> {
    let root = router_path(home).join("backups");
    let canonical_root = fs::canonicalize(&root)
        .map_err(|_| RouterError::coded("E_TRANSACTION_PENDING", "缺少 router backup root"))?;
    let canonical_candidate = fs::canonicalize(candidate)
        .map_err(|_| RouterError::coded("E_TRANSACTION_PENDING", "缺少 journal backup"))?;
    let is_backup = canonical_candidate
        .file_name()
        .is_some_and(|name| name.to_string_lossy().starts_with("backup-"));
    if !canonical_candidate.starts_with(&canonical_root) || !is_backup {
        return Err(RouterError::coded(
            "E_TRANSACTION_PENDING",
            "journal backup 越出受管 backup 目录",
        ));
    }
    Ok(canonical_candidate)
}

fn validated_version_backup_path(home: &Path, candidate: &Path) -> Result<PathBuf> {
    let root = router_path(home).join("backups/versions");
    let canonical_root = fs::canonicalize(&root)
        .map_err(|_| RouterError::coded("E_TRANSACTION_PENDING", "缺少 version backup root"))?;
    let canonical_candidate = fs::canonicalize(candidate)
        .map_err(|_| RouterError::coded("E_TRANSACTION_PENDING", "缺少 version backup"))?;
    let is_backup = canonical_candidate
        .file_name()
        .is_some_and(|name| name.to_string_lossy().starts_with("backup-"));
    if !canonical_candidate.starts_with(&canonical_root) || !is_backup {
        return Err(RouterError::coded(
            "E_TRANSACTION_PENDING",
            "version backup 越出受管 backup 目录",
        ));
    }
    Ok(canonical_candidate)
}

fn pending_transaction(home: &Path) -> Result<(Journal, Backup, PathBuf)> {
    let text = read_optional(&journal_path(home))?
        .ok_or_else(|| RouterError::coded("E_NOT_INSTALLED", "不存在中断的 router 事务"))?;
    let journal: Journal = serde_json::from_str(&text)
        .map_err(|_| RouterError::coded("E_TRANSACTION_PENDING", "事务 journal 无效"))?;
    if journal.protocol != PROTOCOL {
        return Err(RouterError::coded(
            "E_TRANSACTION_PENDING",
            "不支持该事务 journal protocol",
        ));
    }
    let backup_path = validated_backup_path(home, Path::new(&journal.backup))?;
    let backup: Backup = serde_json::from_slice(&fs::read(&backup_path)?)
        .map_err(|_| RouterError::coded("E_TRANSACTION_PENDING", "事务 backup 无效"))?;
    Ok((journal, backup, backup_path))
}

fn restore_backup_contents(home: &Path, backup: &Backup) -> Result<()> {
    restore_optional(&agents_path(home), backup.agents.as_deref())?;
    restore_optional(&current_path(home), backup.current.as_deref())?;
    Ok(())
}

fn validate_active_installation(home: &Path, state: &State) -> Result<()> {
    let version_root = versions_path(home).join(&state.version);
    validate_installed_version_root(&version_root, state)
}

fn remove_abandoned_version(home: &Path, state: &State) -> Result<()> {
    remove_abandoned_version_by_identity(home, &state.version, &state.payload_sha256)
}

fn remove_abandoned_version_by_identity(
    home: &Path,
    version: &str,
    payload_sha256: &str,
) -> Result<()> {
    if Version::parse(version).is_err() {
        return Err(RouterError::coded(
            "E_TRANSACTION_PENDING",
            "待处理事务的版本无效",
        ));
    }
    let root = versions_path(home).join(version);
    if !root.exists() {
        return Ok(());
    }
    let installed: State = serde_json::from_slice(&fs::read(root.join("install.json"))?)
        .map_err(|_| RouterError::coded("E_TRANSACTION_PENDING", "待处理版本的 state 无效"))?;
    if installed.version != version || installed.payload_sha256 != payload_sha256 {
        return Err(RouterError::coded(
            "E_TRANSACTION_PENDING",
            "待处理版本与受管资产冲突",
        ));
    }
    validate_installed_version_root(&root, &installed)?;
    fs::remove_dir_all(root)?;
    Ok(())
}

fn cleanup_managed_assets(home: &Path) -> Result<bool> {
    let root = router_path(home);
    if !root.exists() {
        return Ok(false);
    }
    let root_type = fs::symlink_metadata(&root)?;
    if !root_type.is_dir() || root_type.file_type().is_symlink() {
        return Err(RouterError::coded(
            "E_MANAGED_ASSET_CONFLICT",
            "router 受管资产 root 不是普通目录",
        ));
    }
    for entry in fs::read_dir(&root)? {
        let entry = entry?;
        let name = entry.file_name();
        match name.to_string_lossy().as_ref() {
            "versions" => validate_version_assets(&entry.path())?,
            "backups" => validate_backup_assets(&entry.path())?,
            _ => {
                return Err(RouterError::coded(
                    "E_MANAGED_ASSET_CONFLICT",
                    format!("发现意外受管资产 {}", entry.path().display()),
                ))
            }
        }
    }
    fs::remove_dir_all(root)?;
    Ok(true)
}

fn validate_version_assets(versions: &Path) -> Result<()> {
    let metadata = fs::symlink_metadata(versions)?;
    if !metadata.is_dir() || metadata.file_type().is_symlink() {
        return Err(RouterError::coded(
            "E_MANAGED_ASSET_CONFLICT",
            "router versions 路径不是普通目录",
        ));
    }
    for entry in fs::read_dir(versions)? {
        let entry = entry?;
        let name = entry.file_name().to_string_lossy().to_string();
        let metadata = fs::symlink_metadata(entry.path())?;
        if Version::parse(&name).is_err() || !metadata.is_dir() || metadata.file_type().is_symlink()
        {
            return Err(RouterError::coded(
                "E_MANAGED_ASSET_CONFLICT",
                format!("无效受管版本资产 {}", entry.path().display()),
            ));
        }
        let state: State = serde_json::from_slice(&fs::read(entry.path().join("install.json"))?)
            .map_err(|_| RouterError::coded("E_MANAGED_ASSET_CONFLICT", "受管版本 state 无效"))?;
        if state.version != name {
            return Err(RouterError::coded(
                "E_MANAGED_ASSET_CONFLICT",
                "受管版本目录与其 state 不一致",
            ));
        }
        validate_installed_version_root(&entry.path(), &state)?;
    }
    Ok(())
}

fn validate_backup_assets(backups: &Path) -> Result<()> {
    let metadata = fs::symlink_metadata(backups)?;
    if !metadata.is_dir() || metadata.file_type().is_symlink() {
        return Err(RouterError::coded(
            "E_MANAGED_ASSET_CONFLICT",
            "router backups 路径不是普通目录",
        ));
    }
    for entry in fs::read_dir(backups)? {
        let entry = entry?;
        let name = entry.file_name().to_string_lossy().to_string();
        let metadata = fs::symlink_metadata(entry.path())?;
        if !name.starts_with("backup-")
            || !name.ends_with(".json")
            || !metadata.is_file()
            || metadata.file_type().is_symlink()
        {
            return Err(RouterError::coded(
                "E_MANAGED_ASSET_CONFLICT",
                format!("无效受管 backup 资产 {}", entry.path().display()),
            ));
        }
        serde_json::from_slice::<Backup>(&fs::read(entry.path())?)
            .map_err(|_| RouterError::coded("E_MANAGED_ASSET_CONFLICT", "受管 backup 无效"))?;
    }
    Ok(())
}

fn restore_optional(path: &Path, contents: Option<&str>) -> Result<()> {
    match contents {
        Some(text) => atomic_write(path, text.as_bytes()),
        None if path.exists() => {
            fs::remove_file(path)?;
            Ok(())
        }
        None => Ok(()),
    }
}

fn read_state(home: &Path) -> Result<Option<State>> {
    match read_optional(&current_path(home))? {
        Some(text) => Ok(Some(serde_json::from_str(&text).map_err(|_| {
            RouterError::coded("E_STATE_INVALID", "router current pointer 无效")
        })?)),
        None => Ok(None),
    }
}

fn ensure_no_pending_transaction(home: &Path) -> Result<()> {
    if journal_path(home).exists() {
        return Err(RouterError::coded(
            "E_TRANSACTION_PENDING",
            "先前的 router 事务要求在执行其他操作前安全恢复",
        ));
    }
    Ok(())
}

fn read_optional(path: &Path) -> Result<Option<String>> {
    match fs::read_to_string(path) {
        Ok(text) => Ok(Some(text)),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) if error.kind() == std::io::ErrorKind::PermissionDenied => Err(
            RouterError::coded("E_PERMISSION", format!("无法读取 {}", path.display())),
        ),
        Err(error) => Err(error.into()),
    }
}

fn atomic_write(path: &Path, contents: &[u8]) -> Result<()> {
    let parent = path
        .parent()
        .ok_or_else(|| RouterError::coded("E_PATH_INVALID", "写入目标没有父目录"))?;
    fs::create_dir_all(parent)?;
    let mut temporary = NamedTempFile::new_in(parent)?;
    temporary.write_all(contents)?;
    temporary.as_file().sync_all()?;
    let mut temporary_path = temporary.into_temp_path();
    replace_file(temporary_path.as_ref(), path)?;
    temporary_path.disable_cleanup(true);
    Ok(())
}

#[cfg(not(windows))]
fn replace_file(temporary: &Path, target: &Path) -> Result<()> {
    fs::rename(temporary, target)?;
    Ok(())
}

#[cfg(windows)]
fn replace_file(temporary: &Path, target: &Path) -> Result<()> {
    use std::ffi::OsStr;
    use std::os::windows::ffi::OsStrExt;

    #[link(name = "Kernel32")]
    extern "system" {
        fn MoveFileExW(existing: *const u16, new: *const u16, flags: u32) -> i32;
    }
    const MOVEFILE_REPLACE_EXISTING: u32 = 0x0000_0001;
    let wide = |value: &OsStr| value.encode_wide().chain(Some(0)).collect::<Vec<_>>();
    let from = wide(temporary.as_os_str());
    let to = wide(target.as_os_str());
    // MoveFileExW is the Windows replacement primitive used for the current-pointer swap.
    let result = unsafe { MoveFileExW(from.as_ptr(), to.as_ptr(), MOVEFILE_REPLACE_EXISTING) };
    if result == 0 {
        return Err(RouterError::coded(
            "E_IO",
            format!("无法原子替换 {}", target.display()),
        ));
    }
    Ok(())
}

fn now_ns() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |duration| duration.as_nanos())
}

fn router_path(home: &Path) -> PathBuf {
    home.join("z-codex-router")
}
fn versions_path(home: &Path) -> PathBuf {
    router_path(home).join("versions")
}
fn current_path(home: &Path) -> PathBuf {
    router_path(home).join("current.json")
}
fn journal_path(home: &Path) -> PathBuf {
    router_path(home).join("transaction.json")
}
fn safe_auto_state_path(home: &Path) -> PathBuf {
    router_path(home).join("safe-auto.json")
}
fn safe_auto_journal_path(home: &Path) -> PathBuf {
    router_path(home).join("safe-auto.transaction.json")
}
fn config_path(home: &Path) -> PathBuf {
    home.join("config.toml")
}
fn agents_path(home: &Path) -> PathBuf {
    home.join("AGENTS.md")
}

fn outcome(
    action: &str,
    code: &str,
    version: Option<String>,
    changed: bool,
    backup: Option<String>,
    details: Vec<String>,
) -> Outcome {
    Outcome {
        ok: true,
        action: action.into(),
        code: code.into(),
        version,
        changed,
        backup,
        details,
        profile: None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    fn source_root() -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("plugins/z-codex-router")
    }

    fn source_fixture() -> TempDir {
        let temp = tempfile::tempdir().expect("source fixture");
        let root = temp.path().join("plugins/z-codex-router");
        copy_path(&source_root(), &root).unwrap();
        temp
    }

    fn set_release_identity(root: &Path, version: &str) -> String {
        let payload_sha256 = payload_hash(root).unwrap();
        let release_path = root.join("release/manifest.json");
        let mut release: serde_json::Value =
            serde_json::from_slice(&fs::read(&release_path).unwrap()).unwrap();
        release["version"] = serde_json::Value::String(version.into());
        release["payloadSha256"] = serde_json::Value::String(payload_sha256.clone());
        fs::write(&release_path, serde_json::to_vec_pretty(&release).unwrap()).unwrap();
        let plugin_path = root.join(".codex-plugin/plugin.json");
        let mut plugin: serde_json::Value =
            serde_json::from_slice(&fs::read(&plugin_path).unwrap()).unwrap();
        plugin["version"] = serde_json::Value::String(version.into());
        fs::write(&plugin_path, serde_json::to_vec_pretty(&plugin).unwrap()).unwrap();
        payload_sha256
    }

    fn fixture() -> TempDir {
        tempfile::tempdir().expect("fixture")
    }

    #[test]
    fn managed_block_resolves_codex_home_before_router_state() {
        let state = State {
            version: "1.0.0".into(),
            payload_sha256: "0".repeat(64),
            installed_at_unix_ns: 0,
            agents_existed_before: false,
            managed_separator: String::new(),
        };
        let block = managed_block(&state);
        assert!(block.contains("显式 `CODEX_HOME` 优先，否则使用 `~/.codex`"));
        assert!(block.contains("（未设置时 `$CODEX_HOME` 为 `~/.codex`）"));
        assert!(block.contains("禁止相对于仓库或 worktree 解析"));
        assert!(block.contains("<codex_home>/z-codex-router/current.json"));
        assert!(block.contains("无需单独的未版本化文件"));
        assert!(block.contains(GLOBAL_ROUTING_POLICY));
        assert!(!block.contains("first read `z-codex-router/current.json`"));
    }

    #[test]
    fn current_managed_block_contains_the_complete_global_routing_contract() {
        let state = State {
            version: "1.0.0".into(),
            payload_sha256: "0".repeat(64),
            installed_at_unix_ns: 0,
            agents_existed_before: true,
            managed_separator: "\n".into(),
        };
        let block = managed_block(&state);
        assert_eq!(block.matches("## 全局路由").count(), 1);
        for marker in [
            "先读取一次 `$CODEX_HOME/routing/router.md`",
            "`routing/router.md` 是 tier 到模型和 reasoning effort 的唯一事实来源",
            "本条是用户对符合上述路由条件时创建新/后台独立模型根会话的持久明确授权",
            "创建前的 commentary 是信息披露，不是批准请求",
            "工具明确接受授权时不得要求用户重复确认",
            "若 `create_thread` 未直接暴露，先通过 `tool_search` 定向发现",
            "同一任务最多自动创建一次独立根任务",
            "线程 ID 由创建方从 `create_thread` 返回值记录",
            "`coordination_cost`（创建/等待/汇总成本）",
            "外部不可逆动作，必须由具备权限的人明确确认并实际执行",
        ] {
            assert!(
                block.contains(marker),
                "managed global routing contract is missing: {marker}"
            );
        }
    }

    #[test]
    fn portable_router_contract_requires_exact_routes_and_c1_reroute() {
        let router = fs::read_to_string(source_root().join("core/router.md")).unwrap();
        for marker in [
            "更高 effort 也不兼容",
            "gpt-5.6-sol/xhigh",
            "gpt-5.6-sol/medium",
            "只读取非空的 `model` 与 `reasoning_effort` 两个字段",
            "runtime_observability=unobservable",
            "receipt protocol 1",
            "classification_owner=parent",
            "creation_tool=create_thread",
            "automatic_root_creations=1",
            "requested/accepted，不声称 actual verified",
            "C3/高风险",
            "纯提示协议没有密码学防伪能力",
            "子线程不得猜测",
            "不重新分类本任务",
            "自动根创建总数仍为 `<=1`",
            "thread、session",
            "`stable/current-gpt-5.6-reference.toml` 是安装随附的 shipped default tier mapping",
            "持久用户 profile override",
            "ROUTE_HANDOFF_REQUIRED",
            "ROUTE_CREATE_FAILED",
            "ROUTE_CREATE_UNAVAILABLE",
            "严禁 `spawn_agent` fallback",
            "请为当前相同任务范围创建一个新的 Codex 独立任务",
            "profile restore <reset 返回的 backup 路径>",
            "在开始领域诊断前就创建精确的",
            "create_thread` 未直接暴露，先对线程创建能力执行一次 `tool_search`",
            "同一任务最多自动创建一次",
            "报告 route exception 并停止",
            "方案固定后，必须重新分类具体实现 tier",
            "顺序任务不应创建 sub-agent",
            "code_writer` 只写分配的源码、测试、脚本和必要项目配置",
            "普通仓库工作最多一个 sub-agent",
            "最终回报至少披露 `predicted_tier`",
        ] {
            assert!(
                router.contains(marker),
                "missing routing contract: {marker}"
            );
        }
    }

    #[test]
    fn tri_state_profile_validator_accepts_receipt_aware_preflight() {
        validate_profiles(&source_root()).unwrap();
    }

    #[test]
    fn tri_state_profile_validator_rejects_disabled_exact_route_or_platform() {
        for (needle, replacement) in [
            (
                "require_exact_route_match = true",
                "require_exact_route_match = false",
            ),
            (
                "require_platform_capability = true",
                "require_platform_capability = false",
            ),
        ] {
            let temp = fixture();
            let root = temp.path().join("profile-disabled");
            copy_path(&source_root(), &root).unwrap();
            let profile = root.join("profiles/portable/default.toml");
            let contents = fs::read_to_string(&profile).unwrap();
            assert!(contents.contains(needle));
            fs::write(profile, contents.replace(needle, replacement)).unwrap();
            assert_eq!(
                validate_profiles(&root).unwrap_err().code(),
                "E_PROFILE_INCOMPATIBLE"
            );
        }
    }

    #[test]
    fn tri_state_profile_validator_rejects_invalid_receipt_or_observability() {
        for (needle, replacement) in [
            ("protocol = 1", "protocol = 2"),
            (
                "observable_mismatch = \"mismatch-fail-closed\"",
                "observable_mismatch = \"continue\"",
            ),
            (
                "states = [\"observable\", \"unobservable\"]",
                "states = [\"observable\"]",
            ),
        ] {
            let temp = fixture();
            let root = temp.path().join("profile-invalid");
            copy_path(&source_root(), &root).unwrap();
            let profile = root.join("profiles/portable/default.toml");
            let contents = fs::read_to_string(&profile).unwrap();
            assert!(contents.contains(needle));
            fs::write(profile, contents.replace(needle, replacement)).unwrap();
            assert_eq!(
                validate_profiles(&root).unwrap_err().code(),
                "E_PROFILE_INCOMPATIBLE"
            );
        }
    }

    fn run(home: &Path, command: Command, source: bool) -> Result<Outcome> {
        let source_fixture = source.then(source_fixture);
        execute(Options {
            source: source_fixture
                .as_ref()
                .map(|fixture| fixture.path().join("plugins/z-codex-router")),
            codex_home: Some(home.to_path_buf()),
            command,
        })
    }

    #[test]
    fn persistent_profile_override_lifecycle_is_strict_and_recoverable() {
        let temp = fixture();
        let home = temp.path().join("profile-override-home");
        fs::create_dir_all(&home).unwrap();
        run(&home, Command::Install, true).unwrap();
        let default = run(&home, Command::ProfileShow, false).unwrap();
        assert_eq!(default.code, "OK_DEFAULT");
        assert_eq!(default.profile.unwrap().source, "default");

        let initialized = run(&home, Command::ProfileInit, false).unwrap();
        assert_eq!(initialized.profile.unwrap().source, "user override");
        let configured = run(
            &home,
            Command::ProfileSet {
                tier: "C2".into(),
                model: "gpt-6.0-future".into(),
                effort: "max".into(),
            },
            false,
        )
        .unwrap();
        assert_eq!(
            configured.profile.unwrap().routing["C2"].model,
            "gpt-6.0-future"
        );
        assert_eq!(
            run(
                &home,
                Command::ProfileSet {
                    tier: "A0".into(),
                    model: "gpt-6.0-future".into(),
                    effort: "max".into(),
                },
                false,
            )
            .unwrap_err()
            .code(),
            "E_PROFILE_OVERRIDE_INVALID"
        );
        assert_eq!(
            run(
                &home,
                Command::ProfileSet {
                    tier: "C1".into(),
                    model: "gpt-6.0-future".into(),
                    effort: "ultra".into(),
                },
                false,
            )
            .unwrap_err()
            .code(),
            "E_PROFILE_OVERRIDE_INVALID"
        );
        assert_eq!(
            run(
                &home,
                Command::ProfileSet {
                    tier: "Z9".into(),
                    model: "gpt-6.0-future".into(),
                    effort: "max".into(),
                },
                false,
            )
            .unwrap_err()
            .code(),
            "E_PROFILE_OVERRIDE_INVALID"
        );

        fs::write(
            user_profile_path(&home),
            "schema_version = 1\n[routing]\nA0 = { model = \"current-qualified-root\", effort = \"runtime-qualified\" }\n",
        )
        .unwrap();
        assert_eq!(
            run(&home, Command::Doctor, false).unwrap_err().code(),
            "E_PROFILE_OVERRIDE_INVALID"
        );
        fs::write(
            user_profile_path(&home),
            "schema_version = 1\nschema_version = 1\n",
        )
        .unwrap();
        assert_eq!(
            run(&home, Command::Upgrade { dry_run: false }, true,)
                .unwrap_err()
                .code(),
            "E_PROFILE_OVERRIDE_INVALID"
        );
        assert_eq!(
            run(&home, Command::ProfileValidate, false)
                .unwrap_err()
                .code(),
            "E_PROFILE_OVERRIDE_INVALID"
        );
        let reset = run(&home, Command::ProfileReset, false).unwrap();
        assert_eq!(reset.code, "OK");
        let reset_backup = PathBuf::from(reset.backup.as_deref().unwrap());
        assert!(reset_backup.is_file());
        assert!(profile_backup_metadata_path(&reset_backup)
            .unwrap()
            .is_file());
        assert!(!user_profile_path(&home).exists());
        assert_eq!(reset.profile.unwrap().source, "default");
    }

    #[test]
    fn profile_restore_is_managed_atomic_and_drift_checked() {
        let temp = fixture();
        let home = temp.path().join("profile-restore-home");
        fs::create_dir_all(&home).unwrap();
        run(&home, Command::Install, true).unwrap();
        run(&home, Command::ProfileInit, false).unwrap();
        run(
            &home,
            Command::ProfileSet {
                tier: "C2".into(),
                model: "gpt-6.0-future".into(),
                effort: "max".into(),
            },
            false,
        )
        .unwrap();
        let original = fs::read(user_profile_path(&home)).unwrap();
        let reset = run(&home, Command::ProfileReset, false).unwrap();
        let backup = PathBuf::from(reset.backup.unwrap());
        assert!(profile_backup_metadata_path(&backup).unwrap().is_file());
        let restored = run(
            &home,
            Command::ProfileRestore {
                backup: backup.clone(),
            },
            false,
        )
        .unwrap();
        assert_eq!(restored.code, "OK");
        assert_eq!(fs::read(user_profile_path(&home)).unwrap(), original);
        assert_eq!(restored.profile.unwrap().source, "user override");
        assert_eq!(
            run(
                &home,
                Command::ProfileRestore {
                    backup: backup.clone(),
                },
                false,
            )
            .unwrap_err()
            .code(),
            "E_PROFILE_OVERRIDE_DRIFT"
        );

        let reset = run(&home, Command::ProfileReset, false).unwrap();
        let drifted_backup = PathBuf::from(reset.backup.unwrap());
        fs::write(&drifted_backup, "# modified after reset\n").unwrap();
        assert_eq!(
            run(
                &home,
                Command::ProfileRestore {
                    backup: drifted_backup,
                },
                false,
            )
            .unwrap_err()
            .code(),
            "E_PROFILE_OVERRIDE_BACKUP_DRIFT"
        );
        assert_eq!(
            run(
                &home,
                Command::ProfileRestore {
                    backup: PathBuf::from("../outside.toml"),
                },
                false,
            )
            .unwrap_err()
            .code(),
            "E_PROFILE_OVERRIDE_BACKUP_INVALID"
        );

        let invalid_backup = user_profile_backup_path(&home).unwrap();
        write_profile_backup(&invalid_backup, "schema_version = 1\n[routing]\n").unwrap();
        assert_eq!(
            run(
                &home,
                Command::ProfileRestore {
                    backup: invalid_backup,
                },
                false,
            )
            .unwrap_err()
            .code(),
            "E_PROFILE_OVERRIDE_BACKUP_INVALID"
        );
        assert!(!user_profile_path(&home).exists());
    }

    #[test]
    fn installed_plugin_identity_is_optional_but_exact_when_present() {
        let temp = fixture();
        let home = temp.path().join("plugin-identity-home");
        fs::create_dir_all(&home).unwrap();
        run(&home, Command::Install, true).unwrap();
        let state = read_state(&home).unwrap().unwrap();
        let installed_root = versions_path(&home).join(&state.version);
        assert!(!installed_root.join(".codex-plugin/plugin.json").exists());
        assert_eq!(
            run(&home, Command::Doctor, false).unwrap().code,
            "OK_ENABLED"
        );
        copy_path(
            &source_root().join(".codex-plugin/plugin.json"),
            &installed_root.join(".codex-plugin/plugin.json"),
        )
        .unwrap();
        assert_eq!(
            run(&home, Command::Doctor, false).unwrap().code,
            "OK_ENABLED"
        );
        let plugin_path = installed_root.join(".codex-plugin/plugin.json");
        let mut plugin: serde_json::Value =
            serde_json::from_slice(&fs::read(&plugin_path).unwrap()).unwrap();
        plugin["version"] = serde_json::Value::String("9.9.9".into());
        fs::write(&plugin_path, serde_json::to_vec_pretty(&plugin).unwrap()).unwrap();
        assert_eq!(
            run(&home, Command::Doctor, false).unwrap_err().code(),
            "E_PAYLOAD_DRIFT"
        );
    }

    #[test]
    fn fresh_existing_agents_and_config_are_preserved_with_repeated_install() {
        let temp = fixture();
        let home = temp.path().join("fixture-codex");
        fs::create_dir_all(&home).unwrap();
        fs::write(home.join("AGENTS.md"), "# User rules\nkeep this\n").unwrap();
        let config = "# keep comment\n[agents]\nname = \"existing\"\nunknown = 7\n";
        fs::write(home.join("config.toml"), config).unwrap();
        let installed = run(&home, Command::Install, true).unwrap();
        assert!(installed.changed);
        let agents = fs::read_to_string(home.join("AGENTS.md")).unwrap();
        assert!(agents.starts_with("# User rules\nkeep this"));
        assert_eq!(
            fs::read_to_string(home.join("config.toml")).unwrap(),
            config
        );
        let again = run(&home, Command::Install, true).unwrap();
        assert_eq!(again.code, "OK_NO_CHANGE");
        assert!(!again.changed);
        run(&home, Command::Uninstall, false).unwrap();
        assert_eq!(
            fs::read_to_string(home.join("AGENTS.md")).unwrap(),
            "# User rules\nkeep this\n"
        );
        assert_eq!(
            fs::read_to_string(home.join("config.toml")).unwrap(),
            config
        );
    }

    #[test]
    fn managed_drift_fails_closed_while_complex_config_is_ignored() {
        let temp = fixture();
        let home = temp.path().join("fixture-codex");
        fs::create_dir_all(&home).unwrap();
        run(&home, Command::Install, true).unwrap();
        let agents = home.join("AGENTS.md");
        fs::write(
            &agents,
            fs::read_to_string(&agents).unwrap().replace(
                "工具明确接受授权时不得要求用户重复确认",
                "工具明确接受授权时仍要求用户重复确认",
            ),
        )
        .unwrap();
        assert_eq!(
            run(&home, Command::Doctor, false).unwrap_err().code(),
            "E_MANAGED_BLOCK_DRIFT"
        );
    }

    #[test]
    fn missing_profile_candidate_drift_and_dangerous_paths_are_rejected() {
        let temp = fixture();
        let mismatched_plugin = temp.path().join("mismatched-plugin-source");
        copy_path(&source_root(), &mismatched_plugin).unwrap();
        let plugin_path = mismatched_plugin.join(".codex-plugin/plugin.json");
        let mut plugin: serde_json::Value =
            serde_json::from_slice(&fs::read(&plugin_path).unwrap()).unwrap();
        plugin["version"] = serde_json::Value::String("9.9.9".into());
        fs::write(&plugin_path, serde_json::to_vec_pretty(&plugin).unwrap()).unwrap();
        assert_eq!(
            load_source(Some(mismatched_plugin)).unwrap_err().code(),
            "E_SOURCE_INVALID"
        );
        let cachebuster_plugin = temp.path().join("cachebuster-plugin-source");
        copy_path(&source_root(), &cachebuster_plugin).unwrap();
        let cachebuster_path = cachebuster_plugin.join(".codex-plugin/plugin.json");
        let mut cachebuster: serde_json::Value =
            serde_json::from_slice(&fs::read(&cachebuster_path).unwrap()).unwrap();
        cachebuster["version"] = serde_json::Value::String("1.0.0+codex.local-test".into());
        fs::write(
            &cachebuster_path,
            serde_json::to_vec_pretty(&cachebuster).unwrap(),
        )
        .unwrap();
        assert!(load_source(Some(cachebuster_plugin)).is_ok());
        let broken = temp.path().join("broken-source");
        copy_path(&source_root(), &broken).unwrap();
        fs::remove_file(broken.join("profiles/portable/default.toml")).unwrap();
        assert_eq!(
            load_source(Some(broken)).unwrap_err().code(),
            "E_PROFILE_INCOMPATIBLE"
        );
        let candidate = temp.path().join("candidate-source");
        copy_path(&source_root(), &candidate).unwrap();
        let candidate_path = candidate.join("profiles/candidate/example-next-model.toml");
        fs::write(
            &candidate_path,
            fs::read_to_string(&candidate_path)
                .unwrap()
                .replace("enabled = false", "enabled = true"),
        )
        .unwrap();
        assert_eq!(
            load_source(Some(candidate)).unwrap_err().code(),
            "E_PROFILE_INCOMPATIBLE"
        );
        let missing_mode = temp.path().join("missing-mode-source");
        copy_path(&source_root(), &missing_mode).unwrap();
        fs::remove_file(missing_mode.join("core/modes/engineering.md")).unwrap();
        assert_eq!(
            load_source(Some(missing_mode)).unwrap_err().code(),
            "E_PROFILE_INCOMPATIBLE"
        );
        let missing_role = temp.path().join("missing-role-source");
        copy_path(&source_root(), &missing_role).unwrap();
        fs::remove_file(missing_role.join("agents/roles/reviewer.toml")).unwrap();
        assert_eq!(
            load_source(Some(missing_role)).unwrap_err().code(),
            "E_PROFILE_INCOMPATIBLE"
        );
        assert!(is_dangerous_home(Path::new("/")));
        assert_eq!(
            resolve_path_safely(Path::new("tmp/../outside"))
                .unwrap_err()
                .code(),
            "E_PATH_INVALID"
        );
        #[cfg(unix)]
        {
            let link = temp.path().join("home-link");
            std::os::unix::fs::symlink(BaseDirs::new().unwrap().home_dir(), &link).unwrap();
            assert_eq!(
                resolve_home(Some(link)).unwrap_err().code(),
                "E_CODEX_HOME_DANGEROUS"
            );
        }
    }

    #[test]
    fn uninstall_requires_exact_owned_content() {
        let temp = fixture();
        let home = temp.path().join("fixture-codex");
        fs::create_dir_all(&home).unwrap();
        run(&home, Command::Install, true).unwrap();
        let removed = run(&home, Command::Uninstall, false).unwrap();
        assert!(removed.changed);
        assert!(removed.backup.is_none());
        assert!(!current_path(&home).exists());
        assert!(!agents_path(&home).exists());
        assert!(!router_path(&home).exists());
        let repeated = run(&home, Command::Uninstall, false).unwrap();
        assert_eq!(repeated.code, "OK_NO_CHANGE");
        assert_eq!(
            run(&home, Command::Doctor, false).unwrap().code,
            "OK_NOT_ENABLED"
        );
    }

    #[test]
    fn uninstall_stops_on_payload_drift_without_removing_control_plane() {
        let temp = fixture();
        let home = temp.path().join("fixture-codex");
        fs::create_dir_all(&home).unwrap();
        run(&home, Command::Install, true).unwrap();
        let original_agents = fs::read_to_string(agents_path(&home)).unwrap();
        fs::write(
            versions_path(&home).join("1.0.0/core/router.md"),
            "user modification",
        )
        .unwrap();
        assert_eq!(
            run(&home, Command::Uninstall, false).unwrap_err().code(),
            "E_PAYLOAD_DRIFT"
        );
        assert_eq!(
            fs::read_to_string(agents_path(&home)).unwrap(),
            original_agents
        );
        assert!(current_path(&home).exists());
        assert!(router_path(&home).exists());
    }

    #[test]
    fn uninstall_rejects_tampered_boundary_metadata_before_removing_user_content() {
        let temp = fixture();
        let home = temp.path().join("fixture-codex");
        fs::create_dir_all(&home).unwrap();
        fs::write(agents_path(&home), "# User rule\n").unwrap();
        run(&home, Command::Install, true).unwrap();
        let original_agents = fs::read_to_string(agents_path(&home)).unwrap();
        let mut current: serde_json::Value =
            serde_json::from_slice(&fs::read(current_path(&home)).unwrap()).unwrap();
        current["managed_separator"] = serde_json::Value::String("\n\n".into());
        fs::write(
            current_path(&home),
            serde_json::to_vec_pretty(&current).unwrap(),
        )
        .unwrap();
        assert_eq!(
            run(&home, Command::Uninstall, false).unwrap_err().code(),
            "E_MANAGED_BLOCK_DRIFT"
        );
        assert_eq!(
            fs::read_to_string(agents_path(&home)).unwrap(),
            original_agents
        );
    }

    #[test]
    fn rollback_to_preinstall_state_preserves_absent_agents_file() {
        let temp = fixture();
        let home = temp.path().join("fixture-codex");
        fs::create_dir_all(&home).unwrap();
        run(&home, Command::Install, true).unwrap();
        run(&home, Command::Rollback, false).unwrap();
        assert!(!agents_path(&home).exists());
        assert!(!current_path(&home).exists());
    }

    #[test]
    fn upgrade_rollback_and_candidate_protection() {
        let temp = fixture();
        let home = temp.path().join("fixture-codex");
        fs::create_dir_all(&home).unwrap();
        run(&home, Command::Install, true).unwrap();

        let newer = temp.path().join("newer-source");
        copy_path(&source_root(), &newer).unwrap();
        set_release_identity(&newer, "1.1.0");
        let upgraded = execute(Options {
            source: Some(newer),
            codex_home: Some(home.clone()),
            command: Command::Upgrade { dry_run: false },
        })
        .unwrap();
        assert_eq!(upgraded.version.as_deref(), Some("1.1.0"));
        let checked = run(&home, Command::Doctor, false).unwrap();
        assert_eq!(checked.code, "OK_ENABLED");
        assert_eq!(checked.version.as_deref(), Some("1.1.0"));
        let agents = fs::read_to_string(home.join("AGENTS.md")).unwrap();
        assert_eq!(agents.matches(managed_begin()).count(), 1);
        assert!(agents.contains("version=1.1.0"));
        fs::write(
            agents_path(&home),
            format!("{agents}\n# User rule added after enable\n"),
        )
        .unwrap();
        let rolled_back = run(&home, Command::Rollback, false).unwrap();
        assert_eq!(rolled_back.version.as_deref(), Some("1.0.0"));
        let rolled_back_agents = fs::read_to_string(home.join("AGENTS.md")).unwrap();
        assert!(rolled_back_agents.contains("version=1.0.0"));
        assert!(rolled_back_agents.contains("# User rule added after enable"));
    }

    #[test]
    fn same_version_refresh_replaces_payload_without_touching_safe_auto() {
        let temp = fixture();
        let home = temp.path().join("fixture-codex");
        fs::create_dir_all(&home).unwrap();
        run(&home, Command::Install, true).unwrap();
        run(&home, Command::SafeAutoEnable, false).unwrap();
        let config_before = fs::read(home.join("config.toml")).unwrap();
        let safe_auto_before = fs::read(safe_auto_state_path(&home)).unwrap();

        let variant = temp.path().join("same-version-variant");
        copy_path(&source_root(), &variant).unwrap();
        fs::OpenOptions::new()
            .append(true)
            .open(variant.join("core/router.md"))
            .unwrap()
            .write_all(b"\n<!-- same-version refresh fixture -->\n")
            .unwrap();
        let payload_sha256 = payload_hash(&variant).unwrap();
        let manifest_path = variant.join("release/manifest.json");
        let mut manifest: serde_json::Value =
            serde_json::from_slice(&fs::read(&manifest_path).unwrap()).unwrap();
        manifest["payloadSha256"] = serde_json::Value::String(payload_sha256.clone());
        fs::write(manifest_path, serde_json::to_vec_pretty(&manifest).unwrap()).unwrap();

        let refreshed = execute(Options {
            source: Some(variant),
            codex_home: Some(home.clone()),
            command: Command::Upgrade { dry_run: false },
        })
        .unwrap();
        assert_eq!(refreshed.version.as_deref(), Some("1.0.0"));
        assert_eq!(
            read_state(&home).unwrap().unwrap().payload_sha256,
            payload_sha256
        );
        assert_eq!(fs::read(home.join("config.toml")).unwrap(), config_before);
        assert_eq!(
            fs::read(safe_auto_state_path(&home)).unwrap(),
            safe_auto_before
        );
        assert_eq!(
            run(&home, Command::Doctor, false).unwrap().code,
            "OK_ENABLED"
        );
    }

    #[test]
    fn pending_journal_restores_after_partial_write() {
        let temp = fixture();
        let home = temp.path().join("fixture-codex");
        fs::create_dir_all(&home).unwrap();
        run(&home, Command::Install, true).unwrap();
        let agents_before = fs::read_to_string(agents_path(&home)).unwrap();
        let current_before = fs::read_to_string(current_path(&home)).unwrap();
        let backup = Backup {
            agents: Some(agents_before.clone()),
            current: Some(current_before.clone()),
        };
        let backup_path = create_backup(&home, &backup).unwrap();
        write_journal(
            &home,
            "upgrade",
            &backup_path,
            Some("partial managed write"),
            Some("not valid json"),
            None,
        )
        .unwrap();
        fs::write(agents_path(&home), "partial managed write").unwrap();
        fs::write(current_path(&home), "not valid json").unwrap();
        let restored = run(&home, Command::Recover, false).unwrap();
        assert_eq!(restored.code, "OK_RECOVERED");
        assert_eq!(restored.version.as_deref(), Some("1.0.0"));
        assert_eq!(
            fs::read_to_string(agents_path(&home)).unwrap(),
            agents_before
        );
        assert_eq!(
            fs::read_to_string(current_path(&home)).unwrap(),
            current_before
        );
        assert_eq!(
            run(&home, Command::Doctor, false).unwrap().code,
            "OK_ENABLED"
        );
    }

    #[test]
    fn recovery_stops_when_user_content_no_longer_matches_the_transaction() {
        let temp = fixture();
        let home = temp.path().join("fixture-codex");
        fs::create_dir_all(&home).unwrap();
        run(&home, Command::Install, true).unwrap();
        let agents_before = fs::read_to_string(agents_path(&home)).unwrap();
        let current_before = fs::read_to_string(current_path(&home)).unwrap();
        let backup = Backup {
            agents: Some(agents_before),
            current: Some(current_before),
        };
        let backup_path = create_backup(&home, &backup).unwrap();
        write_journal(
            &home,
            "upgrade",
            &backup_path,
            Some("expected partial write"),
            Some("expected state"),
            None,
        )
        .unwrap();
        fs::write(agents_path(&home), "user edit after interruption").unwrap();
        assert_eq!(
            run(&home, Command::Recover, false).unwrap_err().code(),
            "E_TRANSACTION_PENDING"
        );
        assert_eq!(
            fs::read_to_string(agents_path(&home)).unwrap(),
            "user edit after interruption"
        );
        assert!(journal_path(&home).exists());
    }

    #[test]
    fn recovery_removes_a_verified_version_created_by_the_interrupted_transaction() {
        let temp = fixture();
        let home = temp.path().join("fixture-codex");
        fs::create_dir_all(&home).unwrap();
        run(&home, Command::Install, true).unwrap();
        let agents_before = fs::read_to_string(agents_path(&home)).unwrap();
        let current_before = fs::read_to_string(current_path(&home)).unwrap();
        let newer = temp.path().join("newer-source");
        copy_path(&source_root(), &newer).unwrap();
        set_release_identity(&newer, "1.1.0");
        let source = load_source(Some(newer)).unwrap();
        let next = State {
            version: "1.1.0".into(),
            payload_sha256: source.manifest.payload_sha256.clone(),
            installed_at_unix_ns: now_ns(),
            agents_existed_before: true,
            managed_separator: "\n".into(),
        };
        create_immutable_version(&home, &source, &next, false).unwrap();
        let backup = Backup {
            agents: Some(agents_before.clone()),
            current: Some(current_before.clone()),
        };
        let backup_path = create_backup(&home, &backup).unwrap();
        write_journal(
            &home,
            "upgrade",
            &backup_path,
            Some(&agents_before),
            Some(&current_before),
            Some(&next),
        )
        .unwrap();
        let recovered = run(&home, Command::Recover, false).unwrap();
        assert_eq!(recovered.code, "OK_RECOVERED");
        assert!(!versions_path(&home).join("1.1.0").exists());
        assert_eq!(
            fs::read_to_string(agents_path(&home)).unwrap(),
            agents_before
        );
        assert_eq!(
            fs::read_to_string(current_path(&home)).unwrap(),
            current_before
        );
    }

    #[test]
    fn pending_journal_cannot_escape_backup_directory() {
        let temp = fixture();
        let home = temp.path().join("fixture-codex");
        fs::create_dir_all(&home).unwrap();
        run(&home, Command::Install, true).unwrap();
        let outside = temp.path().join("outside-backup.json");
        fs::write(&outside, "{}").unwrap();
        let journal = Journal {
            protocol: PROTOCOL,
            operation: "rollback".into(),
            backup: outside.display().to_string(),
            expected_agents_sha256: None,
            expected_current_sha256: None,
            created_version: None,
            created_payload_sha256: None,
            replaced_version_backup: None,
            replaced_version: None,
        };
        fs::create_dir_all(router_path(&home)).unwrap();
        fs::write(journal_path(&home), serde_json::to_vec(&journal).unwrap()).unwrap();
        assert_eq!(
            run(&home, Command::Rollback, false).unwrap_err().code(),
            "E_TRANSACTION_PENDING"
        );
    }

    #[test]
    fn safe_auto_enable_is_opt_in_idempotent_and_restores_only_managed_keys() {
        let temp = fixture();
        let home = temp.path().join("fixture-codex");
        fs::create_dir_all(&home).unwrap();
        let original = "# keep\nuser_value = 7\nsandbox_mode = \"read-only\"\n";
        fs::write(config_path(&home), original).unwrap();

        let enabled = run(&home, Command::SafeAutoEnable, false).unwrap();
        assert_eq!(enabled.code, "OK");
        let active = fs::read_to_string(config_path(&home)).unwrap();
        assert!(active.contains("sandbox_mode = \"workspace-write\""));
        assert!(active.contains("approval_policy = \"on-request\""));
        assert!(active.contains("approvals_reviewer = \"auto_review\""));
        assert!(active.contains("user_value = 7"));
        assert_eq!(
            run(&home, Command::SafeAutoEnable, false).unwrap().code,
            "OK_NO_CHANGE"
        );
        assert_eq!(
            run(&home, Command::SafeAutoStatus, false).unwrap().code,
            "SAFE_AUTO_ACTIVE"
        );

        let mut user_edit = active.clone();
        user_edit.push_str("user_added = \"preserve\"\n");
        fs::write(config_path(&home), user_edit).unwrap();
        let restored = run(&home, Command::SafeAutoRestore, false).unwrap();
        assert_eq!(restored.code, "OK");
        let after = fs::read_to_string(config_path(&home)).unwrap();
        assert!(after.contains("user_value = 7"));
        assert!(after.contains("user_added = \"preserve\""));
        assert!(after.contains("sandbox_mode = \"read-only\""));
        assert!(!after.contains("approvals_reviewer"));
        assert_eq!(
            run(&home, Command::SafeAutoStatus, false).unwrap().code,
            "SAFE_AUTO_ABSENT"
        );

        let absent_home = temp.path().join("absent-config-codex");
        fs::create_dir_all(&absent_home).unwrap();
        run(&absent_home, Command::SafeAutoEnable, false).unwrap();
        assert!(config_path(&absent_home).exists());
        run(&absent_home, Command::SafeAutoRestore, false).unwrap();
        assert!(!config_path(&absent_home).exists());

        let all_keys_home = temp.path().join("all-keys-codex");
        fs::create_dir_all(&all_keys_home).unwrap();
        let all_keys_original = "sandbox_mode = \"read-only\"\napproval_policy = \"never\"\napprovals_reviewer = \"human\"\n";
        fs::write(config_path(&all_keys_home), all_keys_original).unwrap();
        run(&all_keys_home, Command::SafeAutoEnable, false).unwrap();
        run(&all_keys_home, Command::SafeAutoRestore, false).unwrap();
        assert_eq!(
            fs::read_to_string(config_path(&all_keys_home)).unwrap(),
            all_keys_original
        );
    }

    #[test]
    fn safe_auto_drift_and_invalid_toml_fail_closed() {
        let temp = fixture();
        let home = temp.path().join("fixture-codex");
        fs::create_dir_all(&home).unwrap();
        fs::write(config_path(&home), "user_value = 7\n").unwrap();
        run(&home, Command::SafeAutoEnable, false).unwrap();
        let active = fs::read_to_string(config_path(&home)).unwrap();
        fs::write(
            config_path(&home),
            active.replace("auto_review", "human_review"),
        )
        .unwrap();
        assert_eq!(
            run(&home, Command::SafeAutoStatus, false).unwrap().code,
            "SAFE_AUTO_DRIFT"
        );
        assert_eq!(
            run(&home, Command::SafeAutoDoctor, false)
                .unwrap_err()
                .code(),
            "E_SAFE_AUTO_DRIFT"
        );
        assert_eq!(
            run(&home, Command::SafeAutoRestore, false)
                .unwrap_err()
                .code(),
            "E_SAFE_AUTO_DRIFT"
        );

        let invalid = temp.path().join("invalid-codex");
        fs::create_dir_all(&invalid).unwrap();
        fs::write(
            config_path(&invalid),
            "sandbox_mode = \"old\"\nsandbox_mode = \"duplicate\"\n",
        )
        .unwrap();
        assert_eq!(
            run(&invalid, Command::SafeAutoEnable, false)
                .unwrap_err()
                .code(),
            "E_CONFIG_INVALID"
        );
    }

    #[test]
    fn safe_auto_restore_requires_explicit_boundary_before_router_uninstall() {
        let temp = fixture();
        let home = temp.path().join("fixture-codex");
        fs::create_dir_all(&home).unwrap();
        run(&home, Command::Install, true).unwrap();
        run(&home, Command::SafeAutoEnable, false).unwrap();
        let routing_doctor = run(&home, Command::Doctor, false).unwrap();
        assert!(routing_doctor
            .details
            .iter()
            .any(|detail| detail.contains("safe-auto=active")));
        assert_eq!(
            run(&home, Command::Uninstall, false).unwrap_err().code(),
            "E_SAFE_AUTO_ACTIVE"
        );
        run(&home, Command::SafeAutoRestore, false).unwrap();
        assert_eq!(run(&home, Command::Uninstall, false).unwrap().code, "OK");
    }

    #[test]
    fn safe_auto_recovery_finishes_after_config_restore_before_state_cleanup() {
        for remove_state in [false, true] {
            let temp = fixture();
            let home = temp.path().join("fixture-codex");
            fs::create_dir_all(&home).unwrap();
            fs::write(config_path(&home), "user_value = 7\n").unwrap();
            run(&home, Command::SafeAutoEnable, false).unwrap();
            let state = read_safe_auto_state(&home).unwrap().unwrap();
            let active = fs::read_to_string(config_path(&home)).unwrap();
            let restored = restore_safe_auto_document(parse_config(Some(&active)).unwrap(), &state)
                .unwrap()
                .map(|document| document.to_string());
            let journal = SafeAutoJournal {
                protocol: PROTOCOL,
                operation: "restore".into(),
                before_hash: optional_hash(Some(&active)),
                after_hash: optional_hash(restored.as_deref()),
                state,
            };
            restore_optional(&config_path(&home), restored.as_deref()).unwrap();
            if remove_state {
                fs::remove_file(safe_auto_state_path(&home)).unwrap();
            }
            atomic_write(
                &safe_auto_journal_path(&home),
                serde_json::to_vec_pretty(&journal).unwrap().as_slice(),
            )
            .unwrap();
            assert_eq!(
                run(&home, Command::Recover, false).unwrap().code,
                "OK_RECOVERED"
            );
            assert!(!safe_auto_journal_path(&home).exists());
            assert!(!safe_auto_state_path(&home).exists());
            assert_eq!(
                fs::read_to_string(config_path(&home)).unwrap(),
                "user_value = 7\n"
            );
        }
    }

    #[test]
    fn safe_auto_recovery_without_router_state_reports_safe_auto_doctor_active() {
        let temp = fixture();
        let home = temp.path().join("fixture-codex");
        fs::create_dir_all(&home).unwrap();
        let original = "user_value = 7\n";
        fs::write(config_path(&home), original).unwrap();

        // Simulate an interrupted safe-auto enable after config.toml was written but
        // before safe-auto.json was durably created. No routing install/state exists.
        run(&home, Command::SafeAutoEnable, false).unwrap();
        let state = read_safe_auto_state(&home).unwrap().unwrap();
        let active = fs::read_to_string(config_path(&home)).unwrap();
        fs::remove_file(safe_auto_state_path(&home)).unwrap();
        let journal = SafeAutoJournal {
            protocol: PROTOCOL,
            operation: "enable".into(),
            before_hash: optional_hash(Some(original)),
            after_hash: optional_hash(Some(&active)),
            state,
        };
        atomic_write(
            &safe_auto_journal_path(&home),
            serde_json::to_vec_pretty(&journal).unwrap().as_slice(),
        )
        .unwrap();

        assert_eq!(
            run(&home, Command::Recover, false).unwrap().code,
            "OK_RECOVERED"
        );
        assert_eq!(
            run(&home, Command::SafeAutoDoctor, false).unwrap().code,
            "OK_ACTIVE"
        );
        assert!(!safe_auto_journal_path(&home).exists());
        assert!(safe_auto_state_path(&home).exists());
        // General routing Doctor reports the independent safe-auto boundary honestly
        // because routing was never installed; this is not a recovery failure.
        assert_eq!(
            run(&home, Command::Doctor, false).unwrap_err().code(),
            "E_SAFE_AUTO_ACTIVE"
        );
    }

    #[test]
    fn safe_auto_recovery_rejects_unknown_config_hash() {
        let temp = fixture();
        let home = temp.path().join("fixture-codex");
        fs::create_dir_all(&home).unwrap();
        fs::write(config_path(&home), "user_value = 7\n").unwrap();
        run(&home, Command::SafeAutoEnable, false).unwrap();
        let state = read_safe_auto_state(&home).unwrap().unwrap();
        let journal = SafeAutoJournal {
            protocol: PROTOCOL,
            operation: "restore".into(),
            before_hash: "0".repeat(64),
            after_hash: "1".repeat(64),
            state,
        };
        atomic_write(
            &safe_auto_journal_path(&home),
            serde_json::to_vec_pretty(&journal).unwrap().as_slice(),
        )
        .unwrap();
        fs::write(config_path(&home), "user edit after interruption\n").unwrap();
        assert_eq!(
            run(&home, Command::Recover, false).unwrap_err().code(),
            "E_SAFE_AUTO_TRANSACTION_PENDING"
        );
        assert!(safe_auto_journal_path(&home).exists());
    }
}
