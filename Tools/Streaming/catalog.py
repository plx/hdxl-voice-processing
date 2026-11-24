#!/usr/bin/env python3
"""Verify the replay receipts and export a compact, revision-bound index for the dashboard."""

import argparse
import gzip
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Tools"))
from Performance.records import sha
from Streaming.benchmark import PROFILES, SEED, cases, validate_group
from Streaming.report import summarize

GROUPS = (*PROFILES, "capacity", "stress", "overhead", "soak")


def compact(trial):
    keys = ("profile", "profileSHA256", "sampleRate", "pattern", "load", "mode", "operation", "seconds", "seed",
            "offeredFrames", "consumedFrames", "droppedFrames", "emittedFrames", "gapCount", "resetCount",
            "queueHighWater", "queueSlots", "schedulerBytes", "pcmBytes", "totalWorkerNS", "throughputRealtimeFactor",
            "workerSecondsPerAdmittedSecond", "scienceSHA256", "callbackBudgetMisses", "secondHalfResidentBytes")
    row = {key: trial[key] for key in keys if key in trial}
    row["lanes"] = {lane: {key: item[key] for key in ("frames", "outcomes", "windows",
                    "acousticEndToObservationNS", "deadlineMisses") if key in item}
                    for lane, item in trial.get("lanes", {}).items()} or trial.get("laneOutcomes", {})
    return row


def group_index(path):
    receipt = json.loads(path.read_bytes())
    group = receipt["group"]
    planned = list(cases(group))
    if receipt.get("schemaVersion") != 1 or len(planned) != len(receipt["runs"]):
        raise ValueError(f"Incomplete {group} receipt")
    rows = []
    files = set()
    for run, case in zip(receipt["runs"], planned, strict=True):
        profile, rate, pattern, load, mode, seconds, operation, repeat = case
        args = [profile, str(rate), pattern, load, mode, str(seconds), str(SEED), operation]
        slots = repeat if group == "capacity" else 32
        name = run["raw"]
        if (run["arguments"] != args or run["slots"] != slots or run["repeat"] != (0 if group == "capacity" else repeat)
                or name != Path(name).name or not name.endswith(".json.gz") or name in files):
            raise ValueError("Mismatched case arguments or duplicate artifact")
        files.add(name)
        raw = path.parent / name
        if sha(raw) != run["rawSHA256"]:
            raise ValueError(f"Replay artifact digest mismatch: {name}")
        doc = json.loads(gzip.decompress(raw.read_bytes()))
        trials = [summarize(trial) for trial in doc["trials"]]
        expected_profiles = ([profile, "core" if profile == "cpps" else "cpps", profile] if operation == "restart"
                             else [profile, profile] if operation == "concurrent" else [profile])
        if (doc["schemaVersion"] != 1 or [t["profile"] for t in trials] != expected_profiles or trials != run["trials"]
                or doc.get("cancellation") != run.get("cancellation")):
            raise ValueError("Summary or composition differs from native receipts")
        for t in trials:
            expected_pattern = [64,128,256,512,1024,93,711] if pattern == "mixed" else [int(pattern)]
            if (t["sampleRate"], t["pattern"], t["load"], t["mode"], t["seconds"], t["seed"], t["operation"],
                t["queueSlots"], t["offeredFrames"]) != (rate, expected_pattern, load, mode, seconds,
                                                          SEED, operation, slots, rate * seconds):
                raise ValueError("Native workload differs from declared acquisition schedule")
        rows.append(dict(raw=name, rawSHA256=sha(raw), repeat=run["repeat"], trials=[compact(t) for t in trials]))
    paired = validate_group(group, receipt["runs"])
    if receipt.get("instrumentationOverhead") != paired:
        raise ValueError("Paired overhead differs from raw evidence")
    evidence = dict(environment=receipt["environment"], receiptSHA256=sha(path), binarySHA256=receipt["binarySHA256"],
                    runs=rows)
    if paired is not None:
        evidence["pairedOverhead"] = paired
    return group, evidence


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("receipts", nargs="+", type=Path)
    args = parser.parse_args()
    groups = {}
    for path in args.receipts:
        group, value = group_index(path)
        if group in groups:
            raise ValueError(f"Duplicate group {group}")
        groups[group] = value
    if set(groups) != set(GROUPS):
        raise ValueError("Supply one results.json from every timing and lifecycle group")
    commits = {v["environment"]["commit"] for v in groups.values()}
    if len(commits) != 1 or not re.fullmatch("[0-9a-f]{40}", next(iter(commits))) or any(
            v["environment"]["workingTreeDirty"] for v in groups.values()):
        raise ValueError("Published catalog requires one clean measured source revision")
    with args.output.open("x") as stream:
        json.dump(dict(schemaVersion=1, commit=commits.pop(), groups=groups), stream,
                  sort_keys=True, separators=(",", ":"), allow_nan=False)
        stream.write("\n")


if __name__ == "__main__":
    main()
