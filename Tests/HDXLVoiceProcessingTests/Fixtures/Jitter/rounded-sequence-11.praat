# Original numerical query wrapper; no external implementation code.
Create empty PointProcess: "jitter", 0.0, 0.1612064483928649
Add point: 0.0
Add point: 0.003715447453743157
Add point: 0.007163801917612242
Add point: 0.010486519574498136
Add point: 0.014369760203252856
Add point: 0.017252750788698902
Add point: 0.020765736338876496
Add point: 0.02464739166689105
Add point: 0.0277576677291654
Add point: 0.03162897091277409
Add point: 0.035002746466508444
Add point: 0.03786507210740819
Add point: 0.040894570065584654
Add point: 0.04475881637077934
Add point: 0.047782049852772616
Add point: 0.05076907734860045
Add point: 0.05448698281279454
Add point: 0.057855183122330345
Add point: 0.06141749249969143
Add point: 0.06420925710132966
Add point: 0.06729154494474641
Add point: 0.07023952085451067
Add point: 0.07361613384032777
Add point: 0.0767884303414418
Add point: 0.08039735981247698
Add point: 0.08383388060963867
Add point: 0.087722522149755
Add point: 0.09139083023571098
Add point: 0.09434968543138045
Add point: 0.09756966976980523
Add point: 0.10110933226071453
Add point: 0.10492575902872098
Add point: 0.10813385426066816
Add point: 0.1109585571065157
Add point: 0.11423845412562755
Add point: 0.11726627059901754
Add point: 0.1210903860166824
Add point: 0.12391472060376932
Add point: 0.12671870409996092
Add point: 0.1299564483928649
appendInfoLine: "begin", tab$, "jitter-reference-v1"
count = Get number of points
appendInfoLine: "count", tab$, count
for i from 1 to count
    time = Get time from index: i
    appendInfoLine: "point", tab$, i, tab$, time
endfor
value = Get number of periods: 0.0, 0.1612064483928649, 0.0001, 0.02, 1.3
appendInfoLine: "periodCount", tab$, value
value = Get mean period: 0.0, 0.1612064483928649, 0.0001, 0.02, 1.3
appendInfoLine: "meanPeriod", tab$, value
value = Get jitter (local): 0.0, 0.1612064483928649, 0.0001, 0.02, 1.3
appendInfoLine: "local", tab$, value
value = Get jitter (local, absolute): 0.0, 0.1612064483928649, 0.0001, 0.02, 1.3
appendInfoLine: "absolute", tab$, value
value = Get jitter (rap): 0.0, 0.1612064483928649, 0.0001, 0.02, 1.3
appendInfoLine: "rap", tab$, value
value = Get jitter (ppq5): 0.0, 0.1612064483928649, 0.0001, 0.02, 1.3
appendInfoLine: "ppq5", tab$, value
value = Get jitter (ddp): 0.0, 0.1612064483928649, 0.0001, 0.02, 1.3
appendInfoLine: "ddp", tab$, value
appendInfoLine: "end", tab$, "jitter-reference-v1"
