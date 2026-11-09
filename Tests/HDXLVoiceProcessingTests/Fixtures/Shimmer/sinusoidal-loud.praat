# Original query wrapper; no external implementation source.
Create AmplitudeTier: "shimmer", 0.0, 0.25390625
Add point: 0.00390625, 8.0
Add point: 0.01171875, 8.625465185974424
Add point: 0.01953125, 8.77994232974546
Add point: 0.02734375, 8.347106991294046
Add point: 0.03515625, 7.652893008705954
Add point: 0.04296875, 7.220057670254541
Add point: 0.05078125, 7.374534814025576
Add point: 0.05859375, 8.0
Add point: 0.06640625, 8.625465185974424
Add point: 0.07421875, 8.77994232974546
Add point: 0.08203125, 8.347106991294046
Add point: 0.08984375, 7.652893008705955
Add point: 0.09765625, 7.220057670254541
Add point: 0.10546875, 7.374534814025576
Add point: 0.11328125, 8.0
Add point: 0.12109375, 8.625465185974424
Add point: 0.12890625, 8.77994232974546
Add point: 0.13671875, 8.347106991294046
Add point: 0.14453125, 7.652893008705954
Add point: 0.15234375, 7.220057670254541
Add point: 0.16015625, 7.3745348140255755
Add point: 0.16796875, 7.999999999999999
Add point: 0.17578125, 8.625465185974422
Add point: 0.18359375, 8.77994232974546
Add point: 0.19140625, 8.347106991294048
Add point: 0.19921875, 7.652893008705954
Add point: 0.20703125, 7.2200576702545405
Add point: 0.21484375, 7.3745348140255755
Add point: 0.22265625, 7.999999999999999
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
