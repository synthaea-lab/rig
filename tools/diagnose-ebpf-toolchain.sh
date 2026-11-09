#!/usr/bin/env bash
# eBPF toolchain diagnostic — run inside a lab VM when a build lands WITHOUT the
# embedded probes ("sensor-linux was built without embedded eBPF probes"):
#
#   vssh ubuntu2204 'bash /synthaea/rig/tools/diagnose-ebpf-toolchain.sh'
#
# Checks the three things userspace/build.rs needs (bpf-linker on PATH, a nightly
# with rust-src, an LLVM major that matches), then does a verbose probe build so
# the real rustc/bpf-linker error is visible instead of buried by aya-build.
#
# Strict mode: a missing tool or a grep that matches nothing is a finding to print,
# not a reason to stop, so every such check ends in `|| echo ...` or `|| true`.
set -euo pipefail
# Written by the guest's provisioning: there is nothing for shellcheck to follow.
# shellcheck source=/dev/null
source "$HOME/.cargo/env" 2>/dev/null || true

agent_src=${SYNTHAEA_SRC:-/synthaea/agent}

# `ls -ld` each entry of $1 whose name mentions bpf, aya or bindgen ("none" if there is none).
list_toolchain_entries() {
  local entry found=0
  for entry in "$1"/*; do
    case ${entry##*/} in
      *bpf*|*aya*|*bindgen*) ls -ld "$entry"; found=1 ;;
    esac
  done
  [ "$found" = 1 ] || echo "  none"
}

# True when rustup lists a toolchain whose name starts with $1. The list is captured
# first so `grep -q` exiting early cannot SIGPIPE rustup and fail the pipeline.
has_toolchain() {
  local toolchains
  toolchains=$(rustup toolchain list) || return 1
  grep -q "^$1" <<<"$toolchains"
}

echo "=== bpf-linker on PATH ==="
command -v bpf-linker && bpf-linker --version || echo "  bpf-linker NOT on PATH — run: vagrant provision <machine>"
echo
echo "=== ~/.cargo/bin ==="
list_toolchain_entries "$HOME/.cargo/bin"
echo
echo "=== /usr/local/bin symlinks (sudo's PATH) ==="
list_toolchain_entries /usr/local/bin
echo
echo "=== eBPF probe toolchain (LLVM major) ==="
ebpf_toolchain=$(tr -d '[:space:]' 2>/dev/null < "$agent_src/packaging/toolchain/ebpf-toolchain.txt" || echo nightly)
echo "  (ebpf-toolchain.txt: $ebpf_toolchain)"
toolchain_installed=0
if has_toolchain "$ebpf_toolchain"; then
  toolchain_installed=1
  rustup run "$ebpf_toolchain" rustc -Vv 2>&1 | grep -i llvm || true
else
  echo "  $ebpf_toolchain not installed — rustup toolchain install $ebpf_toolchain --profile minimal --component rust-src"
fi
echo
echo "=== probe toolchain rust-src component ==="
if [ "$toolchain_installed" = 1 ]; then
  rustup component list --installed --toolchain "$ebpf_toolchain" 2>/dev/null | grep rust-src \
    || echo "  rust-src missing — rustup component add rust-src --toolchain $ebpf_toolchain"
fi
echo
echo "=== system LLVM ==="
llvm-config --version 2>&1 || echo "  no llvm-config"
ls -d /usr/lib/llvm-* 2>/dev/null || echo "  no /usr/lib/llvm-*"
echo
echo "=== verbose probe build ==="
cd "$agent_src"
# The build's own status is not the finding: the filtered lines are.
cargo build --release -p sensor-linux 2>&1 \
  | grep -iE 'bpf-linker|error|warning: sensor-linux|embedded|Compiling sensor|Finished' | head -30 || true
