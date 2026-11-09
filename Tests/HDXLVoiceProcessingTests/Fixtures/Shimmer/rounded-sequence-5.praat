# Original query wrapper; no external implementation source.
Create AmplitudeTier: "shimmer", 0.0, 0.15318455951547044
Add point: 0.00390625, 5.479361437028274
Add point: 0.00949250659465583, 1.055261870380491
Add point: 0.015048541627798437, 1.0008630596566945
Add point: 0.020504343312414776, 0.820443032309413
Add point: 0.026156800422662246, 1.1744227984454483
Add point: 0.031903828413018746, 1.344650382641703
Add point: 0.03768951433154547, 1.4142346533481032
Add point: 0.043340865567248935, 1.172432224266231
Add point: 0.04888762374563763, 0.9841647210996598
Add point: 0.05445343284790093, 1.018456384073943
Add point: 0.0602027487660396, 1.3487686526495963
Add point: 0.06596809295614042, 1.3776195421814919
Add point: 0.07174838052312325, 1.404517620569095
Add point: 0.07726418371519281, 4.642228728625923
Add point: 0.08303694548512187, 1.3909711858723313
Add point: 0.08834207443792062, 0.5492321150377393
Add point: 0.09379893619670636, 0.8223511658143252
Add point: 0.09952690567588433, 1.310345062520355
Add point: 0.10527760549073314, 1.3512596667278558
Add point: 0.11068473224463458, 0.7328281570225954
Add point: 0.1162536966937801, 1.0241360084619373
Add point: 0.12193455951547043, 1.2255530790425837
appendInfoLine: "begin", tab$, "shimmer-reference-v1"
count = Get number of points
appendInfoLine: "count", tab$, count
for i from 1 to count
    time = Get time from index: i
    amplitude = Get value at index: i
    appendInfoLine: "amplitude", tab$, i, tab$, time, tab$, amplitude
endfor
value = Get shimmer (local): 0.0001, 0.02, 1.6
appendInfoLine: "local", tab$, value
value = Get shimmer (local_dB): 0.0001, 0.02, 1.6
appendInfoLine: "db", tab$, value
value = Get shimmer (apq3): 0.0001, 0.02, 1.6
appendInfoLine: "apq3", tab$, value
value = Get shimmer (apq5): 0.0001, 0.02, 1.6
appendInfoLine: "apq5", tab$, value
value = Get shimmer (apq11): 0.0001, 0.02, 1.6
appendInfoLine: "apq11", tab$, value
value = Get shimmer (dda): 0.0001, 0.02, 1.6
appendInfoLine: "dda", tab$, value
appendInfoLine: "end", tab$, "shimmer-reference-v1"
