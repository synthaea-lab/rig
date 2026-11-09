# rig

The Synthaea testing rig. It boots a virtual machine from a catalog of Linux and Windows
targets, builds the [Synthaea agent](https://github.com/synthaea-lab/agent) inside it, runs
the [attack scenarios](https://github.com/synthaea-lab/scenarios) against it, and writes a
report of what each scenario expects next to what the agent detected.

```sh
python3 rig.py up debian12        # boot a VM from machines.json (provisions it on first boot)
python3 rig.py build debian12     # sync the sources into it and build the agent there
python3 rig.py run debian12       # run every default scenario against the agent
python3 rig.py report debian12    # print the report
python3 rig.py down debian12      # halt the VM
```

The same five commands work on Linux (libvirt), Windows (Hyper-V) and Apple Silicon macOS
(QEMU). On Windows, run `python` instead of `python3`.

## Why a rig

An endpoint agent that relies on eBPF, LSM hooks and ETW behaves differently across kernels,
C libraries and operating systems: tracepoint layouts move, verifiers tighten, a prebuilt
dependency stops linking. The rig turns each target in the
[machine matrix](docs/machine-matrix.md) into a reproducible VM, builds the agent from your
local checkouts on that target, and measures it against the same scenarios every time, so a
result on Debian 12 and a result on Fedora 41 are comparable.

## Status

Alpha. The rig is the project's own test harness and evolves with the agent; commands,
catalog fields and report layout can change between commits. Validation status per machine
is recorded in [docs/machine-matrix.md](docs/machine-matrix.md).

## Setup

The rig works on a root directory that holds the checkouts it builds and runs, side by side
with the rig itself:

```text
synthaea/       the rig's root (any name; RIG_ROOT overrides it)
├── agent/      the agent to build
├── rules/      the detection content the agent loads
├── scenarios/  scenario scripts and their expected detections
├── server/     optional: the control plane
└── rig/        this repository
```

```sh
mkdir synthaea
cd synthaea
for r in agent rules scenarios rig; do git clone https://github.com/synthaea-lab/$r.git; done
cd rig
python3 rig.py list
```

On Windows, in PowerShell:

```powershell
mkdir synthaea
cd synthaea
foreach ($r in 'agent','rules','scenarios','rig') { git clone "https://github.com/synthaea-lab/$r.git" }
cd rig
python rig.py list
```

`list` prints every machine with the box it uses on this host. Linux guests receive the
checkouts one way, by rsync, under `/synthaea/<name>`; Windows guests receive them as an
upload to `C:\synthaea`. Nothing else in the root directory is copied. Set `RIG_ROOT` (or
`SYNTHAEA_ROOT`) when the checkouts live elsewhere.

## Prerequisites

On every host: Python 3.10 or later (standard library only), git and
[Vagrant](https://developer.hashicorp.com/vagrant/install) 2.3 or later.
[`just`](https://github.com/casey/just) is optional: `just up debian12` is the same as
`python3 rig.py up debian12`.

| Host | Provider | Setup |
| --- | --- | --- |
| Linux x86_64 | `libvirt` | KVM and libvirt (`sudo apt install qemu-kvm libvirt-daemon-system libvirt-dev`, or your distribution's packages), `vagrant plugin install vagrant-libvirt`, your user in the `libvirt` group, `rsync` |
| Windows | `hyperv` | Once, in an elevated PowerShell from the rig: `powershell -ExecutionPolicy Bypass -File vagrant\hyperv\bootstrap.ps1` (Hyper-V, the *Hyper-V Administrators* group, Vagrant, the Default Switch). An `rsync` on `PATH`: Git for Windows ships one in `C:\Program Files\Git\usr\bin`, or `winget install cwRsync`. Every command that touches a VM runs from an elevated shell |
| macOS, Apple Silicon | `qemu` | `brew install qemu`, `vagrant plugin install vagrant-qemu`. arm64 guests only: no Windows and no Arch |
| Intel macOS, or any x86_64 host | `virtualbox` | VirtualBox 7.x. The default on Intel macOS; elsewhere, select it with `RIG_PROVIDER=virtualbox` |

`RIG_PROVIDER` overrides the provider chosen for the host. Each Linux VM takes about 20 GB
of disk once built and 6 GB of RAM by default (`RIG_MEMORY_MB` changes it), so on a 16 GB
host run one VM at a time. Per-provider details and box fix-ups are in
[vagrant/README.md](vagrant/README.md).

## Quickstart

Linux host, Debian 12 guest:

```sh
python3 rig.py up debian12
python3 rig.py build debian12 --ort-compat
python3 rig.py run debian12
python3 rig.py report debian12
python3 rig.py down debian12
```

Debian 12 needs `--ort-compat`; see [ONNX Runtime on older distros](#onnx-runtime-on-older-distros).
The Windows host runs the same commands with `python`, from an elevated PowerShell;
`debian12` is a turnkey box on Hyper-V. On Apple Silicon, `ubuntu2404` builds without the
compatibility step:

```sh
python3 rig.py up ubuntu2404
python3 rig.py build ubuntu2404
python3 rig.py run ubuntu2404
```

The first `up` of a machine downloads its box and provisions the build toolchain (rustup,
the eBPF nightly, bpf-linker, bindgen, aya-tool): about 15 minutes on a fast connection, an
hour on a slow one. Later `up` calls resume the VM in under a minute, and `build` is
incremental.

## Commands

| Command | What it does |
| --- | --- |
| `list` | The machine catalog, with the box each machine uses on this host |
| `up <machine>` | `vagrant up` with the host's provider; the first boot runs the provisioners |
| `build <machine> [--offline] [--ort auto\|prebuilt\|static] [--ort-compat]` | Syncs the checkouts, builds the agent in the guest, checks that the toolchain would embed the eBPF probes, installs a default `/etc/synthaea/agent.toml` if none exists, and runs `agent status`, which passes every eBPF program through the kernel verifier |
| `run <machine> [scenario ...]` | Re-syncs, then runs each scenario (default: every safe, self-contained one) against a fresh standalone agent and copies the report to `reports/`. Exits non-zero when a scenario fails or errors |
| `report [machine]` | Prints the newest report, of one machine if given |
| `down <machine> [--destroy]` | Halts the VM, or deletes it |
| `check` | Checks what can be checked without a VM: scripts parse and are shellcheck-clean, the runner catalogs cover every scenario, both runners read every sidecar alike, the runner judges the `tests/judge/` snapshots as stated. See [CONTRIBUTING.md](CONTRIBUTING.md) |

Every command exits 0 when it succeeds, 1 when it ran and something failed (a scenario, a
check, the build) and 2 when it could not run (a usage error, or something missing such as
vagrant, a checkout or a build); see [CONTRIBUTING.md](CONTRIBUTING.md#exit-codes).

For anything else, use Vagrant directly from `vagrant/`, for example `vagrant ssh debian12`
(set `RIG_ROOT` there too if the checkouts are not next to the rig).

## Machines

[`machines.json`](machines.json) is the single catalog, read by both `rig.py` and the
Vagrantfile; [docs/machine-matrix.md](docs/machine-matrix.md) explains what each target
proves. Boxes are amd64 unless noted.

| Machine | Target | libvirt | hyperv | qemu (arm64) | Notes |
| --- | --- | --- | --- | --- | --- |
| `ubuntu2404` | Ubuntu 24.04, kernel 6.8 | `cloud-image/ubuntu-24.04` | `jtarpley/ubuntu2404_base` ¹ | `perk/ubuntu-24.04-arm64` | Primary target |
| `ubuntu2204` | Ubuntu 22.04, 5.15 | `generic/ubuntu2204` | same | `perk/ubuntu-2204-arm64` | `--ort-compat` (not yet validated) or `--ort static` |
| `debian12` | Debian 12, 6.1 | `generic/debian12` | same | `cloud-image/debian-12` | `--ort-compat` or `--ort static` |
| `debian13` | Debian 13, 6.12 | `cloud-image/debian-13` | `shekeriev/debian-13` ¹ | `cloud-image/debian-13` | |
| `fedora41` | Fedora 41, 6.11 or later | `fedora/41-cloud-base` | `jtarpley/fedora41_base` ¹ | `fedora/41-cloud-base` | SELinux enforcing |
| `rocky9` | Rocky Linux 9, 5.14 | `generic/rocky9` | same | `rockylinux/9` | Replay-only |
| `arch` | Arch Linux, rolling | `generic/arch` | same | none | |
| `alpine319` | Alpine 3.19, 6.6, musl | `generic/alpine319` | same | same | `--ort static` |
| `win11`, `win10`, `winserver` | Windows | `gusztavvargadr/windows-*` | same | none | WinRM; ETW sensors |

¹ Community box that needs a one-time fix-up, described in
[vagrant/README.md](vagrant/README.md#hyper-v-community-boxes-68--612-fedora).
VirtualBox uses the libvirt box where one is published (see `machines.json`). macOS has no
Vagrant box and is tested on real hardware, outside the rig.

## Reports

Each run writes `reports/<date>-<machine>.md`; a later run on the same day replaces it. A
report records the machine (distribution, kernel, LSMs, C library), the agent build and the
commit of every checkout at build and run time, the verifier summary, a table of every
scenario with its expected detections, what fired and what fired unexpectedly, then the
alerts and agent warnings per scenario. The raw logs, alerts and events stay in the guest
under `~/synthaea-rig/runs/<timestamp>/`.
[reports/2026-11-08-debian12.md](reports/2026-11-08-debian12.md) is an example.

| Result | Meaning |
| --- | --- |
| PASS | Every expected technique fired between `min_count` and `min_count + tolerance` times, and nothing else fired |
| UNEXPECTED | The expectations are met, but other techniques fired too: a false positive, or an expectation to update |
| FAIL | An expected technique fired too few or too many times |
| ERROR | The agent did not start, or the scenario script exited non-zero |
| SKIP | The guest lacks something the scenario needs (a command, an LSM, a kernel version); the reason is shown |

`RESPONSE-ESCALATE`, the escalation record the agent adds to every detection, is listed per
scenario but not judged unless a sidecar expects it.

Reports are not committed by default. A report contains what the guest saw (hostname, paths,
process IDs, commits); review it before sharing.

## Offline builds

`python3 rig.py build <machine> --offline` builds without the guest ever reaching crates.io
or the ONNX Runtime CDN. The host vendors the agent's crates, the eBPF toolchain's sysroot
crates and a cached ONNX Runtime archive into a bundle of about 100 MB, uploads it once per
`Cargo.lock`, and the guest builds against it with a private `CARGO_HOME`. The host needs
rustup and, for the ONNX Runtime archive, a previous build of the agent on the same OS and
architecture. Provisioning a new machine still needs the network, and `--ort static` cannot
be combined with `--offline`. [docs/offline-builds.md](docs/offline-builds.md) describes
the bundle in detail.

## ONNX Runtime on older distros

The agent links a prebuilt static ONNX Runtime by default. That archive needs glibc 2.38 or
later and the libstdc++ of GCC 13 or later; on older targets the final link of `agent` fails
with undefined `__isoc23_*` or `GLIBCXX_3.4.3x` symbols. `build` checks this first and stops
with the options below.

| Target | glibc / GCC | Route |
| --- | --- | --- |
| Ubuntu 24.04, Debian 13, Fedora 41, Arch | 2.39 or later / 13 or later | Nothing to do |
| Debian 12 | 2.36 / 12 | `--ort-compat`: `libstdc++6` and the `libc6` it requires from Debian 13, pinned at low priority. Validated |
| Ubuntu 22.04 | 2.35 / 12 | `--ort-compat`: the same from Ubuntu 24.04. Not yet validated |
| Rocky Linux 9 | 2.34 / 11 | `--ort static` |
| Alpine (musl) | not applicable | `--ort static` |

`--ort-compat` (or `RIG_ORT_COMPAT=1` on the first `up`) is a deliberate partial upgrade of
the C and C++ runtime: the VM keeps the kernel it is in the matrix for, but no longer runs
its distribution's C library. On Debian 12 it upgrades about 15 packages, including
`base-files`, so `/etc/os-release` then reports Debian 13; the report says so. State it when
you quote a result. `--ort static` keeps the distribution intact but builds ONNX Runtime from
source with the agent's `packaging/toolchain/build-onnxruntime-static.sh`, which takes about
an hour and 1 GB and needs CMake 3.28 or later.

## Documentation

- [docs/machine-matrix.md](docs/machine-matrix.md): the targets and what each one proves
- [vagrant/README.md](vagrant/README.md): providers, what the Vagrantfile does, box fix-ups,
  Windows guests
- [docs/provisioning.md](docs/provisioning.md): the in-guest scripts
- [docs/offline-builds.md](docs/offline-builds.md): offline build bundles
- [docs/troubleshooting.md](docs/troubleshooting.md): common failures and their fixes
- [Synthaea documentation](https://www.synthaea.com/en/docs/overview): the project as a whole

## Contributing

Adding a scenario to the catalog, adding a machine and running the local checks are covered
in [CONTRIBUTING.md](CONTRIBUTING.md). Every commit carries a DCO sign-off (`git commit -s`).

## License

Apache License 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
