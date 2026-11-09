<#
  The lab agent's lifecycle, shared by the PowerShell scripts that start an agent of their
  own: runner\run-scenarios.ps1 and runner\windows\validate-admin.ps1. Dot-source it:

    . (Join-Path $PSScriptRoot "LabAgent.ps1")

  New-LabAgentConfig  writes a lab agent.toml (lab-agent.toml.template) that keeps everything
                      inside one directory
  Start-LabAgent      starts agent.exe with that config and returns a handle
  Wait-AgentEvents    waits until the agent has written its first event (its readiness)
  Stop-LabAgent       stops that one process, by pid; safe to call twice

  Every function acts only on what it is given: no process is found by name and no
  script-scope variable is set, so a caller that needs to stop agents in a `finally` keeps
  the handles itself. ASCII only, Windows PowerShell 5.1 compatible, strict-mode clean: a
  dot-sourced file sets no mode of its own (it would be the caller's), so tests/lab-agent.ps1
  runs it under Set-StrictMode -Version Latest, as run-scenarios.ps1 does.
#>

function New-LabAgentConfig {
  <# Writes $Dir\agent.toml and returns its path: offline (the control plane is a .invalid
     host), with logs, state and certificates under $Dir, and the local IPC endpoint on the
     named pipe $PipeName, so two lab agents of different scripts never share one. The text
     is runner\lab-agent.toml.template with @DIR@ and @PIPE@ replaced. #>
  param(
    [Parameter(Mandatory)][string]$Dir,
    [Parameter(Mandatory)][string]$PipeName
  )
  $template = Get-Content -LiteralPath (Join-Path $PSScriptRoot "lab-agent.toml.template") -Raw
  foreach ($placeholder in "@DIR@", "@PIPE@") {
    if (-not $template.Contains($placeholder)) { throw "lab-agent.toml.template has no $placeholder" }
  }
  # String.Replace, not -replace: a directory may hold regex metacharacters such as `$`.
  $config = Join-Path $Dir "agent.toml"
  $template.Replace("@DIR@", $Dir).Replace("@PIPE@", $PipeName) |
    Set-Content -LiteralPath $config -Encoding Ascii -NoNewline
  $config
}

function Start-LabAgent {
  <# Starts `$AgentExe --config $Config run [$RunArgs] --alerts $Dir\alerts.ndjson
     --events $Dir\events.jsonl` hidden, in $Dir, with stdout and stderr redirected to the
     files $StdoutLog and $StderrLog of $Dir. Returns the handle the other functions take:
     Process, Dir, Started, Events, Alerts, StdoutLog, StderrLog (the last four are paths). #>
  param(
    [Parameter(Mandatory)][string]$AgentExe,
    [Parameter(Mandatory)][string]$Config,
    [Parameter(Mandatory)][string]$Dir,
    [string[]]$RunArgs = @(),
    [string]$StdoutLog = "stdout.log",
    [string]$StderrLog = "stderr.log"
  )
  $events = Join-Path $Dir "events.jsonl"
  $alerts = Join-Path $Dir "alerts.ndjson"
  $stdout = Join-Path $Dir $StdoutLog
  $stderr = Join-Path $Dir $StderrLog
  # Start-Process joins the arguments into one command line: quote the paths.
  $agentArgs = @("--config", "`"$Config`"", "run") + $RunArgs +
    @("--alerts", "`"$alerts`"", "--events", "`"$events`"")
  $start = @{
    FilePath = $AgentExe; ArgumentList = $agentArgs; WorkingDirectory = $Dir
    RedirectStandardOutput = $stdout; RedirectStandardError = $stderr; PassThru = $true
  }
  # -WindowStyle exists only on Windows (5.1 has no $IsWindows): the check runs a fake
  # agent under pwsh on Linux.
  if ($PSVersionTable.PSEdition -eq "Desktop" -or $IsWindows) { $start.WindowStyle = "Hidden" }
  $process = Start-Process @start
  [pscustomobject]@{
    Process = $process; Dir = $Dir; Started = Get-Date
    Events = $events; Alerts = $alerts; StdoutLog = $stdout; StderrLog = $stderr
  }
}

function Wait-AgentEvents {
  <# True once the agent has written a first event (its pid store is seeded and its trace
     runs); false if it exits first or $TimeoutSec pass. #>
  param(
    [Parameter(Mandatory)]$Agent,
    [int]$TimeoutSec = 30
  )
  $deadline = (Get-Date).AddSeconds($TimeoutSec)
  while ((Get-Date) -lt $deadline) {
    if ($Agent.Process.HasExited) { return $false }
    if ((Test-Path -LiteralPath $Agent.Events) -and (Get-Item -LiteralPath $Agent.Events).Length -gt 0) { return $true }
    Start-Sleep -Milliseconds 500
  }
  $false
}

function Stop-LabAgent {
  <# Kills the agent's own process (by pid, never by name) and waits up to 10 s for it to
     exit. Does nothing for $null or an agent that has already exited. #>
  param($Agent)
  if ($Agent -and -not $Agent.Process.HasExited) {
    Stop-Process -Id $Agent.Process.Id -Force
    $Agent.Process.WaitForExit(10000) | Out-Null
  }
}
