# Original numerical query wrapper; no external implementation code.
Create empty PointProcess: "jitter", 0.0, 0.17182164896097676
Add point: 0.0
Add point: 0.002019266020167076
Add point: 0.0039844508520764065
Add point: 0.0057305842945788756
Add point: 0.007837765280031212
Add point: 0.010002208225875317
Add point: 0.012381272282873397
Add point: 0.014152879908773078
Add point: 0.016175180139155903
Add point: 0.018450791008217494
Add point: 0.020533915314614813
Add point: 0.022671320874772697
Add point: 0.024812642237957337
Add point: 0.02688516338084204
Add point: 0.029270989767755967
Add point: 0.0316931339053311
Add point: 0.033627530721908744
Add point: 0.035973277524899455
Add point: 0.03784265853806573
Add point: 0.03975823203016868
Add point: 0.04177230758296597
Add point: 0.04397062706266296
Add point: 0.04604136926827777
Add point: 0.04848746981702182
Add point: 0.050529667564454324
Add point: 0.05251151222730792
Add point: 0.05475441483647348
Add point: 0.05707956904353825
Add point: 0.05945404976029142
Add point: 0.06141206955905848
Add point: 0.06376057852057176
Add point: 0.06591604099189377
Add point: 0.06798741780958759
Add point: 0.07019868917457642
Add point: 0.07246463011496719
Add point: 0.07433473362133856
Add point: 0.07646247600433222
Add point: 0.07869132807313386
Add point: 0.08083244969202497
Add point: 0.08292560062388171
Add point: 0.08473591571120778
Add point: 0.08712878002644478
Add point: 0.08956689945114098
Add point: 0.09151609145165518
Add point: 0.09394038025857299
Add point: 0.09573051468236372
Add point: 0.0981544078480753
Add point: 0.10055653015449934
Add point: 0.10294409685632369
Add point: 0.10518475059599344
Add point: 0.10702290728060082
Add point: 0.10880465294964475
Add point: 0.11074905119967297
Add point: 0.11312664565174296
Add point: 0.11505827702317521
Add point: 0.11748060986203199
Add point: 0.11924217415789219
Add point: 0.12149470708987792
Add point: 0.1237329535200115
Add point: 0.12604420452381115
Add point: 0.12848093703238797
Add point: 0.1304152421011046
Add point: 0.13244021389592187
Add point: 0.13441411497156272
Add point: 0.13633667895182347
Add point: 0.1381513887027298
Add point: 0.14057164896097676
appendInfoLine: "begin", tab$, "jitter-reference-v1"
count = Get number of points
appendInfoLine: "count", tab$, count
for i from 1 to count
    time = Get time from index: i
    appendInfoLine: "point", tab$, i, tab$, time
endfor
value = Get number of periods: 0.0, 0.17182164896097676, 0.0001, 0.02, 1.3
appendInfoLine: "periodCount", tab$, value
value = Get mean period: 0.0, 0.17182164896097676, 0.0001, 0.02, 1.3
appendInfoLine: "meanPeriod", tab$, value
value = Get jitter (local): 0.0, 0.17182164896097676, 0.0001, 0.02, 1.3
appendInfoLine: "local", tab$, value
value = Get jitter (local, absolute): 0.0, 0.17182164896097676, 0.0001, 0.02, 1.3
appendInfoLine: "absolute", tab$, value
value = Get jitter (rap): 0.0, 0.17182164896097676, 0.0001, 0.02, 1.3
appendInfoLine: "rap", tab$, value
value = Get jitter (ppq5): 0.0, 0.17182164896097676, 0.0001, 0.02, 1.3
appendInfoLine: "ppq5", tab$, value
value = Get jitter (ddp): 0.0, 0.17182164896097676, 0.0001, 0.02, 1.3
appendInfoLine: "ddp", tab$, value
appendInfoLine: "end", tab$, "jitter-reference-v1"
