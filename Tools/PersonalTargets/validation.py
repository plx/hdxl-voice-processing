"""Validate native exact-profile receipts before a workflow can fit a target."""
import hashlib
import math

from profile_reference import BUDGETS, DEFINITION, canonical

PROFILE_SHA256 = "c9fbb8420ee5ac5f76254129d42d10358dd393f868a5173ee7dea45e0ce9b01b"
IMPLEMENTATION = {"name": "calibration-clip-analysis", "version": 1}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def fraction(value):
    return type(value) in (int, float) and math.isfinite(value) and 0 <= value <= 1


def validate_profile_report(report, reference, reference_bytes):
    require(set(report) == {"schemaVersion", "status", "definition", "profile", "profileIdentity",
        "analysisImplementation", "referenceSHA256", "cases", "physicalDeviceEvidence"}, "Unexpected profile receipt fields")
    require(type(report["schemaVersion"]) is int and report["schemaVersion"] == 1, "Wrong receipt schema")
    require(report["status"] == "passed" and report["definition"] == DEFINITION, "Unsuccessful/wrong profile probe")
    require(report["physicalDeviceEvidence"] is False, "Software probe claimed physical evidence")
    require(report["analysisImplementation"] == IMPLEMENTATION, "Wrong calibration analysis semantics")
    require(report["referenceSHA256"] == hashlib.sha256(reference_bytes).hexdigest(), "Unbound reference fixture")
    require(report["profileIdentity"] == {"identifier": {"name": "shared-pcm-analysis-schedule", "version": 1},
            "sha256": PROFILE_SHA256}, "Unvalidated executable profile")
    require(hashlib.sha256(canonical(report["profile"])).hexdigest() == PROFILE_SHA256, "Profile and identity disagree")
    require(len(report["cases"]) == len(reference["cases"]) == 14, "Incomplete profile cases")
    components = []
    for metric in BUDGETS:
        reference_count = 0
        chunk_count = 0
        boundary_count = 0
        maximum = boundary_maximum = 0.
        for actual, wanted in zip(report["cases"], reference["cases"], strict=True):
            require(set(actual) == {"name", "sampleCount", "boundary", "chunkComparisons",
                "chunkMaximumErrorToBudget", "metrics"}, "Unexpected case receipt fields")
            require(actual["name"] == wanted["name"] and type(actual["sampleCount"]) is int
                    and actual["sampleCount"] == wanted["sampleCount"]
                    and actual["boundary"] is wanted["boundary"], "Changed case identity/geometry")
            require(type(actual["chunkComparisons"]) is int and actual["chunkComparisons"] == 3
                    and fraction(actual["chunkMaximumErrorToBudget"])
                    and actual["chunkMaximumErrorToBudget"] == 0, "Missing exact chunk comparisons")
            require(set(actual["metrics"]) == set(BUDGETS), "Missing metric comparisons")
            point = actual["metrics"][metric]
            values = wanted["expected"][metric]
            require(set(point) == {"frames", "available", "maximumErrorToBudget", "absoluteBudget"}, "Unexpected metric receipt fields")
            require(type(point["frames"]) is int and point["frames"] == len(values)
                    and type(point["available"]) is int and point["available"] == sum(v is not None for v in values),
                    "Incomplete frame/availability denominators")
            require(type(point["absoluteBudget"]) in (int, float) and point["absoluteBudget"] == BUDGETS[metric]
                    and fraction(point["maximumErrorToBudget"]), "Failed/widened numerical budget")
            if metric != "cpps" or wanted["cppsReference"] is not None:
                reference_count += 1
            chunk_count += actual["chunkComparisons"]
            maximum = max(maximum, point["maximumErrorToBudget"])
            if wanted["boundary"]:
                boundary_count += 1
                boundary_maximum = max(boundary_maximum, point["maximumErrorToBudget"])
        components.append({"metric": metric, "referenceCases": reference_count,
            "chunkComparisons": chunk_count, "boundaryCases": boundary_count,
            "maximumReferenceErrorToBudget": maximum, "maximumChunkErrorToBudget": 0,
            "maximumBoundaryErrorToBudget": boundary_maximum})
    return components
