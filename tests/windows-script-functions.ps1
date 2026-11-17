<#
.SYNOPSIS
    Checks the functions of the Windows provisioning and capture scripts that run without a
    Windows host.

.DESCRIPTION
    Each script's functions are defined without running its top level (no elevation check,
    nothing installed or traced) and called under strict mode (Latest) and "Stop", as the
    script calls them, with the programs they run faked:

      - provisioning/agent-build.ps1: Invoke-CargoBuild returns cargo's exit code and nothing
        else, puts cargo's output and errors in the log, and leaves the caller at "Stop";
      - provisioning/agent-install.ps1: Uninstall-WatchdogService goes on past a watchdog
        that writes to stderr and fails, as one with no service installed does;
      - tools/windows/capture-sysmon-etw.ps1: Invoke-Tool returns no output line for a silent
        tool and the exit code of a failing one, Test-ProviderRegistered matches a provider's
        whole name only, and Get-EventStats counts the ids, fields and time span of an event
        dump;
      - tools/windows/observe-rdp.ps1: Get-DataField and Get-UserDataText read an event's
        fields, and "" for what the event leaves out (an empty Data, a missing name, no
        EventData, no UserData).

    A fake program behaves as Windows PowerShell 5.1 does with a native tool writing to
    stderr: it writes an error record. This works under pwsh on any OS.
    `python rig.py check` runs this.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$rig = Split-Path -Parent $PSScriptRoot

$failures = @()
function Assert-True([bool]$Ok, [string]$What) {
    if (-not $Ok) { $script:failures += $What }
}

function Get-ScriptFunctions([string]$RelativePath) {
    <# The function definitions of the script, as one script block to dot-source. #>
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $rig $RelativePath), [ref]$tokens, [ref]$errors)
    if ($errors) { throw "$RelativePath does not parse: $($errors[0])" }
    $functions = $ast.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] }
    [scriptblock]::Create(($functions | ForEach-Object { $_.Extent.Text }) -join "`n")
}

