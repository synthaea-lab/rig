<#
.SYNOPSIS
    Prints what run-scenarios.ps1 reads from each given sidecar, in the shape
    of `run-scenarios.sh --expectations`, so the two parsers can be compared.

.DESCRIPTION
    Loads only the Get-Expectations function of run-scenarios.ps1 (the rest of
    the script needs a lab guest) and runs it on each sidecar given, with an empty
    catalog so the `expect` column fallback never applies: this compares the
    sidecar parsers alone. Prints one `<sidecar>|technique|min_count|tolerance`
    line per expected detection. `python rig.py check` runs this:

        pwsh -File tests/print-ps-expectations.ps1 <sidecar.yaml> ...
#>
param(
    [Parameter(Mandatory, ValueFromRemainingArguments = $true)][string[]]$Sidecar
)
$ErrorActionPreference = "Stop"
$Script = Join-Path (Split-Path -Parent $PSScriptRoot) "runner" "run-scenarios.ps1"

$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($Script, [ref]$tokens, [ref]$errors)
if ($errors) { throw "$Script does not parse: $($errors[0])" }
$definition = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq "Get-Expectations"
}, $true)
if (-not $definition) { throw "$Script defines no Get-Expectations" }
. ([scriptblock]::Create($definition.Extent.Text))

# The script-scope names Get-Expectations reads.
$rows = @{}
foreach ($path in $Sidecar) {
    $file = Get-Item -LiteralPath $path
    $scenDir = $file.DirectoryName
    # Assigned first, as the runner does: Get-Expectations returns its list wrapped in one.
    $expect = Get-Expectations $file.BaseName
    foreach ($e in $expect) {
        Write-Output "$path|$($e.Technique)|$($e.Min)|$($e.Tol)"
    }
}
