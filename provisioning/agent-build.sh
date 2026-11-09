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
#                      static    a source-built static runtime (agent/packaging/toolchain/
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
EBPF_TOOLCHAIN_FILE=$SRC/packaging/toolchain/ebpf-toolchain.txt

# The options, set by parse_args.
OFFLINE=0 ORT=auto ORT_COMPAT=0 PROFILE=release
# The cargo features select_ort picks, and what build_agent built.
FEATURES=() AGENT_BIN="" BUILD_SECONDS=""

say() { printf '\n== %s ==\n' "$*"; }
die() { echo "agent-build: $*" >&2; exit 1; }

print_help() {
  sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//;/^set -euo/d'
}

parse_args() {
  while [ $# -gt 0 ]; do
    case $1 in
      --offline) OFFLINE=1 ;;
      --ort) ORT=${2:?--ort needs auto, prebuilt or static}; shift ;;
      --ort-compat) ORT_COMPAT=1 ;;
      --debug) PROFILE=debug ;;
      -h|--help) print_help; exit 0 ;;
      *) echo "agent-build: unknown option $1 (see --help)" >&2; exit 2 ;;
    esac
    shift
  done
}

load_guest_environment() {
  local profile_script
  # Both are written by the guest's provisioning, so they do not exist where shellcheck runs.
  # shellcheck source=/dev/null
  if [ -f "$HOME/.cargo/env" ]; then . "$HOME/.cargo/env"; fi
  for profile_script in /etc/profile.d/synthaea-*.sh; do
    # shellcheck source=/dev/null
    if [ -f "$profile_script" ]; then . "$profile_script"; fi
  done
}

preflight() {
  local ebpf_toolchain toolchains
  [ -f "$SRC/Cargo.toml" ] || die "$SRC/Cargo.toml missing - are the sources synced? (vagrant rsync <machine>)"
  command -v cargo >/dev/null || die "no cargo - the guest is not provisioned (vagrant provision <machine>)"
  command -v bpf-linker >/dev/null || die "bpf-linker not on PATH: the build would silently drop the eBPF probes (vagrant provision <machine>)"
  ebpf_toolchain=$(tr -d '[:space:]' < "$EBPF_TOOLCHAIN_FILE")
  # Listed first, not piped: `grep -q` stops reading at the first match, and pipefail then
  # reports rustup's failed writes as a missing toolchain.
  toolchains=$(rustup toolchain list)
  grep -q "^$ebpf_toolchain" <<<"$toolchains" || die "probe toolchain $ebpf_toolchain missing (vagrant provision <machine>)"
}

# An earlier hand-rolled offline build may have left a global source replacement behind,
# which breaks every online build afterwards. The offline mode scopes it to its own
# CARGO_HOME instead.
move_global_vendored_config_aside() {
  local config=$HOME/.cargo/config.toml
  if [ -f "$config" ] && grep -q 'vendored-sources' "$config"; then
    mv "$config" "$config.vendored-bak"
    echo "agent-build: moved a global vendored-sources ~/.cargo/config.toml aside (now ~/.cargo/config.toml.vendored-bak)"
  fi
}

# The newest bundle the host pushed to /tmp, or nothing.
newest_pushed_bundle() {
  local bundle newest=""
  for bundle in /tmp/synthaea-offline-*.tar.gz; do
    [ -f "$bundle" ] || continue
    if [ -z "$newest" ] || [ "$bundle" -nt "$newest" ]; then newest=$bundle; fi
  done
  echo "$newest"
}

unpack_offline_bundle() {
  local incoming
  incoming=$(newest_pushed_bundle)
  if [ -n "$incoming" ]; then
    rm -rf "$OFFLINE_DIR.new" && mkdir -p "$OFFLINE_DIR.new"
    tar -xzf "$incoming" -C "$OFFLINE_DIR.new"
    rm -rf "$OFFLINE_DIR" && mv "$OFFLINE_DIR.new" "$OFFLINE_DIR"
    rm -f /tmp/synthaea-offline-*.tar.gz
    echo "unpacked $incoming"
  fi
}

# The bundle KEY tools/offline_bundle.py computes for this Cargo.lock and probe toolchain.
expected_bundle_key() {
  { cat "$SRC/Cargo.lock"; printf '\0'; cat "$EBPF_TOOLCHAIN_FILE"; } | sha256sum | cut -c1-16
}

verify_offline_bundle() {
  local want have
  [ -f "$OFFLINE_DIR/KEY" ] || die "no offline bundle in the guest: run the build from the host with --offline (it pushes one)"
  want=$(expected_bundle_key)
  have=$(cat "$OFFLINE_DIR/KEY")
  [ "$want" = "$have" ] || die "the offline bundle ($have) was made for another Cargo.lock or probe toolchain ($want): re-run from the host with --offline"
}

use_offline_cargo_home() {
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
}

prepare_offline_build() {
  say "offline bundle"
  unpack_offline_bundle
  verify_offline_bundle
  use_offline_cargo_home
}

