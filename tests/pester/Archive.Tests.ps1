# Copyright (c) 2026 Costas Kirgoussios
#
# This software is licensed under the PolyForm Noncommercial License 1.0.0.
# You may obtain a copy of the License at:
# https://polyformproject.org/licenses/noncommercial/1.0.0/

# Tests for the setup.ps1 files layer: locks, orphan cleanup, staging, archive listing, archive safety,
# extraction, install swap, JDK pruning and the disk checks. They mirror tests/sh/archive.sh. Fixtures come
# from tests/integration/make_archives.py into a scratch directory whose name contains a space, so every path
# below is also a quoting test. A test that only makes sense on Windows says so in its name and is skipped
# elsewhere.

BeforeDiscovery {
    $script:OnWindows = ([System.IO.Path]::DirectorySeparatorChar -eq '\')
}

BeforeAll {
    # BeforeDiscovery variables are empty in the run phase, so the run-phase reads need their own copy
    $script:OnWindows = ([System.IO.Path]::DirectorySeparatorChar -eq '\')
    $env:REA_SETUP_NO_MAIN = '1'
    $script:SetupPath = (Resolve-Path (Join-Path $PSScriptRoot '../../setup.ps1')).Path
    . $script:SetupPath
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
    $script:T = Join-Path ([System.IO.Path]::GetTempPath()) ('rea archive work ' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:T | Out-Null
    $script:Python = $null
    foreach ($candidate in @('python3', 'python')) {
        if (-not $script:Python -and (Get-Command $candidate -ErrorAction SilentlyContinue)) { $script:Python = $candidate }
    }
    if (-not $script:Python) { throw 'python3 or python is required to build the archive fixtures' }
    & $script:Python -I (Join-Path $script:Root 'tests/integration/make_archives.py') $script:T
    if ($LASTEXITCODE -ne 0) { throw 'make_archives.py failed' }
    # Zips whose entry names are Windows-style, built here so the refusal is proven on every OS.
    $zipScript = Join-Path $script:T 'mkzip.py'
    Set-Content -LiteralPath $zipScript -Value @(
        'import sys, zipfile',
        'with zipfile.ZipFile(sys.argv[1], "w") as z:',
        '    z.writestr(sys.argv[2], b"x")'
    )
    & $script:Python -I $zipScript (Join-Path $script:T 'win-drive.zip') 'C:\evil.txt'
    & $script:Python -I $zipScript (Join-Path $script:T 'win-dotdot.zip') '..\evil.txt'
    & $script:Python -I $zipScript (Join-Path $script:T 'win-unc.zip') '\\server\share\evil.txt'
    & $script:Python -I $zipScript (Join-Path $script:T 'win-dotdot-mid.zip') 'a\..\..\evil.txt'
    $script:SavedLockPolls = $script:LockPolls
    $script:SavedTar = $script:TarExe
    function script:Set-OldAge {
        param([string]$Path, [int]$Hours)
        [System.IO.Directory]::SetLastWriteTimeUtc($Path, [DateTime]::UtcNow.AddHours(-$Hours))
    }
}

AfterAll {
    Remove-Item -LiteralPath $script:T -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'archive safety: tar' {
    It 'accepts a clean tar' { Test-ReaArchiveSafe -Path (Join-Path $script:T 'clean.tar.gz') | Should -BeTrue }
    It 'refuses <name>' -ForEach @(
        @{ name = 'dotdot' }, @{ name = 'dotdot-mid' }, @{ name = 'abs' }, @{ name = 'symlink' },
        @{ name = 'symlink-rel' }, @{ name = 'symlink-deep' }, @{ name = 'symchain' }, @{ name = 'empty' }
    ) {
        Test-ReaArchiveSafe -Path (Join-Path $script:T "$name.tar.gz") | Should -BeFalse
    }
    It 'accepts the hardlinks GNU tar neutralises when it lists them' {
        # The tar the product lists with, not the first one on PATH: on Windows that is the bsdtar of System32
        $listing = & (Get-ReaTarExe) --version 2>$null
        if (-not ($listing -match 'GNU tar')) { Set-ItResult -Skipped -Because 'tar is not GNU tar: the neutralised hardlink listing is not produced'; return }
        Test-ReaArchiveSafe -Path (Join-Path $script:T 'hardlink-rel.tar.gz') | Should -BeTrue
    }
    It 'refuses a missing archive' { Test-ReaArchiveSafe -Path (Join-Path $script:T 'nope.tar.gz') | Should -BeFalse }
    It 'refuses a file that is not an archive' {
        Test-ReaArchiveSafe -Path (Join-Path $script:T 'notzip.zip') | Should -BeFalse
        $plain = Join-Path $script:T 'plain.tar.gz'
        Set-Content -LiteralPath $plain -Value 'not gzip'
        Test-ReaArchiveSafe -Path $plain | Should -BeFalse
    }
    It 'names the offending entry in the log' {
        Mock Write-ReaLog {}
        Test-ReaArchiveSafe -Path (Join-Path $script:T 'dotdot.tar.gz') | Out-Null
        Should -Invoke Write-ReaLog -ParameterFilter { $Level -eq 'ERROR' -and $Message -like '*evil.txt*' }
    }
    It 'returns nothing, not null, when the listing fails' {
        $r = @(Get-ReaArchiveEntry -Path (Join-Path $script:T 'nope.tar.gz'))
        $r.Count | Should -Be 0
    }
}

Describe 'archive safety: zip' {
    It 'accepts a clean zip' { Test-ReaArchiveSafe -Path (Join-Path $script:T 'clean.zip') | Should -BeTrue }
    It 'refuses <name>' -ForEach @(
        @{ name = 'dotdot' }, @{ name = 'dotdot-mid' }, @{ name = 'abs' }, @{ name = 'backslash' },
        @{ name = 'drive' }, @{ name = 'symlink' }, @{ name = 'win-drive' }, @{ name = 'win-dotdot' },
        @{ name = 'win-unc' }, @{ name = 'win-dotdot-mid' }, @{ name = 'notype-evil' }, @{ name = 'empty' },
        @{ name = 'notzip' }, @{ name = 'nope' }
    ) {
        Test-ReaArchiveSafe -Path (Join-Path $script:T "$name.zip") | Should -BeFalse
    }
    It 'treats an entry without type bits and a harmless name as a regular file' {
        Test-ReaArchiveSafe -Path (Join-Path $script:T 'notype-ok.zip') | Should -BeTrue
        $e = @(Get-ReaArchiveEntry -Path (Join-Path $script:T 'notype-ok.zip'))
        $e[0].Type | Should -Be 'f'
    }
    It 'does not invent a link target for a name holding " l "' {
        $e = @(Get-ReaArchiveEntry -Path (Join-Path $script:T 'spacel.zip'))
        $e.Count | Should -Be 2
        $e[0].Path | Should -Be 'dir/a l b'
        $e[0].Type | Should -Be 'f'
        Test-ReaArchiveSafe -Path (Join-Path $script:T 'spacel.zip') | Should -BeTrue
    }
    It 'mismatched entry count: the verdict is a boolean and, when safe, the hidden entry is never extracted' {
        # .NET may read the count from the end record (then the listed entries are the extracted ones) or refuse
        # the file. Both are safe; reporting safe and then extracting the hidden entry is not.
        $z = Join-Path $script:T 'mismatch.zip'
        $dest = Join-Path $script:T 'mismatch out'
        $safe = @(Test-ReaArchiveSafe -Path $z)
        $safe.Count | Should -Be 1
        $safe[0] | Should -BeOfType [bool]
        $listed = @(Get-ReaArchiveEntry -Path $z)
        if ($safe[0]) {
            $listed.Count | Should -BeGreaterThan 0
            Expand-ReaArchive -Path $z -Destination $dest | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $script:T 'evil') | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $dest 'evil') | Should -BeFalse
        } else {
            $safe[0] | Should -BeFalse
            Test-Path -LiteralPath $dest | Should -BeFalse
        }
    }
}

Describe 'archive listing' {
    It 'lists a tar with modes, types, spaces and link targets' {
        $e = @(Get-ReaArchiveEntry -Path (Join-Path $script:T 'clean.tar.gz'))
        ($e | Where-Object Path -eq 'top/bin/java').Type | Should -Be 'f'
        ($e | Where-Object Path -eq 'top/file with spaces.txt').Type | Should -Be 'f'
        ($e | Where-Object Path -eq 'top/dir with space/').Type | Should -Be 'd'
        $sym = $e | Where-Object Path -eq 'top/bin/libjli.so'
        $sym.Type | Should -Be 'l'
        $sym.Target | Should -Be '../lib/libjli.so'
        $hard = $e | Where-Object Path -eq 'top/hard'
        $hard.Type | Should -Be 'h'
        $hard.Target | Should -Be 'top/lib/libjli.so'
    }
    It 'lists a zip with directory, file and symlink entries' {
        $e = @(Get-ReaArchiveEntry -Path (Join-Path $script:T 'clean.zip'))
        $e.Count | Should -Be 3
        $e[0].Type | Should -Be 'd'
        ($e | Where-Object Path -like '*inner file.txt').Type | Should -Be 'f'
        $s = @(Get-ReaArchiveEntry -Path (Join-Path $script:T 'symlink.zip'))
        $s[0].Type | Should -Be 'l'
        $s[0].Target | Should -Be '/etc/passwd'
    }
}

Describe 'tar listing parser' {
    It 'parses GNU and bsdtar line shapes alike' {
        $gnu = '-rw-r--r-- user/group 12 2026-01-01 00:00 dir with space/a -> b.txt'
        $bsd = '-rw-r--r--  0 user   group      12 Jan  1 00:00 dir with space/a -> b.txt'
        foreach ($l in @($gnu, $bsd)) {
            $e = @(ConvertFrom-ReaTarListing -Text $l)
            $e.Count | Should -Be 1
            $e[0].Path | Should -Be 'dir with space/a -> b.txt'
            $e[0].Type | Should -Be 'f'
        }
    }
    It 'fails closed on a line it cannot parse' {
        @(ConvertFrom-ReaTarListing -Text "-rw-r--r-- u/g 1 2026-01-01 00:00 a`nthis is not a record").Count | Should -Be 0
    }
    It 'fails closed on an ambiguous link line' {
        @(ConvertFrom-ReaTarListing -Text 'lrwxrwxrwx u/g 0 2026-01-01 00:00 a -> b -> /etc/passwd').Count | Should -Be 0
    }
    It 'fails closed on an empty listing' {
        @(ConvertFrom-ReaTarListing -Text '').Count | Should -Be 0
    }
}

Describe 'entry checker on hand-written entries' {
    BeforeAll {
        function script:E {
            param([string]$Type, [string]$Path, [string]$Target = '')
            [pscustomobject]@{ Mode = '?'; Type = $Type; Path = $Path; Target = $Target }
        }
    }
    It 'refuses an absolute hardlink target' { Test-ReaArchiveEntry -Entries @(E h 'top/hl' '/etc/passwd') | Should -BeFalse }
    It 'allows an inside hardlink target' { Test-ReaArchiveEntry -Entries @(E h 'top/hl' 'top/lib/x') | Should -BeTrue }
    It 'refuses a hardlink dotdot target' { Test-ReaArchiveEntry -Entries @(E h 'top/hl' 'top/../../x') | Should -BeFalse }
    It 'allows an inside symlink' { Test-ReaArchiveEntry -Entries @(E l 'a/b/link' '../c') | Should -BeTrue }
    It 'allows a symlink to the root itself' { Test-ReaArchiveEntry -Entries @(E l 'a/link' '..') | Should -BeTrue }
    It 'refuses a symlink one level too far' { Test-ReaArchiveEntry -Entries @(E l 'a/link' '../..') | Should -BeFalse }
    It 'refuses a symlink with an inner dotdot' { Test-ReaArchiveEntry -Entries @(E l 'a/link' 'b/../../x') | Should -BeFalse }
    It 'refuses a symlink with a lexically harmless inner dotdot' { Test-ReaArchiveEntry -Entries @(E l 'a/link' 'b/../c') | Should -BeFalse }
    It 'refuses a Windows absolute symlink target' { Test-ReaArchiveEntry -Entries @(E l 'a/link' 'C:\Windows') | Should -BeFalse }
    It 'refuses a UNC symlink target' { Test-ReaArchiveEntry -Entries @(E l 'a/link' '\\server\share') | Should -BeFalse }
    It 'allows spaces and arrows in a regular file name' { Test-ReaArchiveEntry -Entries @(E f 'dir with space/a -> b.txt') | Should -BeTrue }
    It 'refuses a dotdot component among spaces' { Test-ReaArchiveEntry -Entries @(E f 'dir with space/../../x') | Should -BeFalse }
    It 'allows dots inside a name' { Test-ReaArchiveEntry -Entries @(E f 'a/..b/c..d/e.f') | Should -BeTrue }
    It 'allows ./ as the current directory' { Test-ReaArchiveEntry -Entries @((E d './'), (E f './a.txt')) | Should -BeTrue }
    It 'refuses a colon: <p>' -ForEach @(
        @{ p = 'a.txt:stream' }, @{ p = 'C:evil' }, @{ p = 'top/a:b' }, @{ p = 'top/C:' }
    ) { Test-ReaArchiveEntry -Entries @(E f $p) | Should -BeFalse }
    It 'refuses a segment ending in a dot or a space: <p>' -ForEach @(
        @{ p = 'top/... ' }, @{ p = 'top/...' }, @{ p = 'top/a.' }, @{ p = 'top/a /b' }, @{ p = 'top/.. /b' }, @{ p = 'top/b ' }
    ) { Test-ReaArchiveEntry -Entries @(E f $p) | Should -BeFalse }
    It 'refuses a Windows device name as a segment stem: <p>' -ForEach @(
        @{ p = 'top/CON' }, @{ p = 'top/con.txt' }, @{ p = 'PRN/x' }, @{ p = 'top/Aux.tar.gz' }, @{ p = 'top/NUL' },
        @{ p = 'top/COM1' }, @{ p = 'top/com9.txt' }, @{ p = 'top/LPT1' }, @{ p = 'top/lpt9.log' }
    ) { Test-ReaArchiveEntry -Entries @(E f $p) | Should -BeFalse }
    It 'allows names that only look like device names: <p>' -ForEach @(
        @{ p = 'top/console.txt' }, @{ p = 'top/COM0' }, @{ p = 'top/COM10' }, @{ p = 'top/auxiliary' }
    ) { Test-ReaArchiveEntry -Entries @(E f $p) | Should -BeTrue }
    It 'names the entry in the message for a colon' {
        Mock Write-ReaLog {}
        Test-ReaArchiveEntry -Entries @(E f 'a.txt:stream') | Out-Null
        Should -Invoke Write-ReaLog -ParameterFilter { $Level -eq 'ERROR' -and $Message -like '*a.txt:stream*' -and $Message -like '*colon*' }
    }
    It 'refuses a zip and a tar holding an alternate data stream or a device name' {
        $mk = Join-Path $script:T 'mkzip.py'
        foreach ($case in @(@('ads', 'top/a.txt:s'), @('dev', 'top/NUL.txt'), @('dot', 'top/a.'))) {
            $z = Join-Path $script:T ('bad-' + $case[0] + '.zip')
            & $script:Python -I $mk $z $case[1]
            Test-ReaArchiveSafe -Path $z | Should -BeFalse
        }
        $tarScript = Join-Path $script:T 'mktar.py'
        Set-Content -LiteralPath $tarScript -Value @(
            'import sys, tarfile, io',
            'with tarfile.open(sys.argv[1], "w:gz") as t:',
            '    i = tarfile.TarInfo(sys.argv[2]); i.size = 1',
            '    t.addfile(i, io.BytesIO(b"x"))'
        )
        foreach ($case in @(@('ads', 'top/a.txt:s'), @('dev', 'top/con'), @('dot', 'top/a.'))) {
            $tg = Join-Path $script:T ('bad-' + $case[0] + '.tar.gz')
            & $script:Python -I $tarScript $tg $case[1]
            Test-ReaArchiveSafe -Path $tg | Should -BeFalse
        }
    }
    It 'refuses a backslash dotdot' { Test-ReaArchiveEntry -Entries @(E f 'a\..\..\x') | Should -BeFalse }
    It 'refuses a drive letter in the middle of a path' { Test-ReaArchiveEntry -Entries @(E f 'a/C:/x') | Should -BeFalse }
    It 'refuses a UNC path' { Test-ReaArchiveEntry -Entries @(E f '\\server\share\x') | Should -BeFalse }
    It 'refuses an empty path' { Test-ReaArchiveEntry -Entries @(E f '') | Should -BeFalse }
    It 'refuses an entry below a symlink made earlier' { Test-ReaArchiveEntry -Entries @((E l 'd' '.'), (E f 'd/x')) | Should -BeFalse }
    It 'refuses an entry below a symlink made later' { Test-ReaArchiveEntry -Entries @((E f 'd/x'), (E l 'd' '.')) | Should -BeFalse }
    It 'checks every entry, not just the first' { Test-ReaArchiveEntry -Entries @((E f 'ok'), (E f 'ok2'), (E f '../evil')) | Should -BeFalse }
    It 'refuses an empty list' { Test-ReaArchiveEntry -Entries @() | Should -BeFalse }
}

Describe 'Test-ReaPathInside' {
    It 'accepts a path below the root' { Test-ReaPathInside -Path '/d/e/f' -Root '/d/e' -Separator '/' | Should -BeTrue }
    It 'accepts the root itself' { Test-ReaPathInside -Path '/d/e' -Root '/d/e' -Separator '/' | Should -BeTrue }
    It 'refuses a sibling that shares the prefix' { Test-ReaPathInside -Path 'C:\dest-evil\x' -Root 'C:\dest' -Separator '\' | Should -BeFalse }
    It 'refuses a parent' { Test-ReaPathInside -Path '/d' -Root '/d/e' -Separator '/' | Should -BeFalse }
    It 'is case sensitive by default' { Test-ReaPathInside -Path '/D/E/x' -Root '/d/e' -Separator '/' | Should -BeFalse }
    It 'ignores case when asked (Windows rule)' { Test-ReaPathInside -Path 'C:\DEST\x' -Root 'c:\dest' -Separator '\' -IgnoreCase | Should -BeTrue }
}

Describe 'Get-ReaTarExe' {
    # Git for Windows puts a GNU tar ahead of System32 on PATH, and GNU tar reads the C: of `tar -tvzf C:\x.tar.gz` as
    # a remote host ("cannot list archive"). The bsdtar of System32 does not, so the product names it by path.
    BeforeEach {
        $script:SavedSystemRoot = $env:SystemRoot
        $script:SavedTarForCase = $script:TarExe
        $script:TarExe = ''
        $script:FakeRoot = Join-Path $script:T ('sysroot ' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $script:FakeRoot 'System32') -Force | Out-Null
        $env:SystemRoot = $script:FakeRoot
    }
    AfterEach {
        $env:SystemRoot = $script:SavedSystemRoot
        $script:TarExe = $script:SavedTarForCase
    }
    It 'prefers the tar.exe of System32 on Windows when it exists' {
        $sys = Join-Path (Join-Path $script:FakeRoot 'System32') 'tar.exe'
        [System.IO.File]::WriteAllText($sys, 'x')
        Mock Test-ReaWindowsHost { return $true }
        Get-ReaTarExe | Should -Be $sys
    }
    It 'falls back to tar.exe on PATH on Windows when System32 has none' {
        Mock Test-ReaWindowsHost { return $true }
        Get-ReaTarExe | Should -Be 'tar.exe'
    }
    It 'falls back to tar.exe on PATH on Windows when SystemRoot is not set' {
        $env:SystemRoot = ''
        Mock Test-ReaWindowsHost { return $true }
        Get-ReaTarExe | Should -Be 'tar.exe'
    }
    It 'is plain tar elsewhere, whatever SystemRoot holds' {
        [System.IO.File]::WriteAllText((Join-Path (Join-Path $script:FakeRoot 'System32') 'tar.exe'), 'x')
        Mock Test-ReaWindowsHost { return $false }
        Get-ReaTarExe | Should -Be 'tar'
    }
    It 'lets the TarExe test seam win' {
        $script:TarExe = '/x/mytar'
        Mock Test-ReaWindowsHost { return $true }
        Get-ReaTarExe | Should -Be '/x/mytar'
    }
}

Describe 'extraction' {
    It 'on non-Windows hosts (skipped on Windows): extracts a tar.gz with spaces in the names and keeps the execute bit' -Skip:$script:OnWindows {
        # The execute bit is a Unix concept; on Windows tar.exe has nothing to keep.
        $d = Join-Path $script:T 'extract dest'
        Expand-ReaArchive -Path (Join-Path $script:T 'clean.tar.gz') -Destination $d | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $d 'top/file with spaces.txt') | Should -BeTrue
        ((Get-Item -LiteralPath (Join-Path $d 'top/bin/java')).UnixFileMode.ToString()) | Should -Match 'UserExecute'
    }
    It 'extracts a tar.gz' {
        $d = Join-Path $script:T 'extract tar'
        Expand-ReaArchive -Path (Join-Path $script:T 'clean.tar.gz') -Destination $d | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $d 'top/file with spaces.txt') | Should -BeTrue
    }
    It 'extracts a zip: directory entries become directories, files get their parents' {
        $d = Join-Path $script:T 'extract zip'
        Expand-ReaArchive -Path (Join-Path $script:T 'clean.zip') -Destination $d | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $d 'ghidra_12.1.4_PUBLIC') -PathType Container | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $d 'ghidra_12.1.4_PUBLIC/ok.txt') -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $d 'ghidra_12.1.4_PUBLIC/dir with space/inner file.txt') -PathType Leaf | Should -BeTrue
    }
    It 'extracts a zip whose file entries have no directory entry first' {
        $d = Join-Path $script:T 'extract zip exec'
        Expand-ReaArchive -Path (Join-Path $script:T 'exec.zip') -Destination $d | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $d 'ghidra_12.1.4_PUBLIC/support/analyzeHeadless') | Should -BeTrue
    }
    It 'does not overwrite an existing file' {
        $d = Join-Path $script:T 'extract twice'
        Expand-ReaArchive -Path (Join-Path $script:T 'clean.zip') -Destination $d | Should -BeTrue
        Expand-ReaArchive -Path (Join-Path $script:T 'clean.zip') -Destination $d | Should -BeFalse
    }
    It 'refuses a zip entry that resolves outside the destination even if the check was skipped' {
        $d = Join-Path $script:T 'extract evil'
        foreach ($n in @('dotdot', 'win-dotdot', 'win-drive', 'abs')) {
            Expand-ReaArchive -Path (Join-Path $script:T "$n.zip") -Destination $d | Should -BeFalse
        }
        Test-Path -LiteralPath (Join-Path $script:T 'evil.txt') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:T 'C:\evil.txt') | Should -BeFalse
    }
    It 'refuses to extract when the longest target path exceeds the limit, naming the length and -ToolsDir' {
        Mock Write-ReaLog {}
        $saved = $script:MaxPathLength
        try {
            $d = Join-Path $script:T 'extract long'
            $full = [System.IO.Path]::GetFullPath($d)
            $longest = $full.Length + 1 + 'ghidra_12.1.4_PUBLIC/dir with space/inner file.txt'.Length
            $script:MaxPathLength = $longest - 1
            foreach ($n in @('clean.zip', 'clean.tar.gz')) {
                if ($n -eq 'clean.tar.gz') { $script:MaxPathLength = $full.Length + 1 + 'top/dir with space/inner file.txt'.Length - 1 }
                Expand-ReaArchive -Path (Join-Path $script:T $n) -Destination $d | Should -BeFalse
            }
            Should -Invoke Write-ReaLog -ParameterFilter { $Level -eq 'ERROR' -and $Message -match 'characters' -and $Message -like '*-ToolsDir*' -and $Message -like '*C:\rea*' }
            Test-Path -LiteralPath (Join-Path $d 'top') | Should -BeFalse
            # exactly at the limit is accepted
            $script:MaxPathLength = $longest
            Expand-ReaArchive -Path (Join-Path $script:T 'clean.zip') -Destination $d | Should -BeTrue
        } finally {
            $script:MaxPathLength = $saved
        }
    }
    It 'defaults the path limit to 240' { $script:MaxPathLength | Should -Be 240 }
    It 'fails for a missing archive and creates no directory' {
        $d = Join-Path $script:T 'never'
        Expand-ReaArchive -Path (Join-Path $script:T 'nope.tar.gz') -Destination $d | Should -BeFalse
        Test-Path -LiteralPath $d | Should -BeFalse
    }
}

