"""Explicit versioned reference recipes; no implicit Praat defaults."""
from common import ReferenceError, canonical


def setting(kind, value):
    return {"type": kind, kind: value}


def cpps_profile():
    return {
        "schemaVersion": 1,
        "identifier": {"name": "murton-recipe-praat-7.0.02-all", "version": 1},
        "measurement": {"kind": "cpps", "unit": "decibelsRatio",
                        "algorithm": {"name": "praat-7.0.02-cpps", "version": 1}},
        "inputFormat": {"sampleRate": 16000, "channelCount": 1, "encoding": "float64", "layout": "interleaved"},
        "channels": {"channelIndex": 0}, "precision": "float64", "frameLength": 1000, "hopLength": 20,
        "analysisSampleRate": 10000, "window": {"name": "praat-gaussian-2-physical", "version": 1},
        "preprocessing": {"pitchFloorHz": setting("real", 60), "maximumFrequencyHz": setting("real", 5000),
                          "preEmphasisFromHz": setting("real", 50), "resamplePrecision": setting("integer", 50),
                          "subtractFrameMean": setting("boolean", True)},
        "algorithmSettings": {"pitchFloorHz": setting("real", 60), "pitchCeilingHz": setting("real", 330),
                              "tolerance": setting("real", 0.05), "interpolation": setting("text", "Parabolic"),
                              "smoothingTimeSeconds": setting("real", 0.01), "smoothingQuefrencySeconds": setting("real", 0.001),
                              "subtractTrendBeforeSmoothing": setting("boolean", False),
                              "fitStartSeconds": setting("real", 0.001), "fitEndSeconds": setting("real", 0),
                              "trend": setting("text", "Straight"), "fit": setting("text", "Robust"),
                              "effectiveFit": setting("text", "praat7-siegel-repeated-median"),
                              "selection": setting("text", "all-contiguous-input"),
                              "aggregation": setting("text", "arithmetic-frame-db"),
                              "fftSize": setting("integer", 1024), "debugAlgorithm": setting("integer", 0)},
        "partialWindowPolicy": "discard",
    }


def validate_cpps_profile(profile):
    expected = cpps_profile()
    # The initial executable recipe is deliberately exact. Extend named recipes
    # with independently reviewed goldens rather than silently accepting settings
    # the runner cannot honor. Identity hashing still covers every supplied field.
    # JSON booleans and numbers are distinct even though Python True == 1.
    if canonical(profile) != canonical(expected):
        raise ReferenceError("Unsupported or mismatched CPPS profile; add a named recipe before changing settings")
    return profile
