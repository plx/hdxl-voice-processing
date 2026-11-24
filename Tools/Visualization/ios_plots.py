#!/usr/bin/env python3
"""Render and export the acoustic fixture gallery on a disposable iOS 27.0 Simulator."""
from collections import Counter
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Tools"))
import ci
from Capture.ios_host import ensure_runtime


def main():
    output = ROOT / ".build/visualization-ios-evidence"
    output.mkdir(parents=True, exist_ok=False)
    with (output / "runtime.log").open("w") as log:
        runtime = ensure_runtime(True, log, [])
    device = ci.capture("xcrun", "simctl", "create", "HDXL Plot CI " + uuid.uuid4().hex,
                        "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro", runtime["identifier"])
    try:
        with tempfile.TemporaryDirectory(dir=ROOT / ".build") as temporary:
            scratch = Path(temporary)
            bundle = str(scratch / "plots.xcresult")
            with (output / "build.log").open("w") as log:
                ci.run_command(["xcodebuild", "-scheme", "HDXLVoiceProcessing-Package", "-destination",
                                f"platform=iOS Simulator,id={device}", "-derivedDataPath", str(scratch / "build"),
                                "-parallel-testing-enabled", "NO", "-resultBundlePath", bundle,
                                "-only-testing:HDXLVoiceProcessingVisualizationTests/AcousticPlotRenderTests",
                                "-only-testing:HDXLVoiceProcessingVisualizationTests/AlgorithmInspectorRenderTests",
                                "CODE_SIGNING_ALLOWED=NO", "test"], log, [])
            summary = json.loads(ci.capture("xcrun", "xcresulttool", "get", "test-results", "summary", "--path", bundle))
            (output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
            destinations = [row["device"] for row in summary["devicesAndConfigurations"]]
            if (summary["result"] != "Passed" or summary["totalTestCount"] != 2 or summary["passedTests"] != 2
                    or len(destinations) != 1 or destinations[0]["platform"] != "iOS Simulator"
                    or destinations[0]["osVersion"] != "27.0"):
                raise ValueError("Both acoustic plot and inspector rendering tests must pass on iOS 27.0 Simulator")
            images = output / "renders"
            subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", bundle,
                            "--output-path", images], check=True)
            widths = Counter()
            for png in images.glob("*.png"):
                header = png.read_bytes()[:24]
                if header[:8] != b"\x89PNG\r\n\x1a\n" or header[12:16] != b"IHDR":
                    raise ValueError("Invalid plot PNG")
                width, height = struct.unpack(">II", header[16:24])
                if not 200 < height < 4096:
                    raise ValueError("Invalid plot height")
                widths[width] += 1
            if widths != {350: 21, 800: 21}:
                raise ValueError(f"Incomplete plot renders: {widths}")
    finally:
        subprocess.run(["xcrun", "simctl", "shutdown", device], capture_output=True)
        subprocess.run(["xcrun", "simctl", "delete", device], check=True)


if __name__ == "__main__":
    main()
