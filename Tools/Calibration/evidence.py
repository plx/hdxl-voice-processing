#!/usr/bin/env python3
"""Validate C01 workflow outputs and measure repeated bounded import/file analysis."""
import argparse
import hashlib
import importlib.util
import json
import math
from pathlib import Path
import struct
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Tools"))
import ci

SPEC = importlib.util.spec_from_file_location("calibration_generate", ROOT / "Tools/Calibration/generate.py")
generator = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(generator)
FIXTURES = ROOT / "Tests/HDXLVoiceProcessingTests/Fixtures/Calibration"
PACKAGE = ROOT / "Examples/CalibrationWorkflow"
PROFILE_SHA256 = "5bf396a88af81ad37a14cddb4451cb0def196f1d9384b22c720227d8e835a7df"
STRESS_SHA256 = "3343897e8d01ef94083adbff26fa1c23e43ab2822ec8bad60bb599824dd31a9b"
METRICS = {"rms", "levelDBFS", "fundamentalFrequency", "cpp", "cpps"}
UNAVAILABLE = {"insufficientData", "silence", "clipping", "unsupportedRange", "inapplicableTask",
               "lowConfidence", "invalidInput", "discontinuity", "analysisFailure", "cancelled",
               "missingAcquisition", "excluded", "stale"}
WARNINGS = {"clipping", "lowConfidence", "partialCoverage", "exploratoryApplicability"}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def read(path):
    return json.loads(path.read_bytes(), parse_constant=lambda x: (_ for _ in ()).throw(ValueError(x)))


def positive(value):
    return type(value) in (int, float) and math.isfinite(value) and value > 0


def integer(value, minimum=0):
    return type(value) is int and value >= minimum


def digest(value):
    # The split fields here are ASCII strings/integers only; this is independent
    # of floating-point JSON spelling and excludes generator canonical's LF.
    return hashlib.sha256(generator.canonical(value).rstrip(b"\n")).hexdigest()


def expected_assignment(take, manifest):
    group = digest({"domain": "calibration-recording-group-v1", "acquisitions": [take["recordingID"]],
                    "contents": [{"sha256": take["sha256"]}]})
    if take["sessionID"] == manifest["evaluationSessionID"]:
        role = "sessionEvaluation"
    else:
        draw = digest({"domain": "calibration-recording-holdout-v1", "seed": manifest["splitSeed"],
                       "group": {"sha256": group}})
        role = "recordingEvaluation" if int(draw[:8], 16) / 2**32 < manifest["recordingEvaluationFraction"] else "fitting"
    return {"takeID": take["id"], "recordingGroup": {"sha256": group}, "role": role}


def validate_summary(summary):
    require(summary["metric"] in METRICS and integer(summary["availableCount"]), "Invalid summary identity/count")
    unavailable = summary["unavailable"]
    warnings = summary["warnings"]
    require(isinstance(unavailable, dict) and isinstance(warnings, dict), "Missing availability evidence")
    require(set(unavailable) <= UNAVAILABLE and set(warnings) <= WARNINGS, "Unknown availability/warning reason")
    require(all(integer(x, 1) for x in unavailable.values()), "Invalid unavailable count")
    require(all(integer(x, 1) and x <= summary["availableCount"] for x in warnings.values()), "Invalid warning count")
    require(summary["availableCount"] + sum(unavailable.values()) <= 30000, "Unbounded scalar collection")
    values = [summary.get(key) for key in ("minimum", "lowerQuartile", "median", "upperQuartile", "maximum")]
    if summary["availableCount"] == 0:
        require(values == [None] * 5, "Imputed unavailable scalar")
    else:
        require(all(type(x) in (int, float) and math.isfinite(x) for x in values), "Nonfinite quantile")
        require(values == sorted(values), "Nonmonotone quantile")


