#!/usr/bin/env python3
"""Record synthetic Instruments evidence; raw traces stay local, summaries are shareable."""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET

import ci
import instrumentation

SUBSYSTEM = "org.hdxl.voice-processing"
METADATA = re.compile(r"session=(\d+) epoch=(\d+) span=(\d+) profile=(\d+) frame=(\d+) "
                      r"samples=(\d+) depth=(\d+) validity=(\d+) processed=(\d+) queue_ns=(\d+)")


def validate_trace(xml):
    root = ET.fromstring(xml)
    ids = {node.attrib["id"]: node for node in root.iter() if "id" in node.attrib}
    def resolve(node):
        return ids[node.attrib["ref"]] if "ref" in node.attrib else node
    def value(node):
        node = resolve(node)
        return node.attrib.get("fmt", node.text or "")
    def metadata(node):
        node = resolve(node)
        if not len(node):
            return value(node)
        # Instruments fmt strings apply locale grouping to large integers. Use
        # typed raw arguments, never localized presentation text, for validation.
        parts = []
        for child in node:
            child = resolve(child)
            if child.tag == "narrative-text":
                parts.append(child.text or "")
            elif child.tag == "uint64" and (child.text or "").isascii() and (child.text or "").isdigit():
                number = int(child.text)
                if number > (1 << 64) - 1:
                    raise ValueError("Out-of-range diagnostic argument")
                parts.append(str(number))
            else:
                raise ValueError("Unapproved diagnostic argument type")
        return "".join(parts)
    records = []
    for table in root.findall("node"):
        schema = table.find("schema")
        if schema is None or schema.attrib.get("name") != "os-signpost":
            continue
        columns = [col.findtext("mnemonic") for col in schema.findall("col")]
        for row in table.findall("row"):
            if len(row) != len(columns):
                raise ValueError("Signpost schema column mismatch")
            fields = dict(zip(columns, row))
            if value(fields["subsystem"]) == SUBSYSTEM:
                records.append({key: value(node) for key, node in fields.items()} |
                               {"time": int(resolve(fields["time"]).text), "message": metadata(fields["message"])})
    active = {}
    seen = set()
    sessions = set()
    epochs = set()
    events = Counter()
    spans = Counter()
    frames = Counter()
    overlap = False
    for record in sorted(records, key=lambda r: r["time"]):
        key = (record["category"], record["name"], record["identifier"])
        kind = record["event-type"]
        if kind == "End":
            if record["message"]:
                raise ValueError("Interval ends must not contain metadata")
            begin = active.pop(key, None)
            if begin is None or begin["time"] > record["time"]:
                raise ValueError("Unmatched/reversed interval end")
            continue
        match = METADATA.fullmatch(record["message"])
        if not match:
            raise ValueError("Diagnostic payload contains unapproved/missing metadata")
        session, epoch, span, profile, frame, samples, depth, validity, processed, queue_ns = map(int, match.groups())
        identity = (session, span)
        if identity in seen:
            raise ValueError("Duplicate session/span identity")
        seen.add(identity)
        sessions.add(session)
        epochs.add(epoch)
        record["session"] = session
        if kind == "Begin":
            if key in active or record["name"] not in {"AnalysisFrame", "FFT"} or record["category"] != "worker":
                raise ValueError("Unexpected/duplicate interval")
            if record["name"] == "AnalysisFrame":
                frames[session] += 1
                overlap |= any(r["name"] == "AnalysisFrame" and r["session"] != session for r in active.values())
            active[key] = record
            spans[record["name"]] += 1
        elif kind == "Event":
            events[record["name"]] += 1
            expected_failure = {"Error": (5, 6), "Cancelled": (7, 5), "Overrun": (9, 3)}
            if record["name"] in expected_failure and (frame, validity) != expected_failure[record["name"]]:
                raise ValueError("Failure event lost its frame/validity context")
        else:
            raise ValueError("Unexpected signpost kind")
    expected_events = {"Initialize": 2, "CaptureHandoff": 64, "Reset": 2, "Error": 2,
                       "Cancelled": 2, "Overrun": 2, "RouteChange": 2, "ConfigurationChange": 2}
    if (active or len(sessions) != 2 or 0 in sessions or epochs != {0, 1} or not overlap or
        dict(spans) != {"AnalysisFrame": 64, "FFT": 64} or dict(events) != expected_events or
        sorted(frames.values()) != [32, 32]):
        raise ValueError("Incomplete trace, missing overlap, event loss, or unbalanced intervals")
    return {"pairedIntervals": sum(spans.values()), "intervalsByName": dict(spans),
            "eventsByName": dict(events), "sessions": 2, "overlappingSessions": True,
            "epochs": [0, 1], "unmatchedIntervals": 0, "approvedNumericMetadataOnly": True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--overhead", action="store_true", help="Measure the same probe while Instruments records")
    args = parser.parse_args()
    output = ci.ROOT / ".build" / "instrumentation-artifacts" / ("traced-overhead" if args.overhead else "pairing")
    if output.exists():
        shutil.rmtree(output)
    private = output / "private"
    private.mkdir(parents=True)
    result = {"status": "failed", "commands": []}
    try:
        environment = ci.environment("release")
        ci.validate_environment(environment, json.loads((ci.ROOT / "Configuration/build.json").read_text()))
        environment.update(purpose="synthetic Instruments verification", template="Logging",
                           physicalEvidence="host synthetic only; device evidence deferred to #74")
        (output / "environment.json").write_text(ci.redact(json.dumps(environment, indent=2)) + "\n")
        flags = ["--scratch-path", ".build/instrumentation-system", "-c", "release"]
        with (output / "commands.log").open("w") as log:
            def run(command):
                ci.run_command(command, log, result["commands"])
            run(["swift", "build", *flags, "--product", "InstrumentationProbe"])
            binary = Path(ci.capture("swift", "build", *flags, "--show-bin-path")) / "InstrumentationProbe"
            trace = private / "synthetic.trace"
            stdout = private / "probe.json"
            run(["xcrun", "xctrace", "record", "--template", "Logging", "--output", str(trace),
                 "--time-limit", "1m", "--target-stdout", str(stdout), "--launch", "--", str(binary)] +
                ([] if args.overhead else ["--trace"]))
            if args.overhead:
                rows = json.loads(stdout.read_text())
                result.update(instrumentation.summarize(rows))
                (output / "trials.json").write_text(json.dumps(rows, indent=2) + "\n")
            else:
                if json.loads(stdout.read_text()) != {"traceCompleted": True, "sessions": 2, "framesPerSession": 32}:
                    raise ValueError("Synthetic worker did not complete")
                xml = private / "signposts.xml"
                run(["xcrun", "xctrace", "export", "--input", str(trace), "--xpath",
                     '/trace-toc/run[@number="1"]/data/table[@schema="os-signpost"]', "--output", str(xml)])
                result.update(validate_trace(xml.read_bytes()))
                result["privateExportSHA256"] = hashlib.sha256(xml.read_bytes()).hexdigest()
        result["status"] = "passed"
    except (ValueError, KeyError, OSError, RuntimeError, ET.ParseError, subprocess.SubprocessError) as error:
        result["error"] = ci.redact(str(error))
    (output / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))
    return 0 if result["status"] == "passed" else 1


if __name__ == "__main__":
    sys.exit(main())
