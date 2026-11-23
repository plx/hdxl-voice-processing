"""Measure incremental inspector costs on identical synthetic YIN frames, one fresh process per mode."""
import argparse
import json
import math
import platform
import re
import statistics
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MODES = {"processorOnly": (0, 0), "disabled": (0, 0), "selected": (1, 1), "sampled": (60, 8)}


def summarize(records):
    if len(records) != len(MODES) or {record["mode"] for record in records} != MODES.keys():
        raise ValueError("Missing or duplicate capture mode")
    if len({r["profileSHA256"] for r in records}) != 1 or not re.fullmatch(r"[0-9a-f]{64}", records[0]["profileSHA256"]):
        raise ValueError("Profile mismatch")
    if len({r["pitchChecksumHz"] for r in records}) != 1 or not 0 < records[0]["pitchChecksumHz"] < math.inf:
        raise ValueError("Different or missing YIN observations")
    output = {}
    for r in records:
        mode = r["mode"]
        n, retained = MODES[mode]
        times = sorted(r["frameNanoseconds"])
        copies = sorted(r["captureNanoseconds"])
        if (r["frames"] != 240 or len(times) != 240 or len(copies) != n or r["captured"] != n
                or r["retainedFrames"] != retained or any(type(t) is not int or t < 1 for t in times + copies)
                or not 0 < r["peakRSSBeforeBytes"] <= r["peakRSSAfterBytes"]
                or any((r[key] <= 0 if retained else r[key] != 0)
                       for key in ("retainedCurveBytes", "retainedMetadataBytes"))):
            raise ValueError(f"Invalid capture workload for {mode}")
        output[mode] = {"medianFrameNs": statistics.median(times), "p95FrameNs": times[math.ceil(.95 * len(times)) - 1],
                        "maximumFrameNs": max(times), "meanFrameNs": statistics.mean(times),
                        "medianCaptureNs": statistics.median(copies) if copies else None,
                        "retainedCurveBytes": r["retainedCurveBytes"], "retainedMetadataBytes": r["retainedMetadataBytes"],
                        "peakRSSGrowthBytes": r["peakRSSAfterBytes"] - r["peakRSSBeforeBytes"]}
    for row in output.values():
        row["meanFrameDeltaFromProcessorNs"] = row["meanFrameNs"] - output["processorOnly"]["meanFrameNs"]
        row["peakRSSGrowthDeltaFromProcessorBytes"] = row["peakRSSGrowthBytes"] - output["processorOnly"]["peakRSSGrowthBytes"]
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--scratch-path", type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    build = ["swift", "build", "-c", "release", "--package-path", str(ROOT / "Examples/VisualizationConsumer")]
    if args.scratch_path:
        build.extend(["--scratch-path", str(args.scratch_path.resolve())])
    subprocess.run(build, check=True)
    binary = Path(subprocess.check_output([*build, "--show-bin-path"], text=True).strip()) / "VisualizationConsumer"
    summary = []
    for trial in range(3):
        records = []
        modes = list(MODES)
        for mode in modes[trial:] + modes[:trial]:
            path = args.output / f"{trial}-{mode}.json"
            subprocess.run([binary, "--inspect", mode, path], check=True)
            records.append(json.loads(path.read_bytes()))
        summary.append(summarize(records))
    environment = {"operatingSystem": platform.mac_ver()[0], "architecture": platform.machine(),
                   "hardware": subprocess.check_output(["sysctl", "-n", "hw.model"], text=True).strip(),
                   "swift": subprocess.check_output(["swift", "--version"], text=True).strip()}
    (args.output / "summary.json").write_text(json.dumps({"trials": summary, "environment": environment}, indent=2) + "\n")


if __name__ == "__main__":
    main()