def validate_pass(record, manifest, reused):
    require(set(record) == {"seconds", "analyzed", "reused", "decodedSamples", "snapshotBytes",
        "maximumSnapshotChunkBytes", "maximumDecodedChunkSamples", "maximumPreparedBufferBytes",
        "maximumReservedScalarBytes", "maximumRetainedScalarCount", "peakResidentBytes"}, "Unexpected pass fields")
    require(positive(record["seconds"]), "No measured duration")
    require(all(integer(value) for key, value in record.items() if key != "seconds"), "Invalid execution accounting")
    require(record["analyzed"] == (0 if reused else 16) and record["reused"] == (16 if reused else 0), "Skipped/reclassified inputs")
    require(record["snapshotBytes"] == sum(t["byteCount"] for t in manifest["takes"]), "Missing verified bytes")
    require(record["maximumSnapshotChunkBytes"] == 12844, "Unexpected snapshot chunk geometry")
    require(record["decodedSamples"] == (0 if reused else 102400), "Incorrect decoded denominator")
    require(record["maximumDecodedChunkSamples"] == (0 if reused else 257), "Incorrect decoder capacity")
    require(record["maximumReservedScalarBytes"] == (0 if reused else 1200000), "Incorrect bounded scalar storage")
    require(0 < record["peakResidentBytes"] < 2**40, "No credible process high-water measurement")
    if reused:
        require(record["maximumPreparedBufferBytes"] == 0 and record["maximumRetainedScalarCount"] == 0, "Cache hit performed numerical work")
    else:
        require(0 < record["maximumPreparedBufferBytes"] <= 1024 * 1024, "Unexpected prepared scratch for pinned fixture profile")
        require(0 < record["maximumRetainedScalarCount"] <= 200, "Unexpected retained frame count for short fixtures")


def validate_output(directory, manifest, expected_passes):
    report = read(directory / "report.json")
    require(type(report["schemaVersion"]) is int and report["schemaVersion"] == 1 and report["status"] == "passed", "Failed/schema-mismatched workflow")
    for key in ("syntheticOnly", "labelingCompletedBeforeAnalysis"):
        require(report[key] is True, "Missing workflow distinction")
    for key in ("humanListeningPerformed", "fittedTargetProduced", "physicalDeviceEvidence"):
        require(report[key] is False, "Unsupported human/target/physical evidence claim")
    require(report["manifestSHA256"] == {"sha256": generator.sha((FIXTURES / "manifest.json").read_bytes())}, "Wrong manifest")
    profile = {"identifier": {"name": "shared-pcm-analysis-schedule", "version": 1}, "sha256": PROFILE_SHA256}
    require(report["profileIdentity"] == profile, "Executable example profile drift")
    data_bytes = (directory / "dataset.json").read_bytes()
    require(report["datasetIdentity"] == {"sha256": generator.sha(data_bytes)}, "Wrong completed dataset binding")
    data = read(directory / "dataset.json")
    require(data["revision"] == 2 and data["id"] == manifest["datasetID"], "Labels did not publish a new dataset version")
    takes = {take["id"]: (session["id"], take) for session in data["sessions"] for take in session["takes"]}
    fixture_ids = {t["id"] for t in manifest["takes"]}
    require(len(takes) == 16 and set(takes) == fixture_ids, "Missing/duplicate dataset takes")
    split = read(directory / "split.json")
    expected = [expected_assignment(take, manifest) for take in manifest["takes"]]
    require(split["assignments"] == expected, "Independent whole-recording assignment differs")
    require(split["datasetIdentity"] == report["datasetIdentity"] and split["seed"] == 47
            and split["sessionEvaluationIDs"] == [manifest["evaluationSessionID"]]
            and split["recordingEvaluationFraction"] == 0.25, "Split metadata mismatch")
    for role, key in (("fitting", "fittingTakeIDs"), ("recordingEvaluation", "recordingEvaluationTakeIDs"), ("sessionEvaluation", "sessionEvaluationTakeIDs")):
        require(report[key] == [a["takeID"] for a in expected if a["role"] == role], "Partition changed")
    require(len(report["replayTakeIDs"]) == 16 and set(report["replayTakeIDs"]) == fixture_ids, "Replay omitted takes")
    presenter = read(directory / "replay-presenter.json")
    require(len(presenter) == 16 and [x["ordinal"] for x in presenter] == list(range(1, 17)), "Invalid presenter sequence")
    require(all(set(x) == {"token", "ordinal"} for x in presenter), "Presenter leaks metadata")
    require(len({json.dumps(x["token"], sort_keys=True) for x in presenter}) == 16, "Duplicate replay token")
    comparisons = report["withinSessionComparisons"] + report["separateSessionEvaluation"]
    require(len(report["withinSessionComparisons"]) == 12 and len(report["separateSessionEvaluation"]) == 4, "Missing distinct session evaluation")
    require({x["takeID"] for x in comparisons} == fixture_ids, "Missing comparison")
    by_comparison = {x["takeID"]: x for x in comparisons}
    for fixture in manifest["takes"]:
        session_id, take = takes[fixture["id"]]
        require(session_id == fixture["sessionID"] and take["instruction"] == fixture["instruction"]
                and take["label"]["preference"] == fixture["listeningLabel"]
                and take["label"]["exposure"] == "blindedBeforeFeatures"
                and take["task"]["category"] == fixture["task"] and take["profileIdentity"] == profile, "Lost label/task/profile provenance")
        record = read(directory / f"analysis-{fixture['mediaID']}.json")
        key = record["key"]
        require(key["audio"] == {"sha256": fixture["sha256"]} and key["audioByteCount"] == fixture["byteCount"]
                and key["profile"] == profile and key["source"] == take["source"], "Cache not bound to actual fixture/profile/interval")
        require("url" not in key["decoder"] and "path" not in key["decoder"], "Private decoder locator in cache")
        coverage = record["coverage"]
        require(coverage["source"] == 6400 and coverage["eligible"] == 6400
                and coverage["selected"] == 6400 - fixture["selectedStartSample"], "Incorrect unique selection coverage")
        summaries = {x["metric"]: x for x in record["summaries"]}
        require(len(record["summaries"]) == 5 and set(summaries) == METRICS, "Missing raw metrics")
        for summary in summaries.values():
            validate_summary(summary)
        # Independent PCM16/window/RMS/dBFS oracle, not a call back into Swift.
        pcm = struct.unpack("<6400h", (FIXTURES / fixture["filename"]).read_bytes()[44:])
        energy = [math.fsum((sample / 32768)**2 for sample in pcm[start:start + 400]) / 400
                  for start in range(fixture["selectedStartSample"], 6400 - 400 + 1, 160)]
        for metric, values in (("rms", [math.sqrt(x) for x in energy]),
                               ("levelDBFS", [10 * math.log10(x) for x in energy if x > 0])):
            values.sort()
            summary = summaries[metric]
            require(summary["availableCount"] == len(values), "Wrong complete-window count")
            expected_values = (values[0], values[math.ceil(0.25 * len(values)) - 1],
                               values[math.ceil(0.5 * len(values)) - 1], values[math.ceil(0.75 * len(values)) - 1], values[-1])
            for name, value in zip(("minimum", "lowerQuartile", "median", "upperQuartile", "maximum"), expected_values):
                require(abs(summary[name] - value) <= 1e-10, "Independent raw-level quantile mismatch")
        require(abs(summaries["fundamentalFrequency"]["median"] - fixture["nominalFundamentalHz"]) < 1,
                "Raw pitch lost the synthetic fundamental")
        comparison = by_comparison[fixture["id"]]
        require(comparison["coverage"] == coverage and comparison["rawSummaries"] == record["summaries"]
                and comparison["listeningLabel"] == take["label"] and comparison["sessionID"] == session_id
                and comparison["role"] == expected_assignment(fixture, manifest)["role"],
                "Comparison detached from recorded data")
    imported = report["maximumDatasetImport"]
    require(imported["sessions"] == 32 and imported["takes"] == 512
            and imported["encodedBytes"] == 1895560 and imported["identity"] == {"sha256": STRESS_SHA256}, "Wrong import stress identity/capacity")
    require(len(imported["trialsSeconds"]) == 10 and all(positive(x) for x in imported["trialsSeconds"])
            and integer(imported["peakResidentBytes"], 1), "Missing import timing/memory")
    require(len(report["analysisPasses"]) == expected_passes, "Missing repeated analysis pass")
    for measured in report["analysisPasses"]:
        validate_pass(measured, manifest, False)
    validate_pass(report["cachePass"], manifest, True)
    require(not (directory / "scratch").exists(), "Temporary audio scratch was retained")
    return report


