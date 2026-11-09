# Copyright (c) 2026 Costas Kirgoussios
#
# This software is licensed under the PolyForm Noncommercial License 1.0.0.
# You may obtain a copy of the License at:
# https://polyformproject.org/licenses/noncommercial/1.0.0/

# Tests for -CheckUpstream: Get-ReaRuntimeSupportedGhidra, Test-ReaUpstream and Invoke-ReaStepCheckUpstream. They
# mirror tests/sh/upstream.sh. The network is replaced at its two lowest seams: Invoke-ReaHttpGet copies a prepared
# file for a URL and Send-ReaHeadRequest answers a prepared status, Location and size for a URL; so the redirect
# walk, the release resolvers, the sidecar reads and the size check all run for real. The rea source file is the
# real GhidraReleasePolicy.ts (tests/fixtures; it is src/ghidra/GhidraReleasePolicy.ts of github.com/morluto/rea
# at the tag rea-agents-6.8.0, unchanged). The loopback run against the fake server is in
# tests/integration/run-win.ps1.

BeforeAll {
    $env:REA_SETUP_NO_MAIN = '1'
    . (Resolve-Path (Join-Path $PSScriptRoot '../../setup.ps1')).Path
    $script:Fix = (Resolve-Path (Join-Path $PSScriptRoot '../fixtures')).Path
    $script:T = Join-Path ([System.IO.Path]::GetTempPath()) ('rea up work ' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:T | Out-Null
    $script:Hex = '0' * 64
    $script:ApAsset = 'agent-profile-x86_64-pc-windows-msvc.zip'
    $script:ClAsset = 'clavity-ls-win-x64-0.17.0.tar.gz'
    $script:ApUrl = "https://github.com/ckir/aiprofiles/releases/latest/download/$script:ApAsset"
    $script:ClUrl = "https://github.com/ckir/clavity/releases/download/clavity-v31/$script:ClAsset"
    $script:JdkBase = 'https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.13%2B9/OpenJDK21U-jdk_x64_windows_hotspot_21.0.13_9.zip'
    $script:AdoptiumUrl = 'https://api.adoptium.net/v3/assets/latest/21/hotspot?architecture=x64&image_type=jdk&os=windows&vendor=eclipse'
    $script:NpmUrl = 'https://registry.npmjs.org/rea-agents/latest'
    $script:ReaUrl = 'https://raw.githubusercontent.com/morluto/rea/rea-agents-6.8.0/src/ghidra/GhidraReleasePolicy.ts'
    $script:GhidraFinal = 'https://release-assets.githubusercontent.com/ghidra.zip'

    $policy = [System.IO.File]::ReadAllText((Join-Path $script:Fix 'GhidraReleasePolicy.ts'))
    function script:Write-Up {
        param([string]$Name, [string]$Text)
        $p = Join-Path $script:T $Name
        [System.IO.File]::WriteAllText($p, $Text)
        return $p
    }
    $script:FPolicy = Write-Up 'policy.ts' $policy
    $script:FPolicyNew = Write-Up 'policy-new.ts' ($policy -replace '"12\.1\.4"', '"12.2.0"')
    $script:FPolicyNone = Write-Up 'policy-none.ts' (($policy -split "`n" | Where-Object { $_ -notmatch 'SUPPORTED_GHIDRA_VERSION = ' }) -join "`n")
    $script:FNpm = Write-Up 'npm.json' '{"name":"rea-agents","version":"6.8.0"}'
    $script:FPolicyMin = Write-Up 'policy-min.ts' ('export const MIN_SUPPORTED_GHIDRA_VERSION = "9.9";' + "`n" + $policy)
    $script:FNpmNone = Write-Up 'npm-none.json' '{"name":"rea-agents"}'
    $script:FApSum = Write-Up 'ap.sha256' "$script:Hex  $script:ApAsset`n"
    $script:FBadSum = Write-Up 'bad.sha256' "no checksum here`n"
    $script:FClSum = Write-Up 'cl.sha256' "$script:Hex *$script:ClAsset`n"
    $script:FClApi = Join-Path $script:Fix 'github-release-clavity.json'
    $script:FClTwo = Write-Up 'cl-two.json' ('{"assets":[{"name":"' + $script:ClAsset + '"},{"name":"clavity-ls-win-x64-0.18.0.tar.gz"}]}')
    $jdkJson = [System.IO.File]::ReadAllText((Join-Path $script:Fix 'adoptium-linux-x64.json')) -replace '_linux_', '_windows_' -replace '\.tar\.gz', '.zip'
    $script:FJdk = Write-Up 'adoptium.json' $jdkJson
    $script:FJdkSum = Write-Up 'jdk.sha256.txt' ('d7f5d5cf865a2902b70ff549b97586a7d3f234e016f041ab447ea740c7d66d1c  OpenJDK21U-jdk_x64_windows_hotspot_21.0.13_9.zip' + "`n")
    $script:FJdkOther = Write-Up 'jdk-other.sha256.txt' "$script:Hex  x`n"

    # A world in which every expectation holds, then Set-UpWorld changes one thing.
    function script:Set-UpWorld {
        param([string]$Case = 'ok', [string]$NpmRaw = '')
        $http = @{}
        $head = @{}
        $head['https://github.com/ckir/aiprofiles/releases/latest'] = @{ Status = 302; Location = 'https://github.com/ckir/aiprofiles/releases/tag/v0.1.2' }
        $head[$script:ApUrl] = @{ Status = 200 }
        $head["$script:ApUrl.sha256"] = @{ Status = 200 }
        $http["$script:ApUrl.sha256"] = $script:FApSum
        $head['https://github.com/ckir/clavity/releases/latest'] = @{ Status = 302; Location = 'https://github.com/ckir/clavity/releases/tag/clavity-v31' }
        $http['https://api.github.com/repos/ckir/clavity/releases/latest'] = $script:FClApi
        $head["$script:ClUrl.sha256"] = @{ Status = 200 }
        $http["$script:ClUrl.sha256"] = $script:FClSum
        $http[$script:AdoptiumUrl] = $script:FJdk
        $head["$script:JdkBase.sha256.txt"] = @{ Status = 200 }
        $http["$script:JdkBase.sha256.txt"] = $script:FJdkSum
        $head[$script:PIN_GHIDRA_URL] = @{ Status = 302; Location = $script:GhidraFinal }
        $head[$script:GhidraFinal] = @{ Status = 200; ContentLength = [int64]569649598 }
        $http[$script:NpmUrl] = $script:FNpm
        $http[$script:ReaUrl] = $script:FPolicy
        switch ($Case) {
            'policy-new' { $http[$script:ReaUrl] = $script:FPolicyNew }
            'policy-404' { $http.Remove($script:ReaUrl) }
            'policy-none' { $http[$script:ReaUrl] = $script:FPolicyNone }
            'npm-raw' { $http[$script:NpmUrl] = (Write-Up ('npm-raw-' + [guid]::NewGuid().ToString('N') + '.json') ('{"version":' + $NpmRaw + '}')) }
            'policy-min' { $http[$script:ReaUrl] = $script:FPolicyMin }
            'tag-dots' { $head['https://github.com/ckir/aiprofiles/releases/latest'] = @{ Status = 302; Location = 'https://github.com/ckir/aiprofiles/releases/tag/..' } }
            'npm-none' { $http[$script:NpmUrl] = $script:FNpmNone }
            'len-bad' { $head[$script:GhidraFinal] = @{ Status = 200; ContentLength = [int64]569649597 } }
            'head405' { $head[$script:GhidraFinal] = @{ Status = 405; RangeStatus = 206; ContentRange = 'bytes 0-0/569649598' } }
            'evil' { $head[$script:PIN_GHIDRA_URL] = @{ Status = 302; Location = 'https://evil.example/ghidra.zip' } }
            'ap-badsum' { $http["$script:ApUrl.sha256"] = $script:FBadSum }
            'cl-two' { $http['https://api.github.com/repos/ckir/clavity/releases/latest'] = $script:FClTwo }
            'ap-gone' { $head.Remove('https://github.com/ckir/aiprofiles/releases/latest') }
            'jdk-diff' { $http["$script:JdkBase.sha256.txt"] = $script:FJdkOther }
        }
        $script:Http = $http
        $script:Head = $head
        $script:Gets = New-Object System.Collections.Generic.List[string]
        $script:Out = New-Object System.Collections.Generic.List[string]
    }
}

AfterAll {
    Remove-Item -LiteralPath $script:T -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'check-upstream' {
    BeforeEach {
        $script:LogFile = $null
        $script:ConsoleLevel = 'ERROR'
        $script:RetryWaits = @(0, 0)
        $script:ToolsDir = Join-Path $script:T 'tools dir'
        $script:BinDir = Join-Path $script:T 'bin dir'
        $script:Tmp = Join-Path $script:T ('tmp ' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Tmp | Out-Null
        Mock Get-ReaPlatform { return @{ Os = 'windows'; Arch = 'x64' } }
        Mock Invoke-ReaSleep { }
        Mock Write-ReaOutput { $script:Out.Add($Text) }
        Mock Invoke-ReaHttpGet {
            $script:Gets.Add($Url)
            if (-not $script:Http.ContainsKey($Url)) { return $false }
            Copy-Item -LiteralPath $script:Http[$Url] -Destination $Destination -Force
            return $true
        }
        Mock Send-ReaHeadRequest {
            $e = $script:Head[$Url]
            if ($null -eq $e) { return [pscustomobject]@{ Status = 404; Location = $null; Error = ''; ContentLength = [int64]-1; ContentRange = $null } }
            $status = $e.Status
            if ($Method -eq 'RANGE' -and $e.ContainsKey('RangeStatus')) { $status = $e.RangeStatus }
            $len = [int64]-1
            if ($e.ContainsKey('ContentLength')) { $len = $e.ContentLength }
            $range = $null
            if ($e.ContainsKey('ContentRange')) { $range = $e.ContentRange }
            $loc = $null
            if ($e.ContainsKey('Location')) { $loc = $e.Location }
            return [pscustomobject]@{ Status = $status; Location = $loc; Error = ''; ContentLength = $len; ContentRange = $range }
        }
    }

    Describe 'Get-ReaRuntimeSupportedGhidra' {
        It 'accepts the real policy file: 6.8.0 supports the pinned 12.1.4' {
            Set-UpWorld
            $r = Get-ReaRuntimeSupportedGhidra
            $r.Ghidra | Should -Be '12.1.4'
            $r.ReaVersion | Should -Be '6.8.0'
            $script:Out[0] | Should -Be 'ok rea_supported_ghidra: rea-agents 6.8.0 supports Ghidra 12.1.4'
        }
        It 'the word boundary: MIN_SUPPORTED_GHIDRA_VERSION is not the constant' {
            Set-UpWorld 'policy-min'
            (Get-ReaRuntimeSupportedGhidra).Ghidra | Should -Be '12.1.4'
        }
        It 'a hostile registry version <raw> fails with 5 and requests no rea-agents raw path' -ForEach @(
            @{ raw = '"1.2.3\nx"' }, @{ raw = '"x\n1.2.3"' }, @{ raw = '"../../x\n1.2.3"' }, @{ raw = '"1.2.3/../../x"' },
            @{ raw = '"1.2"' }, @{ raw = '"1.2.3.4"' }, @{ raw = '"v1.2.3"' }, @{ raw = '" 1.2.3"' }, @{ raw = '"1.2.3 "' },
            @{ raw = '"1..3"' }, @{ raw = '""' }, @{ raw = '123' }, @{ raw = '1.5' }, @{ raw = '"\n1.2.3"' }, @{ raw = '"1.2.3\n"' }
        ) {
            Set-UpWorld 'npm-raw' -NpmRaw $raw
            (Test-ReaUpstream) | Should -Be 5
            @($script:Out | Where-Object { $_ -like 'FAIL rea_supported_ghidra*' }).Count | Should -Be 1
            @($script:Gets | Where-Object { $_ -like 'https://raw.githubusercontent.com/*' }).Count | Should -Be 0
        }
        It 'a release tag that is a dot segment fails agent-profile' {
            Set-UpWorld 'tag-dots'
            (Test-ReaUpstream) | Should -Be 5
            @($script:Out | Where-Object { $_ -like 'FAIL agent-profile*' }).Count | Should -Be 1
        }
        It 'a newer Ghidra is exit 5 with the PIN_GHIDRA_* hint' {
            Set-UpWorld 'policy-new'
            $m = $null
            try { Get-ReaRuntimeSupportedGhidra } catch { $m = $_.Exception }
            $m.Data['ReaCode'] | Should -Be 5
            $m.Message | Should -BeLike 'rea 6.8.0 now supports Ghidra 12.2.0; update PIN_GHIDRA_*'
        }
        It 'a 404 is exit 5 naming the URL' {
            Set-UpWorld 'policy-404'
            $m = $null
            try { Get-ReaRuntimeSupportedGhidra } catch { $m = $_.Exception }
            $m.Data['ReaCode'] | Should -Be 5
            $m.Message | Should -BeLike "*$script:ReaUrl*"
        }
        It 'a missing constant is exit 5 naming the constant and the URL' {
            Set-UpWorld 'policy-none'
            $m = $null
            try { Get-ReaRuntimeSupportedGhidra } catch { $m = $_.Exception }
            $m.Data['ReaCode'] | Should -Be 5
            $m.Message | Should -BeLike '*SUPPORTED_GHIDRA_VERSION*'
            $m.Message | Should -BeLike "*$script:ReaUrl*"
        }
        It 'registry JSON without a version is exit 5 naming the registry URL' {
            Set-UpWorld 'npm-none'
            $m = $null
            try { Get-ReaRuntimeSupportedGhidra } catch { $m = $_.Exception }
            $m.Data['ReaCode'] | Should -Be 5
            $m.Message | Should -BeLike "*$script:NpmUrl*"
        }
    }

    Describe 'Test-ReaUpstream' {
        It 'passes when every expectation holds: five ok lines, no archive, nothing written' {
            Set-UpWorld
            $savedTmp = $env:TMPDIR
            $savedTemp = $env:TEMP
            $env:TMPDIR = $script:Tmp
            $env:TEMP = $script:Tmp
            try {
                (Test-ReaUpstream) | Should -Be 0
            } finally {
                $env:TMPDIR = $savedTmp
                $env:TEMP = $savedTemp
            }
            @($script:Out | Where-Object { $_ -like 'ok *' }).Count | Should -Be 5
            @($script:Out | Where-Object { $_ -like 'FAIL*' }).Count | Should -Be 0
            $script:Out[0] | Should -BeLike "ok agent-profile: v0.1.2 $script:ApAsset*"
            $script:Out[1] | Should -BeLike "ok clavity-ls: clavity-v31 $script:ClAsset*"
            $script:Out[2] | Should -BeLike 'ok adoptium: jdk-21.0.13+9 *'
            $script:Out[3] | Should -BeLike 'ok ghidra: 569649598 bytes*'
            @(Get-ChildItem -LiteralPath $script:Tmp -Force).Count | Should -Be 0
            foreach ($u in @($script:ApUrl, $script:ClUrl, $script:JdkBase, $script:PIN_GHIDRA_URL, $script:GhidraFinal)) {
                $script:Gets | Should -Not -Contain $u
            }
            Test-Path -LiteralPath $script:ToolsDir | Should -BeFalse
            Test-Path -LiteralPath $script:BinDir | Should -BeFalse
        }
        It '<case> fails <name> with 5 and still checks the other four' -ForEach @(
            @{ case = 'policy-new'; name = 'rea_supported_ghidra' }
            @{ case = 'policy-404'; name = 'rea_supported_ghidra' }
            @{ case = 'policy-none'; name = 'rea_supported_ghidra' }
            @{ case = 'npm-none'; name = 'rea_supported_ghidra' }
            @{ case = 'len-bad'; name = 'ghidra' }
            @{ case = 'evil'; name = 'ghidra' }
            @{ case = 'ap-badsum'; name = 'agent-profile' }
            @{ case = 'cl-two'; name = 'clavity-ls' }
            @{ case = 'jdk-diff'; name = 'adoptium' }
            @{ case = 'ap-gone'; name = 'agent-profile' }
        ) {
            Set-UpWorld $case
            (Test-ReaUpstream) | Should -Be 5
            @($script:Out | Where-Object { $_ -like 'FAIL*' }).Count | Should -Be 1
            @($script:Out | Where-Object { $_ -like "FAIL $name*" }).Count | Should -Be 1
            @($script:Out | Where-Object { $_ -like 'ok *' }).Count | Should -Be 4
        }
        It 'a Content-Length mismatch names both numbers' {
            Set-UpWorld 'len-bad'
            Mock Write-ReaLog { $script:Logged = $Message }
            $script:Logged = ''
            (Test-ReaUpstream) | Should -Be 5
            Should -Invoke Write-ReaLog -ParameterFilter { $Message -like '*569649597*' -and $Message -like '*569649598*' }
        }
        It 'a refused HEAD falls back to the ranged GET and its Content-Range total' {
            Set-UpWorld 'head405'
            (Test-ReaUpstream) | Should -Be 0
            $script:Out[3] | Should -BeLike 'ok ghidra: 569649598 bytes*'
        }
    }

    Describe 'Invoke-ReaStepCheckUpstream' {
        It 'returns when all hold and stops with the first failing status otherwise' {
            Set-UpWorld
            { Invoke-ReaStepCheckUpstream } | Should -Not -Throw
            Set-UpWorld 'len-bad'
            $m = $null
            try { Invoke-ReaStepCheckUpstream } catch { $m = $_.Exception }
            $m.Data['ReaCode'] | Should -Be 5
        }
    }

    Describe 'Invoke-Main with -CheckUpstream' {
        It 'runs preflight, prereq and the check only: no plan, no confirmation, no lock' {
            $dir = Join-Path $script:T ('main ' + [guid]::NewGuid().ToString('N'))
            $savedLogDir = $script:Opt.LogDir
            $savedFlag = $script:Opt.CheckUpstream
            $savedLog = $script:LogFile
            try {
                $script:Opt.LogDir = $dir
                $script:Opt.CheckUpstream = $true
                $script:Calls = New-Object System.Collections.Generic.List[string]
                Mock Invoke-ReaStepPreflight { $script:Calls.Add('preflight') }
                Mock Invoke-ReaStepPrereq { $script:Calls.Add('prereq') }
                Mock Invoke-ReaStepCheckUpstream { $script:Calls.Add('check') }
                Mock Invoke-ReaPlanToolsBin { $script:Calls.Add('plan') }
                Mock Invoke-ReaPlanJdk { $script:Calls.Add('plan') }
                Mock Invoke-ReaPlanGhidra { $script:Calls.Add('plan') }
                Mock Invoke-ReaPlanConfirm { $script:Calls.Add('confirm'); return $true }
                Mock Read-ReaConfirm { $script:Calls.Add('read-confirm'); return $true }
                Mock Lock-ReaDir { $script:Calls.Add('lock') }
                Mock Invoke-ReaStepToolsBin { $script:Calls.Add('tools-bin') }
                Mock Invoke-ReaStepLaunch { $script:Calls.Add('launch'); return 7 }
                Invoke-Main | Should -Be 0
                ($script:Calls -join ',') | Should -Be 'preflight,prereq,check'
            } finally {
                $script:Opt.LogDir = $savedLogDir
                $script:Opt.CheckUpstream = $savedFlag
                $script:LogFile = $savedLog
                Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}
