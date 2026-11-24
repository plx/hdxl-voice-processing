#!/usr/bin/env python3
"""Capture paired native signpost spans for reduced and full execution on synthetic PCM."""

import argparse
from collections import defaultdict
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Tools"))
from AlgorithmSuite.prepare import prepare
from Performance.records import sha
import ci
from instrumentation import signpost_records

# YIN/SWIPE and jitter/shimmer share a stage name. Native profile tokens distinguish the workers.
DISABLED = {"LevelEnergy", "KWeighting", "Pitch/38", "Pitch/44", "PitchTracking", "HNRCorrelation",
            "Spectrogram", "LongTermSpectrum", "SpectralShape", "BurgLPC", "HarmonicFit",
            "SpeechActivity", "PulseMatching", "Perturbation/50", "Perturbation/51"}
ENABLED = {"CPPSSmoothing", "CPPSFitting", "CPPSAggregation"}


def summarize(xml):
    active = {}
    durations = defaultdict(list)
    rows = [r for r in signpost_records(xml) if re.fullmatch(r"VoiceSuiteWorkloadCheck \(\d+\)", r["process"])]
    if len({r["process"] for r in rows}) != 1:
        raise ValueError("Expected exactly one traced target process")
    for record in sorted(rows, key=lambda r: r["time"]):
        kind = record["event-type"]
        if kind == "Event":
            continue
        key = (record["category"], record["name"], record["identifier"])
        if kind == "Begin":
            profile = re.search(r"(?:^| )profile=(\d+) ", record["message"])
            if key in active or not profile:
                raise ValueError("Duplicate interval or missing native metadata")
            stage = key[1] + ("/" + profile[1] if key[1] in ("Pitch", "Perturbation") else "")
            active[key] = (stage, record["time"])
        elif kind == "End":
            stage, start = active.pop(key)
            durations[stage].append(record["time"] - start)
        else:
            raise ValueError("Unexpected signpost event kind")
    if active:
        raise ValueError("Incomplete native intervals in recording")
    def stats(values):
        ordered = sorted(values)
        return dict(count=len(values), firstNS=values[0], medianNS=ordered[(len(values)-1)//2],
                    maximumNS=ordered[-1], totalNS=sum(values))
    return {name: stats(values) for name, values in sorted(durations.items())}


def capture(binary, bundle, profile, directory):
    trace = directory / "recording.trace"
    stdout = directory / "observed.json"
    xml = directory / "signposts.xml"
    arguments = [str(bundle), profile, "harmonic-low"]
    reference = json.loads(subprocess.check_output([binary, "run", *arguments]))
    subprocess.run(["xcrun", "xctrace", "record", "--template", "Logging", "--output", trace,
                    "--time-limit", "1m", "--target-stdout", stdout, "--launch", "--",
                    binary, "trace", *arguments], check=True, timeout=120)
    if json.loads(stdout.read_bytes()) != reference:
        raise ValueError(f"Native outputs changed with tracing in {profile}")
    subprocess.run(["xcrun", "xctrace", "export", "--input", trace, "--xpath",
                    '/trace-toc/run[@number="1"]/data/table[@schema="os-signpost"]', "--output", xml],
                   check=True, timeout=120)
    return dict(xmlSHA256=sha(xml), spans=summarize(xml.read_bytes()), fixture=reference["fixture"],
                recipe=reference["recipe"], results=reference["results"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    binary = args.binary.resolve(strict=True)
    profiles = {}
    with tempfile.TemporaryDirectory() as raw:
        directory = Path(raw)
        bundle = directory / "inputs"
        prepare(bundle)
        for composition in ("cpps", "full"):
            with tempfile.TemporaryDirectory(dir=directory) as recording:
                profiles[composition] = capture(binary, bundle, composition, Path(recording))
    reduced = set(profiles["cpps"]["spans"])
    full = set(profiles["full"]["spans"])
    if not ENABLED <= reduced or reduced & DISABLED or not (DISABLED | ENABLED) <= full:
        raise ValueError(f"Trace coverage differs. Reduced {sorted(reduced)}, full {sorted(full)}")
    result = dict(template="Logging", binarySHA256=sha(binary), toolchain=ci.environment("release"),
                  profiles=profiles, requiredPositiveControls=sorted(DISABLED), requiredCPPSStages=sorted(ENABLED))
    with args.output.open("x") as stream:
        stream.write(ci.redact(json.dumps(result, indent=2, allow_nan=False)) + "\n")


if __name__ == "__main__":
    main()
