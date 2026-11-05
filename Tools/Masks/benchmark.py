#!/usr/bin/env python3
"""Measure the A08 mask matrix with fresh distributions and verified allocation controls."""
import argparse
import gzip
import hashlib
import importlib.util
import json
import math
import os
import re
from pathlib import Path
import shutil
import subprocess
import sys
import uuid

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Tools"))
import ci

SPEC = importlib.util.spec_from_file_location("smoke_benchmark", ROOT / "Tools/benchmark.py")
smoke = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(smoke)
PACKAGE = ROOT / "Benchmarks"
OPERATIONS = ("Prepare", "Run")
CONTROL = "Capability.MaskAllocationARC"
ALLOCATIONS = ("mallocCountTotal", "mallocBytesCount", "objectAllocCount")
DIAGNOSTICS = (*ALLOCATIONS, "freeCountTotal", "retainCount", "releaseCount")


SHARDS = ('float32', 'float64', 'operations')


def expected_cases(shard=None):
    result = {}
    for kind in ('LTSF', 'Energy', 'Routing'):
        for precision in ('float32', 'float64'):
            for chunk in (64, 256, 1024):
                result[f'{kind}.{precision}.16000Hz.600s.{chunk}chunk'] = kind, precision, 16000, chunk
        result[f'{kind}.float64.48000Hz.600s.256chunk'] = kind, 'float64', 48000, 256
    for kind in ('Resolution', 'Metadata', 'ResetLTSF', 'ResetEnergy', 'ResetRouting'):
        result[f'{kind}.float64.16000Hz.600s.256chunk'] = kind, 'float64', 16000, 256
    if shard is not None:
        if shard not in SHARDS: raise ValueError('Unknown mask shard')
        result = {name: row for name, row in result.items()
                  if (row[1] if row[0] == 'LTSF' else 'operations') == shard}
    return result


def is_digest(value):
    return isinstance(value, str) and re.fullmatch('[a-f0-9]{64}', value) is not None


