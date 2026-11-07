#!/usr/bin/env python3
"""Retain controlled worker/delivery overload evidence, never hardware latency claims."""
import hashlib
import json
import math
from pathlib import Path
import re
import shutil
import statistics
import subprocess
import sys
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Tools"))
import ci

MARKER = "CAPTURE_DELIVERY_TRIALS "
SCOPE = "controlled synthetic producer, real serial analysis worker and bounded delivery bridge; no native capture/session operation"
PROFILES = ("levels", "full")
MODES = ("disabled", "sampled", "detailed")
PATTERNS = ("display-coalescing", "pcm-overload")
FIXED = {"sampleRate": 44100, "chunkFrames": 2048, "slotCount": 4, "bursts": 16,
         "acceptedChunks": 64, "pcmHighWaterSlots": 4, "unknownExtentGaps": 0,
         "fastCoalesced": 0, "slowDelivered": 5, "slowHighWater": 1,
         "strictDelivered": 8, "strictRejected": 1, "strictHighWater": 8,
         "strictErrors": 1, "completions": 1, "activeSubscribersAfterFinish": 0}
TEXT = {"profile", "mode", "pattern", "profileSHA256", "scientificSHA256"}
ARRAYS = {"publicationNanoseconds", "fastSubscriberLagNanoseconds", "slowSubscriberLagNanoseconds", "drains"}
FIELDS = {*TEXT, *ARRAYS, *FIXED, "trial", "offeredChunks", "overflowChunks", "droppedPCMFrames",
          "emittedFrames", "availableCPPSEstimates", "gapEvents", "knownMissingFrames", "resets",
          "publications", "fastDelivered", "slowCoalesced", "processingSamples", "captureLatencySamples",
          "publicationLatencySamples", "workerCallTotalNanoseconds", "publicationTotalNanoseconds"}
RAW_BASE = {"pcmDepthBefore", "pcmDepthAfter", "dequeuedBlocks", "emittedResults", "consumedSourceFrames",
            "cumulativeDroppedFrames", "slowBufferedResults", "workerCallNanoseconds"}
RAW_OPTIONAL = {"processingNanoseconds", "captureBlockStartToWorkerNanoseconds",
                "workerToPublicationNanoseconds", "blockStampToFirstResultNanoseconds"}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def uint(value):
    return type(value) is int and 0 <= value <= 2**64 - 1


def distribution(values, unit="nanoseconds"):
    ordered = sorted(values)
    if not ordered:
        return {"unit": unit, "sampleCount": 0}
    return {"unit": unit, "sampleCount": len(ordered), "minimum": ordered[0], "maximum": ordered[-1],
            "mean": statistics.mean(ordered),
            **{f"p{p}": ordered[math.ceil(p / 100 * len(ordered)) - 1] for p in (50, 95, 99)}}


