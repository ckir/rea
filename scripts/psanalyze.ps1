# Copyright (c) 2026 Costas Kirgoussios
#
# This software is licensed under the PolyForm Noncommercial License 1.0.0.
# You may obtain a copy of the License at:
# https://polyformproject.org/licenses/noncommercial/1.0.0/

# Runs PSScriptAnalyzer over every *.ps1 in scripts/, tests/ and the repository root (non-recursive, so an
# absent setup.ps1 is tolerated) and exits 1 on any finding at Warning or above, or when no file was found.
# PSUseCompatibleSyntax targets Windows PowerShell 5.1.
$ErrorActionPreference = 'Stop'
Import-Module PSScriptAnalyzer -RequiredVersion 1.25.0

$root = Split-Path -Parent $PSScriptRoot
$settings = @{
    Rules = @{
        PSUseCompatibleSyntax = @{ Enable = $true; TargetVersions = @('5.1') }
    }
    Severity = @('Error', 'Warning')
    IncludeDefaultRules = $true
}

$files = @()
foreach ($dir in @('scripts', 'tests')) {
    $path = Join-Path $root $dir
    if (Test-Path -LiteralPath $path) {
        $files += @(Get-ChildItem -Path $path -Recurse -File -Filter *.ps1)
    }
}
$files += @(Get-ChildItem -Path $root -File -Filter *.ps1)

if ($files.Count -eq 0) {
    Write-Error 'psanalyze: no *.ps1 files found; an empty scan is not a clean result.'
    exit 1
}

$failed = $false
foreach ($file in $files) {
    $findings = @(Invoke-ScriptAnalyzer -Path $file.FullName -Settings $settings)
    if ($findings.Count -gt 0) {
        $failed = $true
        $findings | Format-List | Out-String | Write-Output
    }
}

if ($failed) { exit 1 }
Write-Output "psanalyze: $($files.Count) file(s) clean"
