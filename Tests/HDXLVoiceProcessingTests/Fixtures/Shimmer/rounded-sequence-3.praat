# Original query wrapper; no external implementation source.
Create AmplitudeTier: "shimmer", 0.0, 0.1421401582242522
Add point: 0.00390625, 6.113301629666239
Add point: 0.010988458580104634, 0.9150920121464878
Add point: 0.017965305798321164, 0.7675861055031419
Add point: 0.025464113362665686, 1.4983305900823325
Add point: 0.03257948819647676, 0.9615247673355043
Add point: 0.03990050041299713, 1.2494171031285077
Add point: 0.04721453823598235, 1.2396529521793127
Add point: 0.054047605552644075, 0.5662942433264107
Add point: 0.06130577760016812, 1.1614408665336668
Add point: 0.06815894540349421, 0.5944349246565253
Add point: 0.07532253960031085, 1.0290318755432963
Add point: 0.08212161579901087, 0.518706678180024
Add point: 0.08959987692568186, 1.469565577339381
Add point: 0.09665608321566002, 4.39344402984716
Add point: 0.10359952910254444, 0.7208242416381836
Add point: 0.11089015822425219, 1.2068807703908533
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
