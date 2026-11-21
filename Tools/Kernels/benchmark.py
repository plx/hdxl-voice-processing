#!/usr/bin/env python3
"""Measure production DSP kernels using one calibrated plan for clean timing and allocation diagnostics."""

import argparse
import csv
from collections import defaultdict
import gzip
import hashlib
import json
import math
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Tools"))
import benchmark as framework  # noqa: E402 - use the repository's shared benchmark driver
import ci  # noqa: E402

PACKAGE = ROOT / "Benchmarks"
TARGET = "DSPKernelBenchmarks"
CONTROL = "Capability.KernelAllocationARC"
HEAP = {"mallocCountTotal", "mallocBytesCount", "objectAllocCount"}
DIAGNOSTICS = HEAP | {"freeCountTotal", "retainCount", "releaseCount"}
METRIC_NAMES = dict(
    zip(
        (
            "mallocCountTotal",
            "mallocBytesCount",
            "freeCountTotal",
            "objectAllocCount",
            "retainCount",
            "releaseCount",
        ),
        framework.DIAGNOSTICS,
        strict=True,
    )
)
METRIC_NAMES.update(wallClock="Time (wall clock)", cpuTotal="Time (total CPU)")
PREPARATION = {"fftPrepare", "filterPrepare", "resamplerPrepare"}
BOUNDARIES = {
    "control": "Empty non-inlined scalar call with loop, checksum and result consumption.",
    "ringWriteContiguous": "One full contiguous write into prepared frame storage and one scalar read.",
    "ringWriteWrapped": "One full write split at the ring boundary and one scalar read.",
    "ringReadContiguous": "One contiguous suffix copied to the preallocated emission buffer and sampled.",
    "ringReadWrapped": "One suffix spanning the ring boundary copied into the emission buffer and sampled.",
    "ringOverlap": "Append one hop and copy one overlapping window from the ring to the emission buffer.",
    "windowCopy": "Window from immutable input into separate prepared storage.",
    "windowInPlace": "Window freshly restored input at its original address.",
    "ownedWindow": "Allocate an owned Array copy of a borrowed window and retain it until replacement.",
    "interleavedSelect": "Select the second interleaved channel into prepared mono scratch.",
    "interleavedMix": "Compute the production compensated mean of two interleaved channels.",
    "planarSelect": "Select the second borrowed plane into prepared mono scratch.",
    "planarMix": "Compute the production compensated mean of two borrowed planes.",
    "levelReduction": "Scaled sum of squares, RMS scalar materialization and sampling.",
    "filterPrepare": "Derive K-weighting coefficients and initialize shelf and high-pass state.",
    "filter": "Apply both K-weighting sections to PCM using freshly reset filter history.",
    "meanRemoval": "Compensated binary64 mean subtraction into the cepstrum worker's window scratch.",
    "preEmphasis": "Apply the configured first difference to restored resampler output in place.",
    "resamplerPrepare": "Prepare and destroy the whole-interval resampler, tables, FFT plans and scratch.",
    "resample": "Convert one complete input at its rational sample-rate ratio with a prepared workspace.",
    "fftPrepare": "Create and destroy the FFT plan, scalar workspace and profile identity.",
    "splitReal": "Pack even and odd real samples into split-complex storage including approved zero padding.",
    "fftForward": "Prepared public forward real FFT, including validation, packing and normalization.",
    "fftInverse": "Prepared public inverse real FFT from a fixed complex spectrum into time samples.",
    "magnitude": "Convert prepared complex bins to raw one-sided magnitudes.",
    "power": "Convert prepared complex bins to one-sided window-normalized power.",
    "logPower": "Write natural-log spectral powers and inverse bins with the production Nyquist exception.",
    "inverseCepstrum": "Inverse transform a prepared log spectrum and scale signed real cepstral coefficients by the sample rate.",
    "peakDiscrete": "CPP bidirectional discrete peak selection on prepared decibels.",
    "peakParabolic": "CPP bidirectional peak selection with parabolic interpolation on the same decibels.",
    "backgroundFit": "Compute the configured CPP background slope and intercept on prepared decibels.",
}


def write(path, data):
    path.write_text(json.dumps(data, indent=2, allow_nan=False) + "\n")


def swift(mode):
    traits = "KernelBenchmarks" if mode == "timing" else "KernelBenchmarks,AllocationDiagnostics"
    return [
        "--package-path",
        str(PACKAGE),
        "--scratch-path",
        str(ROOT / ".build" / f"b03-kernel-{mode}"),
        "--force-resolved-versions",
        "--traits",
        traits,
        "-c",
        "release",
    ]


