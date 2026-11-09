# Original query wrapper; no external implementation source.
Create AmplitudeTier: "shimmer", 0.0, 0.125
Add point: 0.00390625, 2.5081465439870954
Add point: 0.01610786749602994, 0.7612939968239516
Add point: 0.028765531697135888, 1.1261313608847558
Add point: 0.04131496253598016, 1.0395446710754186
Add point: 0.05422707476594951, 1.329689783975482
Add point: 0.0668817494684481, 1.123739761998877
Add point: 0.07958601091027959, 1.1634091534651816
appendInfoLine: "begin", tab$, "shimmer-reference-v1"
count = Get number of points
appendInfoLine: "count", tab$, count
for i from 1 to count
    time = Get time from index: i
    amplitude = Get value at index: i
    appendInfoLine: "amplitude", tab$, i, tab$, time, tab$, amplitude
endfor
value = Get shimmer (local): 0.0001, 0.02, 1.6
appendInfoLine: "local", tab$, value
value = Get shimmer (local_dB): 0.0001, 0.02, 1.6
appendInfoLine: "db", tab$, value
value = Get shimmer (apq3): 0.0001, 0.02, 1.6
appendInfoLine: "apq3", tab$, value
value = Get shimmer (apq5): 0.0001, 0.02, 1.6
appendInfoLine: "apq5", tab$, value
value = Get shimmer (apq11): 0.0001, 0.02, 1.6
appendInfoLine: "apq11", tab$, value
value = Get shimmer (dda): 0.0001, 0.02, 1.6
appendInfoLine: "dda", tab$, value
appendInfoLine: "end", tab$, "shimmer-reference-v1"
