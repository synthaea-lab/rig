#!/bin/sh
# Box fix-up for jtarpley/fedora41_base (the Hyper-V box of the fedora41 row): a 40 GB disk
# split into small LVM volumes, / with ~6 GB free after the LLVM packages, /home under 1 GB
# (rustup dies with "No space left on device"), /var ~9 GB. Moves the per-user toolchain and
# the cargo target directory to /var/synthaea. Runs as root before the toolchain script.
#
# A no-op on any box where /home has room (every other fedora41 box), so the catalog can
# list it for the machine without caring about the provider. Idempotent.
set -eu

home_free_mb=$(df -Pk /home | awk 'NR == 2 {print int($4 / 1024)}')
if [ "$home_free_mb" -ge 4096 ] && [ ! -L /home/vagrant/.cargo ]; then
  echo "fedora-lvm-prep: /home has ${home_free_mb} MB free, nothing to relocate"
  exit 0
fi

mkdir -p /var/synthaea/cargo /var/synthaea/rustup /var/synthaea/target
chown -R vagrant:vagrant /var/synthaea
for d in cargo rustup; do
  if [ ! -L "/home/vagrant/.$d" ]; then rm -rf "/home/vagrant/.$d"; fi
  ln -sfn "/var/synthaea/$d" "/home/vagrant/.$d"
  chown -h vagrant:vagrant "/home/vagrant/.$d"
done
echo "export CARGO_TARGET_DIR=/var/synthaea/target" > /etc/profile.d/synthaea-target.sh
echo "fedora-lvm-prep: ~/.cargo, ~/.rustup and CARGO_TARGET_DIR now under /var/synthaea"
