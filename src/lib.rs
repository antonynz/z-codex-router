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

#[derive(Debug, Error)]
pub enum RouterError {
    #[error("{message}")]
    Coded { code: &'static str, message: String },
    #[error("I/O error: {0}")]
    Io(#[from] std::io::Error),
    #[error("JSON error: {0}")]
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
    Upgrade { dry_run: bool },
    Recover,
    Rollback,
    Uninstall,
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
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ReleaseManifest {
    schema_version: u8,
    version: String,
    channel: String,
    payload_sha256: String,
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
                "cannot resolve a Codex home; set CODEX_HOME or pass --codex-home",
            )
        })?;
    let resolved = resolve_path_safely(&home)?;
    if is_dangerous_home(&resolved) {
        return Err(RouterError::coded(
            "E_CODEX_HOME_DANGEROUS",
            format!("refusing unsafe CODEX_HOME {}", resolved.display()),
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
            "paths containing '..' are not accepted",
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
            .ok_or_else(|| RouterError::coded("E_PATH_INVALID", "path has no existing parent"))?;
        suffix.push(name.to_os_string());
        ancestor = ancestor
            .parent()
            .ok_or_else(|| RouterError::coded("E_PATH_INVALID", "path has no existing parent"))?;
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
    let root = source.ok_or_else(|| {
        RouterError::coded(
            "E_SOURCE_REQUIRED",
            "a plugin source is required for this action",
        )
    })?;
    let root = resolve_path_safely(&root)?;
    let manifest_path = root.join("release/manifest.json");
    let bytes = fs::read(&manifest_path)
        .map_err(|_| RouterError::coded("E_SOURCE_INVALID", "release/manifest.json is missing"))?;
    let manifest: ReleaseManifest = serde_json::from_slice(&bytes)?;
    if manifest.schema_version != 1
        || manifest.channel != "stable"
        || Version::parse(&manifest.version).is_err()
    {
        return Err(RouterError::coded(
            "E_SOURCE_INVALID",
            "release manifest must be schema 1, stable, and semantic-versioned",
        ));
    }
    validate_payload(&root)?;
    let actual = payload_hash(&root)?;
    if actual != manifest.payload_sha256 {
        return Err(RouterError::coded(
            "E_SOURCE_CHECKSUM",
            "release payload checksum does not match manifest",
        ));
    }
    Ok(SourceRelease { root, manifest })
}

fn validate_payload(root: &Path) -> Result<()> {
    for relative in required_payload_paths() {
        if !root.join(relative).is_file() {
            return Err(RouterError::coded(
                "E_PROFILE_INCOMPATIBLE",
                format!("required payload file is missing: {relative}"),
            ));
        }
    }
    validate_profiles(root)?;
    let compatibility: serde_json::Value =
        serde_json::from_slice(&fs::read(root.join("compatibility.json"))?)?;
    let config_contract = &compatibility["installer"]["configToml"];
    if config_contract["ordinaryInstallAndRoutingEnable"] != "untouched"
        || config_contract["safeAutoApproval"] != "explicit-opt-in-three-keys"
    {
        return Err(RouterError::coded(
            "E_PROFILE_INCOMPATIBLE",
            "compatibility metadata does not describe the safe-auto config boundary",
        ));
    }
    let supported = compatibility["runtime"]["platforms"]
        .as_array()
        .is_some_and(|items| {
            items
                .iter()
                .any(|item| item.as_str() == Some(profile_platform()))
        });
    if !supported {
        return Err(RouterError::coded(
            "E_PROFILE_INCOMPATIBLE",
            "current platform is not declared compatible",
        ));
    }
    let supported_architecture = compatibility["runtime"]["architectures"]
        .as_array()
        .is_some_and(|items| {
            items
                .iter()
                .any(|item| item.as_str() == Some(profile_architecture()))
        });
    if !supported_architecture {
        return Err(RouterError::coded(
            "E_PROFILE_INCOMPATIBLE",
            "current architecture is not declared compatible",
        ));
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
            "profile schema is invalid",
        ));
    }
    let portable = parse_profile(&root.join("profiles/portable/default.toml"))?;
    let stable = parse_profile(&root.join("profiles/stable/current-gpt-5.6-reference.toml"))?;
    let candidate = parse_profile(&root.join("profiles/candidate/example-next-model.toml"))?;
    for profile in [&portable, &stable, &candidate] {
        if profile.get("schema_version").and_then(Item::as_integer) != Some(1) {
            return Err(RouterError::coded(
                "E_PROFILE_INCOMPATIBLE",
                "profile schema_version must equal 1",
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
            "portable profile does not declare tri-state runtime preflight",
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
            "portable profile does not fail closed for invalid policy inputs",
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
            "portable profile receipt policy is invalid",
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
                "portable profile observability policy is invalid",
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
            "portable profile observability states are incomplete",
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
            "portable profile selection is invalid",
        ));
    }

    let stable_metadata = profile_table(&stable, "metadata")?;
    if stable_metadata.get("status").and_then(Item::as_str) != Some("reference") {
        return Err(RouterError::coded(
            "E_PROFILE_INCOMPATIBLE",
            "stable reference profile status is invalid",
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
            "candidate profile must stay disabled and unevaluated",
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
            format!("profile table {name} is missing"),
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
                format!("profile routing entry {tier} is incomplete"),
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
        let relative = file.strip_prefix(root).map_err(|_| {
            RouterError::coded("E_SOURCE_INVALID", "payload path escapes source root")
        })?;
        hasher.update(relative.to_string_lossy().replace('\\', "/").as_bytes());
        hasher.update([0]);
        hasher.update(fs::read(file)?);
        hasher.update([0]);
    }
    Ok(format!("{:x}", hasher.finalize()))
}

fn install(
    home: &Path,
    source: SourceRelease,
    dry_run: bool,
    allow_upgrade: bool,
) -> Result<Outcome> {
    ensure_no_pending_transaction(home)?;
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
        let current_version = Version::parse(&current.version).map_err(|_| {
            RouterError::coded("E_STATE_INVALID", "installed version is not semantic")
        })?;
        let next_version = Version::parse(&next_state.version).map_err(|_| {
            RouterError::coded("E_SOURCE_INVALID", "source version is not semantic")
        })?;
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
                vec!["same version and managed content already installed".into()],
            ));
        } else if !allow_upgrade {
            return Err(RouterError::coded(
                "E_UPGRADE_REQUIRED",
                "a different router version is installed; use upgrade",
            ));
        } else if current.version == next_state.version {
            // An explicit upgrade may refresh a payload at the same public version. This is
            // used for local 1.0.2 policy payloads and keeps safe-auto/config untouched.
            ensure_managed_identity(agents_before.as_deref(), current)?;
            let active_root = versions_path(home).join(&current.version);
            if payload_hash(&active_root)? != current.payload_sha256 {
                return Err(RouterError::coded(
                    "E_PAYLOAD_DRIFT",
                    "installed version payload no longer matches current.json",
                ));
            }
            refresh_same_version = true;
        } else {
            ensure_managed_matches(agents_before.as_deref(), current)?;
            validate_active_installation(home, current)?;
            if next_version <= current_version {
                return Err(RouterError::coded(
                    "E_VERSION_NOT_NEWER",
                    "source stable release is not newer than installed version",
                ));
            }
        }
    } else if agents_before
        .as_deref()
        .is_some_and(|text| text.contains(managed_begin()))
    {
        return Err(RouterError::coded(
            "E_MANAGED_BLOCK_CONFLICT",
            "AGENTS.md contains an untracked router managed block",
        ));
    }

