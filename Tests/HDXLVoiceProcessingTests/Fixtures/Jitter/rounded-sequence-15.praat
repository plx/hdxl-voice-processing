# Original numerical query wrapper; no external implementation code.
Create empty PointProcess: "jitter", 0.0, 0.23299341362367973
Add point: 0.0
Add point: 0.011328810181983404
Add point: 0.01388301953287354
Add point: 0.01652550412345016
Add point: 0.019063959433850343
Add point: 0.022001671168622318
Add point: 0.024607581410336456
Add point: 0.02704378587656385
Add point: 0.03665957227664828
Add point: 0.039644035018343286
Add point: 0.04257500697068233
Add point: 0.04506561567532021
Add point: 0.047710818285888405
Add point: 0.05025097375508937
Add point: 0.05275077652063613
Add point: 0.06146641908421818
Add point: 0.0638394393483912
Add point: 0.06679630350606441
Add point: 0.06961525922870924
Add point: 0.07250166247923563
Add point: 0.07545809700172149
Add point: 0.0778753845794065
Add point: 0.08906083014851901
Add point: 0.09154053239782928
Add point: 0.09406554923999416
Add point: 0.09702113213872315
Add point: 0.09938938582895053
Add point: 0.10221212152698027
Add point: 0.1052515260372801
Add point: 0.11581759318354
Add point: 0.11834312864426082
Add point: 0.12060489494062494
Add point: 0.12355099198460505
Add point: 0.12608213295063347
Add point: 0.12858446348041885
Add point: 0.130921722346347
Add point: 0.14294141938343133
Add point: 0.1458957241327306
Add point: 0.14838387728442048
Add point: 0.15133138807003366
Add point: 0.15378134710594746
Add point: 0.15640513781978949
Add point: 0.15936052674721735
Add point: 0.17051111615887896
Add point: 0.1729912902787328
Add point: 0.17529872894032836
Add point: 0.1782754049513575
Add point: 0.18105114689102936
Add point: 0.1840417628809442
Add point: 0.1871029648193048
Add point: 0.1987037507077912
Add point: 0.20174341362367973
appendInfoLine: "begin", tab$, "jitter-reference-v1"
count = Get number of points
appendInfoLine: "count", tab$, count
for i from 1 to count
    time = Get time from index: i
    appendInfoLine: "point", tab$, i, tab$, time
endfor
value = Get number of periods: 0.0, 0.23299341362367973, 0.0001, 0.02, 1.3
appendInfoLine: "periodCount", tab$, value
value = Get mean period: 0.0, 0.23299341362367973, 0.0001, 0.02, 1.3
appendInfoLine: "meanPeriod", tab$, value
value = Get jitter (local): 0.0, 0.23299341362367973, 0.0001, 0.02, 1.3
appendInfoLine: "local", tab$, value
value = Get jitter (local, absolute): 0.0, 0.23299341362367973, 0.0001, 0.02, 1.3
appendInfoLine: "absolute", tab$, value
value = Get jitter (rap): 0.0, 0.23299341362367973, 0.0001, 0.02, 1.3
appendInfoLine: "rap", tab$, value
value = Get jitter (ppq5): 0.0, 0.23299341362367973, 0.0001, 0.02, 1.3
appendInfoLine: "ppq5", tab$, value
value = Get jitter (ddp): 0.0, 0.23299341362367973, 0.0001, 0.02, 1.3
appendInfoLine: "ddp", tab$, value
appendInfoLine: "end", tab$, "jitter-reference-v1"
