# Original numerical query wrapper; no external implementation code.
Create empty PointProcess: "jitter", 0.0, 0.2113271129041677
Add point: 0.0
Add point: 0.018791569880442692
Add point: 0.02291849980165716
Add point: 0.02860872826777631
Add point: 0.03355941420100862
Add point: 0.03822554666001815
Add point: 0.04276999845355749
Add point: 0.04830475847230991
Add point: 0.06863808978436281
Add point: 0.07337675745249725
Add point: 0.07859017788327764
Add point: 0.0828958415617817
Add point: 0.08839342248631873
Add point: 0.09319495644338895
Add point: 0.0979179676794447
Add point: 0.12068122630589642
Add point: 0.12486064389394597
Add point: 0.13058451101678656
Add point: 0.13492027622222666
Add point: 0.1391619803762296
Add point: 0.14368204108218194
Add point: 0.14789173536392625
Add point: 0.1700414929312537
Add point: 0.17425830082281024
Add point: 0.1800771129041677
appendInfoLine: "begin", tab$, "jitter-reference-v1"
count = Get number of points
appendInfoLine: "count", tab$, count
for i from 1 to count
    time = Get time from index: i
    appendInfoLine: "point", tab$, i, tab$, time
endfor
value = Get number of periods: 0.0, 0.2113271129041677, 0.0001, 0.02, 1.3
appendInfoLine: "periodCount", tab$, value
value = Get mean period: 0.0, 0.2113271129041677, 0.0001, 0.02, 1.3
appendInfoLine: "meanPeriod", tab$, value
value = Get jitter (local): 0.0, 0.2113271129041677, 0.0001, 0.02, 1.3
appendInfoLine: "local", tab$, value
value = Get jitter (local, absolute): 0.0, 0.2113271129041677, 0.0001, 0.02, 1.3
appendInfoLine: "absolute", tab$, value
value = Get jitter (rap): 0.0, 0.2113271129041677, 0.0001, 0.02, 1.3
appendInfoLine: "rap", tab$, value
value = Get jitter (ppq5): 0.0, 0.2113271129041677, 0.0001, 0.02, 1.3
appendInfoLine: "ppq5", tab$, value
value = Get jitter (ddp): 0.0, 0.2113271129041677, 0.0001, 0.02, 1.3
appendInfoLine: "ddp", tab$, value
appendInfoLine: "end", tab$, "jitter-reference-v1"
