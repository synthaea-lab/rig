<#
.SYNOPSIS
    Checks how runner/run-scenarios.ps1 binds its arguments.

.DESCRIPTION
    rig.py calls the runner as `run-scenarios.ps1 -Machine <m> -Source <s> [scenario ...]`.
    The scenario names that follow must all go to $Names, never to $Root or $State by
    position. This binds the script's own attributes and param block (without running its
    body) the way rig.py calls it. This works under pwsh on any OS.
    `python rig.py check` runs this.
#>
param(
    [string]$Script = (Join-Path (Split-Path -Parent $PSScriptRoot) "runner/run-scenarios.ps1")
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($Script, [ref]$tokens, [ref]$errors)
if ($errors) { throw "$Script does not parse: $($errors[0])" }

$failures = @()
function Assert-True([bool]$Ok, [string]$What) {
    if (-not $Ok) { $script:failures += $What }
}

# The script's attributes and param block, with a body that returns what they bound.
$header = (@($ast.ParamBlock.Attributes | ForEach-Object { $_.Extent.Text }) + $ast.ParamBlock.Extent.Text) -join "`n"
$bind = [scriptblock]::Create($header + "`n" + '[pscustomobject]@{ Machine = $Machine; Source = $Source; Root = $Root; State = $State; Names = @($Names) }')
$bound = & $bind -Machine win11 -Source "rig abc" encoded-powershell bits-job
Assert-True ($bound.Machine -eq "win11" -and $bound.Source -eq "rig abc") "bound -Machine/-Source: $($bound.Machine), $($bound.Source)"
Assert-True ($bound.Root -eq "C:\synthaea" -and $bound.State -eq "C:\synthaea-rig") "a scenario name bound by position: Root $($bound.Root), State $($bound.State)"
Assert-True (($bound.Names -join "|") -ceq "encoded-powershell|bits-job") "Names: $($bound.Names -join ', ')"
$bound = & $bind -Machine win11
Assert-True ($bound.Names.Count -eq 0) "Names without scenarios: $($bound.Names -join ', ')"

if ($failures) { throw "runner/run-scenarios.ps1:`n  " + ($failures -join "`n  ") }
Write-Output "runner/run-scenarios.ps1: binds scenario names to -Names only"
