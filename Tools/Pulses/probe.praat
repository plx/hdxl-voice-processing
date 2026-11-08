# Original developer wrapper. All pulse locations come from the pinned executable.
form Pulse reference with injected F0
    sentence Input
    sentence Pitch_file
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
appendInfoLine: "begin", tab$, "pulse-reference-v1"
appendInfoLine: "input", tab$, rate, tab$, samples
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
for i from 1 to count
    time = Get time from index: i
    appendInfoLine: "pulse", tab$, i, tab$, time
endfor
appendInfoLine: "end", tab$, "pulse-reference-v1"
