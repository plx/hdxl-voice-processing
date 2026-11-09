# Original query wrapper; no external implementation source.
Create AmplitudeTier: "shimmer", 0.0, 0.13489815990556964
Add point: 0.00390625, 5.213822986697778
Add point: 0.01222079549722063, 0.9774545966647565
Add point: 0.02042794664448593, 0.8485813767183572
Add point: 0.02888807172479574, 1.15215009637177
Add point: 0.03711743105241719, 0.875231193145737
Add point: 0.045815630119759594, 1.4378388808108866
Add point: 0.054148254881341326, 0.9991497138980776
Add point: 0.06240958335673592, 0.913594170473516
Add point: 0.07038681285843874, 0.5726754020433873
Add point: 0.07851985806017184, 0.759654242079705
Add point: 0.08661432947167973, 0.7133656938094646
Add point: 0.09517062628156663, 1.2675561718642712
Add point: 0.10364815990556965, 1.1730403488036245
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
