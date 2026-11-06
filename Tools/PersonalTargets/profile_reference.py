#!/usr/bin/env python3
"""Generate independent evidence for one explicitly named offline target profile.

Praat supplies CPPS. The existing independent Python YIN oracle supplies raw F0;
math.fsum of original PCM supplies unweighted dBFS. No Swift output is read.
"""
import argparse
import importlib.util
import math
from pathlib import Path
import platform
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Tools/Reference"))
from common import canonical, digest, load_json, pcm_wave, read_pcm
import run as praat_runner

SPEC = importlib.util.spec_from_file_location("target_yin_oracle", ROOT / "Tools/YIN/oracle.py")
yin = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(yin)

SOURCES = ["Tools/PersonalTargets/profile_reference.py", "Tools/YIN/oracle.py",
           "Tools/Reference/common.py", "Tools/Reference/run.py", "Tools/Reference/cpps.py",
           "Tools/Reference/profiles.py", "Tools/Reference/setup.py", "Tools/Reference/voice.py",
           "Tools/Reference/Scripts/cpps.praat", "Tools/Reference/Scripts/voice.praat",
           "Tools/Reference/Profiles/cpps-murton-praat7.json", "Tools/Reference/toolchain.json"]
DEFINITION = "personal-target-offline-16k-murton7-yin50to700-level25ms-v1"
BUDGETS = {"cpps": 1e-4, "fundamentalFrequency": .001, "levelDBFS": 1e-10}


def cases():
    source = "Tests/HDXLVoiceProcessingTests/Fixtures/Calibration/take-01.wav"
    result = [{"name": f"boundary-{count}", "sourcePath": source, "sampleCount": count,
               "boundary": True}
              for count in [0, 399, 400, 640, 641, 1599, 1600, 1601, 1632, 1920]]
    result += [{"name": f"take-{index:02}",
                "sourcePath": f"Tests/HDXLVoiceProcessingTests/Fixtures/Calibration/take-{index:02}.wav",
                "sampleCount": 6400, "boundary": False} for index in [1, 2, 9, 10]]
    return result


def levels(samples):
    result = []
    start = 0
    while start + 400 <= len(samples):
        power = math.fsum(x*x for x in samples[start:start+400]) / 400
        result.append(10 * math.log10(power) if power else None)
        start += 160
    if start < len(samples):
        result.append(None)  # Explicit emit-unavailable partial window.
    return result


def generate(output):
    output = output.resolve()
    if output.exists() or not output.is_relative_to((ROOT / ".build").resolve()):
        raise ValueError("Use a fresh candidate directory under repository .build")
    lock = load_json(ROOT / "Tools/Reference/toolchain.json")
    if platform.python_version() != lock["pythonVersion"]:
        raise ValueError("Pinned Python is required")
    output.mkdir(parents=True)
    profile = yin.configuration(backend="fft")
    records = []
    for case in cases():
        source = ROOT / case["sourcePath"]
        samples, metadata = read_pcm(source)
        if metadata["sampleRate"] != 16000 or len(samples) < case["sampleCount"]:
            raise ValueError("Unexpected fixture geometry")
        samples = samples[:case["sampleCount"]]
        frames = yin.stream(samples, profile)
        frequencies = [None if row["selectedCandidateIndex"] is None else
                       row["candidates"][row["selectedCandidateIndex"]]["frequencyHz"] for row in frames]
        record = {**case, "sourceSHA256": digest(source.read_bytes()),
                  "expected": {"fundamentalFrequency": frequencies, "levelDBFS": levels(samples)},
                  "pitchStatus": [row["status"] for row in frames],
                  "cppsReference": None}
        if len(samples) >= 1600:
            input_path = output / (case["name"] + ".wav")
            input_path.write_bytes(pcm_wave(samples, 16000))
            destination = output / (case["name"] + "-praat")
            reference = praat_runner.generate(
                input_path, ROOT / "Tools/Reference/Profiles/cpps-murton-praat7.json",
                ROOT / ".build/reference-tool/7.0.02/Praat.app/Contents/MacOS/Praat",
                destination, export=False)
            # Host timing is not a deterministic numerical fixture.
            (destination / "execution.json").unlink()
            rows = reference["data"]["frames"]["smoothed"]["values"]
            record["expected"]["cpps"] = [row[-1] for row in rows]
            record["cppsReference"] = {
                "referenceIdentity": reference["referenceIdentity"],
                "rawSHA256": reference["rawOutputSHA256"],
                "manifestSHA256": digest((destination / "reference.json").read_bytes()),
                "manifestPath": destination.name + "/reference.json",
                "rawPath": destination.name + "/reference.raw.txt",
                "inputPath": input_path.name,
                "axes": reference["data"]["axes"],
            }
        else:
            record["expected"]["cpps"] = [None] if samples else []  # Typed short-interval result; never a scalar.
        records.append(record)
        print(case["name"], {k: len(v) for k, v in record["expected"].items()}, flush=True)
    result = {"schemaVersion": 1, "definition": DEFINITION,
              "referenceSources": {path: digest((ROOT / path).read_bytes()) for path in SOURCES},
              "toolchain": lock, "yinProfile": profile,
              "levelParameters": {"windowLength": 400, "hopLength": 160, "weighting": "none",
                                  "accumulation": "compensatedSliding", "partial": "emitUnavailable"},
              "cppsRecipe": "Tools/Reference/Profiles/cpps-murton-praat7.json",
              "inputPrecision": "float64", "sampleRate": 16000,
              "comparisonBudgetsAbsolute": BUDGETS,
              "cases": records}
    (output / "profile-reference.json").write_bytes(canonical(result) + b"\n")
    return result


