#!/usr/bin/env python3
"""Offline integrity/schema checks and explicit reference comparison statuses."""
import argparse
import math
from pathlib import Path
import sys

from common import HERE, ROOT, ReferenceError, canonical, digest, load_json, read_pcm
from fixtures import inputs, primitive_golden
from profiles import validate_cpps_profile
from run import assemble
import voice

GOLDENS = ROOT / "Tests/HDXLVoiceProcessingTests/Fixtures/Reference"
CATALOG = (("cpps-saw", "saw-120ms.wav", "cpps", True),
           ("hnr-silence", "silence-500ms.wav", "hnr-cc", False))


def validate(directory, pcm, analysis="cpps", intermediates=True):
    directory = Path(directory)
    manifest = load_json(directory / "reference.json")
    raw = (directory / "reference.raw.txt").read_text(encoding="utf-8")
    source = read_pcm(pcm)[1]
    profile = validate_cpps_profile(manifest["profile"]) if analysis == "cpps" else voice.recipe(analysis)
    expected = assemble(profile, source, load_json(HERE / "toolchain.json"), raw, intermediates, analysis)
    if canonical(manifest) != canonical(expected):
        raise ReferenceError("Reference schema, identity, input, settings or raw-output mismatch")
    return manifest


def compare_values(expected, actual, absolute=1e-8, relative=1e-10):
    """Bounded numerical comparison; null/status/unit/count differences are exact."""
    if type(expected) is bool or type(actual) is bool:
        return type(expected) is type(actual) and expected == actual
    if isinstance(expected, (int, float)) and isinstance(actual, (int, float)):
        if not math.isfinite(expected) or not math.isfinite(actual):
            return False
        if type(expected) is int:
            return expected == actual
        return math.isclose(expected, actual, abs_tol=absolute, rel_tol=relative)
    if type(expected) is not type(actual):
        return False
    if isinstance(expected, dict):
        return expected.keys() == actual.keys() and all(compare_values(expected[k], actual[k], absolute, relative) for k in expected)
    if isinstance(expected, list):
        return len(expected) == len(actual) and all(compare_values(a, b, absolute, relative) for a, b in zip(expected, actual))
    return expected == actual


def compare(expected, actual):
    if expected["referenceIdentity"] != actual["referenceIdentity"] or expected["identityInputs"] != actual["identityInputs"]:
        return "identityMismatch"
    # Compare numeric outputs, not raw text hashes: harmless last-place formatting
    # may vary, while counts, statuses, descriptors, axes and coverage stay exact.
    a, b = expected["data"], actual["data"]
    if "axes" in a and a["axes"] != b.get("axes"):
        # Axes use seconds tolerance, never the more permissive dB tolerance.
        if not compare_values(a["axes"], b.get("axes"), absolute=1e-12, relative=0):
            return "referenceDisagreement"
    if not compare_values(a, b) or not compare_values(expected.get("result"), actual.get("result")):
        return "referenceDisagreement"
    return "match"


def compare_outcomes(expected, actual):
    """For future native consumers, unsupported input is not numeric disagreement."""
    if actual.get("status") == "unavailable" and actual.get("reason") in {"invalidInput", "unsupportedRange", "insufficientData"}:
        return "unsupportedInput"
    if expected.get("status") == "unavailable" and actual == expected:
        return "matchingUnavailable"
    return "match" if compare_values(expected, actual) else "referenceDisagreement"


def verify_catalog():
    expected_inputs = inputs()
    for name, expected in expected_inputs.items():
        if (GOLDENS / name).read_bytes() != expected:
            raise ReferenceError(f"Original input no longer reproduces: {name}")
    if canonical(load_json(GOLDENS / "primitives.json")) != canonical(primitive_golden()):
        raise ReferenceError("Analytic primitive identity/values differ")
    return [validate(GOLDENS / name, GOLDENS / pcm, analysis, export)
            for name, pcm, analysis, export in CATALOG]


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.parse_args()
    try:
        references = verify_catalog()
        print(f"Offline reference verification passed: {len(references)} Praat manifests, 6 analytic vectors, 3 original inputs")
    except (ReferenceError, OSError, KeyError, TypeError) as error:
        print(f"Offline reference verification failed: {error}", file=sys.stderr)
        sys.exit(1)
