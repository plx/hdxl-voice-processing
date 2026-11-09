# Original query wrapper; no external implementation source.
Create AmplitudeTier: "shimmer", 0.0, 0.15707346464105118
Add point: 0.00390625, 6.321334973908961
Add point: 0.008567866879748181, 1.2555571354459971
Add point: 0.01333011516211131, 1.4769462211988866
Add point: 0.017941437457391823, 1.1449090496171266
Add point: 0.022474111057606272, 0.9718819204717875
Add point: 0.027014902546176348, 0.9897412748541683
Add point: 0.03171108191314323, 1.3315946073271334
Add point: 0.0361428224447776, 0.7498291695956141
Add point: 0.04052218113221567, 0.6345891123637557
Add point: 0.04492141988371838, 0.6783252533059567
Add point: 0.04927520491574383, 0.5783270704559982
Add point: 0.053867486162661495, 1.103018743218854
Add point: 0.05819004267898643, 0.5096243359148502
Add point: 0.06259177296941, 3.419033194659278
Add point: 0.06735619843291882, 1.481736019719392
Add point: 0.07184905815742572, 0.8842913939151913
Add point: 0.07656202391043983, 1.3685246566310525
Add point: 0.08098936335384761, 0.7401467754971236
Add point: 0.08555643259134905, 1.0475523225031793
Add point: 0.0902226519447074, 1.265682577388361
Add point: 0.09455364982407032, 0.528195334598422
Add point: 0.09890610001102851, 0.5753904113080353
Add point: 0.10343357750204052, 0.9604504802264273
Add point: 0.10801160789602858, 1.0716668667737395
Add point: 0.11234228268308055, 0.5274845315143466
Add point: 0.11708132217881606, 1.4258868906181306
Add point: 0.12145071950455363, 3.063370583113283
Add point: 0.12582346464105118, 0.620039300294593
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
