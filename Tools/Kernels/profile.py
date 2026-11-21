#!/usr/bin/env python3
"""Sample each synthetic CPPS stage in isolation and export counts of attributed stacks."""

import argparse
from pathlib import Path
import re
import subprocess
import tempfile
import xml.etree.ElementTree as ET

# Use the paired driver's build flags, including the opt-in stage access trait.
if __package__:
    from . import benchmark as kernels
else:
    import sys

    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
    from Tools.Kernels import benchmark as kernels

SYMBOLS = {
    "meanRemoval": ("PreparedPowerCepstrum.removeMean(",),
    "logPower": ("PreparedPowerCepstrum.writeLogPower(",),
    "inverseCepstrum": (
        "PreparedPowerCepstrum.writeSignedCepstrum(",
        "PreparedFourierTransform.inverseReal(",
    ),
    "peakParabolic": ("PreparedCPP.findPeak(", "PreparedCPP.peakFromSide("),
    "backgroundFit": ("PreparedCPP.fit(", "CPPSelection.select(", "CPPSelection.median("),
}


def summarize(xml, stage):
    root = ET.parse(xml)
    identifiers = {node.get("id"): node for node in root.iter() if node.get("id")}

    def resolved(node):
        return identifiers[node.get("ref")] if node is not None and node.get("ref") else node

    total = attributed = 0
    matched = set()
    for row in root.iter("row"):
        process = resolved(row.find("process"))
        if process is None or not process.get("fmt", "").startswith("KernelWorkloadCheck ("):
            continue
        stack = resolved(row.find("tagged-backtrace"))
        if stack is None:
            continue
        total += 1
        symbols = []
        for entry in stack.findall("frame"):
            frame = resolved(entry)
            image = resolved(frame.find("binary"))
            if image is not None and image.get("name") == "KernelWorkloadCheck":
                symbols.append(frame.get("name", ""))
        hits = {symbol for symbol in symbols if any(key in symbol for key in SYMBOLS[stage])}
        if hits:
            attributed += 1
            matched.update(hits)
    if not attributed:
        raise ValueError(f"No target-process sampled stack attributable to {stage} among {total} stacks")
    return dict(sampledStacks=total, attributedStacks=attributed, matchedSymbols=sorted(matched))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    identity = kernels.build_identity()
    flags = kernels.swift("timing")
    subprocess.run(["swift", "build", *flags, "--product", "KernelWorkloadCheck"], check=True)
    binary = Path(kernels.ci.capture("swift", "build", *flags, "--show-bin-path")) / "KernelWorkloadCheck"
    report = dict(
        template="Time Profiler",
        binarySHA256=kernels.framework.sha(binary),
        buildIdentity=identity,
        environment={**kernels.ci.environment("release"), "execution": "synthetic host profile"},
        hardwareModel=kernels.ci.capture("sysctl", "-n", "hw.model"),
        stages={},
    )
    # Raw system traces contain host/process details. Export only the allowlisted attribution counts.
    with tempfile.TemporaryDirectory() as tmp:
        for stage in SYMBOLS:
            trace = Path(tmp) / (stage + ".trace")
            stdout = Path(tmp) / (stage + ".txt")
            subprocess.run(
                [
                    "xcrun",
                    "xctrace",
                    "record",
                    "--template",
                    "Time Profiler",
                    "--output",
                    str(trace),
                    "--time-limit",
                    "1m",
                    "--target-stdout",
                    str(stdout),
                    "--launch",
                    "--",
                    str(binary),
                    "--profile",
                    stage,
                ],
                check=True,
            )
            trial = re.fullmatch(
                r"(\S+) (\d+) verified batches of (\d+) operations", stdout.read_text().strip()
            )
            if not trial or not trial[1].startswith(stage + ".") or min(int(trial[2]), int(trial[3])) < 1:
                raise ValueError(f"Synthetic stage did not finish its verified workload: {stage}")
            xml = Path(tmp) / (stage + ".xml")
            subprocess.run(
                [
                    "xcrun",
                    "xctrace",
                    "export",
                    "--input",
                    str(trace),
                    "--xpath",
                    '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]',
                    "--output",
                    str(xml),
                ],
                check=True,
            )
            report["stages"][stage] = dict(
                summarize(xml, stage),
                workload=trial[1],
                verifiedBatches=int(trial[2]),
                operationsPerBatch=int(trial[3]),
            )
    kernels.verify_identity(identity)
    kernels.write(args.output / "attribution.json", report)
    print(args.output / "attribution.json")


if __name__ == "__main__":
    main()
