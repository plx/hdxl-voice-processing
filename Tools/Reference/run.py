#!/usr/bin/env python3
"""Generate an explicit external-reference candidate; never overwrite committed goldens."""
import argparse
import os
from pathlib import Path
import platform
import subprocess
import sys
import time

from common import HERE, ROOT, ReferenceError, ReferenceFailure, UnsupportedInput, canonical, digest, load_json, outcome, read_pcm, write_json
import cpps
import voice
from profiles import validate_cpps_profile
from setup import verify_tool


RUNNER_VERSION = 1


def implementation_digest():
    paths = ("common.py", "cpps.py", "profiles.py", "run.py", "Scripts/cpps.praat", "voice.py", "Scripts/voice.praat")
    return digest(canonical({p: digest((HERE / p).read_bytes()) for p in paths}))


def result_record(profile, identity, source, value):
    return {"schemaVersion": 1, "measurement": profile["measurement"], "profile": identity,
            "timing": {"source": {"epoch": {"streamID": "00000000-0000-0000-0000-000000000026", "sequence": 0},
                                  "startSample": 0, "sampleCount": source["sampleCount"], "sampleRate": source["sampleRate"]},
                       "includedSampleCount": source["sampleCount"], "sourceStartSeconds": 0,
                       "hostStartNanoseconds": None, "completedHostNanoseconds": None, "effectiveDelaySeconds": source["sampleCount"] / (2 * source["sampleRate"])},
            "outcome": outcome(value), "intermediatePolicy": {"maximumScalarCount": 0}, "intermediates": []}


def assemble(profile, source, lock, raw, export, analysis="cpps"):
    if analysis != "cpps":
        data = voice.parse(raw, source, analysis)
        identity_inputs = {"runnerVersion": RUNNER_VERSION, "runnerSHA256": implementation_digest(),
                           "toolchain": lock, "recipe": profile, "input": source, "export": "frames"}
        return {"schemaVersion": 1, "referenceIdentity": digest(b"hdxl-reference-v1\n" + canonical(identity_inputs)),
                "identityInputs": identity_inputs, "rawOutputSHA256": digest(raw.encode()), "data": data}
    value, data = cpps.parse(raw, source, export)
    identity = {"identifier": profile["identifier"], "sha256": digest(canonical(profile))}
    identity_inputs = {"runnerVersion": RUNNER_VERSION, "runnerSHA256": implementation_digest(), "toolchain": lock,
                       "profile": identity, "input": source,
                       "selection": [{"startSample": 0, "sampleCount": source["sampleCount"], "included": True, "reason": None}],
                       "export": "intermediates" if export else "frames"}
    return {"schemaVersion": 1, "referenceIdentity": digest(b"hdxl-reference-v1\n" + canonical(identity_inputs)),
            "identityInputs": identity_inputs, "profile": profile, "result": result_record(profile, identity, source, value),
            "data": data, "rawOutputSHA256": digest(raw.encode()),
            "support": {"sourceInterval": "entire contiguous input; no excluded samples stitched",
                        "frameTimes": "Praat frame centers in seconds from input start",
                        "delay": "whole-interval result waits from source midpoint to interval end; runtime compute time excluded",
                        "physicalWindowSeconds": profile["frameLength"] / profile["analysisSampleRate"],
                        "smoothing": "centered, reference-defined edge handling; not a causal streaming result"},
            "tolerances": {"countsIndicesIdentities": "exact", "axisAbsoluteSeconds": 1e-12,
                           "decibelAbsolute": 1e-8, "linearAbsolute": 1e-8, "relative": 1e-10,
                           "purpose": "pinned-reference regeneration; native algorithm tolerances require separate review"}}


