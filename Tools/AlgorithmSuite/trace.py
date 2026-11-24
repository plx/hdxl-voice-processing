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
            "HarmonicCorrection", "SpeechActivity", "PulseMatching", "Perturbation/50", "Perturbation/51"}
ENABLED = {"Cepstrum", "CPP", "CPPSSmoothing", "CPPSFitting", "CPPSAggregation"}


class IncompleteRecording(ValueError):
    """Instruments omitted at least one interval boundary from the target process."""


def summarize(xml, process_id):
    active = {}
    durations = defaultdict(list)
    rows = [r for r in signpost_records(xml) if r["process"] == f"VoiceSuiteWorkloadCheck ({process_id})"]
    if not rows:
        raise IncompleteRecording("No signposts from the traced target")
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
            if key not in active:
                raise IncompleteRecording(f"Missing begin for {key[1]}")
            stage, start = active.pop(key)
            durations[stage].append(record["time"] - start)
        else:
            raise ValueError("Unexpected signpost event kind")
    if active:
        raise IncompleteRecording("Incomplete native intervals in recording")
    def stats(values):
        ordered = sorted(values)
        return dict(count=len(values), firstNS=values[0], medianNS=ordered[(len(values)-1)//2],
                    maximumNS=ordered[-1], totalNS=sum(values))
    return {name: stats(values) for name, values in sorted(durations.items())}


def verify_cpps_counts(spans, reference):
    # The governed harmonic produces a valid fit for each complete frame and a single partial tail.
    lanes = reference["results"][0]["lanes"]
    total = lambda lane: lanes[lane]["available"] + lanes[lane]["unavailable"]
    expected = {"Cepstrum": total("cpp"), "CPP": lanes["cpp"]["available"],
                "CPPSSmoothing": lanes["cpps"]["available"], "CPPSFitting": lanes["cpps"]["available"],
                "CPPSAggregation": total("rollingCPPS")}
    for name, count in expected.items():
        if count <= 0 or spans.get(name, {}).get("count", 0) != count:
            raise IncompleteRecording(f"{name} expected {count} complete spans, observed {spans.get(name, {}).get('count', 0)}")
    return expected


def record(binary, arguments, reference, directory):
    trace = directory / "recording.trace"
    stdout = directory / "observed.json"
    xml = directory / "signposts.xml"
    subprocess.run(["xcrun", "xctrace", "record", "--template", "Logging", "--output", trace,
                    "--time-limit", "1m", "--target-stdout", stdout, "--launch", "--",
                    binary, "trace", *arguments], check=True, timeout=120)
    traced = json.loads(stdout.read_bytes())
    if traced["evidence"] != reference:
        raise ValueError("Native outputs changed with tracing")
    subprocess.run(["xcrun", "xctrace", "export", "--input", trace, "--xpath",
                    '/trace-toc/run[@number="1"]/data/table[@schema="os-signpost"]', "--output", xml],
                   check=True, timeout=120)
    spans = summarize(xml.read_bytes(), traced["processID"])
    expected = verify_cpps_counts(spans, reference)
    return dict(xmlSHA256=sha(xml), spans=spans, expectedCPPSCounts=expected, fixture=reference["fixture"],
                recipe=reference["recipe"], results=reference["results"])


def capture(binary, bundle, profile, directory):
    arguments = [str(bundle), profile, "harmonic-low"]
    reference = json.loads(subprocess.check_output([binary, "run", *arguments]))
    discarded = []
    for _ in range(3):
        with tempfile.TemporaryDirectory(dir=directory) as recording:
            try:
                evidence = record(binary, arguments, reference, Path(recording))
            except IncompleteRecording as error:
                discarded.append(str(error))
                continue
            return dict(evidence, discardedRecordings=discarded)
    raise IncompleteRecording(f"Could not record complete {profile} intervals in three attempts: {discarded}")


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
            profiles[composition] = capture(binary, bundle, composition, directory)
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
