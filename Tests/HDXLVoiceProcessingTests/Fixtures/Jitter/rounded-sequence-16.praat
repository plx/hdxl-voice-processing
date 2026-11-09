# Original numerical query wrapper; no external implementation code.
Create empty PointProcess: "jitter", 0.0, 0.16552460359755788
Add point: 0.0
Add point: 0.0025008753741858525
Add point: 0.005414651556900935
Add point: 0.007546744855906581
Add point: 0.010101831705484073
Add point: 0.012371684156765695
Add point: 0.01510471317495103
Add point: 0.017312767594732575
Add point: 0.019802413950557818
Add point: 0.022609403440263118
Add point: 0.024871314634016012
Add point: 0.02780765564643661
Add point: 0.030287914519256443
Add point: 0.033144754425680725
Add point: 0.03554655478321365
Add point: 0.037743236743641315
Add point: 0.04023997708386741
Add point: 0.043036351404269216
Add point: 0.04583357770348083
Add point: 0.048395832394337035
Add point: 0.051091689298802506
Add point: 0.05326215416536432
Add point: 0.055625727446953516
Add point: 0.05789882418132036
Add point: 0.06032215563079806
Add point: 0.06243465697648933
Add point: 0.0649436532157997
Add point: 0.06736545077452319
Add point: 0.06952844445669325
Add point: 0.07229381804197328
Add point: 0.07496741576175554
Add point: 0.07716849581248243
Add point: 0.07927149146003648
Add point: 0.08193329584633466
Add point: 0.08446095828761463
Add point: 0.08686758930920041
Add point: 0.0894503538577701
Add point: 0.09231712128868094
Add point: 0.09495661763192038
Add point: 0.09756390774264583
Add point: 0.09984202248824295
Add point: 0.10212049701437355
Add point: 0.10476266401811155
Add point: 0.10687612048114535
Add point: 0.10932681129180129
Add point: 0.11152997785020853
Add point: 0.1138021701493708
Add point: 0.11664549270391582
Add point: 0.11882715621520766
Add point: 0.12148984874936287
Add point: 0.12361182293042658
Add point: 0.12639211747198717
Add point: 0.12849546807113804
Add point: 0.1313580791523564
Add point: 0.13427460359755788
appendInfoLine: "begin", tab$, "jitter-reference-v1"
count = Get number of points
appendInfoLine: "count", tab$, count
for i from 1 to count
    time = Get time from index: i
    appendInfoLine: "point", tab$, i, tab$, time
endfor
value = Get number of periods: 0.0, 0.16552460359755788, 0.0001, 0.02, 1.3
appendInfoLine: "periodCount", tab$, value
value = Get mean period: 0.0, 0.16552460359755788, 0.0001, 0.02, 1.3
appendInfoLine: "meanPeriod", tab$, value
value = Get jitter (local): 0.0, 0.16552460359755788, 0.0001, 0.02, 1.3
appendInfoLine: "local", tab$, value
value = Get jitter (local, absolute): 0.0, 0.16552460359755788, 0.0001, 0.02, 1.3
appendInfoLine: "absolute", tab$, value
value = Get jitter (rap): 0.0, 0.16552460359755788, 0.0001, 0.02, 1.3
appendInfoLine: "rap", tab$, value
value = Get jitter (ppq5): 0.0, 0.16552460359755788, 0.0001, 0.02, 1.3
appendInfoLine: "ppq5", tab$, value
value = Get jitter (ddp): 0.0, 0.16552460359755788, 0.0001, 0.02, 1.3
appendInfoLine: "ddp", tab$, value
appendInfoLine: "end", tab$, "jitter-reference-v1"
