#!/bin/sh
# Makes any Linux guest able to build the toolchain and the agent without OOM kills,
# whatever the box ships with. Runs as root before the toolchain script (Vagrant
# provisioner `build-host-setup`), POSIX sh so it also runs on BusyBox (Alpine).
# Idempotent: re-run with `vagrant provision <machine> --provision-with build-host-setup`.
#
# - a 4 GB swapfile, unless the guest already has 4 GB of swap, skipped with a notice when
#   / has under 8 GB free (a release build with LTO peaks well above the RAM of a laptop VM);
# - vm.swappiness 60, written to /proc directly (some boxes have no `sysctl` binary, and
#   jtarpley/ubuntu2404_base pins 0, which disables swap for anonymous memory in practice);
# - CARGO_BUILD_JOBS sized to the RAM the guest sees (about 1 GB per rustc), so a 2 GB
#   Hyper-V guest builds with -j2 instead of being OOM-killed at -j4.
set -eu

SWAP=/swapfile-synthaea
swap_kb=$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo)
free_gb=$(df -Pk / | awk 'NR == 2 {print int($4 / 1048576)}')

if [ ! -f "$SWAP" ] && [ "$swap_kb" -lt 4000000 ]; then
  if [ "$free_gb" -ge 8 ]; then
    # Built under a temporary name and renamed once mkswap succeeded, so an interrupted
    # run never leaves a headerless swapfile behind. No `mkswap -q` (util-linux 2.37 lacks it).
    rm -f "$SWAP.tmp"
    fallocate -l 4G "$SWAP.tmp" 2>/dev/null || dd if=/dev/zero of="$SWAP.tmp" bs=1M count=4096 2>/dev/null
    chmod 600 "$SWAP.tmp"
    mkswap "$SWAP.tmp" >/dev/null
    mv "$SWAP.tmp" "$SWAP"
  else
    echo "build-host-setup: only ${free_gb} GB free on /, no swapfile (free space, then re-run this provisioner)"
  fi
fi
if [ -f "$SWAP" ]; then
  grep -q "^$SWAP " /etc/fstab || echo "$SWAP none swap sw 0 0" >> /etc/fstab
  grep -q "^$SWAP " /proc/swaps || swapon "$SWAP"
  # OpenRC (Alpine) only activates fstab swap with the `swap` service enabled.
  if command -v rc-update >/dev/null 2>&1; then rc-update add swap boot >/dev/null 2>&1 || true; fi
fi

[ -f /etc/sysctl.conf ] && sed -i '/^vm.swappiness/d' /etc/sysctl.conf
mkdir -p /etc/sysctl.d
echo "vm.swappiness = 60" > /etc/sysctl.d/90-synthaea.conf
echo 60 > /proc/sys/vm/swappiness

mem_mb=$(awk '/^MemTotal:/ {print int($2 / 1024)}' /proc/meminfo)
jobs=$(( (mem_mb + 512) / 1024 ))
[ -f "$SWAP" ] && [ "$jobs" -lt 2 ] && jobs=2
[ "$jobs" -lt 1 ] && jobs=1
cpus=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo)
[ "$jobs" -gt "$cpus" ] && jobs=$cpus
echo "export CARGO_BUILD_JOBS=$jobs" > /etc/profile.d/synthaea-build-jobs.sh
# The pre-2026-11 harness wrote the job cap here; drop it so two files never disagree.
rm -f /etc/profile.d/synthaea-cargo.sh
echo "build-host-setup: RAM ${mem_mb} MB, swap $(awk '/^SwapTotal:/ {print int($2 / 1024)}' /proc/meminfo) MB, CARGO_BUILD_JOBS=$jobs"
