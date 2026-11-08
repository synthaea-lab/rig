#!/usr/bin/env python3
"""Builds the offline bundle for an in-guest agent build, and pushes it to a lab machine.

    python tools/offline_bundle.py [--push <machine>] [--target <triple>]

Run on the HOST (Linux, macOS or Windows; needs rustup/cargo, which agent work needs
anyway). The guest then builds with `agent-build.sh --offline` without touching crates.io
or pyke's CDN. `python rig.py build <machine> --offline` does both steps.

The bundle (`.offline/`, gitignored) holds:
  vendor/              `cargo vendor --locked --versioned-dirs` of agent/, plus the crates of
                       the probe toolchain's sysroot (the eBPF crate builds core with
                       nightly `-Z build-std`, which resolves the sysroot's own Cargo.lock)
  vendor-config.toml   the source replacement cargo printed, guest path left as @VENDOR@
  ort-cache/dfbin/     pyke's prebuilt ONNX Runtime for the guest's target, copied from the
                       host's ort cache when a previous host build left it there
  KEY                  a hash of agent/Cargo.lock + agent/ebpf-toolchain.txt: the guest
                       refuses a bundle made for other sources

Vendoring is cached per KEY; a push is skipped when the guest already has that KEY.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import re
import shutil
import subprocess
import sys
import tarfile
from pathlib import Path

RIG = Path(__file__).resolve().parents[1]
ROOT = Path(os.environ.get("RIG_ROOT") or os.environ.get("SYNTHAEA_ROOT") or RIG.parent).resolve()
AGENT = ROOT / "agent"
VAGRANT_DIR = RIG / "vagrant"
CACHE = RIG / ".offline"


class BundleError(RuntimeError):
    """The bundle cannot be made; the message says what to do."""


def run(*cmd: str | Path, cwd: Path = ROOT, capture: bool = False) -> str:
    exe = shutil.which(str(cmd[0])) or str(cmd[0])
    print(f"+ {' '.join(map(str, cmd))}", flush=True)
    res = subprocess.run([exe, *map(str, cmd[1:])], cwd=cwd, check=True, text=True,
                         stdout=subprocess.PIPE if capture else None)
    return res.stdout or ""


def bundle_key() -> str:
    lock = (AGENT / "Cargo.lock").read_bytes()
    tc = (AGENT / "ebpf-toolchain.txt").read_bytes()
    return hashlib.sha256(lock + b"\0" + tc).hexdigest()[:16]


def vendor(dest: Path) -> None:
    """Vendors the agent workspace and the probe toolchain's sysroot into dest/vendor."""
    if (dest / "vendor" / ".complete").exists():
        print(f"vendored crates cached in {dest}")
        return
    shutil.rmtree(dest, ignore_errors=True)
    dest.mkdir(parents=True)
    vendor_dir = dest / "vendor"
    config = run("cargo", "vendor", "--locked", "--versioned-dirs", vendor_dir, cwd=AGENT, capture=True)
    # Keep cargo's own printout (it lists git sources too); only the path is guest-specific.
    template = re.sub(r'(?m)^directory = ".*"$', 'directory = "@VENDOR@"', config)
    if "@VENDOR@" not in template:
        raise BundleError(f"unexpected `cargo vendor` output, no directory line:\n{config}")
    (dest / "vendor-config.toml").write_text(template, encoding="utf-8", newline="\n")

    tc = (AGENT / "ebpf-toolchain.txt").read_text(encoding="utf-8").strip()
    run("rustup", "toolchain", "install", tc, "--profile", "minimal", "--component", "rust-src")
    sysroot = Path(run("rustup", "run", tc, "rustc", "--print", "sysroot", capture=True).strip())
    library = sysroot / "lib" / "rustlib" / "src" / "rust" / "library" / "Cargo.toml"
    if not library.exists():
        raise BundleError(f"{library} missing: rustup component add rust-src --toolchain {tc}")
    sysroot_vendor = dest / "vendor-sysroot"
    run("rustup", "run", tc, "cargo", "vendor", "--locked", "--versioned-dirs",
        "--manifest-path", library, sysroot_vendor)
    added = 0
    for crate in sysroot_vendor.iterdir():
        if not (vendor_dir / crate.name).exists():
            shutil.move(str(crate), vendor_dir / crate.name)
            added += 1
    shutil.rmtree(sysroot_vendor)
    print(f"merged {added} sysroot crates into {vendor_dir}")
    (vendor_dir / ".complete").write_text("", encoding="utf-8")


