# Original numerical query wrapper; no external implementation code.
Create empty PointProcess: "jitter", 0.0, 0.21587058833785705
Add point: 0.0
Add point: 0.012229595008247999
Add point: 0.015551820353102814
Add point: 0.018577164158450614
Add point: 0.022045460054068825
Add point: 0.024716813303602973
Add point: 0.02814894347935478
Add point: 0.030981686103805257
Add point: 0.04318233719244745
Add point: 0.04641011707277357
Add point: 0.04947361626102065
Add point: 0.05274938257476605
Add point: 0.05605596899429655
Add point: 0.05894913735162844
Add point: 0.061986074557498785
Add point: 0.0733792772812012
Add point: 0.07648464431742466
Add point: 0.07937131353373841
Add point: 0.0827067975214595
Add point: 0.08538715831520674
Add point: 0.08897681978629406
Add point: 0.09205768073781653
Add point: 0.10526680995393688
Add point: 0.10791462497876635
Add point: 0.11060202859698617
Add point: 0.1132428453088505
Add point: 0.11659461060768078
Add point: 0.12008059543655689
Add point: 0.1226735797699075
Add point: 0.13707125887536675
Add point: 0.13981396185885386
Add point: 0.142912000079923
Add point: 0.1464901245453802
Add point: 0.14999918907305979
Add point: 0.15354657427789786
Add point: 0.15641285670328214
Add point: 0.16683710509274532
Add point: 0.16979542223514726
Add point: 0.17258257816683908
Add point: 0.17544297682841717
Add point: 0.17890833941750317
Add point: 0.1815176371344205
Add point: 0.18462058833785705
appendInfoLine: "begin", tab$, "jitter-reference-v1"
count = Get number of points
appendInfoLine: "count", tab$, count
for i from 1 to count
    time = Get time from index: i
    appendInfoLine: "point", tab$, i, tab$, time
endfor
value = Get number of periods: 0.0, 0.21587058833785705, 0.0001, 0.02, 1.3
appendInfoLine: "periodCount", tab$, value
value = Get mean period: 0.0, 0.21587058833785705, 0.0001, 0.02, 1.3
appendInfoLine: "meanPeriod", tab$, value
value = Get jitter (local): 0.0, 0.21587058833785705, 0.0001, 0.02, 1.3
appendInfoLine: "local", tab$, value
value = Get jitter (local, absolute): 0.0, 0.21587058833785705, 0.0001, 0.02, 1.3
appendInfoLine: "absolute", tab$, value
value = Get jitter (rap): 0.0, 0.21587058833785705, 0.0001, 0.02, 1.3
appendInfoLine: "rap", tab$, value
value = Get jitter (ppq5): 0.0, 0.21587058833785705, 0.0001, 0.02, 1.3
appendInfoLine: "ppq5", tab$, value
value = Get jitter (ddp): 0.0, 0.21587058833785705, 0.0001, 0.02, 1.3
appendInfoLine: "ddp", tab$, value
appendInfoLine: "end", tab$, "jitter-reference-v1"
