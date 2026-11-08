#!/usr/bin/env python3
"""Synthetic visualization construction/publication evidence before plotting."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import statistics
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Tools"))
import ci

TRIALS = 5
WORKLOADS = {(phase, count) for phase in ("metricConstruction", "mainActorPublicationWithObserver")
             for count in (128, 4096)} | {
                 (phase, count) for phase in ("ownedWaveformConstruction", "validatedFrameAdaptation")
                 for count in (4096, 262_144)}
TIMINGS = ("minimumNanoseconds", "medianNanoseconds", "p95Nanoseconds", "maximumNanoseconds")
SAMPLE_FIELDS = {"phase", "count", "iterations", "warmups", "consumedCount", "observerInvalidations", *TIMINGS}
REPORT_FIELDS = {"schemaVersion", "syntheticOnly", "dspCaptureOrRenderingExecuted", "status", "profileSHA256", "samples"}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False).encode()


def validate_report(report):
    require(set(report) == REPORT_FIELDS, "Unexpected or missing report field")
    require(type(report["schemaVersion"]) is int and report["schemaVersion"] == 1
            and report["syntheticOnly"] is True and report["dspCaptureOrRenderingExecuted"] is False
            and report["status"] == "passed", "Wrong evidence scope")
    digest = report["profileSHA256"]
    require(isinstance(digest, str) and len(digest) == 64
            and all(c in "0123456789abcdef" for c in digest), "Invalid profile digest")
    samples = report["samples"]
    require(isinstance(samples, list) and len(samples) == len(WORKLOADS), "Missing/duplicate workload")
    keys = []
    for sample in samples:
        require(set(sample) == SAMPLE_FIELDS, "Unexpected or missing workload field")
        require(isinstance(sample["phase"], str), "Invalid phase")
        for field in SAMPLE_FIELDS - {"phase"}:
            require(type(sample[field]) is int, "Non-integer evidence")
        key = sample["phase"], sample["count"]
        require(key in WORKLOADS, "Unexpected workload")
        keys.append(key)
        observed = sample["phase"] == "mainActorPublicationWithObserver"
        iterations = 1000 if observed else 100
        require(sample["iterations"] == iterations and sample["warmups"] == 3
                and sample["consumedCount"] == sample["count"] * iterations
                and sample["observerInvalidations"] == (iterations if observed else 0),
                "Wrong workload consumption or Observation evidence")
        timings = [sample[field] for field in TIMINGS]
        require(0 < timings[0] and timings == sorted(timings), "Invalid timing distribution")
    require(set(keys) == WORKLOADS, "Missing/duplicate workload")


def validate_population(records):
    require(len(records) == TRIALS and {r["trial"] for r in records} == set(range(TRIALS)),
            "Missing/duplicate fresh process")
    for record in records:
        validate_report(record["report"])
    require(len({r["report"]["profileSHA256"] for r in records}) == 1, "Profile drift")
    distributions = []
    for phase, count in sorted(WORKLOADS):
        group = [s for r in records for s in r["report"]["samples"]
                 if (s["phase"], s["count"]) == (phase, count)]
        medians = [s["medianNanoseconds"] for s in group]
        distributions.append({"phase": phase, "count": count, "processes": len(group),
                              "medianOfProcessMediansNanoseconds": statistics.median(medians),
                              "minimumProcessMedianNanoseconds": min(medians),
                              "maximumProcessMedianNanoseconds": max(medians)})
    return distributions


def negative_controls(records):
    controls = []
    for name, change in [
        ("missing-process", lambda x: x.pop()),
        ("duplicate-process", lambda x: x.__setitem__(1, copy.deepcopy(x[0]))),
        ("missing-workload", lambda x: x[0]["report"]["samples"].pop()),
        ("duplicate-workload", lambda x: x[0]["report"]["samples"].__setitem__(1,
                                           copy.deepcopy(x[0]["report"]["samples"][0]))),
        ("zero-timing", lambda x: x[0]["report"]["samples"][0].update(minimumNanoseconds=0)),
        ("unordered-timing", lambda x: x[0]["report"]["samples"][0].update(maximumNanoseconds=0)),
        ("unused-result", lambda x: x[0]["report"]["samples"][0].update(consumedCount=0)),
        ("missing-observation", lambda x: [s.update(observerInvalidations=0)
            for s in x[0]["report"]["samples"] if s["phase"] == "mainActorPublicationWithObserver"]),
        ("profile-drift", lambda x: x[0]["report"].update(profileSHA256="0" * 64)),
        ("private-field", lambda x: x[0]["report"].update(privateNote="must-not-be-published")),
        ("wrong-scope", lambda x: x[0]["report"].update(dspCaptureOrRenderingExecuted=True)),
    ]:
        mutated = copy.deepcopy(records)
        change(mutated)
        try:
            validate_population(mutated)
        except ValueError:
            controls.append(name)
        else:
            raise ValueError("Negative evidence control accepted: " + name)
    return controls


def run(output):
    output.mkdir(parents=True, exist_ok=False)
    environment = ci.environment("release")
    ci.validate_environment(environment, json.loads((ROOT / "Configuration/build.json").read_bytes()))
    environment.update(hardwareModel=ci.capture("sysctl", "-n", "hw.model"),
        scope="Synthetic adapter construction and main-actor publication; no DSP, capture, rendering or physical evidence.",
        preparation="Input records/arrays and profile preparation excluded; warmups discarded; no allocation instrumentation.",
        timing="DispatchTime uptime nanoseconds; nearest-rank p95 and upper median of 100 or 1000 operations per process.")
    (output / "environment.json").write_bytes(canonical(environment))
    package = ROOT / "Examples/VisualizationConsumer"
    sources = sorted((ROOT / "Sources").rglob("*.swift"))
    sources += sorted(p for p in package.rglob("*.swift") if ".build" not in p.parts)
    sources += [ROOT / p for p in ("Package.swift", "Configuration/build.json", "Tools/ci.py",
                "Tools/Visualization/benchmark.py", "Tools/Tests/test_visualization_benchmark.py",
                ".github/workflows/visualization-evidence.yml")]
    def hashes():
        return {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
    before = hashes()
    commands = []
    with (output / "commands.log").open("w") as log:
        ci.run_command(["swift", "build", "--package-path", str(package), "-c", "release"], log, commands)
    binary = Path(ci.capture("swift", "build", "--package-path", str(package), "-c", "release", "--show-bin-path")) / "VisualizationConsumer"
    records = []
    for trial in range(TRIALS):
        report_path = output / f"process-{trial}.json"
        command = [str(binary), "--output", str(report_path)]
        process = subprocess.run(command, cwd=ROOT, text=True, stdout=subprocess.PIPE,
                                 stderr=subprocess.STDOUT, timeout=120, check=False)
        with (output / "commands.log").open("a") as log:
            log.write(ci.redact(process.stdout))
        commands.append({"command": [ci.redact(v) for v in command], "exitCode": process.returncode})
        require(process.returncode == 0, "Native visualization probe failed")
        report = json.loads(report_path.read_bytes())
        validate_report(report)
        records.append({"trial": trial, "report": report})
        print(f"Verified eight workloads in fresh process {trial + 1}/{TRIALS}", flush=True)
    distributions = validate_population(records)
    controls = negative_controls(records)
    require(hashes() == before, "Sources changed during the evidence run")
    (output / "result.json").write_bytes(canonical({"schemaVersion": 1, "status": "passed",
        "records": records, "distributions": distributions, "commands": commands,
        "negativeValidationControls": controls, "sourceSHA256": before, "physicalEvidence": False}))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    run(parser.parse_args().output.resolve())