# auto becomes prebuilt when this guest can link the prebuilt runtime; otherwise stop.
resolve_auto_ort() {
  if bash "$RIG/provisioning/ort-compat.sh" --check; then
    ORT=prebuilt
    return
  fi
  cat >&2 <<'MSG'
agent-build: this guest cannot link the prebuilt ONNX Runtime (README.md, "ONNX Runtime
on older distros"). Pick one:
  --ort-compat   Debian 12 / Ubuntu 22.04: newer glibc + libstdc++ from the next release (fast)
  --ort static   build ONNX Runtime from source with this distro's compiler (slow, ~1 GB)
MSG
  exit 1
}

# The contract of ort-static-link-flags.sh: on stdout, shell to eval (an
# `export RUSTFLAGS="..."` line) that links every static library under ORT_LIB_LOCATION; on
# failure, a non-zero exit. The flags are captured first so that a failure stops the build
# here rather than in the linker.
apply_static_link_flags() {
  local flags
  flags=$(bash "$SRC/packaging/toolchain/ort-static-link-flags.sh")
  eval "$flags"
}

prepare_static_ort() {
  [ "$OFFLINE" = 0 ] || die "--ort static clones and builds onnxruntime: not possible offline"
  export ORT_LIB_LOCATION=${ORT_LIB_LOCATION:-$SRC/onnxruntime/build/Linux/Release}
  if [ ! -f "$ORT_LIB_LOCATION/libonnxruntime_session.a" ]; then
    echo "building onnxruntime from source into $SRC/onnxruntime (rsync leaves it alone)"
    bash "$SRC/packaging/toolchain/build-onnxruntime-static.sh"
  fi
  [ -f "$ORT_LIB_LOCATION/_deps/re2-build/libre2.a" ] \
    || cmake --build "$ORT_LIB_LOCATION" --target re2 -j"${CARGO_BUILD_JOBS:-2}"
  apply_static_link_flags
  FEATURES=(--no-default-features --features test-key)
  echo "static from source: ORT_LIB_LOCATION=$ORT_LIB_LOCATION"
}

select_ort() {
  say "ONNX Runtime"
  if [ "$ORT_COMPAT" = 1 ]; then
    if [ "$OFFLINE" = 1 ]; then
      echo "agent-build: --ort-compat installs packages: it needs the guest's package mirror even with --offline"
    fi
    bash "$RIG/provisioning/ort-compat.sh" --apply
  fi
  if [ "$ORT" = auto ]; then resolve_auto_ort; fi
  case $ORT in
    prebuilt) echo "prebuilt (pyke, ort-sys download-binaries)" ;;
    static) prepare_static_ort ;;
    *) die "--ort must be auto, prebuilt or static" ;;
  esac
}

build_agent() {
  local profile_flag=(--release) start
  if [ "$PROFILE" = debug ]; then profile_flag=(); fi
  say "cargo build ($PROFILE${FEATURES[*]:+ ${FEATURES[*]}}, ${CARGO_BUILD_JOBS:-all} jobs)"
  start=$(date +%s)
  (cd "$SRC" && cargo build "${profile_flag[@]}" -p agent "${FEATURES[@]}") 2>&1 | tee "$STATE/build.log"
  BUILD_SECONDS=$(( $(date +%s) - start ))
  AGENT_BIN=${CARGO_TARGET_DIR:-$SRC/target}/$PROFILE/agent
  [ -x "$AGENT_BIN" ] || die "no binary at $AGENT_BIN"
}

# The agent refuses to start without a config (ADR-0013); a lab guest uses the template.
install_default_config() {
  if [ ! -f /etc/synthaea/agent.toml ]; then
    sudo install -D -m 0644 "$SRC/crates/config/data/default-agent.toml" /etc/synthaea/agent.toml
    echo "installed the default /etc/synthaea/agent.toml"
  fi
}

# `agent status` loads the probes through the kernel's eBPF verifier.
verify_probes() {
  say "agent status (eBPF verifier)"
  sudo "$AGENT_BIN" status 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | tee "$STATE/status.txt"
  if grep -q "without embedded eBPF probes" "$STATE/status.txt"; then
    die "the build has no eBPF probes (bash $RIG/tools/diagnose-ebpf-toolchain.sh explains why)"
  fi
}

# run-scenarios.sh reads these keys (agent_bin, and the rest for its report header).
write_build_info() {
  cat > "$STATE/build-info" <<INFO
agent_bin=$AGENT_BIN
source=${SYNTHAEA_SOURCE:-unknown (set by rig.py)}
built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
build_seconds=$BUILD_SECONDS
profile=$PROFILE
ort=$ORT
offline=$OFFLINE
rustc=$(cd "$SRC" && rustc --version)
INFO
}

main() {
  parse_args "$@"
  load_guest_environment
  mkdir -p "$STATE"
  preflight
  move_global_vendored_config_aside
  if [ "$OFFLINE" = 1 ]; then prepare_offline_build; fi
  select_ort
  build_agent
  install_default_config
  verify_probes
  write_build_info
  say "done"
  cat "$STATE/build-info"
}

main "$@"