Describe 'Remove-ReaTree' {
    BeforeEach { Mock Write-ReaLog {} }
    It 'removes a tree but never follows a link out of it' {
        $outside = Join-Path $script:T 'tree outside'
        New-Item -ItemType Directory -Path $outside -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $outside 'precious.txt') -Value x
        $tree = Join-Path $script:T 'tree victim'
        New-Item -ItemType Directory -Path (Join-Path $tree 'sub') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $tree 'sub/f.txt') -Value x
        $link = Join-Path $tree 'sub/link'
        if ($script:OnWindows) {
            New-Item -ItemType Junction -Path $link -Target $outside | Out-Null
        } else {
            New-Item -ItemType SymbolicLink -Path $link -Target $outside | Out-Null
        }
        Test-Path -LiteralPath (Join-Path $link 'precious.txt') | Should -BeTrue
        Remove-ReaTree -Path $tree
        Test-Path -LiteralPath $tree | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $outside 'precious.txt') | Should -BeTrue
    }
    It 'removes a link to a file and a dangling link without touching the target' {
        if ($script:OnWindows) { Set-ItResult -Skipped -Because 'file symlinks need a privilege on Windows'; return }
        $tree = Join-Path $script:T 'tree filelinks'
        New-Item -ItemType Directory -Path $tree -Force | Out-Null
        $target = Join-Path $script:T 'tree filetarget.txt'
        Set-Content -LiteralPath $target -Value x
        New-Item -ItemType SymbolicLink -Path (Join-Path $tree 'l1') -Target $target | Out-Null
        New-Item -ItemType SymbolicLink -Path (Join-Path $tree 'l2') -Target (Join-Path $script:T 'does not exist') | Out-Null
        Remove-ReaTree -Path $tree
        Test-Path -LiteralPath $tree | Should -BeFalse
        Test-Path -LiteralPath $target | Should -BeTrue
    }
    It 'removes a link given directly as the path, not its target' {
        if ($script:OnWindows) { Set-ItResult -Skipped -Because 'covered by the junction case above'; return }
        $outside = Join-Path $script:T 'tree outside2'
        New-Item -ItemType Directory -Path $outside -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $outside 'keep') -Value x
        $link = Join-Path $script:T 'tree direct link'
        New-Item -ItemType SymbolicLink -Path $link -Target $outside | Out-Null
        Remove-ReaTree -Path $link
        (Get-Item -LiteralPath $link -Force -ErrorAction SilentlyContinue) | Should -BeNullOrEmpty
        Test-Path -LiteralPath (Join-Path $outside 'keep') | Should -BeTrue
    }
    It 'clears read-only attributes and removes a file path' {
        $tree = Join-Path $script:T 'tree readonly'
        New-Item -ItemType Directory -Path $tree -Force | Out-Null
        $f = Join-Path $tree 'ro.txt'
        Set-Content -LiteralPath $f -Value x
        Set-ItemProperty -LiteralPath $f -Name IsReadOnly -Value $true
        Remove-ReaTree -Path $tree
        Test-Path -LiteralPath $tree | Should -BeFalse
        $single = Join-Path $script:T 'tree single.txt'
        Set-Content -LiteralPath $single -Value x
        Remove-ReaTree -Path $single
        Test-Path -LiteralPath $single | Should -BeFalse
    }
    It 'is quiet about a path that does not exist' {
        { Remove-ReaTree -Path (Join-Path $script:T 'tree nothing') } | Should -Not -Throw
    }
    It 'is what Clear-ReaTempFile, orphan cleanup and JDK pruning use' {
        $outside = Join-Path $script:T 'tree outside3'
        New-Item -ItemType Directory -Path $outside -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $outside 'keep') -Value x
        $mkLink = {
            param($p)
            if ($script:OnWindows) { New-Item -ItemType Junction -Path $p -Target $outside | Out-Null }
            else { New-Item -ItemType SymbolicLink -Path $p -Target $outside | Out-Null }
        }
        $reg = Join-Path $script:T 'tree reg'
        New-Item -ItemType Directory -Path $reg -Force | Out-Null
        & $mkLink (Join-Path $reg 'l')
        Register-ReaTempFile $reg
        Clear-ReaTempFile
        Test-Path -LiteralPath $reg | Should -BeFalse
        $orph = Join-Path $script:T 'tree orph'
        New-Item -ItemType Directory -Path (Join-Path $orph 'jdk-21.0.1+1.tmp.999999') -Force | Out-Null
        & $mkLink (Join-Path $orph 'jdk-21.0.1+1.tmp.999999/l')
        Remove-ReaOrphan -Dir $orph
        Test-Path -LiteralPath (Join-Path $orph 'jdk-21.0.1+1.tmp.999999') | Should -BeFalse
        $tools = Join-Path $script:T 'tree jdks'
        foreach ($n in @('jdk-21.0.1+1', 'jdk-21.0.2+1', 'jdk-21.0.3+1')) {
            New-Item -ItemType Directory -Path (Join-Path $tools $n) -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $tools "$n/.install-complete") -Value x
        }
        & $mkLink (Join-Path $tools 'jdk-21.0.1+1/l')
        $saved = $env:JAVA_HOME
        $env:JAVA_HOME = ''
        try { Remove-ReaOldJdk -ToolsDir $tools } finally { $env:JAVA_HOME = $saved }
        Test-Path -LiteralPath (Join-Path $tools 'jdk-21.0.1+1') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $outside 'keep') | Should -BeTrue
    }
}

