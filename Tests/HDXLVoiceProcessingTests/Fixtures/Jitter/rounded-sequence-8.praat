# Original numerical query wrapper; no external implementation code.
Create empty PointProcess: "jitter", 0.0, 0.15478349779087391
Add point: 0.0
Add point: 0.004850918595523885
Add point: 0.008387065448769136
Add point: 0.012738895961423018
Add point: 0.01710057028986436
Add point: 0.02090638491101951
Add point: 0.024832928981195435
Add point: 0.02907060435900348
Add point: 0.03289811608983048
Add point: 0.03658113670089126
Add point: 0.04097469511155698
Add point: 0.0449658075942716
Add point: 0.048690363944139475
Add point: 0.05223456023290054
Add point: 0.05590637603323556
Add point: 0.06023736115181235
Add point: 0.06504445931214527
Add point: 0.06982905326372321
Add point: 0.07454556933065758
Add point: 0.07879614905682196
Add point: 0.08244244195588785
Add point: 0.0859745253899018
Add point: 0.09041345993750532
Add point: 0.09411890881102103
Add point: 0.09758269666946336
Add point: 0.102328702842157
Add point: 0.10609757152526676
Add point: 0.11050325725630196
Add point: 0.11447230773560779
Add point: 0.11919064006680855
Add point: 0.1235334977908739
appendInfoLine: "begin", tab$, "jitter-reference-v1"
count = Get number of points
appendInfoLine: "count", tab$, count
for i from 1 to count
    time = Get time from index: i
    appendInfoLine: "point", tab$, i, tab$, time
endfor
value = Get number of periods: 0.0, 0.15478349779087391, 0.0001, 0.02, 1.3
appendInfoLine: "periodCount", tab$, value
value = Get mean period: 0.0, 0.15478349779087391, 0.0001, 0.02, 1.3
appendInfoLine: "meanPeriod", tab$, value
value = Get jitter (local): 0.0, 0.15478349779087391, 0.0001, 0.02, 1.3
appendInfoLine: "local", tab$, value
value = Get jitter (local, absolute): 0.0, 0.15478349779087391, 0.0001, 0.02, 1.3
appendInfoLine: "absolute", tab$, value
value = Get jitter (rap): 0.0, 0.15478349779087391, 0.0001, 0.02, 1.3
appendInfoLine: "rap", tab$, value
value = Get jitter (ppq5): 0.0, 0.15478349779087391, 0.0001, 0.02, 1.3
appendInfoLine: "ppq5", tab$, value
value = Get jitter (ddp): 0.0, 0.15478349779087391, 0.0001, 0.02, 1.3
appendInfoLine: "ddp", tab$, value
appendInfoLine: "end", tab$, "jitter-reference-v1"
