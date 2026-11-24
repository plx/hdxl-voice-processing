#!/usr/bin/env python3
"""Build the standalone watch feasibility host and optionally execute synthetic replay."""
import argparse
import json
import math
from pathlib import Path
import plistlib
import subprocess
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
APP = "WatchFeasibilityProbe"
PROJECT = ROOT / "Examples" / APP / (APP + ".xcodeproj")
BUNDLE = "org.hdxl.voice-processing.watch-feasibility"
REPLAY_PROFILE = "f98d6602d57b33ab0e41076cddb38a2991a05dbabb6dc2738e72794681f948cb"
DEVICE_TYPE = "com.apple.CoreSimulator.SimDeviceType.Apple-Watch-Series-11-42mm"


def command(*args):
    return subprocess.check_output(args, cwd=ROOT, text=True).strip()


def runtime():
    entries = json.loads(command("xcrun", "simctl", "list", "runtimes", "--json"))["runtimes"]
    return next((r for r in entries if r["isAvailable"] and r["version"] == "27.0"
                 and r["identifier"].startswith("com.apple.CoreSimulator.SimRuntime.watchOS-")), None)


def validate_bundle(bundle, platform):
    with (bundle / "Info.plist").open("rb") as info:
        plist = plistlib.load(info)
    if not (plist["MinimumOSVersion"] == "27.0" and plist["DTPlatformName"] == platform
            and plist["CFBundleIdentifier"] == BUNDLE and plist.get("WKWatchOnly")
            and plist.get("NSMicrophoneUsageDescription") and plist["UIDeviceFamily"] == [4]
            and not any(plist.get(key) for key in ("WKBackgroundModes", "UIBackgroundModes"))):
        raise ValueError("Unexpected watch platform, minimum, permissions or background policy")
    binary = bundle / plist["CFBundleExecutable"]
    return {"platform": platform, "minimum": plist["MinimumOSVersion"],
            "sdk": plist["DTSDKName"], "architectures": command("lipo", "-archs", str(binary)).split()}


def validate_replay(receipt):
    result = receipt.get("result") or {}
    last = result.get("lastWindow") or {}
    names = [event["name"] for event in receipt.get("events", [])]
    required = ["started", "analysis-started", "published"]
    if [name for name in names if not name.startswith("scene-")] != required:
        raise ValueError("Unexpected recording or lifecycle events in synthetic replay")
    if not (receipt.get("schemaVersion") == 1 and receipt.get("source") == "synthetic-file"
            and receipt.get("environment") == "watchOS Simulator" and receipt.get("status") == "published"
            and "input" not in receipt and "timing" not in receipt and receipt.get("preflightFileCleanup") == "absent"
            and "privateFileCleanup" not in receipt
            and receipt.get("captureDrops") == "unobservable" and result.get("frames") == 16000 and result.get("sampleRate") == 16000
            and result.get("channels") == 1 and result.get("windows") == 10
            and result.get("profileSHA256") == REPLAY_PROFILE and result.get("fileFormatID") == 1819304813
            and last.get("status") == "finite" and math.isclose(last["finiteDecibels"], -6.020599913, abs_tol=1e-6)):
        raise ValueError("Watch Simulator did not publish the known synthetic level result")


def save(info, output):
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", dir=output.parent, delete=False) as file:
        json.dump(info, file, indent=2)
        file.write("\n")
    Path(file.name).replace(output)


def failure_observation(receipt):
    # A failed app may have taken an unintended path. Keep only allowlisted state
    # and counts, even if its receipt contains a microphone route or private data.
    statuses = {"started", "published", "analysis-failed", "permission-denied", "private-file-cleanup-failed"}
    events = {"started", "analysis-started", "analysis-error", "permission-requested", "recording",
              "scene-active", "scene-inactive", "scene-background"} | statuses
    result = receipt.get("result")
    counts = {}
    if isinstance(result, dict):
        counts = {k: result[k] for k in ("frames", "windows", "sampleRate", "channels")
                  if type(result.get(k)) is int and 0 <= result[k] <= 1_000_000}
    return {"status": receipt.get("status") if receipt.get("status") in statuses else "unrecognized",
            "events": [e["name"] for e in receipt.get("events", [])[:64]
                       if isinstance(e, dict) and isinstance(e.get("name"), str) and e["name"] in events],
            "counts": counts}