    let agents_after = match existing_state.as_ref() {
        Some(previous) if refresh_same_version => replace_managed_by_identity(
            agents_before.as_deref().unwrap_or_default(),
            previous,
            &next_state,
        )?,
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
                format!("would install immutable version under {}", versions_path(home).display()),
                format!("would atomically update {}", current_path(home).display()),
                "would append or exactly replace one hashed AGENTS.md block; config.toml is untouched".into(),
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
        .map_err(|_| RouterError::coded("E_DATA", "router state cannot be encoded as UTF-8"))?;
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
        vec!["stable profile remains selected; disabled candidate was not promoted".into()],
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
                    "safe-auto approval policy is active without an installed router; run `safe-auto restore` before cleanup",
                ))
            }
            SafeAutoStatus::Drift => {
                return Err(RouterError::coded(
                    "E_SAFE_AUTO_DRIFT",
                    "safe-auto state exists but managed keys changed",
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
                "AGENTS.md has a router managed block but router state is absent",
            ));
        }
        if router_path(home).exists() {
            return Err(RouterError::coded(
                "E_STALE_MANAGED_ASSETS",
                "router managed assets remain without a current state; run the uninstall skill to clean them",
            ));
        }
        return Ok(outcome(
            "doctor",
            "OK_NOT_ENABLED",
            None,
            false,
            None,
            vec![
                "no managed routing state is enabled; plugin registration is outside routerctl"
                    .into(),
            ],
        ));
    };
    validate_active_installation(home, &state)?;
    ensure_managed_matches(agents.as_deref(), &state)?;
    let safe_detail = match evaluate_safe_auto(home)? {
        SafeAutoStatus::Active => "safe-auto=active",
        SafeAutoStatus::Absent => "safe-auto=absent",
        SafeAutoStatus::Drift => {
            return Err(RouterError::coded(
                "E_SAFE_AUTO_DRIFT",
                "safe-auto managed keys changed after enablement; run safe-auto status and restore only after resolving the user edit",
            ))
        }
    };
    Ok(outcome(
        "doctor",
        "OK_ENABLED",
        Some(state.version),
        false,
        None,
        vec![format!("managed block, payload hash, profile policy, and runtime platform are valid; {safe_detail}")],
    ))
}

