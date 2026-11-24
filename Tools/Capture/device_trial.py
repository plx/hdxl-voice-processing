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
    affected = []
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
        width = 4 if epoch["encoding"] == "float32" else 8
        require(epoch["channels"] <= 32 and slots * epoch["maximumFramesPerChunk"] * epoch["channels"] * width
                <= 64 * 1024 * 1024, "Prepared PCM exceeds native channel or storage limit")
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
        boundary = epoch.get("boundary")
        require(boundary is None or boundary in ("route-change", "interruption"), "Invalid epoch boundary")
        if boundary is not None:
            require(boundary == scenario, "Observed epoch boundary differs from the scenario")
            affected.append(key)
        elif any(epoch[k] for k in ("droppedFrames", "knownGapFrames", "unknownGaps")):
            findings.append("nominal capture lost input")
    if scenario in NO_CAPTURE_CASES and epochs:
        findings.append("operation unexpectedly opened a capture epoch")
    return ids, affected


def resources(record, duration, findings):
    samples = record["resourceSamples"]
    require(isinstance(samples, list), "resourceSamples must be an array")
    capacities = {e["epoch"]: e["queueSlots"] for e in record["epochs"]}
    totals = {e["epoch"]: e["acceptedChunks"] for e in record["epochs"]}
    prior_chunks = {}
    cpu = []
    for idx, row in enumerate(samples):
        require(row["epoch"] in capacities and number(row["elapsedSeconds"]) and row["elapsedSeconds"] <= duration
                and row["thermalState"] in THERMAL, "Invalid sample time, epoch or thermal observation")
        for key in ("processCPUSeconds", "residentBytes", "queueDepthSlots"):
            value = row.get(key)
            require(value is None or number(value, integer=key != "processCPUSeconds", positive=key == "residentBytes"),
                    f"Invalid {key} observation")
        progress = row.get("acceptedChunks")
        if progress is not None:
            require(number(progress, integer=True), "Invalid sampled accepted chunk count")
            if not prior_chunks.get(row["epoch"], 0) <= progress <= totals[row["epoch"]]:
                findings.append("sampled accepted chunks contradict the epoch totals")
            prior_chunks[row["epoch"]] = progress
        depth = row.get("queueDepthSlots")
        if depth is not None and depth > capacities[row["epoch"]]:
            findings.append("sampled PCM depth exceeded capacity")
        if idx:
            previous = samples[idx - 1]
            elapsed = row["elapsedSeconds"] - previous["elapsedSeconds"]
            require(elapsed > 0, "Elapsed time must increase")
            if (row["epoch"] == previous["epoch"] and row.get("processCPUSeconds") is not None
                    and previous.get("processCPUSeconds") is not None):
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


def import_native(record, directory, missing, findings):
    device, scenario, run = record["deviceClass"], record["scenario"], record["run"]
    native_epochs = []
    native_samples = []
    native_files = set()
    saw_restart = False
    changed_at = []
    successful_starts = []
    previous_stop = None
    boot_sessions = []
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
            boot = native.get("bootSession")
            require(boot is None or (label(boot) and re.fullmatch(
                r"[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}", boot)), "Invalid native boot identity")
            boot_sessions.append(boot)
            if native["sourceState"] != "clean":
                missing.append("reproducible Mac fixture build")
            if native["status"] == "running":
                missing.append("terminal Mac capture receipt")
            if native["status"] == "failed":
                expected = {"permission-denied": "microphone permission denied", "route-change": "input configuration changed"}
                if scenario not in expected or native.get("failure") != expected[scenario]:
                    findings.append("Mac capture fixture failed: " + str(native.get("failure", "unclassified")))
            if native["status"] == "completed":
                require(len(native["runs"]) == native["requestedRuns"] > 0, "Incomplete native run inventory")
                if len(native["runs"]) >= 2:
                    saw_restart = True
            for epoch in native["runs"]:
                start, stop = epoch["startedUptimeNS"], epoch["stoppedUptimeNS"]
                require(number(start, integer=True) and number(stop, integer=True) and start < stop
                        and stop - start == epoch["durationNS"] and (previous_stop is None or start > previous_stop),
                        "Native epochs must be in order on the same monotonic clock")
                previous_stop = stop
                require(type(epoch["inputChanged"]) is bool, "Missing native configuration observation")
                if epoch["inputChanged"]:
                    changed_at.append(stop)
                elif native["status"] == "completed":
                    successful_starts.append(start)
                require(isinstance(epoch["resourceSamples"], list)
                        and all(r["epoch"] == epoch["epoch"] and number(r["uptimeNS"], integer=True)
                                and r["uptimeNS"] >= start for r in epoch["resourceSamples"]),
                        "Invalid native epoch sample")
                native_samples.extend(epoch["resourceSamples"])
                observed = {k: v for k, v in epoch.items() if k != "resourceSamples"}
                observed["boundary"] = "route-change" if epoch["inputChanged"] and scenario == "route-change" else None
                native_epochs.append(observed)
    if not native_files:
        if device == "Mac" and run["operation"] == "capture-only":
            missing.append("native Mac capture receipt")
        return record
    if len(native_files) > 1:
        if None in boot_sessions:
            missing.append("shared boot identity for native Mac receipts")
        if len(set(boot_sessions) - {None}) > 1:
            findings.append("native Mac receipts came from different boots")
    if scenario == "stop-restart" and not saw_restart:
        missing.append("two completed capture epochs on the same Mac owner")
    if scenario == "route-change" and (not changed_at or not any(s > max(changed_at) for s in successful_starts)):
        missing.append("native configuration boundary followed by a successful explicit start")
    require(not record["epochs"] and not record["resourceSamples"], "Choose one source for native capture readings")
    return dict(record, epochs=native_epochs, resourceSamples=native_samples)


