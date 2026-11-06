#!/usr/bin/env python3
"""Generate original, deterministic C01 demonstration audio, never human speech."""
import argparse
import hashlib
import json
from pathlib import Path
import struct

VERSION = 1
RATE = 16000
SAMPLES = 6400
TASKS = ("sustainedVowel", "mostlyVoicedSentence", "repeatedOrdinaryPassage", "novelPassage")


def canonical(value):
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False) + "\n").encode()


def sha(data):
    return hashlib.sha256(data).hexdigest()


def identifier(number):
    return f"00000000-0000-0000-0000-{number:012d}"


def wav(samples):
    payload = struct.pack(f"<{len(samples)}h", *samples)
    return (b"RIFF" + struct.pack("<I", 36 + len(payload)) + b"WAVEfmt "
            + struct.pack("<IHHIIHH", 16, 1, 1, RATE, RATE * 2, 2, 16)
            + b"data" + struct.pack("<I", len(payload)) + payload)


def synthesize(index, task, repetition, instruction):
    # Integer triangle plus deterministic low-amplitude noise: exact across Python
    # hosts, without libm rounding differences. This is not a model of preference.
    period = (80, 100, 128)[(index - 1) % 3]
    amplitude = 5000 + 250 * index + (1000 if instruction == "preferred" else 0)
    state = index
    result = []
    for sample in range(SAMPLES):
        phase = sample % period
        triangle = 4 * abs(phase - period // 2) - period
        state = (1664525 * state + 1013904223) & 0xFFFFFFFF
        noise = ((state >> 16) % 81) - 40
        value = amplitude * triangle // period + noise
        # Explicit artificial gaps exercise different selected/voiced populations.
        # These are not language, word, phoneme, or actual voiced-fraction labels.
        if task != "sustainedVowel" and 2000 <= sample < 2400:
            value = 0
        if task == "novelPassage" and 4400 <= sample < 4800:
            value = noise
        result.append(value)
    return result, period, amplitude


def generate():
    outputs = {}
    takes = []
    index = 0
    for task in TASKS:
        for repetition in (1, 2):
            for instruction in ("usual", "preferred"):
                index += 1
                samples, period, amplitude = synthesize(index, task, repetition, instruction)
                data = wav(samples)
                filename = f"take-{index:02d}.wav"
                outputs[filename] = data
                # Deliberate contradiction, uncertainty, and an "other" label.
                label = {2: "usual", 6: "other", 11: "uncertain"}.get(index, instruction)
                takes.append({
                    "id": identifier(index), "mediaID": f"synthetic-take-{index:02d}",
                    "recordingID": identifier(index + 100), "sessionID": identifier(200 if index <= 12 else 201),
                    "task": task, "promptID": f"synthetic-{task}", "repetition": repetition,
                    "instruction": instruction, "listeningLabel": label, "confidence": 0.75,
                    "filename": filename, "sha256": sha(data), "byteCount": len(data),
                    "sampleCount": len(samples), "sampleRate": RATE,
                    "nominalPeriodSamples": period, "nominalFundamentalHz": RATE / period,
                    "amplitudeInteger": amplitude,
                    "routeID": "synthetic-generator-v1", "roomID": "no-physical-room",
                    "selectedStartSample": 160 if index == 9 else 0,
                    "sourceStartSample": 0,
                    "notes": "Illustrative scripted label; no listener, human voice, or preferred-direction evidence.",
                })
    manifest = {
        "schemaVersion": 1, "generatorVersion": VERSION,
        "generatorSHA256": sha(Path(__file__).read_bytes()),
        "datasetID": identifier(300), "evaluationSessionID": identifier(201),
        "splitSeed": 47, "recordingEvaluationFraction": 0.25,
        "containsHumanVoice": False,
        "interpretation": "Synthetic contract and workflow demonstration; task names exercise metadata, not linguistic content or preference validity.",
        "transformations": ["Integer triangle plus seeded LCG noise, artificial task-dependent gaps", "PCM16 little-endian mono at 16000 Hz; no normalization or resampling"],
        "takes": takes,
    }
    outputs["manifest.json"] = canonical(manifest)
    return outputs


def verify(directory):
    outputs = generate()
    present = {p.name for p in directory.iterdir() if p.is_file() and p.suffix != ".md"}
    if present != set(outputs):
        raise ValueError("Missing or extra calibration fixture artifacts")
    for name, expected in outputs.items():
        path = directory / name
        if path.is_symlink() or path.read_bytes() != expected:
            raise ValueError(f"Calibration fixture differs from its generator: {name}")
    return json.loads(outputs["manifest.json"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("generate", "verify"))
    parser.add_argument("--directory", type=Path, required=True)
    args = parser.parse_args()
    if args.mode == "generate":
        args.directory.mkdir(parents=True, exist_ok=False)
        for name, data in generate().items():
            (args.directory / name).write_bytes(data)
    else:
        manifest = verify(args.directory)
        print(f"Verified {len(manifest['takes'])} original synthetic calibration recordings")


if __name__ == "__main__":
    main()
