#!/usr/bin/env python3
"""Explicitly acquire and verify the pinned development reference in .build only."""
import argparse
import os
from pathlib import Path
import platform
import subprocess
import tempfile
import time
import urllib.request

from common import HERE, ROOT, ReferenceError, digest, load_json, write_json


def verify_tool(path, lock):
    if (platform.system() != "Darwin" or platform.machine() != "arm64"
            or int(platform.mac_ver()[0].split(".")[0]) < 27
            or platform.python_version() != lock["pythonVersion"]):
        raise ReferenceError("Reference environment requires macOS 27 arm64 and pinned Python")
    path = Path(path).resolve()
    if digest(path.read_bytes()) != lock["executableSHA256"]:
        raise ReferenceError("Reference executable differs from the pinned binary")
    version = subprocess.check_output([str(path), "--version"], text=True, timeout=15).strip()
    if version != lock["versionOutput"]:
        raise ReferenceError("Reference executable version mismatch")
    return path


def acquire():
    lock = load_json(HERE / "toolchain.json")
    destination = ROOT / ".build" / "reference-tool" / lock["version"]
    binary = destination / lock["executablePath"]
    started = time.perf_counter()
    if binary.exists():
        return verify_tool(binary, lock), {"reused": True, "seconds": time.perf_counter() - started}
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="praat-acquire-", dir=destination.parent) as temporary:
        staging = Path(temporary)
        archive = staging / "reference.dmg"
        with urllib.request.urlopen(lock["artifactURL"], timeout=60) as response, archive.open("wb") as output:
            remaining = lock["artifactBytes"]
            while remaining:
                chunk = response.read(min(1024 * 1024, remaining))
                if not chunk:
                    raise ReferenceError("Truncated reference download")
                output.write(chunk)
                remaining -= len(chunk)
            if response.read(1):
                raise ReferenceError("Reference download exceeds pinned size")
        if digest(archive.read_bytes()) != lock["artifactSHA256"]:
            raise ReferenceError("Downloaded reference digest differs from the pin")
        mount = staging / "mount"
        mount.mkdir()
        attached = False
        try:
            subprocess.run(["hdiutil", "attach", str(archive), "-readonly", "-nobrowse", "-mountpoint", str(mount)], check=True)
            attached = True
            installed = staging / "installed"
            installed.mkdir()
            subprocess.run(["ditto", str(mount / "Praat.app"), str(installed / "Praat.app")], check=True)
            verify_tool(installed / lock["executablePath"], lock)
        finally:
            if attached:
                subprocess.run(["hdiutil", "detach", str(mount)], check=True)
        if destination.exists():
            raise ReferenceError("Destination already exists; inspect it before retrying")
        os.rename(installed, destination)
    return binary, {"reused": False, "seconds": time.perf_counter() - started}


def main():
    argparse.ArgumentParser(description=__doc__).parse_args()
    binary, timing = acquire()
    report = ROOT / ".build" / "reference-artifacts" / "setup.json"
    report.parent.mkdir(parents=True, exist_ok=True)
    write_json(report, {"schemaVersion": 1, "binary": str(binary.relative_to(ROOT)), "setup": timing,
                        "toolchain": load_json(HERE / "toolchain.json")})
    print(binary.relative_to(ROOT))


if __name__ == "__main__":
    main()