def unit(item, record=None):
    op = item["operation"]
    if op == "backgroundFit":
        return "fit point", record["fitPoints"]
    if op in ("peakDiscrete", "peakParabolic"):
        return "search bin", record["searchBins"]
    if op == "control" or op in PREPARATION:
        return None, None
    if op in {"preEmphasis", "resample"}:
        return "conditioned output sample", item["outputSamples"]
    if op in {"magnitude", "power", "fftInverse", "logPower", "inverseCepstrum"}:
        return "input bin", item["transformLength"] // 2 + 1
    if op == "ringOverlap":
        return "new ingress sample", item["hop"]
    return "input frame" if op.startswith(("planar", "interleaved")) else "input sample", item["inputSamples"]


def case_id(item):
    fields = [
        item["operation"],
        item["precision"],
        f"{item['sourceRate']}Hz",
        f"in{item['inputSamples']}",
        f"out{item['outputSamples']}",
    ]
    for key, prefix, suffix in [
        ("transformLength", "fft", ""),
        ("hop", "hop", ""),
        ("targetRate", "to", "Hz"),
        ("fitMethod", "", ""),
        ("controlBatch", "batch", ""),
    ]:
        if key in item:
            fields.append(f"{prefix}{item[key]}{suffix}")
    fields.append("nearFloor" if item["nearFloor"] else "normal")
    return ".".join(fields)


