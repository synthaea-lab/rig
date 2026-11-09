# Windows guests and Hyper-V hosts

Windows enters the rig in two independent ways: as a **guest** (`win11`, `win10`,
`winserver`), where the agent's ETW and Event Log sensors are built and tested, and as a
**host**, where Hyper-V runs Linux and Windows guests. This page covers both, plus the
Windows-only validation and capture scripts.

## Windows guests

### How they differ from Linux guests

| | Linux guest | Windows guest |
| --- | --- | --- |
| Channel | `vagrant ssh`, bash | `vagrant winrm --shell powershell` |
| Sources | rsync to `/synthaea/<name>` | Zip upload expanded over `C:\synthaea` ([architecture.md](architecture.md#syncing-the-sources)) |
| Toolchain | rustup, eBPF nightly, bpf-linker, LLVM | rustup `stable-msvc`, Visual Studio Build Tools (C++ workload, Windows SDK) |
| Build | [`agent-build.sh`](../provisioning/agent-build.sh) | [`agent-build.ps1`](../provisioning/agent-build.ps1) |
| Runner | [`run-scenarios.sh`](../runner/run-scenarios.sh) | [`run-scenarios.ps1`](../runner/run-scenarios.ps1) |
| Catalog | [`scenarios.conf`](../runner/scenarios.conf) | [`scenarios-windows.conf`](../runner/scenarios-windows.conf) |
| State | `~/synthaea-rig` | `C:\synthaea-rig` |

The Windows sensors are pure-Rust bindings to DLLs Windows already ships (ETW through
`ferrisetw`, the Event Log, the service control manager), so there is no LLVM version to
align and no nightly toolchain. What Rust does not provide on Windows is the MSVC linker and
the Windows SDK import libraries, which the Build Tools install brings.

The guest scripts are ASCII-only and compatible with Windows PowerShell 5.1, the version every
Windows box ships, so nothing needs installing before the rig can drive a guest.
`run-scenarios.ps1` and [`LabAgent.ps1`](../runner/LabAgent.ps1) run under
`Set-StrictMode -Version Latest`.

### The Windows runner

`python rig.py run win11` runs `run-scenarios.ps1 -Machine win11 -Source <description>
[scenario ...]` in an elevated WinRM session. It follows the Linux
[scenario lifecycle](scenario-runs.md#one-scenario) with these differences:

- **Catalog.** `scenarios-windows.conf` has four columns: `name`, `set`, `expect` and `note`.
  The Windows scenarios have no `.yaml` sidecar yet, so `expect` carries what each script's
  header says must fire, as comma-separated `technique:min_count:tolerance` triples. When a
  scenario has a sidecar, the runner reads the sidecar and ignores `expect`. There are no
  `root`, `needs`, `min_kernel`, `agent_flags`, `env`, `yara` or `settle` columns, so the
  Windows runner never SKIPs and always settles for 3 s.
- **Configuration.** Each scenario's agent gets its own `agent.toml`, written by
  `New-LabAgentConfig` from [`runner/lab-agent.toml.template`](../runner/lab-agent.toml.template):
  the control plane is a `.invalid` host, logs, state and certificates live under the
  scenario's run directory, and the local IPC endpoint is a named pipe of its own. Nothing
  is installed system-wide.
- **Agent.** `agent.exe --config <dir>\agent.toml run --standalone --content-dir C:\synthaea
  --alerts ... --events ...`, started hidden. The content directory is the root, which holds
  `rules\`.
- **Readiness** is the first event written to `events.jsonl`, within 45 s, then 2 s more:
  ETW has no single "listening" line, and a written event proves the trace session runs.
- **Script.** Each `.ps1` runs in a child `powershell -NoProfile -ExecutionPolicy Bypass`,
  all output streams to `scenario.log`, with no timeout and without the `EVENTS`, `ALERTS`
  and `AGENT_PID` variables the Linux runner sets. The error preference is `Continue` inside that
  function only: under `Stop`, Windows PowerShell 5.1 turns each stderr line of a native
  command into a terminating error, and a scenario's errors are data for the verdict, not a
  reason to stop the runner.
- **Stop.** `Stop-Process -Force` on the agent's own PID, never by name, so a stray agent
  of another script is never killed. The runner refuses to start when an `agent.exe` is
  already running.
- **Judging** applies the same rules (FAIL, then ERROR, then UNEXPECTED, then PASS;
  `RESPONSE-ESCALATE` not judged), but writes `x` for `×` and `/` between tally items, since
  the scripts stay ASCII.
- **Report.** The header shows the Windows caption and build instead of kernel, LSMs and
  verifier, and there is no agent-warning section.

[`LabAgent.ps1`](../runner/LabAgent.ps1) holds the agent lifecycle (`New-LabAgentConfig`,
`Start-LabAgent`, `Wait-AgentEvents`, `Stop-LabAgent`) that the runner and the admin
validation share. Every function acts only on the handle it is given and sets no
script-scope state, so a caller that must stop agents in a `finally` block keeps its handles
itself.

The Windows runner has not yet run end to end on a lab VM; its parts are tested against
fakes by `rig.py check` ([testing.md](testing.md)).

### Running the toolchain script by hand

The `toolchain` provisioner runs
[`windows-toolchain.ps1`](https://github.com/synthaea-lab/agent/blob/main/packaging/toolchain/windows-toolchain.ps1)
on the first `up`. To run it yourself in a guest:

- **Execution policy.** Windows 11 defaults to `Restricted`. Bypass it for one process:

  ```powershell
  powershell -ExecutionPolicy Bypass -File windows-toolchain.ps1
  ```

- **Logging.** Use `Start-Transcript`, not `Tee-Object`: with `$ErrorActionPreference =
  'Stop'`, redirecting turns `rustup-init`'s routine stderr warning into a fatal error.

  ```powershell
  Start-Transcript -Path log.txt
  .\windows-toolchain.ps1
  Stop-Transcript
  ```

- **A second Rust toolchain on the first build** is expected: the script installs
  `stable-msvc`, the agent pins its own version in `rust-toolchain.toml`, and the first
  `cargo build` fetches it (about 150 MB).

### Installing a built agent

The runner uses a standalone agent per scenario. To test the packaged service path instead
(the watchdog supervising the agent, as on a production endpoint), stage a release build
with [`provisioning/agent-install.ps1`](../provisioning/agent-install.ps1) from an elevated
PowerShell in the guest:

```powershell
.\agent-install.ps1 -SourceDir C:\synthaea\agent\target\release -InstallService
```

| Parameter | Default | Meaning |
| --- | --- | --- |
| `-SourceDir` or `-AgentZip` | | Exactly one: a directory or zip holding `agent.exe`, `watchdog.exe` and optionally `rules\sigma` and `rules\yara` |
| `-InstallDir` | `C:\Synthaea` | Where the binaries go |
| `-StateDir` | `C:\ProgramData\Synthaea\state` | The agent's `storage.state_dir`. Content goes to `<StateDir>\content`; it must match the `agent.toml` in use, or the agent starts with no rules |
| `-InstallService` | off | Registers the watchdog service (`watchdog.exe install`). Without it, the binaries are staged and nothing starts |

The script stops a previous install first (an `agent.exe` in use cannot be overwritten) and
replaces content directories rather than copying into them, so it is safe to re-run.

## Hyper-V hosts

### Host setup

Once, from an elevated PowerShell in the rig checkout:

```powershell
powershell -ExecutionPolicy Bypass -File vagrant\hyperv\bootstrap.ps1
```

[`bootstrap.ps1`](../vagrant/hyperv/bootstrap.ps1) enables the Hyper-V feature (a reboot
may be needed, then re-run it), adds you to *Hyper-V Administrators*, installs Vagrant if
missing, and checks that the *Default Switch* exists. You also need an `rsync` on `PATH` for
Linux guests: Git for Windows ships one in `C:\Program Files\Git\usr\bin`, or install
cwRsync.

Every command that touches a VM (`up`, `halt`, `ssh`, `rsync`, `destroy`) needs an elevated
shell; `rig.py` sets `VAGRANT_HYPERV_SWITCH=Default Switch` to skip the switch prompt. With a
second switch present, Vagrant may still print the menu; answer with the Default Switch's
number.

### Memory

Hyper-V Linux guests use Dynamic Memory starting at 2 GB ([machines.md](machines.md#providers-and-resources)).
A VM that cannot get its startup memory fails with `0x800705AA` ("insufficient system
resources"). On a 16 GB host, run `wsl --shutdown` and close memory-heavy applications
first, and halt a finished VM before starting the next.

### PowerShell helpers

[`vagrant/hyperv/helpers.ps1`](../vagrant/hyperv/helpers.ps1), dot-sourced into an elevated
session, adds commands that call `rig.py` where it covers the step:

```powershell
. rig\vagrant\hyperv\helpers.ps1
Initialize-LabSession
Start-LabMachine debian12
Build-LabAgent debian12 "--ort-compat"
Invoke-LabScenario "beacon dns-exfil" debian12
```

| Command | Alias | Does |
| --- | --- | --- |
| `Initialize-LabSession` | `vprep` | `wsl --shutdown`, checks for `rsync`, sets the switch variable, warns when free RAM is low |
| `Start-LabMachine` | `vup` | `rig.py up` |
| `Sync-LabMachine` | `vsync` | `vagrant rsync` |
| `Invoke-LabShell` | `vssh` | `vagrant ssh`, or runs a bash snippet in the guest |
| `Stop-LabMachine` | `vhalt` | `rig.py down` |
| `Reset-LabMachine` | `vreset` | `rig.py down --destroy`, then `rig.py up` |
| `Build-LabAgent` | `vbuild` | `rig.py build`, with flags as one space-separated string |
| `Get-LabAgentStatus` | `vstatus` | `agent status` in the guest |
| `Invoke-LabScenario` | `vscen` | `rig.py run`, with scenario names as one space-separated string |

Every command takes an optional machine name and otherwise uses `$LabMachine`
(`ubuntu2204` by default). The helpers set `VAGRANT_CWD`, so they work from any directory.

`Invoke-LabShell <machine> '<snippet>'` base64-encodes the snippet and decodes it in the
guest (`echo <b64> | base64 -d | bash`), after sourcing `~/.cargo/env`. A raw
`vagrant ssh -c "..."` from PowerShell is not reliable: PowerShell's native-argument parsing
mangles embedded quotes, `$(...)` and arguments that start with a dash before Vagrant sees
them.

```powershell
vssh debian12 'bash /synthaea/rig/tools/diagnose-ebpf-toolchain.sh'
```

Once a VM runs, plain SSH with the key Vagrant generated works from any shell, without
elevation:

```powershell
$ip = (Get-VM synthaea-debian12 | Get-VMNetworkAdapter).IPAddresses[0]
ssh -i vagrant\.vagrant\machines\debian12\hyperv\private_key vagrant@$ip
```

### Default Switch networking

The Default Switch is a NAT whose DNS forwarding is not always reliable. When a guest
cannot resolve `static.crates.io` or `static.rust-lang.org`:

- In the guest, pin public resolvers (this replaces a `systemd-resolved` stub or a missing
  file alike):

  ```powershell
  vssh debian12 'test -L /etc/resolv.conf && sudo rm -f /etc/resolv.conf; printf "nameserver 1.1.1.1\nnameserver 8.8.8.8\n" | sudo tee /etc/resolv.conf >/dev/null'
  ```

- On the host, from an elevated PowerShell, restart the switch's adapter and the Host
  Network Service, and disconnect any VPN while the lab runs:

  ```powershell
  Get-NetAdapter 'vEthernet (Default Switch)' | Restart-NetAdapter
  Restart-Service hns
  ```

Community boxes for the 6.8, 6.12 and Fedora targets need one-time fix-ups on Hyper-V
(kernel pinning, LVM resizing, a missing `rsync`), documented in
[vagrant/README.md](../vagrant/README.md#hyper-v-community-boxes-68--612-fedora).

## Validation and capture scripts

These run by hand, elevated, inside a Windows guest. They test sensor behaviour that a
scenario cannot express (ETW session limits, raw provider output) or observe what Windows
logs before a detection is written. Each loads
[`powershell/RigCommon.ps1`](../powershell/RigCommon.ps1) for its admin check
(`Assert-RigAdministrator`); the two capture scripts also use its `Write-RigSummary`, which
prints a line and appends it to `summary.txt`, so the console and the file read the same.
Every RigCommon name carries `Rig`, so dot-sourcing it never replaces a function of the same
name in the scenarios' `common.ps1`.

### `runner/windows/validate-admin.ps1`

[`validate-admin.ps1`](../runner/windows/validate-admin.ps1) validates the ETW sensor live, in
phases that can each be skipped:

| Phase | Checks | Skip with |
| --- | --- | --- |
| A | Orphaned ETW sessions: one left by a killed agent and two synthetic `wtrace-` ones are all stopped at agent start, events flow, and the sweep's own `logman.exe` children raise no self-spawn alert | `-SkipOrphans` |
| B | Root cause of a starved session: a manifest provider can be enabled by at most 8 sessions at once, so for each count in `-ProbeCounts` (default 0, 2, 6, 7, 8) it starts that many real-time sessions enabling the agent's providers and records which event types still arrive | `-SkipRootCause` |
| C | 8.3 short paths: mark-of-the-web streams written through short and long paths of the same files give one quarantine event per file, no `~` in event paths, and a long-form path in the download alert | `-SkipLongPath` |
| D | A raw Kernel-File trace around `Unblock-File` and `Remove-Item -Stream Zone.Identifier`, no agent, to see which events a mark removal produces | `-SkipMarkRemoval` |
| E | Mark removal end to end: one `file_delete` of each stream and one `T1553.005` alert per file | `-SkipMarkRemoval` |
| F | The agent's ignored Kernel-File keyword-mask integration test, run as administrator | `-SkipKernelFileMask` |
| G | The same for Kernel-Process: process and image events arrive, thread events do not | `-SkipKernelProcessMask` |

It expects the checkouts under `-Root` (default: the directory holding `rig\`): `agent\`,
where phases F and G run `cargo test`, and `scenarios\`, for its `common.ps1`. It does not
build the agent: it uses `agent\target\release\agent.exe` unless `-AgentExe` says otherwise. Results go to
`summary.txt` under `-OutDir` (default `agent\target\lab-validation\<timestamp>`), with each
phase's agent logs, events and alerts beside it. About 6 minutes with the defaults.

```powershell
cd C:\synthaea\agent; cargo build --release -p agent
powershell -ExecutionPolicy Bypass -File C:\synthaea\rig\runner\windows\validate-admin.ps1
```

### `tools/windows/capture-sysmon-etw.ps1`

[`capture-sysmon-etw.ps1`](../tools/windows/capture-sysmon-etw.ps1) is a passive capture: it
never installs, configures, starts or stops Sysmon and attacks nothing. Phase A inventories
the Sysmon channel (logs, services, and for the newest `-SysmonSample` events the count, field
names and rate per event ID, with the raw sample exported as XML). Phase B checks whether two
driver-free ETW providers (`Microsoft-Windows-Kernel-Process` thread events and
`Microsoft-Windows-Kernel-Audit-API-Calls`) can be enabled by a non-PPL session, and what they
deliver during an idle and a busy window (`-IdleSeconds`, `-BusySeconds`, 60 s each), with
loss counters. The full procedure, with Sysmon installed for the capture, is
[sysmon-capture.md](sysmon-capture.md).

### `tools/windows/observe-rdp.ps1`

[`observe-rdp.ps1`](../tools/windows/observe-rdp.ps1) records which events one failed and
one successful Remote Desktop logon leave behind, and in which order: Security 4624 and 4625
(logon types 3 and 10), RemoteConnectionManager (1149 among others) and LocalSessionManager
(21 to 25). A detection that pairs failures with a later success depends on whether 1149 is
written for refused credentials, which varies with Network Level Authentication. The script
connects to nothing: you make the connections by hand while it waits, once per NLA setting,
then it writes `timeline.csv` and `summary.txt`. `-SinceMinutes N` analyses the last N
minutes without prompting.
