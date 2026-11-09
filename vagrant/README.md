# vagrant

One `Vagrantfile` for every machine of [`../machines.json`](../machines.json) on every
provider. `rig.py` drives it; this page is the per-provider reference: host setup, what the
Vagrantfile does, and the fix-ups particular boxes need. The guide is
[`../README.md`](../README.md).

The providers differ in a few lines each (memory model, forwarded port, box name), so the
machine list, provisioning order and synced folders are shared, and per-box quirks are small
provisioning scripts that detect on their own whether they apply.

## Providers and host setup

| Host | Provider | Install |
| --- | --- | --- |
| Linux (x86_64, KVM) | `libvirt` | libvirt and qemu-kvm, `vagrant`, `vagrant plugin install vagrant-libvirt`; your user in the `libvirt` group |
| Windows (Hyper-V) | `hyperv` | Once, in an elevated PowerShell from this directory: `powershell -ExecutionPolicy Bypass -File hyperv\bootstrap.ps1` (Hyper-V feature, *Hyper-V Administrators*, Vagrant, Default Switch); an `rsync` on `PATH` (Git for Windows ships one, or `winget install cwRsync`) |
| macOS, Apple Silicon | `qemu` | `brew install qemu`, [Vagrant](https://developer.hashicorp.com/vagrant/install), `vagrant plugin install vagrant-qemu`; arm64 guests only |
| Intel macOS, or any x86_64 host | `virtualbox` | VirtualBox 7.x and `vagrant`; the default on Intel macOS, optional elsewhere (`RIG_PROVIDER=virtualbox`) |

`rig.py` picks the provider for the host (`RIG_PROVIDER` overrides). Plain Vagrant works the
same from this directory, for example `vagrant up debian12 --provider libvirt`, with
`RIG_ROOT` set if the checkouts are not next to the rig.

**Hyper-V.** Every `vagrant` command that touches a VM (`up`, `halt`, `ssh`, `rsync`,
`destroy`) needs an elevated shell. Set `$env:VAGRANT_HYPERV_SWITCH = "Default Switch"` to
skip the switch prompt (`rig.py` sets it). On a 16 GB host, run `wsl --shutdown` first:
`0x800705AA` ("insufficient system resources") on `up` means less than about 2.5 GB free.
`hyperv\helpers.ps1`, dot-sourced, adds PowerShell commands that call `rig.py` where it
covers the step (`Initialize-LabSession`, `Start-LabMachine`, `Build-LabAgent`,
`Invoke-LabScenario`, ...), with the short names kept as aliases (`vprep`, `vup`, `vbuild`,
`vscen`, ...); its header lists them all.

Once a VM runs, plain SSH with the key Vagrant generated works from any shell, without
elevation:
`ssh -i .vagrant/machines/<machine>/hyperv/private_key vagrant@<ip>`, where `<ip>` comes
from `(Get-VM synthaea-<machine> | Get-VMNetworkAdapter).IPAddresses`.

**QEMU.** The plugin cannot allocate the forwarded SSH port on its own, so each machine has
its own (`qemu_ssh_port` in the catalog: 50022, 50122, ...), which also lets several run side
by side. There are no snapshots: to roll back, `vagrant destroy -f` and `up` again.

## What the Vagrantfile does

- **Synced folders.** Linux guests get each checkout of the rig's root one way under
  `/synthaea`: `agent/`, `rules/`, `scenarios/`, `server/` when present, and the rig itself
  at `/synthaea/rig`, by rsync on `up` and on `vagrant rsync <machine>` (`rig.py build` and
  `run` re-sync first). Nothing else in the root is synced. Excluded: `.git`, build output
  (`agent/target/`), a source-built `agent/onnxruntime/`, the server's `node_modules/` and
  `.next/`, and the rig's `.offline/` and `reports/`. rsync's `--delete` spares excluded
  paths, so the guest's build output survives a re-sync. There is no `/vagrant` share. The
  synced folders are recorded at `up`: after changing them, run `vagrant reload` before
  `vagrant rsync` honours the change.
- **Windows guests** use WinRM and have no synced folder: `rig.py build` uploads a zip of
  the `agent`, `rules`, `scenarios`, `server` (if present) and `rig` working trees to
  `C:\synthaea`.
- **Resources.** RAM comes from the catalog (6 GB Linux, 8 GB Windows, 4 GB Alpine);
  `RIG_MEMORY_MB` overrides it. vCPUs default to half the host's, between 2 and 8;
  `RIG_CPUS` overrides it. Hyper-V Linux guests use Dynamic Memory, starting at 2 GB with
  the catalog value as the ceiling.
- **Provisioners**, in order. Re-run one with
  `vagrant provision <machine> --provision-with <name>`.
  1. `build-host-setup` (`../provisioning/build-host-setup.sh`, as root): a 4 GB swapfile,
     swappiness 60, and `CARGO_BUILD_JOBS` sized to the guest's RAM.
  2. `prep-*`: the box fix-ups the catalog lists, such as `fedora-lvm-prep.sh`.
  3. `toolchain` (`agent/packaging/toolchain/<family>-toolchain.sh`, as the `vagrant` user):
     packages, rustup with the pinned stable and eBPF nightly toolchains, bpf-linker,
     bindgen and aya-tool. Idempotent, and the slowest step.
  4. `ort-compat` (`../provisioning/ort-compat.sh --apply`): off unless `RIG_ORT_COMPAT=1`
     is set at the first `up`; see
     [ONNX Runtime on older distros](../README.md#onnx-runtime-on-older-distros).

## Boxes per target

The catalog picks, per provider, the box that best matches each target of the
[machine matrix](../docs/machine-matrix.md):

- `generic/*` boxes stop at Ubuntu 22.04, Debian 12, Rocky 9, Arch and Alpine 3.19, on every
  provider.
- The kernel 6.8 and 6.12 targets use the official `cloud-image/*` boxes on libvirt, QEMU and
  VirtualBox. On Hyper-V only community boxes exist, each needing a fix-up (below).
- `perk/*-arm64` are the arm64 Ubuntu boxes for QEMU; Fedora and Rocky publish arm64
  libvirt boxes, which the QEMU plugin also boots.
- `gusztavvargadr/windows-*` publish libvirt, Hyper-V and VirtualBox boxes, amd64 only, so
  there is no Windows guest on Apple Silicon.
- `generic/alpine319` (3.19, kernel 6.6) stands in for the Alpine target, whose purpose is
  musl and BusyBox coverage rather than a kernel version.

Whatever the box, record the `sched_process_fork` tracepoint layout of a new target, since
it differs across kernels:
`sudo cat /sys/kernel/tracing/events/sched/sched_process_fork/format`.

### Hyper-V community boxes (6.8 / 6.12, Fedora)

These boxes ship a Hyper-V provider but are not turnkey. Apply the fixes below over
`vagrant ssh` after the first `up`.

#### ubuntu2404 on Hyper-V: `jtarpley/ubuntu2404_base` (40 GB disk, LVM)

1. **The box boots an Azure 6.17 kernel, not 6.8**, so without this fix a run validates the
   wrong target. Pin the generic 6.8 kernel, which is already installed, and reboot:

   ```bash
   C=$(sudo cat /boot/grub/grub.cfg)
   E=$(echo "$C" | awk -F"'" "/menuentry .*6.8.0-[0-9]*-generic'/ && !/recovery/ {print \$2; exit}")
   S=$(echo "$C" | awk -F"'" '/submenu /{print $2; exit}')
   sudo sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=saved/' /etc/default/grub
   sudo update-grub && sudo grub-set-default "$S>$E" && sudo systemctl reboot
   ```

   Under the generic kernel, Hyper-V no longer reports the guest IP. Find it from the MAC
   address instead (formatted as `00-15-5d-...`):

   ```powershell
   Get-NetNeighbor -LinkLayerAddress (Get-VM synthaea-ubuntu2404 | Get-VMNetworkAdapter).MacAddress
   ```

2. **`/home` is a 1 GB volume and swap takes 8 GB**, so rustup fills `/home` during
   provisioning (`No space left on device`). Reclaim the swap:

   ```bash
   sudo swapoff /dev/vg_ubuntu/swap && sudo lvreduce -f -y -L 1G /dev/vg_ubuntu/swap
   sudo mkswap /dev/vg_ubuntu/swap && sudo swapon -a
   sudo lvextend -r -L +4G /dev/vg_ubuntu/home
   sudo lvextend -r -l +100%FREE /dev/vg_ubuntu/root
   ```

3. **`vm.swappiness = 0` in `/etc/sysctl.conf`** gets the release build's LTO step killed
   while swap sits unused. `build-host-setup` resets it to 60 and adds the 4 GB swapfile,
   but only when `/` has 8 GB free, which this box has only after step 2. Re-run it:
   `vagrant provision ubuntu2404 --provision-with build-host-setup`.
4. If the first `up` failed on the disk, re-run the toolchain provisioning
   (`bash /synthaea/agent/packaging/toolchain/linux-toolchain.sh`) and check that
   `bpf-linker --version` works. Without bpf-linker the agent builds without embedded eBPF
   probes and `agent status` fails.

#### debian13 on Hyper-V: `shekeriev/debian-13` (32 GB disk, single partition)

The disk is fine as shipped, and `build-host-setup` adds a 4 GB swapfile to the box's
1.7 GB of swap. What is missing:

- **`rsync` in the guest**, so `/synthaea` is never populated. Install it with
  `sudo apt-get install -y rsync`, then run `vagrant rsync debian13`.
- Provisioning therefore did not run either. Run it by hand:
  `bash /synthaea/agent/packaging/toolchain/linux-toolchain.sh`.
- The `sysctl` binary (`procps` is not installed). Read `/proc/sys/vm/*` directly if needed.

#### fedora41 on Hyper-V: `jtarpley/fedora41_base` (40 GB disk, LVM)

The box builds natively (Fedora ships clang and LLVM 19; the toolchain script fetches a
prebuilt bpf-linker) and runs with SELinux enforcing.

- **The kernel is not 6.11.** The box is already updated to 6.17, which uses the
  `__data_loc` layout of `sched_process_fork`. Check `uname -r` after `up`.
- **The disk is many small logical volumes**: `/` has about 6 GB free after the LLVM
  packages, `/home` under 1 GB, `/var` about 9 GB. The `prep-fedora-lvm-prep` provisioner
  (`../provisioning/fedora-lvm-prep.sh`) moves `~/.cargo` and `~/.rustup` to `/var/synthaea`
  and sets `CARGO_TARGET_DIR` there. A release build fits and leaves about 4 GB.
- The agent binary is therefore `/var/synthaea/target/release/agent`, not
  `target/release/agent`.
- **SELinux denials are in the journal**, not in `/var/log/audit/audit.log`: `auditd` does
  not run on this box, so `ausearch` always reports no matches. Use
  `sudo journalctl _TRANSPORT=audit | grep AVC`.

## Windows guests

The `toolchain` provisioner (`windows-toolchain.ps1`) installs rustup (stable-msvc) and, if
missing, the Visual Studio Build Tools with the C++ workload and the Windows SDK, which the
ETW, Event Log and service sensors link against. No nightly toolchain or LLVM is needed.

`python rig.py build win11` uploads the sources and runs `../provisioning/agent-build.ps1`;
`python rig.py run win11` runs `../runner/run-scenarios.ps1`. To stage a build for the
packaged service instead, `../provisioning/agent-install.ps1` copies the binaries and the
`rules` content into place and can register the watchdog service.

Running the toolchain script by hand in a Windows guest:

- **Execution policy.** Windows 11 defaults to `Restricted`, which blocks the script. Bypass
  it for one process:

  ```powershell
  powershell -ExecutionPolicy Bypass -File windows-toolchain.ps1
  ```

  or for the current session:

  ```powershell
  Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
  ```

- **Logging the output.** Do not pipe through `Tee-Object`: with
  `$ErrorActionPreference = 'Stop'`, redirection turns `rustup-init`'s routine stderr
  warning into a fatal error. `Start-Transcript` records the same output without that
  effect:

  ```powershell
  Start-Transcript -Path log.txt
  .\windows-toolchain.ps1
  Stop-Transcript
  ```

- **A second Rust toolchain on the first build.** The script installs `stable-msvc`, while
  the agent pins its own version in `rust-toolchain.toml`. The first `cargo build` makes
  rustup fetch that version too (about 150 MB). This is expected.