Describe 'locks' {
    BeforeEach {
        $script:LockPolls = 1
        Mock Invoke-ReaSleep {}
        Mock Write-ReaLog {}
    }
    AfterEach {
        $script:LockPolls = $script:SavedLockPolls
        Clear-ReaTempFile
        $script:LockHeld.Clear()
    }
    It 'takes a fresh lock and records pid and start time' {
        $d = Join-Path $script:T 'lock fresh'
        Lock-ReaDir -Dir $d
        $owner = Get-Content -LiteralPath (Join-Path $d '.lock/owner') -Raw
        $owner | Should -Match ('^pid=' + $PID + ' started=\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ')
        Unlock-ReaDir -Dir $d
        Test-Path -LiteralPath (Join-Path $d '.lock') | Should -BeFalse
    }
    It 'takes over a lock whose owner is dead, with a WARN, and leaves no .lock.stale' {
        $d = Join-Path $script:T 'lock stale'
        New-Item -ItemType Directory -Path (Join-Path $d '.lock') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $d '.lock/owner') -Value 'pid=999999 started=x'
        Lock-ReaDir -Dir $d
        (Get-Content -LiteralPath (Join-Path $d '.lock/owner') -Raw) | Should -Match ('^pid=' + $PID + ' ')
        @(Get-ChildItem -LiteralPath $d -Force -Filter '.lock.stale.*').Count | Should -Be 0
        Should -Invoke Write-ReaLog -ParameterFilter { $Level -eq 'WARN' -and $Message -like '*999999*' }
        Unlock-ReaDir -Dir $d
    }
    It 'refuses a live lock after LockPolls polls and leaves it in place' {
        $d = Join-Path $script:T 'lock live'
        New-Item -ItemType Directory -Path (Join-Path $d '.lock') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $d '.lock/owner') -Value "pid=$PID started=x"
        { Lock-ReaDir -Dir $d } | Should -Throw
        Test-Path -LiteralPath (Join-Path $d '.lock/owner') | Should -BeTrue
        $script:LockHeld.Contains($d) | Should -BeFalse
    }
    It 'polls every 2 seconds, LockPolls times' {
        $d = Join-Path $script:T 'lock polls'
        New-Item -ItemType Directory -Path (Join-Path $d '.lock') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $d '.lock/owner') -Value "pid=$PID started=x"
        $script:LockPolls = 3
        { Lock-ReaDir -Dir $d } | Should -Throw
        Should -Invoke Invoke-ReaSleep -Exactly 2 -ParameterFilter { $Seconds -eq 2 }
    }
    It 'defaults to 60 polls (120 s)' {
        $script:SavedLockPolls | Should -Be 60
    }
    It 'does not treat a fresh ownerless lock as stale' {
        $d = Join-Path $script:T 'lock ownerless'
        New-Item -ItemType Directory -Path (Join-Path $d '.lock') -Force | Out-Null
        { Lock-ReaDir -Dir $d } | Should -Throw
        Test-Path -LiteralPath (Join-Path $d '.lock') | Should -BeTrue
    }
    It 'takes over an ownerless lock older than a minute' {
        $d = Join-Path $script:T 'lock old ownerless'
        New-Item -ItemType Directory -Path (Join-Path $d '.lock') -Force | Out-Null
        Set-OldAge -Path (Join-Path $d '.lock') -Hours 2
        Lock-ReaDir -Dir $d
        Test-Path -LiteralPath (Join-Path $d '.lock/owner') | Should -BeTrue
        Unlock-ReaDir -Dir $d
    }
    It 'never deletes a lock whose owner changed after the staleness decision' {
        $d = Join-Path $script:T 'lock changed'
        $lock = Join-Path $d '.lock'
        New-Item -ItemType Directory -Path $lock -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $lock 'owner') -Value 'pid=999999 started=x'
        $script:ChangeFile = Join-Path $lock 'owner'
        Mock Test-ReaProcessAlive {
            Set-Content -LiteralPath $script:ChangeFile -Value "pid=$PID started=y"
            return $false
        }
        { Lock-ReaDir -Dir $d } | Should -Throw
        (Get-Content -LiteralPath (Join-Path $lock 'owner') -Raw) | Should -Match ('^pid=' + $PID + ' started=y')
        @(Get-ChildItem -LiteralPath $d -Force -Filter '.lock.stale.*').Count | Should -Be 0
    }
    It 'puts back an ownerless lock that turned out to be fresh when moved aside, and keeps polling' {
        $d = Join-Path $script:T 'lock putback'
        $lock = Join-Path $d '.lock'
        New-Item -ItemType Directory -Path $lock -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $lock 'marker') -Value 'someone else'
        # First look (on .lock): old enough to be stale. Second look (on the moved-aside copy): it is fresh.
        $script:AgeCalls = 0
        Mock Test-ReaOlderThan { $script:AgeCalls++; return ($script:AgeCalls -eq 1) }
        { Lock-ReaDir -Dir $d } | Should -Throw
        $script:AgeCalls | Should -Be 2
        Test-Path -LiteralPath (Join-Path $lock 'marker') | Should -BeTrue
        @(Get-ChildItem -LiteralPath $d -Force -Filter '.lock.stale.*').Count | Should -Be 0
        Should -Invoke Write-ReaLog -Exactly 0 -ParameterFilter { $Level -eq 'WARN' }
    }
    It 'still takes over an ownerless lock that is old on both looks' {
        $d = Join-Path $script:T 'lock ownerless both'
        $lock = Join-Path $d '.lock'
        New-Item -ItemType Directory -Path $lock -Force | Out-Null
        Mock Test-ReaOlderThan { return $true }
        Lock-ReaDir -Dir $d
        Test-Path -LiteralPath (Join-Path $lock 'owner') | Should -BeTrue
        Unlock-ReaDir -Dir $d
    }
    It 'works in a tools directory whose name holds brackets' {
        $d = Join-Path $script:T 'a[1]b'
        Lock-ReaDir -Dir $d
        Test-Path -LiteralPath (Join-Path $d '.lock/owner') | Should -BeTrue
        Unlock-ReaDir -Dir $d
        Test-Path -LiteralPath (Join-Path $d '.lock') | Should -BeFalse
        # a second process (here: refusing) sees the lock, so creation really failed atomically
        New-Item -ItemType Directory -Path (Join-Path $d '.lock') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $d '.lock/owner') -Value "pid=$PID started=x"
        { Lock-ReaDir -Dir $d } | Should -Throw
        Test-Path -LiteralPath (Join-Path $d '.lock/owner') | Should -BeTrue
    }
    It 'is reentrant in one process' {
        $d = Join-Path $script:T 'lock reentrant'
        Lock-ReaDir -Dir $d
        Lock-ReaDir -Dir $d
        Unlock-ReaDir -Dir $d
        Test-Path -LiteralPath (Join-Path $d '.lock') | Should -BeFalse
    }
    It 'creates a missing directory, and a path with a space works' {
        $d = Join-Path $script:T 'lock new/deep dir with space'
        Lock-ReaDir -Dir $d
        Test-Path -LiteralPath (Join-Path $d '.lock') -PathType Container | Should -BeTrue
        Unlock-ReaDir -Dir $d
    }
    It 'leaves a lock alone that this process does not hold' {
        $d = Join-Path $script:T 'lock foreign'
        New-Item -ItemType Directory -Path (Join-Path $d '.lock') -Force | Out-Null
        Unlock-ReaDir -Dir $d
        Test-Path -LiteralPath (Join-Path $d '.lock') | Should -BeTrue
    }
    It 'is released by Clear-ReaTempFile, the Invoke-Main finally' {
        $d = Join-Path $script:T 'lock cleared'
        Lock-ReaDir -Dir $d
        Clear-ReaTempFile
        Test-Path -LiteralPath (Join-Path $d '.lock') | Should -BeFalse
    }
}

