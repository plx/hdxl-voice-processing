# Original query wrapper; no external implementation source.
Create AmplitudeTier: "shimmer", 0.0, 0.25390625
Add point: 0.00390625, 3.8725919148493183e-121
Add point: 0.01171875, 4.175363342627353e-121
Add point: 0.01953125, 4.250141709876944e-121
Add point: 0.02734375, 4.040617380858443e-121
Add point: 0.03515625, 3.704566448840194e-121
Add point: 0.04296875, 3.4950421198216928e-121
Add point: 0.05078125, 3.5698204870712835e-121
Add point: 0.05859375, 3.8725919148493183e-121
Add point: 0.06640625, 4.175363342627353e-121
Add point: 0.07421875, 4.250141709876944e-121
Add point: 0.08203125, 4.040617380858443e-121
Add point: 0.08984375, 3.7045664488401943e-121
Add point: 0.09765625, 3.4950421198216928e-121
Add point: 0.10546875, 3.5698204870712835e-121
Add point: 0.11328125, 3.8725919148493183e-121
Add point: 0.12109375, 4.175363342627353e-121
Add point: 0.12890625, 4.250141709876944e-121
Add point: 0.13671875, 4.040617380858443e-121
Add point: 0.14453125, 3.704566448840194e-121
Add point: 0.15234375, 3.4950421198216928e-121
Add point: 0.16015625, 3.569820487071283e-121
Add point: 0.16796875, 3.872591914849318e-121
Add point: 0.17578125, 4.175363342627352e-121
Add point: 0.18359375, 4.250141709876944e-121
Add point: 0.19140625, 4.040617380858444e-121
Add point: 0.19921875, 3.704566448840194e-121
Add point: 0.20703125, 3.4950421198216923e-121
Add point: 0.21484375, 3.569820487071283e-121
Add point: 0.22265625, 3.872591914849318e-121
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
