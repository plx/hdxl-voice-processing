#!/usr/bin/env python3
"""Original small reference inputs and equation-derived primitive goldens (version 1)."""
import argparse
import math
from pathlib import Path
import struct

from common import ROOT, ReferenceError, canonical, digest, pcm_wave, write_json


def primitive_golden():
    # These closed-form transforms are hand-derived, not FFT output. DFT is
    # X[k] = sum_n x[n] exp(-2*pi*i*k*n/N), unnormalized, all N complex bins.
    definitions = [
        ("impulse", [0.5] + [0] * 7, [0.5] * 8, [0] * 8, 0.03125, 0.5),
        ("dc", [0.25] * 8, [2] + [0] * 7, [0] * 8, 0.0625, 0.25),
        ("nyquist", [0.25, -0.25] * 4, [0, 0, 0, 0, 2, 0, 0, 0], [0] * 8, 0.0625, 0.25),
        ("quarter-cosine", [0.5, 0, -0.5, 0] * 2, [0, 0, 2, 0, 0, 0, 2, 0], [0] * 8, 0.125, 0.5),
        ("quarter-sine", [0, 0.5, 0, -0.5] * 2, [0] * 8, [0, 0, -2, 0, 0, 0, 2, 0], 0.125, 0.5),
        ("silence", [0] * 8, [0] * 8, [0] * 8, 0, 0),
    ]
    vectors = [{"id": name, "samples": samples, "sampleRate": 8000,
                "normalizedFloat64LESHA256": digest(struct.pack("<8d", *samples)),
                "dftReal": real, "dftImaginary": imaginary,
                "meanSquare": energy, "rms": math.sqrt(energy), "peak": peak}
               for name, samples, real, imaginary, energy, peak in definitions]
    definition = {"schemaVersion": 1, "profile": "analytic-rectangular-dft8-energy/v1",
                  "window": "rectangular", "dft": "negative exponent; unnormalized forward; two-sided complex",
                  "meanSquare": "sum(x*x)/N", "rms": "sqrt(meanSquare)", "peak": "max(abs(x))",
                  "inputPrecision": "float64", "floatingAbsoluteTolerance": 1e-14,
                  "countsIndicesTolerance": 0, "vectors": vectors}
    return {**definition, "referenceIdentity": digest(b"hdxl-analytic-v1\n" + canonical(definition))}


def inputs():
    # Integer arithmetic followed by exact binary scaling; no platform libm phase drift.
    saw = lambda n: [(((i % 80) * 2 - 79) * 160) / 32768 for i in range(n)]
    return {"saw-120ms.wav": pcm_wave(saw(1920), 16000),
            "saw-500ms.wav": pcm_wave(saw(8000), 16000),
            "silence-500ms.wav": pcm_wave([0] * 8000, 16000)}


def generate(output):
    output = Path(output).resolve()
    if output.exists() or not output.is_relative_to((ROOT / ".build").resolve()):
        raise ReferenceError("Use a fresh candidate directory under repository .build")
    output.mkdir(parents=True)
    for name, data in inputs().items():
        (output / name).write_bytes(data)
    write_json(output / "primitives.json", primitive_golden())


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    generate(parser.parse_args().output)