fn recover(home: &Path) -> Result<Outcome> {
    if safe_auto_journal_path(home).exists() && !journal_path(home).exists() {
        return safe_auto_recover(home);
    }
    let (journal, backup, backup_path) = pending_transaction(home)?;
    let expected_agents = journal.expected_agents_sha256.as_deref().ok_or_else(|| {
        RouterError::coded(
            "E_TRANSACTION_PENDING",
            "pending transaction lacks safe recovery checks; do not overwrite files manually",
        )
    })?;
    let expected_current = journal.expected_current_sha256.as_deref().ok_or_else(|| {
        RouterError::coded(
            "E_TRANSACTION_PENDING",
            "pending transaction lacks safe recovery checks; do not overwrite files manually",
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
            "pending transaction no longer matches its before/after values; preserve files and resolve the conflict",
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
                "replaced version backup has no recoverable version identity",
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
        vec!["restored the original transaction state after exact before/after checks".into()],
    ))
}

fn rollback(home: &Path) -> Result<Outcome> {
    if journal_path(home).exists() {
        return recover(home);
    }
    let current = read_state(home)?
        .ok_or_else(|| RouterError::coded("E_NOT_INSTALLED", "router state is absent"))?;
    let agents_before = read_optional(&agents_path(home))?;
    ensure_managed_matches(agents_before.as_deref(), &current)?;
    validate_active_installation(home, &current)?;
    let rollback_backup_path = latest_backup(home)?;
    let rollback_backup: Backup = serde_json::from_slice(&fs::read(&rollback_backup_path)?)?;
    let target = match rollback_backup.current.as_deref() {
        Some(text) => Some(serde_json::from_str::<State>(text).map_err(|_| {
            RouterError::coded(
                "E_STATE_INVALID",
                "rollback backup current pointer is invalid",
            )
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
        vec!["replaced only the exact managed block and current pointer; user-managed AGENTS.md content was preserved".into()],
    ))
}

fn uninstall(home: &Path) -> Result<Outcome> {
    ensure_no_pending_transaction(home)?;
    if safe_auto_state_path(home).exists() || safe_auto_journal_path(home).exists() {
        return Err(RouterError::coded(
            "E_SAFE_AUTO_ACTIVE",
            "safe-auto approval policy is still managed; run `safe-auto restore` before uninstall",
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
                "AGENTS.md has a router managed block but router state is absent",
            ));
        }
        let changed = cleanup_managed_assets(home)?;
        return Ok(outcome(
            "uninstall",
            if changed { "OK" } else { "OK_NO_CHANGE" },
            None,
            changed,
            None,
            vec![
                "global routing was already disabled; no user-managed AGENTS.md content changed"
                    .into(),
            ],
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
                "AGENTS.md changed while uninstalling; user content was not accepted as verified",
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
        vec!["revoked only the matching managed block and state, verified user content, and cleaned router-managed assets".into()],
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
            vec!["safe-auto approval policy is already active and unchanged".into()],
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
            "config.toml changed while preparing safe-auto enablement; refusing to overwrite it",
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
            "wrote only sandbox_mode, approval_policy, and approvals_reviewer".into(),
            "sandbox remains workspace-write; auto-review replaces only the eligible reviewer".into(),
            "user authorization is still required for Computer Use, credentials, and high-risk or irreversible external actions".into(),
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
            vec!["safe-auto approval policy is absent; no configuration was changed".into()],
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
            "config.toml changed while preparing safe-auto restore; refusing to overwrite it",
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
            "restored only the three managed keys and preserved unrelated config content".into(),
            "router uninstall remains separate; restore safe-auto before uninstalling routing"
                .into(),
        ],
    ))
}

fn safe_auto_status(home: &Path) -> Result<Outcome> {
    if safe_auto_journal_path(home).exists() {
        return Err(RouterError::coded(
            "E_SAFE_AUTO_TRANSACTION_PENDING",
            "safe-auto has an interrupted transaction; run `recover` before another action",
        ));
    }
    let status = evaluate_safe_auto(home)?;
    let (code, detail) = match status {
        SafeAutoStatus::Active => ("SAFE_AUTO_ACTIVE", "safe-auto approval policy is active"),
        SafeAutoStatus::Drift => (
            "SAFE_AUTO_DRIFT",
            "safe-auto state exists but one or more managed keys changed",
        ),
        SafeAutoStatus::Absent => (
            "SAFE_AUTO_ABSENT",
            "safe-auto approval policy is not managed; configuration was not changed",
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
            vec!["managed three-key policy is present and unchanged".into()],
        )),
        SafeAutoStatus::Absent => Ok(outcome(
            "safe-auto-doctor",
            "OK_ABSENT",
            None,
            false,
            None,
            vec!["safe-auto is not enabled; no permission configuration is managed".into()],
        )),
        SafeAutoStatus::Drift => Err(RouterError::coded(
            "E_SAFE_AUTO_DRIFT",
            "safe-auto managed keys changed after enablement; restore is blocked to avoid overwriting user changes",
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
            "config.toml changed outside the interrupted safe-auto transaction; preserve it and resolve the conflict",
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
            vec!["the interrupted safe-auto write had not changed config.toml".into()],
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
                "safe-auto restored config does not match its journal; preserve config.toml",
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
        vec!["completed the interrupted safe-auto transaction after exact hash checks".into()],
    ))
}

fn ensure_no_safe_auto_transaction(home: &Path) -> Result<()> {
    if safe_auto_journal_path(home).exists() {
        return Err(RouterError::coded(
            "E_SAFE_AUTO_TRANSACTION_PENDING",
            "a previous safe-auto transaction requires `recover` before another action",
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
            "safe-auto managed keys are absent or changed; refusing to overwrite user configuration",
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
                    format!("managed config key {key} must be a scalar TOML value"),
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
                        format!("cannot restore original {key}: {error}"),
                    )
                })?;
                let item = parsed.get(key).cloned().ok_or_else(|| {
                    RouterError::coded(
                        "E_SAFE_AUTO_STATE_INVALID",
                        format!("safe-auto state lacks a restorable {key} value"),
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
            RouterError::coded(
                "E_CONFIG_INVALID",
                format!("config.toml is invalid: {error}"),
            )
        })
}

fn read_safe_auto_state(home: &Path) -> Result<Option<SafeAutoState>> {
    let Some(text) = read_optional(&safe_auto_state_path(home))? else {
        return Ok(None);
    };
    let state: SafeAutoState = serde_json::from_str(&text).map_err(|_| {
        RouterError::coded("E_SAFE_AUTO_STATE_INVALID", "safe-auto state is invalid")
    })?;
    if state.protocol != PROTOCOL
        || SAFE_AUTO_KEYS
            .iter()
            .any(|key| !state.original.contains_key(*key) || !state.managed.contains_key(*key))
        || state.managed != managed_safe_auto_values()
    {
        return Err(RouterError::coded(
            "E_SAFE_AUTO_STATE_INVALID",
            "safe-auto state does not describe the supported three-key policy",
        ));
    }
    Ok(Some(state))
}

fn read_safe_auto_journal(home: &Path) -> Result<SafeAutoJournal> {
    let text = read_optional(&safe_auto_journal_path(home))?.ok_or_else(|| {
        RouterError::coded(
            "E_NOT_INSTALLED",
            "no interrupted safe-auto transaction is present",
        )
    })?;
    let journal: SafeAutoJournal = serde_json::from_str(&text).map_err(|_| {
        RouterError::coded(
            "E_SAFE_AUTO_TRANSACTION_PENDING",
            "safe-auto transaction journal is invalid",
        )
    })?;
    if journal.protocol != PROTOCOL || !matches!(journal.operation.as_str(), "enable" | "restore") {
        return Err(RouterError::coded(
            "E_SAFE_AUTO_TRANSACTION_PENDING",
            "safe-auto transaction journal is unsupported",
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
            "managed AGENTS.md block is not byte-for-byte intact",
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
            "managed AGENTS.md block is not byte-for-byte intact",
        )
    })?;
    if existing.matches(managed_begin()).count() != 1 {
        return Err(RouterError::coded(
            "E_MANAGED_BLOCK_DRIFT",
            "AGENTS.md contains multiple managed blocks",
        ));
    }
    let mut replaced =
        String::with_capacity(existing.len() - old.len() + managed_block(next).len());
    replaced.push_str(&existing[..index]);
    replaced.push_str(&managed_block(next));
    replaced.push_str(&existing[index + old.len()..]);
    Ok(replaced)
}

fn replace_managed_by_identity(existing: &str, previous: &State, next: &State) -> Result<String> {
    let identity = format!(
        "id={ROUTER_ID} version={} sha256={}",
        previous.version, previous.payload_sha256
    );
    if existing.matches(managed_begin()).count() != 1 || !existing.contains(&identity) {
        return Err(RouterError::coded(
            "E_MANAGED_BLOCK_DRIFT",
            "managed AGENTS.md block identity is not byte-for-byte intact",
        ));
    }
    let begin = existing.find(managed_begin()).ok_or_else(|| {
        RouterError::coded("E_MANAGED_BLOCK_DRIFT", "managed AGENTS.md block is absent")
    })?;
    let end_marker = format!("<!-- z-codex-router:end id={ROUTER_ID} -->");
    let end = existing[begin..]
        .find(&end_marker)
        .map(|offset| begin + offset + end_marker.len())
        .ok_or_else(|| {
            RouterError::coded(
                "E_MANAGED_BLOCK_DRIFT",
                "managed AGENTS.md block is truncated",
            )
        })?;
    let mut replaced = String::with_capacity(existing.len() + managed_block(next).len());
    replaced.push_str(&existing[..begin]);
    replaced.push_str(&managed_block(next));
    replaced.push_str(&existing[end..]);
    Ok(replaced)
}

fn ensure_managed_identity(existing: Option<&str>, state: &State) -> Result<()> {
    let text = existing
        .ok_or_else(|| RouterError::coded("E_MANAGED_BLOCK_DRIFT", "AGENTS.md is missing"))?;
    let identity = format!(
        "id={ROUTER_ID} version={} sha256={}",
        state.version, state.payload_sha256
    );
    if text.matches(managed_begin()).count() == 1 && text.contains(&identity) {
        return Ok(());
    }
    Err(RouterError::coded(
        "E_MANAGED_BLOCK_DRIFT",
        "managed AGENTS.md block identity is invalid",
    ))
}

fn ensure_managed_matches(existing: Option<&str>, state: &State) -> Result<()> {
    let text = existing
        .ok_or_else(|| RouterError::coded("E_MANAGED_BLOCK_DRIFT", "AGENTS.md is missing"))?;
    let exact = managed_block(state);
    if text.contains(&exact) && text.matches(managed_begin()).count() == 1 {
        return Ok(());
    }
    if text.contains(managed_begin()) {
        return Err(RouterError::coded(
            "E_MANAGED_BLOCK_DRIFT",
            "managed AGENTS.md block has changed",
        ));
    }
    Err(RouterError::coded(
        "E_MANAGED_BLOCK_DRIFT",
        "managed AGENTS.md block is absent",
    ))
}

fn managed_begin() -> &'static str {
    "<!-- z-codex-router:begin"
}

fn managed_block(state: &State) -> String {
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
        "<!-- z-codex-router:begin id={ROUTER_ID} version={} sha256={} protocol={PROTOCOL}{boundary} -->\n# Z Codex Router (managed)\nFor each independent task, first resolve the Codex home: use explicit `CODEX_HOME` when set; otherwise use `~/.codex`. Never resolve this path relative to a repository or worktree. Then read `<codex_home>/z-codex-router/current.json`, followed by `z-codex-router/versions/<current.version>/core/router.md`, resolve `z-codex-router/versions/<current.version>/profiles/portable/default.toml`, and read one relevant mode. Preserve user authority. Runtime metadata is tri-state: exact observable fields are verified, visible differences are mismatch and fail closed, and missing fields are runtime_observability=unobservable. Route receipt protocol 1 is parent-owned: only the real create_thread caller may classify and create it, automatic root creation is at most one, child threads do not reclassify or recurse, and thread IDs come only from the tool return.\n<!-- z-codex-router:end id={ROUTER_ID} -->",
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
                "existing version directory has a different payload",
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
                "staged immutable payload hash differs from source",
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
            .map_err(|_| RouterError::coded("E_SOURCE_INVALID", "cannot copy payload"))?;
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
        return Err(RouterError::coded(
            "E_STATE_INVALID",
            "installed version directory is missing",
        ));
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
        .ok_or_else(|| RouterError::coded("E_NO_BACKUP", "no router backup is available"))
}

fn validated_backup_path(home: &Path, candidate: &Path) -> Result<PathBuf> {
    let root = router_path(home).join("backups");
    let canonical_root = fs::canonicalize(&root).map_err(|_| {
        RouterError::coded("E_TRANSACTION_PENDING", "router backup root is missing")
    })?;
    let canonical_candidate = fs::canonicalize(candidate)
        .map_err(|_| RouterError::coded("E_TRANSACTION_PENDING", "journal backup is missing"))?;
    let is_backup = canonical_candidate
        .file_name()
        .is_some_and(|name| name.to_string_lossy().starts_with("backup-"));
    if !canonical_candidate.starts_with(&canonical_root) || !is_backup {
        return Err(RouterError::coded(
            "E_TRANSACTION_PENDING",
            "journal backup escapes the managed backup directory",
        ));
    }
    Ok(canonical_candidate)
}

fn validated_version_backup_path(home: &Path, candidate: &Path) -> Result<PathBuf> {
    let root = router_path(home).join("backups/versions");
    let canonical_root = fs::canonicalize(&root).map_err(|_| {
        RouterError::coded("E_TRANSACTION_PENDING", "version backup root is missing")
    })?;
    let canonical_candidate = fs::canonicalize(candidate)
        .map_err(|_| RouterError::coded("E_TRANSACTION_PENDING", "version backup is missing"))?;
    let is_backup = canonical_candidate
        .file_name()
        .is_some_and(|name| name.to_string_lossy().starts_with("backup-"));
    if !canonical_candidate.starts_with(&canonical_root) || !is_backup {
        return Err(RouterError::coded(
            "E_TRANSACTION_PENDING",
            "version backup escapes the managed backup directory",
        ));
    }
    Ok(canonical_candidate)
}

fn pending_transaction(home: &Path) -> Result<(Journal, Backup, PathBuf)> {
    let text = read_optional(&journal_path(home))?.ok_or_else(|| {
        RouterError::coded(
            "E_NOT_INSTALLED",
            "no interrupted router transaction is present",
        )
    })?;
    let journal: Journal = serde_json::from_str(&text).map_err(|_| {
        RouterError::coded("E_TRANSACTION_PENDING", "transaction journal is invalid")
    })?;
    if journal.protocol != PROTOCOL {
        return Err(RouterError::coded(
            "E_TRANSACTION_PENDING",
            "transaction journal protocol is unsupported",
        ));
    }
    let backup_path = validated_backup_path(home, Path::new(&journal.backup))?;
    let backup: Backup = serde_json::from_slice(&fs::read(&backup_path)?).map_err(|_| {
        RouterError::coded("E_TRANSACTION_PENDING", "transaction backup is invalid")
    })?;
    Ok((journal, backup, backup_path))
}

fn restore_backup_contents(home: &Path, backup: &Backup) -> Result<()> {
    restore_optional(&agents_path(home), backup.agents.as_deref())?;
    restore_optional(&current_path(home), backup.current.as_deref())?;
    Ok(())
}

fn validate_active_installation(home: &Path, state: &State) -> Result<()> {
    if Version::parse(&state.version).is_err() {
        return Err(RouterError::coded(
            "E_STATE_INVALID",
            "installed version is not semantic",
        ));
    }
    let version_root = versions_path(home).join(&state.version);
    validate_payload(&version_root)?;
    if payload_hash(&version_root)? != state.payload_sha256 {
        return Err(RouterError::coded(
            "E_PAYLOAD_DRIFT",
            "installed version payload hash differs from state",
        ));
    }
    Ok(())
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
            "pending transaction version is invalid",
        ));
    }
    let root = versions_path(home).join(version);
    if !root.exists() {
        return Ok(());
    }
    let installed: State =
        serde_json::from_slice(&fs::read(root.join("install.json"))?).map_err(|_| {
            RouterError::coded("E_TRANSACTION_PENDING", "pending version state is invalid")
        })?;
    if installed.version != version || installed.payload_sha256 != payload_sha256 {
        return Err(RouterError::coded(
            "E_TRANSACTION_PENDING",
            "pending version conflicts with managed assets",
        ));
    }
    validate_payload(&root)?;
    if payload_hash(&root)? != payload_sha256 {
        return Err(RouterError::coded(
            "E_PAYLOAD_DRIFT",
            "pending version payload hash differs from its transaction",
        ));
    }
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
            "router managed asset root is not a regular directory",
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
                    format!("unexpected managed asset {}", entry.path().display()),
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
            "router versions path is not a regular directory",
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
                format!("invalid managed version asset {}", entry.path().display()),
            ));
        }
        let state: State = serde_json::from_slice(&fs::read(entry.path().join("install.json"))?)
            .map_err(|_| {
                RouterError::coded(
                    "E_MANAGED_ASSET_CONFLICT",
                    "managed version state is invalid",
                )
            })?;
        if state.version != name {
            return Err(RouterError::coded(
                "E_MANAGED_ASSET_CONFLICT",
                "managed version directory does not match its state",
            ));
        }
        validate_payload(&entry.path())?;
        if payload_hash(&entry.path())? != state.payload_sha256 {
            return Err(RouterError::coded(
                "E_PAYLOAD_DRIFT",
                "managed version payload hash differs from its state",
            ));
        }
    }
    Ok(())
}

