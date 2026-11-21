"""Compare complete-utterance macOS and incremental iOS Simulator replay of the same manifest."""
import argparse
from contextlib import contextmanager
import json
import platform
from pathlib import Path
import subprocess
import tempfile
import uuid

from prepare import ROOT, json_bytes, prepare


def output(*args):
    return subprocess.check_output(args, text=True, cwd=ROOT).strip()


def executable(platform_name):
    scratch = ROOT / ".build" / ("b02-portable" if platform_name == "macos" else "b02-portable-simulator")
    args = ["swift", "build", "--package-path", str(ROOT / "Tools/Performance/Portable"),
            "--scratch-path", str(scratch), "-c", "release"]
    if platform_name == "simulator":
        args += ["--triple", f"{platform.machine()}-apple-ios27.0-simulator",
                 "--sdk", output("xcrun", "--sdk", "iphonesimulator", "--show-sdk-path")]
    subprocess.run(args, cwd=ROOT, check=True)
    return Path(output(*args, "--show-bin-path")) / "ReplayWorkloads"


@contextmanager
def simulator():
    simctl = ["xcrun", "simctl"]
    runtime = "com.apple.CoreSimulator.SimRuntime.iOS-27-0"
    device = output(*simctl, "create", "Workload verification " + uuid.uuid4().hex,
                    "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro", runtime)
    try:
        subprocess.run([*simctl, "bootstatus", device, "-b"], check=True)
        yield device
    finally:
        subprocess.run([*simctl, "shutdown", device], check=False, capture_output=True)
        subprocess.run([*simctl, "delete", device], check=True)


def compare(host, mobile, manifest_hash, manifest):
    expected = [{k: row[k] for k in ("id", "pcmSHA256", "profileSHA256")} | {"counts": row["expected"]}
                for row in manifest["workloads"]]
    for report, chunk in ((host, max(r["sampleCount"] for r in manifest["workloads"])), (mobile, 17)):
        if (report["workloads"] != expected or report["manifestSHA256"] != manifest_hash
                or report["maximumChunkSamples"] != chunk):
            raise ValueError("Replay result differs from the shared manifest or requested chunk schedule")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    mac, ios = executable("macos"), executable("simulator")
    with tempfile.TemporaryDirectory() as temp:
        bundle = Path(temp) / "workloads"
        digest = prepare(bundle)
        manifest = json.loads((bundle / "manifest.json").read_bytes())
        chunk = max(row["sampleCount"] for row in manifest["workloads"])
        host = json.loads(output(mac, bundle, str(chunk)))
        with simulator() as device:
            mobile = json.loads(output("xcrun", "simctl", "spawn", device, ios, bundle, "17"))
        compare(host, mobile, digest, manifest)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(json_bytes(dict(schemaVersion=1, host=host, ios27Simulator=mobile)))


if __name__ == "__main__":
    main()
