#!/usr/bin/env python3
"""Verify optimized Swift sanitizer detection in bounded, isolated fault processes."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import platform
import selectors
import signal
import subprocess
import sys
import tempfile
import time

import ci

ROOT = Path(__file__).resolve().parent.parent
CONTROLS = {
    "address": ("AddressFailure.swift", ("ERROR: AddressSanitizer: heap-use-after-free",), 86),
    "thread": ("ThreadFailure.swift", ("WARNING: ThreadSanitizer: data race",
                                       "WARNING: ThreadSanitizer: Swift access race"), 87),
}
OVERRIDES = ("ASAN_OPTIONS", "TSAN_OPTIONS", "LSAN_OPTIONS",
             "DYLD_INSERT_LIBRARIES", "LD_PRELOAD")
MAX_LOG_BYTES = 1_048_576


def validate_result(mode, code, output):
    _, expected, expected_code = CONTROLS[mode]
    diagnostic = next((marker for marker in expected if marker in output), None)
    if code != expected_code or diagnostic is None or "Unexpected success:" in output:
        raise ValueError(f"{mode} capability unavailable: expected {expected!r} and exit {expected_code}, got exit {code}")
    return {"available": True, "diagnostic": diagnostic, "exitCode": code}


def capture(command, timeout, environment=None):
    # Compiler children and probe threads cannot outlive a timed-out probe.
    with subprocess.Popen(command, cwd=ROOT, env=environment, stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT, start_new_session=True) as process:
        deadline = time.monotonic() + timeout
        output = bytearray()
        try:
            with selectors.DefaultSelector() as selector:
                selector.register(process.stdout, selectors.EVENT_READ)
                while selector.get_map():
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        raise subprocess.TimeoutExpired(command, timeout)
                    for key, _ in selector.select(remaining):
                        chunk = os.read(key.fd, min(65_536, MAX_LOG_BYTES - len(output) + 1))
                        if not chunk:
                            selector.unregister(key.fileobj)
                            continue
                        output.extend(chunk)
                        if len(output) > MAX_LOG_BYTES:
                            raise ValueError("Capability subprocess exceeded its log budget")
            code = process.wait(timeout=max(0, deadline - time.monotonic()))
            return code, output.decode(errors="replace")
        except BaseException as error:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
            if isinstance(error, subprocess.TimeoutExpired):
                raise ValueError(f"Capability subprocess exceeded {timeout} seconds") from error
            raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=CONTROLS)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    report = {"schemaVersion": 1, "mode": args.mode, "configuration": "release",
              "recordedAtUTC": datetime.datetime.now(datetime.UTC).isoformat(),
              "status": "failed", "commands": []}
    log = []
    try:
        if any(key in os.environ for key in OVERRIDES):
            raise ValueError("Remove sanitizer or injected-runtime environment overrides")
        environment = ci.environment(args.mode)
        ci.validate_environment(environment, json.loads((ROOT / "Configuration/build.json").read_text()))
        report["environment"] = environment
        filename, _, expected_code = CONTROLS[args.mode]
        source = ROOT / "Tools/SanitizerProbe" / filename
        report["sourceSHA256"] = hashlib.sha256(source.read_bytes()).hexdigest()
        build = ROOT / ".build"
        build.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix=f"sanitizer-{args.mode}-", dir=build) as temporary:
            binary = Path(temporary) / "FaultControl"
            target = f"{platform.machine()}-apple-macos27.0"
            command = ["xcrun", "swiftc", "-swift-version", "6", "-O", "-g",
                       "-target", target, "-sanitize=" + args.mode, str(source), "-o", str(binary)]
            report["commands"].append(command)
            code, output = capture(command, 180)
            log.append(output)
            if code != 0:
                raise ValueError(f"Optimized sanitizer control failed to compile: exit {code}")
            report["binarySHA256"] = hashlib.sha256(binary.read_bytes()).hexdigest()
            runtime = os.environ.copy()
            options = f"halt_on_error=1:abort_on_error=0:symbolize=0:exitcode={expected_code}"
            if args.mode == "address":
                options += ":detect_leaks=0"
            runtime["ASAN_OPTIONS" if args.mode == "address" else "TSAN_OPTIONS"] = options
            report["probeRuntimeOptions"] = options
            report["commands"].append([str(binary)])
            code, output = capture([str(binary)], 30, runtime)
            log.append(output)
            report["capability"] = validate_result(args.mode, code, output)
        report["status"] = "passed"
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        report["error"] = str(error)
        log.append(str(error))
    finally:
        (args.output / "sanitizer-capability.log").write_text(ci.redact("\n".join(log)) + "\n")
        (args.output / "sanitizer-capability.json").write_text(ci.redact(json.dumps(report, indent=2)) + "\n")
    print(json.dumps({k: report[k] for k in ("mode", "configuration", "status")}))
    return 0 if report["status"] == "passed" else 1


if __name__ == "__main__":
    sys.exit(main())
