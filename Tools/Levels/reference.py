#!/usr/bin/env python3
"""Explicit, development-only K-coefficient and Decimal-filter oracle; standard library only."""

import argparse
import ast
import cmath
from decimal import Decimal, localcontext
import hashlib
import json
import math
from pathlib import Path
import struct
import sys
from types import SimpleNamespace
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
REVISION = "dc0f83883d247cbeb106064784e32d8c38ce1573"
SOURCE_SHA256 = "5e388497cb67fb13969881beb86b8d93bafaeab8f372655c034b587afcc61bc3"
LICENSE_SHA256 = "9c69b733c8db29a3f3dab2686fb7051991e76b0610eed74b1a22bfda8e451d00"
BASE_URL = f"https://raw.githubusercontent.com/BrechtDeMan/loudness.py/{REVISION}"
CACHE = ROOT / ".build/level-reference" / REVISION
GOLDEN = ROOT / "Tests/HDXLVoiceProcessingTests/Fixtures/Levels/k-weighting.json"
RATES = (16000, 22050, 24000, 32000, 44100, 48000, 88200, 96000, 176400, 192000)
SINE = (0, .3826834323650898, .7071067811865476, .9238795325112867,
        1, .9238795325112867, .7071067811865476, .3826834323650898,
        0, -.3826834323650898, -.7071067811865476, -.9238795325112867,
        -1, -.9238795325112867, -.7071067811865476, -.3826834323650898)


class ReferenceError(ValueError):
    pass


def sha(data):
    return hashlib.sha256(data).hexdigest()


def acquire():
    """Fetch only on explicit request; never silently replace an unexpected cached file."""
    CACHE.mkdir(parents=True, exist_ok=True)
    for name, digest in (("loudness.py", SOURCE_SHA256), ("LICENSE", LICENSE_SHA256)):
        path = CACHE / name
        if path.exists():
            data = path.read_bytes()
        else:
            with urllib.request.urlopen(f"{BASE_URL}/{name}", timeout=60) as response:
                data = response.read(1_000_001)
        if len(data) > 1_000_000 or sha(data) != digest:
            raise ReferenceError(f"Pinned {name} hash mismatch")
        if not path.exists():
            path.write_bytes(data)
    print(f"Verified external MIT reference {REVISION}")


def reference_coefficients(source_dir=CACHE):
    """Execute the pinned author's coefficient equations; do not import NumPy or SciPy.

    The unchanged K_filter function receives a minimal math-only np surface. Its two
    lfilter calls capture coefficients and pass the dummy signal through. Filtering
    below is our separate high-precision direct-form-I calculation, not SciPy output.
    """
    source_dir = Path(source_dir)
    data = (source_dir / "loudness.py").read_bytes()
    if sha(data) != SOURCE_SHA256 or sha((source_dir / "LICENSE").read_bytes()) != LICENSE_SHA256:
        raise ReferenceError("External reference source/license identity mismatch")
    parsed = ast.parse(data)
    functions = [node for node in parsed.body if isinstance(node, ast.FunctionDef) and node.name == "K_filter"]
    if len(functions) != 1:
        raise ReferenceError("Expected one pinned K_filter")
    calls = []

    def capture(b, a, signal):
        calls.append({"b": list(b), "a": list(a)})
        return signal

    scope = {"__builtins__": {}, "np": SimpleNamespace(pi=math.pi, tan=math.tan, power=pow),
             "lfilter": capture}
    exec(compile(ast.Module(body=functions, type_ignores=[]), "<pinned-external-K_filter>", "exec"), scope)
    result = {}
    for rate in RATES:
        calls.clear()
        scope["K_filter"]([], rate)
        if len(calls) != 2 or any(not math.isfinite(x) for stage in calls for values in stage.values() for x in values):
            raise ReferenceError("Invalid external coefficient calculation")
        result[rate] = list(calls)
    return result


