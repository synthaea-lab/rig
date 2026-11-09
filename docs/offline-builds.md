# Offline builds

`python3 rig.py build <machine> --offline` builds the agent in a Linux guest that never
reaches crates.io or the ONNX Runtime CDN. It suits slow or metered connections: the host
downloads once, packs a bundle, and every later build in every VM reuses it. The host side is
[`tools/offline_bundle.py`](../tools/offline_bundle.py); the guest side is the `--offline`
path of [`provisioning/agent-build.sh`](../provisioning/agent-build.sh).

## The bundle

A gzip tarball, `.offline/synthaea-offline-<KEY>-<target>.tar.gz` in the rig checkout
(ignored by git), about 100 MB:

| Entry | Content |
| --- | --- |
| `KEY` | The bundle key (below) |
| `vendor/` | `cargo vendor --locked --versioned-dirs` of the agent checkout, merged with the vendored crates of the eBPF toolchain's sysroot |
| `vendor-config.toml` | The source replacement `cargo vendor` printed, with the guest path left as `@VENDOR@` |
| `ort-cache/dfbin/<target>/<digest>/` | pyke's prebuilt ONNX Runtime for the guest's target, when the host's ort cache has it |

### Why the sysroot crates

The eBPF crate builds `core` with nightly `-Z build-std`, which resolves the standard
library's own `Cargo.lock` and needs its dependencies (`compiler_builtins` and others).
Vendoring only the agent's own dependencies is not enough: an offline probe build then fails with
`no matching package named core`. The bundle therefore installs the eBPF nightly on the host
(with `rust-src`, about 70 MB on first use), vendors the crates of
`<sysroot>/lib/rustlib/src/rust/library/Cargo.toml`, and merges any crate not already present
into `vendor/`.

### The key

```text
KEY = first 16 hex digits of sha256( agent/Cargo.lock + "\0" + agent/packaging/toolchain/ebpf-toolchain.txt )
```

Those two files decide every crate the build needs, so they decide whether a bundle fits.
[`bundle_key`](../tools/offline_bundle.py) computes it in Python on the host and
[`expected_bundle_key`](../provisioning/agent-build.sh) computes it in bash in the guest;
[`tests/test_offline_bundle.py`](../tests/test_offline_bundle.py) checks that the two agree
byte for byte.

## On the host

`rig.py build --offline` syncs the sources, then runs `tools/offline_bundle.py --push
<machine>` before the guest build. By hand:

```bash
python3 tools/offline_bundle.py                    # build the bundle for x86_64-unknown-linux-gnu
python3 tools/offline_bundle.py --push debian12    # build it for the guest's architecture and upload it
python3 tools/offline_bundle.py --push debian12 --target aarch64-unknown-linux-gnu
```

[`push`](../tools/offline_bundle.py) works in this order:

1. Asks the guest, over `vagrant ssh`, for `uname -m` and the key of the bundle it already
   has. The target defaults to `<arch>-unknown-linux-gnu`.
2. Vendors into `.offline/<KEY>/`, unless `vendor/.complete` is already there: vendoring is
   cached per key, and the marker is written last so an interrupted run starts over.
3. Looks up the ONNX Runtime digest for the target in the vendored `ort-sys`'s
   `build/download/dist.tsv`, then the runtime itself in the host's ort cache
   (`ORT_CACHE_DIR`, `XDG_CACHE_HOME`, `~/.cache/ort.pyke.io`,
   `~/Library/Caches/ort.pyke.io`, `%LOCALAPPDATA%\ort.pyke.io`). The cache holds it after
   any host build of the agent on the same OS and architecture. Without it the bundle is made
   anyway, with a warning.
4. Packs the tarball, unless it is already cached, writing to a `.partial` file first.
5. Skips the upload when the guest already has that key; otherwise uploads the tarball to
   `/tmp/` in the guest with `vagrant upload`.

The host needs rustup and cargo, which any agent work needs anyway.

## In the guest

`agent-build.sh --offline` ([`prepare_offline_build`](../provisioning/agent-build.sh)):

1. Unpacks the newest `/tmp/synthaea-offline-*.tar.gz` into `~/synthaea-offline.new`, swaps
   it in place of `~/synthaea-offline`, and deletes the pushed tarballs. With no tarball in
   `/tmp` (the host skipped the upload), the bundle already in place is used.
2. Refuses, with exit 2, a bundle whose `KEY` does not match the synced `Cargo.lock` and
   toolchain file, or no bundle at all.
3. Points a private `CARGO_HOME` at `~/synthaea-offline/cargo-home`, whose `config.toml` is
   the source replacement (with the real vendor path) plus `[net] offline = true`. Nested
   cargo invocations, such as the eBPF build the agent's build script starts, inherit it;
   online builds, which use `~/.cargo`, are not affected.
4. Copies the bundled ONNX Runtime into `~/.cache/ort.pyke.io/dfbin/`, where `ort-sys` looks
   before downloading.

Switching a guest between online and offline builds recompiles the dependencies once,
because their source paths changed: about 10 minutes at 4 vCPUs.

## Limits

- Provisioning a new machine (its first `up`) needs the network: packages, rustup,
  bpf-linker and the `cargo install` of bindgen and aya-tool.
- `--ort-compat` installs packages from the guest's mirror, even with `--offline`; the build
  says so.
- `--ort static` clones and builds ONNX Runtime, so it is refused with `--offline`. Alpine,
  which has no prebuilt runtime, therefore cannot build offline.
- A Windows or Intel macOS host has no cached Linux ONNX Runtime to bundle. The guest then
  downloads it once (about 25 MB), unless an earlier online build left it in its cache.
- Windows guests have no offline mode; `rig.py` ignores `--offline` for them.