fn validate_backup_assets(backups: &Path) -> Result<()> {
    let metadata = fs::symlink_metadata(backups)?;
    if !metadata.is_dir() || metadata.file_type().is_symlink() {
        return Err(RouterError::coded(
            "E_MANAGED_ASSET_CONFLICT",
            "router backups path is not a regular directory",
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
                format!("invalid managed backup asset {}", entry.path().display()),
            ));
        }
        serde_json::from_slice::<Backup>(&fs::read(entry.path())?).map_err(|_| {
            RouterError::coded("E_MANAGED_ASSET_CONFLICT", "managed backup is invalid")
        })?;
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
            RouterError::coded("E_STATE_INVALID", "router current pointer is invalid")
        })?)),
        None => Ok(None),
    }
}

fn ensure_no_pending_transaction(home: &Path) -> Result<()> {
    if journal_path(home).exists() {
        return Err(RouterError::coded(
            "E_TRANSACTION_PENDING",
            "a previous router transaction requires safe recovery before another action",
        ));
    }
    Ok(())
}

fn read_optional(path: &Path) -> Result<Option<String>> {
    match fs::read_to_string(path) {
        Ok(text) => Ok(Some(text)),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) if error.kind() == std::io::ErrorKind::PermissionDenied => Err(
            RouterError::coded("E_PERMISSION", format!("cannot read {}", path.display())),
        ),
        Err(error) => Err(error.into()),
    }
}

