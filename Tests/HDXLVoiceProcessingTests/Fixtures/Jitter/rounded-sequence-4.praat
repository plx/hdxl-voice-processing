# Original numerical query wrapper; no external implementation code.
Create empty PointProcess: "jitter", 0.0, 0.14763466699492708
Add point: 0.0
Add point: 0.00599836186695029
Add point: 0.012926345989471883
Add point: 0.018714284935049362
Add point: 0.025179070980375397
Add point: 0.0324375659917132
Add point: 0.03873771173377463
Add point: 0.045907915228672214
Add point: 0.05158415831014282
Add point: 0.0574907418548537
Add point: 0.06335690042942588
Add point: 0.07053713888170023
Add point: 0.07590080953857978
Add point: 0.08312985066033433
Add point: 0.08894443786404735
Add point: 0.09616359696512516
Add point: 0.10310771721589843
Add point: 0.10975953427856437
Add point: 0.11638466699492708
appendInfoLine: "begin", tab$, "jitter-reference-v1"
count = Get number of points
appendInfoLine: "count", tab$, count
for i from 1 to count
    time = Get time from index: i
    appendInfoLine: "point", tab$, i, tab$, time
endfor
value = Get number of periods: 0.0, 0.14763466699492708, 0.0001, 0.02, 1.3
appendInfoLine: "periodCount", tab$, value
value = Get mean period: 0.0, 0.14763466699492708, 0.0001, 0.02, 1.3
appendInfoLine: "meanPeriod", tab$, value
value = Get jitter (local): 0.0, 0.14763466699492708, 0.0001, 0.02, 1.3
appendInfoLine: "local", tab$, value
value = Get jitter (local, absolute): 0.0, 0.14763466699492708, 0.0001, 0.02, 1.3
appendInfoLine: "absolute", tab$, value
value = Get jitter (rap): 0.0, 0.14763466699492708, 0.0001, 0.02, 1.3
appendInfoLine: "rap", tab$, value
value = Get jitter (ppq5): 0.0, 0.14763466699492708, 0.0001, 0.02, 1.3
appendInfoLine: "ppq5", tab$, value
value = Get jitter (ddp): 0.0, 0.14763466699492708, 0.0001, 0.02, 1.3
appendInfoLine: "ddp", tab$, value
appendInfoLine: "end", tab$, "jitter-reference-v1"
