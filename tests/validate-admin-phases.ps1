<#
.SYNOPSIS
    Checks the phases of runner/windows/validate-admin.ps1 that are functions, against
    fakes of everything they touch on the host.

.DESCRIPTION
    Defines the script's functions without running any of its top-level statements, then
    replaces the helpers that reach the host (logman, the agent, Start-Sleep) with fakes
    that record each call and play a scripted ETW host. Each case runs one phase and
    compares, line for line, the results it recorded and the calls it made, in order.
    Phase A (Invoke-SweepPhase) runs once with every orphan swept and once with a
    survivor, a sensor failure and a logman alert; phase B (Invoke-RootCausePhase) runs
    with a refused probe. This works under pwsh on any OS. `python rig.py check` runs this.
#>
param(
    [string]$Script = (Join-Path (Split-Path -Parent $PSScriptRoot) "runner/windows/validate-admin.ps1")
)
$ErrorActionPreference = "Stop"

$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($Script, [ref]$tokens, [ref]$errors)
if ($errors) { throw "$Script does not parse: $($errors[0])" }
$functions = $ast.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] }
. ([scriptblock]::Create(($functions | ForEach-Object { $_.Extent.Text }) -join "`n"))

# The script-scope names the phases read.
$AgentPrefix = "wtrace-"
$ProbePrefix = "synthaea408-probe-"
$Results = New-Object System.Collections.ArrayList

# -- Fakes -------------------------------------------------------------------------------

$Fake = @{}
function Reset-Fake {
    $script:Results.Clear()
    $script:Fake = @{
        Calls = New-Object System.Collections.ArrayList
        Sessions = New-Object System.Collections.ArrayList
        Ready = $true
        Survivor = $null
        Log = ""
        Alerts = @()
        Markers = @()
        Refuse = @()
    }
}
function Write-Section([string]$Title) { [void]$Fake.Calls.Add("section $Title") }
function Get-EtsSessions([string]$Prefix) {
    @($Fake.Sessions | Where-Object { $_.StartsWith($Prefix, [StringComparison]::OrdinalIgnoreCase) })
}
function Stop-EtsSessions([string]$Prefix) {
    [void]$Fake.Calls.Add("stop-sessions $Prefix")
    foreach ($name in (Get-EtsSessions $Prefix)) { $Fake.Sessions.Remove($name) }
}
function New-RealtimeSession([string]$Name) {
    [void]$Fake.Calls.Add("new-session $Name")
    if ($Fake.Refuse -contains $Name) { throw "refused $Name" }
    [void]$Fake.Sessions.Add($Name)
}
function Get-ProviderEnablers { [ordered]@{ "Kernel-Process" = 1; "Kernel-File" = 0 } }
function Start-PhaseAgent([string]$Tag) {
    [void]$Fake.Calls.Add("start-agent $Tag")
    # A sweep stops every wtrace- session but the survivor, then the agent opens its own.
    if ($Tag -ne "A0-make-orphan") {
        foreach ($name in (Get-EtsSessions $AgentPrefix)) {
            if ($name -ne $Fake.Survivor) { $Fake.Sessions.Remove($name) }
        }
    }
    [void]$Fake.Sessions.Add("${AgentPrefix}$Tag")
    [pscustomobject]@{ Tag = $Tag; Dir = "lab/$Tag"; Started = (Get-Date).AddSeconds(-10) }
}
function Wait-AgentEvents($Agent) { [void]$Fake.Calls.Add("wait-agent $($Agent.Tag)"); $Fake.Ready }
function Stop-LabAgent($Agent) {
    [void]$Fake.Calls.Add("stop-agent $($Agent.Tag)")
    # A killed agent leaves its session behind only for the seed (Stop-Process -Force).
    if ($Agent.Tag -ne "A0-make-orphan") { $Fake.Sessions.Remove("${AgentPrefix}$($Agent.Tag)") }
}
function Invoke-Triggers($Agent, [string]$Marker) { [void]$Fake.Calls.Add("triggers $($Agent.Tag) $Marker") }
function Start-Sleep([int]$Seconds) { [void]$Fake.Calls.Add("sleep $Seconds") }
function Get-AgentLog($Agent) { $Fake.Log }
function Get-Alerts($Agent) { @($Fake.Alerts) }
function Get-EventTypeCounts($Agent) { @{ exec = 3; file_open = 2 } }
function Test-Marker($Agent, [string]$Marker, [string]$Type) { $Fake.Markers -contains "$Marker/$Type" }

# -- Cases -------------------------------------------------------------------------------

$failures = @()
function Expect-Lines([string]$Case, [string]$What, [string[]]$Want, [string[]]$Got) {
    $diff = Compare-Object -ReferenceObject $Want -DifferenceObject $Got -SyncWindow 0 -CaseSensitive
    if ($diff -or $Want.Count -ne $Got.Count) {
        $script:failures += "${Case}: $What differ`n  want:`n    $($Want -join "`n    ")`n  got:`n    $($Got -join "`n    ")"
    }
}
function Get-ResultLines { @($Results | ForEach-Object { "[$($_.Verdict)] $($_.Check): $($_.Detail)" }) }

