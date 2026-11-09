#!/usr/bin/env python3
"""Measure the A12 pulse matrix, with independent evidence and allocation checks."""
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
sys.path.insert(0, str(ROOT / 'Tools'))
import ci

SPEC = importlib.util.spec_from_file_location('smoke_benchmark', ROOT / 'Tools/benchmark.py')
smoke = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(smoke)
SPEC = importlib.util.spec_from_file_location('pulse_canonical', ROOT / 'Tools/Reference/common.py')
canonical_module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(canonical_module)
PACKAGE = ROOT / 'Benchmarks'
OPERATIONS = ('Prepare', 'Run')
CONTROL = 'Capability.PulseAllocationARC'
ALLOCATIONS = ('mallocCountTotal', 'mallocBytesCount', 'objectAllocCount')
DIAGNOSTICS = (*ALLOCATIONS, 'freeCountTotal', 'retainCount', 'releaseCount')
SHARDS = ('steady16000', 'steady44100', 'steady48000', 'stress', 'vowel', 'export')


def capture_stdout(*command):
    # SwiftPM lock-wait notices are stderr, and can lack a trailing newline.
    # Keep them out of machine-readable paths/JSON rather than parsing mixed text.
    return subprocess.run(command,cwd=ROOT,text=True,capture_output=True,check=True).stdout.strip()


def expected_cases(shard=None):
    result = {}
    def add(fixture, group, owned=False):
        for precision in ('float32', 'float64'):
            for support, short in (('completeInterval', 'whole'), ('independentlyAnchoredBlock', 'block')):
                name = f"{fixture}.{precision}.{short}.{'owned' if owned else 'borrowed'}"
                result[name] = dict(fixture=fixture, precision=precision, support=support,
                    ownedSnapshot=owned, shard=group, chunkSamples=256, maximumTrackingAttempts=4096)
    for rate in (16000, 44100, 48000):
        for hz in (80, 150, 300, 600): add(f'gaussian-{rate}-{hz}', f'steady{rate}')
    for fixture in ('rising-f0', 'falling-f0', 'jitter-12pct', 'noisy-high', 'missing-cycles', 'splice', 'silence', 'noise'):
        add(fixture, 'stress')
    add('speech-bl01-vowel-a', 'vowel')
    add('gaussian-48000-150', 'export', True)
    if shard is not None:
        if shard not in SHARDS: raise ValueError('Unknown pulse shard')
        result = {name: row for name, row in result.items() if row['shard'] == shard}
    return result


def fixture_for_case(row):
    path = ROOT / 'Tests/HDXLVoiceProcessingTests/Fixtures/Pulses' / (row['fixture'] + '-' + row['precision'] + '.json')
    return path, json.loads(path.read_text())


def expected_profile(row, fixture):
    return dict(schemaVersion=1, sampleRate=fixture['case']['sampleRate'], inputPrecision=row['precision'],
        arithmeticPrecision='float64', pitchFloorHz=20, pitchCeilingHz=fixture['reference']['pitch']['ceilingHz'],
        minimumPeriodSeconds=.0001, maximumPeriodSeconds=.02, maximumAdjacentPeriodFactor=1.3,
        support=row['support'], definition='hdxl-acoustic-pulses-waveform-cc-v1',
        seedDefinition='voicedIntervalMidpointAbsoluteExtremumParabola',
        correlationDefinition='observedPairsFusedDotScaleSubnormalProductFiniteLagTableRightNeighborPeak',
        interpolationDefinition='threePointParabolaGeometricRangeFallback', amplitudeDefinition='hannRMSPointTwoNeighborPeriods',
        minimumReliableCurvature=128 * math.ulp(1.), minimumRelativeVariation=64 * math.ulp(1.))