def validate_trials(rows):
    expected = {(p, m, s, t) for p in PROFILES for m in MODES for s in PATTERNS for t in range(3)}
    require(isinstance(rows, list) and len(rows) == 36, "Expected all 36 delivery trials")
    found, profiles, science, groups, indexed = set(), {}, {}, {}, {}
    for row in rows:
        require(isinstance(row, dict) and set(row) == FIELDS, "Unexpected or missing delivery fields")
        require(all(uint(row[k]) for k in FIELDS - TEXT - ARRAYS), "Invalid delivery count/duration")
        key = tuple(row[k] for k in ("profile", "mode", "pattern", "trial"))
        require(key in expected and key not in found, "Unexpected or duplicate delivery trial")
        found.add(key)
        indexed[key] = row
        require(all(row[k] == v for k, v in FIXED.items()), "Delivery functional/resource gate failed")
        for field in ("profileSHA256", "scientificSHA256"):
            require(isinstance(row[field], str) and re.fullmatch(r"[0-9a-f]{64}", row[field]), "Invalid evidence digest")
        profile_key = row["profile"]
        require(profiles.setdefault(profile_key, row["profileSHA256"]) == row["profileSHA256"], "Profile changed between modes/patterns")
        science_key = (profile_key, row["pattern"])
        fingerprint = (row["scientificSHA256"], row["emittedFrames"], row["availableCPPSEstimates"])
        require(science.setdefault(science_key, fingerprint) == fingerprint, "Diagnostics changed numerical output or workload")
        overload = row["pattern"] == "pcm-overload"
        enabled = row["mode"] != "disabled"
        drains = 80 if overload else 65
        dropped = 64 * 2048 if overload else 0
        require(row["offeredChunks"] == (128 if overload else 64), "Wrong producer workload")
        require(row["overflowChunks"] == (64 if overload else 0), "Missing sustained PCM overflow")
        require(row["droppedPCMFrames"] == row["knownMissingFrames"] == dropped, "Lost PCM metadata")
        require(row["gapEvents"] == (16 if overload else 0) and row["resets"] == (15 if overload else 0), "Missing gap/reset events")
        require(64 < row["emittedFrames"] < 20_000, "Missing or unbounded metric workload")
        require(0 < row["availableCPPSEstimates"] <= row["emittedFrames"] if profile_key == "full"
                else row["availableCPPSEstimates"] == 0, "Full recipe did not produce available CPPS")
        require(row["publications"] == row["emittedFrames"] + (51 if overload else 5), "Missing control events or metric publications")
        require(row["fastDelivered"] == row["publications"], "Fast consumer lost results")
        require(row["slowCoalesced"] + row["slowDelivered"] == row["publications"] and row["slowCoalesced"] > 0,
                "Coalescing is not accounted independently")
        require(row["processingSamples"] == row["publicationLatencySamples"] == (drains if enabled else 0), "Missing processing/publication timing coverage")
        require(row["captureLatencySamples"] == (64 if enabled else 0), "Missing capture timing coverage")
        for field, count in (("publicationNanoseconds", row["publications"]),
                             ("fastSubscriberLagNanoseconds", row["publications"]),
                             ("slowSubscriberLagNanoseconds", 5)):
            require(isinstance(row[field], list) and len(row[field]) == count and all(uint(v) for v in row[field]), "Invalid raw delivery timing")
        raw = row["drains"]
        require(isinstance(raw, list) and len(raw) == drains, "Missing worker drain observations")
        for observation in raw:
            require(isinstance(observation, dict) and RAW_BASE <= set(observation) <= RAW_BASE | RAW_OPTIONAL, "Unexpected/private raw fields")
            require(all(uint(v) for v in observation.values()), "Invalid raw observation value")
            blocks = observation["dequeuedBlocks"]
            require(blocks in (0, 1), "A worker drain exceeded one block")
            optional = ({"processingNanoseconds", "workerToPublicationNanoseconds"} if enabled else set())
            if blocks:
                optional.add("blockStampToFirstResultNanoseconds")
                if enabled:
                    optional.add("captureBlockStartToWorkerNanoseconds")
            require(set(observation) == RAW_BASE | optional, "Unknown/disabled timing became a fabricated value")
            require(0 <= observation["pcmDepthAfter"] <= observation["pcmDepthBefore"] <= 4, "Invalid PCM queue observation")
            require(observation["pcmDepthBefore"] - observation["pcmDepthAfter"] == blocks, "Queue did not retire the reported block")
            require(observation["consumedSourceFrames"] == blocks * 2048, "Wrong source consumption")
            require(0 < observation["emittedResults"] <= 256 and observation["slowBufferedResults"] == 1, "Unbounded or missing result batch")
            require(0 < observation["workerCallNanoseconds"], "Missing full worker call measurement")
            require(observation["cumulativeDroppedFrames"] <= dropped, "Invalid cumulative PCM loss")
            if enabled:
                require(observation["processingNanoseconds"] <= observation["workerCallNanoseconds"], "Processing interval exceeds enclosing call")
                if blocks:
                    require(observation["captureBlockStartToWorkerNanoseconds"] <= observation["blockStampToFirstResultNanoseconds"], "Clock boundaries are reversed")
        require(sum(r["dequeuedBlocks"] for r in raw) == 64, "Missing accepted blocks")
        require(sum(r["emittedResults"] for r in raw) + 4 == row["publications"], "Worker/publication inventory differs")
        drops = [r["cumulativeDroppedFrames"] for r in raw]
        require(drops == sorted(drops) and set(drops) == ({8192 * i for i in range(1, 17)} if overload else {0}), "Overload was not sustained across all bursts")
        require(row["workerCallTotalNanoseconds"] == sum(r["workerCallNanoseconds"] for r in raw), "Worker total differs from raw trials")
        require(row["publicationTotalNanoseconds"] == sum(row["publicationNanoseconds"]) > 0, "Publication total differs from raw trials")
        groups.setdefault("/".join(key[:3]), []).append(row)
    require(found == expected and len(set(profiles.values())) == 2 and len({s[0] for s in science.values()}) == 4, "Incomplete profile/scenario coverage")
    summaries = {}
    for name, trials in sorted(groups.items()):
        raw = [r for t in trials for r in t["drains"]]
        summaries[name] = {key: distribution([r[key] for r in raw if key in r])
                           for key in ("workerCallNanoseconds", *sorted(RAW_OPTIONAL))}
        summaries[name].update({key: distribution([v for t in trials for v in t[key]])
                                for key in ("publicationNanoseconds", "fastSubscriberLagNanoseconds", "slowSubscriberLagNanoseconds")})
        summaries[name].update({key: distribution([r[key] for r in raw], "slots" if key.startswith("pcm") else "publications")
                                for key in ("pcmDepthBefore", "pcmDepthAfter", "slowBufferedResults")})
    paired = {}
    for profile in PROFILES:
        for pattern in PATTERNS:
            for mode in MODES[1:]:
                paired[f"{profile}/{pattern}/{mode}-minus-disabled"] = {
                    field: [indexed[(profile, mode, pattern, trial)][field] - indexed[(profile, "disabled", pattern, trial)][field]
                            for trial in range(3)]
                    for field in ("workerCallTotalNanoseconds", "publicationTotalNanoseconds")}
    return {"quantileMethod": "nearest rank", "groups": summaries, "pairedModeDifferencesNanoseconds": paired,
            "interpretation": "three repetitions with rotated mode order and fresh workers; preparation and consumer verification outside worker-call/publication timings; no universal duration threshold",
            "clockScope": "synthetic producer block-stamp to first result observation, not acoustic support or physical capture/display latency"}


