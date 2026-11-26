#!/usr/bin/env python3
"""Run the same PCM conformance program on the host and a disposable iOS Simulator."""
import argparse
from contextlib import ExitStack
from hashlib import sha256
import json
from pathlib import Path
import platform
import subprocess
import struct
import sys
from tempfile import TemporaryDirectory

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from Equivalence.inputs import ROOT, prepare, read
from Equivalence.compare import check_compositions, composition_signature, precision, quantization, require, validate
import ci
from Capture.ios_host import ensure_runtime
sys.path.append(str(ROOT / "Tools/Performance"))
from Performance.verify_portable import simulator

GROUPS = ("synthetic", "corpus", "edges", "duration")
# Check disabled work and independent transforms on speech and at the shortest
# reporting boundary. The full composition exercises every metric on every case.
COMPOSITION_CONTROLS = {"short-120ms", "corpus-bl01-vowel-a", "missing-intervals"}


def save(path, value):
    stage = path.with_suffix(".part")
    stage.write_text(json.dumps(value, separators=(",", ":"), allow_nan=False, sort_keys=True) + "\n")
    stage.replace(path)


def build(target, scratch):
    args = ["swift", "build", "--package-path", str(ROOT / "Benchmarks/Portable"),
            "--scratch-path", str((scratch / target).resolve()), "-c", "release", "--product", "AlgorithmConformance",
            "-Xswiftc", "-warnings-as-errors"]
    if target == "ios":
        args += ["--triple", f"{platform.machine()}-apple-ios27.0-simulator",
                 "--sdk", ci.capture("xcrun", "--sdk", "iphonesimulator", "--show-sdk-path")]
    subprocess.run(args, cwd=ROOT, check=True)
    binary_dir = subprocess.check_output([*args, "--show-bin-path"], cwd=ROOT, text=True).strip()
    return Path(binary_dir) / "AlgorithmConformance"


def exercise(prefix, inputs, item, composition, temporary, target):
    path = temporary / (target + ".json")
    path.unlink(missing_ok=True)
    subprocess.run([*prefix, inputs, item["name"], composition, path], check=True, cwd=ROOT)
    result = read(path)
    path.unlink()
    validate(result, item, composition, "macOS" if target == "mac" else "iOS Simulator", platform.machine())
    return result


def compare_case(targets, inputs, items, composition, temporary):
    host = {}
    platforms = {}
    for item in items:
        label = item["representation"]
        mac = exercise(targets["mac"], inputs, item, composition, temporary, "mac")
        host[label] = mac
        platforms["macOS"] = mac["execution"]
        if "ios" in targets:
            mobile = exercise(targets["ios"], inputs, item, composition, temporary, "ios")
            require(mac["recipe"] == mobile["recipe"] and mac["reference"] == mobile["reference"],
                    f"Platform mismatch for {item['name']} / {composition}")
            platforms["iOS Simulator"] = mobile["execution"]
            del mobile
    common = host.get("widened", host["float64"])
    # The proof that the samples are identical is independent of the producer's
    # precision label. Recompute the little-endian Float64 stream from Float32.
    narrow_bytes = (inputs / (host["float32"]["fixture"]["pcmSHA256"] + ".pcm")).read_bytes()
    expanded = b"".join(struct.pack("<d", x) for (x,) in struct.iter_unpack("<f", narrow_bytes))
    require(sha256(expanded).hexdigest() == common["fixture"]["pcmSHA256"], "Different samples in precision pair")
    result = dict(platforms=platforms, composition=composition, partitions=host["float64"]["partitions"],
                  sourceSHA256=items[0]["sourceSHA256"], cases={v["representation"]: dict(
                      pcmSHA256=v["pcmSHA256"], precision=v["precision"], profile=host[v["representation"]]["recipe"]["scheduleIdentity"],
                      recipe=host[v["representation"]]["recipe"],
                      completions=host[v["representation"]]["reference"]["conformance"]["completions"],
                      cycleAmplitudes=len(host[v["representation"]]["reference"]["conformance"]["cycleAmplitudes"]),
                      epochs=host[v["representation"]]["reference"]["epochs"],
                      analyzedSamples=host[v["representation"]]["reference"]["analyzedSamples"]) for v in items},
                  commonPCM=precision(host["float32"], common))
    if "widened" in host:
        result["sourceQuantization"] = quantization(host["float64"], common)
    if items[0]["pair"] == "yin-silence-boundary":
        native = host["float64"]["reference"]["conformance"]
        rounded = common["reference"]["conformance"]
        key = "yin.trackedFundamentalFrequency"
        require(native["values"]["yin"][0].get("reason") == "silence" and rounded["values"]["yin"][0]["status"] == "voiced"
                and native["support"][key][1]["windowStart"] == rounded["support"][key][1]["windowStart"]
                and native["support"][key][1]["dependencyCount"] < rounded["support"][key][1]["dependencyCount"],
                "The silence-boundary fixture did not exercise a rounding-dependent change in tracker memory")
    if items[0]["pair"] in COMPOSITION_CONTROLS:
        result["compositionSignatures"] = {key: composition_signature(run["reference"]) for key, run in host.items()}
    return result


