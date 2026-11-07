<#
.SYNOPSIS
    od-migrate.ps1 - batch migration of files from local/USB disks to a OneDrive
    folder on Windows, using robocopy. Native Windows counterpart of od-migrate.sh.

.DESCRIPTION
    Subcommands:
      plan    <source-dir> <batch-size> [plan-dir]   build batch lists + name report
      mkdirs  <source-dir> <dest-dir>                replicate directory tree only
      copy    <batch-file> <dest-dir> [-Source DIR]  copy one batch with robocopy
      verify  <batch-file> <dest-dir> [-Source DIR]  list files of the batch still to copy
      free    <dest-dir>                             dehydrate synced files (free local space)
      status  <dest-dir>                             count files still occupying local disk

    Typical cycle (repeat for each batch):
      copy -> wait for OneDrive to sync -> status (until 0 hydrated) -> free -> next copy

    Batch files are UTF-8 text, one path per line, relative to the source dir
    (Windows file names cannot contain line breaks). The source dir is recorded
    in <plan-dir>\plan.json so copy/verify do not need it again; override with
    -Source. Plans are NOT interchangeable with od-migrate.sh.

    robocopy has no --files-from: copy groups the batch by directory and runs
    one robocopy per directory with the file names as filters.

    Must run on stock Windows PowerShell 5.1. Keep this file ASCII-only:
    PowerShell 5.1 reads BOM-less scripts in the ANSI code page.

    Version: see $VERSION below and CHANGELOG.md. License: MIT.
#>
# PSReviewUnusedParameter: false positive. -Retries, -WaitSeconds, -Threads and
# -Restartable are read inside functions (Get-RoboOption, Invoke-TreeCopy)
# through script scope, which the analyzer does not follow.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
    Justification = 'Script parameters are read inside functions via script scope')]
[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(Position = 0)][string]$Command,
    [Parameter(Position = 1)][string]$Arg1,
    [Parameter(Position = 2)][string]$Arg2,
    [Parameter(Position = 3)][string]$Arg3,
    [string]$Source,
    [ValidateRange(0, 1000)][int]$Retries = 5,
    [ValidateRange(0, 3600)][int]$WaitSeconds = 10,
    [ValidateRange(1, 128)][int]$Threads = 1,
    [switch]$Restartable,
    [Alias('h')][switch]$Help
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$VERSION = '1.0.0'
$SCRIPT = Split-Path -Leaf $PSCommandPath

trap {
    [Console]::Error.WriteLine("${SCRIPT}: error: " + $_.Exception.Message)
    exit 1
}

# ---------------------------------------------------------------- helpers ---

function Exit-WithError([string]$msg) { [Console]::Error.WriteLine("${SCRIPT}: error: $msg"); exit 1 }
function Write-Warn([string]$msg)     { [Console]::Error.WriteLine("${SCRIPT}: warning: $msg") }
function Write-Info([string]$msg)     { [Console]::Error.WriteLine("${SCRIPT}: $msg") }

function Assert-Command([string]$name) {
    if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
        Exit-WithError "required command not found: $name"
    }
}

