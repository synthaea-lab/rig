<#
.SYNOPSIS
    Checks powershell/RigCommon.ps1 and the scripts that dot-source it.

.DESCRIPTION
    Every rig script that names RigCommon.ps1 parses, dot-sources it by a path that exists
    from the script's directory, and defines neither its own Say nor its own
    WindowsPrincipal admin check. Assert-Administrator, with Test-Administrator faked,
    throws the one message for each -Reason and is silent when elevated. Write-Summary
    appends each line, the empty one included, to the summary file. This works under pwsh
    on any OS. `python rig.py check` runs this.
#>
$ErrorActionPreference = "Stop"
$rig = Split-Path -Parent $PSScriptRoot
. (Join-Path $rig "powershell/RigCommon.ps1")

$failures = @()
function Expect([bool]$Ok, [string]$What) {
    if (-not $Ok) { $script:failures += $What }
}

# -- The scripts that share it -----------------------------------------------------------
$callers = @("tools/windows/capture-sysmon-etw.ps1", "tools/windows/observe-rdp.ps1",
             "runner/windows/validate-admin.ps1", "vagrant/hyperv/bootstrap.ps1",
             "vagrant/hyperv/helpers.ps1")
foreach ($caller in $callers) {
    $path = Join-Path $rig $caller
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    Expect (-not $errors) "$caller does not parse: $($errors | Select-Object -First 1)"
    $text = [System.IO.File]::ReadAllText($path)
    $match = [regex]::Match($text, '\. \(Join-Path \$PSScriptRoot "([^"]*RigCommon\.ps1)"\)')
    if (-not $match.Success) {
        Expect $false "$caller does not dot-source RigCommon.ps1"
        continue
    }
    $target = Join-Path (Split-Path -Parent $path) $match.Groups[1].Value
    Expect (Test-Path -LiteralPath $target) "$caller dot-sources $($match.Groups[1].Value), which does not exist"
    Expect (-not ($text -match 'function Say\b')) "$caller still defines its own Say"
    Expect (-not ($text -match 'WindowsPrincipal')) "$caller still checks the Administrator role itself"
}

# -- Assert-Administrator -----------------------------------------------------------------
function Get-AssertMessage([string]$Reason) {
    try { Assert-Administrator -Reason $Reason; return $null }
    catch { return $_.Exception.Message }
}
function Test-Administrator { $false }
foreach ($case in @(
        @{ Reason = "ETW sessions need it"; Want = "Run from an elevated PowerShell (ETW sessions need it)." },
        @{ Reason = "the Security log needs it"; Want = "Run from an elevated PowerShell (the Security log needs it)." },
        @{ Reason = ""; Want = "Run from an elevated PowerShell." })) {
    $got = Get-AssertMessage $case.Reason
    Expect ($got -ceq $case.Want) "Assert-Administrator -Reason '$($case.Reason)' threw '$got', not '$($case.Want)'"
}
function Test-Administrator { $true }
$got = Get-AssertMessage "ETW sessions need it"
Expect ($null -eq $got) "Assert-Administrator threw '$got' in an elevated session"

# -- Write-Summary ------------------------------------------------------------------------
$summary = Join-Path ([System.IO.Path]::GetTempPath()) ("rig-common-" + [guid]::NewGuid().ToString("N") + ".txt")
try {
    Write-Summary $summary "# title" 6>$null
    Write-Summary $summary "" 6>$null
    Write-Summary -Path $summary -Text ("  id {0,-3} {1}" -f 4, "events") 6>$null
    $lines = @(Get-Content -LiteralPath $summary)
    $want = @("# title", "", "  id 4   events")
    Expect (($lines -join "|") -ceq ($want -join "|")) "Write-Summary wrote '$($lines -join "|")', not '$($want -join "|")'"
    $printed = @(& { Write-Summary $summary "to the host" } 6>&1 | ForEach-Object { "$_" })
    Expect (($printed -join "|") -ceq "to the host") "Write-Summary printed '$($printed -join "|")', not 'to the host'"
}
finally {
    Remove-Item -LiteralPath $summary -ErrorAction SilentlyContinue
}

if ($failures) {
    $failures | ForEach-Object { Write-Error $_ -ErrorAction Continue }
    throw "powershell/RigCommon.ps1: $($failures.Count) check(s) failed"
}
Write-Output "rig: powershell/RigCommon.ps1 and its $($callers.Count) callers check out"
