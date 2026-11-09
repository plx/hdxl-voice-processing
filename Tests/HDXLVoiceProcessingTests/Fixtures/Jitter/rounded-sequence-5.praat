# Original numerical query wrapper; no external implementation code.
Create empty PointProcess: "jitter", 0.0, 0.15126828509499318
Add point: 0.0
Add point: 0.00626764652164032
Add point: 0.011053100934627259
Add point: 0.01613001018756121
Add point: 0.022018826686026942
Add point: 0.028371067528949225
Add point: 0.033630264906872376
Add point: 0.039882551277017536
Add point: 0.044811838202747624
Add point: 0.05103535458109239
Add point: 0.05731626217492805
Add point: 0.06215457920625341
Add point: 0.068381278218003
Add point: 0.0736239428703104
Add point: 0.07851890148303937
Add point: 0.0838516641147564
Add point: 0.08991913285882523
Add point: 0.09573381951492695
Add point: 0.1016657549391837
Add point: 0.10721461475768593
Add point: 0.11356302823341038
Add point: 0.1200182850949932
appendInfoLine: "begin", tab$, "jitter-reference-v1"
count = Get number of points
appendInfoLine: "count", tab$, count
for i from 1 to count
    time = Get time from index: i
    appendInfoLine: "point", tab$, i, tab$, time
endfor
value = Get number of periods: 0.0, 0.15126828509499318, 0.0001, 0.02, 1.3
appendInfoLine: "periodCount", tab$, value
value = Get mean period: 0.0, 0.15126828509499318, 0.0001, 0.02, 1.3
appendInfoLine: "meanPeriod", tab$, value
value = Get jitter (local): 0.0, 0.15126828509499318, 0.0001, 0.02, 1.3
appendInfoLine: "local", tab$, value
value = Get jitter (local, absolute): 0.0, 0.15126828509499318, 0.0001, 0.02, 1.3
appendInfoLine: "absolute", tab$, value
value = Get jitter (rap): 0.0, 0.15126828509499318, 0.0001, 0.02, 1.3
appendInfoLine: "rap", tab$, value
value = Get jitter (ppq5): 0.0, 0.15126828509499318, 0.0001, 0.02, 1.3
appendInfoLine: "ppq5", tab$, value
value = Get jitter (ddp): 0.0, 0.15126828509499318, 0.0001, 0.02, 1.3
appendInfoLine: "ddp", tab$, value
appendInfoLine: "end", tab$, "jitter-reference-v1"
