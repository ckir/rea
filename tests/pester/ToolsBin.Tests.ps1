# Copyright (c) 2026 Costas Kirgoussios
#
# This software is licensed under the PolyForm Noncommercial License 1.0.0.
# You may obtain a copy of the License at:
# https://polyformproject.org/licenses/noncommercial/1.0.0/

# Tests for the setup.ps1 step tools-bin; they mirror tests/sh/tools-bin.sh. The network is replaced at three
# seams: the latest-tag and asset-list functions, the redirect walk and the HTTP GET (which copies a prepared file
# to the destination), so Get-ReaDownload, the checksum, the archive checks and the extraction all run for real.
# The version of a tool is read through $script:VersionRunner, which returns the text of the stub file, so the
# cases run on Linux pwsh too. Every directory has a space in its name.

BeforeDiscovery {
    $script:OnWindows = ([System.IO.Path]::DirectorySeparatorChar -eq '\')
}

BeforeAll {
    $env:REA_SETUP_NO_MAIN = '1'
    . (Resolve-Path (Join-Path $PSScriptRoot '../../setup.ps1')).Path
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
    $script:T = Join-Path ([System.IO.Path]::GetTempPath()) ('rea toolsbin work ' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:T | Out-Null
    $script:SavedPath = $env:PATH
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    function script:Get-Code {
        param([scriptblock]$Block)
        try { & $Block } catch { return $_.Exception.Data['ReaCode'] }
        return 0
    }
    function script:Set-Executable {
        param([string]$Path)
        if (-not $script:OnWindows) { & chmod 755 $Path }
    }
    # A script file named Name holding Text, executable on Unix.
    function script:New-Stub {
        param([string]$Dir, [string]$Name, [string]$Text)
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        $p = Join-Path $Dir $Name
        [System.IO.File]::WriteAllText($p, $Text)
        Set-Executable $p
        return $p
    }
    # Packs the named files of Src into Out (a .zip with ZipFile, anything else a tar.gz with tar).
    function script:New-Pack {
        param([string]$Src, [string]$Out, [string[]]$File)
        if ($Out.EndsWith('.zip')) {
            $z = Join-Path $script:T ('z' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $z | Out-Null
            foreach ($f in $File) { Copy-Item -LiteralPath (Join-Path $Src $f) -Destination $z }
            [System.IO.Compression.ZipFile]::CreateFromDirectory($z, $Out)
        } else {
            & (Get-ReaTarExe) -czf $Out -C $Src @File
            if ($LASTEXITCODE -ne 0) { throw "tar failed for $Out" }
        }
    }
    # Writes Out.sha256 for Out in the layout Layout ('gnu': hash, two spaces, name; 'star': hash, space, star, name).
    function script:New-Sidecar {
        param([string]$Out, [string]$Layout, [string]$Hash = '')
        if (-not $Hash) { $Hash = Get-ReaFileSha256 $Out }
        $name = Split-Path -Leaf $Out
        if ($Layout -eq 'star') { $line = "$Hash *$name" } else { $line = "$Hash  $name" }
        [System.IO.File]::WriteAllText($Out + '.sha256', $line + "`n")
    }

    $script:Src = Join-Path $script:T 'src dir'
    $script:Pk = Join-Path $script:T 'packs dir'
    New-Item -ItemType Directory -Path $script:Src, $script:Pk | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $script:Src 'agent-profile.exe'), 'agent-profile 0.1.2')
    [System.IO.File]::WriteAllText((Join-Path $script:Src 'extra.txt'), 'extra')
    foreach ($v in @('0.17.0', '0.18.0')) {
        [System.IO.File]::WriteAllText((Join-Path $script:Src "clavity-ls.exe"), "clavity-ls $v+built")
        New-Pack -Src $script:Src -Out (Join-Path $script:Pk "clavity-ls-win-x64-$v.tar.gz") -File @('clavity-ls.exe')
        New-Sidecar -Out (Join-Path $script:Pk "clavity-ls-win-x64-$v.tar.gz") -Layout star
    }
    [System.IO.File]::WriteAllText((Join-Path $script:Src 'clavity-ls.exe'), 'clavity-ls 0.17.0+built')
    New-Pack -Src $script:Src -Out (Join-Path $script:Pk 'agent-profile-x86_64-pc-windows-msvc.zip') -File @('agent-profile.exe')
    New-Sidecar -Out (Join-Path $script:Pk 'agent-profile-x86_64-pc-windows-msvc.zip') -Layout gnu
    New-Pack -Src $script:Src -Out (Join-Path $script:Pk 'two.tar.gz') -File @('agent-profile.exe', 'extra.txt')
    New-Sidecar -Out (Join-Path $script:Pk 'two.tar.gz') -Layout gnu
    New-Pack -Src $script:Src -Out (Join-Path $script:Pk 'other.tar.gz') -File @('extra.txt')
    New-Sidecar -Out (Join-Path $script:Pk 'other.tar.gz') -Layout gnu

    $script:ApUrl = 'https://github.com/ckir/aiprofiles/releases/latest/download/agent-profile-x86_64-pc-windows-msvc.zip'
    function script:Get-ClUrl {
        param([string]$Version)
        return "https://github.com/ckir/clavity/releases/download/clavity-v31/clavity-ls-win-x64-$Version.tar.gz"
    }
    function script:Get-AllAsset {
        param([string]$Version)
        $n = @()
        foreach ($rid in @('linux-x64', 'osx-arm64', 'osx-x64', 'win-x64')) {
            $n += "clavity-ls-$rid-$Version.tar.gz"
            $n += "clavity-ls-$rid-$Version.tar.gz.sha256"
        }
        return $n
    }
    function script:Get-Served {
        $m = @{}
        $m[$script:ApUrl] = Join-Path $script:Pk 'agent-profile-x86_64-pc-windows-msvc.zip'
        $m[$script:ApUrl + '.sha256'] = Join-Path $script:Pk 'agent-profile-x86_64-pc-windows-msvc.zip.sha256'
        foreach ($v in @('0.17.0', '0.18.0')) {
            $m[(Get-ClUrl $v)] = Join-Path $script:Pk "clavity-ls-win-x64-$v.tar.gz"
            $m[(Get-ClUrl $v) + '.sha256'] = Join-Path $script:Pk "clavity-ls-win-x64-$v.tar.gz.sha256"
        }
        foreach ($f in @('two.tar.gz', 'other.tar.gz')) {
            $m["https://github.com/x/dl/$f"] = Join-Path $script:Pk $f
            $m["https://github.com/x/dl/$f.sha256"] = Join-Path $script:Pk "$f.sha256"
        }
        return $m
    }
    function script:Get-ListingName {
        param([string]$Dir)
        if (-not (Test-Path -LiteralPath $Dir)) { return @() }
        return @(Get-ChildItem -LiteralPath $Dir -Force | ForEach-Object { $_.Name })
    }
}

AfterAll {
    $env:PATH = $script:SavedPath
    Remove-Item -LiteralPath $script:T -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'tools-bin' {
    BeforeEach {
        $script:Case = Join-Path $script:T ('case ' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Case | Out-Null
        $script:ToolsDir = Join-Path $script:Case 'tools dir'
        $script:BinDir = Join-Path $script:Case 'bin dir'
        $script:LogFile = Join-Path $script:Case 'run.log'
        $script:ConsoleLevel = 'ERROR'
        $script:Summary = @{}
        $script:Opt.DryRun = $false
        $script:Opt.CheckUpstream = $false
        $script:Served = Get-Served
        $script:ClVersion = '0.17.0'
        $script:ApiNames = $null
        $script:ScrapeNames = @()
        $script:VersionRunner = { param($Path) [pscustomobject]@{ ExitCode = 0; Stdout = [System.IO.File]::ReadAllText($Path); Stderr = '' } }
        $env:PATH = $script:SavedPath
        Mock Get-ReaPlatform { return @{ Os = 'windows'; Arch = 'x64' } }
        Mock Get-ReaGitHubLatestTag { if ($Repo -eq 'ckir/aiprofiles') { return 'v0.1.2' } return 'clavity-v31' }
        Mock Get-ReaGitHubReleaseAsset { if ($null -eq $script:ApiNames) { return Get-AllAsset $script:ClVersion } return $script:ApiNames }
        Mock Get-ReaGitHubReleaseAssetsScrape { return $script:ScrapeNames }
        Mock Resolve-ReaRedirect { return [pscustomobject]@{ Code = 0; Url = $Url } }
        Mock Invoke-ReaHttpGet {
            if (-not $script:Served.ContainsKey($Url)) { return $false }
            Copy-Item -LiteralPath $script:Served[$Url] -Destination $Destination
            return $true
        }
        Mock Resolve-ReaExecutable { return $null }
    }
    AfterEach {
        $env:PATH = $script:SavedPath
        $script:LogFile = $null
        $script:VersionRunner = $null
        $script:Opt.DryRun = $false
        $script:Opt.CheckUpstream = $false
        foreach ($d in @($script:LockHeld)) { Unlock-ReaDir -Dir $d }
        Clear-ReaTempFile
    }

    Context 'asset maps' {
        It 'maps agent-profile for the four supported platforms' {
            $r = Resolve-ReaAgentProfile -Os linux -Arch x64
            $r.Asset | Should -Be 'agent-profile-x86_64-unknown-linux-gnu.tar.gz'
            $r.Tag | Should -Be 'v0.1.2'
            $r.Version | Should -Be '0.1.2'
            $r.Url | Should -Be 'https://github.com/ckir/aiprofiles/releases/latest/download/agent-profile-x86_64-unknown-linux-gnu.tar.gz'
            $r.SidecarUrl | Should -Be ($r.Url + '.sha256')
            (Resolve-ReaAgentProfile -Os mac -Arch x64).Asset | Should -Be 'agent-profile-x86_64-apple-darwin.tar.gz'
            (Resolve-ReaAgentProfile -Os mac -Arch aarch64).Asset | Should -Be 'agent-profile-aarch64-apple-darwin.tar.gz'
            (Resolve-ReaAgentProfile -Os windows -Arch x64).Asset | Should -Be 'agent-profile-x86_64-pc-windows-msvc.zip'
        }
        It 'maps clavity-ls for the four supported platforms' {
            (Resolve-ReaClavityLs -Os linux -Arch x64).Asset | Should -Be 'clavity-ls-linux-x64-0.17.0.tar.gz'
            (Resolve-ReaClavityLs -Os mac -Arch aarch64).Asset | Should -Be 'clavity-ls-osx-arm64-0.17.0.tar.gz'
            (Resolve-ReaClavityLs -Os mac -Arch x64).Asset | Should -Be 'clavity-ls-osx-x64-0.17.0.tar.gz'
            $r = Resolve-ReaClavityLs -Os windows -Arch x64
            $r.Asset | Should -Be 'clavity-ls-win-x64-0.17.0.tar.gz'
            $r.Version | Should -Be '0.17.0'
            $r.Tag | Should -Be 'clavity-v31'
            $r.Url | Should -Be 'https://github.com/ckir/clavity/releases/download/clavity-v31/clavity-ls-win-x64-0.17.0.tar.gz'
            $r.SidecarUrl | Should -Be ($r.Url + '.sha256')
        }
        It 'returns nothing for linux aarch64 and windows aarch64 without touching the network' {
            Resolve-ReaAgentProfile -Os linux -Arch aarch64 | Should -BeNullOrEmpty
            Resolve-ReaAgentProfile -Os windows -Arch aarch64 | Should -BeNullOrEmpty
            Resolve-ReaClavityLs -Os linux -Arch aarch64 | Should -BeNullOrEmpty
            Resolve-ReaClavityLs -Os windows -Arch aarch64 | Should -BeNullOrEmpty
            Should -Invoke Get-ReaGitHubLatestTag -Times 0 -Exactly
        }
        It 'matches exactly one asset in the real release listing and none for osx-x64' {
            $json = Get-Content -LiteralPath (Join-Path $script:Root 'tests/fixtures/github-release-clavity.json') -Raw | ConvertFrom-Json
            $script:ApiNames = @($json.assets | ForEach-Object { [string]$_.name })
            (Resolve-ReaClavityLs -Os windows -Arch x64).Asset | Should -Be 'clavity-ls-win-x64-0.17.0.tar.gz'
            (Resolve-ReaClavityLs -Os linux -Arch x64).Asset | Should -Be 'clavity-ls-linux-x64-0.17.0.tar.gz'
            Get-Code { Resolve-ReaClavityLs -Os mac -Arch x64 } | Should -Be 5
        }
        It 'refuses two matching assets with exit 5' {
            $script:ApiNames = @('clavity-ls-win-x64-0.17.0.tar.gz', 'clavity-ls-win-x64-0.18.0.tar.gz')
            Get-Code { Resolve-ReaClavityLs -Os windows -Arch x64 } | Should -Be 5
            Get-Content -LiteralPath $script:LogFile -Raw | Should -Match 'found 2'
        }
        It 'refuses an asset name that only contains the pattern' {
            $script:ApiNames = @('xclavity-ls-win-x64-0.17.0.tar.gz', 'clavity-ls-win-x64-0.17.0.tar.gz.sha256', 'clavity-ls-win-x64-0.17.0.zip')
            Get-Code { Resolve-ReaClavityLs -Os windows -Arch x64 } | Should -Be 5
        }
        It 'reads the release page when the API gives nothing' {
            $script:ApiNames = @()
            $script:ScrapeNames = @('clavity-ls-win-x64-0.17.0.tar.gz', 'clavity-ls-win-x64-0.17.0.tar.gz.sha256')
            (Resolve-ReaClavityLs -Os windows -Arch x64).Asset | Should -Be 'clavity-ls-win-x64-0.17.0.tar.gz'
            Should -Invoke Get-ReaGitHubReleaseAssetsScrape -Times 1 -Exactly -ParameterFilter { $Repo -eq 'ckir/clavity' -and $Tag -eq 'clavity-v31' }
            Get-Content -LiteralPath $script:LogFile -Raw | Should -Match 'WARN.*GitHub API did not answer'
        }
        It 'stops with exit 1 when the latest tag cannot be found' {
            Mock Get-ReaGitHubLatestTag { return $null }
            Get-Code { Resolve-ReaAgentProfile -Os windows -Arch x64 } | Should -Be 1
            Get-Code { Resolve-ReaClavityLs -Os windows -Arch x64 } | Should -Be 1
        }
    }

    Context 'Install-ReaSingleBinary' {
        It 'installs the one file of a tar.gz' {
            $dest = Join-Path $script:BinDir 'clavity-ls.exe'
            Install-ReaSingleBinary -Name clavity-ls -Url (Get-ClUrl '0.17.0') -SidecarUrl ((Get-ClUrl '0.17.0') + '.sha256') -ExpectedFile 'clavity-ls.exe' -DestPath $dest | Should -Be 'installed'
            [System.IO.File]::ReadAllText($dest) | Should -Be 'clavity-ls 0.17.0+built'
            Get-ListingName $script:BinDir | Should -Be @('clavity-ls.exe')
        }
        It 'installs the one file of a zip' {
            $dest = Join-Path $script:BinDir 'agent-profile.exe'
            Install-ReaSingleBinary -Name agent-profile -Url $script:ApUrl -SidecarUrl ($script:ApUrl + '.sha256') -ExpectedFile 'agent-profile.exe' -DestPath $dest | Should -Be 'installed'
            [System.IO.File]::ReadAllText($dest) | Should -Be 'agent-profile 0.1.2'
            Get-ListingName $script:BinDir | Should -Be @('agent-profile.exe')
        }
        It 'refuses an archive with a second entry' {
            $dest = Join-Path $script:BinDir 'agent-profile.exe'
            Get-Code { Install-ReaSingleBinary -Name agent-profile -Url 'https://github.com/x/dl/two.tar.gz' -SidecarUrl 'https://github.com/x/dl/two.tar.gz.sha256' -ExpectedFile 'agent-profile.exe' -DestPath $dest } | Should -Be 5
            Get-ListingName $script:BinDir | Should -BeNullOrEmpty
            Get-Content -LiteralPath $script:LogFile -Raw | Should -Match 'exactly one file'
        }
        It 'refuses a file that is not the expected name' {
            $dest = Join-Path $script:BinDir 'agent-profile.exe'
            Get-Code { Install-ReaSingleBinary -Name agent-profile -Url 'https://github.com/x/dl/other.tar.gz' -SidecarUrl 'https://github.com/x/dl/other.tar.gz.sha256' -ExpectedFile 'agent-profile.exe' -DestPath $dest } | Should -Be 5
            Get-ListingName $script:BinDir | Should -BeNullOrEmpty
        }
        It 'refuses a download whose checksum differs from the sidecar' {
            $bad = Join-Path $script:Case 'bad.sha256'
            [System.IO.File]::WriteAllText($bad, ('0' * 64) + "  two.tar.gz`n")
            $script:Served['https://github.com/x/dl/two.tar.gz.sha256'] = $bad
            $dest = Join-Path $script:BinDir 'agent-profile.exe'
            Get-Code { Install-ReaSingleBinary -Name agent-profile -Url 'https://github.com/x/dl/two.tar.gz' -SidecarUrl 'https://github.com/x/dl/two.tar.gz.sha256' -ExpectedFile 'agent-profile.exe' -DestPath $dest } | Should -Be 5
            Get-ListingName $script:BinDir | Should -BeNullOrEmpty
            Get-Content -LiteralPath $script:LogFile -Raw | Should -Match 'checksum mismatch'
        }
        It 'refuses a sidecar with no SHA-256' {
            $bad = Join-Path $script:Case 'empty.sha256'
            [System.IO.File]::WriteAllText($bad, "not a checksum`n")
            $script:Served[$script:ApUrl + '.sha256'] = $bad
            $dest = Join-Path $script:BinDir 'agent-profile.exe'
            Get-Code { Install-ReaSingleBinary -Name agent-profile -Url $script:ApUrl -SidecarUrl ($script:ApUrl + '.sha256') -ExpectedFile 'agent-profile.exe' -DestPath $dest } | Should -Be 5
            Get-ListingName $script:BinDir | Should -BeNullOrEmpty
        }
        It 'keeps the installed file and removes the staged one when the move finds it in use' {
            $dest = Join-Path $script:BinDir 'clavity-ls.exe'
            New-Item -ItemType Directory -Path $script:BinDir | Out-Null
            [System.IO.File]::WriteAllText($dest, 'old')
            Mock Move-ReaIntoPlace { throw (New-Object System.IO.IOException 'The process cannot access the file because it is being used by another process.') }
            Install-ReaSingleBinary -Name clavity-ls -Url (Get-ClUrl '0.17.0') -SidecarUrl ((Get-ClUrl '0.17.0') + '.sha256') -ExpectedFile 'clavity-ls.exe' -DestPath $dest | Should -Be 'kept'
            [System.IO.File]::ReadAllText($dest) | Should -Be 'old'
            Get-ListingName $script:BinDir | Should -Be @('clavity-ls.exe')
            Get-Content -LiteralPath $script:LogFile -Raw | Should -Match 'WARN.*close running sessions to update clavity-ls'
        }
        It 'stops with exit 1 on a move failure that is not an in-use error' {
            $dest = Join-Path $script:BinDir 'clavity-ls.exe'
            Mock Move-ReaIntoPlace { throw (New-Object System.InvalidOperationException 'other') }
            Get-Code { Install-ReaSingleBinary -Name clavity-ls -Url (Get-ClUrl '0.17.0') -SidecarUrl ((Get-ClUrl '0.17.0') + '.sha256') -ExpectedFile 'clavity-ls.exe' -DestPath $dest } | Should -Be 1
            Get-ListingName $script:BinDir | Should -BeNullOrEmpty
        }
        It 'Move-ReaIntoPlace replaces an existing file and creates a missing one' {
            $a = Join-Path $script:Case 'a.txt'
            $b = Join-Path $script:Case 'b.txt'
            [System.IO.File]::WriteAllText($a, 'new')
            Move-ReaIntoPlace -Source $a -Destination $b
            [System.IO.File]::ReadAllText($b) | Should -Be 'new'
            [System.IO.File]::WriteAllText($a, 'newer')
            Move-ReaIntoPlace -Source $a -Destination $b
            [System.IO.File]::ReadAllText($b) | Should -Be 'newer'
            Test-Path -LiteralPath $a | Should -BeFalse
        }
    }

    Context 'Get-ReaInstalledVersion' {
        BeforeEach {
            New-Item -ItemType Directory -Path $script:BinDir | Out-Null
        }
        It 'returns an empty string for an empty bin dir' {
            $v = Get-ReaInstalledVersion -Name 'clavity-ls'
            $v | Should -BeOfType [string]
            $v | Should -BeExactly ''
        }
        It 'returns the version without build metadata' {
            New-Stub -Dir $script:BinDir -Name 'clavity-ls.exe' -Text 'clavity-ls 0.17.0+abc' | Out-Null
            Get-ReaInstalledVersion -Name 'clavity-ls' | Should -BeExactly '0.17.0'
        }
        It 'returns an empty string when the tool exits non-zero' {
            New-Stub -Dir $script:BinDir -Name 'clavity-ls.exe' -Text 'clavity-ls 0.17.0' | Out-Null
            $script:VersionRunner = { param($Path) [pscustomobject]@{ ExitCode = 1; Stdout = "$Path 0.17.0"; Stderr = '' } }
            Get-ReaInstalledVersion -Name 'clavity-ls' | Should -BeExactly ''
        }
        It 'returns an empty string when the runner throws' {
            New-Stub -Dir $script:BinDir -Name 'clavity-ls.exe' -Text 'clavity-ls 0.17.0' | Out-Null
            $script:VersionRunner = { param($Path) throw "cannot run $Path" }
            Get-ReaInstalledVersion -Name 'clavity-ls' | Should -BeExactly ''
        }
        It 'returns an empty string when the output has no X.Y.Z' {
            New-Stub -Dir $script:BinDir -Name 'clavity-ls.exe' -Text 'no version here' | Out-Null
            Get-ReaInstalledVersion -Name 'clavity-ls' | Should -BeExactly ''
        }
        It 'does not look on PATH' {
            $other = Join-Path $script:Case 'elsewhere dir'
            New-Stub -Dir $other -Name 'clavity-ls.exe' -Text 'clavity-ls 3.3.3' | Out-Null
            $env:PATH = $other + [System.IO.Path]::PathSeparator + $script:SavedPath
            Get-ReaInstalledVersion -Name 'clavity-ls' | Should -BeExactly ''
        }
        It 'runs the copy in the bin dir' {
            $p = New-Stub -Dir $script:BinDir -Name 'clavity-ls.exe' -Text 'clavity-ls 0.17.0'
            $script:Ran = ''
            $script:VersionRunner = { param($Path) $script:Ran = $Path; [pscustomobject]@{ ExitCode = 0; Stdout = 'clavity-ls 0.17.0'; Stderr = '' } }
            Get-ReaInstalledVersion -Name 'clavity-ls' | Should -BeExactly '0.17.0'
            $script:Ran | Should -Be $p
        }
    }

    Context 'Invoke-ReaStepToolsBin' {
        It 'installs both tools into an empty bin dir, prepends it to PATH and holds the lock' {
            Invoke-ReaStepToolsBin
            $log = Get-Content -LiteralPath $script:LogFile -Raw
            $log | Should -Match 'agent-profile: install \(installed: none, latest: 0\.1\.2\)'
            $log | Should -Match 'clavity-ls: install \(installed: none, latest: 0\.17\.0\)'
            $log | Should -Match 'DEBUG.*no agent-profile in '
            [System.IO.File]::ReadAllText((Join-Path $script:BinDir 'agent-profile.exe')) | Should -Be 'agent-profile 0.1.2'
            [System.IO.File]::ReadAllText((Join-Path $script:BinDir 'clavity-ls.exe')) | Should -Be 'clavity-ls 0.17.0+built'
            Get-ListingName $script:BinDir | Should -Be @('agent-profile.exe', 'clavity-ls.exe')
            $env:PATH.StartsWith($script:BinDir + [System.IO.Path]::PathSeparator) | Should -BeTrue
            $script:Summary['tools_bin'] | Should -Match 'agent-profile 0\.1\.2: install'
            Test-Path -LiteralPath (Join-Path $script:ToolsDir '.lock') | Should -BeTrue
            Unlock-ReaToolsDir
            Test-Path -LiteralPath (Join-Path $script:ToolsDir '.lock') | Should -BeFalse
        }
        It 'skips when both are current, does not downgrade, and updates an older one' {
            New-Stub -Dir $script:BinDir -Name 'agent-profile.exe' -Text 'agent-profile 0.1.2' | Out-Null
            New-Stub -Dir $script:BinDir -Name 'clavity-ls.exe' -Text 'clavity-ls 0.17.0+abc' | Out-Null
            Invoke-ReaStepToolsBin
            $log = Get-Content -LiteralPath $script:LogFile -Raw
            $log | Should -Match 'agent-profile: skip \(already latest\) \(installed: 0\.1\.2'
            $log | Should -Match 'clavity-ls: skip \(already latest\) \(installed: 0\.17\.0'
            $log | Should -Not -Match 'WARN'
            [System.IO.File]::ReadAllText((Join-Path $script:BinDir 'clavity-ls.exe')) | Should -Be 'clavity-ls 0.17.0+abc'
            Unlock-ReaToolsDir

            New-Stub -Dir $script:BinDir -Name 'clavity-ls.exe' -Text 'clavity-ls 0.99.0' | Out-Null
            Invoke-ReaStepToolsBin
            Get-Content -LiteralPath $script:LogFile -Raw | Should -Match 'clavity-ls: skip \(already latest\) \(installed: 0\.99\.0'
            [System.IO.File]::ReadAllText((Join-Path $script:BinDir 'clavity-ls.exe')) | Should -Be 'clavity-ls 0.99.0'
            Unlock-ReaToolsDir

            New-Stub -Dir $script:BinDir -Name 'clavity-ls.exe' -Text 'clavity-ls 0.16.0' | Out-Null
            Invoke-ReaStepToolsBin
            Get-Content -LiteralPath $script:LogFile -Raw | Should -Match 'clavity-ls: update \(installed: 0\.16\.0, latest: 0\.17\.0\)'
            [System.IO.File]::ReadAllText((Join-Path $script:BinDir 'clavity-ls.exe')) | Should -Be 'clavity-ls 0.17.0+built'
        }
        It 'updates when the release is newer' {
            $script:ClVersion = '0.18.0'
            New-Stub -Dir $script:BinDir -Name 'agent-profile.exe' -Text 'agent-profile 0.1.2' | Out-Null
            New-Stub -Dir $script:BinDir -Name 'clavity-ls.exe' -Text 'clavity-ls 0.17.0+abc' | Out-Null
            Invoke-ReaStepToolsBin
            $log = Get-Content -LiteralPath $script:LogFile -Raw
            $log | Should -Match 'agent-profile: skip \(already latest\)'
            $log | Should -Match 'clavity-ls: update \(installed: 0\.17\.0, latest: 0\.18\.0\)'
            [System.IO.File]::ReadAllText((Join-Path $script:BinDir 'clavity-ls.exe')) | Should -Be 'clavity-ls 0.18.0+built'
        }
        It 'warns about a copy earlier on PATH and compares the bin dir copy' {
            New-Stub -Dir $script:BinDir -Name 'agent-profile.exe' -Text 'agent-profile 0.1.2' | Out-Null
            New-Stub -Dir $script:BinDir -Name 'clavity-ls.exe' -Text 'clavity-ls 0.17.0+abc' | Out-Null
            $other = Join-Path $script:Case 'shadow dir'
            $shadow = New-Stub -Dir $other -Name 'clavity-ls.exe' -Text 'clavity-ls 0.1.0'
            Mock Resolve-ReaExecutable { if ($Name -eq 'clavity-ls') { return $shadow } return (Join-Path $script:BinDir 'agent-profile.exe') }
            Invoke-ReaStepToolsBin
            $log = Get-Content -LiteralPath $script:LogFile -Raw
            $log | Should -Match ('WARN.*another clavity-ls at .*shadow dir.*clavity-ls\.exe precedes the one this script manages')
            $log | Should -Match 'clavity-ls: skip \(already latest\) \(installed: 0\.17\.0'
            $log | Should -Not -Match 'another agent-profile'
        }
        It 'falls back to the release page when the API gives nothing' {
            $script:ApiNames = @()
            $script:ScrapeNames = Get-AllAsset '0.17.0'
            Invoke-ReaStepToolsBin
            Should -Invoke Get-ReaGitHubReleaseAssetsScrape -Times 1 -Exactly -ParameterFilter { $Tag -eq 'clavity-v31' }
            [System.IO.File]::ReadAllText((Join-Path $script:BinDir 'clavity-ls.exe')) | Should -Be 'clavity-ls 0.17.0+built'
        }
        It 'exits 5 on two matching assets and on none' {
            $script:ApiNames = @('clavity-ls-win-x64-0.17.0.tar.gz', 'clavity-ls-win-x64-0.18.0.tar.gz')
            Get-Code { Invoke-ReaStepToolsBin } | Should -Be 5
            $script:ApiNames = @('clavity-ls-linux-x64-0.17.0.tar.gz')
            Get-Code { Invoke-ReaStepToolsBin } | Should -Be 5
            Get-Content -LiteralPath $script:LogFile -Raw | Should -Match 'found 0'
        }
        It 'installs nothing and exits 5 when the sidecar hash does not match' {
            $bad = Join-Path $script:Case 'bad.sha256'
            [System.IO.File]::WriteAllText($bad, ('0' * 64) + "  agent-profile-x86_64-pc-windows-msvc.zip`n")
            $script:Served[$script:ApUrl + '.sha256'] = $bad
            Get-Code { Invoke-ReaStepToolsBin } | Should -Be 5
            Get-ListingName $script:BinDir | Should -BeNullOrEmpty
        }
        It 'exits 3 for an unsupported architecture' {
            Mock Get-ReaPlatform { return @{ Os = 'windows'; Arch = 'aarch64' } }
            Get-Code { Invoke-ReaStepToolsBin } | Should -Be 3
            Get-ListingName $script:BinDir | Should -BeNullOrEmpty
        }
        It 'reports but installs nothing on a dry run, and takes no lock' {
            $script:Opt.DryRun = $true
            Invoke-ReaStepToolsBin
            Get-ListingName $script:BinDir | Should -BeNullOrEmpty
            Get-Content -LiteralPath $script:LogFile -Raw | Should -Match 'clavity-ls: install \(installed: none'
            Test-Path -LiteralPath (Join-Path $script:ToolsDir '.lock') | Should -BeFalse
        }
        It 'keeps an installed tool that is in use and says so' {
            New-Stub -Dir $script:BinDir -Name 'agent-profile.exe' -Text 'agent-profile 0.1.2' | Out-Null
            New-Stub -Dir $script:BinDir -Name 'clavity-ls.exe' -Text 'clavity-ls 0.16.0' | Out-Null
            Mock Move-ReaIntoPlace { throw (New-Object System.IO.IOException 'in use') }
            Invoke-ReaStepToolsBin
            Get-Content -LiteralPath $script:LogFile -Raw | Should -Match 'WARN.*close running sessions to update clavity-ls'
            [System.IO.File]::ReadAllText((Join-Path $script:BinDir 'clavity-ls.exe')) | Should -Be 'clavity-ls 0.16.0'
            $script:Summary['tools_bin'] | Should -Match 'clavity-ls 0\.17\.0: kept 0\.16\.0 \(in use\)'
        }
    }
}
