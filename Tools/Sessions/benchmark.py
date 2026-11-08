#!/usr/bin/env python3
"""Fresh-process synthetic serialization/storage evidence; no DSP or capture."""
import argparse
from collections import Counter
import copy
import hashlib
import json
import math
from pathlib import Path
import statistics
import struct
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Tools"))
import ci

COUNTS = (6_000, 720_000)  # one minute and two hours at 100 results/second
TRIALS = 5
ALLOWANCE = 32 * 1024 * 1024
START = (1 << 54) + 53
# Independently reproducible from generate_fixtures.levels(400, 160), pinned in
# the validator tests. Accepting any consistent hash would miss recipe drift.
PROFILE_SHA256 = "d447f9cda8e5691284626521e42fa9748ce5c303b034a4f3353652706e28875c"
FIELDS = {"schemaVersion", "status", "syntheticOnly", "dspOrCaptureExecuted", "phase", "frames",
          "sourceDurationSeconds", "seconds", "peakResidentBytes", "archiveBytes", "framedRecords",
          "measurementRecords", "catalogEntries", "encodedCatalogBytes", "maximumRecordPayloadBytes",
          "maximumIOChunkBytes", "embeddedMediaBytes", "available", "unavailable", "lastTimestamp", "profileSHA256"}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False).encode()


def audit_archive(path, count):
    """Independent, bounded framing/digest/seal audit, outside native timing/RSS."""
    with path.open("rb") as stream:
        magic = stream.read(16)
        require(magic == bytes.fromhex("4844584c564f49434500010000000000"), "Wrong wire version")
        aggregate = hashlib.sha256(magic)
        offset, ordinal, kinds, maximum = 16, 0, Counter(), 0
        while True:
            header = stream.read(48)
            require(len(header) == 48, "Truncated record header")
            kind, size, index = struct.unpack("<B3xIQ", header[:16])
            require(header[1:4] == b"\0\0\0" and index == ordinal and 0 < size <= 4096, "Invalid record bounds/order")
            payload = stream.read(size)
            require(len(payload) == size, "Truncated record")
            require(hashlib.sha256(header[:16] + payload).digest() == header[16:], "Record hash mismatch")
            maximum = max(maximum, size)
            kinds[kind] += 1
            if kind == 255:
                footer = json.loads(payload)
                require(footer["precedingByteCount"] == offset and footer["precedingRecordCount"] == ordinal
                        and footer["precedingSHA256"]["sha256"] == aggregate.hexdigest(), "Prefix seal mismatch")
                require(footer["measurementCount"] == count and footer["gapCount"] == 0
                        and footer["catalogEntryCount"] == 4 and footer["mediaReferenceCount"] == 0
                        and footer["embeddedMediaBytes"] == 0 and footer["completion"] == "completed", "Wrong seal counts")
                require(kinds == Counter({1: 1, 2: 1, 3: 1, 4: 1, 5: count, 255: 1})
                        and stream.read(1) == b"", "Unexpected records/trailing bytes")
                aggregate.update(header + payload)
                return {"sha256": aggregate.hexdigest(), "bytes": offset + 48 + size,
                        "maximumRecordPayloadBytes": maximum}
            aggregate.update(header + payload)
            offset += 48 + size
            ordinal += 1


def validate_report(report, phase, count, audit):
    require(set(report) == FIELDS, "Missing or unexpected report fields")
    require(type(report["schemaVersion"]) is int and report["schemaVersion"] == 1
            and report["status"] == "passed" and report["syntheticOnly"] is True
            and report["dspOrCaptureExecuted"] is False and report["phase"] == phase, "Wrong evidence scope")
    expected = {"frames": count, "measurementRecords": count, "framedRecords": count + 5,
                "catalogEntries": 4, "embeddedMediaBytes": 0, "unavailable": (count + 256) // 257,
                "available": count - (count + 256) // 257, "lastTimestamp": START + (count - 1) * 160 + 200,
                "archiveBytes": audit["bytes"], "maximumRecordPayloadBytes": audit["maximumRecordPayloadBytes"]}
    for key, value in expected.items():
        require(type(report[key]) is int and report[key] == value, "Incorrect native counts/bounds")
    require(type(report["sourceDurationSeconds"]) in (int, float)
            and report["sourceDurationSeconds"] == count / 100, "Wrong synthetic duration")
    for key, maximum in [("encodedCatalogBytes", 65_536), ("maximumIOChunkBytes", 4096),
                         ("peakResidentBytes", 1024 * 1024 * 1024)]:
        require(type(report[key]) is int and 0 < report[key] <= maximum, "Invalid memory/buffer evidence")
    require(type(report["seconds"]) in (int, float) and math.isfinite(report["seconds"])
            and report["seconds"] > 0, "Invalid duration")
    require(report["profileSHA256"] == PROFILE_SHA256, "Wrong independently pinned profile")


