#!/usr/bin/env bash

# od-migrate.sh — batch migration of files from local/USB disks to a OneDrive
# folder, from WSL2, using rsync over drvfs (/mnt/c, /mnt/e, ...).
#
# Subcommands:
#   plan    <source-dir> <batch-size> [plan-dir]     build batch lists + name report
#   mkdirs  <source-dir> <dest-dir>                  replicate directory tree only
#   copy    <batch-file> <dest-dir> [--source DIR]   copy one batch with rsync
#   verify  <batch-file> <dest-dir> [--source DIR]   dry-run: what would still be copied
#   free    <dest-dir>                               dehydrate synced files (free local space)
#   status  <dest-dir>                               count files still occupying local disk
#
# Typical cycle (repeat for each batch):
#   copy -> wait for OneDrive to sync -> status (until 0 hydrated) -> free -> next copy
#
# Batch files are NUL-separated lists of paths relative to the source dir
# (rsync --from0), so spaces, quotes and odd characters are safe.
# The source dir is recorded in <plan-dir>/plan.conf so copy/verify do not
# need it again; override with --source.
#
# Version: see VERSION below and CHANGELOG.md. License: MIT.

set -euo pipefail

#############################################################################
# Environment variables                                                     #
#############################################################################

# Not reinventing the wheel. From the following link:
# https://www.ludovicocaldara.net/dba/bash-tips-4-use-logging-levels/
colblk='\033[0;30m' # Black - Regular
colred='\033[0;31m' # Red
colgrn='\033[0;32m' # Green
colylw='\033[0;33m' # Yellow
colpur='\033[0;35m' # Purple
colrst='\033[0m'    # Text Reset
colwht='\033[0;37m' # White

verbosity=5

### verbosity levels
silent_lvl=0
crt_lvl=1
err_lvl=2
wrn_lvl=3
ntf_lvl=4
inf_lvl=5
dbg_lvl=6

VERSION="1.0.0"
SCRIPT="$(basename "$0")"

# ---------------------------------------------------------------- helpers ---

function esilent {
    verb_lvl=$silent_lvl elog "$*"
}

function enotify {
    verb_lvl=$ntf_lvl elog "$*"
}

function eok {
    verb_lvl=$ntf_lvl elog "SUCCESS - $*"
}

function ewarn {
    verb_lvl=$wrn_lvl elog "${colylw}WARNING${colrst} - $*"
}

function einfo {
    verb_lvl=$inf_lvl elog "${colwht}INFO${colrst} ---- $*"
}

function edebug {
    verb_lvl=$dbg_lvl elog "${colgrn}DEBUG${colrst} --- $*"
}

function eerror {
    verb_lvl=$err_lvl elog "${colred}ERROR${colrst} --- $*"
}

function ecrit {
    verb_lvl=$crt_lvl elog "${colpur}FATAL${colrst} --- $*"
}

function edumpvar {
    for var in "$@"; do
        edebug "$var=${!var}"
    done
}

function elog {
    datestring=$(date +"%Y-%m-%d %H:%M:%S")
    if [[ $verbosity -lt $verb_lvl ]]; then
        echo -e "${datestring} - $*"
    else
        echo -e "${datestring} - $*"
    fi
}

die()  { printf '%s: error: %s\n' "$SCRIPT" "$*" >&2; exit 1; }
warn() { printf '%s: warning: %s\n' "$SCRIPT" "$*" >&2; }
info() { printf '%s: %s\n' "$SCRIPT" "$*" >&2; }

need() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }

# Print help. usage 0 -> stdout (explicit --help); usage N>0 -> stderr (misuse).
usage() {
    local rc="${1:-0}"
    local text
    text="$(cat <<EOF
$SCRIPT $VERSION — batch migration of files from local/USB disks to a OneDrive
folder, from WSL2, using rsync over drvfs (/mnt/c, /mnt/e, ...).

Usage: $SCRIPT <subcommand> [args...]
       $SCRIPT -h|--help|help

Subcommands:
  plan    <source-dir> <batch-size> [plan-dir]     build batch lists + name report
  mkdirs  <source-dir> <dest-dir>                  replicate directory tree only
  copy    <batch-file> <dest-dir> [--source DIR]   copy one batch with rsync
  verify  <batch-file> <dest-dir> [--source DIR]   dry-run: what would still be copied
  free    <dest-dir>                               dehydrate synced files (free local space)
  status  <dest-dir>                               count files still occupying local disk

  <batch-size> accepts IEC suffixes (500M, 50G, 1T) or plain bytes.
  [plan-dir] defaults to ./od-plan-YYYYMMDD-HHMMSS.
  --source overrides the SOURCE recorded in <plan-dir>/plan.conf.
  free/status require WSL (powershell.exe) and a dest under /mnt/<drive>.

Typical cycle (repeat for each batch):
  copy -> wait for OneDrive to sync -> status (until 0 hydrated) -> free -> next copy
EOF
)"
    if (( rc == 0 )); then
        printf '%s\n' "$text"
    else
        printf '%s\n' "$text" >&2
    fi
    exit "$rc"
}

