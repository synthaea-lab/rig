# vagrant — the Vagrant harness

One `Vagrantfile` for every machine of [`../machines.json`](../machines.json) on every
provider. [`../README.md`](../README.md) is the guide (quickstart, offline builds,
troubleshooting); this page is the per-provider reference: host setup, what the
`Vagrantfile` does, and the fix-ups particular boxes need.

## Why one Vagrantfile

Until 2026-11 the rig had `vagrant/` (QEMU, plus a libvirt provider) and `vagrant-hyperv/`
(Hyper-V), each with its own machine list, memory settings and provisioning order, and
they had drifted: different boxes for the same row, swap and job-cap fixes on one side
only. The providers differ in a few lines each (memory model, forwarded port, box name);
everything else (which machines exist, how a guest is provisioned, what gets synced) is
the same. So: one catalog, one `Vagrantfile`, a provider block per provider, and the
per-box quirks as small provisioning scripts that detect on their own whether they apply.
The rest of the rig (`rig.py`, the runner) never has to know which harness it is on.

## Providers and host setup

| Host | Provider | Install |
| --- | --- | --- |
| Linux (x86_64, KVM) | `libvirt` | libvirt + qemu-kvm, `vagrant`, `vagrant plugin install vagrant-libvirt`; your user in the `libvirt` group |
| Windows (Hyper-V) | `hyperv` | once, elevated: `hyperv\bootstrap.ps1` (Hyper-V feature, *Hyper-V Administrators*, Vagrant, Default Switch); an `rsync` on `PATH` (Git for Windows ships one, or `winget install cwRsync`) |
| macOS, Apple Silicon | `qemu` | `brew install qemu`, `vagrant`, `vagrant plugin install vagrant-qemu`; arm64 guests only |
| any x86_64 host | `virtualbox` | VirtualBox 7.x + `vagrant`; optional, for when the host's native provider is not an option |

`rig.py` picks the provider for the host (`RIG_PROVIDER` overrides). Plain Vagrant
works the same from this directory: `vagrant up debian12 --provider libvirt` (with
`RIG_ROOT` set if the checkouts are not next to the rig).

**Hyper-V:** every `vagrant` command that touches a VM (`up`, `halt`, `ssh`, `rsync`,
`destroy`) needs an **elevated** shell. Set `$env:VAGRANT_HYPERV_SWITCH = "Default Switch"`
to skip the switch prompt (`rig.py` sets it). Run `wsl --shutdown` first on a 16 GB
host; `0x800705AA` ("insufficient system resources") on `up` means under ~2.5 GB free.
`hyperv\helpers.ps1` has PowerShell shortcuts (`vprep`, `vup`, `vbuild`, `vscen`).

**QEMU:** the plugin cannot auto-allocate the forwarded SSH port, so each machine has its
own (`qemu_ssh_port` in the catalog: 50022, 50122, ...), which also lets several run side
by side. There are no snapshots: rollback = `vagrant destroy -f` + `up`.

## What the Vagrantfile does

- **Synced folders.** Linux guests get each checkout of the rig's root one-way under
  `/synthaea`: `agent/`, `rules/`, `scenarios/` and, when present, `server/`, plus the rig
  itself at `/synthaea/rig`, by rsync on `up` and on `vagrant rsync <machine>` (`rig.py
  build`/`run` re-sync first). Nothing else in the root is synced. Excluded: `.git`, build
  output (`agent/target/`), `agent/onnxruntime/` (a source-built runtime), the server's
  `node_modules/` and `.next/`, the rig's `.offline/` and `reports/`. rsync's `--delete`
  spares excluded paths, so the guest's build output survives a re-sync. No `/vagrant`
  share anywhere (some boxes default it to SMB, which prompts for credentials on every
  Hyper-V `up`). The synced folders are saved at `up`: after changing them, `vagrant reload`
  (or halt + up) before `vagrant rsync` honours it.
- **Windows guests** (WinRM) have no synced folder: `rig.py build` uploads a zip of the
  `agent`, `rules`, `scenarios`, `server` (if present) and `rig` working trees to
  `C:\synthaea`.
- **Resources.** RAM from the catalog (6 GB Linux, 8 GB Windows, 4 GB Alpine),
  `RIG_MEMORY_MB` overrides; vCPUs = half the host's, between 2 and 8, `RIG_CPUS`
  overrides. Hyper-V Linux guests use Dynamic Memory: 2 GB at start, the catalog value as
  the ceiling.
