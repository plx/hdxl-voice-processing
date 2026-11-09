# Original numerical query wrapper; no external implementation code.
Create empty PointProcess: "jitter", 0.0, 0.13397319792905668
Add point: 0.0
Add point: 0.009039338011352812
Add point: 0.017581216636560083
Add point: 0.025455038022094718
Add point: 0.03493532664860444
Add point: 0.04346656599208169
Add point: 0.05198996572881394
Add point: 0.06045861488887264
Add point: 0.06939029318940206
Add point: 0.07856868015631335
Add point: 0.0854899764417011
Add point: 0.0931279430728561
Add point: 0.10272319792905668
appendInfoLine: "begin", tab$, "jitter-reference-v1"
count = Get number of points
appendInfoLine: "count", tab$, count
for i from 1 to count
    time = Get time from index: i
    appendInfoLine: "point", tab$, i, tab$, time
endfor
value = Get number of periods: 0.0, 0.13397319792905668, 0.0001, 0.02, 1.3
appendInfoLine: "periodCount", tab$, value
value = Get mean period: 0.0, 0.13397319792905668, 0.0001, 0.02, 1.3
appendInfoLine: "meanPeriod", tab$, value
value = Get jitter (local): 0.0, 0.13397319792905668, 0.0001, 0.02, 1.3
appendInfoLine: "local", tab$, value
value = Get jitter (local, absolute): 0.0, 0.13397319792905668, 0.0001, 0.02, 1.3
appendInfoLine: "absolute", tab$, value
value = Get jitter (rap): 0.0, 0.13397319792905668, 0.0001, 0.02, 1.3
appendInfoLine: "rap", tab$, value
value = Get jitter (ppq5): 0.0, 0.13397319792905668, 0.0001, 0.02, 1.3
appendInfoLine: "ppq5", tab$, value
value = Get jitter (ddp): 0.0, 0.13397319792905668, 0.0001, 0.02, 1.3
appendInfoLine: "ddp", tab$, value
appendInfoLine: "end", tab$, "jitter-reference-v1"