Describe 'orphan cleanup' {
    BeforeEach { Mock Write-ReaLog {} }
    It 'removes dead-pid and old directories and keeps the rest' {
        $t = Join-Path $script:T 'orphans'
        foreach ($n in @('agent-profile.tmp.999999', 'clavity-ls.exe.old.999999', "jdk-21.0.1+1.tmp.$PID", "jdk-21 old live.tmp.$PID", 'jdk-21.0.2+1.tmp.abc', 'other.dir')) {
            New-Item -ItemType Directory -Path (Join-Path $t $n) -Force | Out-Null
        }
        Set-OldAge -Path (Join-Path $t "jdk-21 old live.tmp.$PID") -Hours 72
        Remove-ReaOrphan -Dir $t
        Test-Path -LiteralPath (Join-Path $t 'agent-profile.tmp.999999') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $t 'clavity-ls.exe.old.999999') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $t "jdk-21.0.1+1.tmp.$PID") | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $t "jdk-21 old live.tmp.$PID") | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $t 'jdk-21.0.2+1.tmp.abc') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $t 'other.dir') | Should -BeTrue
    }
    It 'never touches a *.tmp.<n> or *.old.<n> name the script does not create (the bin dir is shared with other tools)' {
        $t = Join-Path $script:T 'orphans foreign'
        $mine = 'agent-profile.tmp.999999', 'clavity-ls.exe.old.999999', 'jdk-21.0.1+1.tmp.999999', 'jdk-21.0.1+1.work.tmp.999999', 'ghidra.work.tmp.999999', 'ghidra_12.1.4_PUBLIC.old.999999', 'env.ps1.tmp.999999'
        $foreign = 'vim.tmp.999999', 'notes.old.999999', 'my.backup.old.999999', 'jdk-notes.tmp.999999', 'ghidra-notes.old.999999'
        foreach ($n in @($mine) + @($foreign)) {
            New-Item -ItemType Directory -Path (Join-Path $t $n) -Force | Out-Null
        }
        Remove-ReaOrphan -Dir $t
        foreach ($n in $mine) { Test-Path -LiteralPath (Join-Path $t $n) | Should -BeFalse -Because $n }
        foreach ($n in $foreign) { Test-Path -LiteralPath (Join-Path $t $n) | Should -BeTrue -Because $n }
    }
    It 'is fine on an empty or missing directory' {
        { Remove-ReaOrphan -Dir (Join-Path $script:T 'nothing here') } | Should -Not -Throw
    }
    It 'answers to the plural name from the brief' {
        (Get-Command Remove-ReaOrphans).ResolvedCommand.Name | Should -Be 'Remove-ReaOrphan'
    }
}