def validate_matrix(matrix, shard=None):
    expected = expected_cases(shard)
    seen = set()
    def same(a, b, message):
        if canonical_module.canonical(a) != canonical_module.canonical(b): raise ValueError(message)
    for record in matrix:
        name = record['name']
        if name not in expected or name in seen: raise ValueError('Missing, extra or duplicate pulse case')
        seen.add(name)
        row = expected[name]; path, fixture = fixture_for_case(row)
        reference = fixture['reference']; pitch = reference['pitch']
        profile = expected_profile(row, fixture)
        same(record['workload'], row, 'Pulse workload recipe changed')
        same(record['configuration'], profile, 'Pulse configuration changed')
        rate, count = fixture['case']['sampleRate'], fixture['case']['sampleCount']
        frames = len(pitch['frequenciesHz']); capacity = 4096 + frames
        stride = 4 if row['precision'] == 'float32' else 8
        # Pinned arm64 Swift 6.4 record strides: landmark64, period48, pair40,
        # amplitude72, attempt120, correlation bin32. Input is separately owned.
        prepared = count * 8 + capacity * (64 + 48 + 40 + 72) + 4096 * 120
        prepared += (math.ceil(.45 * rate / 20) + 7) * 32
        if row['support'] == 'independentlyAnchoredBlock': prepared += count * stride
        geometry = dict(inputSampleCount=count, f0FrameCount=frames, preparedInputBytes=count * stride,
                        preparedContourBytes=frames * 8, f0FirstCenterSeconds=pitch['firstCenterSeconds'],
                        f0StepSeconds=pitch['stepSeconds'],
                        preparedBufferBytes=prepared, inputDurationSeconds=count / rate,
                        maximumDependencyDelaySeconds=(count / rate) / 2)
        for key, value in geometry.items(): same(record[key], value, 'Pulse geometry/storage/delay changed: ' + key)
        identity = dict(identifier=dict(name=profile['definition'] + '-' + row['support'], version=1),
                        sha256=hashlib.sha256(canonical_module.canonical(profile)).hexdigest())
        same(record['profileIdentity'], identity, 'Pulse profile fingerprint changed')
        contour = dict(schemaVersion=1, sampleRate=rate, sampleCount=count,
            firstCenterSeconds=pitch['firstCenterSeconds'], stepSeconds=pitch['stepSeconds'],
            ceilingHz=pitch['ceilingHz'], frequenciesHz=pitch['frequenciesHz'])
        contour_identity = dict(identifier=dict(name='hdxl-pulse-supplied-f0', version=1),
            sha256=hashlib.sha256(canonical_module.canonical(contour)).hexdigest())
        same(record['f0ContourIdentity'], contour_identity, 'Pulse F0 content identity changed')
        wave_path = path.with_suffix('.wav')
        wave = wave_path.read_bytes()
        if (record['fixtureJSONSHA256'] != hashlib.sha256(path.read_bytes()).hexdigest()
                or record['encodedInputSHA256'] != reference['inputSHA256']
                or record['encodedInputSHA256'] != hashlib.sha256(wave).hexdigest()
                or record['normalizedInputSHA256'] != hashlib.sha256(wave[56:]).hexdigest()):
            raise ValueError('Pulse input/fixture identity changed')
        counts = record['counts']
        keys = {'rawPulses','attempts','acceptedAttempts','rejectedAttempts','eligibleAttempts',
                'eligiblePulses','rawPeriods','eligiblePeriods','rawPairs','eligiblePairs',
                'availableAmplitudes','runs','exportedRecords'}
        if set(counts) != keys or any(type(v) is not int or not 0 <= v <= 30000 for v in counts.values()):
            raise ValueError('Invalid pulse counts')
        n = len(reference['data']['pulseTimesSeconds'])
        if (counts['rawPulses'] != n or counts['rawPeriods'] != max(0,n-1) or counts['rawPairs'] != max(0,n-2)
                or counts['acceptedAttempts'] + counts['rejectedAttempts'] != counts['attempts']
                or not counts['eligibleAttempts'] <= counts['acceptedAttempts'] <= n
                or not counts['runs'] <= counts['eligiblePulses'] <= n
                or counts['eligiblePeriods'] > counts['rawPeriods']
                or counts['eligiblePairs'] > counts['rawPairs']
                or counts['availableAmplitudes'] > counts['eligiblePairs']):
            raise ValueError('Incorrect pulse denominators')
        exported = 2*n + counts['attempts'] + counts['rawPeriods'] + counts['rawPairs'] if row['ownedSnapshot'] else 0
        if counts['exportedRecords'] != exported: raise ValueError('Incorrect owned pulse export coverage')
        for key, limit in (('maximumReferenceErrorSamples',1e-6),('maximumAmplitudeBudgetFraction',1)):
            value = record[key]
            if type(value) not in (int,float) or not math.isfinite(value) or not 0 <= value <= limit:
                raise ValueError('Pulse workload failed reference conformance')
        if type(record['checksum']) not in (int,float) or not math.isfinite(record['checksum']) or record['checksum'] <= 0:
            raise ValueError('Unobserved pulse output')
    if seen != set(expected): raise ValueError('Missing pulse matrix coverage')
    return matrix


