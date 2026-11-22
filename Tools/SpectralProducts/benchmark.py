#!/usr/bin/env python3
"""Measure bounded spectral products and bind the distributions to the shared workload manifest."""
import argparse
from bisect import bisect_left
from dataclasses import dataclass
from collections.abc import Callable
import csv
import gzip
import json
import math
import os
from pathlib import Path
import shutil
import sys
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Tools"))
import benchmark as framework
import ci

TARGET = "SpectralProductBenchmarks"
CONTROL = "Capability.SpectralProductAllocationARC"
BOUNDARIES = {
    "Generate": "One whole PCM interval and finish, including a scalar probe per borrowed spectrum.",
    "LTAS": "Borrow precomputed ordered, eligible spectra and append them to a fresh linear-power accumulator.",
    "Retain8": "Copy each borrowed spectrum into an eight-column ring, including eviction.",
    "Retain64": "Copy each borrowed spectrum into a 64-column ring, including eviction.",
    "Export": "Make an independent owned copy of each borrowed spectrum, consuming one bin and replacing the preceding copy.",
    "CepGenerate": "Stream and finish the canonical finite-FIR preview cepstrogram, consuming one quefrency bin per row.",
    "CepRetain8": "Insert precomputed owned canonical rows into an eight-column ring with eviction.",
    "CepRetain64": "Insert precomputed owned canonical rows into a 64-column ring with eviction.",
    "CepExport": "Export each borrowed canonical power column with the public exporter, including profile checks, normalization and the unavailable tail.",
}
METRICS = {
    "wallClock": "Time (wall clock)", "cpuTotal": "Time (total CPU)",
    **dict(zip(("mallocCountTotal", "mallocBytesCount", "freeCountTotal", "objectAllocCount", "retainCount", "releaseCount"),
               framework.DIAGNOSTICS, strict=True)),
}


def write(path, data):
    path.write_text(json.dumps(data, indent=2, allow_nan=False) + "\n")


