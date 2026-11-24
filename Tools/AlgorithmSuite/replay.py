#!/usr/bin/env python3
"""Compare the independent consumer's public frame sequence with the benchmark output."""

import argparse
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Tools"))
from AlgorithmSuite.prepare import prepare

MASK = (1 << 64) - 1


def lane_digest(rows):
    fingerprint = 14695981039346656037
    total = 0.0
    available = 0
    for row in rows:
        value = row.get("value")
        fingerprint = (fingerprint ^ row["sourceStart"]) * 1099511628211 & MASK
        bits = MASK if value is None else struct.unpack("<Q", struct.pack("<d", value))[0]
        fingerprint = (fingerprint ^ bits) * 1099511628211 & MASK
        if value is not None:
            available += 1
            total += value
    return dict(fingerprint=fingerprint, available=available, unavailable=len(rows)-available, sum=total)


def profile_sha(settings):
    return hashlib.sha256(json.dumps(settings, sort_keys=True, allow_nan=False,
                                     separators=(",", ":")).encode()).hexdigest()


def compare(checker, consumer):
    receipts = []
    with tempfile.TemporaryDirectory() as temp:
        directory = Path(temp) / "inputs"
        prepare(directory)
        for name in ("filtered-harmonics", "harmonic-low"):
            expected = json.loads(subprocess.check_output([checker, "run", directory, "full", name]))
            digest = expected["fixture"]["pcmSHA256"]
            profile = expected["recipe"]["schedule"]
            for chunk in (1, 251, expected["fixture"]["sampleCount"]):
                output = json.loads(subprocess.check_output([consumer, directory / (digest + ".pcm"), str(chunk)]))
                if (output["pcmSHA256"] != digest or output["cppsProfileSHA256"] != profile_sha(profile["cpps"])
                        or output["yinProfileSHA256"] != profile_sha(profile["pitch"]["estimator"])):
                    raise ValueError(f"Consumer used different inputs or algorithms for {name}")
                lanes = {key: lane_digest([r for r in output["frames"] if r["lane"] == key])
                         for key in ("cpp", "cpps", "yin")}
                if any(not row["available"] or row != expected["results"][0]["lanes"][key] for key, row in lanes.items()):
                    raise ValueError(f"Consumer frame sequence differs for {name}/{chunk}")
                receipts.append(dict(fixture=name, chunk=chunk, pcmSHA256=digest, lanes=lanes,
                                     cppsProfileSHA256=output["cppsProfileSHA256"], yinProfileSHA256=output["yinProfileSHA256"]))
    return receipts


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("checker", type=Path)
    parser.add_argument("consumer", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    evidence = compare(args.checker.resolve(strict=True), args.consumer.resolve(strict=True))
    with args.output.open("x") as stream:
        json.dump(evidence, stream, indent=2, allow_nan=False)
        stream.write("\n")
