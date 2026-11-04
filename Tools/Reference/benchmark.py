#!/usr/bin/env python3
"""Regenerate twice or more, compare, and measure reference and native validation boundaries."""
import argparse
import json
import math
import os
from pathlib import Path
import statistics
import subprocess
import sys
import time

from common import HERE, ROOT, ReferenceError, load_json, write_json
from fixtures import generate as generate_inputs
from run import generate
from setup import acquire
from verify import CATALOG, GOLDENS, compare, validate, verify_catalog

WORKLOADS = (
    ("smoke", "saw-120ms.wav", "cpps", False),
    ("intermediates", "saw-120ms.wav", "cpps", True),
    ("catalog-cpps", "saw-500ms.wav", "cpps", False),
    ("catalog-hnr-ac", "saw-500ms.wav", "hnr-ac", False),
    ("catalog-hnr-cc", "saw-500ms.wav", "hnr-cc", False),
    ("catalog-perturbation", "saw-500ms.wav", "perturbation", False),
    ("catalog-formants", "saw-500ms.wav", "formants", False),
    ("catalog-silence", "silence-500ms.wav", "hnr-cc", False),
)


def distribution(values):
    if not values or any(not math.isfinite(v) or v <= 0 for v in values):
        raise ReferenceError("Expected positive finite timing trials")
    ordered = sorted(values)
    return {"trials": values, "unit": "seconds", "median": statistics.median(values),
            "p95NearestRank": ordered[math.ceil(len(ordered) * 0.95) - 1], "minimum": ordered[0], "maximum": ordered[-1]}


def measure(output, trials):
    if not 2 <= trials <= 20:
        raise ReferenceError("Trials must be between 2 and 20")
    output = output.resolve()
    if output.exists() or not output.is_relative_to((ROOT / ".build").resolve()):
        raise ReferenceError("Use a fresh evidence directory under repository .build")
    output.mkdir(parents=True)
    verify_catalog()
    binary, acquisition = acquire()
    write_json(output / "acquisition.json", acquisition)
    generate_inputs(output / "inputs")
    reports = []
    for name, pcm, analysis, export in WORKLOADS:
        first = None
        records = []
        for trial in range(trials):
            destination = output / "workloads" / name / str(trial)
            candidate = generate(output / "inputs" / pcm, HERE / "Profiles/cpps-murton-praat7.json", binary, destination, export, analysis)
            validate(destination, output / "inputs" / pcm, analysis, export)
            if first is not None and compare(first, candidate) != "match":
                raise ReferenceError(f"Reference repeated-run disagreement: {name}")
            first = candidate
            for golden_name, golden_pcm, golden_analysis, golden_export in CATALOG:
                if (pcm, analysis, export) == (golden_pcm, golden_analysis, golden_export):
                    if compare(load_json(GOLDENS / golden_name / "reference.json"), candidate) != "match":
                        raise ReferenceError(f"Committed golden disagrees: {name}")
            records.append(load_json(destination / "execution.json"))
        timing = {key: distribution([r[key] for r in records]) for key in
                  ("setupSeconds", "referenceProcessAndAlgorithmSeconds", "parseValidationSeconds")}
        reports.append({"name": name, "analysis": analysis, "sampleRate": 16000,
                        "frameHop": {"analysisRate": 10000, "frameSamples": 1000, "hopSamples": 20} if analysis == "cpps"
                            else {"hopSeconds": 0.01, "support": "recipe and raw frame/pulse times in manifest"},
                        "metadata": {k: v for k, v in records[0].items() if not k.endswith("Seconds")},
                        "inputDurationSeconds": records[0]["inputDurationSeconds"], "timings": timing,
                        "medianAudioSecondsPerWallSecond": records[0]["inputDurationSeconds"] /
                            timing["referenceProcessAndAlgorithmSeconds"]["median"], "reproducibility": "match"})
        print(f"{name}: {trials} reproducible runs", flush=True)
    write_json(output / "reference-performance.json", {"schemaVersion": 1, "acquisition": acquisition,
        "workloads": reports, "corpus": "complete current original-synthetic catalog; licensed corpus follows #27",
        "measurement": "external process startup, input, algorithm and export; not steady-state native algorithm latency"})
    environment = {**os.environ, "HDXL_REFERENCE_PERFORMANCE": "1"}
    command = ["swift", "test", "--configuration", "release", "--scratch-path", ".build/reference-native",
               "--filter", "referenceNativeValidationPerformance"]
    started = time.perf_counter()
    native = subprocess.run(command, cwd=ROOT, env=environment, capture_output=True, text=True, timeout=1200)
    build_and_test_seconds = time.perf_counter() - started
    safe = (native.stdout + native.stderr).replace(str(ROOT), "<checkout>").replace(str(Path.home()), "<home>")
    (output / "native-validation.log").write_text(safe)
    if native.returncode:
        raise ReferenceError("Native validation failed; inspect native-validation.log")
    lines = [line.removeprefix("REFERENCE_VALIDATION ") for line in native.stdout.splitlines() if line.startswith("REFERENCE_VALIDATION ")]
    if len(lines) != 1:
        raise ReferenceError("Native validation did not emit exactly one measurement record")
    record = json.loads(lines[0])
    golden = load_json(GOLDENS / "cpps-saw/reference.json")
    if record["referenceIdentity"] != golden["referenceIdentity"] or record["profileSHA256"] != golden["identityInputs"]["profile"]["sha256"]:
        raise ReferenceError("Native validation identities differ")
    record["distribution"] = distribution(record["trialsSeconds"])
    record["buildAndTestSeconds"] = build_and_test_seconds
    record["host"] = reports[0]["metadata"]["host"]
    record["configuration"] = "release"
    record["swift"] = subprocess.check_output(["swift", "--version"], text=True).strip()
    write_json(output / "native-performance.json", record)
    print("Native fixture validation completed; external and native timing boundaries are separate.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--trials", type=int, default=3)
    args = parser.parse_args()
    try:
        measure(args.output, args.trials)
    except (ReferenceError, OSError, subprocess.SubprocessError) as error:
        print(f"Reference evidence failed: {error}", file=sys.stderr)
        sys.exit(1)
