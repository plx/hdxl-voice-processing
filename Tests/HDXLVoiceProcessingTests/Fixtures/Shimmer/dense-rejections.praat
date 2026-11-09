# Original query wrapper; no external implementation source.
Create AmplitudeTier: "shimmer", 0.0, 0.23828125
Add point: 0.00390625, 1.0
Add point: 0.01171875, 2.0
Add point: 0.01953125, 4.0
Add point: 0.02734375, 1.0
Add point: 0.03515625, 2.0
Add point: 0.04296875, 4.0
Add point: 0.05078125, 1.0
Add point: 0.05859375, 2.0
Add point: 0.06640625, 4.0
Add point: 0.07421875, 1.0
Add point: 0.08203125, 2.0
Add point: 0.08984375, 4.0
Add point: 0.09765625, 1.0
Add point: 0.10546875, 2.0
Add point: 0.11328125, 4.0
Add point: 0.12109375, 1.0
Add point: 0.12890625, 2.0
Add point: 0.13671875, 4.0
Add point: 0.14453125, 1.0
Add point: 0.15234375, 2.0
Add point: 0.16015625, 4.0
Add point: 0.16796875, 1.0
Add point: 0.17578125, 2.0
Add point: 0.18359375, 4.0
Add point: 0.19140625, 1.0
Add point: 0.19921875, 2.0
Add point: 0.20703125, 4.0
appendInfoLine: "begin", tab$, "shimmer-reference-v1"
count = Get number of points
appendInfoLine: "count", tab$, count
for i from 1 to count
    time = Get time from index: i
    amplitude = Get value at index: i
    appendInfoLine: "amplitude", tab$, i, tab$, time, tab$, amplitude
endfor
value = Get shimmer (local): 0.001953125, 0.03125, 1.6
appendInfoLine: "local", tab$, value
value = Get shimmer (local_dB): 0.001953125, 0.03125, 1.6
appendInfoLine: "db", tab$, value
value = Get shimmer (apq3): 0.001953125, 0.03125, 1.6
appendInfoLine: "apq3", tab$, value
value = Get shimmer (apq5): 0.001953125, 0.03125, 1.6
appendInfoLine: "apq5", tab$, value
value = Get shimmer (apq11): 0.001953125, 0.03125, 1.6
appendInfoLine: "apq11", tab$, value
value = Get shimmer (dda): 0.001953125, 0.03125, 1.6
appendInfoLine: "dda", tab$, value
appendInfoLine: "end", tab$, "shimmer-reference-v1"
