# Original black-box wrapper. Praat performs all peak and fit estimation.
form CPP reference
    sentence Input
    positive Pitch_floor 60
    positive Pitch_ceiling 330
    sentence Interpolation Parabolic
    real Fit_start 0.001
    real Fit_end 0.05
    sentence Fit_method Robust
    positive Seed 7002
endform
Read from file: input$
# Reset before each fit query so intermediate/final estimates share identical
# reference random search choices. The Swift implementation has no random search.
random_initializeWithSeedUnsafelyButPredictably (seed)
slope = Get trend line slope: fit_start, fit_end, "Straight", fit_method$
random_initializeWithSeedUnsafelyButPredictably (seed)
intercept = Get trend line intercept: fit_start, fit_end, "Straight", fit_method$
random_initializeWithSeedUnsafelyButPredictably (seed)
cpp = Get peak prominence: pitch_floor, pitch_ceiling, interpolation$, fit_start, fit_end, "Straight", fit_method$
peak = Get peak: pitch_floor, pitch_ceiling, interpolation$
q = Get quefrency of peak: pitch_floor, pitch_ceiling, interpolation$
appendInfoLine: "cpp-reference-v1", tab$, slope, tab$, intercept, tab$, cpp, tab$, peak, tab$, q
