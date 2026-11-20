<#
.SYNOPSIS
    Checks that every PowerShell script of the rig parses.

.DESCRIPTION
    Every .ps1 under the rig, tests/ included, so that a new script is held to it without a
    list to update. A script that does not parse fails only when it runs, which for the
    provisioning scripts is inside a guest. Reports every script that does not parse, not
    only the first. This works under pwsh on any OS. `python rig.py check` runs this.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$rig = Split-Path -Parent $PSScriptRoot

$scripts = @(Get-ChildItem -LiteralPath $rig -Recurse -File -Filter "*.ps1" |
    ForEach-Object { [System.IO.Path]::GetRelativePath($rig, $_.FullName).Replace("\", "/") } | Sort-Object)

$failures = @()
foreach ($script in $scripts) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile((Join-Path $rig $script), [ref]$tokens, [ref]$errors)
    if ($errors) { $failures += "$script does not parse: $($errors[0])" }
}

if ($failures) { throw "PowerShell scripts:`n  " + ($failures -join "`n  ") }
Write-Output "rig: $($scripts.Count) PowerShell scripts parse"
