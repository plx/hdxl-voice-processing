#!/usr/bin/env python3
"""Build/sign a development bundle; run only synthetic error probes, never capture."""
import hashlib
import json
import plistlib
import shutil
from pathlib import Path
import subprocess
import sys
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Tools"))
import ci


def main():
    output = ROOT / ".build/capture-host-evidence"
    if output.exists():
        shutil.rmtree(output)
    output.mkdir(parents=True, exist_ok=True)
    result = {"status": "failed", "commands": [], "launched": False,
              "physicalEvidence": "pending #74; ad-hoc signature is not device/TCC validation"}
    try:
        environment = ci.environment("release")
        ci.validate_environment(environment, json.loads((ROOT / "Configuration/build.json").read_text()))
        (output / "environment.json").write_text(ci.redact(json.dumps(environment, indent=2)) + "\n")
        with (output / "build.log").open("w") as log:
            ci.run_command(["swift", "test", "--package-path", "Examples/MacOSCaptureHost",
                            "--configuration", "release", "--xunit-output", str(output / "tests.xml")],
                           log, result["commands"])
            ci.run_command(["bash", "Tools/build-macos-capture-host.sh"], log, result["commands"])
        result["testReports"] = ci.test_reports(output)
        if sum(r["testCases"] for r in result["testReports"]) != 2:
            raise ValueError("Expected both host error privacy regressions")
        for report in output.glob("*.xml"):
            ci.redact_report(report)
        bundle = ROOT / ".build/macos-capture-host/MacOSCaptureHost.app"
        info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
        entitlements = plistlib.loads(subprocess.check_output(
            ["codesign", "--display", "--entitlements", "-", "--xml", str(bundle)], stderr=subprocess.PIPE))
        if info["LSMinimumSystemVersion"] != "27.0" or not info["NSMicrophoneUsageDescription"]:
            raise ValueError("Missing host deployment or microphone description")
        if entitlements != {"com.apple.security.device.audio-input": True}:
            raise ValueError("Unexpected hardened-runtime development host entitlements")
        binary = bundle / "Contents/MacOS/MacOSCaptureHost"
        result["launched"] = True
        result["execution"] = "synthetic error-boundary probe only; no engine/permission/file capture"
        probe = subprocess.run([str(binary), "--self-test-error-reporting"], capture_output=True, timeout=30)
        if probe.returncode != 1 or probe.stdout or probe.stderr != b"Capture host failed: operation failed.\n":
            raise ValueError("Host error boundary crashed, leaked details, or returned the wrong exit status")
        result["errorBoundaryProbe"] = {"expectedExitCode": 1, "actualExitCode": probe.returncode,
                                       "sanitizedStderr": probe.stderr.decode(), "stdoutEmpty": True}
        result.update(status="passed", entitlements=entitlements, minimumOS=info["LSMinimumSystemVersion"],
                      binarySHA256=hashlib.sha256(binary.read_bytes()).hexdigest())
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError, ET.ParseError) as error:
        result["error"] = ci.redact(str(error))
    (output / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    return 0 if result["status"] == "passed" else 1


if __name__ == "__main__":
    sys.exit(main())
