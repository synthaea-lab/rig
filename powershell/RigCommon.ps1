<#
  Helpers every PowerShell script of the rig shares. Dot-source it with the path from the
  script to the rig root, for example from tools\windows:

    . (Join-Path $PSScriptRoot "../../powershell/RigCommon.ps1")

  Test-Administrator    whether this session is elevated ($true or $false, prints nothing)
  Assert-Administrator  throws "Run from an elevated PowerShell (<Reason>)." when it is not
  Write-Summary         prints a line and appends it to a summary file

  ASCII only, Windows PowerShell 5.1 compatible.
#>

function Test-Administrator {
  <# True when the current Windows identity holds the Administrator role (an elevated
     session). #>
  $principal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())
  $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-Administrator {
  <# Throws unless the session is elevated. $Reason says what needs the elevation; it goes
     in parentheses after the fixed sentence, so every script fails the same way. #>
  param([string]$Reason = "")
  if (Test-Administrator) { return }
  if ($Reason) { throw "Run from an elevated PowerShell ($Reason)." }
  throw "Run from an elevated PowerShell."
}

function Write-Summary {
  <# Writes $Text to the host and appends it, as one line, to the file $Path: the console
     and the summary file a capture leaves behind read the same. #>
  param(
    [Parameter(Mandatory, Position = 0)][string]$Path,
    [Parameter(Position = 1)][string]$Text = ""
  )
  Write-Host $Text
  Add-Content -Path $Path -Value $Text
}
