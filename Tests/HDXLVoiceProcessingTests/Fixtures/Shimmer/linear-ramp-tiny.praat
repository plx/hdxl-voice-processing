# Original query wrapper; no external implementation source.
Create AmplitudeTier: "shimmer", 0.0, 0.12890625
Add point: 0.00390625, 3.8725919148493183e-121
Add point: 0.01171875, 4.114628909527401e-121
Add point: 0.01953125, 4.356665904205483e-121
Add point: 0.02734375, 4.5987028988835654e-121
Add point: 0.03515625, 4.840739893561648e-121
Add point: 0.04296875, 5.08277688823973e-121
Add point: 0.05078125, 5.324813882917813e-121
Add point: 0.05859375, 5.566850877595895e-121
Add point: 0.06640625, 5.808887872273977e-121
Add point: 0.07421875, 6.05092486695206e-121
Add point: 0.08203125, 6.292961861630142e-121
Add point: 0.08984375, 6.534998856308225e-121
Add point: 0.09765625, 6.777035850986307e-121
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
