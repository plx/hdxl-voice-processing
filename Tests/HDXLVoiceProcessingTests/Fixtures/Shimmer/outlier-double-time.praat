# Original query wrapper; no external implementation source.
Create AmplitudeTier: "shimmer", 0.0, 0.2578125
Add point: 0.0078125, 1.0
Add point: 0.0234375, 1.0
Add point: 0.0390625, 1.0
Add point: 0.0546875, 1.0
Add point: 0.0703125, 1.0
Add point: 0.0859375, 1.0
Add point: 0.1015625, 8.0
Add point: 0.1171875, 1.0
Add point: 0.1328125, 1.0
Add point: 0.1484375, 1.0
Add point: 0.1640625, 1.0
Add point: 0.1796875, 1.0
Add point: 0.1953125, 1.0
appendInfoLine: "begin", tab$, "shimmer-reference-v1"
count = Get number of points
appendInfoLine: "count", tab$, count
for i from 1 to count
    time = Get time from index: i
    amplitude = Get value at index: i
    appendInfoLine: "amplitude", tab$, i, tab$, time, tab$, amplitude
endfor
value = Get shimmer (local): 0.00390625, 0.0625, 1.6
appendInfoLine: "local", tab$, value
value = Get shimmer (local_dB): 0.00390625, 0.0625, 1.6
appendInfoLine: "db", tab$, value
value = Get shimmer (apq3): 0.00390625, 0.0625, 1.6
appendInfoLine: "apq3", tab$, value
value = Get shimmer (apq5): 0.00390625, 0.0625, 1.6
appendInfoLine: "apq5", tab$, value
value = Get shimmer (apq11): 0.00390625, 0.0625, 1.6
appendInfoLine: "apq11", tab$, value
value = Get shimmer (dda): 0.00390625, 0.0625, 1.6
appendInfoLine: "dda", tab$, value
appendInfoLine: "end", tab$, "shimmer-reference-v1"
