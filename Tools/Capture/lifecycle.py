#!/usr/bin/env python3
"""Retain synthetic lifecycle timing/reclamation trials, never hardware acceptance."""
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

MARKER = "LIFECYCLE_RESOURCE_TRIALS "
PHASES = ("initialStartNanoseconds", "interruptionRetirementNanoseconds",
          "resumeStartNanoseconds", "explicitStopRetirementNanoseconds")
FIXED = {"sampleRate": 8000, "sourceTileCapacity": 4, "maximumResultEvents": 256,
         "retiredTransfers": 2, "releasedObservers": 2, "completedOperations": 2,
         "deliveredFrames": 16, "failures": 0, "epochAdvance": 1}
FIELDS = {"encoding", "channels", "maximumFramesPerChunk", "slotCount", "trial",
          "profileSHA256", "captureStorageBytes", *PHASES, *FIXED}
SCOPE = "synthetic capture driver and real serial level-analysis worker; no native capture/session operation"


def validate_trials(rows):
    expected = {(e, c, frames, slots, trial) for e in ("float32", "float64") for c in (1, 2)
                for frames, slots in ((64, 4), (8192, 16)) for trial in range(10)}
    if not isinstance(rows, list) or len(rows) != len(expected):
        raise ValueError("Expected all 80 lifecycle trials")
    found, profiles, groups = set(), {}, {}
    for row in rows:
        if not isinstance(row, dict) or set(row) != FIELDS:
            raise ValueError("Unexpected/missing fields in lifecycle evidence")
        numeric = FIELDS - {"encoding", "profileSHA256"}
        if any(type(row[k]) is not int for k in numeric):
            raise ValueError("Lifecycle counts/durations must be integers, not booleans or floats")
        key = tuple(row[k] for k in ("encoding", "channels", "maximumFramesPerChunk", "slotCount", "trial"))
        if key not in expected or key in found:
            raise ValueError("Unexpected/duplicate lifecycle trial identity")
        found.add(key)
        if any(row[k] != v for k, v in FIXED.items()):
            raise ValueError("Lifecycle functional or resource-retirement gate failed")
        if any(not 0 < row[k] <= 2**64 - 1 for k in PHASES):
            raise ValueError("Missing positive monotonic duration")
        width = 4 if row["encoding"] == "float32" else 8
        if row["captureStorageBytes"] != row["channels"] * row["maximumFramesPerChunk"] * row["slotCount"] * width:
            raise ValueError("PCM capacity does not match declared storage")
        profile = row["profileSHA256"]
        if not isinstance(profile, str) or not re.fullmatch(r"[0-9a-f]{64}", profile):
            raise ValueError("Invalid numerical profile identity")
        profile_key = key[:2]
        if profile_key in profiles and profiles[profile_key] != profile:
            raise ValueError("Numerical recipe changed between repetitions or buffer capacities")
        profiles[profile_key] = profile
        name = f"{key[0]}-c{key[1]}-n{key[2]}-slots{key[3]}"
        groups.setdefault(name, []).append(row)
    if found != expected or len(set(profiles.values())) != 4:
        raise ValueError("Missing lifecycle coverage or indistinguishable format profiles")
    summaries = {}
    for name, trials in sorted(groups.items()):
        phases = {}
        for phase in PHASES:
            samples = sorted(row[phase] for row in trials)
            phases[phase] = {"sampleCount": len(samples), "minimum": samples[0],
                             "maximum": samples[-1], "mean": statistics.mean(samples),
                             **{f"p{p}": samples[math.ceil(p / 100 * len(samples)) - 1] for p in (50, 95, 99)}}
        summaries[name] = phases
    return {"unit": "nanoseconds", "quantileMethod": "nearest rank", "groups": summaries,
            "interpretation": "ten sequential trials per configuration, including the first; process already initialized; no universal duration threshold"}


def parse_trials(log):
    matches = [line.removeprefix(MARKER) for line in log.splitlines() if line.startswith(MARKER)]
    if len(matches) != 1:
        raise ValueError("Expected exactly one fresh lifecycle trial record")
    rows = json.loads(matches[0])
    validate_trials(rows)
    return rows


def validate_test_reports(output, reports):
    if len(reports) != 1 or reports[0]["testCases"] != 1:
        raise ValueError("Expected one executed lifecycle resource test")
    root = ET.parse(output / reports[0]["file"]).getroot()
    cases = root.findall(".//testcase")
    if len(cases) != 1 or cases[0].get("classname") != "HDXLVoiceProcessingAudioTests" or cases[0].get("name") != "lifecycleResourceTrials()":
        raise ValueError("Wrong lifecycle probe test identity")
    if any(root.findall(".//" + tag) for tag in ("failure", "error", "skipped")):
        raise ValueError("Lifecycle probe did not pass completely")


def main():
    output = ROOT / ".build/capture-lifecycle-evidence"
    if output.exists():
        shutil.rmtree(output)
    output.mkdir(parents=True)
    result = {"schemaVersion": 1, "status": "failed", "commands": [], "scope": SCOPE,
              "physicalEvidence": "pending #74; injected lifecycle timings cannot qualify native hardware recovery"}
    try:
        environment = ci.environment("release")
        ci.validate_environment(environment, json.loads((ROOT / "Configuration/build.json").read_text()))
        environment.update(execution=SCOPE, clock="DispatchTime uptimeNanoseconds",
                           processing="level analysis outside timed phases; setup includes worker preparation",
                           retirement="weak transfer references cleared, fake observer callbacks released, native adapter retirement separately tested")
        (output / "environment.json").write_text(ci.redact(json.dumps(environment, indent=2)) + "\n")
        command = ["swift", "test", "--configuration", "release", "--scratch-path", ".build/capture-lifecycle",
                   "--filter", "lifecycleResourceTrials", "--xunit-output", str(output / "tests.xml")]
        with (output / "commands.log").open("w") as log:
            ci.run_command(command, log, result["commands"])
        reports = ci.test_reports(output)
        validate_test_reports(output, reports)
        rows = parse_trials((output / "commands.log").read_text())
        summary = validate_trials(rows)
        (output / "trials.json").write_text(json.dumps(rows, indent=2, allow_nan=False) + "\n")
        (output / "distributions.json").write_text(json.dumps(summary, indent=2, allow_nan=False) + "\n")
        sources = ["Tools/Capture/lifecycle.py", "Tests/HDXLVoiceProcessingAudioTests/CaptureLifecycleTests.swift",
                   *[str(p.relative_to(ROOT)) for p in sorted((ROOT / "Sources/HDXLVoiceProcessingAudio").glob("*.swift"))]]
        result.update(status="passed", trialCount=len(rows), configurationCount=len(summary["groups"]),
                      retiredTransfers=sum(row["retiredTransfers"] for row in rows), testReports=reports,
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
