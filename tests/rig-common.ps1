<#
.SYNOPSIS
    Checks powershell/RigCommon.ps1 and the scripts that dot-source it.

.DESCRIPTION
    Every rig script that names RigCommon.ps1 parses, dot-sources it by a path that exists
    from the script's directory, and defines neither its own Say nor its own
    WindowsPrincipal admin check. RigCommon's names all carry "Rig" and none is also defined
    by the scenarios sibling's common.ps1, which validate-admin.ps1 loads in the same scope;
    helpers.ps1 keeps RigCommon out of the session it is dot-sourced into.
    Assert-RigAdministrator, with Test-RigAdministrator faked,
    throws the one message for each -Reason and is silent when elevated. Write-RigSummary
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

# -- No name another loaded file defines ---------------------------------------------------
function Get-DefinedFunctions([string]$Path) {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
    @($ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false) |
        ForEach-Object { $_.Name })
}
$rigNames = Get-DefinedFunctions (Join-Path $rig "powershell/RigCommon.ps1")
foreach ($name in $rigNames) {
    Expect ($name -match '^[A-Za-z]+-Rig') "RigCommon.ps1 defines $name, a name without the Rig prefix"
}
# validate-admin.ps1 dot-sources the scenarios sibling's common.ps1 and then RigCommon.ps1
# into one scope: neither may replace a function of the other, in either load order.
$common = Join-Path (Split-Path -Parent $rig) "scenarios/scenarios/common.ps1"
if (Test-Path -LiteralPath $common) {
    $shared = @(Get-DefinedFunctions $common | Where-Object { $rigNames -contains $_ })
    Expect ($shared.Count -eq 0) "RigCommon.ps1 and scenarios/common.ps1 both define $($shared -join ', ')"
    $loads = @(
        @((Join-Path $rig "powershell/RigCommon.ps1"), $common),
        @($common, (Join-Path $rig "powershell/RigCommon.ps1")))
    foreach ($order in $loads) {
        $params = & {
            foreach ($file in $order) { . $file }
            $scenariosCmd = Get-Command Assert-Administrator -ErrorAction SilentlyContinue
            $rigCmd = Get-Command Assert-RigAdministrator -ErrorAction SilentlyContinue
            @{ Scenarios = @(if ($scenariosCmd) { $scenariosCmd.Parameters.Keys })
               Rig       = @(if ($rigCmd) { $rigCmd.Parameters.Keys }) }
        }
        Expect ($params.Scenarios -contains "Message") "after loading both, Assert-Administrator is not the scenarios one (-Message)"
        Expect ($params.Rig -contains "Reason") "after loading both, Assert-RigAdministrator has no -Reason"
    }
}
else {
    Write-Output "rig: no scenarios checkout next to the rig; skipped the name check against its common.ps1"
}
$validate = [System.IO.File]::ReadAllText((Join-Path $rig "runner/windows/validate-admin.ps1"))
Expect ($validate -match 'Assert-RigAdministrator -Reason') "validate-admin.ps1 does not call Assert-RigAdministrator"
# helpers.ps1 is dot-sourced into the user's interactive session: it loads RigCommon in a
# child scope, so the session gets the lab commands and none of RigCommon's functions.
$helpers = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $rig "vagrant/hyperv/helpers.ps1"), [ref]$null, [ref]$null)
$topLevelDot = @($helpers.EndBlock.Statements | Where-Object {
        $_ -is [System.Management.Automation.Language.PipelineAst] -and
        $_.PipelineElements[0] -is [System.Management.Automation.Language.CommandAst] -and
        $_.PipelineElements[0].InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Dot })
Expect ($topLevelDot.Count -eq 0) "vagrant/hyperv/helpers.ps1 dot-sources a file into the session it is loaded in"

# -- Assert-RigAdministrator -----------------------------------------------------------------
function Get-AssertMessage([string]$Reason) {
    try { Assert-RigAdministrator -Reason $Reason; return $null }
    catch { return $_.Exception.Message }
}
function Test-RigAdministrator { $false }
foreach ($case in @(
        @{ Reason = "ETW sessions need it"; Want = "Run from an elevated PowerShell (ETW sessions need it)." },
        @{ Reason = "the Security log needs it"; Want = "Run from an elevated PowerShell (the Security log needs it)." },
        @{ Reason = ""; Want = "Run from an elevated PowerShell." })) {
    $got = Get-AssertMessage $case.Reason
    Expect ($got -ceq $case.Want) "Assert-RigAdministrator -Reason '$($case.Reason)' threw '$got', not '$($case.Want)'"
}
function Test-RigAdministrator { $true }
$got = Get-AssertMessage "ETW sessions need it"
Expect ($null -eq $got) "Assert-RigAdministrator threw '$got' in an elevated session"

# -- Write-RigSummary ------------------------------------------------------------------------
$summary = Join-Path ([System.IO.Path]::GetTempPath()) ("rig-common-" + [guid]::NewGuid().ToString("N") + ".txt")
try {
    Write-RigSummary $summary "# title" 6>$null
    Write-RigSummary $summary "" 6>$null
    Write-RigSummary -Path $summary -Text ("  id {0,-3} {1}" -f 4, "events") 6>$null
    $lines = @(Get-Content -LiteralPath $summary)
    $want = @("# title", "", "  id 4   events")
    Expect (($lines -join "|") -ceq ($want -join "|")) "Write-RigSummary wrote '$($lines -join "|")', not '$($want -join "|")'"
    $printed = @(& { Write-RigSummary $summary "to the host" } 6>&1 | ForEach-Object { "$_" })
    Expect (($printed -join "|") -ceq "to the host") "Write-RigSummary printed '$($printed -join "|")', not 'to the host'"
}
finally {
    Remove-Item -LiteralPath $summary -ErrorAction SilentlyContinue
}

if ($failures) {
    $failures | ForEach-Object { Write-Error $_ -ErrorAction Continue }
    throw "powershell/RigCommon.ps1: $($failures.Count) check(s) failed"
}
Write-Output "rig: powershell/RigCommon.ps1 and its $($callers.Count) callers check out"
