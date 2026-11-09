# Original boundary-query wrapper; the pinned external Pitch object is the oracle.
form Explicit sampled F0 boundary queries
    sentence Pitch_file
    sentence Query_file
endform
pitch = Read from file: pitch_file$
queries = Read Strings from raw text file: query_file$
count = Get number of strings
appendInfoLine: "begin", tab$, "pulse-f0-boundaries-v1"
appendInfoLine: "count", tab$, count
for i from 1 to count
    selectObject: queries
    text$ = Get string: i
    time = number(text$)
    selectObject: pitch
    frequency = Get value at time: time, "Hertz", "Linear"
    appendInfoLine: "query", tab$, i, tab$, time, tab$, frequency
endfor
appendInfoLine: "end", tab$, "pulse-f0-boundaries-v1"
