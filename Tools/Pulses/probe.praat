# Original developer wrapper. All pulse locations come from the pinned executable.
form Pulse reference with injected F0
    sentence Input
    sentence Pitch_file
    positive Period_floor 0.0001
    positive Period_ceiling 0.02
    positive Maximum_period_factor 1.3
endform
sound = Read from file: input$
rate = Get sampling frequency
samples = Get number of samples
pitch = Read from file: pitch_file$
frames = Get number of frames
first = Get time from frame number: 1
step = Get time step
start = Get start time
finish = Get end time
appendInfoLine: "begin", tab$, "pulse-reference-v2"
appendInfoLine: "input", tab$, rate, tab$, samples
appendInfoLine: "periodSettings", tab$, period_floor, tab$, period_ceiling, tab$, maximum_period_factor
appendInfoLine: "pitch", tab$, frames, tab$, first, tab$, step, tab$, start, tab$, finish
for i from 1 to frames
    time = Get time from frame number: i
    frequency = Get value in frame: i, "Hertz"
    appendInfoLine: "f0", tab$, i, tab$, time, tab$, frequency
endfor
selectObject: sound, pitch
pulses = To PointProcess (cc)
count = Get number of points
appendInfoLine: "count", tab$, count
observed = 0
for i from 1 to count
    time = Get time from index: i
    appendInfoLine: "pulse", tab$, i, tab$, time
    if time >= 0 and time <= finish
        observed += 1
    endif
endfor
if observed < 3
    appendInfoLine: "amplitudes", tab$, "insufficientData", tab$, 0
else
    selectObject: sound, pulses
    amplitudes = To AmplitudeTier (period): 0, 0, period_floor, period_ceiling, maximum_period_factor
    count = Get number of points
    appendInfoLine: "amplitudes", tab$, "complete", tab$, count
    for i from 1 to count
        time = Get time from index: i
        value = Get value at index: i
        appendInfoLine: "amplitude", tab$, i, tab$, time, tab$, value
    endfor
endif
appendInfoLine: "end", tab$, "pulse-reference-v2"
