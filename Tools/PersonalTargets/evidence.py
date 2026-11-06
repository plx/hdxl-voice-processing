#!/usr/bin/env python3
"""Audit public-API target reports and measure bounded offline fitting/evaluation."""
import argparse
import copy
import hashlib
import json
import math
import os
from pathlib import Path
import statistics
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Tools"))
import ci
import fitting_reference as fitting
import profile_reference as profile
from validation import IMPLEMENTATION, PROFILE_SHA256, require, validate_profile_report

FIXTURES = ROOT / "Tests/HDXLVoiceProcessingTests/Fixtures/PersonalTargets"
PACKAGE = ROOT / "Examples/PersonalTargetWorkflow"
canonical = profile.canonical


def read(path):
    return profile.load_json(path)


def sha(value):
    return hashlib.sha256(value).hexdigest()


def identity(value):
    return {"sha256": sha(canonical(value))}


def integer(value, minimum=0):
    return type(value) is int and value >= minimum


def positive(value):
    return type(value) in (int, float) and math.isfinite(value) and value > 0


def close(actual, expected, tolerance=1e-13):
    require(type(actual) in (int, float) and math.isfinite(actual)
            and abs(actual - expected) <= tolerance, "Independent numerical expectation differs")


def expected_validation(envelope):
    return {"schemaVersion": 1,
        "profile": {"identifier": {"name": "shared-pcm-analysis-schedule", "version": 1}, "sha256": PROFILE_SHA256},
        "analysisImplementation": IMPLEMENTATION, "sourceIdentity": envelope["sourceIdentity"],
        "components": sorted([{**component, "referenceIdentity": envelope["referenceIdentity"],
            "reportIdentity": envelope["reportIdentity"]} for component in envelope["components"]],
            key=lambda item: item["metric"])}


def validate_partition(actual, expected, rows):
    counts = actual["classification"]
    require(actual["inScopeClassification"] == counts and actual["outOfScopeGroupIDs"] == [], "Synthetic cohort changed")
    for key, wanted in expected["counts"].items():
        if type(wanted) is int:
            require(type(counts[key]) is int and counts[key] == wanted, "Incorrect confusion/class/coverage count")
        else:
            close(counts[key], wanted)
    require(counts["unknownLabelGroups"] == 0, "Invented unknown labels")
    require(counts["statisticalUnit"] == "original-acquisition-or-identical-content-group"
            and len(counts["uncertaintyLimitations"]) == 3, "Lost uncertainty limitations")
    for label in ["preferred", "usual"]:
        interval = counts[label + "ConditionalInterval"]
        wanted = expected[label + "Interval"]
        require(interval["successes"] == wanted["successes"] and interval["trials"] == wanted["trials"], "Inflated uncertainty trials")
        require(interval["assumption"] == "independent-acquisition-group-outcomes", "Missing independence assumption")
        close(interval["lower"], wanted["lower"], 1e-14)
        close(interval["upper"], wanted["upper"], 1e-14)
    by_id = {fitting.uuid(x["id"]): x for x in rows}
    predictions = {fitting.uuid(x["id"]): x["predicted"] for x in expected["predictions"]}
    require(len(actual["groups"]) == len(rows), "Omitted/duplicated acquisition group")
    seen = set()
    for item in actual["groups"]:
        group = item["group"]
        require(len(group["takes"]) == 1 and group["distinctAnalysisCount"] == 1, "Wrong synthetic group size")
        take_id = group["takes"][0]["takeID"]
        require(take_id in by_id and take_id not in seen, "Wrong/duplicate input identity")
        seen.add(take_id)
        row = by_id[take_id]
        require(group["recordingGroup"] == {"sha256": row["groupSHA256"]}
                and group["role"] == row["role"] and group["actual"] == row["label"]
                and group["isInScope"] is True, "Changed group provenance")
        require(item["prediction"].get("predicted") == predictions[take_id], "Independent predicted class differs")
        for metric, key in [("cppsDB", "cpps"), ("fundamentalFrequencyHz", "pitch"), ("levelDBFS", "level")]:
            close(group["values"][metric], row[key])
    require(seen == set(by_id), "Missing input groups")


