#!/usr/bin/env python3
"""Original synthetic fitting/evaluation oracle, independent of Swift output.

Labels are assigned to balance software scenarios after deterministic grouping.
This is not a data collection protocol or evidence of personal preference validity.
"""
import argparse
from collections import defaultdict
import hashlib
import json
import math
from pathlib import Path
import statistics

ROOT = Path(__file__).resolve().parents[2]


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False).encode()


def sha(value):
    return hashlib.sha256(value).hexdigest()


def uuid(value):
    return f"00000000-0000-0000-0000-{value:012d}"


def rows():
    counts = defaultdict(int)
    result = []
    for number in range(1, 65):
        session = 800 + (number - 1) // 16
        group = sha(canonical({"domain": "calibration-recording-group-v1", "acquisitions": [uuid(number)],
                               "contents": [{"sha256": sha(f"test-audio-{number}".encode())}]}))
        draw = int(sha(canonical({"domain": "calibration-recording-holdout-v1",
                                 "seed": 53, "group": {"sha256": group}}))[:8], 16) / 2**32
        role = "sessionEvaluation" if session >= 802 else "recordingEvaluation" if draw < .5 else "fitting"
        key = session, role
        preference = "preferred" if counts[key] % 2 == 0 else "usual"
        counts[key] += 1
        result.append({"id": number, "session": session, "role": role, "groupSHA256": group,
                       "label": preference, "cpps": 10. if preference == "preferred" else 4.,
                       "pitch": 200., "level": -20.})
    return result


