#!/usr/bin/env python3
"""Check one fixture across profiles before collecting clean or allocation-mode distributions."""

import argparse
import json
import math
import os
from pathlib import Path
import struct
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Tools"))
from AlgorithmSuite.prepare import prepare
from SpectralProducts.benchmark import SpectralBenchmarkSuite, main as measure

OPERATIONS = ("single.cpps", "single.core", "single.full", "single.separateSpectra", "pair.full")


def require(test, message):
    if not test:
        raise ValueError(message)


def direct_levels(fixture, result, directory):
    """Integrate complete unweighted windows directly from the typed mono PCM."""
    encoding = "<f" if fixture["precision"] == "float32" else "<d"
    samples = [v for v, in struct.iter_unpack(encoding, (directory / (fixture["pcmSHA256"] + ".pcm")).read_bytes())]
    width, hop = fixture["sampleRate"] // 40, fixture["sampleRate"] // 100
    energy, rms = [], []
    for region in fixture["regions"]:
        for i in range(region["start"], region["start"] + region["count"] - width + 1, hop):
            power = math.fsum(x * x for x in samples[i:i + width]) / width
            energy.append(power)
            rms.append(math.sqrt(power))
    for lane, values in (("rms", rms), ("meanSquare", energy)):
        row = result["lanes"][lane]
        require(row["available"] == len(values) * fixture["repeats"], "Complete level windows differ")
        # Both input types are widened for the public level accumulator.
        require(math.isclose(row["sum"], math.fsum(values) * fixture["repeats"],
                             rel_tol=1e-10, abs_tol=1e-12), f"Direct PCM integration differs for {lane}")


def validate_cases(rows):
    name = os.environ["VOICE_SUITE_FIXTURE"]
    directory = Path(os.environ["VOICE_SUITE_INPUTS"])
    fixtures = json.loads((directory / "manifest.json").read_bytes())["cases"]
    fixture = next(f for f in fixtures if f["name"] == name)
    expected = {op + "." + name for op in OPERATIONS}
    phase_names = {"coldSetup", "firstOutput", "warmHop", "warmPowerCepstrogram", "warmFromPower", "warmAggregation"}
    if name == "filtered-harmonics":
        expected |= {"phase." + phase + "." + name for phase in phase_names}
    require(len(rows) == len(expected) and {r["name"] for r in rows} == expected, "Incomplete profile matrix")
    observed = {}
    for r in rows:
        op = r["name"].removesuffix("." + name)
        require(r["fixture"] == fixture, "Prepared PCM identity differs")
        if op.startswith("phase."):
            phase = r["phase"]
            require(r["recipe"]["composition"] == "cpps" and op == "phase." + phase["phase"]
                    and phase["measuredOutputs"]["available"] > 0 and phase["measuredOutputs"]["unavailable"] == 0,
                    "Phase produced no valid work")
            if phase["phase"] in ("warmHop", "warmPowerCepstrogram"):
                require(phase["sourceSamplesInsideTimer"] == fixture["sampleRate"] // 100
                        and phase["measuredOutputs"]["available"] == 1, "Warm phase must consume one hop")
            elif phase["phase"] == "warmFromPower":
                require(phase["inputPowerRowsInsideTimer"] == 1, "Missing upstream power row")
            elif phase["phase"] == "warmAggregation":
                require(phase["inputFramesBeforeAggregation"] > 0, "Aggregation was cold")
            elif phase["phase"] == "firstOutput":
                require(phase["sourceSamplesBeforeTimer"] == 0 and phase["sourceSamplesInsideTimer"] > 0,
                        "First-output phase was prefilled")
            continue
        observed[op] = result = r["results"][0]
        require(r["recipe"]["composition"] == op.split(".")[1], "Unexpected numerical profile")
        require(len(r["results"]) == (2 if op == "pair.full" else 1) and all(x == result for x in r["results"]),
                "Concurrent workers differ")
        require(all(v["available"] + v["unavailable"] > 0 and math.isfinite(v["sum"])
                    for v in result["lanes"].values()), "Empty or nonfinite metric")
    cpps, core, full = (observed[k] for k in OPERATIONS[:3])
    require(set(cpps["lanes"]) == {"cpp", "cpps", "rollingCPPS"}, "Unexpected reduced-profile lane")
    require(cpps["spectralRows"] == core["spectralRows"] == 0, "Disabled transform executed")
    require(all(core["lanes"][k] == v for k, v in cpps["lanes"].items())
            and all(full["lanes"][k] == v for k, v in core["lanes"].items()), "Shared results changed with composition")
    separate = observed["single.separateSpectra"]
    require(full["spectralRows"] > 0 and separate == dict(full, spectralRows=2 * full["spectralRows"]),
            "Separate transforms failed to reproduce the shared path")
    require(observed["pair.full"] == full, "Independent and concurrent results differ")
    require(full["epochs"] == len(fixture["regions"]) * fixture["repeats"]
            and full["analyzedSamples"] == sum(r["count"] for r in fixture["regions"]) * fixture["repeats"],
            "Discontinuity was lost")
    require(full["maximumRootSweeps"] <= 128 and full["pulseTrackingAttempts"] <= 2 * full["epochs"] * 16384,
            "Numerical work exceeded its profile bound")
    required = {"cpp", "cpps", "rollingCPPS", "peak", "rms", "meanSquare", "kWeightedMeanSquare",
                "levelDBFS", "samplePeakDBFS", "clippingFraction", "crest", "yin", "trackedYin",
                "hnrDB", "hnrPeriodicity", "swipePrime", "spectrogram", "ltas", "ltsf", "speechInterval",
                "h1h2", "correctedH1H2", "pulses"}
    required |= {f"{prefix}{n}" for prefix in ("formant", "bandwidth") for n in range(1, 4)}
    required |= {"jitter." + s for s in ("local", "absolute", "rap", "ppq5", "ddp")}
    required |= {"shimmer." + s for s in ("local", "db", "apq3", "apq5", "apq11", "dda")}
    require(required <= full["lanes"].keys(), "Missing public metric")
    require(all(sum(k.startswith(prefix) for k in full["lanes"]) == 6 for prefix in ("frame.", "ltas.")),
            "Missing spectral descriptor")
    direct_levels(fixture, full, directory)
    if fixture["condition"] == "silence":
        for lane in ("cpps", "yin", "swipePrime", "pulses", "jitter.local", "shimmer.local", "correctedH1H2"):
            require(full["lanes"][lane]["available"] == 0, f"Silence produced {lane}")
    if fixture["condition"] == "boundary":
        require(full["omittedPulseRegions"] == full["epochs"] and full["pulseTrackingAttempts"] == 0,
                "A pulse contour bridged a gap")
    if name == "gaussian-48000-80-float64":
        require(full["secondRootStarts"] > 0 and full["maximumRootSweeps"] == 128,
                "Adversarial pole solver did not exercise the bounded second start")
    if name == "corpus-bl01-vowel-a":
        require(all(full["lanes"][k]["available"] > 0 for k in required), "Missing positive vowel control")
    expected_f0 = {"harmonic-low": 62.5, "harmonic-high": 625, "gaussian-48000-80-float64": 80,
                   "gaussian-48000-600-float32": 600}.get(name)
    if expected_f0:
        lane = full["lanes"]["yin"]
        require(lane["available"] > 0 and abs(1200 * math.log2(lane["sum"] / lane["available"] / expected_f0)) <= 20,
                "Pitch differs from governed periodic source by more than the harmonic reference budget")


