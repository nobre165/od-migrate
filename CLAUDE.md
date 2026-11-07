# CLAUDE.md — context for Claude when working on this repository

## What this is

Two implementations of one tool that migrates large directory trees into a
OneDrive folder in size-bounded batches:

- `od-migrate.sh` - Bash + rsync, run from WSL.
- `od-migrate.ps1` - Windows PowerShell + robocopy, run natively on Windows
  (`od-migrate.cmd` is a thin wrapper for cmd.exe). Added because rsync over
  drvfs was producing I/O errors for the maintainer.
 Read `README.md` first for
the user-facing behaviour. This file is about *why* things are the way they are
and how to change them safely.

## Target environment vs. development environment

- **Target:** WSL2 (Ubuntu) on Windows 11. Source and destination are NTFS
  volumes mounted through drvfs (`/mnt/c`, `/mnt/e`, ...). `free` and `status`
  call `powershell.exe` and `attrib`.
- **Development/CI:** native Ubuntu. Everything except `free`/`status` is
  testable there. Any change to `free`/`status`, or to the rsync flags, must be
  verified manually under WSL against a real OneDrive folder before release;
  say so explicitly in the PR/commit message when you could not do it.

## Design decisions — do not undo without a reason

- **Batches are NUL-separated lists of paths relative to the source**
  (`find -printf '%P\0'`, `rsync --from0 --files-from`). Paths with spaces,
  quotes and odd characters are common on Windows; newline-separated lists
  break on them.
- **The source dir is recorded in `plan.conf`** (shell-sourceable, `%q`-quoted)
  so `copy`/`verify` take only batch + destination. `--source` overrides it.
- **`copy` checks free space before starting** using the `.bytes` sidecar
  written by `plan`, with 5% headroom. This check is the whole point of the
  tool: it turns "rsync died at file 40,000" into "run `free` first".
- **rsync flags** (`RSYNC_BASE`): `-r -t -W --inplace --no-perms --no-owner
  --no-group --no-links`.
  - `-t` is required for idempotent re-runs (size+mtime comparison).
  - `-W` because both sides are local; delta transfer only burns CPU.
  - `--inplace` avoids rsync temp files, which double peak disk usage and
    confuse the OneDrive client (rename-into-place).
  - `--no-perms/--no-owner/--no-group` because drvfs/NTFS cannot store them
    and rsync would emit errors on every file.
- **Invalid OneDrive names are excluded at `plan` time** and reported in
  `invalid-names.tsv`, rather than letting rsync copy them and OneDrive refuse
  to sync them later. The rule list lives in `check_name()`; keep it in sync
  with the README section "OneDrive name rules".
- **Oversize files** (larger than the batch size) get a batch of their own
  with a warning instead of aborting the plan.
- **Each implementation is a single file**, no libraries, no Python.
  `od-migrate.sh` must run on a stock WSL Ubuntu with only `rsync` installed;
  `od-migrate.ps1` on stock Windows PowerShell 5.1 with no modules (only
  built-in `robocopy.exe` / `attrib.exe`). No PowerShell 7-only syntax
  (`??`, ternary, `ForEach-Object -Parallel`).
- **Keep the two in parity**: same subcommands, same `check_name()` /
  `Get-NameProblem` rules (plus the `AnyNameProblem` pre-filter regex in the
  .ps1, which must match the same set), same batch packing, `.bytes` sidecar
  and 5% headroom. A behavioural change to one needs the same change (and
  test) in the other, or an explicit note in README "Differences".
