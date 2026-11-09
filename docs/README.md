# rig technical documentation

The rig is Synthaea's test harness for the endpoint agent. It boots a virtual machine from
a catalog of Linux and Windows targets, builds the [agent](https://github.com/synthaea-lab/agent)
inside it from your local checkouts, runs the
[attack scenarios](https://github.com/synthaea-lab/scenarios) against it with the
[detection content](https://github.com/synthaea-lab/rules), and writes a report that sets
what each scenario expects next to what the agent detected.

These pages explain how it works, with links into the code that implements each step. The
root [README](../README.md) is the quick guide (setup, prerequisites, the five commands);
this documentation is the reference behind it.

## Where the rig sits

Synthaea is built from a few repositories that live side by side in one directory, the
rig's *root*:

| Checkout | Role | What the rig does with it |
| --- | --- | --- |
| [`agent`](https://github.com/synthaea-lab/agent) | The endpoint agent: sensors (eBPF, ETW, ...), detection engines, response | Builds it in the guest, runs it standalone once per scenario |
| [`rules`](https://github.com/synthaea-lab/rules) | Sigma and YARA content the agent loads | Gives it to each scenario's agent as its content directory |
| [`scenarios`](https://github.com/synthaea-lab/scenarios) | Benign attack simulations, each with a `.yaml` sidecar listing its expected detections | Runs the scripts and judges the alerts against the sidecars, which it never edits |
| [`server`](https://github.com/synthaea-lab/server) | The control plane (optional) | Syncs it when present; no default scenario needs it |
| `rig` | This repository | Drives everything from the host |

The agent's own unit and integration tests run on a build machine. What they cannot show is
how the agent behaves on a real kernel, C library and operating system: whether the eBPF
programs pass that kernel's verifier, whether the LSM hooks attach, whether a scenario's
alerts fire the expected number of times. The rig answers those questions per target, the
same way every time, so a result on Debian 12 and one on Fedora 41 are comparable.

## Pages

Read [architecture](architecture.md) first; the other pages each cover one part.

- [architecture.md](architecture.md): host and guest sides, the life of `up`, `build`,
  `run` and `report`, where state lives, command quoting, exit codes.
- [machine-matrix.md](machine-matrix.md): the targets, what each one proves, and how far
  each is validated.
- [machines.md](machines.md): the `machines.json` catalog format and its validation, what
  the Vagrantfile does with it, providers and resources, adding a machine.
- [provisioning.md](provisioning.md): the provisioners, the in-guest agent build, ONNX
  Runtime modes, `build-info`.
- [offline-builds.md](offline-builds.md): the vendored bundle that lets a guest build
  without crates.io or the ONNX Runtime CDN.
- [scenario-runs.md](scenario-runs.md): the runner catalog format, one scenario's
  lifecycle, how expectations are read and alerts judged.
- [reports.md](reports.md): what a report contains, the result values, recording a result.
- [windows.md](windows.md): Windows guests, Hyper-V hosts, and the Windows-only
  validation and capture scripts.
- [sysmon-capture.md](sysmon-capture.md): the Sysmon lab capture procedure for a Windows
  guest.
- [testing.md](testing.md): `rig.py check`, the unit tests and fixtures, and how to test a
  change to the rig.
- [troubleshooting.md](troubleshooting.md): symptoms and their fixes.
- [limits.md](limits.md): what the rig does not do yet, and its known gaps.

Contribution rules (DCO sign-off, pull requests) are in
[CONTRIBUTING.md](../CONTRIBUTING.md).
