#!/usr/bin/env python3
"""Export a pinned black-box Gaussian oracle, checked against independent decimal math."""
import argparse
from decimal import Decimal, localcontext
import hashlib
import json
import math
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
OUTPUT = ROOT / "Tests/HDXLVoiceProcessingTests/Fixtures/Framing/gaussian2.json"
COUNTS = (1, 2, 3, 4, 5, 17, 1000)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def mathematical_coefficients(count):
    """Original 70-digit Decimal evaluation; no binary64 exp or Swift implementation reuse."""
    with localcontext() as context:
        context.prec = 70
        edge = Decimal(-12).exp()
        return [float(((-12 * (Decimal(2 * index + 1 - count) / count) ** 2).exp() - edge) / (1 - edge))
                for index in range(count)]


def parse_output(output, count, rate):
    lines = output.strip().splitlines()
    if len(lines) != count + 1 or lines[0].split("\t") != ["gaussian2", str(count), str(rate)]:
        raise ValueError("Unexpected Gaussian reference dimensions")
    values = []
    for index, line in enumerate(lines[1:], 1):
        columns = line.split("\t")
        if len(columns) != 2 or columns[0] != str(index):
            raise ValueError("Unexpected Gaussian reference index")
        value = float(columns[1])
        if not math.isfinite(value):
            raise ValueError("Nonfinite Gaussian reference value")
        values.append(value)
    return values


def generate(executable):
    pin = json.loads((ROOT / "Tools/Reference/toolchain.json").read_text())
    if digest(executable) != pin["executableSHA256"]:
        raise ValueError("Reference executable differs from the pinned toolchain")
    environment = {**os.environ, "LC_ALL": "C", "LANG": "C"}
    script = HERE / "gaussian.praat"
    cases = []
    for count in COUNTS:
        rate = 48_000
        completed = subprocess.run([str(executable), *pin["options"], str(script), str(count), str(rate)],
                                   capture_output=True, text=True, check=True, timeout=60, env=environment)
        values = parse_output(completed.stdout, count, rate)
        expected = mathematical_coefficients(count)
        if max(abs(a - b) for a, b in zip(values, expected)) > 5e-15:
            raise ValueError("Pinned Gaussian differs from declared mathematical definition")
        cases.append({"sampleCount": count, "sampleRate": rate, "values": values,
                      "rawOutput": completed.stdout, "decimalOracle": expected})
    return {"schemaVersion": 1, "definition": "praat-gaussian-2-physical", "definitionVersion": 1,
            "precision": "float64", "absoluteTolerance": 5e-15,
            "tool": {"name": pin["tool"], "version": pin["version"],
                     "executableSHA256": pin["executableSHA256"], "sourceRevision": pin["sourceRevision"]},
            "scriptSHA256": digest(script), "generatorSHA256": digest(Path(__file__)),
            "input": "Sound of exactly N ones at 48000 Hz, generated within Praat; no recording",
            "equation": "u=(2*n+1-N)/N; w=(exp(-12*u*u)-exp(-12))/(1-exp(-12)); 0<=n<N",
            "cases": cases}


def register():
    path = ROOT / "Configuration/provenance.json"
    manifest = json.loads(path.read_text())
    relative = str(OUTPUT.relative_to(ROOT))
    identity = digest(Path(__file__))
    entry = {"id": "framing-gaussian2", "path": relative, "sha256": digest(OUTPUT),
             "source": {"kind": "original-generated", "url": "https://github.com/plx/hdxl-voice-processing/issues/24",
                        "versionOrHash": f"generator-v1-sha256:{identity}"},
             "generator": {"path": "Tools/Framing/reference.py", "version": "1", "sha256": identity},
             "redistribution": {"license": "project", "permission": "inherits-project-license",
                                "evidence": "https://github.com/plx/hdxl-voice-processing/issues/78"},
             "containsHumanVoice": False,
             "consent": {"status": "not-applicable", "evidence": "Original constant synthetic samples; no human recording"},
             "transformations": ["Pinned Praat public scripting Gaussian2 window on ones",
                                 "Independent original Decimal evaluation with 70 significant digits",
                                 "Reference numerical outputs only; no Praat implementation code redistributed"],
             "expectedProfile": "praat-gaussian-2-physical/v1; explicit count and rate per case",
             "referenceOutputIdentity": f"sha256:{digest(OUTPUT)}"}
    manifest["fixtures"] = [item for item in manifest["fixtures"] if item["path"] != relative] + [entry]
    for component in manifest["components"]:
        if component["id"] == "praat":
            usage = "Tools/Framing/reference.py: black-box Gaussian coefficient oracle only; no runtime linkage"
            if usage not in component["usedBy"]:
                component["usedBy"].append(usage)
    path.write_text(json.dumps(manifest, indent=2) + "\n")


def verify(stored, fresh):
    if {key: value for key, value in stored.items() if key != "cases"} != {
        key: value for key, value in fresh.items() if key != "cases"
    } or len(stored["cases"]) != len(fresh["cases"]):
        raise ValueError("Stored Gaussian reference identity differs")
    for old, new in zip(stored["cases"], fresh["cases"]):
        if set(old) != set(new) or any(old[key] != new[key] for key in ("sampleCount", "sampleRate", "decimalOracle")):
            raise ValueError("Stored Gaussian reference axes/oracle differ")
        parsed = parse_output(old["rawOutput"], old["sampleCount"], old["sampleRate"])
        if parsed != old["values"] or len(parsed) != len(new["values"]):
            raise ValueError("Stored Gaussian text and values disagree")
        if any(abs(a - b) > fresh["absoluteTolerance"] for a, b in zip(parsed, new["values"])):
            raise ValueError("Stored Gaussian coefficients differ beyond tolerance")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("executable", type=Path)
    parser.add_argument("--write", action="store_true", help="Regenerate fixture and provenance; default verifies")
    args = parser.parse_args()
    result = generate(args.executable.resolve())
    if args.write:
        OUTPUT.parent.mkdir(parents=True, exist_ok=True)
        OUTPUT.write_text(json.dumps(result, sort_keys=True, indent=2, allow_nan=False) + "\n")
        register()
    else:
        verify(json.loads(OUTPUT.read_text()), result)
    print(f"Verified {len(result['cases'])} Gaussian reference windows")


if __name__ == "__main__":
    main()
