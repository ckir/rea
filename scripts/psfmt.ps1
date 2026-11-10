# Copyright (c) 2026 Costas Kirgoussios
#
# This software is licensed under the PolyForm Noncommercial License 1.0.0.
# You may obtain a copy of the License at:
# https://polyformproject.org/licenses/noncommercial/1.0.0/

# PowerShell formatting with PSScriptAnalyzer's Invoke-Formatter, over every *.ps1 outside .clavity,
# tests/.tmp and .git. ADVISORY: spec section 12b makes shfmt the only formatting gate, so nothing in
# `just check` or lefthook calls this.
#
#   pwsh -NoProfile -File scripts/psfmt.ps1 -Check   lists the files Invoke-Formatter would change and
#                                                    always exits 0, even when the formatter cannot run (`just psfmt-check`)
#   pwsh -NoProfile -File scripts/psfmt.ps1          rewrites those files in place (`just psfmt`)
#
# The settings describe the style the repository already uses: four-space indent, opening brace on the same
# line, `} else {` cuddled, `=` aligned in multi-line hashtables. Line endings are LF and files are written
# as UTF-8 without a byte order mark, matching .gitattributes; a file is touched only when its formatted text
# differs from what it holds. scripts/psanalyze.ps1 is reported today: it leaves its two top-level `=` unaligned.
param(
    [switch]$Check
)
$ErrorActionPreference = 'Stop'
try {
    Import-Module PSScriptAnalyzer

    $root = Split-Path -Parent $PSScriptRoot
    $settings = @{
        IncludeRules = @(
            'PSPlaceOpenBrace'
            'PSPlaceCloseBrace'
            'PSUseConsistentIndentation'
            'PSUseConsistentWhitespace'
            'PSAlignAssignmentStatement'
        )
        Rules        = @{
            PSPlaceOpenBrace           = @{
                Enable             = $true
                OnSameLine         = $true
                NewLineAfter       = $true
                IgnoreOneLineBlock = $true
            }
            PSPlaceCloseBrace          = @{
                Enable             = $true
                NewLineAfter       = $false
                IgnoreOneLineBlock = $true
                NoEmptyLineBefore  = $false
            }
            PSUseConsistentIndentation = @{
                Enable              = $true
                Kind                = 'space'
                IndentationSize     = 4
                PipelineIndentation = 'IncreaseIndentationForFirstPipeline'
            }
            PSUseConsistentWhitespace  = @{
                Enable                                  = $true
                CheckInnerBrace                         = $true
                CheckOpenBrace                          = $true
                CheckOpenParen                          = $true
                CheckOperator                           = $true
                CheckPipe                               = $true
                CheckSeparator                          = $true
                CheckParameter                          = $false
                IgnoreAssignmentOperatorInsideHashTable = $true
            }
            PSAlignAssignmentStatement = @{
                Enable         = $true
                CheckHashtable = $true
            }
        }
    }

    $skip = @('.clavity', '.git', (Join-Path 'tests' '.tmp'))
    $files = @(Get-ChildItem -Path $root -Recurse -File -Filter *.ps1 | Where-Object {
            $relative = $_.FullName.Substring($root.Length).TrimStart('\', '/')
            $excluded = $false
            foreach ($prefix in $skip) {
                if ($relative -eq $prefix -or $relative.StartsWith($prefix + [IO.Path]::DirectorySeparatorChar) -or $relative.StartsWith($prefix + '/')) {
                    $excluded = $true
                }
            }
            -not $excluded
        })

    if ($files.Count -eq 0) {
        throw 'psfmt: no *.ps1 files found; an empty scan is not a clean result.'
    }

    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $changed = @()
    foreach ($file in $files) {
        $current = [IO.File]::ReadAllText($file.FullName).Replace("`r`n", "`n")
        $formatted = (Invoke-Formatter -ScriptDefinition $current -Settings $settings).Replace("`r`n", "`n")
        # Invoke-Formatter drops a trailing newline that the source had; keep the file's own ending.
        if ($current.EndsWith("`n") -and -not $formatted.EndsWith("`n")) { $formatted += "`n" }
        if ($formatted -ne $current) {
            $changed += $file.FullName.Substring($root.Length).TrimStart('\', '/')
            if (-not $Check) {
                [IO.File]::WriteAllText($file.FullName, $formatted, $utf8)
            }
        }
    }

    if ($Check) {
        foreach ($name in $changed) { Write-Output "psfmt: would reformat $name" }
        Write-Output "psfmt: $($changed.Count) of $($files.Count) file(s) would change (advisory)"
        exit 0
    }
    Write-Output "psfmt: reformatted $($changed.Count) of $($files.Count) file(s)"
} catch {
    if ($Check) {
        Write-Warning "psfmt: the advisory check could not run: $_"
        exit 0
    }
    throw
}
