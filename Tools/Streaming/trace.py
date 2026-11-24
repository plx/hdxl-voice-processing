#!/usr/bin/env python3
"""Record production streaming signposts on deterministic PCM; retain numerical evidence."""
import argparse
from collections import Counter, defaultdict
import ctypes
import json
import os
from pathlib import Path
import re
import select
import subprocess
import sys
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Tools"))
import ci
from instrumentation import signpost_records
from Performance.records import sha
from Streaming.build import verified_binary
from Streaming.report import distribution, summarize

META = re.compile(r"session=(\d+) epoch=(\d+) span=(\d+) profile=(\d+) frame=(\d+) samples=(\d+) "
                  r"depth=(\d+) validity=(\d+) processed=(\d+) queue_ns=(\d+)")
STAGES = {"Resample", "PreEmphasis", "FrameAssembly", "FFT", "Cepstrum", "CPP", "CPPSSmoothing",
          "CPPSFitting", "ResultPublication", "ResultDelivery", "AnalysisFrame"}


FULL_STAGES = {"LevelEnergy", "KWeighting", "Pitch", "PitchTracking", "HNR", "HNRNormalization",
               "HNRWindow", "HNRCorrelation", "HNRPeriodSearch"}


class IncompleteRecording(ValueError):
    """Instruments omitted target records. Keep the attempt reason if recording again."""


def reconcile_kernels(profiled, expected):
    observed_dsp = {key.lower(): len(values) for key, values in profiled.items()}
    expected_dsp = {key.lower(): count for key, count in expected.items()}
    if not expected_dsp or observed_dsp != expected_dsp:
        mismatch = {k: (expected_dsp.get(k), observed_dsp.get(k)) for k in expected_dsp.keys() | observed_dsp.keys()
                    if expected_dsp.get(k) != observed_dsp.get(k)}
        raise IncompleteRecording(f"DSP invocation counts differ from the independent scheduler: {mismatch}")
    return expected_dsp


def inspect(xml, document):
    trial = document["trials"][0]
    target = f"StreamingReplayProbe ({document['processID']})"
    rows = [r for r in signpost_records(xml) if r["process"] == target]
    active, seen, durations, profiled, events = {}, set(), defaultdict(list), defaultdict(list), Counter()
    required_stages = STAGES | (FULL_STAGES if trial.get("profile") == "full" else set())
    overruns, resets, dequeues, publications = [], [], [], []
    subscriber_delays = []
    for row in sorted(rows, key=lambda item: item["time"]):
        stage, kind, time = row["name"], row["event-type"], row["time"]
        key = row["category"], stage, row["identifier"]
        category = ({"Reset": "lifecycle", "Initialize": "lifecycle", "Overrun": "flow", "Drop": "flow",
                     "Dequeue": "flow", "CaptureHandoff": "flow", "ResultDelivery": "delivery"}).get(stage, "worker")
        if row["category"] != category:
            raise ValueError("Unexpected signpost category")
        if kind == "End":
            if row["message"]:
                raise ValueError("Signpost end contains unexpected metadata")
            if key not in active:
                raise IncompleteRecording(f"Unmatched {stage} end")
            start, profile = active.pop(key)
            durations[stage].append(time - start)
            if profile not in {54, 5401, 5402}:
                profiled[f"{stage}/{profile}"].append(time - start)
            continue
        match = META.fullmatch(row["message"])
        if not match:
            raise ValueError("Unexpected diagnostic metadata")
        session, epoch, span, profile, sequence, _, depth, validity, _, wait = map(int, match.groups())
        if not session or (session, span) in seen:
            raise ValueError("Invalid session or duplicate signpost identity")
        seen.add((session, span))
        if kind == "Begin":
            if stage not in required_stages:
                raise ValueError("Unexpected streaming interval name")
            if key in active:
                raise IncompleteRecording(f"Missing prior {stage} end")
            active[key] = (time, profile)
            if stage == "ResultDelivery":
                if wait == 2**64-1:
                    raise ValueError("Missing consumer observation lag")
                subscriber_delays.append(wait)
            if stage == "ResultPublication":
                publications.append((time, sequence))
        elif kind == "Event":
            if stage not in {"Initialize", "Reset", "Overrun", "Drop", "CaptureHandoff", "Dequeue", "Cancelled"}:
                raise ValueError("Unexpected streaming event name")
            events[stage] += 1
            if stage == "Reset" and profile == 54:
                resets.append((time, epoch))
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
        "CPPSSmoothing": sum(r["outcomes"]["cpps"] == "available" for r in trial["science"]["records"] if r.get("lane") == "cpps"),
        "CPPSFitting": sum(r["outcomes"]["cpps"] == "available" for r in trial["science"]["records"] if r.get("lane") == "cpps"),
    }
    counts = dict(events) | {k: len(values) for k, values in durations.items()}
    if active or not required_stages <= durations.keys() or any(counts.get(k) != v or not v for k, v in expected.items()):
        raise IncompleteRecording(f"Unbalanced or missing stages: open={len(active)}, stages={sorted(durations)}, "
                                  f"required={expected}, observed={counts}")
    expected_dsp = reconcile_kernels(profiled, trial["science"]["expectedTraceIntervals"])
    if len(resets) != trial["resetCount"]:
        raise IncompleteRecording("Missing worker reset")
    available_sequences = {r["publication"]: r["continuity"] for r in trial["science"]["records"]
                           if r["outcomes"].get("cpps") == "available"}
    for overrun, epoch in overruns:
        if not any(t >= overrun and e == epoch for t, e in resets):
            raise IncompleteRecording("Missing worker reset after overrun")
        if not any(t > overrun and e == epoch + 1 for t, e in dequeues) or not any(
                t > overrun and available_sequences.get(sequence) == epoch + 1 for t, sequence in publications):
            raise IncompleteRecording("Missing resumed dequeue or valid CPPS publication on the new continuity epoch")
    return dict(stagesNS={stage: dict(distribution(values), totalNS=sum(values)) for stage, values in durations.items()
                          if stage not in {"AnalysisFrame", "ResultDelivery"}},
                kernelProfileNS={key: dict(distribution(values), totalNS=sum(values)) for key, values in profiled.items()
                                 if not key.startswith("AnalysisFrame/")},
                independentKernelIntervals=expected_dsp, deliveryMarkerCount=len(durations["ResultDelivery"]),
                events=dict(events), expectedCounts=expected, completeIntervals=sum(map(len, durations.values())),
                subscriberLagNS=distribution(subscriber_delays), unmatchedIntervals=0,
                approvedNumericMetadataOnly=True)


