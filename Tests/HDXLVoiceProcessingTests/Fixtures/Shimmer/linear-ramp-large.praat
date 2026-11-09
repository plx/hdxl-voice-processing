# Original query wrapper; no external implementation source.
Create AmplitudeTier: "shimmer", 0.0, 0.12890625
Add point: 0.00390625, 2.5822498780869086e+120
Add point: 0.01171875, 2.7436404954673404e+120
Add point: 0.01953125, 2.905031112847772e+120
Add point: 0.02734375, 3.066421730228204e+120
Add point: 0.03515625, 3.227812347608636e+120
Add point: 0.04296875, 3.3892029649890675e+120
Add point: 0.05078125, 3.5505935823694993e+120
Add point: 0.05859375, 3.711984199749931e+120
Add point: 0.06640625, 3.873374817130363e+120
Add point: 0.07421875, 4.0347654345107947e+120
Add point: 0.08203125, 4.1961560518912265e+120
Add point: 0.08984375, 4.357546669271658e+120
Add point: 0.09765625, 4.51893728665209e+120
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
