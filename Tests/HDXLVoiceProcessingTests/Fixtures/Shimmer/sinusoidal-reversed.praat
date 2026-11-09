# Original query wrapper; no external implementation source.
Create AmplitudeTier: "shimmer", 0.0, 0.25390625
Add point: 0.00390625, 0.9999999999999999
Add point: 0.01171875, 0.9218168517531969
Add point: 0.01953125, 0.9025072087818176
Add point: 0.02734375, 0.9566116260882442
Add point: 0.03515625, 1.043388373911756
Add point: 0.04296875, 1.0974927912181824
Add point: 0.05078125, 1.0781831482468027
Add point: 0.05859375, 0.9999999999999999
Add point: 0.06640625, 0.9218168517531969
Add point: 0.07421875, 0.9025072087818177
Add point: 0.08203125, 0.9566116260882442
Add point: 0.08984375, 1.0433883739117558
Add point: 0.09765625, 1.0974927912181824
Add point: 0.10546875, 1.078183148246803
Add point: 0.11328125, 1.0
Add point: 0.12109375, 0.921816851753197
Add point: 0.12890625, 0.9025072087818177
Add point: 0.13671875, 0.9566116260882443
Add point: 0.14453125, 1.0433883739117558
Add point: 0.15234375, 1.0974927912181824
Add point: 0.16015625, 1.078183148246803
Add point: 0.16796875, 1.0
Add point: 0.17578125, 0.921816851753197
Add point: 0.18359375, 0.9025072087818177
Add point: 0.19140625, 0.9566116260882442
Add point: 0.19921875, 1.0433883739117558
Add point: 0.20703125, 1.0974927912181824
Add point: 0.21484375, 1.078183148246803
Add point: 0.22265625, 1.0
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
