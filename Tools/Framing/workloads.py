"""Independent closed framing matrix and integer geometry for host evidence.

Keep the supported maximum literal here: deriving it from native output would let
an obsolete window bound silently satisfy a maximum-capacity benchmark run.
"""
import hashlib
import json
import math


def identity(configuration, name):
    canonical = json.dumps(configuration, sort_keys=True, separators=(",", ":"))
    return {"identifier": {"name": name, "version": 1},
            "sha256": hashlib.sha256(canonical.encode()).hexdigest()}


def expected_matrix():
    result = []
    shapes = ("rectangular", "hann-periodic", "hann-symmetric", "hamming-periodic", "hamming-symmetric")
    for precision, width in (("float32", 4), ("float64", 8)):
        geometries = [(rate, seconds, hop, "praat-gaussian-2-physical")
                      for rate in (16000, 44100, 48000)
                      for seconds in (0.020, 0.050, 0.100)
                      for hop in (0.002, 0.005, 0.010, 0.030)]
        geometries += [(rate, None, 0.002, "praat-gaussian-2-physical") for rate in (16000, 44100, 48000)]
        geometries += [(48000, 0.05, 0.005, shape) for shape in shapes]
        for rate, seconds, hop, shape in geometries:
            # All positive: Swift nearest-away-from-zero is floor(x + 0.5).
            length = 131072 if seconds is None else math.floor(seconds * rate + 0.5)
            step = math.floor(hop * rate + 0.5)
            count = max(rate, length + 10 * step)
            configuration = {"window": {"definition": shape, "sampleCount": length,
                                         "sampleRate": rate, "precision": precision},
                             "hopLength": step, "firstFrameOffsetSamples": 0,
                             "partialWindowPolicy": "discard"}
            row = {"name": f"{precision}.{rate}Hz.N{length}.H{step}.{shape}",
                   "configuration": configuration,
                   "framingIdentity": identity(configuration, "sample-grid-framing"),
                   "requestedHopSeconds": hop, "inputSampleCount": count,
                   "inputDurationSeconds": count / rate,
                   "expectedFrameCount": (count - length) // step + 1,
                   "smallChunkSamples": 17, "primitiveOperationsPerIteration": 100,
                   "preparedBufferBytes": 3 * length * width}
            if seconds is not None:
                row["requestedWindowSeconds"] = seconds
            result.append(row)
    return result


def _valid_types(value):
    if isinstance(value, dict):
        return all(isinstance(key, str) and _valid_types(item) for key, item in value.items())
    if isinstance(value, list):
        return all(_valid_types(item) for item in value)
    return type(value) in (str, int, float) and (not isinstance(value, (int, float)) or math.isfinite(value))


def validate_matrix(rows):
    expected = {row["name"]: row for row in expected_matrix()}
    if not isinstance(rows, list) or len(rows) != len(expected) or not _valid_types(rows):
        raise ValueError("Framing workload matrix coverage/types mismatch")
    seen = set()
    for row in rows:
        if not isinstance(row, dict):
            raise ValueError("Malformed framing workload row")
        name = row.get("name")
        if not isinstance(name, str) or name not in expected or name in seen or row != expected[name]:
            raise ValueError(f"Framing workload geometry/identity mismatch: {name}")
        seen.add(name)
    return rows