def ort_cache_roots() -> list[Path]:
    """Where ort-sys keeps downloaded runtimes on this host (ort-sys src/internal/dirs.rs)."""
    home = Path.home()
    roots = [os.environ.get("ORT_CACHE_DIR"), os.environ.get("XDG_CACHE_HOME"),
             home / ".cache" / "ort.pyke.io", home / "Library" / "Caches" / "ort.pyke.io"]
    if os.environ.get("LOCALAPPDATA"):
        roots.append(Path(os.environ["LOCALAPPDATA"]) / "ort.pyke.io")
    return [Path(r) for r in roots if r]


def ort_runtime(vendor_dir: Path, target: str) -> tuple[str, Path | None]:
    """Returns (hash, host cache dir or None) of the prebuilt runtime for target."""
    dists = sorted(vendor_dir.glob("ort-sys-*/build/download/dist.tsv"))
    if not dists:
        raise BundleError("no ort-sys in the vendored crates: did agent/ stop using ort?")
    for line in dists[-1].read_text(encoding="utf-8").splitlines()[1:]:
        cols = line.split("\t")
        if len(cols) == 4 and cols[0] == target and cols[1] == "none":
            digest = cols[3]
            for root in ort_cache_roots():
                d = root / "dfbin" / target / digest
                if d.is_dir():
                    return digest, d
            return digest, None
    raise BundleError(f"ort-sys publishes no prebuilt runtime for {target}: build with --ort static")


def make_bundle(target: str) -> Path:
    if not (AGENT / "Cargo.lock").exists():
        raise BundleError(f"{AGENT} is not checked out (just init agent)")
    key = bundle_key()
    dest = CACHE / key
    vendor(dest)
    (dest / "KEY").write_text(key, encoding="utf-8", newline="\n")
    tarball = CACHE / f"synthaea-offline-{key}-{target}.tar.gz"
    digest, ort_dir = ort_runtime(dest / "vendor", target)
    if tarball.exists():
        print(f"bundle cached: {tarball}")
        return tarball
    if ort_dir is None:
        print(f"warning: no prebuilt ONNX Runtime for {target} ({digest[:12]}) in this host's ort cache; "
              "the guest must already have it (an earlier online build) or download it (~25 MB).",
              file=sys.stderr)
    print(f"packing {tarball.name} ...", flush=True)
    tmp = tarball.with_suffix(".partial")
    with tarfile.open(tmp, "w:gz", compresslevel=1) as tar:
        for name in ("KEY", "vendor-config.toml", "vendor"):
            tar.add(dest / name, arcname=name)
        if ort_dir is not None:
            tar.add(ort_dir, arcname=f"ort-cache/dfbin/{target}/{digest}")
    tmp.replace(tarball)
    print(f"bundle: {tarball} ({tarball.stat().st_size // 2**20} MB)")
    return tarball


def vagrant_out(machine: str, command: str) -> str:
    res = subprocess.run([shutil.which("vagrant") or "vagrant", "ssh", machine, "-c", command],
                         cwd=VAGRANT_DIR, text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    if res.returncode != 0:
        raise BundleError(f"cannot reach {machine} over vagrant ssh (is it up? python rig.py up {machine})")
    return res.stdout.strip()


def push(machine: str, target: str | None) -> None:
    probe = vagrant_out(machine, "uname -m; cat ~/synthaea-offline/KEY 2>/dev/null || true").split()
    arch = probe[0] if probe else "x86_64"
    target = target or f"{arch}-unknown-linux-gnu"
    tarball = make_bundle(target)
    key = bundle_key()
    if len(probe) > 1 and probe[1] == key:
        print(f"{machine} already has offline bundle {key}")
        return
    run("vagrant", "upload", tarball, f"/tmp/{tarball.name}", machine, cwd=VAGRANT_DIR)
    print(f"pushed to {machine}:/tmp/{tarball.name} (agent-build.sh --offline unpacks it)")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--push", metavar="MACHINE", help="upload the bundle to this lab machine")
    parser.add_argument("--target", help="guest target triple (default: asked from the guest, else x86_64-unknown-linux-gnu)")
    args = parser.parse_args()
    try:
        if args.push:
            push(args.push, args.target)
        else:
            make_bundle(args.target or "x86_64-unknown-linux-gnu")
    except BundleError as err:
        print(f"error: {err}", file=sys.stderr)
        return 2
    except subprocess.CalledProcessError as err:
        return err.returncode or 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
