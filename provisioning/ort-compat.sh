#!/bin/sh
# Can this guest link the agent's default ONNX Runtime, and if not, make it able to.
#
# The agent's default `dynamic-onnx` feature links pyke's prebuilt static ONNX Runtime
# (ort-sys `download-binaries`). That archive is built on a recent distro: it needs glibc
# >= 2.38 (__isoc23_strtol & co) and the libstdc++ of GCC >= 13 (GLIBCXX_3.4.31). Older
# rows fail at the final link of `agent`, 20 minutes into a build, with undefined
# `__isoc23_*` / `GLIBCXX_3.4.31` symbols:
#
#   ubuntu-24.04, debian-13, fedora-41, arch   new enough, nothing to do
#   debian-12     (glibc 2.36, GCC 12)          --apply: glibc + libstdc++ from trixie (validated)
#   ubuntu-22.04  (glibc 2.35, GCC 12)          --apply: glibc + libstdc++ from noble (not yet validated)
#   rocky-9       (glibc 2.34), alpine (musl)   no package route: build with `--ort static`
#
# --apply is a deliberate partial upgrade: the C/C++ runtime then comes from the next
# release while the kernel, which is what the row is about, stays. Fine for a disposable lab
# VM, not something to do to a host that matters. The alternative that keeps the distro
# intact is a source-built static ONNX Runtime (`agent-build.sh --ort static`), which takes
# far longer and needs ~1 GB of downloads.
#
# Usage:  ort-compat.sh --check     exit 0 if the prebuilt runtime links here, 1 if not
#         ort-compat.sh --apply     apply the distro's workaround (uses sudo when not root)
#
# Vagrant runs `--apply` as the `ort-compat` provisioner when RIG_ORT_COMPAT=1; the
# rig runs it with `python rig.py build <machine> --ort-compat`.
set -eu

NEED_GLIBC=2.38
NEED_GLIBCXX=GLIBCXX_3.4.31

glibc_version() { getconf GNU_LIBC_VERSION 2>/dev/null | awk '{print $2}'; }

libstdcxx_path() {
  for p in /usr/lib/x86_64-linux-gnu/libstdc++.so.6 /usr/lib/aarch64-linux-gnu/libstdc++.so.6 \
           /usr/lib64/libstdc++.so.6 /usr/lib/libstdc++.so.6; do
    [ -e "$p" ] && { echo "$p"; return; }
  done
}

version_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]; }

check() {
  g=$(glibc_version)
  if [ -z "$g" ]; then
    echo "ort-compat: not glibc (musl?) - pyke publishes no prebuilt ONNX Runtime for it; build with --ort static"
    return 1
  fi
  lib=$(libstdcxx_path)
  has_cxx=no
  [ -n "$lib" ] && grep -aq "$NEED_GLIBCXX" "$lib" && has_cxx=yes
  if version_ge "$g" "$NEED_GLIBC" && [ "$has_cxx" = yes ]; then
    echo "ort-compat: ok (glibc $g, $NEED_GLIBCXX present)"
    return 0
  fi
  echo "ort-compat: the prebuilt ONNX Runtime cannot link here (glibc $g, need >= $NEED_GLIBC; $NEED_GLIBCXX: $has_cxx)"
  return 1
}

SUDO=""
[ "$(id -u)" -eq 0 ] || SUDO="sudo"

apt_from_next_release() {   # $1 = suite, $2 = mirror line
  suite=$1 line=$2
  if ! grep -rqs "[[:space:]]$suite[[:space:]]" /etc/apt/sources.list /etc/apt/sources.list.d/; then
    echo "$line" | $SUDO tee "/etc/apt/sources.list.d/synthaea-$suite.list" >/dev/null
  fi
  # Priority 100: nothing else is ever pulled from the next release unless asked with -t.
  printf 'Package: *\nPin: release n=%s\nPin-Priority: 100\n' "$suite" \
    | $SUDO tee "/etc/apt/preferences.d/synthaea-$suite" >/dev/null
  $SUDO env DEBIAN_FRONTEND=noninteractive apt-get update -qq
  $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq -t "$suite" libstdc++6
}

apply() {
  if check; then return 0; fi
  . /etc/os-release
  case "${ID:-}:${VERSION_CODENAME:-}" in
    debian:bookworm)
      echo "ort-compat: installing libstdc++6 (and the libc6 it needs) from trixie, pinned at priority 100"
      apt_from_next_release trixie "deb http://deb.debian.org/debian trixie main"
      ;;
    ubuntu:jammy)
      echo "ort-compat: installing libstdc++6 (and the libc6 it needs) from noble, pinned at priority 100 (not yet validated)"
      case "$(uname -m)" in
        x86_64) mirror=http://archive.ubuntu.com/ubuntu ;;
        *)      mirror=http://ports.ubuntu.com/ubuntu-ports ;;
      esac
      apt_from_next_release noble "deb $mirror noble main"
      ;;
    *)
      echo "ort-compat: no package workaround for ${PRETTY_NAME:-this distro}; build with --ort static" >&2
      return 1
      ;;
  esac
  check
}

case "${1:---check}" in
  --check) check ;;
  --apply) apply ;;
  *) echo "usage: $0 --check | --apply" >&2; exit 2 ;;
esac
