#!/usr/bin/env python3
"""Run reproducible synthetic microphone replay through the release capture lifecycle."""

import argparse
import gzip
import json
from pathlib import Path
import statistics
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Tools"))
import ci
from Performance.records import sha, system_state
from Streaming.build import verified_binary
from Streaming.report import summarize

PROFILES = ("cpps", "core", "full")
MODES = ("disabled", "sampled", "detailed")
SEED = 7


def cases(group):
    if group in PROFILES:
        for rate in (44100, 48000):
            for pattern in ("64", "128", "256", "512", "1024", "mixed"):
                for load in ("throughput", "paced"):
                    yield group, rate, pattern, load, "disabled", 2, "single", 0
    elif group == "overhead":
        # Each mode takes every ordinal position. Deviations include host scheduling noise.
        for profile in PROFILES:
            for trial in range(6):
                for i in range(3):
                    yield profile, 48000, "mixed", "throughput", MODES[(trial+i) % 3], 2, "overhead", trial
    elif group == "stress":
        for profile in PROFILES:
            for mode in MODES:
                yield profile, 44100, "512", "burst", mode, 2, "single", 0
        yield "core", 48000, "mixed", "throughput", "sampled", 2, "restart", 0
        yield "full", 48000, "256", "paced", "disabled", 2, "concurrent", 0
    elif group == "capacity":
        for rate in (44100, 48000):
            for pattern in ("64", "mixed"):
                for slots in (32, 512):
                    yield "full", rate, pattern, "paced", "disabled", 3, "single", slots
    elif group == "soak":
        for load in ("throughput", "paced"):
            yield "full", 48000, "mixed", load, "disabled", 120, "soak", 0
    else:
        raise ValueError(f"Unknown workload group {group}")


def check_overhead(runs):
    output = {}
    for profile in PROFILES:
        indexed = {(run["repeat"], run["trials"][0]["mode"]): run["trials"][0] for run in runs
                   if run["trials"][0]["profile"] == profile}
        if set(indexed) != {(rep, mode) for rep in range(6) for mode in MODES}:
            raise ValueError("Incomplete paired instrumentation matrix")
        if len({r["scienceSHA256"] for r in indexed.values()}) != 1:
            raise ValueError("A diagnostic mode changed the measurements or validity")
        output[profile] = {}
        for mode in MODES:
            times = []
            for rep in range(6):
                base, measured = indexed[rep, "disabled"], indexed[rep, mode]
                times.append(dict(repeat=rep, wallDeltaNS=measured["elapsedFirstOfferToLastDrainNS"] -
                                  base["elapsedFirstOfferToLastDrainNS"]))
            output[profile][mode] = dict(pairs=times, medianWallDeltaNS=statistics.median(
                row["wallDeltaNS"] for row in times))
    return output


def validate_group(group, runs):
    if group in PROFILES:
        for rate in (44100, 48000):
            peers = [r["trials"][0] for r in runs if r["trials"][0]["sampleRate"] == rate
                     and r["trials"][0]["load"] == "throughput"]
            if len(peers) != 6 or len({r["scienceSHA256"] for r in peers}) != 1:
                raise ValueError("Callback geometry changed the fixed source regions or scientific output")
        for i in range(0, len(runs), 2):
            baseline, paced = runs[i]["trials"][0], runs[i+1]["trials"][0]
            if paced["droppedFrames"] == 0 and paced["scienceSHA256"] != baseline["scienceSHA256"]:
                raise ValueError("Pacing changed outputs for identical admitted samples")
    if group == "stress":
        for profile in PROFILES:
            burst = [run["trials"][0] for run in runs if run["trials"][0]["profile"] == profile
                     and run["trials"][0]["load"] == "burst"]
            if len(burst) != 3 or len({r["scienceSHA256"] for r in burst}) != 1:
                raise ValueError("Overrun recovery differs between diagnostic modes")
        if not any(run.get("cancellation", {}).get("pendingChunksAtCancel", 0) > 0 for run in runs):
            raise ValueError("Missing in-flight cancellation evidence")
    return check_overhead(runs) if group == "overhead" else None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("build_receipt", type=Path)
    parser.add_argument("group", choices=(*PROFILES, "overhead", "stress", "soak", "capacity"))
    parser.add_argument("output", type=Path)
    parser.add_argument("--development-toolchain", action="store_true")
    args = parser.parse_args()
    environment = ci.environment("release")
    binary, build = verified_binary(args.build_receipt, environment)
    if not args.development_toolchain:
        ci.validate_environment(environment, json.loads((ROOT / "Configuration/build.json").read_bytes()))
    environment.update(execution="synthetic PCM via production tap, lifecycle, worker and subscriptions",
                       model=ci.capture("sysctl", "-n", "hw.model"), cpu=ci.capture("sysctl", "-n", "machdep.cpu.brand_string"),
                       power=system_state(), pinnedToolchain=not args.development_toolchain)
    args.output.mkdir(parents=True, exist_ok=False)
    results = []
    with tempfile.TemporaryDirectory() as tmp:
        raw = Path(tmp) / "trial.json"
        for i, (profile, rate, pattern, load, mode, seconds, operation, repeat) in enumerate(cases(args.group)):
            command = [profile, str(rate), pattern, load, mode, str(seconds), str(SEED), operation]
            print(" ".join(command), f"repeat={repeat}", flush=True)
            slot_args = [str(repeat)] if args.group == "capacity" else []
            subprocess.run([binary, *command, raw, *slot_args], check=True, timeout=max(120, seconds * 5))
            data = raw.read_bytes()
            doc = json.loads(data)
            if doc["schemaVersion"] != 1 or len(doc["trials"]) != {"restart": 3, "concurrent": 2}.get(operation, 1):
                raise ValueError("Invalid replay document")
            trials = [summarize(trial) for trial in doc["trials"]]
            artifact = args.output / f"{i:03d}-{profile}-{rate}-{pattern}-{load}-{mode}-{operation}.json.gz"
            artifact.write_bytes(gzip.compress(data, compresslevel=6, mtime=0))
            row = dict(repeat=0 if slot_args else repeat, slots=repeat if slot_args else 32, arguments=command, raw=artifact.name, rawSHA256=sha(artifact), trials=trials)
            if "cancellation" in doc:
                row["cancellation"] = doc["cancellation"]
            results.append(row)
            raw.unlink()
    paired = validate_group(args.group, results)
    if verified_binary(args.build_receipt, ci.environment("release"))[1] != build:
        raise ValueError("Release build changed during measurement")
    receipt = dict(schemaVersion=1, group=args.group, binarySHA256=build["binarySHA256"], build=build, environment=environment,
                   physicalFollowup=74, integrationIssue=62, deviceProtocolIssue=64, runs=results)
    if paired:
        receipt["instrumentationOverhead"] = paired
    (args.output / "results.json").write_text(ci.redact(json.dumps(receipt, indent=2, allow_nan=False)) + "\n")


if __name__ == "__main__":
    main()
