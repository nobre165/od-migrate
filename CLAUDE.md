# CLAUDE.md — context for Claude when working on this repository

## What this is

A single Bash script, `od-migrate.sh`, that migrates large directory trees into
a OneDrive folder from WSL in size-bounded batches. Read `README.md` first for
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
- **Script is a single file**, no libraries, no Python. It must run on a stock
  WSL Ubuntu with only `rsync` installed. Keep it that way unless the user
  asks otherwise.
- **Messages and comments are in English.** The maintainer's working language
  in chat is pt-BR; keep the code and docs in English.

## Conventions

- `set -euo pipefail`; every external command goes through `need` before use.
- Errors via `die`, warnings via `warn`, progress via `info`; all on stderr.
- `shellcheck od-migrate.sh` must be clean (no suppressions added without a
  comment explaining why).
- `bats tests/` must pass. Add or update a test for every behavioural change.
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

If the maintainer reports Windows output for either, treat it as ground truth
over this file and update this section.

## How to work on a change

1. Read the relevant subcommand function and `RSYNC_BASE`.
2. Write or adjust the bats test first when the change is behavioural.
3. Implement; run `shellcheck od-migrate.sh && bats tests/`.
4. Update `README.md` if user-facing, `CHANGELOG.md` under `[Unreleased]`.
5. State clearly in the summary what was and was not tested on WSL.