def validate_binding(directory, prefix, fit, evaluation):
    dataset_bytes = (directory / (prefix + "-dataset.json")).read_bytes()
    dataset = json.loads(dataset_bytes)
    split_bytes = (directory / (prefix + "-split.json")).read_bytes()
    split = json.loads(split_bytes)
    require(fit["datasetIdentity"] == {"sha256": sha(dataset_bytes)} == split["datasetIdentity"], "Dataset version not bound")
    require(fit["splitIdentity"] == {"sha256": sha(split_bytes)}, "Split not bound")
    require(evaluation["fitIdentity"] == identity(fit), "Evaluation is not bound to frozen fit")
    require(fit["candidate"]["datasetIdentity"] == fit["datasetIdentity"]
            and fit["candidate"]["trainingIdentity"] == fit["trainingIdentity"]
            and fit["candidate"]["splitIdentity"] == fit["splitIdentity"], "Candidate provenance drift")
    if evaluation.get("activated") is not None:
        model = evaluation["activated"]
        require(model["candidate"] == fit["candidate"] and model["evaluationIdentity"] == evaluation["evaluationIdentity"], "Evaluation retuned the model")
        require(len(canonical(model)) <= 65536, "Oversize model")
    return dataset, split


def validate_output(directory, references, envelope, repetitions):
    report = read(directory / "report.json")
    require(type(report["schemaVersion"]) is int and report["schemaVersion"] == 1 and report["status"] == "passed", "Incomplete native workflow")
    require(report["syntheticOnly"] is True and report["humanListeningPerformed"] is False
            and report["physicalDeviceEvidence"] is False and report["numericalPCMValidationIsSeparate"] is True, "Unsupported human/physical/numerical claim")
    validation = expected_validation(envelope)
    require(report["validationIdentity"] == identity(validation), "Validation receipt unbound")
    require(report["fittingReferenceIdentity"] == {"sha256": sha((FIXTURES / "fitting-reference.json").read_bytes())}, "Wrong independent fitting fixture")
    require(len(report["scenarios"]) == 9, "Skipped fitting scenario")
    for record, wanted in zip(report["scenarios"], references["cases"], strict=True):
        name = wanted["name"]
        require(record["name"] == name, "Missing/reordered scenario")
        for field, suffix in [("fitFile", "fit"), ("evaluationFile", "evaluation"), ("datasetFile", "dataset"), ("splitFile", "split")]:
            require(record[field] == name + "-" + suffix + ".json", "Unexpected artifact path")
        fit, evaluated = read(directory / record["fitFile"]), read(directory / record["evaluationFile"])
        dataset, split = validate_binding(directory, name, fit, evaluated)
        require(fit["validation"] == validation and fit["candidate"]["validationIdentity"] == identity(validation), "Unverified fitting profile")
        require(fit["candidate"]["scope"]["profile"] == validation["profile"], "Changed fitted profile")
        require(record["datasetIdentity"] == fit["datasetIdentity"] and record["splitIdentity"] == fit["splitIdentity"]
                and record["fitIdentity"] == identity(fit) and record["evaluationIdentity"] == evaluated["evaluationIdentity"], "Scenario identity mismatch")
        rule = fit["candidate"]["rule"]
        for key in ["preferredTraining", "usualTraining", "preferredInterval", "observedCPPS", "direction"]:
            require(rule[key] == wanted[key], "Independent numerical fitting rule differs")
        require(rule["statistic"] == "selectedIntervalLowerMedianV1", "Changed aggregation semantics")
        require(record["activated"] is wanted["activated"] and (evaluated.get("activated") is not None) == wanted["activated"], "Incorrect activation/refusal")
        require(len(dataset["sessions"]) == 4 and sum(len(x["takes"]) for x in dataset["sessions"]) == 64
                and len(split["assignments"]) == 64, "Missing software input records")
        for role, actual in [("fitting", fit["training"]), ("recordingEvaluation", evaluated["recordingEvaluation"]),
                             ("sessionEvaluation", evaluated["sessionEvaluation"])]:
            rows = [x for x in wanted["rows"] if x["role"] == role]
            validate_partition(actual, wanted["reports"][role], rows)
        require(len(evaluated["laterSessions"]) == 2, "Missing whole-session evaluation")
        if "confound" in name:
            reason = "possibleLevelConfound" if name == "loudness-confound" else "possiblePitchConfound"
            require(reason in evaluated["reasons"] and reason in fit["reasons"], "Confound suppressed")
    capacity_fit = read(directory / "capacity-fit.json")
    capacity_evaluation = read(directory / "capacity-evaluation.json")
    dataset, split = validate_binding(directory, "capacity", capacity_fit, capacity_evaluation)
    model = read(directory / "capacity-model.json")
    require(model == capacity_evaluation.get("activated"), "Capacity model not activated by its evaluation")
    require(capacity_fit["validation"] == validation and capacity_fit["reasons"] == []
            and capacity_evaluation["reasons"] == [], "Capacity fit failed")
    require(report["maximumDatasetSessions"] == len(dataset["sessions"]) == 32
            and report["maximumDatasetTakes"] == sum(len(s["takes"]) for s in dataset["sessions"]) == 512
            and len(split["assignments"]) == 512, "Maximum-capacity inputs omitted")
    require(report["maximumDatasetIdentity"] == capacity_fit["datasetIdentity"]
            and report["maximumDatasetBytes"] == (directory / "capacity-dataset.json").stat().st_size
            and report["maximumDatasetBytes"] <= 16 * 1024 * 1024, "Wrong bounded dataset receipt")
    total = sum(x["classification"]["totalGroups"] for x in [capacity_fit["training"],
        capacity_evaluation["recordingEvaluation"], capacity_evaluation["sessionEvaluation"]])
    require(total == 512, "Maximum fit skipped acquisition groups")
    require(report["repetitions"] == repetitions and len(report["capacityTrials"]) == repetitions, "Skipped timing passes")
    for trial in report["capacityTrials"]:
        require(positive(trial["fittingSeconds"]) and positive(trial["evaluationSeconds"]), "Missing timing evidence")
        require(integer(trial["modelBytes"], 1) and trial["modelBytes"] <= 65536
                and trial["modelBytes"] == len(canonical(model))
                and trial["modelIdentity"] == identity(model), "Incorrect model size/identity")
        require(integer(trial["peakResidentBytes"], 1) and trial["peakResidentBytes"] < 2**40, "Missing process RSS evidence")
    return report


