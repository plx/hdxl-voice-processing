# Original developer wrapper. Numeric queries avoid localized Voice report text.
form Reference voice measurements
    sentence Input
    sentence Analysis
    positive Hop_seconds 0.01
    positive Pitch_floor 75
    positive Pitch_ceiling 500
    real Silence_threshold 0.1
    positive Periods_per_window 4.5
    integer Candidates 15
    boolean Accurate yes
    real Voicing_threshold 0.45
    real Octave_cost 0.01
    real Octave_jump_cost 0.35
    real Voiced_unvoiced_cost 0.14
    positive Period_floor 0.0001
    positive Period_ceiling 0.02
    positive Maximum_period_factor 1.3
    positive Maximum_amplitude_factor 1.6
    positive Maximum_formants 5
    positive Formant_ceiling 5000
    positive Window_seconds 0.025
    positive Pre_emphasis_from 50
endform
sound = Read from file: input$
rate = Get sampling frequency
samples = Get number of samples
appendInfoLine: "begin", tab$, analysis$
appendInfoLine: "input", tab$, rate, tab$, samples
if analysis$ = "hnr-ac" or analysis$ = "hnr-cc"
    if analysis$ = "hnr-ac"
        harmonicity = To Harmonicity (ac): hop_seconds, pitch_floor, silence_threshold, periods_per_window
    else
        harmonicity = To Harmonicity (cc): hop_seconds, pitch_floor, silence_threshold, periods_per_window
    endif
    count = Get number of frames
    appendInfoLine: "count", tab$, count
    mean = Get mean: 0, 0
    appendInfoLine: "scalar", tab$, "harmonicToNoiseRatio", tab$, "decibelsRatio", tab$, mean
    for i from 1 to count
        time = Get time from frame number: i
        value = Get value in frame: i
        # Praat's raw Harmonicity silent-frame sentinel; never a measured -200 dB.
        if value = -200
            value = undefined
        endif
        appendInfoLine: "hnr", tab$, i, tab$, time, tab$, value
    endfor
elsif analysis$ = "perturbation"
    pitch = To Pitch (raw cc): hop_seconds, pitch_floor, pitch_ceiling, candidates, accurate, silence_threshold, voicing_threshold, octave_cost, octave_jump_cost, voiced_unvoiced_cost
    selectObject: sound, pitch
    pulses = To PointProcess (cc)
    count = Get number of points
    appendInfoLine: "count", tab$, count
    for i from 1 to count
        time = Get time from index: i
        appendInfoLine: "pulse", tab$, i, tab$, time
    endfor
    local = Get jitter (local): 0, 0, period_floor, period_ceiling, maximum_period_factor
    absolute = Get jitter (local, absolute): 0, 0, period_floor, period_ceiling, maximum_period_factor
    rap = Get jitter (rap): 0, 0, period_floor, period_ceiling, maximum_period_factor
    ppq5 = Get jitter (ppq5): 0, 0, period_floor, period_ceiling, maximum_period_factor
    ddp = Get jitter (ddp): 0, 0, period_floor, period_ceiling, maximum_period_factor
    appendInfoLine: "scalar", tab$, "jitterLocal", tab$, "fraction", tab$, local
    appendInfoLine: "scalar", tab$, "jitterAbsolute", tab$, "seconds", tab$, absolute
    appendInfoLine: "scalar", tab$, "jitterRAP", tab$, "fraction", tab$, rap
    appendInfoLine: "scalar", tab$, "jitterPPQ5", tab$, "fraction", tab$, ppq5
    appendInfoLine: "scalar", tab$, "jitterDDP", tab$, "fraction", tab$, ddp
    selectObject: sound, pulses
    local = Get shimmer (local): 0, 0, period_floor, period_ceiling, maximum_period_factor, maximum_amplitude_factor
    db = Get shimmer (local_dB): 0, 0, period_floor, period_ceiling, maximum_period_factor, maximum_amplitude_factor
    apq3 = Get shimmer (apq3): 0, 0, period_floor, period_ceiling, maximum_period_factor, maximum_amplitude_factor
    apq5 = Get shimmer (apq5): 0, 0, period_floor, period_ceiling, maximum_period_factor, maximum_amplitude_factor
    apq11 = Get shimmer (apq11): 0, 0, period_floor, period_ceiling, maximum_period_factor, maximum_amplitude_factor
    dda = Get shimmer (dda): 0, 0, period_floor, period_ceiling, maximum_period_factor, maximum_amplitude_factor
    appendInfoLine: "scalar", tab$, "shimmerLocal", tab$, "fraction", tab$, local
    appendInfoLine: "scalar", tab$, "shimmerDB", tab$, "decibelsRatio", tab$, db
    appendInfoLine: "scalar", tab$, "shimmerAPQ3", tab$, "fraction", tab$, apq3
    appendInfoLine: "scalar", tab$, "shimmerAPQ5", tab$, "fraction", tab$, apq5
    appendInfoLine: "scalar", tab$, "shimmerAPQ11", tab$, "fraction", tab$, apq11
    appendInfoLine: "scalar", tab$, "shimmerDDA", tab$, "fraction", tab$, dda
elsif analysis$ = "formants"
    formants = To Formant (burg): hop_seconds, maximum_formants, formant_ceiling, window_seconds, pre_emphasis_from
    count = Get number of frames
    appendInfoLine: "count", tab$, count
    for i from 1 to count
        time = Get time from frame number: i
        n = Get number of formants: i
        appendInfoLine: "formantFrame", tab$, i, tab$, time, tab$, n
        for f from 1 to n
            frequency = Get value at time: f, time, "Hertz", "Linear"
            bandwidth = Get bandwidth at time: f, time, "Hertz", "Linear"
            appendInfoLine: "formant", tab$, i, tab$, f, tab$, frequency, tab$, bandwidth
        endfor
    endfor
else
    exitScript: "Unknown analysis"
endif
appendInfoLine: "end", tab$, analysis$
