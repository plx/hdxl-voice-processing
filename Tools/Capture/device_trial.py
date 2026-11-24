#!/usr/bin/env python3
"""Prepare and evaluate a private, operator-observed native capture trial for #59 and #64."""
import argparse
from datetime import datetime, timedelta
import hashlib
import json
import math
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Tools"))
from Performance.budgets import evidence_file
from Streaming.report import distribution

PLATFORMS = {"Mac": "macOS", "iPhone": "iOS", "iPad": "iPadOS"}
ROUTES = ("built-in", "wired", "USB", "Bluetooth")
CASES = {
    "permission-denied": ("explicitRequest", "denialReported", "noCaptureOrAutomaticRetry"),
    "first-grant": ("idleBeforeUserAction", "explicitGrant", "effectiveInputObserved", "stopCompleted"),
    "pending-permission-stop": ("requestPending", "stoppedOrBackgrounded", "lateAnswerObserved", "noCaptureOrActivation"),
    "stop-restart": ("stopCompleted", "freshEpoch", "noOldResults"),
    "route-change": ("routeChangeObserved", "oldAdmissionClosed", "reportedDiscontinuity", "hostInitiatedRestart"),
    "interruption": ("interruptionObserved", "oldAdmissionClosed", "noAutomaticResume", "hostInitiatedRestart"),
    "sustained-foreground": ("foregroundThroughout", "lossAccounted", "boundedQueues", "stopCompleted"),
}
NO_CAPTURE_CASES = {"permission-denied", "pending-permission-stop"}
IOS_CASES = {"pending-permission-stop", "interruption"}
RESTART_CASES = {"stop-restart", "route-change", "interruption"}
THERMAL = {"nominal", "fair", "serious", "critical", "unavailable"}
LATENCIES = ("callbackDurationNS", "processingNS", "acousticEndToObservationNS")
RUN_FIELDS = (
    "recordedAtUTC", "commit", "deviceModel", "architecture", "osVersion", "osBuild", "xcodeBuild",
    "configuration", "operation", "profileID", "profileVersion", "diagnostics", "acquisitionScheduleID",
    "durationSeconds", "powerSource", "lowPowerMode", "profiler", "conditions",
)


def prepare(device, route, scenario):
    if device not in PLATFORMS or route not in ROUTES or scenario not in CASES:
        raise ValueError("Unknown device, route or scenario")
    if device == "Mac" and scenario in IOS_CASES:
        raise ValueError(f"{scenario} requires iPhone or iPad")
    return {
        "schemaVersion": 1, "deviceClass": device, "platform": PLATFORMS[device], "route": route,
        "scenario": scenario, "execution": "unmeasured", "deferredReason": "pending physical validation",
        "run": dict.fromkeys(RUN_FIELDS), "observations": dict.fromkeys(CASES[scenario]),
        "epochs": [], "resourceSamples": [], "latencies": {key: [] for key in LATENCIES},
        "energy": {"unit": None, "samples": [], "unavailableReason": "unmeasured"},
        "failures": [], "evidence": [],
    }


def require(condition, message):
    if not condition:
        raise ValueError(message)


def number(value, *, integer=False, positive=False):
    allowed = (int,) if integer else (int, float)
    return type(value) in allowed and math.isfinite(value) and (value > 0 if positive else value >= 0)


def label(value):
    return isinstance(value, str) and bool(value.strip())