def distribution(values):
    require(len(values) >= 10 and all(positive(x) for x in values), "Insufficient measurement distribution")
    return {"count": len(values), "minimum": min(values), "median": statistics.median(values),
            "maximum": max(values), "mean": statistics.mean(values)}


def negative_controls(directory, references, envelope, native_report, reference, reference_bytes):
    results = []
    for name, path, replacement in [
        ("profile-identity", ["profileIdentity", "sha256"], "0" * 64),
        ("missing-profile-case", ["cases"], native_report["cases"][:-1]),
        ("failed-reference-budget", ["cases", 10, "metrics", "cpps", "maximumErrorToBudget"], 1.01),
        ("skipped-chunks", ["cases", 10, "chunkComparisons"], 0),
        ("invented-available-frame", ["cases", 1, "metrics", "cpps", "available"], 1),
    ]:
        mutated = copy.deepcopy(native_report)
        nested = mutated
        for key in path[:-1]:
            nested = nested[key]
        nested[path[-1]] = replacement
        rejected = False
        try:
            validate_profile_report(mutated, reference, reference_bytes)
        except (ValueError, KeyError, TypeError):
            rejected = True
        require(rejected, "Profile evidence corruption was accepted")
        results.append({"name": name, "rejected": True})
    for name, filename, path, replacement in [
        ("physical-claim", "report.json", ["physicalDeviceEvidence"], True),
        ("incomplete-capacity", "report.json", ["maximumDatasetTakes"], 511),
        ("missing-timing", "report.json", ["capacityTrials", 0, "fittingSeconds"], 0),
        ("retuned-fit", "separated-fit.json", ["candidate", "rule", "preferredInterval", "upper"], 11),
        ("erased-confound", "loudness-confound-evaluation.json", ["reasons"], []),
        ("changed-split", "separated-split.json", ["seed"], 54),
    ]:
        artifact = directory / filename
        original = artifact.read_bytes()
        mutated = json.loads(original)
        nested = mutated
        for key in path[:-1]:
            nested = nested[key]
        nested[path[-1]] = replacement
        artifact.write_bytes(canonical(mutated))
        rejected = False
        try:
            validate_output(directory, references, envelope, 1)
        except (ValueError, KeyError, TypeError):
            rejected = True
        finally:
            artifact.write_bytes(original)
        require(rejected, "Target output corruption was accepted")
        results.append({"name": name, "rejected": True})
    validate_output(directory, references, envelope, 1)
    return results


