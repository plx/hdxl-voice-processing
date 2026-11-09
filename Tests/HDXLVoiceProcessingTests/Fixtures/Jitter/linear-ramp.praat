# Original numerical query wrapper; no external implementation code.
Create empty PointProcess: "jitter", 0.0, 0.1572265625
Add point: 0.0
Add point: 0.0078125
Add point: 0.01611328125
Add point: 0.02490234375
Add point: 0.0341796875
Add point: 0.0439453125
Add point: 0.05419921875
Add point: 0.06494140625
Add point: 0.076171875
Add point: 0.087890625
Add point: 0.10009765625
Add point: 0.11279296875
Add point: 0.1259765625
appendInfoLine: "begin", tab$, "jitter-reference-v1"
count = Get number of points
appendInfoLine: "count", tab$, count
for i from 1 to count
    time = Get time from index: i
    appendInfoLine: "point", tab$, i, tab$, time
endfor
value = Get number of periods: 0.0, 0.1572265625, 0.001953125, 0.03125, 1.3
appendInfoLine: "periodCount", tab$, value
value = Get mean period: 0.0, 0.1572265625, 0.001953125, 0.03125, 1.3
appendInfoLine: "meanPeriod", tab$, value
value = Get jitter (local): 0.0, 0.1572265625, 0.001953125, 0.03125, 1.3
appendInfoLine: "local", tab$, value
value = Get jitter (local, absolute): 0.0, 0.1572265625, 0.001953125, 0.03125, 1.3
appendInfoLine: "absolute", tab$, value
value = Get jitter (rap): 0.0, 0.1572265625, 0.001953125, 0.03125, 1.3
appendInfoLine: "rap", tab$, value
value = Get jitter (ppq5): 0.0, 0.1572265625, 0.001953125, 0.03125, 1.3
appendInfoLine: "ppq5", tab$, value
value = Get jitter (ddp): 0.0, 0.1572265625, 0.001953125, 0.03125, 1.3
appendInfoLine: "ddp", tab$, value
appendInfoLine: "end", tab$, "jitter-reference-v1"
