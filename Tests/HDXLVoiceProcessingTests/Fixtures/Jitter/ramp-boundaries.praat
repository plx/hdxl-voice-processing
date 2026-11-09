# Original numerical query wrapper; no external implementation code.
Create empty PointProcess: "jitter", 0.0, 0.40234375
Add point: 0.0
Add point: 0.001953125
Add point: 0.005859375
Add point: 0.01171875
Add point: 0.01953125
Add point: 0.029296875
Add point: 0.041015625
Add point: 0.0546875
Add point: 0.0703125
Add point: 0.087890625
Add point: 0.107421875
Add point: 0.12890625
Add point: 0.15234375
Add point: 0.177734375
Add point: 0.205078125
Add point: 0.234375
Add point: 0.265625
Add point: 0.298828125
Add point: 0.333984375
Add point: 0.37109375
appendInfoLine: "begin", tab$, "jitter-reference-v1"
count = Get number of points
appendInfoLine: "count", tab$, count
for i from 1 to count
    time = Get time from index: i
    appendInfoLine: "point", tab$, i, tab$, time
endfor
value = Get number of periods: 0.0, 0.40234375, 0.001953125, 0.03125, 1.3
appendInfoLine: "periodCount", tab$, value
value = Get mean period: 0.0, 0.40234375, 0.001953125, 0.03125, 1.3
appendInfoLine: "meanPeriod", tab$, value
value = Get jitter (local): 0.0, 0.40234375, 0.001953125, 0.03125, 1.3
appendInfoLine: "local", tab$, value
value = Get jitter (local, absolute): 0.0, 0.40234375, 0.001953125, 0.03125, 1.3
appendInfoLine: "absolute", tab$, value
value = Get jitter (rap): 0.0, 0.40234375, 0.001953125, 0.03125, 1.3
appendInfoLine: "rap", tab$, value
value = Get jitter (ppq5): 0.0, 0.40234375, 0.001953125, 0.03125, 1.3
appendInfoLine: "ppq5", tab$, value
value = Get jitter (ddp): 0.0, 0.40234375, 0.001953125, 0.03125, 1.3
appendInfoLine: "ddp", tab$, value
appendInfoLine: "end", tab$, "jitter-reference-v1"
