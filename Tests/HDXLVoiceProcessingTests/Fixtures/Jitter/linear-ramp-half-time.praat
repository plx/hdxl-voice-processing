# Original numerical query wrapper; no external implementation code.
Create empty PointProcess: "jitter", 0.0, 0.07861328125
Add point: 0.0
Add point: 0.00390625
Add point: 0.008056640625
Add point: 0.012451171875
Add point: 0.01708984375
Add point: 0.02197265625
Add point: 0.027099609375
Add point: 0.032470703125
Add point: 0.0380859375
Add point: 0.0439453125
Add point: 0.050048828125
Add point: 0.056396484375
Add point: 0.06298828125
appendInfoLine: "begin", tab$, "jitter-reference-v1"
count = Get number of points
appendInfoLine: "count", tab$, count
for i from 1 to count
    time = Get time from index: i
    appendInfoLine: "point", tab$, i, tab$, time
endfor
value = Get number of periods: 0.0, 0.07861328125, 0.0009765625, 0.015625, 1.3
appendInfoLine: "periodCount", tab$, value
value = Get mean period: 0.0, 0.07861328125, 0.0009765625, 0.015625, 1.3
appendInfoLine: "meanPeriod", tab$, value
value = Get jitter (local): 0.0, 0.07861328125, 0.0009765625, 0.015625, 1.3
appendInfoLine: "local", tab$, value
value = Get jitter (local, absolute): 0.0, 0.07861328125, 0.0009765625, 0.015625, 1.3
appendInfoLine: "absolute", tab$, value
value = Get jitter (rap): 0.0, 0.07861328125, 0.0009765625, 0.015625, 1.3
appendInfoLine: "rap", tab$, value
value = Get jitter (ppq5): 0.0, 0.07861328125, 0.0009765625, 0.015625, 1.3
appendInfoLine: "ppq5", tab$, value
value = Get jitter (ddp): 0.0, 0.07861328125, 0.0009765625, 0.015625, 1.3
appendInfoLine: "ddp", tab$, value
appendInfoLine: "end", tab$, "jitter-reference-v1"
