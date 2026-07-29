use clap::{Parser, Subcommand};
use std::path::PathBuf;
use z_codex_router::{execute, Command, Options};

#[derive(Parser)]
#[command(
    name = "routerctl",
    about = "Internal control plane for Z Codex Router"
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
    Rollback,
    Uninstall,
}

fn main() {
    let cli = Cli::parse();
    let command = match cli.command {
        CliCommand::DryRun => Command::DryRun,
        CliCommand::Install => Command::Install,
        CliCommand::Doctor => Command::Doctor,
        CliCommand::Upgrade { dry_run } => Command::Upgrade { dry_run },
        CliCommand::Rollback => Command::Rollback,
        CliCommand::Uninstall => Command::Uninstall,
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
