#!/usr/bin/env python3
"""Build a fresh release replay executable and bind its digest to the source and compiler."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Tools"))
import ci
from Performance.records import sha

PRODUCT = "StreamingReplayProbe"
FLAGS = ["-c", "release", "--product", PRODUCT]
IDENTITY = ("commit", "workingTreeDirty", "architecture", "hostOSBuild", "swift", "xcode", "sdks")


def sources():
    paths = [ROOT / "Package.swift"]
    if (ROOT / "Package.resolved").is_file():
        paths.append(ROOT / "Package.resolved")
    for directory in (ROOT / "Sources", ROOT / "Tools" / PRODUCT):
        paths.extend(p for p in directory.rglob("*") if p.is_file())
    digest = hashlib.sha256()
    for p in sorted(paths):
        digest.update(p.relative_to(ROOT).as_posix().encode() + b"\0" + bytes.fromhex(sha(p)))
    return digest.hexdigest()


def validate_build(build, environment, binary_digest):
    if (build.get("schemaVersion") != 1 or build.get("product") != PRODUCT
            or build.get("swiftBuildArguments") != FLAGS or build.get("binarySHA256") != binary_digest
            or not re.fullmatch("[0-9a-f]{64}", binary_digest)
            or not re.fullmatch("[0-9a-f]{64}", build.get("sourceSHA256", ""))
            or any(build.get("environment", {}).get(key) != environment[key] for key in IDENTITY)):
        raise ValueError("Release build provenance differs from the measured binary or environment")


def verified_binary(receipt, environment):
    build = json.loads(receipt.read_bytes())
    binary = (receipt.parent / "swiftpm" / "release" / PRODUCT).resolve(strict=True)
    validate_build(build, environment, sha(binary))
    if build["sourceSHA256"] != sources():
        raise ValueError("Current package sources differ from the measured release build")
    return binary, build


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path, help="New, ignored or external directory, shared by replay groups")
    args = parser.parse_args()
    output = args.directory.resolve()
    output.mkdir(parents=True, exist_ok=False)
    before = ci.environment("release")
    source = sources()
    scratch = output / "swiftpm"
    subprocess.run(["swift", "build", "--package-path", ROOT, "--scratch-path", scratch, *FLAGS], check=True)
    after = ci.environment("release")
    if source != sources() or any(before[k] != after[k] for k in IDENTITY):
        raise ValueError("Source or toolchain changed during the build")
    binary = scratch / "release" / PRODUCT
    build = dict(schemaVersion=1, product=PRODUCT, swiftBuildArguments=FLAGS, sourceSHA256=source,
                 binarySHA256=sha(binary), environment={key: after[key] for key in IDENTITY})
    with (output / "build.json").open("x") as stream:
        json.dump(build, stream, sort_keys=True, indent=2)
        stream.write("\n")


if __name__ == "__main__":
    main()
