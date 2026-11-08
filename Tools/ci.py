#!/usr/bin/env python3
"""Run reproducible correctness lanes and write a bounded, public-safe evidence bundle."""
import argparse
import datetime
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
LANES = ("debug", "release", "address", "thread", "ios-simulator", "ios-device", "extended")


def redact(text):
    # No environment dump or audio/attachment collection. Remove local account paths
    # from compiler diagnostics while preserving relative source locations.
    return text.replace(str(ROOT), "<checkout>").replace(str(Path.home()), "<home>")


def capture(*command):
    return subprocess.check_output(command, cwd=ROOT, text=True, stderr=subprocess.STDOUT).strip()


def build_configuration(lane):
    return "release" if lane in ("release", "extended", "address", "thread") else "debug"


def environment(lane):
    return {
        "schemaVersion": 1,
        "lane": lane,
        "recordedAtUTC": datetime.datetime.now(datetime.UTC).isoformat(),
        "commit": capture("git", "rev-parse", "HEAD"),
        "workingTreeDirty": bool(capture("git", "status", "--porcelain")),
        "hostOS": capture("sw_vers", "-productVersion"),
        "hostOSBuild": capture("sw_vers", "-buildVersion"),
        "architecture": platform.machine(),
        "xcode": capture("xcodebuild", "-version"),
        "swift": capture("swift", "--version"),
        "python": platform.python_version(),
        "sdks": {sdk: capture("xcrun", "--sdk", sdk, "--show-sdk-version")
                 for sdk in ("macosx", "iphoneos", "iphonesimulator")},
        "runnerImage": {key: os.environ.get(key) for key in ("ImageOS", "ImageVersion")},
        "configuration": build_configuration(lane),
        "sanitizer": lane if lane in ("address", "thread") else None,
        "destination": {"ios-simulator": "generic/platform=iOS Simulator",
                        "ios-device": "generic/platform=iOS"}.get(lane, "host macOS"),
        "execution": "compile-only" if lane.startswith("ios-") else "host tests",
        "physicalEvidence": "not collected; deferred to issue #74",
    }


def validate_environment(actual, expected):
    errors = []
    expected_xcode = f"Xcode {expected['xcodeVersion']}\nBuild version {expected['xcodeBuild']}"
    if actual["xcode"] != expected_xcode:
        errors.append(f"Xcode must be {expected_xcode!r}; select DEVELOPER_DIR")
    if f"swiftlang-{expected['swiftCompilerVersion']}" not in actual["swift"]:
        errors.append("Swift compiler build differs from Configuration/build.json")
    if tuple(map(int, actual["hostOS"].split("."))) < (27, 0):
        errors.append("Host tests require macOS 27 or later")
    for sdk, key in (("macosx", "macOS"), ("iphoneos", "iOS"), ("iphonesimulator", "iOSSimulator")):
        if actual["sdks"].get(sdk) != expected["sdkVersions"][key]:
            errors.append(f"{sdk} SDK differs from the declared version")
    if actual["python"] != expected["pythonVersion"]:
        errors.append(f"Python must be {expected['pythonVersion']}")
    if errors:
        raise RuntimeError("; ".join(errors))