- **Provisioners**, in order (re-run one with `vagrant provision <m> --provision-with <name>`):
  1. `build-host-setup` (`../provisioning/build-host-setup.sh`, root): 4 GB swapfile,
     swappiness 60, `CARGO_BUILD_JOBS` sized to the guest's RAM. Before it, rustc was
     OOM-killed on 2 GB Hyper-V guests.
  2. `prep-*`: the box fix-ups the catalog lists (`fedora-lvm-prep.sh`).
  3. `toolchain` (`agent/packaging/toolchain/<family>-toolchain.sh`, as the `vagrant` user):
     packages, rustup with the pinned stable and probe nightly, bpf-linker, bindgen,
     aya-tool. Idempotent. This is the slow step (an hour on a ~100 KB/s link).
  4. `ort-compat` (`../provisioning/ort-compat.sh --apply`): off unless `RIG_ORT_COMPAT=1`
     at first `up`; see `../README.md`, "ONNX Runtime on older distros".

## Boxes per row

The catalog picks, per provider, the box that best matches the MATRIX row. Constraints
behind the choices (checked against Vagrant Cloud on 2026-11-08):

- `generic/*` (roboxes) stops at 4.3.12 / 2024: Ubuntu 22.04, Debian 12, Rocky 9, Arch,
  Alpine 3.19, on every provider. Nothing newer.
- The 6.8 and 6.12 rows on libvirt/QEMU/VirtualBox use the official `cloud-image/*` boxes;
  on Hyper-V only community boxes exist, each needing a fix-up (below).
- `perk/*-arm64` are the arm64 Ubuntu boxes for QEMU; Fedora and Rocky publish arm64 libvirt
  boxes, which the QEMU plugin also boots.
- `gusztavvargadr/windows-*` publish libvirt, Hyper-V and VirtualBox boxes, amd64 only:
  no Windows guest on Apple Silicon.
- Alpine: `generic/alpine319` (3.19 / 6.6) stands in for the 3.24 row, whose purpose is
  musl/BusyBox coverage rather than a kernel version.

### Hyper-V community boxes (6.8 / 6.12, Fedora)

