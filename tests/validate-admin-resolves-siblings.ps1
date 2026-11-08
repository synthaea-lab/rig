<#
.SYNOPSIS
    Checks that runner/windows/validate-admin.ps1 finds and loads the scenarios
    sibling's common.ps1 under a given root, without running any phase.

.DESCRIPTION
    Runs the script's own top-level statements, from the start through the
    first dot-sourced file, with $Root set to -Root. Those statements resolve
    the sibling paths and dot-source common.ps1; nothing Windows-only runs
    before them, so this works under pwsh on any OS. Fails if $CommonScript
    does not exist or if the helpers the phases call are not defined after
    loading it. `python rig.py check` runs this.
#>
param(
    [Parameter(Mandatory)][string]$Root,
    [string]$Script = (Join-Path (Split-Path -Parent $PSScriptRoot) "runner/windows/validate-admin.ps1")
)
$ErrorActionPreference = "Stop"

$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($Script, [ref]$tokens, [ref]$errors)
if ($errors) { throw "$Script does not parse: $($errors[0])" }

$isDotSource = {
    param($statement)
    $statement -is [System.Management.Automation.Language.PipelineAst] -and
        $statement.PipelineElements[0] -is [System.Management.Automation.Language.CommandAst] -and
        $statement.PipelineElements[0].InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Dot
}
$statements = $ast.EndBlock.Statements
$lastIndex = -1
for ($i = 0; $i -lt $statements.Count; $i++) {
    if (& $isDotSource $statements[$i]) { $lastIndex = $i; break }
}
if ($lastIndex -lt 0) { throw "$Script dot-sources nothing; expected it to load common.ps1" }
$prologue = [scriptblock]::Create(($statements[0..$lastIndex] | ForEach-Object { $_.Extent.Text }) -join "`n")

$CommonScript = $null
try {
    . $prologue
} catch {
    throw "runner/windows/validate-admin.ps1 could not resolve and load common.ps1 under ${Root}: $_"
}

if (-not $CommonScript -or -not (Test-Path -LiteralPath $CommonScript)) {
    throw "runner/windows/validate-admin.ps1 resolved common.ps1 to '$CommonScript', which does not exist under $Root"
}
$missing = @("Invoke-Native", "Invoke-NativeCleanup", "Get-FarFutureDate") |
    Where-Object { -not (Get-Command $_ -CommandType Function -ErrorAction SilentlyContinue) }
if ($missing) { throw "common.ps1 loaded from $CommonScript does not define: $($missing -join ', ')" }
Write-Output "runner/windows/validate-admin.ps1: loads $CommonScript"
