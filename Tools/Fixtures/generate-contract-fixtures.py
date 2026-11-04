"""Reproduce schema-v1 contract examples independently of the Swift encoder.

Requires an explicit output directory. This creates candidate artifacts; it never
updates the provenance manifest or approves replacement golden outputs.
"""
import argparse
import hashlib
import json
from pathlib import Path


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def setting(kind, value):
    return {"type": kind, kind: value}


def fixtures():
    profile = {
        "schemaVersion": 1,
        "identifier": {"name": "contract-fixture", "version": 1},
        "measurement": {
            "kind": "cpps", "unit": "decibelsRatio",
            "algorithm": {"name": "fixture-cpps", "version": 1},
        },
        "inputFormat": {
            "sampleRate": 48000, "channelCount": 1,
            "encoding": "float32", "layout": "interleaved",
        },
        "channels": {"channelIndex": 0},
        "precision": "float64",
        "frameLength": 1024,
        "hopLength": 480,
        "analysisSampleRate": 48000,
        "window": {"name": "hann-symmetric", "version": 1},
        "preprocessing": {"preEmphasis": setting("real", 0.97)},
        "algorithmSettings": {
            "pitchFloorHz": setting("real", 60),
            "pitchCeilingHz": setting("real", 330),
            "smoothingTimeSeconds": setting("real", 0.02),
            "smoothingQuefrencySeconds": setting("real", 0.001),
            "fit": setting("text", "least-squares"),
            "selection": setting("text", "all"),
            "averaging": setting("text", "arithmetic-db"),
            "subtractTrendBeforeSmoothing": setting("boolean", False),
            "fftSize": setting("integer", 2048),
        },
        "partialWindowPolicy": "discard",
    }
    identity = hashlib.sha256(canonical(profile).encode("utf-8")).hexdigest()
    result = {
        "schemaVersion": 1,
        "measurement": profile["measurement"],
        "profile": {"identifier": profile["identifier"], "sha256": identity},
        "timing": {
            "source": {
                "epoch": {"streamID": "00000000-0000-0000-0000-000000000001", "sequence": 0},
                "startSample": 960, "sampleCount": 1024, "sampleRate": 48000,
            },
            "includedSampleCount": 768,
            "sourceStartSeconds": 0.02,
            "hostStartNanoseconds": 1000000000,
            "completedHostNanoseconds": 1100000000,
            "effectiveDelaySeconds": 0.03,
        },
        "outcome": {
            "status": "available",
            "estimate": {"value": 12.5, "confidence": 0.75, "warnings": ["partialCoverage"]},
        },
        "intermediatePolicy": {"maximumScalarCount": 0},
        "intermediates": [],
    }
    return {"profile-v1.json": canonical(profile) + "\n", "result-v1.json": canonical(result) + "\n"}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    for name, content in fixtures().items():
        path = args.output / name
        path.write_text(content, encoding="utf-8")
        print(f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {name}")
