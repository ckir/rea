# Copyright (c) 2026 Costas Kirgoussios
#
# This software is licensed under the PolyForm Noncommercial License 1.0.0.
# You may obtain a copy of the License at:
# https://polyformproject.org/licenses/noncommercial/1.0.0/

# Tests for the setup.ps1 network layer that need no network: URL allow-list, checksums, JSON queries, the
# Adoptium parser, the redirect walk and the retry loop (against mocked transport functions) and the guarantee
# that a token never reaches the log. They mirror tests/sh/network.sh. The loopback tests live in
# tests/integration/run-win.ps1.

BeforeAll {
    $env:REA_SETUP_NO_MAIN = '1'
    $script:SetupPath = (Resolve-Path (Join-Path $PSScriptRoot '../../setup.ps1')).Path
    . $script:SetupPath
    $script:Fix = (Resolve-Path (Join-Path $PSScriptRoot '../fixtures')).Path
    $script:Tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('rea-net-test-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:Tmp | Out-Null
    $script:SavedHosts = $script:AllowedHosts
    $script:SavedSchemes = $script:AllowedSchemes
    $script:SavedWaits = $script:RetryWaits
}

AfterAll {
    Remove-Item -LiteralPath $script:Tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'setup.ps1 network layer' {
    BeforeEach {
        $script:AllowedHosts = $script:SavedHosts
        $script:AllowedSchemes = $script:SavedSchemes
        $script:RetryWaits = @(0, 0, 0, 0)
        $script:LogFile = $null
        $script:ConsoleLevel = 'ERROR'
        $script:Plan = New-Object System.Collections.ArrayList
        $script:Calls = New-Object System.Collections.ArrayList
        $script:Sleeps = New-Object System.Collections.ArrayList
        $script:SentToken = 'unset'
        $script:Body = $null
        Mock Invoke-ReaSleep { [void]$script:Sleeps.Add($Seconds) }
        Mock Send-ReaHttpAttempt {
            [void]$script:Calls.Add($Url)
            $script:SentToken = $AuthToken
            $step = $script:Plan[$script:Calls.Count - 1]
            if ($null -ne $script:Body -and $step.Status -ge 200 -and $step.Status -lt 300) {
                Copy-Item -LiteralPath $script:Body -Destination $Destination -Force
            } elseif ($step.Status -ge 200 -and $step.Status -lt 300) {
                [System.IO.File]::WriteAllText($Destination, 'body')
            }
            $retryable = $false
            if ($step.ContainsKey('Retryable')) { $retryable = $step.Retryable }
            $ra = $null
            if ($step.ContainsKey('RetryAfter')) { $ra = $step.RetryAfter }
            return [pscustomobject]@{ Status = $step.Status; RetryAfter = $ra; Retryable = $retryable; Error = '' }
        }
    }

    Describe 'Test-ReaUrlAllowed' {
        It 'allows an https URL on an allowed host' {
            Test-ReaUrlAllowed 'https://github.com/x' | Should -BeTrue
        }
        It 'refuses http' {
            Test-ReaUrlAllowed 'http://github.com/x' | Should -BeFalse
        }
        It 'refuses a host outside the list' {
            Test-ReaUrlAllowed 'https://evil.example/x' | Should -BeFalse
        }
        It 'refuses userinfo' {
            Test-ReaUrlAllowed 'https://u@github.com/x' | Should -BeFalse
        }
        It 'refuses the userinfo trick' {
            Test-ReaUrlAllowed 'https://github.com@evil.example/x' | Should -BeFalse
        }
        It 'refuses a backslash' {
            Test-ReaUrlAllowed 'https://github.com\@evil.example/x' | Should -BeFalse
        }
        It 'refuses whitespace' {
            Test-ReaUrlAllowed "https://github.com/a b" | Should -BeFalse
        }
        It 'refuses a URL without a scheme' {
            Test-ReaUrlAllowed 'github.com/x' | Should -BeFalse
        }
        It 'allows an upper-case scheme and host' {
            Test-ReaUrlAllowed 'HTTPS://GitHub.com/x' | Should -BeTrue
            Test-ReaUrlAllowed 'https://GITHUB.com/x' | Should -BeTrue
        }
        It 'allows a port' {
            Test-ReaUrlAllowed 'https://github.com:443/x' | Should -BeTrue
        }
        It 'refuses a trailing-dot host' {
            Test-ReaUrlAllowed 'https://github.com./x' | Should -BeFalse
        }
        It 'refuses a suffix host' {
            Test-ReaUrlAllowed 'https://github.com.evil.example/x' | Should -BeFalse
        }
        It 'refuses an empty URL' {
            Test-ReaUrlAllowed '' | Should -BeFalse
        }
        It 'honours the script-scope overrides' {
            $script:AllowedSchemes = @('https', 'http')
            $script:AllowedHosts = @('127.0.0.1')
            Test-ReaUrlAllowed 'http://127.0.0.1:8080/x' | Should -BeTrue
            Test-ReaUrlAllowed 'https://github.com/x' | Should -BeFalse
        }
        It 'extracts the host without userinfo, port and case' {
            Get-ReaUrlHost 'https://api.github.com/repos/a/b?x=1' | Should -Be 'api.github.com'
            Get-ReaUrlHost 'https://u:p@GitHub.com:8443/x' | Should -Be 'github.com'
        }
    }

    Describe 'Test-ReaUrlPathSafe' {
        It 'accepts a plain path' {
            Test-ReaUrlPathSafe 'https://github.com/a/b/c.tar.gz' | Should -BeTrue
        }
        It 'refuses dot-dot segments, plain or percent-encoded, and backslashes' {
            Test-ReaUrlPathSafe 'https://github.com/a/../b' | Should -BeFalse
            Test-ReaUrlPathSafe 'https://github.com/a/..' | Should -BeFalse
            Test-ReaUrlPathSafe 'https://github.com/a/..?x=1' | Should -BeFalse
            Test-ReaUrlPathSafe 'https://github.com/a/%2e%2e/b' | Should -BeFalse
            Test-ReaUrlPathSafe 'https://github.com/a/%2E./b' | Should -BeFalse
            Test-ReaUrlPathSafe 'https://github.com/a\b' | Should -BeFalse
        }
    }

    Describe 'checksums' {
        It 'reads the first 64-hex token of every sidecar layout' {
            Get-ReaSidecarSha256 (Join-Path $script:Fix 'sidecar-aiprofiles.sha256') | Should -Be 'f8114d71dc4d54a342ed13bc2fbe4b87f755af1de1c4e7ffaa47262a2eb1ac3d'
            Get-ReaSidecarSha256 (Join-Path $script:Fix 'sidecar-clavity.sha256') | Should -Be 'c9de4fe583d8c301b90196f3ecb25568f09b7c7ad832ba917fd951df7b15da1c'
            Get-ReaSidecarSha256 (Join-Path $script:Fix 'sidecar-temurin.sha256.txt') | Should -Be 'd7f5d5cf865a2902b70ff549b97586a7d3f234e016f041ab447ea740c7d66d1c'
        }
        It 'lower-cases an upper-case digest' {
            $f = Join-Path $script:Tmp 'upper'
            [System.IO.File]::WriteAllText($f, "ABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCD`n")
            Get-ReaSidecarSha256 $f | Should -Be 'abcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd'
        }
        It 'returns nothing for a file without a hash' {
            $f = Join-Path $script:Tmp 'junk'
            [System.IO.File]::WriteAllText($f, "not a checksum`n")
            Get-ReaSidecarSha256 $f | Should -BeNullOrEmpty
        }
        It 'refuses a 65-hex token' {
            $f = Join-Path $script:Tmp 'long'
            [System.IO.File]::WriteAllText($f, ('a' * 65) + "`n")
            Get-ReaSidecarSha256 $f | Should -BeNullOrEmpty
        }
        It 'reads a sidecar that starts with a UTF-8 byte order mark' {
            $f = Join-Path $script:Tmp 'bom'
            $enc = New-Object System.Text.UTF8Encoding $true
            [System.IO.File]::WriteAllText($f, ('b' * 64) + "  file.bin`r`n", $enc)
            Get-ReaSidecarSha256 $f | Should -Be ('b' * 64)
        }
        It 'hashes a file to lower-case hex' {
            $f = Join-Path $script:Tmp 'abc'
            [System.IO.File]::WriteAllText($f, 'abc')
            Get-ReaFileSha256 $f | Should -BeExactly 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'
        }
    }

    Describe 'Adoptium parsing' {
        It 'parses the release, size, checksum and sidecar' {
            $j = ConvertFrom-ReaAdoptium -Path (Join-Path $script:Fix 'adoptium-linux-x64.json')
            $j.Release | Should -Be 'jdk-21.0.13+9'
            $j.Bytes | Should -Be '207858352'
            $j.Sha256 | Should -Be 'd7f5d5cf865a2902b70ff549b97586a7d3f234e016f041ab447ea740c7d66d1c'
            $j.SidecarUrl | Should -Be 'https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.13%2B9/OpenJDK21U-jdk_x64_linux_hotspot_21.0.13_9.tar.gz.sha256.txt'
            $j.Url | Should -Match '^https://github\.com/adoptium/temurin21-binaries/releases/download/.*\.tar\.gz$'
        }
        It 'validates release tags' {
            Test-ReaJdkRelease 'jdk-22.0.1+7' | Should -BeFalse
            Test-ReaJdkRelease 'jdk-21.0.13+9' | Should -BeTrue
            Test-ReaJdkRelease 'jdk-21+35' | Should -BeTrue
            Test-ReaJdkRelease 'jdk-21.0.13+9;x' | Should -BeFalse
            Test-ReaJdkRelease "jdk-21.0.13+9`n" | Should -BeFalse
        }
        It 'refuses a changed release name, link path or link host' {
            $text = [System.IO.File]::ReadAllText((Join-Path $script:Fix 'adoptium-linux-x64.json'))
            $cases = @{
                'bad-release' = $text.Replace('"release_name": "jdk-21.0.13+9"', '"release_name": "jdk-22.0.1+7"')
                'bad-path'    = $text.Replace('"link": "https://github.com/adoptium/', '"link": "https://github.com/evil/')
                'bad-host'    = $text.Replace('"link": "https://github.com/', '"link": "https://evil.example/')
            }
            foreach ($name in $cases.Keys) {
                $f = Join-Path $script:Tmp ($name + '.json')
                [System.IO.File]::WriteAllText($f, $cases[$name])
                ConvertFrom-ReaAdoptium -Path $f | Should -BeNullOrEmpty -Because $name
            }
        }
        It 'takes the first element of a two-element array' {
            $text = [System.IO.File]::ReadAllText((Join-Path $script:Fix 'adoptium-linux-x64.json')).Trim()
            $second = $text.Replace('jdk-21.0.13+9"', 'jdk-99.0.0+1"')
            $f = Join-Path $script:Tmp 'two.json'
            [System.IO.File]::WriteAllText($f, '[' + $text.Substring(1, $text.Length - 2) + ',' + $second.Substring(1, $second.Length - 2) + ']')
            (ConvertFrom-ReaAdoptium -Path $f).Release | Should -Be 'jdk-21.0.13+9'
        }
        It 'refuses an empty list and a non-JSON file' {
            $f = Join-Path $script:Tmp 'empty.json'
            [System.IO.File]::WriteAllText($f, "[]`n")
            ConvertFrom-ReaAdoptium -Path $f | Should -BeNullOrEmpty
            $g = Join-Path $script:Tmp 'notjson.json'
            [System.IO.File]::WriteAllText($g, 'not json')
            ConvertFrom-ReaAdoptium -Path $g | Should -BeNullOrEmpty
        }
        It 'refuses dot-dot path segments in the link and the sidecar link' {
            $text = [System.IO.File]::ReadAllText((Join-Path $script:Fix 'adoptium-linux-x64.json'))
            $link = 'temurin21-binaries/releases/download/jdk-21.0.13%2B9/OpenJDK21U-jdk_x64_linux_hotspot_21.0.13_9.tar.gz",'
            $side = 'temurin21-binaries/releases/download/jdk-21.0.13%2B9/OpenJDK21U-jdk_x64_linux_hotspot_21.0.13_9.tar.gz.sha256.txt'
            $cases = @{
                'dotdot'  = $text.Replace($link, 'temurin21-binaries/../../evil/releases/x.tar.gz",')
                'dotdot2' = $text.Replace($link, 'temurin21-binaries/%2e%2e/evil/x.tar.gz",')
                'dotdot3' = $text.Replace($side, 'temurin21-binaries/../x.sha256.txt')
            }
            foreach ($name in $cases.Keys) {
                $cases[$name] | Should -Not -Be $text -Because "$name must differ from the fixture"
                $f = Join-Path $script:Tmp ($name + '.json')
                [System.IO.File]::WriteAllText($f, $cases[$name])
                ConvertFrom-ReaAdoptium -Path $f | Should -BeNullOrEmpty -Because $name
            }
        }
        It 'refuses a checksum that is not 64 hex digits' {
            $text = [System.IO.File]::ReadAllText((Join-Path $script:Fix 'adoptium-linux-x64.json'))
            $f = Join-Path $script:Tmp 'badsum.json'
            [System.IO.File]::WriteAllText($f, $text.Replace('d7f5d5cf865a2902b70ff549b97586a7d3f234e016f041ab447ea740c7d66d1c",', 'd7f5",'))
            ConvertFrom-ReaAdoptium -Path $f | Should -BeNullOrEmpty
        }
    }

    Describe 'Get-ReaRetryAfter' {
        It 'reads leading digits' {
            Get-ReaRetryAfter '10' | Should -Be 10
            Get-ReaRetryAfter ' 7 seconds' | Should -Be 7
        }
        It 'ignores a missing, non-numeric or HTTP-date value' {
            Get-ReaRetryAfter $null | Should -BeNullOrEmpty
            Get-ReaRetryAfter '' | Should -BeNullOrEmpty
            Get-ReaRetryAfter 'abc' | Should -BeNullOrEmpty
            Get-ReaRetryAfter 'Wed, 21 Oct 2026 07:28:00 GMT' | Should -BeNullOrEmpty
        }
        It 'ignores more than six digits without throwing' {
            { Get-ReaRetryAfter '99999999999999999999' } | Should -Not -Throw
            Get-ReaRetryAfter '99999999999999999999' | Should -BeNullOrEmpty
            Get-ReaRetryAfter '1000000' | Should -BeNullOrEmpty
            Get-ReaRetryAfter '999999' | Should -Be 999999
        }
    }

    Describe 'Get-ReaRootMessage' {
        It 'unwraps an AggregateException to its inner message' {
            $inner = New-Object System.IO.IOException 'the real cause'
            Get-ReaRootMessage (New-Object System.AggregateException $inner) | Should -Be 'the real cause'
        }
        It 'returns the message of a plain exception' {
            Get-ReaRootMessage (New-Object System.InvalidOperationException 'plain') | Should -Be 'plain'
        }
    }

    Describe 'Test-ReaStalled' {
        It 'is stalled below 1024 bytes in a window' {
            Test-ReaStalled -WindowBytes 1023 | Should -BeTrue
            Test-ReaStalled -WindowBytes 0 | Should -BeTrue
        }
        It 'is not stalled at 1024 bytes in a window' {
            Test-ReaStalled -WindowBytes 1024 | Should -BeFalse
        }
    }

    Describe 'Invoke-ReaHttpGet retries' {
        It 'returns at once on 200' {
            [void]$script:Plan.Add(@{ Status = 200 })
            Invoke-ReaHttpGet -Url 'https://github.com/a' -Destination (Join-Path $script:Tmp 'out') | Should -BeTrue
            $script:Calls.Count | Should -Be 1
        }
        It 'retries 503 twice and then succeeds' {
            [void]$script:Plan.Add(@{ Status = 503 })
            [void]$script:Plan.Add(@{ Status = 503 })
            [void]$script:Plan.Add(@{ Status = 200 })
            Invoke-ReaHttpGet -Url 'https://github.com/a' -Destination (Join-Path $script:Tmp 'out') | Should -BeTrue
            $script:Calls.Count | Should -Be 3
        }
        It 'retries transport errors that are marked retryable' {
            [void]$script:Plan.Add(@{ Status = 0; Retryable = $true })
            [void]$script:Plan.Add(@{ Status = 0; Retryable = $true })
            [void]$script:Plan.Add(@{ Status = 200 })
            Invoke-ReaHttpGet -Url 'https://github.com/a' -Destination (Join-Path $script:Tmp 'out') | Should -BeTrue
        }
        It 'does not retry a transport error that is not retryable' {
            [void]$script:Plan.Add(@{ Status = 0; Retryable = $false })
            [void]$script:Plan.Add(@{ Status = 200 })
            Invoke-ReaHttpGet -Url 'https://github.com/a' -Destination (Join-Path $script:Tmp 'out') | Should -BeFalse
            $script:Calls.Count | Should -Be 1
        }
        It 'does not retry a 404' {
            [void]$script:Plan.Add(@{ Status = 404 })
            [void]$script:Plan.Add(@{ Status = 200 })
            Invoke-ReaHttpGet -Url 'https://github.com/a' -Destination (Join-Path $script:Tmp 'out') | Should -BeFalse
            $script:Calls.Count | Should -Be 1
        }
        It 'does not retry another 4xx' {
            foreach ($code in 400, 401, 403, 410) {
                $script:Calls.Clear()
                $script:Plan.Clear()
                [void]$script:Plan.Add(@{ Status = $code })
                [void]$script:Plan.Add(@{ Status = 200 })
                Invoke-ReaHttpGet -Url 'https://github.com/a' -Destination (Join-Path $script:Tmp 'out') | Should -BeFalse -Because "status $code"
                $script:Calls.Count | Should -Be 1 -Because "status $code"
            }
        }
        It 'retries 429' {
            [void]$script:Plan.Add(@{ Status = 429 })
            [void]$script:Plan.Add(@{ Status = 200 })
            Invoke-ReaHttpGet -Url 'https://github.com/a' -Destination (Join-Path $script:Tmp 'out') | Should -BeTrue
        }
        It 'gives up after four attempts' {
            foreach ($i in 1..5) { [void]$script:Plan.Add(@{ Status = 500 }) }
            Invoke-ReaHttpGet -Url 'https://github.com/a' -Destination (Join-Path $script:Tmp 'out') | Should -BeFalse
            $script:Calls.Count | Should -Be 4
        }
        It 'uses the waits 2 4 8 16 by default' {
            $script:SavedWaits | Should -Be @(2, 4, 8, 16) -Because 'a fresh dot-source sets the defaults'
        }
        It 'never reaches the transport for a disallowed host' {
            [void]$script:Plan.Add(@{ Status = 200 })
            Invoke-ReaHttpGet -Url 'https://evil.example/a' -Destination (Join-Path $script:Tmp 'out') | Should -BeFalse
            $script:Calls.Count | Should -Be 0
        }
        It 'refuses http by default' {
            Invoke-ReaHttpGet -Url 'http://github.com/a' -Destination (Join-Path $script:Tmp 'out') | Should -BeFalse
            $script:Calls.Count | Should -Be 0
        }
        It 'removes the destination after a failure' {
            $dest = Join-Path $script:Tmp 'partial'
            [System.IO.File]::WriteAllText($dest, 'leftover')
            [void]$script:Plan.Add(@{ Status = 404 })
            Invoke-ReaHttpGet -Url 'https://github.com/a' -Destination $dest | Should -BeFalse
            Test-Path -LiteralPath $dest | Should -BeFalse
        }
    }

    Describe 'Invoke-ReaHttpGet Retry-After' {
        BeforeEach { $script:RetryWaits = @(3, 3) }
        It 'uses the base wait without Retry-After' {
            [void]$script:Plan.Add(@{ Status = 503 })
            [void]$script:Plan.Add(@{ Status = 200 })
            Invoke-ReaHttpGet -Url 'https://github.com/a' -Destination (Join-Path $script:Tmp 'out') | Out-Null
            ($script:Sleeps -join ' ') | Should -Be '3'
        }
        It 'uses the base wait when Retry-After is below it' {
            [void]$script:Plan.Add(@{ Status = 503; RetryAfter = '1' })
            [void]$script:Plan.Add(@{ Status = 200 })
            Invoke-ReaHttpGet -Url 'https://github.com/a' -Destination (Join-Path $script:Tmp 'out') | Out-Null
            ($script:Sleeps -join ' ') | Should -Be '3'
        }
        It 'honours a Retry-After above the base wait' {
            [void]$script:Plan.Add(@{ Status = 503; RetryAfter = '10' })
            [void]$script:Plan.Add(@{ Status = 200 })
            Invoke-ReaHttpGet -Url 'https://github.com/a' -Destination (Join-Path $script:Tmp 'out') | Out-Null
            ($script:Sleeps -join ' ') | Should -Be '10'
        }
        It 'caps Retry-After at 120' {
            [void]$script:Plan.Add(@{ Status = 503; RetryAfter = '500' })
            [void]$script:Plan.Add(@{ Status = 200 })
            Invoke-ReaHttpGet -Url 'https://github.com/a' -Destination (Join-Path $script:Tmp 'out') | Out-Null
            ($script:Sleeps -join ' ') | Should -Be '120'
        }
        It 'falls back to the base wait for an overflowing Retry-After, silently' {
            [void]$script:Plan.Add(@{ Status = 503; RetryAfter = '99999999999999999999' })
            [void]$script:Plan.Add(@{ Status = 200 })
            $out = Invoke-ReaHttpGet -Url 'https://github.com/a' -Destination (Join-Path $script:Tmp 'out') 6>&1 5>&1 4>&1 3>&1 2>&1
            @($out).Count | Should -Be 1 -Because 'only the boolean result is emitted'
            ($script:Sleeps -join ' ') | Should -Be '3'
        }
        It 'falls back to the base wait for a non-numeric Retry-After' {
            [void]$script:Plan.Add(@{ Status = 503; RetryAfter = 'abc' })
            [void]$script:Plan.Add(@{ Status = 200 })
            Invoke-ReaHttpGet -Url 'https://github.com/a' -Destination (Join-Path $script:Tmp 'out') | Out-Null
            ($script:Sleeps -join ' ') | Should -Be '3'
        }
        It 'does not reuse a stale Retry-After on the next attempt' {
            $script:RetryWaits = @(0, 0, 0)
            [void]$script:Plan.Add(@{ Status = 503; RetryAfter = '7' })
            [void]$script:Plan.Add(@{ Status = 0; Retryable = $true })
            [void]$script:Plan.Add(@{ Status = 200 })
            Invoke-ReaHttpGet -Url 'https://github.com/a' -Destination (Join-Path $script:Tmp 'out') | Out-Null
            ($script:Sleeps -join ' ') | Should -Be '7 0'
        }
        It 'does not sleep after the last attempt' {
            $script:RetryWaits = @(1, 1)
            [void]$script:Plan.Add(@{ Status = 500 })
            [void]$script:Plan.Add(@{ Status = 500 })
            Invoke-ReaHttpGet -Url 'https://github.com/a' -Destination (Join-Path $script:Tmp 'out') | Out-Null
            $script:Sleeps.Count | Should -Be 1
        }
    }

    Describe 'GITHUB_TOKEN handling' {
        BeforeEach {
            $script:SavedToken = $env:GITHUB_TOKEN
            $script:LogFile = $null
            $script:LogDir = Join-Path $script:Tmp ('log-' + [guid]::NewGuid().ToString('N'))
            $script:ConsoleLevel = 'ERROR'
            $script:LogPath = Open-ReaLog -Directory $script:LogDir
        }
        AfterEach {
            $env:GITHUB_TOKEN = $script:SavedToken
            $script:LogFile = $null
        }
        It 'sends the token to api.github.com only' {
            $env:GITHUB_TOKEN = 'ghp_UnitTestToken0123456789abcdefghijkl'
            [void]$script:Plan.Add(@{ Status = 200 })
            Invoke-ReaHttpGet -Url 'https://api.github.com/repos/a/b/releases/latest' -Destination (Join-Path $script:Tmp 'out') | Out-Null
            $script:SentToken | Should -Be 'ghp_UnitTestToken0123456789abcdefghijkl'
        }
        It 'withholds the token from other hosts' {
            $env:GITHUB_TOKEN = 'ghp_UnitTestToken0123456789abcdefghijkl'
            [void]$script:Plan.Add(@{ Status = 200 })
            Invoke-ReaHttpGet -Url 'https://github.com/a/b' -Destination (Join-Path $script:Tmp 'out') | Out-Null
            $script:SentToken | Should -BeNullOrEmpty
        }
        It 'sends nothing without a token' {
            $env:GITHUB_TOKEN = $null
            [void]$script:Plan.Add(@{ Status = 200 })
            Invoke-ReaHttpGet -Url 'https://api.github.com/x' -Destination (Join-Path $script:Tmp 'out') | Out-Null
            $script:SentToken | Should -BeNullOrEmpty
        }
        It 'never writes the token to the log, on success or failure, and drops query strings' {
            $tok = 'ghp_UnitTestToken0123456789abcdefghijkl'
            $env:GITHUB_TOKEN = $tok
            [void]$script:Plan.Add(@{ Status = 200 })
            Invoke-ReaHttpGet -Url 'https://api.github.com/repos/a/b/releases/latest' -Destination (Join-Path $script:Tmp 'out') | Out-Null
            $script:Plan.Clear()
            $script:Calls.Clear()
            foreach ($i in 1..4) { [void]$script:Plan.Add(@{ Status = 500 }) }
            Invoke-ReaHttpGet -Url 'https://api.github.com/x' -Destination (Join-Path $script:Tmp 'out') | Out-Null
            $script:Plan.Clear()
            $script:Calls.Clear()
            [void]$script:Plan.Add(@{ Status = 200 })
            Invoke-ReaHttpGet -Url 'https://api.github.com/x?access_token=Zq9' -Destination (Join-Path $script:Tmp 'out') | Out-Null
            $log = [System.IO.File]::ReadAllText($script:LogPath)
            $log | Should -Match 'releases/latest'
            $log.Contains($tok) | Should -BeFalse
            $log.Contains('Zq9') | Should -BeFalse
        }
        It 'ignores an unsafe token with a warning that does not contain it' {
            $bad = @('abc"def', 'abc def', "abc`nheader = `"X-Evil: 1`"", 'abc\def', 'abc$def', 'abc;def')
            foreach ($b in $bad) {
                $env:GITHUB_TOKEN = $b
                $script:Calls.Clear()
                $script:Plan.Clear()
                [void]$script:Plan.Add(@{ Status = 200 })
                Invoke-ReaHttpGet -Url 'https://api.github.com/x' -Destination (Join-Path $script:Tmp 'out') | Out-Null
                $script:SentToken | Should -BeNullOrEmpty -Because "token '$b' must not be sent"
            }
            $log = [System.IO.File]::ReadAllText($script:LogPath)
            $log | Should -Match 'GITHUB_TOKEN ignored: unexpected characters'
            $log.Contains('Evil') | Should -BeFalse
        }
        It 'sends a fine-grained token shape' {
            $env:GITHUB_TOKEN = 'github_pat_11AA-bb.cc_DD'
            [void]$script:Plan.Add(@{ Status = 200 })
            Invoke-ReaHttpGet -Url 'https://api.github.com/x' -Destination (Join-Path $script:Tmp 'out') | Out-Null
            $script:SentToken | Should -Be 'github_pat_11AA-bb.cc_DD'
        }
    }

    Describe 'Resolve-ReaRedirects' {
        BeforeEach {
            $script:AllowedSchemes = @('https', 'http')
            $script:AllowedHosts = @('127.0.0.1')
            $script:Chain = @{}
            $script:Heads = New-Object System.Collections.ArrayList
            Mock Send-ReaHeadRequest {
                [void]$script:Heads.Add("$Method $Url")
                $r = $script:Chain[$Url]
                if ($null -eq $r) { $r = @{ Status = 404 } }
                $status = $r.Status
                if ($Method -eq 'HEAD' -and $r.ContainsKey('HeadStatus')) { $status = $r.HeadStatus }
                $loc = $null
                if ($r.ContainsKey('Location')) { $loc = $r.Location }
                return [pscustomobject]@{ Status = $status; Location = $loc; Error = '' }
            }
        }
        It 'returns the URL itself on 200' {
            $script:Chain['http://127.0.0.1/a'] = @{ Status = 200 }
            $r = Resolve-ReaRedirects -Url 'http://127.0.0.1/a'
            $r.Code | Should -Be 0
            $r.Url | Should -Be 'http://127.0.0.1/a'
        }
        It 'follows a three-hop chain to its end' {
            $script:Chain['http://127.0.0.1/i0'] = @{ Status = 302; Location = 'http://127.0.0.1/i1' }
            $script:Chain['http://127.0.0.1/i1'] = @{ Status = 302; Location = 'http://127.0.0.1/i2' }
            $script:Chain['http://127.0.0.1/i2'] = @{ Status = 200 }
            $r = Resolve-ReaRedirects -Url 'http://127.0.0.1/i0'
            $r.Code | Should -Be 0
            $r.Url | Should -Be 'http://127.0.0.1/i2'
        }
        It 'resolves a relative Location against the current URL' {
            $script:Chain['http://127.0.0.1/dir/a'] = @{ Status = 301; Location = '/b' }
            $script:Chain['http://127.0.0.1/b'] = @{ Status = 200 }
            (Resolve-ReaRedirects -Url 'http://127.0.0.1/dir/a').Url | Should -Be 'http://127.0.0.1/b'
        }
        It 'allows exactly five redirects' {
            foreach ($i in 0..4) { $script:Chain["http://127.0.0.1/k$i"] = @{ Status = 302; Location = "http://127.0.0.1/k$($i + 1)" } }
            $script:Chain['http://127.0.0.1/k5'] = @{ Status = 200 }
            $r = Resolve-ReaRedirects -Url 'http://127.0.0.1/k0'
            $r.Code | Should -Be 0
            $r.Url | Should -Be 'http://127.0.0.1/k5'
        }
        It 'fails with code 2 on the sixth redirect' {
            foreach ($i in 0..5) { $script:Chain["http://127.0.0.1/f$i"] = @{ Status = 302; Location = "http://127.0.0.1/f$($i + 1)" } }
            $script:Chain['http://127.0.0.1/f6'] = @{ Status = 200 }
            (Resolve-ReaRedirects -Url 'http://127.0.0.1/f0').Code | Should -Be 2
        }
        It 'fails with code 1 for a disallowed hop' {
            $script:Chain['http://127.0.0.1/e'] = @{ Status = 302; Location = 'https://evil.example/' }
            $r = Resolve-ReaRedirects -Url 'http://127.0.0.1/e'
            $r.Code | Should -Be 1
            $r.Url | Should -BeNullOrEmpty
        }
        It 'fails with code 1 for a disallowed first URL without any request' {
            (Resolve-ReaRedirects -Url 'https://evil.example/').Code | Should -Be 1
            $script:Heads.Count | Should -Be 0
        }
        It 'fails with code 1 for a Location with a backslash' {
            $script:Chain['http://127.0.0.1/e'] = @{ Status = 302; Location = 'http://127.0.0.1\@evil.example/' }
            (Resolve-ReaRedirects -Url 'http://127.0.0.1/e').Code | Should -Be 1
        }
        It 'fails with code 3 for a non-2xx, non-3xx answer' {
            $script:Chain['http://127.0.0.1/n'] = @{ Status = 404 }
            (Resolve-ReaRedirects -Url 'http://127.0.0.1/n').Code | Should -Be 3
            $script:Chain['http://127.0.0.1/s'] = @{ Status = 500 }
            (Resolve-ReaRedirects -Url 'http://127.0.0.1/s').Code | Should -Be 3
            $script:Chain['http://127.0.0.1/z'] = @{ Status = 0 }
            (Resolve-ReaRedirects -Url 'http://127.0.0.1/z').Code | Should -Be 3
        }
        It 'fails with code 3 for a redirect without a Location' {
            $script:Chain['http://127.0.0.1/n'] = @{ Status = 302 }
            (Resolve-ReaRedirects -Url 'http://127.0.0.1/n').Code | Should -Be 3
        }
        It 'falls back to a ranged GET when HEAD answers 405 or 403' {
            foreach ($code in 405, 403) {
                $script:Heads.Clear()
                $script:Chain['http://127.0.0.1/h'] = @{ Status = 200; HeadStatus = $code }
                $r = Resolve-ReaRedirects -Url 'http://127.0.0.1/h'
                $r.Code | Should -Be 0 -Because "HEAD $code"
                ($script:Heads -join '|') | Should -Be 'HEAD http://127.0.0.1/h|RANGE http://127.0.0.1/h'
            }
        }
        It 'does not fall back on other HEAD failures' {
            $script:Chain['http://127.0.0.1/n'] = @{ Status = 404 }
            Resolve-ReaRedirects -Url 'http://127.0.0.1/n' | Out-Null
            $script:Heads.Count | Should -Be 1
        }
    }

    Describe 'Get-ReaDownload' {
        BeforeEach {
            $script:AllowedSchemes = @('https', 'http')
            $script:AllowedHosts = @('127.0.0.1')
            $script:Dir = Join-Path $script:Tmp ('dl-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $script:Dir | Out-Null
            $script:Sha = 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'
            Mock Resolve-ReaRedirect { return [pscustomobject]@{ Code = 0; Url = $Url } }
            Mock Invoke-ReaHttpGet {
                [System.IO.File]::WriteAllText($Destination, $script:Payload)
                return $true
            }
            $script:Payload = 'abc'
        }
        It 'installs the file for a matching digest, upper case accepted, and leaves no temporary' {
            Get-ReaDownload -Url 'http://127.0.0.1/j' -Destination (Join-Path $script:Dir 'ok') -Sha256 $script:Sha.ToUpperInvariant() | Should -BeTrue
            [System.IO.File]::ReadAllText((Join-Path $script:Dir 'ok')) | Should -Be 'abc'
            @(Get-ChildItem -LiteralPath $script:Dir).Count | Should -Be 1
        }
        It 'removes the temporary and installs nothing for a wrong digest' {
            Get-ReaDownload -Url 'http://127.0.0.1/j' -Destination (Join-Path $script:Dir 'bad') -Sha256 ('0' * 64) | Should -BeFalse
            @(Get-ChildItem -LiteralPath $script:Dir).Count | Should -Be 0
        }
        It 'downloads to DEST.tmp.PID' {
            $script:SeenDest = $null
            Mock Invoke-ReaHttpGet {
                $script:SeenDest = $Destination
                [System.IO.File]::WriteAllText($Destination, 'abc')
                return $true
            }
            Get-ReaDownload -Url 'http://127.0.0.1/j' -Destination (Join-Path $script:Dir 'ok') -Sha256 $script:Sha | Out-Null
            $script:SeenDest | Should -Be ((Join-Path $script:Dir 'ok') + '.tmp.' + $PID)
        }
        It 'leaves an earlier DEST untouched when the digest is wrong' {
            $dest = Join-Path $script:Dir 'keep'
            [System.IO.File]::WriteAllText($dest, 'old')
            Get-ReaDownload -Url 'http://127.0.0.1/j' -Destination $dest -Sha256 ('0' * 64) | Should -BeFalse
            [System.IO.File]::ReadAllText($dest) | Should -Be 'old'
        }
        It 'fails and leaves nothing when the transfer fails after writing a partial file' {
            Mock Invoke-ReaHttpGet {
                [System.IO.File]::WriteAllText($Destination, 'par')
                return $false
            }
            Get-ReaDownload -Url 'http://127.0.0.1/d' -Destination (Join-Path $script:Dir 'file') -Sha256 $script:Sha | Should -BeFalse
            @(Get-ChildItem -LiteralPath $script:Dir).Count | Should -Be 0
        }
        It 'removes the temporary when the transfer is interrupted by an exception' {
            Mock Invoke-ReaHttpGet {
                [System.IO.File]::WriteAllText($Destination, 'par')
                throw 'interrupted'
            }
            { Get-ReaDownload -Url 'http://127.0.0.1/d' -Destination (Join-Path $script:Dir 'file') -Sha256 $script:Sha } | Should -Throw
            @(Get-ChildItem -LiteralPath $script:Dir).Count | Should -Be 0
        }
        It 'fails when the redirects cannot be resolved' {
            Mock Resolve-ReaRedirect { return [pscustomobject]@{ Code = 1; Url = $null } }
            Get-ReaDownload -Url 'http://127.0.0.1/e' -Destination (Join-Path $script:Dir 'file') -Sha256 $script:Sha | Should -BeFalse
            @(Get-ChildItem -LiteralPath $script:Dir).Count | Should -Be 0
        }
    }

    Describe 'temporary file registry' {
        BeforeEach {
            $script:Reg = Join-Path $script:Tmp ('reg-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $script:Reg | Out-Null
            Clear-ReaTempFiles
        }
        It 'removes registered files and directories, including a name with a space, and nothing else' {
            $sub = Join-Path $script:Reg 'dir with space'
            New-Item -ItemType Directory -Path $sub | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $sub 'inner'), 'x')
            [System.IO.File]::WriteAllText((Join-Path $script:Reg 'plain'), 'x')
            [System.IO.File]::WriteAllText((Join-Path $script:Reg 'with space.tmp.1'), 'x')
            [System.IO.File]::WriteAllText((Join-Path $script:Reg 'keep'), 'x')
            Register-ReaTempFile (Join-Path $script:Reg 'plain')
            Register-ReaTempFile (Join-Path $script:Reg 'with space.tmp.1')
            Register-ReaTempFile $sub
            Register-ReaTempFile (Join-Path $script:Reg 'never-created')
            Clear-ReaTempFiles
            @(Get-ChildItem -LiteralPath $script:Reg | ForEach-Object { $_.Name }) | Should -Be @('keep')
        }
        It 'is idempotent and fine when empty' {
            { Clear-ReaTempFiles } | Should -Not -Throw
            { Clear-ReaTempFiles } | Should -Not -Throw
            $script:TempFiles.Count | Should -Be 0
        }
        It 'treats a wildcard character in a name literally' {
            [System.IO.File]::WriteAllText((Join-Path $script:Reg 'a[1].tmp'), 'x')
            [System.IO.File]::WriteAllText((Join-Path $script:Reg 'a1.tmp'), 'x')
            Register-ReaTempFile (Join-Path $script:Reg 'a[1].tmp')
            Clear-ReaTempFiles
            @(Get-ChildItem -LiteralPath $script:Reg | ForEach-Object { $_.Name }) | Should -Be @('a1.tmp')
        }
        It 'removes one path when given -Path and keeps the rest registered' {
            $one = Join-Path $script:Reg 'one'
            $two = Join-Path $script:Reg 'two'
            [System.IO.File]::WriteAllText($one, 'x')
            [System.IO.File]::WriteAllText($two, 'x')
            Register-ReaTempFile $one
            Register-ReaTempFile $two
            Clear-ReaTempFiles -Path $one
            Test-Path -LiteralPath $one | Should -BeFalse
            Test-Path -LiteralPath $two | Should -BeTrue
            Clear-ReaTempFiles
            Test-Path -LiteralPath $two | Should -BeFalse
        }
        It 'is called from the finally block of Invoke-Main' {
            $f = Join-Path $script:Reg 'leftover'
            [System.IO.File]::WriteAllText($f, 'x')
            Register-ReaTempFile $f
            $script:Opt.LogDir = Join-Path $script:Reg 'logs'
            Invoke-Main | Out-Null
            Test-Path -LiteralPath $f | Should -BeFalse
        }
        It 'is called when Invoke-Main fails early' {
            $f = Join-Path $script:Reg 'leftover2'
            [System.IO.File]::WriteAllText($f, 'x')
            Register-ReaTempFile $f
            $script:Opt.LogDir = Join-Path $script:Reg 'logs2'
            $savedName = $script:Opt.ProfileName
            $script:Opt.ProfileName = 'bad name!'
            try {
                Invoke-Main | Should -Be $script:EX_USAGE
            } finally {
                $script:Opt.ProfileName = $savedName
            }
            Test-Path -LiteralPath $f | Should -BeFalse
        }
    }

    Describe 'GitHub helpers' {
        BeforeEach {
            Mock Send-ReaHeadRequest { return [pscustomobject]@{ Status = $script:HeadStatus; Location = $script:HeadLocation; Error = '' } }
            $script:HeadStatus = 302
        }
        It 'reads the latest tag from the redirect' {
            $script:HeadLocation = 'https://github.com/ckir/clavity/releases/tag/clavity-v31'
            Get-ReaGitHubLatestTag -Repo 'ckir/clavity' | Should -Be 'clavity-v31'
        }
        It 'fails when the redirect has no tag' {
            $script:HeadLocation = 'https://github.com/ckir/clavity/releases'
            Get-ReaGitHubLatestTag -Repo 'ckir/clavity' | Should -BeNullOrEmpty
        }
        It 'fails when there is no redirect' {
            $script:HeadLocation = $null
            $script:HeadStatus = 200
            Get-ReaGitHubLatestTag -Repo 'ckir/clavity' | Should -BeNullOrEmpty
        }
        It 'lists the release assets from the API fixture' {
            $script:Body = Join-Path $script:Fix 'github-release-clavity.json'
            [void]$script:Plan.Add(@{ Status = 200 })
            $names = @(Get-ReaGitHubReleaseAssets -Repo 'ckir/clavity')
            ($names -join "`n") | Should -Be (@(
                    'clavity-ls-linux-x64-0.17.0.tar.gz',
                    'clavity-ls-linux-x64-0.17.0.tar.gz.sha256',
                    'clavity-ls-win-x64-0.17.0.tar.gz',
                    'clavity-ls-win-x64-0.17.0.tar.gz.sha256') -join "`n")
            $script:Calls[0] | Should -Match 'repos/ckir/clavity/releases/latest$'
        }
        It 'fails when the assets API fails' {
            [void]$script:Plan.Add(@{ Status = 404 })
            @(Get-ReaGitHubReleaseAssets -Repo 'ckir/clavity').Count | Should -Be 0
        }
        It 'returns nothing, not a null element, when the scrape fails' {
            [void]$script:Plan.Add(@{ Status = 404 })
            @(Get-ReaGitHubReleaseAssetsScrape -Repo 'ckir/clavity' -Tag 'clavity-v31').Count | Should -Be 0
        }
        It 'returns nothing when the API answer is not JSON' {
            $f = Join-Path $script:Tmp 'notjson-assets.json'
            [System.IO.File]::WriteAllText($f, 'not json')
            $script:Body = $f
            [void]$script:Plan.Add(@{ Status = 200 })
            @(Get-ReaGitHubReleaseAssets -Repo 'ckir/clavity').Count | Should -Be 0
        }
        It 'scrapes this repository and tag only' {
            $html = Join-Path $script:Tmp 'expanded.html'
            $lines = @(
                '<a href="/ckir/clavity/releases/download/clavity-v31/clavity-ls-win-x64-0.17.0.tar.gz" rel="nofollow">x</a>',
                '<a href="/ckir/clavity/releases/download/clavity-v31/clavity-ls-win-x64-0.17.0.tar.gz.sha256" rel="nofollow">y</a>',
                '<a href="/ckir/clavity/releases/download/clavity-v30/old.tar.gz">z</a>',
                '<a href="/other/repo/releases/download/clavity-v31/foreign.tar.gz">w</a>')
            [System.IO.File]::WriteAllText($html, ($lines -join "`n"))
            $script:Body = $html
            [void]$script:Plan.Add(@{ Status = 200 })
            $names = @(Get-ReaGitHubReleaseAssetsScrape -Repo 'ckir/clavity' -Tag 'clavity-v31')
            ($names -join "`n") | Should -Be "clavity-ls-win-x64-0.17.0.tar.gz`nclavity-ls-win-x64-0.17.0.tar.gz.sha256"
            $script:Calls[0] | Should -Be 'https://github.com/ckir/clavity/releases/expanded_assets/clavity-v31'
        }
        It 'resolves Adoptium through the API URL and parses the answer' {
            $script:Body = Join-Path $script:Fix 'adoptium-linux-x64.json'
            [void]$script:Plan.Add(@{ Status = 200 })
            $r = Resolve-ReaAdoptium -Os 'linux' -Arch 'x64'
            $r.Code | Should -Be 0
            $r.Jdk.Release | Should -Be 'jdk-21.0.13+9'
            $script:Calls[0] | Should -Be 'https://api.adoptium.net/v3/assets/latest/21/hotspot?architecture=x64&image_type=jdk&os=linux&vendor=eclipse'
        }
        It 'returns code 2 when the API cannot be reached' {
            [void]$script:Plan.Add(@{ Status = 404 })
            (Resolve-ReaAdoptium -Os 'linux' -Arch 'x64').Code | Should -Be 2
        }
        It 'returns code 1 when the answer fails validation' {
            $f = Join-Path $script:Tmp 'resolve-bad.json'
            [System.IO.File]::WriteAllText($f, '[]')
            $script:Body = $f
            [void]$script:Plan.Add(@{ Status = 200 })
            (Resolve-ReaAdoptium -Os 'linux' -Arch 'x64').Code | Should -Be 1
        }
    }
}
