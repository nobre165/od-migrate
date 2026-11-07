# Changelog

All notable changes to this project are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- `od-migrate.ps1`: native Windows version (PowerShell 5.1+, robocopy) with
  the same subcommands, name rules and free-space check. Bounded robocopy
  retries (`-Retries`, `-WaitSeconds`), optional `-Threads` and
  `-Restartable`. Does not go through drvfs, where the WSL version can hit
  I/O errors.
- `od-migrate.cmd`: wrapper to run `od-migrate.ps1` from cmd.exe.
- Pester test suite and a Windows CI job (PSScriptAnalyzer + Pester on
  Windows PowerShell 5.1).

### Changed
- `usage`: help text is now an explicit heredoc (no longer parsed from the
  script header), shows the version and option notes; `--help` prints to
  stdout with exit 0, misuse prints to stderr with exit 1.
- Argument parsing uses `getopt` (util-linux). Global options are parsed
  before the subcommand; `copy`/`verify` accept `--source` anywhere among
  their arguments. A missing `--source` value or an unknown option now gives
  a clear error plus usage instead of a shell "unbound variable" crash.

## [1.0.0] - 2026-11-05

### Added
- `plan`: size-bounded batches, NUL-separated relative paths, `.bytes`
  sidecars, `plan.conf`, `plan-summary.txt`, `invalid-names.tsv`.
- `mkdirs`: replicate directory tree only.
- `copy`: per-batch rsync with free-space check and per-batch log; idempotent.
- `verify`: dry-run listing of files still pending for a batch.
- `free` / `status`: OneDrive Files On-Demand helpers via PowerShell (WSL only).
- bats test suite, shellcheck, GitHub Actions CI.