def generate(input_path, profile_path, tool, output, export=True, analysis="cpps"):
    output = Path(output).resolve()
    if output.exists() or not output.is_relative_to((ROOT / ".build").resolve()):
        raise ReferenceError("Use a fresh candidate directory under repository .build")
    started = time.perf_counter()
    profile = validate_cpps_profile(load_json(profile_path)) if analysis == "cpps" else voice.recipe(analysis)
    samples, source = read_pcm(input_path)
    if source["sampleRate"] != (profile["inputFormat"]["sampleRate"] if analysis == "cpps" else profile["sampleRate"]):
        raise UnsupportedInput("unsupportedRange")
    if len(samples) / source["sampleRate"] < 0.1:
        raise UnsupportedInput("insufficientData")
    frames = cpps.frame_count(len(samples), source["sampleRate"])
    if analysis == "cpps" and export and frames * 513 > 50000:
        raise UnsupportedInput("unsupportedRange")
    lock = load_json(HERE / "toolchain.json")
    if platform.python_version() != lock["pythonVersion"]:
        raise ReferenceError("Python version differs from the reference environment")
    binary = verify_tool(tool, lock)
    setup_seconds = time.perf_counter() - started
    environment = {**os.environ, "LC_ALL": "C", "LANG": "C"}
    script = "cpps" if analysis == "cpps" else "voice"
    arguments = cpps.arguments(profile, Path(input_path).resolve(), export) if analysis == "cpps" else voice.arguments(analysis, Path(input_path).resolve())
    command = [str(binary), *lock["options"], str(HERE / f"Scripts/{script}.praat"), *arguments]
    started = time.perf_counter()
    completed = subprocess.run(command, capture_output=True, text=True, encoding="utf-8", env=environment, timeout=120)
    regeneration_seconds = time.perf_counter() - started
    if completed.returncode or completed.stderr.strip():
        # Do not include user filenames or raw PCM in public error reports.
        raise ReferenceFailure(f"Praat failed or warned (exit {completed.returncode}); candidate not written")
    if len(completed.stdout.encode()) > 16 * 1024 * 1024:
        raise ReferenceFailure("Reference output exceeded the 16 MiB budget")
    raw = completed.stdout
    started = time.perf_counter()
    manifest = assemble(profile, source, lock, raw, export, analysis)
    parse_seconds = time.perf_counter() - started
    output.mkdir(parents=True)
    (output / "reference.raw.txt").write_text(raw, encoding="utf-8")
    write_json(output / "reference.json", manifest)
    write_json(output / "execution.json", {"setupSeconds": setup_seconds,
        "referenceProcessAndAlgorithmSeconds": regeneration_seconds, "parseValidationSeconds": parse_seconds,
        "inputDurationSeconds": len(samples) / source["sampleRate"], "profileSHA256": digest(canonical(profile)),
        "referenceIdentity": manifest["referenceIdentity"], "precision": "float64", "export": manifest["identityInputs"]["export"],
        "host": {"system": platform.system(), "osVersion": platform.mac_ver()[0], "architecture": platform.machine(),
                 "model": subprocess.check_output(["sysctl", "-n", "hw.model"], text=True).strip()},
        "allocationCounts": {"status": "unavailable", "reason": "external Praat process has no audited allocation backend"},
        "timingBoundary": "setup separate; regeneration includes process startup, file read, reference computation and export"})
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--analysis", choices=("cpps", *voice.KINDS), default="cpps")
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--profile", type=Path, default=HERE / "Profiles/cpps-murton-praat7.json")
    parser.add_argument("--tool", type=Path, default=ROOT / ".build/reference-tool/7.0.02/Praat.app/Contents/MacOS/Praat")
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--frames-only", action="store_true")
    args = parser.parse_args()
    try:
        if args.analysis != "cpps" and args.profile != HERE / "Profiles/cpps-murton-praat7.json":
            raise ReferenceError("Auxiliary recipes are fixed; --profile is only valid for CPPS")
        manifest = generate(args.input, args.profile, args.tool, args.output, not args.frames_only, args.analysis)
        print(manifest["referenceIdentity"])
    except (ReferenceError, OSError, subprocess.SubprocessError) as error:
        print(f"Reference generation failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
