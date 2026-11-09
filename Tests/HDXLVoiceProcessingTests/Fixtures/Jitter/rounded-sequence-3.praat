# Original numerical query wrapper; no external implementation code.
Create empty PointProcess: "jitter", 0.0, 0.18958591345597858
Add point: 0.0
Add point: 0.024953310360267225
Add point: 0.033132479100687694
Add point: 0.039927440271463374
Add point: 0.04611753845412749
Add point: 0.052742350237344256
Add point: 0.061023121905080704
Add point: 0.06843067370779213
Add point: 0.09287755782541353
Add point: 0.09877134155332376
Add point: 0.10507835412913534
Add point: 0.11113341967766506
Add point: 0.11756289889146242
Add point: 0.12489855772183676
Add point: 0.1308604993697788
Add point: 0.15833591345597858
appendInfoLine: "begin", tab$, "jitter-reference-v1"
count = Get number of points
appendInfoLine: "count", tab$, count
for i from 1 to count
    time = Get time from index: i
    appendInfoLine: "point", tab$, i, tab$, time
endfor
value = Get number of periods: 0.0, 0.18958591345597858, 0.0001, 0.02, 1.3
appendInfoLine: "periodCount", tab$, value
value = Get mean period: 0.0, 0.18958591345597858, 0.0001, 0.02, 1.3
appendInfoLine: "meanPeriod", tab$, value
value = Get jitter (local): 0.0, 0.18958591345597858, 0.0001, 0.02, 1.3
appendInfoLine: "local", tab$, value
value = Get jitter (local, absolute): 0.0, 0.18958591345597858, 0.0001, 0.02, 1.3
appendInfoLine: "absolute", tab$, value
value = Get jitter (rap): 0.0, 0.18958591345597858, 0.0001, 0.02, 1.3
appendInfoLine: "rap", tab$, value
value = Get jitter (ppq5): 0.0, 0.18958591345597858, 0.0001, 0.02, 1.3
appendInfoLine: "ppq5", tab$, value
value = Get jitter (ddp): 0.0, 0.18958591345597858, 0.0001, 0.02, 1.3
appendInfoLine: "ddp", tab$, value
appendInfoLine: "end", tab$, "jitter-reference-v1"
