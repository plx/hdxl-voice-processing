"""Compare native results on the two arm64 targets, including each target's own fingerprints."""
import base64
from itertools import islice
import struct

from AlgorithmSuite.replay import MASK, lane_digest
from Equivalence.compare import distribution, require, scalar_budget, spectral_difference


def without(record, *keys):
    return {key: value for key, value in record.items() if key not in keys}


def exact(left, right, path):
    """Report the first differing field without printing a potentially large binary payload."""
    if left == right:
        return
    if isinstance(left, dict) and isinstance(right, dict) and left.keys() == right.keys():
        for key in left:
            exact(left[key], right[key], f"{path}.{key}")
    if isinstance(left, list) and isinstance(right, list) and len(left) == len(right):
        for index, (first, second) in enumerate(zip(left, right)):
            exact(first, second, f"{path}[{index}]")
    raise ValueError(f"Platform mismatch at {path}")


def spectral_digest(sequence):
    """Reconstruct the Swift worker's ordered digest from its published little-endian bins."""
    words = (word for word, in struct.iter_unpack("<Q", base64.b64decode(sequence["values"], validate=True)))
    fingerprint = 14695981039346656037
    count = 0
    for row in sequence["rows"]:
        label = row["status"]
        if label in ("measured", "noEnergy"):
            status = [1 if label == "measured" else 2]
        else:
            require(label.startswith("unavailable."), "Unknown native spectral status")
            reason = label.removeprefix("unavailable.").encode()
            status = [3, len(reason), *reason]
        for word in (row["start"], *status, row["count"]):
            fingerprint = (fingerprint ^ word) * 1099511628211 & MASK
        for word in islice(words, row["count"]):
            fingerprint = (fingerprint ^ word) * 1099511628211 & MASK
            count += 1
    require(next(words, None) is None and count == sum(row["count"] for row in sequence["rows"]),
            "Native spectral digest has the wrong number of bins")
    return dict(rows=len(sequence["rows"]), bins=count, fingerprint=fingerprint)


def compare_platforms(mac, ios):
    fixture = mac["fixture"]
    name = fixture["name"] + " / " + mac["recipe"]["composition"]
    exact(mac["recipe"], ios["recipe"], name + ".recipe")
    a, b = mac["reference"], ios["reference"]
    if a == b:
        return {"agreement": "exact"}
    # Only the native Float32 spectral transform and values derived from it have a
    # platform roundoff allowance. All other values and all partition checks stay exact.
    if fixture["precision"] != "float32" or not mac["recipe"].get("extensions"):
        exact(a, b, name)
    exact(without(a, "conformance", "lanes", "spectralVerification"),
          without(b, "conformance", "lanes", "spectralVerification"), name)
    x, y = a["conformance"], b["conformance"]
    exact(without(x, "values", "spectra"), without(y, "values", "spectra"), name + ".conformance")
    exact(sorted(x["values"]), sorted(y["values"]), name + ".metrics")
    rate = fixture["sampleRate"]
    scalars = {}
    for key, left in x["values"].items():
        right = y["values"][key]
        summaries = [r["lanes"][key] for r in (a, b)]
        if left == right or scalar_budget(key, rate / 2) == 0:
            exact(left, right, name + "." + key)
            exact(*summaries, name + "." + key + ".summary")
            continue
        exact([without(row, "value") for row in left], [without(row, "value") for row in right], name + "." + key)
        scalars[key] = distribution({"values": {key: left}}, {"values": {key: right}}, rate)[key]
        for rows, summary in zip((left, right), summaries):
            normalized = [dict(row, sourceStart=row["sample"],
                               status=row.get("status", "available" if "value" in row else "unavailable"))
                          for row in rows]
            exact(lane_digest(normalized), summary, name + "." + key + ".summary")
    fft = mac["recipe"]["extensions"]["layout"]["spectrum"]["transform"]["length"]
    bins = {}
    for key in ("spectrogram", "ltas"):
        bins[key] = spectral_difference(x["spectra"][key], y["spectra"][key], transform_length=fft)
    for ref in (a, b):
        spectra = ref["conformance"]["spectra"]
        frames = spectral_digest(spectra["spectrogram"])
        expected = dict(spectrogram=frames, accumulationInput=frames, longTermSpectrum=spectral_digest(spectra["ltas"]))
        exact(expected, ref["spectralVerification"], name + ".spectralVerification")
    return dict(agreement="bounded-float32-spectrum", scalars=scalars, spectra=bins)
