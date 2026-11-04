#!/usr/bin/env python3
"""Measure synthetic instrumentation overhead; no production DSP or device claims."""
import argparse
import json
from pathlib import Path
import re
import shutil
import statistics
import subprocess
import sys

import ci

ROOT = ci.ROOT
MODES = ("bare", "disabled", "sampled", "detailed")


def expected_checksum(iterations):
    mask = (1 << 64) - 1
    total = 0
    for index in range(iterations):
        value = index
        for _ in range(32):
            value = (value * 6364136223846793005 + 1442695040888963407) & mask
            value ^= value >> 23
        total = (total + value) & mask
    return f"{total:x}"


def summarize(rows, compiled_out=False):
    if not isinstance(rows, list) or len(rows) != 32:
        raise ValueError("Expected eight complete trials of four modes")
    keyed = {(row["trial"], row["mode"]): row for row in rows}
    if set(keyed) != {(trial, mode) for trial in range(8) for mode in MODES}:
        raise ValueError("Missing/duplicate instrumentation trials")
    checksum = expected_checksum(10000)
    for row in rows:
        for key in ("iterations", "nanoseconds", "intervals", "events", "suppressed", "unavailable"):
            if type(row[key]) is not int or row[key] < 0:
                raise ValueError(f"Invalid counter/duration: {key}")
        if row["iterations"] != 10000 or row["nanoseconds"] == 0 or row["checksum"] != checksum:
            raise ValueError("Incorrect synthetic workload, duration, or optimized output")
        if row["mode"] in ("bare", "disabled"):
            if any(row[key] for key in ("intervals", "events", "suppressed", "unavailable")):
                raise ValueError("Disabled path emitted or consulted diagnostics")
        else:
            selected = 625 if row["mode"] == "sampled" else 10000
            suppressed = 37500 if row["mode"] == "sampled" else 0
            if row["suppressed"] != suppressed:
                raise ValueError("Frame sampling changed")
            if compiled_out:
                if (row["intervals"], row["events"], row["unavailable"]) != (0, 0, selected * 4 + 1):
                    raise ValueError("Compile-time no-op path attempted system signposts")
            elif (row["intervals"], row["events"], row["unavailable"]) != (selected * 3, selected + 1, 0):
                raise ValueError("Active signpost backend unavailable or emission count changed")
    summary = {}
    for mode in MODES:
        values = [keyed[trial, mode]["nanoseconds"] / 10000 for trial in range(8)]
        deltas = [(keyed[trial, mode]["nanoseconds"] - keyed[trial, "bare"]["nanoseconds"]) / 10000
                  for trial in range(8)]
        summary[mode] = {"medianNanosecondsPerFrame": statistics.median(values),
                         "minNanosecondsPerFrame": min(values), "maxNanosecondsPerFrame": max(values),
                         "medianPairedOverheadNanoseconds": statistics.median(deltas)}
    return {"checksum": checksum, "modes": summary, "trials": 8, "framesPerTrial": 10000,
            "systemSignposts": "compiled out" if compiled_out else "enabled",
            "interpretation": "observed host overhead only; no timing gate or zero-cost claim"}


def inspect_callback(binary):
    assembly = ci.capture("xcrun", "llvm-objdump", "--disassemble", str(binary))
    lines = assembly.splitlines()
    starts = [i for i, line in enumerate(lines) if line.endswith(">:") and
              "CaptureDiagnostics" in line and "6record" in line]
    if len(starts) != 1:
        raise ValueError("Cannot locate optimized capture counter function")
    start = starts[0]
    end = next((i for i in range(start + 1, len(lines)) if lines[i].endswith(">:")), len(lines))
    body = lines[start:end]
    instructions = []
    for line in body[1:]:
        match = re.match(r"\s*[0-9a-f]+:\s+[0-9a-f]+\s+(\S+)", line)
        if match:
            instructions.append(match.group(1))
    # Fail closed on this pinned arm64 compiler's output. No function calls,
    # atomics, traps, backwards branches, allocation or synchronization allowed.
    allowed = {"ldr", "str", "adds", "b.lo", "mov", "tbz", "csinv", "cmp", "csel", "ret"}
    if not instructions or len(instructions) > 32 or set(instructions) - allowed:
        raise ValueError("Capture counter code needs a new bounded-operation audit")
    for line in body[1:]:
        branch = re.match(r"\s*([0-9a-f]+):.*\s(?:b\.lo|tbz)\s+.*?0x([0-9a-f]+)\s*$", line.split("<")[0])
        if branch and int(branch[2], 16) <= int(branch[1], 16):
            raise ValueError("Capture counter contains a backward branch")
    return "\n".join(body) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--compiled-out", action="store_true")
    args = parser.parse_args()
    name = "compiled-out" if args.compiled_out else "system"
    output = ROOT / ".build" / "instrumentation-artifacts" / name
    if output.exists():
        shutil.rmtree(output)
    output.mkdir(parents=True)
    result = {"status": "failed", "commands": []}
    try:
        environment = ci.environment("release")
        ci.validate_environment(environment, json.loads((ROOT / "Configuration/build.json").read_text()))
        environment.update(purpose="synthetic instrumentation overhead", capture="not exercised",
                           tracing="system enabled; external recorder not assumed", compiledOut=args.compiled_out)
        (output / "environment.json").write_text(ci.redact(json.dumps(environment, indent=2)) + "\n")
        scratch = ROOT / ".build" / f"instrumentation-{name}"
        flags = ["--scratch-path", str(scratch), "-c", "release"]
        if args.compiled_out:
            flags += ["-Xswiftc", "-DHDXL_DISABLE_SIGNPOSTS"]
        with (output / "commands.log").open("w") as log:
            ci.run_command(["swift", "build", *flags, "--product", "InstrumentationProbe"], log, result["commands"])
        binary = Path(ci.capture("swift", "build", *flags, "--show-bin-path")) / "InstrumentationProbe"
        rows = json.loads(ci.capture(str(binary)))
        (output / "trials.json").write_text(json.dumps(rows, indent=2) + "\n")
        result.update(summarize(rows, args.compiled_out))
        (output / "capture-counter-assembly.txt").write_text(inspect_callback(binary))
        result["callbackCodeAudit"] = "arm64 bounded leaf; no calls, allocation, locks or loops"
        result["status"] = "passed"
    except (ValueError, KeyError, OSError, RuntimeError, subprocess.SubprocessError) as error:
        result["error"] = ci.redact(str(error))
    (output / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))
    return 0 if result["status"] == "passed" else 1


if __name__ == "__main__":
    sys.exit(main())
