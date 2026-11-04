"""Fail if the core consumer gains optional or development dependencies."""
import json
import subprocess
from pathlib import Path

root = Path(__file__).resolve().parent.parent
package = json.loads(subprocess.check_output(["swift", "package", "dump-package"], cwd=root))
assert package["dependencies"] == [], "Runtime package must have no external dependencies"
targets = {target["name"]: target for target in package["targets"]}
assert targets["HDXLVoiceProcessing"]["dependencies"] == []
for name in ("HDXLVoiceProcessingAudio", "HDXLVoiceProcessingVisualization"):
    assert targets[name]["dependencies"] == [{"byName": ["HDXLVoiceProcessing", None]}]

consumer = root / "Examples" / "CoreConsumer"
description = json.loads(subprocess.check_output(
    ["swift", "package", "describe", "--type", "json"], cwd=consumer
))
assert description["targets"][0]["product_dependencies"] == ["HDXLVoiceProcessing"]
binary_dir = subprocess.check_output(
    ["swift", "build", "--show-bin-path"], cwd=consumer, text=True
).strip()
binary = Path(binary_dir) / "CoreConsumer"
libraries = subprocess.check_output(["otool", "-L", str(binary)], text=True)
for forbidden in ("SwiftUI", "AVFAudio", "AVFoundation"):
    assert forbidden not in libraries, f"Core consumer unexpectedly links {forbidden}"
print("Core dependency graph and linked libraries verified.")
print(f"Informational debug consumer size: {binary.stat().st_size} bytes")
