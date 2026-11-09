# Troubleshooting

Symptoms, their cause and the fix, grouped by the step that shows them. When a step fails,
first re-run it with `--dry-run` to see the exact command sent to the guest, then run that
command yourself in the guest (`vagrant ssh <machine>` from `vagrant/`) to see its full output.

## Build

| Symptom | Cause and fix |
| --- | --- |
| The link of `agent` fails with undefined `__isoc23_strtol` or `GLIBCXX_3.4.31` | The distribution is older than the prebuilt ONNX Runtime needs, and the build was forced with `--ort prebuilt`. Use `--ort-compat` or `--ort static` ([provisioning.md](provisioning.md#onnx-runtime)) |
| `agent-build: this guest cannot link the prebuilt ONNX Runtime` | The same, caught before the build by `--ort auto`. Pick one of the two options it prints |
| `bpf-linker not on PATH` | The toolchain provisioning did not finish (bpf-linker's download failed, or the disk filled). Run `vagrant provision <machine> --provision-with toolchain` |
| `agent status` reports a build "without embedded eBPF probes" | bpf-linker or the eBPF nightly was missing when the agent was built. Re-provision as above, then run `bash /synthaea/rig/tools/diagnose-ebpf-toolchain.sh` in the guest, which prints the real probe-build error |
| `probe toolchain nightly-... missing` | The agent's `ebpf-toolchain.txt` changed since the guest was provisioned. Re-run the `toolchain` provisioner |
| `Unknown attribute kind ... Producer LLVM NN ... Reader LLVM MM` during the probe build | bpf-linker's LLVM and the nightly's LLVM disagree. The pin lives in the agent's `packaging/toolchain/`; align it there, then re-provision |
| `rust-src` missing for the probe toolchain | `rustup component add rust-src --toolchain "$(cat /synthaea/agent/packaging/toolchain/ebpf-toolchain.txt)"` in the guest |
| Offline eBPF build: `no matching package named core` or `compiler_builtins` | The vendor directory lacks the sysroot crates, because the bundle was made by hand. Let `--offline` make it ([offline-builds.md](offline-builds.md#why-the-sysroot-crates)) |
| `the offline bundle (...) was made for another Cargo.lock or probe toolchain` | The agent's lockfile or toolchain changed. Re-run the build from the host with `--offline`, which makes and pushes a new bundle |
| Online builds fail with `failed to select a version ... vendored-sources` | A hand-written `~/.cargo/config.toml` with a global source replacement. `agent-build.sh` moves such a file aside to `config.toml.vendored-bak`; check for one under another name |
| rustc is killed with `signal: 9` | Too little RAM for the job count. Re-run `vagrant provision <machine> --provision-with build-host-setup` after changing `RIG_MEMORY_MB`, so `CARGO_BUILD_JOBS` follows |
| `No space left on device` during provisioning | A box with small volumes. See the box's fix-up in [vagrant/README.md](../vagrant/README.md#hyper-v-community-boxes-68--612-fedora) |

## VMs

| Symptom | Cause and fix |
| --- | --- |
| `<machine> has no box for the <provider> provider` | The catalog has no box for this host's provider (no Windows or Arch guest on Apple Silicon, for example). `RIG_PROVIDER` selects another installed provider |
| `vagrant rsync` ignores a new exclude or folder | Vagrant records the synced folders at `up`; run `vagrant reload <machine>` once |
| `/synthaea` stays empty in the guest | The box has no `rsync`. Install it in the guest, then `vagrant rsync <machine>` |
| Hyper-V `up` fails with `0x800705AA` | The host cannot give the VM its 2 GB startup memory. Run `wsl --shutdown`, close memory-heavy applications, halt other VMs ([windows.md](windows.md#memory)) |
| Hyper-V prompts for SMB credentials on `up` | A box that defaults `/vagrant` to SMB. The rig's Vagrantfile disables that share; make sure vagrant runs from `vagrant/` (or through `rig.py`) |
| The guest cannot resolve `static.crates.io` on Hyper-V | Default Switch DNS. See [windows.md](windows.md#default-switch-networking) |
| A Vagrant command from PowerShell mangles a bash snippet | Use `Invoke-LabShell` (`vssh`) from the Hyper-V helpers, which sends the snippet base64-encoded ([windows.md](windows.md#powershell-helpers)) |
| A shell script fails in the guest with `$'\r': command not found` | The file was checked out with CRLF line endings. `.gitattributes` forces LF for `*.sh`; re-checkout the file, or check `git config core.autocrlf` |

## Runs

| Symptom | Cause and fix |
| --- | --- |
| `no ~/synthaea-rig/build-info: build first` | `run` before `build` on this VM (or after `down --destroy`). Run `rig.py build <machine>` |
| `/etc/synthaea/agent.toml missing` | The agent refuses to start without a configuration. `build` installs the template; re-run it |
| `fix the catalog first` | `run-scenarios.sh --check` found a problem; the lines above it say which. A new scenario in the scenarios checkout needs a row in `runner/scenarios.conf` |
| A scenario is ERROR with "agent did not start" | Read `agent.log` in the scenario's run directory (the report names it). A configuration error or a sensor that failed to attach shows there |
| The `--alerts` file fails with `EACCES` when running the agent by hand | Let the agent create the file. Under `fs.protected_regular`, root cannot open a file pre-created by another user in a sticky directory such as `/tmp` |
| `T1562.001` fires in a scenario that sends no signal | Stopping the agent is itself a signal to a security process. The runner snapshots the alerts before stopping it, so reports are not affected; when running by hand, read the alerts before stopping the agent |
| A `BAYES` or lineage alert names `sshd` or your shell | The operator's own session, seen by the correlator. Reported as UNEXPECTED |
| `timestomp-linux` is SKIP on kernel 6.1 or 5.15 | Expected: its catalog row has `min_kernel` 6.3, because the `inode_setattr` LSM hook it relies on has the `(idmap, dentry, attr)` signature only from 6.3. The runner skips it without starting an agent |
| A scenario's console output is truncated under PowerShell | PowerShell drops interleaved output from `vagrant ssh`. Trust the report and the files in the run directory, not the screen |
| `rig.py run` ends with `the runner wrote no report` | The runner stopped before its report (exit 2: the guest is not ready; exit 1: the catalog check failed). Its own message is above |
