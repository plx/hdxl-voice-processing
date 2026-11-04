"""Pinned auxiliary Praat recipes. Algorithm leaves add their native profiles/goldens."""
from common import ReferenceError, ReferenceFailure, number, outcome
from cpps import integer

KINDS = ("hnr-ac", "hnr-cc", "perturbation", "formants")
PARAMETERS = {"hopSeconds": 0.01, "pitchFloorHz": 75, "pitchCeilingHz": 500,
    "silenceThreshold": 0.1, "periodsPerWindow": 4.5, "maximumCandidates": 15,
    "veryAccurate": True, "voicingThreshold": 0.45, "octaveCost": 0.01,
    "octaveJumpCost": 0.35, "voicedUnvoicedCost": 0.14, "periodFloorSeconds": 0.0001,
    "periodCeilingSeconds": 0.02, "maximumPeriodFactor": 1.3, "maximumAmplitudeFactor": 1.6,
    "maximumFormants": 5, "formantCeilingHz": 5000, "effectiveWindowSeconds": 0.025,
    "preEmphasisFromHz": 50}
UNITS = {"harmonicToNoiseRatio": "decibelsRatio", "jitterLocal": "fraction",
    "jitterAbsolute": "seconds", "jitterRAP": "fraction", "jitterPPQ5": "fraction", "jitterDDP": "fraction",
    "shimmerLocal": "fraction", "shimmerDB": "decibelsRatio", "shimmerAPQ3": "fraction",
    "shimmerAPQ5": "fraction", "shimmerAPQ11": "fraction", "shimmerDDA": "fraction"}


def recipe(kind):
    if kind not in KINDS:
        raise ReferenceError("Unknown reference analysis")
    return {"schemaVersion": 1, "identifier": {"name": f"praat-7.0.02-{kind}-reference", "version": 1},
            "analysis": kind, "sampleRate": 16000, "precision": "float64", "parameters": PARAMETERS,
            "selection": "entire contiguous input; no excluded samples stitched",
            "units": {k: v for k, v in UNITS.items() if k != "harmonicToNoiseRatio"} if kind == "perturbation" else ({"harmonicToNoiseRatio": "decibelsRatio"}
                if kind.startswith("hnr") else {"formantFrequency": "hertz", "formantBandwidth": "hertz"}),
            "timing": "frame centers and pulse times in seconds from input start; not sample indices",
            "scope": "external reference recipe; native AnalysisProfiles and full goldens added by algorithm leaf"}


def arguments(kind, path):
    return [str(path), kind, *[("yes" if v else "no") if type(v) is bool else str(v) for v in PARAMETERS.values()]]


def parse(raw, source, kind):
    lines = raw.splitlines()
    if len(lines) < 4 or lines[0] != "begin\t" + kind or lines[-1] != "end\t" + kind:
        raise ReferenceFailure("Missing/empty/truncated auxiliary output")
    if lines[1] != f"input\t{source['sampleRate']}\t{source['sampleCount']}":
        raise ReferenceFailure("Input rate/count mismatch")
    header = lines[2].split("\t")
    if len(header) != 2 or header[0] != "count":
        raise ReferenceFailure("Missing count")
    count = integer(header[1])
    if count > 100000:
        raise ReferenceFailure("Output count exceeds bound")
    scalars, rows, formants = {}, {}, {}
    expected = {"harmonicToNoiseRatio"} if kind.startswith("hnr") else set(UNITS) - {"harmonicToNoiseRatio"} if kind == "perturbation" else set()
    rowtag = "hnr" if kind.startswith("hnr") else "pulse" if kind == "perturbation" else "formantFrame"
    for line in lines[3:-1]:
        f = line.split("\t")
        if f[0] == "scalar" and len(f) == 4 and f[1] in expected and f[1] not in scalars and f[2] == UNITS[f[1]]:
            scalars[f[1]] = {"measurement": {"kind": f[1], "unit": f[2],
                "algorithm": {"name": "praat-7.0.02-" + kind, "version": 1}}, "outcome": outcome(number(f[3]))}
        elif f[0] == rowtag and len(f) == (3 if kind == "perturbation" else 4):
            index = integer(f[1])
            if index in rows:
                raise ReferenceFailure("Duplicate time row")
            rows[index] = [number(f[2])] + ([integer(f[3])] if kind == "formants" else [number(f[3])] if kind.startswith("hnr") else [])
        elif f[0] == "formant" and len(f) == 5 and kind == "formants":
            key = integer(f[1]), integer(f[2])
            if key in formants:
                raise ReferenceFailure("Duplicate formant")
            values = [number(f[3]), number(f[4])]
            if any(v is not None and v <= 0 for v in values):
                raise ReferenceFailure("Nonpositive formant frequency/bandwidth")
            formants[key] = values
        else:
            raise ReferenceFailure("Malformed/unexpected auxiliary output")
    if scalars.keys() != expected or rows.keys() != set(range(1, count + 1)):
        raise ReferenceFailure("Incomplete auxiliary output")
    values = [rows[i] for i in range(1, count + 1)]
    times = [row[0] for row in values]
    duration = source["sampleCount"] / source["sampleRate"]
    if any(t is None or not 0 <= t <= duration for t in times) or any(a >= b for a, b in zip(times, times[1:])):
        raise ReferenceFailure("Invalid or unordered time in seconds")
    if kind == "formants":
        if any(row[1] > PARAMETERS["maximumFormants"] for row in values):
            raise ReferenceFailure("Too many formants")
        if formants.keys() != {(i, f) for i in range(1, count + 1) for f in range(1, rows[i][1] + 1)}:
            raise ReferenceFailure("Incomplete formant coverage")
    return {"scalars": scalars, "rowType": rowtag, "rows": values,
            "formants": [{"frame": i, "number": f, "frequencyHz": v[0], "bandwidthHz": v[1]}
                         for (i, f), v in sorted(formants.items())],
            "undefinedPolicy": "null component / unavailable scalar; no substitution of zero"}
