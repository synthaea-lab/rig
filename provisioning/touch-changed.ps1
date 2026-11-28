<#
  Stamps the source files that changed since the last upload with this guest's current time,
  so cargo rebuilds what depends on them (`python rig.py build <machine>` runs it after the
  sources are expanded).

  The uploaded zip carries the host's local times, which this guest reads in its own time zone
  and compares with its own clock. An expanded file can therefore look older than the last
  build although it changed after it, and cargo, which compares modification times, rebuilds
  nothing: the lab then tests a binary that is not the code it reports. rig.py lists the files
  whose content changed in <Root>\rig-changed.txt; only those are stamped, so an unchanged
  crate is not rebuilt.

    powershell -ExecutionPolicy Bypass -File C:\synthaea\rig\provisioning\touch-changed.ps1

  ASCII only, Windows PowerShell 5.1 compatible, strict mode (Latest).
#>
param(
  [string]$Root = "C:\synthaea"
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Set-ChangedFileTimes {
  <# Sets the modification time of each file listed in $List (paths relative to $Root, one per
     line) to $Now, and returns how many it stamped. A listed path that is not a file here is
     skipped: the list is written before the upload and a file may have been left out of it. #>
  param(
    [Parameter(Mandatory)][string]$Root,
    [Parameter(Mandatory)][string]$List,
    [Parameter(Mandatory)][datetime]$Now
  )
  $stamped = 0
  foreach ($relative in Get-Content -LiteralPath $List -Encoding UTF8) {
    if (-not $relative) { continue }
    $path = Join-Path $Root $relative
    if (Test-Path -LiteralPath $path -PathType Leaf) {
      (Get-Item -LiteralPath $path).LastWriteTime = $Now
      $stamped++
    }
  }
  $stamped
}

$list = Join-Path $Root "rig-changed.txt"
if (-not (Test-Path -LiteralPath $list)) { throw "$list missing: upload the sources first (python rig.py build <machine>)" }
$stamped = Set-ChangedFileTimes -Root $Root -List $list -Now (Get-Date)
Write-Host "sources changed since the last upload: $stamped file(s) stamped"
