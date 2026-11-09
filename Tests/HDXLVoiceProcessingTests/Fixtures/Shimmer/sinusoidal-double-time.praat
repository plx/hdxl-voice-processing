# Original query wrapper; no external implementation source.
Create AmplitudeTier: "shimmer", 0.0, 0.5078125
Add point: 0.0078125, 1.0
Add point: 0.0234375, 1.078183148246803
Add point: 0.0390625, 1.0974927912181824
Add point: 0.0546875, 1.0433883739117558
Add point: 0.0703125, 0.9566116260882442
Add point: 0.0859375, 0.9025072087818177
Add point: 0.1015625, 0.921816851753197
Add point: 0.1171875, 1.0
Add point: 0.1328125, 1.078183148246803
Add point: 0.1484375, 1.0974927912181824
Add point: 0.1640625, 1.0433883739117558
Add point: 0.1796875, 0.9566116260882443
Add point: 0.1953125, 0.9025072087818177
Add point: 0.2109375, 0.921816851753197
Add point: 0.2265625, 1.0
Add point: 0.2421875, 1.078183148246803
Add point: 0.2578125, 1.0974927912181824
Add point: 0.2734375, 1.0433883739117558
Add point: 0.2890625, 0.9566116260882442
Add point: 0.3046875, 0.9025072087818177
Add point: 0.3203125, 0.9218168517531969
Add point: 0.3359375, 0.9999999999999999
Add point: 0.3515625, 1.0781831482468027
Add point: 0.3671875, 1.0974927912181824
Add point: 0.3828125, 1.043388373911756
Add point: 0.3984375, 0.9566116260882442
Add point: 0.4140625, 0.9025072087818176
Add point: 0.4296875, 0.9218168517531969
Add point: 0.4453125, 0.9999999999999999
appendInfoLine: "begin", tab$, "shimmer-reference-v1"
count = Get number of points
appendInfoLine: "count", tab$, count
for i from 1 to count
    time = Get time from index: i
    amplitude = Get value at index: i
    appendInfoLine: "amplitude", tab$, i, tab$, time, tab$, amplitude
endfor
value = Get shimmer (local): 0.00390625, 0.0625, 1.6
appendInfoLine: "local", tab$, value
value = Get shimmer (local_dB): 0.00390625, 0.0625, 1.6
appendInfoLine: "db", tab$, value
value = Get shimmer (apq3): 0.00390625, 0.0625, 1.6
appendInfoLine: "apq3", tab$, value
value = Get shimmer (apq5): 0.00390625, 0.0625, 1.6
appendInfoLine: "apq5", tab$, value
value = Get shimmer (apq11): 0.00390625, 0.0625, 1.6
appendInfoLine: "apq11", tab$, value
value = Get shimmer (dda): 0.00390625, 0.0625, 1.6
appendInfoLine: "dda", tab$, value
appendInfoLine: "end", tab$, "shimmer-reference-v1"