Describe 'staging and Complete-ReaInstall' {
    BeforeEach { Mock Write-ReaLog {} }
    AfterEach { Clear-ReaTempFile }
    It 'creates NAME.tmp.PID and registers it for cleanup' {
        $t = Join-Path $script:T 'stage tools'
        $s = New-ReaStaging -Dir $t -Name 'ghidra_12.1.4_PUBLIC'
        $s | Should -Be (Join-Path $t "ghidra_12.1.4_PUBLIC.tmp.$PID")
        Test-Path -LiteralPath $s -PathType Container | Should -BeTrue
        Clear-ReaTempFile
        Test-Path -LiteralPath $s | Should -BeFalse
    }
    It 'replaces an incomplete directory and writes the sentinel inside staging' {
        $t = Join-Path $script:T 'swap tools'
        $final = Join-Path $t 'ghidra_12.1.4_PUBLIC'
        New-Item -ItemType Directory -Path $final -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $final 'incomplete-leftover') -Value x
        $s = New-ReaStaging -Dir $t -Name 'ghidra_12.1.4_PUBLIC'
        Set-Content -LiteralPath (Join-Path $s 'marker') -Value x
        Complete-ReaInstall -Staging $s -Final $final | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $final 'marker') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $final 'incomplete-leftover') | Should -BeFalse
        Test-Path -LiteralPath $s | Should -BeFalse
        Test-Path -LiteralPath "$final.old.$PID" | Should -BeFalse
        (Get-Content -LiteralPath (Join-Path $final '.install-complete') -Raw) | Should -Match ('^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ ' + [regex]::Escape($script:PIN_SCRIPT_VERSION))
        Test-ReaInstallValid -Dir $final -File 'marker' | Should -BeTrue
        Test-ReaInstallValid -Dir $final -File 'marker', 'nope' | Should -BeFalse
    }
    It 'treats a directory without the sentinel as invalid' {
        $d = Join-Path $script:T 'nosent'
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $d 'x') -Value x
        Test-ReaInstallValid -Dir $d -File 'x' | Should -BeFalse
        Test-ReaInstallValid -Dir (Join-Path $script:T 'nosuch') | Should -BeFalse
    }
    It 'installs fresh, into a path with a space' {
        $t = Join-Path $script:T 'fresh tools dir'
        $s = New-ReaStaging -Dir $t -Name 'new thing'
        Set-Content -LiteralPath (Join-Path $s 'f') -Value x
        Complete-ReaInstall -Staging $s -Final (Join-Path $t 'new thing') | Should -BeTrue
        Test-ReaInstallValid -Dir (Join-Path $t 'new thing') -File 'f' | Should -BeTrue
    }
    It 'rolls back when the second move fails' {
        $t = Join-Path $script:T 'rollback tools'
        $final = Join-Path $t 'jdk-21.0.13+9'
        New-Item -ItemType Directory -Path $final -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $final 'old-content') -Value x
        $s = New-ReaStaging -Dir $t -Name 'jdk-21.0.13+9'
        $script:RollbackFinal = $final
        Mock Move-Item { throw 'simulated failure' } -ParameterFilter { $LiteralPath -eq $script:RollbackStaging }
        $script:RollbackStaging = $s
        Complete-ReaInstall -Staging $s -Final $final | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $final 'old-content') | Should -BeTrue
        Test-Path -LiteralPath "$final.old.$PID" | Should -BeFalse
    }
    It 'only warns when the previous install cannot be deleted' {
        $t = Join-Path $script:T 'warn tools'
        $final = Join-Path $t 'f'
        New-Item -ItemType Directory -Path $final -Force | Out-Null
        $s = New-ReaStaging -Dir $t -Name 'f'
        Mock Remove-ReaTree { throw 'simulated failure' } -ParameterFilter { $Path -like '*.old.*' }
        Complete-ReaInstall -Staging $s -Final $final | Should -BeTrue
        Should -Invoke Write-ReaLog -ParameterFilter { $Level -eq 'WARN' -and $Message -like '*previous install*' }
        Test-ReaInstallValid -Dir $final | Should -BeTrue
    }
}

