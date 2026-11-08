# Original external-command wrapper; no upstream numerical implementation is embedded.
form HNR reference probe
    sentence Input
    sentence Method
    positive Hop_seconds
    positive Pitch_floor
    real Silence_threshold
    positive Periods_per_window
endform
sound = Read from file: input$
rate = Get sampling frequency
samples = Get number of samples
if method$ = "ac"
    harmonicity = To Harmonicity (ac): hop_seconds, pitch_floor, silence_threshold, periods_per_window
elsif method$ = "cc"
    harmonicity = To Harmonicity (cc): hop_seconds, pitch_floor, silence_threshold, periods_per_window
else
    exitScript: "Unsupported HNR method"
endif
count = Get number of frames
first = Get time from frame number: 1
step = Get time step
mean = Get mean: 0, 0
appendInfoLine: "begin", tab$, "hnr-reference-v1"
appendInfoLine: "input", tab$, rate, tab$, samples
appendInfoLine: "settings", tab$, method$, tab$, hop_seconds, tab$, pitch_floor, tab$, silence_threshold, tab$, periods_per_window
appendInfoLine: "axes", tab$, count, tab$, first, tab$, step
appendInfoLine: "mean", tab$, "decibelsRatio", tab$, mean
for i from 1 to count
    time = Get time from frame number: i
    value = Get value in frame: i
    appendInfoLine: "frame", tab$, i, tab$, time, tab$, value
endfor
appendInfoLine: "end", tab$, "hnr-reference-v1"
