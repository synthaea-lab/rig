# Machines and the Vagrantfile

[`machines.json`](../machines.json) is the rig's one machine catalog. [`rig.py`](../rig.py)
reads it to validate a machine name, pick the box for the host's provider and decide whether
the guest speaks bash or PowerShell; the [Vagrantfile](../vagrant/Vagrantfile) reads it to
define every machine on every provider. Neither keeps a list of its own, so adding a machine
is one catalog entry.

Per-provider host setup and the fix-ups that particular community boxes need are in
[vagrant/README.md](../vagrant/README.md).

## Catalog format

```json
{
  "_doc": ["..."],
  "defaults": {
    "linux":   { "memory_mb": 6144, "provision": "agent/packaging/toolchain/linux-toolchain.sh" },
    "windows": { "memory_mb": 8192, "provision": "agent/packaging/toolchain/windows-toolchain.ps1" }
  },
  "machines": {
    "fedora41": {
      "guest": "linux", "matrix": "fedora-41",
      "boxes": {
        "libvirt": "fedora/41-cloud-base",
        "hyperv": "jtarpley/fedora41_base",
        "qemu": "fedora/41-cloud-base",
        "virtualbox": "fedora/41-cloud-base"
      },
      "prep": ["fedora-lvm-prep.sh"],
      "qemu_ssh_port": 50422,
      "notes": "SELinux Enforcing on purpose. ..."
    }
  }
}
```

`_doc` is free text for readers of the file. `defaults` gives each guest family the values a
machine may leave out. `machines` maps the machine name (what you type after `rig.py up`, and
the Vagrant machine name) to its entry; its order is the order `list` prints.

| Field | Required | Type | Meaning |
| --- | --- | --- | --- |
| `guest` | yes | `linux` or `windows` | Linux guests use SSH, rsync and bash; Windows guests use WinRM, an uploaded zip and PowerShell |
| `matrix` | yes | string | The row of [machine-matrix.md](machine-matrix.md) this machine provides |
| `boxes` | yes | object | Provider to Vagrant box name. A provider without an entry cannot run the machine |
| `primary` | no | boolean | Vagrant's primary machine, the one a bare `vagrant up` starts. Only `ubuntu2404` has it |
| `provision` | no | string | The toolchain script, relative to the root (for example `agent/packaging/toolchain/arch-toolchain.sh`). Defaults to the guest's `defaults` entry |
| `prep` | no | list of strings | Box fix-up scripts in [`provisioning/`](../provisioning/), run before the toolchain. Linux only |
| `memory_mb` | no | integer | Guest RAM in MB. Defaults to the guest's `defaults` entry |
| `qemu_ssh_port` | no | integer | The host port the QEMU provider forwards to the guest's SSH |
| `notes` | no | string | What to know before `up`, for readers of the file |

Providers are `libvirt` (Linux hosts, x86_64), `hyperv` (Windows hosts), `qemu` (Apple
Silicon hosts, arm64 guests) and `virtualbox` (any x86_64 host, optional).

### Validation

`python3 rig.py check` validates the catalog with [`catalog_problems`](../rig.py) before
anything else uses it, so a typo fails there with the machine named, not halfway through a
`vagrant up`. It reports every problem at once:

- `defaults` has a `linux` and a `windows` entry, each with a positive whole `memory_mb`
  and a valid `provision`.
- `machines` is a non-empty object, and every entry is an object.
- No field outside the table above.
- `guest` is `linux` or `windows`; `matrix` is a non-empty string.
- `boxes` is non-empty, every key is one of the four providers, every value a non-empty
  string.
- `provision` is a relative `/` path whose first part is a sibling checkout (`agent`,
  `rules`, `scenarios`, `server`), with no empty, `.` or `..` part and no backslash, ending in
  `.sh` for Linux or `.ps1` for Windows.
- `prep` is absent on Windows guests; on Linux it lists `.sh` file names (no directory) that
  exist in `provisioning/`.
- `memory_mb` is a positive integer; `qemu_ssh_port` an integer from 1024 to 65535, unique
  across machines.

[`tests/test_catalog.py`](../tests/test_catalog.py) pins each message.

## What the Vagrantfile does

The [Vagrantfile](../vagrant/Vagrantfile) runs on every `vagrant` command and defines one
machine per catalog entry. It reads the same environment as `rig.py`:

| Variable | Effect |
| --- | --- |
| `RIG_ROOT` (or `SYNTHAEA_ROOT`) | The root holding the checkouts. Default: the parent of the rig checkout. `rig.py` always sets it |
| `RIG_MEMORY_MB` | Guest RAM, overriding the catalog (on Hyper-V Linux guests, the Dynamic Memory ceiling) |
| `RIG_CPUS` | Guest vCPUs. Default: half the host's, clamped between 2 and 8 |
| `RIG_ORT_COMPAT=1` | Enables the `ort-compat` provisioner on the first provision ([provisioning.md](provisioning.md#onnx-runtime)) |

### Providers and resources

Each provider the machine has a box for gets a provider block that overrides the base box and
applies that provider's tuning ([`PROVIDER_TUNING`](../vagrant/Vagrantfile)):

| Provider | Memory | Other settings |
| --- | --- | --- |
| `libvirt` | Fixed, the catalog value | `cpu_mode = host-passthrough`, so the guest sees the host CPU's features |
| `hyperv` | Linux: Dynamic Memory from 2 GB up to the catalog value. Windows: fixed | VM name `synthaea-<machine>`, linked clone, nested virtualization off |
| `qemu` | Fixed | `ssh_port` from `qemu_ssh_port`: the plugin cannot allocate a forwarded port on its own, and one port per machine lets several run side by side |
| `virtualbox` | Fixed | |

Hyper-V Linux guests start small because a static allocation of the catalog's 6 GB fails to
start (`0x800705AA`) on a 16 GB host with a browser open. The balloon then grows reluctantly,
which is why [`build-host-setup.sh`](../provisioning/build-host-setup.sh) adds swap and sizes
cargo's job count to the RAM the guest actually sees.

Linux guests get the hostname `synthaea-<machine>`; the runner strips that prefix to name the
machine in its report. Every machine gets a 600 s boot timeout. The default `/vagrant` share
is disabled everywhere: some boxes default it to SMB, which prompts for Windows credentials
on every `up` under Hyper-V.

### Synced folders

Linux guests receive each checkout one way, by rsync, on `up` and on
`vagrant rsync <machine>` (which `rig.py build` and `run` call first):

| Host | Guest | Excluded besides `.git` and `.vagrant/` |
| --- | --- | --- |
| `rig/` | `/synthaea/rig` | `.offline/`, `reports/` |
| `<root>/agent` | `/synthaea/agent` | `target/`, `onnxruntime/` |
| `<root>/rules` | `/synthaea/rules` | |
| `<root>/scenarios` | `/synthaea/scenarios` | |
| `<root>/server` (when present) | `/synthaea/server` | `node_modules/`, `.next/` |

Nothing else in the root is synced. rsync's `--delete` spares excluded paths, so the guest's
own `target/` and a source-built `onnxruntime/` survive every re-sync, and builds stay
incremental. Vagrant records the synced folders at `up`: after changing the list or its
excludes, run `vagrant reload <machine>` once before `vagrant rsync` honours the change.

Windows guests have no synced folder; see [architecture.md](architecture.md#syncing-the-sources).

### Provisioners

Linux guests run, in order: `build-host-setup`, one `prep-<script>` per `prep` entry, the
`toolchain` script, and the opt-in `ort-compat`. Windows guests run `toolchain` only. What
each does is in [provisioning.md](provisioning.md#provisioners).

## Boxes per target

The catalog picks, per provider, the box that best matches each row of the matrix:

- `generic/*` boxes exist up to Ubuntu 22.04, Debian 12, Rocky 9, Arch and Alpine 3.19, on
  every provider.
- The kernel 6.8 and 6.12 targets use the official `cloud-image/*` boxes on libvirt, QEMU and
  VirtualBox. On Hyper-V only community boxes exist, and each needs a one-time fix-up
  ([vagrant/README.md](../vagrant/README.md#hyper-v-community-boxes-68--612-fedora)).
- `perk/*-arm64` are the arm64 Ubuntu boxes for QEMU; Fedora and Rocky publish arm64 boxes
  the QEMU plugin also boots.
- `gusztavvargadr/windows-*` publish libvirt, Hyper-V and VirtualBox boxes, amd64 only, so
  there is no Windows guest on Apple Silicon. Arch has no arm64 box either.

Whatever the box, record the `sched_process_fork` tracepoint layout of a new kernel, since it
is what the probes parse:

```bash
sudo cat /sys/kernel/tracing/events/sched/sched_process_fork/format
```

## Adding a machine

1. Add the target to [machine-matrix.md](machine-matrix.md) with what it proves.
2. Add the entry to `machines.json`: `guest`, `matrix` (the new row's name), and a box for
   every provider that publishes one. Give it a free `qemu_ssh_port` if it has a `qemu` box.
3. If the guest is neither apt- nor dnf-based, set `provision` to its toolchain script in the
   agent checkout.
4. If the box needs a fix-up, write a POSIX `sh` script in `provisioning/` that detects on its
   own whether it applies (so the entry can list it whatever the provider) and is idempotent,
   then list it in `prep`. [`fedora-lvm-prep.sh`](../provisioning/fedora-lvm-prep.sh) is the
   model.
5. Run `python3 rig.py check`, then `python3 rig.py list` to see the box chosen for your
   host, then `up`, `build` and `run`.
