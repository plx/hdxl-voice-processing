"""Parse complete, bounded Praat CPPS output without inventing missing values."""
import math

from common import ReferenceFailure, number

FRAME_COLUMNS = ("timeSeconds", "slopeDBPerSecond", "interceptDB", "peakDB", "peakQuefrencySeconds", "cppDB")


def arguments(profile, path, export):
    p = profile["preprocessing"]
    a = profile["algorithmSettings"]
    get = lambda obj, key: obj[key][obj[key]["type"]]
    return [str(path), "1" if export else "0", str(get(p, "pitchFloorHz")),
            str(profile["hopLength"] / profile["analysisSampleRate"]),
            str(get(p, "maximumFrequencyHz")), str(get(p, "preEmphasisFromHz")),
            "yes" if get(a, "subtractTrendBeforeSmoothing") else "no",
            *[str(get(a, key)) for key in ("smoothingTimeSeconds", "smoothingQuefrencySeconds", "pitchFloorHz",
                                          "pitchCeilingHz", "tolerance", "interpolation", "fitStartSeconds",
                                          "fitEndSeconds", "trend", "fit")]]


def integer(token):
    if not token.isascii() or not token.isdigit():
        raise ReferenceFailure("Expected nonnegative integer reference index")
    return int(token)


def parse(raw, input_record, export):
    lines = raw.splitlines()
    if len(lines) < 5 or lines[0] != "begin\tcpps-v1" or lines[-1] != "end\tcpps-v1":
        raise ReferenceFailure("Missing/empty/truncated reference output")
    axes = None
    scalar = None
    scalar_seen = False
    input_seen = False
    frames = {stage: {} for stage in ("raw", "smoothed")}
    cells = {stage: {} for stage in frames}
    for line in lines[1:-1]:
        fields = line.split("\t")
        tag = fields[0]
        if tag == "input" and len(fields) == 3 and not input_seen:
            if [integer(v) for v in fields[1:]] != [input_record["sampleRate"], input_record["sampleCount"]]:
                raise ReferenceFailure("Praat input rate/count disagrees with PCM metadata")
            input_seen = True
        elif tag == "axes" and len(fields) == 6 and axes is None:
            count, first, hop, bins, qstep = integer(fields[1]), number(fields[2]), number(fields[3]), integer(fields[4]), number(fields[5])
            if not 1 <= count <= 30000 or not 1 <= bins <= 8193 or any(v is None for v in (first, hop, qstep)) or first < 0 or hop <= 0 or qstep <= 0:
                raise ReferenceFailure("Invalid reference axes")
            axes = {"frameCount": count, "firstCenterSeconds": first, "hopSeconds": hop,
                    "quefrencyBinCount": bins, "quefrencyOriginSeconds": 0, "quefrencyStepSeconds": qstep}
        elif tag == "scalar" and len(fields) == 3 and fields[1] == "cpps" and not scalar_seen:
            scalar, scalar_seen = number(fields[2]), True
        elif tag == "frame" and len(fields) == 9 and fields[1] in frames:
            index = integer(fields[2])
            if index in frames[fields[1]]:
                raise ReferenceFailure("Duplicate frame")
            frames[fields[1]][index] = [number(v) for v in fields[3:]]
        elif tag == "cell" and len(fields) == 5 and fields[1] in cells and export:
            key = (integer(fields[2]), integer(fields[3]))
            if key in cells[fields[1]]:
                raise ReferenceFailure("Duplicate matrix cell")
            cells[fields[1]][key] = number(fields[4])
        else:
            raise ReferenceFailure("Unexpected, repeated, or malformed reference record")
    if not (axes and input_seen and scalar_seen):
        raise ReferenceFailure("Incomplete reference header")
    n, q = axes["frameCount"], axes["quefrencyBinCount"]
    duration = input_record["sampleCount"] / input_record["sampleRate"]
    expected_count = int((duration - 0.1) / 0.002 + 1.000000001)
    expected_first = (duration - (n - 1) * 0.002) / 2
    if (n != expected_count or q != 513 or axes["hopSeconds"] != 0.002
            or axes["quefrencyStepSeconds"] != 0.0001
            or not math.isclose(axes["firstCenterSeconds"], expected_first, abs_tol=1e-12, rel_tol=0)):
        raise ReferenceFailure("Axes disagree with pinned CPPS recipe and input duration")
    expected_frames = set(range(1, n + 1))
    if export and n * q > 50000:
        raise ReferenceFailure("Intermediate budget exceeded")
    result = {"axes": axes, "frames": {}, "matrices": {}}
    for stage in frames:
        if frames[stage].keys() != expected_frames:
            raise ReferenceFailure("Incomplete reference frame coverage")
        rows = [frames[stage][i] for i in range(1, n + 1)]
        for i, row in enumerate(rows):
            expected_time = axes["firstCenterSeconds"] + i * axes["hopSeconds"]
            if row[0] is None or not math.isclose(row[0], expected_time, abs_tol=1e-12, rel_tol=0):
                raise ReferenceFailure("Frame time disagrees with axis")
            # Undefined components remain null. An available prominence must be
            # explained by the reported peak and background at that same peak.
            if all(v is not None for v in row[1:]):
                if not math.isclose(row[5], row[3] - (row[1] * row[4] + row[2]), abs_tol=1e-7, rel_tol=1e-10):
                    raise ReferenceFailure("CPP components disagree")
        result["frames"][stage] = {"columns": list(FRAME_COLUMNS), "values": rows,
                                   "undefinedPolicy": "null means unavailable reference component, never zero"}
        if export:
            expected_cells = {(row, col) for row in range(1, q + 1) for col in range(1, n + 1)}
            if cells[stage].keys() != expected_cells:
                raise ReferenceFailure("Incomplete reference matrix coverage")
            values = [cells[stage][row, col] for row in range(1, q + 1) for col in range(1, n + 1)]
            if any(v is not None and v < 0 for v in values):
                raise ReferenceFailure("Negative power cepstrum")
            result["matrices"][stage] = {"rows": q, "columns": n, "order": "quefrency-row-major",
                                        "unit": "praat7-linear-power-cepstrum", "values": values}
    values = [row[-1] for row in result["frames"]["smoothed"]["values"]]
    if scalar is not None and all(v is not None for v in values):
        if not math.isclose(scalar, math.fsum(values) / len(values), abs_tol=1e-8, rel_tol=1e-10):
            raise ReferenceFailure("Whole-interval CPPS disagrees with frame mean")
    return scalar, result
