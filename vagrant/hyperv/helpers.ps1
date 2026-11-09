<#
  Dot-source this for the Hyper-V lab commands. RUN FROM AN ELEVATED PowerShell -- the
  Hyper-V provider needs elevation for every command that touches a VM.
  The cross-platform way is `python rig.py up/build/run` (README.md); these commands call
  rig.py for the steps it covers, from a PowerShell session that lives in rig\vagrant.

    . rig\vagrant\hyperv\helpers.ps1   # dot-source (note the leading dot + space)

    Command                 Short   What it does
    Initialize-LabSession   vprep   wsl --shutdown + check rsync + set the switch + free RAM
    Start-LabMachine        vup     rig.py up: boot + provision the machine
    Sync-LabMachine         vsync   vagrant rsync: re-push the sources
    Invoke-LabShell         vssh    vagrant ssh, or run a bash snippet in the guest
    Stop-LabMachine         vhalt   rig.py down: halt the VM
    Reset-LabMachine        vreset  rig.py down --destroy + rig.py up (clean rollback)
    Build-LabAgent          vbuild  rig.py build: provisioning/agent-build.sh in the VM
    Get-LabAgentStatus      vstatus the agent's verifier check (status) in the VM
    Invoke-LabScenario      vscen   rig.py run: scenarios + report copied to reports/

  The short names are aliases, kept for muscle memory; they take the same arguments.

  First-run host setup is .\bootstrap.ps1 (Hyper-V feature, group, Vagrant, Default
  Switch) -- once, not every session.

  Every command takes an optional machine name; it defaults to $LabMachine
  ("ubuntu2204"). Set $LabMachine = "debian12" to switch the default.
#>

$ErrorActionPreference = "Stop"

# RigCommon is loaded in a child scope: this file is dot-sourced into the user's session,
# which should end up with the lab commands below and nothing else.
if (-not (& { . (Join-Path $PSScriptRoot "../../powershell/RigCommon.ps1"); Test-RigAdministrator })) {
  Write-Warning "Not elevated -- vagrant up/ssh/halt/destroy will fail. Re-open PowerShell as Administrator."
}

# Meant to skip the interactive switch prompt on `vagrant up`. Note: with two
# switches present ("Default Switch" + "WSL (Hyper-V firewall)") Vagrant 2.4.9
# still prints the menu -- just answer 1. Setting it does no harm.
$env:VAGRANT_HYPERV_SWITCH = "Default Switch"
# The one Vagrantfile lives in rig\vagrant, whichever directory this session is in.
$env:VAGRANT_CWD = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$env:VAGRANT_DEFAULT_PROVIDER = "hyperv"

# Default target machine for every command below.
$LabMachine = "ubuntu2204"
# The rig's CLI, which the commands call for every step it covers.
$LabRigCli = (Resolve-Path (Join-Path $PSScriptRoot "../../rig.py")).Path

function Resolve-LabMachineName([string]$Name) {
  <# The machine a command targets: $Name, or $LabMachine when none is given. #>
  if ($Name) { return $Name }
  return $LabMachine
}

function Invoke-RigCli([string[]]$Arguments) {
  <# Runs `python rig.py <Arguments>`; its exit code is left in $LASTEXITCODE. #>
  python $LabRigCli @Arguments
}

function Split-LabWords([string]$Words) {
  <# The space-separated words of $Words, as separate arguments (none for an empty string). #>
  @($Words -split '\s+' | Where-Object { $_ })
}