Describe 'JDK pruning' {
    BeforeEach {
        Mock Write-ReaLog {}
        $script:SavedJavaHome = $env:JAVA_HOME
        $env:JAVA_HOME = ''
        $script:Pj = Join-Path $script:T 'jdk tools'
        Remove-Item -LiteralPath $script:Pj -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Path $script:Pj | Out-Null
        function script:New-Jdk {
            param([string[]]$Name)
            foreach ($n in $Name) {
                New-Item -ItemType Directory -Path (Join-Path $script:Pj $n) -Force | Out-Null
                Set-Content -LiteralPath (Join-Path $script:Pj "$n/.install-complete") -Value x
            }
        }
    }
    AfterEach { $env:JAVA_HOME = $script:SavedJavaHome }
    It 'keeps the newest two, orders 21.0.13+10 > 21.0.13+9 > 21.0.9+10 and never touches other directories' {
        New-Jdk 'jdk-21.0.13+9', 'jdk-21.0.9+10', 'jdk-21.0.13+10', 'jdk-17.0.1+1'
        foreach ($n in @('not-a-jdk', 'jdk-21.0.13+9.tmp.1', 'ghidra_12.1.4_PUBLIC', 'jdk-notes', 'jdk-21-scratch', 'jdk-0.0.1-user/sub', 'jdk-mac-old')) {
            New-Item -ItemType Directory -Path (Join-Path $script:Pj $n) -Force | Out-Null
        }
        Set-Content -LiteralPath (Join-Path $script:Pj 'jdk-notes/keep.txt') -Value x
        New-Item -ItemType Directory -Path (Join-Path $script:Pj 'jdk-1.8.0+1/Contents/Home') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:Pj 'jdk-1.8.0+1/Contents/Home/release') -Value x
        Remove-ReaOldJdk -ToolsDir $script:Pj
        Test-Path -LiteralPath (Join-Path $script:Pj 'jdk-notes/keep.txt') | Should -BeTrue
        foreach ($n in @('jdk-21-scratch', 'jdk-0.0.1-user/sub', 'jdk-mac-old', 'not-a-jdk', 'ghidra_12.1.4_PUBLIC', 'jdk-21.0.13+9.tmp.1')) {
            Test-Path -LiteralPath (Join-Path $script:Pj $n) | Should -BeTrue
        }
        Test-Path -LiteralPath (Join-Path $script:Pj 'jdk-21.0.13+10') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:Pj 'jdk-21.0.13+9') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:Pj 'jdk-21.0.9+10') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:Pj 'jdk-17.0.1+1') | Should -BeFalse
        # a JDK without our sentinel is a user's own, whatever its release file says
        Test-Path -LiteralPath (Join-Path $script:Pj 'jdk-1.8.0+1') | Should -BeTrue
    }
    It 'does not accept a JDK release file as the marker: only the sentinel of this script counts' {
        New-Item -ItemType Directory -Path (Join-Path $script:Pj 'jdk-8.0.1+1') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:Pj 'jdk-8.0.1+1/release') -Value x
        New-Item -ItemType Directory -Path (Join-Path $script:Pj 'jdk-11.0.2+9') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:Pj 'jdk-11.0.2+9/release') -Value x
        New-Jdk 'jdk-21.0.1+1', 'jdk-21.0.2+1', 'jdk-21.0.3+1'
        Remove-ReaOldJdk -ToolsDir $script:Pj
        Test-Path -LiteralPath (Join-Path $script:Pj 'jdk-8.0.1+1') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:Pj 'jdk-11.0.2+9') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:Pj 'jdk-21.0.1+1') | Should -BeFalse
    }
    It 'never prunes the JDK in use, even when JAVA_HOME points below it' {
        New-Jdk 'jdk-21.0.9+10', 'jdk-21.0.13+9', 'jdk-21.0.13+10', 'jdk-21.0.20+1'
        $env:JAVA_HOME = Join-Path $script:Pj 'jdk-21.0.9+10/Contents/Home'
        Remove-ReaOldJdk -ToolsDir $script:Pj
        Test-Path -LiteralPath (Join-Path $script:Pj 'jdk-21.0.9+10') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:Pj 'jdk-21.0.13+9') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:Pj 'jdk-21.0.20+1') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:Pj 'jdk-21.0.13+10') | Should -BeTrue
    }
    It 'honours -InUse and a sibling with the same prefix is not the one in use' {
        New-Jdk 'jdk-21.0.1+1', 'jdk-21.0.1+10', 'jdk-21.0.5+1', 'jdk-21.0.6+1'
        Remove-ReaOldJdk -ToolsDir $script:Pj -InUse (Join-Path $script:Pj 'jdk-21.0.1+10')
        Test-Path -LiteralPath (Join-Path $script:Pj 'jdk-21.0.1+10') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:Pj 'jdk-21.0.1+1') | Should -BeFalse
    }
    It 'is fine on a missing directory' {
        { Remove-ReaOldJdk -ToolsDir (Join-Path $script:T 'no such tools') } | Should -Not -Throw
    }
    It 'answers to the plural name from the brief' {
        (Get-Command Remove-ReaOldJdks).ResolvedCommand.Name | Should -Be 'Remove-ReaOldJdk'
    }
}

