use clap::{Parser, Subcommand};
use std::path::PathBuf;
use z_codex_router::{execute, Command, Options};

#[derive(Parser)]
#[command(
    name = "routerctl",
    about = "Internal control plane for Z Codex Router (routing and explicit safe-auto approval opt-in)"
)]
struct Cli {
    /// Plugin release root. The Codex skill supplies this automatically.
    #[arg(long)]
    source: Option<PathBuf>,
    /// Codex home to manage. Prefer CODEX_HOME when testing or integrating.
    #[arg(long)]
    codex_home: Option<PathBuf>,
    #[command(subcommand)]
    command: CliCommand,
}

#[derive(Subcommand)]
enum CliCommand {
    DryRun,
    Install,
    Doctor,
    Upgrade {
        #[arg(long)]
        dry_run: bool,
    },
    Recover,
    Rollback,
    Uninstall,
    /// Inspect or manage the persistent user tier-to-model override.
    Profile {
        #[command(subcommand)]
        command: ProfileCommand,
    },
    /// Explicitly opt in to the safe automatic approval reviewer policy.
    SafeAuto {
        #[command(subcommand)]
        command: SafeAutoCommand,
    },
}

#[derive(Subcommand)]
enum ProfileCommand {
    /// Show the effective routing mapping and its source.
    Show,
    /// Create an editable user override from the shipped active default.
    Init,
    /// Validate the effective routing mapping without changing it.
    Validate,
    /// Back up and remove the user override so the shipped default is active again.
    Reset,
    /// Restore a reset backup from the managed backup directory.
    Restore { backup: PathBuf },
    /// Set one tier in a validated persistent user override.
    Set {
        tier: String,
        model: String,
        effort: String,
    },
}

#[derive(Subcommand)]
enum SafeAutoCommand {
    /// Apply the three-key safe automatic approval policy.
    Enable,
    /// Restore only the three keys' pre-enable values (alias: restore).
    Disable,
    /// Restore only the three keys' pre-enable values.
    Restore,
    /// Report active, drift, or absent state without changing files.
    Status,
    /// Verify active state and fail closed on drift.
    Doctor,
}

fn main() {
    let cli = Cli::parse();
    let command = match cli.command {
        CliCommand::DryRun => Command::DryRun,
        CliCommand::Install => Command::Install,
        CliCommand::Doctor => Command::Doctor,
        CliCommand::Upgrade { dry_run } => Command::Upgrade { dry_run },
        CliCommand::Recover => Command::Recover,
        CliCommand::Rollback => Command::Rollback,
        CliCommand::Uninstall => Command::Uninstall,
        CliCommand::Profile { command } => match command {
            ProfileCommand::Show => Command::ProfileShow,
            ProfileCommand::Init => Command::ProfileInit,
            ProfileCommand::Validate => Command::ProfileValidate,
            ProfileCommand::Reset => Command::ProfileReset,
            ProfileCommand::Restore { backup } => Command::ProfileRestore { backup },
            ProfileCommand::Set {
                tier,
                model,
                effort,
            } => Command::ProfileSet {
                tier,
                model,
                effort,
            },
        },
        CliCommand::SafeAuto { command } => match command {
            SafeAutoCommand::Enable => Command::SafeAutoEnable,
            SafeAutoCommand::Disable | SafeAutoCommand::Restore => Command::SafeAutoRestore,
            SafeAutoCommand::Status => Command::SafeAutoStatus,
            SafeAutoCommand::Doctor => Command::SafeAutoDoctor,
        },
    };
    let options = Options {
        source: cli.source,
        codex_home: cli.codex_home,
        command,
    };
    match execute(options) {
        Ok(result) => println!(
            "{}",
            serde_json::to_string_pretty(&result).unwrap_or_else(|_| "{\"ok\":true}".into())
        ),
        Err(error) => {
            eprintln!("{}: {}", error.code(), error);
            std::process::exit(error.exit_code());
        }
    }
}
