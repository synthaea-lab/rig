<#
.SYNOPSIS
    Checks runner/LabAgent.ps1, the lab agent lifecycle the PowerShell runners share.

.DESCRIPTION
    New-LabAgentConfig must write, for each caller's pipe name, the agent.toml in
    tests/lab-agent/<caller>.toml, with @DIR@ standing for the directory (those are the
    bytes run-scenarios.ps1 and validate-admin.ps1 wrote before they shared it). Where
    /bin/sh exists, Start-LabAgent, Wait-AgentEvents and Stop-LabAgent then drive a fake
    agent: the command line it gets, ready on its first event, not ready when it exits
    first, and a stop that kills it by pid and can be repeated. `python rig.py check`
    runs this.
#>
$ErrorActionPreference = "Stop"
$rig = Split-Path -Parent $PSScriptRoot
. (Join-Path $rig "runner/LabAgent.ps1")

$work = Join-Path ([System.IO.Path]::GetTempPath()) ("rig-lab-agent-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $work | Out-Null
$failures = @()
$started = @()
function Expect([bool]$Ok, [string]$What) {
    if (-not $Ok) { $script:failures += $What }
}

try {
    # -- New-LabAgentConfig: the bytes each caller wrote ---------------------------------
    # Set-Content ends the file with the platform's newline: compare everything before it.
    foreach ($case in @(@{ Golden = "runner"; Pipe = "synthaea-lab-runner" },
                        @{ Golden = "validation"; Pipe = "synthaea-lab-validation" })) {
        $dir = Join-Path $work $case.Golden
        New-Item -ItemType Directory -Path $dir | Out-Null
        $config = New-LabAgentConfig -Dir $dir -PipeName $case.Pipe
        Expect ($config -eq (Join-Path $dir "agent.toml")) "New-LabAgentConfig returned $config, not $dir/agent.toml"
        $want = (Get-Content -LiteralPath (Join-Path $PSScriptRoot "lab-agent/$($case.Golden).toml") -Raw).Replace("@DIR@", $dir).TrimEnd("`r", "`n")
        $got = (Get-Content -LiteralPath $config -Raw).TrimEnd("`r", "`n")
        Expect ($got -ceq $want) "New-LabAgentConfig -PipeName $($case.Pipe) differs from tests/lab-agent/$($case.Golden).toml"
    }

    # -- Start / Wait / Stop on a fake agent ---------------------------------------------
    if (-not (Test-Path -LiteralPath "/bin/sh")) {
        Write-Output "skipped: no /bin/sh for the fake agent of the lifecycle check"
    } else {
        # Records its arguments, writes one event if FAKE_AGENT_EVENTS says so, then waits.
        $fake = Join-Path $work "fake-agent"
        # LF only: this file is CRLF, and a \r after the shebang names no interpreter.
        [System.IO.File]::WriteAllText($fake, (@'
#!/bin/sh
printf '%s\n' "$@" > argv.txt
echo "fake agent up"
echo "fake agent warning" >&2
while [ $# -gt 0 ]; do [ "$1" = --events ] && events=$2; shift; done
[ "$(cat mode)" = exit ] && exit 3
echo '{"type":"exec"}' > "$events"
exec sleep 60
'@ -replace "`r", "") + "`n")
        & chmod +x $fake

        $dir = Join-Path $work "ready"
        New-Item -ItemType Directory -Path $dir | Out-Null
        Set-Content -LiteralPath (Join-Path $dir "mode") -Value "run" -Encoding Ascii
        $agent = Start-LabAgent -AgentExe $fake -Config "$dir/agent.toml" -Dir $dir `
            -RunArgs @("--standalone", "--content-dir", "`"/content root`"") -StdoutLog "agent.out.log" -StderrLog "agent.log"
        $started += $agent
        Expect (Wait-AgentEvents $agent -TimeoutSec 15) "Wait-AgentEvents: false for an agent that wrote an event"
        $argv = @(Get-Content -LiteralPath (Join-Path $dir "argv.txt"))
        $wantArgv = @("--config", "$dir/agent.toml", "run", "--standalone", "--content-dir", "/content root",
                      "--alerts", "$dir/alerts.ndjson", "--events", "$dir/events.jsonl")
        Expect (($argv -join "|") -ceq ($wantArgv -join "|")) "Start-LabAgent passed: $($argv -join ' | ')"
        Expect ($agent.Events -eq "$dir/events.jsonl" -and $agent.Alerts -eq "$dir/alerts.ndjson") "Start-LabAgent handle paths: $($agent.Events), $($agent.Alerts)"
        Expect ((Get-Content -LiteralPath $agent.StdoutLog -Raw) -match "fake agent up") "stdout did not go to $($agent.StdoutLog)"
        Expect ((Get-Content -LiteralPath $agent.StderrLog -Raw) -match "fake agent warning") "stderr did not go to $($agent.StderrLog)"
        Stop-LabAgent $agent
        Expect $agent.Process.HasExited "Stop-LabAgent left pid $($agent.Process.Id) running"
        Stop-LabAgent $agent
        Stop-LabAgent $null

        $dir = Join-Path $work "exits"
        New-Item -ItemType Directory -Path $dir | Out-Null
        Set-Content -LiteralPath (Join-Path $dir "mode") -Value "exit" -Encoding Ascii
        $agent = Start-LabAgent -AgentExe $fake -Config "$dir/agent.toml" -Dir $dir
        $started += $agent
        Expect (-not (Wait-AgentEvents $agent -TimeoutSec 15)) "Wait-AgentEvents: true for an agent that exited first"
        Expect ($agent.StdoutLog -eq "$dir/stdout.log" -and $agent.StderrLog -eq "$dir/stderr.log") "Start-LabAgent default logs: $($agent.StdoutLog), $($agent.StderrLog)"
        Stop-LabAgent $agent
    }
} finally {
    foreach ($agent in $started) { Stop-LabAgent $agent }
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures) { throw "runner/LabAgent.ps1:`n  " + ($failures -join "`n  ") }
Write-Output "runner/LabAgent.ps1: writes both lab configs as before and drives an agent by pid"