Describe 'disk and directories' {
    It 'Get-ReaFreeMb returns a number' {
        Get-ReaFreeMb -Path $script:T | Should -BeGreaterThan 0
    }
    It 'Get-ReaFreeMb of a path that does not exist yet uses an existing parent' {
        Get-ReaFreeMb -Path (Join-Path $script:T 'does/not/exist/yet') | Should -BeGreaterThan 0
    }
    It 'accepts a fixed NTFS volume' {
        Mock Get-ReaDriveInfo { [pscustomobject]@{ DriveType = 'Fixed'; DriveFormat = 'NTFS'; AvailableFreeSpace = 1GB } }
        Test-ReaFixedNtfs -Path 'C:\tools' | Should -BeTrue
    }
    It 'refuses <type>/<format> with exit code 1' -ForEach @(
        @{ type = 'Network'; format = 'NTFS' }, @{ type = 'Fixed'; format = 'ReFS' },
        @{ type = 'Fixed'; format = 'FAT32' }, @{ type = 'Removable'; format = 'NTFS' }
    ) {
        Mock Write-ReaLog {}
        Mock Get-ReaDriveInfo { [pscustomobject]@{ DriveType = $type; DriveFormat = $format; AvailableFreeSpace = 1GB } }.GetNewClosure()
        $code = $null
        try { Test-ReaFixedNtfs -Path 'D:\tools' } catch { $code = $_.Exception.Data['ReaCode'] }
        $code | Should -Be 1
    }
    It 'refuses a volume that cannot be read' {
        Mock Write-ReaLog {}
        Mock Get-ReaDriveInfo { throw 'drive not ready' }
        $code = $null
        try { Test-ReaFixedNtfs -Path 'D:\tools' } catch { $code = $_.Exception.Data['ReaCode'] }
        $code | Should -Be 1
    }
    It 'Get-ReaToolsDir prefers -ToolsDir, else LOCALAPPDATA\rea-tools' {
        $saved = $script:Opt
        $savedLocal = $env:LOCALAPPDATA
        try {
            $env:LOCALAPPDATA = '/x/local'
            $script:Opt = [pscustomobject]@{ ToolsDir = ''; BinDir = '' }
            Get-ReaToolsDir | Should -Be (Join-Path '/x/local' 'rea-tools')
            Get-ReaBinDir | Should -Be (Join-Path (Join-Path '/x/local' 'rea-tools') 'bin')
            $script:Opt = [pscustomobject]@{ ToolsDir = '/o t'; BinDir = '/b' }
            Get-ReaToolsDir | Should -Be '/o t'
            Get-ReaBinDir | Should -Be '/b'
        } finally {
            $script:Opt = $saved
            $env:LOCALAPPDATA = $savedLocal
        }
    }
    It 'Windows only (skipped elsewhere): a UNC path reports a network volume' -Skip:(-not $script:OnWindows) {
        (Get-ReaDriveInfo -Path '\\server\share\x').DriveType | Should -Be 'Network'
    }
    It 'Windows only (skipped elsewhere): the temp drive is a readable volume' -Skip:(-not $script:OnWindows) {
        (Get-ReaDriveInfo -Path ([System.IO.Path]::GetTempPath())).DriveFormat | Should -Not -BeNullOrEmpty
    }
}