def distribution(values):
    require(len(values) >= 10 and all(positive(x) for x in values), "Insufficient measured distribution")
    values = sorted(values)
    return {"count": len(values), "minimum": values[0], "median": values[math.ceil(0.5 * len(values)) - 1],
            "maximum": values[-1], "mean": math.fsum(values) / len(values)}


def negative_controls(directory, manifest):
    """Prove whole-output validation rejects realistic evidence corruption."""
    controls = [
        ("report.json", ["physicalDeviceEvidence"], True),
        ("report.json", ["cachePass", "decodedSamples"], 1),
        ("report.json", ["maximumDatasetImport", "takes"], 511),
        ("report.json", ["analysisPasses", 0, "snapshotBytes"], 0),
        ("split.json", ["assignments", 0, "role"], "fitting"),
        ("dataset.json", ["sessions", 0, "takes", 0, "label", "preference"], "preferred"),
        ("analysis-synthetic-take-01.json", ["key", "audio", "sha256"], "0" * 64),
        ("analysis-synthetic-take-01.json", ["summaries", 4, "median"], 0),
        ("replay-presenter.json", [0, "instruction"], "preferred"),
    ]
    results = []
    for filename, keys, replacement in controls:
        path = directory / filename
        original = path.read_bytes()
        value = json.loads(original)
        nested = value
        for key in keys[:-1]:
            nested = nested[key]
        nested[keys[-1]] = replacement
        path.write_bytes(generator.canonical(value))
        rejected = False
        try:
            validate_output(directory, manifest, 1)
        except (ValueError, KeyError, TypeError):
            rejected = True
        finally:
            path.write_bytes(original)
        require(rejected, f"Corrupt evidence accepted: {filename}, {keys}")
        results.append({"file": filename, "field": keys, "rejected": True})
    validate_output(directory, manifest, 1)
    return results


