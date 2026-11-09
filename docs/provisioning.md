# Provisioning and the agent build

Everything that runs inside a lab VM before the scenarios: the provisioners Vagrant runs on
the first `up`, and the agent build `rig.py build` runs on every call. The scripts are plain
bash, POSIX `sh` or PowerShell with no assumption about the harness: Vagrant runs them, `rig.py`
runs them over `vagrant ssh` or `vagrant winrm`, and they work the same over a plain SSH
session. Every one is idempotent, so re-running a step after a failure is always safe.

## Provisioners

Linux guests run these in order on the first `up`
([`define_linux_provisioners`](../vagrant/Vagrantfile)). Re-run one with
`vagrant provision <machine> --provision-with <name>` from `vagrant/`.

| Name | Script | Runs as | Purpose |
| --- | --- | --- | --- |
| `build-host-setup` | [`provisioning/build-host-setup.sh`](../provisioning/build-host-setup.sh) | root | Swap and a cargo job cap, so the build is not OOM-killed |
| `prep-<script>` | each `prep` entry of the catalog, from [`provisioning/`](../provisioning/) | root | Box fix-ups, such as [`fedora-lvm-prep.sh`](../provisioning/fedora-lvm-prep.sh) |
| `toolchain` | the catalog's `provision`, by default [`agent/packaging/toolchain/linux-toolchain.sh`](https://github.com/synthaea-lab/agent/blob/main/packaging/toolchain/linux-toolchain.sh) | `vagrant` user | System packages (including what the scenarios use, such as `nc` and `dnsutils`), rustup with the pinned stable and eBPF nightly toolchains, bpf-linker, bindgen, aya-tool. The slowest step |
| `ort-compat` | [`provisioning/ort-compat.sh --apply`](../provisioning/ort-compat.sh) | root | Off unless `RIG_ORT_COMPAT=1` at the first `up`; see [ONNX Runtime](#onnx-runtime) |

The order matters: swap and the job cap must exist before the toolchain compiles bindgen and
aya-tool, and a box fix-up that relocates directories must run before anything writes to the
small volumes it works around.

Windows guests run only `toolchain`
([`windows-toolchain.ps1`](https://github.com/synthaea-lab/agent/blob/main/packaging/toolchain/windows-toolchain.ps1)):
rustup with `stable-msvc` and, if missing, the Visual Studio Build Tools with the C++
workload and the Windows SDK. See [windows.md](windows.md).

### `build-host-setup.sh`

A release build of the agent with LTO peaks well above the RAM of a laptop VM, and boxes ship
with anything from no swap to `vm.swappiness = 0`. The script makes every Linux guest able to
build, whatever the box, in POSIX `sh` so that it also runs under BusyBox:

- **Swap.** A 4 GB swapfile at `/swapfile-synthaea` unless the guest already has 4 GB of
  swap. It is created under a temporary name and renamed only once `mkswap` succeeded, so an
  interrupted run never leaves a headerless swapfile. It is skipped, with a notice, when `/`
  has less than 8 GB free. On OpenRC (Alpine) the `swap` service is enabled so the fstab
  entry is honoured at boot.
- **Swappiness 60**, written to `/proc/sys/vm/swappiness` directly (some boxes have no
  `sysctl` binary) and persisted in `/etc/sysctl.d/90-synthaea.conf`; any
  `vm.swappiness` line in `/etc/sysctl.conf` is removed, since a value of 0 leaves swap
  unused for anonymous memory.
- **`CARGO_BUILD_JOBS`**, about one job per GB of RAM the guest sees, at least 2 with the
  swapfile, at most the CPU count, written to `/etc/profile.d/synthaea-build-jobs.sh`. A
  2 GB Hyper-V guest then builds with `-j2` instead of being killed at `-j4`.

After changing `RIG_MEMORY_MB`, re-run this provisioner so the job cap follows.

### Box fix-ups

A `prep` script fixes one box and detects on its own whether it applies, so the catalog can
list it for a machine without caring which provider's box is in use.
[`fedora-lvm-prep.sh`](../provisioning/fedora-lvm-prep.sh) handles the Hyper-V Fedora box,
whose `/home` volume is under 1 GB: when `/home` has less than 4 GB free it moves
`~/.cargo` and `~/.rustup` to `/var/synthaea` (as symlinks) and sets `CARGO_TARGET_DIR` to
`/var/synthaea/target` in `/etc/profile.d/synthaea-target.sh`. On any other Fedora box it
prints that there is nothing to relocate and exits.

The other community boxes need fix-ups that cannot be automated safely (a kernel to pin, LVM
volumes to resize); they are documented step by step in
[vagrant/README.md](../vagrant/README.md#hyper-v-community-boxes-68--612-fedora).

## The agent build

`python3 rig.py build <machine>` syncs the sources and runs
[`provisioning/agent-build.sh`](../provisioning/agent-build.sh) in a Linux guest as the
`vagrant` user. To run it by hand in the guest:

```bash
bash /synthaea/rig/provisioning/agent-build.sh --help
SYNTHAEA_SOURCE='hand build' bash /synthaea/rig/provisioning/agent-build.sh --ort-compat
```

| Option | Effect |
| --- | --- |
| `--offline` | Build from the bundle the host pushed: no crates.io, no CDN ([offline-builds.md](offline-builds.md)) |
| `--ort auto\|prebuilt\|static` | How ONNX Runtime is linked; default `auto` ([below](#onnx-runtime)) |
| `--ort-compat` | Run `ort-compat.sh --apply` first |
| `--debug` | A debug build instead of `--release` (not exposed by `rig.py`) |

| Variable | Default | Meaning |
| --- | --- | --- |
| `SYNTHAEA_ROOT` | `/synthaea` | Where the checkouts are |
| `SYNTHAEA_SOURCE` | `unknown (set by rig.py)` | The source description recorded in `build-info` |
| `RIG_STATE` | `~/synthaea-rig` | Where `build-info`, `build.log` and `status.txt` go |

The steps, in [`main`](../provisioning/agent-build.sh) order:

1. **Load the guest environment**: `~/.cargo/env` and every `/etc/profile.d/synthaea-*.sh`
   (the job cap, a relocated target directory). A non-login `vagrant ssh --command` would not
   read them otherwise.
2. **Preflight**, each failure exiting 2 with the fix: `agent/Cargo.toml` exists (the sources
   are synced), `cargo` is on `PATH` (the guest is provisioned), `bpf-linker` is on `PATH`, and
   the eBPF nightly named in the agent's `packaging/toolchain/ebpf-toolchain.txt` is
   installed. bpf-linker is checked up front because without it the agent's build script
   silently produces a binary with no eBPF probes, and the problem would only show at
   `agent status`.
3. **Move a global vendored config aside.** A `~/.cargo/config.toml` that replaces
   crates.io with vendored sources (left by a hand-rolled offline build) breaks every online
   build; it is renamed to `config.toml.vendored-bak`. The offline mode keeps its source
   replacement in a private `CARGO_HOME` instead.
4. **Offline bundle**, with `--offline` only.
5. **ONNX Runtime**: apply `--ort-compat`, resolve `auto`, prepare a static build.
6. **`cargo build --release -p agent`** in `/synthaea/agent`, with the features step 5 chose,
   logged to `build.log`. The binary is `${CARGO_TARGET_DIR:-/synthaea/agent/target}/release/agent`.
7. **Default configuration.** The agent refuses to start without a configuration file, so
   when `/etc/synthaea/agent.toml` is missing the agent's own template
   ([`crates/config/data/default-agent.toml`](https://github.com/synthaea-lab/agent/blob/main/crates/config/data/default-agent.toml))
   is installed there. An existing file is never overwritten.
8. **`sudo agent status`**, saved to `status.txt`. It loads every eBPF program through the
   running kernel's verifier and prints one line per program. A binary built without
   embedded probes fails the build here (exit 1), pointing at
   [`tools/diagnose-ebpf-toolchain.sh`](../tools/diagnose-ebpf-toolchain.sh).
9. **`build-info`**, then printed.

### `build-info`

A `key=value` file that ties a run to a build. The runner reads `agent_bin` to find the
binary and the rest for its report header.

```text
agent_bin=/synthaea/agent/target/release/agent
source=agent e352603, rules 9aaac6a, scenarios 0496952, rig 1b2edf8
built_at=2026-11-08T18:34:19Z
build_seconds=7
profile=release
ort=prebuilt
offline=1
rustc=rustc 1.99.1 (58cf8f9c3 2026-10-13)
```

| Key | Value |
| --- | --- |
| `agent_bin` | Absolute path of the built binary |
| `source` | `SYNTHAEA_SOURCE` at build time |
| `built_at` | UTC, ISO 8601 |
| `build_seconds` | Wall time of `cargo build` (an incremental build can take seconds) |
| `profile` | `release` or `debug` |
| `ort` | The resolved mode: `prebuilt` or `static` (never `auto`) |
| `offline` | `1` for an offline build, else `0` |
| `rustc` | `rustc --version` in the agent checkout, so the pinned toolchain |

[`tests/test_agent_build.py`](../tests/test_agent_build.py) runs the script against a fake
guest and pins these keys, the preflight refusals and the commands it runs.

## ONNX Runtime

The agent's default features link pyke's prebuilt static ONNX Runtime (the `ort-sys`
`download-binaries` feature). That archive is built on a recent distribution: it needs glibc
2.38 or later (`__isoc23_strtol` and related symbols) and the libstdc++ of GCC 13 or later
(`GLIBCXX_3.4.31`). On older targets the final link of `agent` fails with undefined symbols
about 20 minutes into a build. The build therefore checks first.

| Mode | What happens |
| --- | --- |
| `auto` (default) | Runs [`ort-compat.sh --check`](../provisioning/ort-compat.sh). If the prebuilt runtime can link, behaves as `prebuilt`; otherwise stops with exit 2 and the two options below |
| `prebuilt` | The agent's default features, no check |
| `static` | Builds ONNX Runtime from source with the agent's `packaging/toolchain/build-onnxruntime-static.sh` into `agent/onnxruntime/` (once; rsync leaves it alone), links it with the flags `ort-static-link-flags.sh` prints, and builds with `--no-default-features --features test-key`. About an hour and 1 GB of downloads, needs CMake 3.28 or later. Refused with `--offline` |

`--ort-compat` runs [`ort-compat.sh --apply`](../provisioning/ort-compat.sh) before the
mode is resolved:

| Target | glibc / GCC | What `--apply` does |
| --- | --- | --- |
| Ubuntu 24.04, Debian 13, Fedora 41, Arch | 2.39+ / 13+ | Nothing: the check passes |
| Debian 12 (`bookworm`) | 2.36 / 12 | Adds `trixie` as an apt source pinned at priority 100, then installs `libstdc++6` (and the `libc6` it requires) from it. Validated |
| Ubuntu 22.04 (`jammy`) | 2.35 / 12 | The same from `noble`. Not yet validated |
| Rocky Linux 9 | 2.34 / 11 | No package route: use `--ort static` |
| Alpine (musl) | | No prebuilt runtime exists for musl: use `--ort static` |

Priority 100 means apt never takes anything else from the next release unless asked with
`-t`. Even so, `--apply` is a deliberate partial upgrade of the C and C++ runtime: the VM
keeps the kernel it is in the matrix for, but no longer runs its distribution's C library. On
Debian 12 it upgrades about 15 packages, including `base-files`, so `/etc/os-release` then
names Debian 13. The runner detects the pin and says so in the report's Machine line; state
it when you quote a result. It is fine for a disposable lab VM, not for a host that matters.
`--ort static` keeps the distribution intact at the cost of build time.

## Windows build

[`provisioning/agent-build.ps1`](../provisioning/agent-build.ps1) is the Windows
counterpart, run by `rig.py build` through WinRM. It checks that `C:\synthaea\agent\Cargo.toml`
and `cargo` exist, runs `cargo build --release -p agent` (logged to
`C:\synthaea-rig\build.log`), and writes the same `build-info` keys with `ort=prebuilt` and
`offline=0`. There is no eBPF and no verifier step, no offline mode and no ONNX Runtime
choice. It installs no configuration: the Windows runner writes a lab configuration per
scenario ([windows.md](windows.md#the-windows-runner)).

## Other scripts

| Script | Use |
| --- | --- |
| [`provisioning/agent-install.ps1`](../provisioning/agent-install.ps1) | By hand, in a Windows guest: installs an already-built `agent.exe` and `watchdog.exe` (from `-SourceDir` or `-AgentZip`) into `C:\Synthaea`, the `rules\sigma` and `rules\yara` content under `<StateDir>\content`, and with `-InstallService` registers the watchdog service. For testing the packaged service path rather than the runner's standalone agent. See [windows.md](windows.md#installing-a-built-agent) |
| [`provisioning/fedora-test-setup.sh`](../provisioning/fedora-test-setup.sh) | By hand, in a Fedora guest: checks prerequisites and disk space, builds the static ONNX Runtime and writes the environment for a static-link build |
| [`provisioning/sysmon-adr0026.xml`](../provisioning/sysmon-adr0026.xml) | The Sysmon configuration of the [Sysmon capture](sysmon-capture.md) |
| [`tools/diagnose-ebpf-toolchain.sh`](../tools/diagnose-ebpf-toolchain.sh) | In a Linux guest, when a build has no embedded probes: checks bpf-linker, the nightly's `rust-src` and the LLVM versions, then runs a verbose probe build so the real error is visible |
