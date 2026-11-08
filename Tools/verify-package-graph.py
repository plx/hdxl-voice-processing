"""Prove independent Core/Audio clients do not gain UI or development dependencies."""
import json
import re
import subprocess
from pathlib import Path

root = Path(__file__).resolve().parent.parent
package = json.loads(subprocess.check_output(["swift", "package", "dump-package"], cwd=root))
assert package["dependencies"] == [], "Runtime package must have no external dependencies"
targets = {target["name"]: target for target in package["targets"]}
assert targets["HDXLVoiceProcessing"]["dependencies"] == []
for name in ("HDXLVoiceProcessingAudio", "HDXLVoiceProcessingVisualization"):
    assert targets[name]["dependencies"] == [{"byName": ["HDXLVoiceProcessing", None]}]

for target in ("HDXLVoiceProcessing", "HDXLVoiceProcessingAudio"):
    for source in (root / "Sources" / target).rglob("*.swift"):
        imports = re.findall(
            r"\bimport\s+(?:(?:typealias|struct|class|enum|protocol|var|let|func)\s+)?([A-Za-z0-9_]+)",
            source.read_text())
        assert not any(name.startswith(("SwiftUI", "Charts", "HDXLVoiceProcessingVisualization"))
                       for name in imports), f"UI import leaked into {source.relative_to(root)}"

for name, product in (("CoreConsumer", "HDXLVoiceProcessing"),
                      ("AudioConsumer", "HDXLVoiceProcessingAudio")):
    consumer = root / "Examples" / name
    description = json.loads(subprocess.check_output(
        ["swift", "package", "describe", "--type", "json"], cwd=consumer
    ))
    target = next(target for target in description["targets"] if target["name"] == name)
    assert target["product_dependencies"] == [product]
    binary_dir = subprocess.check_output(
        ["swift", "build", "--show-bin-path"], cwd=consumer, text=True
    ).strip()
    binary = Path(binary_dir) / name
    libraries = subprocess.check_output(["otool", "-L", str(binary)], text=True)
    forbidden = ["SwiftUI", "Charts", "HDXLVoiceProcessingVisualization", "Benchmark", "jemalloc",
                 "MallocInterposer", "SwiftRuntimeInterposer"]
    if name == "CoreConsumer":
        forbidden += ["AVFAudio", "AVFoundation"]
    for module in forbidden:
        assert module not in libraries, f"{name} unexpectedly links {module}"
    print(f"{name} dependency graph and linked libraries verified.")
    print(f"Informational debug consumer size: {binary.stat().st_size} bytes")
