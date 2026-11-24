#!/usr/bin/env python3
"""Record production streaming signposts on deterministic PCM; retain numerical evidence."""
import argparse
from collections import Counter, defaultdict
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Tools"))
import ci
from instrumentation import signpost_records
from Performance.records import sha
from Streaming.report import distribution, summarize

META = re.compile(r"session=(\d+) epoch=(\d+) span=(\d+) profile=(\d+) frame=(\d+) samples=(\d+) "
                  r"depth=(\d+) validity=(\d+) processed=(\d+) queue_ns=(\d+)")
STAGES = {"Resample", "PreEmphasis", "FrameAssembly", "FFT", "Cepstrum", "CPP", "CPPSSmoothing",
          "CPPSFitting", "ResultPublication", "ResultDelivery", "AnalysisFrame"}


class IncompleteRecording(ValueError):
    """Instruments omitted target records. Keep the attempt reason if recording again."""


def inspect(xml, document):
    trial = document["trials"][0]
    target = f"StreamingReplayProbe ({document['processID']})"
    rows = [r for r in signpost_records(xml) if r["process"] == target]
    active, seen, durations, events = {}, set(), defaultdict(list), Counter()
    overruns, dequeues, post_gap_publications = [], [], []
    subscriber_delays = []
    for row in sorted(rows, key=lambda item: item["time"]):
        stage, kind, time = row["name"], row["event-type"], row["time"]
        key = row["category"], stage, row["identifier"]
        if kind == "End":
            if row["message"]:
                raise ValueError("Signpost end contains unexpected metadata")
            if key not in active:
                raise IncompleteRecording(f"Unmatched {stage} end")
            durations[stage].append(time - active.pop(key))
            continue
        match = META.fullmatch(row["message"])
        if not match:
            raise ValueError("Unexpected diagnostic metadata")
        session, epoch, span, profile, sequence, _, depth, validity, _, wait = map(int, match.groups())
        if not session or (session, span) in seen:
            raise ValueError("Invalid session or duplicate signpost identity")
        seen.add((session, span))
        if kind == "Begin":
            if key in active:
                raise IncompleteRecording(f"Missing prior {stage} end")
            active[key] = time
            if stage == "ResultDelivery":
                if wait == 2**64-1:
                    raise ValueError("Missing consumer observation lag")
                subscriber_delays.append(wait)
            if stage == "ResultPublication":
                post_gap_publications.append((time, sequence))
        elif kind == "Event":
            events[stage] += 1
            if stage == "Overrun":
                if profile != 54 or validity != 3:
                    raise ValueError("Overrun lost its worker/validity context")
                overruns.append((time, epoch))
            if stage == "Dequeue":
                if depth > trial["queueSlots"]:
                    raise ValueError("Trace queue exceeds prepared capacity")
                dequeues.append((time, epoch))
        else:
            raise ValueError(f"Unknown signpost record kind {kind}")
    expected = {
        "CaptureHandoff": trial["drainedBlocks"], "Dequeue": trial["drainedBlocks"], "Overrun": trial["gapCount"],
        "ResultPublication": trial["fast"]["accepted"],
        "ResultDelivery": sum(trial[s]["delivered"] for s in ("fast", "slow", "paused")),
        "CPPSSmoothing": sum(r["outcomes"]["cpps"] == "available" for r in trial["science"]["records"]),
        "CPPSFitting": sum(r["outcomes"]["cpps"] == "available" for r in trial["science"]["records"]),
    }
    counts = dict(events) | {k: len(values) for k, values in durations.items()}
    if active or not STAGES <= durations.keys() or any(counts.get(k) != v or not v for k, v in expected.items()):
        raise IncompleteRecording(f"Unbalanced or missing stages: open={len(active)}, stages={sorted(durations)}, "
                                  f"required={expected}, observed={counts}")
    available_sequences = {r["publication"] for r in trial["science"]["records"] if r["outcomes"]["cpps"] == "available"}
    for overrun, epoch in overruns:
        if not any(t > overrun and e > epoch for t, e in dequeues) or not any(
                t > overrun and sequence in available_sequences for t, sequence in post_gap_publications):
            raise IncompleteRecording("Missing resumed dequeue or valid CPPS publication after an overrun")
    return dict(stagesNS={stage: distribution(values) for stage, values in durations.items()},
                events=dict(events), expectedCounts=expected, completeIntervals=sum(map(len, durations.values())),
                subscriberLagNS=distribution(subscriber_delays), unmatchedIntervals=0,
                approvedNumericMetadataOnly=True)


def capture(binary, load, directory):
    def run_args(mode, path):
        return [binary, "cpps", "48000", "512", load, mode, "1", "7", "single", path]
    reference = directory / f"{load}-disabled.json"
    subprocess.run(run_args("disabled", reference), check=True, timeout=90)
    baseline = json.loads(reference.read_bytes())["trials"][0]
    attempts = []
    for _ in range(3):
        with tempfile.TemporaryDirectory(dir=directory) as tmp:
            work = Path(tmp)
            trace, report, xml = work / "capture.trace", work / "trial.json", work / "signposts.xml"
            subprocess.run(["xcrun", "xctrace", "record", "--template", "Logging", "--output", trace,
                            "--time-limit", "1m", "--launch", "--", *run_args("detailed", report)],
                           check=True, timeout=120)
            doc = json.loads(report.read_bytes())
            observed = doc["trials"][0]
            if observed["science"]["sha256"] != baseline["science"]["sha256"]:
                raise ValueError("Traced admission or numerical results differ from the disabled reference")
            subprocess.run(["xcrun", "xctrace", "export", "--input", trace, "--xpath",
                            '/trace-toc/run[@number="1"]/data/table[@schema="os-signpost"]',
                            "--output", xml], check=True, timeout=120)
            try:
                stages = inspect(xml.read_bytes(), doc)
            except IncompleteRecording as error:
                attempts.append(str(error))
                continue
            return dict(stages, xmlSHA256=sha(xml), discardedRecordings=attempts,
                        workload=summarize(observed), referenceSHA256=baseline["science"]["sha256"])
    raise IncompleteRecording(f"No complete {load} trace in three recordings: {attempts}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    binary = args.binary.resolve(strict=True)
    with tempfile.TemporaryDirectory() as directory:
        recordings = {load: capture(binary, load, Path(directory)) for load in ("paced", "burst")}
    report = dict(schemaVersion=1, template="Logging", toolchain=ci.environment("release"),
                  binarySHA256=sha(binary), recordings=recordings)
    with args.output.open("x") as output:
        output.write(ci.redact(json.dumps(report, indent=2, allow_nan=False)) + "\n")


if __name__ == "__main__":
    main()
