"""Compare per-observation contracts before applying any numerical precision budget."""
from array import array
import base64
from bisect import bisect_left
from collections import Counter
import hashlib
import math
import sys

from Reference.common import canonical


def require(condition, message):
    if not condition:
        raise ValueError(message)


def lanes(composition, ranks):
    expected = {"cpp", "cpps", "rollingCPPS"}
    if composition != "cpps":
        expected.update(("yin", "trackedYin", "rms", "meanSquare", "peak", "kWeightedMeanSquare",
                         "levelDBFS", "samplePeakDBFS", "clippingFraction", "crest"))
    if composition in ("full", "separateSpectra"):
        expected.update(("hnrDB", "hnrPeriodicity", "swipePrime", "swipePrimeStrength", "spectrogram", "ltas",
                         "ltsf", "speechInterval", "h1h2", "correctedH1H2", "pulses"))
        expected.update(f"{prefix}{i}" for prefix in ("formant", "bandwidth") for i in range(1, ranks + 1))
        expected.update("jitter." + key for key in ("local", "absolute", "rap", "ppq5", "ddp"))
        expected.update("shimmer." + key for key in ("local", "db", "apq3", "apq5", "apq11", "dda"))
        expected.update(f"{source}.{metric}" for source in ("frame", "ltas") for metric in
                        ("centroid", "spread", "flatness", "rollOff", "slope", "bandEnergyRatio"))
    return expected


def status(row):
    tag = row.get("status", "available" if "value" in row else "unavailable")
    return tag + ("." + row["reason"] if "reason" in row else "")


def sample_is_acquired(lane, sample, spans):
    # A rolling query is placed at the exclusive end of the observed prefix.
    return any(start <= sample < start + n or lane == "rollingCPPS" and sample == start + n for start, n in spans)


def validate_candidates(candidates, frame_support, composition, with_hnr):
    candidate_lanes = {} if composition == "cpps" else {"yin": "yin.fundamentalFrequency"}
    if with_hnr:
        candidate_lanes["hnr"] = "hnr.harmonicToNoiseRatio"
    require(candidate_lanes.keys() == candidates.keys(), "Missing candidate inspections")
    for key, support in candidate_lanes.items():
        inspections = candidates[key]
        frames = frame_support[support]
        require(len(inspections) == len(frames), f"Missing candidate frame: {key}")
        next_frame = Counter()
        for inspection, frame in zip(inspections, frames):
            epoch = frame["epoch"]
            count = inspection["count"]
            require(inspection["epoch"] == epoch and inspection["frame"] == next_frame[epoch] and count >= 0
                    and all(0 <= frame[field] < count for field in ("selectedCandidate", "trackedCandidate", "strongestCandidate")
                            if field in frame), f"Invalid candidate index or inspection order: {key}")
            next_frame[epoch] += 1


