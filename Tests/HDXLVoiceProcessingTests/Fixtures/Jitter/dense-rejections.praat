# Original numerical query wrapper; no external implementation code.
Create empty PointProcess: "jitter", 0.0, 0.25
Add point: 0.0
Add point: 0.00390625
Add point: 0.01171875
Add point: 0.02734375
Add point: 0.03125
Add point: 0.0390625
Add point: 0.0546875
Add point: 0.05859375
Add point: 0.06640625
Add point: 0.08203125
Add point: 0.0859375
Add point: 0.09375
Add point: 0.109375
Add point: 0.11328125
Add point: 0.12109375
Add point: 0.13671875
Add point: 0.140625
Add point: 0.1484375
Add point: 0.1640625
Add point: 0.16796875
Add point: 0.17578125
Add point: 0.19140625
Add point: 0.1953125
Add point: 0.203125
Add point: 0.21875
appendInfoLine: "begin", tab$, "jitter-reference-v1"
count = Get number of points
appendInfoLine: "count", tab$, count
for i from 1 to count
    time = Get time from index: i
    appendInfoLine: "point", tab$, i, tab$, time
endfor
value = Get number of periods: 0.0, 0.25, 0.001953125, 0.03125, 1.3
appendInfoLine: "periodCount", tab$, value
value = Get mean period: 0.0, 0.25, 0.001953125, 0.03125, 1.3
appendInfoLine: "meanPeriod", tab$, value
value = Get jitter (local): 0.0, 0.25, 0.001953125, 0.03125, 1.3
appendInfoLine: "local", tab$, value
value = Get jitter (local, absolute): 0.0, 0.25, 0.001953125, 0.03125, 1.3
appendInfoLine: "absolute", tab$, value
value = Get jitter (rap): 0.0, 0.25, 0.001953125, 0.03125, 1.3
appendInfoLine: "rap", tab$, value
value = Get jitter (ppq5): 0.0, 0.25, 0.001953125, 0.03125, 1.3
appendInfoLine: "ppq5", tab$, value
value = Get jitter (ddp): 0.0, 0.25, 0.001953125, 0.03125, 1.3
appendInfoLine: "ddp", tab$, value
appendInfoLine: "end", tab$, "jitter-reference-v1"