# A: two synthetic orphans plus the seed's, all swept; events flow, no logman alert.
Reset-Fake
$Fake.Log = "orphaned ETW session stopped`norphaned ETW session stopped`norphaned ETW session stopped"
$Fake.Markers = @("synthaea408-sweep/exec")
$Fake.Alerts = @([pscustomobject]@{ technique = "T1059"; message = "powershell" })
Invoke-SweepPhase *> $null
Expect-Lines "A swept" "results" @(
    "[INFO] orphans before start: 3 (1 left by a killed agent): wtrace-A0-make-orphan, wtrace-lab408-a, wtrace-lab408-b"
    "[PASS] #408 every orphan stopped: 3 stopped, 1 wtrace- session(s) left (the new agent's own)"
    "[PASS] #408 events flow after the sweep: exec=3 file_open=2"
    "[PASS] #463 no SELF-SPAWN on the sweep's logman.exe: no T1059 alert mentioning logman"
) (Get-ResultLines)
Expect-Lines "A swept" "calls" @(
    "section A. #408 orphan cleanup"
    "start-agent A0-make-orphan", "wait-agent A0-make-orphan", "stop-agent A0-make-orphan"
    "new-session wtrace-lab408-a", "new-session wtrace-lab408-b"
    "start-agent A1-sweep", "wait-agent A1-sweep", "triggers A1-sweep synthaea408-sweep", "sleep 35"
    "stop-agent A1-sweep", "stop-sessions wtrace-"
) @($Fake.Calls)

# A: one orphan survives, the sensor failed and the sweep's logman raised SELF-SPAWN.
Reset-Fake
$Fake.Survivor = "wtrace-lab408-b"
$Fake.Log = "orphaned ETW session stopped`nETW sensor failed"
$Fake.Alerts = @([pscustomobject]@{ technique = "T1059"; message = "SELF-SPAWN logman.exe stop wtrace-x" })
Invoke-SweepPhase *> $null
Expect-Lines "A survivor" "results" @(
    "[INFO] orphans before start: 3 (1 left by a killed agent): wtrace-A0-make-orphan, wtrace-lab408-a, wtrace-lab408-b"
    "[FAIL] #408 every orphan stopped: survivors: wtrace-lab408-b; 'stopped' log lines: 1"
    "[FAIL] #408 events flow after the sweep: ready=True sensor-failed=True types: exec=3 file_open=2"
    "[FAIL] #463 no SELF-SPAWN on the sweep's logman.exe: SELF-SPAWN logman.exe stop wtrace-x"
) (Get-ResultLines)

# A: the seed agent never becomes ready: the phase throws before making any orphan.
Reset-Fake
$Fake.Ready = $false
$thrown = $null
try { Invoke-SweepPhase *> $null } catch { $thrown = "$_" }
Expect-Lines "A not ready" "error" @("the agent produced no events in 30s; see lab/A0-make-orphan") @("$thrown")
Expect-Lines "A not ready" "calls" @(
    "section A. #408 orphan cleanup", "start-agent A0-make-orphan", "wait-agent A0-make-orphan"
) @($Fake.Calls)

# B: probes of 0 and 2 sessions, the second probe refused; markers seen early and late.
Reset-Fake
$Fake.Refuse = @("synthaea408-probe-2")
$Fake.Markers = @("synthaea408-probe0/exec", "synthaea408-probe0/file_open", "synthaea408-probe2-late/exec")
Invoke-RootCausePhase -ProbeCounts @(0, 2) *> $null
Expect-Lines "B" "results" @(
    "[INFO] host sessions already enabling each provider: Kernel-Process=1 Kernel-File=0"
    "[INFO] probes=0: ready=True exec-seen=True file-seen=True sensor-failed=False types: exec=3 file_open=2"
    "[INFO] probes=2 refused: probe 2 (refused synthaea408-probe-2)"
    "[INFO] probes=2: ready=True exec-seen=True file-seen=False sensor-failed=False types: exec=3 file_open=2"
) (Get-ResultLines)
Expect-Lines "B" "calls" @(
    "section B. #408 root cause (per-provider session limit)"
    "start-agent B-probes-0", "wait-agent B-probes-0"
    "triggers B-probes-0 synthaea408-probe0", "sleep 5", "triggers B-probes-0 synthaea408-probe0-late", "sleep 30"
    "stop-agent B-probes-0", "stop-sessions synthaea408-probe-", "stop-sessions wtrace-"
    "new-session synthaea408-probe-1", "new-session synthaea408-probe-2"
    "start-agent B-probes-2", "wait-agent B-probes-2"
    "triggers B-probes-2 synthaea408-probe2", "sleep 5", "triggers B-probes-2 synthaea408-probe2-late", "sleep 30"
    "stop-agent B-probes-2", "stop-sessions synthaea408-probe-", "stop-sessions wtrace-"
) @($Fake.Calls)

if ($failures) { throw "runner/windows/validate-admin.ps1 phases:`n$($failures -join "`n")" }
Write-Output "runner/windows/validate-admin.ps1: phases A and B record the expected results and calls"