def validate(report, item, composition, platform, architecture):
    dataset = {k: v for k, v in item.items() if k not in ("group", "pair", "representation")}
    require(report["fixture"] == dataset, "Fixture identity, geometry or precision changed")
    execution = report["execution"]
    require((execution["platform"], execution["architecture"]) == (platform, architecture) and execution["operatingSystem"],
            "Wrong execution platform or architecture")
    plans = report["partitions"]
    seed = 61
    random = []
    for _ in range(97):
        seed = (seed * 6_364_136_223_846_793_005 + 1) % 2**64
        random.append(1 + (seed >> 32) % 509)
    require([(p["name"], p["sizes"]) for p in plans] == [
        ("whole-region", [item["sampleCount"]]), ("small", [7]), ("prime", [173]), ("deterministic-random", random)],
        "Incomplete partition matrix")
    r, recipe = report["reference"], report["recipe"]
    require(recipe["composition"] == composition and recipe["schedule"]["inputFormat"]["encoding"] == item["precision"],
            "Profile differs from the requested composition or precision")
    require(hashlib.sha256(canonical(recipe["schedule"])).hexdigest() == recipe["scheduleIdentity"]["sha256"],
            "Schedule provenance differs")
    ext = recipe.get("extensions")
    expected = lanes(composition, ext["harmonics"]["formants"]["order"] // 2 if ext else 0)
    observed = r["conformance"]
    require(expected == r["lanes"].keys() == observed["values"].keys(), "Incomplete numerical metric coverage")
    spans = [(repeat * item["sampleCount"] + span["start"], span["count"])
             for repeat in range(item["repeats"]) for span in item["regions"]]
    require(r["epochs"] == len(spans) and r["analyzedSamples"] == sum(n for _, n in spans),
            "Acquired regions were stitched or dropped")
    completions = observed["completions"]
    require(len(completions) == len(spans), "Missing region completion")
    for epoch, ((start, n), completion) in enumerate(zip(spans, completions)):
        source = completion["source"]
        require(completion["sourceOffset"] == start and source["startSample"] == 0 and source["sampleCount"] == n
                and source["epoch"]["sequence"] == epoch and source["sampleRate"] == item["sampleRate"]
                and completion["eligible"] == completion["selected"] == n and completion["emittedFrames"] > 0,
                "Completion differs from acquired source or coverage")
        cpps = completion["cpps"]
        require(cpps["source"] == source and 0 <= cpps["available"] <= cpps["frames"]
                and ("meanDB" in cpps) != ("reason" in cpps), "Invalid CPPS completion or aggregate outcome")
    for key, rows in observed["values"].items():
        summary = r["lanes"][key]
        counts = Counter(status(row) for row in rows)
        available = sum("value" in row for row in rows)
        require(rows and dict(counts) == summary["statusCounts"] and available == summary["available"]
                and len(rows) - available == summary["unavailable"], f"Availability counts differ: {key}")
        require(all(sample_is_acquired(key, row["sample"], spans) and
                    ("value" not in row or math.isfinite(row["value"])) for row in rows),
                f"Nonfinite value or timestamp outside acquisition: {key}")
    units = {"cpps.cpp": "decibelsRatio", "cpps.cpps": "decibelsRatio"}
    if composition != "cpps":
        units.update({"levels.meanSquare":"normalizedSquaredAmplitude", "levels.rms":"normalizedAmplitude",
                      "levels.peakAmplitude":"normalizedAmplitude", "levels.crestFactor":"dimensionless",
                      "levels.clippingFraction":"fraction", "levels.levelDBFS":"decibelsFullScale",
                      "levels.kWeightedEnergy":"normalizedSquaredAmplitude", "yin.fundamentalFrequency":"hertz",
                      "yin.trackedFundamentalFrequency":"hertz"})
    if ext:
        units.update({"hnr.harmonicToNoiseRatio":"decibelsRatio", "swipePrime.fundamentalFrequency":"hertz"})
    require(observed["support"].keys() == units.keys() and
            {k:v["unit"] for k,v in observed["descriptors"].items()} == units, "Missing or incorrect units")
    for key, rows in observed["support"].items():
        for row in rows:
            require(0 <= row["epoch"] < len(spans), f"Invalid source epoch: {key}")
            start, n = spans[row["epoch"]]
            for prefix in ("window", "dependency"):
                require(start <= row[prefix + "Start"] <= row[prefix + "Start"] + row[prefix + "Count"] <= start + n,
                        f"Measurement {prefix} crosses a gap: {key}")
            require(0 <= row["selected"] <= row["eligible"] <= row["dependencyCount"], f"Invalid coverage: {key}")
            metric = row["metricTiming"]
            source = metric["source"]
            require(source["epoch"]["sequence"] == row["epoch"] and source["sampleRate"] == item["sampleRate"]
                    and 0 <= source["startSample"] <= source["startSample"] + source["sampleCount"] <= n
                    and 0 <= metric["includedSampleCount"] <= source["sampleCount"] and metric["effectiveDelaySeconds"] >= 0,
                    f"Invalid exported measurement timing: {key}")
    validate_candidates(observed["candidates"], observed["support"], composition, bool(ext))
    if ext:
        typed_keys = {k for k in expected if k.startswith(("frame.", "ltas."))}
        if r["completePitchWindows"]:
            typed_keys |= {k for k in expected if k.startswith(("formant", "bandwidth", "jitter.", "shimmer."))}
            typed_keys.update(("h1h2", "correctedH1H2"))
        require(observed["nativeUnits"].keys() == typed_keys, "Missing native measurement unit")
        for key, unit in observed["nativeUnits"].items():
            if key.startswith(("formant", "bandwidth")):
                expected_unit = "hertz"
            elif key.startswith(("shimmer.", "jitter.")):
                expected_unit = {"shimmer.db":"decibelsRatio", "jitter.absolute":"seconds"}.get(key, "fraction")
            elif key.startswith(("frame.", "ltas.")):
                expected_unit = {"slope":"decibelsPerOctave", "flatness":"dimensionless",
                                 "bandEnergyRatio":"decibelsRatio"}.get(key.split(".")[1], "hertz")
            else:
                require(key in ("h1h2", "correctedH1H2"), "Unknown native unit lane")
                expected_unit = "decibelsRatio"
            require(unit == expected_unit, f"Unexpected unit {unit} for {key}")
        require(observed["spectra"].keys() == {"spectrogram", "ltas"} and r["spectralVerification"]["spectrogram"]
                == r["spectralVerification"]["accumulationInput"], "Incomplete shared-transform verification")
        require(len(r["perturbationCoverage"]) + r["omittedPulseRegions"] == len(spans), "Missing cycle coverage")
        require([(a["sourceStart"], a["pulse"]) for a in observed["cycleAmplitudes"]] ==
                [(p["sourceStart"], p["index"]) for p in observed["landmarks"]], "Missing cycle amplitude outcome")
    return dict(epochs=r["epochs"], acquiredSamples=r["analyzedSamples"], metrics=len(expected),
                profile=recipe["scheduleIdentity"]["sha256"], validities={k: v["statusCounts"] for k,v in r["lanes"].items()})


def scalar_budget(metric, nyquist):
    # Scalars computed entirely in Double receive zero slack for identical PCM.
    # The frequency budget is specified as a fraction of the analyzed Nyquist interval.
    if metric in ("spectrogram", "ltas"):
        return 1e-8  # Per-bin, signal-relative FFT check below also applies.
    if metric.startswith(("frame.", "ltas.")):
        return {"centroid": 1e-6 * nyquist, "spread": 1e-6 * nyquist, "rollOff": 0,
                "flatness": 1e-5, "slope": 0.001, "bandEnergyRatio": 0.05}[metric.split(".")[1]]
    return 0


def distribution(left, right, rate, *, different_input=False):
    """Accumulate worst differences by metric and status; positions and status tags never use a tolerance."""
    differences = {}
    for key, aa in left["values"].items():
        bb = right["values"][key]
        if different_input:
            # Signal-dependent interval edges can move. Align by sample and occurrence
            # within that sample (e.g. multiple intervals); never zip shifted observations.
            def indexed(rows):
                visits = Counter()
                result = {}
                for row in rows:
                    sample = row["sample"]
                    result[(sample, visits[sample])] = row
                    visits[sample] += 1
                return result
            a, b = indexed(aa), indexed(bb)
            aligned = [(a.get(k), b.get(k)) for k in sorted(a.keys() | b.keys())]
        else:
            require(len(aa) == len(bb), f"Count differs: {key}")
            aligned = zip(aa, bb)
        groups = {}
        for x, y in aligned:
            first, second = status(x) if x else "absent", status(y) if y else "absent"
            if not different_input:
                require(x["sample"] == y["sample"] and first == second and ("value" in x) == ("value" in y),
                        f"Status or source index differs: {key} at {x['sample']}")
            group = first if first == second else first + " -> " + second
            row = groups.setdefault(group, dict(count=0, maxAbsoluteError=0, worstSourceSample=None))
            row["count"] += 1
            if x and y and "value" in x and "value" in y:
                delta = abs(x["value"] - y["value"])
                if delta > row["maxAbsoluteError"]:
                    row.update(maxAbsoluteError=delta, worstSourceSample=x["sample"])
                if not different_input:
                    require(delta <= scalar_budget(key, rate / 2),
                            f"Precision budget exceeded for {key} at {x['sample']}: {delta}")
        differences[key] = groups
    return differences


def unpack_bins(sequence):
    values = array("d")
    values.frombytes(base64.b64decode(sequence["values"], validate=True))
    if sys.byteorder != "little":
        values.byteswap()
    require(all(type(r["count"]) is int and r["count"] >= 0 for r in sequence["rows"]), "Invalid spectral row size")
    require(all(math.isfinite(v) and v >= 0 for v in values), "Nonfinite or negative spectral power")
    require(sum(r["count"] for r in sequence["rows"]) == len(values), "Spectral row lengths differ")
    return values


def spectral_difference(a, b, *, transform_length=None):
    """Compare matching frequency bins. A transform length enables the identical-PCM budget."""
    x, y = unpack_bins(a), unpack_bins(b)
    left_rows, right_rows = a["rows"], b["rows"]
    require(len(left_rows) == len(right_rows), "Spectral frame count changed")
    left_offset = right_offset = compared = 0
    maximum = 0
    worst_sample = worst_bin = None
    changes = Counter()
    for left, right in zip(left_rows, right_rows):
        require(left["start"] == right["start"], "Spectral source index differs")
        if transform_length is not None:
            require(left == right, "Spectral status or row length differs")
        left_count, right_count = left["count"], right["count"]
        require(left_count == right_count or min(left_count, right_count) == 0, "Frequency grids differ")
        if left["status"] != right["status"]:
            changes[left["status"] + " -> " + right["status"]] += 1
        count = min(left_count, right_count)
        error = peak = 0
        for bin_index in range(count):
            first, second = x[left_offset + bin_index], y[right_offset + bin_index]
            peak = max(peak, first, second)
            delta = abs(first - second)
            error = max(error, delta)
            if delta > maximum:
                maximum, worst_sample, worst_bin = delta, left["start"], bin_index
        if transform_length is not None:
            # Norm-wise roundoff over the butterfly depth, scaled by this row alone.
            budget = 16 * 2**-23 * math.ceil(math.log2(transform_length)) * peak + transform_length * 2**-149
            require(error <= budget, f"Spectral precision budget exceeded at {left['start']}")
        compared += count
        left_offset += left_count
        right_offset += right_count
    return dict(rows=len(left_rows), bins=compared, maxAbsoluteError=maximum, worstSourceSample=worst_sample,
                worstBin=worst_bin, statusChanges=dict(changes), leftOnlyBins=len(x)-compared, rightOnlyBins=len(y)-compared)


def composition_signature(reference):
    """Retain exact emission order and extraction counts for independently run feature bundles."""
    def digest(value):
        return hashlib.sha256(canonical(value)).hexdigest()
    observations = reference["conformance"]
    completions = {}
    for record in observations["completions"]:
        stages = dict(cpps=record["cpps"], **record["framing"])
        if "hnr" in stages:
            stages["hnr"] = dict(framing=stages["hnr"], available=record["hnrAvailableFrames"],
                                 unavailable=record["hnrUnavailableFrames"])
        for stage, details in stages.items():
            completions.setdefault(stage, []).append(dict(source=record["source"], sourceOffset=record["sourceOffset"],
                                                          eligible=record["eligible"], selected=record["selected"], result=details))
    return dict(values={key: digest(rows) for key, rows in observations["values"].items()},
                support={key: digest(rows) for key, rows in observations["support"].items()},
                candidates={key: digest(rows) for key, rows in observations["candidates"].items()},
                completions={key: digest(rows) for key, rows in completions.items()},
                spectralRows=reference["spectralRows"],
                outputSHA256=digest({k: v for k, v in reference.items() if k != "spectralRows"}))


def check_compositions(signatures):
    full = signatures["full"]
    for name in ("cpps", "core"):
        reduced = signatures[name]
        require(reduced["spectralRows"] == 0, "Disabled transform emitted spectral rows")
        for field in ("values", "support", "candidates", "completions"):
            require(all(full[field].get(key) == digest for key, digest in reduced[field].items()),
                    f"Shared {field} changed when enabling additional features: {name}")
    separate = signatures["separateSpectra"]
    require(full["spectralRows"] > 0 and separate["spectralRows"] == 2 * full["spectralRows"]
            and separate["outputSHA256"] == full["outputSHA256"],
            "Independent spectral transforms changed output or work count")


def precision(float32, widened):
    a, b = (r["reference"] for r in (float32, widened))
    x, y = a["conformance"], b["conformance"]
    require(set(x["values"]) == set(y["values"]), "Precision changed metric set")
    for field in ("support", "descriptors", "nativeUnits", "candidates", "landmarks", "cycleAmplitudes", "completions"):
        require(x[field] == y[field], f"Precision changed discrete or timing evidence: {field}")
    require(a["perturbationCoverage"] == b["perturbationCoverage"], "Precision changed cycle coverage")
    errors = distribution(x, y, float32["fixture"]["sampleRate"])
    bins = {}
    if x["spectra"]:
        transform = float32["recipe"]["extensions"]["layout"]["spectrum"]["transform"]["length"]
        bins = {k: spectral_difference(v, y["spectra"][k], transform_length=transform) for k, v in x["spectra"].items()}
    return dict(scalars=errors, spectra=bins)


def pulse_changes(original, rounded, rate, maximum_period):
    """Match mutual nearest landmarks on the same epoch, capped at half a local period."""
    def epochs(data):
        groups = {}
        for landmark, amplitude in zip(data["landmarks"], data["cycleAmplitudes"], strict=True):
            groups.setdefault((landmark["epoch"], landmark["sourceStart"]), []).append(
                dict(landmark=landmark, amplitude=amplitude))
        for records in groups.values():
            records.sort(key=lambda r: (r["landmark"]["timeSeconds"], r["landmark"]["index"]))
        return groups

    def nearest(times, target):
        index = bisect_left(times, target)
        candidates = [i for i in (index - 1, index) if 0 <= i < len(times)]
        return min(candidates, key=lambda i: (abs(times[i] - target), i)) if candidates else None

    def radius(times, index):
        gaps = [abs(times[i] - times[index]) for i in (index - 1, index + 1) if 0 <= i < len(times)]
        return min(maximum_period / 2, min(gaps) / 2) if gaps else 1 / rate

    aa, bb = epochs(original), epochs(rounded)
    changed, missing_native, missing_rounded = [], [], []
    matched = 0
    for epoch in sorted(aa.keys() | bb.keys()):
        left, right = aa.get(epoch, []), bb.get(epoch, [])
        first = [r["landmark"]["timeSeconds"] for r in left]
        second = [r["landmark"]["timeSeconds"] for r in right]
        used = set()
        for i, a in enumerate(left):
            j = nearest(second, first[i])
            if j is None or nearest(first, second[j]) != i or abs(first[i] - second[j]) > min(radius(first, i), radius(second, j)):
                missing_rounded.append(a)
                continue
            used.add(j)
            matched += 1
            b = right[j]
            if a != b:
                change = dict(native=a, rounded=b, timeDeltaSeconds=second[j] - first[i])
                if "rms" in a["amplitude"] and "rms" in b["amplitude"]:
                    change["rmsDelta"] = b["amplitude"]["rms"] - a["amplitude"]["rms"]
                changed.append(change)
        missing_native.extend(b for j,b in enumerate(right) if j not in used)
    return dict(matched=matched, changed=changed, nativeOnly=missing_rounded, roundedOnly=missing_native)


def quantized_support(original, rounded):
    """PCM rounding can change voicing, tracker memory and measurement confidence on a fixed window."""
    fields = ("epoch", "windowStart", "windowCount", "centerSecondsFromRegionOrigin",
              "smoothingFrames", "smoothingEdge", "lookahead")
    changes = {}
    for key, left in original["support"].items():
        rows = []
        right = rounded["support"][key]
        require(len(left) == len(right), f"Input rounding moved a fixed scheduled frame: {key}")
        for a, b in zip(left, right):
            require(all(a.get(field) == b.get(field) for field in fields),
                    f"Input rounding moved an observation window: {key}")
            differences = {field: dict(native=a.get(field), rounded=b.get(field))
                           for field in a.keys() | b.keys() if a.get(field) != b.get(field)}
            if differences:
                rows.append(dict(epoch=a["epoch"], windowStart=a["windowStart"], changes=differences))
        if rows:
            changes[key] = rows
    return changes


def quantization(native, widened):
    """These representations encode different input samples. Preserve the measured differences."""
    x, y = (item["reference"]["conformance"] for item in (native, widened))
    extensions = native["recipe"].get("extensions")
    return dict(nativePCMSHA256=native["fixture"]["pcmSHA256"], widenedPCMSHA256=widened["fixture"]["pcmSHA256"],
                scalars=distribution(x, y, native["fixture"]["sampleRate"], different_input=True),
                changedSupport=quantized_support(x, y),
                spectra={k: spectral_difference(v, y["spectra"][k]) for k,v in x["spectra"].items()},
                differingCandidateCounts={k: sum(a["count"] != b["count"] for a, b in zip(v, y["candidates"][k], strict=True))
                                          for k,v in x["candidates"].items()},
                pulseChanges=pulse_changes(x, y, native["fixture"]["sampleRate"], extensions["pulses"]["maximumPeriodSeconds"])
                            if extensions else None)