def run(output):
    manifest = generator.verify(FIXTURES)
    output.mkdir(parents=True, exist_ok=False)
    environment = ci.environment("release")
    ci.validate_environment(environment, read(ROOT / "Configuration/build.json"))
    environment.update(hardwareModel=ci.capture("sysctl", "-n", "hw.model"),
        interpretation="Offline synthetic workflow; process peak RSS includes import stress/runtime/decoder overhead; no physical-device or allocation-free claim",
        timing="Snapshot hashing, decoder preparation, numerical analysis, bounded summaries and cache validation; each pass has 16 recordings/6.4 source seconds",
        registrationIssue="https://github.com/plx/hdxl-voice-processing/issues/25")
    (output / "environment.json").write_bytes(generator.canonical(environment))
    commands = []
    with (output / "commands.log").open("w") as log:
        ci.run_command(["swift", "build", "--package-path", str(PACKAGE), "-c", "release"], log, commands)
    binary_dir = Path(ci.capture("swift", "build", "--package-path", str(PACKAGE), "-c", "release", "--show-bin-path"))
    records = []
    negative = []
    for passes in (1, 4):
        for trial in range(10):
            destination = output / f"passes-{passes}-trial-{trial:02d}"
            command = [str(binary_dir / "CalibrationWorkflow"), str(FIXTURES), str(destination), str(passes)]
            result = subprocess.run(command, cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=False)
            with (output / "commands.log").open("a") as log:
                log.write(ci.redact(result.stdout))
            require(result.returncode == 0, "Native calibration workflow failed")
            report = validate_output(destination, manifest, passes)
            if passes == 1 and trial == 0:
                negative = negative_controls(destination, manifest)
            records.append({"passes": passes, "trial": trial, "reportPath": f"{destination.name}/report.json",
                            "reportSHA256": generator.sha((destination / "report.json").read_bytes()),
                            "analysisSeconds": sum(p["seconds"] for p in report["analysisPasses"]),
                            "cacheSeconds": report["cachePass"]["seconds"],
                            "importMedianSeconds": distribution(report["maximumDatasetImport"]["trialsSeconds"])["median"],
                            "peakResidentBytes": report["cachePass"]["peakResidentBytes"]})
    source_paths = [Path(__file__), ROOT / "Tools/Calibration/generate.py", PACKAGE / "Sources/CalibrationWorkflow/main.swift"]
    source_paths += sorted((ROOT / "Sources/HDXLVoiceProcessing/Calibration").glob("*.swift"))
    source_paths += sorted((ROOT / "Sources/HDXLVoiceProcessingAudio").glob("Calibration*.swift"))
    result = {"schemaVersion": 1, "status": "passed", "physicalDeviceEvidence": False,
              "manifestSHA256": generator.sha((FIXTURES / "manifest.json").read_bytes()),
              "sourceSHA256": {str(p.relative_to(ROOT)): generator.sha(p.read_bytes()) for p in source_paths},
              "records": records, "negativeValidationControls": negative, "distributions": {str(passes): {
                  key: distribution([r[key] for r in records if r["passes"] == passes])
                  for key in ("analysisSeconds", "cacheSeconds", "importMedianSeconds", "peakResidentBytes")}
                  for passes in (1, 4)},
              "memoryInterpretation": "Compare fresh-process RSS distributions for 16 vs 64 sequential analyses; explicit decoder/scalar bounds are separately validated in every pass, RSS is cumulative including maximum-capacity import"}
    allowance = 32 * 1024 * 1024
    result["residentGrowthAllowanceBytes"] = allowance
    require(result["distributions"]["4"]["peakResidentBytes"]["median"]
            <= result["distributions"]["1"]["peakResidentBytes"]["median"] + allowance,
            "Sequential-analysis median RSS grew beyond the declared 32 MiB host smoke allowance")
    (output / "result.json").write_bytes(generator.canonical(result))
    print("Validated 20 independent native runs, 800 fresh file analyses, 320 verified cache hits and 200 maximum-capacity imports.")
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    run(args.output.resolve())
