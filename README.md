# od-migrate

Batch migration of large directory trees (hundreds of GB) from a local or USB
disk into a OneDrive folder. Two implementations of the same workflow:

- `od-migrate.sh` - Bash + `rsync`, runs under WSL.
- `od-migrate.ps1` - Windows PowerShell + `robocopy`, runs natively on Windows
  (from PowerShell, or from cmd via `od-migrate.cmd`). Prefer it when the WSL
  version hits I/O errors on `/mnt/<drive>`: it does not go through drvfs.

## The problem it solves

A plain `rsync` from `C:\Data` into `C:\Users\you\OneDrive - Company\Data` is a
**disk-to-disk copy on the same drive**. The OneDrive client uploads files
afterwards, and even once uploaded a file keeps occupying local disk until you
"Free up space". With hundreds of GB the disk fills before the client catches
up and `rsync` dies with `No space left on device`.

`od-migrate` splits the job into size-bounded batches and gives you the tools
for the only cycle that actually works:

```
copy batch N  ->  wait for OneDrive to sync  ->  free local space  ->  copy batch N+1
```

## Subcommands

| Command | What it does |
|---|---|
| `plan <source-dir> <batch-size> [plan-dir]` | Scans the source, writes `batch-NNNN.txt` lists (NUL-separated, relative paths), a `.bytes` sidecar per batch, `plan-summary.txt`, `plan.conf` (records the source) and `invalid-names.tsv` (files OneDrive would reject). |
| `mkdirs <source-dir> <dest-dir>` | Replicates the directory tree only, no files. |
| `copy <batch-file> <dest-dir> [--source DIR]` | Copies one batch with `rsync`. Refuses to start if the destination has less free space than the batch needs (+5%). Idempotent: re-running skips files already present with the same size/mtime. Source comes from `plan.conf` next to the batch unless `--source` is given. |
| `verify <batch-file> <dest-dir> [--source DIR]` | `rsync --dry-run`: lists files of the batch that would still be (re)copied. Reads metadata only, so it does not re-hydrate files already freed. |
| `free <dest-dir>` | Marks everything under the directory as "Free up space" (`attrib +U -P /S /D` via PowerShell). OneDrive only dehydrates files already uploaded, so it is safe to run at any time. **Windows/WSL only.** |
| `status <dest-dir>` | Counts files still occupying local disk (those without the `RECALL_ON_DATA_ACCESS` attribute). **Windows/WSL only.** |

Batch size accepts IEC suffixes: `50G`, `500M`, `1T`, or plain bytes.

## Quick start

```bash
# USB disk not visible under /mnt? Mount it (replace E: with the drive letter)
sudo mkdir -p /mnt/e && sudo mount -t drvfs E: /mnt/e

SRC="/mnt/c/Users/REPLACE_USER/REPLACE_SOURCE_DIR"
DST="/mnt/c/Users/REPLACE_USER/OneDrive - REPLACE_COMPANY/REPLACE_TARGET_DIR"

./od-migrate.sh plan "$SRC" 50G ./plan-data      # pick a size below your free space on C:
./od-migrate.sh mkdirs "$SRC" "$DST"

./od-migrate.sh copy   plan-data/batch-0001.txt "$DST"
#   ... let the OneDrive client upload ...
./od-migrate.sh status "$DST"                     # repeat until "still on local disk" is 0
./od-migrate.sh free   "$DST"
./od-migrate.sh verify plan-data/batch-0001.txt "$DST"   # optional
./od-migrate.sh copy   plan-data/batch-0002.txt "$DST"
# ... and so on
```

Use a separate plan directory per source (one for `C:`, one for the USB disk);
`copy` reads the right source from each plan's `plan.conf`.

## Windows-native version (PowerShell + robocopy)

Same subcommands and cycle, no WSL needed. Runs on the Windows PowerShell 5.1
that ships with Windows 11; nothing to install.

```powershell
$Src = 'E:\REPLACE_SOURCE_DIR'
$Dst = 'C:\Users\REPLACE_USER\OneDrive - REPLACE_COMPANY\REPLACE_TARGET_DIR'

.\od-migrate.ps1 plan   $Src 50G .\plan-data
.\od-migrate.ps1 mkdirs $Src $Dst
.\od-migrate.ps1 copy   .\plan-data\batch-0001.txt $Dst
.\od-migrate.ps1 status $Dst
.\od-migrate.ps1 free   $Dst
.\od-migrate.ps1 verify .\plan-data\batch-0001.txt $Dst
```

