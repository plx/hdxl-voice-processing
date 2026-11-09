# Original numerical query wrapper; no external implementation code.
Create empty PointProcess: "jitter", 0.0, 0.15466238400126303
Add point: 0.0
Add point: 0.004857127714150754
Add point: 0.010059269001146525
Add point: 0.014206022864567455
Add point: 0.018010641726855695
Add point: 0.022507045656093395
Add point: 0.026905649994891558
Add point: 0.031213705238293515
Add point: 0.03542510974750092
Add point: 0.039573179066064765
Add point: 0.04389486060070339
Add point: 0.047817776738560164
Add point: 0.052677705462662164
Add point: 0.05727639038957105
Add point: 0.06140718881532931
Add point: 0.06562329585388811
Add point: 0.06997630653267896
Add point: 0.07522471082634928
Add point: 0.0805299223709153
Add point: 0.08565170381906104
Add point: 0.09088315037470734
Add point: 0.09551856840764893
Add point: 0.09941359498966698
Add point: 0.10413786399389872
Add point: 0.10860496824586088
Add point: 0.11386734641797376
Add point: 0.11836075438922061
Add point: 0.12341238400126302
appendInfoLine: "begin", tab$, "jitter-reference-v1"
count = Get number of points
appendInfoLine: "count", tab$, count
for i from 1 to count
    time = Get time from index: i
    appendInfoLine: "point", tab$, i, tab$, time
endfor
value = Get number of periods: 0.0, 0.15466238400126303, 0.0001, 0.02, 1.3
appendInfoLine: "periodCount", tab$, value
value = Get mean period: 0.0, 0.15466238400126303, 0.0001, 0.02, 1.3
appendInfoLine: "meanPeriod", tab$, value
value = Get jitter (local): 0.0, 0.15466238400126303, 0.0001, 0.02, 1.3
appendInfoLine: "local", tab$, value
value = Get jitter (local, absolute): 0.0, 0.15466238400126303, 0.0001, 0.02, 1.3
appendInfoLine: "absolute", tab$, value
value = Get jitter (rap): 0.0, 0.15466238400126303, 0.0001, 0.02, 1.3
appendInfoLine: "rap", tab$, value
value = Get jitter (ppq5): 0.0, 0.15466238400126303, 0.0001, 0.02, 1.3
appendInfoLine: "ppq5", tab$, value
value = Get jitter (ddp): 0.0, 0.15466238400126303, 0.0001, 0.02, 1.3
appendInfoLine: "ddp", tab$, value
appendInfoLine: "end", tab$, "jitter-reference-v1"
