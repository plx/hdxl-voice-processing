#!/usr/bin/env python3
"""Compile and audit the complete capture path with the pinned Apple toolchain."""
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Tools"))
import ci

TARGETS = {
    "macos-arm64": ("macosx", "arm64-apple-macosx27.0"),
    "ios-arm64": ("iphoneos", "arm64-apple-ios27.0"),
    "ios-simulator-arm64": ("iphonesimulator", "arm64-apple-ios27.0-simulator"),
    "ios-simulator-x86_64": ("iphonesimulator", "x86_64-apple-ios27.0-simulator"),
}


def functions(assembly):
    result = {}
    for part in re.split(r"[;#]+ -- End function", assembly):
        # Avoid metadata/data sections: compiler-emitted function begin markers
        # bound each body, independently of optional unwind directives.
        if "-- Begin function" not in part:
            continue
        part = part.rsplit("-- Begin function", 1)[1]
        lines = part.splitlines()[1:]
        label = next((line.split(":", 1)[0] for line in lines
                      if line.startswith("_") and ":" in line), None)
        if label is not None:
            result[label] = "\n".join(lines) + "\n"
    return result


def audit(assembly, architecture):
    bodies = functions(assembly)
    fragments = ("C16offerInterleaved_", "C11offerPlanar_", "C5offer33_")
    selected = {}
    for fragment in fragments:
        matches = [name for name in bodies if fragment in name]
        if len(matches) != 1:
            raise ValueError(f"Expected exactly one callback function for {fragment}")
        selected[matches[0]] = bodies[matches[0]]
    private = next(name for name in selected if "C5offer33_" in name)
    calls = {}
    for name, body in selected.items():
        direct = []
        for line in body.splitlines():
            instruction = line.strip().split()
            if not instruction or line.lstrip().startswith((";", "#", ".")):
                continue
            op = instruction[0]
            is_control = (op in ("bl", "b", "br", "blr") or op.startswith(("call", "jmp", "bra", "blra")))
            if is_control:
                target = instruction[1] if len(instruction) > 1 else ""
                if op == "b" and target.startswith("L"):
                    continue
                if op in ("jmp", "jmpq") and target.startswith("L"):
                    continue
                if target not in ({"_memmove"} if name == private else {private}):
                    raise ValueError(f"Unaudited callback call/branch: {op} {target}")
                direct.append(target)
        if name != private and direct != [private]:
            raise ValueError("Capture wrapper no longer calls exactly the audited implementation")
        calls[name] = direct
    body = selected[private]
    if architecture == "arm64":
        if len(re.findall(r"\bcasa\s", body)) != 1:
            raise ValueError("Admission must contain exactly one native strong CAS")
        for operation in ("ldclrl", "ldsetal", "stlr"):
            if not re.search(rf"\b{operation}\s", body):
                raise ValueError(f"Missing expected native atomic {operation}")
        if re.search(r"\b(?:ldxr|ldaxr|stxr|stlxr)\b", body):
            raise ValueError("Exclusive retry instructions require a new boundedness audit")
        cas = next(i for i, line in enumerate(body.splitlines()) if re.search(r"\bcasa\s", line))
    else:
        if len(re.findall(r"\bcmpxchgq\s", body)) != 1:
            raise ValueError("Admission must contain exactly one native strong CAS")
        cas = next(i for i, line in enumerate(body.splitlines()) if "cmpxchgq" in line)
    # Admission occurs before any loop. No branch may target an instruction at or
    # before it; channel validation/copy loops are bounded by the checked <=32 count.
    lines = body.splitlines()
    labels = {line.split(":", 1)[0]: i for i, line in enumerate(lines)
              if re.match(r"^L\w+:", line)}
    for line in lines:
        match = re.match(r"\s*(?:b(?:\.\w+)?|cbn?z|tbn?z|j\w+)\s+.*?\b(L\w+)\s*(?:[;#].*)?$", line)
        if match and labels.get(match[1], cas + 1) <= cas:
            raise ValueError("Admission has a software retry edge")
    return selected, {"functions": len(selected), "calls": calls,
                      "nativeSingleAttemptAdmission": True,
                      "loopBound": "two source-checked channel loops, at most 32 iterations each",
                      "copyBound": "at most maximumFramesPerChunk * channels * sample width bytes"}


def main():
    output = ROOT / ".build/transport-audit"
    if output.exists():
        shutil.rmtree(output)
    output.mkdir(parents=True, exist_ok=True)
    result = {"schemaVersion": 1, "status": "failed", "targets": {}, "commands": []}
    try:
        environment = ci.environment("release")
        ci.validate_environment(environment, json.loads((ROOT / "Configuration/build.json").read_text()))
        (output / "environment.json").write_text(ci.redact(json.dumps(environment, indent=2)) + "\n")
        sources = sorted((ROOT / "Sources/HDXLVoiceProcessing").rglob("*.swift"))
        audio = sorted((ROOT / "Sources/HDXLVoiceProcessingAudio").rglob("*.swift"))
        with (output / "commands.log").open("w") as log:
            for name, (sdk_name, target) in TARGETS.items():
                folder = output / name
                folder.mkdir(exist_ok=True)
                sdk = ci.capture("xcrun", "--sdk", sdk_name, "--show-sdk-path")
                common = ["xcrun", "swiftc", "-swift-version", "6", "-O", "-target", target,
                          "-sdk", sdk, "-module-cache-path", str(folder / "module-cache"),
                          "-package-name", "HDXLVoiceProcessing"]
                ci.run_command([*common, "-emit-module", "-parse-as-library",
                                "-module-name", "HDXLVoiceProcessing",
                                "-emit-module-path", str(folder / "HDXLVoiceProcessing.swiftmodule"),
                                *map(str, sources)], log, result["commands"])
                assembly = folder / "audio.s"
                ci.run_command([*common, "-whole-module-optimization", "-emit-assembly",
                                "-module-name", "HDXLVoiceProcessingAudio", "-I", str(folder),
                                "-o", str(assembly), *map(str, audio)], log, result["commands"])
                selected, report = audit(assembly.read_text(), target.split("-")[0])
                capture = "\n".join(selected.values())
                (folder / "capture.s").write_text(capture)
                report["captureAssemblySHA256"] = hashlib.sha256(capture.encode()).hexdigest()
                result["targets"][name] = report
        result["status"] = "passed"
    except (ValueError, RuntimeError, OSError, subprocess.SubprocessError) as error:
        result["error"] = ci.redact(str(error))
    (output / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({"status": result["status"], "targets": list(result["targets"]),
                      "error": result.get("error")}, indent=2))
    return 0 if result["status"] == "passed" else 1


if __name__ == "__main__":
    sys.exit(main())
