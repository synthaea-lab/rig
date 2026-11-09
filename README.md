# rig — the Synthaea testing rig

Boot a VM from the machine matrix, build the [Synthaea agent](https://github.com/synthaea-lab/agent)
inside it, run the [attack scenarios](https://github.com/synthaea-lab/scenarios) against it,
and get a report of what each scenario expects versus what fired. Five commands, the same on
a Linux, Windows or macOS host:

```
python rig.py up debian12        # boot (and on first boot provision) a VM from machines.json
python rig.py build debian12     # sync the checkouts into it, build the agent there, verifier check
python rig.py run debian12       # run every safe scenario against the agent, copy the report here
python rig.py report debian12    # print it (reports/<date>-debian12.md)
python rig.py down debian12      # halt the VM
```

(`just <command>` from this directory is the same thing: `just up debian12`, ...)

## Setup

The rig works on a **root directory** holding the checkouts it builds and runs, side by side
with the rig itself:

```
synthaea/                 any name: the rig's root (RIG_ROOT overrides it)
├── agent/                https://github.com/synthaea-lab/agent      the agent to build
├── rules/                https://github.com/synthaea-lab/rules      detection content it loads
├── scenarios/            https://github.com/synthaea-lab/scenarios  scripts + .yaml expectations
├── server/               https://github.com/synthaea-lab/server     optional: control-plane runs
└── rig/                  this repository
```

```sh
mkdir synthaea && cd synthaea
for r in agent rules scenarios rig; do git clone https://github.com/synthaea-lab/$r.git; done
cd rig
python rig.py list               # the machines, with the box each one uses on this host
```

Each Linux VM gets those checkouts one-way at `/synthaea/<name>` (rsync), builds
`/synthaea/agent`, loads `/synthaea/rules` as detection content and runs
`/synthaea/scenarios/scenarios/*.sh`. Nothing else in the root directory is synced. Windows
VMs get the same checkouts uploaded to `C:\synthaea`. `RIG_ROOT` (or `SYNTHAEA_ROOT`) points
the rig at another root directory, for checkouts that live elsewhere.

The toolchain scripts the VMs are provisioned with live in the agent repository
(`agent/packaging/toolchain/`), next to the code they build.

## Repository layout

| Path | Purpose |
| --- | --- |
| `rig.py`, `justfile` | The commands above (Python ≥ 3.10, standard library only; `just` optional) |
| `machines.json` | **The machine catalog**: every machine, its box per provider, its provisioning. Read by the Vagrantfile and `rig.py` |
| `vagrant/` | The one Vagrantfile (libvirt, Hyper-V, QEMU, VirtualBox), per-provider host setup and box fix-ups ([README](vagrant/README.md)); `vagrant/hyperv/` has the Windows host bootstrap and PowerShell helpers |
| `provisioning/` | In-guest scripts: build-host setup, box fix-ups, the agent build (`agent-build.sh`/`.ps1`), the ONNX Runtime compatibility step, the Sysmon lab config ([what each one does](docs/provisioning.md)) |
| `runner/` | The scenario runner (`run-scenarios.sh` for Linux guests, `run-scenarios.ps1` for Windows guests) and its catalogs (`scenarios.conf`, `scenarios-windows.conf`) |
| `runner/windows/validate-admin.ps1` | Elevated live validation of the Windows ETW sensor (orphaned sessions, 8.3 paths, mark-of-the-web removal, keyword masks), run by hand in a Windows guest |
| `tools/offline_bundle.py` | Host side of offline builds: vendors the crates and pushes them to a VM |
| `tools/diagnose-ebpf-toolchain.sh` | In-guest eBPF toolchain diagnostic, for a build without embedded probes |
| `tools/windows/` | Windows telemetry capture helpers, `capture-sysmon-etw.ps1` and `observe-rdp.ps1` (they write to a capture directory you choose) |
| `tests/` | Fixtures and helpers for `python rig.py check`: sidecar fixtures (`tests/sidecars/`), the PowerShell sidecar reader, the `validate-admin.ps1` sibling-path check |
| `docs/` | [Machine matrix](docs/machine-matrix.md) (why each machine is in the matrix, what was validated where), [provisioning scripts](docs/provisioning.md), [Sysmon lab capture](docs/sysmon-capture.md), the historical [Hyper-V #155 runbook](docs/hyperv-runbook-155.md) |
| `reports/` | Run reports copied from the VMs (gitignored, see [Reports](#reports)) |
| `.github/` | CI: the DCO sign-off check |
| `LICENSE`, `NOTICE` | Apache-2.0 license and attribution notice |

## Prerequisites

Everywhere: the checkouts above, Python ≥ 3.10, git, and
[Vagrant](https://developer.hashicorp.com/vagrant/install) ≥ 2.3. For `--offline` builds the
host also needs rustup (it vendors crates with the agent's own toolchain).
[`just`](https://github.com/casey/just) is optional.

| Host | Provider (`RIG_PROVIDER` overrides) | Setup |
| --- | --- | --- |
| **Linux** x86_64 | `libvirt` | KVM + libvirt (`apt install qemu-kvm libvirt-daemon-system libvirt-dev`, or your distro's), `vagrant plugin install vagrant-libvirt`, your user in the `libvirt` group (log out/in), `rsync` |
| **Windows** | `hyperv` | once, in an **elevated** PowerShell: `vagrant\hyperv\bootstrap.ps1` (Hyper-V, *Hyper-V Administrators* group, Vagrant, Default Switch); an `rsync` on `PATH` (Git for Windows ships one at `C:\Program Files\Git\usr\bin`, or `winget install cwRsync`). Every `rig.py` command that touches a VM runs from an **elevated** shell |
| **macOS** Apple Silicon | `qemu` | `brew install qemu vagrant`, `vagrant plugin install vagrant-qemu`. arm64 guests only (no Windows, no Arch) |
| any x86_64 host | `virtualbox` (optional) | VirtualBox 7.x; `RIG_PROVIDER=virtualbox` |

Disk: ~20 GB per Linux VM once built (box, toolchain, `target/`). RAM: 6 GB per Linux VM by
default (`RIG_MEMORY_MB` to change it), so on a 16 GB laptop run one at a time.

## Quickstart

From `rig/`, the same five commands on every host; only the machine differs.

**Linux** (libvirt):

```sh
python3 rig.py up debian12
python3 rig.py build debian12 --ort-compat   # Debian 12 needs it, see "ONNX Runtime on older distros"
python3 rig.py run debian12
python3 rig.py report debian12
python3 rig.py down debian12
```

**Windows** (Hyper-V, elevated PowerShell):

```powershell
python rig.py up debian12
python rig.py build debian12 --ort-compat
python rig.py run debian12
python rig.py report debian12
python rig.py down debian12
```

(`generic/debian12` is the turnkey Hyper-V box; the 6.8/6.12 rows' Hyper-V boxes need the
one-time fix-ups in `vagrant/README.md`.)

**macOS** (Apple Silicon, QEMU; Ubuntu 24.04 needs no ONNX Runtime step):

```sh
python3 rig.py up ubuntu2404
python3 rig.py build ubuntu2404
python3 rig.py run ubuntu2404
python3 rig.py report ubuntu2404
python3 rig.py down ubuntu2404
```

The first `up` of a machine downloads the box and provisions it (rustup, the probe nightly,
bpf-linker, bindgen, aya-tool): 15 minutes on a fast link, an hour on a slow one. After that,
`up` resumes the VM in under a minute and `build` is incremental.

### What each step does

- `up <m>`: `vagrant up <m> --provider <host's>` in `vagrant/`. First boot also runs the
  provisioners (`vagrant/README.md`, "What the Vagrantfile does").
- `build <m>`: `vagrant rsync <m>` (the checkouts to `/synthaea`, build output kept), then
  `provisioning/agent-build.sh` in the guest: checks the toolchain (a missing bpf-linker
  would silently drop the eBPF probes), picks how ONNX Runtime is linked,
  `cargo build --release -p agent`, installs `/etc/synthaea/agent.toml` from the template if
  missing, runs `agent status` (every eBPF program through the verifier) and records the
  build in `~/synthaea-rig/build-info`. Flags: `--offline`, `--ort auto|prebuilt|static`,
  `--ort-compat` (below). Windows guests: the checkouts are uploaded as a zip to
  `C:\synthaea` and `provisioning/agent-build.ps1` builds there.
- `run <m> [scenario ...]`: re-syncs (so scenario edits on the host apply), then
  `runner/run-scenarios.sh` in the guest. Per scenario it starts the agent
  (`agent run --standalone --content-dir <rules> --alerts ... --events ...`), waits until the
  sensor listens, runs the script, waits until the alert file is quiet, snapshots the alerts,
  stops the agent, and compares with the scenario's `.yaml` sidecar. The report is copied to
  `reports/`. Exit status is non-zero when anything FAILed or ERRORed.
- `report [m]`: prints the newest report (of that machine).
- `down <m> [--destroy]`: `vagrant halt` (or `destroy --force`).
- `check`: what CI can check without a VM: the scripts parse, the catalogs are valid, every
  scenario has a runner catalog row and a readable sidecar, and (with pwsh)
  `runner/windows/validate-admin.ps1` resolves and loads `scenarios/scenarios/common.ps1` under the
  root.

For anything else, plain Vagrant in `vagrant/` (`vagrant ssh debian12`,
`vagrant provision debian12 --provision-with toolchain`, ...); set `RIG_ROOT` there too if
your checkouts are not next to the rig.

## Machines

[`machines.json`](machines.json) is the single catalog; [`docs/machine-matrix.md`](docs/machine-matrix.md) says what
each row proves. Box per provider (amd64 unless noted):

| Machine | Row | libvirt (Linux) | hyperv (Windows) | qemu (Apple Silicon, arm64) | Notes |
| --- | --- | --- | --- | --- | --- |
| `ubuntu2404` (primary) | Ubuntu 24.04, 6.8 | `cloud-image/ubuntu-24.04` | `jtarpley/ubuntu2404_base` ¹ | `perk/ubuntu-24.04-arm64` | |
| `ubuntu2204` | Ubuntu 22.04, 5.15 | `generic/ubuntu2204` | same | `perk/ubuntu-2204-arm64` | needs `--ort-compat` (not yet validated) or `--ort static` |
| `debian12` | Debian 12, 6.1 | `generic/debian12` | same | `cloud-image/debian-12` | needs `--ort-compat` (validated) or `--ort static` |
| `debian13` | Debian 13, 6.12 | `cloud-image/debian-13` | `shekeriev/debian-13` ¹ | `cloud-image/debian-13` | |
| `fedora41` | Fedora 41, 6.11/6.17 | `fedora/41-cloud-base` | `jtarpley/fedora41_base` ¹ | `fedora/41-cloud-base` | SELinux Enforcing |
| `rocky9` | Rocky 9, 5.14 | `generic/rocky9` | same | `rockylinux/9` | replay-only (no recent LLVM; glibc 2.34) |
| `arch` | Arch, rolling | `generic/arch` | same | — | `sudo pacman -Syu` for the current kernel |
| `alpine319` | Alpine 3.19, 6.6 (musl) | `generic/alpine319` | same | same | build with `--ort static` |
| `win11`, `win10`, `winserver` | Windows | `gusztavvargadr/windows-*` | same | — | WinRM; ETW sensors |

¹ community box with a documented fix-up: [`vagrant/README.md`](vagrant/README.md#hyper-v-community-boxes-68--612-fedora).
VirtualBox uses the libvirt column's box where it publishes one (see `machines.json`). macOS
(EndpointSecurity) has no Vagrant box: real hardware or Tart/UTM, outside this rig.

## Reports

`reports/<date>-<machine>.md`, one per machine per day (a later run the same day
replaces it). Each holds: machine, distro, kernel, LSMs, libc; the agent build (binary,
profile, ONNX Runtime mode, offline or not, build time, rustc) and the commit of every part
at build time and at run time; the `agent status` verifier summary; a table of every
scenario with the sidecar's expectation, what fired, what fired that was not expected, and
the time; then per scenario the alerts themselves, and the distinct warnings the agent
logged. The raw material (agent log, scenario output, alerts, events) stays in the guest
under `~/synthaea-rig/runs/<timestamp>/`.

| Result | Meaning |
| --- | --- |
| PASS | every expected technique fired between `min_count` and `min_count + tolerance` times, nothing else fired |
| UNEXPECTED | the expectations are met, but other techniques fired too (a false positive, or a sidecar to update) |
| FAIL | an expected technique fired too few or too many times |
| ERROR | the agent did not start, or the script exited non-zero |
| SKIP | the guest lacks a need of the scenario (a command, an LSM, a kernel version); the reason is shown |

`RESPONSE-ESCALATE`, the escalation record the agent adds on top of every detection, is
listed per scenario as a follow-up but never judged (unless a sidecar expects it).

Reports are **gitignored**: most runs are a developer checking a change. When a run is
evidence (a MATRIX row validated, a regression shown), commit it with
`git add -f reports/<file>` and cite it from `docs/machine-matrix.md`. A report holds only what the
guest saw (its hostname, the guest user's paths, process ids, commits): check it before
committing, like any log.

## Offline builds (slow or metered networks)

`python rig.py build <m> --offline` never lets the guest reach crates.io or pyke's CDN. On the
host, `tools/offline_bundle.py`:

1. `cargo vendor --locked --versioned-dirs` of `agent/` (from the host's cargo cache when
   the host has built the agent before);
2. vendors the probe toolchain's **sysroot** crates too (`cargo vendor --manifest-path
   $(rustc +<ebpf-toolchain> --print sysroot)/lib/rustlib/src/rust/library/Cargo.toml`)
   and merges them in: the eBPF crate builds `core` with nightly `-Z build-std`, which
   resolves the sysroot's own lockfile, and fails offline without them. This needs the
   probe toolchain on the host (installed on first use, ~70 MB);
3. adds pyke's prebuilt ONNX Runtime for the guest's target from the host's ort cache
   (`~/.cache/ort.pyke.io`, present after any host build of the agent on the same OS/arch);
4. packs it all (`.offline/`, ~100 MB, cached per `Cargo.lock`) and uploads it with
   `vagrant upload`, unless the guest already has that bundle.

In the guest, `agent-build.sh --offline` unpacks it to `~/synthaea-offline/`, points a
**private** `CARGO_HOME` at it (source replacement + `net.offline = true`; nested cargo
runs such as the eBPF build inherit it, and online builds are not affected), and builds.
The bundle is keyed on `agent/Cargo.lock` + `agent/packaging/toolchain/ebpf-toolchain.txt`: after a lockfile
change, `--offline` makes and pushes a new one. Switching a guest between online and offline builds
recompiles the dependencies once (their sources moved), ~10 minutes at 4 vCPUs.

Limits: provisioning itself (`up` on a new machine) still needs the network (packages,
rustup, bpf-linker, `cargo install` of bindgen/aya-tool); a Windows or Intel-Mac host has no
cached Linux ONNX Runtime to bundle (the guest then downloads it once, ~25 MB, warned);
`--ort static` cannot be offline.

## ONNX Runtime on older distros

The agent's default features link pyke's **prebuilt static ONNX Runtime**. That archive is
built on a recent distro and needs **glibc ≥ 2.38** (`__isoc23_strtol` & co) and the
**libstdc++ of GCC ≥ 13** (`GLIBCXX_3.4.31`). On older rows the build fails at the very
end, linking `agent`, with undefined `__isoc23_*` / `GLIBCXX_3.4.3x` symbols.
`agent-build.sh` checks first (`provisioning/ort-compat.sh --check`) and stops with the
options instead.

| Row | glibc / GCC | Prebuilt links? | Route |
| --- | --- | --- | --- |
| ubuntu-24.04, debian-13, fedora-41, arch | ≥ 2.39 / ≥ 13 | yes | nothing to do |
| debian-12 | 2.36 / 12 | no | `--ort-compat`: `libstdc++6` (and the `libc6` it pulls) from trixie, pinned at priority 100. **Validated** 2026-11-08 |
| ubuntu-22.04 | 2.35 / 12 | no | `--ort-compat`: the same from noble. Not yet validated |
| rocky-9 | 2.34 / 11 | no | `--ort static` (replay-only row anyway) |
| alpine (musl) | — | no musl build exists | `--ort static` |

`--ort-compat` (also the `ort-compat` provisioner, `RIG_ORT_COMPAT=1 python rig.py up <m>`) is a
**deliberate partial upgrade** of the C/C++ runtime: the row keeps its kernel (what it is
in the matrix for) but no longer has its distro's libc. On Debian 12 it upgrades about 15
packages (`libc6`, `libstdc++6`, the GCC runtime libraries, `dpkg`, `base-files`, so
`/etc/os-release` then says trixie; the report flags it). Fine for a disposable VM; say so
when quoting a result. The agent itself does not offer an ML-less build: `--ort static`
(`--no-default-features --features test-key` with a source-built runtime,
`agent/packaging/toolchain/build-onnxruntime-static.sh`) keeps the distro intact but clones and
builds onnxruntime (~1 GB, an hour; needs CMake ≥ 3.28). Tracked as an agent issue.

## Troubleshooting

| Symptom | Cause, fix |
| --- | --- |
| Link of `agent` fails: undefined `__isoc23_strtol`, `GLIBCXX_3.4.31` | Older distro, see [ONNX Runtime on older distros](#onnx-runtime-on-older-distros) |
| `agent status`: "built without embedded eBPF probes" | bpf-linker was missing at build time. `vagrant provision <m> --provision-with toolchain`, then `bash /synthaea/rig/tools/diagnose-ebpf-toolchain.sh` in the guest; `agent-build.sh` refuses to build without bpf-linker |
| Offline eBPF build: `no matching package named core`/`compiler_builtins` | The sysroot crates are missing from the vendor dir: the bundle was made by hand; let `--offline` make it |
| Online builds fail with "failed to select a version ... vendored-sources" | A hand-written `~/.cargo/config.toml` with a global source replacement; `agent-build.sh` moves such a file aside (`config.toml.vendored-bak`) |
| `vagrant rsync` ignores a new exclude | Vagrant saved the synced folder at `up`: `vagrant reload <m>` once |
| T1562.001 in a scenario that sends no signal | Stopping the agent is a signal to a security process. The runner snapshots alerts *before* stopping it, so it does not show up in reports; by hand, read the alerts before Ctrl-C |
| A BAYES alert naming `sshd` or your shell | The operator's own session through the correlator; reported as UNEXPECTED, worth an agent issue if it persists |
| `timestomp-linux` SKIP on 6.1/5.15 | The `inode_setattr` hook needs the 6.3+ signature; the agent disables it (warning in the report) |
| `argv` FAIL with 6 alerts for 3 | The `base64 -d` child's own command line also matches the rule; the sidecar expects 3 (measured 2026-09). Agent rule or sidecar to revisit, not the rig |
| Hyper-V `up`: `0x800705AA` | Under ~2.5 GB free on the host: `wsl --shutdown`, close a browser |
| Hyper-V: SMB credential prompt on `up` | A box defaulting `/vagrant` to SMB: the Vagrantfile disables it; check you run the rig's Vagrantfile (`vagrant/`) |
| rustc OOM-killed (`signal: 9`) | Too little RAM for the job count: `build-host-setup` sizes `CARGO_BUILD_JOBS` to the guest's RAM; re-run it after changing `RIG_MEMORY_MB` |
| The agent refuses to start: no config | `/etc/synthaea/agent.toml` missing; `agent-build.sh` installs the template |
| `--alerts` file EACCES | Let the agent create it: a file pre-created by another user cannot be opened by the root agent under `fs.protected_regular` |

## Adding a scenario

Scenarios live in [synthaea-lab/scenarios](https://github.com/synthaea-lab/scenarios) (one
`<name>.sh` or `.ps1` plus a `<name>.yaml` sidecar with `expected_detections`; see its
README). The rig never edits a sidecar: ML model records bind to their exact bytes.

1. Add the script and sidecar there (its PR).
2. Add a row to `runner/scenarios.conf` here (Windows: `runner/scenarios-windows.conf`):
   `default` if it is safe and self-contained, `opt-in` with a note saying what setup it
   needs otherwise; root, needed commands/LSMs, oldest kernel, extra agent flags or env,
   extra YARA files, settle time.
3. `python rig.py check` checks the catalog covers every scenario and every sidecar parses,
   and (where pwsh exists) that `run-scenarios.ps1` reads every sidecar as `run-scenarios.sh`
   does. A sidecar shape the runners should handle gets a fixture in `tests/sidecars/`.
4. `python rig.py run <m> <name>` to see it on a VM; the report says PASS or why not.

## Adding a machine

Add the row to [`docs/machine-matrix.md`](docs/machine-matrix.md) (what it proves), then the entry to `machines.json` (a box per
provider that has one; `provision` if it is not apt/dnf; a `prep` script in
`provisioning/` if the box needs a fix-up, written to detect whether it applies). Nothing
else lists machines.

## Moving from the two-harness layout

Before 2026-11 the Hyper-V harness had its own directory, `vagrant-hyperv/`, next to
`vagrant/`. Its machine names are unchanged, so an existing Hyper-V VM carries over: move
`vagrant-hyperv/.vagrant/machines/*` into `vagrant/.vagrant/machines/` and run
`vagrant status` from `vagrant/`. In-guest paths moved from `/synthaea/lab` to
`/synthaea/rig`, and the guest state from `~/synthaea-lab` to `~/synthaea-rig`: run `build`
once before `run`.
