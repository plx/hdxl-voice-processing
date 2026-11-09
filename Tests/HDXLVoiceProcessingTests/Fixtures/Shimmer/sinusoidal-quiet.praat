# Original query wrapper; no external implementation source.
Create AmplitudeTier: "shimmer", 0.0, 0.25390625
Add point: 0.00390625, 0.125
Add point: 0.01171875, 0.13477289353085037
Add point: 0.01953125, 0.1371865989022728
Add point: 0.02734375, 0.13042354673896947
Add point: 0.03515625, 0.11957645326103053
Add point: 0.04296875, 0.11281340109772721
Add point: 0.05078125, 0.11522710646914963
Add point: 0.05859375, 0.125
Add point: 0.06640625, 0.13477289353085037
Add point: 0.07421875, 0.1371865989022728
Add point: 0.08203125, 0.13042354673896947
Add point: 0.08984375, 0.11957645326103054
Add point: 0.09765625, 0.11281340109772721
Add point: 0.10546875, 0.11522710646914963
Add point: 0.11328125, 0.125
Add point: 0.12109375, 0.13477289353085037
Add point: 0.12890625, 0.1371865989022728
Add point: 0.13671875, 0.13042354673896947
Add point: 0.14453125, 0.11957645326103053
Add point: 0.15234375, 0.11281340109772721
Add point: 0.16015625, 0.11522710646914962
Add point: 0.16796875, 0.12499999999999999
Add point: 0.17578125, 0.13477289353085034
Add point: 0.18359375, 0.1371865989022728
Add point: 0.19140625, 0.1304235467389695
Add point: 0.19921875, 0.11957645326103053
Add point: 0.20703125, 0.1128134010977272
Add point: 0.21484375, 0.11522710646914962
Add point: 0.22265625, 0.12499999999999999
appendInfoLine: "begin", tab$, "shimmer-reference-v1"
count = Get number of points
appendInfoLine: "count", tab$, count
for i from 1 to count
    time = Get time from index: i
    amplitude = Get value at index: i
    appendInfoLine: "amplitude", tab$, i, tab$, time, tab$, amplitude
endfor
value = Get shimmer (local): 0.001953125, 0.03125, 1.6
appendInfoLine: "local", tab$, value
value = Get shimmer (local_dB): 0.001953125, 0.03125, 1.6
appendInfoLine: "db", tab$, value
value = Get shimmer (apq3): 0.001953125, 0.03125, 1.6
appendInfoLine: "apq3", tab$, value
value = Get shimmer (apq5): 0.001953125, 0.03125, 1.6
appendInfoLine: "apq5", tab$, value
value = Get shimmer (apq11): 0.001953125, 0.03125, 1.6
appendInfoLine: "apq11", tab$, value
value = Get shimmer (dda): 0.001953125, 0.03125, 1.6
appendInfoLine: "dda", tab$, value
appendInfoLine: "end", tab$, "shimmer-reference-v1"