- **Plans are not interchangeable.** The .ps1 writes UTF-8, one path per
  line, `\` separators, `plan.json`; it rejects NUL-separated batches from
  the .sh with a clear message.
- **robocopy has no `--files-from`**: `copy`/`verify` group the batch by
  directory and run one robocopy per directory with the file names as
  filters, chunked under the 32767-char command-line limit. Directory
  arguments never end in `\` (PowerShell 5.1 quoting would turn `"C:\"`
  into an escaped quote); `Format-RoboDir` turns `C:\` into `C:\.`.
- **robocopy flags** (`Get-RoboOption`): `/COPY:DT /DCOPY:T` (data +
  timestamps, mirrors `--no-perms --no-owner --no-group` and `-t`),
  bounded `/R` `/W` (robocopy's default of 1,000,000 retries looks like a
  hang), `/XJ` (mirrors `--no-links`). Exit codes 0-7 are success, 8+ is
  failure; a failed directory does not stop the batch, but `copy` exits 1.
- **.ps1 must stay ASCII-only**: PowerShell 5.1 reads BOM-less scripts in
  the ANSI code page, so an em dash in a string becomes mojibake.
- **Messages and comments are in English.** The maintainer's working language
  in chat is pt-BR; keep the code and docs in English.

## Conventions

- `set -euo pipefail`; every external command goes through `need` before use.
- Errors via `die`, warnings via `warn`, progress via `info`; all on stderr.
- `shellcheck od-migrate.sh` must be clean (no suppressions added without a
  comment explaining why).
- `bats tests/` must pass. Add or update a test for every behavioural change.
- PowerShell: `Invoke-ScriptAnalyzer od-migrate.ps1` clean at Warning level
  (the one suppression, `PSReviewUnusedParameter`, is a documented false
  positive), and `Invoke-Pester tests` must pass. With `pwsh` on Linux the
  helper and command-line tests run and the robocopy tests are skipped;
  for anything touching copy/verify/mkdirs/plan I/O, rely on the `windows`
  CI job and say so.
- The .ps1 returns early when dot-sourced (`. .\od-migrate.ps1`) so tests
  can call its pure functions; keep main-section code below that guard.
  Unit tests load it inside `New-Module` so its StrictMode/trap do not leak
  into Pester, and must never reach `Exit-WithError` (it calls `exit`).
- Name-rule parity is tested: the `Get-NameProblem` cases in
  `tests/od-migrate.Tests.ps1` are the outputs of bash `check_name()` for the
  same names. When a rule changes, change both scripts and regenerate or
  extend that table from the bash output. Whitespace rules are ASCII-only
  on purpose (`.NET \s` would also flag U+00A0, which bash and OneDrive
  accept).
  Tests build their own fixture in `mktemp -d`; do not depend on files in the
  repo.
- Versioning: semantic, via git tags (`v1.0.0`). `VERSION` in the script and
  `CHANGELOG.md` (Keep a Changelog format) are updated in the same commit.
  Do **not** version by renaming the file (`od-migrate-v2.sh`).
- Never put real OneDrive paths, usernames or company names in docs or tests;
  use `REPLACE_*` placeholders.

## Things known to be unverified

- `status` relies on `FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS` (0x400000) to
  detect dehydrated files. Confirmed by the Cloud Files API docs, not yet
  confirmed by the maintainer on a real OneDrive folder.
- `free` uses `attrib +U -P /S /D`. Same status.
- `od-migrate.ps1` as a whole: written on a Linux box without PowerShell;
  helpers and CLI tested with pwsh 7.6 on Linux; first validation of the
  robocopy paths is the `windows` CI job (Pester on PowerShell 5.1), then
  a real batch into a OneDrive folder. Specifically unverified: the `\\?\`
  long-path probe in `Get-LongPath`, `/MT` and `/Z` behaviour against a
  OneDrive folder, and `verify` output parsing on non-English Windows
  (robocopy's `New File`/`Newer` labels are localised; the parser only
  relies on non-empty lines, not the labels).

If the maintainer reports Windows output for either, treat it as ground truth
over this file and update this section.

## How to work on a change

1. Read the relevant subcommand function and `RSYNC_BASE`.
2. Write or adjust the bats test first when the change is behavioural.
3. Implement; run `shellcheck od-migrate.sh && bats tests/`.
4. Update `README.md` if user-facing, `CHANGELOG.md` under `[Unreleased]`.
5. State clearly in the summary what was and was not tested on WSL.
