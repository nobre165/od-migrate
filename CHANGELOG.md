# Changelog

All notable changes to this project are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.0.0] - 2026-11-05

### Added
- `plan`: size-bounded batches, NUL-separated relative paths, `.bytes`
  sidecars, `plan.conf`, `plan-summary.txt`, `invalid-names.tsv`.
- `mkdirs`: replicate directory tree only.
- `copy`: per-batch rsync with free-space check and per-batch log; idempotent.
- `verify`: dry-run listing of files still pending for a batch.
- `free` / `status`: OneDrive Files On-Demand helpers via PowerShell (WSL only).
- bats test suite, shellcheck, GitHub Actions CI.
