# Original development probe; Praat supplies all numerical outputs.
form CPPS probe
    sentence Input
    real Time_window 0.01
    real Q_window 0.001
    boolean Pretrend no
    positive Tolerance 0.05
    boolean Export_all yes
endform
raw = Read from file: input$
frames = Get number of frames
bins = Get number of quefrency bins
first = Get time from frame number: 1
hop = Get time step
qstep = Get quefrency step
appendInfoLine: "begin", tab$, "cpps-probe-v1"
appendInfoLine: "axes", tab$, frames, tab$, bins, tab$, first, tab$, hop, tab$, qstep
random_initializeWithSeedUnsafelyButPredictably (7002)
cpps = Get CPPS: pretrend, time_window, q_window, 60, 330, tolerance, "Parabolic", 0.001, 0, "Straight", "Robust"
appendInfoLine: "cpps", tab$, cpps
if pretrend
    random_initializeWithSeedUnsafelyButPredictably (7002)
    prepared = Subtract trend: 0.001, 0, "Straight", "Robust"
else
    prepared = raw
endif
selectObject: prepared
smoothed = Smooth: time_window, q_window
for stage from 1 to 3
    if stage = 1
        cepstrogram = raw
    elsif stage = 2
        cepstrogram = prepared
    else
        cepstrogram = smoothed
    endif
    selectObject: cepstrogram
    random_initializeWithSeedUnsafelyButPredictably (7002)
    table = To Table (CPP values): 60, 330, tolerance, "Parabolic", 0.001, 0, "Straight", "Robust"
    for i from 1 to frames
        time = Get value: i, "time(s)"
        slope = Get value: i, "dB/s"
        intercept = Get value: i, "intercept(dB)"
        peak = Get value: i, "peak(dB)"
        q = Get value: i, "quefrency(s)"
        cpp = Get value: i, "cpp(dB)"
        appendInfoLine: "frame", tab$, stage, tab$, i, tab$, time, tab$, slope, tab$, intercept, tab$, peak, tab$, q, tab$, cpp
    endfor
    selectObject: table
    Remove
    selectObject: cepstrogram
    matrix = To Matrix
    for row from 1 to bins
        for column from 1 to frames
            if export_all or column = 1 or column = frames or column = floor (frames / 2) + 1
                value = Get value in cell: row, column
                appendInfoLine: "cell", tab$, stage, tab$, row, tab$, column, tab$, value
            endif
        endfor
    endfor
    Remove
endfor
appendInfoLine: "end", tab$, "cpps-probe-v1"