def commands(lane, output):
    if lane.startswith("ios-"):
        return [["bash", "Tools/build-ios.sh", lane.removeprefix("ios-")]]
    configuration = build_configuration(lane)
    test = ["swift", "test", "--configuration", configuration,
            "--xunit-output", str(output / "tests.xml")]
    if lane != "debug":
        test += ["--scratch-path", f".build/ci-{lane}"]
    if lane in ("address", "thread"):
        test += ["--sanitize", lane]
    if lane == "extended":
        test += ["--maximum-repetitions", "10", "--repeat-until", "fail"]
    if lane in ("address", "thread"):
        return [[sys.executable, "Tools/sanitizer-capability.py", lane, "--output", str(output)], test]
    if lane != "debug":
        return [test]
    return [
        ["bash", "Tools/format.sh", "--check"],
        [sys.executable, "Tools/verify-provenance.py"],
        [sys.executable, "Tools/Reference/verify.py"],
        [sys.executable, "Tools/Synthetic/verify.py"],
        [sys.executable, "Tools/Corpus/corpus.py", "verify"],
        [sys.executable, "-m", "unittest", "discover", "-s", "Tools/Tests", "-p", "test_*.py"],
        ["swift", "build"],
        test,
        ["swift", "run", "--package-path", "Examples/CoreConsumer", "CoreConsumer"],
        ["swift", "run", "--package-path", "Examples/AudioConsumer", "AudioConsumer"],
        [sys.executable, "Tools/verify-package-graph.py"],
        ["bash", "Tools/verify-offline.sh"],
    ]


def run_command(command, log, records):
    started = time.monotonic()
    print("+ " + redact(" ".join(command)), flush=True)
    with subprocess.Popen(command, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                          text=True, errors="replace", bufsize=1) as process:
        for line in process.stdout:
            safe = redact(line)
            print(safe, end="", flush=True)
            log.write(safe)
            log.flush()
        code = process.wait()
    records.append({"command": [redact(arg) for arg in command], "exitCode": code,
                    "durationSeconds": round(time.monotonic() - started, 3)})
    if code:
        raise RuntimeError(f"Command exited {code}: {redact(' '.join(command))}")


def test_reports(output):
    reports = []
    for path in sorted(output.glob("*.xml")):
        root = ET.parse(path).getroot()
        reports.append({"file": path.name, "testCases": len(root.findall(".//testcase")),
                        "failures": len(root.findall(".//failure")),
                        "errors": len(root.findall(".//error"))})
    if not sum(report["testCases"] for report in reports):
        raise RuntimeError("Test command produced no nonempty xUnit report")
    if any(report["failures"] or report["errors"] for report in reports):
        raise RuntimeError("xUnit report contains failures or errors")
    return reports


def redact_report(path):
    # Redact values, not serialized markup: <checkout> must be escaped in XML.
    tree = ET.parse(path)
    for element in tree.iter():
        for key, value in element.attrib.items():
            element.set(key, redact(value))
        if element.text:
            element.text = redact(element.text)
        if element.tail:
            element.tail = redact(element.tail)
    tree.write(path, encoding="utf-8", xml_declaration=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("lane", choices=LANES)
    args = parser.parse_args()
    output = ROOT / ".build" / "ci-artifacts" / args.lane
    # Avoid uploading stale successes or failure reports from a previous local run.
    if output.exists():
        shutil.rmtree(output)
    output.mkdir(parents=True)
    result = {"schemaVersion": 1, "lane": args.lane, "status": "failed", "commands": []}
    started = time.monotonic()
    try:
        actual = environment(args.lane)
        (output / "environment.json").write_text(redact(json.dumps(actual, indent=2)) + "\n")
        validate_environment(actual, json.loads((ROOT / "Configuration/build.json").read_text()))
        with (output / "commands.log").open("w") as log:
            for command in commands(args.lane, output):
                run_command(command, log, result["commands"])
        if not args.lane.startswith("ios-"):
            result["testReports"] = test_reports(output)
        result["status"] = "passed"
    except (OSError, subprocess.SubprocessError, RuntimeError, ValueError, ET.ParseError) as error:
        result["error"] = redact(str(error))
        print(result["error"], file=sys.stderr)
    finally:
        result["durationSeconds"] = round(time.monotonic() - started, 3)
        for report in output.glob("*.xml"):
            try:
                redact_report(report)
            except (OSError, ET.ParseError) as error:
                # A truncated/crashed report must not be published unredacted.
                report.unlink(missing_ok=True)
                result["status"] = "failed"
                result["reportError"] = redact(f"{report.name}: {error}")
        (output / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    return 0 if result["status"] == "passed" else 1


if __name__ == "__main__":
    sys.exit(main())
