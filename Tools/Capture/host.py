#!/usr/bin/env python3
"""Build/sign/inspect a local development bundle; never launch or prompt."""
import hashlib
import json
import plistlib
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Tools"))
import ci


def main():
    output = ROOT / ".build/capture-host-evidence"
    output.mkdir(parents=True, exist_ok=True)
    result = {"status": "failed", "commands": [], "launched": False,
              "physicalEvidence": "pending #74; ad-hoc signature is not device/TCC validation"}
    try:
        environment = ci.environment("release")
        ci.validate_environment(environment, json.loads((ROOT / "Configuration/build.json").read_text()))
        (output / "environment.json").write_text(ci.redact(json.dumps(environment, indent=2)) + "\n")
        with (output / "build.log").open("w") as log:
            ci.run_command(["bash", "Tools/build-macos-capture-host.sh"], log, result["commands"])
        bundle = ROOT / ".build/macos-capture-host/MacOSCaptureHost.app"
        info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
        entitlements = plistlib.loads(subprocess.check_output(
            ["codesign", "--display", "--entitlements", "-", "--xml", str(bundle)], stderr=subprocess.PIPE))
        if info["LSMinimumSystemVersion"] != "27.0" or not info["NSMicrophoneUsageDescription"]:
            raise ValueError("Missing host deployment or microphone description")
        if entitlements != {"com.apple.security.device.audio-input": True}:
            raise ValueError("Unexpected hardened-runtime development host entitlements")
        result.update(status="passed", entitlements=entitlements, minimumOS=info["LSMinimumSystemVersion"],
                      binarySHA256=hashlib.sha256((bundle / "Contents/MacOS/MacOSCaptureHost").read_bytes()).hexdigest())
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError) as error:
        result["error"] = ci.redact(str(error))
    (output / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    return 0 if result["status"] == "passed" else 1


if __name__ == "__main__":
    sys.exit(main())