def replay(bundle, install, info, output):
    selected = runtime()
    if not selected and install:
        subprocess.run(["xcodebuild", "-downloadPlatform", "watchOS", "-buildVersion", "27.0",
                        "-architectureVariant", "arm64"], check=True)
        selected = runtime()
    if not selected:
        raise RuntimeError("watchOS 27.0 Simulator runtime required for execution")
    info["simulator"] = {"deviceType": DEVICE_TYPE, "runtime": selected["identifier"],
                         "runtimeBuild": selected["buildversion"]}
    save(info, output)
    device = command("xcrun", "simctl", "create", "HDXL Watch " + uuid.uuid4().hex, DEVICE_TYPE, selected["identifier"])
    try:
        for args in (["boot", device], ["bootstatus", device, "-b"], ["install", device, str(bundle)]):
            subprocess.run(["xcrun", "simctl", *args], check=True)
        container = Path(command("xcrun", "simctl", "get_app_container", device, BUNDLE, "data"))
        target = container / "Documents/watch-trial.json"
        if target.exists():
            raise ValueError("Unexpected trial on the new simulator")
        # Model a force-quit leftover with project-owned bytes on this fresh simulator.
        marker = container / "tmp/HDXLWatchSegment.caf"
        marker.parent.mkdir(exist_ok=True)
        with marker.open("xb") as stream:
            stream.write(b"synthetic recovery check")
        command("xcrun", "simctl", "launch", device, BUNDLE, "--synthetic-replay")
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            if target.exists():
                receipt = json.loads(target.read_bytes())
                if receipt.get("status") != "started":
                    info["replayObservation"] = failure_observation(receipt)
                    save(info, output)
                    if receipt.get("status") != "published":
                        raise ValueError("Watch replay terminated: " + info["replayObservation"]["status"])
                    validate_replay(receipt)
                    recovery = json.loads((container / "Documents/watch-launch.json").read_bytes())
                    if recovery.get("privateFileCleanup") != "removed" or marker.exists():
                        raise ValueError("Watch relaunch failed to remove the synthetic leftover")
                    return {"launchRecovery": "removed-synthetic-leftover", "receipt": receipt}
            time.sleep(0.25)
        if target.exists():
            info["replayObservation"] = failure_observation(json.loads(target.read_bytes()))
            save(info, output)
        raise TimeoutError("Timed out waiting for the Watch app's replay receipt")
    finally:
        subprocess.run(["xcrun", "simctl", "shutdown", device], capture_output=True)
        subprocess.run(["xcrun", "simctl", "delete", device], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--replay", action="store_true", help="Execute the known segment on a disposable Watch Simulator")
    parser.add_argument("--install-runtime", action="store_true", help="Download watchOS 27.0 Simulator for --replay")
    parser.add_argument("--output", required=True, type=Path, help="Write build and optional replay evidence here")
    args = parser.parse_args()
    if args.install_runtime and not args.replay:
        parser.error("--install-runtime requires --replay")
    info = {"schemaVersion": 1, "revision": command("git", "rev-parse", "HEAD"),
            "dirty": bool(command("git", "status", "--porcelain")), "xcode": command("xcodebuild", "-version"),
            "physicalEvidence": "pending #74"}
    info["status"] = "failed"
    try:
        with tempfile.TemporaryDirectory(prefix="hdxl-watch-") as scratch:
            for platform, destination in (("watchos", "watchOS"), ("watchsimulator", "watchOS Simulator")):
                subprocess.run(["xcodebuild", "-project", str(PROJECT), "-scheme", APP, "-configuration", "Release",
                                "-destination", "generic/platform=" + destination, "-derivedDataPath", scratch,
                                "CODE_SIGNING_ALLOWED=NO", "COMPILER_INDEX_STORE_ENABLE=NO", "build"], cwd=ROOT, check=True)
                bundle = Path(scratch) / "Build/Products" / ("Release-" + platform) / (APP + ".app")
                info[platform] = validate_bundle(bundle, platform)
                if args.replay and platform == "watchsimulator":
                    info["replay"] = replay(bundle, args.install_runtime, info, args.output)
        info["status"] = "passed"
    finally:
        save(info, args.output)


if __name__ == "__main__":
    main()