`generic/*` stops at 5.15/6.1 and `bento/*` dropped Hyper-V, so the 6.8 and 6.12
rows use community boxes that ship a Hyper-V provider. Both were validated on
2026-09-24 (26/26 programs through the verifier, `argv.sh` + `lineage.sh` —
see #415/#416). Neither is turnkey. The fixes below are the exact ones used,
applied over `vagrant ssh` after the first `up`.

**Tip — no elevation needed after `up`.** Only `up`/`halt`/`destroy` need the
elevated shell. Once a VM runs, plain SSH with the key Vagrant generated works
from any shell:
`ssh -i .vagrant/machines/<machine>/hyperv/private_key vagrant@<ip>`, where
`<ip>` comes from `(Get-VM synthaea-<machine> | Get-VMNetworkAdapter).IPAddresses`
(see the ubuntu2404 note below for when that comes back empty).

#### ubuntu2404 on Hyper-V — `jtarpley/ubuntu2404_base` (40 GB disk, LVM)

1. **It boots the Azure kernel (6.17), not 6.8.** `uname -r` shows
   `6.17.x-azure`, so without this fix the run validates the wrong row. Pin the
   generic 6.8 kernel (already installed) and reboot:

   ```bash
   C=$(sudo cat /boot/grub/grub.cfg)
   E=$(echo "$C" | awk -F"'" "/menuentry .*6.8.0-[0-9]*-generic'/ && !/recovery/ {print \$2; exit}")
   S=$(echo "$C" | awk -F"'" '/submenu /{print $2; exit}')
   sudo sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=saved/' /etc/default/grub
   sudo update-grub && sudo grub-set-default "$S>$E" && sudo systemctl reboot
   ```

   Under the generic kernel, Hyper-V no longer reports the guest IP (the KVP
   daemon came with the Azure kernel). Find it from the MAC instead:
   `Get-NetNeighbor -LinkLayerAddress (Get-VM synthaea-ubuntu2404 | Get-VMNetworkAdapter).MacAddress`
   (format the MAC as `00-15-5d-…`).
2. **`/home` is a 1 GB LVM volume and swap takes 8 GB**, so rustup
   (`~/.rustup`) fills `/home` during provisioning (`No space left on device`).
   Reclaim the swap:

   ```bash
   sudo swapoff /dev/vg_ubuntu/swap && sudo lvreduce -f -y -L 1G /dev/vg_ubuntu/swap
   sudo mkswap /dev/vg_ubuntu/swap && sudo swapon -a
   sudo lvextend -r -L +4G /dev/vg_ubuntu/home
   sudo lvextend -r -l +100%FREE /dev/vg_ubuntu/root
   ```

3. **`vm.swappiness = 0` in `/etc/sysctl.conf`.** With ~1 GB of RAM the
   release build's LTO step gets OOM-killed (`signal: 9`) while swap sits
   unused. The `build-host-setup` provisioner (`../provisioning/build-host-setup.sh`) resets it to 60. It also adds
   the 4 GB swapfile, but only when `/` has 8 GB free, which this box has only
   after step 2. Once step 2 is done, re-run it:
   `vagrant provision ubuntu2404 --provision-with build-host-setup`.
4. Then re-run the provisioning (`bash /synthaea/agent/packaging/toolchain/linux-toolchain.sh`)
   if the first `up` died on the disk, and check that `bpf-linker --version`
   works. Otherwise `sensor-linux` builds **without** embedded probes and
   `agent status` fails with "built without embedded eBPF probes".

#### debian13 on Hyper-V — `shekeriev/debian-13` (32 GB disk, single partition)

Disk is fine as shipped. The 1.7 GB of swap is not enough on its own, but the
`build-host-setup` provisioner adds a 4 GB swapfile. What's missing:

- **No `rsync` in the guest**, so `/synthaea` never gets populated. Either
  `sudo apt-get install -y rsync` then `vagrant rsync debian13`, or stream the
  tree over SSH:
  `git archive HEAD | ssh … 'sudo mkdir -p /synthaea && sudo chown vagrant: /synthaea && tar -xf - -C /synthaea'`.
- Provisioning therefore never ran either. Run it by hand:
  `bash /synthaea/agent/packaging/toolchain/linux-toolchain.sh`.
- No `sysctl` binary (`procps` not installed). Read `/proc/sys/vm/*` directly
  if needed.

#### fedora41 on Hyper-V — `jtarpley/fedora41_base` (40 GB LVM)

Validated 2026-09-30: builds natively (Fedora ships clang/LLVM 19, `linux-toolchain.sh`
fetches the prebuilt `bpf-linker`), 51/51 programs pass the verifier, `lineage.sh`
3/3 and `argv.sh` fire, with SELinux **Enforcing**. That run was started from an SSH
shell, i.e. in an unconfined domain, so it says nothing about the SELinux policy; the
packaged service is what exercises it (below). What to know:

- **The kernel is not 6.11.** The box is already updated (`6.17.7-100.fc41`); it
  uses the `__data_loc` `sched_process_fork` layout, like Alpine 6.18. `uname -r`
  after `up` says which row you are validating.
- **The disk is many small logical volumes**: `/` has ~6 GB free after the LLVM
  packages, `/home` under 1 GB (rustup dies with "No space left on device"), `/var`
  ~9 GB. The `prep-fedora-lvm-prep` provisioner (`../provisioning/fedora-lvm-prep.sh`) links
  `~/.cargo` and `~/.rustup` into `/var/synthaea` and sets `CARGO_TARGET_DIR` there.
  A release build of the agent (~7.5 min at 2 vCPU-equivalent) fits in the ~9 GB;
  it leaves ~4 GB.
- Run the scenarios against `$CARGO_TARGET_DIR/release/agent`
  (`/var/synthaea/target/release/agent`), not `target/release/agent`.
- **Where SELinux denials are.** `auditd` is not running on this box, so
  `ausearch` reads a missing `/var/log/audit/audit.log` and always answers "no
  matches" (an earlier "0 AVC" claim measured with it was wrong). Denials are in the
  journal: `sudo journalctl _TRANSPORT=audit | grep AVC`.
- **The packaged systemd unit runs on this row.** On 2026-09-30 it did not: installing
  the files the way `synthaea-agent.spec.template` does and starting the real unit under
  Enforcing, four defects stacked, each hiding the next. All four are fixed:
  1. `ExecStartPre` linked `synthaea-ctl` into the read-only `/usr` (RPM spec): #558.
  2. The binaries under `/var/lib/synthaea` were labelled `var_lib_t`, so `init_t` was
     denied `execute`/`map` (`status=203/EXEC`): #558 labels them `bin_t`, and #581 has
     the updater relabel a staged release before promoting it.
  3. The unprivileged `synthaea` user had no capabilities, so it could not load eBPF:
     #559 (ambient `CAP_BPF`, `CAP_PERFMON`, `CAP_SYS_RESOURCE`, `CAP_DAC_READ_SEARCH`,
     `CAP_NET_ADMIN`, `CAP_KILL`; ADR-0014). The set has since grown
     `CAP_AUDIT_READ` (#780, so the always-on AVC reader can open its own
     `NETLINK_AUDIT` socket when eBPF is primary) — see the shipped unit file
     for the current list, this one is a point-in-time record of #559.
  4. The watchdog's working directory was root-owned, so the agent's default relative
     `events.jsonl` failed: #559.

  Re-run on 2026-10-02 (kernel 6.17.7, SELinux Enforcing, the unit installed the way the
  RPM does, with the fixes of #589, #594, #631 and #515): the agent runs under the
  packaged unit, sees `/tmp` and `/home` of another user, and refuses to scan a root-only
  file a user merely tried to open, with **no AVC denial** in the session. The last AVC
  denials in the journal are the 2026-09-30 ones above. This row is not affected by the
  `perf_event_paranoid` problem of Debian and Ubuntu (#643): Fedora has no patch that adds
  level 3.

## Check the tracepoint layout on every new row

`sched_process_fork`'s record layout differs across kernels (#415). 5.15, 6.1,
6.8 and 6.12 all use the inline `char[16]` comm, and Alpine 6.18 and Fedora 6.17 use
`__data_loc`. Since #416 the agent reads it from tracefs at load, but a new row
should still record it:
`sudo cat /sys/kernel/tracing/events/sched/sched_process_fork/format`.

## Windows guests

`windows-toolchain.ps1` (the `toolchain` provisioner) installs rustup (stable-msvc) and,
if missing, the Visual Studio Build Tools with the C++ workload and the Windows SDK: the
MSVC linker and import libraries the ETW, Event Log and SCM sensors link against. No
nightly and no LLVM alignment: `windows-sys`, `ferrisetw` and `windows-service` are
pure-Rust bindings against DLLs Windows ships.

`python rig.py build win11` uploads the sources and runs `../provisioning/agent-build.ps1`;
`python rig.py run win11` runs `../runner/run-scenarios.ps1`. To stage a build for the
packaged service instead, `../provisioning/agent-install.ps1` copies the binaries and the
`rules` content into place and can register the watchdog service.

### Windows guests: operator notes (real-machine validation, #223)

A few things that only show up running this on an actual Windows box, not on
static review — found end to end on a vanilla Windows 11 VM:

- **Execution policy.** Windows 11 defaults to `Restricted`, so
  `windows-toolchain.ps1` refuses to run at all (`UnauthorizedAccess:
  PSSecurityException`). Either invoke it with the policy bypassed for that
  one process:
  ```powershell
  powershell -ExecutionPolicy Bypass -File windows-toolchain.ps1
  ```
  or, in an already-open session:
  ```powershell
  Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
  ```
- **Capturing the output to a log file** — don't pipe through `Tee-Object`
  (`.\windows-toolchain.ps1 *>&1 | Tee-Object -FilePath log.txt`). The
  script's `$ErrorActionPreference = 'Stop'` treats `rustup-init`'s routine
  stderr warning (`installing msvc toolchain without its prerequisites`) as
  fatal and aborts the run - not a real failure, just how PowerShell handles
  stderr under redirection. `Start-Transcript` doesn't redirect stderr, so
  it captures the same output without that side effect:
  ```powershell
  Start-Transcript -Path log.txt
  .\windows-toolchain.ps1
  Stop-Transcript
  ```
- **A second Rust toolchain gets installed on the first build.** This script
  always installs `stable-msvc`, but the repo pins a specific version at the
  root via `rust-toolchain.toml`. The first `cargo build` after provisioning
  makes rustup silently fetch and install that pinned version too (~150MB,
  ~2 extra minutes) - expected rustup behavior given the two don't
  necessarily match, not a bug in this script, but worth knowing before it
  looks like the build is doing something unexpected.