fn atomic_write(path: &Path, contents: &[u8]) -> Result<()> {
    let parent = path
        .parent()
        .ok_or_else(|| RouterError::coded("E_PATH_INVALID", "write target has no parent"))?;
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
            format!("failed to atomically replace {}", target.display()),
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
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    fn source_root() -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("plugins/z-codex-router")
    }

    fn historical_v1_source_fixture() -> TempDir {
        let temp = tempfile::tempdir().expect("historical source fixture");
        let root = temp.path().join("plugins/z-codex-router");
        copy_path(&source_root(), &root).unwrap();
        for relative in [".codex-plugin/plugin.json", "release/manifest.json"] {
            let path = root.join(relative);
            let mut manifest: serde_json::Value =
                serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
            manifest["version"] = serde_json::Value::String("1.0.0".into());
            fs::write(path, serde_json::to_vec_pretty(&manifest).unwrap()).unwrap();
        }
        temp
    }

    fn fixture() -> TempDir {
        tempfile::tempdir().expect("fixture")
    }

    #[test]
    fn managed_block_resolves_codex_home_before_router_state() {
        let state = State {
            version: "1.0.2".into(),
            payload_sha256: "0".repeat(64),
            installed_at_unix_ns: 0,
            agents_existed_before: false,
            managed_separator: String::new(),
        };
        let block = managed_block(&state);
        assert!(block.contains("explicit `CODEX_HOME` when set"));
        assert!(block.contains("otherwise use `~/.codex`"));
        assert!(block.contains("Never resolve this path relative to a repository or worktree"));
        assert!(block.contains("<codex_home>/z-codex-router/current.json"));
        assert!(!block.contains("first read `z-codex-router/current.json`"));
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
            "stable profile `stable/current-gpt-5.6-reference.toml` 是本插件的唯一活动 tier 映射",
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
        let source_fixture = source.then(historical_v1_source_fixture);
        execute(Options {
            source: source_fixture
                .as_ref()
                .map(|fixture| fixture.path().join("plugins/z-codex-router")),
            codex_home: Some(home.to_path_buf()),
            command,
        })
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
            fs::read_to_string(&agents)
                .unwrap()
                .replace("managed", "altered"),
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
        let manifest_path = newer.join("release/manifest.json");
        let mut manifest: serde_json::Value =
            serde_json::from_slice(&fs::read(&manifest_path).unwrap()).unwrap();
        manifest["version"] = serde_json::Value::String("1.0.1".into());
        fs::write(
            &manifest_path,
            serde_json::to_vec_pretty(&manifest).unwrap(),
        )
        .unwrap();
        let upgraded = execute(Options {
            source: Some(newer),
            codex_home: Some(home.clone()),
            command: Command::Upgrade { dry_run: false },
        })
        .unwrap();
        assert_eq!(upgraded.version.as_deref(), Some("1.0.1"));
        let checked = run(&home, Command::Doctor, false).unwrap();
        assert_eq!(checked.code, "OK_ENABLED");
        assert_eq!(checked.version.as_deref(), Some("1.0.1"));
        let agents = fs::read_to_string(home.join("AGENTS.md")).unwrap();
        assert_eq!(agents.matches(managed_begin()).count(), 1);
        assert!(agents.contains("version=1.0.1"));
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
        assert_eq!(refreshed.version.as_deref(), Some("1.0.2"));
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
        let manifest_path = newer.join("release/manifest.json");
        let mut manifest: serde_json::Value =
            serde_json::from_slice(&fs::read(&manifest_path).unwrap()).unwrap();
        manifest["version"] = serde_json::Value::String("1.0.1".into());
        fs::write(
            &manifest_path,
            serde_json::to_vec_pretty(&manifest).unwrap(),
        )
        .unwrap();
        let source = load_source(Some(newer)).unwrap();
        let next = State {
            version: "1.0.1".into(),
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
        assert!(!versions_path(&home).join("1.0.1").exists());
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