def throughput(_, row, wall):
    if "phase" in row:
        phase = row["phase"]
        seconds = phase["sourceSamplesInsideTimer"] / row["fixture"]["sampleRate"]
        return dict(workers=1, analyzedSecondsPerWorker=seconds, epochsPerWorker=0,
                    workerAudioSecondsPerWallSecond=seconds * 1e9 / wall["p50"] if seconds else None)
    workers = len(row["results"])
    result = row["results"][0]
    seconds = result["analyzedSamples"] / row["fixture"]["sampleRate"]
    return dict(workers=workers, analyzedSecondsPerWorker=seconds, epochsPerWorker=result["epochs"],
                workerAudioSecondsPerWallSecond=seconds * workers * 1e9 / wall["p50"])


SUITE = SpectralBenchmarkSuite("VoiceSuiteBenchmarks", "VoiceSuite", "Capability.VoiceSuiteAllocationARC",
    "voice-suite", "VoiceSuiteWorkloadCheck", {"Run": "One complete fixture including worker preparation, every "
    "continuity boundary, result consumption and finish. The pair includes dispatch and both completions."},
    validate_cases, throughput, "Hash-checked governed mono PCM. Each region uses its own acquisition epoch.",
    "PCM decoding and profile construction precede the timer. Each trial owns its workers and scalar result fingerprints.",
    "Elapsed duration of the entire fixture for one worker or one concurrent pair.", minimum_trials=3)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("timing", "allocation"))
    parser.add_argument("fixture")
    parser.add_argument("--development-toolchain", action="store_true")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory() as temp:
        directory = Path(temp) / "inputs"
        prepare(directory)
        if args.fixture not in {row["name"] for row in json.loads((directory / "manifest.json").read_bytes())["cases"]}:
            parser.error("Unknown governed fixture")
        os.environ.update(VOICE_SUITE_INPUTS=str(directory), VOICE_SUITE_FIXTURE=args.fixture)
        sys.argv[1:] = [args.mode] + (["--development-toolchain"] if args.development_toolchain else [])
        measure(SUITE)


if __name__ == "__main__":
    main()
