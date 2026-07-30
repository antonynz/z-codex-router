use clap::{Parser, Subcommand};
use std::path::PathBuf;
use z_codex_router::{execute, Command, Options};

const HELP_TEMPLATE: &str =
    "{about-with-newline}\n用法：{usage}\n\n命令：\n{subcommands}\n选项：\n{options}";

#[derive(Parser)]
#[command(
    name = "routerctl",
    about = "Z Codex Router 内部控制面（路由与显式 Safe Auto 审批 opt-in）",
    help_template = HELP_TEMPLATE,
    disable_help_subcommand = true,
    disable_help_flag = true,
    subcommand_value_name = "命令"
)]
struct Cli {
    /// Plugin Release 根目录；Codex skill 会自动提供。
    #[arg(long)]
    source: Option<PathBuf>,
    /// 要管理的 Codex home；测试或集成时优先使用 CODEX_HOME。
    #[arg(long)]
    codex_home: Option<PathBuf>,
    /// 显示帮助。
    #[arg(
        short = 'h',
        long = "help",
        action = clap::ArgAction::Help,
        global = true,
        required = false
    )]
    _help: Option<bool>,
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
    /// 查看或管理持久用户 tier-to-model override。
    Profile {
        #[command(subcommand)]
        command: ProfileCommand,
    },
    /// 显式选择启用 Safe Auto 审批 reviewer policy。
    SafeAuto {
        #[command(subcommand)]
        command: SafeAutoCommand,
    },
}

#[derive(Subcommand)]
enum ProfileCommand {
    /// 显示有效路由 mapping 及其来源。
    Show,
    /// 根据随附的活动默认值创建可编辑 user override。
    Init,
    /// 验证有效路由 mapping，不做修改。
    Validate,
    /// 备份并移除 user override，使随附默认值重新生效。
    Reset,
    /// 从受管 backup 目录恢复 reset backup。
    Restore { backup: PathBuf },
    /// 在已验证的持久 user override 中设置一个 tier。
    Set {
        tier: String,
        model: String,
        effort: String,
    },
}

#[derive(Subcommand)]
enum SafeAutoCommand {
    /// 应用三键 Safe Auto 审批 policy。
    Enable,
    /// 只恢复三个键启用前的值（restore 的别名）。
    Disable,
    /// 只恢复三个键启用前的值。
    Restore,
    /// 报告 active、drift 或 absent 状态，不修改文件。
    Status,
    /// 验证 active 状态，发现 drift 时 fail closed。
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
