#!/usr/bin/env bash
# Builds the agent inside a provisioned Linux lab guest, from the checkouts synced to
# /synthaea, and records what was built for the scenario runner's report.
#
#   bash /synthaea/rig/provisioning/agent-build.sh [options]
#
# Normally run by rig.py: `python rig.py build <machine> [--offline] [--ort ...]`.
#
# Options:
#   --offline        build from the bundle `tools/offline_bundle.py` pushed to the guest
#                    (vendored crates + the eBPF sysroot crates + the ONNX Runtime archive):
#                    no crates.io, no CDN. For slow or metered networks.
#   --ort MODE       how ONNX Runtime gets linked:
#                      auto      (default) prebuilt when this guest can link it, else stop and
#                                say what to do
#                      prebuilt  pyke's prebuilt static runtime (the agent's default features)
#                      static    a source-built static runtime (agent/toolchain/
#                                build-onnxruntime-static.sh, ~1 GB of downloads, slow) and
#                                `--no-default-features --features test-key`
#   --ort-compat     on Debian 12 / Ubuntu 22.04, first install the newer glibc + libstdc++
#                    the prebuilt runtime needs (provisioning/ort-compat.sh --apply)
#   --debug          a debug build instead of --release
#
# Environment: SYNTHAEA_ROOT (default /synthaea), SYNTHAEA_SOURCE (a description of the
# sources, set by rig.py: the guest has no .git), RIG_STATE (default
# ~/synthaea-rig, where build-info and logs go).
set -euo pipefail

ROOT=${SYNTHAEA_ROOT:-/synthaea}
SRC=$ROOT/agent
RIG=$ROOT/rig
STATE=${RIG_STATE:-$HOME/synthaea-rig}
OFFLINE_DIR=$HOME/synthaea-offline
OFFLINE=0 ORT=auto ORT_COMPAT=0 PROFILE=release

while [ $# -gt 0 ]; do
  case $1 in
    --offline) OFFLINE=1 ;;
    --ort) ORT=${2:?--ort needs auto, prebuilt or static}; shift ;;
    --ort-compat) ORT_COMPAT=1 ;;
    --debug) PROFILE=debug ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//;/^set -euo/d'; exit 0 ;;
    *) echo "agent-build: unknown option $1 (see --help)" >&2; exit 2 ;;
  esac
  shift
done

say() { printf '\n== %s ==\n' "$*"; }
die() { echo "agent-build: $*" >&2; exit 1; }