def distribution(values):
    # Independent inverse empirical CDF using ranks, not an interpolated quantile.
    values = sorted(values)
    return {"count": len(values), "minimum": min(values), "maximum": max(values),
            "lowerQuartile": values[(len(values) - 1) // 4],
            "median": statistics.median_low(values),
            "upperQuartile": values[(3 * len(values) - 1) // 4]}


def interval(preferred, all_values):
    d = distribution(preferred)
    margin = 1.5 * (d["upperQuartile"] - d["lowerQuartile"])
    return {"lower": max(min(all_values), d["lowerQuartile"] - margin),
            "upper": min(max(all_values), d["upperQuartile"] + margin)}


def wilson(successes, trials):
    # Invert the score inequality numerically; native code uses the closed form.
    if not trials:
        return None
    observed = successes / trials
    z_squared = statistics.NormalDist().inv_cdf(.975)**2
    def inside(p):
        return trials * (observed - p)**2 <= z_squared * p * (1 - p)
    def boundary(outside, inside_point):
        for _ in range(100):
            middle = (outside + inside_point) / 2
            if inside(middle):
                inside_point = middle
            else:
                outside = middle
        return inside_point
    return {"successes": successes, "trials": trials,
            "lower": 0. if successes == 0 else boundary(0., observed),
            "upper": 1. if successes == trials else boundary(1., observed)}


def classification(members, band, support, pitch_support, level_support):
    counts = {"totalGroups": len(members), "preferredGroups": 0, "usualGroups": 0,
              "preferredPredictedPreferred": 0, "preferredPredictedUsual": 0, "preferredAbstained": 0,
              "usualPredictedUsual": 0, "usualPredictedPreferred": 0, "usualAbstained": 0}
    predictions = []
    for row in members:
        predicted = None
        if (support[0] <= row["cpps"] <= support[1]
                and pitch_support[0] <= row["pitch"] <= pitch_support[1]
                and level_support[0] <= row["level"] <= level_support[1]):
            predicted = "preferred" if band["lower"] <= row["cpps"] <= band["upper"] else "usual"
        counts[row["label"] + "Groups"] += 1
        counts[row["label"] + ("Predicted" + predicted.capitalize() if predicted else "Abstained")] += 1
        predictions.append({"id": row["id"], "predicted": predicted})
    counts["classifiedGroups"] = sum(x["predicted"] is not None for x in predictions)
    counts["abstainedGroups"] = len(members) - counts["classifiedGroups"]
    counts["balancedAccuracy"] = .5 * sum(counts[k + "Predicted" + k.capitalize()] / counts[k + "Groups"]
                                          for k in ("preferred", "usual"))
    counts["classificationCoverage"] = counts["classifiedGroups"] / len(members)
    return {"counts": counts, "predictions": predictions,
            "preferredInterval": wilson(counts["preferredPredictedPreferred"], counts["preferredGroups"]),
            "usualInterval": wilson(counts["usualPredictedUsual"], counts["usualGroups"])}


def make_case(name):
    records = rows()
    outlier_used = False
    for row in records:
        preferred = row["label"] == "preferred"
        if name == "inverted":
            row["cpps"] = 4. if preferred else 10.
        elif name == "overlap":
            row["cpps"] = 7.
        elif name == "both-sides" and not preferred:
            row["cpps"] = 4. if row["id"] % 3 == 0 else 16.
        elif name == "outlier" and preferred and row["role"] == "fitting" and not outlier_used:
            row["cpps"], outlier_used = 100., True
        elif name == "heldout-overlap" and row["role"] != "fitting":
            row["cpps"] = 10.
        elif name == "heldout-outside" and row["role"] != "fitting":
            row["cpps"] = 100.
        elif name == "loudness-confound":
            row["level"] = -20. if preferred else -30.
        elif name == "pitch-confound":
            row["pitch"] = 200. if preferred else 150.
    training = [x for x in records if x["role"] == "fitting"]
    preferred = [x["cpps"] for x in training if x["label"] == "preferred"]
    usual = [x["cpps"] for x in training if x["label"] == "usual"]
    band = interval(preferred, preferred + usual)
    below, above = any(x < band["lower"] for x in usual), any(x > band["upper"] for x in usual)
    direction = "usualOnBothSides" if below and above else "usualBelowInterval" if below else "usualAboveInterval" if above else "overlapping"
    support = min(preferred + usual), max(preferred + usual)
    pitch = min(x["pitch"] for x in training), max(x["pitch"] for x in training)
    level = min(x["level"] for x in training), max(x["level"] for x in training)
    reports = {role: classification([x for x in records if x["role"] == role], band, support, pitch, level)
               for role in ["fitting", "recordingEvaluation", "sessionEvaluation"]}
    activated = name in ["separated", "inverted", "both-sides", "outlier"]
    return {"name": name, "rows": records, "preferredTraining": distribution(preferred),
            "usualTraining": distribution(usual), "preferredInterval": band,
            "observedCPPS": {"lower": support[0], "upper": support[1]},
            "direction": direction, "reports": reports, "activated": activated}


def generate():
    return {"schemaVersion": 1, "definition": "independent-personal-cpps-iqr-band-v1",
            "generatorSHA256": sha(Path(__file__).read_bytes()),
            "splitSeed": 53, "recordingEvaluationFraction": .5,
            "syntheticOnly": True, "wilsonMethod": "numerical inversion of score inequality",
            "wilsonSource": "https://www.itl.nist.gov/div898/handbook/prc/section2/prc241.htm",
            "cases": [make_case(name) for name in ["separated", "inverted", "overlap", "both-sides",
                "outlier", "heldout-overlap", "heldout-outside", "loudness-confound", "pitch-confound"]]}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["generate", "verify"])
    parser.add_argument("--path", type=Path, required=True)
    arguments = parser.parse_args()
    expected = canonical(generate()) + b"\n"
    if arguments.command == "generate":
        if arguments.path.exists() or not arguments.path.resolve().is_relative_to((ROOT / ".build").resolve()):
            raise ValueError("Generate a fresh candidate under .build")
        arguments.path.parent.mkdir(parents=True, exist_ok=True)
        arguments.path.write_bytes(expected)
    elif arguments.path.read_bytes() != expected:
        raise ValueError("Independent fitting expectations changed")
    print("Nine independent fitting/evaluation cases verified")
