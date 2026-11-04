# Original numeric export wrapper. The menu pre-emphasis option is calibration-only.
form Conditioning reference
    sentence Input
    positive Target_rate 10000
    natural Depth 50
    real Menu_pre_emphasis -1
endform
sound = Read from file: input$
sound = Resample: target_rate, depth
if menu_pre_emphasis >= 0
    Pre-emphasize (in-place): menu_pre_emphasis
endif
count = Get number of samples
rate = Get sampling frequency
start = Get start time
end = Get end time
first = Get time from sample number: 1
appendInfoLine: "axis", tab$, count, tab$, rate, tab$, start, tab$, end, tab$, first
# Large intervals use 64 uniformly spaced samples and each sample's predecessor.
# This bounds export volume while retaining independent pre-emphasis expectations.
if count <= 4096
    exports = count
else
    exports = 64
endif
for j from 1 to exports
    if count <= 4096
        i = j
    else
        i = 1 + floor ((count - 1) * (j - 1) / (exports - 1))
    endif
    value = Get value at sample number: 1, i
    previous = 0
    if i > 1
        previous = Get value at sample number: 1, i - 1
    endif
    appendInfoLine: "sample", tab$, i - 1, tab$, value, tab$, previous
endfor