def validate_plan(rows):
    names = set()
    geometries = defaultdict(set)
    control_counts = set()
    for row in rows:
        item, count = row["workload"], row["operationsPerBatch"]
        median = row["calibrationMedianNanoseconds"]
        if (
            row["name"] in names
            or row["name"] != item["name"]
            or row["generator"] != "kernel-analytic-v1"
            or type(count) is not int
            or not 1 <= count <= 128
            or count & (count - 1)
            or case_id(item) != row["name"]
            or type(median) is not int
            or median < 0
            or type(item["nearFloor"]) is not bool
            or not all(
                type(row[k]) in (int, float) and math.isfinite(row[k])
                for k in ("expectedSample", "verifiedSample")
            )
        ):
            raise ValueError(f"Invalid calibration record {row['name']}")
        op = item["operation"]
        is_float = item["precision"] == "float32"
        if not math.isclose(
            row["expectedSample"],
            row["verifiedSample"],
            rel_tol=2e-5 if is_float else 1e-10,
            abs_tol=8 * (2**-149 if is_float else 2**-1074),
        ):
            raise ValueError(f"Incorrect reference output for {row['name']}")
        if op in ("preEmphasis", "resample", "resamplerPrepare"):
            target = item.get("targetRate")
            if target != 10_000 or item["outputSamples"] != (
                2 * item["inputSamples"] * target + item["sourceRate"]
            ) // (2 * item["sourceRate"]):
                raise ValueError(f"Incorrect resampling denominator for {row['name']}")
        calibrated = 1
        while calibrated < 128 and calibrated * median < 50_000:
            calibrated *= 2
        if op == "control":
            calibrated = item["controlBatch"]
            control_counts.add(calibrated)
        if count != calibrated:
            raise ValueError(f"Batch count disagrees with calibration for {row['name']}")
        names.add(row["name"])
        geometries[op].add(
            (
                item["precision"],
                item["sourceRate"],
                item["inputSamples"],
                item.get("hop"),
                item.get("transformLength"),
                item["nearFloor"],
                item.get("fitMethod"),
            )
        )
    if geometries.keys() != BOUNDARIES.keys() or control_counts != {1, 2, 4, 8, 16, 32, 64, 128}:
        raise ValueError("Missing kernel or empty-loop control")
    # These rates and windows are those enumerated by the shipping profile matrices.
    # Use integer arithmetic to reproduce nearest/away-from-zero half-sample quantization.
    presets = {
        (r, (r * ms + 500) // 1000, (r * hop + 500) // 1000)
        for r in (16_000, 44_100, 48_000)
        for ms in (20, 50, 100)
        for hop in (2, 5, 10, 30)
    }
    presets |= {(r, 131_072, (2 * r + 500) // 1000) for r in (16_000, 44_100, 48_000)}
    presets |= {(r, r // 10, r * hop // 1000) for r in (5000, 10_000, 20_000) for hop in (2, 5, 10, 30)}
    precisions = ("float32", "float64")
    for op in (
        "windowCopy",
        "windowInPlace",
        "ownedWindow",
        "ringReadContiguous",
        "ringReadWrapped",
        "ringWriteContiguous",
        "ringWriteWrapped",
        "ringOverlap",
    ):
        expected = {
            (p, r, n, h, None, False, None)
            for p in precisions
            for r, n, h in presets
            if op != "ringOverlap" or h < n
        }
        if geometries[op] != expected:
            raise ValueError(f"Incomplete or unexpected framing grid for {op}")
    for op in ("interleavedSelect", "interleavedMix", "planarSelect", "planarMix"):
        if geometries[op] != {
            (p, 48_000, n, None, None, False, None) for p in precisions for n in (17, 64, 256, 1024)
        }:
            raise ValueError(f"Incomplete ingress grid for {op}")
    for op in ("fftPrepare", "splitReal", "fftForward", "fftInverse", "magnitude", "power"):
        sizes = {(n, low) for n in (320, 1000, 1024) for low in (False, True)}
        if op not in ("magnitude", "power"):
            sizes |= {(n, False) for n in (2, 4, 8, 16, 64)}
        if geometries[op] != {
            (p, 16_000, n, None, 1 << (n - 1).bit_length(), low, None) for p in precisions for n, low in sizes
        }:
            raise ValueError(f"Incomplete precision or padding grid for {op}")
    for op in (
        "meanRemoval",
        "logPower",
        "inverseCepstrum",
        "peakDiscrete",
        "peakParabolic",
        "backgroundFit",
    ):
        methods = (
            ("leastSquares", "praat7002Robust", "siegelRepeatedMedian", "completeTheilSen")
            if op == "backgroundFit"
            else (None,)
        )
        levels = (False, True) if op in ("meanRemoval", "logPower", "inverseCepstrum") else (False,)
        expected = {
            ("float64", r, r // 10, None, 1 << (r // 10 - 1).bit_length(), low, fit)
            for r in (5000, 10_000, 20_000)
            for low in levels
            for fit in methods
        }
        if geometries[op] != expected:
            raise ValueError(f"Incomplete CPP or cepstrum grid for {op}")
    for op in ("levelReduction", "filter", "filterPrepare"):
        if geometries[op] != {
            (p, 48_000, 256, None, None, low, None) for p in precisions for low in (False, True)
        }:
            raise ValueError(f"Incomplete filter/level grid for {op}")
    for op in ("preEmphasis", "resamplerPrepare", "resample"):
        if geometries[op] != {
            (p, r, 1024, None, 4096, False, None) for p in precisions for r in (16_000, 44_100, 48_000)
        }:
            raise ValueError(f"Incomplete conditioning grid for {op}")


def distributions(raw, records, mode, exported, baseline):
    names = {"Kernel." + r["name"]: r for r in records}
    expected = set(names) | ({CONTROL} if mode == "allocation" else set())
    metrics = {"wallClock", "cpuTotal"} if mode == "timing" else {"wallClock", *DIAGNOSTICS}
    raw_names = {f"{name} (batch: {r['operationsPerBatch']})": name for name, r in names.items()}
    if mode == "allocation":
        raw_names[CONTROL] = CONTROL
    results = raw["results"]
    if raw["baselineName"] != baseline or len(results) != 2 * len(expected):
        raise ValueError("Incorrect raw baseline or workload count")
    summary, p99 = {}, {}
    for info, values in zip(results[::2], results[1::2], strict=True):
        raw_name = info["name"]
        name = raw_names.get(raw_name)
        if info["target"] != TARGET or name not in expected or name in summary:
            raise ValueError(f"Unexpected benchmark {name}")
        row = summary[name] = {}
        for m in values:
            tags = {} if name == CONTROL else {"batch": str(names[name]["operationsPerBatch"])}
            if (
                m.get("tags") != tags
                or len(m["metric"]) != 1
                or m["scalingFactor"] != 1
                or m["timeUnits"] != "nanoseconds"
            ):
                raise ValueError(f"Unexpected framework scaling or time unit for {name}")
            metric = next(iter(m["metric"]))
            hist = m["statistics"]["histogram"]
            count, maximum = hist["_totalCount"], hist["maxValue"]
            if (
                metric not in metrics
                or metric in row
                or type(count) is not int
                or count < 10
                or type(maximum) is not int
                or maximum < 0
                or sum(hist["counts"]) != count
            ):
                raise ValueError(f"Invalid raw distribution for {name} {metric}")
            if metric == "wallClock" and maximum == 0:
                raise ValueError(f"Missing wall measurement for {name}")
            if mode == "allocation":
                if name == CONTROL and metric in DIAGNOSTICS and maximum == 0:
                    raise ValueError(f"Inactive diagnostic backend for {metric}")
                if name != CONTROL and metric in HEAP:
                    op = names[name]["workload"]["operation"]
                    if op not in PREPARATION | {"ownedWindow"} and maximum != 0:
                        raise ValueError(f"Allocated in prepared path {name} {metric}: maximum {maximum}")
                    if op == "ownedWindow" and metric == "mallocCountTotal" and maximum == 0:
                        raise ValueError(f"Owned output allocation was not observed for {name}")
            filename = f"{baseline}.{TARGET}.{raw_name}.{metric}.histogram.percentiles.tsv".replace(" ", "_")
            path = exported / filename
            lines = path.read_text().splitlines()
            if len(lines) != 102 or not lines[0].startswith("Percentile\t"):
                raise ValueError(f"Invalid framework percentile export for {name}")
            quantiles = [line.split("\t") for line in lines[1:]]
            if [int(q) for q, _ in quantiles] != list(range(101)):
                raise ValueError(f"Missing framework percentile for {name}")
            selected = {f"p{q}": int(quantiles[q][1]) for q in (50, 95, 99)}
            if not 0 <= selected["p50"] <= selected["p95"] <= selected["p99"]:
                raise ValueError(f"Invalid percentiles for {name} {metric}")
            row[metric] = dict(sampleCount=count, maximum=maximum, **selected)
            p99[f"{name} - {METRIC_NAMES[metric]}"] = selected["p99"]
        if set(row) != metrics:
            raise ValueError(f"Missing metrics for {name}")
    return summary, p99


def measure(mode, root, plan_path, records, pinned):
    output = root / ("kernels-" + mode)
    output.mkdir()
    lock = PACKAGE / "Package.resolved"
    resolution = lock.read_bytes()
    base_name = "b03-" + uuid.uuid4().hex[:12]
    baseline = PACKAGE / ".benchmarkBaselines" / TARGET / base_name
    result = dict(schemaVersion=1, status="failed", mode=mode, commands=[])
    try:
        env = framework.measurement_environment(mode)
        if pinned:
            ci.validate_environment(env, json.loads((ROOT / "Configuration/build.json").read_bytes()))
        env.update(
            mode=mode,
            frameworkScalingFactor=1,
            operations=BOUNDARIES,
            calibrationSHA256=framework.sha(plan_path),
            toolchainPolicy="pinned" if pinned else "development",
            packageResolvedSHA256=hashlib.sha256(resolution).hexdigest(),
            exportStatistic="Unscaled per-batch distribution. Division by batch size gives a mean within that batch.",
            fixture="kernel-analytic-v1: deterministic real/complex, polynomial, impulse and PCM fixtures",
            measurement="Fixtures, reference computations and restoration of mutable inputs precede the timer. The measured loop consumes a scalar; verification follows the timer.",
        )
        write(output / "environment.json", env)
        (output / "resolution.json").write_bytes(resolution)
        shutil.copyfile(plan_path, output / "workloads.json")
        flags = swift(mode)
        plugin = [
            "swift",
            "package",
            *flags,
            "--allow-writing-to-package-directory",
            "benchmark",
            "--target",
            TARGET,
            "--time-units",
            "nanoseconds",
            "--no-progress",
        ]
        with (output / "commands.log").open("w") as log:

            def run(args):
                ci.run_command(args, log, result["commands"])

            run([*plugin, "baseline", "update", base_name])
            raw = json.loads((baseline / "results.json").read_bytes())
            raw["machine"]["hostname"] = "<host>"
            with gzip.open(output / "raw-baseline.json.gz", "wt") as stream:
                json.dump(raw, stream, separators=(",", ":"), allow_nan=False)
            binary = Path(ci.capture("swift", "build", *flags, "--show-bin-path")) / TARGET
            result["binary"] = framework.inspect_binary(binary, mode)
            with tempfile.TemporaryDirectory(dir=output) as temp:
                run(
                    [
                        *plugin,
                        "baseline",
                        "read",
                        base_name,
                        "--format",
                        "histogramPercentiles",
                        "--path",
                        temp,
                    ]
                )
                distribution, p99 = distributions(raw, records, mode, Path(temp), base_name)
            write(output / "distributions.json", distribution)
            write(output / "p99.json", p99)
            result.update(
                workloadManifestSHA256=framework.write_workload_manifest(output, mode),
                status="passed",
                uniqueMeasurements=len(distribution),
            )
    except (OSError, RuntimeError, KeyError, ValueError, subprocess.SubprocessError) as error:
        result["error"] = ci.redact(str(error))
        raise
    finally:
        if baseline.exists():
            shutil.rmtree(baseline)
        if lock.read_bytes() != resolution:
            result.update(status="failed", error="Pinned dependency lock changed")
        write(output / "result.json", result)
    if result["status"] != "passed":
        raise ValueError("Invalid benchmark result")
    return distribution


def table(path, records, timing, allocation):
    columns = [
        "case",
        "sourceRateHz",
        "sourceWindowSamples",
        "fftLength",
        "hopSamples",
        "unit",
        "unitsPerOperation",
        "fitSlopeEvaluations",
        "operationsPerBatch",
        "observations",
        "batchP50ns",
        "batchP95ns",
        "batchP99ns",
        "meanNsPerOperationInP50Batch",
        "meanNsPerUnitInP50Batch",
        "maxMallocCountPerBatch",
        "maxMallocBytesPerBatch",
        "maxObjectsPerBatch",
        "meanMallocCountPerOperationInMaxBatch",
        "meanMallocBytesPerOperationInMaxBatch",
    ]
    with path.open("w", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=columns)
        writer.writeheader()
        for r in records:
            name = "Kernel." + r["name"]
            batch = r["operationsPerBatch"]
            measure = timing[name]["wallClock"]
            alloc = allocation[name]
            kind, count = unit(r["workload"], r)
            avg = measure["p50"] / batch
            writer.writerow(
                dict(
                    case=name,
                    sourceRateHz=r["workload"]["sourceRate"],
                    sourceWindowSamples=r["workload"]["inputSamples"],
                    fftLength=r["workload"].get("transformLength"),
                    hopSamples=r["workload"].get("hop"),
                    unit=kind,
                    unitsPerOperation=count,
                    fitSlopeEvaluations=r.get("slopeEvaluations"),
                    operationsPerBatch=batch,
                    observations=measure["sampleCount"],
                    batchP50ns=measure["p50"],
                    batchP95ns=measure["p95"],
                    batchP99ns=measure["p99"],
                    meanNsPerOperationInP50Batch=avg,
                    meanNsPerUnitInP50Batch=avg / count if count else None,
                    maxMallocCountPerBatch=alloc["mallocCountTotal"]["maximum"],
                    maxMallocBytesPerBatch=alloc["mallocBytesCount"]["maximum"],
                    maxObjectsPerBatch=alloc["objectAllocCount"]["maximum"],
                    meanMallocCountPerOperationInMaxBatch=alloc["mallocCountTotal"]["maximum"] / batch,
                    meanMallocBytesPerOperationInMaxBatch=alloc["mallocBytesCount"]["maximum"] / batch,
                )
            )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--development-toolchain",
        action="store_true",
        help="Record local development measurements with the selected Xcode instead of qualifying the pinned CI toolchain",
    )
    opts = parser.parse_args()
    overrides = {
        "MALLOC_INTERPOSER_LOCAL_PATH",
        "RUNTIME_INTERPOSER_LOCAL_PATH",
        "BENCHMARK_DISABLE_MALLOC_INTERPOSER",
        "BENCHMARK_DISABLE_JEMALLOC",
        "DYLD_INSERT_LIBRARIES",
        "LD_PRELOAD",
    }
    if overrides.intersection(os.environ):
        parser.error("Remove allocator and tracing overrides before measurement")
    root = PACKAGE / ".build/artifacts/kernels" / uuid.uuid4().hex
    root.mkdir(parents=True)
    print(f"Kernel evidence directory {root}", flush=True)
    plan = root / "calibration.json"
    common = swift("timing")
    with (root / "calibration.log").open("w") as log:
        ci.run_command(["swift", "build", *common, "--product", "KernelWorkloadCheck"], log, [])
    binary = Path(ci.capture("swift", "build", *common, "--show-bin-path")) / "KernelWorkloadCheck"
    with plan.open("wb") as out:
        subprocess.run([binary], stdout=out, check=True)
    records = json.loads(plan.read_bytes())
    validate_plan(records)
    os.environ["HDXL_KERNEL_PLAN"] = str(plan)
    clean = measure("timing", root, plan, records, not opts.development_toolchain)
    diagnostics = measure("allocation", root, plan, records, not opts.development_toolchain)
    table(root / "kernels.csv", records, clean, diagnostics)
    write(
        root / "result.json",
        dict(
            status="passed",
            cases=len(records),
            calibrationSHA256=framework.sha(plan),
            tableSHA256=framework.sha(root / "kernels.csv"),
            timingResultSHA256=framework.sha(root / "kernels-timing/result.json"),
            allocationResultSHA256=framework.sha(root / "kernels-allocation/result.json"),
        ),
    )
    print(root / "kernels.csv")


if __name__ == "__main__":
    main()