def verify(directory):
    directory = directory.resolve()
    result = load_json(directory / "profile-reference.json")
    lock = load_json(ROOT / "Tools/Reference/toolchain.json")
    expected_sources = {path: digest((ROOT / path).read_bytes()) for path in SOURCES}
    expected_header = {
        "schemaVersion": 1, "definition": DEFINITION, "referenceSources": expected_sources,
        "toolchain": lock, "yinProfile": yin.configuration(backend="fft"),
        "levelParameters": {"windowLength": 400, "hopLength": 160, "weighting": "none",
                            "accumulation": "compensatedSliding", "partial": "emitUnavailable"},
        "cppsRecipe": "Tools/Reference/Profiles/cpps-murton-praat7.json",
        "inputPrecision": "float64", "sampleRate": 16000, "comparisonBudgetsAbsolute": BUDGETS,
    }
    if {k: v for k, v in result.items() if k != "cases"} != expected_header:
        raise ValueError("Reference definition, source, profile or budget changed")
    if len(result["cases"]) != len(cases()):
        raise ValueError("Missing/extra reference case")
    files = {"profile-reference.json"}
    for spec, item in zip(cases(), result["cases"], strict=True):
        source = ROOT / spec["sourcePath"]
        original, metadata = read_pcm(source)
        if metadata["sampleRate"] != 16000 or len(original) < spec["sampleCount"]:
            raise ValueError("Unexpected source geometry")
        samples = original[:spec["sampleCount"]]
        rows = yin.stream(samples, result["yinProfile"])
        expected = {"fundamentalFrequency": [None if row["selectedCandidateIndex"] is None else
            row["candidates"][row["selectedCandidateIndex"]]["frequencyHz"] for row in rows],
            "levelDBFS": levels(samples), "cpps": [None] if samples and len(samples) < 1600 else []}
        receipt = None
        if len(samples) >= 1600:
            folder = spec["name"] + "-praat"
            input_name = spec["name"] + ".wav"
            files.update([input_name, folder + "/reference.json", folder + "/reference.raw.txt"])
            if (directory / input_name).read_bytes() != pcm_wave(samples, 16000):
                raise ValueError("Praat input differs from original PCM")
            _, input_metadata = read_pcm(directory / input_name)
            raw_path = directory / folder / "reference.raw.txt"
            reference_path = directory / folder / "reference.json"
            reference = load_json(reference_path)
            assembled = praat_runner.assemble(
                load_json(ROOT / result["cppsRecipe"]), input_metadata, lock,
                raw_path.read_text(encoding="utf-8"), False)
            if canonical(reference) != canonical(assembled):
                raise ValueError("Praat output, identity and manifest disagree")
            expected["cpps"] = [row[-1] for row in reference["data"]["frames"]["smoothed"]["values"]]
            receipt = {"referenceIdentity": reference["referenceIdentity"],
                "rawSHA256": reference["rawOutputSHA256"],
                "manifestSHA256": digest(reference_path.read_bytes()),
                "manifestPath": folder + "/reference.json", "rawPath": folder + "/reference.raw.txt",
                "inputPath": input_name, "axes": reference["data"]["axes"]}
        rebuilt = {**spec, "sourceSHA256": digest(source.read_bytes()), "expected": expected,
                   "pitchStatus": [row["status"] for row in rows], "cppsReference": receipt}
        if canonical(item) != canonical(rebuilt):
            raise ValueError("Independent values, availability or case provenance changed")
    actual = {str(p.relative_to(directory)) for p in directory.rglob("*") if p.is_file()}
    if actual != files or any(p.is_symlink() for p in directory.rglob("*")):
        raise ValueError("Missing, extra or symlinked reference artifacts")
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["generate", "verify"])
    parser.add_argument("--directory", type=Path, required=True)
    arguments = parser.parse_args()
    result = generate(arguments.directory) if arguments.command == "generate" else verify(arguments.directory)
    print(f"{arguments.command}: {len(result['cases'])} exact-profile cases")
