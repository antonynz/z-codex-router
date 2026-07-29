use directories::BaseDirs;
use semver::Version;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::BTreeSet;
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
    Rollback,
    Uninstall,
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
}

#[derive(Debug, Serialize, Deserialize)]
struct Backup {
    agents: Option<String>,
    current: Option<String>,
}

#[derive(Debug, Serialize, Deserialize)]
struct Journal {
    protocol: u8,
    operation: String,
    backup: String,
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
        Command::Rollback => rollback(&home),
        Command::Uninstall => uninstall(&home),
        Command::DryRun => install(&home, load_source(options.source)?, true, false),
        Command::Install => install(&home, load_source(options.source)?, false, false),
        Command::Upgrade { dry_run } => install(&home, load_source(options.source)?, dry_run, true),
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
    for key in [
        "require_explicit_runtime_metadata",
        "require_exact_route_match",
        "require_platform_capability",
    ] {
        if preflight.get(key).and_then(Item::as_bool) != Some(true) {
            return Err(RouterError::coded(
                "E_PROFILE_INCOMPATIBLE",
                "portable profile has a disabled preflight",
            ));
        }
    }
    for key in [
        "on_unknown",
        "on_missing_profile",
        "on_incompatible_profile",
        "on_disabled_candidate",
    ] {
        if preflight.get(key).and_then(Item::as_str) != Some("fail-closed") {
            return Err(RouterError::coded(
                "E_PROFILE_INCOMPATIBLE",
                "portable profile does not fail closed",
            ));
        }
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
    let next_state = State {
        version: source.manifest.version.clone(),
        payload_sha256: source.manifest.payload_sha256.clone(),
        installed_at_unix_ns: now_ns(),
    };

    if let Some(current) = existing_state.as_ref() {
        ensure_managed_matches(agents_before.as_deref(), current)?;
        let current_version = Version::parse(&current.version).map_err(|_| {
            RouterError::coded("E_STATE_INVALID", "installed version is not semantic")
        })?;
        let next_version = Version::parse(&next_state.version).map_err(|_| {
            RouterError::coded("E_SOURCE_INVALID", "source version is not semantic")
        })?;
        if current.version == next_state.version
            && current.payload_sha256 == next_state.payload_sha256
        {
            return Ok(outcome(
                "install",
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
        } else if next_version <= current_version {
            return Err(RouterError::coded(
                "E_VERSION_NOT_NEWER",
                "source stable release is not newer than installed version",
            ));
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
    let backup_path = create_backup(home, agents_before, read_optional(&current_path(home))?)?;
    write_journal(
        home,
        if allow_upgrade { "upgrade" } else { "install" },
        &backup_path,
    )?;
    let result = (|| {
        create_immutable_version(home, &source, &next_state)?;
        atomic_write(&agents_path(home), agents_after.as_bytes())?;
        atomic_write(
            &current_path(home),
            serde_json::to_vec_pretty(&next_state)?.as_slice(),
        )?;
        Ok(())
    })();
    if let Err(error) = result {
        let _ = restore_backup(home, &backup_path);
        let _ = fs::remove_file(journal_path(home));
        return Err(error);
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
    let state = read_state(home)?
        .ok_or_else(|| RouterError::coded("E_NOT_INSTALLED", "router state is absent"))?;
    let version_root = versions_path(home).join(&state.version);
    validate_payload(&version_root)?;
    if payload_hash(&version_root)? != state.payload_sha256 {
        return Err(RouterError::coded(
            "E_PAYLOAD_DRIFT",
            "installed version payload hash differs from state",
        ));
    }
    ensure_managed_matches(read_optional(&agents_path(home))?.as_deref(), &state)?;
    Ok(outcome("doctor", "OK", Some(state.version), false, None, vec!["managed block, payload hash, profile policy, and runtime platform are valid; config.toml is unmanaged".into()]))
}

fn rollback(home: &Path) -> Result<Outcome> {
    let backup_path = match read_optional(&journal_path(home))? {
        Some(text) => {
            let journal: Journal = serde_json::from_str(&text).map_err(|_| {
                RouterError::coded("E_TRANSACTION_PENDING", "transaction journal is invalid")
            })?;
            if journal.protocol != PROTOCOL {
                return Err(RouterError::coded(
                    "E_TRANSACTION_PENDING",
                    "transaction journal protocol is unsupported",
                ));
            }
            validated_backup_path(home, Path::new(&journal.backup))?
        }
        None => {
            let state = read_state(home)?
                .ok_or_else(|| RouterError::coded("E_NOT_INSTALLED", "router state is absent"))?;
            ensure_managed_matches(read_optional(&agents_path(home))?.as_deref(), &state)?;
            let backup = latest_backup(home)?;
            validated_backup_path(home, &backup)?
        }
    };
    restore_backup(home, &backup_path)?;
    let restored = read_state(home)?.map(|item| item.version);
    let _ = fs::remove_file(journal_path(home));
    Ok(outcome(
        "rollback",
        "OK",
        restored,
        true,
        Some(backup_path.display().to_string()),
        vec!["restored pre-transaction AGENTS.md and current pointer".into()],
    ))
}

fn uninstall(home: &Path) -> Result<Outcome> {
    ensure_no_pending_transaction(home)?;
    let state = read_state(home)?
        .ok_or_else(|| RouterError::coded("E_NOT_INSTALLED", "router state is absent"))?;
    let agents = read_optional(&agents_path(home))?;
    ensure_managed_matches(agents.as_deref(), &state)?;
    let agents_after = remove_managed(agents.as_deref().unwrap_or_default(), &state)?;
    let backup_path = create_backup(home, agents, read_optional(&current_path(home))?)?;
    write_journal(home, "uninstall", &backup_path)?;
    let result = (|| {
        atomic_write(&agents_path(home), agents_after.as_bytes())?;
        fs::remove_file(current_path(home))?;
        Ok(())
    })();
    if let Err(error) = result {
        let _ = restore_backup(home, &backup_path);
        let _ = fs::remove_file(journal_path(home));
        return Err(error);
    }
    let _ = fs::remove_file(journal_path(home));
    Ok(outcome("uninstall", "OK", Some(state.version), true, Some(backup_path.display().to_string()), vec!["removed only the matching managed block and current pointer; immutable versions remain for audit".into()]))
}

fn append_managed(existing: Option<&str>, state: &State) -> String {
    let block = managed_block(state);
    match existing {
        None | Some("") => block,
        Some(text) => format!("{}\n\n{block}", text.trim_end()),
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
    result.push_str(existing[..index].trim_end());
    result.push_str(existing[index + block.len()..].trim_start_matches('\n'));
    if !result.is_empty() {
        result.push('\n');
    }
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
    format!(
        "<!-- z-codex-router:begin id={ROUTER_ID} version={} sha256={} protocol={PROTOCOL} -->\n# Z Codex Router (managed)\nFor each independent task, first read `z-codex-router/current.json`; then read `z-codex-router/versions/<current.version>/core/router.md`, resolve `z-codex-router/versions/<current.version>/profiles/portable/default.toml`, and read one relevant mode. Preserve user authority and fail closed if the profile or runtime cannot be verified.\n<!-- z-codex-router:end id={ROUTER_ID} -->",
        state.version, state.payload_sha256
    )
}

fn create_immutable_version(home: &Path, source: &SourceRelease, state: &State) -> Result<()> {
    let versions = versions_path(home);
    fs::create_dir_all(&versions)?;
    let destination = versions.join(&state.version);
    if destination.exists() {
        let actual = payload_hash(&destination)?;
        if actual == state.payload_sha256 {
            return Ok(());
        }
        return Err(RouterError::coded(
            "E_IMMUTABLE_VERSION_CONFLICT",
            "existing version directory has a different payload",
        ));
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

fn create_backup(home: &Path, agents: Option<String>, current: Option<String>) -> Result<PathBuf> {
    let backups = router_path(home).join("backups");
    fs::create_dir_all(&backups)?;
    let path = backups.join(format!("backup-{}.json", now_ns()));
    atomic_write(
        &path,
        serde_json::to_vec_pretty(&Backup { agents, current })?.as_slice(),
    )?;
    Ok(path)
}

fn write_journal(home: &Path, operation: &str, backup: &Path) -> Result<()> {
    let journal = Journal {
        protocol: PROTOCOL,
        operation: operation.into(),
        backup: backup.display().to_string(),
    };
    atomic_write(
        &journal_path(home),
        serde_json::to_vec_pretty(&journal)?.as_slice(),
    )
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

fn restore_backup(home: &Path, backup_path: &Path) -> Result<()> {
    let backup: Backup = serde_json::from_slice(&fs::read(backup_path)?)?;
    restore_optional(&agents_path(home), backup.agents.as_deref())?;
    restore_optional(&current_path(home), backup.current.as_deref())?;
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
            "a previous router transaction requires rollback review",
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

    fn fixture() -> TempDir {
        tempfile::tempdir().expect("fixture")
    }

    fn run(home: &Path, command: Command, source: bool) -> Result<Outcome> {
        execute(Options {
            source: source.then(source_root),
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
        assert!(!current_path(&home).exists());
        assert!(!fs::read_to_string(agents_path(&home))
            .unwrap()
            .contains(managed_begin()));
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
        assert_eq!(checked.version.as_deref(), Some("1.0.1"));
        let agents = fs::read_to_string(home.join("AGENTS.md")).unwrap();
        assert_eq!(agents.matches(managed_begin()).count(), 1);
        assert!(agents.contains("version=1.0.1"));
        let rolled_back = run(&home, Command::Rollback, false).unwrap();
        assert_eq!(rolled_back.version.as_deref(), Some("1.0.0"));
        assert!(fs::read_to_string(home.join("AGENTS.md"))
            .unwrap()
            .contains("version=1.0.0"));
    }

    #[test]
    fn pending_journal_restores_after_partial_write() {
        let temp = fixture();
        let home = temp.path().join("fixture-codex");
        fs::create_dir_all(&home).unwrap();
        run(&home, Command::Install, true).unwrap();
        let agents_before = fs::read_to_string(agents_path(&home)).unwrap();
        let current_before = fs::read_to_string(current_path(&home)).unwrap();
        let backup = create_backup(
            &home,
            Some(agents_before.clone()),
            Some(current_before.clone()),
        )
        .unwrap();
        write_journal(&home, "upgrade", &backup).unwrap();
        fs::write(agents_path(&home), "partial managed write").unwrap();
        fs::write(current_path(&home), "not valid json").unwrap();
        let restored = run(&home, Command::Rollback, false).unwrap();
        assert_eq!(restored.version.as_deref(), Some("1.0.0"));
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
        };
        fs::create_dir_all(router_path(&home)).unwrap();
        fs::write(journal_path(&home), serde_json::to_vec(&journal).unwrap()).unwrap();
        assert_eq!(
            run(&home, Command::Rollback, false).unwrap_err().code(),
            "E_TRANSACTION_PENDING"
        );
    }
}
