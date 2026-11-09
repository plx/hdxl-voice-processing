# Original numerical query wrapper; no external implementation code.
Create empty PointProcess: "jitter", 0.0, 0.1666474040584927
Add point: 0.0
Add point: 0.0020797223887694554
Add point: 0.004804659796618147
Add point: 0.007392563402591761
Add point: 0.009624734229042328
Add point: 0.012418736121839
Add point: 0.014568447767440894
Add point: 0.016994447522835493
Add point: 0.019553066650294652
Add point: 0.02203863820310549
Add point: 0.02417668492247772
Add point: 0.02670801891027839
Add point: 0.02906316708446303
Add point: 0.031560239369781425
Add point: 0.033621729896597875
Add point: 0.035623316649275476
Add point: 0.03796192159854053
Add point: 0.040514201274352325
Add point: 0.042490686165928354
Add point: 0.044653941015740634
Add point: 0.046748595734160125
Add point: 0.048876210536497336
Add point: 0.05138750847282132
Add point: 0.0540674057517234
Add point: 0.056234674493760045
Add point: 0.058719950646572254
Add point: 0.06082398132113407
Add point: 0.06279832725404828
Add point: 0.06544474887622831
Add point: 0.06821117901232182
Add point: 0.07064923100015481
Add point: 0.07278338296868328
Add point: 0.07490456875369307
Add point: 0.0769891331071544
Add point: 0.07928534926217426
Add point: 0.08129655461583751
Add point: 0.08403696521445886
Add point: 0.08630440634497928
Add point: 0.08906795677870312
Add point: 0.0915027552041214
Add point: 0.09383426216375526
Add point: 0.09660535097327305
Add point: 0.09935511783366868
Add point: 0.1020208554587693
Add point: 0.10425704697396475
Add point: 0.10625464860937515
Add point: 0.10859926771192392
Add point: 0.11102670862225796
Add point: 0.11325708664266305
Add point: 0.11604727237834597
Add point: 0.11860806424140245
Add point: 0.12099968925232092
Add point: 0.12343675925013878
Add point: 0.12602398127738743
Add point: 0.12875132494725267
Add point: 0.1307891783090253
Add point: 0.13313862050805864
Add point: 0.1353974040584927
appendInfoLine: "begin", tab$, "jitter-reference-v1"
count = Get number of points
appendInfoLine: "count", tab$, count
for i from 1 to count
    time = Get time from index: i
    appendInfoLine: "point", tab$, i, tab$, time
endfor
value = Get number of periods: 0.0, 0.1666474040584927, 0.0001, 0.02, 1.3
appendInfoLine: "periodCount", tab$, value
value = Get mean period: 0.0, 0.1666474040584927, 0.0001, 0.02, 1.3
appendInfoLine: "meanPeriod", tab$, value
value = Get jitter (local): 0.0, 0.1666474040584927, 0.0001, 0.02, 1.3
appendInfoLine: "local", tab$, value
value = Get jitter (local, absolute): 0.0, 0.1666474040584927, 0.0001, 0.02, 1.3
appendInfoLine: "absolute", tab$, value
value = Get jitter (rap): 0.0, 0.1666474040584927, 0.0001, 0.02, 1.3
appendInfoLine: "rap", tab$, value
value = Get jitter (ppq5): 0.0, 0.1666474040584927, 0.0001, 0.02, 1.3
appendInfoLine: "ppq5", tab$, value
value = Get jitter (ddp): 0.0, 0.1666474040584927, 0.0001, 0.02, 1.3
appendInfoLine: "ddp", tab$, value
appendInfoLine: "end", tab$, "jitter-reference-v1"
