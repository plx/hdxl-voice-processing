#!/usr/bin/env python3
"""Build the iOS host and run synthetic-only probes on a disposable Simulator."""
import argparse
import hashlib
import json
import plistlib
import shutil
from pathlib import Path
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Tools"))
import ci

PROJECT = "Examples/IOSCaptureHost/IOSCaptureHost.xcodeproj"
BUNDLE = "org.hdxl.voice-processing.capture-host"
CHECKS = ["late-start-intent-rejected", "late-lifecycle-intent-rejected", "idempotent-lifecycle-finish",
          "bounded-lifecycle-display-completion", "independent-lifecycle-strict-delivery",
          "private-error-redacted", "permission-states-distinct", "bounded-pcm-samples-preserved",
          "closed-transfer-drained", "worker-rejects-gap"]
EVIDENCE = "synthetic iOS host execution; no permission request, session activation or microphone capture"
TEST_CASES = {"IOSCaptureHostTests/testSyntheticHostWithoutMicrophoneAccess()",
              "SessionInterchangeTests/testSessionArchiveFixturesOnIOS27()",
              "SessionStorageTests/testImportReplacementRefusesCorruptionAndPreservesPriorSession()",
              "SessionStorageTests/testSyntheticStorageSharingAndOriginalPCMReplay()"}


def installed_runtime():
    runtimes = json.loads(ci.capture("xcrun", "simctl", "list", "runtimes", "--json"))["runtimes"]
    return next((r for r in runtimes if r.get("isAvailable") and r.get("version") == "27.0"
                 and r["identifier"].startswith("com.apple.CoreSimulator.SimRuntime.iOS-")), None)


def ensure_runtime(install, log, commands):
    runtime = installed_runtime()
    if runtime is not None:
        return runtime
    if not install:
        raise RuntimeError("iOS 27.0 Simulator is unavailable; rerun with --install-runtime")
    # Xcode can exit 70 when content is already downloaded. Do not call the
    # downloader for a runtime that CoreSimulator already reports as available.
    ci.run_command(["xcodebuild", "-downloadPlatform", "iOS", "-buildVersion", "27.0",
                    "-architectureVariant", "arm64"], log, commands)
    runtime = installed_runtime()
    if runtime is None:
        raise RuntimeError("Download completed without an available iOS 27.0 Simulator runtime")
    return runtime


def validate_probe(probe):
    expected = {"schemaVersion": 1, "status": "passed", "checks": CHECKS, "evidence": EVIDENCE}
    if probe != expected:
        raise ValueError("Missing, unexpected, or failed synthetic host checks")


def validate_test_summary(summary):
    if any(summary.get(key) != value for key, value in {
            "result": "Passed", "totalTestCount": len(TEST_CASES), "passedTests": len(TEST_CASES),
            "failedTests": 0, "skippedTests": 0, "expectedFailures": 0}.items()):
        raise ValueError("Expected capture-host, session-interchange and storage regressions to execute and pass without skips")
    runs = summary.get("devicesAndConfigurations", [])
    if len(runs) != 1:
        raise ValueError("Expected one Simulator execution configuration")
    device = runs[0].get("device", {})
    if device.get("platform") != "iOS Simulator" or device.get("osVersion") != "27.0":
        raise ValueError("Host test runtime must be iOS 27.0 Simulator")
    if summary.get("testFailures") or summary.get("runtimeWarnings"):
        raise ValueError("Host tests reported failures or runtime warnings")


def validate_test_tree(tree):
    found = []

    def visit(nodes):
        if not isinstance(nodes, list):
            raise ValueError("Malformed test tree")
        for node in nodes:
            if not isinstance(node, dict):
                raise ValueError("Malformed test node")
            if node.get("nodeType") == "Test Case":
                if node.get("nodeIdentifier") not in TEST_CASES or node.get("result") != "Passed":
                    raise ValueError("Unexpected or failed named host regression")
                found.append(node["nodeIdentifier"])
            visit(node.get("children", []))

    visit(tree.get("testNodes"))
    if set(found) != TEST_CASES or len(found) != len(TEST_CASES):
        raise ValueError("Missing or duplicate named host regression")
    return sorted(found)


