# Tests for od-migrate.ps1 (Pester 5+). Run: Invoke-Pester tests
#
#  - "helpers": pure functions, loaded by dot-sourcing the script into a
#    dynamic module (the script skips its main section when dot-sourced).
#    Runs on any OS, including pwsh on Linux.
#  - "command line": usage and argument errors, run as a child process.
#    Runs on any OS.
#  - "with robocopy": plan / mkdirs / copy / verify end to end. Windows only.
#
# free / status need a real OneDrive folder and are tested manually (see
# CLAUDE.md). Child processes use the same PowerShell edition as the test
# run, so CI on Windows PowerShell 5.1 tests the 5.1 behaviour.

BeforeDiscovery {
    $OnWindows = [Environment]::OSVersion.Platform -eq 'Win32NT'
}

BeforeAll {
    $Ps1 = Join-Path (Split-Path -Parent $PSScriptRoot) 'od-migrate.ps1'
    $PsExe = (Get-Process -Id $PID).Path

    function Invoke-Od {
        $ErrorActionPreference = 'Continue'   # native stderr must not throw
        $out = & $PsExe -NoProfile -ExecutionPolicy Bypass -File $Ps1 @args 2>&1 |
            ForEach-Object { "$_" }
        [pscustomobject]@{ Code = $LASTEXITCODE; Output = ($out -join "`n") }
    }

    function Write-RandomFile([string]$path, [int]$bytes) {
        $buf = New-Object byte[] $bytes
        (New-Object Random).NextBytes($buf)
        [IO.File]::WriteAllBytes($path, $buf)
    }

    function Get-Hash([string]$path) { (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash }
}

Describe 'od-migrate.ps1 helpers' {
    BeforeAll {
        # A module keeps the script's StrictMode / trap / ErrorActionPreference
        # out of the test scope. Never call Exit-WithError paths here: exit
        # would end the test run.
        $Od = New-Module -Name od-migrate-under-test -ScriptBlock {
            param($path)
            . $path
        } -ArgumentList $Ps1
    }

    It 'ConvertTo-ByteCount parses <In> as <Out>' -ForEach @(
        @{ In = '123'; Out = 123 }
        @{ In = '4M'; Out = 4194304 }
        @{ In = '500m'; Out = 524288000 }
        @{ In = '50G'; Out = 53687091200 }
        @{ In = '50GiB'; Out = 53687091200 }
        @{ In = '50GB'; Out = 53687091200 }
        @{ In = '1T'; Out = 1099511627776 }
        @{ In = '1.5G'; Out = 1610612736 }
    ) {
        & $Od { param($v) ConvertTo-ByteCount $v } $In | Should -Be $Out
    }

    It 'Format-Size ignores the current culture' {
        $saved = [Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [Threading.Thread]::CurrentThread.CurrentCulture = 'pt-BR'
            & $Od { Format-Size 1536 } | Should -Be '1.5KB'
        } finally {
            [Threading.Thread]::CurrentThread.CurrentCulture = $saved
        }
        & $Od { Format-Size 0 } | Should -Be '0B'
        & $Od { Format-Size 53687091200 } | Should -Be '50.0GB'
    }

    # Expected reasons are the output of check_name() in od-migrate.sh for the
    # same names (with / as separator): the two implementations must agree.
    It 'Get-NameProblem matches od-migrate.sh check_name (expects "<Reason>")' -ForEach @(
            @{ Name = 'ok.txt'; Reason = '' }
            @{ Name = 'dir a\f1 with space.bin'; Reason = '' }
            @{ Name = 'a<b'; Reason = 'forbidden-char;' }
            @{ Name = 'a>b'; Reason = 'forbidden-char;' }
            @{ Name = 'a:b'; Reason = 'forbidden-char;' }
            @{ Name = 'a"b'; Reason = 'forbidden-char;' }
            @{ Name = 'a|b'; Reason = 'forbidden-char;' }
            @{ Name = 'a?b'; Reason = 'forbidden-char;' }
            @{ Name = 'a*b'; Reason = 'forbidden-char;' }
            @{ Name = '' + 'ctl' + [char]0x0001 + 'x'; Reason = 'control-char;' }
            @{ Name = '' + 'del' + [char]0x007F + 'x'; Reason = 'control-char;' }
            @{ Name = '' + 'tab' + [char]0x0009 + 'x'; Reason = 'control-char;' }
            @{ Name = ' lead'; Reason = 'leading-space;' }
            @{ Name = 'trail '; Reason = 'trailing-space-or-dot;' }
            @{ Name = 'trail.'; Reason = 'trailing-space-or-dot;' }
            @{ Name = 'dir.\x'; Reason = 'trailing-space-or-dot;' }
            @{ Name = 'dir \x'; Reason = 'trailing-space-or-dot;' }
            @{ Name = ' d\x'; Reason = 'leading-space;' }
            @{ Name = '~$lock.docx'; Reason = 'tilde-dollar-prefix;' }
            @{ Name = 'x~$y'; Reason = '' }
            @{ Name = '_vti_cnf'; Reason = '_vti_;' }
            @{ Name = 'a_vti_'; Reason = '' }
            @{ Name = 'a\_vti_x\b'; Reason = '_vti_;' }
            @{ Name = '.lock'; Reason = 'reserved-file;' }
            @{ Name = 'x.lock'; Reason = '' }
            @{ Name = '.LOCK'; Reason = '' }
            @{ Name = 'desktop.ini'; Reason = 'reserved-file;' }
            @{ Name = 'Desktop.ini'; Reason = '' }
            @{ Name = 'desktop.ini.bak'; Reason = '' }
            @{ Name = 'CON'; Reason = 'reserved-name;' }
            @{ Name = 'con'; Reason = 'reserved-name;' }
            @{ Name = 'CON.txt'; Reason = 'reserved-name;' }
            @{ Name = 'con.tar.gz'; Reason = 'reserved-name;' }
            @{ Name = 'CONSOLE'; Reason = '' }
            @{ Name = 'COM1'; Reason = 'reserved-name;' }
            @{ Name = 'com9.x'; Reason = 'reserved-name;' }
            @{ Name = 'COM10'; Reason = '' }
            @{ Name = 'LPT0'; Reason = 'reserved-name;' }
            @{ Name = 'lpt5.doc'; Reason = 'reserved-name;' }
            @{ Name = 'NUL'; Reason = 'reserved-name;' }
            @{ Name = 'nul\x'; Reason = 'reserved-name;' }
            @{ Name = 'AUX.'; Reason = 'trailing-space-or-dot;reserved-name;' }
            @{ Name = 'PRN '; Reason = 'trailing-space-or-dot;' }
            @{ Name = 'a\CON\b'; Reason = 'reserved-name;' }
            @{ Name = 'CONx\y'; Reason = '' }
            @{ Name = 'x.CON'; Reason = '' }
            @{ Name = 'ok\ok\ok.txt'; Reason = '' }
            @{ Name = '' + 'na' + [char]0x00EF + 've caf' + [char]0x00E9 + '.txt'; Reason = '' }
            @{ Name = '' + [char]0x65E5 + [char]0x672C + [char]0x8A9E + '.txt'; Reason = '' }
            @{ Name = '' + 'emoji ' + [char]0xD83D + [char]0xDE00 + '.png'; Reason = '' }
            @{ Name = '' + 'nbsp' + [char]0x00A0 + 'end'; Reason = '' }
            @{ Name = '' + [char]0x00A0 + 'lead'; Reason = '' }
            @{ Name = ('a' * 351); Reason = 'path>350chars;' }
            @{ Name = ('a' * 350); Reason = '' }
            @{ Name = 'dir\' + ('b' * 346); Reason = '' }
    ) {
        & $Od { param($n) Get-NameProblem $n 1 } $Name | Should -BeExactly $Reason
        # the fast pre-filter must flag exactly the names the full check flags
        $flagged = & $Od { param($n) $n.Length -gt 350 -or $AnyNameProblem.IsMatch($n) } $Name
        $flagged | Should -Be ([bool]$Reason)
    }

    It 'Get-NameProblem flags files over 250 GB' {
        & $Od { Get-NameProblem 'big.bin' 268435456001 } | Should -Be 'file>250GB;'
        & $Od { Get-NameProblem 'big.bin' 268435456000 } | Should -Be ''
    }

    It 'Join-Rel and Format-RoboDir handle roots and empty sides' {
        & $Od { Join-Rel '' 'a.txt' } | Should -Be 'a.txt'
        & $Od { Join-Rel 'C:\src' '' } | Should -Be 'C:\src'
        & $Od { Join-Rel 'C:\' 'a' } | Should -Be 'C:\a'
        & $Od { Join-Rel 'C:\src' 'dir a\b' } | Should -Be 'C:\src\dir a\b'
        & $Od { Format-RoboDir 'C:\' } | Should -Be 'C:\.'
        & $Od { Format-RoboDir 'C:\My Dir' } | Should -Be 'C:\My Dir'
    }

    It 'Split-NameList keeps every name and respects the budget' {
        $chunks = & $Od {
            $names = 1..100 | ForEach-Object { 'file-{0:D3}.bin' -f $_ }   # 12 chars + 3
            , (Split-NameList $names 150)
        }
        $chunks.Count | Should -Be 10
        foreach ($c in $chunks) { $c.Count | Should -Be 10 }
        @($chunks | ForEach-Object { $_ }).Count | Should -Be 100
    }

    It 'Get-BatchLayout groups by directory in file order, even a dir named Keys' {
        $batch = Join-Path $TestDrive 'batch-0001.txt'
        [IO.File]::WriteAllLines($batch, [string[]]@('root.txt', 'Keys\a.bin', 'dir a\x.bin', 'Keys\b.bin', 'dir a\sub\y.bin'))
        $layout = & $Od { param($b) Get-BatchLayout $b } $batch
        $layout.Dirs | Should -Be @('', 'Keys', 'dir a', 'dir a\sub')
        @($layout.Files['Keys']) | Should -Be @('a.bin', 'b.bin')
        @($layout.Files['']) | Should -Be @('root.txt')
    }
}

Describe 'od-migrate.ps1 command line' {
    It 'no args prints usage and exits 1' {
        $r = Invoke-Od
        $r.Code | Should -Be 1
        $r.Output | Should -Match 'Subcommands:'
    }

    It 'help and -Help print usage and exit 0' {
        (Invoke-Od help).Code | Should -Be 0
        $r = Invoke-Od -Help
        $r.Code | Should -Be 0
        $r.Output | Should -Match 'Usage:'
    }

    It 'unknown subcommand fails' {
        $r = Invoke-Od bogus
        $r.Code | Should -Be 1
        $r.Output | Should -Match 'unknown subcommand'
    }

    It 'subcommand with missing or extra args prints usage and exits 1' {
        $r = Invoke-Od copy
        $r.Code | Should -Be 1
        $r.Output | Should -Match 'Usage:'
        (Invoke-Od status a b).Code | Should -Be 1
    }

    It '-Source is rejected outside copy and verify' {
        $r = Invoke-Od plan $TestDrive 1G -Source $TestDrive
        $r.Code | Should -Be 1
        $r.Output | Should -Match '-Source is only valid'
    }

    It 'plan rejects unparsable size' {
        $r = Invoke-Od plan $TestDrive 12X (Join-Path $TestDrive 'plan')
        $r.Code | Should -Be 1
        $r.Output | Should -Match 'cannot parse size'
    }
}

Describe 'od-migrate.ps1 with robocopy' -Skip:(-not $OnWindows) {
    BeforeEach {
        $Tmp = Join-Path ([IO.Path]::GetTempPath()) ('od-' + [guid]::NewGuid().ToString('N'))
        $Src = Join-Path $Tmp 'src'
        $Dst = Join-Path $Tmp 'dst'
        $Plan = Join-Path $Tmp 'plan'
        New-Item -ItemType Directory -Force -Path (Join-Path $Src 'dir a\sub'), (Join-Path $Src 'dir b'), $Dst | Out-Null
        Write-RandomFile (Join-Path $Src 'dir a\f1 with space.bin') 3MB
        Write-RandomFile (Join-Path $Src 'dir a\sub\f2.bin') 2MB
        Write-RandomFile (Join-Path $Src 'dir b\big.bin') 5MB
        # valid on NTFS, rejected by OneDrive
        Write-RandomFile (Join-Path $Src 'dir b\~$lock.docx') 1MB
        Write-RandomFile (Join-Path $Src 'dir b\desktop.ini') 100KB
        Set-Content -LiteralPath (Join-Path $Src 'root.txt') -Value 'hi'
        $Valid = @('root.txt', 'dir a\f1 with space.bin', 'dir a\sub\f2.bin', 'dir b\big.bin')
    }

    AfterEach { Remove-Item -LiteralPath $Tmp -Recurse -Force -ErrorAction SilentlyContinue }

    It 'plan packs files by size and skips invalid OneDrive names' {
        $r = Invoke-Od plan $Src 4M $Plan
        $r.Code | Should -Be 0
        # 4 valid files, 2 invalid, 1 oversize (big.bin > 4M)
        $r.Output | Should -Match '4 planned, 2 skipped'
        $r.Output | Should -Match '1 oversize'
        Test-Path -LiteralPath (Join-Path $Plan 'plan.json') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $Plan 'plan-summary.txt') | Should -BeTrue
        $tsv = Get-Content -LiteralPath (Join-Path $Plan 'invalid-names.tsv') -Raw
        $tsv | Should -Match ([regex]::Escape("tilde-dollar-prefix;`t"))
        $tsv | Should -Match ([regex]::Escape("reserved-file;`t"))
        $tsv | Should -Match ([regex]::Escape('~$lock.docx'))
        $tsv | Should -Match 'desktop\.ini'
        foreach ($b in Get-ChildItem -LiteralPath $Plan -Filter 'batch-*.txt') {
            $bytesFile = [IO.Path]::ChangeExtension($b.FullName, '.bytes')
            Test-Path -LiteralPath $bytesFile | Should -BeTrue
            $bytes = [long](Get-Content -LiteralPath $bytesFile -Raw).Trim()
            # oversize file is allowed to exceed, but only when alone in its batch
            if ($bytes -gt 4MB) { @(Get-Content -LiteralPath $b.FullName).Count | Should -Be 1 }
        }
        # one relative path per line
        Get-Content -LiteralPath (Join-Path $Plan 'batch-0001.txt') | Should -Contain 'dir a\f1 with space.bin'
    }

    It 'plan records absolute source in plan.json' {
        Push-Location $Tmp
        try { $r = Invoke-Od plan 'src' 1T 'plan' } finally { Pop-Location }
        $r.Code | Should -Be 0
        $conf = Get-Content -LiteralPath (Join-Path $Plan 'plan.json') -Raw | ConvertFrom-Json
        $conf.Source | Should -Be $Src
    }

    It 'mkdirs replicates directory tree without files' {
        $r = Invoke-Od mkdirs $Src $Dst
        $r.Code | Should -Be 0
        Test-Path -LiteralPath (Join-Path $Dst 'dir a\sub') -PathType Container | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $Dst 'dir b') -PathType Container | Should -BeTrue
        @(Get-ChildItem -LiteralPath $Dst -Recurse -File -Force).Count | Should -Be 0
    }

    It 'copy transfers one batch and is idempotent' {
        (Invoke-Od plan $Src 4M $Plan).Code | Should -Be 0
        $batch = Join-Path $Plan 'batch-0001.txt'
        $r = Invoke-Od copy $batch $Dst
        $r.Code | Should -Be 0
        $f1 = 'dir a\f1 with space.bin'
        Get-Hash (Join-Path $Dst $f1) | Should -Be (Get-Hash (Join-Path $Src $f1))
        Test-Path -LiteralPath (Join-Path $Dst 'dir a\sub\f2.bin') | Should -BeFalse   # batch 2
        # second run copies nothing
        $r = Invoke-Od copy $batch $Dst
        $r.Code | Should -Be 0
        $r.Output | Should -Not -Match 'New File'
        Test-Path -LiteralPath ([IO.Path]::ChangeExtension($batch, '.log')) | Should -BeTrue
    }

    It 'copy accepts -Source override when plan.json is absent' {
        (Invoke-Od plan $Src 1T $Plan).Code | Should -Be 0   # everything in one batch
        Remove-Item -LiteralPath (Join-Path $Plan 'plan.json')
        $batch = Join-Path $Plan 'batch-0001.txt'
        $r = Invoke-Od copy $batch $Dst
        $r.Code | Should -Be 1
        $r.Output | Should -Match 'plan.json not found'
        $r = Invoke-Od copy $batch $Dst -Source $Src
        $r.Code | Should -Be 0
        Test-Path -LiteralPath (Join-Path $Dst 'root.txt') | Should -BeTrue
    }

    It 'copy refuses to start when the batch does not fit in free space' {
        (Invoke-Od plan $Src 1T $Plan).Code | Should -Be 0
        Set-Content -LiteralPath (Join-Path $Plan 'batch-0001.bytes') -Value '1125899906842624'   # 1 PiB
        $r = Invoke-Od copy (Join-Path $Plan 'batch-0001.txt') $Dst
        $r.Code | Should -Be 1
        $r.Output | Should -Match 'not enough free space'
        Test-Path -LiteralPath (Join-Path $Dst 'root.txt') | Should -BeFalse
    }

    It 'copy rejects a NUL-separated batch from od-migrate.sh' {
        New-Item -ItemType Directory -Force -Path $Plan | Out-Null
        $batch = Join-Path $Plan 'batch-0001.txt'
        [IO.File]::WriteAllText($batch, "root.txt`0dir a/f1 with space.bin`0")
        $r = Invoke-Od copy $batch $Dst -Source $Src
        $r.Code | Should -Be 1
        $r.Output | Should -Match 'od-migrate\.sh'
    }

    It 'verify reports pending files and clean batches' {
        (Invoke-Od plan $Src 4M $Plan).Code | Should -Be 0
        $batch = Join-Path $Plan 'batch-0001.txt'
        $r = Invoke-Od verify $batch $Dst
        $r.Code | Should -Be 0
        $r.Output | Should -Match ([regex]::Escape('dir a\f1 with space.bin'))
        (Invoke-Od copy $batch $Dst).Code | Should -Be 0
        $r = Invoke-Od verify $batch $Dst
        $r.Code | Should -Be 0
        $r.Output | Should -Match 'nothing pending'
    }

    It 'all batches together reproduce every valid file' {
        (Invoke-Od plan $Src 4M $Plan).Code | Should -Be 0
        foreach ($b in Get-ChildItem -LiteralPath $Plan -Filter 'batch-*.txt') {
            (Invoke-Od copy $b.FullName $Dst).Code | Should -Be 0
        }
        foreach ($f in $Valid) {
            Get-Hash (Join-Path $Dst $f) | Should -Be (Get-Hash (Join-Path $Src $f))
        }
        Test-Path -LiteralPath (Join-Path $Dst 'dir b\~$lock.docx') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $Dst 'dir b\desktop.ini') | Should -BeFalse
    }
}