def validate_cases(records):
    expected = {(rate, seconds, width) for rate in (16000, 44100, 48000)
                for seconds in (1, 10, 60) for width in (20, 64)}
    seen = set()
    for record in records:
        rate, seconds, width = key = (record["sampleRate"], record["durationSeconds"], record["windowMilliseconds"])
        length = (rate * width + 500) // 1000
        layout = record["layout"]
        cep = record["cepstrogram"]
        cep_size = 4 * width
        if (key not in expected or key in seen or record["name"] != f"fs{rate}-s{seconds}-w{width}"
                or record["inputSamples"] != rate * seconds or record["source"]["sampleCount"] != rate * seconds
                or layout["framing"]["window"]["sampleCount"] != length or layout["framing"]["hopLength"] != length // 2
                or layout["spectrum"]["transform"]["length"] != 1 << (length - 1).bit_length()
                or layout["framing"]["window"]["precision"] != "float64"
                or record["expectedFrames"] != 1 + (rate * seconds - length) // (length // 2)
                or cep["frame"]["frameLength"] != cep_size or cep["previewHopLength"] != cep_size // 2
                or record["expectedCepstralFrames"] != 2 + (4000 * seconds - cep_size) // (cep_size // 2)):
            raise ValueError(f"Invalid spectral case {key}")
        seen.add(key)
    if seen != expected:
        raise ValueError("Incomplete spectral geometry matrix")


def validate_memory(rows):
    if len(rows) != 10:
        raise ValueError("Missing ten-minute streaming samples")
    for i, row in enumerate(rows, start=1):
        frames = 1 + (i * 60 * 48000 - 3072) // 1536
        if (row["seconds"] != i * 60 or row["retainedFrames"] != 64 or row["measuredFrames"] != frames
                or row["evictedFrames"] != frames - 64 or row["liveHeapBytes"] <= 0):
            raise ValueError("Streaming frame counts or heap observation invalid")
    heap = [row["liveHeapBytes"] for row in rows]
    if max(heap) - min(heap) > 16 * 1024 * 1024:
        raise ValueError("Live heap growth exceeded the 16 MiB synthetic regression allowance")


def histogram_percentiles(histogram):
    """Reconstruct the pinned HdrHistogram's clipped highest-equivalent values at integer percentiles."""
    counts = histogram["counts"]
    half = histogram["subBucketHalfCountMagnitude"]
    unit = histogram["unitMagnitude"]
    total, maximum = histogram["_totalCount"], histogram["maxValue"]
    if (type(half) is not int or not 0 <= half <= 20 or type(unit) is not int or not 0 <= unit <= 63
            or type(total) is not int or total <= 0 or type(maximum) is not int or maximum < 0
            or not counts or any(type(n) is not int or n < 0 for n in counts)):
        raise ValueError("Malformed histogram geometry or counts")
    cumulative, upper = [], []
    observed = 0
    first_lower = last_lower = 0
    for index, n in enumerate(counts):
        if not n:
            continue
        bucket = (index >> half) - 1
        sub = index if bucket < 0 else (index & ((1 << half) - 1)) + (1 << half)
        shift = max(0, bucket) + unit
        lower = sub << shift
        if not observed:
            first_lower = lower
        last_lower = lower
        observed += n
        cumulative.append(observed)
        upper.append(lower + (1 << shift) - 1)
    minimum = 0 if counts[0] else histogram["minNonZeroValue"]
    if (observed != total or not first_lower <= minimum <= upper[0]
            or not last_lower <= maximum <= upper[-1] or minimum > maximum):
        raise ValueError("Raw extrema or observation count contradict occupied histogram buckets")
    result = [minimum]
    for q in range(1, 100):
        rank = max(1, math.ceil(math.nextafter(float(q), 0.0) * total / 100))
        result.append(max(minimum, min(maximum, upper[bisect_left(cumulative, rank)])))
    return [*result, maximum]


def validate_control(histogram):
    if histogram["counts"][0] or histogram["minNonZeroValue"] <= 0:
        raise ValueError("Allocation capability control missed known work in a measured trial")


def validate_heap_allocations(operation, frame_count, maximum):
    # A prepared generator reuses its buffers. Allow a fixed instrumentation margin per trial.
    if operation == "Generate" and maximum > 2:
        raise ValueError(f"Prepared spectral generation allocated {maximum} times in one trial")
    # The owned destination allocates per frame. Widening a scalar must not allocate per bin.
    if operation in {"Retain8", "Retain64", "Export"} and maximum > 2 * frame_count:
        raise ValueError(f"Excessive heap allocations while copying {operation}: {maximum} for {frame_count} frames")


def product_rate(op, item, wall):
    frames = item["expectedCepstralFrames" if op.startswith("Cep") else "expectedFrames"]
    return dict(framesPerTrial=frames, sourceSeconds=item["durationSeconds"],
                framesPerSecondAtP50Latency=frames * 1e9 / wall["p50"],
                framesPerSecondAtP99Latency=frames * 1e9 / wall["p99"])


def stream_probe(checker, output):
    memory = json.loads(ci.capture(checker, "--stream-memory"))
    write(output / "long-stream.json", memory)
    validate_memory(memory)


@dataclass(frozen=True)
class SpectralBenchmarkSuite:
    target: str
    namespace: str
    control: str
    artifact: str
    checker: str
    boundaries: dict
    validate_cases: Callable
    throughput: Callable
    input_description: str
    preparation: str
    duration_statistic: str
    allocation_check: Callable | None = None
    extra_timing_probe: Callable | None = None
    comparisons: Callable | None = None
    kernel_stages: bool = False
    minimum_trials: int = 10


PRODUCTS = SpectralBenchmarkSuite(
    TARGET, "SpectralProducts", CONTROL, "spectral-products", "SpectralProductWorkloadCheck",
    BOUNDARIES, validate_cases, product_rate,
    "One binary64 mono ramp, (index % 257 - 128) / 128. Generated before timing.",
    "PCM, canonical rows, fresh workers and reference checks are outside each measurement.",
    "Outer iteration for one declared source interval, including its unavailable cepstral tail.",
    allocation_check=lambda op, record, maximum: validate_heap_allocations(op, record["expectedFrames"], maximum),
    extra_timing_probe=stream_probe)


def distributions(raw, exported, baseline, records, mode, suite=PRODUCTS):
    case_by_op = {f"{suite.namespace}.{op}.{item['name']}": (op, item) for item in records for op in suite.boundaries}
    expected = set(case_by_op)
    if mode == "allocation":
        expected.add(suite.control)
    metrics = {"wallClock", "cpuTotal"} if mode == "timing" else set(METRICS) - {"cpuTotal"}
    data, p99, rates = {}, {}, []
    results = raw["results"]
    if raw["baselineName"] != baseline or len(results) != 2 * len(expected):
        raise ValueError("Inconsistent baseline identity or result count")
    for identity, measurements in zip(results[::2], results[1::2], strict=True):
        name = identity["name"]
        if name not in expected or name in data or identity["target"] != suite.target:
            raise ValueError(f"Unexpected benchmark {name}")
        row = data[name] = {}
        for measurement in measurements:
            metric, = measurement["metric"]
            histogram = measurement["statistics"]["histogram"]
            count, maximum = histogram["_totalCount"], histogram["maxValue"]
            minimum_trials = 10 if name == suite.control else suite.minimum_trials
            if (metric not in metrics or metric in row or measurement["scalingFactor"] != 1
                    or measurement["timeUnits"] != "nanoseconds" or type(count) is not int or count < minimum_trials
                    or sum(histogram["counts"]) != count or type(maximum) is not int or maximum < 0
                    or (metric == "wallClock" or name == suite.control) and maximum == 0):
                raise ValueError(f"Invalid distribution for {name}/{metric}")
            if name == suite.control:
                validate_control(histogram)
            if metric == "mallocCountTotal" and name != suite.control and suite.allocation_check:
                operation, record = case_by_op[name]
                suite.allocation_check(operation, record, maximum)
            path = exported / f"{baseline}.{suite.target}.{name}.{metric}.histogram.percentiles.tsv"
            lines = path.read_text().splitlines()
            points = [tuple(map(int, line.split("\t"))) for line in lines[1:]]
            unit = " (ns) *" if metric in ("wallClock", "cpuTotal") else " *"
            if lines[0] != "Percentile\t" + METRICS[metric] + unit or [q for q, _ in points] != list(range(101)):
                raise ValueError(f"Incomplete percentiles for {name}/{metric}")
            quantiles = [value for _, value in points]
            if quantiles != histogram_percentiles(histogram):
                raise ValueError(f"Invalid percentiles for {name}/{metric}")
            row[metric] = dict(sampleCount=count, maximum=maximum, p50=quantiles[50], p95=quantiles[95], p99=quantiles[99])
            p99[f"{name} - {METRICS[metric]}"] = quantiles[99]
        if set(row) != metrics:
            raise ValueError(f"Missing metrics for {name}")
        if mode == "timing":
            op, item = case_by_op[name]
            rates.append(dict(operation=name, **suite.throughput(op, item, row["wallClock"])))
    return data, p99, rates


def main(suite=PRODUCTS):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("timing", "allocation"))
    parser.add_argument("--development-toolchain", action="store_true")
    args = parser.parse_args()
    mode = args.mode
    if any(key in os.environ for key in ("MALLOC_INTERPOSER_LOCAL_PATH", "RUNTIME_INTERPOSER_LOCAL_PATH",
                                         "BENCHMARK_DISABLE_MALLOC_INTERPOSER", "BENCHMARK_DISABLE_JEMALLOC",
                                         "DYLD_INSERT_LIBRARIES", "LD_PRELOAD")):
        raise ValueError("Allocator override present")
    package = framework.PACKAGE
    baseline_name = "spectral-" + uuid.uuid4().hex
    baseline = package / ".benchmarkBaselines" / suite.target / baseline_name
    output = package / ".build/artifacts" / f"{suite.artifact}-{mode}" / baseline_name
    output.mkdir(parents=True)
    print(output, flush=True)
    lock = package / "Package.resolved"
    resolution = lock.read_bytes()
    result = dict(mode=mode, status="failed", commands=[])
    try:
        flags = framework.swift_arguments(mode)
        if suite.kernel_stages:
            if "--traits" in flags:
                flags[flags.index("--traits") + 1] += ",KernelBenchmarks"
            else:
                flags += ["--traits", "KernelBenchmarks"]
        environment = framework.measurement_environment(mode, swift_pm_arguments=flags)
        if not args.development_toolchain:
            ci.validate_environment(environment, json.loads((ROOT / "Configuration/build.json").read_bytes()))
        environment.update(operations=suite.boundaries, frameworkScalingFactor=1,
                           toolchainPolicy="development" if args.development_toolchain else "pinned",
                           input=suite.input_description,
                           preparation=suite.preparation,
                           durationStatistic=suite.duration_statistic,
                           packageResolvedSHA256=framework.sha(lock))
        (output / "environment.json").write_text(ci.redact(json.dumps(environment, indent=2)) + "\n")
        (output / "resolution.json").write_bytes(resolution)
        plugin = ["swift", "package", *flags, "--allow-writing-to-package-directory", "benchmark", "--target", suite.target,
                  "--time-units", "nanoseconds", "--no-progress"]
        with (output / "commands.log").open("w") as log:
            def run(args):
                ci.run_command(args, log, result["commands"])
            run(["swift", "build", *flags, "--product", suite.checker])
            binaries = Path(ci.capture("swift", "build", *flags, "--show-bin-path"))
            checker = str(binaries / suite.checker)
            records = json.loads(ci.capture(checker))
            suite.validate_cases(records)
            write(output / "workloads.json", records)
            if mode == "timing" and suite.extra_timing_probe:
                suite.extra_timing_probe(checker, output)
            run([*plugin, "baseline", "update", baseline_name])
            raw = json.loads((baseline / "results.json").read_bytes())
            raw["machine"]["hostname"] = "<host>"
            with gzip.open(output / "raw-baseline.json.gz", "wt") as stream:
                json.dump(raw, stream, separators=(",", ":"), allow_nan=False)
            result["binary"] = framework.inspect_binary(binaries / suite.target, mode)
            result["binary"]["sha256"] = framework.sha(binaries / suite.target)
            with tempfile.TemporaryDirectory(dir=output) as temp:
                run([*plugin, "baseline", "read", baseline_name, "--format", "histogramPercentiles", "--path", temp])
                data, p99, rates = distributions(raw, Path(temp), baseline_name, records, mode, suite)
            write(output / "distributions.json", data)
            write(output / "p99.json", p99)
            if suite.comparisons:
                write(output / "comparisons.json", suite.comparisons(data, records, mode))
            if rates:
                with (output / "throughput.csv").open("w", newline="") as stream:
                    writer = csv.DictWriter(stream, fieldnames=list(rates[0]))
                    writer.writeheader()
                    writer.writerows(rates)
            if lock.read_bytes() != resolution:
                raise ValueError("Locked dependency resolution changed")
            result.update(status="passed", workloadManifestSHA256=framework.write_workload_manifest(output, mode),
                          benchmarkCount=len(data), rawBaselineSHA256=framework.sha(output / "raw-baseline.json.gz"))
    finally:
        if baseline.exists():
            shutil.rmtree(baseline)
        write(output / "result.json", result)


if __name__ == "__main__":
    main()