def validate_population(records):
    required = {(count, phase, trial) for count in COUNTS for phase in ("write", "read") for trial in range(TRIALS)}
    keys = [(r["report"]["frames"], r["report"]["phase"], r["trial"]) for r in records]
    require(set(keys) == required and len(keys) == len(required), "Missing/duplicate fresh process")
    for record in records:
        report = record["report"]
        validate_report(report, report["phase"], report["frames"], record["archiveAudit"])
    for count in COUNTS:
        group = [r for r in records if r["report"]["frames"] == count]
        require(len({r["archiveAudit"]["sha256"] for r in group}) == 1, "Nondeterministic archive bytes")
    require(len({r["report"]["profileSHA256"] for r in records}) == 1, "Profile drift")
    require(len({r["report"]["encodedCatalogBytes"] for r in records}) == 1, "Catalog grew with timeline")
    distributions = {}
    for phase in ("write", "read"):
        groups = {}
        for count in COUNTS:
            group = [r["report"] for r in records if r["report"]["phase"] == phase and r["report"]["frames"] == count]
            groups[str(count)] = {key: {"minimum": min(values), "median": statistics.median(values), "maximum": max(values)}
                for key in ("seconds", "peakResidentBytes") for values in [[x[key] for x in group]]}
        require(groups[str(COUNTS[1])]["peakResidentBytes"]["median"]
                <= groups[str(COUNTS[0])]["peakResidentBytes"]["median"] + ALLOWANCE,
                "Long-session median RSS grew beyond the 32 MiB smoke allowance")
        distributions[phase] = groups
    return distributions


def negative_controls(records):
    results = []
    for name, change in [
        ("missing-process", lambda x: x.pop()),
        ("duplicate-process", lambda x: x.append(copy.deepcopy(x[0]))),
        ("zero-timing", lambda x: x[0]["report"].update(seconds=0)),
        ("nan-timing", lambda x: x[0]["report"].update(seconds=float("nan"))),
        ("wrong-count", lambda x: x[0]["report"].update(measurementRecords=0)),
        ("oversize-record", lambda x: x[0]["report"].update(maximumRecordPayloadBytes=4097)),
        ("private-field", lambda x: x[0]["report"].update(privateNote="must-not-be-published")),
        ("dsp-in-timing", lambda x: x[0]["report"].update(dspOrCaptureExecuted=True)),
        ("profile-drift", lambda x: x[0]["report"].update(profileSHA256="0" * 64)),
        ("rss-growth", lambda x: [r["report"].update(peakResidentBytes=900 * 1024 * 1024)
                                  for r in x if r["report"]["frames"] == COUNTS[1]]),
    ]:
        changed = copy.deepcopy(records)
        change(changed)
        try:
            validate_population(changed)
        except ValueError:
            results.append(name)
        else:
            raise ValueError("Negative evidence control accepted: " + name)
    return results


def run(output):
    output.mkdir(parents=True, exist_ok=False)
    environment = ci.environment("release")
    ci.validate_environment(environment, json.loads((ROOT / "Configuration/build.json").read_bytes()))
    environment.update(hardwareModel=ci.capture("sysctl", "-n", "hw.model"),
        scope="Synthetic scalar serialization/storage with record construction and integrity/meaning checks; no DSP or capture.",
        memory="Darwin process high-water RSS in fresh processes, including runtime/allocator overhead; separate from owned byte bounds.",
        filesystem="Regular local file writes include fsync/publication; reads follow writes and may use the OS page cache.")
    (output / "environment.json").write_bytes(canonical(environment))
    commands = []
    package = ROOT / "Examples/SessionWorkflow"
    sources = sorted((ROOT / "Sources").rglob("*.swift")) + [p for p in package.rglob("*.swift") if ".build" not in p.parts]
    sources += [Path(__file__), ROOT / "Package.swift", ROOT / "Configuration/build.json", ROOT / "Tools/ci.py",
                ROOT / "Tools/Sessions/generate_fixtures.py", ROOT / "Tools/Tests/test_session_benchmark.py",
                ROOT / ".github/workflows/session-interchange.yml"]
    def source_hashes():
        return {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
    before = source_hashes()
    with (output / "commands.log").open("w") as log:
        ci.run_command(["swift", "build", "--package-path", str(package), "-c", "release"], log, commands)
    binary = Path(ci.capture("swift", "build", "--package-path", str(package), "-c", "release", "--show-bin-path")) / "SessionWorkflow"
    records = []
    for count in COUNTS:
        for trial in range(TRIALS):
            archive = output / f"synthetic-{count}-{trial}.hvps"
            reports = {}
            try:
                for phase in ("write", "read"):
                    report_path = output / f"{phase}-{count}-{trial}.json"
                    command = [str(binary), "--serialization-" + phase, "--frames", str(count),
                               "--archive", str(archive), "--output", str(report_path)]
                    process = subprocess.run(command, cwd=ROOT, text=True, stdout=subprocess.PIPE,
                                             stderr=subprocess.STDOUT, timeout=300, check=False)
                    with (output / "commands.log").open("a") as log:
                        log.write(ci.redact(process.stdout))
                    require(process.returncode == 0, "Native serialization process failed")
                    reports[phase] = json.loads(report_path.read_bytes())
                audit = audit_archive(archive, count)
                for phase, report in reports.items():
                    validate_report(report, phase, count, audit)
                    records.append({"trial": trial, "report": report, "archiveAudit": audit})
            finally:
                archive.unlink(missing_ok=True)
            print(f"Verified {count} synthetic records, trial {trial + 1}/{TRIALS}", flush=True)
    distributions = validate_population(records)
    controls = negative_controls(records)
    require(source_hashes() == before, "Sources changed during the evidence run")
    result = {"schemaVersion": 1, "status": "passed", "commands": commands, "records": records,
              "distributions": distributions, "negativeValidationControls": controls,
              "residentGrowthAllowanceBytes": ALLOWANCE, "physicalEvidence": False,
              "sourceSHA256": before}
    (output / "result.json").write_bytes(canonical(result))
    print("Verified 20 fresh processes and 10 evidence controls; synthetic archives removed.", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    run(parser.parse_args().output.resolve())
