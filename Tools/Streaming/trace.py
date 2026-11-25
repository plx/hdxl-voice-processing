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
import signal
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


class CollectorTimeout(IncompleteRecording):
    """A collector phase timed out without producing verified evidence."""


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


class AcquisitionJournal:
    """Persist phase transitions separately from the validated signpost result."""

    def __init__(self, output, environment, build):
        self.path = output.with_name(f"{output.stem}-attempts-{uuid.uuid4().hex}.json")
        self.started = time.monotonic()
        self.data = {"schemaVersion": 1, "commit": environment["commit"], "xcode": environment["xcode"],
                     "binarySHA256": build["binarySHA256"], "status": "acquiring", "events": []}
        self.mark("prepared")

    def mark(self, phase, **values):
        self.data["events"].append({"phase": phase, "elapsedSeconds": round(time.monotonic() - self.started, 3),
                                    **values})
        self.persist()

    def finish(self, status):
        self.data["status"] = status
        self.persist()

    def persist(self):
        temporary = self.path.with_suffix(".tmp")
        temporary.write_text(json.dumps(self.data, indent=2, allow_nan=False) + "\n")
        temporary.replace(self.path)


def read_trial(report, expected, process_id=None):
    document = json.loads(report.read_bytes())
    trials = document["trials"]
    if (document["schemaVersion"] != 1 or len(trials) != 1
            or not isinstance(document["processID"], int) or document["processID"] <= 0
            or (process_id is not None and document["processID"] != process_id)
            or any(trials[0].get(field) != value for field, value in expected.items())):
        raise ValueError("Replay report does not describe the requested process and workload")
    return document


def read_completed_trial(report, expected, process_id, baseline, journal):
    journal.mark("reference-comparison")
    document = read_trial(report, expected, process_id)
    trial = document["trials"][0]
    if trial["science"]["sha256"] != baseline["science"]["sha256"]:
        raise ValueError("Traced admission or numerical results differ from the disabled reference")
    journal.mark("workload-validation")
    return document, summarize(trial)


def record_attached(target, trace, report, ready, journal, baseline, expected):
    name = "org.hdxl.voice.streaming-replay." + uuid.uuid4().hex
    system = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
    fd, token = ctypes.c_int(), ctypes.c_int()
    journal.mark("recorder-startup")
    if system.notify_register_file_descriptor(name.encode(), ctypes.byref(fd), 0, ctypes.byref(token)):
        raise RuntimeError("Unable to register for Instruments recording startup")
    try:
        command = ["xcrun", "xctrace", "record", "--template", "Logging", "--no-prompt", "--output", trace,
                   "--time-limit", "1m", "--notify-tracing-started", name, "--attach", str(target.pid)]
        with subprocess.Popen(command, stdin=subprocess.DEVNULL) as recorder:
            try:
                deadline = time.monotonic() + 60
                while not select.select([fd.value], [], [], 0.25)[0]:
                    if time.monotonic() >= deadline:
                        raise CollectorTimeout("Recording-start notification timed out")
                    if recorder.poll() is not None or target.poll() is not None:
                        raise RuntimeError("Recorder or replay exited before recording started")
                if len(os.read(fd.value, 4)) != 4:
                    raise RuntimeError("Incomplete Instruments startup notification")
                journal.mark("measured-workload")
                ready.touch(exist_ok=False)
                deadline = time.monotonic() + 60
                while not report.is_file():
                    if target.poll() is not None or recorder.poll() is not None or time.monotonic() >= deadline:
                        raise RuntimeError("Replay failed to publish its trial before recording ended")
                    time.sleep(0.05)
                completed = read_completed_trial(report, expected, target.pid, baseline, journal)
                journal.mark("recorder-finalization")
                recorder.send_signal(signal.SIGINT)
                try:
                    status = recorder.wait(timeout=120)
                except subprocess.TimeoutExpired as error:
                    raise CollectorTimeout("Recorder finalization timed out") from error
                if status:
                    raise subprocess.CalledProcessError(status, command)
                return completed
            finally:
                if recorder.poll() is None:
                    recorder.kill()
    finally:
        system.notify_cancel(token.value)