# Parse "50G", "500M", "1T", "123456789" into bytes.
to_bytes() {
    local v="$1"
    case "$v" in
        *[0-9]) printf '%s' "$v" ;;
        *)      numfmt --from=iec "$v" 2>/dev/null || die "cannot parse size: $v" ;;
    esac
}

human() { numfmt --to=iec --suffix=B "$1"; }

abspath() { readlink -f "$1"; }

# Common rsync options for drvfs -> drvfs copies:
#  -r -t        recurse, keep mtime (needed for idempotent re-runs)
#  -W           whole-file: delta transfer only costs CPU when both sides are local
#  --inplace    no temp files: OneDrive client dislikes rename-into-place and
#               temp files double the peak disk usage
#  --no-*       NTFS via drvfs does not map perms/owner/group; avoids spurious errors
RSYNC_BASE=(-r -t -W --inplace --no-perms --no-owner --no-group --no-links)

# Load plan.conf next to a batch file (sets SOURCE) unless --source was given.
resolve_source() {
    local batch="$1" override="${2:-}"
    if [[ -n "$override" ]]; then
        SOURCE="$(abspath "$override")"
    else
        local conf; conf="$(dirname "$(abspath "$batch")")/plan.conf"
        [[ -f "$conf" ]] || die "plan.conf not found next to $batch; pass --source DIR"
        # shellcheck disable=SC1090
        source "$conf"
        [[ -n "${SOURCE:-}" ]] || die "SOURCE not set in $conf"
    fi
    [[ -d "$SOURCE" ]] || die "source dir does not exist: $SOURCE"
}

# Windows path for PowerShell calls (free/status). Only works on drvfs mounts.
win_path() {
    need wslpath
    wslpath -w "$1" 2>/dev/null || die "cannot convert to Windows path (is it under /mnt/<drive>?): $1"
}