def align_samples(samples):
    """Join development-host exports across Starts and launches on the same boot clock."""
    require(isinstance(samples, list), "resourceSamples must be an array")
    if not samples or not any("uptimeNS" in r for r in samples):
        return samples
    require(all(number(r.get("uptimeNS"), integer=True) for r in samples), "Cannot mix resource time bases")
    origin = samples[0]["uptimeNS"]
    return [dict(row, elapsedSeconds=(row["uptimeNS"] - origin) / 1e9) for row in samples]


def sustained(record, result, missing, findings):
    run = record["run"]
    if len(record["epochs"]) != 1:
        missing.append("one continuous foreground capture")
        return
    epoch = record["epochs"][0]
    measured = epoch.get("durationNS")
    if measured is None:
        missing.append("observed capture interval")
        return
    require(number(measured, integer=True, positive=True), "Invalid capture interval")
    seconds = measured / 1e9
    if run["durationSeconds"] < seconds:
        findings.append("declared trial duration is shorter than capture")
    if seconds < 120:
        missing.append("120 seconds of continuous capture")
    tolerance = min(0.25, 2 * epoch["maximumFramesPerChunk"] / epoch["sampleRate"])
    if abs(epoch["consumedFrames"] / epoch["sampleRate"] - seconds) > tolerance:
        findings.append("delivered audio duration differs from the capture interval")
    samples = record["resourceSamples"]

    def spans_capture(rows):
        return (len(rows) >= 3 and rows[0]["elapsedSeconds"] <= seconds / 4
                and rows[-1]["elapsedSeconds"] >= seconds * 3 / 4
                and any(seconds / 4 < r["elapsedSeconds"] < seconds * 3 / 4 for r in rows))

    for key in ("residentBytes", "queueDepthSlots", "processCPUSeconds", "acceptedChunks"):
        if not spans_capture([r for r in samples if r.get(key) is not None]):
            missing.append(f"sustained {key} observations")
    progress = [r for r in samples if r.get("acceptedChunks") is not None]
    for previous, row in zip(progress, progress[1:]):
        elapsed = min(seconds, row["elapsedSeconds"]) - previous["elapsedSeconds"]
        if elapsed > tolerance and row["acceptedChunks"] == previous["acceptedChunks"]:
            findings.append("capture stalled between resource observations")
            break
    for row in samples:
        stall = row.get("longestObservedStallNS")
        if stall is not None:
            require(number(stall, integer=True), "Invalid observed admission stall")
            if stall / 1e9 > tolerance:
                findings.append("capture stalled before thinning resource history")
                break
    if "processCPUSecondsPerWallSecond" not in result:
        missing.append("process CPU interval")
    needed = LATENCIES if run["operation"] == "live-analysis" else ("callbackDurationNS",)
    missing.extend(key for key in needed if key not in result)


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
    record = import_native(record, directory, missing, findings)
    record = dict(record, resourceSamples=align_samples(record["resourceSamples"]))
    if not record["evidence"]:
        missing.append("local hashed observation artifact")
    epochs, affected = check_epochs(record["epochs"], scenario, findings)
    if scenario in ("route-change", "interruption") and (not affected or record["epochs"][-1]["epoch"] in affected):
        missing.append("observed boundary followed by a new unaffected epoch")
    if scenario not in NO_CAPTURE_CASES and len(epochs) < (2 if scenario in RESTART_CASES else 1):
        missing.append("required capture epochs")
    result = resources(record, run["durationSeconds"], findings)
    if scenario == "sustained-foreground":
        sustained(record, result, missing, findings)
    status = "failed" if findings else "deferred" if missing else "passed"
    return dict(output, functionalStatus=status, run=run, measurements=result, failures=findings,
                epochs=record["epochs"], resourceSamples=record["resourceSamples"], observations=observations, missing=missing, evidence=record["evidence"],
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
