# Troubleshooting

## Build

| Symptom | Cause and fix |
| --- | --- |
| The link of `agent` fails with undefined `__isoc23_strtol` or `GLIBCXX_3.4.31` | An older distribution; see [ONNX Runtime on older distros](../README.md#onnx-runtime-on-older-distros) |
| `agent status` reports "built without embedded eBPF probes" | bpf-linker was missing at build time. Run `vagrant provision <machine> --provision-with toolchain`, then `bash /synthaea/rig/tools/diagnose-ebpf-toolchain.sh` in the guest. `agent-build.sh` refuses to build without bpf-linker |
| Offline eBPF build: `no matching package named core` or `compiler_builtins` | The vendor directory lacks the sysroot crates because the bundle was made by hand; let `--offline` make it ([offline builds](offline-builds.md)) |
| Online builds fail with "failed to select a version ... vendored-sources" | A hand-written `~/.cargo/config.toml` with a global source replacement. `agent-build.sh` moves such a file aside to `config.toml.vendored-bak` |
| rustc is killed with `signal: 9` | Too little RAM for the job count. `build-host-setup` sizes `CARGO_BUILD_JOBS` to the guest's RAM; re-run it after changing `RIG_MEMORY_MB` |

## VMs

| Symptom | Cause and fix |
| --- | --- |
| `vagrant rsync` ignores a new exclude | Vagrant saves the synced folders at `up`; run `vagrant reload <machine>` once |
| Hyper-V `up` fails with `0x800705AA` | Less than about 2.5 GB free on the host. Run `wsl --shutdown` and close memory-heavy applications |
| Hyper-V prompts for SMB credentials on `up` | A box that defaults `/vagrant` to SMB. The rig's Vagrantfile disables that share; make sure you run from `vagrant/` |

## Runs

| Symptom | Cause and fix |
| --- | --- |
| The agent refuses to start: no configuration | `/etc/synthaea/agent.toml` is missing; `build` installs the template |
| The `--alerts` file fails with `EACCES` | Let the agent create the file. Under `fs.protected_regular`, the root agent cannot open a file pre-created by another user |
| T1562.001 fires in a scenario that sends no signal | Stopping the agent is itself a signal to a security process. The runner snapshots the alerts before stopping it, so reports are not affected; when running by hand, read the alerts before stopping the agent |
| A BAYES alert names `sshd` or your shell | The operator's own session, seen by the correlator. Reported as UNEXPECTED |
| `timestomp-linux` is skipped on kernel 6.1 or 5.15 | The `inode_setattr` LSM hook needs the 6.3 signature; the agent disables it and the report shows the warning |