# OneDrive name rules. Returns a reason string on stdout if invalid, empty if ok.
# Checked per path component. Limits are OneDrive for Business documented limits.
check_name() {
    local rel="$1" size="$2" reason=""
    local IFS='/' comp
    # path length: OneDrive limit is 400 chars for the full path incl. the
    # OneDrive root; we flag at 350 to leave room for the Windows-side prefix.
    (( ${#rel} > 350 )) && reason+="path>350chars;"
    (( size > 268435456000 )) && reason+="file>250GB;"
    for comp in $rel; do
        [[ "$comp" =~ [\<\>:\"\|\?\*] ]]            && reason+="forbidden-char;"
        [[ "$comp" =~ [[:cntrl:]] ]]                  && reason+="control-char;"
        [[ "$comp" =~ ^[[:space:]] ]]                 && reason+="leading-space;"
        [[ "$comp" =~ [[:space:].]$ ]]                && reason+="trailing-space-or-dot;"
        [[ "$comp" =~ ^~\$ ]]                         && reason+="tilde-dollar-prefix;"
        [[ "$comp" == "_vti_"* ]]                     && reason+="_vti_;"
        [[ "$comp" =~ ^\.lock$|^desktop\.ini$ ]]      && reason+="reserved-file;"
        shopt -s nocasematch
        [[ "$comp" =~ ^(CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(\..*)?$ ]] && reason+="reserved-name;"
        shopt -u nocasematch
    done
    printf '%s' "$reason"
}

# ------------------------------------------------------------------- plan ---

cmd_plan() {
    [[ $# -ge 2 ]] || usage 1
    need find; need sort; need numfmt
    local src; src="$(abspath "$1")"
    [[ -d "$src" ]] || die "source dir does not exist: $src"
    local limit; limit="$(to_bytes "$2")"
    local plan_dir="${3:-./od-plan-$(date +%Y%m%d-%H%M%S)}"
    mkdir -p "$plan_dir"
    plan_dir="$(abspath "$plan_dir")"

    info "scanning $src (this can take a while on drvfs)..."
    local raw="$plan_dir/.files.raw"
    # size<TAB>relative-path, NUL-terminated, sorted by path so a directory's
    # files tend to land in the same batch.
    find "$src" -type f -printf '%s\t%P\0' | sort -z -t $'\t' -k2 > "$raw"

    local invalid="$plan_dir/invalid-names.tsv"
    local summary="$plan_dir/plan-summary.txt"
    : > "$invalid"

    local n=0 batch_bytes=0 batch_files=0 total_bytes=0 total_files=0 \
          skipped=0 oversize=0 size rel reason batch
    local -a batch_sizes=() batch_counts=()

    open_batch() {
        n=$((n+1)); batch_bytes=0; batch_files=0
        batch="$(printf '%s/batch-%04d.txt' "$plan_dir" "$n")"
        : > "$batch"
    }
    close_batch() {
        (( batch_files == 0 )) && return 0
        printf '%s\n' "$batch_bytes" > "${batch%.txt}.bytes"
        batch_sizes+=("$batch_bytes"); batch_counts+=("$batch_files")
    }

    open_batch
    while IFS=$'\t' read -r -d '' size rel; do
        reason="$(check_name "$rel" "$size")"
        if [[ -n "$reason" ]]; then
            printf '%s\t%s\t%s\n' "$reason" "$size" "$rel" >> "$invalid"
            skipped=$((skipped+1))
            continue
        fi
        if (( size > limit )); then
            oversize=$((oversize+1))
            warn "file larger than batch size, gets its own batch: $rel ($(human "$size"))"
            if (( batch_files > 0 )); then close_batch; open_batch; fi
            printf '%s\0' "$rel" >> "$batch"
            batch_bytes=$size; batch_files=1
            close_batch; open_batch
            total_bytes=$((total_bytes+size)); total_files=$((total_files+1))
            continue
        fi
        if (( batch_bytes + size > limit )); then
            close_batch; open_batch
        fi
        printf '%s\0' "$rel" >> "$batch"
        batch_bytes=$((batch_bytes+size)); batch_files=$((batch_files+1))
        total_bytes=$((total_bytes+size)); total_files=$((total_files+1))
    done < "$raw"
    close_batch
    # remove trailing empty batch if any
    [[ -s "$batch" ]] || rm -f "$batch"
    rm -f "$raw"

    printf 'SOURCE=%q\n' "$src" > "$plan_dir/plan.conf"

    {
        printf 'od-migrate plan v%s — %s\n' "$VERSION" "$(date -Is)"
        printf 'source     : %s\n' "$src"
        printf 'batch size : %s (%s bytes)\n' "$(human "$limit")" "$limit"
        printf 'files      : %d planned, %d skipped (invalid OneDrive names), %d oversize\n' \
               "$total_files" "$skipped" "$oversize"
        printf 'total      : %s\n' "$(human "$total_bytes")"
        printf 'batches    : %d\n\n' "${#batch_sizes[@]}"
        local i
        for i in "${!batch_sizes[@]}"; do
            printf 'batch-%04d.txt  %8s  %7d files\n' $((i+1)) \
                   "$(human "${batch_sizes[$i]}")" "${batch_counts[$i]}"
        done
    } | tee "$summary" >&2

    if (( skipped > 0 )); then
        warn "$skipped file(s) have names OneDrive will reject — see $invalid (rename them and re-plan, or they will never be copied)"
    fi
    info "plan written to $plan_dir"
}

# ----------------------------------------------------------------- mkdirs ---

cmd_mkdirs() {
    [[ $# -eq 2 ]] || usage 1
    need rsync
    local src; src="$(abspath "$1")"
    local dest; dest="$(abspath "$2")"
    [[ -d "$src" ]] || die "source dir does not exist: $src"
    mkdir -p "$dest"
    info "replicating directory tree $src -> $dest"
    rsync "${RSYNC_BASE[@]}" -f '+ */' -f '- *' --info=stats1 "$src/" "$dest/"
}

# ------------------------------------------------------------ copy/verify ---

parse_batch_args() {
    need getopt
    # Options may appear before, between or after the positionals
    # (getopt permutes them); "--" ends options.
    local parsed src_override=""
    if ! parsed="$(getopt --options "" --longoptions "source:" \
                          --name "$SCRIPT" -- "$@")"; then
        usage 1   # getopt already printed the reason on stderr
    fi
    # Safe: getopt output is quoted specifically for this eval.
    eval set -- "$parsed"
    while true; do
        case "$1" in
            --source) src_override="$2"; shift 2 ;;
            --)       shift; break ;;
            *)        die "internal argument parsing error at: $1" ;;
        esac
    done
    [[ $# -eq 2 ]] || usage 1
    BATCH="$(abspath "$1")"; DEST="$(abspath "$2")"
    [[ -f "$BATCH" ]] || die "batch file not found: $BATCH"
    resolve_source "$BATCH" "$src_override"
}

check_space() {
    local bytes_file="${BATCH%.txt}.bytes" need_bytes avail
    [[ -f "$bytes_file" ]] || { warn "no .bytes sidecar for batch; skipping free-space check"; return 0; }
    need_bytes="$(<"$bytes_file")"
    avail="$(df --output=avail -B1 "$DEST" | tail -1 | tr -d ' ')"
    # 5% headroom for OneDrive metadata / filesystem overhead
    local required=$(( need_bytes + need_bytes / 20 ))
    if (( avail < required )); then
        die "not enough free space on destination: need ~$(human "$required"), have $(human "$avail"). Wait for OneDrive to sync, then run: $SCRIPT free $DEST"
    fi
    info "free space ok: batch $(human "$need_bytes"), available $(human "$avail")"
}

cmd_copy() {
    parse_batch_args "$@"
    need rsync
    mkdir -p "$DEST"
    check_space
    local log="${BATCH%.txt}.log"
    info "copying batch $(basename "$BATCH") from $SOURCE to $DEST (log: $log)"
    rsync "${RSYNC_BASE[@]}" \
          --from0 --files-from="$BATCH" \
          --info=progress2,stats1 \
          --log-file="$log" \
          "$SOURCE/" "$DEST/"
    info "batch done. Next: wait for OneDrive to sync, check with '$SCRIPT status $DEST', then '$SCRIPT free $DEST'"
}

cmd_verify() {
    parse_batch_args "$@"
    need rsync
    info "dry-run of $(basename "$BATCH"): lines below are files that would still be (re)copied"
    rsync "${RSYNC_BASE[@]}" \
          --from0 --files-from="$BATCH" \
          --dry-run --itemize-changes \
          "$SOURCE/" "$DEST/" | grep -v '/$' || info "nothing pending — batch fully present in destination"
}

# ------------------------------------------------------------ free/status ---

cmd_free() {
    [[ $# -eq 1 ]] || usage 1
    need powershell.exe
    local dest; dest="$(abspath "$1")"
    local wdest; wdest="$(win_path "$dest")"
    info "marking files under $wdest as 'free up space' (attrib +U -P). Only files already synced will be dehydrated."
    # +U = unpinned (free up space), -P = not pinned (always keep on device)
    powershell.exe -NoProfile -Command "attrib +U -P \"$wdest\\*\" /S /D" >/dev/null
    info "done. Run '$SCRIPT status $dest' to see how much is still on local disk."
}

cmd_status() {
    [[ $# -eq 1 ]] || usage 1
    need powershell.exe
    local dest; dest="$(abspath "$1")"
    local wdest; wdest="$(win_path "$dest")"
    # FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS (0x400000) marks a dehydrated
    # (cloud-only) file. Anything without it still occupies local disk.
    powershell.exe -NoProfile -Command "
        \$f = Get-ChildItem -LiteralPath '$wdest' -Recurse -File -Force -ErrorAction SilentlyContinue
        \$hyd = \$f | Where-Object { -not ([int]\$_.Attributes -band 0x400000) }
        \$bytes = (\$hyd | Measure-Object -Property Length -Sum).Sum
        if (-not \$bytes) { \$bytes = 0 }
        Write-Output ('total files        : ' + \$f.Count)
        Write-Output ('still on local disk: ' + \$hyd.Count + ' files, ' + [math]::Round(\$bytes/1GB,2) + ' GB')
        Write-Output ('cloud-only         : ' + (\$f.Count - \$hyd.Count) + ' files')
    " | tr -d '\r'
}

# ------------------------------------------------------------------- main ---

need getopt

# Global options. The leading "+" makes getopt stop at the first non-option
# (the subcommand) instead of permuting, so subcommand options such as
# "copy ... --source DIR" are left for the subcommand's own parser.
SHORT_OPTS="+h"
LONG_OPTS="help"

if ! PARSED_OPTIONS="$(getopt --options "$SHORT_OPTS" --longoptions "$LONG_OPTS" \
                              --name "$SCRIPT" -- "$@")"; then
    usage 1   # getopt already printed the reason on stderr
fi
# Safe: getopt output is quoted specifically for this eval.
eval set -- "$PARSED_OPTIONS"

while true; do
    case "$1" in
        -h|--help) usage 0 ;;
        --)        shift; break ;;
        *)         die "internal argument parsing error at: $1" ;;
    esac
done

# Remaining positionals: <subcommand> [args...]
[[ $# -ge 1 ]] || usage 1
cmd="$1"; shift
case "$cmd" in
    plan)    cmd_plan "$@" ;;
    mkdirs)  cmd_mkdirs "$@" ;;
    copy)    cmd_copy "$@" ;;
    verify)  cmd_verify "$@" ;;
    free)    cmd_free "$@" ;;
    status)  cmd_status "$@" ;;
    help)    usage 0 ;;
    *) die "unknown subcommand: $cmd (try --help)" ;;
esac