# Both are written by the guest's provisioning, so they do not exist where shellcheck runs.
# shellcheck source=/dev/null
[ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
# shellcheck source=/dev/null
for f in /etc/profile.d/synthaea-*.sh; do [ -f "$f" ] && . "$f"; done
mkdir -p "$STATE"

[ -f "$SRC/Cargo.toml" ] || die "$SRC/Cargo.toml missing - are the sources synced? (vagrant rsync <machine>)"
command -v cargo >/dev/null || die "no cargo - the guest is not provisioned (vagrant provision <machine>)"
command -v bpf-linker >/dev/null || die "bpf-linker not on PATH: the build would silently drop the eBPF probes (vagrant provision <machine>)"
EBPF_TC=$(tr -d '[:space:]' < "$SRC/ebpf-toolchain.txt")
rustup toolchain list | grep -q "^$EBPF_TC" || die "probe toolchain $EBPF_TC missing (vagrant provision <machine>)"

# An earlier hand-rolled offline build may have left a global source replacement behind,
# which breaks every online build afterwards. The offline mode below scopes it to its own
# CARGO_HOME instead.
if [ -f "$HOME/.cargo/config.toml" ] && grep -q 'vendored-sources' "$HOME/.cargo/config.toml"; then
  mv "$HOME/.cargo/config.toml" "$HOME/.cargo/config.toml.vendored-bak"
  echo "agent-build: moved a global vendored-sources ~/.cargo/config.toml aside (now ~/.cargo/config.toml.vendored-bak)"
fi

# --- offline bundle --------------------------------------------------------------------
if [ "$OFFLINE" = 1 ]; then
  say "offline bundle"
  incoming=""   # the newest pushed bundle, if any
  for f in /tmp/synthaea-offline-*.tar.gz; do
    [ -f "$f" ] || continue
    if [ -z "$incoming" ] || [ "$f" -nt "$incoming" ]; then incoming=$f; fi
  done
  if [ -n "$incoming" ]; then
    rm -rf "$OFFLINE_DIR.new" && mkdir -p "$OFFLINE_DIR.new"
    tar -xzf "$incoming" -C "$OFFLINE_DIR.new"
    rm -rf "$OFFLINE_DIR" && mv "$OFFLINE_DIR.new" "$OFFLINE_DIR"
    rm -f /tmp/synthaea-offline-*.tar.gz
    echo "unpacked $incoming"
  fi
  [ -f "$OFFLINE_DIR/KEY" ] || die "no offline bundle in the guest: run the build from the host with --offline (it pushes one)"
  want=$({ cat "$SRC/Cargo.lock"; printf '\0'; cat "$SRC/ebpf-toolchain.txt"; } | sha256sum | cut -c1-16)
  have=$(cat "$OFFLINE_DIR/KEY")
  [ "$want" = "$have" ] || die "the offline bundle ($have) was made for another Cargo.lock or probe toolchain ($want): re-run from the host with --offline"
  export CARGO_HOME=$OFFLINE_DIR/cargo-home
  mkdir -p "$CARGO_HOME"
  # Scoped to this CARGO_HOME, which nested cargo runs (the eBPF build) inherit.
  sed "s#@VENDOR@#$OFFLINE_DIR/vendor#g" "$OFFLINE_DIR/vendor-config.toml" > "$CARGO_HOME/config.toml"
  printf '\n[net]\noffline = true\n' >> "$CARGO_HOME/config.toml"
  if [ -d "$OFFLINE_DIR/ort-cache/dfbin" ]; then
    mkdir -p "$HOME/.cache/ort.pyke.io"
    cp -a "$OFFLINE_DIR/ort-cache/dfbin" "$HOME/.cache/ort.pyke.io/"
  fi
  echo "vendored crates: $(find "$OFFLINE_DIR/vendor" -mindepth 1 -maxdepth 1 -name '[!.]*' | wc -l), cargo home: $CARGO_HOME"
fi

# --- ONNX Runtime ----------------------------------------------------------------------
say "ONNX Runtime"
if [ "$ORT_COMPAT" = 1 ]; then
  [ "$OFFLINE" = 1 ] && echo "agent-build: --ort-compat installs packages: it needs the guest's package mirror even with --offline"
  bash "$RIG/provisioning/ort-compat.sh" --apply
fi
if [ "$ORT" = auto ]; then
  if bash "$RIG/provisioning/ort-compat.sh" --check; then
    ORT=prebuilt
  else
    cat >&2 <<'MSG'
agent-build: this guest cannot link the prebuilt ONNX Runtime (README.md, "ONNX Runtime
on older distros"). Pick one:
  --ort-compat   Debian 12 / Ubuntu 22.04: newer glibc + libstdc++ from the next release (fast)
  --ort static   build ONNX Runtime from source with this distro's compiler (slow, ~1 GB)
MSG
    exit 1
  fi
fi

FEATURES=()
case $ORT in
  prebuilt)
    echo "prebuilt (pyke, ort-sys download-binaries)"
    ;;
  static)
    [ "$OFFLINE" = 1 ] && die "--ort static clones and builds onnxruntime: not possible offline"
    export ORT_LIB_LOCATION=${ORT_LIB_LOCATION:-$SRC/onnxruntime/build/Linux/Release}
    if ! ls "$ORT_LIB_LOCATION"/libonnxruntime_session.a >/dev/null 2>&1; then
      echo "building onnxruntime from source into $SRC/onnxruntime (rsync leaves it alone)"
      bash "$SRC/toolchain/build-onnxruntime-static.sh"
    fi
    ls "$ORT_LIB_LOCATION"/_deps/re2-build/libre2.a >/dev/null 2>&1 \
      || cmake --build "$ORT_LIB_LOCATION" --target re2 -j"${CARGO_BUILD_JOBS:-2}"
    eval "$(bash "$SRC/toolchain/ort-static-link-flags.sh")"
    FEATURES=(--no-default-features --features test-key)
    echo "static from source: ORT_LIB_LOCATION=$ORT_LIB_LOCATION"
    ;;
  *) die "--ort must be auto, prebuilt or static" ;;
esac

# --- build -----------------------------------------------------------------------------
say "cargo build ($PROFILE${FEATURES[*]:+ ${FEATURES[*]}}, ${CARGO_BUILD_JOBS:-all} jobs)"
PROFILE_FLAG=(--release)
[ "$PROFILE" = debug ] && PROFILE_FLAG=()
start=$(date +%s)
cd "$SRC"
cargo build "${PROFILE_FLAG[@]}" -p agent "${FEATURES[@]}" 2>&1 | tee "$STATE/build.log"
build_seconds=$(( $(date +%s) - start ))
BIN=${CARGO_TARGET_DIR:-$SRC/target}/$PROFILE/agent
[ -x "$BIN" ] || die "no binary at $BIN"

# --- config + verifier check -----------------------------------------------------------
# The agent refuses to start without a config (ADR-0013); a lab guest uses the template.
if [ ! -f /etc/synthaea/agent.toml ]; then
  sudo install -D -m 0644 "$SRC/crates/config/data/default-agent.toml" /etc/synthaea/agent.toml
  echo "installed the default /etc/synthaea/agent.toml"
fi

say "agent status (eBPF verifier)"
sudo "$BIN" status 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | tee "$STATE/status.txt"
if grep -q "without embedded eBPF probes" "$STATE/status.txt"; then
  die "the build has no eBPF probes (bash $RIG/tools/diagnose-ebpf-toolchain.sh explains why)"
fi

cat > "$STATE/build-info" <<INFO
agent_bin=$BIN
source=${SYNTHAEA_SOURCE:-unknown (set by rig.py)}
built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
build_seconds=$build_seconds
profile=$PROFILE
ort=$ORT
offline=$OFFLINE
rustc=$(cd "$SRC" && rustc --version)
INFO
say "done"
cat "$STATE/build-info"
