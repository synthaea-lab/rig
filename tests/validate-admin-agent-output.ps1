<#
.SYNOPSIS
    Checks that runner/windows/validate-admin.ps1 reads the agent's alerts and events under
    strict mode, where a JSON field an alert or an event leaves out throws when read.

.DESCRIPTION
    Defines the script's Get-Alerts and Get-EventsNaming without running its top level, with
    the scenarios sibling's common.ps1 (its Get-OptionalProperty) loaded from -Root, and
    calls them under strict mode (Latest) and "Stop" on an alerts and an events file whose
    records leave out technique, path or meta. Each comes back with every field, $null for
    what the record left out. This works under pwsh on any OS. `python rig.py check` runs
    this.
#>
param(
    [Parameter(Mandatory)][string]$Root,
    [string]$Script = (Join-Path (Split-Path -Parent $PSScriptRoot) "runner/windows/validate-admin.ps1")
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($Script, [ref]$tokens, [ref]$errors)
if ($errors) { throw "$Script does not parse: $($errors[0])" }
$readers = $ast.EndBlock.Statements | Where-Object {
    $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -in @("Get-Alerts", "Get-EventsNaming") }
. (Join-Path $Root "scenarios/scenarios/common.ps1")
. ([scriptblock]::Create(($readers | ForEach-Object { $_.Extent.Text }) -join "`n"))

$failures = @()
function Assert-True([bool]$Ok, [string]$What) {
    if (-not $Ok) { $script:failures += $What }
}

$work = Join-Path ([System.IO.Path]::GetTempPath()) ("rig-validate-admin-output-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $work | Out-Null
try {
    $agent = [pscustomobject]@{ Alerts = Join-Path $work "alerts.ndjson"; Events = Join-Path $work "events.jsonl" }
    Set-Content -LiteralPath $agent.Alerts -Encoding Ascii -Value @(
        '{"technique":"T1105","message":"download into C:\\lab"}',
        '{"message":"an alert without a technique"}',
        '')
    Set-Content -LiteralPath $agent.Events -Encoding Ascii -Value @(
        '{"type":"file_delete","path":"C:\\lab\\a.exe:Zone.Identifier","meta":{"comm":"powershell.exe"}}',
        '{"type":"exec","cmdline":"a.exe","meta":{}}',
        '{"type":"file_open","path":"C:\\lab\\a.exe"}',
        '{"type":"exec","cmdline":"other.exe"}')

    $alerts = @(Get-Alerts $agent | ForEach-Object { "$($_.technique)|$($_.message)" })
    $want = @("T1105|download into C:\lab", "|an alert without a technique")
    Assert-True (($alerts -join "`n") -ceq ($want -join "`n")) "Get-Alerts: [$($alerts -join '] [')]"

    $events = @(Get-EventsNaming $agent @("a.exe") | ForEach-Object { "$($_.type)|$($_.path)|$($_.comm)" })
    $want = @("file_delete|C:\lab\a.exe:Zone.Identifier|powershell.exe", "exec||", "file_open|C:\lab\a.exe|")
    Assert-True (($events -join "`n") -ceq ($want -join "`n")) "Get-EventsNaming: [$($events -join '] [')]"
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures) { throw "runner/windows/validate-admin.ps1 agent output:`n  " + ($failures -join "`n  ") }
Write-Output "runner/windows/validate-admin.ps1: reads alerts and events that leave fields out"
