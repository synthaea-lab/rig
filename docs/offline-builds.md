# Offline builds

`python3 rig.py build <machine> --offline` builds the agent in a Linux guest that never
reaches crates.io or the ONNX Runtime CDN. It suits slow or metered connections: the host
downloads once, and every later build in every VM reuses the same bundle.

## On the host

`tools/offline_bundle.py` (run by `rig.py build --offline`, or by hand with
`python3 tools/offline_bundle.py --push <machine>`):

1. Runs `cargo vendor --locked --versioned-dirs` on `agent/`, from the host's cargo cache
   when the host has built the agent before.
2. Vendors the eBPF toolchain's sysroot crates too, and merges them in. The eBPF crate builds
   `core` with nightly `-Z build-std`, which resolves the sysroot's own lockfile and fails
   offline without them. This installs the eBPF toolchain on the host on first use (about
   70 MB).
3. Adds the prebuilt ONNX Runtime for the guest's target from the host's ort cache
   (`~/.cache/ort.pyke.io`), which exists after any host build of the agent on the same OS
   and architecture.
4. Packs the result into `.offline/` (about 100 MB, cached per key) and uploads it with
   `vagrant upload`, unless the guest already has that bundle.

The bundle is keyed on `agent/Cargo.lock` and `agent/packaging/toolchain/ebpf-toolchain.txt`.
After either changes, `--offline` builds and pushes a new bundle; the guest refuses a bundle
made for other sources.

## In the guest

`provisioning/agent-build.sh --offline` unpacks the bundle to `~/synthaea-offline/` and
points a private `CARGO_HOME` at it, with a source replacement and `net.offline = true`.
Nested cargo invocations such as the eBPF build inherit it, and online builds are not
affected. Switching a guest between online and offline builds recompiles the dependencies
once, because their sources moved: about 10 minutes at 4 vCPUs.

## Limits

- Provisioning a new machine (its first `up`) still needs the network: packages, rustup,
  bpf-linker and the `cargo install` of bindgen and aya-tool.
- `--ort-compat` installs packages and needs the guest's package mirror.
- `--ort static` clones and builds ONNX Runtime, so it cannot run offline.
- A Windows or Intel macOS host has no cached Linux ONNX Runtime to bundle. The guest then
  downloads it once (about 25 MB) and the build warns.
