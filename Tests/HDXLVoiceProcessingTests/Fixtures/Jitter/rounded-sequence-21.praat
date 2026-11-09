# Original numerical query wrapper; no external implementation code.
Create empty PointProcess: "jitter", 0.0, 0.23098147799146826
Add point: 0.0
Add point: 0.008893406984210013
Add point: 0.01072375260873232
Add point: 0.012939658181159757
Add point: 0.014627850541239605
Add point: 0.016681260030018165
Add point: 0.01887581674584653
Add point: 0.02105847853871528
Add point: 0.03020256827578414
Add point: 0.03216021449354012
Add point: 0.03449607233605348
Add point: 0.036636629467736936
Add point: 0.03866149244986009
Add point: 0.04048205858187285
Add point: 0.042288194693345584
Add point: 0.04939298162302003
Add point: 0.05142425829356071
Add point: 0.05328953760487493
Add point: 0.055200450496561825
Add point: 0.056946733204787596
Add point: 0.05873689028855879
Add point: 0.06092200211214367
Add point: 0.06981560295496601
Add point: 0.07181657525112387
Add point: 0.07399308498040773
Add point: 0.07631546878148801
Add point: 0.07857720952637028
Add point: 0.08035583225658628
Add point: 0.0822210926439613
Add point: 0.08986726458519696
Add point: 0.09182013348855543
Add point: 0.09349674382170196
Add point: 0.09567677212622948
Add point: 0.09785561336693353
Add point: 0.09953704387273173
Add point: 0.1016149551997194
Add point: 0.10968216212179976
Add point: 0.11164790365884546
Add point: 0.11384510221271775
Add point: 0.11603323407508433
Add point: 0.1177866873743711
Add point: 0.11950493027500343
Add point: 0.12153435287149623
Add point: 0.1295850519376807
Add point: 0.13191608469120691
Add point: 0.13367539552540983
Add point: 0.13580694471420718
Add point: 0.13788567522442896
Add point: 0.13985344973749012
Add point: 0.14219005044309885
Add point: 0.1492090542226331
Add point: 0.15139083411570167
Add point: 0.1536325917026493
Add point: 0.1555452533078845
Add point: 0.15746895499217783
Add point: 0.1594802509402157
Add point: 0.16133340626955026
Add point: 0.17029263895824545
Add point: 0.17255567413049278
Add point: 0.17434100669489702
Add point: 0.1763930192339699
Add point: 0.1787298671231139
Add point: 0.18102779207674316
Add point: 0.18292647940630555
Add point: 0.1896964290186064
Add point: 0.19185628036477134
Add point: 0.19358350314549166
Add point: 0.1957478292350657
Add point: 0.19779732501849065
Add point: 0.19973147799146826
appendInfoLine: "begin", tab$, "jitter-reference-v1"
count = Get number of points
appendInfoLine: "count", tab$, count
for i from 1 to count
    time = Get time from index: i
    appendInfoLine: "point", tab$, i, tab$, time
endfor
value = Get number of periods: 0.0, 0.23098147799146826, 0.0001, 0.02, 1.3
appendInfoLine: "periodCount", tab$, value
value = Get mean period: 0.0, 0.23098147799146826, 0.0001, 0.02, 1.3
appendInfoLine: "meanPeriod", tab$, value
value = Get jitter (local): 0.0, 0.23098147799146826, 0.0001, 0.02, 1.3
appendInfoLine: "local", tab$, value
value = Get jitter (local, absolute): 0.0, 0.23098147799146826, 0.0001, 0.02, 1.3
appendInfoLine: "absolute", tab$, value
value = Get jitter (rap): 0.0, 0.23098147799146826, 0.0001, 0.02, 1.3
appendInfoLine: "rap", tab$, value
value = Get jitter (ppq5): 0.0, 0.23098147799146826, 0.0001, 0.02, 1.3
appendInfoLine: "ppq5", tab$, value
value = Get jitter (ddp): 0.0, 0.23098147799146826, 0.0001, 0.02, 1.3
appendInfoLine: "ddp", tab$, value
appendInfoLine: "end", tab$, "jitter-reference-v1"