def record_when_ready(arguments, trace, ready):
    """Release the measured target after Instruments announces the recording."""
    name = "org.hdxl.voice.streaming-replay." + uuid.uuid4().hex
    system = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
    fd, token = ctypes.c_int(), ctypes.c_int()
    if system.notify_register_file_descriptor(name.encode(), ctypes.byref(fd), 0, ctypes.byref(token)):
        raise RuntimeError("Unable to register for Instruments recording startup")
    command = ["xcrun", "xctrace", "record", "--template", "Logging", "--output", trace,
               "--time-limit", "1m", "--notify-tracing-started", name,
               "--env", f"HDXL_REPLAY_RECORDING_START={ready}", "--launch", "--", *arguments]
    try:
        with subprocess.Popen(command) as recorder:
            try:
                deadline = time.monotonic() + 60
                while not select.select([fd.value], [], [], 0.25)[0]:
                    if recorder.poll() is not None or time.monotonic() >= deadline:
                        raise RuntimeError("Instruments exited or timed out before recording started")
                if len(os.read(fd.value, 4)) != 4:
                    raise RuntimeError("Incomplete Instruments startup notification")
                ready.touch(exist_ok=False)
                if recorder.wait(timeout=120):
                    raise subprocess.CalledProcessError(recorder.returncode, command)
            finally:
                if recorder.poll() is None:
                    recorder.kill()
    finally:
        # Darwin releases the notification descriptor when its token is cancelled.
        system.notify_cancel(token.value)


def capture(binary, profile, load, directory):
    def run_args(mode, path):
        return [binary, profile, "48000", "512", load, mode, "1", "7",
                "trace" if mode == "detailed" else "single", path]
    reference = directory / f"{load}-disabled.json"
    subprocess.run(run_args("disabled", reference), check=True, timeout=90)
    baseline = json.loads(reference.read_bytes())["trials"][0]
    attempts = []
    for _ in range(3):
        with tempfile.TemporaryDirectory(dir=directory) as tmp:
            work = Path(tmp)
            trace, report, xml = work / "capture.trace", work / "trial.json", work / "signposts.xml"
            record_when_ready(run_args("detailed", report), trace, work / "recorder-started")
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
    parser.add_argument("build_receipt", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    environment = ci.environment("release")
    binary, build = verified_binary(args.build_receipt, environment)
    with tempfile.TemporaryDirectory() as directory:
        recordings = {name: capture(binary, profile, load, Path(directory)) for name, profile, load in
                      (("paced", "cpps", "paced"), ("burst", "cpps", "burst"), ("full", "full", "throughput"))}
    if verified_binary(args.build_receipt, ci.environment("release"))[1] != build:
        raise ValueError("Release build changed during trace acquisition")
    environment["execution"] = "Instruments Logging on governed, synthetic native PCM"
    environment["model"] = ci.capture("sysctl", "-n", "hw.model")
    report = dict(schemaVersion=1, template="Logging", toolchain=environment,
                  binarySHA256=build["binarySHA256"], build=build, recordings=recordings)
    with args.output.open("x") as output:
        output.write(ci.redact(json.dumps(report, indent=2, allow_nan=False)) + "\n")


if __name__ == "__main__":
    main()