function Initialize-LabSession {
  <#
    Per-session prep before Start-LabMachine (vup), in order:
      1. wsl --shutdown  -- the boxes ask for 4 GB; reclaim it from WSL first
      2. check an rsync is on PATH (Vagrant needs one for the synced folder --
         Git for Windows ships one, or `choco install rsync` / `winget install cwRsync`)
      3. (re)assert the switch env var
      4. warn when too little RAM is free for the VM to start
  #>
  Write-Host "wsl --shutdown" -ForegroundColor Cyan
  wsl --shutdown
  $rsync = (Get-Command rsync -ErrorAction SilentlyContinue).Source
  if ($rsync) {
    Write-Host "rsync: $rsync" -ForegroundColor Green
  } else {
    Write-Warning "no rsync on PATH -- `vagrant up` will fail to sync the repo. Install cwRsync or Git-for-Windows rsync."
  }
  $env:VAGRANT_HYPERV_SWITCH = "Default Switch"
  Write-Host "VAGRANT_HYPERV_SWITCH = $env:VAGRANT_HYPERV_SWITCH" -ForegroundColor Green

  # The VM boots at 1 GB (Dynamic Memory, see Vagrantfile). Under ~1.5 GB free,
  # `vagrant up` dies with 0x800705AA -- warn before the 30 s import + failure.
  $freeMB = [int]((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1KB)
  if ($freeMB -lt 1536) {
    Write-Warning "only ${freeMB} MB RAM free -- close a browser/IDE before Start-LabMachine (Hyper-V needs ~1 GB to start the VM)."
  } else {
    Write-Host "RAM free: ${freeMB} MB" -ForegroundColor Green
  }
}

function Start-LabMachine {
  <# Bring the machine up (creates + provisions on first run). #>
  param([string]$Machine)
  Invoke-RigCli @("up", (Resolve-LabMachineName $Machine))
}

function Sync-LabMachine {
  <# Re-push the rig's root to /synthaea after host-side edits (one-way rsync). Build-LabAgent
     and Invoke-LabScenario sync first on their own. #>
  param([string]$Machine)
  vagrant rsync (Resolve-LabMachineName $Machine)
}

function Invoke-LabRemote {
  <#
    Run a bash snippet in the guest. The snippet is base64'd and decoded inside
    the VM so it survives untouched through PowerShell's native-arg parser,
    vagrant, and ssh -- otherwise embedded quotes / `$(...)` / leading-dash
    tokens (`curl -fSL ...`) get mangled and vagrant rejects them as options.
    ~/.cargo/env is sourced first; the snippet sets its own `set -e` if it wants
    fail-fast.
  #>
  param([string]$Machine, [string]$Script)
  $m = Resolve-LabMachineName $Machine
  $full = "source ~/.cargo/env 2>/dev/null || true`n" + $Script
  $b64  = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($full))
  vagrant ssh $m -c "echo $b64 | base64 -d | bash"
}

function Invoke-LabShell {
  <# Interactive shell, or `Invoke-LabShell ubuntu2204 'cmd; cmd'` to run a bash snippet. #>
  param([string]$Machine, [string]$Command)
  $m = Resolve-LabMachineName $Machine
  if ($Command) { Invoke-LabRemote $m $Command } else { vagrant ssh $m }
}

function Stop-LabMachine {
  <# Halt the VM; Reset-LabMachine deletes it instead. #>
  param([string]$Machine)
  Invoke-RigCli @("down", (Resolve-LabMachineName $Machine))
}

function Reset-LabMachine {
  <# Clean rollback: destroy the VM and bring a fresh one up + provisioned. #>
  param([string]$Machine)
  $m = Resolve-LabMachineName $Machine
  Invoke-RigCli @("down", $m, "--destroy")
  Invoke-RigCli @("up", $m)
}

function Build-LabAgent {
  <# Build the agent in the VM (rig.py build: sync, then provisioning/agent-build.sh). $Flags
     are rig.py build's, space-separated, e.g. "--offline" or "--ort static --ort-compat". #>
  param([string]$Machine, [string]$Flags = "")
  Invoke-RigCli (@("build", (Resolve-LabMachineName $Machine)) + @(Split-LabWords $Flags))
}

function Get-LabAgentStatus {
  <# Verifier check: loads all sensor programs and reports (needs a prior Build-LabAgent). #>
  param([string]$Machine)
  Invoke-LabRemote (Resolve-LabMachineName $Machine) 'sudo $(sed -n "s/^agent_bin=//p" ~/synthaea-rig/build-info) status'
}

function Invoke-LabScenario {
  <#
    Run scenarios through the lab runner (rig.py run: sync, run, copy the report to reports/).
      Invoke-LabScenario                      # every default scenario
      Invoke-LabScenario "beacon dns-exfil"   # just these
      Invoke-LabScenario "argv" debian12
  #>
  param([string]$Scenarios = "", [string]$Machine)
  Invoke-RigCli (@("run", (Resolve-LabMachineName $Machine)) + @(Split-LabWords $Scenarios))
}

Set-Alias -Name vprep -Value Initialize-LabSession
Set-Alias -Name vup -Value Start-LabMachine
Set-Alias -Name vsync -Value Sync-LabMachine
Set-Alias -Name vssh -Value Invoke-LabShell
Set-Alias -Name vhalt -Value Stop-LabMachine
Set-Alias -Name vreset -Value Reset-LabMachine
Set-Alias -Name vbuild -Value Build-LabAgent
Set-Alias -Name vstatus -Value Get-LabAgentStatus
Set-Alias -Name vscen -Value Invoke-LabScenario

Write-Host "lab commands loaded: Initialize-LabSession (vprep), Start-LabMachine (vup), Sync-LabMachine (vsync), Invoke-LabShell (vssh), Stop-LabMachine (vhalt), Reset-LabMachine (vreset), Build-LabAgent (vbuild), Get-LabAgentStatus (vstatus), Invoke-LabScenario (vscen)  (default machine: $LabMachine)" -ForegroundColor Green