def run(output):
    reference = profile.verify(FIXTURES / "Profile")
    reference_bytes = (FIXTURES / "Profile/profile-reference.json").read_bytes()
    fitting_bytes = (FIXTURES / "fitting-reference.json").read_bytes()
    require(fitting_bytes == fitting.canonical(fitting.generate()) + b"\n", "Changed independent fitting fixtures")
    references = json.loads(fitting_bytes)
    output.mkdir(parents=True, exist_ok=False)
    environment = ci.environment("release")
    ci.validate_environment(environment, read(ROOT / "Configuration/build.json"))
    environment.update(hardwareModel=ci.capture("sysctl", "-n", "hw.model"),
        interpretation="Offline synthetic fit/evaluate; RSS includes process/runtime, inputs and reports. No callback, human-listening or physical-device claim.",
        timing="Each capacity pass fits and evaluates 512 takes/32 sessions; dataset preparation/import and artifact writes are outside those two measured intervals.",
        registrationIssue="https://github.com/plx/hdxl-voice-processing/issues/25")
    (output / "environment.json").write_bytes(canonical(environment))
    sources = sorted((ROOT / "Sources/HDXLVoiceProcessing").rglob("*.swift"))
    source_map = {str(path.relative_to(ROOT)): sha(path.read_bytes()) for path in sources}
    source_bytes = canonical(source_map)
    (output / "analysis-source-identities.json").write_bytes(source_bytes)
    commands = []
    native_path = output / "profile-validation.json"
    with (output / "commands.log").open("w") as log:
        command = ["env", "HDXL_PERSONAL_TARGET_PROFILE_REPORT=" + str(native_path),
                   "swift", "test", "-c", "release", "--scratch-path", ".build/personal-target-profile-check",
                   "--filter", "personalTargetExactProfile", "--xunit-output", str(output / "profile-tests.xml")]
        try:
            ci.run_command(command, log, commands)
        finally:
            for path in output.glob("*.xml"):
                ci.redact_report(path)
        test_reports = ci.test_reports(output)
        require(sum(x["testCases"] for x in test_reports) == 1, "Unexpected native profile test selection")
        native_bytes = native_path.read_bytes()
        native = json.loads(native_bytes)
        components = validate_profile_report(native, reference, reference_bytes)
        envelope = {"schemaVersion": 1, "status": "passed", "profile": native["profile"],
            "analysisImplementation": IMPLEMENTATION, "sourceIdentity": {"sha256": sha(source_bytes)},
            "referenceIdentity": {"sha256": sha(reference_bytes)}, "reportIdentity": {"sha256": sha(native_bytes)},
            "components": components}
        envelope_path = output / "checked-evidence.json"
        envelope_path.write_bytes(canonical(envelope))
        ci.run_command(["swift", "build", "--package-path", str(PACKAGE), "-c", "release"], log, commands)
    binary = Path(ci.capture("swift", "build", "--package-path", str(PACKAGE), "-c", "release", "--show-bin-path")) / "PersonalTargetWorkflow"
    records = []
    negative = []
    for repetitions in (1, 4):
        for trial in range(10):
            destination = output / f"passes-{repetitions}-trial-{trial:02d}"
            completed = subprocess.run([str(binary), str(ROOT), str(envelope_path), str(destination), str(repetitions)],
                cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120, check=False)
            with (output / "commands.log").open("a") as log:
                log.write(ci.redact(completed.stdout))
            require(completed.returncode == 0, "Native public-API workflow failed")
            report = validate_output(destination, references, envelope, repetitions)
            if repetitions == 1 and trial == 0:
                negative = negative_controls(destination, references, envelope, native, reference, reference_bytes)
            record = {"repetitions": repetitions, "trial": trial, "reportPath": destination.name + "/report.json",
                "reportSHA256": sha((destination / "report.json").read_bytes()),
                "fittingSeconds": statistics.median(x["fittingSeconds"] for x in report["capacityTrials"]),
                "evaluationSeconds": statistics.median(x["evaluationSeconds"] for x in report["capacityTrials"]),
                "peakResidentBytes": max(x["peakResidentBytes"] for x in report["capacityTrials"]),
                "modelBytes": max(x["modelBytes"] for x in report["capacityTrials"])}
            records.append(record)
            print(f"Verified {destination.name}", flush=True)
    distributions = {str(repetitions): {key: distribution([x[key] for x in records if x["repetitions"] == repetitions])
        for key in ["fittingSeconds", "evaluationSeconds", "peakResidentBytes", "modelBytes"]} for repetitions in (1, 4)}
    allowance = 32 * 1024 * 1024
    require(distributions["4"]["peakResidentBytes"]["median"] <= distributions["1"]["peakResidentBytes"]["median"] + allowance,
            "Repeated fitting median RSS exceeded the declared 32 MiB host smoke allowance")
    evidence_sources = sorted((ROOT / "Tools/PersonalTargets").glob("*.py")) + sorted(PACKAGE.rglob("*.swift"))
    evidence_sources = [p for p in evidence_sources if ".build" not in p.parts]
    result = {"schemaVersion": 1, "status": "passed", "physicalDeviceEvidence": False,
        "profileIdentity": native["profileIdentity"], "analysisSourceIdentity": envelope["sourceIdentity"],
        "profileReferenceSHA256": sha(reference_bytes), "fittingReferenceSHA256": sha(fitting_bytes),
        "profileReportSHA256": sha(native_bytes), "checkedEvidenceSHA256": sha(envelope_path.read_bytes()),
        "evidenceSourceSHA256": {str(p.relative_to(ROOT)): sha(p.read_bytes()) for p in evidence_sources},
        "commands": commands, "testReports": test_reports, "records": records,
        "negativeValidationControls": negative, "distributions": distributions,
        "residentGrowthAllowanceBytes": allowance,
        "memoryInterpretation": "Fresh-process cumulative RSS includes nine small scenario exports and prepared maximum-count inputs; compare 1 versus 4 sequential maximum-capacity fits, not callback allocations or a 16 MiB maximum-metadata stress test."}
    (output / "result.json").write_bytes(canonical(result))
    print("Verified 20 fresh processes, 180 synthetic scenarios, 50 maximum-capacity fits/evaluations, and 11 corruption controls.")
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    run(parser.parse_args().output.resolve())
