# Original numerical query wrapper; no external implementation code.
Create empty PointProcess: "jitter", 0.0, 0.42431640625
Add point: 0.0
Add point: 0.0078125
Add point: 0.01611328125
Add point: 0.07861328125
Add point: 0.08642578125
Add point: 0.0947265625
Add point: 0.1572265625
Add point: 0.1650390625
Add point: 0.17333984375
Add point: 0.23583984375
Add point: 0.24365234375
Add point: 0.251953125
Add point: 0.314453125
Add point: 0.322265625
Add point: 0.33056640625
Add point: 0.39306640625
appendInfoLine: "begin", tab$, "jitter-reference-v1"
count = Get number of points
appendInfoLine: "count", tab$, count
for i from 1 to count
    time = Get time from index: i
    appendInfoLine: "point", tab$, i, tab$, time
endfor
value = Get number of periods: 0.0, 0.42431640625, 0.001953125, 0.03125, 1.3
appendInfoLine: "periodCount", tab$, value
value = Get mean period: 0.0, 0.42431640625, 0.001953125, 0.03125, 1.3
appendInfoLine: "meanPeriod", tab$, value
value = Get jitter (local): 0.0, 0.42431640625, 0.001953125, 0.03125, 1.3
appendInfoLine: "local", tab$, value
value = Get jitter (local, absolute): 0.0, 0.42431640625, 0.001953125, 0.03125, 1.3
appendInfoLine: "absolute", tab$, value
value = Get jitter (rap): 0.0, 0.42431640625, 0.001953125, 0.03125, 1.3
appendInfoLine: "rap", tab$, value
value = Get jitter (ppq5): 0.0, 0.42431640625, 0.001953125, 0.03125, 1.3
appendInfoLine: "ppq5", tab$, value
value = Get jitter (ddp): 0.0, 0.42431640625, 0.001953125, 0.03125, 1.3
appendInfoLine: "ddp", tab$, value
appendInfoLine: "end", tab$, "jitter-reference-v1"
