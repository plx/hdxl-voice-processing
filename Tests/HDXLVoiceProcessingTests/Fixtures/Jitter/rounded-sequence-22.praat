# Original numerical query wrapper; no external implementation code.
Create empty PointProcess: "jitter", 0.0, 0.1712003809246772
Add point: 0.0
Add point: 0.0019640318602726506
Add point: 0.003985913329950283
Add point: 0.005725043472484686
Add point: 0.007830591299615872
Add point: 0.009986438742691041
Add point: 0.011725899960259153
Add point: 0.013664118273971744
Add point: 0.015603950321405696
Add point: 0.01739390491510186
Add point: 0.019030561238021337
Add point: 0.020709206839226398
Add point: 0.022956675369283537
Add point: 0.025189791406625698
Add point: 0.02685920180889437
Add point: 0.02861792997627232
Add point: 0.030779626662663824
Add point: 0.032673126692959784
Add point: 0.03481610082535413
Add point: 0.03668502412203591
Add point: 0.03850970988936471
Add point: 0.04047623398989134
Add point: 0.0427212472912148
Add point: 0.044414755388413774
Add point: 0.04604298356410044
Add point: 0.04780216417331338
Add point: 0.049891529319910866
Add point: 0.05210952294878482
Add point: 0.053882747043524144
Add point: 0.055743319542089005
Add point: 0.057840385119041174
Add point: 0.059540291789005724
Add point: 0.061656698741090414
Add point: 0.06361674017857205
Add point: 0.06540320235982877
Add point: 0.06719742753923548
Add point: 0.06896537908500669
Add point: 0.07078638043082229
Add point: 0.0730181083593813
Add point: 0.07481882341062793
Add point: 0.07692916083946609
Add point: 0.0789006357328617
Add point: 0.08071030311902107
Add point: 0.08295591118400737
Add point: 0.08455225133243052
Add point: 0.08673900497931754
Add point: 0.08868505841580022
Add point: 0.09084415781302736
Add point: 0.09265798844092597
Add point: 0.09472355251695262
Add point: 0.09677224652893178
Add point: 0.09894681266585113
Add point: 0.10101629872327275
Add point: 0.10312799727712094
Add point: 0.10514915641363655
Add point: 0.10733514158323836
Add point: 0.10897769570305871
Add point: 0.11085980465011043
Add point: 0.11283686475029053
Add point: 0.11482439354630723
Add point: 0.11692939823273962
Add point: 0.11895628170233416
Add point: 0.12068778506598811
Add point: 0.12273306305493371
Add point: 0.12433265848013644
Add point: 0.12606668595271633
Add point: 0.12820822004871354
Add point: 0.12992748247159538
Add point: 0.1320054371580213
Add point: 0.13411182907846525
Add point: 0.1358974825589282
Add point: 0.13774286512392933
Add point: 0.1399503809246772
appendInfoLine: "begin", tab$, "jitter-reference-v1"
count = Get number of points
appendInfoLine: "count", tab$, count
for i from 1 to count
    time = Get time from index: i
    appendInfoLine: "point", tab$, i, tab$, time
endfor
value = Get number of periods: 0.0, 0.1712003809246772, 0.0001, 0.02, 1.3
appendInfoLine: "periodCount", tab$, value
value = Get mean period: 0.0, 0.1712003809246772, 0.0001, 0.02, 1.3
appendInfoLine: "meanPeriod", tab$, value
value = Get jitter (local): 0.0, 0.1712003809246772, 0.0001, 0.02, 1.3
appendInfoLine: "local", tab$, value
value = Get jitter (local, absolute): 0.0, 0.1712003809246772, 0.0001, 0.02, 1.3
appendInfoLine: "absolute", tab$, value
value = Get jitter (rap): 0.0, 0.1712003809246772, 0.0001, 0.02, 1.3
appendInfoLine: "rap", tab$, value
value = Get jitter (ppq5): 0.0, 0.1712003809246772, 0.0001, 0.02, 1.3
appendInfoLine: "ppq5", tab$, value
value = Get jitter (ddp): 0.0, 0.1712003809246772, 0.0001, 0.02, 1.3
appendInfoLine: "ddp", tab$, value
appendInfoLine: "end", tab$, "jitter-reference-v1"