def continuity_targets(targets, inputs, temporary):
    results = {}
    for precision_name in ("float32", "float64"):
        pair = {}
        for target, prefix in targets.items():
            path = temporary / "continuity.json"
            path.unlink(missing_ok=True)
            subprocess.run([*prefix, "continuity", inputs, "harmonic-low." + precision_name,
                            "corpus-bl01-vowel-a." + precision_name, path], check=True)
            evidence = read(path)
            r = evidence["result"]
            require(evidence["execution"]["platform"] == ("macOS" if target == "mac" else "iOS Simulator")
                    and r["observedSamples"] == 960000 and r["observedFrames"] > 0 and r["gaps"] == [1, 1600]
                    and r["routeSampleRate"] == 44100 and r["routeSchedule"] != r["schedule"]
                    and r["rejectedInputs"] == ["nan", "infinity", "unannounced-gap", "unannounced-sample-rate", "unannounced-epoch"]
                    and len(r["heapSamples"]) == 6 and r["preparedBufferBytes"] > 0, "Incomplete continuity evidence")
            pair[target] = evidence
        if "ios" in targets:
            for key in ("schedule", "routeSchedule", "observedFrames", "observedSamples"):
                require(pair["mac"]["result"][key] == pair["ios"]["result"][key],
                        f"Platform continuity mismatch: {key}")
        results[precision_name] = pair
    return results


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--group", choices=GROUPS)
    parser.add_argument("--host-only", action="store_true")
    parser.add_argument("--install-runtime", action="store_true")
    parser.add_argument("--development-toolchain", action="store_true")
    parser.add_argument("--scratch", type=Path, default=ROOT / ".build/algorithm-equivalence")
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    group = args.group or "all"
    environment = ci.environment("algorithm-equivalence")
    environment.update(configuration="release", execution="macOS host" if args.host_only else "macOS and iOS Simulator",
                       destination=platform.machine(), hardwareModel=ci.capture("sysctl", "-n", "hw.model"))
    result = dict(schemaVersion=1, group=group, status="running", environment=environment, completed=[])
    try:
        if not args.development_toolchain:
            ci.validate_environment(environment, read(ROOT / "Configuration/build.json"))
            require(not environment["workingTreeDirty"] and environment["architecture"] == "arm64",
                    "Qualified runs require a clean revision on the supported arm64 host")
        mac = build("mac", args.scratch.resolve())
        targets = {"mac": [mac]}
        result["binarySHA256"] = {"mac": sha256(mac.read_bytes()).hexdigest()}
        with TemporaryDirectory() as temporary, ExitStack() as resources:
            temp = Path(temporary)
            inputs = temp / "inputs"
            manifest = prepare(inputs)
            manifest_bytes = (inputs / "manifest.json").read_bytes()
            (output / "inputs.json").write_bytes(manifest_bytes)
            result["manifestSHA256"] = sha256(manifest_bytes).hexdigest()
            if not args.host_only:
                with (output / "runtime.log").open("w") as log:
                    runtime = ensure_runtime(args.install_runtime, log, [])
                ios = build("ios", args.scratch.resolve())
                device = resources.enter_context(simulator())
                targets["ios"] = ["xcrun", "simctl", "spawn", device, ios]
                result["simulator"] = {key: runtime[key] for key in ("identifier", "version", "buildversion")}
                devices = json.loads(ci.capture("xcrun", "simctl", "list", "devices", "--json"))["devices"]
                result["simulator"]["deviceType"] = next(d["deviceTypeIdentifier"] for d in devices[runtime["identifier"]]
                                                          if d["udid"] == device and d["state"] == "Booted")
                result["binarySHA256"]["ios"] = sha256(ios.read_bytes()).hexdigest()
            pairs = {}
            for item in manifest["cases"]:
                if not args.group or item["group"] == args.group:
                    pairs.setdefault(item["pair"], []).append(item)
            require(pairs, "Empty fixture group")
            result["expectedPairs"] = list(pairs)
            result["unavailableInputs"] = [r for r in manifest["unavailable"] if not args.group or r["group"] == args.group]
            for name, items in pairs.items():
                result["activeCase"] = name
                save(output / "result.json", result)
                profiles = ("cpps", "core", "full", "separateSpectra") if name in COMPOSITION_CONTROLS else ("full",)
                signatures = {}
                for profile in profiles:
                    report = compare_case(targets, inputs, items, profile, temp)
                    for label, signature in report.get("compositionSignatures", {}).items():
                        signatures.setdefault(label, {})[profile] = signature
                    path = output / f"{name}.{profile}.json"
                    save(path, report)
                    result["completed"].append(dict(pair=name, composition=profile, file=path.name,
                                                    sha256=sha256(path.read_bytes()).hexdigest()))
                for typed_profiles in signatures.values():
                    check_compositions(typed_profiles)
                print(f"{name}: {len(profiles)} composition(s) passed", flush=True)
                save(output / "result.json", result)
            if args.group in (None, "edges"):
                result["continuity"] = continuity_targets(targets, inputs, temp)
        result.pop("activeCase", None)
        result["status"] = "passed"
    except (OSError, KeyError, TypeError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
        result["status"] = "failed"
        result["error"] = ci.redact(str(error))
        print(result["error"], file=sys.stderr)
    finally:
        save(output / "result.json", result)
    return 0 if result["status"] == "passed" else 1


if __name__ == "__main__":
    sys.exit(main())
