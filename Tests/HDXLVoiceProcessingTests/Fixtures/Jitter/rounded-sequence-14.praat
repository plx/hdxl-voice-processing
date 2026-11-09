# Original numerical query wrapper; no external implementation code.
Create empty PointProcess: "jitter", 0.0, 0.16430162643160048
Add point: 0.0
Add point: 0.0029274972282776917
Add point: 0.006036462238181331
Add point: 0.009026860399365736
Add point: 0.011755616400041618
Add point: 0.014428263062630625
Add point: 0.017260486225940338
Add point: 0.02027868263462248
Add point: 0.022913132581678736
Add point: 0.025801878038231127
Add point: 0.028673567548232512
Add point: 0.03135693535836051
Add point: 0.033696154748904514
Add point: 0.036415043872257226
Add point: 0.03917371418239781
Add point: 0.04162898925055439
Add point: 0.044285767549493656
Add point: 0.04716331996337329
Add point: 0.049630099047563915
Add point: 0.05212027752868986
Add point: 0.055297195333276046
Add point: 0.058107606902065324
Add point: 0.06087587862511605
Add point: 0.06373408905553839
Add point: 0.06612474276153889
Add point: 0.06865867821231304
Add point: 0.07140549969765643
Add point: 0.07466790143174068
Add point: 0.07706050521894617
Add point: 0.08027558063709876
Add point: 0.08308215826895321
Add point: 0.08583322021903264
Add point: 0.08814963114603112
Add point: 0.09088851494691981
Add point: 0.09320447750515692
Add point: 0.09628901543994693
Add point: 0.09910776563253927
Add point: 0.10227937869491548
Add point: 0.10493598542645083
Add point: 0.10806863816649033
Add point: 0.11043359627856666
Add point: 0.11298127734221958
Add point: 0.11536659807830195
Add point: 0.1183998916769633
Add point: 0.1216567139971044
Add point: 0.12461421295492779
Add point: 0.12718538335592408
Add point: 0.13024327888231102
Add point: 0.13305162643160048
appendInfoLine: "begin", tab$, "jitter-reference-v1"
count = Get number of points
appendInfoLine: "count", tab$, count
for i from 1 to count
    time = Get time from index: i
    appendInfoLine: "point", tab$, i, tab$, time
endfor
value = Get number of periods: 0.0, 0.16430162643160048, 0.0001, 0.02, 1.3
appendInfoLine: "periodCount", tab$, value
value = Get mean period: 0.0, 0.16430162643160048, 0.0001, 0.02, 1.3
appendInfoLine: "meanPeriod", tab$, value
value = Get jitter (local): 0.0, 0.16430162643160048, 0.0001, 0.02, 1.3
appendInfoLine: "local", tab$, value
value = Get jitter (local, absolute): 0.0, 0.16430162643160048, 0.0001, 0.02, 1.3
appendInfoLine: "absolute", tab$, value
value = Get jitter (rap): 0.0, 0.16430162643160048, 0.0001, 0.02, 1.3
appendInfoLine: "rap", tab$, value
value = Get jitter (ppq5): 0.0, 0.16430162643160048, 0.0001, 0.02, 1.3
appendInfoLine: "ppq5", tab$, value
value = Get jitter (ddp): 0.0, 0.16430162643160048, 0.0001, 0.02, 1.3
appendInfoLine: "ddp", tab$, value
appendInfoLine: "end", tab$, "jitter-reference-v1"