From cmd.exe use the wrapper, which also bypasses the execution policy for
that one process:

```bat
od-migrate.cmd copy plan-data\batch-0001.txt "C:\Users\REPLACE_USER\OneDrive - REPLACE_COMPANY\REPLACE_TARGET_DIR"
```

If PowerShell refuses to run the script directly ("running scripts is
disabled" or "not digitally signed"), use `od-migrate.cmd`, or run
`Unblock-File .\od-migrate.ps1` once for a downloaded copy. If you
downloaded the repository as a ZIP, unblock everything after extracting:
`Get-ChildItem -Recurse | Unblock-File`. To run `.ps1` files directly from
now on, `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` is enough; it
does not need administrator rights.

### Do not run as administrator

Run `od-migrate` from a normal PowerShell or cmd window, as the same user
that is signed in to OneDrive. Administrator rights are not needed and are
best avoided:

- robocopy only needs them to copy permissions/owner (`/COPY:S/O/U`) or for
  backup mode (`/B`, `/ZB`). This tool uses `/COPY:DT` (data and
  timestamps) only.
- `free` and `status` work on files inside your own OneDrive folder.
- The OneDrive client runs as your user. Files created from an elevated
  window can end up owned by the Administrators group, which can cause sync
  or permission problems later.
- Mapped network drives (`Z:`) are not visible from an elevated window, so
  a source on a mapped drive "does not exist" there.

The exception is a source with folders your user cannot read, for example
another user's profile on an old disk: `plan` warns `cannot read directory`
and the `copy` log shows `ERROR 5 (0x00000005) ... Access is denied`.
Running the whole tool elevated is not a good fix, because of the ownership
problem above. Instead, take ownership of just those source folders once,
from an administrator window, then run `od-migrate` normally:

```powershell
takeown /f "E:\REPLACE_LOCKED_DIR" /r /d y
icacls "E:\REPLACE_LOCKED_DIR" /grant "${env:USERNAME}:(OI)(CI)R" /t
```

Differences from the Bash version:

| | `od-migrate.sh` | `od-migrate.ps1` |
|---|---|---|
| Batch files | NUL-separated, `/` separators | UTF-8, one path per line, `\` separators |
| Plan config | `plan.conf` | `plan.json` |
| Source override | `--source DIR` | `-Source DIR` |
| Copy engine | one `rsync --files-from` per batch | one `robocopy` per directory of the batch, file names as filters |
| Retries on I/O errors | none (rsync fails the file) | `-Retries N` (default 5), `-WaitSeconds N` (default 10) |
| Extra options | - | `-Threads N` (`/MT:N`), `-Restartable` (`/Z`, resumes large files after an error) |
| Reparse points | symlinks skipped | junctions/symlinks skipped and listed in `invalid-names.tsv` as `reparse-point` |

Plans are **not** interchangeable: a plan made by one script must be copied
with the same script. Name rules, batch packing, the `.bytes` sidecars and
the 5% free-space check are the same.

`copy` keeps going when a directory fails, then exits 1 and lists the failed
directories; details are in `batch-NNNN.log` (UTF-16, search for `ERROR`).
Re-running the same `copy` only transfers what is missing. A persistent
`ERROR 1117` / `ERROR 23` on the *source* points to a failing disk or cable
(`chkdsk E: /f`, another USB port), not to this tool.

## Supported environments

| Environment | plan / mkdirs / copy / verify | free / status |
|---|---|---|
| WSL2 (Ubuntu) on Windows 11, source and destination under `/mnt/<drive>` | yes — the target use case | yes |
| Native Linux (development, CI) | yes | no — `powershell.exe` is absent; the commands fail with a clear error |
| Windows 10/11, `od-migrate.ps1` (PowerShell 5.1 or 7) | yes | yes |

`rsync` is run with `--inplace --no-perms --no-owner --no-group -W` because the
destination is NTFS mounted through drvfs. These flags are harmless on native
Linux, but **tests on native Linux do not prove they behave correctly on
`/mnt/c`** — that validation happens by running a real batch under WSL.

### OneDrive name rules

`plan` excludes files OneDrive for Business would reject and lists them in
`invalid-names.tsv` with a reason: forbidden characters (`< > : " | ? *`),
control characters, leading spaces, trailing spaces or dots, `~$` prefix,
reserved names (`CON`, `PRN`, `AUX`, `NUL`, `COM1-9`, `LPT1-9`), `_vti_`,
`.lock`, `desktop.ini`, paths longer than 350 characters, files over 250 GB.
Rename them and run `plan` again, or they will never be copied.

## Known limitations

- `--inplace` leaves a partial file in the destination if `rsync` is
  interrupted, and OneDrive may upload that partial file before the copy
  finishes. After an interruption, run `verify` and `copy` again for the
  same batch; only files whose size/mtime differ are retransferred.
- Batch sizes use the logical file size reported by `find`. NTFS-compressed or
  sparse files occupy less on disk than planned (in your favour).
- `free`/`status` rely on the OneDrive Files On-Demand attributes
  (`attrib +U -P`, `FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS`). Validate against
  what Explorer shows on your first batch.
- Symlinks are skipped (`--no-links`).
- `od-migrate.ps1`: robocopy file filters also match 8.3 short names, so a
  file literally named like another file's short name (`REPORT~1.DOC`) can
  pull that other file into the batch too. Harmless (one extra file), rare.
- `od-migrate.ps1`: `free` uses `attrib`, which may skip paths longer than
  260 characters unless Windows long paths are enabled.

## Requirements

- bash 4+, GNU coreutils (`find`, `sort`, `numfmt`, `readlink`, `df`), `rsync`
- Under WSL: `wslpath` and `powershell.exe` on `PATH` (default on WSL2)
- `od-migrate.ps1`: Windows PowerShell 5.1 (built in) or PowerShell 7;
  `robocopy.exe` and `attrib.exe` (built in)

```bash
sudo apt install -y rsync coreutils
```

## Development

```bash
sudo apt install -y bats shellcheck
shellcheck od-migrate.sh
bats tests/
```

PowerShell version (Pester 5+ and PSScriptAnalyzer). On Windows everything
runs; with `pwsh` on Linux the robocopy tests are skipped, but the helper
tests (name rules checked against `od-migrate.sh`, sizes, batch layout) and
the command-line tests still run:

```powershell
Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser -SkipPublisherCheck
Install-Module PSScriptAnalyzer -Scope CurrentUser
Invoke-ScriptAnalyzer -Path od-migrate.ps1
Invoke-Pester tests
```

CI (`.github/workflows/ci.yml`) runs all of the above on every push and pull
request: the Bash suite and the portable Pester tests (PowerShell 7) on
Ubuntu, the full Pester suite on Windows PowerShell 5.1 (`windows-latest`).
The test suite covers `plan`, `mkdirs`, `copy`, `verify` and the clean failure
of `free`/`status` without PowerShell; the Windows-only behaviour is tested
manually (see `CLAUDE.md`).

### Maintaining the project with Claude

The repository carries a `CLAUDE.md` with the design decisions, conventions and
test expectations, so Claude Code (or a claude.ai session with the repo
attached) has the context it needs to make changes safely.

#### 1. GitHub CLI (`gh`)

Check first; install only if missing:

```bash
if command -v gh >/dev/null 2>&1; then
    echo "gh already installed: $(gh --version | head -1)"
else
    sudo apt install -y gh \
    || { # fallback: official GitHub apt repository
         sudo mkdir -p -m 755 /etc/apt/keyrings
         curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
           | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
         echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
           | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
         sudo apt update && sudo apt install -y gh; }
fi
gh auth status || gh auth login
```

#### 2. Claude Code

Check first; install only if missing. The native installer is the documented
method (do **not** run it with `sudo`); the npm package still works but needs
Node.js 18+.

```bash
if command -v claude >/dev/null 2>&1; then
    echo "Claude Code already installed: $(claude --version)"
else
    curl -fsSL https://claude.ai/install.sh | bash
    # the binary lands in ~/.local/bin — add it to PATH if 'claude' is not found
    grep -q '.local/bin' ~/.bashrc || echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
    export PATH="$HOME/.local/bin:$PATH"
fi
claude doctor
```

Official docs: <https://docs.claude.com/en/docs/claude-code/overview>

#### 3. Create the repository and push

```bash
cd od-migrate
git init -b main
git add .
git commit -m "Initial import of od-migrate v1.0.0"
gh repo create od-migrate --public --source=. --remote=origin --push
```

#### 4. Day-to-day

```bash
cd od-migrate
claude          # interactive session; CLAUDE.md is loaded automatically
```

Typical asks: "add a `--dry-run` flag to copy", "the status command reports X
on Windows, here is the output, fix it", "bump to 1.1.0 and update the
changelog". Claude Code runs `shellcheck` and `bats` as part of the change;
anything touching `free`/`status` still needs a manual check under WSL.

## License

MIT — see [LICENSE](LICENSE).
