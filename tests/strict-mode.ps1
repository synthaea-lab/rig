<#
.SYNOPSIS
    Checks where the rig's PowerShell scripts set strict mode and the error preference.

.DESCRIPTION
    Every script outside tests/ that runs as a file parses and sets strict mode (Latest)
    before anything else runs, so a misspelled variable or a missing property throws
    instead of reading as $null.
    The files that are dot-sourced (helpers.ps1 into the user's session, RigCommon.ps1 and
    LabAgent.ps1 into the scripts) set neither strict mode nor $ErrorActionPreference at
    their top level: either would change the session that loads them. This works under pwsh
    on any OS. `python rig.py check` runs this.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$rig = Split-Path -Parent $PSScriptRoot

$dotSourced = @("vagrant/hyperv/helpers.ps1", "powershell/RigCommon.ps1", "runner/LabAgent.ps1")
# Every other script outside tests/, so that a new one is held to the rule without a list to
# update.
$runAsFile = @(Get-ChildItem -LiteralPath $rig -Recurse -File -Filter "*.ps1" |
    ForEach-Object { [System.IO.Path]::GetRelativePath($rig, $_.FullName).Replace("\", "/") } |
    Where-Object { -not $_.StartsWith("tests/") -and $dotSourced -notcontains $_ } | Sort-Object)

$failures = @()
function Assert-True([bool]$Ok, [string]$What) {
    if (-not $Ok) { $script:failures += $What }
}

function Get-TopLevelStatements([string]$RelativePath) {
    <# The statements of the script's body (its param block excluded), or a failure when it
       does not parse. #>
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $rig $RelativePath), [ref]$tokens, [ref]$errors)
    if ($errors) { throw "$RelativePath does not parse: $($errors[0])" }
    @($ast.EndBlock.Statements)
}

function Test-SetsStrictMode($Statement) {
    $Statement -is [System.Management.Automation.Language.PipelineAst] -and
        $Statement.PipelineElements[0] -is [System.Management.Automation.Language.CommandAst] -and
        $Statement.PipelineElements[0].GetCommandName() -eq "Set-StrictMode"
}

function Test-SetsErrorPreference($Statement) {
    $Statement -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $Statement.Left.Extent.Text -match '^\$(global:|script:)?ErrorActionPreference$'
}

foreach ($path in $runAsFile) {
    $statements = Get-TopLevelStatements $path
    $first = if ($statements.Count -gt 0) { $statements[0].Extent.Text } else { "(none)" }
    Assert-True ($first -ceq "Set-StrictMode -Version Latest") "$path does not start with Set-StrictMode -Version Latest: $first"
}

foreach ($path in $dotSourced) {
    foreach ($statement in (Get-TopLevelStatements $path)) {
        Assert-True (-not (Test-SetsStrictMode $statement)) "$path sets strict mode in the session that dot-sources it: $($statement.Extent.Text)"
        Assert-True (-not (Test-SetsErrorPreference $statement)) "$path sets `$ErrorActionPreference in the session that dot-sources it: $($statement.Extent.Text)"
    }
}

if ($failures) { throw "strict mode:`n  " + ($failures -join "`n  ") }
Write-Output "rig: $($runAsFile.Count) scripts set strict mode first, $($dotSourced.Count) dot-sourced files leave the session's modes alone"
