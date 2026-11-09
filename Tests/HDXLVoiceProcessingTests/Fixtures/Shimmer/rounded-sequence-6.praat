# Original query wrapper; no external implementation source.
Create AmplitudeTier: "shimmer", 0.0, 0.1550087221949361
Add point: 0.00390625, 4.874806647421792
Add point: 0.008777763962280005, 0.7430279245600104
Add point: 0.013673862074385397, 0.7921962242107838
Add point: 0.018501948288292623, 0.6561724278144538
Add point: 0.023325186201604082, 0.6464758266229182
Add point: 0.028530874944524838, 1.4113774858415127
Add point: 0.03370371910289396, 1.345688316738233
Add point: 0.038744462442933586, 1.0814866800792515
Add point: 0.043670575887430466, 0.852226888993755
Add point: 0.0487698110388592, 1.1984703028574586
Add point: 0.0537782769309124, 1.0169317841064185
Add point: 0.05858528078545351, 0.614007709082216
Add point: 0.06379429480968975, 1.418028048472479
Add point: 0.06898102062265389, 6.867258129641414
Add point: 0.07388287874648813, 0.8037162476684898
Add point: 0.07889448792941403, 1.0232183658517897
Add point: 0.0837877316409722, 0.7864874231163412
Add point: 0.08889474699134008, 1.2140307007357478
Add point: 0.09373885206307751, 0.688210143474862
Add point: 0.09885141979681794, 1.225135467480868
Add point: 0.10377645807922818, 0.8500765648204833
Add point: 0.10874152097315527, 0.9301257878541946
Add point: 0.113673068961245, 0.8630959761794657
Add point: 0.11870597801019903, 1.0658180979080498
Add point: 0.12375872219493612, 1.1054883694741875
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