function Show-Usage([int]$rc = 0) {
    $text = @"
$SCRIPT $VERSION - batch migration of files from local/USB disks to a OneDrive
folder on Windows, using robocopy.

Usage: $SCRIPT <subcommand> [args...] [options]
       $SCRIPT -Help
       (from cmd.exe: od-migrate.cmd <subcommand> [args...] [options])

Subcommands:
  plan    <source-dir> <batch-size> [plan-dir]   build batch lists + name report
  mkdirs  <source-dir> <dest-dir>                replicate directory tree only
  copy    <batch-file> <dest-dir> [-Source DIR]  copy one batch with robocopy
  verify  <batch-file> <dest-dir> [-Source DIR]  list files of the batch still to copy
  free    <dest-dir>                             dehydrate synced files (free local space)
  status  <dest-dir>                             count files still occupying local disk

Options (copy, mkdirs):
  -Retries N       retries per failed file, robocopy /R (default 5)
  -WaitSeconds N   wait between retries, robocopy /W (default 10)
  -Threads N       robocopy /MT:N (default 1 = single-threaded)
  -Restartable     robocopy /Z: resume large files after I/O errors (slower)

  <batch-size> accepts IEC suffixes (500M, 50G, 1T) or plain bytes.
  [plan-dir] defaults to .\od-plan-YYYYMMDD-HHMMSS.
  -Source overrides the Source recorded in <plan-dir>\plan.json.
  Plans made by od-migrate.sh cannot be used here: run plan again.

Typical cycle (repeat for each batch):
  copy -> wait for OneDrive to sync -> status (until 0 hydrated) -> free -> next copy
"@
    if ($rc -eq 0) { [Console]::Out.WriteLine($text) } else { [Console]::Error.WriteLine($text) }
    exit $rc
}

$Invariant = [Globalization.CultureInfo]::InvariantCulture

# Parse "50G", "500M", "1T", "123456789" into bytes (IEC, powers of 1024).
function ConvertTo-ByteCount([string]$s) {
    if ($s -notmatch '^\s*(\d+(?:\.\d+)?)\s*([KMGTP]?)(?:i?B)?\s*$') {
        Exit-WithError "cannot parse size: $s"
    }
    $n = [double]::Parse($Matches[1], $Invariant)
    $exp = 0
    if ($Matches[2]) { $exp = 'KMGTP'.IndexOf($Matches[2].ToUpperInvariant()) + 1 }
    $bytes = [long]($n * [math]::Pow(1024, $exp))
    if ($bytes -le 0) { Exit-WithError "batch size must be greater than zero: $s" }
    return $bytes
}

function Format-Size([long]$b) {
    $units = 'B', 'KB', 'MB', 'GB', 'TB', 'PB'
    $v = [double]$b; $i = 0
    while ($v -ge 1024 -and $i -lt 5) { $v /= 1024; $i++ }
    if ($i -eq 0) { return "${b}B" }
    return [string]::Format($Invariant, '{0:0.0}{1}', $v, $units[$i])
}

