#!/usr/bin/env python3
"""Measure the six spectral descriptors and their incremental cost beyond the shared PCM-to-power FFT."""
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from SpectralProducts.benchmark import SpectralBenchmarkSuite, main

BOUNDARIES = {
    "FFT": "Stream one interval through the prepared spectral product worker, probe a bin per frame and finish.",
    "FFTAndShape": "Identical PCM, FFT, output probe and finish plus all six descriptors on each borrowed column.",
    "SharedFrame": "Evaluate all six descriptors once per owned precomputed frame and consume each value.",
    "SeparateFrame": "Evaluate each descriptor alone on the same precomputed frame and consume all six values.",
    "SharedLTAS": "Evaluate all six descriptors on each of two precomputed sliding LTAS snapshots.",
    "SeparateLTAS": "Evaluate each descriptor alone on each of the same two LTAS snapshots.",
    "RollingLTAS": "Rebuild two successive exact sliding LTAS windows from precomputed rows, snapshot and evaluate all six.",
}


def validate_cases(records):
    expected = {(n, upper, seconds) for n in (256, 2048) for upper in (2000, 8000) for seconds in (1, 8)}
    seen = set()
    for record in records:
        layout = record["layout"]
        n = layout["spectrum"]["transform"]["length"]
        frame = record["frameProfile"]
        upper, seconds = frame["analysisBand"]["upperHz"], record["durationSeconds"]
        key = n, upper, seconds
        length = 250 if n == 256 else 1000
        hop, samples = length // 2, 16000 * seconds
        fit = frame["fitBand"]
        step = 16000 / n
        aggregate = dict(frame, source="longTermSpectrum")
        intervals = record["intervals"]
        if (key not in expected or key in seen or record["name"] != f"fft{n}-band{upper}-s{seconds}"
                or record["sampleRate"] != 16000 or layout["framing"]["window"]["sampleRate"] != 16000
                or layout["framing"]["window"]["precision"] != "float64"
                or layout["framing"]["window"]["sampleCount"] != length or layout["framing"]["hopLength"] != hop
                or record["expectedFrames"] != 1 + (samples - length) // hop
                or frame["analysisBand"]["lowerHz"] != 0 or frame["includeDC"] or frame["source"] != "frame"
                or frame["weighting"] != "power" or frame["relativeLogFloorDB"] != -100
                or fit != dict(lowerHz=125, upperHz=upper / 2) or record["fitBins"] != 1 + int((upper / 2 - 125) / step)
                or record["aggregateProfile"] != aggregate or record["frameIdentity"] == record["aggregateIdentity"]
                or len(intervals) != 2 or [x["startSample"] for x in intervals] != [0, hop]
                or any(x["sampleCount"] != samples or x["sampleRate"] != 16000 for x in intervals)
                or intervals[0]["epoch"] != intervals[1]["epoch"]):
            raise ValueError(f"Invalid descriptor workload {key}")
        seen.add(key)
    if seen != expected:
        raise ValueError("Incomplete spectral-shape workload matrix")


def throughput(op, item, wall):
    aggregate = op in ("SharedLTAS", "SeparateLTAS", "RollingLTAS")
    count = 2 if aggregate else item["expectedFrames"]
    return dict(unit="LTAS snapshots" if aggregate else "frames", spectraPerTrial=count,
                windowSeconds=item["durationSeconds"], spectraPerSecondAtP50Latency=count * 1e9 / wall["p50"],
                spectraPerSecondAtP99Latency=count * 1e9 / wall["p99"])


def comparisons(data, records, mode):
    rows = []
    metrics = ["wallClock"] if mode == "timing" else ["mallocCountTotal", "mallocBytesCount"]
    for record in records:
        name = record["name"]
        for a, b, count in [("FFTAndShape", "FFT", record["expectedFrames"]),
                            ("SeparateFrame", "SharedFrame", record["expectedFrames"]),
                            ("SeparateLTAS", "SharedLTAS", 2)]:
            for metric in metrics:
                first = data[f"SpectralShape.{a}.{name}"][metric]
                second = data[f"SpectralShape.{b}.{name}"][metric]
                rows.append(dict(case=name, metric=metric, minuend=a, subtrahend=b, spectraPerTrial=count,
                                 differenceOfTrialMediansPerSpectrum=(first["p50"] - second["p50"]) / count))
    return rows


SUITE = SpectralBenchmarkSuite(
    "SpectralShapeBenchmarks", "SpectralShape", "Capability.SpectralShapeAllocationARC", "spectral-shape",
    "SpectralShapeWorkloadCheck", BOUNDARIES, validate_cases, throughput,
    "Binary64 mono PCM at 16 kHz, two deterministic sawtooths with periods 257 and 89 samples.",
    "PCM, power columns, reference LTAS, prepared worker storage and output verification are outside measurement.",
    "One recorded outer iteration covers one source interval for frames or two successive windows for LTAS.",
    comparisons=comparisons)


if __name__ == "__main__":
    main(SUITE)
