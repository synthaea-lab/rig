<#
.SYNOPSIS
    Checks the parts of runner/run-scenarios.ps1 that run without a lab guest.

.DESCRIPTION
    The script must set strict mode (Latest) before anything else runs. Its functions,
    defined without running the top level and called under strict mode and "Stop" as the
    runner calls them, must count techniques, format report cells, and run a scenario whose
    errors are data: the exit code comes back, its error records land in the log, and the
    caller's preference stays "Stop". This works under pwsh on any OS.
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

# -- Strict mode, first ------------------------------------------------------------------
$first = $ast.EndBlock.Statements | Select-Object -First 1
Assert-True ($first.Extent.Text -ceq "Set-StrictMode -Version Latest") "first statement is not Set-StrictMode -Version Latest: $($first.Extent.Text)"

# -- Functions ---------------------------------------------------------------------------
$functions = $ast.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] }
. ([scriptblock]::Create(($functions | ForEach-Object { $_.Extent.Text }) -join "`n"))

$work = Join-Path ([System.IO.Path]::GetTempPath()) ("rig-run-scenarios-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $work | Out-Null
try {
    # Get-Counts
    $alerts = Join-Path $work "alerts.ndjson"
    Set-Content -LiteralPath $alerts -Encoding Ascii -Value @(
        '{"technique":"T1059.001","message":"a"}',
        '{"technique":"T1059.001","message":"b"}',
        '{"technique":"RESPONSE-ESCALATE","message":"c"}',
        '{"event":"no technique"}')
    $counts = Get-Counts $alerts
    Assert-True ($counts.Count -eq 2 -and $counts["T1059.001"] -eq 2 -and $counts["RESPONSE-ESCALATE"] -eq 1) "Get-Counts: $(($counts.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', ')"
    $counts = Get-Counts (Join-Path $work "missing.ndjson")
    Assert-True ($counts.Count -eq 0) "Get-Counts of a missing file: $($counts.Count) techniques"

    # Format-Cell
    Assert-True ((Format-Cell "a|b") -ceq 'a\|b') "Format-Cell 'a|b': $(Format-Cell 'a|b')"
    Assert-True ((Format-Cell "") -ceq "-") "Format-Cell '': $(Format-Cell '')"
    Assert-True ((Format-Cell $null) -ceq "-") "Format-Cell null: $(Format-Cell $null)"

    # Invoke-ScenarioScript, with a fake `powershell` that behaves as Windows PowerShell 5.1
    # does with a scenario writing to stderr: an error record, then a non-zero exit code.
    $fakeCalls = New-Object System.Collections.ArrayList
    function powershell {
        [void]$fakeCalls.Add($args -join " ")
        Write-Output "scenario stdout"
        Write-Error "scenario stderr"
        $global:LASTEXITCODE = 3
    }
    $log = Join-Path $work "scenario.log"
    $rc = Invoke-ScenarioScript -Script "C:\s\encoded-powershell.ps1" -Log $log
    Assert-True ($rc -eq 3) "Invoke-ScenarioScript returned $rc, not the script's exit code 3"
    Assert-True (($fakeCalls -join "|") -ceq "-NoProfile -ExecutionPolicy Bypass -File C:\s\encoded-powershell.ps1") "Invoke-ScenarioScript ran: $($fakeCalls -join ' | ')"
    $logText = Get-Content -LiteralPath $log -Raw
    Assert-True ($logText -match "scenario stdout" -and $logText -match "scenario stderr") "the scenario's output and errors are not all in its log: $logText"
    Assert-True ($ErrorActionPreference -eq "Stop") "Invoke-ScenarioScript left the caller's preference at $ErrorActionPreference"
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures) { throw "runner/run-scenarios.ps1:`n  " + ($failures -join "`n  ") }
Write-Output "runner/run-scenarios.ps1: strict, counts, formats and runs a scenario whose errors are data"
