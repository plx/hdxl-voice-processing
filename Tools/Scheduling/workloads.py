"""Independent matrix/recipe/coverage checks for shared-scheduler evidence."""
import hashlib
import importlib.util
import json
import math
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]


def load(name, relative):
    spec = importlib.util.spec_from_file_location(name, ROOT / relative)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


canonical = load("schedule_canonical", "Tools/Reference/common.py").canonical
yin = load("schedule_yin_recipe", "Tools/YIN/benchmark.py")
cpps = load("schedule_cpps_recipe", "Tools/CPPS/benchmark.py")


def expected_cases():
    result = {}

    def add(precision, rate, composition="full", channels=1, layout="interleaved", kind="preview"):
        name = f"{composition}.{precision}.{rate}Hz.c{channels}.{layout}.{kind}"
        result[name] = dict(precision=precision, rate=rate, composition=composition,
                            channels=channels, layout=layout, kind=kind)

    for precision in ("float32", "float64"):
        for rate in (16000, 44100, 48000):
            for composition in ("light", "full"):
                add(precision, rate, composition)
        for layout in ("interleaved", "planar"):
            add(precision, 48000, channels=2, layout=layout)
        for kind in ("selected", "whole"):
            add(precision, 16000, kind=kind)
    return result


def finite(value):
    return type(value) in (int, float) and math.isfinite(value)


def validate_coefficients(value, rate):
    fixture = json.loads((ROOT / "Tests/HDXLVoiceProcessingTests/Fixtures/Levels/k-weighting.json").read_text())
    oracle = next(row for row in fixture["coefficientSets"] if row["sampleRate"] == rate)
    if (set(value), value["schemaVersion"], value["sampleRate"], value["method"]) != (
        {"schemaVersion", "sampleRate", "method", "shelf", "highpass"}, 1, rate,
        {"name": "bs1770-5-prewarped-tables", "version": 1}
    ):
        raise ValueError("Incorrect weighting coefficient provenance")
    for name, stage in zip(("shelf", "highpass"), oracle["stages"]):
        expected = dict(zip(("b0", "b1", "b2", "a1", "a2"), [*stage["b"], *stage["a"][1:]]))
        if set(value[name]) != set(expected) or any(
            not finite(value[name][key]) or abs(value[name][key] - number)
                > fixture["nativeComparisonBudgets"]["coefficientAbsolute"]
            for key, number in expected.items()
        ):
            raise ValueError("Weighting coefficients differ from independent pinned oracle")


