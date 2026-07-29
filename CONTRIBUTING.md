# Contributing

Please keep changes small, portable, and fail-closed. Do not add personal paths, credentials, real configuration, or a model mapping to `core/`.

Before proposing a change, run formatting, unit tests, Clippy, plugin validation, all three skill validations, and the repository secret/path scan. Installer tests must use a temporary `CODEX_HOME`; never use a developer's real Codex directory.

Changes to install semantics need fixtures for fresh install, repeated install, drift/conflict, rollback, and uninstall. Changes to profiles need an explicit compatibility and migration story. Candidate model profiles stay disabled until an evaluated release intentionally promotes them.