def decimal_filter(samples, coefficients):
    """80-digit direct-form-I cascade, separate from the native transposed implementation."""
    values = [Decimal.from_float(x) for x in samples]
    with localcontext() as context:
        context.prec = 80
        for stage in coefficients:
            b = [Decimal.from_float(x) for x in stage["b"]]
            a = [Decimal.from_float(x) for x in stage["a"]]
            x1 = x2 = y1 = y2 = Decimal(0)
            output = []
            for x in values:
                y = (b[0] * x + b[1] * x1 + b[2] * x2 - a[1] * y1 - a[2] * y2) / a[0]
                output.append(y)
                x2, x1, y2, y1 = x1, x, y1, y
            values = output
    return values


def response(stages, rate, frequency):
    if frequency == 0:
        return {"frequencyHz": 0, "magnitude": 0, "phaseRadians": None, "groupDelaySeconds": None}

    def transfer(f):
        z = cmath.exp(-2j * math.pi * f / rate)
        h = 1 + 0j
        for stage in stages:
            h *= sum(c * z ** j for j, c in enumerate(stage["b"])) / sum(c * z ** j for j, c in enumerate(stage["a"]))
        return h

    h = transfer(frequency)
    delta = .01
    # Independent central phase difference; native evaluation uses analytic derivatives.
    delay = -cmath.phase(transfer(frequency + delta) / transfer(frequency - delta)) / (4 * math.pi * delta)
    return {"frequencyHz": frequency, "magnitude": abs(h),
            "phaseRadians": cmath.phase(h), "groupDelaySeconds": delay}


def signals(precision):
    state = 32
    white = []
    for _ in range(512):
        state = (1103515245 * state + 12345) & 0x7fffffff
        white.append((state - 0x40000000) / 0x80000000)
    # Original finite-band pink-noise realization: 1/sqrt(bin) magnitude and seeded phases.
    phases = [2 * math.pi * ((int((x + .5) * 0x80000000) % 65536) / 65536) for x in white[:255]]
    pink = [math.fsum(math.cos(2 * math.pi * k * n / 512 + phases[k - 1]) / math.sqrt(k)
                      for k in range(1, 256)) for n in range(512)]
    peak = max(abs(x) for x in pink)
    pink = [round(x / peak * 0x40000) / 0x80000 for x in pink]
    tiny = 1e-40 if precision == "float32" else 1e-300
    raw = {
        "silence": [0.] * 512,
        "impulse": [1.] + [0.] * 511,
        "dc": [.25] * 512,
        "negative-dc": [-.25] * 512,
        "step": [0.] * 128 + [.5] * 384,
        "nyquist": [.25 * (-1) ** n for n in range(512)],
        "full-scale-sine": [SINE[n % 16] for n in range(512)],
        "attenuated-sine": [.125 * SINE[n % 16] for n in range(512)],
        "white-noise": white,
        "pink-noise": pink,
        "over-range-square": [1.25 if n % 16 < 8 else -1.25 for n in range(512)],
        "tiny-sine": [tiny * SINE[n % 16] for n in range(512)],
    }
    if precision == "float32":
        return {name: [struct.unpack("<f", struct.pack("<f", x))[0] for x in values] for name, values in raw.items()}
    return raw


