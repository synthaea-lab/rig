# provisioning — in-guest scripts

What runs inside a lab VM besides the toolchain itself (which lives with the code it builds,
in `agent/toolchain/`). Plain bash/sh/PowerShell with no harness assumptions: Vagrant runs
them (`../vagrant/Vagrantfile`), `rig.py build` runs them over
`vagrant ssh`/`winrm`, and they work the same over a plain ssh session or cloud-init.
Every script is idempotent.

| Script | Runs | Purpose |
| --- | --- | --- |
| `build-host-setup.sh` | provisioner, root, every Linux guest | 4 GB swapfile, swappiness 60, `CARGO_BUILD_JOBS` sized to the guest's RAM (POSIX sh, BusyBox too) |
| `fedora-lvm-prep.sh` | provisioner, root, `fedora41` | moves `~/.cargo`, `~/.rustup` and the cargo target dir to `/var/synthaea` on the small-LVM Hyper-V box; a no-op elsewhere |
| `ort-compat.sh` | `--check` from `agent-build.sh`; `--apply` with `--ort-compat` or the `ort-compat` provisioner | can this guest link the prebuilt ONNX Runtime; on Debian 12 / Ubuntu 22.04, install the newer glibc + libstdc++ it needs (`../README.md`, "ONNX Runtime on older distros") |
| `agent-build.sh` | `python rig.py build`, as the `vagrant` user | the agent build: toolchain checks, optional offline bundle, ONNX Runtime mode, `cargo build`, default `/etc/synthaea/agent.toml`, `agent status`, `~/synthaea-rig/build-info` |
| `agent-build.ps1` | `python rig.py build` on Windows guests | the same for Windows: `cargo build --release -p agent` in `C:\synthaea\agent`, `C:\synthaea-rig\build-info` |
| `agent-install.ps1` | by hand | installs an already-built agent + watchdog (+ `rules` content under `storage.state_dir\content`) into a Windows VM, optionally as the watchdog service — for the packaged-service path rather than the runner's standalone agent |
| `fedora-test-setup.sh` | by hand | the Fedora VM setup for testing the static ONNX Runtime link (issue #110) |
| `sysmon-adr0026.xml`, `sysmon-capture.md` | by hand | the Sysmon configuration and procedure behind ADR-0026's ETW/Sysmon comparison captures |

## Windows toolchain vs. Linux toolchain

Unlike eBPF, the Windows sensors (`sensor-windows`/ETW via `ferrisetw`,
`sensor-windows-eventlog`, and `watchdog`'s SCM integration via `windows-service`) are
pure-Rust FFI bindings against DLLs Windows already ships: no LLVM-version alignment. The
one thing Rust does not provide on Windows is the MSVC linker and the Windows SDK import
libraries, which `agent/toolchain/windows-toolchain.ps1` gets from a Visual Studio Build
Tools install (the C++ workload). No nightly toolchain on Windows: that is a Linux/aya-only
requirement.
