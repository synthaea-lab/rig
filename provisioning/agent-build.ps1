<#
  Builds the agent inside a provisioned Windows lab guest, from the sources rig.py
  uploaded to C:\synthaea (`python rig.py build <machine>`), and records what was built for the
  scenario runner's report. Windows counterpart of agent-build.sh: no eBPF, no offline mode,
  and ONNX Runtime comes from pyke's prebuilt MSVC archive (the agent's default features).

    powershell -ExecutionPolicy Bypass -File C:\synthaea\rig\provisioning\agent-build.ps1 [-Source "..."]

  Prerequisite: the `toolchain` provisioner (agent\packaging\toolchain\windows-toolchain.ps1) ran.
  ASCII only, Windows PowerShell 5.1 compatible.
#>
param(
  [string]$Source = "unknown (set by rig.py)",
  [string]$Root = "C:\synthaea",
  [string]$State = "C:\synthaea-rig"
)
$ErrorActionPreference = "Stop"

$agentDir = Join-Path $Root "agent"
if (-not (Test-Path (Join-Path $agentDir "Cargo.toml"))) {
  throw "$agentDir\Cargo.toml missing: upload the sources first (python rig.py build <machine>)"
}
$env:Path = "$env:USERPROFILE\.cargo\bin;$env:Path"
if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
  throw "no cargo: the guest is not provisioned (vagrant provision <machine>)"
}
New-Item -ItemType Directory -Force -Path $State | Out-Null

$sw = [Diagnostics.Stopwatch]::StartNew()
Push-Location $agentDir
try {
  # cargo reports progress on stderr; under WinRM that is not an error.
  $ErrorActionPreference = "Continue"
  & cargo build --release -p agent 2>&1 | ForEach-Object { "$_" } | Tee-Object -FilePath (Join-Path $State "build.log")
  $rc = $LASTEXITCODE
  $ErrorActionPreference = "Stop"
  if ($rc -ne 0) { throw "cargo build failed ($rc), see $State\build.log" }
  $rustc = (& rustc --version)
} finally {
  Pop-Location
}
$bin = Join-Path $agentDir "target\release\agent.exe"
if (-not (Test-Path $bin)) { throw "no binary at $bin" }

@(
  "agent_bin=$bin"
  "source=$Source"
  "built_at=$((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))"
  "build_seconds=$([int]$sw.Elapsed.TotalSeconds)"
  "profile=release"
  "ort=prebuilt"
  "offline=0"
  "rustc=$rustc"
) | Set-Content -LiteralPath (Join-Path $State "build-info") -Encoding Ascii
Get-Content (Join-Path $State "build-info")
