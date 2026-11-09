# Original numerical query wrapper; no external implementation code.
Create empty PointProcess: "jitter", 0.0, 0.1687715254411729
Add point: 0.0
Add point: 0.0021560112298618112
Add point: 0.004428013896888487
Add point: 0.006694789496351682
Add point: 0.008920407254582919
Add point: 0.010825130997615381
Add point: 0.01314094512857517
Add point: 0.015141245733956685
Add point: 0.017316470118745677
Add point: 0.019495612731906992
Add point: 0.02148992374435614
Add point: 0.023511885424225554
Add point: 0.025761034819854263
Add point: 0.027860149765999626
Add point: 0.03028028191899901
Add point: 0.03267100059402013
Add point: 0.03450533097711108
Add point: 0.036944123246459
Add point: 0.039347615665832086
Add point: 0.04165963305939879
Add point: 0.04367823314250689
Add point: 0.04590031602422443
Add point: 0.04771905862718678
Add point: 0.04956030625571577
Add point: 0.05168793084211242
Add point: 0.053682219658791004
Add point: 0.0560413750309406
Add point: 0.0580124714444189
Add point: 0.06027582029705746
Add point: 0.06207394064963371
Add point: 0.06429429912294322
Add point: 0.06655300593241523
Add point: 0.06894552882963224
Add point: 0.07080063592204723
Add point: 0.0727871679503258
Add point: 0.07497376398335251
Add point: 0.07739351556864162
Add point: 0.07936324455109728
Add point: 0.08126434002286734
Add point: 0.08325367023059896
Add point: 0.08579731163335964
Add point: 0.08774807618563975
Add point: 0.08983755542307019
Add point: 0.09174920409735617
Add point: 0.09361229993195436
Add point: 0.09610339272132083
Add point: 0.09837779510951014
Add point: 0.10047522155542696
Add point: 0.10299668471025222
Add point: 0.10532973933668868
Add point: 0.1076092515058522
Add point: 0.11006485403242076
Add point: 0.11258348576932053
Add point: 0.1147767049195903
Add point: 0.11730155507661909
Add point: 0.11934097427717896
Add point: 0.12170018574860676
Add point: 0.12422384625885373
Add point: 0.12660993419949512
Add point: 0.1288406863845075
Add point: 0.13104019148006996
Add point: 0.13319986907190787
Add point: 0.1352882573830784
Add point: 0.1375215254411729
appendInfoLine: "begin", tab$, "jitter-reference-v1"
count = Get number of points
appendInfoLine: "count", tab$, count
for i from 1 to count
    time = Get time from index: i
    appendInfoLine: "point", tab$, i, tab$, time
endfor
value = Get number of periods: 0.0, 0.1687715254411729, 0.0001, 0.02, 1.3
appendInfoLine: "periodCount", tab$, value
value = Get mean period: 0.0, 0.1687715254411729, 0.0001, 0.02, 1.3
appendInfoLine: "meanPeriod", tab$, value
value = Get jitter (local): 0.0, 0.1687715254411729, 0.0001, 0.02, 1.3
appendInfoLine: "local", tab$, value
value = Get jitter (local, absolute): 0.0, 0.1687715254411729, 0.0001, 0.02, 1.3
appendInfoLine: "absolute", tab$, value
value = Get jitter (rap): 0.0, 0.1687715254411729, 0.0001, 0.02, 1.3
appendInfoLine: "rap", tab$, value
value = Get jitter (ppq5): 0.0, 0.1687715254411729, 0.0001, 0.02, 1.3
appendInfoLine: "ppq5", tab$, value
value = Get jitter (ddp): 0.0, 0.1687715254411729, 0.0001, 0.02, 1.3
appendInfoLine: "ddp", tab$, value
appendInfoLine: "end", tab$, "jitter-reference-v1"
