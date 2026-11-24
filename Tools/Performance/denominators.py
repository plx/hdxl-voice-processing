"""Audit the denominators of an unscaled smoke export and one scheduled PCM run."""
import argparse
import hashlib
import json
import math
from pathlib import Path

TIME_TO_NS = {"ns": 1, "μs": 1_000, "ms": 1_000_000, "s": 1_000_000_000}


def read(directory, name):
    return json.loads((directory / name).read_bytes())


def positive(value):
    if type(value) not in (int, float) or not math.isfinite(value) or value <= 0:
        raise ValueError(f"Expected a positive finite observation, got {value}")
    return value


def timing_environment(directory, files):
    result = read(directory, "result.json")
    environment = read(directory, "environment.json")
    if result["status"] != "passed" or result["mode"] != "timing" or environment["frameworkScalingFactor"] != 1:
        raise ValueError("Expected successful timing evidence at framework scaling factor one")
    return environment, verify_files(directory, result, environment, files)


def verify_files(directory, result, environment, files):
    manifest_path = directory / "workload-manifest.json"
    if not manifest_path.is_file() and "measurementMode" not in environment and "workloadManifestSHA256" not in result:
        return "legacy-unbound"
    if environment.get("measurementMode") != "timing" or environment.get("allocatorBackend") != "disabled":
        raise ValueError("Timing requires an environment with the allocator backend disabled")
    verify_manifest(directory, result, "timing", files)
    return "digest-verified"


def verify_manifest(directory, result, mode, files):
    content = (directory / "workload-manifest.json").read_bytes()
    if result.get("workloadManifestSHA256") != hashlib.sha256(content).hexdigest():
        raise ValueError("Final result does not match the workload manifest digest")
    manifest = json.loads(content)
    if manifest["schemaVersion"] != 1 or manifest["mode"] != mode:
        raise ValueError(f"Expected a {mode} workload manifest")
    for field, filename in files.items():
        if (manifest[field] != filename or
                manifest[field + "SHA256"] != hashlib.sha256((directory / filename).read_bytes()).hexdigest()):
            raise ValueError(f"Workload manifest digest or filename mismatch: {filename}")


def smoke(directory):
    env, binding = timing_environment(directory, {"environmentFile": "environment.json", "caseFile": "workload.json",
                                                  "exportFile": "Current_run.json"})
    case = read(directory, "workload.json")
    if (case["mode"] != "timing" or case["framesPerBatch"] != env["framesPerSmokeIteration"]
            or case["samplesPerFrame"] != env["samplesPerFrame"]):
        raise ValueError("Smoke denominator differs between the harness and its workload check")
    export = read(directory, "Current_run.json")
    rows = [r for r in export if r["name"] == "Smoke.GainEnergy - Time (wall clock)"]
    if len(rows) != 1 or rows[0]["unit"] not in TIME_TO_NS:
        raise ValueError("Expected one batch wall-time observation with a known time unit")
    elapsed = positive(rows[0]["value"]) * TIME_TO_NS[rows[0]["unit"]]
    return dict(operation="Smoke.GainEnergy", commit=env["commit"], artifactBinding=binding, batchP99Nanoseconds=elapsed,
                framesPerBatch=case["framesPerBatch"], samplesPerFrame=case["samplesPerFrame"],
                averageNanosecondsPerFrameInP99Batch=elapsed / positive(case["framesPerBatch"]),
                singleFrameLatencyDistribution="unmeasured")


def schedule(directory, name):
    env, binding = timing_environment(directory, {"environmentFile": "environment.json", "caseFile": "workloads.json",
                                                  "distributionFile": "distributions.json", "exportFile": "p99.json"})
    matrix = read(directory, "workloads.json")
    rows = [r for r in matrix if r["name"] == name]
    if len(rows) != 1:
        raise ValueError("Expected exactly one selected scheduler workload")
    row = rows[0]
    if row["digest"] != row["directDigest"] or row["digest"] != row["splitDigest"]:
        raise ValueError("Direct or alternate-chunk coverage differs")
    op = "Schedule.Run." + name
    values = read(directory, "p99.json")
    # Scheduling's wrapper explicitly exports nanoseconds and validates the units before writing p99.json.
    elapsed = positive(values[op + " - Time (wall clock)"])
    cpu = values[op + " - Time (total CPU)"]
    source = positive(row["inputDurationSeconds"])
    analyzed = row["analyzedDurationSeconds"]
    if any(type(v) not in (int, float) or not math.isfinite(v) or v < 0 for v in (analyzed, cpu)):
        raise ValueError("Analyzed duration and process CPU must be finite and nonnegative")
    return dict(operation=op, commit=env["commit"], pcmSHA256=row["inputSHA256"], artifactBinding=binding,
                wallBatchP99Nanoseconds=elapsed, processCPUBatchP99Nanoseconds=cpu,
                inputSeconds=source, analyzedSeconds=analyzed,
                inputSecondsPerWallSecondAtP99=source * 1e9 / elapsed,
                analyzedSecondsPerWallSecondAtP99=analyzed * 1e9 / elapsed,
                realTimeFactorAtWallP99=elapsed / (1e9 * source),
                validityByLane={lane: dict(processed=x["frames"], available=x["available"],
                                           unavailable=x["frames"]-x["available"]) for lane,x in row["digest"].items()},
                captureToResultAge="unmeasured")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("smoke_directory", type=Path)
    parser.add_argument("schedule_directory", type=Path)
    parser.add_argument("--case", default="light.float32.16000Hz.c1.interleaved.preview")
    args = parser.parse_args()
    print(json.dumps(dict(smoke=smoke(args.smoke_directory), schedule=schedule(args.schedule_directory, args.case)), indent=2))
