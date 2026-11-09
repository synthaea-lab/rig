#!/usr/bin/env bash
# eBPF toolchain diagnostic — run inside a lab VM when a build lands WITHOUT the
# embedded probes ("sensor-linux was built without embedded eBPF probes"):
#
#   vssh ubuntu2204 'bash /synthaea/rig/tools/diagnose-ebpf-toolchain.sh'
#
# Checks the three things userspace/build.rs needs (bpf-linker on PATH, a nightly
# with rust-src, an LLVM major that matches), then does a verbose probe build so
# the real rustc/bpf-linker error is visible instead of buried by aya-build.
set -u
# Written by the guest's provisioning: there is nothing for shellcheck to follow.
# shellcheck source=/dev/null
source "$HOME/.cargo/env" 2>/dev/null || true

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
_ebpf_tc=$(tr -d '[:space:]' 2>/dev/null < "${SYNTHAEA_SRC:-/synthaea/agent}/packaging/toolchain/ebpf-toolchain.txt" || echo nightly)
echo "  (ebpf-toolchain.txt: $_ebpf_tc)"
rustup toolchain list | grep -q "^$_ebpf_tc" || echo "  $_ebpf_tc not installed — rustup toolchain install $_ebpf_tc --profile minimal --component rust-src"
rustup toolchain list | grep -q "^$_ebpf_tc" && { rustup run "$_ebpf_tc" rustc -Vv 2>&1 | grep -i llvm; }
echo
echo "=== probe toolchain rust-src component ==="
rustup toolchain list | grep -q "^$_ebpf_tc" && { rustup component list --installed --toolchain "$_ebpf_tc" 2>/dev/null | grep rust-src || echo "  rust-src missing — rustup component add rust-src --toolchain $_ebpf_tc"; }
echo
echo "=== system LLVM ==="
llvm-config --version 2>&1 || echo "  no llvm-config"
ls -d /usr/lib/llvm-* 2>/dev/null || echo "  no /usr/lib/llvm-*"
echo
echo "=== verbose probe build ==="
cd /synthaea/agent && cargo build --release -p sensor-linux 2>&1 \
  | grep -iE 'bpf-linker|error|warning: sensor-linux|embedded|Compiling sensor|Finished' | head -30