def validate_raw(raw, matrix, mode):
    expected = {f"Pulse.{operation}.{item['name']}" for item in matrix for operation in OPERATIONS}
    if mode == "allocation":
        expected.add(CONTROL)
    rows = raw["results"]
    if not isinstance(rows, list) or len(rows) != 2 * len(expected):
        raise ValueError("Missing/extra raw benchmark distributions")
    allocating_runs = {f"Pulse.Run.{r['name']}" for r in matrix
                       if r['workload']['ownedSnapshot']}
    result = {}
    required = {"wallClock", "cpuTotal"} if mode == "timing" else {"wallClock", *DIAGNOSTICS}
    for index in range(0, len(rows), 2):
        identity, measurements = rows[index:index + 2]
        name = identity["name"]
        if name not in expected or name in result or identity["target"] != "PulseBenchmarks":
            raise ValueError("Unexpected/duplicate pulse workload")
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
            buckets = histogram["counts"]
            if (type(maximum) is not int or maximum < 0 or not isinstance(buckets, list)
                    or not buckets or any(type(v) is not int or v < 0 for v in buckets)
                    or sum(buckets) != count):
                raise ValueError("Malformed histogram evidence")
            if metric == "wallClock" and maximum <= 0:
                raise ValueError("No positive workload duration")
            if mode == "allocation":
                if name == CONTROL and metric in DIAGNOSTICS and maximum <= 0:
                    raise ValueError(f"Unavailable allocation/ARC capability: {metric}")
                if name.startswith("Pulse.Run.") and name not in allocating_runs and metric in ALLOCATIONS and maximum != 0:
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