def check_epochs(epochs, scenario, findings):
    require(isinstance(epochs, list), "epochs must be an array")
    ids = set()
    for epoch in epochs:
        key = epoch["epoch"]
        require(label(key) and key not in ids, "Missing or repeated capture epoch")
        ids.add(key)
        require(number(epoch["sampleRate"], positive=True) and number(epoch["channels"], integer=True, positive=True)
                and epoch["encoding"] in ("float32", "float64") and epoch["layout"] in ("interleaved", "planar"),
                "Invalid effective PCM format")
        for field in ("queueSlots", "maximumFramesPerChunk", "acceptedChunks", "drainedChunks",
                      "consumedFrames", "droppedFrames", "queueHighWater", "knownGapFrames", "unknownGaps",
                      "invalidChunks"):
            require(number(epoch[field], integer=True), f"Invalid epoch counter {field}")
        slots = epoch["queueSlots"]
        require(2 <= slots <= 4096 and slots.bit_count() == 1 and 0 < epoch["maximumFramesPerChunk"] <= 65536,
                "Invalid prepared capacity")
        require(type(epoch["producerContractViolated"]) is bool, "Missing producer contract observation")
        if epoch["producerContractViolated"] or epoch["invalidChunks"]:
            findings.append("capture producer contract or input format failed")
        if epoch["queueHighWater"] > epoch["queueSlots"]:
            findings.append("observed PCM depth exceeded capacity")
        if epoch["acceptedChunks"] != epoch["drainedChunks"]:
            findings.append("accepted and drained chunk counts differ at stop")
        chunks = epoch["drainedChunks"]
        if not chunks or not chunks <= epoch["consumedFrames"] <= chunks * epoch["maximumFramesPerChunk"]:
            findings.append("consumed frame count does not match the drained chunks")
        if epoch["droppedFrames"] > epoch["knownGapFrames"] and not epoch["unknownGaps"]:
            findings.append("dropped PCM missing from reported gaps")
        if any(epoch[k] for k in ("droppedFrames", "knownGapFrames", "unknownGaps")) and scenario not in (
                "route-change", "interruption"):
            findings.append("nominal capture lost input")
    if scenario in NO_CAPTURE_CASES and epochs:
        findings.append("operation unexpectedly opened a capture epoch")
    return ids


def resources(record, duration, findings):
    samples = record["resourceSamples"]
    require(isinstance(samples, list), "resourceSamples must be an array")
    capacities = {e["epoch"]: e["queueSlots"] for e in record["epochs"]}
    cpu = []
    for idx, row in enumerate(samples):
        require(row["epoch"] in capacities and number(row["elapsedSeconds"]) and row["elapsedSeconds"] <= duration
                and row["thermalState"] in THERMAL, "Invalid sample time, epoch or thermal observation")
        for key in ("processCPUSeconds", "residentBytes", "queueDepthSlots"):
            value = row.get(key)
            require(value is None or number(value, integer=key != "processCPUSeconds", positive=key == "residentBytes"),
                    f"Invalid {key} observation")
        depth = row.get("queueDepthSlots")
        if depth is not None and depth > capacities[row["epoch"]]:
            findings.append("sampled PCM depth exceeded capacity")
        if idx:
            previous = samples[idx - 1]
            elapsed = row["elapsedSeconds"] - previous["elapsedSeconds"]
            require(elapsed > 0, "Elapsed time must increase")
            if row.get("processCPUSeconds") is not None and previous.get("processCPUSeconds") is not None:
                delta = row["processCPUSeconds"] - previous["processCPUSeconds"]
                require(delta >= 0, "Cumulative process CPU cannot decrease")
                cpu.append(delta / elapsed)
    result = {}
    if samples:
        for key in ("residentBytes", "queueDepthSlots"):
            values = [row[key] for row in samples if row.get(key) is not None]
            if values:
                result[key] = distribution(values)
        result["thermalHistory"] = [[row["elapsedSeconds"], row["thermalState"]] for row in samples]
    if cpu:
        result["processCPUSecondsPerWallSecond"] = distribution(cpu)
    latency = record["latencies"]
    require(set(latency) == set(LATENCIES), "Unexpected latency measurement")
    for key, values in latency.items():
        require(isinstance(values, list) and all(number(v, integer=True) for v in values), f"Invalid {key} samples")
        if values:
            result[key] = distribution(values)
    energy = record["energy"]
    require(isinstance(energy["samples"], list) and all(number(v) for v in energy["samples"]), "Invalid energy samples")
    if energy["samples"]:
        require(label(energy["unit"]) and energy["unavailableReason"] is None, "Measured energy needs a unit")
        result["energy"] = {"unit": energy["unit"], **distribution(energy["samples"])}
    else:
        require(energy["unit"] is None and label(energy["unavailableReason"]), "State why energy was unavailable")
    return result


