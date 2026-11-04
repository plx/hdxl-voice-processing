# Original black-box wrapper; no Praat implementation code is copied.
form Gaussian coefficients
    positive Sample_count 5
    positive Sample_rate 48000
endform
Create Sound from formula: "ones", 1, 0, sample_count / sample_rate, sample_rate, "1"
count = Get number of samples
if count <> sample_count
    exitScript: "Unexpected Sound sample count"
endif
Multiply by window: "Gaussian2"
appendInfoLine: "gaussian2", tab$, count, tab$, sample_rate
for index from 1 to count
    value = Get value at sample number: 1, index
    appendInfoLine: index, tab$, value
endfor
