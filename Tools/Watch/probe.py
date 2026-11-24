#!/usr/bin/env python3
"""Build the standalone watch feasibility host and optionally execute synthetic replay."""
import argparse
import json
import math
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
APP = "WatchFeasibilityProbe"
PROJECT = ROOT / "Examples" / APP / (APP + ".xcodeproj")
BUNDLE = "org.hdxl.voice-processing.watch-feasibility"
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
            and "input" not in receipt and "recorderStopToResultReadySeconds" not in receipt
            and receipt.get("captureDrops") == "unobservable" and result.get("frames") == 16000 and result.get("sampleRate") == 16000
            and result.get("channels") == 1 and result.get("windows") == 10
            and re.fullmatch("[a-f0-9]{64}", result.get("profileSHA256", ""))
            and last.get("status") == "finite" and math.isclose(last["finiteDecibels"], -6.020599913, abs_tol=1e-6)):
        raise ValueError("Watch Simulator did not publish the known synthetic level result")


def replay(bundle, install):
    selected = runtime()
    if not selected and install:
        subprocess.run(["xcodebuild", "-downloadPlatform", "watchOS", "-buildVersion", "27.0",
                        "-architectureVariant", "arm64"], check=True)
        selected = runtime()
    if not selected:
        raise RuntimeError("watchOS 27.0 Simulator runtime required for execution")
    device = command("xcrun", "simctl", "create", "HDXL Watch " + uuid.uuid4().hex, DEVICE_TYPE, selected["identifier"])
    try:
        for args in (["boot", device], ["bootstatus", device, "-b"], ["install", device, str(bundle)]):
            subprocess.run(["xcrun", "simctl", *args], check=True)
        container = Path(command("xcrun", "simctl", "get_app_container", device, BUNDLE, "data"))
        target = container / "Documents/watch-trial.json"
        if target.exists():
            raise ValueError("Unexpected trial on the new simulator")
        command("xcrun", "simctl", "launch", device, BUNDLE, "--synthetic-replay")
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            if target.exists():
                receipt = json.loads(target.read_bytes())
                if receipt.get("status") != "started":
                    validate_replay(receipt)
                    return {"deviceType": DEVICE_TYPE, "runtimeBuild": selected["buildversion"], "receipt": receipt}
            time.sleep(0.25)
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
    with tempfile.TemporaryDirectory(prefix="hdxl-watch-") as scratch:
        for platform, destination in (("watchos", "watchOS"), ("watchsimulator", "watchOS Simulator")):
            subprocess.run(["xcodebuild", "-project", str(PROJECT), "-scheme", APP, "-configuration", "Release",
                            "-destination", "generic/platform=" + destination, "-derivedDataPath", scratch,
                            "CODE_SIGNING_ALLOWED=NO", "COMPILER_INDEX_STORE_ENABLE=NO", "build"], cwd=ROOT, check=True)
            bundle = Path(scratch) / "Build/Products" / ("Release-" + platform) / (APP + ".app")
            info[platform] = validate_bundle(bundle, platform)
            if args.replay and platform == "watchsimulator":
                info["replay"] = replay(bundle, args.install_runtime)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(info, indent=2) + "\n")


if __name__ == "__main__":
    main()