def record_when_ready(arguments, trace, report, journal, baseline, expected):
    # Own the target independently. Stopping the attached recorder cannot terminate
    # the replay, and the replay can wait for finalization without holding up xctrace.
    ready = report.with_name("recorder-started")
    env = dict(os.environ, HDXL_REPLAY_RECORDING_START=str(ready), HDXL_REPLAY_HOLD_FOR_RECORDER="1")
    journal.mark("target-startup")
    with subprocess.Popen(arguments, env=env, stdin=subprocess.DEVNULL) as target:
        try:
            completed = record_attached(target, trace, report, ready, journal, baseline, expected)
            journal.mark("target-release")
            ready.unlink()
            status = target.wait(timeout=10)
            if status:
                raise subprocess.CalledProcessError(status, arguments)
            return completed
        finally:
            if target.poll() is None:
                target.kill()
            ready.unlink(missing_ok=True)


def capture(binary, profile, load, directory, journal):
    requested = dict(profile=profile, sampleRate=48000, pattern=[512], load=load, seconds=1, seed=7, queueSlots=32)
    reference_request = dict(requested, mode="disabled", operation="single")
    trace_request = dict(requested, mode="detailed", operation="trace")

    def run_args(request, path):
        return [binary, request["profile"], str(request["sampleRate"]), str(request["pattern"][0]), request["load"],
                request["mode"], str(request["seconds"]), str(request["seed"]), request["operation"], path]

    journal.mark("reference", profile=profile, load=load)
    reference = directory / f"{load}-disabled.json"
    subprocess.run(run_args(reference_request, reference), check=True, timeout=90)
    baseline = read_trial(reference, reference_request)["trials"][0]
    attempts = []
    for attempt in range(1, 4):
        journal.mark("attempt", profile=profile, load=load, attempt=attempt)
        with tempfile.TemporaryDirectory(dir=directory) as temporary:
            work = Path(temporary)
            trace, report, xml = work / "capture.trace", work / "trial.json", work / "signposts.xml"
            try:
                doc, workload = record_when_ready(run_args(trace_request, report), trace, report, journal,
                                                  baseline, trace_request)
                journal.mark("export")
                try:
                    subprocess.run(["xcrun", "xctrace", "export", "--input", trace, "--xpath",
                                    '/trace-toc/run[@number="1"]/data/table[@schema="os-signpost"]',
                                    "--output", xml], check=True, timeout=120)
                except subprocess.TimeoutExpired as error:
                    raise CollectorTimeout("Recorder export timed out") from error
                journal.mark("signpost-accounting")
                stages = inspect(xml.read_bytes(), doc)
            except IncompleteRecording as error:
                # The public journal publishes the failing phase without exception payloads,
                # paths, raw signposts, environment variables or target arguments.
                journal.mark("discarded", during=journal.data["events"][-1]["phase"],
                             reason="timeout" if isinstance(error, CollectorTimeout) else "incomplete-signposts")
                attempts.append(str(error))
                continue
            journal.mark("validated", intervals=stages["completeIntervals"])
            return dict(stages, xmlSHA256=sha(xml), discardedRecordings=attempts,
                        workload=workload, referenceSHA256=baseline["science"]["sha256"])
    raise IncompleteRecording(f"No complete {load} trace in three recordings: {attempts}")


def verification_environment(journal):
    environment = ci.environment("release")
    path = journal.path.resolve()
    if environment["workingTreeDirty"] and path.is_relative_to(ROOT):
        # An unignored output inside the checkout creates one new journal during this run.
        # Keep every other tracked and untracked change in the existing provenance check.
        relative = path.relative_to(ROOT).as_posix()
        environment["workingTreeDirty"] = bool(subprocess.check_output(
            ["git", "-C", ROOT, "status", "--porcelain", "--", ".", f":(exclude,literal){relative}"]
        ))
    return environment


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("build_receipt", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    environment = ci.environment("release")
    binary, build = verified_binary(args.build_receipt, environment)
    journal = AcquisitionJournal(args.output, environment, build)
    try:
        with tempfile.TemporaryDirectory() as directory:
            recordings = {name: capture(binary, profile, load, Path(directory), journal)
                          for name, profile, load in (("paced", "cpps", "paced"), ("burst", "cpps", "burst"),
                                                      ("full", "full", "throughput"))}
        journal.mark("build-verification")
        if verified_binary(args.build_receipt, verification_environment(journal))[1] != build:
            raise ValueError("Release build changed during trace acquisition")
        environment["execution"] = "Instruments Logging on governed, synthetic native PCM"
        environment["model"] = ci.capture("sysctl", "-n", "hw.model")
        report = dict(schemaVersion=1, template="Logging", toolchain=environment,
                      binarySHA256=build["binarySHA256"], build=build, recordings=recordings)
        encoded = ci.redact(json.dumps(report, indent=2, allow_nan=False)) + "\n"
        with args.output.open("x") as output:
            output.write(encoded)
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