def operation_costs(matrix, values):
    """Derived p99 costs; per-attempt division is amortized, never stage timing."""
    result = {}
    for row in matrix:
        name = row['name']
        run = values[f'Pulse.Run.{name} - Time (wall clock)']
        prepare = values[f'Pulse.Prepare.{name} - Time (wall clock)']
        if run <= 0 or prepare <= 0: raise ValueError('Missing positive operation duration')
        attempts = row['counts']['attempts']
        result[name] = dict(statistic='p99 of retained operation distribution',
            prepareNanoseconds=prepare, runNanoseconds=run,
            inputSecondsPerWallSecond=row['inputDurationSeconds'] / (run * 1e-9),
            amortizedNanosecondsPerAttempt=run / attempts if attempts else None,
            attempts=attempts, acceptedAttempts=row['counts']['acceptedAttempts'],
            rejectedAttempts=row['counts']['rejectedAttempts'],
            eligiblePeriods=row['counts']['eligiblePeriods'], preparedBufferBytes=row['preparedBufferBytes'],
            scope='Whole analyzer cost, including reset and consumption; accepted/rejected stage costs are separate')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("timing", "allocation"))
    parser.add_argument("--shard", choices=SHARDS, required=True)
    args = parser.parse_args()
    output = PACKAGE / ".build/artifacts" / f"pulse-{args.mode}-{args.shard}-{uuid.uuid4().hex[:8]}"
    output.mkdir(parents=True)
    print(str(output), flush=True)
    result = {"schemaVersion": 1, "mode": args.mode, "shard": args.shard, "status": "failed", "commands": []}
    lock = PACKAGE / "Package.resolved"
    before = lock.read_bytes()
    name = f"pulse-{args.mode}-{args.shard}-{uuid.uuid4().hex}"
    baseline = PACKAGE / ".benchmarkBaselines/PulseBenchmarks" / name
    try:
        overrides = ("MALLOC_INTERPOSER_LOCAL_PATH", "RUNTIME_INTERPOSER_LOCAL_PATH",
                     "BENCHMARK_DISABLE_MALLOC_INTERPOSER", "BENCHMARK_DISABLE_JEMALLOC",
                     "DYLD_INSERT_LIBRARIES", "LD_PRELOAD")
        if any(key in os.environ for key in overrides):
            raise ValueError("Remove allocator/backend environment overrides")
        environment = ci.environment("release")
        ci.validate_environment(environment, json.loads((ROOT / "Configuration/build.json").read_text()))
        environment.update({"hardwareModel": ci.capture("sysctl", "-n", "hw.model"),
            "purpose": "A12 waveform-correlation pulse processing; physical evidence deferred #74",
            "mode": args.mode, "shard": args.shard, "packageResolvedSHA256": hashlib.sha256(before).hexdigest(),
            "frameworkScalingFactor": 1, "exportStatistic": "p99, one declared Prepare or Run operation",
            "sampling": "Run: one warmup, ten measured operations, 3600s cap. Prepare/control: three warmups, thirty operations, 60s cap. Ten samples required; p99 of ten is effectively the maximum, not a stable population tail estimate.",
            "distributions": "raw-baseline.json.gz; sample counts/maxima in distributions.json; p99.json",
            "input": "Existing pinned Pulses fixtures: Gaussian80/150/300/600Hz at16/44.1/48k; rising/falling F0, jitter12%, noisy, missing cycles, splices, silence/noise, and licensed sustained-vowel excerpt. Exact PCM/F0/fixture identities retained. Loading, decoding, contour hashing and input preparation excluded.",
            "operations": {"Prepare": "construct/destroy selected prepared tracker or complete-block collector, including its bounded buffers; prepared PCM/F0 excluded",
                "Run": "reset and analyze complete input; block mode additionally copies256-sample chunks and finishes. Consume all borrowed output arrays. Owned cases additionally copy and consume all five snapshot arrays; no archive encoding claim."},
            "workingMemory": "Tracker owns Double PCM, bounded lag table and five output buffers; block collector additionally owns input-precision PCM. Input/F0 ownership separate; object bookkeeping excluded. Maximum4096attempts, never unbounded.",
            "delay": "Both profiles require complete input. Effective center delay is half its duration; early points may wait the full block. Independent blocks imply no cross-block period continuity.",
            "latency": "Full analyzer operation including reset and bounded output consumption; input duration/wall time gives throughput. Not physical capture latency. Per-cycle matching/interpolation distributions are measured separately.",
            "allocationClaim": "Prepared borrowed Run heap maxima must be zero; owned snapshots allocate deliberately. Positive allocation/ARC control required; diagnostics disabled."})
        environment["sourceSHA256"] = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted([*ROOT.glob("Sources/HDXLVoiceProcessing/**/*.swift"),
                ROOT/"Benchmarks/Sources/PulseWorkload/PulseWorkload.swift",
                ROOT/"Benchmarks/Benchmarks/PulseBenchmarks/PulseBenchmarks.swift",
                ROOT/"Package.swift", ROOT/"Benchmarks/Package.swift", Path(__file__)])}
        (output / "environment.json").write_text(ci.redact(json.dumps(environment, indent=2)) + "\n")
        (output / "resolution.json").write_bytes(before)
        common = smoke.swift_arguments(args.mode)
        common[common.index('--scratch-path') + 1] = str(ROOT / '.build' / ('pulse-' + args.mode))
        plugin = ["swift", "package", *common, "--allow-writing-to-package-directory", "benchmark",
                  "--target", "PulseBenchmarks", "--time-units", "nanoseconds", "--no-progress"]
        with (output / "commands.log").open("w") as log:
            def run(command):
                ci.run_command(command, log, result["commands"])
            run([sys.executable, "Tools/verify-provenance.py"])
            run(["swift", "build", *common, "--product", "PulseWorkloadCheck"])
            binary_dir = Path(capture_stdout("swift", "build", *common, "--show-bin-path"))
            matrix = json.loads(capture_stdout(str(binary_dir / "PulseWorkloadCheck"), "--shard", args.shard))
            validate_matrix(matrix, args.shard)
            names = "|".join(re.escape(row["name"]) for row in matrix)
            plugin += ["--filter", rf"^(Pulse\.(Prepare|Run)\.({names})|{re.escape(CONTROL)})$"]
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
            result["binary"] = smoke.inspect_binary(binary_dir / "PulseBenchmarks", args.mode)
            run([*plugin, "baseline", "read", name, "--format", "jsonSmallerIsBetter", "--path", str(output)])
            exports = json.loads((output / f"{name}.json").read_text())
            values = validate_export(exports, summary, args.mode)
            (output / "p99.json").write_text(json.dumps(values, indent=2) + "\n")
            if args.mode == 'timing':
                (output / 'costs.json').write_text(json.dumps(operation_costs(matrix, values), indent=2) + '\n')
            (output / f"{name}.json").unlink()
            result.update({"status": "passed", "workloadCount": len(matrix), "benchmarkCount": len(summary),
                           "metricCount": len(values), "preparedRunAllocationMaximum": 0 if args.mode == "allocation" else None,
                           "allocationEvidence": "positive control plus zero-heap prepared Pulse processing, with owned export allocations reported separately" if args.mode == "allocation" else "instrumentation disabled"})
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