# Absolute, normalised path; relative paths resolve against the PowerShell
# location (not the process cwd, which is what .NET would use).
function Resolve-FullPath([string]$p) {
    $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($p)
    $full = [IO.Path]::GetFullPath($full)
    if ($full.Length -gt 3 -and $full.EndsWith('\')) { $full = $full.TrimEnd('\') }
    return $full
}

# \\?\ prefix for .NET file APIs so paths over 260 chars work. Probed once:
# if this runtime rejects the prefix, fall back to plain paths.
try {
    $script:UseLongPrefix = (New-Object IO.DirectoryInfo ('\\?\' + $env:SystemDrive + '\')).Exists
} catch {
    $script:UseLongPrefix = $false
}
function Get-LongPath([string]$p) {
    if (-not $script:UseLongPrefix -or $p.StartsWith('\\?\')) { return $p }
    if ($p.StartsWith('\\')) { return '\\?\UNC\' + $p.Substring(2) }
    return '\\?\' + $p
}

function Test-Dir([string]$p)  { return [IO.Directory]::Exists((Get-LongPath $p)) }
function Test-File([string]$p) { return [IO.File]::Exists((Get-LongPath $p)) }

# base + "\" + rel, tolerating an empty side and a base that ends in "\" (C:\).
function Join-Rel([string]$base, [string]$rel) {
    if (-not $base) { return $rel }
    if (-not $rel) { return $base }
    if ($base.EndsWith('\')) { return $base + $rel }
    return "$base\$rel"
}

# robocopy directory argument. A trailing backslash would escape the closing
# quote PowerShell adds around paths with spaces, so "C:\" becomes "C:\.".
function Format-RoboDir([string]$p) {
    if ($p.EndsWith('\')) { return $p + '.' }
    return $p
}

$Utf8NoBom = New-Object Text.UTF8Encoding $false
function Write-Utf8File([string]$path, [string[]]$lines) {
    [IO.File]::WriteAllLines((Get-LongPath $path), $lines, $Utf8NoBom)
}

# robocopy options shared by copy and mkdirs:
#  /COPY:DT /DCOPY:T  data + timestamps only (timestamps make re-runs idempotent:
#                     unchanged size+mtime is skipped); no ACLs/owner/attributes,
#                     matching od-migrate.sh (--no-perms --no-owner --no-group)
#  /R /W              bounded retries: robocopy's default is 1,000,000 retries
#                     30 s apart, which looks like a hang on a flaky disk
#  /XJ                skip junctions and symlinks (like rsync --no-links)
# robocopy writes straight into the destination file (no temp file + rename),
# which is what od-migrate.sh gets from rsync --inplace.
function Get-RoboOption {
    $o = @('/COPY:DT', '/DCOPY:T', "/R:$Retries", "/W:$WaitSeconds", '/XJ', '/NP', '/BYTES')
    if ($Threads -gt 1) { $o += "/MT:$Threads" }
    if ($Restartable) { $o += '/Z' }
    return , $o
}

# OneDrive name rules. Returns a reason string if invalid, empty if ok.
# Checked per path component. Keep in sync with check_name() in od-migrate.sh
# and the README section "OneDrive name rules".
function Get-NameProblem([string]$rel, [long]$size) {
    $r = ''
    # OneDrive limit is 400 chars for the full path incl. the OneDrive root;
    # flag at 350 to leave room for the Windows-side prefix.
    if ($rel.Length -gt 350) { $r += 'path>350chars;' }
    if ($size -gt 268435456000) { $r += 'file>250GB;' }
    foreach ($c in $rel.Split([char]'\')) {
        if ($c -match '[<>:"|?*]')                         { $r += 'forbidden-char;' }
        if ($c -match '[\x00-\x1F\x7F]')                   { $r += 'control-char;' }
        # ASCII whitespace only, like bash [[:space:]]: .NET \s would also match
        # U+00A0 and other Unicode spaces, which OneDrive accepts.
        if ($c -match '^[\t\n\v\f\r ]')                    { $r += 'leading-space;' }
        if ($c -match '[\t\n\v\f\r .]$')                   { $r += 'trailing-space-or-dot;' }
        if ($c.StartsWith('~$', [StringComparison]::Ordinal))    { $r += 'tilde-dollar-prefix;' }
        if ($c.StartsWith('_vti_', [StringComparison]::Ordinal)) { $r += '_vti_;' }
        if ($c -ceq '.lock' -or $c -ceq 'desktop.ini')     { $r += 'reserved-file;' }
        # -match is case-insensitive, like nocasematch in the bash version
        if ($c -match '^(CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(\..*)?$') { $r += 'reserved-name;' }
    }
    return $r
}

# Fast pre-filter equivalent to the per-component rules above, applied to the
# whole relative path, so the slow per-component check runs only on suspects.
$script:AnyNameProblem = New-Object regex (
    '[<>:"|?*\x00-\x1F\x7F]|(?:^|\\)[\t\n\v\f\r ]|[\t\n\v\f\r .](?:\\|$)|(?:^|\\)~\$|(?:^|\\)_vti_' +
    '|(?:^|\\)(?:\.lock|desktop\.ini)(?:\\|$)' +
    '|(?i:(?:^|\\)(?:CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(?:\.[^\\]*)?(?:\\|$))')

# Walk the tree depth-first: a directory's files (sorted) come before its
# subdirectories (sorted), so a directory's files land in the same batch.
# Reparse points (junctions, symlinks) are not followed and are reported.
# Returns the number of unreadable directories.
function Get-TreeFileList([string]$root, $rels, $sizes, $reparse) {
    $lroot = Get-LongPath $root
    $stack = New-Object 'System.Collections.Generic.Stack[string]'
    $stack.Push('')
    $unreadable = 0
    $cmp = [StringComparer]::OrdinalIgnoreCase
    while ($stack.Count -gt 0) {
        $rel = $stack.Pop()
        try {
            $entries = (New-Object IO.DirectoryInfo (Join-Rel $lroot $rel)).GetFileSystemInfos()
        } catch {
            $shown = if ($rel) { $rel } else { '.' }
            Write-Warn "cannot read directory, skipped: $shown ($($_.Exception.Message))"
            $unreadable++
            continue
        }
        $fNames = New-Object 'System.Collections.Generic.List[string]'
        $fSizes = New-Object 'System.Collections.Generic.List[long]'
        $dNames = New-Object 'System.Collections.Generic.List[string]'
        foreach ($e in $entries) {
            if (($e.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                $reparse.Add((Join-Rel $rel $e.Name))
            } elseif (($e.Attributes -band [IO.FileAttributes]::Directory) -ne 0) {
                $dNames.Add($e.Name)
            } else {
                $fNames.Add($e.Name)
                $fSizes.Add($e.Length)
            }
        }
        $fn = $fNames.ToArray(); $fs = $fSizes.ToArray()
        [Array]::Sort($fn, $fs, $cmp)
        for ($i = 0; $i -lt $fn.Length; $i++) {
            $rels.Add((Join-Rel $rel $fn[$i]))
            $sizes.Add($fs[$i])
        }
        $dn = $dNames.ToArray()
        [Array]::Sort($dn, $cmp)
        for ($i = $dn.Length - 1; $i -ge 0; $i--) { $stack.Push((Join-Rel $rel $dn[$i])) }
    }
    return $unreadable
}

# ------------------------------------------------------------------- plan ---

function Invoke-Plan([string]$srcArg, [string]$sizeArg, [string]$planArg) {
    $src = Resolve-FullPath $srcArg
    if (-not (Test-Dir $src)) { Exit-WithError "source dir does not exist: $src" }
    $limit = ConvertTo-ByteCount $sizeArg
    if (-not $planArg) { $planArg = '.\od-plan-' + (Get-Date -Format 'yyyyMMdd-HHmmss') }
    $planDir = Resolve-FullPath $planArg
    [void][IO.Directory]::CreateDirectory((Get-LongPath $planDir))

    Write-Info "scanning $src ..."
    $rels    = New-Object 'System.Collections.Generic.List[string]'
    $sizes   = New-Object 'System.Collections.Generic.List[long]'
    $reparse = New-Object 'System.Collections.Generic.List[string]'
    $unreadable = Get-TreeFileList $src $rels $sizes $reparse

    $invalid = New-Object 'System.Collections.Generic.List[string]'
    foreach ($r in $reparse) { $invalid.Add("reparse-point;`t0`t$r") }

    $n = 0
    $cur = New-Object 'System.Collections.Generic.List[string]'
    $curBytes = [long]0
    $bSizes = New-Object 'System.Collections.Generic.List[long]'
    $bCounts = New-Object 'System.Collections.Generic.List[int]'
    $totalBytes = [long]0; $totalFiles = 0; $skipped = $reparse.Count; $oversize = 0

    # dot-sourced so it updates the variables of this function
    $closeBatch = {
        if ($cur.Count -gt 0) {
            $n++
            $base = [IO.Path]::Combine($planDir, ('batch-{0:D4}' -f $n))
            Write-Utf8File "$base.txt" $cur.ToArray()
            Write-Utf8File "$base.bytes" @([string]$curBytes)
            $bSizes.Add($curBytes); $bCounts.Add($cur.Count)
            $cur.Clear(); $curBytes = [long]0
        }
    }

    for ($i = 0; $i -lt $rels.Count; $i++) {
        $rel = $rels[$i]; $size = $sizes[$i]
        if ($rel.Length -gt 350 -or $size -gt 268435456000 -or $script:AnyNameProblem.IsMatch($rel)) {
            $reason = Get-NameProblem $rel $size
            if ($reason) {
                $invalid.Add("$reason`t$size`t$rel")
                $skipped++
                continue
            }
        }
        if ($size -gt $limit) {
            $oversize++
            Write-Warn "file larger than batch size, gets its own batch: $rel ($(Format-Size $size))"
            . $closeBatch
            $cur.Add($rel); $curBytes = $size
            . $closeBatch
        } else {
            if ($curBytes + $size -gt $limit) { . $closeBatch }
            $cur.Add($rel); $curBytes += $size
        }
        $totalBytes += $size; $totalFiles++
    }
    . $closeBatch

    $invalidPath = [IO.Path]::Combine($planDir, 'invalid-names.tsv')
    Write-Utf8File $invalidPath $invalid.ToArray()

    $conf = [ordered]@{
        Source  = $src
        Tool    = $SCRIPT
        Version = $VERSION
        Created = (Get-Date).ToString('s')
    }
    Write-Utf8File ([IO.Path]::Combine($planDir, 'plan.json')) @(($conf | ConvertTo-Json))

    $summary = New-Object 'System.Collections.Generic.List[string]'
    $summary.Add(('od-migrate plan v{0} (powershell) - {1}' -f $VERSION, (Get-Date).ToString('s')))
    $summary.Add("source     : $src")
    $summary.Add("batch size : $(Format-Size $limit) ($limit bytes)")
    $summary.Add("files      : $totalFiles planned, $skipped skipped (see invalid-names.tsv), $oversize oversize")
    $summary.Add("total      : $(Format-Size $totalBytes)")
    $summary.Add("batches    : $($bSizes.Count)")
    $summary.Add('')
    for ($i = 0; $i -lt $bSizes.Count; $i++) {
        $summary.Add(('batch-{0:D4}.txt  {1,8}  {2,7} files' -f ($i + 1), (Format-Size $bSizes[$i]), $bCounts[$i]))
    }
    Write-Utf8File ([IO.Path]::Combine($planDir, 'plan-summary.txt')) $summary.ToArray()
    foreach ($l in $summary) { [Console]::Error.WriteLine($l) }

    if ($skipped -gt 0) {
        Write-Warn "$skipped file(s) will not be copied (invalid OneDrive names or reparse points) - see $invalidPath (rename them and re-plan)"
    }
    if ($unreadable -gt 0) {
        Write-Warn "$unreadable director(y/ies) could not be read and were not planned - see warnings above"
    }
    Write-Info "plan written to $planDir"
}

# ----------------------------------------------------------------- mkdirs ---

function Invoke-TreeCopy([string]$srcArg, [string]$destArg) {
    Assert-Command 'robocopy.exe'
    $src = Resolve-FullPath $srcArg
    $dest = Resolve-FullPath $destArg
    if (-not (Test-Dir $src)) { Exit-WithError "source dir does not exist: $src" }
    [void][IO.Directory]::CreateDirectory((Get-LongPath $dest))
    Write-Info "replicating directory tree $src -> $dest"
    # /E + /XF * : every subdirectory, no files
    & robocopy.exe (Format-RoboDir $src) (Format-RoboDir $dest) '/E' '/XF' '*' `
        '/DCOPY:T' '/XJ' "/R:$Retries" "/W:$WaitSeconds" '/NP' '/NFL' '/NJH' | Out-Host
    $rc = $LASTEXITCODE
    if ($rc -ge 8) { Exit-WithError "robocopy failed with exit code $rc" }
}

# ------------------------------------------------------------ copy/verify ---

function Resolve-Source([string]$batch, [string]$override) {
    if ($override) {
        $s = Resolve-FullPath $override
    } else {
        $conf = [IO.Path]::Combine([IO.Path]::GetDirectoryName($batch), 'plan.json')
        if (-not (Test-File $conf)) { Exit-WithError "plan.json not found next to $batch; pass -Source DIR" }
        $s = ([IO.File]::ReadAllText((Get-LongPath $conf)) | ConvertFrom-Json).Source
        if (-not $s) { Exit-WithError "Source not set in $conf" }
    }
    if (-not (Test-Dir $s)) { Exit-WithError "source dir does not exist: $s" }
    return $s
}

# Batch file -> .Dirs (relative dirs, in file order) and .Files (dir -> names).
# Dirs is a separate list, not $dict.Keys: PowerShell's dot access on a
# dictionary returns the entry named "Keys" if a directory has that name.
function Get-BatchLayout([string]$batch) {
    $lines = [IO.File]::ReadAllLines((Get-LongPath $batch), [Text.Encoding]::UTF8)
    if ($lines.Length -gt 0 -and $lines[0].IndexOf([char]0) -ge 0) {
        Exit-WithError "$batch is a NUL-separated batch written by od-migrate.sh; run '$SCRIPT plan' to make a plan for this script"
    }
    $dirs = New-Object 'System.Collections.Generic.List[string]'
    $files = New-Object 'System.Collections.Generic.Dictionary[string,System.Collections.Generic.List[string]]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($l in $lines) {
        if (-not $l) { continue }
        $idx = $l.LastIndexOf('\')
        if ($idx -ge 0) { $d = $l.Substring(0, $idx); $name = $l.Substring($idx + 1) }
        else { $d = ''; $name = $l }
        if (-not $files.ContainsKey($d)) {
            $files[$d] = New-Object 'System.Collections.Generic.List[string]'
            $dirs.Add($d)
        }
        $files[$d].Add($name)
    }
    return [pscustomobject]@{ Dirs = $dirs.ToArray(); Files = $files }
}

# Split file names into chunks that keep the robocopy command line under the
# 32767-char CreateProcess limit.
function Split-NameList($names, [int]$budget) {
    $chunks = New-Object 'System.Collections.Generic.List[object]'
    $cur = New-Object 'System.Collections.Generic.List[string]'
    $len = 0
    foreach ($nm in $names) {
        if ($cur.Count -gt 0 -and $len + $nm.Length + 3 -gt $budget) {
            $chunks.Add($cur.ToArray())
            $cur = New-Object 'System.Collections.Generic.List[string]'
            $len = 0
        }
        $cur.Add($nm); $len += $nm.Length + 3
    }
    if ($cur.Count -gt 0) { $chunks.Add($cur.ToArray()) }
    return , $chunks
}

function Get-ArgBudget([string[]]$fixed) {
    $len = 0
    foreach ($a in $fixed) { $len += $a.Length + 3 }
    return 32000 - $len - 200
}

function Test-FreeSpace([string]$batch, [string]$dest) {
    $bytesFile = [IO.Path]::ChangeExtension($batch, '.bytes')
    if (-not (Test-File $bytesFile)) {
        Write-Warn 'no .bytes sidecar for batch; skipping free-space check'
        return
    }
    $need = [long]([IO.File]::ReadAllText((Get-LongPath $bytesFile)).Trim())
    try {
        $avail = (New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($dest))).AvailableFreeSpace
    } catch {
        Write-Warn "cannot read free space for $dest; skipping free-space check"
        return
    }
    # 5% headroom for OneDrive metadata / filesystem overhead
    $required = $need + [long][math]::Floor($need / 20)
    if ($avail -lt $required) {
        Exit-WithError "not enough free space on destination: need ~$(Format-Size $required), have $(Format-Size $avail). Wait for OneDrive to sync, then run: $SCRIPT free `"$dest`""
    }
    Write-Info "free space ok: batch $(Format-Size $need), available $(Format-Size $avail)"
}

function Invoke-Copy([string]$batchArg, [string]$destArg, [string]$override) {
    Assert-Command 'robocopy.exe'
    $batch = Resolve-FullPath $batchArg
    if (-not (Test-File $batch)) { Exit-WithError "batch file not found: $batch" }
    $src = Resolve-Source $batch $override
    $dest = Resolve-FullPath $destArg
    [void][IO.Directory]::CreateDirectory((Get-LongPath $dest))
    Test-FreeSpace $batch $dest

    $groups = Get-BatchLayout $batch
    $dirs = $groups.Dirs
    $log = [IO.Path]::ChangeExtension($batch, '.log')
    $name = [IO.Path]::GetFileName($batch)
    $opts = Get-RoboOption
    Write-Info "copying batch $name from $src to $dest ($($dirs.Count) directories; log: $log)"

    $failed = New-Object 'System.Collections.Generic.List[string]'
    $sw = [Diagnostics.Stopwatch]::StartNew()
    for ($i = 0; $i -lt $dirs.Count; $i++) {
        $d = $dirs[$i]
        if ($sw.ElapsedMilliseconds -ge 500) {
            Write-Progress -Activity "od-migrate copy $name" -Status "directory $($i + 1) of $($dirs.Count): $d" `
                -PercentComplete ([int](100 * $i / $dirs.Count))
            $sw.Restart()
        }
        $s = Format-RoboDir (Join-Rel $src $d)
        $t = Format-RoboDir (Join-Rel $dest $d)
        $fixed = @($s, $t, "/UNILOG+:$log", '/TEE', '/NDL', '/NJH', '/NJS', '/FP') + $opts
        foreach ($chunk in (Split-NameList $groups.Files[$d] (Get-ArgBudget $fixed))) {
            & robocopy.exe $s $t $chunk $opts "/UNILOG+:$log" '/TEE' '/NDL' '/NJH' '/NJS' '/FP' | Out-Host
            $rc = $LASTEXITCODE
            # robocopy: 0-7 = success (bit flags), 8+ = some copies failed
            if ($rc -ge 8) { $failed.Add($(if ($d) { $d } else { '.' })) }
        }
    }
    Write-Progress -Activity "od-migrate copy $name" -Completed

    if ($failed.Count -gt 0) {
        $shown = ($failed | Select-Object -First 10) -join '; '
        if ($failed.Count -gt 10) { $shown += '; ...' }
        Exit-WithError ("$($failed.Count) robocopy run(s) failed (exit code 8 or more) in: $shown. " +
            "Details in $log (search for ERROR). Re-run the same copy: files already copied are skipped.")
    }
    Write-Info "batch done. Next: wait for OneDrive to sync, check with '$SCRIPT status `"$dest`"', then '$SCRIPT free `"$dest`"'"
}

function Invoke-Verify([string]$batchArg, [string]$destArg, [string]$override) {
    Assert-Command 'robocopy.exe'
    $batch = Resolve-FullPath $batchArg
    if (-not (Test-File $batch)) { Exit-WithError "batch file not found: $batch" }
    $src = Resolve-Source $batch $override
    $dest = Resolve-FullPath $destArg
    $groups = Get-BatchLayout $batch
    Write-Info "dry-run of $([IO.Path]::GetFileName($batch)): lines below are files that would still be (re)copied"

    # /L lists only; robocopy reads metadata, so freed (cloud-only) files are
    # not re-hydrated.
    $opts = @('/L', '/COPY:DT', '/XJ', '/R:0', '/W:0', '/NP', '/NDL', '/NJH', '/NJS', '/FP', '/BYTES')
    $pending = 0; $errors = 0
    foreach ($d in $groups.Dirs) {
        $s = Format-RoboDir (Join-Rel $src $d)
        $t = Format-RoboDir (Join-Rel $dest $d)
        foreach ($chunk in (Split-NameList $groups.Files[$d] (Get-ArgBudget (@($s, $t) + $opts)))) {
            $out = & robocopy.exe $s $t $chunk $opts
            if ($LASTEXITCODE -ge 8) { $errors++ }
            foreach ($line in $out) {
                $tl = "$line".Trim()
                if ($tl -and $tl -notmatch '^\*EXTRA') { $pending++; Write-Output $tl }
            }
        }
    }
    if ($errors -gt 0) { Exit-WithError "robocopy reported errors in $errors run(s); see the lines above" }
    if ($pending -eq 0) { Write-Info 'nothing pending - batch fully present in destination' }
}

# ------------------------------------------------------------ free/status ---

function Invoke-Free([string]$destArg) {
    Assert-Command 'attrib.exe'
    $dest = Resolve-FullPath $destArg
    if (-not (Test-Dir $dest)) { Exit-WithError "dest dir does not exist: $dest" }
    Write-Info "marking files under $dest as 'free up space' (attrib +U -P). Only files already synced will be dehydrated."
    # +U = unpinned (free up space), -P = not pinned (always keep on device)
    & attrib.exe '+U' '-P' (Join-Rel $dest '*') '/S' '/D' | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Warn "attrib exited with code $LASTEXITCODE" }
    Write-Info "done. Run '$SCRIPT status `"$dest`"' to see how much is still on local disk."
}

function Invoke-Status([string]$destArg) {
    $dest = Resolve-FullPath $destArg
    if (-not (Test-Dir $dest)) { Exit-WithError "dest dir does not exist: $dest" }
    # FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS (0x400000) marks a dehydrated
    # (cloud-only) file. Anything without it still occupies local disk.
    $files = @(Get-ChildItem -LiteralPath $dest -Recurse -File -Force -ErrorAction SilentlyContinue)
    $hyd = @($files | Where-Object { -not ([int64]$_.Attributes -band 0x400000) })
    $bytes = [long]0
    foreach ($f in $hyd) { $bytes += $f.Length }
    Write-Output ('total files        : ' + $files.Count)
    Write-Output ('still on local disk: ' + $hyd.Count + ' files, ' + (Format-Size $bytes))
    Write-Output ('cloud-only         : ' + ($files.Count - $hyd.Count) + ' files')
}

# ------------------------------------------------------------------- main ---

# Dot-sourced (". .\od-migrate.ps1"): define the functions only, run nothing.
# Lets the unit tests call the pure helpers directly.
if ($MyInvocation.InvocationName -eq '.') { return }

function Assert-ArgCount([int]$min, [int]$max) {
    $given = @($Arg1, $Arg2, $Arg3 | Where-Object { $_ }).Count
    if ($given -lt $min -or $given -gt $max) { Show-Usage 1 }
}

if ($Help -or $Command -in @('help', '-h', '--help', '/?')) { Show-Usage 0 }
if (-not $Command) { Show-Usage 1 }
if ($Source -and $Command -notin @('copy', 'verify')) {
    Exit-WithError "-Source is only valid for copy and verify"
}

switch ($Command) {
    'plan'   { Assert-ArgCount 2 3; Invoke-Plan $Arg1 $Arg2 $Arg3 }
    'mkdirs' { Assert-ArgCount 2 2; Invoke-TreeCopy $Arg1 $Arg2 }
    'copy'   { Assert-ArgCount 2 2; Invoke-Copy $Arg1 $Arg2 $Source }
    'verify' { Assert-ArgCount 2 2; Invoke-Verify $Arg1 $Arg2 $Source }
    'free'   { Assert-ArgCount 1 1; Invoke-Free $Arg1 }
    'status' { Assert-ArgCount 1 1; Invoke-Status $Arg1 }
    default  { Exit-WithError "unknown subcommand: $Command (try -Help)" }
}
exit 0
