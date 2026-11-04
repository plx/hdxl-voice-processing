#!/usr/bin/env python3
"""Measure synthesis separately or prepare immutable PCM for future analysis benchmarks (#25)."""
import argparse
import hashlib
import math
from pathlib import Path
import platform
import subprocess
import time

from catalog import signal, harmonics
from generate import implementation, fresh_output
from synthetic import Renderer, canonical, sha256, write_json, pcm_bytes, wave_header, require


def workloads():
    result = []
    for duration in (1, 10, 60, 300):
        for rate in (16000, 44100, 48000):
            for f0 in (50, 600):
                name = f"synthetic-{duration}s-{rate}hz-f0-{f0}"
                recipe = signal(name, harmonics(f0, (1, 2, 3, 5), [0.125, 0.0625, 0.03125, 0.015625]),
                                count=rate * duration, rate=rate)
                result.append({"id": name, "recipe": recipe, "sourceF0Hz": f0,
                               "durationSeconds": duration, "sampleRate": rate,
                               "precision": "float64", "blockSamples": 4096,
                               "suggestedAnalysis": {"frameSamples": round(rate * 0.04), "hopSamples": round(rate * 0.01),
                                                     "status": "registration only; algorithm-specific profiles belong to #25"}})
    return result


def distribution(values):
    require(bool(values) and all(math.isfinite(v) and v >= 0 for v in values), "Invalid timing distribution")
    ordered = sorted(values)
    def percentile(p):
        return ordered[max(0, math.ceil(p * len(ordered)) - 1)]
    return {"count": len(values), "minimum": ordered[0], "median": percentile(0.5),
            "p95": percentile(0.95), "p99": percentile(0.99), "maximum": ordered[-1],
            "mean": math.fsum(values) / len(values), "quantileRule": "nearest rank"}


def environment():
    model = subprocess.check_output(["sysctl", "-n", "hw.model"], text=True).strip() if platform.system() == "Darwin" else "unavailable"
    return {"os": platform.system(), "osRelease": platform.release(), "architecture": platform.machine(),
            "hardwareModel": model, "python": platform.python_version(),
            "allocations": {"status": "unavailable", "reason": "no audited Python allocator backend; no zero-allocation claim"},
            "physicalDeviceEvidence": False}


def trial(workload, output=None):
    """Bounded memory; exact support, continuous phase/state across uneven final blocks."""
    recipe, block = workload["recipe"], workload["blockSamples"]
    started = time.perf_counter_ns()
    renderer = Renderer(recipe)
    setup = (time.perf_counter_ns() - started) / 1e9
    digest = hashlib.sha256()
    header = wave_header(recipe["sampleRate"], recipe["sampleCount"])
    artifact_hash = hashlib.sha256(header)
    stream = output.open("xb") if output is not None else None
    full, partial, serialization, io_times = [], [], [], []
    total_started = time.perf_counter_ns()
    try:
        if stream:
            t = time.perf_counter_ns()
            stream.write(header)
            io_times.append((time.perf_counter_ns() - t) / 1e9)
        while renderer.position < renderer.count:
            t = time.perf_counter_ns()
            samples = renderer.read(block)
            elapsed = (time.perf_counter_ns() - t) / 1e9
            (full if len(samples) == block else partial).append(elapsed)
            t = time.perf_counter_ns()
            data = pcm_bytes(samples)
            digest.update(data)
            artifact_hash.update(data)
            serialization.append((time.perf_counter_ns() - t) / 1e9)
            if stream:
                t = time.perf_counter_ns()
                stream.write(data)
                io_times.append((time.perf_counter_ns() - t) / 1e9)
        if stream:
            t = time.perf_counter_ns()
            stream.close()
            io_times.append((time.perf_counter_ns() - t) / 1e9)
    finally:
        if stream and not stream.closed:
            stream.close()
    total = (time.perf_counter_ns() - total_started) / 1e9
    render_seconds = math.fsum(full + partial)
    return {"setupSeconds": setup, "renderSeconds": render_seconds, "loopWallSeconds": total,
            "samplesPerRenderSecond": renderer.count / render_seconds,
            "audioSecondsPerRenderSecond": workload["durationSeconds"] / render_seconds,
            "fullBlockLatencySeconds": distribution(full) if full else None,
            "partialBlockLatencySeconds": distribution(partial) if partial else None,
            "serializationAndHashSeconds": math.fsum(serialization), "fileWriteSeconds": math.fsum(io_times),
            "normalizedFloat64LESHA256": digest.hexdigest(), "artifactSHA256": artifact_hash.hexdigest(),
            "finalState": renderer.snapshot()}


def run(output, mode, selected, trials):
    output = fresh_output(output)
    engine = implementation()
    host = environment()
    output.mkdir()
    records = []
    for workload in selected:
        settings = {"workload": workload, "generatorSHA256": engine["sha256"]}
        identity = sha256(canonical(settings))
        measurements = []
        for _ in range(trials if mode == "generation" else 1):
            measurements.append(trial(workload, output / (workload["id"] + ".wav") if mode == "prepare" else None))
        require(len({m["normalizedFloat64LESHA256"] for m in measurements}) == 1, "Synthesis drift across trials")
        record = {**settings, "workloadIdentity": identity, "measurements": measurements,
                  "renderSecondsDistribution": distribution([m["renderSeconds"] for m in measurements]),
                  "throughputSamplesPerSecondDistribution": distribution([m["samplesPerRenderSecond"] for m in measurements]),
                  "artifact": workload["id"] + ".wav" if mode == "prepare" else None,
                  "consumptionRule": "Validate workload/PCM hashes and load or mmap BEFORE native timed analysis; never call synthesis inside the timed loop"}
        write_json(output / (workload["id"] + ".json"), record)
        records.append({"id": workload["id"], "workloadIdentity": identity,
                        "normalizedFloat64LESHA256": measurements[0]["normalizedFloat64LESHA256"]})
        print(f"{workload['id']}: {len(measurements)} trial(s), median render {record['renderSecondsDistribution']['median']:.6f}s", flush=True)
    report = {"schemaVersion": 1, "mode": mode, "environment": host, "generator": engine,
              "benchmarkSourceSHA256": sha256(Path(__file__).read_bytes()), "workloads": records,
              "timing": {"clock": "perf_counter_ns monotonic", "setup": "validation, coefficient and oscillator-table construction",
                         "steadyState": "Renderer.read only, includes output-list allocation; excludes setup, serialization, hashing, I/O and analysis",
                         "serialization": "PCM validation/Float64 packing plus PCM/WAVE SHA256 updates",
                         "fileWrite": "buffered writes and close; no fsync/durable-storage claim",
                         "loopWall": "all block work after setup, includes timing/list bookkeeping and I/O when preparing"},
              "analysisExecuted": False, "registrationIssue": "https://github.com/plx/hdxl-voice-processing/issues/25"}
    write_json(output / "report.json", report)
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=("generation", "prepare"), default="generation")
    parser.add_argument("--matrix", choices=("smoke", "full"), default="smoke")
    parser.add_argument("--workload", help="Exact registered workload id; overrides matrix")
    parser.add_argument("--trials", type=int, default=3)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    require(1 <= args.trials <= 10, "Trial count must be 1...10")
    selected = [w for w in workloads() if w["id"] == args.workload] if args.workload else [w for w in workloads() if args.matrix == "full" or w["durationSeconds"] == 1]
    require(bool(selected), "Unknown workload")
    run(args.output, args.mode, selected, args.trials)
