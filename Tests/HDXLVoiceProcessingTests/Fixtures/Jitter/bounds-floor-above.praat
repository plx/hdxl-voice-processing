# Original numerical query wrapper; no external implementation code.
Create empty PointProcess: "jitter", 0.0, 0.125
Add point: 0.0
Add point: 0.0078125
Add point: 0.01953125
Add point: 0.02734375
Add point: 0.0390625
Add point: 0.046875
appendInfoLine: "begin", tab$, "jitter-reference-v1"
count = Get number of points
appendInfoLine: "count", tab$, count
for i from 1 to count
    time = Get time from index: i
    appendInfoLine: "point", tab$, i, tab$, time
endfor
value = Get number of periods: 0.0, 0.125, 0.007812500000000002, 0.01171875, 1.5
appendInfoLine: "periodCount", tab$, value
value = Get mean period: 0.0, 0.125, 0.007812500000000002, 0.01171875, 1.5
appendInfoLine: "meanPeriod", tab$, value
value = Get jitter (local): 0.0, 0.125, 0.007812500000000002, 0.01171875, 1.5
appendInfoLine: "local", tab$, value
value = Get jitter (local, absolute): 0.0, 0.125, 0.007812500000000002, 0.01171875, 1.5
appendInfoLine: "absolute", tab$, value
value = Get jitter (rap): 0.0, 0.125, 0.007812500000000002, 0.01171875, 1.5
appendInfoLine: "rap", tab$, value
value = Get jitter (ppq5): 0.0, 0.125, 0.007812500000000002, 0.01171875, 1.5
appendInfoLine: "ppq5", tab$, value
value = Get jitter (ddp): 0.0, 0.125, 0.007812500000000002, 0.01171875, 1.5
appendInfoLine: "ddp", tab$, value
appendInfoLine: "end", tab$, "jitter-reference-v1"