def validate_matrix(matrix, shard=None):
    expected = expected_cases(shard)
    seen, inputs, plans = set(), {}, {}
    for row in matrix:
        name = row['name']
        if name not in expected or name in seen: raise ValueError('Unexpected/duplicate mask case')
        seen.add(name)
        kind, precision, rate, chunk = expected[name]
        pcm = kind in ('LTSF', 'Energy', 'Routing')
        spectral = kind in ('LTSF', 'ResetLTSF')
        ltsf = dict(schemaVersion=1, sampleRate=rate, inputPrecision=precision,
                    declaredInputBandwidthHz=rate / 2, hopSeconds=.01, shortWindowSeconds=.1,
                    longWindowSeconds=.3, minimumFrequencyHz=70, maximumFrequencyHz=6000,
                    flatnessThreshold=-10, relativeIntensityThresholdDB=-35,
                    minimumSpeechSeconds=.1, minimumNonSpeechSeconds=.1)
        energy = dict(schemaVersion=1, sampleRate=rate, inputPrecision=precision,
                      declaredInputBandwidthHz=rate / 2, windowSamples=rate // 100,
                      activationDBFS=-40, deactivationDBFS=-45,
                      activationConfirmationWindows=2, deactivationConfirmationWindows=3)
        if row['workload'] != dict(name=name, kind=kind, sampleRate=rate, precision=precision,
            chunkSamples=chunk, inputDurationSeconds=600, ltsf=ltsf, energy=energy):
            raise ValueError('Incorrect mask workload/profile recipe')
        count = 600 * rate
        length = 2 * (int(.02 * rate) // 2 - 1)
        fft = 1024 if rate == 16000 else 4096
        bins = int(6000 / (rate / fft))
        first = int(70 / (rate / fft)) - 1
        frames = 59999
        geometry = dict(effectiveMaximumFrequencyHz=(bins-1)*rate/fft,
            effectiveMinimumFrequencyHz=first*rate/fft, fftBinsPerSpectrogramBin=1,
            fftLength=fft, firstFlatnessBin=first, firstFrequencyHz=0, frameLength=length,
            frequencyBinCount=bins, frequencyStepHz=rate/fft, lastFlatnessBin=bins-1,
            longFrameCount=30, physicalWindowSeconds=.02, shortAveragingEnabled=True,
            spectralRingFrameCount=13)
        layout = row['layout']
        if layout['configuration'] != ltsf or layout['spectral'] != geometry or layout['frameCount'] != frames or layout['maximumEffectiveDelaySeconds'] != 600:
            raise ValueError('Incorrect spectral geometry or effective delay')
        source = dict(epoch=dict(sequence=0,streamID='00000000-0000-0000-0000-000000000034'),
                      startSample=0, sampleCount=count, sampleRate=rate)
        if layout['source'] != source or abs(layout['firstCenterSeconds']-.01) > 1e-12:
            raise ValueError('Incorrect original source timeline')
        # Scalar storage includes all interval buffers (24-byte stride), complex
        # bins, compensated sums, counts and FFT scratch. No PCM/object/setup table claim.
        workspace = (3*length + 73*bins + 13 + 2*frames)*8 + (fft//2+1)*16 + bins*40 + fft*16 + 4*(frames+1)*24
        if row['preparedInputBytes'] != (count * (4 if precision == 'float32' else 8) if pcm else 0) or row['preparedScalarWorkspaceBytes'] != (workspace if spectral else 0):
            raise ValueError('Incorrect prepared scalar/input storage')
        for key, family in [('ltsfIdentity','praat-7.0.02-ltsf-supported-domain'), ('energyIdentity','absolute-rms-eligibility-confirmed-windows')]:
            if row[key]['identifier'] != dict(name=family, version=1) or not is_digest(row[key]['sha256']):
                raise ValueError('Missing profile identity')
        for key in ('inputSHA256', 'planSHA256'):
            if not is_digest(row[key]): raise ValueError('Missing content identity')
        input_key = (rate, precision) if pcm else 'empty'
        if input_key in inputs and inputs[input_key] != row['inputSHA256']: raise ValueError('Inconsistent identical input hashes')
        inputs[input_key] = row['inputSHA256']
        if not pcm and row['inputSHA256'] != hashlib.sha256(b'').hexdigest(): raise ValueError('Nonempty metadata-only input')
        if rate in plans and plans[rate] != row['planSHA256']: raise ValueError('Inconsistent dense plan identity')
        plans[rate] = row['planSHA256']
        width = rate // 50
        missing = sum(i % 101 == 0 for i in range(30000)) * width
        selected = sum(i % 101 != 0 and i % 2 == 0 for i in range(30000)) * width
        coverage = row['coverage']
        counts = dict(sourceSampleCount=count, missingSampleCount=missing, eligibleSampleCount=count-missing,
                      selectedSampleCount=selected, excludedEligibleSampleCount=count-missing-selected)
        durations = {key.replace('SampleCount','DurationSeconds'): value/rate for key,value in counts.items()}
        if any(coverage[k] != v for k,v in {**counts, **durations, 'sourceCoverage': selected/count, 'eligibleCoverage': selected/(count-missing)}.items()):
            raise ValueError('Incorrect selected/eligible/missing coverage')
        tags = ('missingAcquisition','silence','suspectedExternalNoise','clipping','speechDetected',
                'nonSpeechDetected','lowPeriodicityConfidence','algorithmInsufficiency','energyEligible','energyIneligible')
        if [x['tag'] for x in coverage['tags']] != list(tags): raise ValueError('Missing distinct tag coverage')
        for tag in coverage['tags']:
            indices = [i for i in range(30000) if (i % 101 == 0 if tag['tag']=='missingAcquisition' else
                        i % 101 != 0 and i % 3 == 0 if tag['tag'] in ('suspectedExternalNoise','lowPeriodicityConfidence') else False)]
            a = len(indices)*width; b = 0 if tag['tag']=='missingAcquisition' else a
            c = 0 if b == 0 else sum(i % 2 == 0 for i in indices)*width
            want = dict(tag=tag['tag'], sampleCount=a, eligibleSampleCount=b, selectedSampleCount=c,
                        durationSeconds=a/rate, eligibleDurationSeconds=b/rate, selectedDurationSeconds=c/rate)
            if tag != want: raise ValueError('Incorrect tag duration union')
        emitted = frames if kind == 'LTSF' else 60000 if kind == 'Energy' else selected if kind == 'Routing' else 30000 if kind == 'Resolution' else 1
        if row['observations'] != 30000 or row['emittedUnits'] != emitted or type(row['exportedBytes']) is not int or (row['exportedBytes'] <= 0 if kind == 'Metadata' else row['exportedBytes'] != 0):
            raise ValueError('Incorrect output/metadata coverage')
        if type(row['checksum']) not in (int,float) or not math.isfinite(row['checksum']) or row['checksum'] == 0:
            raise ValueError('Missing finite observable output checksum')
    if seen != set(expected): raise ValueError('Missing mask matrix coverage')
    return matrix


def validate_raw(raw, matrix, mode):
    expected = {f"Mask.{operation}.{item['name']}" for item in matrix for operation in OPERATIONS}
    if mode == "allocation":
        expected.add(CONTROL)
    rows = raw["results"]
    if not isinstance(rows, list) or len(rows) != 2 * len(expected):
        raise ValueError("Missing/extra raw benchmark distributions")
    allocating_runs = {f"Mask.Run.{r['name']}" for r in matrix
                       if r['workload']['kind'] in ('Resolution', 'Metadata')}
    result = {}
    required = {"wallClock", "cpuTotal"} if mode == "timing" else {"wallClock", *DIAGNOSTICS}
    for index in range(0, len(rows), 2):
        identity, measurements = rows[index:index + 2]
        name = identity["name"]
        if name not in expected or name in result or identity["target"] != "MaskBenchmarks":
            raise ValueError("Unexpected/duplicate masks workload")
        metrics = {}
        for measurement in measurements:
            if len(measurement["metric"]) != 1 or measurement["scalingFactor"] != 1:
                raise ValueError("Unexpected metric identity or framework scaling")
            metric = next(iter(measurement["metric"]))
            histogram = measurement["statistics"]["histogram"]
            count = histogram["_totalCount"]
            maximum = histogram["maxValue"]
            if metric in metrics or metric not in required or type(count) is not int or count < 10:
                raise ValueError("Missing/duplicate metric or fewer than 10 measured samples")
            if type(maximum) is not int or maximum < 0 or sum(histogram["counts"]) != count:
                raise ValueError("Malformed histogram evidence")
            if metric == "wallClock" and maximum <= 0:
                raise ValueError("No positive workload duration")
            if mode == "allocation":
                if name == CONTROL and metric in DIAGNOSTICS and maximum <= 0:
                    raise ValueError(f"Unavailable allocation/ARC capability: {metric}")
                if name.startswith("Mask.Run.") and name not in allocating_runs and metric in ALLOCATIONS and maximum != 0:
                    raise ValueError(f"Steady-state allocation observed: {name}, {metric}, maximum={maximum}")
            metrics[metric] = {"sampleCount": count, "maximum": maximum}
        if set(metrics) != required:
            raise ValueError("Missing metric coverage")
        result[name] = metrics
    return result


def validate_export(rows, names, mode):
    metrics = ("Time (wall clock)", "Time (total CPU)") if mode == "timing" else ("Time (wall clock)", *smoke.DIAGNOSTICS)
    expected = {f"{name} - {metric}" for name in names for metric in metrics}
    result = {}
    for row in rows:
        name, value = row["name"], row["value"]
        if name not in expected or name in result or isinstance(value, bool) or not isinstance(value, (float, int)) or not math.isfinite(value) or value < 0:
            raise ValueError("Invalid p99 benchmark export")
        wanted_unit = "ns" if " - Time (" in name else "#"
        if row["unit"] != wanted_unit:
            raise ValueError("Unexpected benchmark unit")
        result[name] = value
    if set(result) != expected:
        raise ValueError("Missing p99 export metrics")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("timing", "allocation"))
    parser.add_argument("--shard", choices=SHARDS, required=True)
    args = parser.parse_args()
    output = PACKAGE / ".build/artifacts" / f"masks-{args.mode}-{args.shard}"
    if output.exists():
        shutil.rmtree(output)
    output.mkdir(parents=True)
    result = {"schemaVersion": 1, "mode": args.mode, "shard": args.shard, "status": "failed", "commands": []}
    lock = PACKAGE / "Package.resolved"
    before = lock.read_bytes()
    name = f"masks-{args.mode}-{args.shard}-{uuid.uuid4().hex}"
    baseline = PACKAGE / ".benchmarkBaselines/MaskBenchmarks" / name
    try:
        overrides = ("MALLOC_INTERPOSER_LOCAL_PATH", "RUNTIME_INTERPOSER_LOCAL_PATH",
                     "BENCHMARK_DISABLE_MALLOC_INTERPOSER", "BENCHMARK_DISABLE_JEMALLOC",
                     "DYLD_INSERT_LIBRARIES", "LD_PRELOAD")
        if any(key in os.environ for key in overrides):
            raise ValueError("Remove allocator/backend environment overrides")
        environment = ci.environment("release")
        ci.validate_environment(environment, json.loads((ROOT / "Configuration/build.json").read_text()))
        environment.update({"hardwareModel": ci.capture("sysctl", "-n", "hw.model"),
                            "purpose": "A08 ten-minute LTSF/energy, dense mask routing/resolution, reset and owned metadata; physical evidence deferred under #74",
                            "mode": args.mode, "shard": args.shard, "packageResolvedSHA256": hashlib.sha256(before).hexdigest(),
                            "frameworkScalingFactor": 1, "exportStatistic": "p99, one declared Prepare or Run operation",
                            "sampling": "600s PCM Run: one warmup, ten measured operations, 3600s cap. Others: three warmups, thirty measured operations, 60s cap. Validation requires ten samples; p99 of ten samples is effectively the maximum, not a stable population tail estimate.",
                            "distributions": "raw-baseline.json.gz; sample counts/maxima in distributions.json; p99.json",
                            "input": "Original 125/250Hz harmonics with UInt32 LCG seed34 noise and 250ms amplitude transitions, rounded once to source precision. Dense annotations: 30000 disjoint 20ms intervals, alternating selection, every101st missing and every3rd remaining tagged low periodicity/noise. Generation excluded; exact input and plan bytes hashed.",
                            "operations": {"Prepare": "construct/destroy operation-specific worker storage or prepared routing/export timeline; synthetic PCM and observation generation excluded",
                                           "Run": "one 600s detector/routing pass with reset/finalize, dense timeline resolution, complete canonical metadata export with byte checksum, or one explicit reset. No CPP computation. Routing consumes every selected PCM sample."},
                            "workingMemory": "owned scalar buffers including spectral/intensity history, features, FFT and interval scratch; opaque FFT tables/object overhead excluded. Energy has constant-size value state, no scalar arrays; routing retains prepared plan/timeline arrays. Heap allocation counters cover these objects and owned metadata; export byte volume reported separately.",
                            "delay": "LTSF final decisions require complete 600s source; energy uses 10ms windows with 2/3-window confirmation. Finalized mask routing adds no detector delay. No physical capture latency claim.",
                            "latency": "full declared operations, not per-window or capture latency; audio duration divided by run time gives throughput",
                            "allocationClaim": "Prepared LTSF, energy, routing and reset Run require zero heap maxima. Resolution and Metadata Run allocate by design. Positive allocation/ARC control required; diagnostics disabled."})
        (output / "environment.json").write_text(ci.redact(json.dumps(environment, indent=2)) + "\n")
        (output / "resolution.json").write_bytes(before)
        common = smoke.swift_arguments(args.mode)
        plugin = ["swift", "package", *common, "--allow-writing-to-package-directory", "benchmark",
                  "--target", "MaskBenchmarks", "--time-units", "nanoseconds", "--no-progress"]
        with (output / "commands.log").open("w") as log:
            def run(command):
                ci.run_command(command, log, result["commands"])
            run([sys.executable, "Tools/verify-provenance.py"])
            run(["swift", "build", *common, "--product", "MaskWorkloadCheck"])
            binary_dir = Path(ci.capture("swift", "build", *common, "--show-bin-path"))
            matrix = json.loads(ci.capture(str(binary_dir / "MaskWorkloadCheck"), "--shard", args.shard))
            validate_matrix(matrix, args.shard)
            names = "|".join(re.escape(row["name"]) for row in matrix)
            plugin += ["--filter", rf"^(Mask\.(Prepare|Run)\.({names})|{re.escape(CONTROL)})$"]
            (output / "workloads.json").write_text(json.dumps(matrix, indent=2) + "\n")
            if baseline.exists():
                raise ValueError("Fresh baseline unexpectedly exists")
            run([*plugin, "baseline", "update", name])
            raw = json.loads((baseline / "results.json").read_text())
            if raw.get("baselineName") != name:
                raise ValueError("Raw capture identity differs from this execution")
            raw["machine"]["hostname"] = "<host>"
            with gzip.open(output / "raw-baseline.json.gz", "wt") as stream:
                json.dump(raw, stream, separators=(",", ":"), allow_nan=False)
            summary = validate_raw(raw, matrix, args.mode)
            (output / "distributions.json").write_text(json.dumps(summary, indent=2) + "\n")
            result["binary"] = smoke.inspect_binary(binary_dir / "MaskBenchmarks", args.mode)
            run([*plugin, "baseline", "read", name, "--format", "jsonSmallerIsBetter", "--path", str(output)])
            exports = json.loads((output / f"{name}.json").read_text())
            values = validate_export(exports, summary, args.mode)
            (output / "p99.json").write_text(json.dumps(values, indent=2) + "\n")
            (output / f"{name}.json").unlink()
            result.update({"status": "passed", "workloadCount": len(matrix), "benchmarkCount": len(summary),
                           "metricCount": len(values), "preparedRunAllocationMaximum": 0 if args.mode == "allocation" else None,
                           "allocationEvidence": "positive control plus zero-heap prepared detector/routing/reset, with resolution/metadata allocations reported separately" if args.mode == "allocation" else "instrumentation disabled"})
    except (OSError, ValueError, KeyError, TypeError, RuntimeError, subprocess.SubprocessError) as error:
        result["error"] = ci.redact(str(error))
        print(result["error"], file=sys.stderr)
    finally:
        if baseline.exists():
            shutil.rmtree(baseline)
        if lock.read_bytes() != before:
            result.update(status="failed", error="Package.resolved changed during locked measurement")
        (output / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    return 0 if result["status"] == "passed" else 1


if __name__ == "__main__":
    sys.exit(main())