def validate_app(app):
    info = plistlib.loads((app / "Info.plist").read_bytes())
    if info.get("MinimumOSVersion") != "27.0" or info.get("CFBundleIdentifier") != BUNDLE:
        raise ValueError("Incorrect host deployment or identity")
    if not info.get("NSMicrophoneUsageDescription") or info.get("UIBackgroundModes"):
        raise ValueError("Missing microphone description or unexpected background claim")
    return {"minimumOS": info["MinimumOSVersion"], "backgroundModes": [],
            "microphoneUsageDescriptionPresent": True,
            "binarySHA256": hashlib.sha256((app / "IOSCaptureHost").read_bytes()).hexdigest()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--install-runtime", action="store_true",
                        help="Ask Xcode to install iOS 27.0 Simulator only if unavailable")
    args = parser.parse_args()
    output = ROOT / ".build/ios-capture-host-evidence"
    scratch = ROOT / ".build/ios-capture-host-ci"
    if output.exists():
        shutil.rmtree(output)
    output.mkdir(parents=True)
    results = scratch / "tests.xcresult"
    if results.exists():
        shutil.rmtree(results)
    result = {"schemaVersion": 1, "status": "failed", "commands": [],
              "physicalEvidence": "pending #74; Simulator execution and unsigned device compilation only"}
    simulator = None
    try:
        environment = ci.environment("ios-simulator")
        ci.validate_environment(environment, json.loads((ROOT / "Configuration/build.json").read_text()))
        environment.update(execution=EVIDENCE, configuration="Debug", destination="isolated iOS 27.0 Simulator")
        (output / "environment.json").write_text(ci.redact(json.dumps(environment, indent=2)) + "\n")
        with (output / "runtime.log").open("w") as log:
            runtime = ensure_runtime(args.install_runtime, log, result["commands"])
        simulator = ci.capture("xcrun", "simctl", "create", "HDXL Capture CI " + uuid.uuid4().hex,
                               "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro", runtime["identifier"])
        result["simulatorRuntime"] = {k: runtime[k] for k in ("name", "version", "buildversion")}
        common = ["xcodebuild", "-project", PROJECT, "-scheme", "IOSCaptureHost",
                  "-derivedDataPath", str(scratch), "CODE_SIGNING_ALLOWED=NO"]
        with (output / "build.log").open("w") as log:
            ci.run_command(common + ["-configuration", "Release", "-destination", "generic/platform=iOS",
                                     "build"], log, result["commands"])
            result["deviceBuild"] = validate_app(scratch / "Build/Products/Release-iphoneos/IOSCaptureHost.app")
            ci.run_command(common + ["-configuration", "Debug", "-destination", f"platform=iOS Simulator,id={simulator}",
                                     "-parallel-testing-enabled", "NO", "-resultBundlePath", str(results),
                                     "test"], log, result["commands"])
            summary = json.loads(ci.capture("xcrun", "xcresulttool", "get", "test-results", "summary",
                                             "--path", str(results), "--compact"))
            validate_test_summary(summary)
            tree = json.loads(ci.capture("xcrun", "xcresulttool", "get", "test-results", "tests",
                                          "--path", str(results), "--compact"))
            result["testCases"] = validate_test_tree(tree)
            # Keep a compact test summary; raw xcresults remain local.
            result["tests"] = {key: summary[key] for key in
                               ("result", "totalTestCount", "passedTests", "failedTests", "skippedTests")}
            app = scratch / "Build/Products/Debug-iphonesimulator/IOSCaptureHost.app"
            result["simulatorBuild"] = validate_app(app)
            # XCTest can use a cloned device or shut down its destination afterward.
            # Install and launch the built app explicitly for the separate UI probe.
            devices = json.loads(ci.capture("xcrun", "simctl", "list", "devices", "--json"))["devices"]
            device = next(d for group in devices.values() for d in group if d["udid"] == simulator)
            if device["state"] != "Booted":
                ci.run_command(["xcrun", "simctl", "boot", simulator], log, result["commands"])
            ci.run_command(["xcrun", "simctl", "bootstatus", simulator, "-b"], log, result["commands"])
            ci.run_command(["xcrun", "simctl", "install", simulator, str(app)], log, result["commands"])
            container = Path(ci.capture("xcrun", "simctl", "get_app_container", simulator, BUNDLE, "data"))
            receipt = container / "Documents/synthetic-self-test.json"
            if receipt.exists():
                raise ValueError("Unexpected preexisting app probe receipt")
            ci.run_command(["xcrun", "simctl", "launch", simulator, BUNDLE, "--self-test"], log, result["commands"])
            deadline = time.monotonic() + 60
            while not receipt.exists() and time.monotonic() < deadline:
                time.sleep(0.2)
            probe = json.loads(receipt.read_text())
            validate_probe(probe)
            result["appProbe"] = probe
        result["status"] = "passed"
    except (OSError, ValueError, KeyError, RuntimeError, StopIteration, subprocess.SubprocessError) as error:
        result["error"] = ci.redact(str(error))
    finally:
        if simulator:
            # Only the device created by this invocation is stopped and deleted.
            shutdown = subprocess.run(["xcrun", "simctl", "shutdown", simulator], capture_output=True)
            deleted = subprocess.run(["xcrun", "simctl", "delete", simulator], capture_output=True)
            result["cleanup"] = {"shutdownExitCode": shutdown.returncode, "deleteExitCode": deleted.returncode}
            if deleted.returncode:
                result["status"] = "failed"
                result["error"] = "Unable to delete the disposable Simulator"
        (output / "result.json").write_text(ci.redact(json.dumps(result, indent=2)) + "\n")
    return 0 if result["status"] == "passed" else 1


if __name__ == "__main__":
    sys.exit(main())
