# Original numerical query wrapper; no external implementation code.
Create empty PointProcess: "jitter", 0.0, 0.1563004573438749
Add point: 0.0
Add point: 0.0032193503297250053
Add point: 0.006550592238740396
Add point: 0.009962852477994081
Add point: 0.012911252613329063
Add point: 0.016620177465998236
Add point: 0.020234223015016012
Add point: 0.023625358223798687
Add point: 0.027182413597890576
Add point: 0.030252630296121685
Add point: 0.03442590982748828
Add point: 0.038011514196904114
Add point: 0.04159817248441479
Add point: 0.04570784758531123
Add point: 0.04937882362835808
Add point: 0.05250053258305083
Add point: 0.0555719989302036
Add point: 0.058567149783276755
Add point: 0.06251451777606105
Add point: 0.06569636345059346
Add point: 0.06909142088685519
Add point: 0.07254417082964211
Add point: 0.07661634463072656
Add point: 0.07968625111646752
Add point: 0.08375308548283232
Add point: 0.08670041525233371
Add point: 0.0900086509582304
Add point: 0.09402066502387503
Add point: 0.09720693855837453
Add point: 0.10088560774643807
Add point: 0.10443952558034134
Add point: 0.1074956598191888
Add point: 0.11106323379025396
Add point: 0.11510107742102783
Add point: 0.11849424770846131
Add point: 0.12199059431557543
Add point: 0.1250504573438749
appendInfoLine: "begin", tab$, "jitter-reference-v1"
count = Get number of points
appendInfoLine: "count", tab$, count
for i from 1 to count
    time = Get time from index: i
    appendInfoLine: "point", tab$, i, tab$, time
endfor
value = Get number of periods: 0.0, 0.1563004573438749, 0.0001, 0.02, 1.3
appendInfoLine: "periodCount", tab$, value
value = Get mean period: 0.0, 0.1563004573438749, 0.0001, 0.02, 1.3
appendInfoLine: "meanPeriod", tab$, value
value = Get jitter (local): 0.0, 0.1563004573438749, 0.0001, 0.02, 1.3
appendInfoLine: "local", tab$, value
value = Get jitter (local, absolute): 0.0, 0.1563004573438749, 0.0001, 0.02, 1.3
appendInfoLine: "absolute", tab$, value
value = Get jitter (rap): 0.0, 0.1563004573438749, 0.0001, 0.02, 1.3
appendInfoLine: "rap", tab$, value
value = Get jitter (ppq5): 0.0, 0.1563004573438749, 0.0001, 0.02, 1.3
appendInfoLine: "ppq5", tab$, value
value = Get jitter (ddp): 0.0, 0.1563004573438749, 0.0001, 0.02, 1.3
appendInfoLine: "ddp", tab$, value
appendInfoLine: "end", tab$, "jitter-reference-v1"
