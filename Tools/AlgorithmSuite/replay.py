#!/usr/bin/env python3
"""Compare the independent consumer's public frame sequence with the benchmark output."""

import argparse
import hashlib
import json
import os
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
    statuses = {}
    for row in rows:
        value = row.get("value")
        fingerprint = (fingerprint ^ row["sourceStart"]) * 1099511628211 & MASK
        bits = MASK if value is None else struct.unpack("<Q", struct.pack("<d", value))[0]
        fingerprint = (fingerprint ^ bits) * 1099511628211 & MASK
        status = row["status"]
        if row.get("reason") is not None:
            status += "." + row["reason"]
        statuses[status] = statuses.get(status, 0) + 1
        label = status.encode("utf-8")
        fingerprint = (fingerprint ^ len(label)) * 1099511628211 & MASK
        for byte in label:
            fingerprint = (fingerprint ^ byte) * 1099511628211 & MASK
        if value is not None:
            available += 1
            total += value
    return dict(fingerprint=fingerprint, available=available, unavailable=len(rows)-available, sum=total,
                statusCounts=statuses)


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
            if name == "filtered-harmonics":
                cases = json.loads(subprocess.check_output([checker], env=dict(
                    os.environ, VOICE_SUITE_INPUTS=str(directory), VOICE_SUITE_FIXTURE=name)))
                first = next(r["phase"] for r in cases if r.get("phase", {}).get("phase") == "firstOutput")
            for chunk in (1, 251, expected["fixture"]["sampleCount"]):
                output = json.loads(subprocess.check_output([consumer, directory / (digest + ".pcm"), str(chunk)]))
                if (output["pcmSHA256"] != digest or output["cppsProfileSHA256"] != profile_sha(profile["cpps"])
                        or output["yinProfileSHA256"] != profile_sha(profile["pitch"]["estimator"])):
                    raise ValueError(f"Consumer used different inputs or algorithms for {name}")
                lanes = {key: lane_digest([r for r in output["frames"] if r["lane"] == key])
                         for key in ("cpp", "cpps", "yin")}
                if any(not row["available"] or row != expected["results"][0]["lanes"][key] for key, row in lanes.items()):
                    raise ValueError(f"Consumer frame sequence differs for {name}/{chunk}")
                if chunk == 1 and name == "filtered-harmonics" and output["firstValidCPPSAfterSamples"] != first["sourceSamplesInsideTimer"]:
                    raise ValueError("CPPS first-output timing differs from sample-by-sample external replay")
                receipts.append(dict(fixture=name, chunk=chunk, pcmSHA256=digest, lanes=lanes,
                                     firstValidCPPSAfterSamples=output["firstValidCPPSAfterSamples"],
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
