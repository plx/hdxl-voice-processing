# Original query wrapper; no external implementation source.
Create AmplitudeTier: "shimmer", 0.0, 0.126953125
Add point: 0.001953125, 1.0
Add point: 0.005859375, 1.078183148246803
Add point: 0.009765625, 1.0974927912181824
Add point: 0.013671875, 1.0433883739117558
Add point: 0.017578125, 0.9566116260882442
Add point: 0.021484375, 0.9025072087818177
Add point: 0.025390625, 0.921816851753197
Add point: 0.029296875, 1.0
Add point: 0.033203125, 1.078183148246803
Add point: 0.037109375, 1.0974927912181824
Add point: 0.041015625, 1.0433883739117558
Add point: 0.044921875, 0.9566116260882443
Add point: 0.048828125, 0.9025072087818177
Add point: 0.052734375, 0.921816851753197
Add point: 0.056640625, 1.0
Add point: 0.060546875, 1.078183148246803
Add point: 0.064453125, 1.0974927912181824
Add point: 0.068359375, 1.0433883739117558
Add point: 0.072265625, 0.9566116260882442
Add point: 0.076171875, 0.9025072087818177
Add point: 0.080078125, 0.9218168517531969
Add point: 0.083984375, 0.9999999999999999
Add point: 0.087890625, 1.0781831482468027
Add point: 0.091796875, 1.0974927912181824
Add point: 0.095703125, 1.043388373911756
Add point: 0.099609375, 0.9566116260882442
Add point: 0.103515625, 0.9025072087818176
Add point: 0.107421875, 0.9218168517531969
Add point: 0.111328125, 0.9999999999999999
appendInfoLine: "begin", tab$, "shimmer-reference-v1"
count = Get number of points
appendInfoLine: "count", tab$, count
for i from 1 to count
    time = Get time from index: i
    amplitude = Get value at index: i
    appendInfoLine: "amplitude", tab$, i, tab$, time, tab$, amplitude
endfor
value = Get shimmer (local): 0.0009765625, 0.015625, 1.6
appendInfoLine: "local", tab$, value
value = Get shimmer (local_dB): 0.0009765625, 0.015625, 1.6
appendInfoLine: "db", tab$, value
value = Get shimmer (apq3): 0.0009765625, 0.015625, 1.6
appendInfoLine: "apq3", tab$, value
value = Get shimmer (apq5): 0.0009765625, 0.015625, 1.6
appendInfoLine: "apq5", tab$, value
value = Get shimmer (apq11): 0.0009765625, 0.015625, 1.6
appendInfoLine: "apq11", tab$, value
value = Get shimmer (dda): 0.0009765625, 0.015625, 1.6
appendInfoLine: "dda", tab$, value
appendInfoLine: "end", tab$, "shimmer-reference-v1"
