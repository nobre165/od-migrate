# od-migrate

Batch migration of large directory trees (hundreds of GB) from a local or USB
disk into a OneDrive folder, from WSL, using `rsync`.

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

## Supported environments

| Environment | plan / mkdirs / copy / verify | free / status |
|---|---|---|
| WSL2 (Ubuntu) on Windows 11, source and destination under `/mnt/<drive>` | yes — the target use case | yes |
| Native Linux (development, CI) | yes | no — `powershell.exe` is absent; the commands fail with a clear error |

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

## Requirements

- bash 4+, GNU coreutils (`find`, `sort`, `numfmt`, `readlink`, `df`), `rsync`
- Under WSL: `wslpath` and `powershell.exe` on `PATH` (default on WSL2)

```bash
sudo apt install -y rsync coreutils
```

## Development

```bash
sudo apt install -y bats shellcheck
shellcheck od-migrate.sh
bats tests/
```

CI (`.github/workflows/ci.yml`) runs both on every push and pull request.
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
