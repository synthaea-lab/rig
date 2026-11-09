<#
  The lab's scenario runner for Windows guests: the counterpart of run-scenarios.sh, run
  INSIDE the guest after agent-build.ps1 (`python rig.py run <machine>` does both ends).

    powershell -ExecutionPolicy Bypass -File C:\synthaea\rig\runner\run-scenarios.ps1 `
        -Machine win11 [-Source "..."] [scenario ...]

  For each selected scenario (default: the `default` set of scenarios-windows.conf): start
  the agent standalone on the rules checkout with a lab config confined to the run
  directory, wait for its first event, run the scenario, let the alerts settle, snapshot
  them, stop the agent, and compare with the scenario's expectations (its .yaml sidecar
  when it has one, else the catalog's `expect` column). Writes a Markdown report and
  prints `REPORT: <path>`. Results: PASS, UNEXPECTED, FAIL, ERROR, SKIP, as on Linux.

  Needs an elevated session (WinRM gives the vagrant user one). ASCII only, Windows
  PowerShell 5.1 compatible, strict mode (Latest) throughout, LabAgent.ps1 included. Not yet
  run end to end on a lab VM.
#>
param(
  [string]$Machine = $env:COMPUTERNAME,
  [string]$Source = "unknown (set by rig.py)",
  [string]$Root = "C:\synthaea",
  [string]$State = "C:\synthaea-rig",
  [Parameter(ValueFromRemainingArguments = $true)][string[]]$Names = @()
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scenDir = Join-Path $Root "scenarios\scenarios"
$catalog = Join-Path $PSScriptRoot "scenarios-windows.conf"
. (Join-Path $PSScriptRoot "LabAgent.ps1")
$buildInfo = Join-Path $State "build-info"
if (-not (Test-Path $buildInfo)) { throw "no ${buildInfo}: build first (python rig.py build $Machine)" }
$info = @{}
Get-Content $buildInfo | ForEach-Object { $k, $v = $_ -split "=", 2; $info[$k] = $v }
$agent = $info["agent_bin"]
if (-not (Test-Path $agent)) { throw "agent binary $agent missing: build first" }

# --- catalog + expectations -----------------------------------------------------------
$rows = [ordered]@{}
foreach ($line in Get-Content $catalog) {
  if ($line -match '^\s*(#|$)') { continue }
  $c = $line -split '\|' | ForEach-Object { $_.Trim() }
  $rows[$c[0]] = [pscustomobject]@{ Set = $c[1]; Expect = $c[2]; Note = $c[3] }
}

function Get-Expectations {
  <# The expected detections of scenario $Name: its sidecar's expected_detections when
     $scenDir has a $Name.yaml, else the catalog's `expect` column. Returns one list of
     (Technique, Min, Tol), wrapped so that an empty or single list stays a list. #>
  param([Parameter(Mandatory)][string]$Name)
  $yaml = Join-Path $scenDir "$Name.yaml"
  $out = @()
  if (Test-Path $yaml) {
    $in = $false; $cur = $null
    foreach ($l in Get-Content $yaml) {
      if ($l -match '^expected_detections:') { $in = $true; continue }
      if ($in -and $l -match '^[^\s#-]') { break }
      if (-not $in) { continue }
      $l = ($l -split '#')[0]
      if ($l -match 'technique:\s*["'']?([^"'']+)["'']?\s*$') {
        if ($cur) { $out += $cur }
        $cur = [pscustomobject]@{ Technique = $Matches[1].Trim(); Min = 1; Tol = 0 }
      } elseif ($l -match 'min_count:\s*(\d+)' -and $cur) { $cur.Min = [int]$Matches[1] }
      elseif ($l -match 'tolerance:\s*(\d+)' -and $cur) { $cur.Tol = [int]$Matches[1] }
    }
    if ($cur) { $out += $cur }
    return ,$out
  }
  $spec = $rows[$Name].Expect
  if ($spec -and $spec -ne "-") {
    foreach ($e in $spec -split ",") {
      $t, $m, $o = $e.Trim() -split ":"
      $out += [pscustomobject]@{ Technique = $t; Min = [int]$m; Tol = [int]$o }
    }
  }
  return ,$out
}

if ($Names.Count -eq 0) { $Names = @($rows.Keys | Where-Object { $rows[$_].Set -eq "default" }) }
foreach ($n in $Names) { if (-not $rows.Contains($n)) { throw "unknown scenario '$n' (see $catalog)" } }
if (Get-Process -Name "agent" -ErrorAction SilentlyContinue) { throw "an agent.exe is already running; stop it first" }

$stamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
$run = Join-Path $State "runs\$stamp"
New-Item -ItemType Directory -Force -Path $run, (Join-Path $State "reports") | Out-Null

function Get-Counts {
  <# How many times each technique fired in the alerts file $File (none if it is missing). #>
  param([Parameter(Mandatory)][string]$File)
  $counts = @{}
  if (Test-Path $File) {
    foreach ($l in Get-Content $File) {
      if ($l -match '"technique":"([^"]*)"') { $counts[$Matches[1]] = 1 + [int]$counts[$Matches[1]] }
    }
  }
  return $counts
}

function Invoke-ScenarioScript {
  <# Runs the scenario $Script in a child Windows PowerShell, every output stream into the
     file $Log, and returns its exit code. A scenario's errors are data, not the runner's:
     Windows PowerShell 5.1 turns each line a native command writes to a redirected stderr
     into an error record, which "Stop" would make terminating. So the preference is
     "Continue" here, in this function's scope only; the caller's stays "Stop". #>
  param(
    [Parameter(Mandatory)][string]$Script,
    [Parameter(Mandatory)][string]$Log
  )
  $ErrorActionPreference = "Continue"
  & powershell -NoProfile -ExecutionPolicy Bypass -File $Script *> $Log
  $LASTEXITCODE
}

$results = @()
$t0 = Get-Date
foreach ($n in $Names) {
  Write-Host "== $n"
  $dir = Join-Path $run $n
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $expect = Get-Expectations $n
  $r = [pscustomobject]@{ Name = $n; Status = ""; Fired = ""; Unexpected = ""; Detail = ""; Seconds = 0; Expect = $expect }
  $start = Get-Date
  $config = New-LabAgentConfig -Dir $dir -PipeName "synthaea-lab-runner"
  $labAgent = Start-LabAgent -AgentExe $agent -Config $config -Dir $dir `
    -RunArgs @("--standalone", "--content-dir", "`"$Root`"") -StdoutLog "agent.out.log" -StderrLog "agent.log"
  if (-not (Wait-AgentEvents $labAgent -TimeoutSec 45)) {
    Stop-LabAgent $labAgent
    $r.Status = "ERROR"; $r.Detail = "agent did not start (see $($labAgent.StderrLog))"
    $r.Seconds = [int]((Get-Date) - $start).TotalSeconds; $results += $r; Write-Host "   ERROR"; continue
  }
  $alerts = $labAgent.Alerts
  Start-Sleep -Seconds 2

  $rc = Invoke-ScenarioScript -Script (Join-Path $scenDir "$n.ps1") -Log (Join-Path $dir "scenario.log")

  # Settle: 3 s, then until the alert file has been quiet for 2 s (max 20 s).
  Start-Sleep -Seconds 3
  $last = -1; $quiet = 0
  for ($i = 0; $i -lt 20 -and $quiet -lt 2; $i++) {
    $size = if (Test-Path $alerts) { (Get-Item $alerts).Length } else { 0 }
    if ($size -eq $last) { $quiet++ } else { $quiet = 0 }
    $last = $size; Start-Sleep -Seconds 1
  }
  $snap = Join-Path $dir "alerts.snapshot.ndjson"
  if (Test-Path $alerts) { Copy-Item $alerts $snap } else { New-Item -ItemType File $snap | Out-Null }
  Stop-LabAgent $labAgent
  $r.Seconds = [int]((Get-Date) - $start).TotalSeconds

  $got = Get-Counts $snap
  $fired = @(); $fail = @(); $unexp = @()
  foreach ($e in $expect) {
    $c = [int]$got[$e.Technique]
    $fired += "$($e.Technique) x$c"
    if ($c -lt $e.Min) { $fail += "$($e.Technique) fired $c times, needs >= $($e.Min)" }
    elseif ($c -gt $e.Min + $e.Tol) { $fail += "$($e.Technique) fired $c times, allows <= $($e.Min + $e.Tol)" }
  }
  # Follow-ups (the escalation record added on top of every detection) are never judged.
  foreach ($t in $got.Keys) {
    if ($expect | Where-Object { $_.Technique -eq $t }) { continue }
    if ($t -eq "RESPONSE-ESCALATE") { continue }
    $unexp += "$t x$($got[$t])"
  }
  if ($fail.Count) { $r.Status = "FAIL"; if ($rc -ne 0) { $fail += "script exited $rc" } }
  elseif ($rc -ne 0) { $r.Status = "ERROR"; $fail += "script exited $rc" }
  elseif ($unexp.Count) { $r.Status = "UNEXPECTED" }
  else { $r.Status = "PASS" }
  $r.Fired = $fired -join ", "; $r.Unexpected = $unexp -join ", "; $r.Detail = $fail -join "; "
  Write-Host "   $($r.Status)  fired: $($r.Fired)  $($r.Unexpected)  $($r.Detail)"
  $results += $r
}
$total = [int]((Get-Date) - $t0).TotalSeconds

# --- report ---------------------------------------------------------------------------
$os = Get-CimInstance Win32_OperatingSystem
$date = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd")
$report = Join-Path $State "reports\$date-$Machine.md"
$tally = ($results | Group-Object Status | ForEach-Object { "$($_.Name) $($_.Count)" }) -join " / "
function Format-Cell {
  <# $Text as one Markdown table cell: pipes escaped, "-" when empty. #>
  param([string]$Text)
  if ($Text) { $Text -replace '\|', '\|' } else { "-" }
}
$md = @()
$md += "# Lab run: $Machine, $date"
$md += ""
$md += "| | |"
$md += "| --- | --- |"
$md += "| Machine | ``$Machine`` ($env:COMPUTERNAME), $($os.Caption) |"
$md += "| OS build | $($os.Version) ($env:PROCESSOR_ARCHITECTURE) |"
$md += "| Agent build | ``$agent``, $($info['profile']), ONNX Runtime $($info['ort']), built $($info['built_at']) in $($info['build_seconds'])s with $($info['rustc']) |"
$md += "| Sources at build | $(Format-Cell $info['source']) |"
$md += "| Sources at run | $(Format-Cell $Source) |"
$md += "| Run | $($Names.Count) scenarios in ${total}s, one standalone agent per scenario, content = ``rules\`` |"
$md += ""
$md += "**$tally**"
$md += ""
$md += "| Scenario | Result | Expected | Fired | Unexpected | Time |"
$md += "| --- | --- | --- | --- | --- | --- |"
foreach ($r in $results) {
  $exp = ($r.Expect | ForEach-Object { "$($_.Technique) x$($_.Min)" + $(if ($_.Tol) { "(+$($_.Tol))" } else { "" }) }) -join ", "
  $md += "| ``$($r.Name)`` | $($r.Status) | $(Format-Cell $exp) | $(Format-Cell $r.Fired) | $(Format-Cell $r.Unexpected) | $($r.Seconds)s |"
}
$md += ""
$md += "## Details"
foreach ($r in $results) {
  $md += ""
  $md += "### ``$($r.Name)``: $($r.Status)"
  if ($r.Detail) { $md += ""; $md += $r.Detail }
  $snap = Join-Path $run "$($r.Name)\alerts.snapshot.ndjson"
  if ((Test-Path $snap) -and (Get-Item $snap).Length -gt 0) {
    $md += ""; $md += '```'
    $md += Get-Content $snap | ForEach-Object { $_ -replace '.*"technique":"([^"]*)","message":"(.*)"}$', '$1  $2' }
    $md += '```'
  }
}
$md += ""
$md += "Raw material (agent.log, scenario.log, alerts, events per scenario): ``$run`` in the guest."
$md | Set-Content -LiteralPath $report -Encoding UTF8
Write-Host ""
Write-Host "== $tally in ${total}s"
Write-Host "REPORT: $report"
if ($results | Where-Object { $_.Status -in @("FAIL", "ERROR") }) { exit 1 }
exit 0
