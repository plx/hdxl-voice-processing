#!/usr/bin/env python3
"""Join two measured modes only when their immutable inputs, results and build agree."""

import argparse
import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from Performance.denominators import verify_manifest
from Performance.records import sha


def load(root, name):
    return json.loads((root / name).read_bytes())


def compare(timing, allocation):
    manifests = {}
    for mode, path in (("timing", timing), ("allocation", allocation)):
        status = load(path, "result.json")
        if status["status"] != "passed" or status["mode"] != mode:
            raise ValueError(f"Missing successful {mode} receipt")
        verify_manifest(path, status, mode, {"caseFile": "workloads.json", "environmentFile": "environment.json",
                                             "distributionFile": "distributions.json", "exportFile": "p99.json"})
        env = load(path, "environment.json")
        if env["workingTreeDirty"] is not False:
            raise ValueError("Comparison requires a clean recorded source tree in each mode")
        if (env["measurementMode"] != mode or env["packageResolvedSHA256"] != sha(path / "resolution.json")
                or env["allocatorBackend"] != {"timing": "disabled", "allocation": "malloc-interposer"}[mode]):
            raise ValueError(f"Build settings or dependency resolution differ from the {mode} receipt")
        manifests[mode] = status["workloadManifestSHA256"]
    if ((timing / "resolution.json").read_bytes() != (allocation / "resolution.json").read_bytes()
            or load(timing, "workloads.json") != load(allocation, "workloads.json")):
        raise ValueError("The two modes used different resolution, geometry or public results")
    timing_env, allocation_env = (load(p, "environment.json") for p in (timing, allocation))
    for key in ("commit", "workingTreeDirty", "python", "sdks", "architecture", "hardwareModel", "hostOSBuild",
                "swift", "xcode", "toolchainPolicy"):
        if timing_env[key] != allocation_env[key]:
            raise ValueError(f"Build mismatch for {key}")
    time, memory = (load(p, "distributions.json") for p in (timing, allocation))
    if set(memory) != set(time) | {"Capability.VoiceSuiteAllocationARC"}:
        raise ValueError("Allocation controls or timing cases differ")
    source = load(timing, "workloads.json")
    records = {}
    for row in source:
        key = "VoiceSuite.Run." + row["name"]
        records[row["name"]] = dict(wallNS=time[key]["wallClock"], cpuNS=time[key]["cpuTotal"],
                                    allocations={k: v for k, v in memory[key].items() if k != "wallClock"})
    name = source[0]["fixture"]["name"]
    pairs = (("single.cpps", "single.core"), ("single.core", "single.full"),
             ("single.full", "single.separateSpectra"), ("single.full", "pair.full"))
    differences = []
    for a, b in pairs:
        first, second = (records[key + "." + name] for key in (a, b))
        differences.append(dict(first=a, second=b, differenceOfWallMediansNS=second["wallNS"]["p50"]-first["wallNS"]["p50"],
            differenceOfMallocMedians=second["allocations"]["mallocCountTotal"]["p50"]-first["allocations"]["mallocCountTotal"]["p50"]))
    return dict(commit=timing_env["commit"], workloadManifestSHA256=manifests, fixture=source[0]["fixture"],
                scenarios=records, comparisons=differences)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for arg in ("timing", "allocation", "output"):
        parser.add_argument(arg, type=Path)
    args = parser.parse_args()
    report = compare(args.timing, args.allocation)
    with args.output.open("x") as stream:
        json.dump(report, stream, indent=2, allow_nan=False)
        stream.write("\n")
