# Original wrapper for a separately identified reference F0 source.
form Reference F0 for pulse conformance
    sentence Input
endform
sound = Read from file: input$
rate = Get sampling frequency
samples = Get number of samples
hop = 0.005
floor = 75
ceiling = 700
candidates = 15
silence = 0.03
voicing = 0.45
octave = 0.01
jump = 0.35
transition = 0.14
pitch = To Pitch (raw cc): hop, floor, ceiling, candidates, "yes", silence, voicing, octave, jump, transition
frames = Get number of frames
first = Get time from frame number: 1
step = Get time step
start = Get start time
finish = Get end time
appendInfoLine: "begin", tab$, "pulse-f0-reference-v1"
appendInfoLine: "input", tab$, rate, tab$, samples
appendInfoLine: "settings", tab$, hop, tab$, floor, tab$, ceiling, tab$, candidates, tab$, 1, tab$, silence, tab$, voicing, tab$, octave, tab$, jump, tab$, transition
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
appendInfoLine: "end", tab$, "pulse-f0-reference-v1"