def evaluate(record, directory):
    device, route, scenario = (record[k] for k in ("deviceClass", "route", "scenario"))
    template = prepare(device, route, scenario)
    require(type(record["schemaVersion"]) is int and record["schemaVersion"] == 1
            and record["platform"] == template["platform"], "Unsupported schema or platform")
    output = {
        "schemaVersion": 1, "deviceClass": device, "platform": record["platform"], "route": route,
        "scenario": scenario, "coverage": "baseline" if device in ("Mac", "iPhone") and route == "built-in" else "optional",
        "functionalStatus": "deferred", "deviceFollowup": 74, "performanceQualificationIssue": 64,
    }
    if record["execution"] == "unmeasured":
        require(label(record["deferredReason"]), "A deferred trial needs its reason")
        return dict(output, reason=record["deferredReason"])
    require(record["execution"] == "physical" and record["deferredReason"] is None, "Identify actual physical execution")
    run = record["run"]
    require(set(run) == set(RUN_FIELDS), "Incomplete run configuration")
    for field in set(RUN_FIELDS) - {"durationSeconds", "lowPowerMode"}:
        require(label(run[field]), f"Missing run field {field}")
    require(re.fullmatch(r"[0-9a-f]{40}", run["commit"]), "A full measured Git revision is required")
    require(re.fullmatch(r"\d+(?:\.\d+){1,2}", run["osVersion"]) and int(run["osVersion"].split(".")[0]) >= 27,
            "Expected OS 27 or later")
    require(datetime.fromisoformat(run["recordedAtUTC"]).utcoffset() == timedelta(0), "Record a UTC observation time")
    require(run["configuration"] in ("debug", "release") and run["operation"] in ("capture-only", "live-analysis")
            and run["diagnostics"] in ("disabled", "sampled", "detailed")
            and (run["lowPowerMode"] is None or type(run["lowPowerMode"]) is bool)
            and number(run["durationSeconds"], positive=True), "Invalid build, operation, diagnostics, power or duration")
    require(isinstance(record["failures"], list) and all(label(v) for v in record["failures"]), "Invalid failure notes")
    findings = record["failures"].copy()
    observations = record["observations"]
    require(observations.keys() == template["observations"].keys()
            and all(v is None or type(v) is bool for v in observations.values()), "Invalid scenario observations")
    findings.extend(name for name, value in observations.items() if value is False)
    missing = [name for name, value in observations.items() if value is None]
    require(isinstance(record["evidence"], list), "evidence must be an array")
    native_epochs = []
    native_files = set()
    native_samples = []
    for item in record["evidence"]:
        require(item["kind"] in ("mac-capture-check", "operator-notes", "instrument-export"), "Unknown evidence kind")
        path = evidence_file(directory, item["file"], item["sha256"])
        if item["kind"] == "mac-capture-check":
            require(device == "Mac" and run["operation"] == "capture-only" and run["configuration"] == "release",
                    "Wrong scope for the release Mac capture fixture")
            require(path not in native_files, "Repeated Mac capture receipt")
            native_files.add(path)
            native = json.loads(path.read_bytes())
            require(native["schemaVersion"] == 1 and native["operation"] == "capture-only"
                    and native["status"] in ("running", "completed", "failed"), "Invalid native capture receipt")
            require(native["revision"] == run["commit"], "Mac capture fixture and declared revision differ")
            if native["sourceState"] != "clean":
                missing.append("reproducible Mac fixture build")
            if native["status"] == "running":
                missing.append("terminal Mac capture receipt")
            if native["status"] == "failed":
                expected = {"permission-denied": "microphone permission denied", "route-change": "input configuration changed"}
                if native.get("failure") != expected.get(scenario, ""):
                    findings.append("Mac capture fixture failed: " + str(native.get("failure", "unclassified")))
            if native["status"] == "completed":
                require(len(native["runs"]) == native["requestedRuns"] > 0, "Incomplete native run inventory")
            for epoch in native["runs"]:
                native_epochs.append({k: v for k, v in epoch.items() if k != "resourceSamples"})
                if scenario == "sustained-foreground":
                    require(len(native["runs"]) == 1 and len(native_files) == 1,
                            "Use one continuous native capture for sustained evidence")
                    native_samples = epoch["resourceSamples"]
                    if epoch["durationNS"] < 120_000_000_000:
                        missing.append("120 seconds of continuous native capture")
    if native_files:
        require(not record["epochs"], "Choose one source for capture epochs")
        record = dict(record, epochs=native_epochs)
        if native_samples:
            require(not record["resourceSamples"], "Choose one source for resource samples")
            record = dict(record, resourceSamples=native_samples)
    if not record["evidence"]:
        missing.append("local hashed observation artifact")
    epochs = check_epochs(record["epochs"], scenario, findings)
    if scenario not in NO_CAPTURE_CASES and len(epochs) < (2 if scenario in RESTART_CASES else 1):
        missing.append("required capture epochs")
    result = resources(record, run["durationSeconds"], findings)
    if scenario == "sustained-foreground":
        samples = record["resourceSamples"]
        def spans_trial(rows):
            return (len(rows) >= 3 and rows[0]["elapsedSeconds"] <= run["durationSeconds"] / 4
                    and rows[-1]["elapsedSeconds"] >= run["durationSeconds"] * 3 / 4
                    and any(run["durationSeconds"] / 4 < r["elapsedSeconds"] < run["durationSeconds"] * 3 / 4
                            for r in rows))
        if run["durationSeconds"] < 120 or len(epochs) != 1:
            missing.append("120 seconds of continuous foreground capture")
        for key in ("residentBytes", "queueDepthSlots", "processCPUSeconds"):
            if not spans_trial([r for r in samples if r.get(key) is not None]):
                missing.append(f"sustained {key} observations")
        if "processCPUSecondsPerWallSecond" not in result:
            missing.append("process CPU interval")
        needed = LATENCIES if run["operation"] == "live-analysis" else ("callbackDurationNS",)
        missing.extend(key for key in needed if key not in result)
    status = "failed" if findings else "deferred" if missing else "passed"
    return dict(output, functionalStatus=status, run=run, measurements=result, failures=findings,
                epochs=record["epochs"], observations=observations, missing=missing, evidence=record["evidence"],
                performanceBudget="evaluate separately for the measured scope")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="action", required=True)
    new = sub.add_parser("prepare", help="write an unmeasured physical trial form")
    new.add_argument("device", choices=PLATFORMS)
    new.add_argument("route", choices=ROUTES)
    new.add_argument("scenario", choices=CASES)
    new.add_argument("output", type=Path)
    check = sub.add_parser("evaluate", help="evaluate one form and print its receipt")
    check.add_argument("trial", type=Path)
    args = parser.parse_args()
    if args.action == "prepare":
        form = prepare(args.device, args.route, args.scenario)
        with args.output.open("x") as stream:
            json.dump(form, stream, indent=2)
            stream.write("\n")
        return 0
    raw = args.trial.read_bytes()
    receipt = evaluate(json.loads(raw), args.trial.parent)
    receipt["trialSHA256"] = hashlib.sha256(raw).hexdigest()
    print(json.dumps(receipt, indent=2, allow_nan=False))
    return {"passed": 0, "failed": 1, "deferred": 2}[receipt["functionalStatus"]]


if __name__ == "__main__":
    sys.exit(main())
