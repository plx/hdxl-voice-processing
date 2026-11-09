# Original numerical query wrapper; no external implementation code.
Create empty PointProcess: "jitter", 0.0, 0.16087091635700365
Add point: 0.0
Add point: 0.0031918583902092105
Add point: 0.005786538406802506
Add point: 0.008578287157442365
Add point: 0.011028104178155498
Add point: 0.01412398844183532
Add point: 0.016709236542605244
Add point: 0.01940012292734429
Add point: 0.02274386830942924
Add point: 0.02562193558496587
Add point: 0.028296759342672024
Add point: 0.03087859574099317
Add point: 0.03397016945904503
Add point: 0.03654445618123966
Add point: 0.03904078715737662
Add point: 0.04166067620879723
Add point: 0.044638767960919604
Add point: 0.04761430413585484
Add point: 0.050297134648768824
Add point: 0.05355847747732802
Add point: 0.05620849023949737
Add point: 0.05923856897848
Add point: 0.06247105576888903
Add point: 0.06587710781505686
Add point: 0.06857873705667716
Add point: 0.07176456799977184
Add point: 0.07519931028449824
Add point: 0.07807909977208026
Add point: 0.08050716369118374
Add point: 0.08355100292144066
Add point: 0.08602405159087054
Add point: 0.08892707492118725
Add point: 0.0917260403224431
Add point: 0.09426534157780488
Add point: 0.09743043379258935
Add point: 0.09999814142291566
Add point: 0.10334334500866718
Add point: 0.1060849292044226
Add point: 0.10911432132340607
Add point: 0.11209771283371506
Add point: 0.11459442106061883
Add point: 0.11721646628232996
Add point: 0.12066449908310241
Add point: 0.12388168657633389
Add point: 0.1268133394360569
Add point: 0.12962091635700365
appendInfoLine: "begin", tab$, "jitter-reference-v1"
count = Get number of points
appendInfoLine: "count", tab$, count
for i from 1 to count
    time = Get time from index: i
    appendInfoLine: "point", tab$, i, tab$, time
endfor
value = Get number of periods: 0.0, 0.16087091635700365, 0.0001, 0.02, 1.3
appendInfoLine: "periodCount", tab$, value
value = Get mean period: 0.0, 0.16087091635700365, 0.0001, 0.02, 1.3
appendInfoLine: "meanPeriod", tab$, value
value = Get jitter (local): 0.0, 0.16087091635700365, 0.0001, 0.02, 1.3
appendInfoLine: "local", tab$, value
value = Get jitter (local, absolute): 0.0, 0.16087091635700365, 0.0001, 0.02, 1.3
appendInfoLine: "absolute", tab$, value
value = Get jitter (rap): 0.0, 0.16087091635700365, 0.0001, 0.02, 1.3
appendInfoLine: "rap", tab$, value
value = Get jitter (ppq5): 0.0, 0.16087091635700365, 0.0001, 0.02, 1.3
appendInfoLine: "ppq5", tab$, value
value = Get jitter (ddp): 0.0, 0.16087091635700365, 0.0001, 0.02, 1.3
appendInfoLine: "ddp", tab$, value
appendInfoLine: "end", tab$, "jitter-reference-v1"
