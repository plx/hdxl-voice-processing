"""Exact accepted-sequence statistics, separate from waveform/pulse-estimator eligibility."""
from decimal import Decimal, localcontext
from fractions import Fraction

from synthetic import rational, require

DEFINITION = {"name": "explicit-accepted-sequence-statistics", "version": 1}
UNITS = {"jitterAbsolute": "seconds", "shimmerDB": "decibelsRatio"}


def outcome(value=None, reason=None, partial=False):
    if reason is not None:
        return {"status": "unavailable", "reason": reason}
    return {"status": "available", "estimate": {"value": float(value), "confidence": None,
            "warnings": ["partialCoverage"] if partial else []}}


def statistics(values, family, included=None):
    """No hidden period/amplitude-factor culling; callers specify accepted entries.

    Every eligible window is contiguous in the original sequence. The normalization
    mean uses all included entries, including endpoints, and is stated explicitly.
    This is a mathematical sequence profile, not full Praat waveform parity.
    """
    require(family in ("period", "amplitude"), "Unknown sequence family")
    require(type(values) is list and len(values) <= 100000, "Invalid sequence")
    numbers = [rational(v) for v in values]
    if included is None:
        included = [True] * len(numbers)
    require(type(included) is list and len(included) == len(numbers)
            and all(type(v) is bool for v in included), "Invalid inclusion mask")
    selected = [v for v, keep in zip(numbers, included) if keep]
    mean = sum(selected, Fraction()) / len(selected) if selected else None
    partial = not all(included)
    metrics = (["jitterAbsolute", "jitterLocal", "jitterRAP", "jitterPPQ5", "jitterDDP"] if family == "period"
               else ["shimmerLocal", "shimmerDB", "shimmerAPQ3", "shimmerAPQ5", "shimmerAPQ11", "shimmerDDA"])
    widths = {"jitterAbsolute": 2, "jitterLocal": 2, "jitterRAP": 3, "jitterPPQ5": 5, "jitterDDP": 3,
              "shimmerLocal": 2, "shimmerDB": 2, "shimmerAPQ3": 3, "shimmerAPQ5": 5, "shimmerAPQ11": 11, "shimmerDDA": 3}
    invalid = any(v <= 0 for v in selected)
    domain_reason = ("insufficientData" if not selected else "silence" if family == "amplitude" and all(v == 0 for v in selected)
                     else "invalidInput" if invalid else None)
    results = {}
    for metric in metrics:
        width = widths[metric]
        starts = [i for i in range(len(numbers) - width + 1) if all(included[i:i + width])]
        record = {"measurement": {"kind": metric, "unit": UNITS.get(metric, "fraction"), "algorithm": DEFINITION},
                  "eligibleWindowCount": len(starts), "width": width, "exactRational": None,
                  "highPrecisionDecimal": None}
        reason = domain_reason or ("insufficientData" if not starts else None)
        if reason:
            record["outcome"] = outcome(reason=reason)
        elif metric == "shimmerDB":
            with localcontext() as context:
                context.prec = 80
                total = Decimal(0)
                for i in starts:
                    ratio = numbers[i] / numbers[i + 1]
                    d = Decimal(ratio.numerator) / Decimal(ratio.denominator)
                    total += abs(d.ln() / Decimal(10).ln())
                value = 20 * total / len(starts)
                record["highPrecisionDecimal"] = str(value)
                record["outcome"] = outcome(value, partial=partial)
        else:
            if width == 2:
                differences = [abs(numbers[i + 1] - numbers[i]) for i in starts]
            else:
                differences = [abs(numbers[i + width // 2] - sum(numbers[i:i + width]) / width) for i in starts]
            value = sum(differences) / len(differences)
            if metric != "jitterAbsolute":
                value /= mean
            if metric in ("jitterDDP", "shimmerDDA"):
                value *= 3
            record["exactRational"] = {"numerator": str(value.numerator), "denominator": str(value.denominator)}
            record["outcome"] = outcome(value, partial=partial)
        results[metric] = record
    return {"definition": DEFINITION, "family": family, "values": [str(v) for v in numbers],
            "included": included, "sourceCount": len(numbers), "includedCount": len(selected),
            "normalizationMean": str(mean) if mean is not None else None,
            "normalization": "mean of all explicitly included entries; no implicit threshold or endpoint removal",
            "continuity": "excluded entries break every window; no stitching", "statistics": results}
