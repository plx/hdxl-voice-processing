# Original numerical query wrapper; no external implementation code.
Create empty PointProcess: "jitter", 0.0, 0.22108530410605132
Add point: 0.0
Add point: 0.007655673013386231
Add point: 0.009896833307575435
Add point: 0.012082390841017266
Add point: 0.014014433537879747
Add point: 0.016435846265627663
Add point: 0.018985191299844616
Add point: 0.02089787079897095
Add point: 0.029385765586974394
Add point: 0.032046092740863306
Add point: 0.03408515556964134
Add point: 0.036123463216274763
Add point: 0.038755847964441106
Add point: 0.04098475270565938
Add point: 0.04292781948154284
Add point: 0.05067036362756467
Add point: 0.053272718306345106
Add point: 0.05526856028519846
Add point: 0.057621647056366784
Add point: 0.06002175280533265
Add point: 0.06191314974492839
Add point: 0.06425090259171239
Add point: 0.07404938233315161
Add point: 0.07649643209233711
Add point: 0.07877553075631362
Add point: 0.08078060394674223
Add point: 0.08292068347570339
Add point: 0.08500913616751364
Add point: 0.08748193478063597
Add point: 0.09549727172389713
Add point: 0.09798005987350322
Add point: 0.10043074612370799
Add point: 0.10233096774357943
Add point: 0.10470602014805826
Add point: 0.10717918479196008
Add point: 0.10913222045328108
Add point: 0.1179836235776152
Add point: 0.12020869707387068
Add point: 0.1221078330576314
Add point: 0.12468716553473232
Add point: 0.12667548418333438
Add point: 0.1290981934914916
Add point: 0.13097440793962137
Add point: 0.14014262605109257
Add point: 0.14273431562897965
Add point: 0.14535763856830525
Add point: 0.14738827356478648
Add point: 0.14972539102431096
Add point: 0.15171612369044774
Add point: 0.1536950063588765
Add point: 0.1626862517860454
Add point: 0.1645954249815127
Add point: 0.1666373006023192
Add point: 0.1685928048921845
Add point: 0.17058140151565163
Add point: 0.17274567763432233
Add point: 0.17520807117012083
Add point: 0.18290535107794734
Add point: 0.1852118670567871
Add point: 0.18720478118982026
Add point: 0.18983530410605132
appendInfoLine: "begin", tab$, "jitter-reference-v1"
count = Get number of points
appendInfoLine: "count", tab$, count
for i from 1 to count
    time = Get time from index: i
    appendInfoLine: "point", tab$, i, tab$, time
endfor
value = Get number of periods: 0.0, 0.22108530410605132, 0.0001, 0.02, 1.3
appendInfoLine: "periodCount", tab$, value
value = Get mean period: 0.0, 0.22108530410605132, 0.0001, 0.02, 1.3
appendInfoLine: "meanPeriod", tab$, value
value = Get jitter (local): 0.0, 0.22108530410605132, 0.0001, 0.02, 1.3
appendInfoLine: "local", tab$, value
value = Get jitter (local, absolute): 0.0, 0.22108530410605132, 0.0001, 0.02, 1.3
appendInfoLine: "absolute", tab$, value
value = Get jitter (rap): 0.0, 0.22108530410605132, 0.0001, 0.02, 1.3
appendInfoLine: "rap", tab$, value
value = Get jitter (ppq5): 0.0, 0.22108530410605132, 0.0001, 0.02, 1.3
appendInfoLine: "ppq5", tab$, value
value = Get jitter (ddp): 0.0, 0.22108530410605132, 0.0001, 0.02, 1.3
appendInfoLine: "ddp", tab$, value
appendInfoLine: "end", tab$, "jitter-reference-v1"