def expected_profile(row, coefficients):
    rate, precision = row["rate"], row["precision"]
    full = row["composition"] == "full"
    level = dict(schemaVersion=1, sampleRate=rate, inputPrecision=precision,
        arithmeticPrecision="float64", windowLength=rate // 40, hopLength=rate // 100,
        accumulation="compensatedSliding", partialWindowPolicy="emitUnavailable",
        pcmReference="unitPeak", channelPolicy="monoAlreadySelected", averaging="rectangularMeanSquare",
        energyUnit="normalizedSquaredAmplitude", logLevelUnit="decibelsFullScale",
        filterPhasePolicy="causalFrequencyDependentNoTimestampShift", kWeighting=coefficients,
        weighting=dict(kind="bs1770Revision5", warmupSampleCount=rate // 10) if full else dict(kind="none"))
    pitch = yin.expected_profile(dict(rate=rate, precision=precision, floor=50, ceiling=700,
        integration=math.ceil(rate / 50), hopSamples=rate // 100, backend="fft", tracking=full))
    cepstral = cpps.expected_profile(dict(rate=rate, precision=precision, hop=10, time=20,
        quefrency=1, pretrend=False, kind="IntervalCPPS" if row["kind"] == "whole" else "PreviewCPPS")) if full else None
    return dict(schemaVersion=1, inputFormat=dict(sampleRate=rate, channelCount=row["channels"],
        encoding=precision, layout=row["layout"]), channels=dict(channelIndex=None),
        channelConversion="nativeSelectionOrScaledFloat64Mean", levels=level, pitch=pitch, cpps=cepstral)


def expected_mask(rate):
    epoch = dict(streamID="00000000-0000-0000-0000-000000000440", sequence=0)

    def source(start, count):
        return dict(epoch=epoch, startSample=start, sampleCount=count, sampleRate=rate)

    return dict(schemaVersion=1, source=source(0, rate), effectiveDelaySeconds=0,
        policy=dict(combination="all", rejectedTags=[], selectionSources=[0]),
        provenances=[dict(schemaVersion=1, kind="externalAnnotation", parameters={},
            identifier=dict(name="schedule-benchmark-regions", version=1))],
        observations=[dict(provenanceIndex=0, selection="selected", tags=["speechDetected"],
            source=source(start, rate * 2 // 5)) for start in (0, rate * 3 // 5)])


def validate_digest(digest, row):
    rate = row["rate"]
    full = row["composition"] == "full"
    regions = [(0, rate)] if row["kind"] != "selected" else [(0, rate * 2 // 5), (rate * 3 // 5, rate * 2 // 5)]
    if set(digest) != {"levels", "pitch", "cpps"}:
        raise ValueError("Missing algorithm digest")
    for lane, values in digest.items():
        if set(values) != {"frames", "available", "sourceStartSum", "sourceCountSum", "checksum", "auxiliaryChecksum"}:
            raise ValueError("Malformed algorithm digest")
        for key in ("frames", "available", "sourceStartSum", "sourceCountSum"):
            if type(values[key]) is not int or values[key] < 0:
                raise ValueError("Invalid digest count")
        if values["available"] > values["frames"] or any(not finite(values[key]) for key in ("checksum", "auxiliaryChecksum")):
            raise ValueError("Invalid availability/checksum")
        if lane == "cpps":
            if not full:
                if any(values.values()): raise ValueError("Light profile unexpectedly analyzed CPPS")
                continue
            available = sum(((count * 10000 // rate) - 1000) // 100 + 1 for _, count in regions)
            frames = available + (0 if row["kind"] == "whole" else len(regions))
            if (values["frames"], values["available"]) != (frames, available):
                raise ValueError("Incorrect CPPS full/partial coverage")
            if values["checksum"] <= 0 or values["auxiliaryChecksum"] <= 0:
                raise ValueError("No observable CPPS/CPP output")
            if not (0 <= values["sourceStartSum"] <= frames * rate
                    and available * rate // 10 <= values["sourceCountSum"] <= frames * rate):
                raise ValueError("Invalid CPPS source support")
            if row["kind"] == "whole" and (values["sourceStartSum"], values["sourceCountSum"]) != (0, frames * rate):
                raise ValueError("Whole CPPS lost complete-interval dependency")
            continue
        support = rate // 40 if lane == "levels" else 2 * math.ceil(rate / 50) + 1
        hop = rate // 100
        frames = available = starts = counts = 0
        for offset, count in regions:
            n = (count - support) // hop + 1
            partial = int(n * hop < count)
            frames += n + partial
            available += n
            starts += (n + partial) * offset
            if full:
                counts += n * support + hop * n * (n - 1) // 2
                if lane == "levels": counts += count * partial
                else:
                    starts += n * hop * partial
                    counts += (count - n * hop) * partial
            else:
                starts += hop * (n + partial) * (n + partial - 1) // 2
                counts += n * support + (count - n * hop) * partial
        if (values["frames"], values["available"], values["sourceStartSum"], values["sourceCountSum"]) != (frames, available, starts, counts):
            raise ValueError(f"Incorrect {lane} availability or dependency support")
        if values["checksum"] <= 0 or (values["auxiliaryChecksum"] <= 0 if full else values["auxiliaryChecksum"] != 0):
            raise ValueError("Missing numerical output or unrequested tracking/weighting")


def validate_matrix(matrix):
    expected = expected_cases()
    if not isinstance(matrix, list) or len(matrix) != len(expected):
        raise ValueError("Incorrect scheduler matrix size")
    seen, hashes = set(), {}
    for record in matrix:
        name = record["name"]
        if name not in expected or name in seen: raise ValueError("Unexpected/duplicate workload")
        seen.add(name)
        row = expected[name]
        workload = record["workload"]
        coefficients = workload["profile"]["levels"]["kWeighting"]
        if row["composition"] == "full": validate_coefficients(coefficients, row["rate"])
        elif coefficients is not None: raise ValueError("Unexpected light-profile weighting")
        profile = expected_profile(row, coefficients)
        identity = dict(identifier=dict(name="shared-pcm-analysis-schedule", version=1),
            sha256=hashlib.sha256(canonical(profile)).hexdigest())
        wanted = dict(name=name, kind=row["kind"], composition=row["composition"], profile=profile,
            identity=identity, sourceTileCapacity=256, inputChunkSamples=173, inputSampleCount=row["rate"])
        if row["kind"] == "selected": wanted["maskPlan"] = expected_mask(row["rate"])
        if canonical(workload) != canonical(wanted):
            raise ValueError("Incorrect scheduler recipe, profile identity or mask")
        if record["preparedInputBytes"] != row["rate"] * row["channels"] * (4 if row["precision"] == "float32" else 8):
            raise ValueError("Incorrect prepared input size")
        if type(record["preparedBufferBytes"]) is not int or not (0 < record["preparedBufferBytes"] < 64 * 1024 * 1024):
            raise ValueError("Unbounded/invalid prepared scratch size")
        if any(not finite(record[key]) for key in ("inputDurationSeconds", "analyzedDurationSeconds")) or (
            record["inputDurationSeconds"], record["analyzedDurationSeconds"]
        ) != (1, .8 if row["kind"] == "selected" else 1):
            raise ValueError("Incorrect throughput denominators")
        if record["digest"] != record["directDigest"] or record["digest"] != record["splitDigest"]:
            raise ValueError("Native-reference or chunk-partition mismatch")
        validate_digest(record["digest"], row)
        digest = record["inputSHA256"]
        if not isinstance(digest, str) or re.fullmatch("[0-9a-f]{64}", digest) is None:
            raise ValueError("Invalid input PCM hash")
        key = (row["rate"], row["precision"], row["channels"], row["layout"])
        if key in hashes and hashes[key] != digest: raise ValueError("Identical PCM has inconsistent hashes")
        hashes[key] = digest
    if seen != set(expected): raise ValueError("Incomplete scheduler matrix")
    return matrix
