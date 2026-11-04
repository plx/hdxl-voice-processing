#!/usr/bin/env python3
"""Run isolated, locked host benchmarks and validate their exported evidence."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

import ci

ROOT = Path(__file__).resolve().parent.parent
PACKAGE = ROOT / "Benchmarks"
SMOKE = "Smoke.GainEnergy"
PROBE = "Capability.AllocationARC"
DIAGNOSTICS = (
    "Malloc (total)", "Malloc (bytes total)", "Free (total)",
    "Object allocs", "Retains", "Releases",
)


def validate_results(rows, mode):
    if not isinstance(rows, list) or not rows:
        raise ValueError("Benchmark export is missing or empty")
    values = {}
    for row in rows:
        name, value = row["name"], row["value"]
        if name in values or isinstance(value, bool) or not isinstance(value, (int, float)):
            raise ValueError(f"Duplicate/invalid metric: {name}")
        if not math.isfinite(value) or value < 0 or not isinstance(row.get("unit"), str) or not row["unit"]:
            raise ValueError(f"Nonfinite/negative/untyped metric: {name}")
        values[name] = value
    metrics = ("Time (wall clock)", "Time (total CPU)") if mode == "timing" else (
        "Time (wall clock)", *DIAGNOSTICS)
    benchmarks = (SMOKE,) if mode == "timing" else (SMOKE, PROBE)
    expected = {f"{benchmark} - {metric}" for benchmark in benchmarks for metric in metrics}
    if set(values) != expected:
        raise ValueError(f"Metric coverage mismatch: missing={expected - values.keys()}, extra={values.keys() - expected}")
    if values[f"{SMOKE} - Time (wall clock)"] <= 0:
        raise ValueError("Smoke work has no positive measured duration")
    if mode == "allocation":
        for metric in DIAGNOSTICS:
            if values[f"{PROBE} - {metric}"] <= 0:
                raise ValueError(f"Diagnostic capability probe did not observe {metric}; unavailable is not zero")
    return {
        "allocator": "disabled" if mode == "timing" else "malloc-interposer (revision in resolution.json)",
        "arc": "not requested" if mode == "timing" else "Swift 6.4 native runtime hooks",
        "observedDiagnosticMetrics": [] if mode == "timing" else list(DIAGNOSTICS),
        "unavailableMetrics": {
            "allocatedResidentMemory": "not provided by this backend",
            "memoryLeaked": "legacy jemalloc resident-growth metric; not provided by this backend",
        },
        "metricCount": len(rows),
    }


def swift_arguments(mode):
    args = ["--package-path", str(PACKAGE), "--scratch-path", str(ROOT / ".build" / mode),
            "--force-resolved-versions", "-c", "release"]
    if mode == "allocation":
        args += ["--traits", "AllocationDiagnostics"]
    return args


def inspect_binary(path, mode):
    links = ci.capture("otool", "-L", str(path))
    symbols = ci.capture("nm", "-g", str(path))
    has_interposer = "MallocInterposer" in links
    if has_interposer != (mode == "allocation"):
        raise ValueError("Benchmark binary allocator linkage disagrees with requested mode")
    if "jemalloc" in links.lower() or "jemalloc" in symbols.lower():
        raise ValueError("Unexpected legacy jemalloc backend in Swift 6.4 build")
    if mode == "timing" and ("interposer" in symbols.lower() or "replacement_malloc" in symbols):
        raise ValueError("Timing binary unexpectedly contains allocator interposition symbols")
    return {"linkedLibraries": ci.redact(links), "allocatorLinkVerified": True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("timing", "allocation"))
    parser.add_argument("operation", nargs="?", default="run",
                        choices=("run", "list", "baseline-update", "baseline-read", "baseline-compare"))
    parser.add_argument("--baseline", default="smoke", help="Local baseline name; mode is prefixed automatically")
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9_-]{1,64}", args.baseline):
        parser.error("Baseline name must be 1–64 ASCII letters, digits, underscores or hyphens")
    output = PACKAGE / ".build" / "artifacts" / args.mode / args.operation
    if output.exists():
        shutil.rmtree(output)
    output.mkdir(parents=True)
    result = {"schemaVersion": 1, "mode": args.mode, "operation": args.operation,
              "status": "failed", "commands": []}
    lock = PACKAGE / "Package.resolved"
    lock_before = lock.read_bytes()
    try:
        overrides = ("MALLOC_INTERPOSER_LOCAL_PATH", "RUNTIME_INTERPOSER_LOCAL_PATH",
                     "BENCHMARK_DISABLE_MALLOC_INTERPOSER", "BENCHMARK_DISABLE_JEMALLOC",
                     "DYLD_INSERT_LIBRARIES", "LD_PRELOAD")
        if any(name in os.environ for name in overrides):
            raise ValueError("Remove allocator/backend environment overrides; modes are selected by explicit traits")
        environment = ci.environment("release")
        ci.validate_environment(environment, json.loads((ROOT / "Configuration/build.json").read_text()))
        environment.update({"purpose": "host benchmark smoke/capability check, not a performance baseline",
                            "mode": args.mode, "operation": args.operation,
                            "packageResolvedSHA256": hashlib.sha256(lock_before).hexdigest(),
                            "exportStatistic": "p99; unscaled outer-iteration values",
                            "framesPerSmokeIteration": 1000, "samplesPerFrame": 1024,
                            "frameworkScalingFactor": 1,
                            "operationsPerCapabilityIteration": 1,
                            "environmentScope": "reader only" if args.operation == "baseline-read" else "current execution"})
        (output / "environment.json").write_text(ci.redact(json.dumps(environment, indent=2)) + "\n")
        (output / "resolution.json").write_bytes(lock_before)
        common = swift_arguments(args.mode)
        plugin = ["swift", "package", *common, "--allow-writing-to-package-directory", "benchmark"]
        with (output / "commands.log").open("w") as log:
            def run(command):
                ci.run_command(command, log, result["commands"])

            run([sys.executable, "Tools/verify-provenance.py"])
            if args.operation in ("run", "list", "baseline-update", "baseline-compare"):
                run(["swift", "build", *common, "--product", "WorkloadCheck"])
                binary_dir = Path(ci.capture("swift", "build", *common, "--show-bin-path"))
                workload = json.loads(ci.capture(str(binary_dir / "WorkloadCheck")))
                if workload["mode"] != args.mode or not workload["outputChanged"]:
                    raise ValueError("Optimized workload probe or trait selection failed")
                (output / "workload.json").write_text(json.dumps(workload, indent=2) + "\n")
                run([*plugin, "list"])
                checkout = ROOT / ".build" / args.mode / "checkouts" / "benchmark"
                selected = json.loads(ci.capture("swift", "package", "--package-path", str(checkout), "dump-package"))
                declared = json.loads((ROOT / "Configuration/benchmark.json").read_text())["framework"]
                manifest_hash = hashlib.sha256((checkout / declared["selectedManifest"]).read_bytes()).hexdigest()
                if selected["toolsVersion"]["_version"] != declared["manifestToolsVersion"] or manifest_hash != declared["manifestSHA256"]:
                    raise ValueError("Selected benchmark manifest differs from the reviewed declaration")
                result["frameworkManifest"] = declared
                listing = (output / "commands.log").read_text()
                if SMOKE not in listing or ((PROBE in listing) != (args.mode == "allocation")):
                    raise ValueError("Plugin discovery does not match the requested mode")
                result["binary"] = inspect_binary(binary_dir / "VoiceDSPBenchmarks", args.mode)
            baseline = f"{args.mode}-{args.baseline}"
            export = ["--format", "jsonSmallerIsBetter", "--path", str(output)]
            pattern = f"^({re.escape(SMOKE)}|{re.escape(PROBE)})$"
            if args.operation == "run":
                run([*plugin, "run", "--filter", pattern, *export])
            elif args.operation == "baseline-update":
                run([*plugin, "baseline", "update", baseline])
                run([*plugin, "baseline", "read", baseline, *export])
            elif args.operation == "baseline-read":
                run([*plugin, "baseline", "read", baseline, *export])
            elif args.operation == "baseline-compare":
                # This compares an existing baseline with a new measured run. It reports
                # differences but intentionally does not enforce performance thresholds.
                run([*plugin, "run", "--filter", pattern, *export])
                run([*plugin, "baseline", "compare", baseline])
            if args.operation in ("run", "baseline-update", "baseline-read", "baseline-compare"):
                exports = [p for p in output.glob("*.json") if p.name not in {
                    "environment.json", "resolution.json", "workload.json", "result.json"}]
                if len(exports) != 1:
                    raise ValueError(f"Expected one fresh benchmark export; found {len(exports)}")
                result["capabilities"] = validate_results(json.loads(exports[0].read_text()), args.mode)
                result["export"] = exports[0].name
            result["status"] = "passed"
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError) as error:
        result["error"] = ci.redact(str(error))
        print(result["error"], file=sys.stderr)
    finally:
        if lock.read_bytes() != lock_before:
            result["status"] = "failed"
            result["error"] = "Package.resolved changed during a locked benchmark operation"
        (output / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    return 0 if result["status"] == "passed" else 1


if __name__ == "__main__":
    sys.exit(main())
