# Original query wrapper; no external implementation source.
Create AmplitudeTier: "shimmer", 0.0, 0.064453125
Add point: 0.001953125, 1.0
Add point: 0.005859375, 1.25
Add point: 0.009765625, 1.0
Add point: 0.013671875, 1.25
Add point: 0.017578125, 1.0
Add point: 0.021484375, 1.25
Add point: 0.025390625, 1.0
Add point: 0.029296875, 1.25
Add point: 0.033203125, 1.0
Add point: 0.037109375, 1.25
Add point: 0.041015625, 1.0
Add point: 0.044921875, 1.25
Add point: 0.048828125, 1.0
appendInfoLine: "begin", tab$, "shimmer-reference-v1"
count = Get number of points
appendInfoLine: "count", tab$, count
for i from 1 to count
    time = Get time from index: i
    amplitude = Get value at index: i
    appendInfoLine: "amplitude", tab$, i, tab$, time, tab$, amplitude
endfor
value = Get shimmer (local): 0.0009765625, 0.015625, 1.6
appendInfoLine: "local", tab$, value
value = Get shimmer (local_dB): 0.0009765625, 0.015625, 1.6
appendInfoLine: "db", tab$, value
value = Get shimmer (apq3): 0.0009765625, 0.015625, 1.6
appendInfoLine: "apq3", tab$, value
value = Get shimmer (apq5): 0.0009765625, 0.015625, 1.6
appendInfoLine: "apq5", tab$, value
value = Get shimmer (apq11): 0.0009765625, 0.015625, 1.6
appendInfoLine: "apq11", tab$, value
value = Get shimmer (dda): 0.0009765625, 0.015625, 1.6
appendInfoLine: "dda", tab$, value
appendInfoLine: "end", tab$, "shimmer-reference-v1"
