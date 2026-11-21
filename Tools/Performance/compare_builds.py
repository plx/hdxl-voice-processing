"""Measure fresh process replay through the public API under four compiler configurations."""
import argparse
import json
from pathlib import Path
import statistics
import subprocess
import tempfile
import time

from prepare import ROOT, json_bytes, prepare

VARIANTS = {
    "unoptimized": ["SWIFT_OPTIMIZATION_LEVEL=-Onone", "SWIFT_COMPILATION_MODE=singlefile"],
    "optimized": ["SWIFT_OPTIMIZATION_LEVEL=-O", "SWIFT_COMPILATION_MODE=singlefile"],
    "wholeModule": ["SWIFT_OPTIMIZATION_LEVEL=-O", "SWIFT_COMPILATION_MODE=wholemodule"],
    "resilient": ["SWIFT_OPTIMIZATION_LEVEL=-O", "SWIFT_COMPILATION_MODE=wholemodule", "BUILD_LIBRARY_FOR_DISTRIBUTION=YES"],
}


def compare(directory):
    commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    dirty = bool(subprocess.check_output(["git", "status", "--porcelain"], cwd=ROOT))
    directory.mkdir(parents=True, exist_ok=False)
    bins = {}
    for name, flags in VARIANTS.items():
        scratch = ROOT / ".build" / ("b02-xcode-" + name)
        args = ["xcodebuild", "-scheme", "ReplayWorkloads", "-configuration", "Release",
                "-destination", "platform=macOS,arch=arm64", "-derivedDataPath", str(scratch),
                "CODE_SIGNING_ALLOWED=NO", *flags, "build"]
        with (directory / (name + ".log")).open("w") as log:
            subprocess.run(args, cwd=ROOT / "Tools/Performance/Portable", stdout=log, stderr=subprocess.STDOUT, check=True)
        bins[name] = scratch / "Build/Products/Release/ReplayWorkloads"
    measurements = {name: [] for name in bins}
    names = list(bins)
    with tempfile.TemporaryDirectory() as temp:
        bundle = Path(temp) / "bundle"
        manifest_hash = prepare(bundle)
        reference = None
        for trial in range(9):
            for name in names[trial % len(names):] + names[:trial % len(names)]:
                start = time.perf_counter_ns()
                result = subprocess.check_output([bins[name], bundle, "17"])
                elapsed = time.perf_counter_ns() - start
                report = json.loads(result)
                if reference is None:
                    reference = report
                if report != reference or report["manifestSHA256"] != manifest_hash:
                    raise ValueError("Compiler comparison changed workload identity or valid-work counts")
                if trial:
                    measurements[name].append(elapsed)
    return dict(schemaVersion=1, manifestSHA256=manifest_hash, commit=commit, workingTreeDirty=dirty,
                boundary="fresh child process launch to exit including bundle reads, checks, all analyses and report export",
                consumer="separate executable and WorkloadReplay module importing the public HDXLVoiceProcessing product",
                cachePolicy="one warmup per binary; fresh process per trial; filesystem cache uncontrolled",
                inputs=len(reference["workloads"]), chunkSamples=17, clock="parent monotonic perf_counter_ns",
                xcode=subprocess.check_output(["xcodebuild", "-version"], text=True).strip(),
                swift=subprocess.check_output(["swift", "--version"], text=True).strip(),
                hardwareModel=subprocess.check_output(["sysctl", "-n", "hw.model"], text=True).strip(),
                variants={name: dict(xcodeSettings=VARIANTS[name], samplesNanoseconds=values,
                                     medianNanoseconds=statistics.median(values))
                          for name, values in measurements.items()})


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    result = compare(args.output)
    (args.output / "comparison.json").write_bytes(json_bytes(result))
