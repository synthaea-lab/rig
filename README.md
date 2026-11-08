# lab — Test Lab

Reproducible environment for validating detections and sensors end to end.

Part of the Synthaea umbrella ([synthaea-lab/edr](https://github.com/synthaea-lab/edr)),
checked out at `<umbrella>/lab`. The VM harnesses sync the **umbrella** root to
`/synthaea`; in-VM scripts build in `/synthaea/agent` and reach scenarios as
`../lab/scenarios`. The toolchain and ONNX Runtime build scripts that used to live in
`provisioning/` moved to the agent repo (`agent/toolchain/`).

The lab is defined **provider-neutrally**: the machine matrix (which OS/kernel
combinations must be tested and why) and the provisioning scripts are shared; how the
VMs are created is a per-developer choice. Vagrant+QEMU on macOS is the first harness —
others (Hyper-V, VirtualBox, Proxmox, cloud instances, WSL2 for Linux-only work) are
welcome as siblings of `vagrant/` reusing the same `provisioning/` scripts.

| Path | Purpose |
| --- | --- |
| `MATRIX.md` | The canonical machine matrix: OS, kernel, family, what each machine proves |
| `provisioning/` | Provider-neutral setup scripts every harness runs inside its VMs |
| `vagrant/` | Vagrant harness (QEMU on Apple Silicon; Windows boxes need an x86 host) |
| `vagrant-hyperv/` | Vagrant harness (Hyper-V on Windows; Debian-family x86_64 rows) + `RUNBOOK-155.md` |
| `scenarios/` | Scripted attack scenarios run against a live agent in any harness |
| `validate-155.sh` | In-VM assertion script for PR #155: build + verifier + argv (#152) + lineage (#53) |
| `lint.sh` | In-VM local lint gate — same checks as CI, run when sparing the CI budget |
| `diag.sh` | In-VM eBPF toolchain diagnostic (bpf-linker / nightly / rust-src / LLVM major) |

Workflow: bring up a machine from the matrix with your harness, provision it, install
the agent build, run a scenario, and assert the expected detections fired (the same
scenarios back the conformance suite and CI smoke tests). To be migrated from
`old/lab`. Scenarios are benign by construction and for detection validation in the
lab only.
