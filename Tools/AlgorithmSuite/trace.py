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
from trace_acquisition import AcquisitionJournal, CollectorTimeout, IncompleteRecording, record_when_ready

# YIN/SWIPE and jitter/shimmer share a stage name. Native profile tokens distinguish the workers.
DISABLED = {"LevelEnergy", "KWeighting", "Pitch/38", "Pitch/44", "PitchTracking", "HNRCorrelation",
            "Spectrogram", "LongTermSpectrum", "SpectralShape", "BurgLPC", "HarmonicFit",
            "HarmonicCorrection", "SpeechActivity", "PulseMatching", "Perturbation/50", "Perturbation/51"}
ENABLED = {"Cepstrum", "CPP", "CPPSSmoothing", "CPPSFitting", "CPPSAggregation"}


def summarize(xml, process_id):
    active = {}
    durations = defaultdict(list)
    # The separately owned target stays alive until the recorder exits. Its PID uniquely
    # identifies these rows even when Instruments abbreviates the displayed process name.
    rows = [r for r in signpost_records(xml) if r["process"].endswith(f" ({process_id})")]
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


def record(binary, arguments, reference, directory, journal):
    trace = directory / "recording.trace"
    report = directory / "observed.json"
    xml = directory / "signposts.xml"

    def validate_report(pid):
        journal.mark("reference-comparison")
        traced = json.loads(report.read_bytes())
        if traced["processID"] != pid or traced["evidence"] != reference:
            raise ValueError("Traced process or native outputs differ from the reference")
        return pid

    process_id = record_when_ready([binary, "trace", *arguments, report], trace, report, journal, validate_report)
    journal.mark("export")
    try:
        subprocess.run(["xcrun", "xctrace", "export", "--input", trace, "--xpath",
                        '/trace-toc/run[@number="1"]/data/table[@schema="os-signpost"]', "--output", xml],
                       check=True, timeout=120)
    except subprocess.TimeoutExpired as error:
        raise CollectorTimeout("Recorder export timed out") from error
    journal.mark("signpost-accounting")
    spans = summarize(xml.read_bytes(), process_id)
    expected = verify_cpps_counts(spans, reference)
    return dict(xmlSHA256=sha(xml), spans=spans, expectedCPPSCounts=expected, fixture=reference["fixture"],
                recipe=reference["recipe"], results=reference["results"])


def capture(binary, bundle, profile, directory, journal):
    arguments = [str(bundle), profile, "harmonic-low"]
    journal.mark("reference", profile=profile)
    reference = json.loads(subprocess.check_output([binary, "run", *arguments], timeout=90))
    discarded = []
    for attempt in range(1, 4):
        journal.mark("attempt", profile=profile, attempt=attempt)
        with tempfile.TemporaryDirectory(dir=directory) as recording:
            try:
                evidence = record(binary, arguments, reference, Path(recording), journal)
            except IncompleteRecording as error:
                journal.mark("discarded", during=journal.data["events"][-1]["phase"],
                             reason="timeout" if isinstance(error, CollectorTimeout) else "incomplete-signposts")
                discarded.append(str(error))
                continue
            journal.mark("validated", profile=profile, intervals=sum(row["count"] for row in evidence["spans"].values()))
            return dict(evidence, discardedRecordings=discarded)
    raise IncompleteRecording(f"Could not record complete {profile} intervals in three attempts: {discarded}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    binary = args.binary.resolve(strict=True)
    environment = ci.environment("release")
    digest = sha(binary)
    journal = AcquisitionJournal(args.output, environment, digest)
    try:
        profiles = {}
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            bundle = directory / "inputs"
            prepare(bundle)
            for composition in ("cpps", "full"):
                profiles[composition] = capture(binary, bundle, composition, directory, journal)
        journal.mark("profile-coverage")
        reduced = set(profiles["cpps"]["spans"])
        full = set(profiles["full"]["spans"])
        if not ENABLED <= reduced or reduced & DISABLED or not (DISABLED | ENABLED) <= full:
            raise ValueError(f"Trace coverage differs. Reduced {sorted(reduced)}, full {sorted(full)}")
        if sha(binary) != digest:
            raise ValueError("Offline trace binary changed during acquisition")
        result = dict(template="Logging", binarySHA256=digest, toolchain=environment,
                      profiles=profiles, requiredPositiveControls=sorted(DISABLED), requiredCPPSStages=sorted(ENABLED))
        with args.output.open("x") as stream:
            stream.write(ci.redact(json.dumps(result, indent=2, allow_nan=False)) + "\n")
    except KeyboardInterrupt:
        journal.mark("interrupted", during=journal.data["events"][-1]["phase"])
        journal.finish("interrupted")
        raise
    except Exception as error:
        journal.mark("failure", during=journal.data["events"][-1]["phase"], kind=type(error).__name__)
        journal.finish("failed")
        raise
    journal.finish("passed")


if __name__ == "__main__":
    main()
