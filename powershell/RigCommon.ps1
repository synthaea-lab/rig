<#
  Helpers every PowerShell script of the rig shares. Dot-source it with the path from the
  script to the rig root, for example from tools\windows:

    . (Join-Path $PSScriptRoot "../../powershell/RigCommon.ps1")

  Test-RigAdministrator    whether this session is elevated ($true or $false, prints nothing)
  Assert-RigAdministrator  throws "Run from an elevated PowerShell (<Reason>)." when it is not
  Write-RigSummary         prints a line and appends it to a summary file

  Every name carries "Rig" so that dot-sourcing this file never replaces a function of the
  same name, such as the scenarios' Assert-Administrator that validate-admin.ps1 also
  loads. tests/rig-common.ps1 checks that.

  ASCII only, Windows PowerShell 5.1 compatible.
#>

function Test-RigAdministrator {
  <# True when the current Windows identity holds the Administrator role (an elevated
     session). #>
  $principal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())
  $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-RigAdministrator {
  <# Throws unless the session is elevated. $Reason says what needs the elevation; it goes
     in parentheses after the fixed sentence, so every script fails the same way. #>
  param([string]$Reason = "")
  if (Test-RigAdministrator) { return }
  if ($Reason) { throw "Run from an elevated PowerShell ($Reason)." }
  throw "Run from an elevated PowerShell."
}

function Write-RigSummary {
  <# Writes $Text to the host and appends it, as one line, to the file $Path: the console
     and the summary file a capture leaves behind read the same. #>
  param(
    [Parameter(Mandatory, Position = 0)][string]$Path,
    [Parameter(Position = 1)][string]$Text = ""
  )
  Write-Host $Text
  Add-Content -Path $Path -Value $Text
}
