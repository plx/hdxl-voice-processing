# Original command wrapper. Praat computes all reference values.
form Reference CPPS
    sentence Input
    integer Export_matrices 1
    positive Analysis_floor 60
    positive Hop_seconds 0.002
    positive Maximum_frequency 5000
    positive Pre_emphasis_from 50
    boolean Subtract_trend no
    real Time_smoothing 0.01
    real Quefrency_smoothing 0.001
    positive Search_floor 60
    positive Search_ceiling 330
    positive Tolerance 0.05
    sentence Interpolation Parabolic
    real Fit_start 0.001
    real Fit_end 0
    sentence Trend Straight
    sentence Fit Robust
endform
sound = Read from file: input$
rate = Get sampling frequency
samples = Get number of samples
appendInfoLine: "begin", tab$, "cpps-v1"
appendInfoLine: "input", tab$, rate, tab$, samples
raw = To PowerCepstrogram: analysis_floor, hop_seconds, maximum_frequency, pre_emphasis_from
frames = Get number of frames
first = Get time from frame number: 1
hop = Get time step
bins = Get number of quefrency bins
qstep = Get quefrency step
appendInfoLine: "axes", tab$, frames, tab$, first, tab$, hop, tab$, bins, tab$, qstep
cpps = Get CPPS: subtract_trend, time_smoothing, quefrency_smoothing, search_floor, search_ceiling, tolerance, interpolation$, fit_start, fit_end, trend$, fit$
appendInfoLine: "scalar", tab$, "cpps", tab$, cpps
if subtract_trend
    prepared = Subtract trend: fit_start, fit_end, trend$, fit$
else
    prepared = raw
endif
selectObject: prepared
smoothed = Smooth: time_smoothing, quefrency_smoothing
for stage from 1 to 2
    if stage = 1
        selectObject: raw
        stage$ = "raw"
    else
        selectObject: smoothed
        stage$ = "smoothed"
    endif
    cepstrogram = selected()
    table = To Table (CPP values): search_floor, search_ceiling, tolerance, interpolation$, fit_start, fit_end, trend$, fit$
    count = Get number of rows
    for i from 1 to count
        time = Get value: i, "time(s)"
        slope = Get value: i, "dB/s"
        intercept = Get value: i, "intercept(dB)"
        peak = Get value: i, "peak(dB)"
        quefrency = Get value: i, "quefrency(s)"
        cpp = Get value: i, "cpp(dB)"
        appendInfoLine: "frame", tab$, stage$, tab$, i, tab$, time, tab$, slope, tab$, intercept, tab$, peak, tab$, quefrency, tab$, cpp
    endfor
    selectObject: table
    Remove
    if export_matrices
        if frames * bins > 50000
            exitScript: "Intermediate export exceeds 50000 scalars per matrix"
        endif
        selectObject: cepstrogram
        matrix = To Matrix
        for row from 1 to bins
            for column from 1 to frames
                value = Get value in cell: row, column
                appendInfoLine: "cell", tab$, stage$, tab$, row, tab$, column, tab$, value
            endfor
        endfor
        Remove
    endif
endfor
appendInfoLine: "end", tab$, "cpps-v1"