$work = Join-Path ([System.IO.Path]::GetTempPath()) ("rig-windows-functions-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $work | Out-Null
try {
    # -- provisioning/agent-build.ps1 ----------------------------------------------------------
    . (Get-ScriptFunctions "provisioning/agent-build.ps1")
    $cargoCalls = New-Object System.Collections.ArrayList
    function cargo {
        [void]$cargoCalls.Add($args -join " ")
        Write-Output "Compiling agent"
        Write-Error "warning: progress on stderr"
        $global:LASTEXITCODE = 101
    }
    $buildLog = Join-Path $work "build.log"
    $rc = @(Invoke-CargoBuild -Log $buildLog 6> $null)
    Assert-True ($rc.Count -eq 1 -and $rc[0] -eq 101) "Invoke-CargoBuild returned [$($rc -join ', ')], not cargo's exit code 101 alone"
    Assert-True (($cargoCalls -join "|") -ceq "build --release -p agent") "Invoke-CargoBuild ran: cargo $($cargoCalls -join ' | cargo ')"
    $logText = Get-Content -LiteralPath $buildLog -Raw
    Assert-True ($logText -match "Compiling agent" -and $logText -match "progress on stderr") "cargo's output and errors are not all in build.log: $logText"
    Assert-True ($ErrorActionPreference -eq "Stop") "Invoke-CargoBuild left the caller's preference at $ErrorActionPreference"

    # -- provisioning/agent-install.ps1 --------------------------------------------------------
    . (Get-ScriptFunctions "provisioning/agent-install.ps1")
    $watchdogCalls = New-Object System.Collections.ArrayList
    function watchdog-without-service {
        [void]$watchdogCalls.Add($args -join " ")
        Write-Error "[watchdog] loaded configuration"
        $global:LASTEXITCODE = 1
    }
    $thrown = $null
    try { Uninstall-WatchdogService -Watchdog "watchdog-without-service" } catch { $thrown = "$_" }
    Assert-True ($null -eq $thrown) "Uninstall-WatchdogService stopped on a watchdog with no service: $thrown"
    Assert-True (($watchdogCalls -join "|") -ceq "uninstall") "Uninstall-WatchdogService ran: watchdog $($watchdogCalls -join ' | watchdog ')"

    # -- tools/windows/capture-sysmon-etw.ps1 --------------------------------------------------
    . (Get-ScriptFunctions "tools/windows/capture-sysmon-etw.ps1")
    function silent-tool { $global:LASTEXITCODE = 0 }
    function failing-tool { Write-Output "out"; Write-Error "err"; $global:LASTEXITCODE = 5 }
    $silent = Invoke-Tool -FilePath "silent-tool"
    Assert-True ($silent.Exit -eq 0 -and $silent.Output.Count -eq 0) "Invoke-Tool of a silent tool: exit $($silent.Exit), $($silent.Output.Count) output line(s)"
    $failing = Invoke-Tool -FilePath "failing-tool"
    Assert-True ($failing.Exit -eq 5 -and ($failing.Output -join "|") -ceq "out|err") "Invoke-Tool of a failing tool: exit $($failing.Exit), output [$($failing.Output -join '|')]"
    Assert-True ($ErrorActionPreference -eq "Stop") "Invoke-Tool left the caller's preference at $ErrorActionPreference"

    function logman.exe {
        "Provider                                 GUID"
        "-------------------------------------------------------------------------------"
        "Microsoft-Windows-Kernel-Processor-Power {0F67E49F-FE51-4E9F-B490-6F2948CC6027}"
        "Microsoft-Windows-Kernel-Process         {22FB2CD6-0E7B-422B-A0C7-2FAD1FD0E716}"
        $global:LASTEXITCODE = 0
    }
    Assert-True ((Test-ProviderRegistered -Name "Microsoft-Windows-Kernel-Process") -eq $true) "Test-ProviderRegistered misses Microsoft-Windows-Kernel-Process"
    Assert-True ((Test-ProviderRegistered -Name "Microsoft-Windows-Kernel") -eq $false) "Test-ProviderRegistered matches a part of a provider's name"
    function logman.exe { $global:LASTEXITCODE = 0 }
    Assert-True ((Test-ProviderRegistered -Name "Microsoft-Windows-Kernel-Process") -eq $false) "Test-ProviderRegistered with no provider listed is not false"

    $dump = Join-Path $work "events.xml"
    $ns = "xmlns='http://schemas.microsoft.com/win/2004/08/events/event'"
    Set-Content -LiteralPath $dump -Encoding Ascii -Value @(
        "<Events>"
        "<Event $ns><System><EventID>1</EventID><TimeCreated SystemTime='2026-11-01T10:00:00.000Z'/></System><EventData><Data Name='Image'>a</Data><Data Name='User'>b</Data></EventData></Event>"
        "<Event $ns><System><EventID>1</EventID><TimeCreated SystemTime='2026-11-01T10:00:02.000Z'/></System><EventData><Data Name='Image'>c</Data></EventData></Event>"
        "<Event $ns><System><EventID Qualifiers='0'>10</EventID></System></Event>"
        "</Events>")
    $stats = Get-EventStats -XmlPath $dump
    $counts = ($stats.Ids.Keys | Sort-Object | ForEach-Object { "$_=$($stats.Ids[$_])" }) -join " "
    Assert-True ($counts -ceq "1=2 10=1") "Get-EventStats counts: $counts"
    $fields = ($stats.Fields["1"].Keys | Sort-Object) -join ","
    Assert-True ($fields -ceq "Image,User") "Get-EventStats fields of id 1: $fields"
    Assert-True ($stats.Fields["10"].Count -eq 0) "Get-EventStats fields of id 10: $($stats.Fields['10'].Keys -join ',')"
    Assert-True (($stats.Last - $stats.First).TotalSeconds -eq 2) "Get-EventStats span: $($stats.First) to $($stats.Last)"

    # -- tools/windows/observe-rdp.ps1 ---------------------------------------------------------
    . (Get-ScriptFunctions "tools/windows/observe-rdp.ps1")
    [xml]$failedLogon = "<Event $ns><System><EventID>4625</EventID></System><EventData><Data Name='LogonType'>10</Data><Data Name='SubStatus'></Data></EventData></Event>"
    [xml]$noEventData = "<Event $ns><System><EventID>1149</EventID></System></Event>"
    [xml]$authenticated = "<Event $ns><System><EventID>1149</EventID></System><UserData><EventXML xmlns='Event_NS'><Param1>alice</Param1><Param2>LAB</Param2><Param3>10.0.0.5</Param3></EventXML></UserData></Event>"
    Assert-True ((Get-DataField $failedLogon "LogonType") -ceq "10") "Get-DataField LogonType: $(Get-DataField $failedLogon 'LogonType')"
    Assert-True ((Get-DataField $failedLogon "SubStatus") -ceq "") "Get-DataField of an empty Data: $(Get-DataField $failedLogon 'SubStatus')"
    Assert-True ((Get-DataField $failedLogon "IpAddress") -ceq "") "Get-DataField of a missing name: $(Get-DataField $failedLogon 'IpAddress')"
    Assert-True ((Get-DataField $noEventData "LogonType") -ceq "") "Get-DataField with no EventData: $(Get-DataField $noEventData 'LogonType')"
    Assert-True ((Get-UserDataText $authenticated) -ceq "Param1=alice Param2=LAB Param3=10.0.0.5") "Get-UserDataText: $(Get-UserDataText $authenticated)"
    Assert-True ((Get-UserDataText $failedLogon) -ceq "") "Get-UserDataText with no UserData: $(Get-UserDataText $failedLogon)"
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures) { throw "Windows script functions:`n  " + ($failures -join "`n  ") }
Write-Output "rig: the functions of agent-build, agent-install, capture-sysmon-etw and observe-rdp behave under strict mode as stated"
