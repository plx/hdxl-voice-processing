#!/usr/bin/env python3
"""Run and independently validate native corpus load/decode timing, without DSP timing."""
import argparse
import json
import math
import os
from pathlib import Path
import subprocess
import sys

from corpus import (FIXTURES, ROOT, SUBSETS, canonical, new_output, prepare_long_stream,
                    read_json, require, sha, verify)

sys.path.insert(0, str(ROOT / "Tools"))
import ci


def distribution(values):
    require(len(values) == 10 and all(type(x) in (int, float) and math.isfinite(x) and x > 0 for x in values), "Invalid timing distribution")
    ordered = sorted(values)
    return {"count": len(values), "minimum": ordered[0], "median": ordered[4],
            "p95": ordered[9], "maximum": ordered[-1], "mean": math.fsum(values) / len(values),
            "quantileRule": "nearest rank; raw samples retained, ten trials do not characterize tail latency"}


def validate(records, manifest, prepared):
    require(len(records) == len(SUBSETS), "Missing or duplicate corpus workload")
    by_id = {record["id"]: record for record in manifest["fixtures"]}
    seen = set()
    manifest_hash = sha(canonical(manifest) + b"\n")
    for record in records:
        name = record["workload"]
        require(name in SUBSETS and name not in seen, "Unknown or duplicate corpus workload")
        seen.add(name)
        require(type(record["schemaVersion"]) is int and record["schemaVersion"] == 1, "Unexpected report schema")
        fixtures = [by_id[key] for key in SUBSETS[name]]
        hashes = [x["sha256"] for x in fixtures]
        counts = [x["decoded"]["sampleCount"] if x["decoded"] else 0 for x in fixtures]
        byte_count = sum(x["byteCount"] for x in fixtures)
        reasons = [x["expectedInput"]["reason"] for x in fixtures if x["expectedInput"]["reason"]]
        expected_energy = math.fsum(x["decoded"]["meanSquare"] * x["decoded"]["sampleCount"] for x in fixtures if x["decoded"])
        if name == "corpus-long-stream/v1":
            require(prepared["corpusManifestSHA256"] == manifest_hash, "Wrong prepared corpus identity")
            hashes = [prepared["outputSHA256"]]
            counts = [44100 * 60]
            byte_count = 44 + 2 * counts[0]
            reasons = []
            expected_energy = prepared["decoded"]["meanSquare"] * counts[0]
            require(prepared["continuityBoundarySamples"] == list(range(88200, 44100 * 60, 88200)), "Missing artificial join boundaries")
        require(record["fixtureIDs"] == SUBSETS[name] and record["inputSHA256"] == hashes, "Fixture identity mismatch")
        require(record["corpusManifestSHA256"] == manifest_hash, "Corpus manifest identity mismatch")
        require(record["decodedSampleCount"] == sum(counts) and record["inputByteCount"] == byte_count
                and record["decodedPCMBytes"] == sum(counts) * 8 and record["sampleRate"] == 44100, "Incorrect load/decode denominator")
        require(record["unavailableReasons"] == reasons, "Negative fixtures excluded from benchmark")
        require(record["algorithmPerformance"] is False and record["longStreamNaturalContinuity"] is False
                and record["frameLength"] is None and record["hopLength"] is None, "Misclassified corpus timing")
        require("unavailable" in record["allocations"], "Unsubstantiated allocation evidence")
        checksums = record["energyChecksums"]
        require(len(checksums) == 10 and all(type(x) in (int, float) and math.isfinite(x)
                and abs(x - expected_energy) <= max(1e-10, abs(expected_energy) * 1e-12) for x in checksums), "Decode was not fully consumed or checksum drifted")
        for key in ("loadTrialsSeconds", "decodeTrialsSeconds"):
            distribution(record[key])
    return True


def run(output):
    manifest = verify()
    output = new_output(output)
    prepared = prepare_long_stream(FIXTURES, output / "prepared")
    environment = ci.environment("release")
    ci.validate_environment(environment, read_json(ROOT / "Configuration/build.json"))
    environment["hardwareModel"] = ci.capture("sysctl", "-n", "hw.model")
    (output / "environment.json").write_bytes(canonical(environment) + b"\n")
    env = dict(os.environ, HDXL_CORPUS_PERFORMANCE="1", HDXL_CORPUS_PREPARED=str(output / "prepared"))
    command = ["swift", "test", "-c", "release", "--scratch-path", ".build/corpus-release",
               "--filter", "corpusNativeLoadingAndDecodingPerformance"]
    records = []
    with (output / "native.log").open("w") as log:
        result = subprocess.run(command, cwd=ROOT, env=env, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, text=True, check=False)
        safe = ci.redact(result.stdout).replace(str(output), "<evidence>")
        log.write(safe)
        for line in safe.splitlines():
            if line.startswith("CORPUS_PERFORMANCE "):
                records.append(json.loads(line.removeprefix("CORPUS_PERFORMANCE ")))
    require(result.returncode == 0, "Native corpus timing test failed; inspect native.log")
    validate(records, manifest, prepared)
    # Confirm the prepared artifact bytes actually match the identity consumed by Swift.
    require(sha((output / "prepared/long-stream.wav").read_bytes()) == prepared["outputSHA256"], "Prepared input changed")
    report = {
        "schemaVersion": 1, "status": "passed", "environment": environment,
        "benchmarkSourceSHA256": sha(Path(__file__).read_bytes()),
        "nativeSourceSHA256": sha((ROOT / "Tests/HDXLVoiceProcessingTests/VoiceCorpusTests.swift").read_bytes()),
        "decoderSourceSHA256": sha((ROOT / "Tests/HDXLVoiceProcessingTests/Support/VoiceCorpus.swift").read_bytes()),
        "corpusManifestSHA256": sha(canonical(manifest) + b"\n"),
        "records": records,
        "distributions": {r["workload"]: {key: distribution(r[key]) for key in ("loadTrialsSeconds", "decodeTrialsSeconds")} for r in records},
        "physicalDeviceEvidence": False, "algorithmPerformance": False,
        "registrationIssue": "https://github.com/plx/hdxl-voice-processing/issues/25",
    }
    (output / "report.json").write_bytes(canonical(report) + b"\n")
    for name, values in report["distributions"].items():
        print(f"{name}: median load {values['loadTrialsSeconds']['median']:.6f}s; decode {values['decodeTrialsSeconds']['median']:.6f}s")
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    run(args.output)
