# Original black-box export wrapper; the pinned Praat binary performs analysis.
form Cepstral interval reference
    sentence Input
    positive Pitch_floor 60
    positive Hop_seconds 0.002
    positive Maximum_frequency 5000
    positive Pre_emphasis_from 50
endform
original = Read from file: input$
raw = To PowerCepstrogram: pitch_floor, hop_seconds, maximum_frequency, pre_emphasis_from
frames = Get number of frames
first = Get time from frame number: 1
hop = Get time step
bins = Get number of quefrency bins
qstep = Get quefrency step
appendInfoLine: "begin", tab$, "cepstral-interval-v1"
appendInfoLine: "axes", tab$, frames, tab$, first, tab$, hop, tab$, bins, tab$, qstep
matrix = To Matrix
# Five evenly spaced frames preserve endpoint and interior support. Short inputs
# export each frame exactly once. Every selected frame retains every quefrency bin.
exports = min (frames, 5)
for j from 1 to exports
    if exports = 1
        frame = 1
    else
        frame = 1 + floor ((frames - 1) * (j - 1) / (exports - 1))
    endif
    selectObject: raw
    center = Get time from frame number: frame
    appendInfoLine: "frame-center", tab$, frame - 1, tab$, center
    selectObject: matrix
    for row from 1 to bins
        value = Get value in cell: row, frame
        appendInfoLine: "cell", tab$, frame - 1, tab$, row - 1, tab$, value
    endfor
endfor
selectObject: original
resampled = Resample: 2 * maximum_frequency, 50
count = Get number of samples
rate = Get sampling frequency
first = Get time from sample number: 1
end = Get end time
if count > 30000
    exitScript: "Reference resample export exceeds 30000 samples"
endif
appendInfoLine: "resampled-axis", tab$, count, tab$, rate, tab$, first, tab$, end
for i from 1 to count
    value = Get value at sample number: 1, i
    appendInfoLine: "resampled", tab$, i - 1, tab$, value
endfor
appendInfoLine: "end", tab$, "cepstral-interval-v1"