Describe 'Move-ReaItemRetry' {
    BeforeEach {
        Mock Write-ReaLog {}
        $script:Naps = New-Object System.Collections.ArrayList
        Mock Invoke-ReaSleepMillisecond { [void]$script:Naps.Add($Milliseconds) }
        $script:Src = Join-Path $script:T ('mv src ' + [guid]::NewGuid().ToString('N'))
        $script:Dst = Join-Path $script:T ('mv dst ' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Src | Out-Null
        $script:Failures = 0
        Mock Move-Item {
            if ($script:Failures -gt 0) {
                $script:Failures--
                throw 'Access to the path is denied.'
            }
            [System.IO.Directory]::Move($LiteralPath, $Destination)
        }
    }
    It 'moves at once when nothing holds the directory' {
        Move-ReaItemRetry -Path $script:Src -Destination $script:Dst
        Test-Path -LiteralPath $script:Dst | Should -BeTrue
        $script:Naps.Count | Should -Be 0
    }
    It 'tries again after an access-denied failure and then succeeds' {
        $script:Failures = 3
        Move-ReaItemRetry -Path $script:Src -Destination $script:Dst
        Test-Path -LiteralPath $script:Dst | Should -BeTrue
        $script:Naps.Count | Should -Be 3
        $script:Naps[0] | Should -BeGreaterOrEqual 500
        ($script:Naps | Measure-Object -Maximum).Maximum | Should -BeLessOrEqual 2000
    }
    It 'with -FileOnly retries a file move that keeps failing and throws the last failure' {
        $missing = Join-Path (Join-Path $script:T 'no such dir for mv') 'file.bin'
        $f = Join-Path $script:T ('mv file ' + [guid]::NewGuid().ToString('N'))
        Set-Content -LiteralPath $f -Value x
        { Move-ReaItemRetry -Path $f -Destination $missing -FileOnly -Attempts 3 } | Should -Throw
        $script:Naps.Count | Should -Be 2
    }
    It 'Move-ReaIntoPlace moves a new file through the retrying helper' {
        Mock Move-ReaItemRetry { }
        $f = Join-Path $script:T ('mv into ' + [guid]::NewGuid().ToString('N'))
        Set-Content -LiteralPath $f -Value x
        Move-ReaIntoPlace -Source $f -Destination ($f + '.dest')
        Should -Invoke Move-ReaItemRetry -Times 1 -Exactly -ParameterFilter { $FileOnly }
    }
    It 'throws the last failure after the attempts are used up' {
        $script:Failures = 99
        { Move-ReaItemRetry -Path $script:Src -Destination $script:Dst -Attempts 4 } | Should -Throw '*denied*'
        $script:Naps.Count | Should -Be 3
        Test-Path -LiteralPath $script:Src | Should -BeTrue
    }
}

Describe 'Resolve-ReaLinkedPath' {
    # macOS has relative symlinks directly under the root (/var -> private/var, /tmp -> private/tmp), and the parent
    # of a root-level path is the empty string for Split-Path: the relative target must still be joined to the root.
    It 'resolves a relative symlink that sits directly under the root' {
        $sep = [System.IO.Path]::DirectorySeparatorChar
        $root = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetTempPath())
        $link = $root + 'rea-fake-link'
        Mock Get-Item { [pscustomobject]@{ LinkType = 'SymbolicLink'; Target = @('rea-fake-real') } } -ParameterFilter { $LiteralPath -eq $link }
        Mock Get-Item { $null } -ParameterFilter { $LiteralPath -ne $link }
        Resolve-ReaLinkedPath -Path ($link + $sep + 'child') | Should -Be ($root + 'rea-fake-real' + $sep + 'child')
    }
}
