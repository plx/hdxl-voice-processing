# Original numerical query wrapper; no external implementation code.
Create empty PointProcess: "jitter", 0.0, 0.21009886372843403
Add point: 0.0
Add point: 0.01374430400856699
Add point: 0.017892629733228554
Add point: 0.021818025065362096
Add point: 0.02522410537993822
Add point: 0.029646739782138658
Add point: 0.03337746165768924
Add point: 0.0373713001485717
Add point: 0.0523908875768449
Add point: 0.055668913769096925
Add point: 0.059457432799883046
Add point: 0.06268416664410885
Add point: 0.0661924719358705
Add point: 0.0701067945270244
Add point: 0.07419715725154115
Add point: 0.08721670519327746
Add point: 0.09137084173508742
Add point: 0.09543126638096651
Add point: 0.09927503977678359
Add point: 0.1028506498610995
Add point: 0.10631326037203859
Add point: 0.11050714968152955
Add point: 0.12388211436789091
Add point: 0.12747353958668942
Add point: 0.13158441321145245
Add point: 0.1359378403050897
Add point: 0.13948866065408
Add point: 0.14347092445433823
Add point: 0.1470177561990344
Add point: 0.16334363753513365
Add point: 0.16729993322788062
Add point: 0.1712826097435587
Add point: 0.17526611415955887
Add point: 0.17884886372843403
appendInfoLine: "begin", tab$, "jitter-reference-v1"
count = Get number of points
appendInfoLine: "count", tab$, count
for i from 1 to count
    time = Get time from index: i
    appendInfoLine: "point", tab$, i, tab$, time
endfor
value = Get number of periods: 0.0, 0.21009886372843403, 0.0001, 0.02, 1.3
appendInfoLine: "periodCount", tab$, value
value = Get mean period: 0.0, 0.21009886372843403, 0.0001, 0.02, 1.3
appendInfoLine: "meanPeriod", tab$, value
value = Get jitter (local): 0.0, 0.21009886372843403, 0.0001, 0.02, 1.3
appendInfoLine: "local", tab$, value
value = Get jitter (local, absolute): 0.0, 0.21009886372843403, 0.0001, 0.02, 1.3
appendInfoLine: "absolute", tab$, value
value = Get jitter (rap): 0.0, 0.21009886372843403, 0.0001, 0.02, 1.3
appendInfoLine: "rap", tab$, value
value = Get jitter (ppq5): 0.0, 0.21009886372843403, 0.0001, 0.02, 1.3
appendInfoLine: "ppq5", tab$, value
value = Get jitter (ddp): 0.0, 0.21009886372843403, 0.0001, 0.02, 1.3
appendInfoLine: "ddp", tab$, value
appendInfoLine: "end", tab$, "jitter-reference-v1"
