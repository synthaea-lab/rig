<#
.SYNOPSIS
    Checks the commands vagrant/hyperv/helpers.ps1 gives a Hyper-V session.

.DESCRIPTION
    Every function is named Verb-Noun with an approved verb, every short name (vup, vssh, ...)
    is an alias of one of them, and each command, called through its short name with the
    arguments it has always taken, runs the stated rig.py or vagrant command line. The
    functions and aliases are defined without running the top level (no elevation check, no
    environment changes), with python, vagrant and wsl faked. This works under pwsh on any OS.
    `python rig.py check` runs this.
#>
param(
    [string]$Script = (Join-Path (Split-Path -Parent $PSScriptRoot) "vagrant/hyperv/helpers.ps1")
)
$ErrorActionPreference = "Stop"

$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($Script, [ref]$tokens, [ref]$errors)
if ($errors) { throw "$Script does not parse: $($errors[0])" }

$failures = @()
function Assert-True([bool]$Ok, [string]$What) {
    if (-not $Ok) { $script:failures += $What }
}

# -- Names ---------------------------------------------------------------------------------
$functions = @($ast.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] })
$approved = @(Get-Verb | ForEach-Object { $_.Verb })
foreach ($function in $functions) {
    $verb, $noun = $function.Name -split '-', 2
    Assert-True ($noun -and $approved -contains $verb) "$($function.Name) is not Verb-Noun with an approved verb"
}
$aliasStatements = @($ast.EndBlock.Statements | Where-Object {
        $_ -is [System.Management.Automation.Language.PipelineAst] -and
        $_.PipelineElements[0] -is [System.Management.Automation.Language.CommandAst] -and
        $_.PipelineElements[0].GetCommandName() -eq "Set-Alias" })

$want = [ordered]@{
    vprep = "Initialize-LabSession"; vup = "Start-LabMachine"; vsync = "Sync-LabMachine"
    vssh = "Invoke-LabShell"; vhalt = "Stop-LabMachine"; vreset = "Reset-LabMachine"
    vbuild = "Build-LabAgent"; vstatus = "Get-LabAgentStatus"; vscen = "Invoke-LabScenario"
}

# -- Commands --------------------------------------------------------------------------------
# Defined in a child scope with fakes for the programs they call; each fake records its line.
$results = & {
    $LabMachine = "ubuntu2204"
    $LabRigCli = "RIG"
    $calls = [System.Collections.Generic.List[string]]::new()
    function python { $calls.Add("python " + ($args -join " ")) }
    function vagrant { $calls.Add("vagrant " + ($args -join " ")) }
    function wsl { $calls.Add("wsl " + ($args -join " ")) }
    . ([scriptblock]::Create(($functions | ForEach-Object { $_.Extent.Text }) -join "`n"))
    foreach ($statement in $aliasStatements) { . ([scriptblock]::Create($statement.Extent.Text)) }

    $aliases = @{}
    foreach ($name in $want.Keys) {
        $alias = Get-Alias -Name $name -ErrorAction SilentlyContinue
        $aliases[$name] = if ($alias) { $alias.Definition } else { $null }
    }

    $guest = { param($line) $b64 = ($line -split " ")[5]; [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64)) }
    $lines = [ordered]@{}
    foreach ($case in @(
            @{ Call = { vup }; Name = "vup" },
            @{ Call = { vup debian12 }; Name = "vup debian12" },
            @{ Call = { vsync debian12 }; Name = "vsync debian12" },
            @{ Call = { vssh }; Name = "vssh" },
            @{ Call = { vssh debian12 'uname -r; id' }; Name = "vssh debian12 snippet" },
            @{ Call = { vhalt debian12 }; Name = "vhalt debian12" },
            @{ Call = { vreset debian12 }; Name = "vreset debian12" },
            @{ Call = { vbuild }; Name = "vbuild" },
            @{ Call = { vbuild debian12 "--offline  --ort static" }; Name = "vbuild debian12 flags" },
            @{ Call = { vstatus debian12 }; Name = "vstatus debian12" },
            @{ Call = { vscen }; Name = "vscen" },
            @{ Call = { vscen "beacon dns-exfil" }; Name = "vscen two" },
            @{ Call = { vscen "argv" debian12 }; Name = "vscen argv debian12" })) {
        $calls.Clear()
        & $case.Call
        $lines[$case.Name] = @($calls | ForEach-Object {
                if ($_ -match '^vagrant ssh \S+ -c echo ') { ($_ -split " ", 5)[0..3] -join " "; "guest: " + (& $guest $_) } else { $_ }
            })
    }
    @{ Aliases = $aliases; Lines = $lines }
}

foreach ($name in $want.Keys) {
    Assert-True ($results.Aliases[$name] -eq $want[$name]) "$name is an alias of '$($results.Aliases[$name])', not $($want[$name])"
}

$snippetPrefix = "guest: source ~/.cargo/env 2>/dev/null || true`n"
$expected = [ordered]@{
    "vup"                   = @("python RIG up ubuntu2204")
    "vup debian12"          = @("python RIG up debian12")
    "vsync debian12"        = @("vagrant rsync debian12")
    "vssh"                  = @("vagrant ssh ubuntu2204")
    "vssh debian12 snippet" = @("vagrant ssh debian12 -c", "${snippetPrefix}uname -r; id")
    "vhalt debian12"        = @("python RIG down debian12")
    "vreset debian12"       = @("python RIG down debian12 --destroy", "python RIG up debian12")
    "vbuild"                = @("python RIG build ubuntu2204")
    "vbuild debian12 flags" = @("python RIG build debian12 --offline --ort static")
    "vstatus debian12"      = @("vagrant ssh debian12 -c", "${snippetPrefix}sudo `$(sed -n `"s/^agent_bin=//p`" ~/synthaea-rig/build-info) status")
    "vscen"                 = @("python RIG run ubuntu2204")
    "vscen two"             = @("python RIG run ubuntu2204 beacon dns-exfil")
    "vscen argv debian12"   = @("python RIG run debian12 argv")
}
foreach ($name in $expected.Keys) {
    $got = @($results.Lines[$name])
    $ok = ($got.Count -eq $expected[$name].Count) -and -not (Compare-Object $got $expected[$name] -SyncWindow 0 -CaseSensitive)
    Assert-True $ok "${name}: ran $(($got | ForEach-Object { "[$_]" }) -join ' '), not $(($expected[$name] | ForEach-Object { "[$_]" }) -join ' ')"
}

if ($failures) {
    $failures | ForEach-Object { Write-Output "FAIL: $_" }
    exit 1
}
Write-Output "rig: vagrant/hyperv/helpers.ps1 names its commands Verb-Noun, keeps the short aliases, and runs them as stated"
