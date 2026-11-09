# Machine matrix

The targets the rig must be able to produce, and what each one proves about the agent. How
to boot a row (the box per provider, its provisioning) is in
[`machines.json`](../machines.json); its `matrix` field names a row of the table below, so
keep the row names stable. [machines.md](machines.md) describes the catalog.

## Why a matrix

The agent's Linux sensors are eBPF programs driven by tracepoints and BPF-LSM hooks. Parent
lineage comes from `sched_process_fork` fields, the executed image from
`sched_process_exec`, and the command line from `/proc/<pid>/cmdline` read in user space, so
there is no table of per-kernel `task_struct` offsets to maintain. Every kernel is still a
portability test case: the tracepoint record layout, `__data_loc` string handling, the BTF
available at load time and the verifier's rules all drift across versions. The
`sched_process_fork` layout, for one, carries `comm` inline on 6.8 and 6.12 kernels and as
a `__data_loc` field on newer ones. The C library matters too: the agent links a prebuilt
ONNX Runtime that needs a recent glibc and libstdc++, and musl is a separate build.

On Windows the sensors are ETW consumers, the Event Log and a few socket and service APIs,
so the rows are about Windows SKUs rather than kernels.

## Targets

| Row (`matrix`) | Machine | Family | Kernel | Proves |
| --- | --- | --- | --- | --- |
| `ubuntu-24.04` | `ubuntu2404` | Debian | 6.8 | The primary development and validation target |
| `ubuntu-22.04` | `ubuntu2204` | Debian | 5.15 | The oldest supported LTS kernel, with the strictest verifier of the Debian family |
| `debian-12` | `debian12` | Debian | 6.1 | Debian oldstable; a kernel without the 6.3 `inode_setattr` LSM signature |
| `debian-13` | `debian13` | Debian | 6.12 | The newest Debian kernel |
| `fedora-41` | `fedora41` | RPM | 6.11, 6.17 with updates | The RPM family, SELinux enforcing, a `__data_loc` `sched_process_fork` once updated |
| `rocky-9` | `rocky9` | RPM (RHEL) | 5.14 | The enterprise RHEL-clone baseline; replay only (no LLVM recent enough for the probes) |
| `arch (rolling)` | `arch` | pacman | rolling | Kernel and LLVM drift as it happens |
| `alpine-3.24` | `alpine319` | musl, BusyBox | 6.18 (`virt`) | musl libc and a BusyBox userland instead of glibc and coreutils |
| `windows-11 / windows-10` | `win11`, `win10` | Windows client | | ETW sensors on client SKUs |
| `windows-server` | `winserver` | Windows server | | ETW sensors on server SKUs |
| `macos` | none | macOS | | EndpointSecurity sensors; real hardware or a local hypervisor, no Vagrant box |

The Alpine row targets 3.24, but the newest Alpine Vagrant box is `generic/alpine319`
(3.19, kernel 6.6). The row is about musl and BusyBox, not a kernel version, so the older
box still covers it.

## Validation status

A row is validated when the agent built in the guest, `agent status` loaded every eBPF
program through that kernel's verifier, and scenarios ran. Evidence is a report committed
under [`reports/`](../reports/) ([reports.md](reports.md#recording-a-result)).

| Row | Status | Evidence |
| --- | --- | --- |
| `debian-12` | Validated on libvirt (`generic/debian12`), built with `--offline` and `--ort-compat`: 7 eBPF programs accepted, the 15 default scenarios run (`timestomp-linux` skipped below 6.3) | [`reports/2026-11-08-debian12.md`](../reports/2026-11-08-debian12.md) |
| `ubuntu-24.04` | Validated on Hyper-V before the current runner existed: programs accepted, argv and lineage checks passed | No report committed |
| `debian-13` | Same as `ubuntu-24.04` | No report committed |
| `fedora-41` | Validated on Hyper-V on kernel 6.17.7: native build with clang/LLVM 19, programs accepted, lineage and argv checks on a `__data_loc` `sched_process_fork`, packaged service running under SELinux enforcing with no AVC denial | No report committed |
| `arch (rolling)` | Validated on kernel 7.2: the beacon scenario fired end to end | No report committed |
| `ubuntu-22.04` | Not validated; the `--ort-compat` route for this release is untested | |
| `rocky-9`, `alpine-3.24` | Not validated with the rig | |
| Windows rows | The Windows runner has not yet run end to end on a lab VM | |

A row without a committed report should be re-run with `python3 rig.py run <machine>` before
a result is quoted, and the report committed.

## Changing the matrix

This page comes first: a new target is added here, with what it proves, and only then to
`machines.json` ([machines.md](machines.md#adding-a-machine)). A validation worth recording
here cites its committed report.