def parse_trials(log):
    records = [line.removeprefix(MARKER) for line in log.splitlines() if line.startswith(MARKER)]
    require(len(records) == 1, "Expected exactly one fresh delivery record")
    rows = json.loads(records[0])
    validate_trials(rows)
    return rows


def validate_test_reports(output, reports):
    require(len(reports) == 1 and reports[0]["testCases"] == 1, "Expected one delivery evidence test")
    root = ET.parse(output / reports[0]["file"]).getroot()
    cases = root.findall(".//testcase")
    require(len(cases) == 1 and cases[0].get("classname") == "HDXLVoiceProcessingAudioTests"
            and cases[0].get("name") == "captureDeliveryEvidenceTrials()", "Wrong delivery test identity")
    require(not any(root.findall(".//" + tag) for tag in ("failure", "error", "skipped")), "Delivery evidence did not pass")


def main():
    output = ROOT / ".build/capture-delivery-evidence"
    if output.exists():
        shutil.rmtree(output)
    output.mkdir(parents=True)
    result = {"schemaVersion": 1, "status": "failed", "commands": [], "scope": SCOPE,
              "physicalEvidence": "pending #74; synthetic block stamps are not hardware latency measurements"}
    try:
        environment = ci.environment("release")
        ci.validate_environment(environment, json.loads((ROOT / "Configuration/build.json").read_text()))
        environment.update(execution=SCOPE, clock="DispatchTime uptimeNanoseconds", producer="sixteen controlled bursts, no native callback",
                           consumers="fast strict capacity1, display newest capacity1 every fourth burst, stalled strict capacity8")
        (output / "environment.json").write_text(ci.redact(json.dumps(environment, indent=2)) + "\n")
        command = ["swift", "test", "--configuration", "release", "--scratch-path", ".build/capture-delivery",
                   "--filter", "captureDeliveryEvidenceTrials", "--xunit-output", str(output / "tests.xml")]
        with (output / "commands.log").open("w") as log:
            ci.run_command(command, log, result["commands"])
        reports = ci.test_reports(output)
        validate_test_reports(output, reports)
        rows = parse_trials((output / "commands.log").read_text())
        summary = validate_trials(rows)
        (output / "trials.json").write_text(json.dumps(rows, indent=2, allow_nan=False) + "\n")
        (output / "distributions.json").write_text(json.dumps(summary, indent=2, allow_nan=False) + "\n")
        sources = ["Package.swift", "Configuration/build.json", "Tools/Capture/delivery.py",
                   "Tools/Tests/test_capture_delivery.py", "Tests/HDXLVoiceProcessingAudioTests/CaptureDeliveryEvidenceTests.swift",
                   *[str(p.relative_to(ROOT)) for folder in ("HDXLVoiceProcessing", "HDXLVoiceProcessingAudio")
                     for p in sorted((ROOT / "Sources" / folder).rglob("*.swift"))]]
        result.update(status="passed", trialCount=36, configurationCount=12, testReports=reports,
                      sourceSHA256={s: hashlib.sha256((ROOT / s).read_bytes()).hexdigest() for s in sources})
        for report in output.glob("*.xml"):
            ci.redact_report(report)
    except (OSError, ValueError, KeyError, TypeError, RuntimeError, subprocess.SubprocessError, ET.ParseError) as error:
        result["error"] = ci.redact(str(error))
        print(result["error"], file=sys.stderr)
    (output / "result.json").write_text(json.dumps(result, indent=2, allow_nan=False) + "\n")
    return 0 if result["status"] == "passed" else 1


if __name__ == "__main__":
    sys.exit(main())