def generate(source_dir=CACHE):
    coefficients = reference_coefficients(source_dir)
    fixtures = []
    by_precision = {p: signals(p) for p in ("float32", "float64")}
    indices = sorted(set(range(0, 512, 8)) | set(range(8)) | set(range(504, 512)))
    with localcontext() as context:
        context.prec = 80
        for rate in RATES:
            for precision, catalog in by_precision.items():
                for name, values in catalog.items():
                    scale = max(map(abs, values)) or 1.
                    divisor = Decimal.from_float(scale)
                    weighted = decimal_filter(values, coefficients[rate])
                    windows = []
                    for start in range(0, 512 - 128 + 1, 64):
                        original = [Decimal.from_float(x) / divisor for x in values[start:start + 128]]
                        filtered = [x / divisor for x in weighted[start:start + 128]]
                        windows.append({"startSample": start, "sampleCount": 128,
                                        "unweightedNormalizedMeanSquare": float(sum(x*x for x in original) / 128),
                                        "weightedNormalizedMeanSquare": float(sum(x*x for x in filtered) / 128)})
                    fixtures.append({"name": name, "sampleRate": rate, "inputPrecision": precision,
                                     "input": values, "referenceScale": scale,
                                     "inputSHA256": sha(b"".join(struct.pack("<f" if precision == "float32" else "<d", x) for x in values)),
                                     "selectedOutputIndices": indices,
                                     "normalizedFilteredSamples": [float(weighted[i] / divisor) for i in indices],
                                     "windows": windows})
    return {"schemaVersion": 1,
            "oracle": "Pinned external coefficient equations plus original 80-digit Decimal direct-form-I cascade; not SciPy or full loudness conformance",
            "reference": {"repository": "https://github.com/BrechtDeMan/loudness.py", "revision": REVISION,
                          "sourceSHA256": SOURCE_SHA256, "license": "MIT", "licenseSHA256": LICENSE_SHA256},
            "generatorSHA256": sha(Path(__file__).read_bytes()),
            "nativeComparisonBudgets": {"coefficientAbsolute": 2e-12,
                                        "normalizedSampleAbsolute": 2e-9,
                                        "normalizedMeanSquareAbsolute": 2e-9,
                                        "responseMagnitudeAbsolute": 3e-9,
                                        "responsePhaseAbsoluteRadians": 1e-8,
                                        "responseGroupDelayAbsoluteSeconds": 1e-6},
            "coefficientSets": [{"sampleRate": rate, "stages": stages,
                                 "responses": [response(stages, rate, f) for f in
                                               (0, 10, 20, 40, 100, 200, 500, 1000, 1682, 2000, 4000, 6000, 10000, 16000, 20000)
                                               if f < rate / 2]}
                                for rate, stages in coefficients.items()],
            "cases": fixtures}


def compare(actual, expected, location="root"):
    if type(actual) is not type(expected):
        raise ReferenceError(f"Type mismatch: {location}")
    if isinstance(expected, dict):
        if actual.keys() != expected.keys():
            raise ReferenceError(f"Field mismatch: {location}")
        for key in expected:
            compare(actual[key], expected[key], f"{location}.{key}")
    elif isinstance(expected, list):
        if len(actual) != len(expected):
            raise ReferenceError(f"Count mismatch: {location}")
        for i, (left, right) in enumerate(zip(actual, expected)):
            compare(left, right, f"{location}[{i}]")
    elif isinstance(expected, float):
        # Tiny values are compared relative to their magnitude, never an absolute floor of one.
        tolerance = 2e-12 * max(abs(expected), abs(actual))
        if not math.isfinite(actual) or abs(actual - expected) > tolerance:
            raise ReferenceError(f"Numerical mismatch: {location}")
    elif actual != expected:
        raise ReferenceError(f"Value mismatch: {location}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("acquire", "generate", "verify"))
    parser.add_argument("--source-dir", type=Path, default=CACHE)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if args.operation == "acquire":
        if args.output is not None or args.source_dir != CACHE:
            raise ReferenceError("Acquisition has a fixed ignored cache destination")
        acquire()
        return
    if args.operation == "generate":
        if args.output is None or args.output.exists() or not args.output.resolve().is_relative_to((ROOT / ".build").resolve()):
            raise ReferenceError("Use a fresh candidate output under .build")
    elif args.output is not None:
        raise ReferenceError("Verify never writes or updates the committed fixture")
    result = generate(args.source_dir)
    if args.operation == "generate":
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, indent=2, allow_nan=False) + "\n")
        print(f"Generated {len(result['cases'])} independent level cases")
    else:
        compare(result, json.loads(GOLDEN.read_text()))
        print(f"Verified {len(result['cases'])} independent level cases")


if __name__ == "__main__":
    try:
        main()
    except (ReferenceError, OSError) as error:
        print(f"Level reference error: {error}", file=sys.stderr)
        raise SystemExit(1)
