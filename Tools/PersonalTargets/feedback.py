#!/usr/bin/env python3
"""Measure deterministic feedback and bounded observers using synthetic summaries."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import re
import statistics
import subprocess
import sys
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Tools"))
import ci

MARKER = "PERSONAL_FEEDBACK_EVIDENCE "
RATES = (4, 40, 1000)
MODES = ("disabled", "sampled", "detailed")
TEXT = {"mode", "targetSHA256", "configurationSHA256", "outputSHA256", "finalState"}
COUNTS = {"rateHz", "subscribers", "trial", "sourceSamples", "qualifiedSamples", "matchingSamples",
          "acceptedIntervals", "stateChanges", "fastDelivered", "fastHighWater", "strictDelivered",
          "strictHighWater", "strictErrors", "displayDelivered", "displayCoalesced", "displayHighWater",
          "activeAfterFinish"}
SCOPE = "fabricated complete summaries, deterministic virtual source clock, real feedback policy and bounded subscriptions; no DSP, native capture, hardware or human validation"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def uint(value):
    return type(value) is int and 0 <= value < 2**64


def durations(values):
    require(isinstance(values, list) and len(values) == 256 and all(uint(x) and x > 0 for x in values),
            "Missing or invalid raw timing observations")


def distribution(values):
    ordered = sorted(values)
    return {"unit": "nanoseconds", "count": len(ordered), "minimum": min(ordered), "maximum": max(ordered),
            "mean": statistics.mean(ordered),
            **{f"p{p}": ordered[math.ceil(p / 100 * len(ordered)) - 1] for p in (50, 95, 99)}}


def validate_report(report):
    require(isinstance(report, dict) and set(report) == {"preparations", "trials"}, "Unexpected feedback evidence fields")
    preparations = report["preparations"]
    require(isinstance(preparations, list) and len(preparations) == 3, "Missing preparation measurements")
    seen = set()
    for item in preparations:
        require(isinstance(item, dict) and set(item) == {"rateHz", "nanoseconds"}, "Unexpected preparation fields")
        rate = item["rateHz"]
        require(uint(rate) and rate in RATES and rate not in seen, "Duplicate or unknown preparation rate")
        seen.add(rate)
        durations(item["nanoseconds"])
    rows = report["trials"]
    require(isinstance(rows, list) and len(rows) == 54, "Expected all 54 feedback trials")
    expected = {(rate, subscribers, mode, trial) for rate in RATES for subscribers in (0, 64)
                for mode in MODES for trial in range(3)}
    indexed, fingerprints, groups = {}, {}, {}
    target = configuration = None
    for row in rows:
        require(isinstance(row, dict) and set(row) == TEXT | COUNTS | {"updateNanoseconds"}, "Unexpected/private trial fields")
        require(all(uint(row[k]) for k in COUNTS) and all(isinstance(row[k], str) for k in TEXT), "Invalid feedback count or text")
        key = (row["rateHz"], row["subscribers"], row["mode"], row["trial"])
        require(key in expected and key not in indexed, "Unexpected or duplicate feedback trial")
        indexed[key] = row
        for field in ("targetSHA256", "configurationSHA256", "outputSHA256"):
            require(re.fullmatch(r"[0-9a-f]{64}", row[field]), "Invalid feedback digest")
        target = target or row["targetSHA256"]
        configuration = configuration or row["configurationSHA256"]
        require(row["targetSHA256"] == target and row["configurationSHA256"] == configuration, "Model or policy changed between trials")
        fingerprint = (row["outputSHA256"], row["stateChanges"])
        require(fingerprints.setdefault(key[0], fingerprint) == fingerprint, "Diagnostics or observers changed feedback")
        samples = 256 * (16000 // key[0])
        require(row["sourceSamples"] == row["qualifiedSamples"] == samples
                and row["matchingSamples"] == samples // 2 and row["acceptedIntervals"] == 256,
                "Incomplete source/summary coverage")
        require(4 <= row["stateChanges"] <= 20 and row["finalState"] == "departedTarget", "Missing policy transitions")
        require(row["activeAfterFinish"] == 0, "Observers survived termination")
        many = key[1] == 64
        expected_delivery = {"fastDelivered": 258, "fastHighWater": 1,
            "strictDelivered": 4, "strictHighWater": 4, "strictErrors": 1,
            "displayDelivered": 62, "displayCoalesced": 62 * 257, "displayHighWater": 1}
        require(all(row[k] == (v if many else 0) for k, v in expected_delivery.items()),
                "Observer delivery, overflow or resource bound differs")
        durations(row["updateNanoseconds"])
        groups.setdefault(f"{key[0]}Hz/{key[1]}-observers/{key[2]}", []).extend(row["updateNanoseconds"])
    require(set(indexed) == expected and len({v[0] for v in fingerprints.values()}) == 3,
            "Incomplete rate/observer/mode coverage")
    paired = {}
    for rate in RATES:
        for subscribers in (0, 64):
            for mode in MODES[1:]:
                paired[f"{rate}Hz/{subscribers}-observers/{mode}-minus-disabled"] = [
                    sum(indexed[(rate, subscribers, mode, trial)]["updateNanoseconds"])
                    - sum(indexed[(rate, subscribers, "disabled", trial)]["updateNanoseconds"])
                    for trial in range(3)]
    return {"quantileMethod": "nearest rank", "updateGroups": {k: distribution(v) for k, v in sorted(groups.items())},
            "preparationGroups": {str(p["rateHz"]): distribution(p["nanoseconds"]) for p in preparations},
            "pairedModeTotalDifferencesNanoseconds": paired,
            "interpretation": "Three repetitions with rotated mode/observer order; preparation measured once per rate outside updates. Timed update includes policy, snapshot construction and publication. Consumer drains, assertions, encoding and hashing are outside timings. Rates are virtual source cadences, not paced hardware deadlines. No universal time threshold."}


def parse_report(log):
    records = [line.removeprefix(MARKER) for line in log.splitlines() if line.startswith(MARKER)]
    require(len(records) == 1, "Expected exactly one fresh feedback evidence record")
    report = json.loads(records[0])
    validate_report(report)
    return report


def validate_test_reports(output, reports):
    require(len(reports) == 1 and reports[0]["testCases"] == 1, "Expected one feedback evidence test")
    root = ET.parse(output / reports[0]["file"]).getroot()
    cases = root.findall(".//testcase")
    require(len(cases) == 1 and cases[0].get("classname") == "HDXLVoiceProcessingTests"
            and cases[0].get("name") == "feedbackPerformanceEvidenceTrials()", "Wrong feedback test identity")
    require(not any(root.findall(".//" + tag) for tag in ("failure", "error", "skipped")), "Feedback evidence did not pass")


def run(output):
    output.mkdir(parents=True, exist_ok=False)
    result = {"schemaVersion": 1, "status": "failed", "commands": [], "scope": SCOPE,
              "physicalEvidence": "pending #74; defaults and applicability review #142"}
    try:
        environment = ci.environment("release")
        ci.validate_environment(environment, json.loads((ROOT / "Configuration/build.json").read_text()))
        environment.update(execution=SCOPE, timingClock="DispatchTime uptimeNanoseconds",
                           policyClock="injected virtual source-end nanoseconds", paced=False)
        (output / "environment.json").write_text(ci.redact(json.dumps(environment, indent=2)) + "\n")
        command = ["swift", "test", "--configuration", "release", "--scratch-path", ".build/feedback-evidence",
                   "--filter", "feedbackPerformanceEvidenceTrials", "--xunit-output", str(output / "tests.xml")]
        with (output / "commands.log").open("w") as log:
            ci.run_command(command, log, result["commands"])
        reports = ci.test_reports(output)
        validate_test_reports(output, reports)
        report = parse_report((output / "commands.log").read_text())
        summary = validate_report(report)
        (output / "trials.json").write_text(json.dumps(report, indent=2, allow_nan=False) + "\n")
        (output / "distributions.json").write_text(json.dumps(summary, indent=2, allow_nan=False) + "\n")
        sources = ["Package.swift", "Configuration/build.json", "Tools/ci.py", "Tools/PersonalTargets/feedback.py",
                   "Tools/Tests/test_personal_target_feedback.py", ".github/workflows/personal-target-evidence.yml",
                   *[str(p.relative_to(ROOT)) for p in sorted((ROOT / "Sources/HDXLVoiceProcessing").rglob("*.swift"))],
                   *[str(p.relative_to(ROOT)) for p in sorted((ROOT / "Tests/HDXLVoiceProcessingTests").glob("*.swift"))]]
        result.update(status="passed", trialCount=54, configurationCount=18, testReports=reports,
                      sourceSHA256={s: hashlib.sha256((ROOT / s).read_bytes()).hexdigest() for s in sources})
    except (OSError, ValueError, KeyError, TypeError, RuntimeError, subprocess.SubprocessError, ET.ParseError) as error:
        result["error"] = ci.redact(str(error))
        print(result["error"], file=sys.stderr)
    finally:
        for path in output.glob("*.xml"):
            ci.redact_report(path)
    (output / "result.json").write_text(json.dumps(result, indent=2, allow_nan=False) + "\n")
    return 0 if result["status"] == "passed" else 1


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    sys.exit(run(parser.parse_args().output.resolve()))
