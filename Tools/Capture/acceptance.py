#!/usr/bin/env python3
"""Index the native runtime acceptance cases actually executed by the shared Debug lane."""
import argparse
import hashlib
import json
from pathlib import Path
import sys
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Tools"))
import ci

MODULE = "HDXLVoiceProcessingAudioTests"
CASES = {
    "file-and-native-chunk-invariance": (
        "schedulingFilesMatchMemoryAcrossDecoderChunksPrecisionsAndLayouts",
        "schedulingTransferMatchesMemoryForBothPrecisionsAndLayouts",
        "macCaptureTapPreservesNativeChannelsAndVariableBuffers",
    ),
    "loss-and-clock-continuity": (
        "macCaptureTapUnknownTimingAndClockTransitionsAreExplicit",
        "macCaptureTapOverflowAndOversizedBuffersRemainVisible",
        "schedulingTransferKnownAndTerminalGapsStayObservable",
        "lifecyclePCMGapPrecedesResetAndNewFrames",
    ),
    "permission-and-session-ownership": (
        "lifecycleConstructionAndLatePermissionHaveNoCaptureEffects",
        "iosCapturePermissionAndActivityFailuresHaveNoSessionSideEffects",
        "iosCaptureDeactivationRequiresGrantAndItsOwnActivation",
    ),
    "fresh-epochs-and-recovery": (
        "lifecycleRealPCMUsesFreshEpochAndHistoryAfterReconfiguration",
        "lifecycleAnalysisIdentityCannotAliasGapRegionAfterRestart",
        "iosCaptureRouteChangeReportsUnknownGapAndDoesNotAutoResume",
        "iosCaptureInterruptionDuringActivationCannotResumeIt",
    ),
    "cancellation-and-teardown": (
        "lifecycleCallerCancellationFromPublicationRetiresStartup",
        "lifecycleLateWorkerBatchIsRejectedAndFinishWaitsForWorker",
        "lifecycleRepeatedConcurrentStopsCompleteOncePerOperation",
        "lifecycleResourceTrials",
    ),
    "bounded-subscribers-and-overload": (
        "captureDeliveryEvidenceTrials",
        "lifecycleResultCapacityFailsExplicitlyWithoutPublishingPartialBatch",
    ),
}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def software_report(directory, commit):
    environment_bytes = (directory / "environment.json").read_bytes()
    environment = json.loads(environment_bytes)
    ci.validate_environment(environment, json.loads((ROOT / "Configuration/build.json").read_bytes()))
    if (environment["commit"] != commit or environment["lane"] != "debug"
            or environment["configuration"] != "debug" or environment["workingTreeDirty"] is not False):
        raise ValueError("Expected a clean Debug receipt for the requested checkout")
    result = json.loads((directory / "result.json").read_bytes())
    reports = ci.test_reports(directory)
    if (result["status"] != "passed" or result["lane"] != "debug" or result["testReports"] != reports
            or not result["commands"] or any(c["exitCode"] != 0 for c in result["commands"])):
        raise ValueError("A complete passed Debug lane is required")
    cases = {}
    hashes = {}
    for report in reports:
        name = report["file"]
        data = (directory / name).read_bytes()
        hashes[name] = digest(data)
        for case in ET.fromstring(data).findall(".//testcase"):
            if case.get("classname") != MODULE:
                continue
            test = case.get("name")
            if test in cases or any(case.find(tag) is not None for tag in ("skipped", "error", "failure")):
                raise ValueError(f"Duplicate or unsuccessful capture test {test}")
            cases[test] = name
    scenarios = {}
    for scenario, tests in CASES.items():
        names = [test + "()" for test in tests]
        missing = set(names) - cases.keys()
        if missing:
            raise ValueError(f"Missing native test for {scenario}: {sorted(missing)}")
        scenarios[scenario] = {name: cases[name] for name in names}
    return {
        "schemaVersion": 1, "scope": "deterministic runtime on macOS", "status": "passed",
        "commit": commit, "environmentSHA256": digest(environment_bytes), "testReportSHA256": hashes,
        "scenarios": scenarios, "physicalEvidence": "pending physical validation",
        "deviceFollowup": 74,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path, help="shared Debug CI artifact directory")
    parser.add_argument("--commit", help="expected measured revision (defaults to the current checkout)")
    args = parser.parse_args()
    output = args.directory / "native-acceptance.json"
    output.unlink(missing_ok=True)
    result = software_report(args.directory, args.commit or ci.capture("git", "rev-parse", "HEAD"))
    output.write_text(json.dumps(result, indent=2, allow_nan=False) + "\n")
    print(f"Verified {sum(map(len, result['scenarios'].values()))} named capture tests in {output}")


if __name__ == "__main__":
    main()
