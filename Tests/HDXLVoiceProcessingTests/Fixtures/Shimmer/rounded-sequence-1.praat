# Original query wrapper; no external implementation source.
Create AmplitudeTier: "shimmer", 0.0, 0.1262667458113283
Add point: 0.00390625, 4.2861980211455375
Add point: 0.013894547428004443, 0.9882974280044436
Add point: 0.023906964497407895, 1.0124170694034547
Add point: 0.033665481255622576, 0.7585167582146823
Add point: 0.044008516522590066, 1.3430352669674903
Add point: 0.054022333557251834, 1.0138170346617699
Add point: 0.06405802191258407, 1.0356883553322405
Add point: 0.07445374928298405, 1.3957273703999817
Add point: 0.08479103228542953, 1.3372830024454743
Add point: 0.09501674581132828, 1.2257135258987546
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
